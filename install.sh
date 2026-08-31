#!/usr/bin/env bash
# install.sh — установщик AntiZapret-AWG 2.0.
#
# МОДЕЛЬ: слой настоящего AmneziaWG 2.0 ПАРАЛЛЕЛЬНО уже установленному AntiZapret.
# Ванильный AntiZapret не трогается ни байтом: wg-quick, порты 51443/51080,
# редиректы 540/580 и 52xxx, client.sh, админ-панели — всё работает штатно.
# AmneziaWG живёт на своих интерфейсах antizapret-awg/vpn-awg, своих подсетях
# (третий октет +1) и своём UDP-порту (рандомный, выбирается один раз и
# закрепляется навсегда — или задаётся вручную).
#
# Использование:
#   1) если AntiZapret ещё НЕ установлен — сначала поставь базу (она перезагрузит сервер):
#        bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/beta/install.sh) --install-base
#      …сервер перезагрузится…
#   2) затем поставь слой AmneziaWG:
#        bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/az-awg2/beta/install.sh)
#
# Флаги слоя AmneziaWG:
#   --preset3 X        пресет обфускации ОТДЕЛЬНО для слоя 3.0 (по умолчанию —
#                      тот же, что у 2.0). Пресеты router и low объявлены без
#                      header protection: на них слой 3.0 вырождается в 2.0.
#   --template3 Y      мимикрия отдельно для слоя 3.0
#   --awg3-ports A,V   порты слоя 3.0 вручную (antizapret3,vpn3)
#   --awg-ports A,V    зафиксировать порты вручную (antizapret,vpn),
#                      по умолчанию — рандомные свободные с закреплением
#   --awg 2|3|both     какие версии протокола ставить (по умолчанию спросит).
#                      3.0 поднимается ОТДЕЛЬНЫМИ интерфейсами и не мешает 2.0
#   --preset X --template Y --fp Z   обфускация без вопросов
#   --no-bot           не спрашивать про Telegram-бота
#   --plan             показать, что сделает прогон, и ничего не делать
#   --update           обновить код/бот/самовосстановление БЕЗ смены обфускации,
#                      портов и клиентов (существующие клиенты не ломаются)
#   --reconfigure      переспросить параметры заново (генерирует НОВЫЙ профиль
#                      обфускации → клиентам нужно переимпортировать конфиги;
#                      порты при этом НЕ меняются)
#   --migrate          миграция со старых режимов replace/keep на parallel
#                      (ключи клиентов сохраняются, конфиги нужно раздать заново)
#   --install-bot [T A]  доустановить Telegram-бот ПОСЛЕ установки слоя.
#                      Токен и chat_id можно передать аргументами или ввести
#                      интерактивно. Повторный запуск обновляет токен/админов.
#   --bot-token X      токен бота для --install-bot без интерактива
#   --bot-admins X     chat_id админов через запятую. Сам по себе, без
#                      --install-bot, меняет ТОЛЬКО список админов и
#                      перезапускает бота — переустановка не нужна.
#                      Список заменяется целиком: перечисляй всех, включая себя.
#   --remove-bot       удалить только Telegram-бот (слой AmneziaWG остаётся)
#   --uninstall        полностью удалить слой AmneziaWG (ваниль не трогается)
#
# Запуск БЕЗ флагов на сервере с уже установленным слоем показывает меню:
# переустановка / новая обфускация / бот / обновление / удаление. Без
# терминала (автоматизация) выполняется безопасное обновление (--update).
set -euo pipefail

REPO_URL="https://github.com/blindtechnique/az-awg2"
# ветка beta: слой AmneziaWG 3.0, awg-doctor, самотест, шифрование бэкапа.
# Переключиться на стабильную: AWG_REPO_BRANCH=main bash install.sh
REPO_BRANCH="${AWG_REPO_BRANCH:-beta}"
UPSTREAM_REPO="https://github.com/GubernievS/AntiZapret-VPN.git"
DEST="/opt/antizapret-awg"
STATE="/opt/antizapret-awg/install-state.env"

INSTALL_BASE=0; NO_BOT=0; RECONFIGURE=0; UPDATE=0; MIGRATE=0; PLAN=0
INSTALL_BOT=0; REMOVE_BOT=0; UNINSTALL=0
CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""; CLI_PORTS=""
# Слой 3.0 настраивается отдельно: у него своя обфускация и свои порты. Пусто
# означает «взять как у 2.0» — так ведут себя все установки, сделанные раньше.
CLI_PRESET3=""; CLI_TEMPLATE3=""; CLI_PORTS3=""
# какие версии протокола поднимать: 2 | 3 | both
CLI_AWG_VER=""
CLI_BOT_TOKEN=""; CLI_BOT_ADMINS=""

# ── самозагрузка (curl|bash): клонируем и re-exec, с защитой от зацикливания ──
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || echo /nonexistent)"
if [ ! -f "$SELF_DIR/patches/antizapret-awg-integration.sh" ]; then
    if [ -n "${AWG_NO_BOOTSTRAP:-}" ]; then
        echo "[bootstrap] неполная структура репозитория." >&2; exit 1
    fi
    echo "[bootstrap] клонирую репозиторий…"
    command -v git >/dev/null 2>&1 || { apt-get update -y && apt-get install -y git; }
    BOOT_DIR="$(mktemp -d)"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$BOOT_DIR/repo"
    # Защита от CRLF: если файлы попали в репозиторий с Windows-машины, каждая
    # строка кончается на \r, и bash падает уже на первой — «: invalid option
    # nameset: pipefail». Чистим то, что будем исполнять и раскладывать.
    find "$BOOT_DIR/repo" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' \
        -o -name '*.timer' -o -name '*.conf' -o -name '*.template' \) \
        -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    exec env AWG_NO_BOOTSTRAP=1 bash "$BOOT_DIR/repo/install.sh" "$@"
fi
REPO_DIR="$SELF_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --install-base) INSTALL_BASE=1; shift ;;
        --update) UPDATE=1; shift ;;
        --plan) PLAN=1; shift ;;
        --migrate) MIGRATE=1; shift ;;
        --install-bot)
            INSTALL_BOT=1; shift
            # опциональные позиционные: токен и chat_id (если не начинаются с --)
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then CLI_BOT_TOKEN="$1"; shift; fi
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then CLI_BOT_ADMINS="$1"; shift; fi ;;
        --remove-bot) REMOVE_BOT=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --bot-token) CLI_BOT_TOKEN="$2"; shift 2 ;;
        --bot-admins) CLI_BOT_ADMINS="$2"; shift 2 ;;
        --awg-ports) CLI_PORTS="$2"; shift 2 ;;
        --awg3-ports) CLI_PORTS3="$2"; shift 2 ;;
        --preset3) CLI_PRESET3="$2"; shift 2 ;;
        --template3) CLI_TEMPLATE3="$2"; shift 2 ;;
        --no-bot) NO_BOT=1; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
        --awg) CLI_AWG_VER="$2"; shift 2 ;;
        --preset) CLI_PRESET="$2"; shift 2 ;;
        --template) CLI_TEMPLATE="$2"; shift 2 ;;
        --fp) CLI_FP="$2"; shift 2 ;;
        --keep-wireguard)  # legacy: parallel теперь единственный режим
            echo "[install] --keep-wireguard устарел: параллельный режим теперь единственный." >&2
            shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Запускать под root (sudo)"; exit 1; }
