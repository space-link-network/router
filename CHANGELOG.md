# Changelog

Все заметные изменения проекта документируются здесь.
Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версионирование — [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

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
