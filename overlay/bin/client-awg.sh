#!/usr/bin/env bash
# client-awg.sh — генерация клиента AmneziaWG для AntiZapret-AWG.
# Делает: ключи (awg) → выбор свободного IP → добавление peer в серверный
# интерфейс (awg set + запись в .conf) → рендер клиентского .conf с ЕДИНЫМ
# профилем обфускации → QR (сырой .conf) + vpn:// URI + QR URI.
#
# Использование:
#   client-awg.sh add   <name> [antizapret|vpn] [--ttl 2h]  # создать (TTL: 30m/2h/7d)
#   client-awg.sh del   <name> [antizapret|vpn]    # удалить клиента
#   client-awg.sh list  [antizapret|vpn]           # список
#   client-awg.sh regen-all                        # пересоздать конфиги всех
#                                                    (после смены обфускации)
#   client-awg.sh expire-check                     # удалить просроченные (по таймеру)
# Профиль обфускации берётся из /etc/amnezia/amneziawg/obfuscation.env
# (единый источник, тот же, что применён к серверу — иначе туннель не встанет).
set -euo pipefail

AWG_DIR="/etc/amnezia/amneziawg"
STATE_ENV="${AWG_DIR}/obfuscation.env"
CLIENT_DIR="/opt/antizapret-awg/clients"
SELF_DIR="$(dirname "$(readlink -f "$0")")"
EXPORT="${SELF_DIR}/awg-export.py"
[ -f "$EXPORT" ] || EXPORT="${SELF_DIR}/../bin/awg-export.py"

log() { printf '\033[1;36m[client-awg]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[client-awg]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# ── замок на состояние слоя ────────────────────────────────────────────────
# Под ним: серверные конфиги, каталог клиентов, expiry.tsv, stats.db. Берётся
# внутри самих скриптов, а не в юнитах, — тогда под него попадают сразу все
# входы: бот, меню, ssh и оба таймера (awg-stats раз в минуту, awg-expire раз
# в пять). Образец — flock в bot/awg_bot.py, но там обёртка `flock файл cmd`,
# а здесь нужен ДЕСКРИПТОР: замок обязан быть отпущен до перезапуска сервисов.
#
# Файл отдельный от /run/antizapret-client.lock: тот принадлежит ванильному
# client.sh и защищает /etc/wireguard — другой объект и другое время удержания.
#
# /run, а не /tmp: у бота в юните PrivateTmp=true, его /tmp отдельный, и замок
# в /tmp не сериализовал бы ничего, при этом выглядя рабочим. И не в $DEST —
# этот каталог переписывает само восстановление, а смена inode у файла замка
# означала бы две стороны, держащие РАЗНЫЕ замки, без единого признака беды.
AWG_LOCK="${AWG_LOCK:-/run/antizapret-awg.lock}"

# Возвращает 0 (открыт), 2 (нет flock), 3 (не открыть файл) — разные беды,
# и путать их нельзя: «нет flock» там, где flock есть, отправляет искать не то.
_lock_open() {
    command -v flock >/dev/null 2>&1 || return 2
    # Фигурные скобки обязательны. `exec 9>файл` с неудачной перенаправкой
    # завершает неинтерактивную оболочку ЦЕЛИКОМ — `|| return` до неё не
    # доходит; а `2>/dev/null`, приписанное к самому exec, применяется уже
    # после открытия и сообщения не прячет. Без скобок восстановление на
    # машине с недоступным на запись /run обрывалось посреди работы.
    { exec 9>"$AWG_LOCK"; } 2>/dev/null || return 3
}
_lock_excuse() {  # _lock_excuse <код _lock_open> <что защищаем>
    case "$1" in
        2) err "нет flock (пакет util-linux): $2 идёт без защиты от таймеров" ;;
        *) err "не открыть замок $AWG_LOCK: $2 идёт без защиты от таймеров" ;;
    esac
}
# Для ручных операций: ждём. Отдельный код 1 именно на «не дождались» — у
# `flock -w` на команде код 1 неотличим от отказа самой команды.
lock_wait() {  # lock_wait <секунд> <что защищаем>
    local o=0
    _lock_open || o=$?
    [ "$o" = 0 ] || { _lock_excuse "$o" "$2"; return 0; }
    flock -w "$1" 9 && return 0
    err "$2: за $1 с не удалось взять $AWG_LOCK — идёт другая операция"
    return 1
}
# Для таймеров: не ждём ни секунды. У oneshot-юнитов TimeoutStartSec по
# умолчанию 90 с, и ожидание кончилось бы SIGTERM посреди правки файлов.
lock_try() {  # lock_try <что защищаем>
    local o=0
    _lock_open || o=$?
    [ "$o" = 0 ] || { _lock_excuse "$o" "$1"; return 0; }
    flock -n 9
}
# Скобки и здесь обязательны, но по другой причине, чем в _lock_open:
# `exec` БЕЗ команды применяет перенаправления к самой оболочке НАВСЕГДА,
# так что `exec 9>&- 2>/dev/null` тихо уводил в /dev/null весь дальнейший
# stderr скрипта — вместе с сообщениями о неподнявшихся сервисах.
lock_drop() { { exec 9>&-; } 2>/dev/null || true; }


