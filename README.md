<div align="center">

# AntiZapret-AWG 2.0

**AntiZapret с полноценным AmneziaWG 2.0 — параллельным слоем поверх штатной установки.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![AmneziaWG](https://img.shields.io/badge/AmneziaWG-2.0-2ea44f)](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
[![OS](https://img.shields.io/badge/Ubuntu%2024.04%2B%20%C2%B7%20Debian%2012%2B-e95420?logo=ubuntu&logoColor=white)](#требования)
[![Bash](https://img.shields.io/badge/bash-4EAA25?logo=gnubash&logoColor=white)](#)
[![Telegram bot](https://img.shields.io/badge/Telegram-бот-26A5E4?logo=telegram&logoColor=white)](#telegram-бот)
[![Based on AntiZapret-VPN](https://img.shields.io/badge/based%20on-AntiZapret--VPN-555)](https://github.com/GubernievS/AntiZapret-VPN)

Установка в два шага. Клиенты, статистика и обновления — из Telegram. Штатный AntiZapret не трогается.

</div>

---

## Зачем это

В оригинальном [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) поддержка AmneziaWG сводится к совместимости с существующей инфраструктурой WireGuard: соединение использует обычный WireGuard-handshake, а «AmneziaWG»-конфиги отличаются лишь junk-префиксами. Транспорт при этом остаётся распознаваемым.

Форк добавляет **полноценный AmneziaWG 2.0** с собственным транспортом — рандомизированные заголовки, обфускация транспортных пакетов, мимикрия под QUIC/TLS/DNS. Ключевое отличие от прежних версий: слой работает **параллельно** штатному AntiZapret, а не вместо него. Оригинальные WireGuard-интерфейсы, порты, `client.sh`, DNS и правила маршрутизации не изменяются ни на байт — слой поднимает свои интерфейсы на отдельных подсетях и отдельном UDP-порту. Отсюда два практических следствия: обновление AntiZapret не ломает слой, а сторонние админ-панели (например [AdminPanelAZ](https://github.com/Kirito0098/AdminPanelAZ)) продолжают работать без патчей.

## Что внутри

- **AmneziaWG 2.0** — kernel-модуль через официальный PPA (Ubuntu) или ручной репозиторий (Debian), обфускация в `[Interface]`.
- **Параллельная работа** — штатные WireGuard и OpenVPN остаются активными; слой не конфликтует с ними и с админ-панелями.
- **Раздельная маршрутизация (AntiZapret)** — в туннель уходит только заблокированное, остальное идёт напрямую. Работает и на AmneziaWG-слое, и на штатных WireGuard/OpenVPN.
- **Полный VPN** — отдельный профиль, весь трафик через сервер.
- **Настраиваемая обфускация и мимикрия** — пресеты интенсивности, шаблоны под QUIC/TLS/DNS/VoIP, выбор MTU и домена мимикрии.
- **Рандомный UDP-порт с закреплением** — выбирается при установке из свободных, исключая все зарезервированные AntiZapret; фиксируется навсегда. Задаётся и вручную.
- **Клиенты в один тап** — `.conf`, QR и `vpn://` для приложения Amnezia. Управление клиентами всех типов: AmneziaWG 2.0, стоковый WireGuard/AmneziaWG и OpenVPN.
- **Временные клиенты** с автоудалением по TTL.
- **Telegram-бот** — клиенты, статистика с гео, бэкап/восстановление и **обновления сервера** (списки, полное обновление AntiZapret, обновление слоя, перенастройка обфускации). Всё на кнопках.
- **Статистика по четырём интерфейсам** — трафик по клиентам и дням, кто онлайн, история подключений с IP/городом/провайдером, раздельно для слоя AWG 2.0 и стоковых клиентов.
- **Бэкап одной командой** — OpenVPN PKI, ключи AmneziaWG, конфиги, списки, статистика.
- **Поддержка альтернативных диапазонов** AntiZapret (`172.x`, fake-IP `198.18.x`) — подсети наследуются автоматически.

## Как это работает

```mermaid
flowchart LR
    C["📱 Клиент<br/>AmneziaWG 2.0"] -- "обфусцированный трафик<br/>(мимикрия QUIC/TLS)" --> S

    subgraph S["🖥 Сервер"]
        AWG["awg-quick@antizapret-awg<br/>10.29.9.0/24 · рандомный порт"]
        WG["штатный wg-quick@antizapret<br/>10.29.8.0/24 · не тронут"]
        R{"Адрес<br/>заблокирован?"}
        AWG --> R
    end

    R -- "да<br/>(списки РКН + DNS)" --> OUT["🌍 Заблокированный ресурс"]
    R -- "нет" --> DROP["⨯ дропается на сервере →<br/>устройство идёт напрямую"]
```

Слой AmneziaWG 2.0 живёт на своих интерфейсах `antizapret-awg` / `vpn-awg`, чьи подсети получаются сдвигом третьего октета штатных на +1 (`10.29.9.x` / `10.28.9.x`). NAT, DNS и защиты штатного AntiZapret покрывают их автоматически, потому что его правила ходят по агрегатам подсетей, а раздельная маршрутизация завязана на подсеть-источник, а не на тип интерфейса. Штатные `10.29.8.x` / `10.28.8.x` при этом продолжают обслуживаться родным WireGuard. Полный VPN (`vpn-awg`) отдаёт `AllowedIPs = 0.0.0.0/0, ::/0`.

## Требования

- **Ubuntu 24.04+** — рекомендуется, протестировано.
- **Debian 12/13** — работает, best-effort: на самых свежих ядрах DKMS-модуль AmneziaWG иногда не собирается ([upstream issue](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/143)). Если модуль не загрузился — смотри `dkms status` и лог сборки.
- root, установленный AntiZapret (или чистый сервер — установщик поставит базу и перезагрузит машину).
- Для бота: Python 3, `pip`/`venv` (ставятся автоматически). Зависимость: `aiogram 3` — устанавливается в изолированный venv `/opt/antizapret-awg/venv`.

## Установка

Базовый `setup.sh` перезагружает сервер, поэтому установка разбита на два шага.

**Шаг 1. Базовый AntiZapret.** Если он уже стоит — пропусти. Если нет, поставь оригинальной командой:

```bash
bash <(wget -qO- --no-hsts --inet4-only https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup.sh)
```

> Если официальный установщик у тебя падает из-за просроченного GPG-ключа OpenVPN, поставь базу через наш скрипт — он этот случай обходит: `bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh) --install-base`

**Шаг 2. Слой AmneziaWG 2.0** (после перезагрузки, без ребута):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh)
```

Выбираешь обфускацию, мимикрию, MTU, домен, порт (по умолчанию рандомный) и при желании ставишь бота. Готово.

### Флаги установщика

| Флаг | Что делает |
|---|---|
| `--install-base` | поставить базовый AntiZapret с обходом GPG-бага и перезагрузить сервер |
| `--preset high --template web` | обфускация без вопросов |
| `--awg-ports A,V` | задать порты вручную (`antizapret,vpn`), иначе рандомные из свободных |
| `--no-bot` | не спрашивать про Telegram-бота |
| `--install-bot [токен chat_id]` | доустановить бота **после** установки слоя (аргументами или интерактивно) |
| `--remove-bot` | удалить только бота, слой и клиенты остаются |
| `--bot-token X` / `--bot-admins X` | токен и chat_id для `--install-bot` без интерактива |
| `--update` | обновить код слоя, бота и раннера обновлений **без** смены обфускации, портов и клиентов |
| `--reconfigure` | переспросить настройки обфускации заново (новый профиль → клиентам нужно переимпортировать конфиги; порты не меняются) |
| `--migrate` | миграция со старых режимов `replace`/`keep` на `parallel` (ключи клиентов сохраняются, конфиги раздаются заново) |

## Управление

Через бота — или из консоли:

```bash
# AmneziaWG 2.0 (слой)
awg-client add  ivan antizapret          # split-routing → .conf + QR + vpn://
awg-client add  ivan vpn                  # полный туннель
awg-client add  guest antizapret --ttl 6h # временный (30m / 6h / 7d …)
awg-client del  ivan antizapret
awg-client list antizapret

# стоковые WireGuard/AmneziaWG и OpenVPN — штатный скрипт AntiZapret
/root/antizapret/client.sh 4 ivan         # добавить стоковый WG (оба туннеля)
/root/antizapret/client.sh 5 ivan         # удалить стоковый WG
/root/antizapret/client.sh 6              # список стоковых WG
/root/antizapret/client.sh 1 ivan 3650    # добавить OpenVPN
/root/antizapret/client.sh 2 ivan         # удалить OpenVPN
/root/antizapret/client.sh 3              # список OpenVPN

# обфускация
awg-obfuscation                           # меню с подсказками
awg-obfuscation --show                    # текущий профиль
awg-obfuscation --regenerate              # новые сигнатуры

# статистика
/opt/antizapret-awg/venv/bin/python /opt/antizapret-awg/awg_stats.py overview
# бэкап
awg-backup backup                         # → tar.gz
awg-backup restore файл.tar.gz
```

> Вызовы `client.sh` из бота сериализуются через `flock`, чтобы не конфликтовать с админ-панелью, которая пишет в те же файлы.

## Telegram-бот

Одна команда — `/start`, дальше всё кнопками.

```
🔐 AntiZapret-AWG 2.0 · vpn.example.com
├─ 👥 Клиенты
│   ├─ ➕ AmneziaWG 2.0 (AntiZapret / Полный VPN)
│   ├─ ➕ Стоковый WG      (оба туннеля, отдаются -am конфиг + QR + vpn://)
│   ├─ ➕ OpenVPN
│   ├─ ⏳ Временный клиент
│   └─ 📋 Список → клиент → ℹ️ Информация · 📥 Скачать · 🗑 Удалить
│                          (🌐 AWG2 split · 🔒 AWG2 полный · 🅰️ сток · 📄 OpenVPN)
│      (пункты скрываются, если OpenVPN или WireGuard не установлены)
├─ ℹ️ Информация      CPU / RAM / диск / аптайм, онлайн, топ-5, трафик
├─ ⚙️ Настройки AntiZapret
│   ├─ 🩹 Патч OpenVPN (анти-цензура)         (patch-openvpn.sh, при OpenVPN)
│   ├─ ⚡ OpenVPN DCO вкл/выкл                 (openvpn-dco.sh, при OpenVPN)
│   └─ 📝 include-/exclude-hosts, include-ips  (правка списков → doall)
├─ 🔄 Обновление
│   ├─ 🔎 Проверить обновления              (есть ли изменения кода на GitHub)
│   ├─ 📋 Обновить списки АнтиЗапрета      (doall.sh, безопасно)
│   ├─ 🧬 Обновить AWG 2.0                   (код слоя, install.sh --update)
│   └─ 🛠 Перенастроить обфускацию
├─ 🛡 Обфускация       показать / перегенерировать
├─ 💾 Бэкап
└─ ♻️ Восстановить     (принимает загруженный .tar.gz)
```

**Информация о клиенте** показывает онлайн-статус, текущий IP с городом и провайдером, историю последних подключений с датой/временем, трафик за сессию и всего — раздельно для клиентов слоя и стоковых. Клиент, который ещё ни разу не подключался, помечается отдельно, а не выдаёт ошибку.

**Настройки AntiZapret** — тонкая обёртка над штатными функциями базового проекта: анти-цензурный патч OpenVPN, переключение DCO и правка списков маршрутизации (`include-hosts`, `exclude-hosts`, `include-ips`) прямо из чата. После правки списков бот напоминает нажать «Обновить списки».

**Статистика OpenVPN-клиентов** собирается из status-логов AntiZapret и копится в той же базе, что и для WireGuard: трафик, IP, город и провайдер, история подключений. В карточке клиента видно активную сессию (туннель, IP, время, трафик) и накопленные за всё время данные.

**Проверка обновлений** (🔎) сравнивает код установщика AntiZapret и код слоя на GitHub с установленными версиями и сообщает, есть ли смысл обновляться. Обновление самого AntiZapret выполняется штатной командой в терминале сервера (бот её показывает) — так надёжнее всего. Списки блокировок в проверку не входят: они меняются постоянно и обновляются отдельной кнопкой.

Доступ — только по whitelist `AWG_BOT_ADMINS`. Бот ставится в Шаге 2 либо доустанавливается позже через `--install-bot`.


## Настройки обфускации

**Пресеты интенсивности:** `router` · `low` · `medium` (по умолчанию) · `high` · `paranoid`.

**Шаблоны мимикрии:** `quic` · `tls` · `web` (QUIC+TLS) · `voip` · `dns` · `mixed`. Выбирай протокол, который у твоего провайдера точно ходит.

**MTU:** авто/1320, 1420, 1280 (мобильные) или свой. **Домен мимикрии:** авто из встроенного пула доступных из РФ доменов или свой.

Профиль генерируется один раз и применяется одинаково к серверу и всем клиентам — иначе handshake не пройдёт. При смене профиля клиентские конфиги пересобираются автоматически; их нужно переимпортировать на устройствах. Перенастроить можно из бота (🔄 Обновление → 🛠 Перенастроить обфускацию) или флагом `--reconfigure`.

## Порты

Слой выбирает UDP-порт при установке рандомно из диапазона `20000–59999`, исключая занятые и все зарезервированные AntiZapret (`51443/51080` штатного WireGuard, `52443/52080` junk-редиректов, `540/580` резерва WG, `80/443/504/508` и `50080/50443` OpenVPN, плюс `1194/53/22`). Порт закрепляется в `/etc/amnezia/amneziawg/services.env` и больше не меняется — от него зависят все выданные клиентские конфиги. Задать вручную: `--awg-ports A,V`. Рандомный нестандартный порт вдобавок хуже поддаётся целевому сканированию.

## Обновление и переустановка

Состояние слоя лежит **вне** `/root/antizapret` — в `/opt/antizapret-awg` (overlay, клиенты, статистика) и `/etc/amnezia/amneziawg` (серверные ключи, профиль, порты), поэтому переживает любые операции с базой:

- **Авто-обновление AntiZapret** (по таймеру) качает только списки блокировок и пару скриптов маршрутизации — интерфейсы, обфускацию, конфиги и клиентов слоя не трогает.
- **Полное обновление AntiZapret** (штатный `setup.sh` в терминале) делает `rm -rf /root/antizapret`. После него слой **чинится сам**: drop-in на `antizapret.service` и юнит `awg-reintegrate.service` восстанавливают сервисы слоя, симлинки, хук в `custom-up.sh` и DNS-view в `kresd.conf`. В режиме `parallel` штатный WireGuard при этом не трогается вовсе. Обновлять AntiZapret из бота не нужно — команду подскажет кнопка «🔎 Проверить обновления»:

  ```bash
  bash <(wget -qO- --no-hsts --inet4-only https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup.sh)
  ```

Обновить **код** слоя (скрипты, бот, раннер) — без смены обфускации и без пересборки клиентов:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh) --update
```

Сменить **настройки** обфускации — новый профиль, конфиги переимпортировать на устройствах:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh) --reconfigure
```

### Миграция со старых версий

Ранние версии форка умели работать в режимах `replace` (замена штатного WG) и `keep` (WG на фиксированных `52xxx`). Актуальная версия работает только в `parallel`. Перевод — одной командой:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh) --migrate
```

Миграция возвращает штатный WireGuard в исходное состояние (порты, редиректы), переносит слой на интерфейсы `antizapret-awg`/`vpn-awg` и рандомный порт, сохраняя ключи клиентов. Клиентские конфиги при этом придётся раздать заново: у `keep` меняется порт `Endpoint`, у `replace` — ещё и туннельный IP.

## Диагностика

```bash
awg show                                    # интерфейсы слоя, peers, handshake, трафик
wg show                                      # штатные WireGuard-интерфейсы
systemctl status awg-quick@antizapret-awg
```

| Симптом | Причина / решение |
|---|---|
| нет интерфейса в `awg show` | `awg-quick` не поднялся → `journalctl -u awg-quick@antizapret-awg` |
| `__AWG_OBFUSCATION__` в конфиге | обфускация не применилась → `--reconfigure` |
| peer есть, но нет `latest handshake` | профиль клиента ≠ профиля сервера → переимпортируй свежий конфиг |
| handshake есть, `received` = 0 | блокировка по IP/AS провайдером — смени хостинг/IP или включи WARP |
| `awg-quick: ... already exists` | `ip link del antizapret-awg && systemctl start awg-quick@antizapret-awg` |
| бот не видит стоковый клиент | обнови слой (`--update`) — фикс имён файлов включён |
| split-клиент открывает только «прямые» сайты | после полного обновления раздай ему свежий конфиг (📥 Скачать) — маршруты обновились |
| Debian: репозиторий Amnezia «not signed» | обнови слой (`--update`) — keyring теперь `0644`, читается верификатором `_apt` |
| установлен режим `replace`/`keep` | `--migrate` |

## На чём основано

- [GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) — база: маршрутизация, OpenVPN, DNS, списки.
- [amnezia-vpn/amneziawg](https://github.com/amnezia-vpn) — сам AmneziaWG 2.0.
- [Kirito0098/AdminPanelAZ](https://github.com/Kirito0098/AdminPanelAZ) — веб-панель, совместимая со слоем.
- [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) и [Vadim-Khristenko/AmneziaWG-Architect](https://github.com/Vadim-Khristenko/AmneziaWG-Architect) — подходы к установке AWG и генерации мимикрии.

## История изменений

Полный список версий и изменений — в [CHANGELOG.md](CHANGELOG.md).

## Лицензия

[GPLv3](LICENSE). Свободно используй, меняй и распространяй — производные тоже остаются открытыми.
