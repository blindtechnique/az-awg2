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
BACKUP_SH=overlay/bin/awg-backup.sh
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
# Берём блок целиком: он состоит из двух if подряд, и первый `^    fi$` его
# не закрывает — обрезка по нему оставляла бы old_az_iface неопределённым.
GUARD="$(awk '/local old_mode=/,/MARK_VPN_IFACE/' "$INTEG")
    fi"
if [ -z "$GUARD" ]; then
    bad "не нашли решение о продолжении миграции" "мерить нечего"
else
    probe() {  # probe <MODE в services.env> <есть ли метка> → что решил код
        # shellcheck disable=SC2034  # обе читает вырезанный из файла код под eval
        ( set -euo pipefail
          MODE="$1"; MIGRATE_MARK="$WORK/mark"; rm -f "$WORK/mark"
          # Блок читает и текущие имена интерфейсов: под set -u без них он
          # падает раньше, чем успеет что-то решить.
          AZ_IFACE=antizapret-awg; VPN_IFACE=vpn-awg
          # Метка теперь сорсится, а не читается: формат key=value.
          [ "$2" = 1 ] && printf 'MARK_MODE=keep
MARK_AZ_IFACE=antizapret
MARK_VPN_IFACE=vpn
' > "$WORK/mark"
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

head_ "3б. Метка хранит то, чего повтор уже не найдёт в services.env"
# Одного режима мало: имена старых интерфейсов после первой же записи
# перезаписаны, и повтор, читая их оттуда, получил бы old_if == new_if,
# пропустил переименование целиком — и всё равно отрапортовал об успехе.
mb="$(sed -n '/mkdir -p "\$(dirname "\$MIGRATE_MARK")"/,/> "\$MIGRATE_MARK"/p' "$INTEG")"
for k in MARK_MODE MARK_AZ_IFACE MARK_VPN_IFACE; do
    case "$mb" in
        *"$k"*) ok "метка записывает $k" ;;
        *) bad "метка не хранит $k" "повтор не сможет доделать переименование" ;;
    esac
done
if sed -n '/local resumed=0/,/MARK_VPN_IFACE/p' "$INTEG" | grep -q 'MARK_AZ_IFACE:-'; then
    ok "и повтор берёт имена именно из неё, а не из services.env"
else
    bad "повтор читает имена из перезаписанного services.env"
fi

head_ "3г. Повтор не затирает метку уже мигрированными именами"
# Восстановление имён из метки было, а вот запись метки шла безусловно и брала
# значения из УЖЕ перезаписанного services.env. После второго прерывания метка
# содержала мигрированные имена, то есть единственный след незавершённости
# исчезал: сервер оставался наполовину переехавшим и объявленным здоровым, а
# штатный путь починки закрывался навсегда.
if [ -z "$mb" ]; then
    bad "не нашли блок записи метки" "мерить нечего"
else
    out="$( set -euo pipefail
            MIGRATE_MARK="$WORK/mark2"; rm -f "$MIGRATE_MARK"
            export old_mode=keep
            # так выглядит ПОВТОР: services.env уже содержит новые имена…
            export AZ_IFACE=antizapret-awg VPN_IFACE=vpn-awg
            export AZ_SUBNET=10.29.10 VPN_SUBNET=10.28.10
            # …а старые восстановлены из метки предыдущим блоком
            export old_az_iface=antizapret old_vpn_iface=vpn
            export old_az_sub=10.29.9 old_vpn_sub=10.28.9
            eval "$mb"
            cat "$MIGRATE_MARK" )"
    printf '%s\n' "$out" | grep -qx 'MARK_AZ_IFACE=antizapret' \
        && ok "в метке осталось исходное имя antizapret" \
        || bad "метка перезаписана мигрированным именем" \
               "второе прерывание сотрёт единственный след: $(printf '%s' "$out" | tr '\n' ' ')"
    printf '%s\n' "$out" | grep -qx 'MARK_VPN_IFACE=vpn' \
        && ok "и vpn тоже" \
        || bad "метка перезаписана мигрированным именем vpn-awg" \
               "$(printf '%s' "$out" | tr '\n' ' ')"
    printf '%s\n' "$out" | grep -qx 'MARK_AZ_SUBNET=10.29.9' \
        && ok "и подсеть исходная, а не новая" \
        || bad "в метке новая подсеть" "если её когда-нибудь прочитают, повтор уедет не туда"
