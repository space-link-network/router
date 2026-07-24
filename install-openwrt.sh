#!/bin/sh
# Space Link Router installer. POSIX sh, runs in BusyBox.
# Usage: wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install.sh | sh
set -eu

VERSION="0.3.6"
# GitLab "permalink/latest" resolves to the most recent release of the public
# project and exposes each release asset at /downloads/<asset-name>.
RELEASE_BASE="${RELEASE_BASE:-https://gitlab.com/space-link-vpn/router/-/releases/permalink/latest/downloads}"
CLOUD_API="${CLOUD_API:-https://api.space-link.app/api/v1}"
STATE_DIR="/etc/space-link"
BACKUP_DIR="/etc/space-link/backups"
INSTALL_DIR="/opt/space-link"
WWW_DIR="$INSTALL_DIR/www"
RULES_DIR="$INSTALL_DIR/rules"
BIN_PATH="$INSTALL_DIR/space-link-api"

# Где живёт наша панель. По умолчанию — alias-IP на LAN-интерфейсе чтобы
# не конфликтовать с uhttpd (LuCI). Если alias не поднимется, упадём в
# fallback (Вариант A): выключим uhttpd и займём :80 на основном IP.
# IP подобран ВНЕ DHCP-пула OpenWrt (.100-.249) чтобы DHCP его не выдал клиенту.
PANEL_IP="${PANEL_IP:-192.168.1.2}"
PANEL_PORT="${PANEL_PORT:-80}"
# Реальные bind/port, на которых в итоге запустится lighttpd. Считаются после
# configure_panel_ip; до этого = желаемому PANEL_IP/PANEL_PORT.
EFFECTIVE_BIND="$PANEL_IP"
EFFECTIVE_PORT="$PANEL_PORT"
ROUTER_IP=""

# Пакеты, критичные для ПАНЕЛИ/ДОМЕНА — установка прерывается, если чего-то нет.
# sing-box (VPN-движок) СОЗНАТЕЛЬНО не здесь: его отсутствие не должно мешать
# подняться панели и my.space (см. цикл движка в install_packages).
REQUIRED_PKGS="ca-certificates curl lighttpd lighttpd-mod-proxy lighttpd-mod-rewrite lighttpd-mod-redirect lighttpd-mod-setenv"
# VPN-движок — best-effort: если недоступен в фиде, WARN и продолжаем, чтобы
# панель/домен всё равно поднялись; движок можно доустановить позже.
ENGINE_PKGS="sing-box"
# Optional pkgs — install if available, warn-only on failure.
OPTIONAL_PKGS="kmod-tun"

# Resolve script dir so the bundled installer (run from a worktree or
# /tmp extraction) can find ./lib and ./templates. When piped via wget,
# we fall back to downloading them.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0" 2>/dev/null || echo .)" && pwd 2>/dev/null || echo /tmp)

# ---- CLI args --------------------------------------------------------------
TOKEN=""
SKIP_TOKEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --token)
      shift
      TOKEN="${1:-}"
      ;;
    --token=*)
      TOKEN="${1#--token=}"
      ;;
    --skip-token)
      SKIP_TOKEN=1
      ;;
    --help|-h)
      cat <<EOF
Space Link Router installer

Usage:
  install.sh [--token <value>] [--skip-token]

Options:
  --token <value>   Pre-set the Space Link cloud token (non-interactive).
  --skip-token      Skip the token prompt entirely (configure later in UI).
  -h, --help        Show this help and exit.
EOF
      exit 0
      ;;
  esac
  shift || true
done

# ---- helpers ---------------------------------------------------------------
if [ -f "$SCRIPT_DIR/lib/colors.sh" ]; then
  . "$SCRIPT_DIR/lib/colors.sh"
  . "$SCRIPT_DIR/lib/arch-detect.sh"
  . "$SCRIPT_DIR/lib/api-client.sh"
else
  # Minimal fallback when piped from network (lib/ not next to us).
  step()  { printf '==> %s\n' "$1"; }
  ok()    { printf 'OK  %s\n' "$1"; }
  warn()  { printf 'WRN %s\n' "$1"; }
  err()   { printf 'ERR %s\n' "$1" 1>&2; }
  die()   { err "$1"; exit "${2:-1}"; }
  banner() { printf '\n  Space Link Router\n\n'; }
  detect_arch() {
    case "$(uname -m 2>/dev/null)" in
      aarch64|arm64) echo aarch64 ;;
      armv7l|armv7|armhf) echo armv7 ;;
      mipsel|mips|mips64el) echo mipsel ;;
      *) echo unknown ;;
    esac
  }
  validate_token() {
    [ -z "${1:-}" ] && return 2
    _hwid="rtr-$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':' | tr 'A-Z' 'a-z' || echo unknown)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 10 -H "Authorization: Bearer $1" -H "X-Hwid: $_hwid" "$CLOUD_API/router/validate" >/dev/null 2>&1
    else
      wget -q --timeout=10 --header="Authorization: Bearer $1" --header="X-Hwid: $_hwid" -O- "$CLOUD_API/router/validate" >/dev/null 2>&1
    fi
  }
fi

# ---- detection mode --------------------------------------------------------
mode="first_install"
if [ -f "$STATE_DIR/version" ]; then
  prev=$(cat "$STATE_DIR/version" 2>/dev/null || echo "")
  if [ "$prev" = "$VERSION" ]; then
    mode="repair"
  else
    mode="update"
  fi
fi

