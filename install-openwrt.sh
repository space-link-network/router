#!/bin/sh
# Space Link Router installer. POSIX sh, runs in BusyBox.
# Usage: wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install.sh | sh
set -eu

VERSION="0.3.65"
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
INSTALL_TMP_DIR="${INSTALL_TMP_DIR:-/tmp}"
ENGINE_LOCK_DIR="${SPACE_LINK_ENGINE_LOCK:-/tmp/space-link-engine.lock}"
ENGINE_LOCK_RETRIES="${SPACE_LINK_ENGINE_LOCK_RETRIES:-30}"
ENGINE_LOCK_HELD=0
ACTIVE_INSTALL_DIR="$INSTALL_DIR"
PREVIOUS_INSTALL_DIR="${PREVIOUS_INSTALL_DIR:-/opt/space-link.previous}"
CANDIDATE_DIR="${CANDIDATE_DIR:-/opt/.space-link-candidate.$$}"
UPDATE_DIR="${SPACE_LINK_UPDATE_DIR:-$STATE_DIR/update}"
UPDATE_PENDING_MAX_AGE="${SPACE_LINK_UPDATE_PENDING_MAX_AGE:-7200}"
UPDATE_TX_ACTIVE=0
UPDATE_GUARD_STARTED=0
UPDATE_ROOT="${SPACE_LINK_UPDATE_ROOT:-}"
UPDATE_MODE=0
UPDATE_TX_PREPARED=0
INSTALL_SUCCESS=0
PREVIOUS_VERSION="unknown"
PREVIOUS_SPACE_LINK_ENABLED=0
PREVIOUS_SPACE_LINK_RUNNING=1
PREVIOUS_SINGBOX_ENABLED=0
PREVIOUS_SINGBOX_RUNNING=0
PREVIOUS_LIGHTTPD_ENABLED=0
PREVIOUS_LIGHTTPD_RUNNING=0
PREVIOUS_TPROXY_ARMED=0

# The panel is the .2 alias in the live LAN /24, outside OpenWrt's default
# DHCP pool (.100-.249). It is intentionally unset until network.lan.ipaddr has
# been read; no vendor-default prefix is allowed to become persisted state.
PANEL_IP=""
PANEL_PORT="${PANEL_PORT:-80}"
# The actual lighttpd listener is resolved by configure_panel_ip. It normally
# equals PANEL_IP, with the router's primary address used only as a safe fallback.
EFFECTIVE_BIND=""
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
    # BusyBox pgrep -x compares the full command line on deployed routers.
    # pidof matches the executable name exactly, without argv substring hits.
    if pidof "$svc" >/dev/null 2>&1; then
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
prune_backup_files() {
  keep="$1"
  shift
  [ "$#" -gt "$keep" ] || return 0
  remove=$(( $# - keep ))
  for file in "$@"; do
    [ "$remove" -gt 0 ] || break
    [ -e "$file" ] || continue
    rm -f "$file" 2>/dev/null || true
    remove=$(( remove - 1 ))
  done
}

prune_uci_backups() {
  for conf in dhcp network firewall wireless; do
    prune_backup_files 5 "$BACKUP_DIR/$conf".[0-9]*.uci
    prune_backup_files 5 "$BACKUP_DIR/$conf.raw".[0-9]*
  done
  prune_backup_files 3 "$BACKUP_DIR"/dhcp.broken.[0-9]*
  prune_backup_files 3 "$BACKUP_DIR"/dhcp.preinstall.[0-9]*
}

cleanup_install_artifacts() {
  for file in \
    "$INSTALL_TMP_DIR"/space-link-*.tar.gz \
    "$INSTALL_TMP_DIR"/space-link-*.tmp \
    "$INSTALL_TMP_DIR"/space-link-*.part
  do
    [ -e "$file" ] && rm -f "$file" 2>/dev/null || true
  done
  if command -v apk >/dev/null 2>&1; then
    apk cache clean >/dev/null 2>&1 || true
  fi
  rm -f "$BIN_PATH.new" 2>/dev/null || true
  for dir in "$INSTALL_DIR"/.www.new.*; do
    [ -e "$dir" ] && rm -rf "$dir" 2>/dev/null || true
  done
  for dir in "$INSTALL_DIR"/.www.old.*; do
    [ -e "$dir" ] || continue
    if [ ! -e "$WWW_DIR" ]; then
      mv "$dir" "$WWW_DIR" 2>/dev/null || true
    else
      rm -rf "$dir" 2>/dev/null || true
    fi
  done
}

acquire_engine_lock() {
  attempt=0
  while [ "$attempt" -lt "$ENGINE_LOCK_RETRIES" ]; do
    if mkdir "$ENGINE_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$ENGINE_LOCK_DIR/owner"
      ENGINE_LOCK_HELD=1
      return 0
    fi
    owner=""
    [ -r "$ENGINE_LOCK_DIR/owner" ] && owner=$(cat "$ENGINE_LOCK_DIR/owner" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*)
        # Allow a concurrent process to finish mkdir -> owner before treating
        # an ownerless directory as stale.
        sleep 1
        [ -r "$ENGINE_LOCK_DIR/owner" ] || rm -rf "$ENGINE_LOCK_DIR" 2>/dev/null || true
        ;;
      *)
        kill -0 "$owner" 2>/dev/null || rm -rf "$ENGINE_LOCK_DIR" 2>/dev/null || true
        sleep 1
        ;;
    esac
    attempt=$(( attempt + 1 ))
  done
  die "Другая операция с VPN ещё выполняется. Повтори через минуту."
}

release_engine_lock() {
  [ "$ENGINE_LOCK_HELD" = "1" ] || return 0
  owner=""
  [ -r "$ENGINE_LOCK_DIR/owner" ] && owner=$(cat "$ENGINE_LOCK_DIR/owner" 2>/dev/null || true)
  [ "$owner" = "$$" ] || return 0
  rm -f "$ENGINE_LOCK_DIR/owner" 2>/dev/null || true
  rmdir "$ENGINE_LOCK_DIR" 2>/dev/null || true
  ENGINE_LOCK_HELD=0
}

installer_exit() {
  exit_status=$?
  [ "$ENGINE_LOCK_HELD" = "1" ] || return "$exit_status"
  if [ "$UPDATE_TX_PREPARED" = "1" ] \
     && { [ "$exit_status" != "0" ] || [ "$INSTALL_SUCCESS" != "1" ]; }; then
    rollback_installer_transaction
  fi
  cleanup_install_artifacts
  release_engine_lock
  return "$exit_status"
}

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
  prune_uci_backups
  ok "снапшот UCI: $BACKUP_DIR (ts=$ts; хранится до 5 поколений)"
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
  if pidof dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq уже работает"
    return 0
  fi

  warn "dnsmasq не запущен — пробую поднять"
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 2
  if pidof dnsmasq >/dev/null 2>&1; then
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
  if pidof dnsmasq >/dev/null 2>&1; then
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

  if pidof dnsmasq >/dev/null 2>&1; then
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

set_install_target() {
  INSTALL_DIR="$1"
  WWW_DIR="$INSTALL_DIR/www"
  RULES_DIR="$INSTALL_DIR/rules"
  BIN_PATH="$INSTALL_DIR/space-link-api"
}

validate_candidate_runtime() {
  candidate="$1"
  [ -s "$candidate/space-link-api" ] || return 1
  [ -f "$candidate/www/index.html" ] || return 1
  [ -s "$candidate/rules/presets/ru.txt" ] || return 1
}

activate_candidate_runtime() {
  validate_candidate_runtime "$CANDIDATE_DIR" \
    || die "Новая сборка неполная — текущая версия оставлена без изменений"

  rm -rf "$PREVIOUS_INSTALL_DIR" 2>/dev/null || true
  if [ -e "$ACTIVE_INSTALL_DIR" ]; then
    mv "$ACTIVE_INSTALL_DIR" "$PREVIOUS_INSTALL_DIR" \
      || die "Не удалось сохранить предыдущую версию"
  fi
  if ! mv "$CANDIDATE_DIR" "$ACTIVE_INSTALL_DIR"; then
    [ -e "$PREVIOUS_INSTALL_DIR" ] && mv "$PREVIOUS_INSTALL_DIR" "$ACTIVE_INSTALL_DIR" 2>/dev/null || true
    die "Не удалось атомарно активировать новую версию"
  fi
  set_install_target "$ACTIVE_INSTALL_DIR"
  UPDATE_TX_ACTIVE=1
}

update_root_path() {
  printf '%s/%s\n' "$UPDATE_ROOT" "$1"
}

prepare_candidate_runtime() {
  UPDATE_MODE=1
  rm -rf "$CANDIDATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$CANDIDATE_DIR")"
  if [ -d "$ACTIVE_INSTALL_DIR" ]; then
    cp -a "$ACTIVE_INSTALL_DIR" "$CANDIDATE_DIR" \
      || die "Не удалось подготовить изолированную копию текущей версии"
  else
    mkdir -p "$CANDIDATE_DIR"
  fi
  set_install_target "$CANDIDATE_DIR"
}

update_managed_paths() {
  cat <<'EOF'
etc/config/dhcp
etc/config/network
etc/config/firewall
etc/config/wireless
etc/config/uhttpd
etc/config/sing-box
etc/config/space-link
etc/lighttpd/conf.d/space-link.conf
etc/init.d/space-link
etc/init.d/space-link-dns
etc/init.d/space-link-tproxy
etc/init.d/space-link-update-guard
usr/bin/space-link-dns
usr/bin/space-link-panel-watchdog
usr/bin/space-link-update-guard
etc/hotplug.d/iface/99-space-link-panel-ip
etc/crontabs/root
etc/space-link/version
etc/space-link/lan-ipv6.restore
etc/space-link/tproxy.nft
etc/space-link/tproxy.armed
EOF
}

service_was_enabled() {
  service="$1"
  rc_dir=$(update_root_path etc/rc.d)
  for link in "$rc_dir"/S??"$service"; do
    [ -L "$link" ] && return 0
  done
  return 1
}

service_was_running() {
  init=$(update_root_path "etc/init.d/$1")
  [ -x "$init" ] || return 1
  "$init" status 2>/dev/null | grep -q running
}

update_pending_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

update_pending_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

clear_stuck_update_pending() {
  reason="$1"
  outcome="$2"
  mkdir -p "$UPDATE_DIR"
  printf '%s\n' "$outcome" > "$UPDATE_DIR/outcome"
  rm -rf "$UPDATE_DIR/pending"
  sync 2>/dev/null || true
  case "$reason" in
    malformed) warn "Состояние прошлого обновления повреждено. Начинаю новое обновление." ;;
    stale) warn "Проверка прошлого обновления длилась слишком долго. Начинаю новое обновление." ;;
  esac
}

