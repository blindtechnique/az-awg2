#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# «Не спрашивали — не меняем»: ответы владельца переживают --preset.
#
# collect_choices задаёт локальные умолчания (TEMPLATE='', FP=chrome, MTU=1320,
# HOST='', PRESET3='') и только потом ветвится. ВСЕ диалоги — обфускация,
# мимикрия, браузер, MTU, домен — лежат в ветке else, а --preset уходит в ветку
# if, то есть не спрашивается ничего. Дальше state перезаписывается целиком, и
# в него уезжали именно умолчания, поверх выбранного владельцем.
#
# Цена ошибки: сервер с мимикрией web, браузером safari, MTU 1280 и отдельным
# пресетом слоя 3.0 после одной команды `install.sh --preset paranoid`
# оказывался на авто/chrome/1320, а слой 3.0 переезжал на пресет слоя 2.0 —
# пустой PRESET3 значит «как у 2.0». Вернуть было неоткуда: и install-state.env,
# и obfuscation.meta уже перезаписаны, а флагов --mtu и --host у install.sh нет.
#
# Первая попытка этой починки перенесла только MTU и HOST и оставила соседние
# ключи затираться, а тест этого не увидел, потому что стенд ВСЕГДА задавал
# CLI_TEMPLATE и CLI_FP. Отсюда раздел 2: он гоняет ту же функцию с пустым CLI.
#
# Обратная сторона правила проверяется разделом 6: --reconfigure по-прежнему
# спрашивает и по-прежнему МЕНЯЕТ. Починка «заморозить сохранённое» сломала бы
# именно это.
#
#   bash tests/test_state_preserve.sh

fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# state_val вырезаем вместе с функцией: collect_choices теперь зовёт её, и без
# неё стенд мерил бы не то, что работает на сервере.
CC="$(sed -n '/^state_val()/,/^}$/p;/^collect_choices()/,/^}$/p' install.sh)"
if [ -z "$CC" ]; then
    echo "  ✘ не нашли collect_choices в install.sh — мерить нечего"
    exit 1
fi
case "$CC" in
    *state_val*) ;;
    *) echo "  ✘ state_val не попала в вырез — стенд мерил бы не то"; exit 1 ;;
esac

# ── стенд ───────────────────────────────────────────────────────────────────
# Функция вырезается из install.sh и запускается с заглушками вместо диалогов:
# нас интересует ровно то, что она положит в state. T_CLI и F_CLI — то, что
# владелец задал в командной строке; пустые значения означают «не задавал».
T_CLI=tls
F_CLI=firefox
P3_CLI=""
T3_CLI=""
run_cc() {  # run_cc <строки прежнего state или ""> <CLI_PRESET> <RECONFIGURE> [ответы диалога]
    local prev="$1" preset="$2" rec="$3" answers="${4:-}"
    local st="$WORK/install-state.env" logf="$WORK/run.log"
    rm -f "$st"
    [ -n "$prev" ] && printf '%s\n' "$prev" > "$st"
    # shellcheck disable=SC2034  # их читает вырезанная функция через eval
    (
        set -euo pipefail
        STATE="$st"
        RECONFIGURE="$rec"
        NO_BOT=1                       # бот в этом тесте не участвует
        CLI_PORTS="" CLI_PORTS3=""
        CLI_PRESET="$preset" CLI_TEMPLATE="$T_CLI" CLI_FP="$F_CLI"
        CLI_PRESET3="$P3_CLI" CLI_TEMPLATE3="$T3_CLI" CLI_AWG_VER="both"
        log() { :; }
        parse_cli_ports()  { :; }
        parse_cli_ports3() { :; }
        ask_pick()  { :; }
        ask_port()  { PORT_ANSWER=0; }
        ask_yn()    { return 1; }
        ask_valid() { return 1; }
        has_tty()   { return 1; }
        eval "$CC"
        collect_choices
    ) <<< "$answers" > "$logf" 2>&1 || {
        printf 'ПАДЕНИЕ\n'
        sed 's/^/       /' "$logf" >&2
        return 1
    }
    cat "$st"
}

val() {  # val <текст state> <ключ> → значение без кавычек
    printf '%s\n' "$1" | sed -n "s/^$2='\(.*\)'\$/\1/p"
}

want() {  # want <текст state> <ключ> <ожидание> <чем это кончится>
    local got; got="$(val "$1" "$2")"
    if [ "$got" = "$3" ]; then
        ok "$2 = «$3»"
    else
        bad "$2 стало «$got», ждали «$3»" "$4"
    fi
}

