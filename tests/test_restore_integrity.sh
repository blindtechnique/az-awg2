#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Что архив на самом деле содержит и что восстановление на самом деле сообщает.
#
# Две находки, ради которых набор написан:
#
#   1. DEST в awg-backup.sh указывал на /root/antizapret/awg — каталог, которого
#      не создаёт никто; весь остальной репозиторий знает /opt/antizapret-awg.
#      Поэтому `[ -d "$DEST/clients" ]` был всегда ложен, и в архив НЕ попадали
#      ни клиентские приватные ключи (а они существуют только там), ни stats.db,
#      ни expiry.tsv. Молча: рядом стоял `|| true`.
#
#   2. do_restore не мог вернуть ненулевой код: после распаковки каждый шаг шёл
#      с `|| true` либо `|| err`, а err — это printf, он возвращает 0. Бот
#      печатает «✅ Восстановлено.» ровно по rc = 0, то есть галочка приходила
#      всегда — в том числе на сервере, где не поднялся ни один тоннель.
#
# Статическая часть работает везде; настоящий прогон — под пространством имён.
#
#   bash tests/test_restore_integrity.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BK=overlay/bin/awg-backup.sh
DOC=overlay/bin/awg-doctor.sh

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Каталог слоя назван одинаково во всём репозитории"
# Инвариант, а не сверка с константой: расхождение и было дефектом, поэтому
# проверяем именно согласие файлов между собой.
declare -A seen=()
for f in install.sh patches/antizapret-awg-integration.sh "$DOC" "$BK"; do
    d="$(sed -n 's/^DEST=["'"'"']\?\([^"'"'"' ]*\).*/\1/p' "$f" 2>/dev/null | head -1)"
    [ -n "$d" ] && seen["$d"]="${seen[$d]:-} $f"
done
if [ "${#seen[@]}" = 1 ]; then
    ok "DEST один и тот же везде: ${!seen[*]}"
else
    for d in "${!seen[@]}"; do printf '     %-28s %s\n' "$d" "${seen[$d]}"; done
    bad "DEST разошёлся между файлами" "бэкап читает не тот каталог, в котором лежат данные"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Код возврата восстановления больше не константа"
body="$(sed -n '/^do_restore()/,/^}$/p' "$BK")"
if [ -z "$body" ]; then
    bad "не нашли do_restore" "мерить нечего"
else
    printf '%s\n' "$body" | grep -q 'return "\$rc"' \
        && ok "do_restore возвращает накопленный код" \
        || bad "do_restore не возвращает накопленный код" "отказ снова не доедет до бота"
    n="$(printf '%s\n' "$body" | grep -c 'systemctl restart.*2>/dev/null' || true)"
    [ "$n" = 0 ] && ok "причина отказа systemctl больше не уходит в /dev/null" \
        || bad "$n перезапусков всё ещё глушат stderr" "бот показывает stderr только при ненулевом коде"
    printf '%s\n' "$body" | grep -q 'RESTORE_MARK' \
        && ok "метка незавершённого восстановления ставится" \
        || bad "метки нет" "прерывание останется незамеченным"
fi
grep -q 'check_marks' "$DOC" && ok "доктор проверяет метку" || bad "доктор про метку не знает"
# Метка обязана проверяться ДО требования services.env: восстановление, убитое
# до копирования этого файла, иначе выглядит как «слой не установлен».
m_line="$(grep -n '^check_marks$' "$DOC" | head -1 | cut -d: -f1)"
s_line="$(grep -n '^\[ -f "\$SERVICES" \]' "$DOC" | head -1 | cut -d: -f1)"
if [ -n "$m_line" ] && [ -n "$s_line" ] && [ "$m_line" -lt "$s_line" ]; then
    ok "и проверяет раньше, чем требует services.env"
else
    bad "метка проверяется после требования services.env ($m_line / $s_line)" \
        "самый тяжёлый случай прерывания не покажется никогда"
fi

# ═══════════════════════════════════════════════════════════════════════════
if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — остальное пропущено\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_restore_integrity" \
        "пропущено: unshare -Urm недоступен, настоящий прогон backup/restore не проверялся"
    exit $fail
fi

export STAND_REPO="$ROOT"
unshare -Urm --map-root-user bash -s <<'INNER'
set -uo pipefail
fail=0
ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"
mkdir -p "$W/etc-orig"
mount --rbind /etc "$W/etc-orig" 2>/dev/null || { echo "  · не подложить /etc"; exit 0; }
for d in /etc /root /opt /usr/local; do
    mount -t tmpfs none "$d" 2>/dev/null || { echo "  · не смонтировать tmpfs на $d"; exit 0; }
done
cp -a "$W/etc-orig/." /etc/ 2>/dev/null || true