# Return success only for a current, complete probation. The update guard owns
# recovery after activation; this check only prevents an old state file from
# making every later installation impossible.
update_pending_is_running() {
  pending_file="$UPDATE_DIR/pending"
  [ -e "$pending_file" ] || return 1
  if [ ! -f "$pending_file" ] || [ ! -r "$pending_file" ]; then
    clear_stuck_update_pending malformed rollback-failed
    return 1
  fi

  pending_candidate=""
  pending_previous=""
  pending_started_at=""
  pending_valid=1
  pending_candidate_seen=0
  pending_previous_seen=0
  pending_healthy_seen=0
  pending_failed_seen=0

  while IFS='=' read -r key value; do
    case "$key" in
      candidate_version)
        if [ -n "$value" ]; then pending_candidate=$value; pending_candidate_seen=1; else pending_valid=0; fi
        ;;
      previous_version)
        if [ -n "$value" ]; then pending_previous=$value; pending_previous_seen=1; else pending_valid=0; fi
        ;;
      healthy_checks)
        if update_pending_is_uint "$value"; then pending_healthy_seen=1; else pending_valid=0; fi
        ;;
      failed_checks)
        if update_pending_is_uint "$value"; then pending_failed_seen=1; else pending_valid=0; fi
        ;;
      grace_checks|expect_wifi|previous_space_link_enabled|previous_space_link_running|previous_singbox_enabled|previous_singbox_running|previous_lighttpd_enabled|previous_lighttpd_running|previous_tproxy_armed)
        update_pending_is_uint "$value" || pending_valid=0
        ;;
      started_at)
        if update_pending_is_uint "$value"; then pending_started_at=$value; else pending_valid=0; fi
        ;;
    esac
  done < "$pending_file"

  if [ "$pending_valid" != 1 ] || [ "$pending_candidate_seen" != 1 ] \
    || [ "$pending_previous_seen" != 1 ] || [ "$pending_healthy_seen" != 1 ] \
    || [ "$pending_failed_seen" != 1 ]; then
    clear_stuck_update_pending malformed rollback-failed
    return 1
  fi

  if [ -z "$pending_started_at" ]; then
    pending_started_at=$(update_pending_mtime "$pending_file" 2>/dev/null || true)
  fi
  pending_max_age=$UPDATE_PENDING_MAX_AGE
  update_pending_is_uint "$pending_max_age" || pending_max_age=7200
  pending_now=$(date +%s 2>/dev/null || true)
  if update_pending_is_uint "$pending_started_at" && update_pending_is_uint "$pending_now" \
    && [ "$pending_now" -ge "$pending_started_at" ] \
    && [ $((pending_now - pending_started_at)) -ge "$pending_max_age" ]; then
    clear_stuck_update_pending stale stale
    return 1
  fi
  return 0
}

snapshot_update_state() {
  [ "$UPDATE_MODE" = "1" ] || return 0
  if update_pending_is_running; then
    die "Предыдущее обновление ещё проходит проверку. Повтори через 10 минут."
  fi

  PREVIOUS_VERSION=$(cat "$(update_root_path etc/space-link/version)" 2>/dev/null || echo unknown)
  service_was_enabled space-link && PREVIOUS_SPACE_LINK_ENABLED=1 || PREVIOUS_SPACE_LINK_ENABLED=0
  service_was_running space-link && PREVIOUS_SPACE_LINK_RUNNING=1 || PREVIOUS_SPACE_LINK_RUNNING=0
  service_was_enabled sing-box && PREVIOUS_SINGBOX_ENABLED=1 || PREVIOUS_SINGBOX_ENABLED=0
  service_was_running sing-box && PREVIOUS_SINGBOX_RUNNING=1 || PREVIOUS_SINGBOX_RUNNING=0
  service_was_enabled lighttpd && PREVIOUS_LIGHTTPD_ENABLED=1 || PREVIOUS_LIGHTTPD_ENABLED=0
  service_was_running lighttpd && PREVIOUS_LIGHTTPD_RUNNING=1 || PREVIOUS_LIGHTTPD_RUNNING=0
  [ -e "$(update_root_path etc/space-link/tproxy.armed)" ] \
    && PREVIOUS_TPROXY_ARMED=1 || PREVIOUS_TPROXY_ARMED=0
  EXPECT_WIFI=0
  if [ -z "$UPDATE_ROOT" ] && wifi status 2>/dev/null | grep -q '"up"[[:space:]]*:[[:space:]]*true'; then
    EXPECT_WIFI=1
  fi

  rm -rf "$UPDATE_DIR"
  mkdir -p "$UPDATE_DIR/snapshot"
  update_managed_paths > "$UPDATE_DIR/managed-files"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    source_path=$(update_root_path "$relative")
    [ -e "$source_path" ] || [ -L "$source_path" ] || continue
    snapshot_path="$UPDATE_DIR/snapshot/$relative"
    mkdir -p "$(dirname "$snapshot_path")"
    cp -a "$source_path" "$snapshot_path" \
      || die "Не удалось сохранить системный файл $relative для отката"
  done < "$UPDATE_DIR/managed-files"
  UPDATE_TX_PREPARED=1
}