# ---- helpers: service wait ------------------------------------------------
# Опрашивает init.d-сервис до ~10 сек, потом сдаётся. Возвращает 0 если жив.
wait_service_up() {
  svc="$1"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if /etc/init.d/"$svc" status 2>/dev/null | grep -q running; then
      return 0
    fi
    if pgrep -x "$svc" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ---- UCI backup / rollback -------------------------------------------------
# Снимок текущих UCI-конфигов ДО любых правок. Хранится в /etc/space-link/backups/
# вместе с симлинком *.latest.uci на актуальный. Используется чтобы при любой
# поломке (наш баг, неудачный network reload, битый dhcp.address) можно было
# вернуться к рабочему состоянию.
backup_uci_state() {
  mkdir -p "$BACKUP_DIR"
  ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
  for conf in dhcp network firewall wireless; do
    if uci -q export "$conf" > "$BACKUP_DIR/$conf.$ts.uci" 2>/dev/null; then
      ln -sf "$conf.$ts.uci" "$BACKUP_DIR/$conf.latest.uci" 2>/dev/null || true
    else
      rm -f "$BACKUP_DIR/$conf.$ts.uci" 2>/dev/null || true
    fi
  done
  # Сырые файлы тоже копируем — на случай если uci-парсер сам не справится.
  for f in dhcp network firewall wireless; do
    [ -r "/etc/config/$f" ] && cp "/etc/config/$f" "$BACKUP_DIR/$f.raw.$ts" 2>/dev/null || true
  done
  ok "снапшот UCI: $BACKUP_DIR (ts=$ts)"
}

rollback_uci() {
  conf="$1"
  bak="$BACKUP_DIR/${conf}.latest.uci"
  [ -r "$bak" ] || return 1
  uci -q import "$conf" < "$bak" 2>/dev/null || return 1
  uci -q commit "$conf" 2>/dev/null || return 1
  return 0
}

# ---- dnsmasq self-healing --------------------------------------------------
# Если dnsmasq лежит (наследие от прошлой сломанной установки) — пытаемся
# поднять. Последовательно: restart → чистка битых list address → restart →
# восстановление /etc/config/dhcp из /rom/ → restart. Если и так не взлетел,
# install прерывается, потому что без dnsmasq DHCP/DNS клиентам не работает.
ensure_dnsmasq_alive() {
  step "Проверка dnsmasq"
  if pgrep dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq уже работает"
    return 0
  fi

  warn "dnsmasq не запущен — пробую поднять"
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 2
  if pgrep dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq поднят"
    return 0
  fi

  # Битые address-записи (с экранированными кавычками и т.п.) типичный
  # симптом — sed выгребает любую строку с обратным слэшем.
  warn "ищу битые list address в /etc/config/dhcp"
  if [ -f /etc/config/dhcp ]; then
    bad=$(grep -E "^[[:space:]]*list[[:space:]]+address.*\\\\" /etc/config/dhcp 2>/dev/null || true)
    if [ -n "$bad" ]; then
      warn "найдены битые записи, удаляю"
      sed -i '/list address.*\\/d' /etc/config/dhcp 2>/dev/null || true
    fi
  fi
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 2
  if pgrep dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq поднят (после чистки битых записей)"
    return 0
  fi

  # Заводской конфиг /rom/etc/config/dhcp — последний резерв.
  if [ -r /rom/etc/config/dhcp ]; then
    warn "восстанавливаю заводской /etc/config/dhcp из /rom/"
    cp /etc/config/dhcp "$BACKUP_DIR/dhcp.broken.$(date +%s 2>/dev/null || echo x)" 2>/dev/null || true
    cp /rom/etc/config/dhcp /etc/config/dhcp 2>/dev/null || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
  fi

  if pgrep dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq восстановлен из заводского конфига"
    return 0
  fi

  die "dnsmasq не запускается даже с заводского /etc/config/dhcp. Проверь logread -e dnsmasq."
}

# ---- migrate from xray (v0.1.x → v0.2.0) ----------------------------------
# Раньше движком был xray-core. С v0.2.0 переехали на sing-box. Если на роутере
# остались старые артефакты — гасим демона и сносим конфиги/geo-данные, чтобы
# не сбивали init.d и не занимали место. Идемпотентно: если xray не было,
# функция молча проходит.
migrate_from_xray() {
  if [ ! -f /etc/init.d/xray ] && [ ! -d /etc/xray ]; then
    return 0
  fi
  step "Миграция с xray (если был)"
  if [ -f /etc/init.d/xray ]; then
    /etc/init.d/xray stop    >/dev/null 2>&1 || true
    /etc/init.d/xray disable >/dev/null 2>&1 || true
  fi
  rm -rf /etc/xray 2>/dev/null || true
  rm -f /usr/bin/geoip.dat /usr/bin/geosite.dat 2>/dev/null || true
  ok "xray-артефакты убраны"
}

# ---- preflight -------------------------------------------------------------
preflight() {
  step "Проверки окружения"

  if [ ! -f /etc/openwrt_release ]; then
    warn "Не обнаружен /etc/openwrt_release — установка возможно не на OpenWrt. Продолжаем."
  else
    ok "OpenWrt"
  fi

  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
      ok "Интернет"
    else
      die "Нет интернета. Проверьте подключение."
    fi
  fi

  # DNS: убедимся что resolv.conf валиден. Если нет — пишем fallback в
  # /tmp/resolv.conf (его /etc/resolv.conf обычно симлинкает).
  ensure_dns

  ARCH=$(detect_arch)
  if [ "$ARCH" = "unknown" ]; then
    die "Неизвестная архитектура: $(uname -m)"
  fi
  ok "Архитектура: $ARCH"
}

ensure_dns() {
  # Если dnsmasq отвечает на 127.0.0.1:53 — всё хорошо.
  if command -v nslookup >/dev/null 2>&1; then
    if nslookup localhost 127.0.0.1 >/dev/null 2>&1; then
      ok "DNS (через dnsmasq)"
      return 0
    fi
  fi
  # Проверим /etc/resolv.conf на наличие внешнего nameserver-а.
  if [ -r /etc/resolv.conf ]; then
    if grep -E '^nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null \
       | grep -vqE '127\.0\.0\.1|::1'; then
      ok "DNS (resolv.conf)"
      return 0
    fi
  fi
  warn "Нет рабочего DNS — ставлю fallback 1.1.1.1"
  if [ -L /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
    mkdir -p /tmp
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf
  else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >> /etc/resolv.conf
  fi
}

# ---- token prompt ----------------------------------------------------------
prompt_token() {
  # During update/repair we keep whatever token was already saved.
  [ "$mode" = "first_install" ] || return 0

  # If user passed --token on the command line, validate and we're done.
  if [ -n "$TOKEN" ]; then
    step "Токен передан в аргументах — проверяю"
    if validate_token "$TOKEN"; then ok "Токен принят"
    else warn "Токен не прошёл проверку. Сохраняю как есть — можно заменить в UI."
    fi
    return 0
  fi
  if [ "$SKIP_TOKEN" = "1" ]; then
    printf 'Токен пропущен (--skip-token). Настройте позже: http://my.space/\n'
    return 0
  fi

  # Decide which fd to read from. `wget | sh` has stdin bound to the pipe —
  # so we fall back to /dev/tty when stdin isn't a terminal. If neither is
  # available, skip silently.
  if [ -t 0 ]; then
    _tty_in="/dev/stdin"
  elif [ -r /dev/tty ]; then
    _tty_in="/dev/tty"
  else
    printf '\nНет терминала для ввода токена. Открой http://my.space/ и введи токен или ссылку подписки в разделе Setup.\n'
    return 0
  fi

  printf '\n'
  printf 'Token (Enter to skip): '
  # POSIX read from the chosen fd.
  read -r TOKEN < "$_tty_in" || TOKEN=""

  if [ -n "$TOKEN" ]; then
    step "Проверка токена..."
    if validate_token "$TOKEN"; then
      ok "Токен принят"
    else
      warn "Токен не прошёл проверку. Сохраняю как есть — можно заменить позже в UI."
    fi
  else
    printf 'Пропущено. Открой http://my.space/ и введи токен или ссылку подписки в Setup.\n'
  fi
}

# ---- package install -------------------------------------------------------
# OpenWrt 24.10+ migrated from opkg to apk (Alpine Package Keeper). We detect
# what's actually present and call the matching commands. Package names are
# identical between the two on OpenWrt, so only the verbs change.
PKG_MGR=""
pkg_is_installed() {
  case "$PKG_MGR" in
    apk)  apk info -e "$1" >/dev/null 2>&1 ;;
    opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
  esac
}
pkg_install_one() {
  case "$PKG_MGR" in
    apk)  apk add "$1" >/dev/null 2>&1 ;;
    opkg) opkg install "$1" >/dev/null 2>&1 ;;
  esac
}
pkg_update_index() {
  case "$PKG_MGR" in
    apk)  apk update >/dev/null 2>&1 ;;
    opkg) opkg update >/dev/null 2>&1 ;;
  esac
}

install_packages() {
  step "Установка системных пакетов"
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
    ok "пакетный менеджер: apk (OpenWrt 24.10+)"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR=opkg
    ok "пакетный менеджер: opkg"
  else
    die "Ни apk, ни opkg не найден. Этот установщик рассчитан на OpenWrt/ImmortalWrt."
  fi

  step "Обновление списка пакетов"
  pkg_update_index || warn "не удалось обновить индекс — продолжаем"

  missing=""
  for pkg in $REQUIRED_PKGS; do
    if pkg_is_installed "$pkg"; then
      ok "$pkg (уже стоит)"
      continue
    fi
    if pkg_install_one "$pkg"; then
      ok "$pkg"
    else
      missing="$missing $pkg"
    fi
  done
  if [ -n "$missing" ]; then
    die "Не удалось установить обязательные пакеты:$missing. Проверь интернет/репозитории и повтори."
  fi

  # VPN-движок (sing-box): best-effort. Панель и домен обязаны подняться даже
  # если движок недоступен в фиде — иначе одна проблема с пакетом валит всю
  # установку ещё ДО настройки my.space/панели.
  for pkg in $ENGINE_PKGS; do
    if pkg_is_installed "$pkg"; then
      ok "$pkg (движок, уже стоит)"
    elif pkg_install_one "$pkg"; then
      ok "$pkg (движок)"
    else
      warn "движок $pkg не установился — панель и домен поднимутся, но VPN не заработает, пока не поставишь его вручную: apk add $pkg (или opkg install $pkg)"
    fi
  done

  for pkg in $OPTIONAL_PKGS; do
    if pkg_is_installed "$pkg"; then
      ok "$pkg (опц., уже стоит)"
    elif pkg_install_one "$pkg"; then
      ok "$pkg (опц.)"
    else
      warn "не удалось установить $pkg (опционально, пропускаю)"
    fi
  done
}

# ---- download artifacts ----------------------------------------------------
fetch() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  else
    wget -q -O "$out" "$url"
  fi
}

install_binary() {
  step "Загрузка space-link-api ($ARCH)"
  mkdir -p "$INSTALL_DIR"
  url="$RELEASE_BASE/space-link-api-$ARCH"
  fetch "$url" "$BIN_PATH.new" || die "Не удалось скачать $url"
  chmod 0755 "$BIN_PATH.new"
  mv "$BIN_PATH.new" "$BIN_PATH"
  ok "$BIN_PATH"
}

install_ui() {
  step "Загрузка UI bundle"
  mkdir -p "$WWW_DIR"
  fetch "$RELEASE_BASE/ui.tar.gz" /tmp/space-link-ui.tar.gz || die "Не удалось скачать ui.tar.gz"
  tar -xzf /tmp/space-link-ui.tar.gz -C "$WWW_DIR"
  rm -f /tmp/space-link-ui.tar.gz
  ok "$WWW_DIR"
}