# ── определить сервис/интерфейс/подсеть/порт ─────────────────────────────────
# параметры сервисов пишет integration в services.env (зависят от режима replace/keep)
SERVICES="${AWG_DIR}/services.env"
resolve_service() {
    local svc="${1:-antizapret}"
    [ -f "$SERVICES" ] && . "$SERVICES"
    # LAYER=2 — kernel-модуль (обычные сервисы), LAYER=3 — userspace-датапас.
    # От него зависят и профиль обфускации, и MTU, и способ перезагрузки peers.
    LAYER=2
    case "$svc" in
        antizapret)
            IFACE="${AZ_IFACE:-antizapret}"; SUBNET="${AZ_SUBNET:-10.29.8}"
            PORT="${AZ_PORT:-51443}"; DNS_SRV="${AZ_DNS:-10.29.8.1}"; SPLIT="${AZ_SPLIT:-1}" ;;
        vpn)
            IFACE="${VPN_IFACE:-vpn}"; SUBNET="${VPN_SUBNET:-10.28.8}"
            PORT="${VPN_PORT:-51080}"; DNS_SRV="${VPN_DNS:-10.29.8.1}"; SPLIT="${VPN_SPLIT:-0}" ;;
        antizapret3)
            [ "${LAYER3:-0}" = 1 ] || die "Слой 3.0 не установлен (install.sh --awg both)"
            IFACE="${AZ3_IFACE:-antizapret-awg3}"; SUBNET="${AZ3_SUBNET:-10.29.10}"
            PORT="${AZ3_PORT:-0}"; DNS_SRV="${AZ3_DNS:-10.29.8.1}"; SPLIT="${AZ3_SPLIT:-1}"
            LAYER=3; MTU="${MTU3:-1380}" ;;
        vpn3)
            [ "${LAYER3:-0}" = 1 ] || die "Слой 3.0 не установлен (install.sh --awg both)"
            IFACE="${VPN3_IFACE:-vpn-awg3}"; SUBNET="${VPN3_SUBNET:-10.28.10}"
            PORT="${VPN3_PORT:-0}"; DNS_SRV="${VPN3_DNS:-10.29.8.1}"; SPLIT="${VPN3_SPLIT:-0}"
            LAYER=3; MTU="${MTU3:-1380}" ;;
        *) die "Неизвестный сервис: $svc (antizapret|vpn|antizapret3|vpn3)" ;;
    esac
    SERVER_CONF="${AWG_DIR}/${IFACE}.conf"
    [ -f "$SERVER_CONF" ] || die "Нет серверного конфига $SERVER_CONF"
}

