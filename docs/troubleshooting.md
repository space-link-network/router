# Troubleshooting

## Не открывается `http://my.spacelink`

1. Подключись к роутеру по IP-адресу: `http://192.168.1.1` (или твоему LAN-IP).
2. Если открывается — значит DNS-alias не сработал. Перезапусти dnsmasq:
   ```sh
   /etc/init.d/dnsmasq restart
   ```
3. На клиенте сбрось DNS-кеш (Mac: `sudo dscacheutil -flushcache`).

## Панель открывается, но «токен не задан»

Это нормально, если ты при установке нажал Enter. Зайди в личный кабинет
[app.space-link.app](https://app.space-link.app/routers), скопируй токен,
вставь в форму на `/setup` и нажми «Сохранить».

## Видео не открывается / VPN не работает

1. Открой панель → Dashboard. Смотри секцию «VPN-сервис».
   - Если «Остановлен» — нажми «Перезапустить».
   - Если по-прежнему остановлен — открой логи:
     ```sh
     logread | grep xray
     ```
2. Проверь активный сервер. Сменить можно в разделе «Серверы».
3. Проверь подписку: если статус «frozen» или «expired» — продли в личном кабинете.

## Не хватает места на роутере

Перед установкой убедись, что есть минимум 30 МБ свободно:
```sh
df -h /
```
Если мало — снеси неиспользуемые пакеты:
```sh
opkg list-installed | sort
opkg remove <пакет>
```

## Установщик ругается на «opkg update failed»

Чаще всего это означает, что у роутера нет интернета. Проверь:
```sh
ping -c 3 1.1.1.1
```
Если пинг не идёт — проблема с WAN-настройкой роутера, к Space Link не относится.

## Как полностью удалить

```sh
wget -qO- https://raw.githubusercontent.com/space-link/space-link-router/main/uninstall.sh | sh -s -- --purge
```
Флаг `--purge` снесёт и токен.

## Куда писать, если ничего не помогает

- Telegram: [@spacelink_support](https://t.me/spacelink_support)
- Issue: [github.com/space-link/space-link-router/issues](https://github.com/space-link/space-link-router/issues)

В обращении укажи модель роутера, версию OpenWrt (`cat /etc/openwrt_release`) и вывод:
```sh
logread | tail -50
/etc/init.d/space-link status
```