# Сервер, на котором владелец в своё время ответил на все вопросы.
PREV="AWG_PRESET='medium'
AWG_TEMPLATE='web'
AWG_PRESET3='medium'
AWG_TEMPLATE3='quic'
AWG_FP='safari'
AWG_BOT_INSTALL='0'
AWG_BOT_TOKEN=''
AWG_BOT_ADMINS=''
AWG_MTU='1280'
AWG_HOST='yandex.ru'
AWG_VER='both'"

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. --preset с явными флагами: заданное применяется"
T_CLI=tls F_CLI=firefox P3_CLI=high T3_CLI=dns
S="$(run_cc "$PREV" paranoid 0)"
want "$S" AWG_PRESET    paranoid "пресет из CLI не применён — команда ничего не сделала"
want "$S" AWG_TEMPLATE  tls      "шаблон из CLI не применён"
want "$S" AWG_FP        firefox  "профиль браузера из CLI не применён"
want "$S" AWG_PRESET3   high     "пресет слоя 3.0 из CLI не применён"
want "$S" AWG_TEMPLATE3 dns      "шаблон слоя 3.0 из CLI не применён"

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. --preset без остальных флагов: не тронуто НИЧЕГО из неспрошенного"
# Ровно этот случай пропустила первая попытка починки: перенесли MTU и HOST,
# а мимикрию, браузер и профиль слоя 3.0 оставили затираться умолчаниями.
T_CLI="" F_CLI="" P3_CLI="" T3_CLI=""
S="$(run_cc "$PREV" paranoid 0)"
want "$S" AWG_PRESET    paranoid "ради этого команду и звали"
want "$S" AWG_TEMPLATE  web       "мимикрия ушла в авто — сервер сменил маскировку молча"
want "$S" AWG_FP        safari    "браузерный профиль сброшен в chrome"
want "$S" AWG_PRESET3   medium    "слой 3.0 переехал на пресет слоя 2.0"
want "$S" AWG_TEMPLATE3 quic      "мимикрия слоя 3.0 сброшена"
want "$S" AWG_MTU       1280      "MTU сброшен в 1320 — клиентам с узким каналом станет хуже"
want "$S" AWG_HOST      yandex.ru "домен мимикрии потерян"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Чистая установка с --preset берёт умолчания"
# Переносить нечего — здесь умолчания правильны, и правка не должна была
# превратить отсутствие state в отказ или в пустые значения.
T_CLI="" F_CLI="" P3_CLI="" T3_CLI=""
S2="$(run_cc "" high 0)"
want "$S2" AWG_MTU      1320   "умолчание MTU потеряно"
want "$S2" AWG_FP       chrome "умолчание профиля браузера потеряно"
want "$S2" AWG_HOST     ""     "домен взялся ниоткуда"
want "$S2" AWG_TEMPLATE ""     "шаблон взялся ниоткуда"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Пустые значения в state не выдаются за ответы"
# Старый state (до появления этих ключей) или ручная правка: переносить нечего,
# значит работает умолчание, а не пустой MTU в конфиге сервера.
T_CLI="" F_CLI="" P3_CLI="" T3_CLI=""
S3="$(run_cc "AWG_PRESET='low'
AWG_MTU=''
AWG_FP=''
AWG_HOST=''
AWG_VER='both'" low 0)"
want "$S3" AWG_MTU 1320   "пустой MTU просочился в конфиг"
want "$S3" AWG_FP  chrome "пустой профиль браузера просочился"

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Явный флаг сильнее сохранённого"
# Обратная сторона: перенос не должен превращаться в «заморозить навсегда».
T_CLI=voip F_CLI=chrome P3_CLI="" T3_CLI=""
S5="$(run_cc "$PREV" low 0)"
want "$S5" AWG_TEMPLATE voip   "флаг --template проигнорирован"
want "$S5" AWG_FP       chrome "флаг --fp проигнорирован"
want "$S5" AWG_PRESET3  medium "а неспрошенное всё равно перенесено"

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. --reconfigure по-прежнему спрашивает и по-прежнему меняет"
# Ответы диалога: пресет 5 (paranoid), пресет3 3, мимикрия 0 (авто),
# браузер 1 (chrome), MTU 3 (1280), домен 2 + свой.
T_CLI="" F_CLI="" P3_CLI="" T3_CLI=""
S4="$(run_cc "$PREV" "" 1 "5
3
0
1
3
2
example.org")"
want "$S4" AWG_MTU    1280        "диалог MTU не отработал"
want "$S4" AWG_HOST   example.org "диалог домена не отработал"
want "$S4" AWG_PRESET paranoid    "диалог пресета не отработал"
want "$S4" AWG_FP     chrome      "диалог браузера не отработал"

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Правило записано в коде, а не подобрано под тест"
# Перенос обязан читать сохранённое состояние внутри ветки --preset и обязан
# покрывать все ключи. Если кто-то заменит его на константу или снова забудет
# половину, разделы выше могут остаться зелёными по случайности.
BR="$(printf '%s\n' "$CC" | sed -n '/if \[ -n "\$CLI_PRESET" \]/,/^    else$/p')"
for k in AWG_TEMPLATE AWG_FP AWG_PRESET3 AWG_TEMPLATE3 AWG_MTU AWG_HOST; do
    if printf '%s\n' "$BR" | grep -q "$k"; then
        ok "ветка --preset читает $k"
    else
        bad "в ветке --preset нет $k" "значит оно берётся из умолчания"
    fi
done

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit "$fail"
