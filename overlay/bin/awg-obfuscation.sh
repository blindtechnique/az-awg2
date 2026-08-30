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
#   awg-obfuscation.sh --reapply       # разложить текущий профиль заново,
#                                      # НЕ меняя значений (обновление слоя)
#   awg-obfuscation.sh --regenerate    # перегенерировать I-пакеты (новые сигнатуры)
#
# Параметры (кроме Jc/Jmin/Jmax) обязаны совпадать client<->server — поэтому
# единый источник истины: $STATE_ENV. client-awg.sh читает его же.
set -euo pipefail

# ── пути ──────────────────────────────────────────────────────────────────────
AWG_DIR="${AWG_DIR:-/etc/amnezia/amneziawg}"   # переопределяется для тестов
# Слой 2.0 и слой 3.0 держат РАЗНЫЕ профили: у 3.0 другой набор параметров
# и другой MTU, а смешивать их нельзя — стороны должны совпадать внутри слоя.
STATE_ENV="${AWG_DIR}/obfuscation.env"          # AWG_* переменные (единый источник)
STATE_META="${AWG_DIR}/obfuscation.meta"        # preset/template/fp/host/mtu
GEN="$(dirname "$(readlink -f "$0")")/../obfuscation/awg_obfuscate.py"
[ -f "$GEN" ] || GEN="/opt/antizapret-awg/awg_obfuscate.py"   # fallback после установки
SERVER_ANTIZAPRET="${AWG_AZ_CONF:-${AWG_DIR}/antizapret.conf}"
SERVER_VPN="${AWG_VPN_CONF:-${AWG_DIR}/vpn.conf}"

PRESET="medium"; TEMPLATE=""; FP="chrome"; HOST=""; MTU=0; EXTREME=0
APPLY=0; SHOW=0; REGEN=0; INTERACTIVE=1
# --reapply: разложить уже сгенерированный профиль заново, ничего не меняя
REAPPLY=0
# --v3: генерировать профиль для слоя AmneziaWG 3.0 (свои файлы состояния,
# параметры header protection / content padding / таймингов)
V3=0

# ── парсинг флагов ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --preset)    PRESET="$2"; SET_PRESET=1; shift 2; INTERACTIVE=0 ;;
        --template)  TEMPLATE="$2"; SET_TEMPLATE=1; shift 2; INTERACTIVE=0 ;;
        --fp)        FP="$2"; SET_FP=1; shift 2 ;;
        --host)      HOST="$2"; SET_HOST=1; shift 2 ;;
        --mtu)       MTU="$2"; SET_MTU=1; shift 2 ;;
        --v3)        V3=1; INTERACTIVE=0; shift ;;
        --extreme)   EXTREME=1; shift ;;
        --apply)     APPLY=1; INTERACTIVE=0; shift ;;
        --reapply)   REAPPLY=1; APPLY=1; INTERACTIVE=0; shift ;;
        --show)      SHOW=1; INTERACTIVE=0; shift ;;
        --regenerate) REGEN=1; INTERACTIVE=0; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

# ── переключение на слой 3.0 ────────────────────────────────────────────────
if [ "$V3" = 1 ]; then
    STATE_ENV="${AWG_DIR}/obfuscation3.env"
    STATE_META="${AWG_DIR}/obfuscation3.meta"
    GEN="$(dirname "$(readlink -f "$0")")/../obfuscation/awg3_obfuscate.py"
    [ -f "$GEN" ] || GEN="/opt/antizapret-awg/awg3_obfuscate.py"
    SERVER_ANTIZAPRET="${AWG3_AZ_CONF:-${AWG_DIR}/antizapret-awg3.conf}"
    SERVER_VPN="${AWG3_VPN_CONF:-${AWG_DIR}/vpn-awg3.conf}"
fi

log() { printf '\033[1;36m[awg-obf]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[awg-obf]\033[0m %s\n' "$*" >&2; }

