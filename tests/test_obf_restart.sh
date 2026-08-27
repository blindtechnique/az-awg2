#!/bin/bash
# Приёмка блока перезапуска после --apply: он не пропускается молча, говорит
# вслух, если параметры не доехали, и возвращает 3 — чтобы вызывающий не пошёл
# раздавать клиентам профиль, которого на сервере нет.
SRC="${1:?awg-obfuscation.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1"; echo "     ждали: [$3]"; echo "     вышло: [$2]"; fail=1; fi; }
inc(){ case "$2" in *"$3"*) echo "  ✔ $1" ;; *) echo "  ✘ $1 — нет «$3»"; echo "     вышло: [$2]"; fail=1 ;; esac; }
noinc(){ case "$2" in *"$3"*) echo "  ✘ $1 — есть лишнее «$3»"; fail=1 ;; *) echo "  ✔ $1" ;; esac; }

# блок: от строки с unit_pfx до "    fi", закрывающего ветку с exit 3
blk="$(awk '/^    if \[ "\$V3" = 1 \].*unit_pfx/{on=1}
            on{print}
            /exit 3/{seen=1}
            seen && /^    fi$/{exit}' "$SRC")"
case "$blk" in
    *unit_present*live_any*apply_failed*exit\ 3*) ;;
    *) echo "  ✘ блок перезапуска вырезан не целиком"; exit 1 ;;
esac
if printf '%s\n' "$blk" | grep -v '^ *#' | grep -q 'list-unit-files *|'; then
    echo "  ✘ конвейер под pipefail остался в коде"; fail=1
fi

# run <юнит есть:1|0> <ключ отдан:1|0> <V3:1|0> <интерфейсы подняты:1|0> [старт падает:1]
# печатает вывод, последней строкой — "rc=<код>"
run() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/bin"
    cat > "$d/bin/systemctl" <<EOS
#!/bin/bash
case "\$1" in
  cat)  [ "$1" = 1 ] && exit 0 || exit 1 ;;
  list-unit-files)
        for n in \$(seq 1 4000); do echo "unit-\$n.service enabled enabled"; done
        [ "$1" = 1 ] && echo "awg3@.service enabled enabled"
        for n in \$(seq 1 4000); do echo "zzz-\$n.service enabled enabled"; done ;;
  start) [ "${5:-0}" = 1 ] && exit 1 || exit 0 ;;
esac
exit 0
EOS
    # ip link show решает, «есть ли чему ломаться»
    cat > "$d/bin/ip" <<EOS
#!/bin/sh
case "\$2" in
  show) [ "$4" = 1 ] && exit 0 || exit 1 ;;
esac
exit 0
EOS
    cat > "$d/bin/python3" <<EOS
#!/bin/sh
[ "$2" = 1 ] && echo "  header_protection_key = abcd(скрыт)"
exit 0
EOS
    printf 'stub\n' > "$d/bin/awg3-uapi.py"
    printf 'stub\n' > "$d/bin/awg-uapi.py"
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo 'log(){ echo "[log] $*"; }'
        echo 'err(){ echo "[err] $*"; }'
        echo "V3=$3; KMOD3=0"
        [ "$3" = 1 ] && echo 'V3_BLOCK=header_protection_key=dead' || echo 'V3_BLOCK=""'
        echo 'az_iface=antizapret-awg3; vpn_iface=vpn-awg3'
        echo 'ifaces="antizapret-awg3 vpn-awg3"'
        printf '%s\n' "$blk"
    } > "$d/bin/probe.sh"
    chmod +x "$d/bin/"*
    local out rc
    out="$( PATH="$d/bin:$PATH"; "$d/bin/probe.sh" 2>&1 )"; rc=$?
    printf '%s\nrc=%s\n' "$out" "$rc"
    rm -rf "$d"
}

echo "══ Рабочий сервер, всё получилось ══════════════════════════════════════"
o="$(run 1 1 1 1)"
inc "перезапуск первого интерфейса" "$o" "Перезапуск awg3@antizapret-awg3"
inc "и второго"                     "$o" "Перезапуск awg3@vpn-awg3"
inc "подтверждение по UAPI"         "$o" "Параметры 3.0 приняты демоном"
inc "и «Готово»"                    "$o" "Готово."
chk "код возврата"                  "$(printf '%s' "$o" | tail -1)" "rc=0"

