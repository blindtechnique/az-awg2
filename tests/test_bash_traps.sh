#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Ловушки bash, на которых установщик врал или умирал молча.
#
# Все — про «set -euo pipefail» и про то, что ненулевой код приезжает не
# оттуда, откуда его ждут:
#   1) `ss -lunH` печатает колонку Netid не на всех версиях iproute2, поэтому
#      жёсткий номер поля угадывает лишь на одной раскладке. Здесь стояло $5 —
#      колонка Peer, «0.0.0.0:*»: список занятых портов был пуст ВСЕГДА, а сам
#      вызов возвращал 1 и ронял подстановку;
#   2) `печатай | grep -q` под pipefail отдаёт 141, когда совпадение нашлось в
#      начале длинного вывода: занятый порт (или занятый IP) объявлялся
#      свободным, а порт на первой установке закрепляется навсегда;
#   3) grep без совпадения в присваивании убивал команду молча, вместо того
#      чтобы отдать пустую строку в заготовленную ветку.
#
# Куски вырезаются из НАСТОЯЩИХ файлов и исполняются как есть.
#
#   bash tests/test_bash_traps.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

INTEG=patches/antizapret-awg-integration.sh

# Подставной ss: обе раскладки, с колонкой Netid и без неё. Настоящий ss
# печатает её не всегда, и правка, угадавшая одну, обязана работать в обеих.
mk_ss() {  # mk_ss <каталог> <netid: 0|1> <порт…>
    local d="$1" netid="$2"; shift 2
    mkdir -p "$d"
    {
        echo '#!/bin/bash'
        for p in "$@"; do
            if [ "$netid" = 1 ]; then
                printf 'printf "udp UNCONN 0      0      0.0.0.0:%%s 0.0.0.0:*\\n" %s\n' "$p"
            else
                printf 'printf "UNCONN 0      0      0.0.0.0:%%s 0.0.0.0:*\\n" %s\n' "$p"
            fi
        done
    } > "$d/ss"
    chmod +x "$d/ss"
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Занятый порт виден в обеих раскладках ss"

BP="$(grep '^busy_ports()' "$INTEG")"
if [ -z "$BP" ]; then
    bad "не нашли busy_ports в интеграции" "мерить нечего"
else
    for netid in 0 1; do
        d="$WORK/ss$netid"; mk_ss "$d" "$netid" 51820 41234
        out="$(PATH="$d:$PATH" bash -c "set -euo pipefail; $BP
            busy_ports | tr '\n' ' '" 2>&1)" || out="ОТКАЗ:$?"
        label="без Netid"; [ "$netid" = 1 ] && label="с Netid"
        # sort -u выдаёт по возрастанию, поэтому порядок в шаблоне значения
        # не имеет — проверяем оба порта по отдельности.
        if case "$out" in *51820*) true ;; *) false ;; esac &&
           case "$out" in *41234*) true ;; *) false ;; esac; then
            ok "занятые порты найдены ($label)"
        else
            bad "занятые порты не найдены ($label)" "вышло «$out»"
        fi
    done
    # Пустой вывод ss не должен ронять вызывающего: busy_ports стоит первой
    # командой в подстановке exclude=…, и её обрыв унёс бы резервные порты.
    d="$WORK/ssempty"; mk_ss "$d" 0
    out="$(PATH="$d:$PATH" bash -c "set -euo pipefail; $BP
        exclude=\"22 53 \$(busy_ports) 80\"; echo \"[\$exclude]\"" 2>&1)" || out="ОТКАЗ:$?"
    case "$out" in
        *22*53*80*) ok "пустой ss не роняет список исключений" ;;
        *) bad "пустой ss обрывает подстановку" "вышло «$out»" ;;
    esac
fi

head_ "2. Предикаты установщика отвечают правдой"
PRED="$(sed -n '/^RESERVED_PORTS=/p;/^port_reserved()/p;/^port_busy()/,/^}$/p' install.sh)"
if [ -z "$PRED" ]; then
    bad "не нашли port_reserved/port_busy" "мерить нечего"