AWG=/etc/amnezia/amneziawg
DEST=/opt/antizapret-awg
AZ=/root/antizapret
mkdir -p "$AWG" "$DEST/clients/antizapret" "$DEST/clients/vpn" \
         "$AZ/config" "$AZ/client" /etc/knot-resolver /etc/openvpn/easyrsa3/pki

cat > "$AWG/services.env" <<EOS
MODE=parallel
LAYER2=1
LAYER3=0
AZ_IFACE=antizapret-awg
VPN_IFACE=vpn-awg
AZ_PORT=41234
VPN_PORT=42345
EOS
printf "AWG_Jc='4'\n" > "$AWG/obfuscation.env"
printf '[Interface]\nPrivateKey = SRV_KEY\nListenPort = 41234\n' > "$AWG/antizapret-awg.conf"
# по два клиента на каждый профиль — их приватные ключи есть ТОЛЬКО здесь
for s in antizapret vpn; do
    for i in 1 2; do
        printf '[Interface]\nPrivateKey = CLIENT_%s_%s\n' "$s" "$i" \
            > "$DEST/clients/$s/$s-c$i-am.conf"
    done
done
: > "$DEST/stats.db"; printf 'c1\t2030-01-01\n' > "$DEST/expiry.tsv"
printf 'x\n' > "$AZ/config/include-hosts.txt"
printf 'x\n' > /etc/knot-resolver/kresd.conf.lua
printf '#!/bin/bash\nexit 0\n' > "$AZ/doall.sh"
printf 'PKI\n' > /etc/openvpn/easyrsa3/pki/ca.crt