# ── показать текущий профиль ─────────────────────────────────────────────────
show_current() {
    if [ -f "$STATE_META" ]; then
        log "Текущий профиль обфускации:"; sed 's/^/    /' "$STATE_META"
        echo
        log "Активные параметры ($(basename "$STATE_ENV")):"; sed 's/^/    /' "$STATE_ENV"
    else
        err "Профиль ещё не сгенерирован. Запусти без --show."
    fi
}
[ "$SHOW" = 1 ] && { show_current; exit 0; }

# ── регенерация: те же preset/template, новые I-пакеты и H-диапазоны ──────────
if [ "$REGEN" = 1 ] && [ -f "$STATE_META" ]; then
    # Из метаданных берём только то, чего НЕ задали в командной строке. Раньше
    # они затирали всё подряд, и `--regenerate --preset medium` молча оставлял
    # прежний пресет: человек видел в выводе не тот, что просил, и решал, что
    # смена не сработала. Явный флаг должен быть сильнее сохранённого значения.
    saved_preset="$PRESET"; saved_template="$TEMPLATE"
    saved_fp="$FP"; saved_host="$HOST"; saved_mtu="$MTU"
    # shellcheck disable=SC1090
    . "$STATE_META"
    [ "${SET_PRESET:-0}" = 1 ]   && PRESET="$saved_preset"     || PRESET="${META_PRESET:-medium}"
    [ "${SET_TEMPLATE:-0}" = 1 ] && TEMPLATE="$saved_template" || TEMPLATE="${META_TEMPLATE:-}"
    [ "${SET_FP:-0}" = 1 ]       && FP="$saved_fp"             || FP="${META_FP:-chrome}"
    [ "${SET_HOST:-0}" = 1 ]     && HOST="$saved_host"         || HOST="${META_HOST:-}"
    [ "${SET_MTU:-0}" = 1 ]      && MTU="$saved_mtu"           || MTU="${META_MTU:-0}"
    if [ "${SET_PRESET:-0}" = 1 ] || [ "${SET_TEMPLATE:-0}" = 1 ]; then
        log "Регенерация профиля: preset=$PRESET template=${TEMPLATE:-default} (задано флагами)"
    else
        log "Регенерация профиля: preset=$PRESET template=${TEMPLATE:-default} (новые сигнатуры)"
    fi
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

if [ "$REAPPLY" = 1 ]; then
    # Профиль не трогаем: он уже согласован с выданными клиентами. Нужно лишь
    # разложить его заново — например после обновления кода слоя. Новый профиль
    # здесь означал бы обрыв связи у ВСЕХ выданных клиентов сразу.
    [ -s "$STATE_ENV" ] || { err "нет $STATE_ENV — нечего применять"; exit 1; }
    log "Повторное применение существующего профиля (значения не меняются)"
else
    log "Генерация профиля: preset=$PRESET template=${TEMPLATE:-default} fp=$FP"
    # ГЕНЕРИРУЕМ ПРОФИЛЬ ОДИН РАЗ (в env-формат). Серверный [Interface]-блок выводим
    # из ТОГО ЖЕ env — иначе два вызова генератора дали бы разные случайные профили,
    # и обфускация сервера не совпала бы с клиентами (клиенты читают этот же env) →
    # handshake был бы невозможен.
    ENV_BLOCK="$(python3 "$GEN" "${GEN_ARGS[@]}" --format env)"

    mkdir -p "$AWG_DIR"
    umask 077
    printf '%s\n' "$ENV_BLOCK" > "$STATE_ENV"
