#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Прерывание НАСТОЯЩЕЙ миграции, а не воспроизведение её последствий.
#
# Остальные наборы работают с вырезанными кусками. Здесь запускается весь
# patches/antizapret-awg-integration.sh --migrate, только в отдельном
# пространстве имён: tmpfs поверх /etc/amnezia, /root/antizapret,
# /opt/antizapret-awg и /etc/systemd/system, root даётся --map-root-user.
# Ничего за пределами пространства имён не меняется — точка.
#
# Проверяется то, что до сих пор держалось на чтении кода: метка
# незавершённой операции действительно доводит прерванную миграцию до конца.
#
# Прерывание точечное: заглушка mv выполняет переименование и убивает процесс
# сразу после того, как переехал ПЕРВЫЙ сервис. Это ровно граница, на которой
# первый конфиг уже переименован, второй ещё нет, а MODE=parallel в
# services.env записан двумя шагами раньше.
#
#   bash tests/test_migrate_interrupt.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — набор пропущен\n'
    printf '    (нужен unshare -Urm --map-root-user; без него настоящую миграцию не запустить)\n\n'
    exit 0
fi

# Всё, что ниже, исполняется ВНУТРИ пространства имён: там мы root, а tmpfs
# поверх системных каталогов делает стенд полностью изолированным.
export STAND_REPO="$ROOT"
unshare -Urm --map-root-user bash -s <<'INNER'
set -uo pipefail
fail=0
ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"
# Монтируем tmpfs поверх САМИХ /etc, /root и /opt, а не поверх подкаталогов:
# внутри пространства имён они принадлежат настоящему root и на запись
# недоступны, так что создать в них точку монтирования нельзя. Пустой /etc
# оболочка переживает — проверено: id, mktemp и подстановки работают.
# /etc нельзя просто накрыть пустым tmpfs: половина утилит в Debian ходит
# через /etc/alternatives, и awk с sed просто исчезают. Поэтому настоящий /etc
# сначала подкладывается рядом bind-монтированием, а потом копируется в tmpfs.
mkdir -p "$W/etc-orig"
mount --rbind /etc "$W/etc-orig" 2>/dev/null || { echo "  · не подложить /etc"; exit 0; }
for d in /etc /root /opt /usr/local; do
    mount -t tmpfs none "$d" 2>/dev/null || { echo "  · не смонтировать tmpfs на $d"; exit 0; }
done
cp -a "$W/etc-orig/." /etc/ 2>/dev/null || true
mkdir -p /etc/amnezia/amneziawg /etc/systemd/system /etc/wireguard          /root/antizapret /opt/antizapret-awg /usr/local/bin

AWG=/etc/amnezia/amneziawg
mkdir -p "$AWG" /opt/antizapret-awg/clients/antizapret /opt/antizapret-awg/clients/vpn

# ── состояние ДО миграции: старый режим replace, старые имена интерфейсов ───
cat > "$AWG/services.env" <<EOS
MODE=replace
LAYER2=1
LAYER3=0
AZ_IFACE=antizapret
VPN_IFACE=vpn
AZ_SUBNET=10.29.9
VPN_SUBNET=10.28.9
AZ_PORT=52443
VPN_PORT=52080
AZ_DNS=10.29.8.1
VPN_DNS=10.29.8.1
AZ_SPLIT=1
VPN_SPLIT=0
MTU=1320
MTU3=1280
EOS
for s in antizapret vpn; do
    printf '[Interface]\nPrivateKey = SRV_%s\nAddress = 10.29.9.1/24\nListenPort = 52443\n' \
        "$s" > "$AWG/$s.conf"
    printf '[Interface]\nPrivateKey = CL\n\n[Peer]\nEndpoint = 1.2.3.4:52443\n' \
        > "/opt/antizapret-awg/clients/$s/$s-c1-am.conf"
done
printf '#!/bin/bash\n# AmneziaWG redirection ports to WireGuard\n' > /root/antizapret/up.sh
printf '' > /root/antizapret/client.sh