fi

head_ "3в. Установщик тоже знает про метку"
# У install.sh своя проверка MODE. Пока она не знала о метке, штатный путь
# `install.sh --migrate` коротил на «миграция не нужна», и до починки дело не
# доходило вовсе — как бы хорошо ни вела себя сама интеграция.
if grep -q 'migrate-in-progress' install.sh; then
    ok "install.sh проверяет метку перед своим коротким замыканием"
else
    bad "install.sh коротит по MODE, не глядя на метку" "штатный путь миграции не чинится"
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

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Восстановление, убитое между копированием ключей и клиентов"
# Все cp внутри do_restore идут с `|| true`, поэтому отказом команды операцию
# не прервать — она просто поехала бы дальше. Изображаем настоящее убийство:
# заглушка cp делает kill -9 родителю на N-м вызове. Так выглядят оборванный
# ssh, OOM и ребут, и заодно видно, что бывает, когда trap уже не выполнится.
# У do_restore здесь два абсолютных пути (/etc/knot-resolver и /etc/openvpn):
# без root mkdir по ним падает, и стенд мерил бы не прерывание, а отсутствие
# прав. Переписываем их в вырезанном куске — сам файл не трогаем.
DR="$(sed -n '/^_restore_part()/,/^}$/p;/^do_restore()/,/^}$/p' "$BACKUP_SH" \
      | sed "s#/etc/knot-resolver#$WORK/knot#g; s#/etc/openvpn#$WORK/openvpn#g")"
mkdir -p "$WORK/knot" "$WORK/openvpn"
if [ -z "$DR" ]; then
    bad "не нашли do_restore" "мерить нечего"