else
    d="$WORK/sspred"; mk_ss "$d" 0 51820
    out="$(PATH="$d:$PATH" bash -c "set -euo pipefail; $PRED
        for p in 53 51820 33333; do
            if port_reserved \"\$p\"; then echo \"\$p=резерв\"
            elif port_busy \"\$p\"; then echo \"\$p=занят\"
            else echo \"\$p=свободен\"; fi
        done" 2>&1)" || out="ОТКАЗ:$?"
    case "$out" in
        *"53=резерв"*) ok "зарезервированный порт распознан" ;;
        *) bad "резервный порт не распознан" "вышло «$out»" ;;
    esac
    case "$out" in
        *"51820=занят"*) ok "занятый порт распознан" ;;
        *) bad "занятый порт назван свободным" "вышло «$out»" ;;
    esac
    case "$out" in
        *"33333=свободен"*) ok "свободный порт не оболган" ;;
        *) bad "свободный порт назван занятым" "вышло «$out»" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Из полностью занятого диапазона порт не выдаётся"
PICK="$(grep '^RESERVED_PORTS=' "$INTEG"; grep '^busy_ports()' "$INTEG"
        sed -n '/^pick_random_port()/,/^}$/p' "$INTEG")"
if [ -z "$PICK" ]; then
    bad "не нашли pick_random_port" "мерить нечего"
else
    # Занят ВЕСЬ диапазон, из которого выбирает функция. Правильный ответ —
    # отказ. Старый код на первой же попытке ловил SIGPIPE (список длиннее
    # буфера трубы), читал 141 как «не найдено» и отдавал занятый порт.
    d="$WORK/ssall"; mkdir -p "$d"
    {
        echo '#!/bin/bash'
        echo 'for p in $(seq 20000 59999); do printf "UNCONN 0      0      0.0.0.0:%s 0.0.0.0:*\n" "$p"; done'
    } > "$d/ss"
    chmod +x "$d/ss"
    out="$(PATH="$d:$PATH" bash -c "set -euo pipefail
        err() { printf 'ERR %s\n' \"\$*\" >&2; }
        $PICK
        pick_random_port" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" != 0 ]; then
        ok "занятый диапазон → честный отказ (код $rc)"
    else
        bad "выдан порт из полностью занятого диапазона" "вернулось «$out»"
    fi
    case "$out" in
        *"не нашёл свободный порт"*) ok "и сказано, почему" ;;
        *) bad "отказ без объяснения" "вышло «$out»" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Занятый IP не выдаётся второму клиенту"
# Честно про охват: в /24 занятых адресов не больше 253, список влезает в буфер
# трубы, и SIGPIPE тут не случается. То есть это latent-случай того же класса,
# и поведенчески он покраснеть НЕ может — за него отвечает статическая проверка
# в разделе 6. Здесь проверяется, что переписанная логика считает правильно.
NEXT="$(sed -n '/^next_ip()/,/^}$/p' overlay/bin/client-awg.sh)"
if [ -z "$NEXT" ]; then
    bad "не нашли next_ip" "мерить нечего"
