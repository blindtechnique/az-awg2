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


# ═══════════════════════════════════════════════════════════════════════════
head_ "8. Понижение профиля не оставляет параметров 3.0 от прежнего"
# apply_to_server писал <iface>.v3 только `if [ -n "$V3_BLOCK" ]` — при пустом
# блоке файл не переписывался И НЕ удалялся. Пустым блок становится штатно:
# пресеты router и low объявлены без header protection. Значит понижение
# medium → router оставляло прежний .v3, датапас применял его на
# ExecStartPost, сервер продолжал ждать header protection, а клиентские
# конфиги уже перевыпущены без неё — не подключался НИКТО.
AP="$(sed -n '/^apply_to_server()/,/^}$/p' overlay/bin/awg-obfuscation.sh)"
if [ -z "$AP" ]; then
    bad "не нашли apply_to_server в overlay/bin/awg-obfuscation.sh" "мерить нечего"
else
    D="$WORK/v3"; rm -rf "$D"; mkdir -p "$D"
    printf '[Interface]\nPrivateKey = SRV\n\n[Peer]\nPublicKey = P\n' > "$D/awgX.conf"
    printf 'header_protection_key=СТАРЫЙ\n' > "$D/awgX.v3"
    # shellcheck disable=SC2034  # читает вырезанная apply_to_server
    ( IFACE_BLOCK="Jc = 4"; V3_BLOCK=""
      log() { :; }; err() { :; }
      eval "$AP"
      apply_to_server "$D/awgX.conf" awgX ) >/dev/null 2>&1
    [ -f "$D/awgX.v3" ] \
        && bad "прежний .v3 остался при пустом профиле" \
               "датапас применит его, и сервер разойдётся со всеми выданными конфигами" \
        || ok "прежний .v3 убран"

    # А при непустом блоке файл обязан перезаписаться, а не исчезнуть.
    printf 'header_protection_key=СТАРЫЙ\n' > "$D/awgX.v3"
    # shellcheck disable=SC2034  # читает вырезанная apply_to_server
    ( IFACE_BLOCK="Jc = 4"; V3_BLOCK="header_protection_key=НОВЫЙ"
      log() { :; }; err() { :; }
      eval "$AP"
      apply_to_server "$D/awgX.conf" awgX ) >/dev/null 2>&1
    if grep -q 'НОВЫЙ' "$D/awgX.v3" 2>/dev/null; then
        ok "непустой профиль перезаписывает .v3"
    else
        bad "непустой профиль не записал .v3" "$(cat "$D/awgX.v3" 2>/dev/null)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "9. Застрявший .v3 виден и без демона"
VS="$(sed -n '/^check_v3_stale()/,/^}$/p' "$DOC")"
if [ -z "$VS" ]; then
    bad "не нашли check_v3_stale в $DOC" "мерить нечего"
else
    vs() {  # vs <содержимое .v3 | -> нет файла> <объявлена ли в профиле>
        local d="$WORK/vs"; rm -rf "$d"; mkdir -p "$d"
        [ "$1" = "-" ] || printf '%s\n' "$1" > "$d/i.v3"
        ( ok()   { printf 'OK %s\n' "$*"; }
          bad()  { printf 'BAD %s\n' "$*"; }
          warn() { printf 'WARN %s\n' "$*"; }
          eval "$VS"
          check_v3_stale "$d/i.v3" "$2" router )
    }
    out="$(vs 'header_protection_key=СТАРЫЙ' 0)"
    case "$out" in
        *BAD*) ok "ключ есть, профиль его не объявляет — поломка названа" ;;
        *) bad "застрявший ключ пропущен" "[$out]" ;;
    esac
    out="$(vs 'header_protection_key=НОРМА' 1)"
    case "$out" in
        *BAD*|*WARN*) bad "жалоба там, где профиль ключ объявляет" "[$out]" ;;
        *) ok "объявленный ключ жалобы не вызывает" ;;
    esac
    out="$(vs - 0)"
    case "$out" in
        *BAD*|*WARN*) bad "жалоба при отсутствии .v3" "[$out]" ;;
        *) ok "нет файла — нет разговора" ;;
    esac
    out="$(vs 'rekey_timeout=5' 0)"
    case "$out" in
        *BAD*|*WARN*) bad "жалоба на .v3 без ключа защиты заголовка" "[$out]" ;;
        *) ok ".v3 без header_protection_key не трогаем" ;;
    esac
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "10. Каждая проверка вызвана для КАЖДОГО каталога клиентов"
# Стенды вырезают функции и гоняют их на своих каталогах, поэтому удаление
# строки вызова в докторе оставляет весь набор зелёным, а инвариант для одного
# каталога тихо исчезает — каталог продолжают осматривать соседние функции.
CL=overlay/bin/client-awg.sh
svcs="$(sed -n '/^regen_all()/,/^}$/p' "$CL" \
        | sed -n 's/^ *for svc in \(.*\); do$/\1/p' | head -1)"