S="$W/stub"; mkdir -p "$S"
for c in ip awg awg-quick kresd; do printf '#!/bin/sh\nexit 0\n' > "$S/$c"; done
{
    echo '#!/bin/sh'
    echo '[ "${SYSTEMCTL_FAIL:-0}" = 1 ] && { echo "Job failed. See journalctl." >&2; exit 1; }'
    echo 'exit 0'
} > "$S/systemctl"
# chmod внутри do_restore зовётся ровно один раз — сразу после ВСЕХ копирований
# и до блока перезапуска. Убийство на нём и есть искомая граница:
# «файлы новые, сервисы старые».
{
    echo '#!/bin/bash'
    echo '[ "${CHMOD_KILL:-0}" = 1 ] && { kill -9 "$PPID"; sleep 5; }'
    echo 'exec /bin/chmod "$@"'
} > "$S/chmod"
chmod +x "$S"/*
export PATH="$S:$PATH"

BK="$STAND_REPO/overlay/bin/awg-backup.sh"
DOC="$STAND_REPO/overlay/bin/awg-doctor.sh"
MARK="$AWG/.restore-in-progress"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Архив содержит клиентские приватные ключи"
out="$(bash "$BK" backup "$W/bk.tar.gz" 2>"$W/bk.err")"; rc=$?
[ "$rc" = 0 ] && ok "бэкап отработал успешно" \
    || bad "бэкап отказал (код $rc)" "$(tail -2 "$W/bk.err")"
mkdir -p "$W/unpack" && tar -xzf "$W/bk.tar.gz" -C "$W/unpack" 2>/dev/null
n="$(grep -rl 'PrivateKey = CLIENT_' "$W/unpack" 2>/dev/null | wc -l)"
if [ "$n" = 4 ]; then
    ok "все 4 клиентских конфига с приватными ключами внутри архива"
else
    bad "в архиве $n клиентских конфигов из 4" \
        "именно это и терялось молча: переиздать их нечем, в серверном конфиге одни публичные"
fi
[ -f "$W/unpack/awgstate/stats.db" ] && ok "stats.db в архиве" || bad "stats.db не попал в архив"
[ -f "$W/unpack/awgstate/expiry.tsv" ] && ok "expiry.tsv в архиве" \
    || bad "expiry.tsv не попал в архив" "сроки временных клиентов не наступят"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Смерть между копированием файлов и перезапуском сервисов"
# Делаем живое состояние заведомо другим, чтобы отличить восстановленное.
printf '[Interface]\nPrivateKey = ЖИВОЙ\n' > "$AWG/antizapret-awg.conf"
rm -f "$DEST/clients/antizapret/antizapret-c1-am.conf"
{ CHMOD_KILL=1 bash "$BK" restore "$W/bk.tar.gz" >"$W/r1.log" 2>&1; rc=$?; } 2>/dev/null
grep -q 'SRV_KEY' "$AWG/antizapret-awg.conf" \
    && ok "файлы уже подменены восстановленными" \
    || bad "файлы не подменены" "прерывание слишком раннее"
[ -f "$MARK" ] && ok "метка осталась — операция не доведена до конца" \
    || bad "метки нет" "прерывание в этом окне снова невидимо"
mark_arch="$(sed -n 's/^MARK_ARCHIVE=//p' "$MARK" 2>/dev/null)"
[ "$mark_arch" = "$W/bk.tar.gz" ] && ok "в метке лежит путь архива — есть чем повторить" \
    || bad "в метке нет пути архива" "[$mark_arch]"
docout="$(bash "$DOC" 2>&1 || true)"
case "$docout" in
    *"восстановление не доведено до конца"*)
        ok "доктор говорит об этом вслух" ;;
    *)  bad "доктор молчит о незавершённом восстановлении" \
            "владелец, не читавший вывод прогона, ничего не узнает" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Сервисы не поднялись — это отказ, а не успех"
SYSTEMCTL_FAIL=1 bash "$BK" restore "$W/bk.tar.gz" >"$W/r2.log" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "код возврата ненулевой ($rc) — бот покажет ❌, а не галочку" \
    || bad "код возврата 0 при неподнявшихся тоннелях" "это и есть та самая зелень поверх мёртвого сервера"
grep -q 'не перезапущено' "$W/r2.log" && ok "сказано, что именно не встало" \
    || bad "отказ перезапуска не назван" "$(tail -3 "$W/r2.log")"
grep -q 'journalctl' "$W/r2.log" && ok "и куда смотреть" || bad "нет подсказки, где искать причину"
grep -q 'Job failed' "$W/r2.log" && ok "причина от systemd доехала до вывода" \
    || bad "stderr systemd по-прежнему проглочен" "снятие 2>/dev/null не сработало"
[ -f "$MARK" ] && ok "метка оставлена: файлы новые, сервисы старые" \
    || bad "метка снята при неподнявшихся сервисах" "ровно тот случай, ради которого она есть"

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Успешное восстановление снимает метку и возвращает ноль"
bash "$BK" restore "$W/bk.tar.gz" >"$W/r3.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "код возврата 0" || bad "успешный прогон отдал $rc" "$(tail -3 "$W/r3.log")"
[ -f "$MARK" ] && bad "метка осталась после успешного прогона" "доктор будет пугать зря" \
    || ok "метка снята"
n="$(find "$DEST/clients" -name '*-am.conf' | wc -l)"
[ "$n" = 4 ] && ok "все 4 клиентских конфига вернулись на место" \
    || bad "восстановлено $n клиентских конфигов из 4"
grep -q 'CLIENT_antizapret_1' "$DEST/clients/antizapret/antizapret-c1-am.conf" 2>/dev/null \
    && ok "и приватный ключ удалённого клиента вернулся" \
    || bad "приватный ключ не восстановлен"

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Архив, снятый до починки — молчать о нём нельзя"
mkdir -p "$W/old/amneziawg" "$W/old/awgstate" "$W/old/config" \
         "$W/old/knot" "$W/old/custom" "$W/old/client" "$W/old/openvpn"
printf '[Interface]\nPrivateKey = SRV_KEY\n' > "$W/old/amneziawg/antizapret-awg.conf"
cp "$AWG/services.env" "$W/old/amneziawg/"
echo old > "$W/old/MANIFEST"
( cd "$W/old" && tar -czf "$W/old.tar.gz" . )
bash "$BK" restore "$W/old.tar.gz" >"$W/r4.log" 2>&1; rc=$?
grep -q 'нет клиентских ключей' "$W/r4.log" \
    && ok "прогон сказал, что ключей клиентов в архиве нет" \
    || bad "про пустой архив ничего не сказано" "$(tail -3 "$W/r4.log")"
[ "$rc" != 0 ] && ok "и вернул ненулевой код ($rc)" \
    || bad "код 0 на архиве без клиентских ключей" "владелец узнает об этом в худший день"

# ═══════════════════════════════════════════════════════════════════════════
head_ "8. PKI, брошенный оборванным прогоном, возвращается на место"
# Окно между двумя переименованиями: easyrsa3 уже уехал в .old, замена ещё не
# встала. Повтор раньше начинался с `rm -rf …old` и сносил единственную копию.
rm -rf /etc/openvpn/easyrsa3
mkdir -p /etc/openvpn/easyrsa3.old/pki
printf 'ОРИГИНАЛ\n' > /etc/openvpn/easyrsa3.old/pki/ca.crt
bash "$BK" restore "$W/bk.tar.gz" >"$W/r5.log" 2>&1
if [ -d /etc/openvpn/easyrsa3 ]; then
    ok "каталог easyrsa3 снова на месте"
    grep -q 'оборвалось' "$W/r5.log" && ok "и прогон объяснил, откуда он взялся" \
        || bad "восстановление PKI из .old прошло молча"
else
    bad "easyrsa3 так и не появился" "повтор снёс единственную уцелевшую копию"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