fi
umask 077
# серверный блок — строго из сохранённого env (порядок ключей фиксирован)
IFACE_BLOCK="$(
    . "$STATE_ENV"
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
        v="AWG_${k}"; val="${!v:-}"
        [ -n "$val" ] && printf '%s = %s\n' "$k" "$val"
    done
    true    # гарантируем нулевой код подоболочки (иначе set -e убьёт скрипт на пустом I5)
)"
# ── параметры 3.0 в формате UAPI ────────────────────────────────────────────
# amneziawg-tools (v1.0.20260618) их не парсит: `awg setconf` упал бы на
# «Line unrecognized». Поэтому они НЕ идут в .conf, а лежат в <iface>.v3 и
# применяются awg3-datapath.sh через UAPI-сокет уже после старта демона.
# Берём их из ТОГО ЖЕ STATE_ENV, что и блок [Interface], — второй запуск
# генератора дал бы другие случайные значения, и клиенты не сошлись бы с сервером.
V3_BLOCK=""
if [ "$V3" = 1 ]; then
    V3_BLOCK="$(
        # shellcheck disable=SC1090
        . "$STATE_ENV"
        [ -n "${AWG_HPK_HEX:-}" ] && printf 'header_protection_key=%s\n' "$AWG_HPK_HEX"
        [ -n "${AWG_ContentPaddingAddition:-}" ] && printf 'content_padding_addition=%s\n' "$AWG_ContentPaddingAddition"
        [ -n "${AWG_RekeyAfterTime:-}" ] && printf 'rekey_after_time=%s\n' "$AWG_RekeyAfterTime"
        [ -n "${AWG_RekeyTimeout:-}" ] && printf 'rekey_timeout=%s\n' "$AWG_RekeyTimeout"
        [ -n "${AWG_RejectAfterTime:-}" ] && printf 'reject_after_time=%s\n' "$AWG_RejectAfterTime"
        [ -n "${AWG_KeepaliveTimeout:-}" ] && printf 'keepalive_timeout=%s\n' "$AWG_KeepaliveTimeout"
        [ -n "${AWG_MaxHandshakeAttempts:-}" ] && printf 'max_handshake_attempts=%s\n' "$AWG_MaxHandshakeAttempts"
        true   # пустой хвост не должен ронять скрипт под set -e
    )"
fi

# При --reapply пресет не менялся, и переписывать метаданные незачем: иначе
# META_GENERATED сдвигался бы на каждое обновление слоя.
[ "$REAPPLY" = 1 ] || cat > "$STATE_META" <<EOF
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
if [ -n "$V3_BLOCK" ]; then
    echo "──────── параметры 3.0 (применяются через UAPI) ────────"
    # ключ header protection — это секрет, в лог юнита ему не место
    printf '%s\n' "$V3_BLOCK" | sed 's/^header_protection_key=.*/header_protection_key=(скрыт)/'
fi
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
        | grep -vE '^__AWG3?_OBFUSCATION__$|^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5) *=' || true)"
    peers="$(awk '/^\[Peer\]/{p=1} p' "$conf" \
        | grep -vE '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5) *=' || true)"
    {
        # [Interface]-часть без хвостовых пустых строк
        printf '%s\n' "$iface" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
        printf '%s\n' "$IFACE_BLOCK"
        if [ -n "$peers" ]; then printf '\n%s\n' "$peers"; fi
    } > "$conf"
    chmod 600 "$conf"
    # слой 3.0: рядом с конфигом кладём UAPI-файл с v3-параметрами
    local v3f="${conf%.conf}.v3"
    if [ -n "$V3_BLOCK" ]; then
        printf '%s\n' "$V3_BLOCK" > "$v3f"
        chmod 600 "$v3f"
    elif [ -f "$v3f" ]; then
        # Пустой блок означает «у этого профиля v3-параметров нет» — так
        # объявлены пресеты router и low. Прежний .v3 оставлять НЕЛЬЗЯ:
        # датапас применит его на ExecStartPost, сервер продолжит ждать header
        # protection, а клиентские конфиги уже перевыпущены без неё — не
        # подключится никто, и доктор до недавнего времени показывал ok.
        rm -f "$v3f"
        log "Убран прежний $v3f — у профиля нет параметров 3.0"
    fi
    log "Применено к $name ($conf)"
}