if [ -z "$svcs" ]; then
    bad "не нашли список сервисов в regen_all ($CL)" "мерить нечего"
else
    ok "список каталогов взят из $CL: $svcs"
    for _svc in $svcs; do
        for _fn in check_ports check_client_hosts check_peers check_client_mtu; do
            # Закрывающая кавычка обязательна: без неё clients/antizapret
            # совпал бы и с clients/antizapret3.
            if grep -q "^ *$_fn .*clients/$_svc\"" "$DOC"; then
                ok "$_fn вызвана для $_svc"
            else
                bad "$_fn не вызвана для каталога $_svc" \
                    "инвариант для этого каталога не проверяется, а набор остаётся зелёным"
            fi
        done
    done
    # Обратная сторона: вызов на каталог, которого проект не создаёт, — опечатка.
    for _d in $(grep -oE 'clients/[a-z0-9]+"' "$DOC" | sed 's|clients/||; s|"||' | sort -u); do
        case " $svcs " in
            *" $_d "*) ;;
            *) bad "проверка вызвана для каталога $_d, которого нет в regen_all" \
                   "опечатка: осматривается не то, что создаётся" ;;
        esac
    done
    ok "лишних каталогов в вызовах нет"

    # check_live идёт по интерфейсам, а не по каталогам клиентов, поэтому в
    # список выше он не годится. Связываем его с check_iface: сколько
    # интерфейсов осматривается, столько же раз надо спросить и живое ядро.
    n_iface="$(grep -c '^ *check_iface "' "$DOC" || true)"
    n_live="$(grep -c '^ *check_live "' "$DOC" || true)"
    if [ "$n_iface" = "$n_live" ] && [ "$n_iface" != 0 ]; then
        ok "сверка с живым ядром вызвана для всех $n_iface интерфейсов"
    else
        bad "check_live вызвана $n_live раз при $n_iface интерфейсах" \
            "для части интерфейсов расхождение конфига с ядром не проверяется"
    fi
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "11. MTU у выданных конфигов сверяется с объявленным"
# regen-all MTU не меняет — он правит только строки обфускации. Значит после
# смены MTU все выданные конфиги молча остаются на прежнем, и вред тише, чем у
# порта: соединение встаёт, мелкие запросы ходят, а крупные пакеты пропадают.
MF="$(sed -n '/^check_client_mtu()/,/^}$/p' "$DOC")"
if [ -z "$MF" ]; then
    bad "не нашли check_client_mtu в $DOC" "мерить нечего"
else
    mkm() {  # mkm <каталог> <mtu…> — по конфигу на значение, «-» значит без MTU
        local d="$1"; shift
        rm -rf "$d"; mkdir -p "$d"
        local i=0 m
        for m in "$@"; do
            i=$((i + 1))
            if [ "$m" = "-" ]; then
                printf '[Interface]\nPrivateKey = K%s\n' "$i" > "$d/x-c$i-am.conf"
            else
                printf '[Interface]\nPrivateKey = K%s\nMTU = %s\n' "$i" "$m" \
                    > "$d/x-c$i-am.conf"
            fi
        done
    }
    mtu() {  # mtu <объявленный> <каталог>
        ( ok()   { printf 'OK %s\n' "$*"; }
          bad()  { printf 'BAD %s\n' "$*"; }
          warn() { printf 'WARN %s\n' "$*"; }
          eval "$MF"
          check_client_mtu "$1" "$2" x )
    }

    D="$WORK/m1"; mkm "$D" 1420 1420 1420
    out="$(mtu 1420 "$D")"
    case "$out" in
        *BAD*|*WARN*) bad "исправное состояние названо расхождением" "$out" ;;
        *) ok "все совпадают — проверка молчит по существу" ;;
    esac
    case "$out" in
        *"у всех 3 конфигов MTU 1420"*) ok "и сказано, сколько сверено" ;;
        *) bad "число не названо" "$out" ;;
    esac

    D="$WORK/m2"; mkm "$D" 1420 1280 1420 1280
    out="$(mtu 1420 "$D")"
    case "$out" in
        *"WARN"*"2 из 4 конфигов другой MTU"*) ok "посчитаны только несовпавшие" ;;
        *) bad "расхождение не посчитано" "$out" ;;
    esac
    case "$out" in *1280*) ok "и показан образец" ;; *) bad "образец не показан" "$out" ;; esac
    case "$out" in
        *"regen-all MTU не меняет"*) ok "и сказано, что regen-all тут не поможет" ;;
        *) bad "подсказка неверная или её нет" "$out" ;;
    esac
    case "$out" in
        *BAD*) bad "названо поломкой" "MTU могли сменить только что, конфиги ещё не розданы" ;;
        *) ok "это замечание, а не поломка" ;;
    esac

    D="$WORK/m3"; mkm "$D" 1420 1280
    out="$(mtu "" "$D")"
    case "$out" in
        *WARN*|*BAD*) bad "жалоба при необъявленном MTU" "$out" ;;
        *) ok "не объявлен — сравнивать не с чем, молчим" ;;
    esac

    D="$WORK/m4"; mkm "$D" 1420 - 1420
    out="$(mtu 1420 "$D")"
    case "$out" in
        *"у всех 2 конфигов MTU 1420"*) ok "конфиг без строки MTU в счёт не идёт" ;;
        *) bad "конфиг без MTU посчитан или сломал проверку" "$out" ;;
    esac
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "12. Живой интерфейс сверяется с серверным конфигом"
# check_peers сверяет файлы между собой. Здесь — файл против ЯДРА: на диске всё
# может быть согласовано, а интерфейс поднят из прежнего состояния. Так
# выглядит «конфиг переписали, а awg setconf не сделали», и именно это остаётся
# после восстановления, убитого между копированием файлов и перезапуском.
LV="$(sed -n '/^check_live()/,/^}$/p' "$DOC")"
if [ -z "$LV" ]; then
    bad "не нашли check_live в $DOC" "мерить нечего"
