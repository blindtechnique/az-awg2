#!/bin/bash
# Приёмка раздельных пресетов и портов для слоёв 2.0 и 3.0.
INST="${1:?install.sh}"; INTG="${2:?integration.sh}"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }
has() { if grep -qF -- "$2" "$3"; then echo "  ✔ $1"; else echo "  ✘ $1"; fail=1; fi; }

echo "── Флаги появились ─────────────────────────────────────────────────────"
has "install.sh знает --preset3"     '--preset3) CLI_PRESET3='   "$INST"
has "install.sh знает --template3"   '--template3) CLI_TEMPLATE3=' "$INST"
has "install.sh знает --awg3-ports"  '--awg3-ports) CLI_PORTS3='  "$INST"
has "integration знает --preset3"    '--preset3) PRESET3='        "$INTG"
has "integration знает --az3-port"   '--az3-port) CLI_AZ3_PORT='  "$INTG"
has "флаги описаны в справке"        '--awg3-ports A,V'           "$INST"

echo
echo "── Обратная совместимость: пусто = как у слоя 2.0 ──────────────────────"
has "integration подставляет PRESET"  'local p3="${PRESET3:-$PRESET}"' "$INTG"
has "и TEMPLATE"                      't3="${TEMPLATE3:-$TEMPLATE}"'   "$INTG"
has "install.sh не выдумывает пресет" 'local P3="${AWG_PRESET3:-}"'    "$INST"
has "переменные объявлены под set -u" 'PRESET3=""; TEMPLATE3=""'       "$INTG"

echo
echo "── Приоритет портов: CLI > закреплённый > случайный ────────────────────"
has "AZ3_PORT"  'AZ3_PORT="${CLI_AZ3_PORT:-${pinned_az3:-'   "$INTG"
has "VPN3_PORT" 'VPN3_PORT="${CLI_VPN3_PORT:-${pinned_vpn3:-' "$INTG"

echo
echo "── Предупреждение про router и low ─────────────────────────────────────"
has "названы прямо"        'router и low — БЕЗ header protection' "$INST"
has "сказано, с чего начинается полный 3.0" 'Полный 3.0 — от medium' "$INST"
has "подтверждение после выбора"            'слой 3.0 будет без header protection' "$INST"

echo
echo "── Вопрос про 3.0 не задаётся, когда слоя нет ──────────────────────────"
n2=$(grep -c 'if \[ "$AWG_VER" != 2 \]; then' "$INST")
chk "оба блока (пресет и порты) под условием" "$n2" "2"

echo
echo "── Состояние пишется ───────────────────────────────────────────────────"
has "AWG_PRESET3 в state"   "AWG_PRESET3='\$PRESET3'"   "$INST"
has "AWG_TEMPLATE3 в state" "AWG_TEMPLATE3='\$TEMPLATE3'" "$INST"

echo
echo "── Проверка портов 3.0 ─────────────────────────────────────────────────"
has "есть parse_cli_ports3"          'parse_cli_ports3() {'        "$INST"
has "ловит пересечение со слоем 2.0" 'уже занят слоем 2.0'         "$INST"
has "вызывается при разборе"         '[ -n "$CLI_PORTS3" ] && parse_cli_ports3' "$INST"

echo
echo "── Логика приоритета портов (эмуляция) ─────────────────────────────────"
pick() { echo RANDOM_PORT; }
t() { CLI="$1"; PIN="$2"; echo "${CLI:-${PIN:-$(pick)}}"; }
chk "явный порт сильнее всех"        "$(t 40000 30000)" "40000"
chk "закреплённый сильнее случайного" "$(t '' 30000)"    "30000"
chk "иначе случайный"                 "$(t '' '')"       "RANDOM_PORT"

echo
echo "── Синтаксис ───────────────────────────────────────────────────────────"
bash -n "$INST" && echo "  ✔ install.sh" || fail=1
bash -n "$INTG" && echo "  ✔ integration" || fail=1

echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