# ── единый профиль обфускации (как AWG_OBFUSCATION для рендера клиента) ───────
load_obfuscation() {
    # у слоя 3.0 свой профиль и свои параметры, которых нет в 2.0
    local keys="Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5"
    # STATE_ENV задаём явно в обеих ветках: regen-all перебирает сервисы обоих
    # слоёв в одном процессе, и «залипшее» значение указало бы на чужой профиль.
    STATE_ENV="${AWG_DIR}/obfuscation.env"
    if [ "${LAYER:-2}" = 3 ]; then
        STATE_ENV="${AWG_DIR}/obfuscation3.env"
        keys="$keys HeaderProtectionKey ContentPaddingAddition RekeyAfterTime"
        keys="$keys RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts"
    fi
    [ -f "$STATE_ENV" ] || die "Нет $STATE_ENV — сначала запусти awg-obfuscation.sh"
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    AWG_OBFUSCATION=""
    for k in $keys; do
        v="AWG_${k}"; val="${!v:-}"
        [ -n "$val" ] && AWG_OBFUSCATION+="${k} = ${val}"$'\n'
    done
    AWG_OBFUSCATION="${AWG_OBFUSCATION%$'\n'}"
}

server_pubkey() {
    # cut -d= -f2- сохраняет хвостовой '=' base64-ключа (awk -F' *= *' его обрезал!)
    # Читаем отдельно, а не одной трубой в awg pubkey: под pipefail grep без
    # совпадения отдаёт 1, и вся команда умирала молча — без единой строки о
    # том, что в серверном конфиге нет ключа. Пустой ключ здесь означает
    # ненастроенный сервер, и сказать это надо вслух.
    local priv
    priv="$(grep '^PrivateKey' "$SERVER_CONF" | head -1 | cut -d= -f2- | tr -d ' \t' || true)"
    [ -n "$priv" ] || die "в $SERVER_CONF нет PrivateKey — сервер не настроен"
    printf '%s' "$priv" | awg pubkey
}

# реальный внешний хост: домен из настроек AntiZapret или публичный IP сервера
server_host() {
    local h=""
    [ -f /root/antizapret/setup ] && h="$(. /root/antizapret/setup 2>/dev/null; echo "${WIREGUARD_HOST:-}")"
    # `|| true` внутри подстановки: правый операнд || — последняя команда
    # списка, поэтому set -e срабатывает на ней в полную силу, и отказ ip или
    # грепа без совпадения обрывал скрипт, не доходя до запасного варианта
    # через api.ipify.org ниже.
    if [ -z "$h" ]; then
        h="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+' || true)"
        # Фильтруем только УГАДАННОЕ. Объявленный WIREGUARD_HOST не оспариваем
        # никогда: 192.168.1.10 у домашнего сервера в той же локалке законен.
        # А вот приватный src за NAT, который скрипт угадал сам, уезжает прямо
        # в Endpoint клиента и делает конфиг мёртвым, называясь созданным.
        case "$h" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|127.*|169.254.*|0.0.0.0|"") h="" ;; esac
    fi
    [ -n "$h" ] || h="$(curl -s https://api.ipify.org)"
    echo "$h"
}

# ── выбор свободного IP в подсети ────────────────────────────────────────────
next_ip() {
    local used; used="$(grep -oE "AllowedIPs = ${SUBNET//./\\.}\.[0-9]+" "$SERVER_CONF" \
        | grep -oE '[0-9]+$' || true)"
    local i
    for i in $(seq 2 254); do
        # Без трубы: `echo | grep -q` под pipefail отдаёт 141 при совпадении в
        # начале списка, и занятый адрес выдавался бы как свободный — двум
        # клиентам достался бы один IP.
        case $'\n'"$used"$'\n' in
            *$'\n'"$i"$'\n'*) ;;              # занят — берём следующий
            *) echo "${SUBNET}.${i}"; return 0 ;;
        esac
    done
    die "Свободные IP в ${SUBNET}.0/24 закончились"
}

EXPIRY_FILE="/opt/antizapret-awg/expiry.tsv"

# ── парсинг длительности TTL (30m/2h/7d) → секунды ───────────────────────────
ttl_seconds() {
    local t="$1" n unit
    n="${t%[smhd]}"; unit="${t##*[0-9]}"
    case "$unit" in
        s) echo "$n" ;; m) echo $((n*60)) ;; h) echo $((n*3600)) ;;
        d) echo $((n*86400)) ;; *) echo "" ;;
    esac
}

