#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Прерывание --reconfigure на самой опасной его границе.
#
# Порядок в прогоне такой: сначала выпускается новый профиль обфускации и на
# него переезжает СЕРВЕР, и только последним шагом переписываются клиентские
# конфиги. Смерть между этими двумя действиями означает не «часть клиентов
# отстала», а «не подключается НИКТО»: сервер уже говорит на новом профиле,
# все выданные конфиги — на старом.
#
# Граница ловится точно: md5sum во всём проекте зовётся только внутри
# regen_all, по разу на клиента в начале итерации. Значит убийство на ПЕРВОМ
# её вызове — это ровно «сервер переехал, клиентов не тронули».
#
# Как и в наборе о миграции, запускается весь настоящий скрипт в отдельном
# пространстве имён; за его пределами не меняется ничего.
#
#   bash tests/test_reconfigure_interrupt.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── статическая часть: она работает и там, где namespace недоступен ─────────
head_ "1. Отказ regen-all в конце прогона не спрятан"
# Это самый разрушительный из возможных отказов, и раньше он был единственным
# полностью заглушённым: вывод в /dev/null, код съеден `|| true`, а прогон
# допечатывал «Готово» поверх неработающих клиентов.
if grep -q 'regen-all 2>/dev/null || true' patches/antizapret-awg-integration.sh; then
    bad "отказ regen-all по-прежнему глушится" "«Готово» поверх неподключающихся клиентов"
else
    ok "вывод и код возврата regen-all больше не выбрасываются"
fi
if grep -q 'не подключится никто' patches/antizapret-awg-integration.sh; then
    ok "и сказано, что именно произошло и что делать"
else
    bad "отказ не объяснён" "владельцу нужно знать, что сервер уже на новом профиле"
fi

if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — остальное пропущено\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_reconfigure_interrupt" \
        "пропущено: unshare -Urm недоступен, прерывание reconfigure не проверялось"
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
mkdir -p /etc/amnezia/amneziawg /etc/systemd/system /etc/wireguard \
         /root/antizapret /opt/antizapret-awg /usr/local/bin

AWG=/etc/amnezia/amneziawg
CL=/opt/antizapret-awg/clients
mkdir -p "$CL/antizapret" "$CL/vpn"

# ── стенд: уже установленный сервер в режиме parallel ───────────────────────
cat > "$AWG/services.env" <<EOS
MODE=parallel
LAYER2=1
LAYER3=0
AZ_IFACE=antizapret-awg
VPN_IFACE=vpn-awg
AZ_SUBNET=10.29.9
VPN_SUBNET=10.28.9
AZ_PORT=41234
VPN_PORT=42345
AZ_DNS=10.29.8.1
VPN_DNS=10.29.8.1
AZ_SPLIT=1
VPN_SPLIT=0
MTU=1320
MTU3=1280
EOS
# профиль, с которым конфиги были выданы
printf "AWG_Jc='4'\nAWG_Jmin='8'\nAWG_Jmax='120'\nAWG_S1='80'\nAWG_S2='90'\n" > "$AWG/obfuscation.env"
for s in antizapret vpn; do
    printf '[Interface]\nPrivateKey = SRV_%s\nAddress = 10.29.9.1/24\nListenPort = 41234\nJc = 4\nS1 = 80\n' \
        "$s" > "$AWG/${s}-awg.conf"
    for i in 1 2 3; do
        printf '[Interface]\nPrivateKey = CL%s\nAddress = 10.29.9.%s/32\nJc = 4\nS1 = 80\n\n[Peer]\nPublicKey = P\nEndpoint = 1.2.3.4:41234\n' \
            "$i" "$((i + 1))" > "$CL/$s/$s-c$i-am.conf"
    done
done
printf '#!/bin/bash\n# AmneziaWG redirection ports to WireGuard\n' > /root/antizapret/up.sh
: > /root/antizapret/client.sh

# ── заглушки ───────────────────────────────────────────────────────────────
S="$W/stub"; mkdir -p "$S"
for c in systemctl ip iptables ip6tables awg awg-quick modinfo depmod modprobe sysctl kresd; do
    printf '#!/bin/sh\nexit 0\n' > "$S/$c"