if [ "$APPLY" = 1 ]; then
    apply_to_server "$SERVER_ANTIZAPRET" "antizapret"
    apply_to_server "$SERVER_VPN" "vpn"
    az_iface="$(basename "$SERVER_ANTIZAPRET" .conf)"
    vpn_iface="$(basename "$SERVER_VPN" .conf)"
    # Слой 3.0 живёт в userspace-юните awg3@, а не в awg-quick@: у него свой
    # датапас (amneziawg-go) и v3-ключи, которые awg-tools не понимают —
    # их применяет awg3-datapath.sh через UAPI-сокет уже после старта.
    if [ "$V3" = 1 ]; then unit_pfx="awg3@"; else unit_pfx="awg-quick@"; fi
    # Наличие юнита проверяем БЕЗ конвейера. Прежнее
    #     systemctl list-unit-files | grep -q "$unit_pfx"
    # под `set -o pipefail` возвращает 141: `grep -q` выходит по первому
    # совпадению и закрывает читающий конец трубы, systemctl получает SIGPIPE
    # на остатке вывода — и весь конвейер считается упавшим. Условие оказывалось
    # ложным, перезапуск пропускался МОЛЧА, а скрипт всё равно печатал «Готово».
    # Профиль при этом лежал в файлах, но до работающего демона не доезжал.
    unit_present=0
    systemctl cat "${unit_pfx}.service" >/dev/null 2>&1 && unit_present=1
    # Есть ли чему ломаться. На ПЕРВОЙ установке юнитов ещё нет — их ставит
    # switch_services уже после обфускации, — интерфейсы не подняты, и тишина
    # тут норма. Ругаться и возвращать ненулевой код нужно только тогда, когда
    # туннель уже работает и только что разошёлся с записанным конфигом.
    live_any=0
    for i in "$az_iface" "$vpn_iface"; do
        ip link show "$i" >/dev/null 2>&1 && live_any=1
    done
    apply_failed=0
    if [ "$unit_present" = 1 ]; then
        for i in "$az_iface" "$vpn_iface"; do
            log "Перезапуск ${unit_pfx}${i} (чистый старт)"
            # stop + принудительный снос интерфейса (иначе up: already exists) + start
            systemctl stop "${unit_pfx}${i}" 2>/dev/null || true
            ip link del "$i" 2>/dev/null || true
            systemctl start "${unit_pfx}${i}" || {
                err "Не удалось поднять ${unit_pfx}${i}"
                [ "$live_any" = 1 ] && apply_failed=1
                # завершающий true обязателен: группа — правая часть ||,
                # и её ненулевой статус под set -e уронил бы скрипт
                true
            }
        done
    elif [ "$live_any" = 1 ]; then
        err "Юнит ${unit_pfx}.service не найден, а интерфейсы подняты."
        err "   Профиль записан в конфиги, но РАБОТАЮЩИЙ туннель его не получил:"
        err "   перезапусти интерфейсы вручную, иначе сервер и клиенты разойдутся."
        apply_failed=1
    else
        log "Юнитов ${unit_pfx}* ещё нет — профиль применится при их первом старте."
    fi
    # Параметры 3.0 живут только в памяти amneziawg-go и применяются из
    # <iface>.v3 на ExecStartPost. Если перезапуск не случился или UAPI
    # отказал, файлы будут правильные, а туннель — прежний. Снаружи это
    # расхождение не видно, поэтому проверяем и говорим вслух.
    if [ "$V3" = 1 ] && [ -n "$V3_BLOCK" ] && [ "$unit_present" = 1 ] \
        && [ "$unit_pfx" = "awg3@" ]; then
        v3_uapi="$(dirname "$(readlink -f "$0")")/awg3-uapi.py"
        [ -f "$v3_uapi" ] || v3_uapi="/opt/antizapret-awg/awg3-uapi.py"
        for i in "$az_iface" "$vpn_iface"; do
            live=""
            [ -f "$v3_uapi" ] && live="$(python3 "$v3_uapi" show "$i" 2>/dev/null || true)"
            case "$live" in
                *header_protection_key*) log "Параметры 3.0 приняты демоном ($i)" ;;
                *) err "Параметры 3.0 НЕ доехали до $i — туннель работает как 2.0."
                   err "   Смотри: journalctl -u ${unit_pfx}${i} -n 30 --no-pager"
                   apply_failed=1 ;;
            esac
        done
    fi
    if [ "$apply_failed" = 0 ]; then
        log "Готово. Клиентские конфиги синхронизируются автоматически (regen-all)."
    else
        err "НЕ ГОТОВО: профиль лёг в файлы, но до работающего туннеля не доехал."
        exit 3
    fi
else
    log "Профиль сгенерирован, но НЕ применён (--apply не задан)."
fi
