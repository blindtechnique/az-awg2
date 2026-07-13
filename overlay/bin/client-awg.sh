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

# ── определить сервис/интерфейс/подсеть/порт ─────────────────────────────────
# параметры сервисов пишет integration в services.env (зависят от режима replace/keep)
SERVICES="${AWG_DIR}/services.env"
resolve_service() {
    local svc="${1:-antizapret}"
    [ -f "$SERVICES" ] && . "$SERVICES"
    case "$svc" in
        antizapret)
            IFACE="${AZ_IFACE:-antizapret}"; SUBNET="${AZ_SUBNET:-10.29.8}"
            PORT="${AZ_PORT:-51443}"; DNS_SRV="${AZ_DNS:-10.29.8.1}"; SPLIT="${AZ_SPLIT:-1}" ;;
        vpn)
            IFACE="${VPN_IFACE:-vpn}"; SUBNET="${VPN_SUBNET:-10.28.8}"
            PORT="${VPN_PORT:-51080}"; DNS_SRV="${VPN_DNS:-10.29.8.1}"; SPLIT="${VPN_SPLIT:-0}" ;;
        *) die "Неизвестный сервис: $svc (antizapret|vpn)" ;;
    esac
    SERVER_CONF="${AWG_DIR}/${IFACE}.conf"
    [ -f "$SERVER_CONF" ] || die "Нет серверного конфига $SERVER_CONF"
}

# ── единый профиль обфускации (как AWG_OBFUSCATION для рендера клиента) ───────
load_obfuscation() {
    [ -f "$STATE_ENV" ] || die "Нет $STATE_ENV — сначала запусти awg-obfuscation.sh"
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    AWG_OBFUSCATION=""
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
        v="AWG_${k}"; val="${!v:-}"
        [ -n "$val" ] && AWG_OBFUSCATION+="${k} = ${val}"$'\n'
    done
    AWG_OBFUSCATION="${AWG_OBFUSCATION%$'\n'}"
}

server_pubkey() {
    # cut -d= -f2- сохраняет хвостовой '=' base64-ключа (awk -F' *= *' его обрезал!)
    grep '^PrivateKey' "$SERVER_CONF" | head -1 | cut -d= -f2- | tr -d ' \t' | awg pubkey
}

# реальный внешний хост: домен из настроек AntiZapret или публичный IP сервера
server_host() {
    local h=""
    [ -f /root/antizapret/setup ] && h="$(. /root/antizapret/setup 2>/dev/null; echo "${WIREGUARD_HOST:-}")"
    [ -n "$h" ] || h="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
    [ -n "$h" ] || h="$(curl -s https://api.ipify.org)"
    echo "$h"
}

# ── выбор свободного IP в подсети ────────────────────────────────────────────
next_ip() {
    local used; used="$(grep -oE "AllowedIPs = ${SUBNET//./\\.}\.[0-9]+" "$SERVER_CONF" \
        | grep -oE '[0-9]+$' || true)"
    local i
    for i in $(seq 2 254); do
        echo "$used" | grep -qx "$i" || { echo "${SUBNET}.${i}"; return 0; }
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
        allowed="${SUBNET}.0/24, ${dns}/32$(cat /etc/wireguard/ips 2>/dev/null)"
    else
        # полный туннель: внутренний DNS сервера (стабильный, не зависит от смены
        # публичного IP); ::/0 добавлен чтобы IPv6 не утекал мимо туннеля
        dns="${DNS_SRV:-10.29.8.1}"; allowed="0.0.0.0/0, ::/0"
    fi

    # рендер клиентского .conf
    cat > "$conf" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${cip}/32
DNS = ${dns}
MTU = ${MTU:-1320}
${AWG_OBFUSCATION}

[Peer]
PublicKey = $(server_pubkey)
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
    python3 "$EXPORT" "$conf" --name "${svc}-${name}" --outdir "$outdir" --all >/dev/null

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
    log "  QR   : ${outdir}/${svc}-${name}.png        (AmneziaWG native / WireGuard)"
    log "  URI  : ${outdir}/${svc}-${name}.vpn        (Amnezia VPN app)"
    log "  QR-URI: ${outdir}/${svc}-${name}-vpn.png"
    echo "$conf"
}

