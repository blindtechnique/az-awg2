#!/usr/bin/env bash
# install.sh — установщик AntiZapret-AWG 2.0.
#
# МОДЕЛЬ (надёжная, без гонок с перезагрузкой): скрипт ставит слой настоящего
# AmneziaWG 2.0 ПОВЕРХ уже установленного AntiZapret. Базовый AntiZapret и его
# перезагрузка — отдельный шаг, не смешивается с нашим слоем.
#
# Использование:
#   1) если AntiZapret ещё НЕ установлен — сначала поставь базу (она перезагрузит сервер):
#        bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh) --install-base
#      …сервер перезагрузится…
#   2) затем поставь слой AmneziaWG:
#        bash <(curl -fsSL https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh)
#
# Флаги слоя AmneziaWG:
#   --keep-wireguard   оставить ванильный WireGuard активным (AWG на портах 52443/52080),
#                      по умолчанию WG заменяется на AmneziaWG на тех же портах 51443/51080
#   --preset X --template Y --fp Z   обфускация без вопросов
#   --no-bot           не спрашивать про Telegram-бота
#   --reconfigure      переспросить параметры заново
set -euo pipefail

REPO_URL="https://github.com/fageoner/Antizapret-AWG-2.0"
REPO_BRANCH="${AWG_REPO_BRANCH:-main}"
UPSTREAM_REPO="https://github.com/GubernievS/AntiZapret-VPN.git"
DEST="/opt/antizapret-awg"
STATE="/opt/antizapret-awg/install-state.env"

INSTALL_BASE=0; NO_BOT=0; RECONFIGURE=0; KEEP_WG=0
CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""

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
        --keep-wireguard) KEEP_WG=1; shift ;;
        --no-bot) NO_BOT=1; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
        --preset) CLI_PRESET="$2"; shift 2 ;;
        --template) CLI_TEMPLATE="$2"; shift 2 ;;
        --fp) CLI_FP="$2"; shift 2 ;;
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
    log "станет базой для AmneziaWG; OpenVPN оставь). В конце сервер ПЕРЕЗАГРУЗИТСЯ."
    log "После перезагрузки поставь слой AmneziaWG:  bash install.sh"
    echo
    bash "$tmp/AntiZapret-VPN/setup.sh"
}

# ════════════════════════════════════════════════════════════════════════════
#  ШАГ 2: слой AmneziaWG поверх установленного AntiZapret (без перезагрузки)
# ════════════════════════════════════════════════════════════════════════════
collect_choices() {
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ] && [ -z "$CLI_PRESET" ]; then
        . "$STATE"
        [ "${AWG_KEEP_WG:-0}" = 1 ] && KEEP_WG=1
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
        if [ "$KEEP_WG" = 0 ]; then
            echo
            echo "  Ванильный WireGuard: по умолчанию заменяется на AmneziaWG (те же порты"
            echo "  51443/51080). Оставить ванильный WG активным ПАРАЛЛЕЛЬНО (AmneziaWG"
            echo "  тогда на портах 52443/52080)?"
            read -rp "  Оставить ванильный WireGuard? [y/N]: " kw
            case "${kw:-N}" in y|Y) KEEP_WG=1;; esac
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
AWG_KEEP_WG='$KEEP_WG'
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

setup_bot() {
    [ "${AWG_BOT_INSTALL:-0}" = 1 ] || { log "Бот не выбран — пропуск"; return; }
    log "Установка бота…"
    mkdir -p "$DEST/bot"; cp "$REPO_DIR/bot/awg_bot.py" "$DEST/bot/"
    [ -d "$DEST/venv" ] || python3 -m venv "$DEST/venv"
    "$DEST/venv/bin/pip" install -q -r "$REPO_DIR/bot/requirements.txt"
    sed -e "s#PASTE_TOKEN_HERE#${AWG_BOT_TOKEN}#" \
        -e "s#^Environment=AWG_BOT_ADMINS=.*#Environment=AWG_BOT_ADMINS=${AWG_BOT_ADMINS}#" \
        "$REPO_DIR/bot/awg-bot.service" > /etc/systemd/system/awg-bot.service
    systemctl daemon-reload; systemctl enable --now awg-bot
    log "Бот запущен. Напиши ему /start"
}

awg_layer() {
    [ -f "$STATE" ] && . "$STATE"
    local P="${AWG_PRESET:-medium}" T="${AWG_TEMPLATE:-}" F="${AWG_FP:-chrome}"
    local M="${AWG_MTU:-1320}" H="${AWG_HOST:-}"
    log "Слой AmneziaWG 2.0 (обфускация $P/${T:-default}, MTU $M$([ "$KEEP_WG" = 1 ] && echo ', WG сохранён'))…"
    bash "$REPO_DIR/patches/antizapret-awg-integration.sh" \
        --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$M" ${H:+--host "$H"} \
        $([ "$KEEP_WG" = 1 ] && echo --keep-wireguard)
    setup_stats
    setup_bot
    echo
    log "✅ Готово. Управление клиентами (OpenVPN и AmneziaWG) — через бота или:"
    log "   awg-client add myphone antizapret"
}

# ════════════════════════════════════════════════════════════════════════════
main() {
    # чистим устаревший awg-resume от прошлых версий установщика (больше не нужен)
    if [ -f /etc/systemd/system/awg-resume.service ]; then
        systemctl disable --now awg-resume.service 2>/dev/null || true
        rm -f /etc/systemd/system/awg-resume.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    if [ "$INSTALL_BASE" = 1 ]; then
        install_base
        exit 0
    fi
    if ! base_installed; then
        echo
        log "AntiZapret не обнаружен (нет /root/antizapret/client.sh и up.sh)."
        log "Это слой AmneziaWG — он ставится ПОВЕРХ AntiZapret."
        log ""
        log "Поставь базу через этот же скрипт (важно: официальный установщик"
        log "GubernievS сейчас падает из-за просроченного GPG-ключа OpenVPN —"
        log "наш --install-base этот баг обходит):"
        log "    bash install.sh --install-base      # поставит базу и перезагрузит сервер"
        log "затем, после перезагрузки:"
        log "    bash install.sh                     # поставит слой AmneziaWG"
        exit 1
    fi
    log "AntiZapret обнаружен — ставлю слой AmneziaWG 2.0 (без перезагрузки)"
    collect_choices
    awg_layer
}
main