# ── добавить клиента ─────────────────────────────────────────────────────────
add_client() {
    local name="$1" svc="${2:-antizapret}" ttl="${3:-}"
    resolve_service "$svc"; load_obfuscation
    local outdir="${CLIENT_DIR}/${svc}"; mkdir -p "$outdir"
    local conf="${outdir}/${svc}-${name}-am.conf"
    [ -f "$conf" ] && die "Клиент '$name' ($svc) уже существует"

    local cpriv cpub cpsk cip host
    cpriv="$(awg genkey)"; cpub="$(printf '%s' "$cpriv" | awg pubkey)"
    cpsk="$(awg genpsk)"; cip="$(next_ip)"
    host="$(server_host)"

    local allowed dns
    if [ "$SPLIT" = 1 ]; then
        # split-routing: DNS = внутренний knot AntiZapret (из services.env);
        # AllowedIPs = своя подсеть + сам knot/32 (для keep-режима) + forward-подсети
        # AntiZapret (/etc/wireguard/ips) — ОСНОВА обхода блокировок
        dns="${DNS_SRV:-${SUBNET}.1}"
        # `|| true`: без файла ips подстановка вернула бы 1, и под set -e скрипт
        # умер бы молча, без единой строки в выводе — искать такое потом больно
        allowed="${SUBNET}.0/24, ${dns}/32$(cat /etc/wireguard/ips 2>/dev/null || true)"
    else
        # полный туннель: внутренний DNS сервера (стабильный, не зависит от смены
        # публичного IP); ::/0 добавлен чтобы IPv6 не утекал мимо туннеля
        dns="${DNS_SRV:-10.29.8.1}"; allowed="0.0.0.0/0, ::/0"
    fi

    # Ключ сервера берём ДО рендера, обычным присваиванием: die внутри $( ) в
    # heredoc убивает только подоболочку — cat дописал бы «PublicKey = »
    # пустым, и клиент получил бы заведомо нерабочий профиль со словом
    # «создан». Здесь отказ виден вызывающему.
    # `|| die` на самом присваивании: без него отказ `awg pubkey` (в отличие от
    # отсутствия ключа, которое ловит сама server_pubkey) убивал бы add_client
    # молча, и проверка на пустоту ниже стала бы недостижимой. Измерено:
    # plain-присваивание с упавшей подстановкой под set -e роняет скрипт.
    local spub
    spub="$(server_pubkey)" || die "не удалось получить публичный ключ сервера — клиент не создан"
    [ -n "$spub" ] || die "публичный ключ сервера пуст — клиент не создан"
    # рендер клиентского .conf
    cat > "$conf" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${cip}/32
DNS = ${dns}
MTU = ${MTU:-1320}
${AWG_OBFUSCATION}

[Peer]
PublicKey = ${spub}
PresharedKey = ${cpsk}
Endpoint = ${host}:${PORT}
AllowedIPs = ${allowed}
PersistentKeepalive = 15
EOF

    # peer на сервере: в рантайме (awg set) + персистентно (в .conf)
    awg set "$IFACE" peer "$cpub" preshared-key <(printf '%s' "$cpsk") \
        allowed-ips "${cip}/32" 2>/dev/null || \
        log "awg set пропущен (интерфейс не поднят?) — peer записан в конфиг"
    cat >> "$SERVER_CONF" <<EOF

[Peer]
# ${name}
PublicKey = ${cpub}
PresharedKey = ${cpsk}
AllowedIPs = ${cip}/32
EOF

    # QR (сырой conf) + vpn:// URI + QR URI
    # `|| log` обязателен: экспортёр возвращает 3, когда в системе нет ни segno,
    # ни qrcode. Клиент при этом создан полностью (.conf и vpn:// на месте), но
    # под `set -euo pipefail` ненулевой код убил бы add_client ровно здесь —
    # уже после того, как peer прописан и в рантайме, и в серверном конфиге.
    python3 "$EXPORT" "$conf" --name "${svc}-${name}" --outdir "$outdir" --all >/dev/null \
        || log "экспортёр: QR не собран (см. предупреждение выше) — .conf и vpn:// на месте"

    # временный клиент: записать срок удаления
    local expiry_note=""
    if [ -n "$ttl" ]; then
        local secs; secs="$(ttl_seconds "$ttl")"
        if [ -n "$secs" ]; then
            local when=$(( $(date +%s) + secs ))
            mkdir -p "$(dirname "$EXPIRY_FILE")"
            printf '%s\t%s\t%s\n' "$name" "$svc" "$when" >> "$EXPIRY_FILE"
            expiry_note=" · ⏳ до $(date -d "@$when" '+%Y-%m-%d %H:%M')"
        else
            log "TTL '$ttl' не распознан (примеры: 30m, 2h, 7d) — клиент создан бессрочным"
        fi
    fi

    log "Клиент '$name' ($svc)${expiry_note} создан:"
    log "  conf : $conf"
    if [ -f "${outdir}/${svc}-${name}.png" ]; then
        log "  QR   : ${outdir}/${svc}-${name}.png        (AmneziaWG native / WireGuard)"
    else
        log "  QR   : (не создан — см. предупреждение экспортёра выше)"
    fi
    if [ -f "${outdir}/${svc}-${name}.vpn" ]; then
        log "  URI  : ${outdir}/${svc}-${name}.vpn        (Amnezia VPN app)"
    fi
    if [ -f "${outdir}/${svc}-${name}-vpn.png" ]; then
        log "  QR-URI: ${outdir}/${svc}-${name}-vpn.png"
    fi
    echo "$conf"
}