# ── удалить клиента ──────────────────────────────────────────────────────────
del_client() {
    local name="$1" svc="${2:-antizapret}"
    resolve_service "$svc"
    local outdir="${CLIENT_DIR}/${svc}" conf="${CLIENT_DIR}/${svc}/${svc}-${name}-am.conf"
    [ -f "$conf" ] || die "Клиент '$name' ($svc) не найден"
    local cpub; cpub="$(grep '^PrivateKey' "$conf" | head -1 | cut -d= -f2- | tr -d ' \t' | awg pubkey)"
    awg set "$IFACE" peer "$cpub" remove 2>/dev/null || true
    # вычистить [Peer]-блок клиента из серверного конфига по PublicKey
    python3 - "$SERVER_CONF" "$cpub" <<'PY'
import sys, re
path, pub = sys.argv[1], sys.argv[2]
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
    load_obfuscation
    local svc conf name
    for svc in antizapret vpn; do
        resolve_service "$svc" 2>/dev/null || continue
        for conf in "${CLIENT_DIR}/${svc}"/*-am.conf; do
            [ -f "$conf" ] || continue
            name="$(basename "$conf" | sed "s/^${svc}-//;s/-am.conf//")"
            # заменить только строки обфускации, ключи/IP/peer не трогаем
            python3 - "$conf" "$AWG_OBFUSCATION" <<'PY'
import sys, re
path, block = sys.argv[1], sys.argv[2]
txt = open(path, encoding="utf-8").read().splitlines()
obf = {"Jc","Jmin","Jmax","S1","S2","S3","S4","H1","H2","H3","H4","I1","I2","I3","I4","I5"}
out, in_iface = [], False
for line in txt:
    key = line.split("=",1)[0].strip() if "=" in line else ""
    if line.strip().startswith("[Interface]"): in_iface=True; out.append(line); continue
    if line.strip().startswith("[Peer]"):
        if in_iface: out.extend(block.splitlines()); out.append("")
        in_iface=False; out.append(line); continue
    if in_iface and key in obf: continue
    if key in obf: continue   # вычистить obf и вне [Interface] (защита от порчи)
    out.append(line)
open(path,"w",encoding="utf-8").write("\n".join(out)+"\n")
PY
            python3 "$EXPORT" "$conf" --name "${svc}-${name}" \
                --outdir "$(dirname "$conf")" --all >/dev/null
            log "Пересоздан: $svc/$name"
        done
    done
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
            del_client "$name" "$svc" 2>/dev/null || true
        else
            printf '%s\t%s\t%s\n' "$name" "$svc" "$when" >> "$tmp"
        fi
    done < "$EXPIRY_FILE"
    mv "$tmp" "$EXPIRY_FILE"
}

case "${1:-}" in
    add)
        [ $# -ge 2 ] || die "Укажи имя: add <name> [antizapret|vpn] [--ttl 2h]"
        name="$2"; svc="antizapret"; ttl=""
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --ttl) ttl="$2"; shift 2 ;;
                antizapret|vpn) svc="$1"; shift ;;
                *) shift ;;
            esac
        done
        add_client "$name" "$svc" "$ttl" ;;
    del)
        [ $# -ge 2 ] || die "Укажи имя: del <name> [antizapret|vpn]"
        del_client "$2" "${3:-antizapret}"
        # вычистить из expiry
        [ -f "$EXPIRY_FILE" ] && grep -vP "^$2\t${3:-antizapret}\t" "$EXPIRY_FILE" > "${EXPIRY_FILE}.tmp" 2>/dev/null \
            && mv "${EXPIRY_FILE}.tmp" "$EXPIRY_FILE" || true ;;
    list)  list_clients "${2:-antizapret}" ;;
    regen-all) regen_all ;;
    expire-check) expire_check ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
