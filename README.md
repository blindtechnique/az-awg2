<div align="center">

# AntiZapret-AWG 2.0

**AntiZapret с настоящим AmneziaWG 2.0 вместо ванильного WireGuard под маской.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![AmneziaWG](https://img.shields.io/badge/AmneziaWG-2.0-2ea44f)](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
[![OS](https://img.shields.io/badge/Ubuntu%2024.04%2B%20%C2%B7%20Debian%2012%2B-e95420?logo=ubuntu&logoColor=white)](#требования)
[![Bash](https://img.shields.io/badge/bash-4EAA25?logo=gnubash&logoColor=white)](#)
[![Telegram bot](https://img.shields.io/badge/Telegram-бот-26A5E4?logo=telegram&logoColor=white)](#telegram-бот)
[![Based on AntiZapret-VPN](https://img.shields.io/badge/based%20on-AntiZapret--VPN-555)](https://github.com/GubernievS/AntiZapret-VPN)

Установка в два шага. Клиенты и статистика — из Telegram. OpenVPN на месте.

</div>

---

## Зачем это

Стоковый [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) заявляет AmneziaWG, но под капотом поднимает обычный WireGuard: порты «amnezia» просто редиректятся на ванильный `wg`, а сам handshake остаётся стандартным (`H1..H4 = 1,2,3,4`, `S1=S2=0`). Для фильтров это по-прежнему обычный WireGuard.

Этот форк ставит **настоящий AmneziaWG 2.0**: рандомные заголовки, junk-префиксы, обфускация транспортных пакетов и мимикрия под QUIC/TLS/DNS. Всё остальное от AntiZapret работает как раньше — OpenVPN, раздельная маршрутизация, свой DNS, WARP, fake-IP.

## Что внутри

- **Настоящий AmneziaWG 2.0** — kernel-модуль через официальный PPA, обфускация в `[Interface]`, а не косметика поверх WireGuard.
- **Раздельная маршрутизация (AntiZapret)** — в туннель уходит только заблокированное, остальное идёт напрямую с устройства. Работает и на AmneziaWG, и на OpenVPN.
- **Полный VPN** — отдельный профиль, весь трафик через сервер.
- **Настраиваемая обфускация и мимикрия** — пресеты интенсивности, шаблоны под QUIC/TLS/DNS/VoIP, выбор MTU и домена мимикрии при установке.
- **Клиенты в один тап** — `.conf`, QR и `vpn://`-ссылка для приложения Amnezia. OpenVPN тоже отдаётся `.ovpn`.
- **Временные клиенты** с автоудалением по TTL.
- **Telegram-бот** — управление клиентами (AmneziaWG + OpenVPN), временные клиенты, статистика с гео, бэкап/восстановление. Всё на кнопках.
- **Статистика** — трафик по клиентам и дням, кто онлайн, история подключений с IP/городом/провайдером.
- **Бэкап одной командой** — OpenVPN PKI, ключи AmneziaWG, конфиги, списки, статистика.
- **Поддержка альтернативных диапазонов** AntiZapret (`172.x`, fake-IP `198.18.x`) — подсети наследуются автоматически.

## Как это работает

```mermaid
flowchart LR
    C["📱 Клиент<br/>AmneziaWG 2.0"] -- "обфусцированный трафик<br/>(мимикрия QUIC/TLS)" --> S

    subgraph S["🖥 Сервер"]
        AWG["awg-quick@antizapret<br/>10.29.8.0/24"]
        R{"Адрес<br/>заблокирован?"}
        AWG --> R
    end

    R -- "да<br/>(списки РКН + DNS)" --> OUT["🌍 Заблокированный ресурс"]
    R -- "нет" --> DROP["⨯ дропается на сервере →<br/>устройство идёт напрямую"]
```

Раздельная маршрутизация завязана на подсети-источники, а не на тип интерфейса, поэтому замена WireGuard → AmneziaWG ничего в ней не меняет. Полный VPN живёт в отдельной подсети (`10.28.x`) с `AllowedIPs = 0.0.0.0/0, ::/0`.

## Требования

- **Ubuntu 24.04+** — рекомендуется, на ней всё протестировано.
- **Debian 12/13** — работает, но best-effort: на самых свежих ядрах DKMS-модуль AmneziaWG иногда не собирается ([upstream issue](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/143)). Если модуль не загрузился — смотри `dkms status` и логи сборки.
- root, чистый сервер (установщик базы перезагружает машину).

## Установка

Форк не ставит базу сам в одном заходе (её `setup.sh` перезагружает сервер) — поэтому два шага.

**Шаг 1. Базовый AntiZapret** (ставит зависимости, перезагружает сервер; заодно обходит [сломанный GPG-ключ OpenVPN](https://github.com/OpenVPN/openvpn/issues/803), из-за которого официальный установщик сейчас падает):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh) --install-base
```

Ответь на вопросы `setup.sh`: WireGuard включи (он станет базой для AmneziaWG), OpenVPN оставь. Сервер перезагрузится.

**Шаг 2. Слой AmneziaWG 2.0** (после перезагрузки, без ребута):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh)
```

Тут выбираешь обфускацию, мимикрию, MTU, домен и ставишь бота. Готово.

> Если AntiZapret уже стоит — сразу запускай Шаг 2.

### Флаги Шага 2

| Флаг | Что делает |
|---|---|
| `--preset high --template web` | обфускация без вопросов |
| `--keep-wireguard` | оставить ванильный WG активным, AmneziaWG на портах 52443/52080 |
| `--no-bot` | не спрашивать про Telegram-бота |
| `--update` | обновить код/бот/самовосстановление **без** смены обфускации и пересборки клиентов — существующие клиенты не ломаются |
| `--reconfigure` | переспросить настройки заново (генерирует **новый** профиль обфускации → клиентам нужно переимпортировать конфиги) |

## Управление

Через бота — или из консоли:

```bash
# AmneziaWG
awg-client add  ivan antizapret          # split-routing → .conf + QR + vpn://
awg-client add  ivan vpn                  # полный туннель
awg-client add  guest antizapret --ttl 6h # временный (30m / 6h / 7d …)
awg-client del  ivan antizapret
awg-client list antizapret

# OpenVPN (штатный скрипт AntiZapret)
/root/antizapret/client.sh 1 ivan 3650    # добавить
/root/antizapret/client.sh 2 ivan         # удалить
/root/antizapret/client.sh 3              # список

# обфускация
awg-obfuscation                           # меню с подсказками
awg-obfuscation --show                     # текущий профиль
awg-obfuscation --regenerate               # новые сигнатуры

# бэкап
awg-backup backup                          # → tar.gz
awg-backup restore файл.tar.gz
```

## Telegram-бот

Одна команда — `/start`, дальше всё кнопками.

```
🔐 AntiZapret-AWG 2.0 · vpn.example.com
├─ 👥 Клиенты
│   ├─ ➕ AmneziaWG (AntiZapret / Полный VPN)
│   ├─ ➕ OpenVPN
│   ├─ ⏳ Временный клиент
│   └─ 📋 Список → клиент → ℹ️ Информация · 📥 Скачать · 🗑 Удалить
├─ ℹ️ Информация      CPU / RAM / диск / аптайм, онлайн, топ-5, трафик
├─ 🛡 Обфускация       показать / перегенерировать
├─ 💾 Бэкап
└─ ♻️ Восстановить     (принимает загруженный .tar.gz)
```

**Информация о клиенте** не сбрасывается и показывает: онлайн-статус, текущий IP с городом и провайдером, историю последних подключений с точной датой/временем, трафик за сессию и всего.

Доступ — только по whitelist `AWG_BOT_ADMINS`. Установка бота встроена в Шаг 2 (спросит токен и chat_id).

<!-- Скриншоты: добавь свои в docs/img/ и вставь сюда, например:
![Меню бота](docs/img/bot-menu.png)
![Инфо о сервере](docs/img/bot-server.png)
-->

## Настройки обфускации

**Пресеты интенсивности:** `router` · `low` · `medium` (по умолчанию) · `high` · `paranoid`.

**Шаблоны мимикрии:** `quic` · `tls` · `web` (QUIC+TLS) · `voip` · `dns` · `mixed`. Выбирай тот протокол, который у твоего провайдера точно ходит.

**MTU:** авто/1320, 1420, 1280 (мобильные) или свой. **Домен мимикрии:** авто из встроенного пула доступных из РФ доменов или свой.

Профиль генерируется один раз и применяется одинаково к серверу и всем клиентам — иначе handshake не пройдёт. При смене профиля клиентские конфиги пересобираются автоматически; их нужно переимпортировать на устройствах.

## Обновление и переустановка

Слой пережил обновление AntiZapret — по крайней мере, старается:

- **Авто-обновление AntiZapret** (по таймеру) качает только списки блокировок и пару скриптов маршрутизации. Наши интерфейсы, обфускацию, конфиги и клиентов оно не трогает — всё работает дальше.
- **Ручной `setup.sh`** делает `rm -rf /root/antizapret`. Чтобы это пережить, всё наше состояние лежит **вне** `/root/antizapret` — в `/opt/antizapret-awg` (overlay, клиенты) и `/etc/amnezia/amneziawg` (серверные ключи и профиль). После такого обновления слой **чинится сам**: юнит `awg-reintegrate.service` на загрузке возвращает наши сервисы, гасит заново включённый ванильный WireGuard, восстанавливает хук в `custom-up.sh`, а в keep-режиме заново убирает вернувшийся редирект портов `52xxx→51xxx`.

Обновить **код** слоя (скрипты, бот, самовосстановление) — без смены обфускации и без пересборки клиентов, существующие клиенты продолжат работать:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh) --update
```

Сменить **настройки** (обфускацию, мимикрию, MTU, домен) — генерирует новый профиль, конфиги придётся переимпортировать на устройствах:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh) --reconfigure
```

## Диагностика

```bash
awg show                                    # интерфейсы, peers, handshake, трафик
systemctl status awg-quick@antizapret
```

| Симптом | Причина / решение |
|---|---|
| нет интерфейса в `awg show` | `awg-quick` не поднялся → `journalctl -u awg-quick@antizapret` |
| `__AWG_OBFUSCATION__` в конфиге | обфускация не применилась → переустанови Шаг 2 |
| peer есть, но нет `latest handshake` | профиль клиента ≠ профиля сервера → переимпортируй свежий конфиг |
| handshake есть, `received` = 0 | блокировка по IP/AS провайдером — смени хостинг/IP или включи WARP |
| `awg-quick: 'vpn' already exists` | `ip link del vpn && systemctl start awg-quick@vpn` |

## На чём основано

- [GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) — база: маршрутизация, OpenVPN, DNS, списки.
- [amnezia-vpn/amneziawg](https://github.com/amnezia-vpn) — сам AmneziaWG 2.0.
- [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) и [Vadim-Khristenko/AmneziaWG-Architect](https://github.com/Vadim-Khristenko/AmneziaWG-Architect) — подходы к установке AWG и генерации мимикрии.

## Лицензия

[GPLv3](LICENSE). Свободно используй, меняй и распространяй — производные тоже остаются открытыми.
