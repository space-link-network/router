#!/bin/sh
# Space Link Router installer. POSIX sh, runs in BusyBox.
# Usage: wget -qO- https://get.space-link.app/install.sh | sh
set -eu

VERSION="0.1.0"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/space-link/space-link-router/releases/latest/download}"
CLOUD_API="${CLOUD_API:-https://api.space-link.app/api/v1}"
STATE_DIR="/etc/space-link"
INSTALL_DIR="/opt/space-link"
WWW_DIR="$INSTALL_DIR/www"
BIN_PATH="$INSTALL_DIR/space-link-api"

# Resolve script dir so the bundled installer (run from a worktree or
# /tmp extraction) can find ./lib and ./templates. When piped via wget,
# we fall back to downloading them.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0" 2>/dev/null || echo .)" && pwd 2>/dev/null || echo /tmp)

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

  ARCH=$(detect_arch)
  if [ "$ARCH" = "unknown" ]; then
    die "Неизвестная архитектура: $(uname -m)"
  fi
  ok "Архитектура: $ARCH"
}

# ---- token prompt ----------------------------------------------------------
TOKEN=""
prompt_token() {
  [ "$mode" = "first_install" ] || return 0
  printf '\n'
  printf 'Введи токен Space Link (или нажми Enter, чтобы настроить позже): '
  # `read` is POSIX
  read TOKEN || TOKEN=""
  if [ -n "$TOKEN" ]; then
    step "Проверка токена..."
    if validate_token "$TOKEN"; then
      ok "Токен принят"
    else
      warn "Токен не прошёл проверку. Сохраняю как есть — можно заменить позже в UI."
    fi
  else
    printf 'Пропущено. Настроишь позже в http://my.spacelink/setup\n'
  fi
}

# ---- package install -------------------------------------------------------
install_packages() {
  step "Установка системных пакетов"
  if ! command -v opkg >/dev/null 2>&1; then
    warn "opkg не найден — пропускаю установку пакетов. Убедитесь, что xray-core и lighttpd установлены вручную."
    return 0
  fi
  opkg update >/dev/null 2>&1 || warn "opkg update завершился с ошибкой"
  for pkg in xray-core lighttpd lighttpd-mod-redirect lighttpd-mod-proxy; do
    if opkg list-installed | grep -q "^$pkg "; then
      ok "$pkg уже установлен"
    else
      opkg install "$pkg" >/dev/null 2>&1 && ok "$pkg" || warn "не удалось установить $pkg"
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

# ---- templates -------------------------------------------------------------
install_templates() {
  step "Установка конфигов"

  # lighttpd
  if [ -f "$SCRIPT_DIR/../templates/lighttpd.conf" ]; then
    cp "$SCRIPT_DIR/../templates/lighttpd.conf" /etc/lighttpd/conf.d/space-link.conf
  else
    fetch "$RELEASE_BASE/lighttpd.conf" /etc/lighttpd/conf.d/space-link.conf || warn "lighttpd.conf пропущен"
  fi
  ok "lighttpd"

  # init.d
  if [ -f "$SCRIPT_DIR/../templates/space-link.init" ]; then
    cp "$SCRIPT_DIR/../templates/space-link.init" /etc/init.d/space-link
  else
    fetch "$RELEASE_BASE/space-link.init" /etc/init.d/space-link || warn "init script пропущен"
  fi
  chmod 0755 /etc/init.d/space-link
  ok "init.d"
}

# ---- enable services -------------------------------------------------------
enable_services() {
  step "Включение сервисов"
  /etc/init.d/space-link enable >/dev/null 2>&1 || true
  /etc/init.d/space-link restart >/dev/null 2>&1 || /etc/init.d/space-link start >/dev/null 2>&1 || warn "space-link не стартовал"
  /etc/init.d/lighttpd enable >/dev/null 2>&1 || true
  /etc/init.d/lighttpd restart >/dev/null 2>&1 || /etc/init.d/lighttpd start >/dev/null 2>&1 || warn "lighttpd не стартовал"
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
    umask 022
  fi
  printf '%s\n' "$VERSION" > "$STATE_DIR/version"
  date '+%Y-%m-%dT%H:%M:%S' > "$STATE_DIR/installed_at"
}

# ---- dnsmasq alias ---------------------------------------------------------
configure_dns() {
  step "Регистрация my.spacelink в dnsmasq"
  router_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
  line="address=/my.spacelink/$router_ip"
  if [ -f /etc/dnsmasq.conf ]; then
    grep -q '^address=/my.spacelink/' /etc/dnsmasq.conf || printf '%s\n' "$line" >> /etc/dnsmasq.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    ok "my.spacelink → $router_ip"
  else
    warn "dnsmasq.conf не найден — пропускаю DNS-alias"
  fi
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
  router_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
  wifi=$(uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null || echo "—")
  printf '\n'
  printf '%s\n' "================================================"
  printf '   Space Link Router установлен (%s)\n' "$VERSION"
  printf '%s\n' "================================================"
  printf '   WiFi:       %s\n' "$wifi"
  printf '   Панель:     http://my.spacelink   (или http://%s)\n' "$router_ip"
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
install_templates
save_state
configure_dns
enable_services
install_cron
final_summary
