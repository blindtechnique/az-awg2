#!/bin/bash
# Приёмка восстановления ветки слоя в awg-upstream-check.sh.
SRC="${1:?awg-upstream-check.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }

# вырезаем ровно блок восстановления, чтобы проверять код репозитория, а не копию
blk="$(sed -n '/^    branch="\$(cat "\$DEST\/\.layer-branch"/,/^    \[ -n "\$branch" \] || branch=main$/p' "$SRC")"
[ -n "$blk" ] || { echo "  ✘ блок не найден"; exit 1; }

run() {  # run <содержимое .layer-branch или пусто> <строка bot.env или пусто>
    local d; d="$(mktemp -d)"
    [ -n "$1" ] && printf '%s\n' "$1" > "$d/.layer-branch"
    [ -n "$2" ] && printf '%s\n' "$2" > "$d/bot.env"
    ( set -uo pipefail; DEST="$d"; eval "$blk"; echo "$branch|$(cat "$d/.layer-branch" 2>/dev/null || echo -)" )
    rm -rf "$d"
}

BETA='AWG_INSTALL_SH_URL=https://raw.githubusercontent.com/blindtechnique/az-awg2/beta/install.sh'
MAIN='AWG_INSTALL_SH_URL=https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh'

echo "── Файл ветки есть: он и главный ───────────────────────────────────────"
chk "beta читается как есть"        "$(run beta "$MAIN")" "beta|beta"
chk "main читается как есть"        "$(run main "$BETA")" "main|main"

echo
echo "── Файла нет — восстанавливаем из URL бота (это и был баг) ─────────────"
chk "beta-установка больше не сравнивается с main" "$(run '' "$BETA")" "beta|beta"
chk "main-установка остаётся на main"              "$(run '' "$MAIN")" "main|main"
echo "  (и файл дописан, чтобы чинить один раз)"

echo
echo "── Нечего восстанавливать — прежнее поведение ──────────────────────────"
chk "нет bot.env"          "$(run '' '')"                          "main|-"
chk "мусор вместо URL"     "$(run '' 'AWG_INSTALL_SH_URL=')"       "main|-"
chk "чужая строка"         "$(run '' 'AWG_BOT_TOKEN=123:abc')"     "main|-"

echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
