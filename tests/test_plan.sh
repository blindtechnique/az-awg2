#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --plan: показать, что сделает прогон, и ничего не сделать.
#
# Два свойства, ради которых он и нужен:
#   1) отчёт совпадает с тем, что произойдёт на самом деле — решение о режиме
#      берётся общей функцией obf_mode, а не второй копией условия;
#   2) сам план не меняет на диске ни байта.
#
#   bash tests/test_plan.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
inc() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет «$3»" ;; esac; }
noinc() { case "$2" in *"$3"*) bad "$1" "лишнее «$3»" ;; *) ok "$1" ;; esac; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── стенд: установленный сервер ─────────────────────────────────────────────
mk_stand() {  # mk_stand <каталог> <layers: 2|23> <клиентов>
    local d="$1" L="$2" n="${3:-3}" l3=0 i s
    case "$L" in *3*) l3=1 ;; esac
    mkdir -p "$d/etc" "$d/dest/clients"
    {
        echo "MODE=parallel"; echo "LAYER2=1"; echo "LAYER3=$l3"
        echo "AZ_IFACE=antizapret-awg"; echo "AZ_SUBNET=10.29.9"; echo "AZ_PORT=41234"
        echo "AZ_DNS=10.29.8.1"; echo "AZ_SPLIT=1"
        echo "VPN_IFACE=vpn-awg"; echo "VPN_SUBNET=10.28.9"; echo "VPN_PORT=42345"
        echo "VPN_DNS=10.29.8.1"; echo "VPN_SPLIT=0"
        echo "AZ3_IFACE=antizapret-awg3"; echo "AZ3_SUBNET=10.29.10"; echo "AZ3_PORT=43456"
        echo "AZ3_DNS=10.29.8.1"; echo "AZ3_SPLIT=1"
        echo "VPN3_IFACE=vpn-awg3"; echo "VPN3_SUBNET=10.28.10"; echo "VPN3_PORT=44567"
        echo "VPN3_DNS=10.29.8.1"; echo "VPN3_SPLIT=0"
        echo "MTU=1320"; echo "MTU3=1280"
    } > "$d/etc/services.env"
    printf "AWG_Jc='4'\nAWG_S1='80'\n" > "$d/etc/obfuscation.env"
    [ "$l3" = 1 ] && printf "AWG_Jc='5'\nAWG_S1='81'\n" > "$d/etc/obfuscation3.env"
    for s in antizapret vpn; do
        mkdir -p "$d/dest/clients/$s"
        for i in $(seq 1 "$n"); do
            printf '[Interface]\n' > "$d/dest/clients/$s/$s-c$i-am.conf"
        done
    done
    if [ "$l3" = 1 ]; then
        for s in antizapret3 vpn3; do
            mkdir -p "$d/dest/clients/$s"
            printf '[Interface]\n' > "$d/dest/clients/$s/$s-c1-am.conf"
        done
    fi
    return 0
}

# копия интеграции с путями, перенаправленными на стенд
integ() {  # integ <каталог> → путь к скрипту
    local d="$1" f="$1/integration.sh"
    [ -f "$f" ] && { echo "$f"; return; }
    cp patches/antizapret-awg-integration.sh "$f"
    sed -i "s#^AWG_DIR=\"/etc/amnezia/amneziawg\"#AWG_DIR=\"$d/etc\"#" "$f"
    sed -i "s#^DEST=\"/opt/antizapret-awg\"#DEST=\"$d/dest\"#" "$f"
    # Проверку на root снимаем только у копии: стенд под root не гоняется.
    # Что она есть в настоящем скрипте — отдельный пункт ниже, и это важно:
    # без root план читал бы services.env и профили с правами 600 и показал бы
    # «первая установка» на работающем сервере, то есть соврал бы.
    sed -i 's#^\[ "$(id -u)" = 0 \] .*#:#' "$f"
    echo "$f"
}

snapshot() {  # snapshot <каталог> — состав и содержимое, кроме самой копии скрипта
    ( cd "$1" && find etc dest -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null )
}

