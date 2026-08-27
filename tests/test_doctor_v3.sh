#!/bin/bash
# Приёмка доктора az-awg2: спрашиваются ОБА интерфейса слоя 3.0, а «не ответил»
# отличается от «ключа нет».
DOC="${1:?awg-doctor.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1"; echo "     ждали: [$3]"; echo "     вышло: [$2]"; fail=1; fi; }
inc(){ case "$2" in *"$3"*) echo "  ✔ $1" ;; *) echo "  ✘ $1 — нет «$3»"; echo "     вышло: [$2]"; fail=1 ;; esac; }
noinc(){ case "$2" in *"$3"*) echo "  ✘ $1 — лишнее «$3»"; fail=1 ;; *) echo "  ✔ $1" ;; esac; }

blk="$(awk '/^    v3_preset=/{on=1} on{print} on && /^    fi$/{if(++n==2) exit}' "$DOC")"
case "$blk" in
    *v3_missing*VPN3_IFACE*) ;;
    *) echo "  ✘ блок вырезан не целиком или второй интерфейс не проверяется"; exit 1 ;;
esac

# run <пресет> <режим для antizapret-awg3> <режим для vpn-awg3>
# режимы: key | nokey | dead ; отдельно nofile — самого скрипта нет
run() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/etc" "$d/dest"
    [ -n "$1" ] && printf 'META_PRESET=%s\n' "$1" > "$d/etc/obfuscation3.meta"
    if [ "${2:-}" != nofile ]; then
        # один скрипт на оба интерфейса: режим выбирается по имени, как у
        # настоящего awg3-uapi.py, которому интерфейс приходит аргументом
        {
            echo 'import sys'
            echo 'iface = sys.argv[2] if len(sys.argv) > 2 else ""'
            echo 'modes = {"antizapret-awg3": "'"$2"'", "vpn-awg3": "'"$3"'"}'
            echo 'm = modes.get(iface, "dead")'
            echo 'if m == "dead": sys.exit(1)'
            echo 'print("%s: параметры AmneziaWG 3.0" % iface)'
            echo 'if m == "key": print("  header_protection_key = abcd(скрыт)")'
            echo 'else: print("  не заданы (работает как 2.0)")'
        } > "$d/dest/awg3-uapi.py"
    fi
    # переменные ниже читает вырезанный из скрипта блок под eval,
    # статически такую связь не увидеть
    # shellcheck disable=SC2034
    ( set -uo pipefail
      AWG_DIR="$d/etc"; DEST="$d/dest"
      AZ3_IFACE=antizapret-awg3; VPN3_IFACE=vpn-awg3
      ok(){   echo "ok|$*";   }
      warn(){ echo "warn|$*"; }
      # подсказки доктор печатает в stderr (чтобы не пачкать JSON) — сливаем:
      # владелец видит их вместе со строками ok/warn
      eval "$blk" ) 2>&1
    rm -rf "$d"
}

echo "── Оба интерфейса с ключом ─────────────────────────────────────────────"
o="$(run medium key key)"
inc "antizapret-awg3 зелёный" "$o" "ok|antizapret-awg3: header protection применена (пресет medium)"
inc "vpn-awg3 тоже"           "$o" "ok|vpn-awg3: header protection применена (пресет medium)"

echo
echo "── Ключ только у первого: раньше это оставалось незамеченным ───────────"
o="$(run medium key nokey)"
inc "первый зелёный"                  "$o" "ok|antizapret-awg3: header protection"
inc "а про второй сказано"            "$o" "warn|пресет medium должен включать header protection, но её нет: vpn-awg3"
noinc "первый в список не попал"      "$o" "нет: antizapret-awg3 vpn-awg3"
echo "  (доктор проверял только antizapret-awg3 — полный туннель мог годами работать как 2.0)"

echo
echo "── Ключа нет нигде, пресет его и не обещал ─────────────────────────────"
o="$(run low nokey nokey)"
inc "это не поломка"        "$o" "ok|пресет low — без header protection, так и задумано"
inc "перечислены оба"       "$o" "antizapret-awg3 vpn-awg3"
inc "совет задаёт пресет"   "$o" "--preset medium --regenerate --apply"

echo
echo "── Ключа нет нигде там, где он обещан ──────────────────────────────────"
o="$(run paranoid nokey nokey)"
inc "предупреждение"        "$o" "warn|пресет paranoid должен включать header protection"
inc "оба интерфейса названы" "$o" "antizapret-awg3 vpn-awg3"

echo
echo "── «Спросить не удалось» ≠ «ключа нет» ─────────────────────────────────"
o="$(run medium key dead)"
inc "молчащий интерфейс назван"    "$o" "warn|vpn-awg3: демон не ответил по UAPI"
inc "с командой для разбора"       "$o" "journalctl -u awg3@vpn-awg3"
noinc "пресет в этом не обвиняется" "$o" "должен включать header protection"

o="$(run medium nofile nofile)"
inc "нет awg3-uapi.py — сказано прямо" "$o" "нечем спросить демона"
noinc "и без обвинения пресета"        "$o" "должен включать header protection"

echo
echo "── Бит +x больше не решает ─────────────────────────────────────────────"
if printf '%s\n' "$blk" | grep -q '\[ -x "\$DEST'; then
    echo "  ✘ проверка -x осталась"; fail=1
else
    echo "  ✔ файл проверяется через -f"
fi

echo
bash -n "$DOC" && echo "  ✔ синтаксис" || fail=1
echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
