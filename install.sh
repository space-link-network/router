#!/bin/sh
# Space Link Router — firmware dispatcher.
#
# Detects what's running on the router (OpenWrt / Keenetic / Padavan / ...)
# and runs the matching installer. Universal entry point — same URL works
# everywhere:
#
#   wget -qO- https://gitlab.com/space-link-vpn/router/-/raw/main/install.sh | sh
#
# Power users can skip the dispatcher and call install-<firmware>.sh directly.
set -eu

INSTALLER_BASE="${INSTALLER_BASE:-https://gitlab.com/space-link-vpn/router/-/raw/main}"

# ---- detection -------------------------------------------------------------
detect_firmware() {
  # OpenWrt / ImmortalWrt
  if [ -f /etc/openwrt_release ]; then
    echo openwrt; return
  fi
  # Keenetic — owns /tmp/system.cfg and (on Entware) /opt/etc/ndm or /opt/bin
  if [ -f /tmp/system.cfg ] || [ -d /opt/etc/ndm ]; then
    echo keenetic; return
  fi
  # Padavan/RT-N56U fork — sysinfo lives in /etc/storage
  if [ -f /etc/storage/started_script.sh ] || grep -qi padavan /etc/firmware_release 2>/dev/null; then
    echo padavan; return
  fi
  # ASUSWRT-Merlin / stock — Asus-specific paths
  if [ -d /jffs/scripts ] && command -v nvram >/dev/null 2>&1; then
    echo asuswrt; return
  fi
  echo unknown
}

# ---- run a remote sub-installer --------------------------------------------
run_sub() {
  fw="$1"; shift
  url="$INSTALLER_BASE/install-$fw.sh"
  printf '==> Прошивка: %s\n' "$fw"
  printf '==> Загрузка %s\n' "$url"

  # When the dispatcher script itself is being piped in (no $0 dir), we need
  # to pipe the sub-installer through sh as well. -s -- forwards CLI args.
  # curl первым — busybox-wget на свежем OpenWrt не умеет HTTPS.
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | sh -s -- "$@"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" | sh -s -- "$@"
  else
    printf 'ERR Нет ни curl, ни wget — нечем скачать установщик.\n' 1>&2
    exit 1
  fi
}

# ---- main ------------------------------------------------------------------
case "${1:-}" in
  --help|-h)
    cat <<EOF
Space Link Router — dispatcher

Универсальный установщик: определит прошивку и вызовет нужный установщик.

Usage:
  install.sh [--force <firmware>] [--token <value>] [--skip-token]
  install.sh --help

Options:
  --force <fw>     Пропустить автодетект и поставить как для <fw>:
                   openwrt | keenetic | padavan | asuswrt
  --token <value>  Передаётся в дочерний установщик.
  --skip-token     Передаётся в дочерний установщик.

Прямые ссылки (если хочешь без dispatcher'а):
  install-openwrt.sh   — для OpenWrt/ImmortalWrt (Netis, GL.iNet, Xiaomi-OW, …)
  install-keenetic.sh  — для Keenetic (KeeneticOS + Entware)   [скоро]
  install-padavan.sh   — для Padavan-форков                    [скоро]
EOF
    exit 0
    ;;
  --force)
    shift
    fw="${1:-}"
    [ -n "$fw" ] || { echo "ERR --force требует имя прошивки" 1>&2; exit 1; }
    shift || true
    run_sub "$fw" "$@"
    exit 0
    ;;
esac

FW=$(detect_firmware)
if [ "$FW" = "unknown" ]; then
  cat 1>&2 <<EOF
ERR Не удалось определить прошивку.

Запусти явно нужный установщик:
  wget -qO- $INSTALLER_BASE/install-openwrt.sh | sh
  wget -qO- $INSTALLER_BASE/install-keenetic.sh | sh

Или, если уверен в прошивке, передай --force:
  install.sh --force openwrt
EOF
  exit 1
fi

run_sub "$FW" "$@"