restore_update_snapshot() {
  [ -r "$UPDATE_DIR/managed-files" ] || return 0
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in
      /*|*'..'*) return 1 ;;
    esac
    target=$(update_root_path "$relative")
    snapshot="$UPDATE_DIR/snapshot/$relative"
    rm -rf "$target" 2>/dev/null || true
    if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
      mkdir -p "$(dirname "$target")"
      cp -a "$snapshot" "$target" || return 1
    fi
  done < "$UPDATE_DIR/managed-files"
}

install_update_guard() {
  guard_bin=$(update_root_path usr/bin/space-link-update-guard)
  guard_init=$(update_root_path etc/init.d/space-link-update-guard)
  mkdir -p "$(dirname "$guard_bin")" "$(dirname "$guard_init")"
  if [ -f "$SCRIPT_DIR/../templates/space-link-update-guard" ]; then
    cp "$SCRIPT_DIR/../templates/space-link-update-guard" "$guard_bin"
    cp "$SCRIPT_DIR/../templates/space-link-update-guard.init" "$guard_init"
  else
    fetch "$RELEASE_BASE/space-link-update-guard" "$guard_bin" \
      || die "Не удалось скачать независимый guard обновлений"
    fetch "$RELEASE_BASE/space-link-update-guard.init" "$guard_init" \
      || die "Не удалось скачать procd-сервис guard обновлений"
  fi
  chmod 0755 "$guard_bin" "$guard_init"
  if [ -z "$UPDATE_ROOT" ]; then
    "$guard_init" enable >/dev/null 2>&1 \
      || die "Не удалось включить независимый guard обновлений"
  fi
}

write_update_pending() {
  mkdir -p "$UPDATE_DIR"
  pending_started_at=$(date +%s 2>/dev/null || true)
  pending_tmp="$UPDATE_DIR/pending.tmp.$$"
  cat > "$pending_tmp" <<EOF
candidate_version=$VERSION
previous_version=$PREVIOUS_VERSION
healthy_checks=0
failed_checks=0
grace_checks=0
expect_wifi=${EXPECT_WIFI:-0}
previous_space_link_enabled=$PREVIOUS_SPACE_LINK_ENABLED
previous_space_link_running=$PREVIOUS_SPACE_LINK_RUNNING
previous_singbox_enabled=$PREVIOUS_SINGBOX_ENABLED
previous_singbox_running=$PREVIOUS_SINGBOX_RUNNING
previous_lighttpd_enabled=$PREVIOUS_LIGHTTPD_ENABLED
previous_lighttpd_running=$PREVIOUS_LIGHTTPD_RUNNING
previous_tproxy_armed=$PREVIOUS_TPROXY_ARMED
EOF
  [ -n "$pending_started_at" ] && printf 'started_at=%s\n' "$pending_started_at" >> "$pending_tmp"
  chmod 0600 "$pending_tmp" 2>/dev/null || true
  mv "$pending_tmp" "$UPDATE_DIR/pending"
}

begin_update_transaction() {
  [ "$UPDATE_MODE" = "1" ] || return 0
  validate_candidate_runtime "$CANDIDATE_DIR" \
    || die "Новая сборка неполная — текущая версия оставлена без изменений"
  [ "$UPDATE_TX_PREPARED" = "1" ] || snapshot_update_state
  install_update_guard
  write_update_pending
  activate_candidate_runtime
}

start_update_guard() {
  [ "$UPDATE_MODE" = "1" ] || return 0
  guard_init=$(update_root_path etc/init.d/space-link-update-guard)
  if [ -z "$UPDATE_ROOT" ] && [ -x "$guard_init" ]; then
    "$guard_init" restart >/dev/null 2>&1 \
      || "$guard_init" start >/dev/null 2>&1 \
      || die "Не удалось запустить независимый guard обновлений"
    guard_running=0
    for _ in 1 2 3 4 5; do
      if "$guard_init" status 2>/dev/null | grep -q running; then
        guard_running=1
        break
      fi
      sleep 1
    done
    [ "$guard_running" = "1" ] \
      || die "Guard обновлений не запустился — возвращаю предыдущую версию"
  fi
  UPDATE_GUARD_STARTED=1
}
restore_pre_activation_services() {
  dnsmasq_init=$(update_root_path etc/init.d/dnsmasq)
  [ -x "$dnsmasq_init" ] && "$dnsmasq_init" restart >/dev/null 2>&1 || true
  odhcpd_init=$(update_root_path etc/init.d/odhcpd)
  [ -x "$odhcpd_init" ] && "$odhcpd_init" restart >/dev/null 2>&1 || true
  if [ "$PREVIOUS_TPROXY_ARMED" = "1" ]; then
    tproxy_init=$(update_root_path etc/init.d/space-link-tproxy)
    [ -x "$tproxy_init" ] && "$tproxy_init" start >/dev/null 2>&1 || true
  fi
}


rollback_installer_transaction() {
  [ "$UPDATE_TX_PREPARED" = "1" ] || return 0
  guard_bin=$(update_root_path usr/bin/space-link-update-guard)
  if [ "$UPDATE_TX_ACTIVE" = "1" ] && [ -x "$guard_bin" ] && [ -f "$UPDATE_DIR/pending" ]; then
    SL_ROOT="$UPDATE_ROOT" \
    SL_ACTIVE_DIR="$ACTIVE_INSTALL_DIR" \
    SL_PREVIOUS_DIR="$PREVIOUS_INSTALL_DIR" \
    SL_UPDATE_DIR="$UPDATE_DIR" \
      "$guard_bin" rollback || warn "Автоматический откат завершился с ошибкой"
  else
    restore_update_snapshot || warn "Не удалось полностью восстановить системные конфиги"
    rm -f "$UPDATE_DIR/pending" 2>/dev/null || true
    rm -rf "$CANDIDATE_DIR" 2>/dev/null || true
    restore_pre_activation_services
  fi
  UPDATE_TX_ACTIVE=0
  UPDATE_TX_PREPARED=0
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
  mkdir -p "$INSTALL_DIR" "$INSTALL_TMP_DIR"
  archive="$INSTALL_TMP_DIR/space-link-ui.tar.gz"
  stage="$INSTALL_DIR/.www.new.$$"
  old="$INSTALL_DIR/.www.old.$$"
  rm -rf "$stage" "$old"
  fetch "$RELEASE_BASE/ui.tar.gz" "$archive" || die "Не удалось скачать ui.tar.gz"
  mkdir -p "$stage"
  tar -xzf "$archive" -C "$stage" || die "Не удалось распаковать ui.tar.gz"
  [ -f "$stage/index.html" ] || die "В ui.tar.gz отсутствует index.html"

  if [ -e "$WWW_DIR" ]; then
    mv "$WWW_DIR" "$old" || die "Не удалось подготовить замену UI"
  fi
  if ! mv "$stage" "$WWW_DIR"; then
    [ -e "$old" ] && mv "$old" "$WWW_DIR" 2>/dev/null || true
    die "Не удалось активировать новый UI"
  fi
  rm -rf "$old"
  rm -f "$archive"
  ok "$WWW_DIR"
}

install_rules() {
  step "Установка пресетов маршрутизации"
  mkdir -p "$RULES_DIR/presets" "$RULES_DIR/presets/ip"
  if [ -d "$SCRIPT_DIR/../rules/presets" ]; then
    cp "$SCRIPT_DIR/../rules/presets"/*.txt "$RULES_DIR/presets/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../rules/presets/ip/"*.txt "$RULES_DIR/presets/ip/" 2>/dev/null || true
  else
    for preset in ru cis ai social stores crypto ads twitch-ads win-spy torrent; do
      fetch "$RELEASE_BASE/rules-$preset.txt" "$RULES_DIR/presets/$preset.txt" 2>/dev/null \
        || warn "пресет $preset не скачался — не критично, можно выбрать позже"
    done
    for preset in telegram; do
      fetch "$RELEASE_BASE/rules-ip-$preset.txt" "$RULES_DIR/presets/ip/$preset.txt" 2>/dev/null \
        || warn "пресет адресов $preset не скачался — не критично, можно выбрать позже"
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

# ---- LAN prefix ------------------------------------------------------------
# Both our box and almost every ISP router ship on 192.168.1.1. Plugged into
# each other they share a prefix, the default gateway resolves to our own
# bridge, and nothing routes: no internet, no tunnel — while the panel still
# answers, because a local address needs no routing. A fresh install therefore
# moves onto a prefix of our own. Existing installs keep whatever they have.
LAN_CANDIDATES="192.168.11.1 192.168.77.1 192.168.99.1 10.71.0.1"

# Networks currently reachable through the upstream link. WAN_TEST_NETWORKS
# lets the contract suite drive this without a real interface.
wan_networks() {
  if [ -n "${WAN_TEST_NETWORKS:-}" ]; then
    printf '%s\n' $WAN_TEST_NETWORKS
    return 0
  fi
  ip -4 route show 2>/dev/null | awk '$1 ~ /\// && $0 !~ /br-lan/ { print $1 }'
  ip -4 route show default 2>/dev/null | awk '{ print $3 }'
}

# Compare only the first three octets: every candidate is a /24, and an ISP
# router handing out a wider mask still overlaps us on that boundary.
lan_prefix_conflicts() {
  candidate_prefix=$(printf '%s\n' "${1:-}" | cut -d. -f1-3)
  [ -n "$candidate_prefix" ] || return 1
  for network in $(wan_networks); do
    network_prefix=$(printf '%s\n' "$network" | cut -d/ -f1 | cut -d. -f1-3)
    [ "$network_prefix" = "$candidate_prefix" ] && return 0
  done
  return 1
}

pick_lan_prefix() {
  for candidate in $LAN_CANDIDATES; do
    lan_prefix_conflicts "$candidate" && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# Runs on updates too: every router shipped so far sits on the vendor default,
# and that is exactly the prefix an ISP box occupies. A prefix the user chose
# themselves is left alone unless it actually collides with the upstream.
# The panel alias is always the .2 address in the active /24. Re-derive it on
# every run: an earlier installer may already have moved network.lan while
# leaving the panel consumers pinned to the vendor-default address.
sync_panel_ip_to_lan() {
  panel_lan_ip="$(printf '%s\n' "${1:-}" | awk '{ print $1; exit }' | cut -d/ -f1)"
  panel_target_ip="$(printf '%s\n' "$panel_lan_ip" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9][0-9]*$/ || $i < 0 || $i > 255) {
          exit 1
        }
      }
      printf "%d.%d.%d.2\n", $1, $2, $3
    }
  ')" || return 1
  [ -n "$panel_target_ip" ] || return 1
  PANEL_IP="$panel_target_ip"
  EFFECTIVE_BIND="$PANEL_IP"
}

relocate_lan_subnet() {
  command -v uci >/dev/null 2>&1 || return 0

  current=$(uci -q get network.lan.ipaddr 2>/dev/null | awk '{print $1}' | cut -d'/' -f1)
  [ -n "$current" ] || return 0
  current_prefix=$(printf '%s\n' "$current" | cut -d. -f1-3)

  # Synchronize even when the LAN itself no longer needs moving. This is the
  # repair path for installations where network.lan was committed but the
  # panel files and runtime alias were left on the previous prefix.
  sync_panel_ip_to_lan "$current" || return 0
  ROUTER_IP="$current"
  [ "${KEEP_LAN:-0}" = "1" ] && return 0

  needs_move=0
  # 192.168.1.x is what both we and virtually every ISP router ship with.
  [ "$current_prefix" = "192.168.1" ] && needs_move=1
  lan_prefix_conflicts "$current" && needs_move=1
  [ "$needs_move" = "1" ] || return 0

  target=$(pick_lan_prefix) || {
    warn "все запасные подсети заняты сетью провайдера — оставляю $current"
    return 0
  }
  target_prefix=$(printf '%s\n' "$target" | cut -d. -f1-3)
  [ "$target_prefix" = "$current_prefix" ] && return 0

  step "Своя подсеть роутера: $target (была $current)"
  uci -q set network.lan.ipaddr="$target" || { warn "не удалось задать адрес — оставляю $current"; return 0; }
  uci -q set network.lan.netmask="255.255.255.0" 2>/dev/null || true
  relocate_static_leases "$current_prefix" "$target_prefix"
  shorten_dhcp_lease
  uci -q commit network || { warn "не удалось сохранить адрес — оставляю $current"; return 0; }
  uci -q commit dhcp >/dev/null 2>&1 || true

  # Reload, never a full restart: the installer is usually running through the
  # very session that a restart would drop, and netifd takes longer to bring
  # interfaces back.
  /etc/init.d/network reload >/dev/null 2>&1 || true

  # Keep the previous address alive as a plain alias so the running SSH/web
  # session and every client still holding a lease keep working until they
  # renew. It is not persisted, so it disappears on the next reboot.
  ip addr add "$current/24" dev br-lan 2>/dev/null || true
  LAN_LEGACY_IP="$current"

  ROUTER_IP="$target"
  sync_panel_ip_to_lan "$target" || return 0
  ok "роутер теперь на $ROUTER_IP, панель на $PANEL_IP (старый адрес ещё отвечает до перезагрузки)"
}


# Static leases written for the old prefix would point at a network that no
# longer exists; move them with the router instead of silently breaking them.
relocate_static_leases() {
  from="$1"
  to="$2"
  index=0
  while :; do
    lease_ip=$(uci -q get "dhcp.@host[$index].ip" 2>/dev/null) || break
    [ -n "$lease_ip" ] || break
    case "$lease_ip" in
      "$from".*)
        uci -q set "dhcp.@host[$index].ip=${to}.${lease_ip##*.}" >/dev/null 2>&1 || true
        ;;
    esac
    index=$((index + 1))
  done
}

# Clients keep the old gateway until their lease renews. Shorten it so the new
# address propagates in minutes instead of hours; the original value is put
# back once the install finishes.
shorten_dhcp_lease() {
  LAN_LEASETIME_ORIGINAL=$(uci -q get dhcp.lan.leasetime 2>/dev/null || echo "")
  uci -q set dhcp.lan.leasetime="5m" >/dev/null 2>&1 || true
}

restore_dhcp_lease() {
  [ -n "${LAN_LEGACY_IP:-}" ] || return 0
  if [ -n "${LAN_LEASETIME_ORIGINAL:-}" ]; then
    uci -q set dhcp.lan.leasetime="$LAN_LEASETIME_ORIGINAL" >/dev/null 2>&1 || true
  else
    uci -q delete dhcp.lan.leasetime >/dev/null 2>&1 || true
  fi
  uci -q commit dhcp >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
}

# ---- panel IP alias --------------------------------------------------------
# Пытается поднять alias-IP. Если не поднялся за 2 сек — fallback (Вариант A):
# выключаем uhttpd, занимаем :80 на основном IP роутера. EFFECTIVE_BIND и
# EFFECTIVE_PORT в конце отражают реальное место панели.
# Disable the old hook before touching addresses: otherwise an interface event
# can recreate the stale alias between deletion and the final atomic rewrite.
# Only addresses recorded by this installer are candidates for removal.
remove_stale_panel_aliases() {
  stale_panel_hotplug="$1"
  managed_panel_ips=""
  if [ -f "$stale_panel_hotplug" ]; then
    managed_panel_ips="$managed_panel_ips $(sed -n 's|.*ip addr add "\([0-9][0-9.]*\)/24".*|\1|p' "$stale_panel_hotplug" 2>/dev/null || true)"
    rm -f "$stale_panel_hotplug" \
      || die "Не удалось отключить устаревший hotplug адреса панели"
  fi

  panel_hosts="${PANEL_HOSTS_FILE:-/etc/hosts}"
  if [ -f "$panel_hosts" ]; then
    managed_panel_ips="$managed_panel_ips $(awk '
      {
        managed = ($0 ~ /# space-link-panel[[:space:]]*$/)
        for (i = 2; i <= NF; i++) {
          if ($i == "my.space" || $i == "my.sapce" ||
              $i == "my.spacelink" || $i == "spacelink.lan" ||
              $i == "panel.home.arpa") {
            managed = 1
          }
        }
        if (managed) print $1
      }
    ' "$panel_hosts" 2>/dev/null)"
  fi

  panel_lighttpd="${PANEL_LIGHTTPD_CONF:-/etc/lighttpd/conf.d/space-link.conf}"
  if [ -f "$panel_lighttpd" ]; then
    managed_panel_ips="$managed_panel_ips $(awk -F'"' '/server.bind/ { print $2; exit }' "$panel_lighttpd" 2>/dev/null)"
  fi
  if command -v uci >/dev/null 2>&1; then
    for panel_record in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true); do
      case "$panel_record" in
        */my.space/*|*/my.sapce/*|*/my.spacelink/*|*/spacelink.lan/*|*/panel.home.arpa/*)
          managed_panel_ips="$managed_panel_ips ${panel_record##*/}"
          ;;
      esac
    done
  fi


  for stale_panel_ip in $managed_panel_ips; do
    case "$stale_panel_ip" in
      ''|*[!0-9.]*|*.*.*.*.*) continue ;;
      *.*.*.2) ;;
      *) continue ;;
    esac
    [ "$stale_panel_ip" = "$PANEL_IP" ] && continue
    [ "$stale_panel_ip" = "$ROUTER_IP" ] && continue
    if ip addr show br-lan 2>/dev/null | grep -Fq "inet $stale_panel_ip/"; then
      ip addr del "$stale_panel_ip/24" dev br-lan 2>/dev/null || true
      if ip addr show br-lan 2>/dev/null | grep -Fq "inet $stale_panel_ip/"; then
        die "Не удалось удалить устаревший адрес панели $stale_panel_ip"
      fi
    fi
  done
}