else
    LS="$WORK/livestub"; mkdir -p "$LS"
    printf '#!/bin/sh\nexit 0\n' > "$LS/ip"
    {
        echo '#!/bin/bash'
        echo 'case "${1:-}" in'
        echo '  pubkey) read -r k; printf "PUB-%s\n" "$k"; exit 0 ;;'
        echo '  show) case "${3:-}" in'
        echo '          public-key) printf "%s\n" "$LIVE_PUB" ;;'
        echo '          peers) printf "%s" "$LIVE_PEERS" | tr " " "\n" | grep -v "^$" || true ;;'
        echo '        esac; exit 0 ;;'
        echo 'esac'
        echo 'exit 0'
    } > "$LS/awg"
    chmod +x "$LS"/ip "$LS"/awg

    lv() {  # lv <живой pubkey> <живые пиры> <пиры в конфиге>
        local d="$WORK/lv" p
        rm -rf "$d"; mkdir -p "$d"
        { printf '[Interface]\nPrivateKey = SRV\n'
          for p in $3; do printf '\n[Peer]\nPublicKey = %s\n' "$p"; done
        } > "$d/i.conf"
        ( PATH="$LS:$PATH"; export LIVE_PUB="$1" LIVE_PEERS="$2"
          ok()   { printf 'OK %s\n' "$*"; }
          bad()  { printf 'BAD %s\n' "$*"; }
          warn() { printf 'WARN %s\n' "$*"; }
          eval "$LV"
          check_live i "$d/i.conf" )
    }

    out="$(lv PUB-SRV "K1 K2" "K1 K2")"
    case "$out" in
        *BAD*|*WARN*) bad "исправное состояние названо расхождением" "$out" ;;
        *) ok "ключ и пиры совпали — жалоб нет" ;;
    esac

    out="$(lv PUB-ДРУГОЙ "K1" "K1")"
    case "$out" in
        *"BAD"*"работает по ДРУГОМУ ключу"*) ok "интерфейс из чужого конфига найден" ;;
        *) bad "чужой ключ интерфейса пропущен" "$out" ;;
    esac
    case "$out" in
        *"не перезапущен"*) ok "и сказано, что это значит" ;;
        *) bad "последствие не названо" "$out" ;;
    esac

    out="$(lv PUB-SRV "K1" "K1 K2")"
    case "$out" in
        *"BAD"*"1 пиров есть в конфиге, но не загружены"*) ok "незагруженный пир найден" ;;
        *) bad "пир из конфига без загрузки пропущен" "$out" ;;
    esac

    out="$(lv PUB-SRV "K1 K9" "K1")"
    case "$out" in
        *"WARN"*"1 пиров загружены в интерфейс, но их нет в конфиге"*)
            ok "лишний пир в ядре найден" ;;
        *) bad "пир в ядре без конфига пропущен" "$out" ;;
    esac
    case "$out" in
        *"BAD"*) bad "названо поломкой" "пир мог быть добавлен руками через awg set" ;;
        *) ok "и это замечание, а не поломка" ;;
    esac

    # Молчание там, где доказать нечем: интерфейса нет.
    mkdir -p "$WORK/empty"
    out="$( PATH="$WORK/empty:$PATH"
            d="$WORK/lv2"; rm -rf "$d"; mkdir -p "$d"
            printf '[Interface]\nPrivateKey = SRV\n' > "$d/i.conf"
            ok() { printf 'OK %s\n' "$*"; }; bad() { printf 'BAD %s\n' "$*"; }
            warn() { printf 'WARN %s\n' "$*"; }
            eval "$LV"; check_live i "$d/i.conf" )"
    case "$out" in
        *BAD*|*WARN*) bad "жалоба при неподнятом интерфейсе" "$out" ;;
        *) ok "интерфейс не поднят — молчим, об этом говорит check_iface" ;;
    esac
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