install_rules() {
  step "Установка пресетов маршрутизации"
  mkdir -p "$RULES_DIR/presets"
  if [ -d "$SCRIPT_DIR/../rules/presets" ]; then
    cp "$SCRIPT_DIR/../rules/presets"/*.txt "$RULES_DIR/presets/" 2>/dev/null || true
  else
    for preset in ru cis ai social stores crypto ads twitch-ads win-spy torrent; do
      fetch "$RELEASE_BASE/rules-$preset.txt" "$RULES_DIR/presets/$preset.txt" 2>/dev/null \
        || warn "пресет $preset не скачался — не критично, можно выбрать позже"
    done
  fi
  ok "$RULES_DIR"
}

# ---- templates -------------------------------------------------------------
install_templates() {
  step "Установка конфигов"

  mkdir -p /etc/lighttpd/conf.d
  # lighttpd
  if [ -f "$SCRIPT_DIR/../templates/lighttpd.conf" ]; then
    cp "$SCRIPT_DIR/../templates/lighttpd.conf" /etc/lighttpd/conf.d/space-link.conf
  else
    fetch "$RELEASE_BASE/lighttpd.conf" /etc/lighttpd/conf.d/space-link.conf || warn "lighttpd.conf пропущен"
  fi
  # Подставляем реальный bind/port. Разделитель | вместо /, чтобы IP с маской
  # или путь не ломали выражение. Отдельные -e команды — BusyBox sed не любит ';'.
  sed -i -e "s|__PANEL_IP__|$EFFECTIVE_BIND|g" \
         -e "s|__PANEL_PORT__|$EFFECTIVE_PORT|g" \
    /etc/lighttpd/conf.d/space-link.conf 2>/dev/null || warn "не удалось подставить PANEL_IP/PORT в lighttpd.conf"
  ok "lighttpd ($EFFECTIVE_BIND:$EFFECTIVE_PORT)"

  # init.d
  if [ -f "$SCRIPT_DIR/../templates/space-link.init" ]; then
    cp "$SCRIPT_DIR/../templates/space-link.init" /etc/init.d/space-link
  else
    fetch "$RELEASE_BASE/space-link.init" /etc/init.d/space-link || warn "init script пропущен"
  fi
  chmod 0755 /etc/init.d/space-link
  ok "init.d"

  # Reversible dnsmasq -> sing-box forwarding controller.
  if [ -f "$SCRIPT_DIR/../templates/space-link-dns" ]; then
    cp "$SCRIPT_DIR/../templates/space-link-dns" /usr/bin/space-link-dns
  else
    fetch "$RELEASE_BASE/space-link-dns" /usr/bin/space-link-dns || warn "DNS controller пропущен"
  fi
  chmod 0755 /usr/bin/space-link-dns 2>/dev/null || true
  ok "DNS controller"
}

# ---- panel IP alias --------------------------------------------------------
# Пытается поднять alias-IP. Если не поднялся за 2 сек — fallback (Вариант A):
# выключаем uhttpd, занимаем :80 на основном IP роутера. EFFECTIVE_BIND и
# EFFECTIVE_PORT в конце отражают реальное место панели.
configure_panel_ip() {
  # uci get может вернуть "192.168.1.1/24" (если уже list) или несколько
  # адресов через пробел — берём первый и отрезаем маску. Это и есть
  # настоящий primary-IP роутера, без артефактов прошлых установок.
  ROUTER_IP_RAW=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
  ROUTER_IP=$(printf '%s\n' "$ROUTER_IP_RAW" | awk '{print $1}' | cut -d'/' -f1)
  [ -n "$ROUTER_IP" ] || ROUTER_IP="192.168.1.1"
  ROUTER_MASK=$(uci -q get network.lan.netmask 2>/dev/null || echo "255.255.255.0")

  step "Доп. IP для панели: $PANEL_IP (основной: $ROUTER_IP)"
  if ! command -v uci >/dev/null 2>&1; then
    warn "uci недоступен — переключаюсь на основной IP роутера ($ROUTER_IP)"
    fallback_to_router_ip
    return 0
  fi

  # Удалим старый отдельный интерфейс lan_panel если был от v0.1.4-v0.1.7 —
  # он на OpenWrt 25.x ломал основной IP. Переходим на secondary list ipaddr.
  if uci -q get network.lan_panel >/dev/null 2>&1; then
    uci -q delete network.lan_panel
  fi

  # Перезаписываем list ipaddr с нуля: основной IP + наш panel-IP, оба с /24.
  # Старые значения (включая возможные дубли и битые) выбрасываем.
  cidr_main="$ROUTER_IP/24"
  cidr_panel="$PANEL_IP/24"

  # Перезаписываем целиком, чтобы убрать возможные дубли наших прошлых попыток.
  uci -q delete network.lan.ipaddr 2>/dev/null || true
  uci add_list network.lan.ipaddr="$cidr_main"
  uci add_list network.lan.ipaddr="$cidr_panel"
  uci commit network

  # Reload сети — нативный путь, в одном интерфейсе оба IP не теряются.
  service network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
  sleep 3

  # Verify: основной IP жив И PANEL_IP появился.
  main_present=0
  alias_present=0
  ip addr show br-lan 2>/dev/null | grep -q "inet $ROUTER_IP/" && main_present=1
  ip addr show br-lan 2>/dev/null | grep -q "inet $PANEL_IP/" && alias_present=1

  # Подстраховка: если reload не поднял secondary-IP (частая причина «сайт/домен
  # не открывается на первой установке» — на интерфейсе оказался один адрес
  # вместо двух) — добавляем его напрямую. ip addr add НЕ рвёт соединение (в
  # отличие от полного restart сети, что убило бы SSH-сессию установки), а
  # uci-конфиг с двумя ipaddr уже закоммичен выше, так что адрес переживёт reboot.
  if [ "$alias_present" != "1" ]; then
    ip addr add "$PANEL_IP/24" dev br-lan 2>/dev/null || true
    sleep 1
    ip addr show br-lan 2>/dev/null | grep -q "inet $PANEL_IP/" && alias_present=1
    ip addr show br-lan 2>/dev/null | grep -q "inet $ROUTER_IP/" && main_present=1
  fi

  if [ "$main_present" = "1" ] && [ "$alias_present" = "1" ]; then
    EFFECTIVE_BIND="$PANEL_IP"
    EFFECTIVE_PORT="$PANEL_PORT"
    ok "доп. IP $PANEL_IP/24 на br-lan, основной $ROUTER_IP жив — LuCI и панель параллельно"
    # Прибиваем uhttpd явно к ROUTER_IP, без 0.0.0.0-wildcard. Без этого
    # uhttpd при следующем boot стартует первым и забирает 0.0.0.0:80 на
    # всех интерфейсах включая PANEL_IP — наш lighttpd падает на
    # "Address already in use" и панель пропадает после reboot.
    uci -q delete uhttpd.main.listen_http  >/dev/null 2>&1 || true
    uci -q delete uhttpd.main.listen_https >/dev/null 2>&1 || true
    uci add_list uhttpd.main.listen_http="$ROUTER_IP:80"   >/dev/null 2>&1 || true
    uci add_list uhttpd.main.listen_https="$ROUTER_IP:443" >/dev/null 2>&1 || true
    uci commit uhttpd >/dev/null 2>&1 || true

    /etc/init.d/uhttpd enable  >/dev/null 2>&1 || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd start >/dev/null 2>&1 || true
    sleep 1
    if pgrep uhttpd >/dev/null 2>&1; then
      ok "uhttpd (LuCI) запущен на http://$ROUTER_IP/ (bind only)"
    else
      warn "uhttpd не стартовал — LuCI недоступна, не критично"
    fi
    return 0
  fi

  warn "secondary IP не встал (main=$main_present alias=$alias_present) — откатываю"
  rollback_uci network >/dev/null 2>&1 || true
  service network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
  sleep 3
  fallback_to_router_ip
}

# Вариант A: гасим uhttpd (LuCI), слушаем на основном IP роутера :80.
fallback_to_router_ip() {
  # Двойная санитизация — на случай если configure_panel_ip ещё не успел.
  clean=$(printf '%s\n' "${ROUTER_IP:-192.168.1.1}" | awk '{print $1}' | cut -d'/' -f1)
  [ -n "$clean" ] || clean="192.168.1.1"
  EFFECTIVE_BIND="$clean"
  EFFECTIVE_PORT="80"
  warn "выключаю uhttpd (LuCI будет недоступна до удаления нашего конфига)"
  /etc/init.d/uhttpd stop  >/dev/null 2>&1 || true
  /etc/init.d/uhttpd disable >/dev/null 2>&1 || true
}

disarm_traffic_path() {
  # Remove the old unconditional hotplug first. Otherwise a firewall reload
  # during package installation can recreate the table after we stop it.
  rm -f /etc/hotplug.d/firewall/99-space-link-tproxy 2>/dev/null || true
  rm -f /etc/space-link/tproxy.armed 2>/dev/null || true
  if [ -x /usr/bin/space-link-dns ]; then
    /usr/bin/space-link-dns disable >/dev/null 2>&1 || true
  fi
  if [ -x /etc/init.d/space-link-tproxy ]; then
    /etc/init.d/space-link-tproxy stop >/dev/null 2>&1 || true
    /etc/init.d/space-link-tproxy disable >/dev/null 2>&1 || true
  fi
  nft delete table inet space_link >/dev/null 2>&1 || true
  ip rule del fwmark 0xff >/dev/null 2>&1 || true
  ip -6 rule del fwmark 0xff >/dev/null 2>&1 || true
  ip route flush table 100 >/dev/null 2>&1 || true
  ip -6 route flush table 100 >/dev/null 2>&1 || true
}

# ---- transparent proxy -----------------------------------------------------
# Поднимаем TPROXY: маркируем LAN-трафик через nftables, заворачиваем по
# fwmark в отдельную routing-таблицу с local-route на lo, где sing-box ловит его
# на tproxy inbound :12345. Без этого sing-box на роутере — просто SOCKS-прокси
# на localhost, и клиенты в WiFi его не видят.
#
# Параметры можно переопределить из окружения (TPROXY_PORT/TPROXY_MARK/TPROXY_TABLE),
# но дефолты прибиты к sing-box-конфигу — менять синхронно с api/internal/singbox/singbox.go.
#
# На OpenWrt 25.x все файлы в /etc/nftables.d/ инклюдятся ВНУТРЬ fw4-сгенерированной
# таблицы — там нельзя писать `table inet space_link { ... }` (таблица в таблице,
# парсер падает). Поэтому держим nft-конфиг отдельно: свой каталог
# /etc/space-link/, свой init.d-скрипт, и hotplug firewall — поднимает табличку
# обратно после каждого fw4 reload, который мог снести её.
configure_tproxy() {
  step "Настройка прозрачного проксирования (TPROXY)"
  disarm_traffic_path
  TPROXY_PORT="${TPROXY_PORT:-12345}"
  TPROXY_MARK="${TPROXY_MARK:-255}"
  TPROXY_TABLE="${TPROXY_TABLE:-100}"

  # Anti-leak controls.
  #   dns_tunnel — keep external port-53 traffic inside the protected path.
  #   block_quic — optional troubleshooting switch only. Native applications
  #                such as YouTube do not reliably fall back from QUIC, so
  #                UDP/443 must be proxied by default rather than rejected.
  DNS_TUNNEL="${TPROXY_DNS_TUNNEL:-$(uci -q get space-link.tproxy.dns_tunnel 2>/dev/null || echo 1)}"
  if [ -n "${TPROXY_BLOCK_QUIC+x}" ]; then
    BLOCK_QUIC="$TPROXY_BLOCK_QUIC"
  elif [ "$(uci -q get space-link.tproxy.quic_default_v026 2>/dev/null || echo 0)" != "1" ]; then
    # v0.3.25 persisted the harmful value 1 as its default. Clear it exactly
    # once on both upgrades and fresh installs; later explicit UCI choices are
    # preserved after the migration marker exists.
    BLOCK_QUIC=0
  else
    BLOCK_QUIC="$(uci -q get space-link.tproxy.block_quic 2>/dev/null || echo 0)"
  fi

  # Persist effective values so diagnostics and future repair installs agree.
  if ! uci -q get space-link.tproxy >/dev/null 2>&1; then
    uci -q set space-link=tproxy 2>/dev/null || {
      touch /etc/config/space-link 2>/dev/null || true
      uci -q set space-link.tproxy=tproxy 2>/dev/null || true
    }
  fi
  uci -q set space-link.tproxy.dns_tunnel="$DNS_TUNNEL" 2>/dev/null || true
  uci -q set space-link.tproxy.block_quic="$BLOCK_QUIC" 2>/dev/null || true
  uci -q set space-link.tproxy.quic_default_v026=1 2>/dev/null || true
  uci -q commit space-link 2>/dev/null || true

  # 1) Убедимся что ядро умеет nft tproxy. Сначала пробуем modprobe, потом
  #    apk add нужных kmod-пакетов. Если ничего не помогло — выходим
  #    мягко, не валим всю установку.
  for mod in nf_tproxy xt_TPROXY nft_tproxy; do
    lsmod 2>/dev/null | grep -q "^$mod " || modprobe "$mod" 2>/dev/null || true
  done
  if ! lsmod 2>/dev/null | grep -q nft_tproxy; then
    warn "nft_tproxy не загружен, ставлю пакет"
    if [ "$PKG_MGR" = "apk" ]; then
      apk add kmod-nft-tproxy kmod-nf-tproxy >/dev/null 2>&1 || {
        warn "kmod-nft-tproxy не доступен — TPROXY не настроится"
        return 0
      }
    elif [ "$PKG_MGR" = "opkg" ]; then
      opkg install kmod-nft-tproxy kmod-nf-tproxy >/dev/null 2>&1 || {
        warn "kmod-nft-tproxy не доступен — TPROXY не настроится"
        return 0
      }
    fi
    modprobe nft_tproxy 2>/dev/null || true
    if ! lsmod 2>/dev/null | grep -q nft_tproxy; then
      warn "модуль nft_tproxy не загрузился — TPROXY не настроится"
      return 0
    fi
  fi
  ok "nft_tproxy готов"

  # 2) Снять старый сломанный drop-in из v0.1.13 если он остался.
  if [ -f /etc/nftables.d/99-space-link-tproxy.nft ]; then
    rm -f /etc/nftables.d/99-space-link-tproxy.nft
    if command -v fw4 >/dev/null 2>&1; then
      fw4 reload >/dev/null 2>&1 || true
    fi
  fi

  # 3) Алиас для routing-таблицы (читаемость `ip rule show`).
  mkdir -p /etc/iproute2 2>/dev/null || true
  if [ -f /etc/iproute2/rt_tables ]; then
    if ! grep -q "^[[:space:]]*$TPROXY_TABLE[[:space:]]\+space-link" /etc/iproute2/rt_tables 2>/dev/null; then
      sed -i "/^[[:space:]]*$TPROXY_TABLE[[:space:]]/d" /etc/iproute2/rt_tables 2>/dev/null || true
      printf '%s space-link\n' "$TPROXY_TABLE" >> /etc/iproute2/rt_tables
    fi
  fi

  # 4) Standalone nft-конфиг — кладём ВНЕ /etc/nftables.d/, чтобы fw4 его
  #    не подсасывал. `table ... ; delete table ...` в начале — идиома для
  #    идемпотентности: если таблица есть, она пересоздаётся; если нет —
  #    delete молча игнорится благодаря объявлению на первой строке.
  mkdir -p /etc/space-link 2>/dev/null || true

  # DNS-leak тумблер: когда dns_tunnel=1, перехватываем исходящий из LAN
  # DNS (порт 53 tcp+udp) в tproxy ДО private-исключений — иначе запрос к
  # dnsmasq/роутеру (192.168.x.1:53) вернулся бы по `return` и ушёл мимо
  # туннеля. sing-box ловит его на tproxy-инбаунде и гонит через dns-out.
  DNS_RULE_V4=""
  DNS_RULE_V6=""
  if [ "$DNS_TUNNEL" = "1" ]; then
    DNS_RULE_V4="iifname \"br-lan\" meta l4proto { tcp, udp } th dport 53 tproxy ip to :__TPROXY_PORT__ meta mark set __TPROXY_MARK__ accept"
    DNS_RULE_V6="iifname \"br-lan\" meta l4proto { tcp, udp } th dport 53 tproxy ip6 to :__TPROXY_PORT__ meta mark set __TPROXY_MARK__ accept"
  fi

  # QUIC тумблер: режем UDP/443 из LAN, чтобы браузеры откатились на TCP/TLS
  # (HTTP/2), который tproxy уверенно sniff'ит. Иначе часть HTTP/3-трафика
  # уходит по IP-маршрутизации мимо правил доменной маршрутизации.
  QUIC_RULE=""
  if [ "$BLOCK_QUIC" = "1" ]; then
    QUIC_RULE="iifname \"br-lan\" meta l4proto udp th dport 443 reject"
  fi

  cat > /etc/space-link/tproxy.nft <<NFT
table inet space_link
delete table inet space_link

table inet space_link {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # IPv4 private / special-use исключения — этот трафик НЕ заворачиваем.
        ip daddr 0.0.0.0/8        return
        ip daddr 10.0.0.0/8       return
        ip daddr 127.0.0.0/8      return
        ip daddr 169.254.0.0/16   return
        ip daddr 172.16.0.0/12    return
        ip daddr 192.168.0.0/16   return
        ip daddr 100.64.0.0/10    return
        ip daddr 224.0.0.0/4      return
        ip daddr 240.0.0.0/4      return
        ip daddr 255.255.255.255  return

        # IPv6 private / special-use исключения (симметрично IPv4) — закрывает
        # v6-leak: без них ip6 daddr-трафик из LAN не имел бы private-returns и
        # ловился бы (или утекал в зависимости от ip6 rule). LAN/ULA/link-local
        # и multicast остаются локальными.
        ip6 daddr ::1/128         return
        ip6 daddr ::/128          return
        ip6 daddr fe80::/10       return
        ip6 daddr fc00::/7        return
        ip6 daddr ff00::/8        return
        ip6 daddr ::ffff:0:0/96   return

        fib daddr type local      return
        # Перехватываем только DNS к внешним адресам. Запросы к LAN-адресу
        # роутера должны дойти до dnsmasq; их TPROXY-перехват лишает клиентов DNS.
        ${DNS_RULE_V4}
        ${DNS_RULE_V6}



        # QUIC-block (по тумблеру block_quic): режем UDP/443 → TCP-fallback.
        ${QUIC_RULE}

        # Основной заворот: TCP+UDP из LAN на tproxy-инбаунд sing-box.
        # Парные правила для IPv4 и IPv6 (tproxy ip / tproxy ip6).
        iifname "br-lan" meta l4proto { tcp, udp } meta nfproto ipv4 tproxy ip to :__TPROXY_PORT__ meta mark set __TPROXY_MARK__ accept
        iifname "br-lan" meta l4proto { tcp, udp } meta nfproto ipv6 tproxy ip6 to :__TPROXY_PORT__ meta mark set __TPROXY_MARK__ accept
    }
    # output chain убран в v0.2.3 — он содержал только returns без активной
    # маркировки, при этом регистрировался как второй mangle-hook на output
    # и конфликтовал с fw4-chain, провоцируя respawn-петлю sing-box.
}
NFT
  sed -i "s/__TPROXY_PORT__/$TPROXY_PORT/g; s/__TPROXY_MARK__/$TPROXY_MARK/g" /etc/space-link/tproxy.nft
  # Подчистить пустые строки от незаданных опциональных правил (косметика).
  sed -i '/^        $/d' /etc/space-link/tproxy.nft

  # 5) init.d-скрипт. apply: грузит nft + ставит fwmark rule + local-route.
  #    stop: сносит таблицу и rule. reload == apply.
  cat > /etc/init.d/space-link-tproxy <<'INITD'
#!/bin/sh /etc/rc.common
START=99
STOP=10

clear_path() {
  nft delete table inet space_link 2>/dev/null
  ip rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip route flush table __TABLE__ 2>/dev/null
  ip -6 rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip -6 route flush table __TABLE__ 2>/dev/null
}

engine_ready() {
  pgrep -x sing-box >/dev/null 2>&1 || return 1
  command -v netstat >/dev/null 2>&1 || return 1
  netstat -ln 2>/dev/null | grep -Eq '[:.]12345[[:space:]]'
}

apply() {
  # The persistent marker records desired state, but a procd process can exist
  # before its listener is ready. Both conditions are required on every start
  # and firewall reload.
  if [ ! -f /etc/space-link/tproxy.armed ] || ! engine_ready; then
    clear_path
    return 1
  fi
  if ! nft_output=$(nft -f /etc/space-link/tproxy.nft 2>&1); then
    printf '%s\n' "$nft_output" | logger -t space-link-tproxy
    clear_path
    return 1
  fi
  [ -z "$nft_output" ] || printf '%s\n' "$nft_output" | logger -t space-link-tproxy
  ip rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip rule add fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip route flush table __TABLE__ 2>/dev/null
  ip route add local 0.0.0.0/0 dev lo table __TABLE__ 2>/dev/null
  ip -6 rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip -6 rule add fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip -6 route flush table __TABLE__ 2>/dev/null
  ip -6 route add local ::/0 dev lo table __TABLE__ 2>/dev/null
}

start() { apply; }
stop() { clear_path; }
reload() { apply; }
INITD
  sed -i "s/__MARK__/$TPROXY_MARK/g; s/__TABLE__/$TPROXY_TABLE/g" /etc/init.d/space-link-tproxy
  chmod 0755 /etc/init.d/space-link-tproxy

  # 6) Firewall hotplug: после fw4 reload (например при network restart) наша
  #    table inet space_link может слететь — переподнимаем.
  mkdir -p /etc/hotplug.d/firewall 2>/dev/null || true
  cat > /etc/hotplug.d/firewall/99-space-link-tproxy <<'HOOK'
#!/bin/sh
# fw4 reload may remove the standalone table. Restore it only while the
# health-gated path is armed and the destination listener still exists.
if [ -f /etc/space-link/tproxy.armed ] && pgrep -x sing-box >/dev/null 2>&1; then
  /etc/init.d/space-link-tproxy reload >/dev/null 2>&1 || /etc/init.d/space-link-tproxy stop >/dev/null 2>&1
else
  /etc/init.d/space-link-tproxy stop >/dev/null 2>&1
fi
HOOK
  chmod 0755 /etc/hotplug.d/firewall/99-space-link-tproxy

  # 7) Снять старый iface-hotplug от v0.1.13, если остался.
  rm -f /etc/hotplug.d/iface/99-space-link-tproxy 2>/dev/null || true

  # Install and enable the service, but do not intercept anything yet.
  # activate_traffic_path performs the engine/config/listener health gate.
  /etc/init.d/space-link-tproxy enable 2>/dev/null || true
  ok "TPROXY настроен и ожидает проверку sing-box"
}

# The active config must be valid, the process stable, and the transparent
# listener present before LAN interception can be armed.
traffic_engine_ready() {
  [ -s /etc/space-link/active-server ] || return 1
  if [ -x /usr/bin/sing-box ]; then
    /usr/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || return 1
  fi
  pgrep -x sing-box >/dev/null 2>&1 || return 1
  command -v netstat >/dev/null 2>&1 || return 1
  netstat -ln 2>/dev/null | grep -Eq '[:.]12345[[:space:]]' || return 1
}

activate_traffic_path() {
  step "Проверка и включение прозрачного проксирования"
  # enable_services starts the API, whose startup reconciliation may already
  # have completed the same health-gated activation. Preserve that healthy
  # path instead of introducing a second stop/start protection gap.
  if [ -f /etc/space-link/tproxy.armed ] \
     && traffic_engine_ready \
     && nft list table inet space_link >/dev/null 2>&1; then
    ok "TPROXY уже активен и прошёл проверку"
    return 0
  fi

  rm -f /etc/space-link/tproxy.armed 2>/dev/null || true
  /etc/init.d/space-link-tproxy stop >/dev/null 2>&1 || true
  if [ ! -s /etc/space-link/active-server ]; then
    /etc/init.d/space-link-tproxy disable >/dev/null 2>&1 || true
    if [ -x /usr/bin/space-link-dns ]; then
      /usr/bin/space-link-dns disable >/dev/null 2>&1 || true
    fi
    ok "сервер не выбран — интернет оставлен напрямую"
    return 0
  fi

  retries="${TRAFFIC_READY_RETRIES:-5}"
  ready=0
  i=1
  while [ "$i" -le "$retries" ]; do
    if traffic_engine_ready; then
      ready=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done

  if [ "$ready" != "1" ]; then
    /etc/init.d/space-link-tproxy disable >/dev/null 2>&1 || true
    if [ -x /usr/bin/space-link-dns ]; then
      /usr/bin/space-link-dns disable >/dev/null 2>&1 || true
    fi
    warn "sing-box или :12345 не готовы — TPROXY выключен, интернет оставлен напрямую"
    return 0
  fi

  touch /etc/space-link/tproxy.armed
  /etc/init.d/space-link-tproxy enable >/dev/null 2>&1 || true
  if /etc/init.d/space-link-tproxy start >/dev/null 2>&1 \
     && nft list table inet space_link >/dev/null 2>&1; then
    ok "TPROXY активирован после проверки sing-box"
    return 0
  fi

  rm -f /etc/space-link/tproxy.armed 2>/dev/null || true
  /etc/init.d/space-link-tproxy stop >/dev/null 2>&1 || true
  /etc/init.d/space-link-tproxy disable >/dev/null 2>&1 || true
  if [ -x /usr/bin/space-link-dns ]; then
    /usr/bin/space-link-dns disable >/dev/null 2>&1 || true
  fi
  warn "TPROXY не применился — интернет оставлен напрямую"
}

# ---- enable services -------------------------------------------------------
enable_services() {
  step "Включение сервисов"

  # sing-box — ставим минимальный direct-конфиг с локальным DNS-inbound.
  # Благодаря этому dnsmasq может безопасно использовать 127.0.0.42 даже до
  # выбора сервера; после выбора Go API заменит стаб полным конфигом.
  if [ ! -s /etc/sing-box/config.json ]; then
    mkdir -p /etc/sing-box
    if [ -f "$SCRIPT_DIR/../templates/sing-box-stub.json" ]; then
      cp "$SCRIPT_DIR/../templates/sing-box-stub.json" /etc/sing-box/config.json
    else
      fetch "$RELEASE_BASE/sing-box-stub.json" /etc/sing-box/config.json 2>/dev/null || \
        printf '%s\n' '{"log":{"level":"warn"},"dns":{"servers":[{"tag":"direct-dns","address":"https://9.9.9.9/dns-query","detour":"direct"}],"final":"direct-dns"},"inbounds":[{"type":"direct","tag":"dns-in","listen":"127.0.0.42","listen_port":53,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"default_domain_resolver":"direct-dns","final":"direct","rules":[{"protocol":"dns","action":"hijack-dns"}]}}' > /etc/sing-box/config.json
    fi
  fi
  # ---- sing-box capabilities ----------------------------------------------
  # CAP_NET_ADMIN нужен для tproxy-инбаунда :12345 — без него init.d падает
  # с "listen tcp4 0.0.0.0:12345: operation not permitted". В v0.2.2 мы
  # делали setcap на бинарь, но procd при respawn ре-exec'ает через
  # posix_spawn() — file caps не наследуются → процесс падает каждые 2-5 сек
  # в цикле. Правильный путь — отдать caps через сам procd через
  # `procd_set_param capabilities /etc/capabilities/sing-box.json`. Тогда
  # ambient/inheritable caps сохраняются на respawn.
  mkdir -p /etc/capabilities
  cat > /etc/capabilities/sing-box.json <<'CAP'
{
  "ambient":     ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"],
  "bounding":    ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"],
  "effective":   ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"],
  "permitted":   ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"],
  "inheritable": ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"]
}
CAP
  ok "/etc/capabilities/sing-box.json"

  # Патчим /etc/init.d/sing-box: добавляем строку `procd_set_param capabilities ...`
  # перед `procd_close_instance`. Idempotent: если уже есть — пропускаем.
  if [ -f /etc/init.d/sing-box ] && ! grep -q "capabilities /etc/capabilities/sing-box.json" /etc/init.d/sing-box; then
    # backup перед патчем (только один раз)
    [ -f /etc/init.d/sing-box.orig ] || cp /etc/init.d/sing-box /etc/init.d/sing-box.orig
    awk '/procd_close_instance/ && !done { print "\tprocd_set_param capabilities /etc/capabilities/sing-box.json"; done=1 } { print }' \
      /etc/init.d/sing-box.orig > /etc/init.d/sing-box
    chmod 0755 /etc/init.d/sing-box
    ok "init.d/sing-box патчен на procd capabilities"
  fi

  # Fallback: всё-таки делаем setcap на бинарь — на случай если procd
  # capabilities у юзера какая-то странная версия.
  if ! command -v setcap >/dev/null 2>&1; then
    apk add libcap-bin >/dev/null 2>&1 || opkg install libcap-bin >/dev/null 2>&1 || true
  fi
  if command -v setcap >/dev/null 2>&1 && [ -x /usr/bin/sing-box ]; then
    setcap "cap_net_admin,cap_net_bind_service,cap_net_raw+ep" /usr/bin/sing-box >/dev/null 2>&1 || true
  fi

  # uci sing-box.main.enabled=1 — без этого init.d молча выходит из start_service.
  uci -q set sing-box.main.enabled='1'
  # conffile — КРИТИЧНО для кнопки «Перезапустить VPN» (RTR-5). Стоковый
  # /etc/init.d/sing-box читает путь к конфигу из uci sing-box.main.conffile.
  # Go API рендерит активный сервер в /etc/sing-box/config.json, поэтому init.d
  # должен указывать ровно на этот файл — иначе рестарт грузит стаб/чужой конфиг
  # и тоннель не поднимается. Должно совпадать с SINGBOX_CONFIG в api/config.go.
  uci -q set sing-box.main.conffile='/etc/sing-box/config.json'
  uci -q commit sing-box

  /etc/init.d/sing-box enable >/dev/null 2>&1 || true
  /etc/init.d/sing-box restart >/dev/null 2>&1 || /etc/init.d/sing-box start >/dev/null 2>&1 \
    || warn "sing-box не стартовал — посмотри logread -e sing-box"

  /etc/init.d/space-link enable >/dev/null 2>&1 || true
  /etc/init.d/space-link restart >/dev/null 2>&1 || /etc/init.d/space-link start >/dev/null 2>&1 \
    || warn "space-link не стартовал — посмотри logread -e space-link"

  # Ждём, пока Go API реально начнёт отвечать на 127.0.0.1:8080. lighttpd
  # проксирует /api/* туда — если стартовать lighttpd раньше, первые
  # запросы UI получат 502.
  step "Ждём space-link API"
  api_ok=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 2 http://127.0.0.1:8080/api/local/health >/dev/null 2>&1 && { api_ok=1; break; }
    else
      wget -q --timeout=2 -O- http://127.0.0.1:8080/api/local/health >/dev/null 2>&1 && { api_ok=1; break; }
    fi
    sleep 1
  done
  if [ "$api_ok" = "1" ]; then
    ok "space-link-api отвечает"
  else
    warn "space-link-api не ответил за 10 сек — UI может первое время отдавать 502"
  fi

  /etc/init.d/lighttpd enable >/dev/null 2>&1 || true
  /etc/init.d/lighttpd restart >/dev/null 2>&1 || /etc/init.d/lighttpd start >/dev/null 2>&1 \
    || warn "lighttpd не стартовал — посмотри logread -e lighttpd"

  # wait + retry: lighttpd иногда падает с EADDRINUSE если порт ещё не
  # освободился от предыдущей попытки. Даём 5 секунд + retry до 3 раз.
  for try in 1 2 3; do
    sleep 2
    if pgrep -x lighttpd >/dev/null 2>&1; then
      ok "lighttpd работает (try=$try)"
      break
    fi
    if [ "$try" = "3" ]; then
      warn "lighttpd не поднимается за 3 попытки — logread -e lighttpd; конфликт портов?"
      # Диагностический вывод: что слушает :80
      netstat -lnp 2>/dev/null | grep ":80\b" | sed 's/^/   /' | head -3
    else
      /etc/init.d/lighttpd restart >/dev/null 2>&1 || /etc/init.d/lighttpd start >/dev/null 2>&1
    fi
  done

  ok "сервисы"
}

# ---- save state ------------------------------------------------------------
save_state() {
  mkdir -p "$STATE_DIR"
  chmod 0755 "$STATE_DIR"
  if [ -n "$TOKEN" ]; then
    umask 077
    printf '%s\n' "$TOKEN" > "$STATE_DIR/token"
    chmod 0600 "$STATE_DIR/token"
    printf '%s\n' "token" > "$STATE_DIR/mode"
    chmod 0644 "$STATE_DIR/mode"
    umask 022

    # Best-effort: if the local API is already up, POST the token so it picks
    # it up without a restart. Failure is fine — the file on disk is the truth.
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        --data "{\"token\":\"$TOKEN\"}" \
        http://127.0.0.1:8080/api/local/token >/dev/null 2>&1 || true
    fi
  fi
  printf '%s\n' "$VERSION" > "$STATE_DIR/version"
  date '+%Y-%m-%dT%H:%M:%S' > "$STATE_DIR/installed_at"
}

# ---- dnsmasq alias ---------------------------------------------------------
# dnsmasq 2.86+ forwards non-A/AAAA queries (including HTTPS/SVCB) upstream
# when a domain has only address=/domain/IP. A public answer for my.space can
# therefore escape the router even while its A record is local. We install an
# empty address=/domain/ rule beside the IPv4 answer: the IP rule wins for A,
# while the empty rule makes every other RR type local and non-forwarded.
#
# Every write first removes all current and legacy Space Link values. This
# makes repair/update runs deterministic and prevents conflicting answers from
# surviving a dnsmasq restart or config reload.
configure_dns() {
  step "Регистрация my.space → $EFFECTIVE_BIND в dnsmasq"

  if ! command -v uci >/dev/null 2>&1; then
    if [ -f /etc/dnsmasq.conf ]; then
      _dns_file_normalize /etc/dnsmasq.conf
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
      ok "my.space → $EFFECTIVE_BIND (через dnsmasq.conf)"
    else
      warn "ни uci, ни dnsmasq.conf не доступны — открывай панель по IP: http://$EFFECTIVE_BIND"
    fi
    return 0
  fi

  _dns_sed_scrub
  _dns_uci_normalize
  uci -q commit dhcp >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 2

  if _dns_verify; then
    ok "my.space → $EFFECTIVE_BIND (dnsmasq жив, DNS отвечает)"
    return 0
  fi

  warn "dnsmasq не отвечает после правки — откатываю dhcp из снапшота"
  if rollback_uci dhcp; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
  fi

  if ! _dns_verify; then
    warn "снапшот не помог — восстанавливаю заводской /etc/config/dhcp из /rom/"
    if [ -r /rom/etc/config/dhcp ]; then
      cp /etc/config/dhcp "$BACKUP_DIR/dhcp.broken.$(date +%s 2>/dev/null || echo x)" 2>/dev/null || true
      cp /rom/etc/config/dhcp /etc/config/dhcp 2>/dev/null || true
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
      sleep 2
    fi
  fi

  if _dns_verify; then
    # Базу подняли. Нормализуем локальные зоны ещё раз.
    _dns_uci_normalize
    uci -q commit dhcp >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
    if _dns_verify; then
      ok "dnsmasq восстановлен, my.space → $EFFECTIVE_BIND"
    else
      # Снова легло именно от наших записей. Лучше потерять my.space
      # чем DHCP/DNS клиентам.
      warn "my.space ломает dnsmasq — оставляю без alias, открывай по IP: http://$EFFECTIVE_BIND"
      _dns_uci_purge_all
      uci -q commit dhcp >/dev/null 2>&1 || true
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
  else
    err "dnsmasq не стартует даже с заводского конфига. Проверь logread -e dnsmasq."
  fi
}

# Podkop-style DNS path: clients -> dnsmasq -> sing-box 127.0.0.42:53.
# The controller probes both layers and restores the previous resolver on any
# failure, so a sing-box/config error cannot take down all LAN name resolution.
configure_protected_dns() {
  step "DNS через защищённое соединение"
  if [ ! -x /usr/bin/space-link-dns ]; then
    warn "DNS controller отсутствует — оставляю текущий upstream dnsmasq"
    return 0
  fi
  if /usr/bin/space-link-dns enable >/dev/null 2>&1; then
    ok "dnsmasq → sing-box 127.0.0.42:53"
  else
    warn "sing-box DNS не ответил — сохранён прежний рабочий DNS"
  fi
}

# Remove every current or legacy rule owned by Space Link. Matching the values
# already present is what removes unknown stale IPs; the fixed candidate list
# alone cannot do that reliably.
_dns_uci_purge_all() {
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  [ -n "$addrs" ] || return 0
  for a in $addrs; do
    case "$a" in
      */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*)
        uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true
        ;;
    esac
  done
}

