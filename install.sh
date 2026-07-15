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
#        bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh) --install-base
#      …сервер перезагрузится…
#   2) затем поставь слой AmneziaWG:
#        bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh)
#
# Флаги слоя AmneziaWG:
#   --awg-ports A,V    зафиксировать порты вручную (antizapret,vpn),
#                      по умолчанию — рандомные свободные с закреплением
#   --preset X --template Y --fp Z   обфускация без вопросов
#   --no-bot           не спрашивать про Telegram-бота
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
#   --bot-admins X     chat_id (через запятую) для --install-bot без интерактива
#   --remove-bot       удалить только Telegram-бот (слой AmneziaWG остаётся)
set -euo pipefail

REPO_URL="https://github.com/fageoner/Antizapret-AWG-2.0"
REPO_BRANCH="${AWG_REPO_BRANCH:-main}"
UPSTREAM_REPO="https://github.com/GubernievS/AntiZapret-VPN.git"
DEST="/opt/antizapret-awg"
STATE="/opt/antizapret-awg/install-state.env"

INSTALL_BASE=0; NO_BOT=0; RECONFIGURE=0; UPDATE=0; MIGRATE=0
INSTALL_BOT=0; REMOVE_BOT=0
CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""; CLI_PORTS=""
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
    exec env AWG_NO_BOOTSTRAP=1 bash "$BOOT_DIR/repo/install.sh" "$@"
fi
REPO_DIR="$SELF_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --install-base) INSTALL_BASE=1; shift ;;
        --update) UPDATE=1; shift ;;
        --migrate) MIGRATE=1; shift ;;
        --install-bot)
            INSTALL_BOT=1; shift
            # опциональные позиционные: токен и chat_id (если не начинаются с --)
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then CLI_BOT_TOKEN="$1"; shift; fi
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then CLI_BOT_ADMINS="$1"; shift; fi ;;
        --remove-bot) REMOVE_BOT=1; shift ;;
        --bot-token) CLI_BOT_TOKEN="$2"; shift 2 ;;
        --bot-admins) CLI_BOT_ADMINS="$2"; shift 2 ;;
        --awg-ports) CLI_PORTS="$2"; shift 2 ;;
        --no-bot) NO_BOT=1; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
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

# зарезервировано ванилью: WG 51443/51080, «-am» редирект 52443/52080, резерв WG
# 540/580, резерв OpenVPN 80/443/504/508, реальный OpenVPN 50080/50443, 1194, 53, 22
RESERVED_PORTS="22 53 80 443 504 508 540 580 1194 50080 50443 51080 51443 52080 52443"
port_reserved() { printf '%s\n' $RESERVED_PORTS | grep -qx "$1"; }
port_busy() { ss -lunH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | grep -qx "$1"; }
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
parse_cli_ports() {  # "1234,5678" → AZ_PORT_CHOICE/VPN_PORT_CHOICE
    AZ_PORT_CHOICE="${CLI_PORTS%%,*}"; VPN_PORT_CHOICE="${CLI_PORTS##*,}"
    if ! valid_port "$AZ_PORT_CHOICE" || ! valid_port "$VPN_PORT_CHOICE" \
        || [ "$AZ_PORT_CHOICE" = "$VPN_PORT_CHOICE" ]; then
        log "❌ --awg-ports: нужно два разных порта 1-65535 через запятую, напр. 34567,45678"
        exit 2
    fi
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

collect_choices() {
    AZ_PORT_CHOICE=""; VPN_PORT_CHOICE=""
    [ -n "$CLI_PORTS" ] && parse_cli_ports
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ] && [ -z "$CLI_PRESET" ]; then
        . "$STATE"
        # порты при повторном запуске всегда берутся из services.env (закреплены) —
        # ответы из state здесь не применяем, чтобы не «переехать» случайно
        log "Использую сохранённые ответы (обфускация ${AWG_PRESET:-medium}/${AWG_TEMPLATE:-default}, бот $([ "${AWG_BOT_INSTALL:-0}" = 1 ] && echo да || echo нет)). Сброс: --reconfigure"
        return
    fi
    local PRESET="medium" TEMPLATE="" FP="chrome" MTU=1320 HOST="" BOT_INSTALL=0 BOT_TOKEN="" BOT_ADMINS=""
    if [ -n "$CLI_PRESET" ]; then
        PRESET="$CLI_PRESET"; TEMPLATE="$CLI_TEMPLATE"; FP="${CLI_FP:-chrome}"
    else
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Обфускация AmneziaWG 2.0 — интенсивность"
        echo "   1) router  2) low  3) medium [по умолч.]  4) high  5) paranoid"
        echo "   4) high — если провайдер режет WireGuard; 5) paranoid — жёсткие блокировки РФ"
        read -rp "Выбор [3]: " x; case "${x:-3}" in 1) PRESET=router;;2) PRESET=low;;4) PRESET=high;;5) PRESET=paranoid;;*) PRESET=medium;; esac
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
        [[ "$MTU" =~ ^[0-9]+$ ]] || MTU=1320
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
        fi
    fi
    if [ "$NO_BOT" = 0 ]; then
        echo
        read -rp "Установить Telegram-бот (клиенты OpenVPN+AmneziaWG, статистика, бэкап)? [y/N]: " b
        case "${b:-N}" in y|Y)
            read -rp "  Токен бота (@BotFather): " BOT_TOKEN
            read -rp "  Твой chat_id: " BOT_ADMINS
            [ -n "$BOT_TOKEN" ] && [ -n "$BOT_ADMINS" ] && BOT_INSTALL=1 || log "Токен/admin пустые — бот пропущен" ;;
        esac
    fi
    mkdir -p "$(dirname "$STATE")"; umask 077
    cat > "$STATE" <<EOF
