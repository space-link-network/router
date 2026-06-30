# Changelog

Все заметные изменения проекта документируются здесь.
Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версионирование — [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

### Changed
- README переписан как общая документация: процесс установочного скрипта,
  работа в панели, настройка, обновление и удаление.
- Документация разделена: общая (README) + OpenWrt (`docs/openwrt.md`,
  полный процесс прошивки и установки) + Keenetic (`docs/keenetic.md`, заглушка
  «в разработке»).
- Адрес панели в документации унифицирован: `http://my.space/` (+ фоллбэк по IP).
- Установка / обновление / удаление документированы через
  `https://install.space-link.app/…` (gitlab raw — запасной адрес).
- `docs/troubleshooting.md` актуализирован (sing-box вместо xray, раздел
  «Служба соединения», коллизия DNS для `my.space`).

### Removed
- Документы по конкретным моделям (Netis NX32U, GL.iNet Beryl AX) — заменены
  общей документацией и инструкцией по OpenWrt.
- Неиспользуемый `lighttpd.conf` из корня репозитория (конфиг приходит из
  релиза/шаблонов установщиком).
- GitHub Actions workflow (`.github/workflows/ci.yml`) — репозиторий на GitLab,
  workflow не запускался; shell-линт переносится в internal CI.

## [0.1.0] — 2026-06-26

### Added
- Первый MVP-релиз.
- Installer для OpenWrt (POSIX sh, BusyBox-совместимый).
- Локальный API на Go (127.0.0.1:8080) с эндпоинтами для токена, серверов, статуса.
- Веб-панель на Vue 3 + Tailwind (русскоязычная, тёмная тема).
- Поддержка отложенного ввода токена: установка проходит без него, юзер вставляет в UI позже.
- Шаблон xray-config с VLESS+Reality+Vision.
- Routing rules: direct/proxy/block списки доменов.
- DNS-alias `my.spacelink` через dnsmasq.
- Heartbeat в облако по cron каждые 5 минут.