else
    R="$WORK/restore"
    mkdir -p "$R/stage/amneziawg" "$R/stage/client" "$R/stage/awgstate" \
             "$R/etc" "$R/az/client"
    echo backup > "$R/stage/MANIFEST"
    printf 'PrivateKey = ИЗ_БЭКАПА\n' > "$R/stage/amneziawg/antizapret-awg.conf"
    printf 'PrivateKey = КЛИЕНТ_ИЗ_БЭКАПА\n' > "$R/stage/client/c1-am.conf"
    # Настоящий архив всегда несёт эти три вещи, и восстановление теперь вслух
    # жалуется на их отсутствие. Стенд мерит прерывание, а не полноту архива,
    # поэтому обставляем его как настоящий — иначе он мерил бы жалобу.
    printf 'LAYER2=1\nAZ_IFACE=antizapret\nVPN_IFACE=vpn\n' \
        > "$R/stage/amneziawg/services.env"
    printf 'stats\n' > "$R/stage/awgstate/stats.db"
    printf '#!/bin/bash\nexit 0\n' > "$R/az/doall.sh"
    ( cd "$R/stage" && tar -czf "$R/bk.tar.gz" . )

    # живое состояние делаем заведомо ДРУГИМ, чтобы отличать восстановленное
    printf 'PrivateKey = ЖИВОЙ\n' > "$R/etc/antizapret-awg.conf"
    printf 'PrivateKey = ЖИВОЙ_КЛИЕНТ\n' > "$R/az/client/c1-am.conf"

    CPSTUB="$WORK/cpstub"; mkdir -p "$CPSTUB"
    {
        echo '#!/bin/bash'
        echo 'n=$(( $(cat "$CP_COUNT" 2>/dev/null || echo 0) + 1 ))'
        echo 'echo "$n" > "$CP_COUNT"'
        echo '[ "$n" -ge "$CP_DIE_AT" ] && { kill -9 "$PPID"; sleep 5; }'
        echo 'exec /usr/bin/cp "$@"'
    } > "$CPSTUB/cp"
    chmod +x "$CPSTUB/cp"

    run_restore() {  # run_restore <умереть на N-м cp | 0 = не умирать>
        local pfx=""
        [ "$1" != 0 ] && pfx="$CPSTUB:"
        echo 0 > "$WORK/cpcnt"
        # RESTORE_MARK объявлен на уровне файла, а вырезается только тело
        # функции — без этой строки кусок падает под set -u на первой же записи.
        PATH="${pfx}$PATH" CP_COUNT="$WORK/cpcnt" CP_DIE_AT="$1" \
        bash -c "set -euo pipefail
            AWG_DIR=$R/etc; DEST=$R/dest; AZ=$R/az
            RESTORE_MARK=$R/etc/.restore-in-progress
            # Замок объявлен на уровне файла, а вырезается только тело функции.
            # Здесь он не при чём: стенд мерит прерывание, а не блокировку —
            # её проверяет tests/test_restore_integrity.sh на настоящем скрипте.
            lock_wait() { :; }; lock_drop() { :; }
            log() { :; }; err() { :; }; systemctl() { :; }
            $DR
            do_restore $R/bk.tar.gz" >/dev/null 2>&1
    }

    # Сообщение оболочки о сигнале глушим здесь: оно от родителя, а не
    # от самой операции, и в отчёте только мешает.
    { run_restore 2 || true; } 2>/dev/null
    k="$(cat "$R/etc/antizapret-awg.conf" 2>/dev/null || true)"
    c="$(cat "$R/az/client/c1-am.conf" 2>/dev/null || true)"
    case "$k" in
        *ИЗ_БЭКАПА*)
            case "$c" in
                *ЖИВОЙ*) ok "состояние рассогласовано, как и задумано: ключи из бэкапа, клиенты прежние" ;;
                *) bad "клиенты успели восстановиться" "прерывание слишком позднее" ;;
            esac ;;
        *) bad "ключи не восстановились" "прерывание слишком раннее: [$k]" ;;
    esac

    run_restore 0 && rc=0 || rc=$?
    k="$(cat "$R/etc/antizapret-awg.conf" 2>/dev/null || true)"
    c="$(cat "$R/az/client/c1-am.conf" 2>/dev/null || true)"
    [ "$rc" = 0 ] && ok "повторное восстановление отработало успешно" \
        || bad "повторное восстановление отказало (код $rc)"
    case "$k$c" in
        *ЖИВОЙ*) bad "после повторного запуска остались куски прежнего состояния" "[$k] [$c]" ;;
        *) ok "повторный запуск довёл восстановление до конца" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Восстановление не уничтожает чужой PKI, если умереть посередине"
# Единственный шаг восстановления, который делает состояние ХУЖЕ исходного, а
# не просто неполным: каталог easyrsa3 ванильного OpenVPN сначала удаляется, и
# только потом копируется новый. Смерть между этими действиями оставляет
# систему вообще без PKI, и взять его уже неоткуда.
body="$(sed -n '/^do_restore()/,/^}$/p' "$BACKUP_SH")"
if ! printf '%s\n' "$body" | grep -q easyrsa3; then
    bad "не нашли обработку easyrsa3 в do_restore" "мерить нечего"
else
    if printf '%s\n' "$body" | grep -q 'rm -rf /etc/openvpn/easyrsa3; *cp -r'; then
        bad "PKI сносится до того, как готова замена" \
            "смерть между rm и cp оставит систему без easyrsa3 навсегда"
    else
        ok "замена PKI не начинается со сноса оригинала"
    fi
    if printf '%s\n' "$body" | grep -q 'easyrsa3\.restore'; then
        ok "новый PKI кладётся рядом и подменяется переименованием"
    else
        bad "нет промежуточного каталога" "окно между сносом и заменой не сужено"
    fi
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