# ── удалить клиента ──────────────────────────────────────────────────────────
del_client() {
    local name="$1" svc="${2:-antizapret}"
    resolve_service "$svc"
    local outdir="${CLIENT_DIR}/${svc}" conf="${CLIENT_DIR}/${svc}/${svc}-${name}-am.conf"
    [ -f "$conf" ] || die "Клиент '$name' ($svc) не найден"
    # Раньше ключ читался одной трубой прямо в `awg pubkey`. Под pipefail
    # конфиг без PrivateKey ронял всю команду молча: grep отдавал 1, и до
    # сообщения дело не доходило. Читаем отдельно и говорим, что не так.
    local cpriv cpub
    cpriv="$(grep '^PrivateKey' "$conf" | head -1 | cut -d= -f2- | tr -d ' \t' || true)"
    [ -n "$cpriv" ] || die "в конфиге '$conf' нет PrivateKey — по ключу удалять нечего"
    # Проверять здесь обязательно, и вот почему. expire_check зовёт del_client
    # левым операндом ||, а в таком вызове errexit подавлен на ВСЁ тело
    # функции: отказ `awg pubkey` не остановил бы удаление, а оставил бы cpub
    # пустым. Фильтр ниже ищет вхождение подстроки, и пустая входит в любой
    # блок — серверный конфиг вычищался бы целиком, молча, из-под таймера.
    cpub="$(printf '%s' "$cpriv" | awg pubkey)" \
        || die "не удалось вывести публичный ключ клиента из '$conf'"
    [ -n "$cpub" ] || die "пустой публичный ключ клиента ('$conf') — серверный конфиг не трогаю"
    awg set "$IFACE" peer "$cpub" remove 2>/dev/null || true
    # вычистить [Peer]-блок клиента из серверного конфига по PublicKey
    python3 - "$SERVER_CONF" "$cpub" <<'PY'
import sys, re
path, pub = sys.argv[1], sys.argv[2]
# Пустой ключ сюда попасть уже не может, но цена ошибки — вычищенные из
# серверного конфига ВСЕ пиры: подстрока "PublicKey = " есть в каждом блоке.
if not pub:
    sys.exit("пустой PublicKey — фильтр совпал бы со всеми пирами")
txt = open(path, encoding="utf-8").read()
blocks = re.split(r'(?=\[Peer\])', txt)
keep = [b for b in blocks if f"PublicKey = {pub}" not in b]
open(path, "w", encoding="utf-8").write("".join(keep))
PY
    rm -f "$conf" "${outdir}/${svc}-${name}"*.png "${outdir}/${svc}-${name}.vpn"
    log "Клиент '$name' ($svc) удалён"
}