else
    conf="$WORK/server.conf"
    : > "$conf"
    for i in $(seq 2 200); do echo "AllowedIPs = 10.29.9.$i/32" >> "$conf"; done
    out="$(bash -c "set -euo pipefail
        SUBNET=10.29.9; SERVER_CONF='$conf'
        die() { printf 'DIE %s\n' \"\$*\"; exit 1; }
        $NEXT
        next_ip" 2>&1)" || out="ОТКАЗ:$?"
    [ "$out" = "10.29.9.201" ] && ok "выдан первый действительно свободный адрес" \
        || bad "выдан занятый или неверный адрес" "вернулось «$out»"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Конфиг без PrivateKey не убивает удаление молча"
CP="$(sed -n '/cpriv="\$(grep/,+1p' overlay/bin/client-awg.sh)"
if [ -z "$CP" ]; then
    bad "не нашли чтение PrivateKey в del_client" "мерить нечего"
else
    conf="$WORK/client.conf"
    printf '[Interface]\nAddress = 10.29.9.2/32\n' > "$conf"
    out="$(bash -c "set -euo pipefail
        conf='$conf'
        die() { printf 'DIE %s\n' \"\$*\"; exit 1; }
        $CP
        echo 'дошли дальше'" 2>&1)" || true
    case "$out" in
        *"DIE"*"нет PrivateKey"*) ok "сказано, что не так, вместо тихой смерти" ;;
        *) bad "команда умирает без объяснения" "вышло «$out»" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Заплаты на месте"
if grep -q "print \$5" "$INTEG" install.sh; then
    bad "где-то вернулся жёсткий \$5" "ss печатает Netid не всегда"
else
    ok "номер колонки ss нигде не зашит наглухо"
fi
for f in "$INTEG" install.sh overlay/bin/client-awg.sh; do
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'grep -qx'; then
        bad "в $f осталась труба с grep -qx" "она отдаёт 141 на длинном выводе"
    else
        ok "$f обходится без grep -qx в проверках"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Миграция переживает хост без маршрута по умолчанию"
# Статус подстановки — это статус всего конвейера, и под pipefail он приезжает
# от ip (rc=2 без маршрута по умолчанию), а не от grep. set -e убивал
# do_migrate прямо здесь — уже ПОСЛЕ того, как конфиги переименованы и в
# services.env лёг MODE=parallel. Повторный --migrate после этого коротит на
# «уже parallel», и ванильный редирект не вернётся никогда.
DL="$(grep -F 'difc="$(ip route get' "$INTEG")"
if [ -z "$DL" ]; then
    bad "не нашли определение difc в do_migrate" "мерить нечего"
else
    out="$(bash -c "set -euo pipefail
        ip() { echo 'RTNETLINK answers: Network is unreachable' >&2; return 2; }
        difc=''
$DL
        echo \"ЖИВ:[\$difc]\"" 2>/dev/null)" || out="ОТКАЗ:$?"
    [ "$out" = "ЖИВ:[]" ] && ok "пустой difc доезжает до заготовленной ветки" \
        || bad "миграция умирает на определении интерфейса" "вернулось «$out»"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "8. Конфиг без PrivateKey не убивает сборку интерфейса"
# Конфиг перезаписывается усекающим редиректом; прерывание в этом окне
# оставляет файл без строки PrivateKey. Ветки «ключ отсутствует или битый»
# написаны ровно на этот случай — и были недостижимы, потому что присваивание
# умирало раньше.
for fn in _extract_key _extract_key3; do
    EK="$(grep -F "${fn}() {" "$INTEG")"
    if [ -z "$EK" ]; then
        bad "не нашли $fn в интеграции" "мерить нечего"
        continue
    fi
    conf="$WORK/trunc.conf"
    printf '# AntiZapret-AWG\nAddress = 10.29.9.1/24\n' > "$conf"
    out="$(bash -c "set -euo pipefail
$EK
        priv=\"\$($fn '$conf')\"
        echo \"ЖИВ:[\$priv]\"" 2>&1)" || out="ОТКАЗ:$?"
    [ "$out" = "ЖИВ:[]" ] && ok "$fn отдаёт пустую строку вместо смерти" \
        || bad "$fn роняет прогон на усечённом конфиге" "вернулось «$out»"
    # И существующий ключ обязан читаться по-прежнему
    printf 'PrivateKey = aGVsbG8=\n' > "$conf"
    out="$(bash -c "set -euo pipefail
$EK
        echo \"[\$($fn '$conf')]\"" 2>&1)" || out="ОТКАЗ"
    [ "$out" = "[aGVsbG8=]" ] && ok "$fn читает существующий ключ" \
        || bad "$fn сломал чтение ключа" "вышло «$out»"
