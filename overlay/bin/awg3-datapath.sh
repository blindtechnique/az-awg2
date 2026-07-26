#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg3-datapath.sh — жизненный цикл интерфейса AmneziaWG 3.0.
#
# ПОЧЕМУ НЕ awg-quick
# ------------------
# awg-quick сначала пробует `ip link add <if> type amneziawg` и уходит в
# userspace только если это НЕ удалось. Kernel-модуль amneziawg (HEAD от
# 2026-06-11) знает параметры лишь до 2.0 — в нём нет header protection,
# content padding и таймингов. То есть на машине с загруженным модулем
# awg-quick МОЛЧА поднял бы 2.0-датапас вместо 3.0. Поэтому мы явно и всегда
# запускаем userspace-демон amneziawg-go.
#
# Второе преимущество: здесь amneziawg-go — главный процесс юнита, а не
# «выстрелил и забыл», как в awg-quick (Type=oneshot). Падение демона видит
# systemd и перезапускает его (Restart=on-failure).
#
# РАЗДЕЛЕНИЕ КОНФИГОВ
# -------------------
#   /etc/amnezia/amneziawg/<if>.conf  — обычный awg-конфиг (PrivateKey, Address,
#                                       ListenPort, MTU, Jc..I5, [Peer]-блоки).
#                                       Его читает `awg setconf`.
#   /etc/amnezia/amneziawg/<if>.v3    — строки UAPI с параметрами 3.0.
#                                       amneziawg-tools их не парсит, поэтому они
#                                       НЕ должны попадать в .conf, иначе
#                                       `awg setconf` упадёт «Line unrecognized».
#   /etc/amnezia/amneziawg/<if>.env   — SUBNET/PORT/NAT/SPLIT/DNS для этого интерфейса.
#
# Команды:
#   awg3-datapath.sh run       <if>   # ExecStart: запускает демон в foreground
#   awg3-datapath.sh configure <if>   # ExecStartPost: адрес, MTU, setconf, UAPI, NAT
#   awg3-datapath.sh cleanup   <if>   # ExecStopPost: снять NAT-правила
#   awg3-datapath.sh reload    <if>   # перечитать peers без разрыва (syncconf)
#   awg3-datapath.sh status    <if>
set -euo pipefail

AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
SELF_DIR="$(dirname "$(readlink -f "$0")")"
UAPI="$SELF_DIR/awg3-uapi.py"
[ -f "$UAPI" ] || UAPI=/opt/antizapret-awg/awg3-uapi.py

log() { printf '\033[1;34m[awg3]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[awg3]\033[0m %s\n' "$*" >&2; }

IFACE="${2:-}"
[ -n "$IFACE" ] || { err "не указан интерфейс"; exit 2; }
CONF="$AWG_DIR/$IFACE.conf"
V3="$AWG_DIR/$IFACE.v3"
IENV="$AWG_DIR/$IFACE.env"

load_env() {
    SUBNET=""; PORT=""; NAT=0; SPLIT=0; MTU=1380; ADDRESS=""
    WAN=""
    # shellcheck disable=SC1090
    [ -f "$SERVICES" ] && . "$SERVICES"
    # shellcheck disable=SC1090
    [ -f "$IENV" ] && . "$IENV"
    [ -n "$WAN" ] || WAN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
    # Address берём из .conf — единый источник истины
    [ -n "$ADDRESS" ] || ADDRESS="$(awk -F'[[:space:]]*=[[:space:]]*' '/^Address/{print $2; exit}' "$CONF" 2>/dev/null)"
    local m; m="$(awk -F'[[:space:]]*=[[:space:]]*' '/^MTU/{print $2; exit}' "$CONF" 2>/dev/null)"
    [ -n "$m" ] && MTU="$m"
    # ВАЖНО: явный `return 0`. Иначе, когда в конфиге нет строки MTU, последним
    # выполнится ложный тест, функция вернёт 1 — а её вызывают обычной командой,
    # и `set -e` молча прибьёт весь скрипт без единого сообщения.
    return 0
}

