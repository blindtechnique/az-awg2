#!/usr/bin/env bash
# awg-obfuscation.sh — интерактивная настройка обфускации AmneziaWG 2.0 для
# AntiZapret-AWG. Генерирует согласованный набор параметров (пресет + шаблон
# мимикрии), сохраняет его в state-файл и применяет ОДИНАКОВО к серверу и всем
# будущим клиентам. Может работать интерактивно (меню) и по флагам (для
# установщика и Telegram-бота).
#
# Использование:
#   awg-obfuscation.sh                 # интерактивное меню
#   awg-obfuscation.sh --preset high --template web --fp chrome --apply
#   awg-obfuscation.sh --show          # показать текущий профиль
#   awg-obfuscation.sh --regenerate    # перегенерировать I-пакеты (новые сигнатуры)
#
# Параметры (кроме Jc/Jmin/Jmax) обязаны совпадать client<->server — поэтому
# единый источник истины: $STATE_ENV. client-awg.sh читает его же.
set -euo pipefail

# ── пути ──────────────────────────────────────────────────────────────────────
AWG_DIR="/etc/amnezia/amneziawg"
STATE_ENV="${AWG_DIR}/obfuscation.env"          # AWG_* переменные (единый источник)
STATE_META="${AWG_DIR}/obfuscation.meta"        # preset/template/fp/host/mtu
GEN="$(dirname "$(readlink -f "$0")")/../obfuscation/awg_obfuscate.py"
[ -f "$GEN" ] || GEN="/opt/antizapret-awg/awg_obfuscate.py"   # fallback после установки
SERVER_ANTIZAPRET="${AWG_AZ_CONF:-${AWG_DIR}/antizapret.conf}"
SERVER_VPN="${AWG_VPN_CONF:-${AWG_DIR}/vpn.conf}"

PRESET="medium"; TEMPLATE=""; FP="chrome"; HOST=""; MTU=0; EXTREME=0
APPLY=0; SHOW=0; REGEN=0; INTERACTIVE=1

