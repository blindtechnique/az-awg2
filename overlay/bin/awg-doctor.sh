#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-doctor.sh — самопроверка слоя AmneziaWG поверх AntiZapret.
#
#   awg-doctor              # быстрые проверки (секунды)
#   awg-doctor --deep       # + реальный клиент в network namespace и трафик
#   awg-doctor --json       # машинно-читаемо (для бота)
#
# Зачем: обычная беда — «клиент не подключается», а причина где-то между
# профилем обфускации, портом, NAT ванили и MTU. Скрипт проходит цепочку
# сверху вниз и говорит, на каком звене рвётся.
#
# --deep поднимает временный netns со своим клиентом, гоняет через туннель
# трафик и всё за собой убирает. Ничего в рабочей конфигурации не меняет.
set -uo pipefail

AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
DEST=/opt/antizapret-awg
DEEP=0; JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deep) DEEP=1; shift ;;
        --json) JSON=1; shift ;;
        -h|--help) sed -n '3,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

PROBLEMS=0
declare -a REPORT=()

ok()   { REPORT+=("OK|$1"); [ "$JSON" = 1 ] || printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad()  { REPORT+=("FAIL|$1"); PROBLEMS=$((PROBLEMS+1)); [ "$JSON" = 1 ] || printf '  \033[1;31m✗\033[0m %s\n' "$1"; }
warn() { REPORT+=("WARN|$1"); [ "$JSON" = 1 ] || printf '  \033[1;33m!\033[0m %s\n' "$1"; }
# заголовок секции попадает и в JSON: бот рисует по нему структуру,
# иначе в чат приезжает плоская простыня без разделов
head_() { REPORT+=("SECTION|$1"); [ "$JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f "$SERVICES" ] || { echo "Слой не установлен: нет $SERVICES" >&2; exit 3; }
# shellcheck disable=SC1090
. "$SERVICES"
LAYER2="${LAYER2:-1}"; LAYER3="${LAYER3:-0}"

# ── ваниль ──────────────────────────────────────────────────────────────────
head_ "Ванильный AntiZapret"
if [ -f /root/antizapret/client.sh ]; then ok "AntiZapret на месте"; else bad "нет /root/antizapret/client.sh"; fi
if systemctl is-active --quiet antizapret 2>/dev/null; then ok "antizapret.service работает"
else warn "antizapret.service не активен"; fi
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then ok "IP forwarding включён"
else bad "IP forwarding выключен"; fi

# ── интерфейсы слоёв ────────────────────────────────────────────────────────
check_iface() {  # check_iface <имя> <порт> <слой>
    local i="$1" p="$2" layer="$3" unit
    [ "$layer" = 3 ] && unit="awg3@$i" || unit="awg-quick@$i"
    if ip link show "$i" >/dev/null 2>&1; then
        ok "$i поднят ($(ip -4 -br addr show "$i" | awk '{print $3}'))"
    else
        bad "$i отсутствует — journalctl -u $unit"
        return
    fi
    if systemctl is-active --quiet "$unit"; then ok "$unit активен"; else bad "$unit не активен"; fi
    # Поле берём с конца, а не по номеру: `ss -lunH` печатает колонку Netid не
    # на всех версиях iproute2, и «четвёртая» верна лишь в одной раскладке.
    # Локальный адрес — предпоследнее поле в любой. Так же считает busy_ports.
    # grep -q оставлен сознательно: вывод ss короткий, в буфер трубы влезает,
    # и SIGPIPE тут не случается — а файл к тому же идёт без set -e.
    if ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -qE ":$p\$"; then ok "порт $p слушается"
    else bad "порт $p не слушается"; fi
    local peers; peers="$(awg show "$i" peers 2>/dev/null | grep -c . || true)"
    ok "$i: клиентов $peers"
}

if [ "$LAYER2" = 1 ]; then
    head_ "Слой AmneziaWG 2.0 (kernel-модуль)"
    if modinfo amneziawg >/dev/null 2>&1; then ok "модуль amneziawg собран"
    else bad "модуль amneziawg недоступен — dkms status"; fi
    check_iface "${AZ_IFACE:-antizapret-awg}" "${AZ_PORT:-0}" 2
    check_iface "${VPN_IFACE:-vpn-awg}" "${VPN_PORT:-0}" 2
fi

if [ "$LAYER3" = 1 ]; then
    head_ "Слой AmneziaWG 3.0 (userspace)"
    if command -v amneziawg-go >/dev/null 2>&1; then ok "amneziawg-go установлен"
    else bad "нет amneziawg-go"; fi
    check_iface "${AZ3_IFACE:-antizapret-awg3}" "${AZ3_PORT:-0}" 3
    check_iface "${VPN3_IFACE:-vpn-awg3}" "${VPN3_PORT:-0}" 3
    # Параметры 3.0 живут только в памяти демона — спрашиваем через UAPI.
    # Но их отсутствие само по себе НЕ поломка: пресеты router и low объявлены
    # без header protection, паддинга и таймингов. Раньше доктор в обоих случаях
    # писал «параметры 3.0 не применены», и владелец исправного сервера шёл
    # искать несуществующую проблему. Поэтому сначала смотрим, что за пресет.
    v3_preset="$(sed -n 's/^META_PRESET=//p' "$AWG_DIR/obfuscation3.meta" 2>/dev/null | head -1)"
    v3_uapi="$DEST/awg3-uapi.py"
    # Спрашиваем ОБА интерфейса. Раньше проверялся только antizapret-awg3, и
    # полный туннель мог сколько угодно работать как 2.0 — доктор молчал.
    # Бит +x не проверяем: скрипт запускается через python3, и потеря права на
    # исполнение раньше давала диагноз «параметры не применены» на пустом месте.
    v3_missing=""
    for local_i in "${AZ3_IFACE:-antizapret-awg3}" "${VPN3_IFACE:-vpn-awg3}"; do
        if [ ! -f "$v3_uapi" ]; then
            warn "нечем спросить демона: нет $v3_uapi — состояние 3.0 неизвестно"
            v3_missing=""
            break
        fi
        # «Спросить не удалось» и «ключа нет» — разные диагнозы, и чинятся они
        # по-разному. Прежде обе ситуации сваливались в одну ветку.
        v3_live="$(python3 "$v3_uapi" show "$local_i" 2>/dev/null || true)"
        if [ -z "$v3_live" ]; then
            warn "$local_i: демон не ответил по UAPI — состояние 3.0 неизвестно"
            echo "     смотри: journalctl -u awg3@$local_i -n 30 --no-pager" >&2
            continue
        fi
        case "$v3_live" in
            *header_protection_key*)
                ok "$local_i: header protection применена (пресет ${v3_preset:-?})" ;;
            *) v3_missing="$v3_missing $local_i" ;;
        esac
    done
    if [ -n "$v3_missing" ]; then
        case "$v3_preset" in
            router|low)
                ok "пресет $v3_preset — без header protection, так и задумано (${v3_missing# })"
                echo "     обфускация на уровне 2.0; нужен полный набор 3.0 —" >&2
                echo "     в боте: 🛡 Обфускация → 🛠 Сменить пресет," >&2
                echo "     или руками: awg-obfuscation --v3 --preset medium --regenerate --apply" >&2
                echo "     и раздай клиентам свежие конфиги: awg-client regen-all" >&2 ;;
            *)
                warn "пресет ${v3_preset:-?} должен включать header protection, но её нет:${v3_missing}"
                echo "     профиль: $AWG_DIR/obfuscation3.env (ищи AWG_HPK_HEX)" >&2
                echo "     параметры:$(for i in $v3_missing; do printf ' %s' "$AWG_DIR/$i.v3"; done)" >&2
                echo "     починить: awg-obfuscation --v3 --regenerate --apply" >&2 ;;
        esac
    fi