# ── заглушки: всё, что трогает систему ─────────────────────────────────────
S="$W/stub"; mkdir -p "$S"
for c in systemctl ip iptables ip6tables awg awg-quick modinfo depmod modprobe sysctl; do
    printf '#!/bin/sh\nexit 0\n' > "$S/$c"
done
# Порт предсказуемый, но КАЖДЫЙ РАЗ другой: pick_random_port зовут дважды, и
# второй вызов получает первый порт в списке исключений — с постоянным
# значением он крутил бы все 200 попыток и отказал.
{
    echo '#!/bin/bash'
    echo 'c=/tmp/shufcnt; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"'
    echo 'echo $(( 33000 + n ))'
} > "$S/shuf"
printf '#!/bin/sh\nexit 0\n' > "$S/ss"
# mv переименовывает по-настоящему, но после переезда ПЕРВОГО сервиса убивает
# прогон: ровно та граница, где один конфиг уже переехал, второй ещё нет.
cat > "$S/mv" <<'EOS'
#!/bin/bash
/usr/bin/mv "$@"
rc=$?
if [ "${MV_KILL:-0}" = 1 ]; then
    for a in "$@"; do
        case "$a" in *antizapret-awg.conf) kill -9 "$PPID"; sleep 5 ;; esac
    done
fi
exit $rc
EOS
chmod +x "$S"/*
export PATH="$S:$PATH"

INTEG="$STAND_REPO/patches/antizapret-awg-integration.sh"

head_ "1. Миграция, убитая после переезда первого сервиса"
# Сообщение оболочки о сигнале глушим: оно от родителя, а не от операции.
{ MV_KILL=1 bash "$INTEG" --migrate >"$W/run1.log" 2>&1; rc=$?; } 2>/dev/null
[ "$rc" != 0 ] && ok "прогон прерван (код $rc)" || bad "прогон не прервался" "заглушка не сработала"

[ -f "$AWG/antizapret-awg.conf" ] && ok "первый сервис переехал" \
    || bad "первый сервис не переехал" "прерывание слишком раннее, мерить нечего"
[ -f "$AWG/vpn-awg.conf" ] && bad "второй сервис тоже успел" "прерывание слишком позднее" \
    || ok "второй — ещё нет: состояние ровно посередине"
grep -q '^MODE=parallel' "$AWG/services.env" \
    && ok "а MODE=parallel уже записан — это и есть ловушка" \
    || bad "MODE не записан" "тогда и коротить было бы не на чем"
[ -s "$AWG/.migrate-in-progress" ] && ok "метка незавершённой операции на месте" \
    || bad "метки нет" "повторный запуск не узнает, что работа не доделана"

head_ "2. Повторный запуск доделывает работу"
bash "$INTEG" --migrate >"$W/run2.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "повторный прогон отработал успешно" \
    || bad "повторный прогон отказал (код $rc)" "$(tail -3 "$W/run2.log")"
grep -q 'Найдена незавершённая миграция' "$W/run2.log" \
    && ok "и распознал, что миграция была прервана" \
    || bad "повтор не увидел незавершённой операции" "$(tail -3 "$W/run2.log")"
[ -f "$AWG/vpn-awg.conf" ] && ok "второй сервис доехал" \
    || bad "второй сервис так и не переехал" "ровно тот дефект, ради которого всё затевалось"
[ -e "$AWG/.migrate-in-progress" ] && bad "метка осталась после успешного прогона" \
    || ok "метка снята"

head_ "3. Порты после миграции согласованы"
# Тот самый инвариант: объявленный порт обязан совпасть с записанным.
. "$AWG/services.env"
for pair in "antizapret-awg:${AZ_PORT:-}" "vpn-awg:${VPN_PORT:-}"; do
    f="$AWG/${pair%%:*}.conf"; want="${pair##*:}"
    got="$(sed -n 's/^ListenPort *= *//p' "$f" 2>/dev/null | head -1)"
    if [ -z "$got" ]; then
        bad "${pair%%:*}: нет ListenPort в конфиге"
    elif [ "$got" = "$want" ]; then
        ok "${pair%%:*}: порт в конфиге совпал с объявленным ($want)"
    else
        bad "${pair%%:*}: объявлен $want, в конфиге $got"
    fi
done

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
