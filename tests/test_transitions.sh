#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Матрица переходов: из какого состояния каким действием и что при этом обязано
# сохраниться.
#
# Проект стал stateful, и последние баги шли одной и той же дорогой: правка
# создаёт новое состояние, а edge case вылезает в соседнем переходе. Отдельные
# тесты функций такое не ловят — нужна таблица.
#
# Проверяется настоящий код: условия выбора режима вырезаются из установщика,
# а сам режим отрабатывает на реальных awg-obfuscation.sh и client-awg.sh с
# путями, перенаправленными во временный каталог. Не подделывается ничего,
# кроме systemd и ip, которых на этой машине всё равно нет.
#
#   bash tests/test_transitions.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ждали [$3], вышло [$2]"; fi; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── стенд ───────────────────────────────────────────────────────────────────
# layers: 2 | 3 | 23 | none
mk_stand() {  # mk_stand <каталог> <layers>
    local d="$1" L="$2" l2=0 l3=0
    case "$L" in *2*) l2=1 ;; esac
    case "$L" in *3*) l3=1 ;; esac
    mkdir -p "$d/etc" "$d/clients"
    {
        echo "MODE=parallel"
        echo "LAYER2=$l2"
        echo "LAYER3=$l3"
        echo "AZ_IFACE=antizapret-awg";  echo "AZ_SUBNET=10.29.9"
        echo "AZ_PORT=41234";            echo "AZ_DNS=10.29.8.1"; echo "AZ_SPLIT=1"
        echo "VPN_IFACE=vpn-awg";        echo "VPN_SUBNET=10.28.9"
        echo "VPN_PORT=42345";           echo "VPN_DNS=10.29.8.1"; echo "VPN_SPLIT=0"
        echo "AZ3_IFACE=antizapret-awg3"; echo "AZ3_SUBNET=10.29.10"
        echo "AZ3_PORT=43456";           echo "AZ3_DNS=10.29.8.1"; echo "AZ3_SPLIT=1"
        echo "VPN3_IFACE=vpn-awg3";      echo "VPN3_SUBNET=10.28.10"
        echo "VPN3_PORT=44567";          echo "VPN3_DNS=10.29.8.1"; echo "VPN3_SPLIT=0"
        echo "MTU=1320"; echo "MTU3=1280"
    } > "$d/etc/services.env"

    [ "$l2" = 1 ] && mk_layer "$d" 2
    [ "$l3" = 1 ] && mk_layer "$d" 3
    return 0
}

mk_layer() {  # mk_layer <каталог> <2|3>
    local d="$1" v="$2" env svcs ifs
    if [ "$v" = 2 ]; then
        env="obfuscation.env"; svcs="antizapret vpn"; ifs="antizapret-awg vpn-awg"
    else
        env="obfuscation3.env"; svcs="antizapret3 vpn3"; ifs="antizapret-awg3 vpn-awg3"
    fi
    # значения в одинарных кавычках — так их пишет to_env в awg_obfuscate.py
    {
        echo "AWG_Jc='4'"; echo "AWG_Jmin='8'"; echo "AWG_Jmax='80'"
        echo "AWG_S1='8${v}'"; echo "AWG_S2='23'"; echo "AWG_S3='26'"; echo "AWG_S4='15'"
        echo "AWG_H1='52587784-52618069'"; echo "AWG_H2='559414338-559451961'"
        echo "AWG_H3='1366798142-1366837561'"; echo "AWG_H4='1485382529-1485414651'"
        echo "AWG_I1='<b 0xc30000000${v}><t><r 999>'"
        [ "$v" = 3 ] && echo "AWG_HeaderProtectionKey='YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY='"
        [ "$v" = 3 ] && echo "AWG_HPK_HEX='6162636465666768696a6b6c6d6e6f707172737475767778797a313233343536'"
    } > "$d/etc/$env"

    local i
    for i in $ifs; do
        {
            echo "[Interface]"
            echo "Address = 10.29.${v}.1/24"
            echo "ListenPort = 4${v}234"
            echo "PrivateKey = QEDCBA0987654321abcdefghijklmnopqrstuvwxy${v}="
            echo
            echo "[Peer]"
            echo "PublicKey = ZYXWVU0987654321abcdefghijklmnopqrstuvwxyzB="
            echo "AllowedIPs = 10.29.${v}.2/32"
        } > "$d/etc/$i.conf"
    done
    local s
    for s in $svcs; do
        mkdir -p "$d/clients/$s"
        {
            echo "[Interface]"
            echo "PrivateKey = AAAABBBB0987654321abcdefghijklmnopqrstuvw${v}="
            echo "Address = 10.29.${v}.2/32"
            echo "DNS = 10.29.8.1"
            echo "MTU = 1320"
            echo
            echo "[Peer]"
            echo "PublicKey = ZYXWVU0987654321abcdefghijklmnopqrstuvwxyzB="
            echo "Endpoint = vpn.example.com:4${v}234"
            echo "AllowedIPs = 10.29.${v}.0/24, 10.29.8.1/32"
            echo "PersistentKeepalive = 15"
        } > "$d/clients/$s/$s-ann-am.conf"
    done
}

