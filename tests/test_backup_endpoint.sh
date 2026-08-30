#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Что архив на самом деле содержит и какой адрес попадает клиенту.
#
# Три находки, ради которых набор написан:
#
#   1. DEST в awg-backup.sh указывал на /root/antizapret/awg — каталог, которого
#      не создаёт никто. Настоящий знает соседний client-awg.sh:
#      CLIENT_DIR="/opt/antizapret-awg/clients". Из-за расхождения в архив не
#      попадали ни stats.db, ни expiry.tsv, а строки про clients/ не было вовсе:
#      приватные ключи клиентов не архивировались никогда. В серверном конфиге
#      лежат одни публичные — переиздать выданные конфиги нечем.
#
#   2. stats.db копировался простым cp, хотя база в режиме WAL: свежие записи
#      живут в stats.db-wal, а сам файл остаётся заголовком в 4 КиБ. Такая копия
#      открывается с «no such table» — теряется вся схема.
#
#   3. server_host() за NAT отдавал приватный адрес, и он уезжал прямо в
#      Endpoint клиента: конфиг мёртв, а называется созданным.
#
# Плюс восстановление: оно сносило easyrsa3 до того, как готова замена, и не
# могло вернуть ненулевой код — бот печатает «✅ Восстановлено.» ровно по нулю.
#
# Статическая часть работает везде; настоящий прогон — под пространством имён.
#
#   bash tests/test_backup_endpoint.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BK=overlay/bin/awg-backup.sh
CL=overlay/bin/client-awg.sh

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Каталог слоя назван одинаково в бэкапе и в работе с клиентами"
# Инвариант, а не сверка с константой: расхождение и было дефектом.
d_bk="$(sed -n 's/^DEST="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$BK" | head -1)"
d_cl="$(sed -n 's|^CLIENT_DIR="\([^"]*\)/clients"|\1|p' "$CL" | head -1)"
if [ -n "$d_bk" ] && [ "$d_bk" = "$d_cl" ]; then
    ok "DEST совпадает: $d_bk"
else
    bad "DEST разошёлся: бэкап «$d_bk», клиенты «$d_cl»" \
        "бэкап читает не тот каталог, в котором лежат данные"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. stats.db не копируется простым cp, а восстановление убирает журналы"
if grep -q 'cp "\$DEST/stats\.db"' "$BK"; then
    bad "stats.db копируется через cp" "в режиме WAL это даёт базу без схемы"
else
    ok "простого cp для stats.db больше нет"
fi
grep -q 'src.backup(dst)' "$BK" && ok "снимок берётся через backup API sqlite" \
    || bad "нет снимка через backup API" "горячая копия WAL-базы некорректна"
grep -q 'rm -f "\$DEST/stats.db-wal"' "$BK" \
    && ok "осиротевшие журналы прежней базы убираются" \
    || bad "старый -wal остаётся после восстановления" \
           "sqlite проиграет его поверх и отдаст данные ПРЕЖНЕЙ установки"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Восстановление возвращает накопленный код, а не константу"
body="$(sed -n '/^do_restore()/,/^}$/p' "$BK")"
printf '%s\n' "$body" | grep -q 'return "\$rc"' \
    && ok "do_restore возвращает накопленный код" \
    || bad "код возврата не накапливается" "бот покажет ✅ на мёртвом сервере"
printf '%s\n' "$body" | grep -q 'rm -rf /etc/openvpn/easyrsa3; *cp -r' \
    && bad "PKI сносится до того, как готова замена" \
           "смерть между rm и cp оставит систему без easyrsa3 навсегда" \
    || ok "замена PKI не начинается со сноса оригинала"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Угаданный приватный адрес не должен уехать в Endpoint"
SH="$(sed -n '/^server_host()/,/^}$/p' "$CL")"
if [ -z "$SH" ]; then
    bad "не нашли server_host в $CL" "мерить нечего"
else
    W="$(mktemp -d)"; S="$W/stub"; mkdir -p "$S"
    printf '#!/bin/sh\necho "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5"\n' > "$S/ip"
    printf '#!/bin/sh\necho 203.0.113.7\n' > "$S/curl"
    chmod +x "$S/ip" "$S/curl"
    got="$( PATH="$S:$PATH"; eval "$SH"; server_host )"
    case "$got" in
        10.0.0.5) bad "в Endpoint уехал приватный адрес 10.0.0.5" \
                      "за NAT такой конфиг мёртв, а выглядит созданным" ;;
        203.0.113.7) ok "приватный src отброшен, взят внешний адрес" ;;
        *) bad "неожиданный адрес: [$got]" ;;
    esac
    # ОБЪЯВЛЕННЫЙ приватный адрес оспаривать нельзя: домашний сервер в своей
    # же локалке — законный случай.
    mkdir -p "$W/az"; printf 'WIREGUARD_HOST=192.168.1.10\n' > "$W/az/setup"
    got="$( PATH="$S:$PATH"
            SH2="${SH//\/root\/antizapret\/setup/$W\/az\/setup}"
            eval "$SH2"; server_host )"
    case "$got" in
        192.168.1.10) ok "объявленный приватный адрес оставлен как есть" ;;
        *) bad "объявленный адрес подменён на [$got]" "домашний сервер — законный случай" ;;
    esac
    rm -rf "$W"
