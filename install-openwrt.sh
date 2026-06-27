#!/bin/sh
# Space Link Router installer. POSIX sh, runs in BusyBox.
# Usage: wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install.sh | sh
set -eu

VERSION="0.1.16"
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

# Packages we hard-require: install must abort if any is missing.
REQUIRED_PKGS="ca-certificates curl xray-core lighttpd lighttpd-mod-proxy lighttpd-mod-rewrite lighttpd-mod-redirect"
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
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 10 -H "Authorization: Bearer $1" "$CLOUD_API/router/validate" >/dev/null 2>&1
    else
      wget -q --timeout=10 --header="Authorization: Bearer $1" -O- "$CLOUD_API/router/validate" >/dev/null 2>&1
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
    if nslookup gitlab.com 127.0.0.1 >/dev/null 2>&1; then
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
    printf 'Токен пропущен (--skip-token). Настройте позже: http://my.spacelink/\n'
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
    printf '\nНет терминала для ввода токена. Открой http://my.spacelink/ и введи токен или ссылку подписки в разделе Setup.\n'
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
    printf 'Пропущено. Открой http://my.spacelink/ и введи токен или ссылку подписки в Setup.\n'
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
    for preset in ru cis; do
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

  if [ "$main_present" = "1" ] && [ "$alias_present" = "1" ]; then
    EFFECTIVE_BIND="$PANEL_IP"
    EFFECTIVE_PORT="$PANEL_PORT"
    ok "доп. IP $PANEL_IP/24 на br-lan, основной $ROUTER_IP жив — LuCI и панель параллельно"
    # Прошлые версии (v0.1.7 fallback) могли disable+stop uhttpd. Сейчас :80
    # на основном IP свободен — поднимаем LuCI обратно.
    /etc/init.d/uhttpd enable >/dev/null 2>&1 || true
    /etc/init.d/uhttpd start  >/dev/null 2>&1 || true
    sleep 1
    if pgrep uhttpd >/dev/null 2>&1; then
      ok "uhttpd (LuCI) запущен на http://$ROUTER_IP/"
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

# ---- transparent proxy -----------------------------------------------------
# Поднимаем TPROXY: маркируем LAN-трафик через nftables, заворачиваем по
# fwmark в отдельную routing-таблицу с local-route на lo, где xray ловит его
# на dokodemo-door :12345. Без этого xray на роутере — просто SOCKS-прокси
# на localhost, и клиенты в WiFi его не видят.
#
# Параметры можно переопределить из окружения (TPROXY_PORT/TPROXY_MARK/TPROXY_TABLE),
# но дефолты прибиты к xray-config.json — менять синхронно с api/internal/xray/xray.go.
#
# На OpenWrt 25.x все файлы в /etc/nftables.d/ инклюдятся ВНУТРЬ fw4-сгенерированной
# таблицы — там нельзя писать `table inet space_link { ... }` (таблица в таблице,
# парсер падает). Поэтому держим nft-конфиг отдельно: свой каталог
# /etc/space-link/, свой init.d-скрипт, и hotplug firewall — поднимает табличку
# обратно после каждого fw4 reload, который мог снести её.
configure_tproxy() {
  step "Настройка прозрачного проксирования (TPROXY)"
  TPROXY_PORT="${TPROXY_PORT:-12345}"
  TPROXY_MARK="${TPROXY_MARK:-255}"
  TPROXY_TABLE="${TPROXY_TABLE:-100}"

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
  cat > /etc/space-link/tproxy.nft <<NFT
table inet space_link
delete table inet space_link

table inet space_link {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        ip daddr 0.0.0.0/8        return
        ip daddr 10.0.0.0/8       return
        ip daddr 127.0.0.0/8      return
        ip daddr 169.254.0.0/16   return
        ip daddr 172.16.0.0/12    return
        ip daddr 192.168.0.0/16   return
        ip daddr 224.0.0.0/4      return
        ip daddr 240.0.0.0/4      return
        ip daddr 255.255.255.255  return
        fib daddr type local      return

        iifname "br-lan" meta l4proto { tcp, udp } tproxy ip to :__TPROXY_PORT__ meta mark set __TPROXY_MARK__ accept
    }

    chain output {
        type route hook output priority mangle; policy accept;

        meta mark __TPROXY_MARK__ return
        ip daddr 0.0.0.0/8        return
        ip daddr 10.0.0.0/8       return
        ip daddr 127.0.0.0/8      return
        ip daddr 169.254.0.0/16   return
        ip daddr 172.16.0.0/12    return
        ip daddr 192.168.0.0/16   return
        ip daddr 224.0.0.0/4      return
        ip daddr 240.0.0.0/4      return
        fib daddr type local      return
    }
}
NFT
  sed -i "s/__TPROXY_PORT__/$TPROXY_PORT/g; s/__TPROXY_MARK__/$TPROXY_MARK/g" /etc/space-link/tproxy.nft

  # 5) init.d-скрипт. apply: грузит nft + ставит fwmark rule + local-route.
  #    stop: сносит таблицу и rule. reload == apply.
  cat > /etc/init.d/space-link-tproxy <<'INITD'
