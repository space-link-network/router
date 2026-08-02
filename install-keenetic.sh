#!/bin/sh
# Space Link Router — Keenetic installer (ЭКСПЕРИМЕНТАЛЬНО / TEST BUILD).
#
# ВНИМАНИЕ: это ранний тестовый установщик под KeeneticOS + Entware. Он НЕ
# является поддерживаемой сборкой: часть подсистем (прозрачное проксирование
# через nft tproxy, sing-box capabilities, перехват DNS на dnsmasq роутера)
# на стоке Keenetic недоступна или требует ручной доводки. Скрипт ставит
# панель управления + Go API и честно отмечает, что ещё не работает.
#
# Платформа: KeeneticOS (NDM) + Entware (opkg), пути /opt/*.
#   - init.d:        /opt/etc/init.d/  (rc-стиль Entware, S##name)
#   - конфиги:       /opt/etc/
#   - бинарники:     /opt/bin, /opt/sbin
#   - веб-сервер:    Entware lighttpd/nginx ИЛИ туннелим на :88 (KeeneticOS
#                    держит :80/:443 под своим веб-интерфейсом).
#
# Запуск (через dispatcher install.sh он подхватывается автоматически):
#   wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install-keenetic.sh | sh
set -eu

VERSION="0.3.51"

# ---- Entware paths ---------------------------------------------------------
OPT="/opt"
OPT_ETC="$OPT/etc"
OPT_INITD="$OPT_ETC/init.d"
OPT_BIN="$OPT/bin"
STATE_DIR="$OPT_ETC/space-link"
INSTALL_DIR="$OPT/space-link"
PANEL_PORT="${PANEL_PORT:-88}"   # KeeneticOS держит :80 под своим UI.

RELEASE_BASE="${RELEASE_BASE:-https://gitlab.com/space-link-vpn/router/-/raw/main/dist}"

# ---- pretty print ----------------------------------------------------------
step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    OK  %s\n' "$1"; }
warn() { printf '    !!  %s\n' "$1"; }
die()  { printf '    ERR %s\n' "$1" 1>&2; exit 1; }

experimental_banner() {
  cat <<'BANNER'
  ============================================================
        Space Link Router — Keenetic (ЭКСПЕРИМЕНТАЛЬНО)
  ============================================================
   Это ТЕСТОВАЯ сборка под KeeneticOS + Entware.
   Поддерживается частично — см. список ниже. Панель и Go API
   поставятся, но прозрачный туннель для всех клиентов WiFi
   пока НЕ настраивается автоматически.

   Поддерживается сейчас:
     • установка Go API + веб-панели управления (Entware)
     • ввод/хранение токена подписки
     • просмотр серверов / подписки / маршрутизации (UI)

   ПОКА НЕ поддерживается (coming soon):
     • TPROXY на nft (KeeneticOS использует свой firewall/ndm)
     • sing-box procd capabilities (нет procd — Entware rc-init)
     • перехват DNS роутера (dnsmasq под управлением NDM)
     • alias-домен my.space (нет dnsmasq-address на стоке)

   Для боевого использования ставь на OpenWrt/ImmortalWrt:
     install-openwrt.sh
  ============================================================
BANNER
}

# ---- preflight -------------------------------------------------------------
preflight() {
  step "Проверка окружения Keenetic / Entware"

  # Keenetic-маркеры (совпадают с детектором в dispatcher install.sh).
  if [ ! -f /tmp/system.cfg ] && [ ! -d "$OPT_ETC/ndm" ]; then
    warn "не вижу маркеров Keenetic (/tmp/system.cfg, /opt/etc/ndm)"
    warn "продолжаю, но это может быть не Keenetic — прерви Ctrl-C если ошибся"
  fi

  if [ ! -d "$OPT" ] || ! command -v opkg >/dev/null 2>&1; then
    die "Entware не найден (нет /opt или opkg). Установи Entware на Keenetic
        (USB-накопитель + 'Приложения' в KeeneticOS), затем запусти заново."
  fi
  ok "Entware на месте (opkg доступен)"

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "нет ни curl, ни wget"
  ok "загрузчик есть"
}