done

# ═══════════════════════════════════════════════════════════════════════════
head_ "9. Определение адреса доезжает до запасного варианта"
# Правый операнд || — последняя команда списка, поэтому set -e срабатывает на
# ней в полную силу: отказ ip обрывал скрипт, не доходя до api.ipify.org ниже.
HL="$(grep -F 'h="$(ip route get' overlay/bin/client-awg.sh)"
if [ -z "$HL" ]; then
    bad "не нашли определение адреса в client-awg.sh" "мерить нечего"
else
    out="$(bash -c "set -euo pipefail
        ip() { return 2; }
        h=''
$HL
        echo \"ЖИВ:[\$h]\"" 2>/dev/null)" || out="ОТКАЗ:$?"
    [ "$out" = "ЖИВ:[]" ] && ok "отказ ip не обрывает выдачу клиента" \
        || bad "выдача клиента умирает на определении адреса" "вернулось «$out»"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "10. Пароль архива доезжает до openssl"
# openssl читает пароль ИЗ ОКРУЖЕНИЯ (-pass env:…), а read создаёт обычную
# переменную оболочки. Без export введённый с клавиатуры ВЕРНЫЙ пароль давал
# «неверный пароль или битый архив»: интерактивное восстановление
# зашифрованного архива не работало никогда.
if sed -n '/read -rsp "Пароль архива/,+12p' overlay/bin/awg-backup.sh | grep -q 'export BACKUP_PASS'; then
    ok "введённый с клавиатуры пароль уезжает в окружение"
else
    bad "пароль из read не экспортируется" "openssl его не увидит"
fi
if command -v openssl >/dev/null 2>&1; then
    W2="$WORK/enc"; mkdir -p "$W2"; echo "PrivateKey = SECRET" > "$W2/a"
    ( export BACKUP_PASS=hunter2
      openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
          -in "$W2/a" -out "$W2/a.enc" -pass env:BACKUP_PASS 2>/dev/null )
    # Так выглядит переменная после read: обычная, не экспортированная.
    out="$(bash -c "BACKUP_PASS=hunter2
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
            -in '$W2/a.enc' -out '$W2/a.dec' -pass env:BACKUP_PASS 2>&1" || true)"
    case "$out" in
        *"No environment variable"*) ok "и без export openssl её действительно не видит" ;;
        *) bad "проверка не воспроизвела причину" "вышло «$out»" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "11. Проверка MTU стоит на вводе, а не на сохранённом значении"
# Разница принципиальная. На ввод человека проверка обязана быть: `--mtu 60`
# опускал потолок джанка ниже Jmin. А на значение из services.env её ставить
# НЕЛЬЗЯ — оно приезжает в awg-obfuscation.sh на каждом прогоне, включая
# --reapply: отказ сломал бы --update работающему серверу, а тихая подмена
# поменяла бы ему MTU и MTU в клиентских конфигах.
if grep -q '576' install.sh && grep -q '1500' install.sh; then
    ok "установщик проверяет диапазон введённого MTU"
else
    bad "в установщике нет диапазона MTU" "--mtu 60 снова доедет до генератора"
fi
if grep -q 'вне диапазона 576-1500' install.sh; then
    ok "и говорит, что взял вместо введённого"
else
    bad "подмена MTU в диалоге происходит молча"
fi

# Проверка статическая: убеждаемся, что рубежа с диапазоном там НЕТ.
for f in "$INTEG" overlay/bin/awg-obfuscation.sh; do
    if grep -v '^[[:space:]]*#' "$f" | grep -q '\-ge 576'; then
        bad "$f режет сохранённый MTU" "это сломает --update там, где значение уже записано"
    else
        ok "$f пропускает сохранённый MTU как есть"
    fi
done

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
