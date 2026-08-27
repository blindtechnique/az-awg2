#!/bin/bash
# Приёмка: явный --preset сильнее сохранённого при --regenerate.
SRC="${1:?awg-obfuscation.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }

blk="$(sed -n '/^if \[ "\$REGEN" = 1 \]/,/^fi$/p' "$SRC")"
[ -n "$blk" ] || { echo "  ✘ блок регенерации не найден"; exit 1; }

META="$(mktemp)"
printf 'META_PRESET=low\nMETA_TEMPLATE=web\nMETA_FP=chrome\nMETA_HOST=\nMETA_MTU=1380\n' > "$META"

run() {  # run <SET_PRESET> <PRESET из CLI> [SET_TEMPLATE] [TEMPLATE]
    REGEN=1 STATE_META="$META" \
    SET_PRESET="$1" PRESET="$2" SET_TEMPLATE="${3:-0}" TEMPLATE="${4:-}" \
    FP="" HOST="" MTU="" \
    bash -c "log(){ :; }; APPLY=0; $blk; echo \"\$PRESET|\$TEMPLATE|\$FP\"" 2>/dev/null
}

echo "── Регенерация без флагов: берём сохранённое ───────────────────────────"
chk "пресет и шаблон из метаданных" "$(run 0 '')" "low|web|chrome"

echo
echo "── Регенерация с явным --preset: флаг сильнее ──────────────────────────"
chk "пресет из командной строки, шаблон сохранён" "$(run 1 medium)" "medium|web|chrome"
echo "  (именно этот случай молча оставлял прежний пресет)"

echo
echo "── Явный --template тоже уважается ─────────────────────────────────────"
chk "оба из командной строки" "$(run 1 high 1 tls)" "high|tls|chrome"
chk "только шаблон" "$(run 0 '' 1 quic)" "low|quic|chrome"

rm -f "$META"
echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