log() { printf '\033[1;35m[install]\033[0m %s\n' "$*"; }

base_installed() {
    # надёжный признак установленного AntiZapret — его ключевые файлы
    # (не зависим от формата вывода systemctl, который подводил на свежих серверах)
    [ -f /root/antizapret/client.sh ] || [ -f /root/antizapret/up.sh ]
}

layer_installed() { [ -f /etc/amnezia/amneziawg/services.env ]; }

# зарезервировано ванилью: WG 51443/51080, «-am» редирект 52443/52080, резерв WG
# 540/580, резерв OpenVPN 80/443/504/508, реальный OpenVPN 50080/50443, 1194, 53, 22
RESERVED_PORTS="22 53 80 443 504 508 540 580 1194 50080 50443 51080 51443 52080 52443"
# Обе проверки — предикаты, то есть их код возврата и есть ответ. Труба с
# `grep -q` для этого не годится: под pipefail она отдаёт 141, когда
# совпадение нашлось в начале длинного вывода, и «порт занят» читается как
# «свободен». Сравниваем подстановкой по строке.
port_reserved() { case " $RESERVED_PORTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
port_busy() {
    # Поле с конца и `|| true` — по тем же причинам, что в busy_ports
    # интеграции; до этой правки здесь стояло $5, колонка Peer, и предикат
    # отвечал «свободен» на любой порт, включая занятый.
    local busy
    busy="$(ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -oE '[0-9]+$' | sort -u || true)"
    case $'\n'"$busy"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ════════════════════════════════════════════════════════════════════════════
#  ШАГ 1 (опционально): установка базового AntiZapret (перезагружает сервер)
# ════════════════════════════════════════════════════════════════════════════
preflight_base() {
    if [ -f /var/run/reboot-required ]; then
        log "⚠️ Нужна перезагрузка перед установкой базы (осталась от обновления ядра):"
        log "    reboot   — затем снова: bash install.sh --install-base"
        exit 0
    fi
    # чистим битые сторонние репозитории от прошлых прерванных попыток
    local changed=0
    for f in /etc/apt/sources.list.d/*openvpn* /etc/apt/sources.list.d/*knot* \
             /etc/apt/sources.list.d/*amnezia*; do
        [ -e "$f" ] && { rm -f "$f"; changed=1; }
    done
    [ "$changed" = 1 ] && log "Убраны битые списки репозиториев от прошлых попыток"
}

install_base() {
    if base_installed; then
        log "AntiZapret уже установлен — база не нужна. Запусти без --install-base для слоя AmneziaWG."
        exit 0
    fi
    log "Установка базового AntiZapret (GubernievS)…"
    preflight_base
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1 || apt-get install -y git
    local tmp; tmp="$(mktemp -d)"
    git clone --depth 1 "$UPSTREAM_REPO" "$tmp/AntiZapret-VPN"
    [ -n "${ANTIZAPRET_REF:-}" ] && { git -C "$tmp/AntiZapret-VPN" fetch --depth 1 origin "$ANTIZAPRET_REF" 2>/dev/null && git -C "$tmp/AntiZapret-VPN" checkout FETCH_HEAD 2>/dev/null || true; }
    # ОБХОД сломанного upstream: истёкший GPG-ключ OpenVPN/knot (issue #803/#808) →
    # apt-get update падает с NO_PUBKEY. trusted=yes снимает требование подписи для
    # этих двух репозиториев (транспорт остаётся HTTPS). Плюс ретраи на скачивание ключей.
    sed -i 's#\[signed-by=#[trusted=yes signed-by=#g' "$tmp/AntiZapret-VPN/setup.sh" 2>/dev/null || true
    sed -i 's#curl -fL --connect-timeout 30#curl -fL --connect-timeout 30 --retry 6 --retry-delay 3 --retry-all-errors#g' "$tmp/AntiZapret-VPN/setup.sh" 2>/dev/null || true
    log "Применён обход GPG-ключа OpenVPN/knot (известная проблема upstream)"
    echo
    log "Запускается базовый setup.sh. Отвечай на его вопросы (WireGuard включи — он"
    log "останется работать параллельно с AmneziaWG; OpenVPN оставь). В конце сервер"
    log "ПЕРЕЗАГРУЗИТСЯ. После перезагрузки поставь слой AmneziaWG:  bash install.sh"
    echo
    bash "$tmp/AntiZapret-VPN/setup.sh"
}

# ════════════════════════════════════════════════════════════════════════════
#  ШАГ 2: слой AmneziaWG параллельно установленному AntiZapret (без перезагрузки)
# ════════════════════════════════════════════════════════════════════════════
# надёжный y/n: читает с терминала (важно при bash <(curl…), где stdin — не tty),
# срезает пробелы/CR, нормализует регистр. Принимает y/yes/д/да.
# /dev/tty может существовать, но не открываться (нет управляющего терминала —
# например при `ssh host 'bash -s' < script`). Проверяем именно ОТКРЫТИЕ.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# Строгий да/нет: принимаем только явный ответ, всё остальное переспрашиваем.
# Раньше любой мусор молча означал «нет», и установка тихо уходила не по той
# ветке — например без бота.
ask_yn() {  # ask_yn "<вопрос>" <default: y|n> → 0 если да
    local q="$1" def="${2:-n}" a src=/dev/stdin tries=0
    has_tty && src=/dev/tty
    while :; do
        a=""
        read -rp "$q" a < "$src" || a="$def"
        # tr понижает регистр только латиницы — кириллицу доводим sed'ом,
        # иначе «НЕТ» заглавными не распознаётся
        a="$(printf '%s' "$a" | tr -d '[:space:]\r' | tr 'A-Z' 'a-z' \
             | sed 's/Д/д/g; s/А/а/g; s/Н/н/g; s/Е/е/g; s/Т/т/g')"
        [ -z "$a" ] && a="$def"
        case "$a" in
            y|yes|д|да)  return 0 ;;
            n|no|н|нет)  return 1 ;;
        esac
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            log "внятного ответа нет — беру значение по умолчанию: $def"
            case "$def" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
        fi
        printf '    Ответьте y (да) или n (нет). Enter — вариант по умолчанию.\n' >&2
    done
}

# Выбор пункта меню: принимаем только перечисленные варианты.
ask_pick() {  # ask_pick <имя_переменной> <дефолт> "<допустимые через пробел>"
    local __var="$1" def="$2" allowed="$3" v src=/dev/stdin tries=0
    has_tty && src=/dev/tty
    while :; do
        v=""
        read -rp "Выбор [$def]: " v < "$src" || v="$def"
        v="$(printf '%s' "$v" | tr -d '[:space:]\r')"
        [ -z "$v" ] && v="$def"
        # Без трубы: `printf | grep -q` под pipefail отдаёт 141, когда
        # совпадение нашлось в начале длинного вывода. Здесь список короткий и
        # до беды не доходило, но класс тот же — и держать исключение из
        # правила дороже, чем его убрать.
        if [ -n "$v" ] && case " $allowed " in *" $v "*) true ;; *) false ;; esac; then
            printf -v "$__var" '%s' "$v"; return 0
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            log "внятного выбора нет — беру вариант по умолчанию: $def"
            printf -v "$__var" '%s' "$def"; return 0
        fi
        printf '    Допустимые варианты: %s. Enter — %s.\n' "$allowed" "$def" >&2
    done
}

# Ввод с проверкой по регулярке: не пускаем дальше, пока не введено корректное.
ask_valid() {  # ask_valid <имя_переменной> "<подсказка>" <регулярка> "<пояснение>" [дефолт]
    local __var="$1" q="$2" re="$3" hint="$4" def="${5:-}" v src=/dev/stdin tries=0
    has_tty && src=/dev/tty
    while :; do
        v=""
        read -rp "$q" v < "$src" || v="$def"
        v="$(printf '%s' "$v" | tr -d '[:space:]\r')"
        [ -z "$v" ] && v="$def"
        if [ -n "$v" ] && [[ "$v" =~ $re ]]; then
            printf -v "$__var" '%s' "$v"; return 0
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 5 ] && { log "корректное значение не введено"; return 1; }
        printf '    %s\n' "$hint" >&2
    done
}

parse_cli_ports() {  # "1234,5678" → AZ_PORT_CHOICE/VPN_PORT_CHOICE
    AZ_PORT_CHOICE="${CLI_PORTS%%,*}"; VPN_PORT_CHOICE="${CLI_PORTS##*,}"
    if ! valid_port "$AZ_PORT_CHOICE" || ! valid_port "$VPN_PORT_CHOICE" \
        || [ "$AZ_PORT_CHOICE" = "$VPN_PORT_CHOICE" ]; then
        log "❌ --awg-ports: нужно два разных порта 1-65535 через запятую, напр. 34567,45678"
        exit 2
    fi
}

parse_cli_ports3() {  # "1234,5678" → AZ3_PORT_CHOICE/VPN3_PORT_CHOICE
    AZ3_PORT_CHOICE="${CLI_PORTS3%%,*}"; VPN3_PORT_CHOICE="${CLI_PORTS3##*,}"
    if ! valid_port "$AZ3_PORT_CHOICE" || ! valid_port "$VPN3_PORT_CHOICE" \
        || [ "$AZ3_PORT_CHOICE" = "$VPN3_PORT_CHOICE" ]; then
        log "❌ --awg3-ports: нужно два разных порта 1-65535 через запятую, напр. 34567,45678"
        exit 2
    fi
    # Пересечение со слоем 2.0 поймать здесь дешевле, чем потом ловить
    # «Address already in use» на старте второго интерфейса.
    local p
    for p in "$AZ3_PORT_CHOICE" "$VPN3_PORT_CHOICE"; do
        if [ "$p" = "${AZ_PORT_CHOICE:-}" ] || [ "$p" = "${VPN_PORT_CHOICE:-}" ]; then
            log "❌ порт $p уже занят слоем 2.0 — у слоёв должны быть разные порты"
            exit 2
        fi
    done
}

ask_port() {  # ask_port <подпись> <исключить> → PORT_ANSWER ("" = авто)
    local label="$1" excl="$2" p
    while :; do
        read -rp "    Порт $label (Enter = авто/рандом): " p
        [ -z "$p" ] && { PORT_ANSWER=""; return; }
        valid_port "$p" || { echo "    Некорректный порт (1-65535)"; continue; }
        [ "$p" = "$excl" ] && { echo "    Совпадает с другим портом AWG"; continue; }
        if port_reserved "$p"; then
            read -rp "    ⚠️ Порт $p зарезервирован AntiZapret (WG/OpenVPN/редиректы). Всё равно использовать? [y/N]: " a
            case "${a:-N}" in y|Y) ;; *) continue ;; esac
        elif port_busy "$p"; then
            read -rp "    ⚠️ Порт $p уже слушается на сервере. Всё равно использовать? [y/N]: " a
            case "${a:-N}" in y|Y) ;; *) continue ;; esac
        fi
        PORT_ANSWER="$p"; return
    done
}

# Одно значение из сохранённого install-state.env. Читаем в подоболочке: файл
# объявляет десяток переменных, и точка в текущей области видимости затёрла бы
# то, что прогон уже решил.
state_val() {  # state_val <имя ключа> → значение или пусто
    [ -f "$STATE" ] || return 0
    ( . "$STATE" 2>/dev/null || true; printf '%s' "${!1:-}" )
}

collect_choices() {
    AZ_PORT_CHOICE=""; VPN_PORT_CHOICE=""
    [ -n "$CLI_PORTS" ] && parse_cli_ports
    [ -n "$CLI_PORTS3" ] && parse_cli_ports3
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ] && [ -z "$CLI_PRESET" ]; then
        . "$STATE"
        # порты при повторном запуске всегда берутся из services.env (закреплены) —
        # ответы из state здесь не применяем, чтобы не «переехать» случайно
        log "Использую сохранённые ответы (обфускация ${AWG_PRESET:-medium}/${AWG_TEMPLATE:-default}, бот $([ "${AWG_BOT_INSTALL:-0}" = 1 ] && echo да || echo нет)). Сброс: --reconfigure"
        return
    fi
    local PRESET="medium" TEMPLATE="" FP="chrome" MTU=1320 HOST="" BOT_INSTALL=0 BOT_TOKEN="" BOT_ADMINS=""
    local PRESET3="" TEMPLATE3=""      # пусто = как у слоя 2.0
    local AWG_VER="${CLI_AWG_VER:-}"

    # ── версия протокола ────────────────────────────────────────────────────
    # 2.0 работает на kernel-модуле, 3.0 — только userspace (в модуле нет
    # header protection и остального из 3.0). Слои независимы: разные
    # интерфейсы, подсети и порты, поэтому «оба сразу» — рабочий вариант:
    # клиентам со свежими приложениями выдаёшь 3.0, остальным 2.0.
    if [ -z "$AWG_VER" ]; then
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Какую версию AmneziaWG поднять?"
        echo
        echo "   1) 2.0        — как раньше: kernel-модуль, работает с любыми"
        echo "                   клиентами AmneziaWG, включая старые."
        echo "   2) 3.0        — header protection, content padding, рандомные"
        echo "                   тайминги. Датапас userspace (amneziawg-go),"
        echo "                   собирается из исходников. Нужны свежие клиенты."
        echo "   3) обе сразу  — два независимых слоя [по умолчанию]."
        echo "                   Клиент заводится в нужный одной командой."
        ask_pick VER_CHOICE 3 "1 2 3"
        case "$VER_CHOICE" in 1) AWG_VER=2 ;; 2) AWG_VER=3 ;; *) AWG_VER=both ;; esac
    fi
    case "$AWG_VER" in 2|3|both) ;; *) log "неизвестное значение --awg '$AWG_VER', беру both"; AWG_VER=both ;; esac

    if [ -n "$CLI_PRESET" ]; then
        # Не спрашивали — не меняем. Все диалоги — обфускация, мимикрия, браузер,
        # MTU, домен — лежат в ветке else, которую эта ветка пропускает. Раньше
        # сюда уезжали ЛОКАЛЬНЫЕ умолчания (TEMPLATE='', FP=chrome, MTU=1320,
        # HOST='', PRESET3='') и ложились в state поверх ответов владельца.
        # Сервер с мимикрией web, браузером firefox, MTU 1280 и отдельным
        # пресетом 3.0 после одной команды `--preset paranoid` оказывался на
        # авто/chrome/1320, а слой 3.0 переезжал на пресет слоя 2.0 — пустой
        # PRESET3 значит «как у 2.0». Вернуть было неоткуда: и install-state.env,
        # и obfuscation.meta уже перезаписаны.
        #
        # Поэтому каждое значение берётся из CLI, если оно там задано, и из
        # сохранённого состояния, если нет. У MTU и HOST флагов нет вовсе —
        # они приходят только из state.
        local _v
        PRESET="$CLI_PRESET"
        _v="$(state_val AWG_TEMPLATE)";  TEMPLATE="${CLI_TEMPLATE:-$_v}"
        _v="$(state_val AWG_FP)";        FP="${CLI_FP:-${_v:-chrome}}"
        _v="$(state_val AWG_PRESET3)";   PRESET3="${CLI_PRESET3:-$_v}"
        _v="$(state_val AWG_TEMPLATE3)"; TEMPLATE3="${CLI_TEMPLATE3:-$_v}"
        _v="$(state_val AWG_MTU)";       MTU="${_v:-$MTU}"
        _v="$(state_val AWG_HOST)";      HOST="${_v:-$HOST}"
    else
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Обфускация AmneziaWG 2.0 — интенсивность"
        echo "   1) router  2) low  3) medium [по умолч.]  4) high  5) paranoid"
        echo "   4) high — если провайдер режет WireGuard; 5) paranoid — жёсткие блокировки РФ"
        read -rp "Выбор [3]: " x; case "${x:-3}" in 1) PRESET=router;;2) PRESET=low;;4) PRESET=high;;5) PRESET=paranoid;;*) PRESET=medium;; esac
        # У слоя 3.0 свой профиль, и «интенсивность» значит для него другое:
        # router и low объявлены без header protection, паддинга и таймингов,
        # то есть на них 3.0 отдаёт ровно то же, что 2.0, и смысла в отдельном
        # слое не остаётся. Поэтому спрашиваем отдельно и говорим об этом прямо.
        if [ "$AWG_VER" != 2 ]; then
            echo
            echo "  Обфускация AmneziaWG 3.0 — отдельно от слоя 2.0"
            echo "   1) router  2) low  3) medium [по умолч.]  4) high  5) paranoid"
            echo "   ⚠️ router и low — БЕЗ header protection, паддинга и таймингов:"
            echo "      слой 3.0 на них работает как 2.0. Полный 3.0 — от medium."
            read -rp "Выбор [3]: " x3
            case "${x3:-3}" in 1) PRESET3=router;;2) PRESET3=low;;4) PRESET3=high;;5) PRESET3=paranoid;;*) PRESET3=medium;; esac
            case "$PRESET3" in
                router|low)
                    echo "   Выбран $PRESET3: слой 3.0 будет без header protection." ;;
            esac
        fi
        echo "  Мимикрия (под что маскировать): 0)авто 1)quic 2)tls 3)web 4)voip 5)dns 6)mixed"
        echo "   не уверен — '3) web'"
        read -rp "Выбор [0]: " y; case "${y:-0}" in 1) TEMPLATE=quic;;2) TEMPLATE=tls;;3) TEMPLATE=web;;4) TEMPLATE=voip;;5) TEMPLATE=dns;;6) TEMPLATE=mixed;;*) TEMPLATE="";; esac
        echo "  Профиль браузера: 1) chrome  2) firefox  3) safari"
        read -rp "Выбор [1]: " z; case "${z:-1}" in 2) FP=firefox;;3) FP=safari;;*) FP=chrome;; esac
        echo
        echo "  MTU (шаблоны): 1) авто/1320 [реком. для AWG 2.0]  2) 1420 (макс.)"
        echo "                 3) 1280 (мобильные/узкие линки)  4) свой"
        read -rp "  Выбор [1]: " mt; case "${mt:-1}" in
            2) MTU=1420;; 3) MTU=1280;; 4) read -rp "    Введи MTU: " MTU;; *) MTU=1320;;
        esac
        # Проверяем то, что человек только что набрал в диалоге. Здесь не
        # отказ, а откат к дефолту — но вслух: молчаливая подмена уводила с
        # не тем MTU, и узнавалось это по неработающим клиентам. Сохранённое
        # значение существующего сервера этой веткой не проходит и не
        # трогается — там менять MTU опаснее, чем оставить как есть.
        if ! { [[ "$MTU" =~ ^[0-9]+$ ]] && [ "$MTU" -ge 576 ] && [ "$MTU" -le 1500 ]; }; then
            echo "    MTU «$MTU» вне диапазона 576-1500 — беру 1320"
            MTU=1320
        fi
        echo
        echo "  Домен для мимикрии I-пакетов: 1) авто (пул доступных из РФ) [реком.]"
        echo "                                2) свой домен"
        read -rp "  Выбор [1]: " dm; case "${dm:-1}" in
            2) read -rp "    Домен (напр. yandex.ru): " HOST;; *) HOST="";;
        esac
        if [ -z "$CLI_PORTS" ]; then
            echo
            echo "  UDP-порты AmneziaWG: по умолчанию выбираются РАНДОМНО из свободных"
            echo "  (рекомендуется: не пересекаются с ванилью и хуже поддаются сканированию)"
            echo "  и закрепляются навсегда. Можно задать свои."
            ask_port "antizapret (split-туннель)" ""
            AZ_PORT_CHOICE="$PORT_ANSWER"
            ask_port "vpn (полный туннель)" "$AZ_PORT_CHOICE"
            VPN_PORT_CHOICE="$PORT_ANSWER"
            # У слоя 3.0 свои интерфейсы и свои порты: спрашиваем их отдельно,
            # иначе задать их вручную было нельзя вовсе — всегда рандом.
            if [ "$AWG_VER" != 2 ]; then
                ask_port "antizapret3 (split, слой 3.0)" "$AZ_PORT_CHOICE"
                AZ3_PORT_CHOICE="$PORT_ANSWER"
                ask_port "vpn3 (полный, слой 3.0)" "$AZ3_PORT_CHOICE"
                VPN3_PORT_CHOICE="$PORT_ANSWER"
            fi
        fi
    fi
    if [ "$NO_BOT" = 0 ]; then
        echo
        if ask_yn "Установить Telegram-бот (клиенты OpenVPN+AmneziaWG, статистика, бэкап)? [y/N]: " n; then
            # проверяем формат: опечатка оборачивается ботом, который молча
            # не отвечает, и причину приходится искать в журнале
            if ask_valid BOT_TOKEN "  Токен бота (@BotFather): " '^[0-9]+:[A-Za-z0-9_-]+$' \
                   "Формат: 123456789:AA...  (цифры, двоеточие, ключ)" \
               && ask_valid BOT_ADMINS "  Твой chat_id (число, у @userinfobot): " '^[0-9]+(,[0-9]+)*$' \
                   "Только число или числа через запятую, не @username."; then
                BOT_INSTALL=1
            else
                log "Токен/chat_id не введены — бот пропущен"
            fi
        fi
    fi
    mkdir -p "$(dirname "$STATE")"; umask 077
    cat > "$STATE" <<EOF
AWG_PRESET='$PRESET'
AWG_TEMPLATE='$TEMPLATE'
AWG_PRESET3='$PRESET3'
AWG_TEMPLATE3='$TEMPLATE3'
AWG_FP='$FP'
AWG_BOT_INSTALL='$BOT_INSTALL'
AWG_BOT_TOKEN='$BOT_TOKEN'
AWG_BOT_ADMINS='$BOT_ADMINS'
AWG_MTU='$MTU'
AWG_HOST='$HOST'
AWG_VER='$AWG_VER'
EOF
}

setup_stats() {
    log "Статистика (venv + systemd timer)…"
    apt-get install -y python3-venv >/dev/null 2>&1 || true
    [ -d "$DEST/venv" ] || python3 -m venv "$DEST/venv"
    cp "$REPO_DIR/bot/awg-stats.service" "$REPO_DIR/bot/awg-stats.timer" /etc/systemd/system/
    cp "$REPO_DIR/bot/awg-expire.service" "$REPO_DIR/bot/awg-expire.timer" /etc/systemd/system/ 2>/dev/null || true
    "$DEST/venv/bin/python" "$DEST/awg_stats.py" init 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now awg-stats.timer awg-expire.timer 2>/dev/null || true
}

_deploy_bot() {  # _deploy_bot <token> <admins> — общая часть установки/обновления бота
    local token="$1" admins="$2"
    log "Установка бота…"
    mkdir -p "$DEST/bot"; cp "$REPO_DIR/bot/awg_bot.py" "$DEST/bot/"
    [ -d "$DEST/venv" ] || python3 -m venv "$DEST/venv"
    "$DEST/venv/bin/pip" install -q -r "$REPO_DIR/bot/requirements.txt"
    # Переменные бота (включая токен) кладём в файл с правами 600, а не в юнит:
    # /etc/systemd/system читается всеми, и токен оттуда утекает любому
    # локальному пользователю.
    umask 077
    {
        echo "# Создано install.sh $(date -u +%FT%TZ). Права 600: здесь токен."
        sed -e "s#PASTE_TOKEN_HERE#${token}#" \
            -e "s#^AWG_BOT_ADMINS=.*#AWG_BOT_ADMINS=${admins}#" \
            "$REPO_DIR/bot/bot.env.template" | grep -v '^#'
        # кнопка «Обновить слой» в боте должна тянуть ТУ ЖЕ ветку, откуда ставили,
        # иначе установка с beta молча откатится на main
        echo "AWG_INSTALL_SH_URL=https://raw.githubusercontent.com/blindtechnique/az-awg2/${REPO_BRANCH}/install.sh"
    } > "$DEST/bot.env"
    chmod 600 "$DEST/bot.env"
    cp "$REPO_DIR/bot/awg-bot.service" /etc/systemd/system/awg-bot.service

    # если юнит остался от прежней версии — вычищаем из него токен
    if grep -q '^Environment=AWG_BOT_TOKEN=' /etc/systemd/system/awg-bot.service 2>/dev/null; then
        sed -i '/^Environment=AWG_BOT_TOKEN=/d' /etc/systemd/system/awg-bot.service
        log "токен убран из юнита — теперь он только в $DEST/bot.env (600)"
    fi
    systemctl daemon-reload; systemctl enable --now awg-bot
    # запомним факт установки бота в state (для --update)
    if [ -f "$STATE" ]; then
        sed -i "s#^AWG_BOT_INSTALL=.*#AWG_BOT_INSTALL='1'#" "$STATE" 2>/dev/null \
            || echo "AWG_BOT_INSTALL='1'" >> "$STATE"
    fi
    log "Бот запущен. Напиши ему /start"
}

# ── действующие настройки бота ───────────────────────────────────────────────
# Установщик за свою историю держал токен и админов в двух разных местах, и на
# живых серверах встречаются оба: сначала — строки Environment= в юните, позже —
# отдельный bot.env с правами 600 (юнит в /etc/systemd/system читается всеми,
# и токен оттуда утекал любому локальному пользователю).
#
# Читаем по убыванию свежести: bot.env → install-state.env → юнит. Раньше
# смотрели только в юнит, и на новой раскладке «Enter = оставить текущее»
# не срабатывало никогда: _deploy_bot как раз вычищает эти строки из юнита.
bot_prev() {  # bot_prev <имя переменной>
    local key="$1" v=""
    [ -f "$DEST/bot.env" ] && v="$(sed -n "s/^${key}=//p" "$DEST/bot.env" 2>/dev/null | head -1)"
    if [ -z "$v" ] && [ -f "$STATE" ]; then
        v="$(sed -n "s/^${key}=//p" "$STATE" 2>/dev/null | head -1)"
        v="${v%\'}"; v="${v#\'}"      # в STATE значения записаны в одинарных кавычках
    fi
    if [ -z "$v" ] && [ -f /etc/systemd/system/awg-bot.service ]; then
        v="$(sed -n "s/^Environment=${key}=//p" /etc/systemd/system/awg-bot.service 2>/dev/null | head -1)"
    fi
    printf '%s' "$v"
}

# ── сменить список админов, не переустанавливая бота ──────────────────────────
# awg_bot.py читает AWG_BOT_ADMINS один раз при старте процесса, поэтому хватает
# правки строки и рестарта юнита: venv, зависимости и токен не трогаем. Список
# ЗАМЕНЯЕТСЯ целиком — перечислять надо всех, включая себя.
set_bot_admins() {  # set_bot_admins <chat_id через запятую>
    local admins="$1" unit=/etc/systemd/system/awg-bot.service
    [ -f "$unit" ] || { err "Бот не установлен. Сначала: bash install.sh --install-bot"; exit 1; }
    # Проверяем до записи: пустое значение или мусор в списке молча лишают
    # доступа ВСЕХ — бот с пустым ADMINS не отвечает никому и падает на старте.
    case "$admins" in
        ''|*[!0-9,]*|,*|*,|*,,*)
            err "chat_id — только цифры через запятую, без пробелов: «$admins»"
            err "Пример: bash install.sh --bot-admins 111222333,444555666"
            exit 2 ;;
    esac
    if [ -f "$DEST/bot.env" ] && grep -q '^AWG_BOT_ADMINS=' "$DEST/bot.env"; then
        sed -i "s#^AWG_BOT_ADMINS=.*#AWG_BOT_ADMINS=${admins}#" "$DEST/bot.env"
        log "Обновлён $DEST/bot.env"
    elif grep -q '^Environment=AWG_BOT_ADMINS=' "$unit" 2>/dev/null; then
        sed -i "s#^Environment=AWG_BOT_ADMINS=.*#Environment=AWG_BOT_ADMINS=${admins}#" "$unit"
        systemctl daemon-reload
        log "Обновлён $unit (раскладка до переноса токена в bot.env)"
    else
        err "не нашёл, где заданы админы: ни $DEST/bot.env, ни Environment= в юните"
        exit 1
    fi
    # STATE держим в согласии: из него setup_bot берёт значения при переустановке
    # слоя, и рассинхрон вернул бы старый список в самый неожиданный момент.
    if [ -f "$STATE" ] && grep -q '^AWG_BOT_ADMINS=' "$STATE"; then
        sed -i "s#^AWG_BOT_ADMINS=.*#AWG_BOT_ADMINS='${admins}'#" "$STATE"
    fi
    systemctl restart awg-bot
    log "Админы бота: $admins"
    log "Проверка:  journalctl -u awg-bot -n 3 --no-pager   (бот печатает список при старте)"
}

setup_bot() {  # вызывается из awg_layer при первичной установке (данные из STATE)
    [ "${AWG_BOT_INSTALL:-0}" = 1 ] || { log "Бот не выбран — пропуск"; return; }
    local t="${AWG_BOT_TOKEN:-}" a="${AWG_BOT_ADMINS:-}"
    # бот мог ставиться позже через --install-bot: тогда в STATE флаг есть,
    # а токена нет — берём действующие значения оттуда, где они реально лежат
    [ -z "$t" ] && t="$(bot_prev AWG_BOT_TOKEN)"
    [ -z "$a" ] && a="$(bot_prev AWG_BOT_ADMINS)"
    if [ -z "$t" ] || [ -z "$a" ]; then
        log "Бот: нет токена/chat_id — пропуск (доустановка: bash install.sh --install-bot)"
        return
    fi
    _deploy_bot "$t" "$a"
}

# ── доустановка бота ОТДЕЛЬНО, после установки слоя (--install-bot) ───────────
# Разовая миграция: у кого токен лежит в юните — переносим в bot.env и стираем.
migrate_bot_env() {
    local unit=/etc/systemd/system/awg-bot.service
    [ -f "$unit" ] || return 0
    grep -q '^Environment=AWG_BOT_TOKEN=' "$unit" || return 0
    local tok adm
    tok="$(grep -oP '^Environment=AWG_BOT_TOKEN=\K\S+' "$unit" || true)"
    adm="$(grep -oP '^Environment=AWG_BOT_ADMINS=\K\S+' "$unit" || true)"
    [ -n "$tok" ] || return 0
    log "Переношу токен бота из юнита в $DEST/bot.env (юнит читается всеми)"
    _deploy_bot "$tok" "$adm"
}

install_bot_only() {
    if [ ! -f /etc/amnezia/amneziawg/services.env ]; then
        log "Слой AmneziaWG ещё не установлен. Сначала: bash install.sh"
        exit 1
    fi
    local token="$CLI_BOT_TOKEN" admins="$CLI_BOT_ADMINS"
    # ре-инсталл поверх существующего бота: подставим прошлые значения как дефолт
    local prev_token="" prev_admins=""
    if [ -f /etc/systemd/system/awg-bot.service ]; then
        prev_token="$(bot_prev AWG_BOT_TOKEN)"
        prev_admins="$(bot_prev AWG_BOT_ADMINS)"
        log "Бот уже установлен — обновлю токен/админов (Enter = оставить текущее)."
    fi
    # Токен спрашиваем, только если его негде взять: менять один лишь список
    # админов — самая частая операция, и требовать ради неё лезть в @BotFather
    # за токеном незачем.
    if [ -z "$token" ] && [ -z "$prev_token" ]; then
        read -rp "  Токен бота (@BotFather): " token
    fi
    [ -z "$token" ] && token="$prev_token"
    if [ -z "$admins" ]; then
        read -rp "  chat_id админов (через запятую)${prev_admins:+ [$prev_admins]}: " admins
        [ -z "$admins" ] && admins="$prev_admins"
    fi
    if [ -z "$token" ] || [ -z "$admins" ]; then
        log "❌ Нужны и токен, и chat_id. Примеры:"
        log "   bash install.sh --install-bot 123456:ABC 111222333"
        log "   bash install.sh --bot-admins 111222333,444555666   (только админы)"
        exit 2
    fi
    _deploy_bot "$token" "$admins"
    # статистика могла быть не поднята, если слой ставили с --no-bot — гарантируем
    setup_stats
}

remove_bot_only() {
    if [ ! -f /etc/systemd/system/awg-bot.service ]; then
        log "Бот не установлен — нечего удалять."
        exit 0
    fi
    log "Удаляю Telegram-бот (слой AmneziaWG и клиенты остаются)…"
    systemctl disable --now awg-bot 2>/dev/null || true
    rm -f /etc/systemd/system/awg-bot.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$DEST/bot/awg_bot.py"
    [ -f "$STATE" ] && sed -i "s#^AWG_BOT_INSTALL=.*#AWG_BOT_INSTALL='0'#" "$STATE" 2>/dev/null || true
    log "✅ Бот удалён. Вернуть: bash install.sh --install-bot"
}

awg_layer() {
    [ -f "$STATE" ] && . "$STATE"
    local P="${AWG_PRESET:-medium}" T="${AWG_TEMPLATE:-}" F="${AWG_FP:-chrome}"
    # Пусто — значит слой 3.0 настраивается как 2.0. Так ведут себя установки,
    # сделанные до появления раздельных пресетов: у них в state только AWG_PRESET.
    local P3="${AWG_PRESET3:-}" T3="${AWG_TEMPLATE3:-}"
    local M="${AWG_MTU:-1320}" H="${AWG_HOST:-}"
    # В обычном прогоне --awg уже записан в state диалогом collect_choices.
    # План идёт мимо диалога, и без этой строки он показывал бы слои из
    # install-state.env вместо запрошенных.
    local V="${AWG_VER:-both}"
    case "$CLI_AWG_VER" in 2|3|both) V="$CLI_AWG_VER" ;; esac
    case "$V" in
        2)    log "Слой AmneziaWG 2.0 параллельно ванили (обфускация $P/${T:-default}, MTU $M)…" ;;
        3)    log "Слой AmneziaWG 3.0 параллельно ванили (userspace-датапас)…" ;;
        both) log "Слои AmneziaWG 2.0 и 3.0 параллельно ванили…" ;;
    esac
    # ветку передаём вниз: integration запишет её в .layer-branch, и проверка
    # обновлений будет сравнивать с той же веткой, откуда ставили
    # --reconfigure передаём вниз: без него интеграция не отличала бы
    # «обнови код» от «выпусти новый профиль» и перевыпускала бы всегда.
    # Через ${VAR:+…} нельзя: RECONFIGURE это 0 или 1, оба непустые, и
    # флаг уезжал бы вниз ВСЕГДА — то есть ровно наоборот.
    local rec="" plan=""
    # Явный --preset — тоже просьба сменить профиль: он минует меню (см. main),
    # и без этой ветки новый пресет попадал бы в install-state.env, а
    # obfuscation.env оставался прежним — `awg-obfuscation --show` врал бы.
    if [ "$RECONFIGURE" = 1 ] || [ -n "$CLI_PRESET" ]; then rec=--reconfigure; fi
    # --plan строит отчёт теми же функциями, что и реальный прогон,
    # и возвращается, ничего не изменив
    if [ "$PLAN" = 1 ]; then plan=--plan; fi
    AWG_REPO_BRANCH="$REPO_BRANCH" \
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" --awg "$V" $rec $plan \
        --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$M" ${H:+--host "$H"} \
        ${AZ_PORT_CHOICE:+--az-port "$AZ_PORT_CHOICE"} \
        ${VPN_PORT_CHOICE:+--vpn-port "$VPN_PORT_CHOICE"} \
        ${P3:+--preset3 "$P3"} ${T3:+--template3 "$T3"} \
        ${AZ3_PORT_CHOICE:+--az3-port "$AZ3_PORT_CHOICE"} \
        ${VPN3_PORT_CHOICE:+--vpn3-port "$VPN3_PORT_CHOICE"}
    # план на этом кончается: ни статистику, ни бота он не трогает
    [ "$PLAN" = 1 ] && return 0
    setup_stats
    setup_bot
    echo
    log "✅ Готово. Ванильный AntiZapret работает как раньше, AmneziaWG 2.0 — параллельно."
    log "   Порты AWG закреплены в /etc/amnezia/amneziawg/services.env"
    case "$V" in
        2) log "   Клиенты:  awg-client add myphone antizapret" ;;
        3) log "   Клиенты:  awg-client add myphone antizapret3   (слой 3.0)" ;;
        *) log "   Клиенты 2.0:  awg-client add myphone antizapret"
           log "   Клиенты 3.0:  awg-client add myphone antizapret3" ;;
    esac
    log "   Проверка связности:  awg-doctor"
}

# ── обновление кода без переконфигурации (обфускация, порты и клиенты не меняются)
update_layer() {
    base_installed || { log "AntiZapret не установлен — нечего обновлять"; exit 1; }
    if [ ! -f /etc/amnezia/amneziawg/services.env ]; then
        log "Слой AmneziaWG ещё не установлен. Запусти без --update для установки."
        exit 1
    fi
    log "Обновление AntiZapret-AWG (код и сервисы; обфускация, порты и клиенты НЕ трогаются)…"
    migrate_bot_env
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" --update
    setup_stats
    if [ -f /etc/systemd/system/awg-bot.service ]; then
        mkdir -p "$DEST/bot"
        cp "$REPO_DIR/bot/awg_bot.py" "$DEST/bot/"
        [ -d "$DEST/venv" ] && "$DEST/venv/bin/pip" install -q -r "$REPO_DIR/bot/requirements.txt" 2>/dev/null || true
        systemctl restart awg-bot 2>/dev/null || true
        log "Бот обновлён и перезапущен"
    fi
    echo
    log "✅ Обновление завершено. Уже созданные клиенты работают как раньше —"
    log "   переимпортировать конфиги НЕ нужно."
}

# ── миграция со старых режимов replace/keep на parallel ──────────────────────
migrate_layer() {
    if [ ! -f /etc/amnezia/amneziawg/services.env ]; then
        log "Слой AmneziaWG не установлен — мигрировать нечего."
        exit 1
    fi
    local cur; cur="$(. /etc/amnezia/amneziawg/services.env 2>/dev/null; echo "${MODE:-replace}")"
    # Метка незавершённой миграции важнее записанного режима: интеграция пишет
    # MODE=parallel вторым шагом, и после смерти на любом из следующих здесь
    # коротило бы на «миграция не нужна» — то есть штатный путь до починки не
    # доходил вовсе. Имя файла продублировано намеренно: install.sh не читает
    # переменные интеграции, и связь между ними держит тест.
    if [ "$cur" = parallel ] && [ ! -s /etc/amnezia/amneziawg/.migrate-in-progress ]; then
        log "Уже режим parallel — миграция не нужна."
        exit 0
    fi
    echo
    log "⚠️ Миграция режима '$cur' → parallel:"
    log "   • ванильный WireGuard вернётся в исходное состояние (порты, редиректы);"
    log "   • AmneziaWG переедет на интерфейсы antizapret-awg/vpn-awg и новый порт;"
    log "   • ключи клиентов сохранятся, но КОНФИГИ ПРИДЁТСЯ РАЗДАТЬ ЗАНОВО"
    [ "$cur" = replace ] && log "     (меняются порт Endpoint и туннельный IP)" \
                         || log "     (меняется порт Endpoint)"
    read -rp "Продолжить миграцию? [y/N]: " a
    case "${a:-N}" in y|Y) ;; *) log "Отменено"; exit 0 ;; esac
    [ -n "$CLI_PORTS" ] && parse_cli_ports
    [ -n "$CLI_PORTS3" ] && parse_cli_ports3
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" --migrate \
        ${AZ_PORT_CHOICE:+--az-port "$AZ_PORT_CHOICE"} \
        ${VPN_PORT_CHOICE:+--vpn-port "$VPN_PORT_CHOICE"}
}

# ── полное удаление слоя AmneziaWG (ваниль не трогается) ─────────────────────
remove_layer() {
    layer_installed || { log "Слой AmneziaWG не установлен — удалять нечего."; exit 0; }
    local AZ_IFACE="" VPN_IFACE="" AZ_SUBNET="" VPN_SUBNET=""
    # shellcheck disable=SC1091
    . /etc/amnezia/amneziawg/services.env 2>/dev/null || true
    AZ_IFACE="${AZ_IFACE:-antizapret-awg}"; VPN_IFACE="${VPN_IFACE:-vpn-awg}"
    echo
    log "⚠️ Полное удаление слоя AmneziaWG:"
    log "   • интерфейсы $AZ_IFACE/$VPN_IFACE, порты, профиль обфускации;"
    log "   • ВСЕ клиенты AWG 2.0 (ключи и конфиги в $DEST/clients);"
    log "   • Telegram-бот, статистика, таймеры, симлинки awg-client/awg-backup;"
    log "   • ванильный AntiZapret (WireGuard/OpenVPN) продолжит работать как раньше."
    if [ -x "$DEST/awg-backup.sh" ] && ask_yn "Сделать бэкап слоя перед удалением? [Y/n]: " y; then
        "$DEST/awg-backup.sh" || log "бэкап не удался — продолжаю"
    fi
    ask_yn "Точно удалить слой ПОЛНОСТЬЮ? [y/N]: " n || { log "Отменено"; exit 0; }

    log "Останавливаю сервисы…"
    systemctl disable --now awg-bot awg-stats.timer awg-expire.timer \
        awg-reintegrate.service 2>/dev/null || true
    systemctl stop awg-stats.service awg-expire.service 2>/dev/null || true
    for i in "$AZ_IFACE" "$VPN_IFACE"; do
        systemctl disable --now "awg-quick@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true
    done

    log "Убираю юниты, дроп-ины и симлинки…"
    rm -f /etc/systemd/system/awg-bot.service \
          /etc/systemd/system/awg-stats.service /etc/systemd/system/awg-stats.timer \
          /etc/systemd/system/awg-expire.service /etc/systemd/system/awg-expire.timer \
          /etc/systemd/system/awg-reintegrate.service
    rm -rf /etc/systemd/system/awg-quick@.service.d
    rm -f /etc/systemd/system/antizapret.service.d/awg-reintegrate.conf
    rmdir /etc/systemd/system/antizapret.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/awg-obfuscation /usr/local/bin/awg-client /usr/local/bin/awg-backup

    # DNS-view наших подсетей из kresd.conf (строки вида view:addr('X.Y.Z.1/24'…)
    local s gw
    for s in "$AZ_SUBNET" "$VPN_SUBNET"; do
        [ -n "$s" ] || continue
        gw="$s.1"
        sed -i "\#view:addr('${gw}/#d" /etc/knot-resolver/kresd.conf 2>/dev/null || true
    done
    systemctl restart kresd@1 2>/dev/null || true

    rm -rf /etc/amnezia/amneziawg "$DEST"
    systemctl restart antizapret 2>/dev/null || true
    echo
    log "✅ Слой AmneziaWG удалён. Ваниль работает штатно."
    log "   Пакеты amneziawg-tools и модуль ядра оставлены (не мешают);"
    log "   убрать вручную: apt remove amneziawg amneziawg-tools"
    log "   Поставить слой заново: bash install.sh"
}

# ── меню при повторном запуске без флагов на сервере с установленным слоем ───
menu_existing() {
    if [ ! -t 0 ]; then
        # автоматизация/pipe: молча ничего не ломаем — только безопасное обновление
        log "Слой AmneziaWG уже установлен, терминала нет — выполняю обновление кода"
        log "(обфускация, порты и клиенты не трогаются). Другие действия:"
        log "--reconfigure · --install-bot · --remove-bot · --uninstall"
        update_layer
        exit 0
    fi
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Слой AmneziaWG 2.0 уже установлен. Что сделать?"
    echo "   1) Переустановить заново (переспросить ВСЕ параметры;"
    echo "      новая обфускация → конфиги клиентов раздать заново)"
    echo "   2) Обновить обфускацию (новый профиль, настройки прежние;"
    echo "      конфиги клиентов раздать заново)"
    echo "   3) Telegram-бот: установить / обновить токен / удалить"
    echo "   4) Обновить слой — код и бот, обфускация/порты/клиенты"
    echo "      НЕ трогаются, ничего не ломается  [по умолчанию]"
    echo "   5) Удалить слой полностью (ваниль останется работать)"
    echo "   0) Выход"
    local m b
    read -rp "Выбор [4]: " m
    case "${m:-4}" in
        1)
            log "⚠️ Будет сгенерирован НОВЫЙ профиль обфускации: все розданные"
            log "   клиентам конфиги перестанут работать — их придётся раздать заново."
            ask_yn "Продолжить? [y/N]: " n || { log "Отменено"; exit 0; }
            RECONFIGURE=1
            collect_choices
            awg_layer
            ;;
        2)
            log "⚠️ Новый профиль обфускации с текущими настройками (пресет/шаблон/бот"
            log "   сохраняются). Розданные клиентам конфиги придётся раздать заново."
            ask_yn "Продолжить? [y/N]: " n || { log "Отменено"; exit 0; }
            collect_choices   # STATE есть → ответы берутся сохранённые, без вопросов
            # Пункт обещает НОВЫЙ профиль и уже взял подтверждение. Без этого
            # флага awg_layer уходит в --reapply и молча ничего не меняет —
            # владелец соглашается отключить всех и не получает ничего.
            RECONFIGURE=1
            awg_layer
            ;;
        3)
            if [ -f /etc/systemd/system/awg-bot.service ]; then
                echo "   1) Обновить токен/админов   2) Удалить бота   0) Назад"
                read -rp "Выбор [1]: " b
                case "${b:-1}" in
                    2) remove_bot_only ;;
                    0) log "Выход" ;;
                    *) install_bot_only ;;
                esac
            else
                install_bot_only
            fi
            ;;
        5) remove_layer ;;
        0) log "Выход" ;;
        *) update_layer ;;
    esac
    exit 0
}

# --plan: рассказать, не делая. Отдельная точка входа, потому что обычный
# путь main() по дороге к слою успевает и почистить устаревшие юниты, и уйти
# в --update/--migrate — то есть сделать настоящую работу вместо отчёта.
plan_entry() {
    local nope=""
    [ "$UNINSTALL" = 1 ]    && nope="--uninstall"
    [ "$INSTALL_BASE" = 1 ] && nope="--install-base"
    [ "$INSTALL_BOT" = 1 ]  && nope="--install-bot"
    [ "$REMOVE_BOT" = 1 ]   && nope="--remove-bot"
    if [ -n "$nope" ]; then
        # Молча проигнорировать флаг нельзя: пользователь ждал бы отчёта,
        # а получил бы отчёт про другое.
        err "--plan не умеет показывать $nope: у этой операции нет отчёта"
        err "Запусти её без --plan — или убери $nope, чтобы увидеть план слоя"
        return 2
    fi
    if ! base_installed; then
        log "AntiZapret не обнаружен — слой ставить не на что."
        log "План: сначала база (--install-base, сервер перезагрузится),"
        log "затем этот же скрипт без флагов поставит слой."
        return 0
    fi
    awg_layer
}

# ════════════════════════════════════════════════════════════════════════════
main() {
    # При установке через bash <(curl…) stdin занят потоком скрипта, и read
    # берёт данные оттуда, а не с клавиатуры (симптом: «y» будто проигнорирован).
    # Если есть управляющий терминал и мы в интерактивном сценарии — привязываем
    # stdin к нему на весь диалог.
    if [ -r /dev/tty ] && [ "$UPDATE" = 0 ] && [ "$MIGRATE" = 0 ] \
       && [ "$REMOVE_BOT" = 0 ] && [ "$PLAN" = 0 ]; then
        exec < /dev/tty
    fi
    # План — раньше всего остального: ниже уже чистится устаревший awg-resume,
    # а --update и --migrate уходят своей дорогой и сделали бы настоящую
    # работу вместо отчёта о ней.
    if [ "$PLAN" = 1 ]; then
        plan_entry
        exit $?
    fi
    # чистим устаревший awg-resume от прошлых версий установщика (больше не нужен)
    if [ -f /etc/systemd/system/awg-resume.service ]; then
        systemctl disable --now awg-resume.service 2>/dev/null || true
        rm -f /etc/systemd/system/awg-resume.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    if [ "$REMOVE_BOT" = 1 ]; then
        remove_bot_only
        exit 0
    fi
    # --bot-admins сам по себе (без --install-bot) меняет только список админов:
    # правка строки и рестарт юнита, без venv, pip и повторной раскладки бота.
    if [ "$INSTALL_BOT" = 0 ] && [ -n "$CLI_BOT_ADMINS" ] && [ -z "$CLI_BOT_TOKEN" ]; then
        set_bot_admins "$CLI_BOT_ADMINS"
        exit 0
    fi
    if [ "$UNINSTALL" = 1 ]; then
        [ -r /dev/tty ] && exec < /dev/tty
        remove_layer
        exit 0
    fi
    if [ "$INSTALL_BOT" = 1 ]; then
        install_bot_only
        exit 0
    fi
    if [ "$MIGRATE" = 1 ]; then
        migrate_layer
        exit 0
    fi
    if [ "$UPDATE" = 1 ]; then
        update_layer
        exit 0
    fi
    if [ "$INSTALL_BASE" = 1 ]; then
        install_base
        exit 0
    fi
    if ! base_installed; then
        echo
        log "AntiZapret не обнаружен (нет /root/antizapret/client.sh и up.sh)."
        log "Это слой AmneziaWG — он ставится ПАРАЛЛЕЛЬНО AntiZapret."
        log ""
        log "Поставь базу через этот же скрипт (важно: официальный установщик"
        log "GubernievS сейчас падает из-за просроченного GPG-ключа OpenVPN —"
        log "наш --install-base этот баг обходит):"
        log "    bash install.sh --install-base      # поставит базу и перезагрузит сервер"
        log "затем, после перезагрузки:"
        log "    bash install.sh                     # поставит слой AmneziaWG"
        exit 1
    fi
    log "AntiZapret обнаружен"
    # слой уже стоит, а явных флагов нет → меню вместо молчаливой переустановки
    # (раньше повторный запуск без флагов молча генерил новую обфускацию и ломал
    # все розданные клиентам конфиги). --reconfigure/--preset — осознанный выбор,
    # они идут по старому пути без меню.
    if layer_installed && [ "$RECONFIGURE" = 0 ] && [ -z "$CLI_PRESET" ]; then
        menu_existing   # выполняет выбранное действие и завершает скрипт
    fi
    log "Ставлю слой AmneziaWG 2.0 параллельно ванили (без перезагрузки)"
    collect_choices
    awg_layer
}
main