plan() {  # plan <каталог> <--awg X> <флаги…> → отчёт
    local d="$1" ver="$2"; shift 2
    local sh; sh="$(integ "$d")"
    bash "$sh" --plan --awg "$ver" --preset medium --fp chrome --mtu 1320 "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. План ничего не меняет на диске"
D="$WORK/ro"; mk_stand "$D" 23 5 >/dev/null
before="$(snapshot "$D")"
out="$(plan "$D" both)"
after="$(snapshot "$D")"
if [ "$before" = "$after" ]; then
    ok "ни один файл не изменился и не появился"
else
    bad "план что-то тронул" "$(diff <(echo "$before") <(echo "$after") | head -5)"
fi
inc "и сам говорит, что это только план" "$out" "Это только план: ничего не изменено"

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Обычный прогон: профиль сохраняется"
inc "названа операция"              "$out" "ПОВТОРНЫЙ ПРОГОН"
inc "профиль 2.0 в «не изменится»"  "$out" "профиль обфускации 2.0 (применяется существующий)"
inc "профиль 3.0 тоже"              "$out" "профиль обфускации 3.0 (применяется существующий)"
inc "перевыпуска НЕ будет"          "$out" "перевыпуск профиля обфускации 2.0"
inc "переимпорт не понадобится"     "$out" "Переимпортировать конфиги никому не придётся"
inc "порты названы"                 "$out" "41234/42345"
inc "подсети названы"               "$out" "10.29.9.0/24"
inc "число конфигов 2.0"            "$out" "конфиги клиентов 2.0: 10"
inc "число конфигов 3.0"            "$out" "конфиги клиентов 3.0: 2"
noinc "и никого не пугает"          "$out" "перестанут подключаться"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. --reconfigure: сказано, скольких это отключит"
out="$(plan "$D" both --reconfigure)"
inc "названа операция"          "$out" "НОВЫЙ ПРОФИЛЬ ОБФУСКАЦИИ"
inc "профиль 2.0 — новый"       "$out" "профиль обфускации 2.0 — НОВЫЙ"
inc "и сказано, сколько ломает" "$out" "конфиги клиентов 2.0: 10 — все перестанут подключаться"
inc "профиль 3.0 — тоже новый"  "$out" "профиль обфускации 3.0 — НОВЫЙ"
inc "предупреждение выдано"     "$out" "придётся заново скачать и импортировать"
noinc "ложного успокоения нет"  "$out" "никому не придётся"
after2="$(snapshot "$D")"
[ "$before" = "$after2" ] && ok "и даже разрушительный план ничего не тронул" \
    || bad "план с --reconfigure изменил файлы"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. --update: до профиля и клиентов дело не доходит"
out="$(plan "$D" both --update)"
inc "названа операция"        "$out" "ОБНОВЛЕНИЕ КОДА"
inc "профили сохраняются"     "$out" "✓ профиль обфускации 2.0"
inc "конфиги сохраняются"     "$out" "конфиги клиентов: 2.0 — 10"
inc "порты не меняются"       "$out" "смена портов и подсетей"
inc "переимпорт не нужен"     "$out" "Переимпортировать конфиги никому не придётся"
noinc "ничего не «НОВЫЙ»"     "$out" "НОВЫЙ"

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Только слой 2.0: про 3.0 не выдумывается"
D2="$WORK/l2"; mk_stand "$D2" 2 4 >/dev/null
out="$(plan "$D2" 2)"
inc "конфиги 2.0 посчитаны"   "$out" "конфиги клиентов 2.0: 8"
noinc "нет чужих портов"      "$out" "43456"
noinc "нет профиля 3.0"       "$out" "профиль обфускации 3.0"
# ${LAYER3:+…} раскрывается и на «0» — на таком сервере отчёт дописывал
# «, 3.0 — 0». Ровно эта ловушка уже ловилась в install.sh.
out="$(plan "$D2" 2 --update)"
inc "обновление считает конфиги 2.0" "$out" "конфиги клиентов: 2.0 — 8"
noinc "и не выдумывает нулевой 3.0"  "$out" "3.0 — 0"

head_ "5б. Добавление 3.0 к работающему 2.0"
# тот же сервер, но прогон просит оба слоя: 3.0 появится, 2.0 останется цел
out="$(plan "$D2" both)"
inc "профиль 3.0 будет создан"   "$out" "профиль обфускации 3.0 — НОВЫЙ"
inc "профиль 2.0 не трогается"   "$out" "профиль обфускации 2.0 (применяется существующий)"
inc "сказано это прямо"          "$out" "слой 2.0 при этом не затрагивается"
noinc "клиенты 2.0 не в списке потерь" "$out" "конфиги клиентов 2.0: 8 — все перестанут"

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Чистая машина: план первой установки"
D3="$WORK/empty"; mkdir -p "$D3/etc" "$D3/dest"
rm -f "$D3/etc/services.env"
out="$(plan "$D3" both)"
inc "названа операция"        "$out" "ПЕРВАЯ УСТАНОВКА"
inc "сказано, что ломать нечего" "$out" "ломать нечего"
[ -f "$D3/etc/services.env" ] && bad "план создал services.env" || ok "ничего не создано"

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Проверка на root остаётся"
if grep -q '^\[ "$(id -u)" = 0 \]' patches/antizapret-awg-integration.sh; then
    ok "интеграция по-прежнему требует root"
else
    bad "проверка на root пропала" "без неё план прочитает не всё и соврёт"
fi

head_ "8. У плана нет своей копии условия"
# Если бы план решал сам, он бы разошёлся с прогоном — ровно этот класс ошибок
# в проекте уже случался дважды.
body="$(sed -n '/^plan_report()/,/^}/p' patches/antizapret-awg-integration.sh)"
if printf '%s\n' "$body" | grep -q 'RECONFIGURE.*!= 1.*-s '; then
    bad "в plan_report своя проверка профиля — она разойдётся с gen_obfuscation"
else
    ok "решение берётся общей obf_mode, а не повторяется"
fi
n="$(grep -c 'obf_mode "\$AWG_DIR/obfuscation' patches/antizapret-awg-integration.sh)"
[ "$n" -ge 4 ] && ok "obf_mode зовут и прогон, и план ($n мест)" \
    || bad "obf_mode используется реже, чем ожидалось ($n)"

head_ "9. install.sh: флаг доходит вниз"
# ${PLAN:+…} здесь уже ловили в соседнем месте: «0» тоже непустое, и план
# уезжал бы вниз всегда — то есть ровно наоборот.
DEC="$(grep -F 'plan=--plan; fi' install.sh | head -1)"
if [ -z "$DEC" ]; then
    bad "в install.sh не найдено решение о --plan" "мерить нечего"
else
    # shellcheck disable=SC2034  # PLAN читает вырезанное условие под eval
    p() { ( PLAN="$1"; plan=""; eval "$DEC"; echo "[$plan]" ); }
    [ "$(p 1)" = "[--plan]" ] && ok "PLAN=1 → флаг уезжает вниз" \
        || bad "PLAN=1 флаг не передаётся" "вышло $(p 1)"
    [ "$(p 0)" = "[]" ] && ok "PLAN=0 → флага нет" \
        || bad "PLAN=0 флаг всё равно передаётся" "вышло $(p 0)"
fi

# --awg идёт мимо диалога collect_choices, и без отдельной строки план
# показывал бы слои из install-state.env вместо запрошенных.
AV="$(grep -F 'case "$CLI_AWG_VER" in 2|3|both)' install.sh | head -1)"
if [ -z "$AV" ]; then
    bad "план не учитывает --awg с командной строки"
else
    # shellcheck disable=SC2034  # CLI_AWG_VER читает вырезанная строка
    v() { ( CLI_AWG_VER="$1"; V="${2:-both}"; eval "$AV"; echo "$V" ); }
    [ "$(v 3 both)" = 3 ]    && ok "--awg 3 перебивает состояние" \
        || bad "--awg 3 потерян" "вышло $(v 3 both)"
    [ "$(v "" 2)" = 2 ]      && ok "без --awg берётся состояние" \
        || bad "состояние потеряно" "вышло $(v "" 2)"
    [ "$(v мусор both)" = both ] && ok "мусор в --awg не уезжает вниз" \
        || bad "мусор в --awg уехал вниз" "вышло $(v мусор both)"
fi

head_ "10. План стоит раньше любых действий"
# Тут и была настоящая дыра: --update уходил своей дорогой ДО проверки плана,
# и `--plan --update` делал настоящее обновление.
body="$(sed -n '/^main()/,/^}/p' install.sh)"
nl_of() { printf '%s\n' "$body" | grep -n "$1" | head -1 | cut -d: -f1; }
pl="$(nl_of 'PLAN" = 1 \]; then')"
if [ -z "$pl" ]; then
    bad "в main() нет ветки плана"