configure_panel_ip() {
  # Keep the router's primary LAN configuration byte-for-byte intact. A prior
  # installer rewrote network.lan.ipaddr as a list and reloaded all of netifd;
  # on real hardware that dropped Ethernet, Wi-Fi, and the SSH recovery path.
  ROUTER_IP_RAW=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
  ROUTER_IP=$(printf '%s\n' "$ROUTER_IP_RAW" | awk '{print $1}' | cut -d'/' -f1)
  [ -n "$ROUTER_IP" ] || ROUTER_IP="192.168.1.1"
  sync_panel_ip_to_lan "$ROUTER_IP" || {
    warn "не удалось вычислить адрес панели из LAN $ROUTER_IP"
    fallback_to_router_ip
    return 0
  }

  step "Доп. IP для панели: $PANEL_IP (основной: $ROUTER_IP)"
  if ! command -v uci >/dev/null 2>&1; then
    warn "uci недоступен — переключаюсь на основной IP роутера ($ROUTER_IP)"
    fallback_to_router_ip
    return 0
  fi

  # Remove only the obsolete standalone interface. Never rewrite lan.ipaddr
  # and never reload network during an application update.
  if uci -q get network.lan_panel >/dev/null 2>&1; then
    uci -q delete network.lan_panel
    uci commit network
  fi

  panel_hotplug="${PANEL_HOTPLUG_PATH:-/etc/hotplug.d/iface/99-space-link-panel-ip}"
  remove_stale_panel_aliases "$panel_hotplug"

  main_present=0
  alias_present=0
  ip addr show br-lan 2>/dev/null | grep -Fq "inet $ROUTER_IP/" && main_present=1
  ip addr show br-lan 2>/dev/null | grep -Fq "inet $PANEL_IP/" && alias_present=1
  if [ "$alias_present" != "1" ]; then
    ip addr add "$PANEL_IP/24" dev br-lan 2>/dev/null || true
    sleep 1
    ip addr show br-lan 2>/dev/null | grep -Fq "inet $PANEL_IP/" && alias_present=1
    ip addr show br-lan 2>/dev/null | grep -Fq "inet $ROUTER_IP/" && main_present=1
  fi

  if [ "$main_present" = "1" ] && [ "$alias_present" = "1" ]; then
    EFFECTIVE_BIND="$PANEL_IP"
    EFFECTIVE_PORT="$PANEL_PORT"

    # Persist the runtime alias without changing the LAN UCI package. netifd
    # invokes this after future LAN ifup events and the panel watchdog provides
    # a second non-disruptive repair path.
    mkdir -p "$(dirname "$panel_hotplug")"
    panel_hotplug_tmp="$panel_hotplug.tmp.$$"
    cat > "$panel_hotplug_tmp" <<HOOK
#!/bin/sh
[ "\${ACTION:-}" = "ifup" ] || exit 0
[ "\${INTERFACE:-}" = "lan" ] || exit 0
ip addr show br-lan 2>/dev/null | grep -Fq "inet $PANEL_IP/" \
  || ip addr add "$PANEL_IP/24" dev br-lan 2>/dev/null || true
HOOK
    chmod 0755 "$panel_hotplug_tmp" \
      || { rm -f "$panel_hotplug_tmp"; die "Не удалось сохранить настройки адреса панели"; }
    mv "$panel_hotplug_tmp" "$panel_hotplug" \
      || die "Не удалось сохранить настройки адреса панели"

    ok "доп. IP $PANEL_IP/24 добавлен без перезапуска сети; основной $ROUTER_IP сохранён"
    uci -q delete uhttpd.main.listen_http  >/dev/null 2>&1 || true
    uci -q delete uhttpd.main.listen_https >/dev/null 2>&1 || true
    uci add_list uhttpd.main.listen_http="$ROUTER_IP:80"   >/dev/null 2>&1 || true
    uci add_list uhttpd.main.listen_https="$ROUTER_IP:443" >/dev/null 2>&1 || true
    uci commit uhttpd >/dev/null 2>&1 || true

    /etc/init.d/uhttpd enable  >/dev/null 2>&1 || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd start >/dev/null 2>&1 || true
    sleep 1
    if pidof uhttpd >/dev/null 2>&1; then
      ok "uhttpd (LuCI) запущен на http://$ROUTER_IP/ (bind only)"
    else
      warn "uhttpd не стартовал — LuCI недоступна, не критично"
    fi
    return 0
  fi

  warn "secondary IP не встал (main=$main_present alias=$alias_present) — использую основной IP без reload сети"
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

  # Traffic controls.
  #   dns_tunnel — retained as a persisted compatibility/diagnostic value;
  #                the dedicated DNS-pinning table now owns external port 53.
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

  # DNS pinning lives in the separate `space_link_dns` dstnat table and sends
  # hardcoded port-53 clients to dnsmasq. This mangle hook runs before dstnat,
  # so it must explicitly return DNS before the catch-all TPROXY rules below.
  # When the watchdog removes a silent dnsmasq redirect, the same returns make
  # the client's configured resolver fail open instead of entering sing-box.
  DNS_RULE_V4="iifname \"br-lan\" meta l4proto { tcp, udp } meta nfproto ipv4 th dport 53 return"
  DNS_RULE_V6="iifname \"br-lan\" meta l4proto { tcp, udp } meta nfproto ipv6 th dport 53 return"

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
        # DNS continues to the dedicated dnsmasq redirect, never to sing-box.
        # Family-specific returns also preserve direct fail-open if it is down.
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
  # BusyBox pgrep -x checks the full argv; pidof checks the exact executable name.
  pidof sing-box >/dev/null 2>&1 || return 1
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
  # IPv6 policy routing is a bonus: plenty of routers run IPv4-only, and
  # iproute2 exits 2 when it cannot add the rule. Letting that code escape
  # would tell the engine the restart failed, and the watchdog would engage
  # the kill switch over an optional command. Interception is applied by the
  # nft ruleset above, so report on that instead.
  return 0
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
# health-gated path is armed and the exact sing-box executable is still alive.
if [ -f /etc/space-link/tproxy.armed ] && pidof sing-box >/dev/null 2>&1; then
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
  pidof sing-box >/dev/null 2>&1 || return 1
  command -v netstat >/dev/null 2>&1 || return 1
  netstat -ln 2>/dev/null | grep -Eq '[:.]12345[[:space:]]' || return 1
}

# A kill switch that was engaged by an older release survives reboots and can
# only be cleared by hand. We have just verified the whole path end to end, so
# an update is exactly the moment to release it — otherwise the router keeps
# routing around the tunnel until someone notices the banner.
clear_stale_kill_switch() {
  state_file="${WATCHDOG_STATE_FILE:-/etc/space-link/watchdog.json}"
  [ -f "$state_file" ] || return 0
  grep -q '"active"[[:space:]]*:[[:space:]]*true' "$state_file" || return 0
  printf '%s\n' '{"active":false}' > "$state_file"
  ok "аварийное отключение снято — защита снова включена"
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
    clear_stale_kill_switch
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
  # The DHCP transport retries every resolver advertised by the ISP instead
  # of making fresh installs depend on one remote endpoint. Direct traffic is
  # already ISP-visible, so local reachability is the honest privacy tradeoff.
  if [ ! -s /etc/sing-box/config.json ]; then
    mkdir -p /etc/sing-box
    if [ -f "$SCRIPT_DIR/../templates/sing-box-stub.json" ]; then
      cp "$SCRIPT_DIR/../templates/sing-box-stub.json" /etc/sing-box/config.json
    else
      fetch "$RELEASE_BASE/sing-box-stub.json" /etc/sing-box/config.json 2>/dev/null || \
        printf '%s\n' '{"log":{"level":"warn"},"dns":{"servers":[{"type":"udp","tag":"direct-dns","server":"127.0.0.1","server_port":53}],"final":"direct-dns"},"inbounds":[{"type":"direct","tag":"dns-in","listen":"127.0.0.42","listen_port":53,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true,"default_domain_resolver":"direct-dns","final":"direct","rules":[{"protocol":"dns","action":"hijack-dns"}]}}' > /etc/sing-box/config.json
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
    if pidof lighttpd >/dev/null 2>&1; then
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
# ---- LAN DNS pinning -------------------------------------------------------
# `address=/my.space/...` only helps clients that actually ask us. A device
# with 8.8.8.8 hardcoded resolves my.space on the internet, where it is a real
# registered domain parked on someone else's IP — that is why the panel opens
# in one browser and not in another. Redirect every LAN query for port 53 to
# our own resolver, and reject DoT so clients fall back to plain 53 which we
# now own. DoH cannot be intercepted; the Firefox canary below handles Firefox,
# and sing-box resolves the panel names locally for the tunnelled path.
write_dns_pinning_ruleset() {
  target="${DNS_PIN_FILE:-/etc/space-link/dns-pinning.nft}"
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  cat > "$target" <<'NFT'
table inet space_link_dns
delete table inet space_link_dns

table inet space_link_dns {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        # Queries already addressed to the router reach dnsmasq on their own.
        fib daddr type local return
        iifname "br-lan" meta l4proto { tcp, udp } th dport 53 redirect to :53
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        # DNS-over-TLS would bypass the redirect above; rejecting it makes
        # clients fall back to port 53 instead of silently using a stranger's
        # resolver. Reject (not drop) so the fallback is immediate.
        iifname "br-lan" meta l4proto tcp th dport 853 reject
    }
}
NFT
}