done
printf '#!/bin/sh\nexit 0\n' > "$S/ss"
{
    echo '#!/bin/bash'
    echo 'c=/tmp/shufcnt; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"'
    echo 'echo $(( 33000 + n ))'
} > "$S/shuf"
# md5sum зовётся ТОЛЬКО из regen_all, по разу на клиента в начале итерации.
# Убийство на первом вызове = сервер уже переехал, клиентов не тронули.
{
    echo '#!/bin/bash'
    echo '[ "${MD5_KILL:-0}" = 1 ] && { kill -9 "$PPID"; sleep 5; }'
    echo 'exec /usr/bin/md5sum "$@"'
} > "$S/md5sum"
chmod +x "$S"/*
export PATH="$S:$PATH"

INTEG="$STAND_REPO/patches/antizapret-awg-integration.sh"
prof() { grep -h '^Jc' "$CL"/antizapret/*-am.conf 2>/dev/null | sort | uniq -c | tr -d ' ' | tr '\n' ' '; }
srv_jc() { sed -n 's/^Jc *= *//p' "$AWG/antizapret-awg.conf" 2>/dev/null | head -1; }
env_jc() { sed -n "s/^AWG_Jc='\\(.*\\)'/\\1/p" "$AWG/obfuscation.env" 2>/dev/null | head -1; }

head_ "2. Смерть между переездом сервера и переписыванием клиентов"
before_env="$(env_jc)"
{ MD5_KILL=1 bash "$INTEG" --awg 2 --reconfigure --preset high --fp chrome --mtu 1320 \
    >"$W/run1.log" 2>&1; rc=$?; } 2>/dev/null
# Прогон здесь не умирает: regen-all вызывается через `if !`, и его смерть
# перехватывается. Но именно это и проверяем — что отказ не проглочен.
grep -q 'не подключится никто' "$W/run1.log"     && ok "прогон сказал вслух, что клиенты остались на старом профиле"     || bad "отказ regen-all не сообщён" "$(tail -3 "$W/run1.log")"
[ "$rc" != 0 ] && ok "и вернул ненулевой код ($rc) — автоматика увидит отказ"     || bad "код возврата 0 при неработающих клиентах" "это и есть зелень поверх сломанного"

after_env="$(env_jc)"
if [ -n "$after_env" ] && [ "$after_env" != "$before_env" ]; then
    ok "профиль сервера сменился: Jc $before_env → $after_env"
else
    bad "профиль не сменился" "прерывание слишком раннее, мерить нечего: [$before_env] → [$after_env]"
fi
[ "$(srv_jc)" = "$after_env" ] && ok "и серверный конфиг уже на новом профиле" \
    || bad "серверный конфиг не обновлён" "в конфиге $(srv_jc), в профиле $after_env"

cl="$(prof)"
case "$cl" in
    *"Jc=4"*)
        case "$cl" in
            *"Jc=$after_env"*) bad "часть клиентов успела обновиться" "$cl — граница не та" ;;
            *) ok "а КЛИЕНТЫ все на старом: $cl — не подключается никто" ;;
        esac ;;
    *) bad "клиенты уже обновлены" "$cl — прерывание слишком позднее" ;;
esac

head_ "3. Повторный прогон БЕЗ --reconfigure доводит клиентов"
# Именно без: с --reconfigure владелец получил бы третий профиль и сломал бы
# клиентов ещё раз. Штатное восстановление — обычный прогон, он переприменяет
# существующий профиль и пересоздаёт конфиги.
bash "$INTEG" --awg 2 --preset high --fp chrome --mtu 1320 >"$W/run2.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "повторный прогон отработал успешно" \
    || bad "повторный прогон отказал (код $rc)" "$(tail -3 "$W/run2.log")"
[ "$(env_jc)" = "$after_env" ] && ok "профиль НЕ перевыпущен заново (Jc $after_env)" \
    || bad "профиль сменился повторно" "было $after_env, стало $(env_jc)"
cl="$(prof)"
case "$cl" in
    *"Jc=4"*) bad "клиенты так и остались на старом профиле" "$cl" ;;
    *) ok "все клиенты переведены на профиль сервера: $cl" ;;
esac
keys="$(grep -h '^PrivateKey' "$CL"/antizapret/*-am.conf | sort | tr '\n' ' ')"
case "$keys" in
    *CL1*CL2*CL3*) ok "ключи клиентов при этом не тронуты" ;;
    *) bad "ключи клиентов изменились" "$keys" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