#!/bin/sh /etc/rc.common
START=99
STOP=10

apply() {
  nft -f /etc/space-link/tproxy.nft 2>&1 | logger -t space-link-tproxy
  ip rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip rule add fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip route flush table __TABLE__ 2>/dev/null
  ip route add local 0.0.0.0/0 dev lo table __TABLE__ 2>/dev/null
}

start() { apply; }
stop() {
  nft delete table inet space_link 2>/dev/null
  ip rule del fwmark __MARK__ table __TABLE__ 2>/dev/null
  ip route flush table __TABLE__ 2>/dev/null
}
reload() { apply; }
INITD
  sed -i "s/__MARK__/$TPROXY_MARK/g; s/__TABLE__/$TPROXY_TABLE/g" /etc/init.d/space-link-tproxy
  chmod 0755 /etc/init.d/space-link-tproxy

  # 6) Firewall hotplug: после fw4 reload (например при network restart) наша
  #    table inet space_link может слететь — переподнимаем.
  mkdir -p /etc/hotplug.d/firewall 2>/dev/null || true
  cat > /etc/hotplug.d/firewall/99-space-link-tproxy <<'HOOK'
#!/bin/sh
# fw4 reload может снести нашу table inet space_link — переподнимаем.
/etc/init.d/space-link-tproxy reload 2>/dev/null
HOOK
  chmod 0755 /etc/hotplug.d/firewall/99-space-link-tproxy

  # 7) Снять старый iface-hotplug от v0.1.13, если остался.
  rm -f /etc/hotplug.d/iface/99-space-link-tproxy 2>/dev/null || true

  # 8) Enable + start.
  /etc/init.d/space-link-tproxy enable 2>/dev/null || true
  /etc/init.d/space-link-tproxy start 2>/dev/null || true

  # 9) Verify.
  sleep 1
  if nft list table inet space_link >/dev/null 2>&1; then
    ok "TPROXY активен (table inet space_link загружена, port=$TPROXY_PORT, mark=$TPROXY_MARK, table=$TPROXY_TABLE)"
  else
    warn "TPROXY не применился — посмотри: logread -t space-link-tproxy"
  fi
}

