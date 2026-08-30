#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Согласованность копий состояния: ключи и пиры.
#
# Приватный ключ клиента существует ТОЛЬКО в его конфиге, публичный — в [Peer]
# серверного. Пара пишется не атомарно: add_client делает три отдельные записи
# (клиентский файл, `awg set` на живой интерфейс, [Peer] в конфиг), del_client —
# две в обратном порядке. Значит расхождение достижимо обрывом, а не только
# переносом сервера; а восстановление из архива, снятого до починки DEST, даёт
# худший вариант — серверный конфиг с пирами и пустой каталог клиентов.
#
# Уровни назначены по доказуемости, и набор проверяет именно их:
#
#   ключа клиента нет среди пиров        → bad   (клиент мёртв, законного
#                                                 состояния нет)
#   у клиента чужой ключ сервера         → bad   (handshake невозможен)
#   два клиента делят адрес              → bad   (next_ip отдаст его третьему)
#   пир без клиентского файла            → warn  (мог быть заведён руками)
#   нет awg / пустой ключ                → молчим (доказать нечем)
#
#   bash tests/test_consistency.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DOC=overlay/bin/awg-doctor.sh
FN="$(sed -n '/^check_peers()/,/^}$/p' "$DOC")"
[ -n "$FN" ] || { bad "не нашли check_peers в $DOC" "мерить нечего"; echo; exit 1; }

# Заглушка awg: check_peers сравнивает выведенные ключи между собой, поэтому
# достаточно детерминированного отображения приватного ключа в «публичный».
S="$WORK/stub"; mkdir -p "$S"
{
    echo '#!/bin/bash'
    echo '[ "${1:-}" = pubkey ] || exit 0'
    echo 'read -r k; printf "PUB-%s\n" "$k"'
} > "$S/awg"
chmod +x "$S/awg"

# ── стенд ──────────────────────────────────────────────────────────────────
mk() {  # mk <каталог> <ключ сервера> <ключ сервера у клиентов> <клиент…>
    local d="$1" srv="$2" srv_seen="$3"; shift 3
    rm -rf "$d"; mkdir -p "$d/clients" "$d/etc"
    printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n' "$srv" > "$d/etc/antizapret-awg.conf"
    local spec name key addr i=0
    for spec in "$@"; do
        i=$((i + 1))
        name="c$i"; key="${spec%%:*}"; addr="${spec##*:}"
        printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\n\n[Peer]\nPublicKey = %s\nEndpoint = h:51820\n' \
            "$key" "$addr" "$srv_seen" > "$d/clients/antizapret-$name-am.conf"
    done
}
add_peer() {  # add_peer <каталог> <публичный ключ>
    printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.29.9.9/32\n' "$2" >> "$1/etc/antizapret-awg.conf"
}
peers_of() {  # peers_of <каталог> — добавить пиров под каждого клиента
    local d="$1" f k
    for f in "$d"/clients/*-am.conf; do
        k="$(sed -n 's/^PrivateKey *= *//p' "$f" | head -1)"
        add_peer "$d" "PUB-$k"
    done
}
run() {  # run <каталог> → вывод проверки
    ( PATH="$S:$PATH"
      ok()   { printf 'OK %s\n' "$*"; }
      bad()  { printf 'BAD %s\n' "$*"; }
      warn() { printf 'WARN %s\n' "$*"; }
      eval "$FN"
      check_peers "$1/etc/antizapret-awg.conf" "$1/clients" antizapret-awg )
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Всё согласовано — ни одной жалобы"
D="$WORK/a"; mk "$D" SRV PUB-SRV K1:10.29.9.2 K2:10.29.9.3 K3:10.29.9.4
peers_of "$D"
out="$(run "$D")"
case "$out" in
    *BAD*|*WARN*) bad "исправное состояние названо расхождением" "$out" ;;
    *) ok "проверка молчит по существу" ;;
esac
case "$out" in
    *"все 3 клиентов есть среди пиров"*) ok "и сказано, сколько сверено" ;;
    *) bad "число сверенных не названо" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Клиент выдан, а пира нет — он мёртв, и это поломка"
D="$WORK/b"; mk "$D" SRV PUB-SRV K1:10.29.9.2 K2:10.29.9.3
add_peer "$D" PUB-K1          # пир только для первого
out="$(run "$D")"
case "$out" in
    *"BAD"*"у 1 из 2 клиентов ключа нет среди пиров"*) ok "посчитан только потерянный" ;;
    *) bad "клиент без пира не найден" "$out" ;;
esac
case "$out" in
    *"сервер их не примет"*) ok "и сказано, что это значит" ;;
    *) bad "последствие не названо" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Пир без клиентского файла — доступ без имени, но это замечание"
# Ровно то, что оставляет восстановление из архива без клиентских ключей.
D="$WORK/c"; mk "$D" SRV PUB-SRV K1:10.29.9.2
peers_of "$D"
add_peer "$D" PUB-ЧУЖОЙ
out="$(run "$D")"
case "$out" in
    *"WARN"*"1 пиров без клиентского файла"*) ok "сирота найдена" ;;
    *) bad "пир без файла пропущен" "$out" ;;
esac
case "$out" in
    *"отозвать по имени нечем"*) ok "и сказано, чем это плохо" ;;
    *) bad "последствие не названо" "$out" ;;
esac
case "$out" in
    *"BAD"*) bad "названо поломкой" "пир мог быть заведён руками — красное не заслужено" ;;
    *) ok "это замечание, а не поломка" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Два клиента делят адрес — следующий заберёт маршрут у работающего"
D="$WORK/d"; mk "$D" SRV PUB-SRV K1:10.29.9.2 K2:10.29.9.2
peers_of "$D"
out="$(run "$D")"
case "$out" in
    *"BAD"*"делят адрес"*) ok "дубликат адреса найден" ;;
    *) bad "дубликат пропущен" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. У клиента чужой ключ сервера — handshake невозможен"
D="$WORK/e"; mk "$D" SRV PUB-СТАРЫЙ K1:10.29.9.2 K2:10.29.9.3
peers_of "$D"
out="$(run "$D")"
case "$out" in
    *"BAD"*"чужой ключ сервера"*) ok "несовпадение ключа сервера найдено" ;;
    *) bad "чужой ключ сервера пропущен" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Нечем вывести ключ — молчим, а не выдумываем"
D="$WORK/f"; mk "$D" SRV PUB-SRV K1:10.29.9.2
peers_of "$D"
out="$( PATH="$WORK/empty:$PATH"
        mkdir -p "$WORK/empty"
        ok() { printf 'OK %s\n' "$*"; }; bad() { printf 'BAD %s\n' "$*"; }
        warn() { printf 'WARN %s\n' "$*"; }
        eval "$FN"; check_peers "$D/etc/antizapret-awg.conf" "$D/clients" antizapret-awg )"
case "$out" in
    *BAD*) bad "отсутствие awg названо поломкой сервера" "$out" ;;
    *) ok "поломкой не названо" ;;
esac

head_ "7. Клиентский файл без приватного ключа — не наш формат, пропускаем"
D="$WORK/g"; mk "$D" SRV PUB-SRV K1:10.29.9.2
peers_of "$D"
printf '[Interface]\nAddress = 10.29.9.9/32\n' > "$D/clients/antizapret-чужой-am.conf"
out="$(run "$D")"
case "$out" in
    *"все 1 клиентов есть среди пиров"*) ok "чужой файл не попал в счёт" ;;
    *) bad "чужой файл посчитан или сломал проверку" "$out" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
