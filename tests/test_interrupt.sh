#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Прерывание посреди многошаговой операции.
#
# Вопрос здесь не «падает ли команда», а другой:
#
#     если операция умерла между двумя необратимыми действиями,
#     приведёт ли ПОВТОРНЫЙ запуск систему в согласованное состояние?
#
# Это следующий класс после «команда упала»: система остаётся в промежуточном
# состоянии, и повторный запуск либо доделывает работу, либо коротит на
# признаке, который первый прогон успел записать, — и тогда работа не будет
# доделана никогда.
#
# Прерывание воспроизводится детерминированно: внешняя команда, которую
# операция зовёт по разу на шаг, подменяется заглушкой, выходящей с ошибкой на
# N-м вызове. Под set -e это и есть смерть посреди цикла.
#
#   bash tests/test_interrupt.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

INTEG=patches/antizapret-awg-integration.sh
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── стенд: сервер с выданными клиентами ─────────────────────────────────────
mk_stand() {  # mk_stand <каталог> <клиентов>
    local d="$1" n="$2" i
    mkdir -p "$d/etc" "$d/dest/clients/antizapret" "$d/bin"
    {
        echo "MODE=parallel"; echo "LAYER2=1"; echo "LAYER3=0"
        echo "AZ_IFACE=antizapret-awg"; echo "AZ_SUBNET=10.29.9"; echo "AZ_PORT=41234"
        echo "AZ_DNS=10.29.8.1"; echo "AZ_SPLIT=1"
        echo "VPN_IFACE=vpn-awg"; echo "VPN_SUBNET=10.28.9"; echo "VPN_PORT=42345"
        echo "VPN_DNS=10.29.8.1"; echo "VPN_SPLIT=0"
        echo "MTU=1320"; echo "MTU3=1280"
    } > "$d/etc/services.env"
    # профиль А — тот, с которым конфиги были выданы
    printf "AWG_Jc='4'\nAWG_S1='80'\n" > "$d/etc/obfuscation.env"
    printf '[Interface]\nPrivateKey = SRV\nListenPort = 41234\n' > "$d/etc/antizapret-awg.conf"
    for i in $(seq 1 "$n"); do
        printf '[Interface]\nPrivateKey = K%s\nAddress = 10.29.9.%s/32\nJc = 4\nS1 = 80\n\n[Peer]\nPublicKey = SRVPUB\nAllowedIPs = 0.0.0.0/0\n' \
            "$i" "$((i + 1))" > "$d/dest/clients/antizapret/antizapret-c$i-am.conf"
    done
}

# копия скрипта с путями на стенд
client_sh() {  # client_sh <каталог> → путь
    local d="$1" f="$1/bin/client-awg.sh"
    [ -f "$f" ] && { echo "$f"; return; }
    cp overlay/bin/client-awg.sh "$f"
    sed -i "s#^AWG_DIR=.*#AWG_DIR=\"$d/etc\"#" "$f"
    sed -i "s#^DEST=.*#DEST=\"$d/dest\"#" "$f"
    sed -i "s#^CLIENT_DIR=.*#CLIENT_DIR=\"$d/dest/clients\"#" "$f"
    chmod +x "$f"
    echo "$f"
}