echo
echo "══ Параметры до демона не доехали ══════════════════════════════════════"
o="$(run 1 0 1 1)"
inc "сказано ВСЛУХ"        "$o" "Параметры 3.0 НЕ доехали"
inc "с командой разбора"   "$o" "journalctl -u awg3@"
noinc "и НЕ «Готово»"      "$o" "Готово."
chk "код 3 — вызывающий не пойдёт раздавать клиентам" "$(printf '%s' "$o" | tail -1)" "rc=3"
echo "  (раньше здесь молча печаталось «Готово» и возвращался 0)"

echo
echo "══ Юнита нет, но туннель работает ══════════════════════════════════════"
o="$(run 0 1 1 1)"
inc "названа причина"      "$o" "не найден, а интерфейсы подняты"
inc "и чем грозит"         "$o" "РАБОТАЮЩИЙ туннель его не получил"
noinc "перезапуск не выдумывается" "$o" "Перезапуск"
chk "код 3"                "$(printf '%s' "$o" | tail -1)" "rc=3"

echo
echo "══ Первая установка: юнитов ещё нет, интерфейсов тоже ══════════════════"
o="$(run 0 1 1 0)"
inc "спокойная строка, а не ошибка" "$o" "профиль применится при их первом старте"
noinc "без паники"                  "$o" "РАБОТАЮЩИЙ туннель"
inc "и «Готово»"                    "$o" "Готово."
chk "код 0 — установка не падает"   "$(printf '%s' "$o" | tail -1)" "rc=0"
echo "  (switch_services ставит и запускает юниты уже ПОСЛЕ обфускации)"

echo
echo "══ Слой 2.0: проверки UAPI быть не должно ══════════════════════════════"
o="$(run 1 0 0 1)"
inc "перезапуск awg-quick" "$o" "Перезапуск awg-quick@"
noinc "про 3.0 ни слова"   "$o" "Параметры 3.0"
chk "код 0"                "$(printf '%s' "$o" | tail -1)" "rc=0"

echo
echo "══ Не удалось поднять живой интерфейс ══════════════════════════════════"
o="$(run 1 1 1 1 1)"
inc "ошибка старта названа" "$o" "Не удалось поднять"
chk "код 3"                 "$(printf '%s' "$o" | tail -1)" "rc=3"
echo "  ── а на первой установке то же самое не валит прогон ──"
o="$(run 1 1 1 0 1)"
inc "ошибка всё равно видна" "$o" "Не удалось поднять"
chk "но код 0"               "$(printf '%s' "$o" | tail -1)" "rc=0"

echo
echo "══ Прежняя проверка на этом же стенде действительно ломалась ═══════════"
d="$(mktemp -d)"; mkdir -p "$d/bin"
cat > "$d/bin/systemctl" <<'EOS'
#!/bin/bash
case "$1" in
  cat) exit 0 ;;
  list-unit-files)
        for n in $(seq 1 4000); do echo "unit-$n.service enabled enabled"; done
        echo "awg3@.service enabled enabled"
        for n in $(seq 1 4000); do echo "zzz-$n.service enabled enabled"; done ;;
esac
exit 0
EOS
chmod +x "$d/bin/systemctl"
chk "прежний конвейер даёт ЛОЖЬ, хотя юнит есть" \
    "$(PATH="$d/bin:$PATH" bash -euo pipefail -c 'if systemctl list-unit-files | grep -q "awg3@"; then echo ИСТИНА; else echo ЛОЖЬ; fi' 2>&1)" "ЛОЖЬ"
chk "новая проверка в той же среде — ИСТИНА" \
    "$(PATH="$d/bin:$PATH" bash -euo pipefail -c 'p=0; systemctl cat "awg3@.service" >/dev/null 2>&1 && p=1; [ "$p" = 1 ] && echo ИСТИНА || echo ЛОЖЬ' 2>&1)" "ИСТИНА"
rm -rf "$d"

echo
bash -n "$SRC" && echo "  ✔ синтаксис" || fail=1
echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