_dns_uci_normalize() {
  _dns_uci_purge_all
  uci -q add_list dhcp.@dnsmasq[0].address="/my.space/$EFFECTIVE_BIND" >/dev/null 2>&1 || return 1
  uci -q add_list dhcp.@dnsmasq[0].address="/my.space/" >/dev/null 2>&1 || return 1
  uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/$EFFECTIVE_BIND" >/dev/null 2>&1 || return 1
  uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/" >/dev/null 2>&1 || return 1
}

# Non-UCI variants still read /etc/dnsmasq.conf. Rewrite only Space Link's
# exact directives, preserving user DNS settings and unrelated local zones.
_dns_file_normalize() {
  conf="$1"
  tmp="${conf}.space-link.$$"
  if ! awk '
    /^[[:space:]]*(address|local)=\/(my\.space|my\.sapce|my\.spacelink|spacelink\.lan)\// { next }
    { print }
  ' "$conf" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf 'address=/my.space/%s\n' "$EFFECTIVE_BIND" >> "$tmp"
  printf 'local=/my.space/\n' >> "$tmp"
  printf 'address=/my.sapce/%s\n' "$EFFECTIVE_BIND" >> "$tmp"
  printf 'local=/my.sapce/\n' >> "$tmp"
  mv "$tmp" "$conf"
}