else
    for pair in 'UPDATE" = 1 \]:--update' 'MIGRATE" = 1 \]:--migrate' \
                'awg-resume.service \]:чистка awg-resume'; do
        pat="${pair%%:*}"; name="${pair##*:}"
        n="$(nl_of "$pat")"
        if [ -z "$n" ]; then
            bad "не нашли в main(): $name"
        elif [ "$pl" -lt "$n" ]; then
            ok "план раньше, чем $name"
        else
            bad "$name отрабатывает раньше плана" "с --plan это будет сделано по-настоящему"
        fi
    done
fi

# Ранний выход в awg_layer: план не ставит статистику и бота.
lay="$(sed -n '/^awg_layer()/,/^}/p' install.sh)"
nl_lay() { printf '%s\n' "$lay" | grep -n "$1" | head -1 | cut -d: -f1; }
r="$(nl_lay 'PLAN" = 1 \] && return 0')"
s1="$(nl_lay '^    setup_stats$')"; s2="$(nl_lay '^    setup_bot$')"
if [ -z "$r" ] || [ -z "$s1" ] || [ -z "$s2" ]; then
    bad "не нашли ранний выход или setup_stats/setup_bot в awg_layer"
elif [ "$r" -lt "$s1" ] && [ "$r" -lt "$s2" ]; then
    ok "план возвращается раньше статистики и бота"