fetch() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  else
    wget -qO "$out" "$url"
  fi
}

# ---- packages --------------------------------------------------------------
install_packages() {
  step "Установка пакетов (opkg)"
  opkg update >/dev/null 2>&1 || warn "opkg update не прошёл — пробую дальше с кэшем"
  # lighttpd как reverse-proxy для панели; sing-box — движок (TEST).
  for pkg in ca-certificates lighttpd lighttpd-mod-proxy; do
    opkg install "$pkg" >/dev/null 2>&1 || warn "пакет $pkg не поставился — панель может не подняться"
  done
  # sing-box в Entware может отсутствовать в фиде — отмечаем, не валим.
  opkg install sing-box >/dev/null 2>&1 || warn "sing-box нет в Entware-фиде — движок придётся ставить вручную (TEST)"
  ok "пакеты обработаны"
}

# ---- token -----------------------------------------------------------------
prompt_token() {
  step "Токен подписки"
  TOKEN="${TOKEN:-}"
  # CLI: --token <value> / --skip-token (передаётся из dispatcher).
  while [ $# -gt 0 ]; do
    case "$1" in
      --token) shift; TOKEN="${1:-}";;
      --skip-token) TOKEN="";;
    esac
    shift || true
  done
  if [ -z "$TOKEN" ] && [ -t 0 ]; then
    printf '    Введи токен подписки (Enter — пропустить, задашь в панели): '
    read -r TOKEN || TOKEN=""
  fi
  mkdir -p "$STATE_DIR"
  if [ -n "$TOKEN" ]; then
    umask 077
    printf '%s\n' "$TOKEN" > "$STATE_DIR/token"
    printf 'token\n' > "$STATE_DIR/mode"
    umask 022
    ok "токен сохранён"
  else
    ok "токен не задан — введёшь в панели"
  fi
}

# ---- binary + UI -----------------------------------------------------------
install_binary() {
  step "Установка Go API (TEST)"
  mkdir -p "$INSTALL_DIR" "$OPT_BIN"
  # Keenetic = mipsel/aarch64 в зависимости от модели. Здесь TEST-заглушка:
  # тянем generic-сборку, если её нет в dist — честно предупреждаем.
  if fetch "$RELEASE_BASE/space-link-api" "$OPT_BIN/space-link-api" 2>/dev/null; then
    chmod 0755 "$OPT_BIN/space-link-api"
    ok "space-link-api установлен в $OPT_BIN"
  else
    warn "бинарь space-link-api под Keenetic-арку не найден в dist — TEST-сборка"
    warn "собери под нужную арку (mipsel/aarch64) и положи в $OPT_BIN/space-link-api"
  fi
}

install_ui() {
  step "Установка UI (TEST)"
  mkdir -p "$INSTALL_DIR/ui"
  if fetch "$RELEASE_BASE/ui.tar.gz" "/tmp/sl-ui.tar.gz" 2>/dev/null; then
    tar -xzf /tmp/sl-ui.tar.gz -C "$INSTALL_DIR/ui" 2>/dev/null \
      && ok "UI распакован в $INSTALL_DIR/ui" \
      || warn "не удалось распаковать UI"
    rm -f /tmp/sl-ui.tar.gz
  else
    warn "UI-архив не скачался — панель будет без фронта (TEST)"
  fi
}

# ---- init.d (Entware rc-стиль, НЕ procd) -----------------------------------
install_initd() {
  step "Автозапуск (Entware init.d, TEST)"
  mkdir -p "$OPT_INITD"
  # Entware использует S##/K## rc-скрипты, без procd. Простой обёрткой
  # запускаем Go API в фоне. capabilities/tproxy тут НЕ настраиваются.
  cat > "$OPT_INITD/S99space-link" <<INITD
#!/bin/sh
# Space Link Router — Entware init (TEST). Не procd: без respawn/capabilities.
ENABLED=yes
PROCS=space-link-api
ARGS=""
PREARGS=""
DESC="Space Link Router API (TEST)"
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

start() {
  export STATE_DIR="$STATE_DIR"
  export LISTEN_ADDR="127.0.0.1:8080"
  export SL_UI_DIR="$INSTALL_DIR/ui"
  $OPT_BIN/space-link-api >/tmp/space-link.log 2>&1 &
  echo \$! > /tmp/space-link.pid
}
stop() {
  [ -f /tmp/space-link.pid ] && kill "\$(cat /tmp/space-link.pid)" 2>/dev/null
  rm -f /tmp/space-link.pid
}
case "\$1" in
  start) start;;
  stop)  stop;;
  restart) stop; sleep 1; start;;
  *) echo "usage: \$0 {start|stop|restart}";;