apply_dns_pinning() {
  step "Локальные имена роутера для всей сети"
  command -v nft >/dev/null 2>&1 || { warn "nft отсутствует — пропускаю"; return 0; }
  write_dns_pinning_ruleset
  if nft -f /etc/space-link/dns-pinning.nft >/dev/null 2>&1; then
    ok "запросы имён из сети обслуживает сам роутер"
  else
    warn "не удалось включить перехват DNS — имена будут работать только у устройств с DNS роутера"
  fi
}

# The router's own processes must resolve the panel too, and /etc/hosts keeps
# working even while dnsmasq is being restarted.
write_panel_hosts() {
  hosts_file="${PANEL_HOSTS_FILE:-/etc/hosts}"
  [ -f "$hosts_file" ] || return 0
  tmp="${hosts_file}.space-link.$$"
  if ! awk '
    /# space-link-panel[[:space:]]*$/ { next }
    {
      owned = 0
      kept = 0
      rebuilt = $1
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "#") {
          for (j = i; j <= NF; j++) rebuilt = rebuilt " " $j
          break
        }
        if ($i == "my.space" || $i == "my.sapce" ||
            $i == "my.spacelink" || $i == "spacelink.lan" ||
            $i == "panel.home.arpa") {
          owned = 1
          continue
        }
        rebuilt = rebuilt " " $i
        kept = 1
      }
      if (owned) {
        if (kept) print rebuilt
        next
      }
      print
    }
  ' "$hosts_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s my.space my.sapce panel.home.arpa # space-link-panel\n' "$EFFECTIVE_BIND" >> "$tmp"
  if cmp -s "$tmp" "$hosts_file" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$hosts_file"
}

# Every install and update ends here, and the panel must answer immediately —
# not after the watchdog's ten-minute full audit. dnsmasq parses /etc/hosts
# only at startup and configure_dns already restarted it before the panel
# records were written, so an update that moves the panel leaves the name
# pointing at the previous address for the rest of the boot. Reload
# unconditionally: it costs one signal, and skipping it on "nothing changed"
# is exactly how a half-migrated router keeps serving a dead address.
bring_panel_up() {
  step "Проверка панели"
  /etc/init.d/dnsmasq reload >/dev/null 2>&1 \
    || /etc/init.d/dnsmasq restart >/dev/null 2>&1 \
    || true

  panel_probe=1
  while [ "$panel_probe" -le 5 ]; do
    if wget -q -O /dev/null --timeout=3 "http://$EFFECTIVE_BIND/" 2>/dev/null; then
      ok "панель отвечает на http://$EFFECTIVE_BIND/"
      return 0
    fi
    /etc/init.d/lighttpd restart >/dev/null 2>&1 || true
    sleep 2
    panel_probe=$((panel_probe + 1))
  done

  warn "панель не ответила на http://$EFFECTIVE_BIND/ — watchdog продолжит поднимать её"
  return 0
}