AWG_PRESET='$PRESET'
AWG_TEMPLATE='$TEMPLATE'
AWG_FP='$FP'
AWG_BOT_INSTALL='$BOT_INSTALL'
AWG_BOT_TOKEN='$BOT_TOKEN'
AWG_BOT_ADMINS='$BOT_ADMINS'
AWG_MTU='$MTU'
AWG_HOST='$HOST'
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
    sed -e "s#PASTE_TOKEN_HERE#${token}#" \
        -e "s#^Environment=AWG_BOT_ADMINS=.*#Environment=AWG_BOT_ADMINS=${admins}#" \
        "$REPO_DIR/bot/awg-bot.service" > /etc/systemd/system/awg-bot.service
    systemctl daemon-reload; systemctl enable --now awg-bot
    # запомним факт установки бота в state (для --update)
    if [ -f "$STATE" ]; then
        sed -i "s#^AWG_BOT_INSTALL=.*#AWG_BOT_INSTALL='1'#" "$STATE" 2>/dev/null \
            || echo "AWG_BOT_INSTALL='1'" >> "$STATE"
    fi
    log "Бот запущен. Напиши ему /start"
}

setup_bot() {  # вызывается из awg_layer при первичной установке (данные из STATE)
    [ "${AWG_BOT_INSTALL:-0}" = 1 ] || { log "Бот не выбран — пропуск"; return; }
    _deploy_bot "${AWG_BOT_TOKEN}" "${AWG_BOT_ADMINS}"
}

# ── доустановка бота ОТДЕЛЬНО, после установки слоя (--install-bot) ───────────
install_bot_only() {
    if [ ! -f /etc/amnezia/amneziawg/services.env ]; then
        log "Слой AmneziaWG ещё не установлен. Сначала: bash install.sh"
        exit 1
    fi
    local token="$CLI_BOT_TOKEN" admins="$CLI_BOT_ADMINS"
    # ре-инсталл поверх существующего бота: подставим прошлые значения как дефолт
    local prev_token="" prev_admins=""
    if [ -f /etc/systemd/system/awg-bot.service ]; then
        prev_token="$(grep -oP 'AWG_BOT_TOKEN=\K\S+' /etc/systemd/system/awg-bot.service 2>/dev/null || true)"
        prev_admins="$(grep -oP 'AWG_BOT_ADMINS=\K\S+' /etc/systemd/system/awg-bot.service 2>/dev/null || true)"
        log "Бот уже установлен — обновлю токен/админов (Enter = оставить текущее)."
    fi
    if [ -z "$token" ]; then
        read -rp "  Токен бота (@BotFather)${prev_token:+ [оставить текущий]}: " token
        [ -z "$token" ] && token="$prev_token"
    fi
    if [ -z "$admins" ]; then
        read -rp "  chat_id админов (через запятую)${prev_admins:+ [$prev_admins]}: " admins
        [ -z "$admins" ] && admins="$prev_admins"
    fi
    if [ -z "$token" ] || [ -z "$admins" ]; then
        log "❌ Нужны и токен, и chat_id. Пример:"
        log "   bash install.sh --install-bot 123456:ABC 111222333"
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
    local M="${AWG_MTU:-1320}" H="${AWG_HOST:-}"
    log "Слой AmneziaWG 2.0 параллельно ванили (обфускация $P/${T:-default}, MTU $M)…"
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" \
        --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$M" ${H:+--host "$H"} \
        ${AZ_PORT_CHOICE:+--az-port "$AZ_PORT_CHOICE"} \
        ${VPN_PORT_CHOICE:+--vpn-port "$VPN_PORT_CHOICE"}
    setup_stats
    setup_bot
    echo
    log "✅ Готово. Ванильный AntiZapret работает как раньше, AmneziaWG 2.0 — параллельно."
    log "   Порты AWG закреплены в /etc/amnezia/amneziawg/services.env"
    log "   Управление клиентами — через бота или:  awg-client add myphone antizapret"
}

# ── обновление кода без переконфигурации (обфускация, порты и клиенты не меняются)
update_layer() {
    base_installed || { log "AntiZapret не установлен — нечего обновлять"; exit 1; }
    if [ ! -f /etc/amnezia/amneziawg/services.env ]; then
        log "Слой AmneziaWG ещё не установлен. Запусти без --update для установки."
        exit 1
    fi
    log "Обновление AntiZapret-AWG (код и сервисы; обфускация, порты и клиенты НЕ трогаются)…"
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
    if [ "$cur" = parallel ]; then
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
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" --migrate \
        ${AZ_PORT_CHOICE:+--az-port "$AZ_PORT_CHOICE"} \
        ${VPN_PORT_CHOICE:+--vpn-port "$VPN_PORT_CHOICE"}
}

# ════════════════════════════════════════════════════════════════════════════
main() {
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
    log "AntiZapret обнаружен — ставлю слой AmneziaWG 2.0 параллельно (без перезагрузки)"
    collect_choices
    awg_layer
}
main