esac
INITD
  chmod 0755 "$OPT_INITD/S99space-link"
  ok "S99space-link создан (rc-init, TEST)"

  step "TPROXY / DNS / sing-box capabilities"
  warn "TPROXY на Keenetic не настраивается этой сборкой (нужен nft-tproxy + свой"
  warn "  firewall-хук вместо ndm). Клиенты WiFi туннель пока не получают — TEST."
  warn "DNS-перехват и alias my.space не настраиваются (dnsmasq под NDM) — TEST."
}

# ---- lighttpd panel --------------------------------------------------------
configure_panel() {
  step "Веб-панель (lighttpd reverse-proxy на :$PANEL_PORT, TEST)"
  conf_dir="$OPT_ETC/lighttpd/conf.d"
  mkdir -p "$conf_dir"
  if [ -f "$INSTALL_DIR/templates/lighttpd.conf" ]; then
    cp "$INSTALL_DIR/templates/lighttpd.conf" "$conf_dir/space-link.conf"
  else
    cat > "$conf_dir/space-link.conf" <<LCONF
# Space Link Router panel (Keenetic TEST). KeeneticOS держит :80 — слушаем :$PANEL_PORT.
server.port = $PANEL_PORT
server.document-root = "$INSTALL_DIR/ui"
server.modules += ( "mod_proxy" )
\$HTTP["url"] =~ "^/api/" {
  proxy.server = ( "" => ( ( "host" => "127.0.0.1", "port" => 8080 ) ) )
}
LCONF
  fi
  ok "панель сконфигурирована на :$PANEL_PORT (TEST)"
  if [ -x "$OPT_INITD/S80lighttpd" ]; then
    "$OPT_INITD/S80lighttpd" restart >/dev/null 2>&1 || warn "lighttpd не перезапустился"
  else
    warn "lighttpd init не найден — запусти веб-сервер вручную"
  fi
}

# ---- summary ---------------------------------------------------------------
summary() {
  router_ip="$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo '<router-ip>')"
  printf '\n'
  printf '%s\n' "============================================================"
  printf '   Space Link Router (Keenetic TEST) — %s\n' "$VERSION"
  printf '%s\n' "============================================================"
  printf '   Панель:   http://%s:%s   (ЭКСПЕРИМЕНТАЛЬНО)\n' "$router_ip" "$PANEL_PORT"
  if [ -n "${TOKEN:-}" ]; then
    printf '   Токен:    сохранён\n'
  else
    printf '   Токен:    не задан — введи в панели\n'
  fi
  printf '%s\n' "------------------------------------------------------------"
  printf '   Статус подсистем:\n'
  printf '     Панель + API .......... установлено (TEST)\n'
  printf '     TPROXY (туннель LAN) .. НЕ настроено (coming soon)\n'
  printf '     DNS-перехват .......... НЕ настроено (coming soon)\n'
  printf '     alias my.space ........ НЕ настроено (coming soon)\n'
  printf '%s\n' "------------------------------------------------------------"
  printf '   Для полноценной работы используй OpenWrt-сборку:\n'
  printf '     install-openwrt.sh\n'
  printf '%s\n\n' "============================================================"
}

# ---- main ------------------------------------------------------------------
experimental_banner
preflight
prompt_token "$@"
install_packages
install_binary
install_ui
install_initd
configure_panel
"$OPT_INITD/S99space-link" start >/dev/null 2>&1 || warn "space-link-api не стартовал (TEST)"
summary
