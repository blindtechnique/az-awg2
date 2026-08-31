#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# «Не спрашивали — не меняем»: ответы владельца переживают --preset.
#
# collect_choices задаёт локальные умолчания (MTU=1320, HOST='') и только потом
# ветвится. Диалоги MTU и домена мимикрии лежат в ветке else, а --preset уходит
# в ветку if — то есть их никто не спрашивает. Дальше state перезаписывается
# целиком, и в него уезжали именно умолчания, поверх выбранного владельцем.
#
# Цена ошибки: сервер, поставленный с MTU 1280 «для мобильных», после одной
# команды `install.sh --preset paranoid` молча возвращался на 1320, и взять
# прежнее значение было больше неоткуда — install-state.env уже перезаписан.
# Флагов --mtu и --host у install.sh нет вовсе, так что задать их заново в том
# же прогоне тоже нельзя.
#
# Обратная сторона правила проверяется здесь же: --reconfigure по-прежнему
# спрашивает и по-прежнему МЕНЯЕТ. Починка «заморозить сохранённое» сломала бы
# именно это, и раздел 5 на неё краснеет.
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

CC="$(sed -n '/^collect_choices()/,/^}$/p' install.sh)"
if [ -z "$CC" ]; then
    echo "  ✘ не нашли collect_choices в install.sh — мерить нечего"
    exit 1
fi

# ── стенд ───────────────────────────────────────────────────────────────────
# Функция вырезается из install.sh и запускается с заглушками вместо диалогов:
# нас интересует ровно то, что она положит в state.
run_cc() {  # run_cc <строки прежнего state или ""> <CLI_PRESET> <RECONFIGURE> [ответы диалога]
    local prev="$1" preset="$2" rec="$3" answers="${4:-}"
    local st="$WORK/install-state.env" logf="$WORK/run.log"
    rm -f "$st"
    [ -n "$prev" ] && printf '%s\n' "$prev" > "$st"
    (
        set -euo pipefail
        STATE="$st"
        RECONFIGURE="$rec"
        NO_BOT=1                       # бот в этом тесте не участвует
        CLI_PORTS="" CLI_PORTS3=""
        CLI_PRESET="$preset" CLI_TEMPLATE="tls" CLI_FP="firefox"
        CLI_PRESET3="" CLI_TEMPLATE3="" CLI_AWG_VER="both"
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

PREV="AWG_PRESET='medium'
AWG_TEMPLATE=''
AWG_PRESET3=''
AWG_TEMPLATE3=''
AWG_FP='chrome'
AWG_BOT_INSTALL='0'
AWG_BOT_TOKEN=''
AWG_BOT_ADMINS=''
AWG_MTU='1280'
AWG_HOST='yandex.ru'
AWG_VER='both'"

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. --preset не трогает то, чего не спрашивал"
S="$(run_cc "$PREV" paranoid 0)"
case "$(val "$S" AWG_MTU)" in
    1280) ok "MTU 1280 остался 1280" ;;
    *)    bad "MTU затёрт" "стало «$(val "$S" AWG_MTU)», ждали 1280" ;;
esac
case "$(val "$S" AWG_HOST)" in
    yandex.ru) ok "домен мимикрии остался yandex.ru" ;;
    *)         bad "домен затёрт" "стало «$(val "$S" AWG_HOST)», ждали yandex.ru" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. …и при этом делает то, ради чего его звали"
case "$(val "$S" AWG_PRESET)" in
    paranoid) ok "пресет из CLI применён" ;;
    *)        bad "пресет не применён" "стало «$(val "$S" AWG_PRESET)»" ;;
esac
case "$(val "$S" AWG_TEMPLATE)" in
    tls) ok "шаблон из CLI применён" ;;
    *)   bad "шаблон не применён" "стало «$(val "$S" AWG_TEMPLATE)»" ;;
esac
case "$(val "$S" AWG_FP)" in
    firefox) ok "профиль браузера из CLI применён" ;;
    *)       bad "профиль не применён" "стало «$(val "$S" AWG_FP)»" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Чистая установка с --preset берёт умолчания"
# Переносить нечего — здесь 1320 и пустой домен правильны, и правка не должна
# была превратить отсутствие state в отказ или в пустой MTU.
S2="$(run_cc "" high 0)"
case "$(val "$S2" AWG_MTU)" in
    1320) ok "MTU 1320 по умолчанию" ;;
    *)    bad "умолчание MTU потеряно" "стало «$(val "$S2" AWG_MTU)»" ;;
esac
case "$(val "$S2" AWG_HOST)" in
    "") ok "домен пуст (пул по умолчанию)" ;;
    *)  bad "домен взялся ниоткуда" "стало «$(val "$S2" AWG_HOST)»" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Пустое значение в state не выдаётся за ответ"
# Старый state (до появления этих ключей) или ручная правка: переносить нечего,
# значит работает умолчание, а не пустой MTU в конфиге.
S3="$(run_cc "AWG_PRESET='low'
AWG_MTU=''
AWG_HOST=''
AWG_VER='both'" low 0)"
case "$(val "$S3" AWG_MTU)" in
    1320) ok "пустой MTU в state → умолчание 1320" ;;
    *)    bad "пустой MTU просочился" "стало «$(val "$S3" AWG_MTU)»" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. --reconfigure по-прежнему спрашивает и по-прежнему меняет"
# Обратная сторона правила. Ответы диалога: пресет 5 (paranoid), пресет3 3,
# мимикрия 0 (авто), браузер 1 (chrome), MTU 3 (1280), домен 2 + свой.
S4="$(run_cc "$PREV" "" 1 "5
3
0
1
3
2
example.org")"
case "$(val "$S4" AWG_MTU)" in
    1280) ok "MTU взят из ответа (1280)" ;;
    *)    bad "диалог MTU не отработал" "стало «$(val "$S4" AWG_MTU)»" ;;
esac
case "$(val "$S4" AWG_HOST)" in
    example.org) ok "домен взят из ответа" ;;
    *)           bad "диалог домена не отработал" "стало «$(val "$S4" AWG_HOST)»" ;;
esac
case "$(val "$S4" AWG_PRESET)" in
    paranoid) ok "пресет взят из ответа" ;;
    *)        bad "диалог пресета не отработал" "стало «$(val "$S4" AWG_PRESET)»" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Правило записано в коде, а не подобрано под тест"
# Перенос обязан читать именно сохранённый state и обязан стоять в ветке
# --preset. Если кто-то заменит его на константу, раздел 1 останется зелёным.
BR="$(printf '%s\n' "$CC" | sed -n '/if \[ -n "\$CLI_PRESET" \]/,/^    else$/p')"
if printf '%s\n' "$BR" | grep -q 'AWG_MTU' && printf '%s\n' "$BR" | grep -q 'AWG_HOST'; then
    ok "перенос читает AWG_MTU и AWG_HOST внутри ветки --preset"
else
    bad "переноса в ветке --preset нет" "раздел 1 зелен по другой причине"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit "$fail"
