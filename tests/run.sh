#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/run.sh — вся приёмка одним прогоном.
#
#   bash tests/run.sh            # всё
#   bash tests/run.sh obf        # только наборы, чьё имя содержит «obf»
#
# Ничего не устанавливает и не трогает систему: наборы работают на подставных
# systemctl/ip/python3 во временных каталогах и разбирают НАСТОЯЩИЕ файлы
# репозитория, а не свои копии. Поэтому прогон безопасен и на боевой машине.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1
PY="${PYTHON:-python3}"
FILTER="${1:-}"

pass=0; fail=0; skipped=0
FAILED=""

ok()   { printf '  \033[1;32m✔\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[1;31m✘\033[0m %s\n' "$1"; fail=$((fail+1)); FAILED="$FAILED $1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Логи GitHub Actions открываются только после входа, а аннотации публичны.
# Поэтому причину отказа дублируем аннотацией: она видна и в pull request,
# и снаружи, без доступа к логам.
annotate() {  # annotate <набор> <вывод>
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    printf '::error title=%s::%s\n' "$1" \
        "$(printf '%s' "$2" | sed 's/%/%25/g; s/\r/%0D/g' | awk '{printf "%s%%0A", $0}')"
}

run() {  # run <имя> <команда…>
    local name="$1"; shift
    case "$name" in
        *"$FILTER"*) ;;
        *) skipped=$((skipped+1)); return 0 ;;
    esac
    local out rc
    out="$(timeout 300 "$@" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then
        ok "$name"
    else
        [ "$rc" = 124 ] && out="$out"$'\n'"(превышен лимит 300 с)"
        bad "$name"
        printf '%s\n' "$out" | tail -25 | sed 's/^/      /'
        annotate "$name" "$(printf '%s\n' "$out" | tail -25)"
    fi
}

head_ "Синтаксис"
syn=0
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { printf '  ✘ %s\n' "$f"; syn=1; }
done < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')
[ "$syn" = 0 ] && ok "bash -n по всем .sh" || bad "bash -n по всем .sh"

pyc="$("$PY" -m compileall -q bot overlay tests 2>&1)"
if [ -z "$pyc" ]; then ok "py_compile по всем .py"; else bad "py_compile по всем .py"; printf '%s\n' "$pyc" | sed 's/^/      /'; fi

head_ "Установщик"
run "askyn: ответ на вопрос про бота не теряется" \
    bash tests/test_install_askyn.sh install.sh
run "слои: раздельные пресеты и порты 2.0/3.0" \
    bash tests/test_install_layers.sh install.sh patches/antizapret-awg-integration.sh

head_ "Обфускация"
run "приоритет явных флагов над сохранённым профилем" \
    bash tests/test_obf_preset.sh overlay/bin/awg-obfuscation.sh
run "перезапуск после --apply и код возврата" \
    bash tests/test_obf_restart.sh overlay/bin/awg-obfuscation.sh

head_ "Диагностика"
run "слой 3.0: оба интерфейса и разные причины отказа" \
    bash tests/test_doctor_v3.sh overlay/bin/awg-doctor.sh

head_ "Переход между ветками"
run "конфиги слоя 2.0 переживают переход с main" \
    bash tests/test_migration_main_to_beta.sh

head_ "Проверка обновлений"
run "таблица компонентов сравнивает со своей веткой" \
    bash tests/test_upstream_branch.sh overlay/bin/awg-upstream-check.sh
run "кнопка в боте сравнивает со своей веткой" \
    "$PY" tests/test_update_branch.py

head_ "Бот"
run "меню обфускации: предупреждение, фон, исход" "$PY" tests/test_bot_obfuscation.py
run "постраничный список клиентов"                "$PY" tests/test_bot_paging.py
run "пояснение про «version 3.1» у слоя 3.0"      "$PY" tests/test_bot_v3_note.py

head_ "Статистика"
run "карточка клиента суммирует его интерфейсы" "$PY" tests/test_stats_client.py
run "счётчик считает людей, а не конфиги"       "$PY" tests/test_stats_overview.py

printf '\n\033[1m%s\033[0m\n' "Итог"
printf '  прошло %d, упало %d' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', пропущено по фильтру %d' "$skipped"
printf '\n'
if [ "$fail" != 0 ]; then
    printf '  упавшие:%s\n' "$FAILED"
    exit 1
fi