fi

# ── профиль обфускации ──────────────────────────────────────────────────────
head_ "Профиль обфускации"
for pair in "obfuscation.env|2.0|$LAYER2" "obfuscation3.env|3.0|$LAYER3"; do
    f="${pair%%|*}"; rest="${pair#*|}"; ver="${rest%%|*}"; on="${rest##*|}"
    [ "$on" = 1 ] || continue
    if [ -s "$AWG_DIR/$f" ]; then ok "профиль $ver есть ($f)"; else bad "нет $AWG_DIR/$f"; fi
done
# незаменённый плейсхолдер — классический признак, что обфускация не применилась
if grep -rqs '__AWG3\?_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
    # Плейсхолдер у слоёв разный, и лечить надо тот слой, где он остался:
    # awg-obfuscation без --v3 перегенерирует профиль 2.0, а конфиг 3.0 как был
    # сломан, так и останется. Поэтому смотрим, в каком именно файле нашли.
    if grep -rqs '__AWG3_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
        bad "в конфиге слоя 3.0 остался плейсхолдер обфускации — awg-obfuscation --v3 --regenerate --apply && awg-client regen-all"
    fi
    if grep -rqs '__AWG_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
        bad "в конфиге слоя 2.0 остался плейсхолдер обфускации — awg-obfuscation --regenerate --apply && awg-client regen-all"
    fi
else
    ok "плейсхолдеров в конфигах нет"