# Remove every current or legacy rule owned by Space Link. Matching the values
# already present is what removes unknown stale IPs; the fixed candidate list
# alone cannot do that reliably.
_dns_uci_purge_all() {
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  [ -n "$addrs" ] || return 0
  for a in $addrs; do
    case "$a" in
      */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*|*/panel.home.arpa/*)
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
  # RFC 8375 reserves home.arpa for home networks: unlike my.space it can never
  # be registered by anyone, so this name is immune to a public answer.
  uci -q add_list dhcp.@dnsmasq[0].address="/panel.home.arpa/$EFFECTIVE_BIND" >/dev/null 2>&1 || return 1
  uci -q add_list dhcp.@dnsmasq[0].address="/panel.home.arpa/" >/dev/null 2>&1 || return 1
  # Firefox turns its own DoH off when this canary domain returns NXDOMAIN,
  # which keeps the browser using the resolver we control.
  _dns_uci_canary
}

_dns_uci_canary() {
  servers=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
  for s in $servers; do
    [ "$s" = "/use-application-dns.net/" ] && return 0
  done
  uci -q add_list dhcp.@dnsmasq[0].server="/use-application-dns.net/" >/dev/null 2>&1 || return 1
}

# Non-UCI variants still read /etc/dnsmasq.conf. Rewrite only Space Link's
# exact directives, preserving user DNS settings and unrelated local zones.
_dns_file_normalize() {
  conf="$1"
  tmp="${conf}.space-link.$$"
  if ! awk '
    /^[[:space:]]*(address|local)=\/(my\.space|my\.sapce|my\.spacelink|spacelink\.lan|panel\.home\.arpa)\// { next }
    /^[[:space:]]*server=\/use-application-dns\.net\// { next }
    { print }
  ' "$conf" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf 'address=/my.space/%s\n' "$EFFECTIVE_BIND" >> "$tmp"
  printf 'local=/my.space/\n' >> "$tmp"
  printf 'address=/my.sapce/%s\n' "$EFFECTIVE_BIND" >> "$tmp"
  printf 'local=/my.sapce/\n' >> "$tmp"
  printf 'address=/panel.home.arpa/%s\n' "$EFFECTIVE_BIND" >> "$tmp"
  printf 'local=/panel.home.arpa/\n' >> "$tmp"
  printf 'server=/use-application-dns.net/\n' >> "$tmp"
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
  sed -i '/list address.*panel\.home\.arpa\//d' /etc/config/dhcp 2>/dev/null || true
}

# Verify the process, exact authoritative UCI rules, and both IPv4 answers.
_dns_verify() {
  pidof dnsmasq >/dev/null 2>&1 || return 1
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  for expected in "/my.space/$EFFECTIVE_BIND" "/my.space/" "/my.sapce/$EFFECTIVE_BIND" "/my.sapce/" \
    "/panel.home.arpa/$EFFECTIVE_BIND" "/panel.home.arpa/"; do
    found=0
    for a in $addrs; do
      [ "$a" = "$expected" ] && found=$((found + 1))
    done
    [ "$found" = "1" ] || return 1
  done
  if command -v nslookup >/dev/null 2>&1; then
    nslookup my.space 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND" || return 1
    nslookup my.sapce 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND" || return 1
    nslookup panel.home.arpa 127.0.0.1 2>/dev/null | grep -q "$EFFECTIVE_BIND" || return 1
  fi
  return 0
}

# ---- panel watchdog --------------------------------------------------------
install_panel_watchdog() {
  step "Установка watchdog панели"
  cat > /usr/bin/space-link-panel-watchdog <<'WATCHDOG'
#!/bin/sh

# A LAN ULA is useful only when the router can send IPv6 upstream. odhcpd
# otherwise makes clients prefer unreachable AAAA answers, adding a timeout to
# every connection. Keep the operator's exact modes in a private state file so
# automatic suppression is reversible and never invents an enabled policy.
ipv6_state_file=${IPV6_LAN_STATE_FILE:-/etc/space-link/lan-ipv6.restore}
ipv6_odhcpd_init=${ODHCPD_INIT:-/etc/init.d/odhcpd}
panel_hosts_file=${PANEL_HOSTS_FILE:-/etc/hosts}
panel_hotplug_file=${PANEL_HOTPLUG_PATH:-/etc/hotplug.d/iface/99-space-link-panel-ip}
panel_lighttpd_conf=${PANEL_LIGHTTPD_CONF:-/etc/lighttpd/conf.d/space-link.conf}
panel_target_cache=${PANEL_TARGET_CACHE:-/tmp/space-link-panel-watchdog.target}


ipv6_log() {
  logger -t space-link-ipv6-lan "$*" 2>/dev/null || true
}

ipv6_mode_is_supported() {
  case "${1:-}" in
    __unset__|server|relay|hybrid|disabled) return 0 ;;
    *) return 1 ;;
  esac
}

ipv6_uci_get() {
  ipv6_value=$(uci -q get "dhcp.lan.$1" 2>/dev/null) || ipv6_value="__unset__"
  [ -n "$ipv6_value" ] || ipv6_value="__unset__"
  printf '%s\n' "$ipv6_value"
}

read_ipv6_restore_state() {
  ipv6_restore_ra=""
  ipv6_restore_dhcpv6=""
  ipv6_restore_ndp=""
  ipv6_restore_applied=""
  ipv6_seen_ra=0
  ipv6_seen_dhcpv6=0
  ipv6_seen_ndp=0
  ipv6_seen_applied=0
  ipv6_state_valid=1

  while IFS='=' read -r ipv6_key ipv6_value; do
    case "$ipv6_key" in
      ra)
        [ "$ipv6_seen_ra" = 0 ] || ipv6_state_valid=0
        ipv6_restore_ra="$ipv6_value"
        ipv6_seen_ra=1
        ;;
      dhcpv6)
        [ "$ipv6_seen_dhcpv6" = 0 ] || ipv6_state_valid=0
        ipv6_restore_dhcpv6="$ipv6_value"
        ipv6_seen_dhcpv6=1
        ;;
      ndp)
        [ "$ipv6_seen_ndp" = 0 ] || ipv6_state_valid=0
        ipv6_restore_ndp="$ipv6_value"
        ipv6_seen_ndp=1
        ;;
      applied)
        [ "$ipv6_seen_applied" = 0 ] || ipv6_state_valid=0
        ipv6_restore_applied="$ipv6_value"
        ipv6_seen_applied=1
        ;;
      *) ipv6_state_valid=0 ;;
    esac
  done < "$ipv6_state_file"

  [ "$ipv6_state_valid" = 1 ] || return 1
  [ "$ipv6_seen_ra" = 1 ] || return 1
  [ "$ipv6_seen_dhcpv6" = 1 ] || return 1
  [ "$ipv6_seen_ndp" = 1 ] || return 1
  [ "$ipv6_seen_applied" = 1 ] || return 1
  ipv6_mode_is_supported "$ipv6_restore_ra" || return 1
  ipv6_mode_is_supported "$ipv6_restore_dhcpv6" || return 1
  ipv6_mode_is_supported "$ipv6_restore_ndp" || return 1
  case "$ipv6_restore_applied" in 0|1) ;; *) return 1 ;; esac
  return 0
}

write_ipv6_restore_state() {
  ipv6_state_dir=${ipv6_state_file%/*}
  [ "$ipv6_state_dir" != "$ipv6_state_file" ] || ipv6_state_dir="."
  mkdir -p "$ipv6_state_dir" || return 1
  ipv6_state_tmp="$ipv6_state_file.tmp.$$"
  (
    umask 077
    {
      printf 'ra=%s\n' "$ipv6_restore_ra"
      printf 'dhcpv6=%s\n' "$ipv6_restore_dhcpv6"
      printf 'ndp=%s\n' "$ipv6_restore_ndp"
      printf 'applied=%s\n' "$ipv6_restore_applied"
    } > "$ipv6_state_tmp"
  ) || {
    rm -f "$ipv6_state_tmp"
    return 1
  }
  mv "$ipv6_state_tmp" "$ipv6_state_file"
}

restart_ipv6_advertiser() {
  [ -x "$ipv6_odhcpd_init" ] || return 0
  "$ipv6_odhcpd_init" restart >/dev/null 2>&1
}

disable_lan_ipv6() {
  ipv6_current_ra=$(ipv6_uci_get ra)
  ipv6_current_dhcpv6=$(ipv6_uci_get dhcpv6)
  ipv6_current_ndp=$(ipv6_uci_get ndp)
  for ipv6_mode in "$ipv6_current_ra" "$ipv6_current_dhcpv6" "$ipv6_current_ndp"; do
    if ! ipv6_mode_is_supported "$ipv6_mode"; then
      ipv6_log "неизвестный ручной режим IPv6 '$ipv6_mode'; настройки LAN оставлены без изменений"
      return 1
    fi
  done

  if [ -f "$ipv6_state_file" ]; then
    if ! read_ipv6_restore_state; then
      ipv6_log "файл восстановления IPv6 повреждён; настройки LAN оставлены без изменений"
      return 1
    fi
  else
    if [ "$ipv6_current_ra" = disabled ] \
       && [ "$ipv6_current_dhcpv6" = disabled ] \
       && [ "$ipv6_current_ndp" = disabled ]; then
      # An already-disabled setup belongs to the operator, not this controller.
      return 0
    fi
    ipv6_restore_ra="$ipv6_current_ra"
    ipv6_restore_dhcpv6="$ipv6_current_dhcpv6"
    ipv6_restore_ndp="$ipv6_current_ndp"
    ipv6_restore_applied=0
  fi

  ipv6_needs_config=0
  if [ "$ipv6_current_ra" != disabled ]; then
    ipv6_restore_ra="$ipv6_current_ra"
    ipv6_needs_config=1
  fi
  if [ "$ipv6_current_dhcpv6" != disabled ]; then
    ipv6_restore_dhcpv6="$ipv6_current_dhcpv6"
    ipv6_needs_config=1
  fi
  if [ "$ipv6_current_ndp" != disabled ]; then
    ipv6_restore_ndp="$ipv6_current_ndp"
    ipv6_needs_config=1
  fi
  if [ "$ipv6_needs_config" = 1 ]; then
    # A hand edit during an outage becomes the value restored after recovery.
    ipv6_restore_applied=0
    write_ipv6_restore_state || return 1
  fi

  ipv6_set_failed=0
  if [ "$ipv6_current_ra" != disabled ]; then
    uci -q set dhcp.lan.ra=disabled >/dev/null 2>&1 || ipv6_set_failed=1
  fi
  if [ "$ipv6_current_dhcpv6" != disabled ]; then
    uci -q set dhcp.lan.dhcpv6=disabled >/dev/null 2>&1 || ipv6_set_failed=1
  fi
  if [ "$ipv6_current_ndp" != disabled ]; then
    uci -q set dhcp.lan.ndp=disabled >/dev/null 2>&1 || ipv6_set_failed=1
  fi
  [ "$ipv6_set_failed" = 0 ] || return 1

  if [ "$ipv6_needs_config" = 1 ] || [ "$ipv6_restore_applied" != 1 ]; then
    uci -q commit dhcp >/dev/null 2>&1 || return 1
    restart_ipv6_advertiser || return 1
    ipv6_restore_applied=1
    write_ipv6_restore_state || return 1
    ipv6_log "IPv6-аплинка нет; RA, DHCPv6 и NDP в LAN отключены"
  fi
  return 0
}

restore_lan_ipv6() {
  [ -f "$ipv6_state_file" ] || return 0
  if ! read_ipv6_restore_state; then
    ipv6_log "файл восстановления IPv6 повреждён; ручные настройки не перезаписаны"
    return 1
  fi

  ipv6_current_ra=$(ipv6_uci_get ra)
  ipv6_current_dhcpv6=$(ipv6_uci_get dhcpv6)
  ipv6_current_ndp=$(ipv6_uci_get ndp)
  ipv6_restore_changed=0
  ipv6_restore_failed=0

  if [ "$ipv6_current_ra" = disabled ] && [ "$ipv6_restore_ra" != disabled ]; then
    if [ "$ipv6_restore_ra" = __unset__ ]; then
      uci -q delete dhcp.lan.ra >/dev/null 2>&1 || ipv6_restore_failed=1
    else
      uci -q set "dhcp.lan.ra=$ipv6_restore_ra" >/dev/null 2>&1 || ipv6_restore_failed=1
    fi
    ipv6_restore_changed=1
  fi
  if [ "$ipv6_current_dhcpv6" = disabled ] && [ "$ipv6_restore_dhcpv6" != disabled ]; then
    if [ "$ipv6_restore_dhcpv6" = __unset__ ]; then
      uci -q delete dhcp.lan.dhcpv6 >/dev/null 2>&1 || ipv6_restore_failed=1
    else
      uci -q set "dhcp.lan.dhcpv6=$ipv6_restore_dhcpv6" >/dev/null 2>&1 || ipv6_restore_failed=1
    fi
    ipv6_restore_changed=1
  fi
  if [ "$ipv6_current_ndp" = disabled ] && [ "$ipv6_restore_ndp" != disabled ]; then
    if [ "$ipv6_restore_ndp" = __unset__ ]; then
      uci -q delete dhcp.lan.ndp >/dev/null 2>&1 || ipv6_restore_failed=1
    else
      uci -q set "dhcp.lan.ndp=$ipv6_restore_ndp" >/dev/null 2>&1 || ipv6_restore_failed=1
    fi
    ipv6_restore_changed=1
  fi
  [ "$ipv6_restore_failed" = 0 ] || return 1

  if [ "$ipv6_restore_changed" = 1 ]; then
    uci -q commit dhcp >/dev/null 2>&1 || return 1
  fi
  # Retry a previously failed daemon apply even if UCI already has the values.
  restart_ipv6_advertiser || return 1
  rm -f "$ipv6_state_file" || return 1
  ipv6_log "IPv6-аплинк появился; прежние настройки LAN восстановлены"
  return 0
}

# A main-table forwarding default is the decisive signal. A global WAN address
# without a default cannot reach the internet, while DHCPv6-PD may legitimately
# use a link-local next hop, so requiring a global address would disable working
# provider IPv6. Netlink errors are indeterminate and must never disable LAN v6.
ipv6_default_route_state() {
  ipv6_routes=$(ip -6 route show default 2>/dev/null) || return 2
  printf '%s\n' "$ipv6_routes" | grep -q '^default[[:space:]]'
}

reevaluate_lan_ipv6() {
  command -v uci >/dev/null 2>&1 || return 0
  if ipv6_default_route_state; then
    restore_lan_ipv6
    return $?
  else
    ipv6_route_status=$?
  fi
  if [ "$ipv6_route_status" = 1 ]; then
    disable_lan_ipv6
    return $?
  fi
  ipv6_log "не удалось проверить IPv6-маршрут; настройки LAN оставлены без изменений"
  return 0
}

if [ "${1:-}" = "--ipv6" ]; then
  reevaluate_lan_ipv6
  exit $?
fi
if [ "${1:-}" = "--ipv6-restore" ]; then
  command -v uci >/dev/null 2>&1 || exit 0
  restore_lan_ipv6
  exit $?
fi

# procd runs this mode continuously. HTTP probes have bounded deadlines and
# each check is a child process, so a failed check cannot exit the recovery
# loop. Thirty 20-second ticks preserve the full audit's ten-minute cadence.
# Persistent failures back off restart attempts while healthy ticks stay fast.
if [ "${1:-}" = "--loop" ]; then
  check_interval=20
  full_audit_ticks=30
  max_failure_backoff=300
  check_count=0
  consecutive_failures=0
  while :; do
    check_count=$((check_count + 1))
    check_mode="--once"
    if [ "$check_count" -ge "$full_audit_ticks" ]; then
      check_mode="--full"
      check_count=0
    fi

    if "$0" "$check_mode"; then
      consecutive_failures=0
      next_delay="$check_interval"
    else
      consecutive_failures=$((consecutive_failures + 1))
      backoff_steps="$consecutive_failures"
      next_delay="$check_interval"
      while [ "$backoff_steps" -gt 0 ] && [ "$next_delay" -lt "$max_failure_backoff" ]; do
        next_delay=$((next_delay * 2))
        [ "$next_delay" -le "$max_failure_backoff" ] || next_delay="$max_failure_backoff"
        backoff_steps=$((backoff_steps - 1))
      done
    fi

    sleep "$next_delay" || true
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
    curl -fsS -m 2 "$url" >/dev/null 2>&1
    return $?
  fi
  wget -q --timeout=2 -O- "$url" >/dev/null 2>&1
}

panel_ok() {
  http_ok "$1"
}

restart_service() {
  svc="$1"
  reason="$2"
  log "$svc unhealthy: $reason; restarting"
  /etc/init.d/"$svc" restart >/dev/null 2>&1 || /etc/init.d/"$svc" start >/dev/null 2>&1 || true
}

# Kill only the unhealthy API instance. Restarting /etc/init.d/space-link here
# would also kill this watchdog and can resurrect a service an administrator
# deliberately stopped. SIGKILL avoids waiting for the API's 10-second graceful
# shutdown timeout when its HTTP server is already wedged; procd owns respawn.
restart_api() {
  reason="$1"
  log "space-link-api unhealthy: $reason; requesting API instance restart"
  if command -v ubus >/dev/null 2>&1 \
     && ubus call service signal '{"name":"space-link","instance":"api","signal":9}' >/dev/null 2>&1; then
    return 0
  fi
  if command -v killall >/dev/null 2>&1 \
     && killall -KILL space-link-api >/dev/null 2>&1; then
    return 0
  fi
  log "could not signal the space-link API process"
  return 1
}
# network.lan.ipaddr is authoritative. Every persisted panel consumer is
# rewritten from the .2 address in that live /24 during a full audit.
panel_target_from_lan() {
  panel_lan_raw="$(uci -q get network.lan.ipaddr 2>/dev/null)" || return 1
  panel_lan_ip="$(printf '%s\n' "$panel_lan_raw" | awk '{ print $1; exit }' | cut -d/ -f1)"
  printf '%s\n' "$panel_lan_ip" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9][0-9]*$/ || $i < 0 || $i > 255) {
          exit 1
        }
      }
      printf "%d.%d.%d.2\n", $1, $2, $3
    }
  '
}

panel_remember_managed_alias() {
  panel_candidate="${1:-}"
  case "$panel_candidate" in
    ''|*[!0-9.]*|*.*.*.*.*) return 0 ;;
    *.*.*.2) ;;
    *) return 0 ;;
  esac
  case " $panel_managed_aliases " in
    *" $panel_candidate "*) ;;
    *) panel_managed_aliases="${panel_managed_aliases:+$panel_managed_aliases }$panel_candidate" ;;
  esac
}

panel_collect_managed_aliases() {
  panel_managed_aliases=""
  if [ -f "$panel_hotplug_file" ]; then
    for panel_candidate in $(sed -n 's|.*ip addr add "\([0-9][0-9.]*\)/24".*|\1|p' "$panel_hotplug_file" 2>/dev/null); do
      panel_remember_managed_alias "$panel_candidate"
    done
  fi
  if [ -f "$panel_hosts_file" ]; then
    for panel_candidate in $(awk '
      {
        managed = ($0 ~ /# space-link-panel[[:space:]]*$/)
        for (i = 2; i <= NF; i++) {
          if ($i == "my.space" || $i == "my.sapce" ||
              $i == "my.spacelink" || $i == "spacelink.lan" ||
              $i == "panel.home.arpa") {
            managed = 1
          }
        }
        if (managed) print $1
      }
    ' "$panel_hosts_file" 2>/dev/null); do
      panel_remember_managed_alias "$panel_candidate"
    done
  fi
  if [ -f "$panel_lighttpd_conf" ]; then
    panel_candidate="$(awk -F'"' '/server.bind/ { print $2; exit }' "$panel_lighttpd_conf" 2>/dev/null)"
    panel_remember_managed_alias "$panel_candidate"
  fi
  if command -v uci >/dev/null 2>&1; then
    for panel_record in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true); do
      case "$panel_record" in
        */my.space/*|*/my.sapce/*|*/my.spacelink/*|*/spacelink.lan/*|*/panel.home.arpa/*)
          panel_remember_managed_alias "${panel_record##*/}"
          ;;
      esac
    done
  fi
}