# Sed по сырому /etc/config/dhcp. Снимает строки, в которых list address
# содержит обратный слэш (типовой признак побитого экранирования) или
# подстроку любого из наших доменов (если uci по какой-то причине промахнулся):
# my.space (текущий), spacelink.lan и my.spacelink (legacy).
_dns_sed_scrub() {
  [ -f /etc/config/dhcp ] || return 0
  cp /etc/config/dhcp "$BACKUP_DIR/dhcp.preinstall.$(date +%s 2>/dev/null || echo x)" 2>/dev/null || true
  # BusyBox sed: \{1,\} не поддерживается, используем простые паттерны.
  sed -i '/list address.*\\/d' /etc/config/dhcp 2>/dev/null || true
  sed -i '/list address.*my\.space\//d' /etc/config/dhcp 2>/dev/null || true
  sed -i '/list address.*my\.sapce\//d' /etc/config/dhcp 2>/dev/null || true
  sed -i '/list address.*spacelink\.lan/d' /etc/config/dhcp 2>/dev/null || true
  sed -i '/list address.*my\.spacelink/d' /etc/config/dhcp 2>/dev/null || true
}

# Verify the process, exact authoritative UCI rules, and both IPv4 answers.
_dns_verify() {
  pgrep dnsmasq >/dev/null 2>&1 || return 1
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  for expected in "/my.space/$EFFECTIVE_BIND" "/my.space/" "/my.sapce/$EFFECTIVE_BIND" "/my.sapce/"; do
    found=0
    for a in $addrs; do
      [ "$a" = "$expected" ] && found=$((found + 1))
    done
    [ "$found" = "1" ] || return 1
  done
  if command -v nslookup >/dev/null 2>&1; then
    nslookup my.space 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND" || return 1
    nslookup my.sapce 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND" || return 1
  fi
  return 0
}