# ── снимки того, что обязано (или не обязано) меняться ──────────────────────
# identity — то, что не имеет права измениться НИ ПРИ КАКОМ действии:
# ключи, порты, подсети, адреса. Их смена означает потерю доступа без
# возможности починить конфиг на месте.
identity() {  # identity <каталог> [2|3|all]
    local d="$1" scope="${2:-all}" ifs cls keys
    case "$scope" in
        2)   ifs="$d/etc/antizapret-awg.conf $d/etc/vpn-awg.conf"
             cls="$d/clients/antizapret $d/clients/vpn"
             keys='^(AZ|VPN)_(PORT|SUBNET|IFACE)=' ;;
        3)   ifs="$d/etc/antizapret-awg3.conf $d/etc/vpn-awg3.conf"
             cls="$d/clients/antizapret3 $d/clients/vpn3"
             keys='^(AZ3|VPN3)_(PORT|SUBNET|IFACE)=' ;;
        *)   ifs="$d/etc/*.conf"; cls="$d/clients/*"
             keys='^(AZ|VPN)[0-9]?_(PORT|SUBNET|IFACE)=' ;;
    esac
    { # shellcheck disable=SC2086
      grep -hE '^(PrivateKey|ListenPort|Address) ' $ifs 2>/dev/null
      # shellcheck disable=SC2086
      grep -hE '^(PrivateKey|Address|PublicKey|Endpoint) ' $cls/*.conf 2>/dev/null
      grep -hE "$keys" "$d/etc/services.env"
    } | sort | md5sum | cut -d' ' -f1
}
profile()  { md5sum "$1/etc/$2" 2>/dev/null | cut -d' ' -f1; }   # obfuscation[3].env
clients() {  # clients <каталог> [2|3|all]
    local cls
    case "${2:-all}" in
        2) cls="$1/clients/antizapret $1/clients/vpn" ;;
        3) cls="$1/clients/antizapret3 $1/clients/vpn3" ;;
        *) cls="$1/clients/*" ;;
    esac
    # shellcheck disable=SC2086
    cat $cls/*.conf 2>/dev/null | md5sum | cut -d' ' -f1
}

# ── настоящие скрипты с путями, перенаправленными на стенд ──────────────────
client_sh() {  # client_sh <каталог> → путь
    local d="$1" bin="$1/bin"
    [ -x "$bin/client-awg.sh" ] && { echo "$bin/client-awg.sh"; return; }
    mkdir -p "$bin"
    cp overlay/bin/client-awg.sh overlay/bin/awg-export.py "$bin/"
    sed -i "s#^AWG_DIR=\"/etc/amnezia/amneziawg\"#AWG_DIR=\"$d/etc\"#" "$bin/client-awg.sh"
    sed -i "s#^CLIENT_DIR=\"/opt/antizapret-awg/clients\"#CLIENT_DIR=\"$d/clients\"#" "$bin/client-awg.sh"
    chmod +x "$bin/client-awg.sh"
    echo "$bin/client-awg.sh"
}

# Режим выбирает НАСТОЯЩАЯ функция из установщика, а не её копия здесь.
# Пустая выборка = тест мерит сам себя, поэтому она фатальна.
OBF_MODE_FN="$(sed -n '/^obf_mode()/,/^}/p' patches/antizapret-awg-integration.sh)"
REC="$(grep -F 'rec=--reconfigure; fi' install.sh | head -1)"
[ -n "$OBF_MODE_FN" ] || { echo "не нашли obf_mode в интеграции — мерить нечего"; exit 1; }
[ -n "$REC" ] || { echo "не нашли выбор --reconfigure в install.sh — мерить нечего"; exit 1; }

mode_of() {  # mode_of <2|3> <RECONFIGURE> <CLI_PRESET> <каталог etc> → --apply|--reapply
    local v="$1" f="$4/obfuscation.env"
    [ "$v" = 2 ] || f="$4/obfuscation3.env"
    # переменные ниже читают вырезанные из установщика куски под eval —
    # статически такую связь не увидеть
    # shellcheck disable=SC2034
    ( RECONFIGURE="$2"; CLI_PRESET="$3"; rec=""
      eval "$REC"                       # установщик решает, передавать ли флаг вниз
      if [ "$rec" = --reconfigure ]; then RECONFIGURE=1; else RECONFIGURE=0; fi
      eval "$OBF_MODE_FN"               # и его же obf_mode решает, что делать
      obf_mode "$f" )
}

apply_layer() {  # apply_layer <каталог> <2|3> <режим> [пресет]
    local d="$1" v="$2" m="$3" p="${4:-medium}" rc=0
    if [ "$v" = 2 ]; then
        AWG_DIR="$d/etc" AWG_AZ_CONF="$d/etc/antizapret-awg.conf" \
        AWG_VPN_CONF="$d/etc/vpn-awg.conf" \
            bash overlay/bin/awg-obfuscation.sh --preset "$p" "$m" >"$d/obf.log" 2>&1 || rc=$?
    else
        AWG_DIR="$d/etc" AWG3_AZ_CONF="$d/etc/antizapret-awg3.conf" \
        AWG3_VPN_CONF="$d/etc/vpn-awg3.conf" \
            bash overlay/bin/awg-obfuscation.sh --v3 --preset "$p" "$m" >"$d/obf.log" 2>&1 || rc=$?
    fi
    return $rc
}

regen() {  # regen <каталог>
    local sh; sh="$(client_sh "$1")"
    ( cd "$1" && bash "$sh" regen-all >"$1/regen.log" 2>&1 )
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. --update вообще не доходит до профиля и клиентов"
# Самое сильное свойство перехода «обновить код»: оно структурное, а не
# вычисляемое. Ветка возвращается ДО plan_services, gen_obfuscation и regen-all.
# Ветка берётся из main(), а не первая попавшаяся: с появлением plan_report
# таких строк в файле стало три, переменная делалась многострочной, и
# сравнение номеров превращалось в сравнение строк («1007» < «849…»).
main_at="$(grep -n '^main() {' patches/antizapret-awg-integration.sh | cut -d: -f1)"
upd_start="$(awk -F: -v m="$main_at" '$1>m' <(grep -n 'if \[ "\$UPDATE" = 1 \]; then' \
             patches/antizapret-awg-integration.sh) | head -1 | cut -d: -f1)"
upd_ret="$(awk -v s="$upd_start" 'NR>s && /^        return$|^        return 0$/{print NR; exit}' \
           patches/antizapret-awg-integration.sh)"
for what in plan_services gen_obfuscation regen-all; do
    # grep -v по комментариям: слово «regen-all» встречается и в пояснениях,
    # а мерить надо вызов.
    ln="$(grep -n -- "$what" patches/antizapret-awg-integration.sh \
          | grep -v ':[[:space:]]*#' \
          | awk -F: -v s="$upd_start" '$1>s {print $1; exit}')"
    if [ -n "$upd_ret" ] && [ -n "$ln" ] && [ "$ln" -gt "$upd_ret" ]; then
        ok "$what вызывается только после выхода из ветки --update"
    else
        bad "$what достижим из --update" "return на строке ${upd_ret:-?}, вызов на ${ln:-?}"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Таблица режимов: из какого состояния что выбирается"
E="$WORK/dec"; mkdir -p "$E/none"
mk_stand "$E/l2" 2 >/dev/null; mk_stand "$E/l3" 3 >/dev/null; mk_stand "$E/l23" 23 >/dev/null

#        описание                                  слой RECONF PRESET  каталог      ждём
while read -r name v rc pre dir want; do
    [ -z "$name" ] && continue
    # прочерк = пресет не задан: read кавычки не обрабатывает, и «""» попало бы
    # в CLI_PRESET двумя символами — непустым значением
    [ "$pre" = "-" ] && pre=""
    chk "$(printf '%s' "$name" | tr '_' ' ')" "$(mode_of "$v" "$rc" "$pre" "$E/$dir/etc")" "$want"
done <<'ROWS'
пусто:_установка_2.0_выпускает_профиль          2 0 -    none --apply
пусто:_установка_3.0_выпускает_профиль          3 0 -    none --apply
2.0_есть:_повторный_прогон_не_трогает_профиль   2 0 -    l2   --reapply
2.0_есть:_--reconfigure_выпускает_новый         2 1 -    l2   --apply
2.0_есть:_явный_--preset_выпускает_новый        2 0 high l2   --apply
3.0_есть:_повторный_прогон_не_трогает_профиль   3 0 -    l3   --reapply
3.0_есть:_--reconfigure_выпускает_новый         3 1 -    l3   --apply
оба_слоя:_повторный_прогон_не_трогает_2.0       2 0 -    l23  --reapply
оба_слоя:_повторный_прогон_не_трогает_3.0       3 0 -    l23  --reapply
только_2.0:_включение_3.0_выпускает_профиль_3.0 3 0 -    l2   --apply
только_2.0:_и_НЕ_трогает_профиль_2.0            2 0 -    l2   --reapply
ROWS

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Что переходы делают на самом деле"

run_row() {  # run_row <название> <layers> <слой> <RECONF> <PRESET> <проф> <клиенты>
    local name="$1" L="$2" v="$3" rc="$4" pre="$5" want_prof="$6" want_cli="$7"
    local d
    d="$WORK/$(echo "$name" | md5sum | cut -c1-8)"
    mk_stand "$d" "$L" >/dev/null
    regen "$d"                                   # привести к каноническому виду
    local env; [ "$v" = 2 ] && env=obfuscation.env || env=obfuscation3.env
    local id0 pr0 cl0; id0="$(identity "$d")"; pr0="$(profile "$d" "$env")"; cl0="$(clients "$d")"
    local m; m="$(mode_of "$v" "$rc" "$pre" "$d/etc")"
    apply_layer "$d" "$v" "$m" "${pre:-medium}" || { bad "$name" "обфускатор упал: $(tail -2 "$d/obf.log")"; return; }
    regen "$d"
    local id1 pr1 cl1; id1="$(identity "$d")"; pr1="$(profile "$d" "$env")"; cl1="$(clients "$d")"

    [ "$id0" = "$id1" ] || { bad "$name" "identity изменилась — ключи/порты/адреса поехали"; return; }
    case "$want_prof" in
        same) [ "$pr0" = "$pr1" ] || { bad "$name" "профиль перевыпущен, а не должен"; return; } ;;
        new)  [ "$pr0" != "$pr1" ] || { bad "$name" "профиль не изменился, хотя должен"; return; } ;;
    esac
    case "$want_cli" in
        same) [ "$cl0" = "$cl1" ] || { bad "$name" "конфиги клиентов изменились"; return; } ;;
        new)  [ "$cl0" != "$cl1" ] || { bad "$name" "конфиги клиентов не пересозданы"; return; } ;;
    esac
    ok "$name"
}

run_row "2.0: повторный прогон — профиль и конфиги те же"      2   2 0 ""   same same
run_row "2.0: --reconfigure — новый профиль, identity цела"    2   2 1 ""   new  new
run_row "2.0: --preset — новый профиль, identity цела"         2   2 0 high new  new
run_row "3.0: повторный прогон — профиль и конфиги те же"      3   3 0 ""   same same
run_row "3.0: --reconfigure — новый профиль, identity цела"    3   3 1 ""   new  new
run_row "оба слоя: повторный прогон — всё на месте"            23  2 0 ""   same same

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Слои не задевают друг друга"
D="$WORK/iso"; mk_stand "$D" 23 >/dev/null; regen "$D"
p2_0="$(profile "$D" obfuscation.env)"; p3_0="$(profile "$D" obfuscation3.env)"
c0="$(clients "$D")"
apply_layer "$D" 3 --apply paranoid && regen "$D"
chk "смена профиля 3.0 не тронула профиль 2.0" "$(profile "$D" obfuscation.env)" "$p2_0"
[ "$(profile "$D" obfuscation3.env)" != "$p3_0" ] \
    && ok "профиль 3.0 при этом действительно сменился" \
    || bad "профиль 3.0 не сменился — проверка ничего не значит"
[ "$(clients "$D")" != "$c0" ] \
    && ok "конфиги пересозданы" || bad "конфиги не пересозданы"
# и наоборот: 2.0 не трогает 3.0
D2="$WORK/iso2"; mk_stand "$D2" 23 >/dev/null; regen "$D2"
q3="$(profile "$D2" obfuscation3.env)"
apply_layer "$D2" 2 --apply paranoid && regen "$D2"
chk "смена профиля 2.0 не тронула профиль 3.0" "$(profile "$D2" obfuscation3.env)" "$q3"

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Включение слоя 3.0 рядом с работающим 2.0"
N="$WORK/add3"; mk_stand "$N" 2 >/dev/null; regen "$N"
id0="$(identity "$N" 2)"; p2="$(profile "$N" obfuscation.env)"; c2="$(clients "$N" 2)"
# установщик: слой 2.0 существует → --reapply, слой 3.0 новый → --apply
mk_layer "$N" 3   # интерфейсы и клиенты слоя 3.0 заводит build_iface3, профиля ещё нет
rm -f "$N/etc/obfuscation3.env"
sed -i 's/^LAYER3=0/LAYER3=1/' "$N/etc/services.env"
chk "для 2.0 выбран --reapply"  "$(mode_of 2 0 "" "$N/etc")" "--reapply"
chk "для 3.0 выбран --apply"    "$(mode_of 3 0 "" "$N/etc")" "--apply"
apply_layer "$N" 2 --reapply && apply_layer "$N" 3 --apply && regen "$N"
chk "профиль 2.0 не тронут"     "$(profile "$N" obfuscation.env)" "$p2"
chk "identity слоя 2.0 не тронута" "$(identity "$N" 2)" "$id0"
chk "конфиги слоя 2.0 не тронуты" "$(clients "$N" 2)" "$c2"
[ -s "$N/etc/obfuscation3.env" ] && ok "профиль 3.0 создан" || bad "профиля 3.0 нет"

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Битое состояние: отказ, а не тихий перевыпуск"
B="$WORK/broken"; mk_stand "$B" 2 >/dev/null; regen "$B"
c_before="$(clients "$B")"
rm -f "$B/etc/obfuscation.env"
if apply_layer "$B" 2 --reapply; then
    bad "--reapply без профиля отработал молча" "должен был отказаться"
else
    ok "--reapply без профиля отказывается (код $?)"
    grep -q "нечего применять" "$B/obf.log" && ok "и объясняет причину" \
        || bad "причина не названа" "$(tail -1 "$B/obf.log")"
fi
chk "клиенты при этом не тронуты" "$(clients "$B")" "$c_before"

# пустой файл профиля — это не профиль: выпускаем новый, а не падаем
B2="$WORK/broken2"; mk_stand "$B2" 2 >/dev/null
: > "$B2/etc/obfuscation.env"
chk "пустой obfuscation.env считается отсутствующим" "$(mode_of 2 0 "" "$B2/etc")" "--apply"

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