# ── парсинг флагов ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --preset)    PRESET="$2"; shift 2; INTERACTIVE=0 ;;
        --template)  TEMPLATE="$2"; shift 2; INTERACTIVE=0 ;;
        --fp)        FP="$2"; shift 2 ;;
        --host)      HOST="$2"; shift 2 ;;
        --mtu)       MTU="$2"; shift 2 ;;
        --extreme)   EXTREME=1; shift ;;
        --apply)     APPLY=1; INTERACTIVE=0; shift ;;
        --show)      SHOW=1; INTERACTIVE=0; shift ;;
        --regenerate) REGEN=1; INTERACTIVE=0; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;36m[awg-obf]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[awg-obf]\033[0m %s\n' "$*" >&2; }

# ── показать текущий профиль ─────────────────────────────────────────────────
show_current() {
    if [ -f "$STATE_META" ]; then
        log "Текущий профиль обфускации:"; sed 's/^/    /' "$STATE_META"
        echo
        log "Активные параметры (obfuscation.env):"; sed 's/^/    /' "$STATE_ENV"
    else
        err "Профиль ещё не сгенерирован. Запусти без --show."
    fi
}
[ "$SHOW" = 1 ] && { show_current; exit 0; }

# ── регенерация: те же preset/template, новые I-пакеты и H-диапазоны ──────────
if [ "$REGEN" = 1 ] && [ -f "$STATE_META" ]; then
    # shellcheck disable=SC1090
    . "$STATE_META"
    PRESET="${META_PRESET:-medium}"; TEMPLATE="${META_TEMPLATE:-}"
    FP="${META_FP:-chrome}"; HOST="${META_HOST:-}"; MTU="${META_MTU:-0}"
    log "Регенерация профиля: preset=$PRESET template=${TEMPLATE:-default} (новые сигнатуры)"
    APPLY=1
fi

# ── интерактивное меню ────────────────────────────────────────────────────────
if [ "$INTERACTIVE" = 1 ]; then
    echo "═══════════════════════════════════════════════════════════════"
    echo "  AntiZapret-AWG · настройка обфускации AmneziaWG 2.0"
    echo "═══════════════════════════════════════════════════════════════"
    echo "ПРЕСЕТ ИНТЕНСИВНОСТИ — сколько «шума» добавляем. Больше = скрытнее,"
    echo "но выше задержка и оверхед по трафику."
    echo
    echo "  1) router    — минимум шума. Для слабых устройств-клиентов"
    echo "                 (Keenetic/MikroTik/RPi) и мобильного интернета."
    echo "                 Ставь, если важнее стабильность и батарея."
    echo "  2) low       — лёгкая обфускация. Провайдер почти не мешает,"
    echo "                 нужен минимальный оверхед."
    echo "  3) medium    — сбалансированно [по умолчанию]. H-рандом + S1..S4 +"
    echo "                 1 профиль мимикрии. Подходит большинству."
    echo "  4) high      — агрессивный провайдер/оператор режет WireGuard."
    echo "                 Полный набор + 2 I-пакета + транспортная обфускация."
    echo "  5) paranoid  — жёсткие блокировки (мобильные операторы РФ с активной"
    echo "                 фильтрацией). Максимум, 3 профиля, MTU 1280 для сотовых."
    read -rp "Выбор [3]: " c; case "${c:-3}" in
        1) PRESET=router;; 2) PRESET=low;; 4) PRESET=high;; 5) PRESET=paranoid;; *) PRESET=medium;;
    esac
    echo
    echo "ШАБЛОН МИМИКРИИ — под какой протокол маскировать пакеты. Выбирай тот,"
    echo "что у ТВОЕГО провайдера точно НЕ блокируется и выглядит естественно."
    echo
    echo "  0) авто       — набор по умолчанию для пресета (безопасный выбор)"
    echo "  1) quic       — под QUIC/HTTP3 (видео, CDN, Discord). Универсально,"
    echo "                  если QUIC у провайдера ходит свободно."
    echo "  2) tls        — под HTTPS (TLS 1.3). Если QUIC режут, а 443/TLS — нет."
    echo "  3) web        — QUIC + TLS вместе. Смешанный веб-трафик, реалистично."
    echo "  4) voip       — под звонки/WebRTC (DTLS + SIP). Если у оператора VoIP"
    echo "                  приоритетный и не трогается."
    echo "  5) dns        — под DNS-запросы. Экзотика, для сетей где всё режут,"
    echo "                  кроме DNS (иногда работает в отелях/гостевых Wi-Fi)."
    echo "  6) mixed      — QUIC + TLS + DNS. Максимальная неоднородность профиля."
    echo
    echo "  Подсказка: не уверен — оставь 'авто' или выбери 'web'. Для мобильных"
    echo "  операторов РФ обычно хорошо заходит 'web' или 'quic'."
    read -rp "Выбор [0]: " t; case "${t:-0}" in
        1) TEMPLATE=quic;; 2) TEMPLATE=tls;; 3) TEMPLATE=web;; 4) TEMPLATE=voip;; 5) TEMPLATE=dns;; 6) TEMPLATE=mixed;; *) TEMPLATE="";;
    esac
    echo
    echo "ПРОФИЛЬ БРАУЗЕРА — под размеры пакетов какого браузера подгонять junk."
    echo "  1) chrome [по умолчанию, самый распространённый]  2) firefox  3) safari"
    read -rp "Выбор [1]: " f; case "${f:-1}" in 2) FP=firefox;; 3) FP=safari;; *) FP=chrome;; esac
    echo
    echo "Кастомный домен для мимикрии (напр. yandex.ru). Enter — из встроенного"
    echo "пула доступных из РФ доменов (Яндекс/VK/Сбер/госуслуги/CDN)."
    read -rp "Домен: " HOST
    echo
    read -rp "Применить к серверу и перезапустить туннели сейчас? [Y/n]: " a
    case "${a:-Y}" in n|N) APPLY=0;; *) APPLY=1;; esac
fi