fi

# ── DNS ─────────────────────────────────────────────────────────────────────
head_ "DNS"
if [ -f /etc/knot-resolver/kresd.conf ]; then
    miss=0
    for s in "${AZ_SUBNET:-}" "${VPN_SUBNET:-}" "${AZ3_SUBNET:-}" "${VPN3_SUBNET:-}"; do
        [ -n "$s" ] || continue
        grep -q "view:addr('$s.1/24'" /etc/knot-resolver/kresd.conf && continue
        # Свой view нужен только там, где ваниль сама их держит: она описывает
        # view для split-подсетей, а для полного VPN их может не быть вовсе —
        # тогда и нам добавлять некуда, и это не проблема.
        if grep -q "view:addr('${s%.*}\." /etc/knot-resolver/kresd.conf; then
            miss=$((miss+1))
        fi
    done
    [ "$miss" = 0 ] && ok "view для подсетей слоя на месте" \
                    || warn "в kresd.conf не хватает view для $miss подсетей (awg-knot-view.sh)"
else
    warn "kresd.conf не найден — DNS-проверка пропущена"
fi

# ── глубокая проверка ───────────────────────────────────────────────────────
if [ "$DEEP" = 1 ]; then
    head_ "Проверка связности (реальный клиент)"
    NS=awgdoc$$
    TMPNAME="doctor$$"
    cleanup_deep() {
        ip netns exec "$NS" awg-quick down "$TMPNAME" >/dev/null 2>&1
        ip netns del "$NS" >/dev/null 2>&1
        ip link del "vd$$" >/dev/null 2>&1
        "$DEST/client-awg.sh" del "$TMPNAME" "$DOC_SVC" >/dev/null 2>&1
        rm -f "$AWG_DIR/$TMPNAME.conf" 2>/dev/null
    }
    trap cleanup_deep EXIT
    DOC_SVC=vpn; [ "$LAYER2" = 1 ] || DOC_SVC=vpn3
    if "$DEST/client-awg.sh" add "$TMPNAME" "$DOC_SVC" >/dev/null 2>&1; then
        ok "тестовый клиент создан ($DOC_SVC)"
        CONF="$(ls -1 /opt/antizapret-awg/clients/$DOC_SVC/*"$TMPNAME"*-am.conf 2>/dev/null | head -1)"
        [ -n "$CONF" ] || CONF="$(ls -1 /opt/antizapret-awg/clients/$DOC_SVC/*"$TMPNAME"* 2>/dev/null | head -1)"
        if [ -n "$CONF" ]; then
            ip netns add "$NS" 2>/dev/null
            ip link add "vd$$" type veth peer name vdp 2>/dev/null
            ip link set vdp netns "$NS" 2>/dev/null
            ip addr add 10.199.0.1/24 dev "vd$$" 2>/dev/null; ip link set "vd$$" up
            ip netns exec "$NS" ip link set lo up
            ip netns exec "$NS" ip addr add 10.199.0.2/24 dev vdp
            ip netns exec "$NS" ip link set vdp up
            ip netns exec "$NS" ip route add default via 10.199.0.1
            iptables -w -t nat -A POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null
            grep -v '^DNS' "$CONF" > "$AWG_DIR/$TMPNAME.conf"; chmod 600 "$AWG_DIR/$TMPNAME.conf"
            ip netns exec "$NS" awg-quick up "$TMPNAME" >/dev/null 2>&1
            hs=0
            for _ in $(seq 1 15); do
                hs="$(ip netns exec "$NS" awg show "$TMPNAME" latest-handshakes 2>/dev/null | awk '{print $2}')"
                [ "${hs:-0}" != 0 ] && break
                sleep 1
            done
            [ "${hs:-0}" != 0 ] && ok "handshake проходит" || bad "handshake не проходит"
            iptables -w -t nat -D POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null
        else
            warn "не нашёл конфиг тестового клиента — глубокая проверка пропущена"
        fi
    else
        bad "не удалось создать тестового клиента"
    fi
    cleanup_deep; trap - EXIT
fi

# ── вывод ───────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
    printf '{"problems": %d, "checks": [' "$PROBLEMS"
    first=1
    for r in "${REPORT[@]}"; do
        st="${r%%|*}"; msg="${r#*|}"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"status":"%s","text":"%s"}' "$st" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
else
    echo
    if [ "$PROBLEMS" = 0 ]; then
        printf '\033[1;32mПроверка завершена: проблем не найдено\033[0m\n'
    else
        printf '\033[1;31mПроверка завершена: проблем — %d\033[0m\n' "$PROBLEMS"
    fi
fi
exit 0
