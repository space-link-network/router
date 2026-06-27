#!/bin/sh
# Space Link Router uninstaller. POSIX sh.
set -eu

STATE_DIR="/etc/space-link"
INSTALL_DIR="/opt/space-link"

printf '==> Останавливаю сервисы\n'
/etc/init.d/space-link stop 2>/dev/null || true
/etc/init.d/space-link disable 2>/dev/null || true

printf '==> Удаляю файлы\n'
rm -f /etc/init.d/space-link
rm -f /etc/lighttpd/conf.d/space-link.conf
rm -rf "$INSTALL_DIR"

# Сохраняем токен по умолчанию — позволяет переустановку без повторного ввода.
if [ "${1:-}" = "--purge" ]; then
  printf '==> --purge: удаляю токен, state и снапшоты\n'
  rm -rf "$STATE_DIR"
fi

printf '==> Чищу dnsmasq alias (uci + dnsmasq.conf)\n'
if command -v uci >/dev/null 2>&1; then
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  if [ -n "$addrs" ]; then
    for a in $addrs; do
      case "$a" in
        */my.spacelink/*) uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true ;;
      esac
    done
    uci -q commit dhcp >/dev/null 2>&1 || true
  fi
fi
if [ -f /etc/dnsmasq.conf ]; then
  sed -i '/^address=\/my\.spacelink\//d' /etc/dnsmasq.conf 2>/dev/null || true
fi
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

printf '==> Снимаю alias-IP панели (network.lan_panel)\n'
if command -v uci >/dev/null 2>&1; then
  if uci -q get network.lan_panel >/dev/null 2>&1; then
    uci -q delete network.lan_panel >/dev/null 2>&1 || true
    uci -q commit network >/dev/null 2>&1 || true
    service network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
  fi
fi

printf '==> Поднимаю uhttpd (LuCI), если был выключен\n'
/etc/init.d/uhttpd enable >/dev/null 2>&1 || true
/etc/init.d/uhttpd start  >/dev/null 2>&1 || true

printf '==> Чищу cron\n'
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v 'space-link' | crontab - 2>/dev/null || true
fi

/etc/init.d/lighttpd restart >/dev/null 2>&1 || true
printf 'OK  Space Link удалён\n'
