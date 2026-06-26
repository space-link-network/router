# Space Link Router

Клиентское ПО для роутеров с OpenWrt: разворачивает VLESS+Reality VPN и даёт удобную панель управления в локальной сети.

## Быстрая установка

Зайди на роутер по SSH и выполни:

```sh
wget -qO- https://get.space-link.app/install.sh | sh
```

Или напрямую из GitHub:

```sh
wget -qO- https://raw.githubusercontent.com/space-link/space-link-router/main/install.sh | sh
```

Установщик спросит токен. Если у тебя его пока нет — просто нажми Enter, настроишь позже через панель (`http://my.spacelink`).

## Что получишь

- VPN-сервис xray-core с актуальной подпиской Space Link
- Веб-панель на `http://my.spacelink`:
    - переключение серверов в один клик
    - статус подписки
    - смена/удаление токена
    - проверка обновлений
- Умная маршрутизация: российские сервисы напрямую, заблокированные через VPN, реклама режется.

## Поддерживаемые роутеры

| Модель | Архитектура | Статус | Прошивка |
| --- | --- | --- | --- |
| Netis NX32U | aarch64 | OK | [инструкция](docs/netis-nx32u.md) |
| GL.iNet Beryl AX (MT3000) | aarch64 | OK | [инструкция](docs/gl-inet-beryl-ax.md) |
| Xiaomi AX3200 | aarch64 | бета | — |
| Любой OpenWrt 23.05+ aarch64/armv7/mipsel | разные | OK | стандарт OpenWrt |

## Где взять токен

Зарегистрируйся и оформи подписку: [app.space-link.app](https://app.space-link.app/routers). В разделе «Роутеры» создай новый — там же будет токен.

## Удаление

```sh
wget -qO- https://raw.githubusercontent.com/space-link/space-link-router/main/uninstall.sh | sh
```

Чтобы стереть всё, включая токен: `... | sh -s -- --purge`.

## Документация

- [Troubleshooting](docs/troubleshooting.md)
- [Netis NX32U](docs/netis-nx32u.md)
- [GL.iNet Beryl AX](docs/gl-inet-beryl-ax.md)

## Поддержка

- Telegram: [@spacelink_support](https://t.me/spacelink_support)
- Email: support@space-link.app

## Лицензия

MIT — см. [LICENSE](LICENSE).