# ---- panel watchdog --------------------------------------------------------
install_panel_watchdog() {
  step "Установка watchdog панели"
  cat > /usr/bin/space-link-panel-watchdog <<'WATCHDOG'
#!/bin/sh

# procd runs this mode continuously. Each check is a separate process so a
# single stuck/failed command cannot permanently kill the recovery loop.
if [ "${1:-}" = "--loop" ]; then
  while :; do
    "$0" --once
    sleep 30
  done
fi
# Self-heal for the local router panel. VPN data-plane may be fine while the
# panel is down: API can die, or lighttpd can stop serving/proxying after boot.

log() {
  logger -t space-link-panel-watchdog "$*" 2>/dev/null || echo "space-link-panel-watchdog: $*"
}

http_ok() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 3 "$url" >/dev/null 2>&1
    return $?
  fi
  wget -q --timeout=3 -O- "$url" >/dev/null 2>&1
}

panel_ok() {
  url="$1"
  host="$2"
  http_ok "$url" && return 0
  http_ok "http://my.space/" && return 0
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 3 -H "Host: $host" "$url" >/dev/null 2>&1
    return $?
  fi
  return 1
}

restart_service() {
  svc="$1"
  reason="$2"
  log "$svc unhealthy: $reason; restarting"
  /etc/init.d/"$svc" enable >/dev/null 2>&1 || true
  /etc/init.d/"$svc" restart >/dev/null 2>&1 || /etc/init.d/"$svc" start >/dev/null 2>&1 || true
}