# ---- enable services -------------------------------------------------------
enable_services() {
  step "Включение сервисов"

  # xray — ставим минимальный заглушечный конфиг, чтобы init.d не падал
  # до того, как Go API отрендерит реальный config.json с активным сервером.
  if [ ! -s /etc/xray/config.json ]; then
    mkdir -p /etc/xray
    printf '%s\n' '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}' > /etc/xray/config.json
  fi
  /etc/init.d/xray enable >/dev/null 2>&1 || true
  /etc/init.d/xray restart >/dev/null 2>&1 || /etc/init.d/xray start >/dev/null 2>&1 \
    || warn "xray не стартовал — посмотри logread -e xray"

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
# Защищённая версия. Шаги:
#   1) выгребаем все my.spacelink-записи (uci del_list) и битые address'ы
#      (sed по сырому /etc/config/dhcp — кавычки, лишние слэши).
#   2) добавляем /my.spacelink/$EFFECTIVE_BIND.
#   3) commit + restart + sleep 2 + verify (pgrep dnsmasq && nslookup gitlab.com).
#   4) если verify провалился — откат через rollback_uci (наш свежий снапшот),
#      затем /rom/etc/config/dhcp как последний резерв. После каждого отката
#      делаем ещё одну попытку добавить my.spacelink.
configure_dns() {
  step "Регистрация my.spacelink → $EFFECTIVE_BIND в dnsmasq"

  if ! command -v uci >/dev/null 2>&1; then
    if [ -f /etc/dnsmasq.conf ]; then
      sed -i "/my\\.spacelink/d" /etc/dnsmasq.conf 2>/dev/null || true
      printf 'address=/my.spacelink/%s\n' "$EFFECTIVE_BIND" >> /etc/dnsmasq.conf
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
      ok "my.spacelink → $EFFECTIVE_BIND (через dnsmasq.conf)"
    else
      warn "ни uci, ни dnsmasq.conf не доступны — открывай панель по IP: http://$EFFECTIVE_BIND"
    fi
    return 0
  fi

  _dns_uci_purge_all
  _dns_sed_scrub
  uci -q add_list dhcp.@dnsmasq[0].address="/my.spacelink/$EFFECTIVE_BIND" >/dev/null 2>&1 || true
  uci -q commit dhcp >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 2

  if _dns_verify; then
    ok "my.spacelink → $EFFECTIVE_BIND (dnsmasq жив, DNS отвечает)"
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
    # Базу подняли. Аккуратно докинем my.spacelink ещё раз.
    uci -q add_list dhcp.@dnsmasq[0].address="/my.spacelink/$EFFECTIVE_BIND" >/dev/null 2>&1 || true
    uci -q commit dhcp >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
    if _dns_verify; then
      ok "dnsmasq восстановлен, my.spacelink → $EFFECTIVE_BIND"
    else
      # Снова легло именно от нашей записи. Лучше потерять my.spacelink
      # чем DHCP/DNS клиентам.
      warn "my.spacelink ломает dnsmasq — оставляю без alias, открывай по IP: http://$EFFECTIVE_BIND"
      uci -q del_list dhcp.@dnsmasq[0].address="/my.spacelink/$EFFECTIVE_BIND" >/dev/null 2>&1 || true
      uci -q commit dhcp >/dev/null 2>&1 || true
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
  else
    err "dnsmasq не стартует даже с заводского конфига. Проверь logread -e dnsmasq."
  fi
}

# Vsё, что когда-либо могло быть нашим address-ом — удаляем. Перебираем известные
# IP-кандидаты + текущие значения; del_list по несуществующему — безопасно.
_dns_uci_purge_all() {
  for ip in 192.168.1.1 192.168.1.2 192.168.1.3 192.168.1.100 192.168.1.101 192.168.0.1 "$ROUTER_IP" "$EFFECTIVE_BIND"; do
    [ -n "$ip" ] || continue
    uci -q del_list dhcp.@dnsmasq[0].address="/my.spacelink/$ip" >/dev/null 2>&1 || true
  done
  # Дополнительно — выгрести любое значение списка, где есть подстрока my.spacelink.
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  if [ -n "$addrs" ]; then
    for a in $addrs; do
      case "$a" in
        */my.spacelink/*) uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true ;;
      esac
    done
  fi
}

# Sed по сырому /etc/config/dhcp. Снимает строки, в которых list address
# содержит обратный слэш (типовой признак побитого экранирования) или
# подстроку my.spacelink (если uci по какой-то причине промахнулся).
_dns_sed_scrub() {
  [ -f /etc/config/dhcp ] || return 0
  cp /etc/config/dhcp "$BACKUP_DIR/dhcp.preinstall.$(date +%s 2>/dev/null || echo x)" 2>/dev/null || true
  # BusyBox sed: \{1,\} не поддерживается, используем простые паттерны.
  sed -i '/list address.*\\/d' /etc/config/dhcp 2>/dev/null || true
  sed -i '/list address.*my\.spacelink/d' /etc/config/dhcp 2>/dev/null || true
}

# Проверка: процесс жив И DNS реально отвечает.
_dns_verify() {
  pgrep dnsmasq >/dev/null 2>&1 || return 1
  if command -v nslookup >/dev/null 2>&1; then
    nslookup gitlab.com 127.0.0.1 >/dev/null 2>&1 && return 0
    # Бывает что gitlab.com не резолвится по причине внешнего блока — тогда
    # запасной таргет, который точно резолвится через root-серверы.
    nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 && return 0
  fi
  # Без nslookup доверяем pgrep — это всё ещё лучше, чем ничего.
  return 0
}

# ---- heartbeat cron --------------------------------------------------------
install_cron() {
  step "Установка cron для heartbeat"
  cron_line="*/5 * * * * /usr/bin/wget -q -O- http://127.0.0.1:8080/api/local/status >/dev/null 2>&1"
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v 'space-link' ; printf '%s # space-link\n' "$cron_line") | crontab -
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    ok "cron"
  else
    warn "crontab не найден — пропускаю"
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
  printf '   Панель:     http://my.spacelink%s   (или %s)\n' "$port_suffix" "$panel_url"
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

  if pgrep -x xray >/dev/null 2>&1; then
    printf '   xray:            OK  работает\n'
  else
    printf '   xray:            --  не запущен (норма пока не выбран сервер)\n'
  fi

  if [ "$EFFECTIVE_BIND" = "$router_ip" ]; then
    printf '   LuCI:            --  выключена (мы заняли :80 на %s)\n' "$router_ip"
  elif pgrep uhttpd >/dev/null 2>&1; then
    printf '   LuCI:            OK  работает на http://%s/\n' "$router_ip"
  else
    printf '   LuCI:            ERR uhttpd не запущен (вручную: service uhttpd start)\n'
  fi

  if command -v nslookup >/dev/null 2>&1 && \
     nslookup my.spacelink 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND"; then
    printf '   my.spacelink:    OK  резолвит в %s\n' "$EFFECTIVE_BIND"
  else
    printf '   my.spacelink:    --  не резолвит — открывай по %s\n' "$panel_url"
  fi

  if command -v nft >/dev/null 2>&1 && nft list table inet space_link >/dev/null 2>&1; then
    printf '   TPROXY:          OK  nft table space_link загружена\n'
  else
    printf '   TPROXY:          ERR таблица не загружена — посмотри: logread -t space-link-tproxy\n'
  fi

  printf '\n'
  if [ "$dns_ok" = "1" ] && [ "$api_ok" = "1" ] && [ "$http_ok" = "1" ]; then
    printf '   Установка успешна. Открывай: http://my.spacelink%s\n' "$port_suffix"
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
# Если dnsmasq уже лежит от прошлой кривой установки или ручных правок — чиним.
ensure_dnsmasq_alive
prompt_token
install_packages
install_binary
install_ui
install_rules
configure_panel_ip
install_templates
save_state
configure_dns
configure_tproxy
enable_services
install_cron
final_summary