# Return 0 when replaced, 1 when already identical, and 2 on write failure.
panel_replace_file() {
  panel_candidate_file="$1"
  panel_destination_file="$2"
  if [ -f "$panel_destination_file" ] \
     && cmp -s "$panel_candidate_file" "$panel_destination_file" 2>/dev/null; then
    rm -f "$panel_candidate_file"
    return 1
  fi
  if mv "$panel_candidate_file" "$panel_destination_file"; then
    return 0
  fi
  rm -f "$panel_candidate_file"
  return 2
}

panel_write_hosts() {
  [ -f "$panel_hosts_file" ] || return 0
  panel_tmp="${panel_hosts_file}.space-link.$$"
  if ! awk '
    /# space-link-panel[[:space:]]*$/ { next }
    {
      owned = 0
      kept = 0
      rebuilt = $1
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "#") {
          for (j = i; j <= NF; j++) rebuilt = rebuilt " " $j
          break
        }
        if ($i == "my.space" || $i == "my.sapce" ||
            $i == "my.spacelink" || $i == "spacelink.lan" ||
            $i == "panel.home.arpa") {
          owned = 1
          continue
        }
        rebuilt = rebuilt " " $i
        kept = 1
      }
      if (owned) {
        if (kept) print rebuilt
        next
      }
      print
    }
  ' "$panel_hosts_file" > "$panel_tmp"; then
    rm -f "$panel_tmp"
    return 1
  fi
  printf '%s my.space my.sapce panel.home.arpa # space-link-panel\n' "$panel_target" >> "$panel_tmp"
  if panel_replace_file "$panel_tmp" "$panel_hosts_file"; then
    panel_files_changed=1
  else
    panel_replace_status=$?
    [ "$panel_replace_status" = "1" ] || return 1
  fi
}

panel_write_lighttpd_bind() {
  [ -f "$panel_lighttpd_conf" ] || return 0
  panel_tmp="${panel_lighttpd_conf}.space-link.$$"
  if ! awk -v target="$panel_target" '
    BEGIN { written = 0 }
    /^[[:space:]]*server\.bind[[:space:]]*=/ {
      if (!written) print "server.bind = \"" target "\""
      written = 1
      next
    }
    { print }
    END {
      if (!written) print "server.bind = \"" target "\""
    }
  ' "$panel_lighttpd_conf" > "$panel_tmp"; then
    rm -f "$panel_tmp"
    return 1
  fi
  if panel_replace_file "$panel_tmp" "$panel_lighttpd_conf"; then
    panel_files_changed=1
    panel_restart_lighttpd=1
  else
    panel_replace_status=$?
    [ "$panel_replace_status" = "1" ] || return 1
  fi
}

panel_write_hotplug() {
  panel_hotplug_dir="${panel_hotplug_file%/*}"
  [ "$panel_hotplug_dir" != "$panel_hotplug_file" ] || panel_hotplug_dir="."
  mkdir -p "$panel_hotplug_dir" || return 1
  panel_tmp="${panel_hotplug_file}.space-link.$$"
  cat > "$panel_tmp" <<PANEL_HOTPLUG
#!/bin/sh
[ "\${ACTION:-}" = "ifup" ] || exit 0
[ "\${INTERFACE:-}" = "lan" ] || exit 0
ip addr show br-lan 2>/dev/null | grep -Fq "inet $panel_target/" \
  || ip addr add "$panel_target/24" dev br-lan 2>/dev/null || true
PANEL_HOTPLUG
  chmod 0755 "$panel_tmp" || { rm -f "$panel_tmp"; return 1; }
  if panel_replace_file "$panel_tmp" "$panel_hotplug_file"; then
    panel_files_changed=1
  else
    panel_replace_status=$?
    [ "$panel_replace_status" = "1" ] || return 1
    chmod 0755 "$panel_hotplug_file" 2>/dev/null || true
  fi
}

panel_sync_address() {
  panel_target="$(panel_target_from_lan)" || {
    log "cannot derive panel address from network.lan.ipaddr; retaining current address"
    return 1
  }
  panel_router_raw="$(uci -q get network.lan.ipaddr 2>/dev/null)" || return 1
  panel_router_ip="$(printf '%s\n' "$panel_router_raw" | awk '{ print $1; exit }' | cut -d/ -f1)"
  panel_collect_managed_aliases

  if ! ip addr show br-lan 2>/dev/null | grep -Fq "inet $panel_target/"; then
    ip addr add "$panel_target/24" dev br-lan 2>/dev/null || true
    if ! ip addr show br-lan 2>/dev/null | grep -Fq "inet $panel_target/"; then
      log "cannot add panel address $panel_target to br-lan; retaining current address"
      return 1
    fi
    panel_restart_lighttpd=1
  fi

  panel_files_changed=0
  panel_write_hosts || return 1
  panel_write_lighttpd_bind || return 1
  panel_write_hotplug || return 1

  for panel_stale in $panel_managed_aliases; do
    [ "$panel_stale" = "$panel_target" ] && continue
    [ "$panel_stale" = "$panel_router_ip" ] && continue
    if ip addr show br-lan 2>/dev/null | grep -Fq "inet $panel_stale/"; then
      ip addr del "$panel_stale/24" dev br-lan 2>/dev/null || true
    fi
  done

  if [ "$panel_files_changed" = "1" ]; then
    rm -f "$panel_target_cache"
    # /etc/hosts is only parsed by dnsmasq at startup, so the new panel
    # address stays invisible to every LAN client until dnsmasq is told to
    # re-read it. Without this the audit fixes the files and the name still
    # resolves to the previous prefix.
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 \
      || /etc/init.d/dnsmasq restart >/dev/null 2>&1 \
      || true
    log "panel address synchronized to $panel_target from network.lan.ipaddr"
  fi
  return 0
}



panel_restart_lighttpd=0
if [ "${1:-}" = "--full" ] && command -v uci >/dev/null 2>&1; then
  panel_sync_address || log "panel address audit could not converge"
fi

conf="$panel_lighttpd_conf"
target_cache="$panel_target_cache"
bind=""
port=""
# Config parsing needs two awk processes, so reuse the RAM-backed result on the
# 29 cheap ticks between full audits. A full audit refreshes it from lighttpd.
if [ "${1:-}" != "--full" ] && [ -r "$target_cache" ]; then
  {
    IFS= read -r bind || bind=""
    IFS= read -r port || port=""
  } < "$target_cache"
fi
if [ -z "$bind" ] || [ -z "$port" ]; then
  bind="$(awk -F'"' '/server.bind/ { print $2; exit }' "$conf" 2>/dev/null)"
  port="$(awk '/server.port/ { print $3; exit }' "$conf" 2>/dev/null)"
  [ -n "$bind" ] || bind="$(uci -q get network.lan.ipaddr 2>/dev/null | awk '{ print $1; exit }' | cut -d/ -f1)"
  [ -n "$bind" ] || bind="192.168.1.1"
  [ -n "$port" ] || port="80"
  printf '%s\n%s\n' "$bind" "$port" > "$target_cache"
fi
panel_url="http://$bind:$port/"
[ "$port" = "80" ] && panel_url="http://$bind/"

# A static index alone can look healthy while its proxied API is wedged. Probe
# both loopback API and lighttpd on every cheap tick. Each HTTP request has its
# own two-second deadline, and the functional panel probe is authoritative:
# a process-name false negative must never trigger a restart storm.
api_url="http://127.0.0.1:8080/api/local/status"
api_healthy=0
panel_healthy=0
lighttpd_restarted=0
if [ "$panel_restart_lighttpd" = "1" ]; then
  restart_service lighttpd "panel address changed to $bind"
  lighttpd_restarted=1
  sleep 2
fi
http_ok "$api_url" && api_healthy=1
panel_ok "$panel_url" && panel_healthy=1
if [ "${1:-}" != "--full" ] \
   && [ "$api_healthy" = "1" ] \
   && [ "$panel_healthy" = "1" ]; then
  exit 0
fi

if [ "$api_healthy" != "1" ]; then
  restart_api "loopback HTTP check failed ($api_url)" || true
  sleep 2
  if http_ok "$api_url"; then
    api_healthy=1
  else
    log "space-link API still not reachable after restart request"
  fi
fi