api_url="http://127.0.0.1:8080/api/local/health"
if ! http_ok "$api_url"; then
  restart_service space-link "api health failed"
  sleep 3
  http_ok "$api_url" || log "space-link-api still unhealthy after restart"
fi

conf="/etc/lighttpd/conf.d/space-link.conf"
bind="$(awk -F'"' '/server.bind/ { print $2; exit }' "$conf" 2>/dev/null)"
port="$(awk '/server.port/ { print $3; exit }' "$conf" 2>/dev/null)"
[ -n "$bind" ] || bind="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
[ -n "$port" ] || port="80"
panel_url="http://$bind:$port/"
[ "$port" = "80" ] && panel_url="http://$bind/"

# Secondary-IP self-heal: панель слушает на $bind (напр. 192.168.1.2). После
# ребута netifd иногда не поднимает второй адрес вовремя (или lighttpd стартует
# раньше него) → .1.2 недоступен и панель/домен мертвы, хотя VPN работает. Если
# $bind не на br-lan — поднимаем напрямую (не рвёт сеть) и рестартуем lighttpd.
case "$bind" in
  127.*|"") ;;
  *)
    if ! ip addr show br-lan 2>/dev/null | grep -q "inet $bind/"; then
      log "панельный IP $bind не поднят на br-lan — добавляю и перезапускаю lighttpd"
      ip addr add "$bind/24" dev br-lan 2>/dev/null || true
      restart_service lighttpd "panel IP $bind was missing after boot"
      sleep 2
    fi
    ;;
esac

if ! pgrep -x lighttpd >/dev/null 2>&1; then
  restart_service lighttpd "process not running"
  sleep 2
elif ! panel_ok "$panel_url" "my.space"; then
  restart_service lighttpd "panel http check failed ($panel_url)"
  sleep 2
fi

if ! pgrep -x lighttpd >/dev/null 2>&1; then
  log "lighttpd still not running after restart"
elif ! panel_ok "$panel_url" "my.space"; then
  log "panel still not reachable after lighttpd restart ($panel_url)"
fi

# Local panel aliases self-heal. my.space is canonical; my.sapce is retained
# as a typo-safe alias so it never escapes to the public parked domain. Check
# the persisted UCI values as well as A lookups: a lookup can contain the right
# IP while a conflicting stale address or a missing HTTPS/SVCB blocker remains.
if command -v uci >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
  aliases_ok=1
  canonical_ip=0
  canonical_local=0
  typo_ip=0
  typo_local=0
  addrs="$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)"
  for a in $addrs; do
    case "$a" in
      "/my.space/$bind") canonical_ip=$((canonical_ip + 1)) ;;
      "/my.space/") canonical_local=$((canonical_local + 1)) ;;
      "/my.sapce/$bind") typo_ip=$((typo_ip + 1)) ;;
      "/my.sapce/") typo_local=$((typo_local + 1)) ;;
      */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*) aliases_ok=0 ;;
    esac
  done
  [ "$canonical_ip" = "1" ] || aliases_ok=0
  [ "$canonical_local" = "1" ] || aliases_ok=0
  [ "$typo_ip" = "1" ] || aliases_ok=0
  [ "$typo_local" = "1" ] || aliases_ok=0
  for host in my.space my.sapce; do
    nslookup "$host" 127.0.0.1 2>/dev/null | grep -q "$bind" || aliases_ok=0
  done
  if [ "$aliases_ok" != "1" ]; then
    log "panel DNS aliases are stale or non-authoritative; normalizing to $bind"
    for a in $addrs; do
      case "$a" in
        */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*)
          uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true
          ;;
      esac
    done
    uci -q add_list dhcp.@dnsmasq[0].address="/my.space/$bind" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.space/" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/$bind" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/" >/dev/null 2>&1 || true
    uci -q commit dhcp >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  fi
fi

# Protected DNS self-heal/fail-open. A running process is not enough: verify
# that dnsmasq can resolve through 127.0.0.42. If repair fails, restore the
# pre-Space-Link resolver so clients keep internet instead of losing all DNS.
if [ -x /usr/bin/space-link-dns ] \
   && ! grep -q '"active":[[:space:]]*true' /etc/space-link/watchdog.json 2>/dev/null; then
  if ! /usr/bin/space-link-dns status >/dev/null 2>&1; then
    log "защищённый DNS не отвечает — пробую переподключить"
    if ! /usr/bin/space-link-dns enable >/dev/null 2>&1; then
      /usr/bin/space-link-dns disable >/dev/null 2>&1 || true
      log "защищённый DNS не восстановлен — включён прежний DNS (fail-open)"
    fi
  fi
fi

# TPROXY self-heal: сервер выбран, трафикация не выключена и sing-box жив, но
# nft-таблица заворота пропала (например не переподнялась после ребута) → трафик
# уходит НАПРЯМУЮ мимо VPN. Переподнимаем заворот — «включено, а идёт напрямую»
# чинится само (крон гоняет скрипт раз в минуту).
if [ -s /etc/space-link/active-server ] && pgrep sing-box >/dev/null 2>&1 \
   && ! grep -q '"active":[[:space:]]*true' /etc/space-link/watchdog.json 2>/dev/null; then
  if command -v nft >/dev/null 2>&1 && ! nft list table inet space_link >/dev/null 2>&1; then
    log "TPROXY-таблица пропала при активном сервере — переподнимаю заворот трафика"
    /etc/init.d/space-link-tproxy start >/dev/null 2>&1 || /etc/init.d/space-link-tproxy reload >/dev/null 2>&1 || true
  fi