else
    bad "план доходит до setup_stats/setup_bot"
fi

head_ "11. Операции без отчёта план не подменяет собой"
PE="$(sed -n '/^plan_entry()/,/^}/p' install.sh)"
if [ -z "$PE" ]; then
    bad "plan_entry не найдена"
else
    run_pe() {  # run_pe <переменная|""> <base: 0|1> → вывод и rc
        # shellcheck disable=SC2034  # их читает сама plan_entry под eval
        ( UNINSTALL=0; INSTALL_BASE=0; INSTALL_BOT=0; REMOVE_BOT=0
          [ -n "$1" ] && eval "$1=1"
          err() { printf 'ERR %s\n' "$*"; }
          log() { printf 'LOG %s\n' "$*"; }
          if [ "$2" = 1 ]; then base_installed() { return 0; }
          else base_installed() { return 1; }; fi
          awg_layer() { echo "ВЫЗВАН_AWG_LAYER"; }
          eval "$PE"
          plan_entry; printf 'rc=%s\n' "$?" )
    }
    out="$(run_pe "" 1)"
    inc "обычный план доходит до слоя" "$out" "ВЫЗВАН_AWG_LAYER"
    inc "и завершается успехом"        "$out" "rc=0"
    for pair in 'UNINSTALL:--uninstall' 'INSTALL_BASE:--install-base' \
                'INSTALL_BOT:--install-bot' 'REMOVE_BOT:--remove-bot'; do
        var="${pair%%:*}"; flag="${pair##*:}"
        out="$(run_pe "$var" 1)"
        noinc "$flag не выполняется"  "$out" "ВЫЗВАН_AWG_LAYER"
        inc   "$flag назван в отказе" "$out" "$flag"
        inc   "$flag → код 2"         "$out" "rc=2"
    done
    out="$(run_pe "" 0)"
    noinc "без базы слой не планируется" "$out" "ВЫЗВАН_AWG_LAYER"
    inc   "и сказано, что ставить не на что" "$out" "ставить не на что"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
