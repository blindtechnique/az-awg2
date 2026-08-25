#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-upstream-check.sh — есть ли новые версии апстрима.
#
#   awg-upstream-check           # человекочитаемо
#   awg-upstream-check --json    # для бота
#   awg-upstream-check --quiet   # молча; код возврата 10 = есть обновления
#
# Проверяются: amneziawg-go (датапас слоя 3.0), amneziawg-tools и код самого
# слоя на GitHub. НИЧЕГО не обновляет — только сообщает. Пересборка датапаса
# без спроса рвёт туннели, поэтому решение всегда за администратором.
set -uo pipefail

DEST=/opt/antizapret-awg
SRC=/opt/src
JSON=0; QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

# последний НЕ пре-релизный тег вида vX.Y.Z или vX.Y.YYYYMMDD
latest_tag() {  # latest_tag <owner/repo>
    git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
        | awk -F/ '{print $NF}' | grep -E '^v[0-9]' | sort -V | tail -1
}

installed_go_ref() {
    [ -d "$SRC/amneziawg-go/.git" ] || { echo ""; return; }
    git -C "$SRC/amneziawg-go" describe --tags --exact-match 2>/dev/null \
        || git -C "$SRC/amneziawg-go" rev-parse --short HEAD 2>/dev/null
}

UPDATES=0
declare -a ROWS=()

add_row() {  # add_row <что> <установлено> <доступно> <есть_обновление>
    ROWS+=("$1|$2|$3|$4")
    [ "$4" = 1 ] && UPDATES=$((UPDATES+1))
    return 0
}

# ── amneziawg-go: только если стоит слой 3.0 ────────────────────────────────
if command -v amneziawg-go >/dev/null 2>&1; then
    # Сравниваем с ПИНОМ установщика, а не с последним тегом апстрима. Проект
    # намеренно держится серии 3.0, апстрим ушёл на 3.1 — при сравнении с
    # последним тегом «есть обновление» горело бы вечно: бот слал бы
    # уведомления, --update ничего бы не менял, и так по кругу.
    # Значение обязано совпадать с AWG_GO_REF в patches/antizapret-awg-integration.sh.
    PIN_GO="${AWG_GO_REF:-v3.0.20260805}"
    cur="$(installed_go_ref)"; [ -n "$cur" ] || cur="(неизвестно)"
    if [ "$cur" != "$PIN_GO" ]; then add_row "amneziawg-go" "$cur" "$PIN_GO" 1
    else add_row "amneziawg-go" "$cur" "$PIN_GO" 0; fi
    new="$(latest_tag amnezia-vpn/amneziawg-go)"
    [ -n "$new" ] && [ "$new" != "$PIN_GO" ] && \
        UPSTREAM_NOTE="апстрим выпустил amneziawg-go $new (проект пиннится на $PIN_GO — см. README)"
fi

# ── amneziawg-tools: ставятся пакетом из PPA, проектом не пиннятся ─────────
# Показываем справочно, без флага «есть обновление»: обновлять их отдельно от
# ванильного AntiZapret нельзя, а пометка заставляла бы запускать --update,
# который на них всё равно не влияет.
if command -v awg >/dev/null 2>&1; then
    cur="$(awg --version 2>&1 | grep -oE 'v[0-9][0-9.]*(-[0-9]+)?' | head -1 || true)"
    [ -n "$cur" ] || cur="(пакет)"
    add_row "amneziawg-tools" "$cur" "$cur" 0
fi

# ── код слоя ────────────────────────────────────────────────────────────────
if [ -f "$DEST/.layer-rev" ]; then
    cur="$(cat "$DEST/.layer-rev")"
    branch="$(cat "$DEST/.layer-branch" 2>/dev/null || echo main)"
    new="$(git ls-remote "https://github.com/blindtechnique/az-awg2.git" "refs/heads/$branch" 2>/dev/null | cut -c1-12)"
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then add_row "az-awg2 ($branch)" "$cur" "$new" 1
    else add_row "az-awg2 ($branch)" "$cur" "${new:-?}" 0; fi
fi

if [ "$JSON" = 1 ]; then
    printf '{"updates": %d, "items": [' "$UPDATES"
    first=1
    for r in "${ROWS[@]}"; do
        IFS='|' read -r what cur new upd <<< "$r"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"name":"%s","installed":"%s","latest":"%s","update":%s}' \
            "$what" "$cur" "$new" "$([ "$upd" = 1 ] && echo true || echo false)"
    done
    printf ']}\n'
elif [ "$QUIET" = 0 ]; then
    printf '%-22s %-18s %s\n' КОМПОНЕНТ УСТАНОВЛЕНО ДОСТУПНО
    for r in "${ROWS[@]}"; do
        IFS='|' read -r what cur new upd <<< "$r"
        mark=""; [ "$upd" = 1 ] && mark="  ← есть обновление"
        printf '%-22s %-18s %s%s\n' "$what" "$cur" "$new" "$mark"
    done
    echo
    if [ "$UPDATES" = 0 ]; then
        echo "Всё актуально."
    else
        echo "Обновить код слоя:  bash install.sh --update"
        echo "(конфиги, порты и клиенты при этом не меняются)"
    fi
    if [ -n "${UPSTREAM_NOTE:-}" ]; then
        echo
        echo "ℹ️  $UPSTREAM_NOTE"
        echo "   Это справка, а не повод обновляться: пин меняется вместе с кодом слоя."
    fi
fi

[ "$UPDATES" -gt 0 ] && exit 10
exit 0
