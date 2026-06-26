# Netis NX32U — установка OpenWrt и Space Link

NX32U — это бюджетный aarch64-роутер на MediaTek MT7981B. Идеально подходит для дома, потянет 200+ Мбит/с через VPN.

## Шаг 1. Прошивка OpenWrt

Заводская прошивка не позволяет ставить сторонние пакеты, поэтому начинаем с OpenWrt.

1. Скачай свежую сборку OpenWrt для NX32U со страницы [openwrt.org/toh/netis/nx32u](https://openwrt.org/toh/start?dataflt%5BModel*~%5D=NX32U) (или с готовой сборкой от 4PDA — поиск «Netis NX32U OpenWrt»).
2. Войди в стоковую веб-панель: `http://192.168.1.1`, логин/пароль на наклейке.
3. Поднимись по сложному, но стандартному пути «Системные настройки → Обновление прошивки» и залей `…-initramfs.bin`. Роутер ребутнётся в OpenWrt LuCI.
4. В LuCI: System → Backup/Flash → Flash image → залей `…-sysupgrade.bin`.

Подробный гайд (с фото и решением частых проблем) — на 4PDA:
[forum.4pda.to → Netis NX32U](https://4pda.to/forum/index.php?showtopic=1097654)

## Шаг 2. Базовая настройка OpenWrt

```sh
ssh root@192.168.1.1
passwd                            # задай root-пароль
opkg update
opkg install curl ca-bundle ca-certificates luci-i18n-base-ru
```

## Шаг 3. Установка Space Link

```sh
wget -qO- https://raw.githubusercontent.com/space-link/space-link-router/main/install.sh | sh
```

Введи токен (или Enter, чтобы пропустить). Дождись финальной плашки.

## Шаг 4. Открой панель

С устройства в сети роутера:

- `http://my.spacelink`
- или `http://192.168.1.1`

Если токена не вводил — на экране появится форма. Вставь токен и нажми «Сохранить». Дальше — выбери сервер на вкладке «Серверы».

## Известные особенности

- При первой загрузке xray может стартовать 10-15 секунд — это норма, прогревает Reality-хэндшейк.
- WiFi-каналы по умолчанию: 5 ГГц = auto, 2.4 ГГц = 6. Меняй в LuCI → Network → Wireless.

## Откат на стоковую прошивку

NX32U поддерживает заводской сброс через 10-секундное удержание Reset, но это **не** возвращает стоковую прошивку. Нужно прошить заводской образ через u-boot recovery — гайд на той же ветке 4PDA.