fi

# ═══════════════════════════════════════════════════════════════════════════
if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — остальное пропущено\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_backup_endpoint" \
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

W="$(mktemp -d)"; mkdir -p "$W/etc-orig"
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

printf '[Interface]\nPrivateKey = SRV\nListenPort = 41234\n' > "$AWG/antizapret-awg.conf"
printf "AWG_Jc='4'\n" > "$AWG/obfuscation.env"
for s in antizapret vpn; do
    for i in 1 2; do
        printf '[Interface]\nPrivateKey = CLIENT_%s_%s\n' "$s" "$i" \
            > "$DEST/clients/$s/$s-c$i-am.conf"
    done
done
printf 'c1\t2030-01-01\n' > "$DEST/expiry.tsv"
printf 'x\n' > "$AZ/config/include-hosts.txt"
printf 'x\n' > /etc/knot-resolver/kresd.conf.lua
printf '#!/bin/bash\nexit 0\n' > "$AZ/doall.sh"
printf 'PKI\n' > /etc/openvpn/easyrsa3/pki/ca.crt

S="$W/stub"; mkdir -p "$S"
for c in ip awg awg-quick kresd; do printf '#!/bin/sh\nexit 0\n' > "$S/$c"; done
{ echo '#!/bin/sh'
  echo '[ "${SYSTEMCTL_FAIL:-0}" = 1 ] && { echo "Job failed. See journalctl." >&2; exit 1; }'
  echo 'exit 0'
} > "$S/systemctl"
chmod +x "$S"/*
export PATH="$S:$PATH"
BK="$STAND_REPO/overlay/bin/awg-backup.sh"

# ── живая база в режиме WAL, как её оставляет поллер ───────────────────────
python3 - "$DEST/stats.db" <<'PYMK'
import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)")
for i in range(200):
    c.execute("INSERT INTO t(v) VALUES (?)", ("изархива%d" % i,))
c.commit()
os._exit(0)          # без штатного закрытия — остаётся непустой -wal
PYMK

head_ "5. Архив содержит клиентские ключи, сроки и живую статистику"
bash "$BK" backup "$W/bk.tar.gz" >"$W/bk.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "бэкап отработал успешно" || bad "бэкап отказал ($rc)" "$(tail -2 "$W/bk.log")"
mkdir -p "$W/un" && tar -xzf "$W/bk.tar.gz" -C "$W/un" 2>/dev/null
n="$(grep -rl 'PrivateKey = CLIENT_' "$W/un" 2>/dev/null | wc -l)"
[ "$n" = 4 ] && ok "все 4 клиентских конфига с приватными ключами внутри архива" \
    || bad "в архиве $n клиентских конфигов из 4" \
           "переиздать их нечем — в серверном конфиге одни публичные"
[ -f "$W/un/awgstate/expiry.tsv" ] && ok "expiry.tsv в архиве" \
    || bad "expiry.tsv не попал в архив" "сроки временных клиентов не наступят"
got="$(python3 - "$W/un/awgstate/stats.db" <<'PYRD'
import sqlite3, sys
try:
    print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM t").fetchone()[0])
except Exception as e:
    print("ОШИБКА: %s" % e)
PYRD
)"
[ "$got" = 200 ] && ok "и статистика читается целиком: $got записей" \
    || bad "статистика в архиве: $got" "простой cp WAL-базы даёт «no such table»"

head_ "6. Восстановление возвращает данные и не молчит об отказе"
rm -f "$DEST/clients/antizapret/antizapret-c1-am.conf"
python3 - "$DEST/stats.db" <<'PYSRV'
import os, sqlite3, sys
p = sys.argv[1]
for s in ("", "-wal", "-shm"):
    try: os.unlink(p + s)
    except OSError: pass
c = sqlite3.connect(p); c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)")
for i in range(500): c.execute("INSERT INTO t(v) VALUES (?)", ("прежний%d" % i,))
c.commit(); os._exit(0)
PYSRV
bash "$BK" restore "$W/bk.tar.gz" >"$W/r1.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "успешное восстановление отдаёт 0" \
    || bad "успешное восстановление отдало $rc" "$(tail -3 "$W/r1.log")"
[ -f "$DEST/clients/antizapret/antizapret-c1-am.conf" ] \
    && ok "удалённый клиентский конфиг вернулся" || bad "конфиг не восстановлен"
got="$(python3 - "$DEST/stats.db" <<'PYRD2'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    print("%s %s" % (c.execute("SELECT count(*) FROM t").fetchone()[0],
                     c.execute("SELECT v FROM t LIMIT 1").fetchone()[0]))
except Exception as e:
    print("ОШИБКА: %s" % e)
PYRD2
)"
case "$got" in
    "200 изархива"*) ok "и база из архива, а не прежняя ($got)" ;;
    *прежний*) bad "читается база ПРЕЖНЕЙ установки: $got" \
                   "осиротевший -wal проигран поверх восстановленного файла" ;;
    *) bad "неожиданное состояние базы: $got" ;;
esac

head_ "7. Сервисы не поднялись — это отказ, а не успех"
SYSTEMCTL_FAIL=1 bash "$BK" restore "$W/bk.tar.gz" >"$W/r2.log" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "код возврата ненулевой ($rc) — бот покажет ❌" \
    || bad "код 0 при неподнявшихся тоннелях" "зелень поверх мёртвого сервера"
grep -q 'не перезапущено' "$W/r2.log" && ok "сказано, что именно не встало" \
    || bad "отказ перезапуска не назван" "$(tail -3 "$W/r2.log")"
grep -q 'Job failed' "$W/r2.log" && ok "причина от systemd доехала до вывода" \
    || bad "stderr systemd проглочен" "снятие 2>/dev/null не сработало"

head_ "8. Архив, снятый до починки — молчать о нём нельзя"
mkdir -p "$W/old"/{amneziawg,awgstate,config,knot,custom,client,openvpn}
printf '[Interface]\nPrivateKey = SRV\n' > "$W/old/amneziawg/antizapret-awg.conf"
echo old > "$W/old/MANIFEST"
( cd "$W/old" && tar -czf "$W/old.tar.gz" . )
bash "$BK" restore "$W/old.tar.gz" >"$W/r3.log" 2>&1; rc=$?
grep -q 'нет клиентских ключей' "$W/r3.log" \
    && ok "сказано, что ключей клиентов в архиве нет" \
    || bad "про пустой архив ничего не сказано" "$(tail -3 "$W/r3.log")"
[ "$rc" != 0 ] && ok "и вернул ненулевой код ($rc)" \
    || bad "код 0 на архиве без клиентских ключей"

head_ "9. PKI, брошенный оборванным прогоном, возвращается на место"
rm -rf /etc/openvpn/easyrsa3
mkdir -p /etc/openvpn/easyrsa3.old/pki
printf 'ОРИГИНАЛ\n' > /etc/openvpn/easyrsa3.old/pki/ca.crt
bash "$BK" restore "$W/bk.tar.gz" >"$W/r4.log" 2>&1
if [ -d /etc/openvpn/easyrsa3 ]; then
    ok "каталог easyrsa3 снова на месте"
    grep -q 'оборвалось' "$W/r4.log" && ok "и прогон объяснил, откуда он взялся" \
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
