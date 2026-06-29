#!/bin/sh
# Space Link Router uninstaller. POSIX sh.
set -eu

STATE_DIR="/etc/space-link"
INSTALL_DIR="/opt/space-link"

printf '==> Останавливаю сервисы\n'
/etc/init.d/space-link stop 2>/dev/null || true
/etc/init.d/space-link disable 2>/dev/null || true
# VPN-движок (с v0.2.0 — sing-box). Сам пакет оставляем установленным, чтобы
# повторная установка прошла без сети, но конфиг и автозапуск выключаем.
/etc/init.d/sing-box stop    2>/dev/null || true
/etc/init.d/sing-box disable 2>/dev/null || true

printf '==> Удаляю файлы\n'
rm -f /etc/init.d/space-link
rm -f /etc/lighttpd/conf.d/space-link.conf
rm -rf /etc/sing-box 2>/dev/null || true
# Артефакты старого xray-движка (v0.1.x) — если роутер апгрейдится с предыдущей
# версии, тоже подметаем. На свежей v0.2.0 уже отсутствуют — rm молча проходит.
rm -rf /etc/xray 2>/dev/null || true
rm -f /usr/bin/geoip.dat /usr/bin/geosite.dat 2>/dev/null || true
rm -rf "$INSTALL_DIR"

# Сохраняем токен по умолчанию — позволяет переустановку без повторного ввода.
if [ "${1:-}" = "--purge" ]; then
  printf '==> --purge: удаляю токен, state и снапшоты\n'
  rm -rf "$STATE_DIR"
fi

printf '==> Снимаю прозрачное проксирование (TPROXY)\n'
TPROXY_MARK="${TPROXY_MARK:-255}"
TPROXY_TABLE="${TPROXY_TABLE:-100}"
# v0.1.14+: standalone init.d + own nft файл вне /etc/nftables.d/.
if [ -x /etc/init.d/space-link-tproxy ]; then
  /etc/init.d/space-link-tproxy stop 2>/dev/null || true
  /etc/init.d/space-link-tproxy disable 2>/dev/null || true
fi
rm -f /etc/init.d/space-link-tproxy 2>/dev/null || true
rm -f /etc/space-link/tproxy.nft 2>/dev/null || true
rm -f /etc/hotplug.d/firewall/99-space-link-tproxy 2>/dev/null || true
# v0.1.13 артефакты — у некоторых пользователей ещё могут остаться.
rm -f /etc/hotplug.d/iface/99-space-link-tproxy 2>/dev/null || true
rm -f /etc/nftables.d/99-space-link-tproxy.nft 2>/dev/null || true
ip rule del fwmark "$TPROXY_MARK" table "$TPROXY_TABLE" 2>/dev/null || true
ip -6 rule del fwmark "$TPROXY_MARK" table "$TPROXY_TABLE" 2>/dev/null || true
ip route flush table "$TPROXY_TABLE" 2>/dev/null || true
ip -6 route flush table "$TPROXY_TABLE" 2>/dev/null || true
# anti-leak тумблеры жили в uci-конфиге space-link (v0.3.0) — снимаем секцию.
if command -v uci >/dev/null 2>&1; then
  uci -q delete space-link.tproxy >/dev/null 2>&1 || true
  uci -q commit space-link >/dev/null 2>&1 || true
fi
if command -v nft >/dev/null 2>&1; then
  nft delete table inet space_link >/dev/null 2>&1 || true
fi
if command -v fw4 >/dev/null 2>&1; then
  fw4 reload >/dev/null 2>&1 || true
fi
if [ -f /etc/iproute2/rt_tables ]; then
  sed -i "/^[[:space:]]*$TPROXY_TABLE[[:space:]]\+space-link/d" /etc/iproute2/rt_tables 2>/dev/null || true
fi

printf '==> Чищу dnsmasq alias (uci + dnsmasq.conf)\n'
if command -v uci >/dev/null 2>&1; then
  addrs=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
  if [ -n "$addrs" ]; then
    for a in $addrs; do
      case "$a" in
        */my.space/*|*/my.spacelink/*|*/spacelink.lan/*)
          uci -q del_list dhcp.@dnsmasq[0].address="$a" >/dev/null 2>&1 || true
          ;;
      esac
    done
    uci -q commit dhcp >/dev/null 2>&1 || true
  fi
fi
if [ -f /etc/dnsmasq.conf ]; then
  sed -i '/^address=\/my\.space\//d' /etc/dnsmasq.conf 2>/dev/null || true
  sed -i '/^address=\/my\.spacelink\//d' /etc/dnsmasq.conf 2>/dev/null || true
  sed -i '/^address=\/spacelink\.lan\//d' /etc/dnsmasq.conf 2>/dev/null || true
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