# Secondary-IP self-heal: панель слушает на $bind (напр. 192.168.1.2). После
# ребута netifd иногда не поднимает второй адрес вовремя (или lighttpd стартует
# раньше него) → .1.2 недоступен и панель/домен мертвы, хотя VPN работает. Если
# $bind не на br-lan — поднимаем напрямую (не рвёт сеть) и рестартуем lighttpd.
case "$bind" in
  127.*|"") ;;
  *)
    if ! ip addr show br-lan 2>/dev/null | grep -Fq "inet $bind/"; then
      log "панельный IP $bind не поднят на br-lan — добавляю и перезапускаю lighttpd"
      ip addr add "$bind/24" dev br-lan 2>/dev/null || true
      restart_service lighttpd "panel IP $bind was missing after boot"
      lighttpd_restarted=1
      sleep 2
    fi
    ;;
esac

if [ "$lighttpd_restarted" != "1" ] && [ "$panel_healthy" != "1" ]; then
  restart_service lighttpd "panel http check failed ($panel_url)"
  lighttpd_restarted=1
  sleep 2
fi

# Re-probe only after a recovery action. A healthy full audit reuses the probe
# above instead of curling the same panel twice. HTTP success proves both that
# lighttpd is alive and that it serves the configured address.
if [ "$lighttpd_restarted" = "1" ]; then
  if panel_ok "$panel_url"; then
    panel_healthy=1
  else
    panel_healthy=0
    log "panel still not reachable after lighttpd restart ($panel_url)"
  fi
fi

# Only the alias audit below is reserved for the scheduled full tick: it shells
# out to nslookup several times and may rewrite UCI, which is too much to run
# every twenty seconds. The protected-DNS and TPROXY self-heals further down
# stay on every tick — they are two cheap status checks, and before this split
# they ran once a minute. Making them ten times rarer would have traded a
# faster panel for a slower recovery of the thing people actually notice: no
# names resolving, or traffic quietly leaving the tunnel.
if [ "${1:-}" = "--full" ]; then
  # One route lookup plus three UCI reads every ten minutes on IPv4-only WANs;
  # steady state never commits flash or restarts odhcpd.
  reevaluate_lan_ipv6 || log "не удалось синхронизировать IPv6 LAN с аплинком"
fi

if [ "${1:-}" = "--full" ] && command -v uci >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
  aliases_ok=1
  canonical_ip=0
  canonical_local=0
  typo_ip=0
  typo_local=0
  home_ip=0
  home_local=0
  addrs="$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)"
  for a in $addrs; do
    case "$a" in
      "/my.space/$bind") canonical_ip=$((canonical_ip + 1)) ;;
      "/my.space/") canonical_local=$((canonical_local + 1)) ;;
      "/my.sapce/$bind") typo_ip=$((typo_ip + 1)) ;;
      "/my.sapce/") typo_local=$((typo_local + 1)) ;;
      "/panel.home.arpa/$bind") home_ip=$((home_ip + 1)) ;;
      "/panel.home.arpa/") home_local=$((home_local + 1)) ;;
      */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*|*/panel.home.arpa/*) aliases_ok=0 ;;
    esac
  done
  [ "$canonical_ip" = "1" ] || aliases_ok=0
  [ "$canonical_local" = "1" ] || aliases_ok=0
  [ "$typo_ip" = "1" ] || aliases_ok=0
  [ "$typo_local" = "1" ] || aliases_ok=0
  [ "$home_ip" = "1" ] || aliases_ok=0
  [ "$home_local" = "1" ] || aliases_ok=0
  for host in my.space my.sapce panel.home.arpa; do
    nslookup "$host" 127.0.0.1 2>/dev/null | grep -Fq "$bind" || aliases_ok=0
  done
  if [ "$aliases_ok" != "1" ]; then
    log "panel DNS aliases are stale or non-authoritative; normalizing to $bind"
    for a in $addrs; do
      case "$a" in
        */my.space/*|*/my.sapce/*|*/spacelink.lan/*|*/my.spacelink/*|*/panel.home.arpa/*)
          uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true
          ;;
      esac
    done
    uci -q add_list dhcp.@dnsmasq[0].address="/my.space/$bind" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.space/" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/$bind" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/my.sapce/" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/panel.home.arpa/$bind" >/dev/null 2>&1 || true
    uci -q add_list dhcp.@dnsmasq[0].address="/panel.home.arpa/" >/dev/null 2>&1 || true
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
# Without the table, active VPN traffic leaks directly. The ten-minute full
# audit rebuilds interception without adding work to every light panel tick.
# BusyBox pgrep -x checks full argv; pidof checks the exact executable name.
if [ -s /etc/space-link/active-server ] && pidof sing-box >/dev/null 2>&1 \
   && ! grep -q '"active":[[:space:]]*true' /etc/space-link/watchdog.json 2>/dev/null; then
  if command -v nft >/dev/null 2>&1 && ! nft list table inet space_link >/dev/null 2>&1; then
    log "TPROXY-таблица пропала при активном сервере — переподнимаю заворот трафика"
    /etc/init.d/space-link-tproxy start >/dev/null 2>&1 || /etc/init.d/space-link-tproxy reload >/dev/null 2>&1 || true
  fi
fi

# DNS pinning self-heal, fail-open. The redirect funnels every LAN query into
# our resolver, so a dead dnsmasq would take the whole network's DNS with it.
# Drop the redirect while the resolver is silent, restore it once it answers.
if command -v nft >/dev/null 2>&1; then
  resolver_ok=0
  if command -v nslookup >/dev/null 2>&1; then
    nslookup my.space 127.0.0.1 >/dev/null 2>&1 && resolver_ok=1
  elif pidof dnsmasq >/dev/null 2>&1; then
    resolver_ok=1
  fi
  if [ "$resolver_ok" = "1" ]; then
    if [ -f /etc/space-link/dns-pinning.nft ] \
       && ! nft list table inet space_link_dns >/dev/null 2>&1; then
      log "перехват DNS пропал — возвращаю локальные имена для сети"
      nft -f /etc/space-link/dns-pinning.nft >/dev/null 2>&1 || true
    fi
  elif nft list table inet space_link_dns >/dev/null 2>&1; then
    log "локальный DNS молчит — снимаю перехват, чтобы сеть не осталась без имён"
    nft delete table inet space_link_dns >/dev/null 2>&1 || true
  fi
fi

[ "$api_healthy" = "1" ] \
  && [ "$panel_healthy" = "1" ] \
  && exit 0
exit 1
WATCHDOG
  chmod 0755 /usr/bin/space-link-panel-watchdog
  if /usr/bin/space-link-panel-watchdog --ipv6; then
    ok "IPv6 LAN соответствует доступности аплинка"
  else
    warn "не удалось применить режим IPv6 LAN — watchdog повторит проверку"
  fi
  ok "panel watchdog"
}

# ---- heartbeat cron --------------------------------------------------------
install_cron() {
  step "Установка cron для heartbeat"
  heartbeat_line="*/5 * * * * /usr/bin/wget -q -O- http://127.0.0.1:8080/api/local/status >/dev/null 2>&1 # space-link-heartbeat"
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
  printf '%s\n' "$heartbeat_line" >> "$cron_tmp"

  # Prefer the platform frontend, but never trust only its exit code. The
  # production failure that motivated this check returned success while the
  # root crontab remained empty.
  if command -v crontab >/dev/null 2>&1; then
    crontab "$cron_tmp" >/dev/null 2>&1 || true
  fi
  cron_snapshot="$(crontab -l 2>/dev/null || cat "$cron_file" 2>/dev/null || true)"
  if [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$heartbeat_line" || true)" != "1" ]; then
    cp "$cron_tmp" "$cron_file"
    chmod 0600 "$cron_file" 2>/dev/null || true
    cron_snapshot="$(cat "$cron_file" 2>/dev/null || true)"
  fi
  rm -f "$cron_tmp"

  "$cron_init" enable >/dev/null 2>&1 || true
  "$cron_init" restart >/dev/null 2>&1 || true

  if [ "$(printf '%s\n' "$cron_snapshot" | grep -Fxc "$heartbeat_line" || true)" = "1" ]; then
    ok "cron: heartbeat"
  else
    warn "cron не сохранил heartbeat"
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
  if pidof dnsmasq >/dev/null 2>&1; then
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
  if pidof lighttpd >/dev/null 2>&1; then
    printf '   lighttpd:        OK  работает\n'
    http_ok=1
  else
    printf '   lighttpd:        ERR не запущен — панель недоступна\n'
  fi

  if pidof sing-box >/dev/null 2>&1; then
    printf '   sing-box:        OK  работает\n'
  else
    printf '   sing-box:        --  не запущен (норма пока не выбран сервер)\n'
  fi

  if [ "$EFFECTIVE_BIND" = "$router_ip" ]; then
    printf '   LuCI:            --  выключена (мы заняли :80 на %s)\n' "$router_ip"
  elif pidof uhttpd >/dev/null 2>&1; then
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
    # The IP works no matter which DNS the device uses; names can be hijacked
    # by a public resolver, so show the address that always answers first.
    printf '   Установка успешна. Открывай: http://%s%s\n' "$EFFECTIVE_BIND" "$port_suffix"
    printf '   Также работает: http://my.space%s и http://panel.home.arpa%s\n' "$port_suffix" "$port_suffix"
  else
    printf '   Установка завершена с предупреждениями. Запусти %s ещё раз — установщик попробует починить.\n' "$0"
  fi
  printf '\n'
}

# ---- main ------------------------------------------------------------------
trap installer_exit EXIT
banner
printf '   Версия: %s   Режим: %s\n\n' "$VERSION" "$mode"

preflight
prompt_token
acquire_engine_lock
if [ -d "$ACTIVE_INSTALL_DIR" ]; then
  prepare_candidate_runtime
  snapshot_update_state
fi
# Снапшот рабочих конфигов ДО любых правок — для отката если что-то пойдёт не так.
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
backup_uci_state
# Package upgrades may restart sing-box. Remove interception before touching
# packages so LAN remains on direct WAN throughout the entire update window.
disarm_traffic_path
# Если dnsmasq уже лежит от прошлой кривой установки или ручных правок — чиним.
ensure_dnsmasq_alive
install_packages
migrate_from_xray
install_binary
install_ui
install_rules
begin_update_transaction
relocate_lan_subnet
configure_panel_ip
[ "$UPDATE_MODE" = "1" ] || install_update_guard
install_templates
save_state
configure_tproxy
install_panel_watchdog
enable_services
configure_dns
configure_protected_dns
write_panel_hosts
bring_panel_up
apply_dns_pinning
activate_traffic_path
install_cron
restore_dhcp_lease
start_update_guard
final_summary
INSTALL_SUCCESS=1
