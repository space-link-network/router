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
  printf '==> --purge: удаляю токен и state\n'
  rm -rf "$STATE_DIR"
fi

printf '==> Чищу dnsmasq alias\n'
if [ -f /etc/dnsmasq.conf ]; then
  sed -i '/^address=\/my\.spacelink\//d' /etc/dnsmasq.conf 2>/dev/null || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

printf '==> Чищу cron\n'
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v 'space-link' | crontab - 2>/dev/null || true
fi

/etc/init.d/lighttpd restart >/dev/null 2>&1 || true
printf 'OK  Space Link удалён\n'