list_clients() {
    local svc="${1:-antizapret}"
    resolve_service "$svc"
    log "Клиенты ($svc):"
    ls -1 "${CLIENT_DIR}/${svc}"/*-am.conf 2>/dev/null \
        | sed "s#.*/${svc}-##;s/-am.conf//" | sed 's/^/  /' || echo "  (нет)"
}

# ── пересоздать конфиги всех клиентов (после смены обфускации) ────────────────
regen_all() {
    local svc conf name before after
    # сколько конфигов реально изменилось: см. итог в конце функции
    local same=0 changed=0 changed_list=""
    # shellcheck disable=SC1090
    [ -f "$SERVICES" ] && . "$SERVICES"
    # Слои независимы: у каждого свой профиль, поэтому load_obfuscation вызываем
    # ПОСЛЕ resolve_service — она и выбирает obfuscation.env либо obfuscation3.env.
    # Ненужные сервисы отсеиваем ДО вызова: resolve_service/load_obfuscation
    # завершаются через die(), то есть уронили бы весь regen-all, а не итерацию.
    for svc in antizapret vpn antizapret3 vpn3; do
        case "$svc" in
            *3) [ "${LAYER3:-0}" = 1 ] || continue
                [ -f "${AWG_DIR}/obfuscation3.env" ] || continue ;;
            *)  [ "${LAYER2:-1}" = 1 ] || continue
                [ -f "${AWG_DIR}/obfuscation.env" ] || continue ;;
        esac
        [ -d "${CLIENT_DIR}/${svc}" ] || continue
        resolve_service "$svc"
        load_obfuscation
        for conf in "${CLIENT_DIR}/${svc}"/*-am.conf; do
            [ -f "$conf" ] || continue
            name="$(basename "$conf" | sed "s/^${svc}-//;s/-am.conf//")"
            before="$(md5sum "$conf" | cut -d" " -f1)"
            # заменить только строки обфускации, ключи/IP/peer не трогаем
            python3 - "$conf" "$AWG_OBFUSCATION" <<'PY'
import sys, re
path, block = sys.argv[1], sys.argv[2]
txt = open(path, encoding="utf-8").read().splitlines()
obf = {"Jc","Jmin","Jmax","S1","S2","S3","S4","H1","H2","H3","H4","I1","I2","I3","I4","I5",
       # ключи 3.0: их тоже вычищаем, иначе после смены профиля в конфиге
       # останется старый header protection и клиент не сойдётся с сервером
       "HeaderProtectionKey","ContentPaddingAddition","RekeyAfterTime","RekeyTimeout",
       "RejectAfterTime","KeepaliveTimeout","MaxHandshakeAttempts"}
out, in_iface = [], False
for line in txt:
    key = line.split("=",1)[0].strip() if "=" in line else ""
    if line.strip().startswith("[Interface]"): in_iface=True; out.append(line); continue
    if line.strip().startswith("[Peer]"):
        if in_iface:
            # Хвостовые пустые строки [Interface] убираем ПЕРЕД вставкой:
            # иначе каждый прогон regen-all добавлял бы ещё одну, файл
            # менялся бы без единого содержательного изменения, и владелец
            # думал бы, что клиентам пора раздавать конфиги заново.
            while out and not out[-1].strip():
                out.pop()
            out.append("")
            out.extend(block.splitlines()); out.append("")
        in_iface=False; out.append(line); continue
    if in_iface and key in obf: continue
    if key in obf: continue   # вычистить obf и вне [Interface] (защита от порчи)
    out.append(line)
open(path,"w",encoding="utf-8").write("\n".join(out)+"\n")
PY
            after="$(md5sum "$conf" | cut -d" " -f1)"
            python3 "$EXPORT" "$conf" --name "${svc}-${name}" \
                --outdir "$(dirname "$conf")" --all >/dev/null \
                || log "  QR не собран для $svc/$name (см. предупреждение выше)"
            if [ "$before" = "$after" ]; then
                same=$((same+1))
            else
                changed=$((changed+1)); changed_list="$changed_list $svc/$name"
                log "Изменён: $svc/$name"
            fi
        done
    done
    # Итог важнее перечисления: после обновления слоя нужно знать не «что-то
    # происходило», а придётся ли людям заново импортировать конфиги.
    if [ "$changed" = 0 ]; then
        log "Конфиги клиентов: $same без изменений — переимпорт не нужен"
    else
        log "Конфиги клиентов: $same без изменений, $changed изменено"
        log "   Заново скачать конфиг нужно:$changed_list"
    fi
}

# ── проверка и удаление просроченных временных клиентов ──────────────────────
expire_check() {
    [ -f "$EXPIRY_FILE" ] || exit 0
    local now; now="$(date +%s)"
    local tmp; tmp="$(mktemp)"
    while IFS=$'\t' read -r name svc when; do
        [ -n "$name" ] || continue
        if [ "$now" -ge "$when" ] 2>/dev/null; then
            log "Срок клиента '$name' ($svc) истёк — удаляю"
            # Подоболочка обязательна: die внутри del_client — это exit, и он
            # оборвал бы ВЕСЬ прогон до mv ниже, оставив список просроченных
            # нетронутым, а остальных — неудалёнными.
            ( del_client "$name" "$svc" ) \
                || log "клиента '$name' удалить не удалось — см. ошибку выше"
        else
            printf '%s\t%s\t%s\n' "$name" "$svc" "$when" >> "$tmp"
        fi
    done < "$EXPIRY_FILE"
    mv "$tmp" "$EXPIRY_FILE"
}

# Замок берётся на уровне диспетчера, а не внутри функций: expire_check зовёт
# del_client, и второй flock на том же файле дал бы самодедлок.
# Читающие команды (list, overview) оставлены без замка сознательно — иначе
# бот вис бы на всё время восстановления.
case "${1:-}" in
    add|del|regen-all)
        lock_wait 60 "изменение клиентов" \
            || die "занято другой операцией (восстановление? обфускация?) — повтори" ;;
    expire-check)
        # Пропустить тик безопасно: следующий придёт через пять минут, а
        # ожидание кончилось бы SIGTERM по TimeoutStartSec посреди правки.
        lock_try "проверка сроков" \
            || { log "состояние слоя занято — пропускаю тик"; exit 0; } ;;
esac

case "${1:-}" in
    add)
        [ $# -ge 2 ] || die "Укажи имя: add <name> [antizapret|vpn|antizapret3|vpn3] [--ttl 2h]"
        name="$2"; svc="antizapret"; ttl=""
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --ttl) ttl="$2"; shift 2 ;;
                antizapret|vpn|antizapret3|vpn3) svc="$1"; shift ;;
                # Раньше здесь стоял молчаливый `*) shift`, и любое незнакомое
                # слово просто выбрасывалось: запрос на antizapret3 тихо создавал
                # клиента 2.0 в другом каталоге. Теперь — явная ошибка.
                *) die "Неизвестный аргумент '$1'. Сервисы: antizapret|vpn|antizapret3|vpn3, срок: --ttl 2h" ;;
            esac
        done
        add_client "$name" "$svc" "$ttl" ;;
    del)
        [ $# -ge 2 ] || die "Укажи имя: del <name> [antizapret|vpn|antizapret3|vpn3]"
        del_client "$2" "${3:-antizapret}"
        # вычистить из expiry
        [ -f "$EXPIRY_FILE" ] && grep -vP "^$2\t${3:-antizapret}\t" "$EXPIRY_FILE" > "${EXPIRY_FILE}.tmp" 2>/dev/null \
            && mv "${EXPIRY_FILE}.tmp" "$EXPIRY_FILE" || true ;;
    list)  list_clients "${2:-antizapret}" ;;
    regen-all) regen_all ;;
    expire-check) expire_check ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
