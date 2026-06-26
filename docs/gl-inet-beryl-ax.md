# GL.iNet Beryl AX (MT3000) — Space Link

> Заглушка. Полная инструкция будет добавлена в одном из следующих релизов.

Beryl AX (MT3000) идёт со стоковой прошивкой на базе OpenWrt — менять её не обязательно.

## Быстрый старт

1. Открой админку: `http://192.168.8.1`.
2. Сменипароль, обнови прошивку до последней (System → Upgrade).
3. Включи SSH (System → Administration → SSH), задай root-пароль.
4. По SSH:
   ```sh
   wget -qO- https://raw.githubusercontent.com/space-link/space-link-router/main/install.sh | sh
   ```
5. Открой `http://my.spacelink` (или `http://192.168.8.1:81` если 80-й порт занят GL.iNet GUI).

## Известные проблемы

- 80-й порт занят родной GL-панелью. Возможно понадобится изменить порт lighttpd на 81 в `/etc/lighttpd/conf.d/space-link.conf` после установки.
- Реклама будет отображаться этим документом как «в работе» до выпуска полного гайда.

## Запросить инструкцию

Если ты установил Space Link на Beryl AX и всё работает — пришли скриншоты в [@spacelink_support](https://t.me/spacelink_support), мы дополним этот документ.