fi
WATCHDOG
  chmod 0755 /usr/bin/space-link-panel-watchdog
  ok "panel watchdog"
}

# ---- heartbeat cron --------------------------------------------------------
install_cron() {
  step "Установка cron для heartbeat/watchdog"
  heartbeat_line="*/5 * * * * /usr/bin/wget -q -O- http://127.0.0.1:8080/api/local/status >/dev/null 2>&1 # space-link-heartbeat"
  watchdog_line="* * * * * /usr/bin/space-link-panel-watchdog >/dev/null 2>&1 # space-link-panel-watchdog"
  cron_file="${CRONTAB_FILE:-/etc/crontabs/root}"
  cron_init="${CRON_INIT:-/etc/init.d/cron}"
  cron_tmp="/tmp/space-link-cron.$$"

  mkdir -p "$(dirname "$cron_file")"
  {
    if command -v crontab >/dev/null 2>&1; then
      crontab -l 2>/dev/null || true
    elif [ -r "$cron_file" ]; then
      cat "$cron_file"
    fi
  } | grep -v '# space-link-heartbeat$' \
    | grep -v '# space-link-panel-watchdog$' > "$cron_tmp" || true
  printf '%s\n%s\n' "$heartbeat_line" "$watchdog_line" >> "$cron_tmp"

  # Prefer the platform frontend, but never trust only its exit code. The
  # production failure that motivated this check returned success while the
  # root crontab remained empty.
  if command -v crontab >/dev/null 2>&1; then
    crontab "$cron_tmp" >/dev/null 2>&1 || true
  fi
  cron_snapshot="$(crontab -l 2>/dev/null || cat "$cron_file" 2>/dev/null || true)"
  if [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$heartbeat_line" || true)" != "1" ] \
     || [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$watchdog_line" || true)" != "1" ]; then
    cp "$cron_tmp" "$cron_file"
    chmod 0600 "$cron_file" 2>/dev/null || true
    cron_snapshot="$(cat "$cron_file" 2>/dev/null || true)"
  fi
  rm -f "$cron_tmp"

  "$cron_init" enable >/dev/null 2>&1 || true
  "$cron_init" restart >/dev/null 2>&1 || true

  if [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$heartbeat_line" || true)" = "1" ] \
     && [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$watchdog_line" || true)" = "1" ]; then
    ok "cron: heartbeat + panel watchdog"
  else
    warn "cron не сохранил watchdog; procd-supervisor остаётся активным"
  fi
}

# ---- final summary ---------------------------------------------------------
final_summary() {
  router_ip="${ROUTER_IP:-$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")}"
  wifi=$(uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null || echo "—")
  port_suffix=""
  [ "$EFFECTIVE_PORT" = "80" ] || port_suffix=":$EFFECTIVE_PORT"
  panel_url="http://$EFFECTIVE_BIND$port_suffix"
  printf '\n'
  printf '%s\n' "================================================"
  printf '   Space Link Router установлен (%s)\n' "$VERSION"
  printf '%s\n' "================================================"
  printf '   WiFi:       %s\n' "$wifi"
  printf '   Панель:     http://my.space%s   (или %s)\n' "$port_suffix" "$panel_url"
  if [ "$EFFECTIVE_BIND" = "$router_ip" ]; then
    printf '   LuCI:       выключена (мы заняли :80 на основном IP)\n'
  else
    printf '   LuCI:       http://%s   (стандартный веб-интерфейс OpenWrt)\n' "$router_ip"
  fi
  if [ -z "$TOKEN" ]; then
    printf '   Токен:      не задан — введи в панели управления\n'
  else
    printf '   Токен:      сохранён\n'
  fi
  printf '%s\n' "================================================"

  # ---- диагностика ----------------------------------------------------------
  printf '\n--- Диагностика ---\n'

  dns_ok=0
  if pgrep dnsmasq >/dev/null 2>&1; then
    leases=0
    [ -r /tmp/dhcp.leases ] && leases=$(wc -l < /tmp/dhcp.leases 2>/dev/null || echo 0)
    printf '   DHCP/DNS:        OK  работает (%s аренд)\n' "$leases"
    dns_ok=1
  else
    printf '   DHCP/DNS:        ERR dnsmasq не запущен — клиенты не получат IP!\n'
  fi

  api_ok=0
  if command -v curl >/dev/null 2>&1 && \
     curl -fsS -m 2 http://127.0.0.1:8080/api/local/health 2>/dev/null | grep -q '"ok":true'; then
    printf '   space-link-api:  OK  отвечает\n'
    api_ok=1
  else
    printf '   space-link-api:  ERR не отвечает на 127.0.0.1:8080\n'
  fi

  http_ok=0
  if pgrep lighttpd >/dev/null 2>&1; then
    printf '   lighttpd:        OK  работает\n'
    http_ok=1
  else
    printf '   lighttpd:        ERR не запущен — панель недоступна\n'
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    printf '   sing-box:        OK  работает\n'
  else
    printf '   sing-box:        --  не запущен (норма пока не выбран сервер)\n'
  fi

  if [ "$EFFECTIVE_BIND" = "$router_ip" ]; then
    printf '   LuCI:            --  выключена (мы заняли :80 на %s)\n' "$router_ip"
  elif pgrep uhttpd >/dev/null 2>&1; then
    printf '   LuCI:            OK  работает на http://%s/\n' "$router_ip"
  else
    printf '   LuCI:            ERR uhttpd не запущен (вручную: service uhttpd start)\n'
  fi

  if command -v nslookup >/dev/null 2>&1 && \
     nslookup my.space 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND"; then
    printf '   my.space:        OK  резолвит в %s\n' "$EFFECTIVE_BIND"
  else
    printf '   my.space:        --  не резолвит — открывай по %s\n' "$panel_url"
  fi

  # Deliberately no TLS listener: without a locally trusted certificate an
  # HTTPS redirect is impossible because the TLS handshake happens first.
  # A refused :443 connection lets HTTPS-first browsers offer/fall back to the
  # canonical HTTP URL; a stray TLS listener is surfaced explicitly.
  if command -v curl >/dev/null 2>&1 && \
     curl -ksS -m 2 -o /dev/null "https://$EFFECTIVE_BIND/" >/dev/null 2>&1; then
    printf '   HTTPS:           WRN unexpected TLS listener; use http://my.space/ explicitly\n'
  else
    printf '   HTTPS:           --  not configured; HTTPS cannot redirect before a TLS handshake, use http://my.space/\n'
  fi

  if command -v nft >/dev/null 2>&1 && nft list table inet space_link >/dev/null 2>&1; then
    dnst=$(uci -q get space-link.tproxy.dns_tunnel 2>/dev/null || echo 0)
    quic=$(uci -q get space-link.tproxy.block_quic 2>/dev/null || echo 0)
    dns_lbl="выкл"; [ "$dnst" = "1" ] && dns_lbl="вкл"
    quic_lbl="выкл"; [ "$quic" = "1" ] && quic_lbl="вкл"
    printf '   TPROXY:          OK  nft table space_link (v4+v6, DNS-tunnel:%s, QUIC-block:%s)\n' "$dns_lbl" "$quic_lbl"
  else
    printf '   TPROXY:          ERR таблица не загружена — посмотри: logread -t space-link-tproxy\n'
  fi

  # conffile-проверка (RTR-5): кнопка «Перезапустить VPN» из панели грузит
  # config.json только если стоковый init.d указывает на него через uci.
  cf=$(uci -q get sing-box.main.conffile 2>/dev/null || echo "")
  if [ "$cf" = "/etc/sing-box/config.json" ]; then
    printf '   sing-box conffile: OK  %s (рестарт из панели грузит активный конфиг)\n' "$cf"
  else
    printf '   sing-box conffile: ERR %s — кнопка рестарта может грузить не тот конфиг\n' "${cf:-не задан}"
  fi

  printf '\n'
  if [ "$dns_ok" = "1" ] && [ "$api_ok" = "1" ] && [ "$http_ok" = "1" ]; then
    printf '   Установка успешна. Открывай: http://my.space%s\n' "$port_suffix"
  else
    printf '   Установка завершена с предупреждениями. Запусти %s ещё раз — установщик попробует починить.\n' "$0"
  fi
  printf '\n'
}

# ---- main ------------------------------------------------------------------
banner
printf '   Версия: %s   Режим: %s\n\n' "$VERSION" "$mode"

preflight
# Снапшот рабочих конфигов ДО любых правок — для отката если что-то пойдёт не так.
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
backup_uci_state
# Package upgrades may restart sing-box. Remove interception before touching
# packages so LAN remains on direct WAN throughout the entire update window.
disarm_traffic_path
# Если dnsmasq уже лежит от прошлой кривой установки или ручных правок — чиним.
ensure_dnsmasq_alive
prompt_token
install_packages
migrate_from_xray
install_binary
install_ui
install_rules
configure_panel_ip
install_templates
save_state
configure_tproxy
install_panel_watchdog
enable_services
configure_dns
configure_protected_dns
activate_traffic_path
install_cron
final_summary