# ── NAT: нужен только в standalone. В режиме antizapret правила ванильного
#    AntiZapret уже покрывают наши подсети (они ходят по агрегатам /15 и /16),
#    поэтому свои MASQUERADE мы НЕ добавляем — иначе получится двойной NAT.
nat_rules() {  # nat_rules -A|-D
    local op="$1"
    [ "${NAT:-0}" = 1 ] || return 0
    [ -n "${SUBNET:-}" ] || return 0
    [ -n "$WAN" ] || { err "не определён внешний интерфейс — NAT пропущен"; return 0; }
    local nat_op="$op"
    # -A для добавления делаем идемпотентно через -C
    if [ "$op" = "-A" ]; then
        iptables -w -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null \
            || iptables -w -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE
        iptables -w -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null \
            || iptables -w -A FORWARD -i "$IFACE" -j ACCEPT
        iptables -w -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null \
            || iptables -w -A FORWARD -o "$IFACE" -j ACCEPT
        iptables -w -t mangle -C FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
            || iptables -w -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -w -t nat "$nat_op" POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null || true
        iptables -w "$nat_op" FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
        iptables -w "$nat_op" FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || true
        iptables -w -t mangle "$nat_op" FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
}

cmd_run() {
    [ -f "$CONF" ] || { err "нет $CONF"; exit 1; }
    command -v amneziawg-go >/dev/null || { err "amneziawg-go не установлен"; exit 1; }
    # если интерфейс завис с прошлого раза — снимаем, иначе демон не стартует
    ip link del "$IFACE" 2>/dev/null || true
    rm -f "/var/run/amneziawg/$IFACE.sock" 2>/dev/null || true
    # -f: не уходить в фон, чтобы systemd видел процесс и мог его перезапускать
    exec amneziawg-go -f "$IFACE"
}

cmd_configure() {
    load_env
    "$UAPI" wait "$IFACE" 20

    # 1) базовый конфиг (всё, что понимает amneziawg-tools)
    #    awg-quick strip убирает Address/MTU/DNS/PostUp/… и оставляет то, что ждёт setconf.
    #    Дополнительно выкидываем незаменённые плейсхолдеры обфускации: setconf
    #    падает на любой нераспознанной строке, а systemd в этом случае показывает
    #    только «control process exited with error code» — искать причину долго.
    local stripped; stripped="$(mktemp)"
    awg-quick strip "$IFACE" | grep -vE '^__AWG3?_OBFUSCATION__$' > "$stripped"
    if grep -q '__AWG' "$stripped"; then
        err "в $CONF остался плейсхолдер обфускации — запусти awg-obfuscation --v3 --regenerate"
    fi
    if ! awg setconf "$IFACE" "$stripped"; then
        err "awg setconf не принял $CONF — строка ниже:"
        awg setconf "$IFACE" "$stripped" 2>&1 | head -3 >&2
        rm -f "$stripped"
        return 1
    fi
    rm -f "$stripped"

    # 2) параметры AmneziaWG 3.0 — только через UAPI
    if [ -s "$V3" ]; then
        "$UAPI" set "$IFACE" --from-file "$V3"
    fi

    # 3) адрес и MTU
    if [ -n "${ADDRESS:-}" ]; then
        local a
        for a in ${ADDRESS//,/ }; do
            ip address add "$a" dev "$IFACE" 2>/dev/null || true
        done
    fi
    ip link set mtu "${MTU:-1380}" up dev "$IFACE"

    # 4) форвардинг и NAT (только standalone)
    if [ "${NAT:-0}" = 1 ]; then
        sysctl -q -w net.ipv4.ip_forward=1
        nat_rules -A
    fi
    log "$IFACE настроен (MTU ${MTU:-1380}${SUBNET:+, подсеть $SUBNET}${NAT:+, NAT=$NAT})"
}

cmd_cleanup() {
    load_env
    nat_rules -D
    ip link del "$IFACE" 2>/dev/null || true
    log "$IFACE остановлен, правила сняты"
}

cmd_reload() {
    load_env
    # syncconf сохраняет живые handshake'и; параметры 3.0 он не трогает,
    # потому что не знает о них (они живут только в UAPI-состоянии демона)
    awg syncconf "$IFACE" <(awg-quick strip "$IFACE")
    log "$IFACE: peers перечитаны без разрыва соединений"
}

cmd_status() {
    echo "── systemd ──"
    systemctl --no-pager --plain is-active "awg3@$IFACE" 2>/dev/null || true
    echo "── awg show (параметры до 2.0) ──"
    awg show "$IFACE" 2>/dev/null || echo "интерфейс не поднят"
    echo "── AmneziaWG 3.0 (через UAPI) ──"
    "$UAPI" show "$IFACE" 2>/dev/null || true
}

case "${1:-}" in
    run)       cmd_run ;;
    configure) cmd_configure ;;
    cleanup)   cmd_cleanup ;;
    reload)    cmd_reload ;;
    status)    cmd_status ;;
    *) echo "usage: awg3-datapath.sh {run|configure|cleanup|reload|status} <iface>"; exit 2 ;;
esac
