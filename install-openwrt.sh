#!/bin/sh
# Space Link Router installer. POSIX sh, runs in BusyBox.
# Usage: wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install.sh | sh
set -eu

VERSION="0.1.5"
# GitLab "permalink/latest" resolves to the most recent release of the public
# project and exposes each release asset at /downloads/<asset-name>.
RELEASE_BASE="${RELEASE_BASE:-https://gitlab.com/space-link-vpn/router/-/releases/permalink/latest/downloads}"
CLOUD_API="${CLOUD_API:-https://api.space-link.app/api/v1}"
STATE_DIR="/etc/space-link"
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
  # Подставляем реальный bind/port (после configure_panel_ip).
  sed -i "s/__PANEL_IP__/$EFFECTIVE_BIND/g; s/__PANEL_PORT__/$EFFECTIVE_PORT/g" \
    /etc/lighttpd/conf.d/space-link.conf
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
  ROUTER_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")

  step "Alias-IP для панели: $PANEL_IP"
  if ! command -v uci >/dev/null 2>&1; then
    warn "uci недоступен — переключаюсь на основной IP роутера ($ROUTER_IP)"
    fallback_to_router_ip
    return 0
  fi

  # Создаём (или обновляем) секцию network.lan_panel
  if ! uci -q get network.lan_panel >/dev/null 2>&1; then
    uci set network.lan_panel='interface'
  fi
  uci set network.lan_panel.proto='static'
  uci set network.lan_panel.device='br-lan'
  uci set network.lan_panel.ipaddr="$PANEL_IP"
  uci set network.lan_panel.netmask='255.255.255.0'
  uci commit network

  # Перечитываем сеть. На некоторых сборках reload может на пару секунд
  # обронить SSH — это нормально, всё восстановится.
  service network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true

  # Проверка: реально ли поднялся alias на br-lan.
  sleep 2
  if ip addr show br-lan 2>/dev/null | grep -q "inet $PANEL_IP/"; then
    EFFECTIVE_BIND="$PANEL_IP"
    EFFECTIVE_PORT="$PANEL_PORT"
    ok "alias $PANEL_IP/24 поднят на br-lan"
  else
    warn "alias $PANEL_IP не поднялся — fallback на основной IP роутера ($ROUTER_IP)"
    fallback_to_router_ip
  fi
}

# Вариант A: гасим uhttpd (LuCI), слушаем на основном IP роутера :80.
fallback_to_router_ip() {
  EFFECTIVE_BIND="$ROUTER_IP"
  EFFECTIVE_PORT="80"
  warn "выключаю uhttpd (LuCI будет недоступна до удаления нашего конфига)"
  /etc/init.d/uhttpd stop  >/dev/null 2>&1 || true
  /etc/init.d/uhttpd disable >/dev/null 2>&1 || true
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
# Идемпотентно: удаляем точечно все возможные старые address-записи my.spacelink
# (на возможных IP-адресах), добавляем одну на EFFECTIVE_BIND. После рестарта
# проверяем что dnsmasq поднялся — если нет, чистим address целиком и пробуем
# снова без нашей записи (панель тогда открывается по IP, не по имени).
configure_dns() {
  step "Регистрация my.spacelink → $EFFECTIVE_BIND в dnsmasq"

  if command -v uci >/dev/null 2>&1; then
    _dns_uci_apply
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    if wait_service_up dnsmasq; then
      ok "my.spacelink → $EFFECTIVE_BIND (через uci)"
      return 0
    fi
    warn "dnsmasq не поднялся — чищу address-list и пробую заново"
    _dns_uci_purge
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    if wait_service_up dnsmasq; then
      warn "dnsmasq жив, но my.spacelink не зарегистрирован — открывай по IP: http://$EFFECTIVE_BIND"
    else
      warn "dnsmasq всё ещё не поднялся — проверь logread -e dnsmasq и uci show dhcp"
    fi
  elif [ -f /etc/dnsmasq.conf ]; then
    sed -i "/my\\.spacelink/d" /etc/dnsmasq.conf
    printf 'address=/my.spacelink/%s\n' "$EFFECTIVE_BIND" >> /etc/dnsmasq.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    ok "my.spacelink → $EFFECTIVE_BIND (через dnsmasq.conf)"
  else
    warn "ни uci, ни dnsmasq.conf не доступны — открывай панель по IP: http://$EFFECTIVE_BIND"
  fi
}

# Удаляет точечно записи /my.spacelink/<ip> для известных кандидатов, добавляет
# одну на EFFECTIVE_BIND. del_list с несуществующим значением безопасно
# игнорируется — никаких циклов по индексам и shell-escaping не требуется.
_dns_uci_apply() {
  for ip in 192.168.1.1 192.168.1.2 192.168.1.3 192.168.1.100 192.168.1.101 192.168.0.1 "$ROUTER_IP" "$EFFECTIVE_BIND"; do
    [ -n "$ip" ] || continue
    uci -q del_list dhcp.@dnsmasq[0].address="/my.spacelink/$ip" 2>/dev/null || true
  done
  uci add_list dhcp.@dnsmasq[0].address="/my.spacelink/$EFFECTIVE_BIND" >/dev/null 2>&1
  uci commit dhcp >/dev/null 2>&1 || true
}

# На случай если address-list где-то побился — выгребаем целиком все
# my.spacelink-записи, обычные оставляем.
_dns_uci_purge() {
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  [ -n "$addrs" ] || return 0
  uci -q delete dhcp.@dnsmasq[0].address >/dev/null 2>&1 || true
  for a in $addrs; do
    case "$a" in
      */my.spacelink/*) ;;
      *) uci add_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 ;;
    esac
  done
  uci commit dhcp >/dev/null 2>&1 || true
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
}

# ---- main ------------------------------------------------------------------
banner
printf '   Версия: %s   Режим: %s\n\n' "$VERSION" "$mode"

preflight
prompt_token
install_packages
install_binary
install_ui
install_rules
configure_panel_ip
install_templates
save_state
configure_dns
enable_services
install_cron
final_summary