profiles() {  # profiles <каталог> → сколько конфигов с каким Jc
    grep -h '^Jc' "$1"/dest/clients/antizapret/*-am.conf 2>/dev/null | sort | uniq -c | tr -d ' ' | tr '\n' ' '
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. regen-all: смерть посреди списка клиентов"

D="$WORK/regen"; mk_stand "$D" 6
SH="$(client_sh "$D")"

# профиль сменился: конфиги обязаны переехать с Jc=4 на Jc=9
printf "AWG_Jc='9'\nAWG_S1='81'\n" > "$D/etc/obfuscation.env"

# Заглушка md5sum: операция зовёт её по разу на клиента в начале итерации,
# поэтому «умереть на третьем вызове» = «умереть на третьем клиенте».
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/md5sum" <<'EOS'
#!/bin/bash
c="${STUB_COUNT:-/tmp/awgcnt}"
n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$c"
[ "$n" -ge "${STUB_DIE_AT:-3}" ] && exit 1
exec /usr/bin/md5sum "$@"
EOS
chmod +x "$STUB/md5sum"

echo 0 > "$WORK/cnt"
PATH="$STUB:$PATH" STUB_COUNT="$WORK/cnt" STUB_DIE_AT=3 \
    bash "$SH" regen-all >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && ok "прогон прерван (код $rc)" \
    || bad "прогон не прервался" "заглушка не сработала — дальше мерить нечего"

mixed="$(profiles "$D")"
case "$mixed" in
    *"Jc=4"*|*"Jc = 4"*)
        case "$mixed" in
            *"Jc=9"*|*"Jc = 9"*) ok "состояние действительно смешанное: $mixed" ;;
            *) bad "ни один конфиг не успел обновиться" "$mixed — прерывание слишком раннее, тест ничего не мерит" ;;
        esac ;;
    *) bad "все конфиги уже обновлены" "$mixed — прерывание слишком позднее" ;;
esac

# ── повторный запуск, уже без заглушки ─────────────────────────────────────
bash "$SH" regen-all >/dev/null 2>&1 && rc=0 || rc=$?
after="$(profiles "$D")"
[ "$rc" = 0 ] && ok "повторный запуск отработал успешно" \
    || bad "повторный запуск отказал (код $rc)" "после прерывания система не чинится сама"
case "$after" in
    *"Jc = 4"*) bad "часть конфигов осталась со старым профилем" "$after" ;;
    *) ok "все конфиги приведены к одному профилю: $after" ;;
esac

# И ключи клиентов при этом обязаны остаться прежними: перевыпуск ключа
# означал бы, что клиент уже не подключится вообще.
keys="$(grep -h '^PrivateKey' "$D"/dest/clients/antizapret/*-am.conf | sort | tr '\n' ' ')"
case "$keys" in
    *K1*K2*K3*K4*K5*K6*) ok "ключи клиентов не тронуты" ;;
    *) bad "ключи клиентов изменились" "$keys" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. regen-all повторяем: второй прогон подряд ничего не меняет"
# Идемпотентность — то, на чём держится вывод «конфиги переиздавать не нужно».
sum1="$(cat "$D"/dest/clients/antizapret/*-am.conf | md5sum)"
bash "$SH" regen-all >/dev/null 2>&1 || true
sum2="$(cat "$D"/dest/clients/antizapret/*-am.conf | md5sum)"
[ "$sum1" = "$sum2" ] && ok "повторный прогон не изменил ни байта" \
    || bad "прогон меняет конфиги каждый раз" "владелец будет думать, что клиентам пора раздавать новые"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Миграция, прерванная посередине, доделывается повторным запуском"
# Здесь прерывание нельзя изобразить убийством: do_migrate требует ванильный
# AntiZapret, root и живые юниты. Зато состояние ПОСЛЕ прерывания
# воспроизводится точно, а именно оно и решает: write_services пишет
# MODE=parallel вторым шагом, восстановление ванили — пятым. Смерть между ними
# оставляла «заявлено parallel, работа не доделана», повторный запуск коротил
# на первой строке и выходил с кодом 0 — то есть работа не делалась НИКОГДА.
# Вместе с MODE терялся и старый режим: доделывать было уже нечем.
GUARD="$(sed -n '/local old_mode=/,/^    fi$/p' "$INTEG" | head -20)"
if [ -z "$GUARD" ]; then
    bad "не нашли решение о продолжении миграции" "мерить нечего"
else
    probe() {  # probe <MODE в services.env> <есть ли метка> → что решил код
        # shellcheck disable=SC2034  # обе читает вырезанный из файла код под eval
        ( set -euo pipefail
          MODE="$1"; MIGRATE_MARK="$WORK/mark"; rm -f "$WORK/mark"
          [ "$2" = 1 ] && echo keep > "$WORK/mark"
          log() { printf 'LOG %s\n' "$*"; }
          local old_mode
          eval "$GUARD"
          printf 'ПРОДОЛЖАЕМ из %s\n' "$old_mode" )
    }
    out="$(probe keep 0)"
    case "$out" in
        *"ПРОДОЛЖАЕМ из keep"*) ok "обычная миграция из keep идёт как раньше" ;;
        *) bad "миграция из keep сломана" "вышло «$out»" ;;
    esac

    out="$(probe parallel 0)"
    case "$out" in
        *"миграция не нужна"*) ok "завершённая миграция по-прежнему не повторяется" ;;
        *) bad "на готовой системе миграция запускается заново" "вышло «$out»" ;;
    esac

    out="$(probe parallel 1)"
    case "$out" in
        *"ПРОДОЛЖАЕМ из keep"*) ok "прерванная миграция доделывается, а не объявляется ненужной" ;;
        *) bad "прерванная миграция считается завершённой" \
               "повторный запуск не доделает работу никогда: «$out»" ;;
    esac
    case "$out" in
        *"Найдена незавершённая"*) ok "и об этом сказано вслух" ;;
        *) bad "продолжение происходит молча" ;;
    esac
fi

head_ "4. Метка ставится до первой записи и снимается последней"
# Метка, поставленная после write_services, не прикрывает ничего.
BODY="$(sed -n '/^do_migrate()/,/^}/p' "$INTEG")"
nl_of() { printf '%s\n' "$BODY" | grep -n "$1" | head -1 | cut -d: -f1; }
m="$(nl_of 'MIGRATE_MARK"$')"; w="$(nl_of '^    write_services$')"; u="$(nl_of 'rm -f "\$MIGRATE_MARK"')"
if [ -z "$m" ] || [ -z "$w" ] || [ -z "$u" ]; then
    bad "не нашли постановку/снятие метки или write_services в do_migrate"
else
    [ "$m" -lt "$w" ] && ok "метка ставится раньше записи services.env" \
        || bad "метка ставится позже первой записи" "прерывание между ними ничем не прикрыто"
    [ "$u" -gt "$w" ] && ok "и снимается уже после всей работы" \
        || bad "метка снимается слишком рано"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