# ── генерация ─────────────────────────────────────────────────────────────────
GEN_ARGS=(--preset "$PRESET" --fp "$FP")
[ -n "$TEMPLATE" ] && GEN_ARGS+=(--template "$TEMPLATE")
[ -n "$HOST" ] && GEN_ARGS+=(--host "$HOST")
[ "$MTU" != 0 ] && GEN_ARGS+=(--mtu "$MTU")
[ "$EXTREME" = 1 ] && GEN_ARGS+=(--extreme)

log "Генерация профиля: preset=$PRESET template=${TEMPLATE:-default} fp=$FP"
# ГЕНЕРИРУЕМ ПРОФИЛЬ ОДИН РАЗ (в env-формат). Серверный [Interface]-блок выводим
# из ТОГО ЖЕ env — иначе два вызова генератора дали бы разные случайные профили,
# и обфускация сервера не совпала бы с клиентами (клиенты читают этот же env) →
# handshake был бы невозможен.
ENV_BLOCK="$(python3 "$GEN" "${GEN_ARGS[@]}" --format env)"

# ── сохранить state ──────────────────────────────────────────────────────────
mkdir -p "$AWG_DIR"
umask 077
printf '%s\n' "$ENV_BLOCK" > "$STATE_ENV"
# серверный блок — строго из сохранённого env (порядок ключей фиксирован)
IFACE_BLOCK="$(
    . "$STATE_ENV"
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
        v="AWG_${k}"; val="${!v:-}"
        [ -n "$val" ] && printf '%s = %s\n' "$k" "$val"
    done
    true    # гарантируем нулевой код подоболочки (иначе set -e убьёт скрипт на пустом I5)
)"
cat > "$STATE_META" <<EOF
META_PRESET=$PRESET
META_TEMPLATE=$TEMPLATE
META_FP=$FP
META_HOST=$HOST
META_MTU=$MTU
META_GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log "Профиль сохранён в $STATE_ENV"
echo
echo "──────── сгенерированный [Interface]-блок ────────"
echo "$IFACE_BLOCK"
echo "──────────────────────────────────────────────────"

# ── применить к серверу ──────────────────────────────────────────────────────
apply_to_server() {
    local conf="$1" name="$2"
    [ -f "$conf" ] || { err "Не найден $conf — пропуск ($name)"; return 0; }
    # ВАЖНО: параметры обфускации (Jc/S/H/I) должны быть в [Interface] ДО [Peer],
    # иначе awg setconf падает с «Line unrecognized: Jc=..». Поэтому разделяем конфиг
    # на [Interface]-часть и [Peer]-часть, чистим старую обфускацию только в первой,
    # вставляем свежий блок в конец [Interface], затем дописываем peers.
    local iface peers
    iface="$(awk '/^\[Peer\]/{exit} {print}' "$conf" \
        | grep -vE '^__AWG_OBFUSCATION__$|^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5) *=' || true)"
    peers="$(awk '/^\[Peer\]/{p=1} p' "$conf" \
        | grep -vE '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5) *=' || true)"
    {
        # [Interface]-часть без хвостовых пустых строк
        printf '%s\n' "$iface" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
        printf '%s\n' "$IFACE_BLOCK"
        if [ -n "$peers" ]; then printf '\n%s\n' "$peers"; fi
    } > "$conf"
    log "Применено к $name ($conf)"
}

if [ "$APPLY" = 1 ]; then
    apply_to_server "$SERVER_ANTIZAPRET" "antizapret"
    apply_to_server "$SERVER_VPN" "vpn"
    az_iface="$(basename "$SERVER_ANTIZAPRET" .conf)"
    vpn_iface="$(basename "$SERVER_VPN" .conf)"
    for i in "$az_iface" "$vpn_iface"; do
        if systemctl list-unit-files | grep -q "awg-quick@"; then
            log "Перезапуск awg-quick@$i (чистый старт)"
            # stop + принудительный снос интерфейса (иначе awg-quick up: already exists) + start
            systemctl stop "awg-quick@$i" 2>/dev/null || true
            ip link del "$i" 2>/dev/null || true
            systemctl start "awg-quick@$i" || err "Не удалось поднять awg-quick@$i"
        fi
    done
    log "Готово. Клиентские конфиги синхронизируются автоматически (regen-all)."
else
    log "Профиль сгенерирован, но НЕ применён (--apply не задан)."
fi
