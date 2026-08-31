#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Приватные ключи клиентов не должны быть доступны на чтение кому попало.
#
# В клиентском .conf лежит PrivateKey клиента и PresharedKey; то же самое
# целиком повторяется в QR-.png и в vpn://-ссылке рядом. add_client создавал их
# без umask и без chmod — 0644 в каталоге 0755, — то есть читал любой локальный
# пользователь и любой скомпрометированный сервис. Ключи клиентов существуют
# ТОЛЬКО здесь (это сказано и в awg-backup.sh), поэтому утечка окончательна:
# закрыть её задним числом нельзя, можно лишь перевыпустить всех клиентов.
# Права 0644 уезжали и в tar бэкапа, то есть переселялись на новый сервер.
#
# Раздел 2 — про уже работающие серверы: новые файлы закрыты в add_client, но
# старые сами не починятся, поэтому интеграция чинит их при каждом прогоне.
# Это настоящий код, вырезанный из deploy_overlay и запущенный на стенде.
#
#   bash tests/test_secret_perms.sh

fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

CL=overlay/bin/client-awg.sh
IN=patches/antizapret-awg-integration.sh

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Путь создания закрыт до первой записи"
# Проверка структурная: полноценный стенд для add_client потребовал бы awg,
# python-экспортёр и учёт сроков, и мерил бы в основном сам стенд. Здесь важен
# порядок — umask обязан стоять ДО mkdir и до heredoc, иначе и каталог, и файл
# успевают родиться открытыми.
AC="$(sed -n '/^add_client()/,/^}$/p' "$CL")"
if [ -z "$AC" ]; then
    bad "не нашли add_client в $CL" "мерить нечего"
else
    n_umask="$(printf '%s\n' "$AC" | grep -n 'umask 077' | head -1 | cut -d: -f1)"
    n_mkdir="$(printf '%s\n' "$AC" | grep -n 'mkdir -p "$outdir"' | head -1 | cut -d: -f1)"
    n_conf="$(printf '%s\n' "$AC" | grep -n 'cat > "$conf"' | head -1 | cut -d: -f1)"
    if [ -z "$n_umask" ]; then
        bad "в add_client нет umask 077" "профили родятся 0644 — ключи прочтёт любой локальный пользователь"
    elif [ -n "$n_mkdir" ] && [ "$n_umask" -lt "$n_mkdir" ]; then
        ok "umask 077 стоит до создания каталога"
    else
        bad "umask 077 стоит после mkdir" "каталог клиентов останется проходным для всех"
    fi
    if [ -n "$n_umask" ] && [ -n "$n_conf" ] && [ "$n_umask" -lt "$n_conf" ]; then
        ok "…и до записи профиля"
    else
        bad "umask 077 не предшествует записи профиля" "файл родится 0644"
    fi
    printf '%s\n' "$AC" | grep -q 'chmod 600 "$conf"' \
        && ok "профиль закрывается явным chmod 600" \
        || bad "нет chmod 600 на профиле" "umask спасает только новый файл, но не перезапись поверх старого"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Уже выданные конфиги чинятся на работающем сервере"
# Вырезаем настоящий блок починки из deploy_overlay и гоняем его на стенде,
# собранном ровно так, как выглядит сервер прежних версий.
FIX="$(sed -n '/^    if \[ -d "\$DEST\/clients" \]; then$/,/^    fi$/p' "$IN")"
if [ -z "$FIX" ]; then
    bad "не нашли блок починки прав в $IN" "старые серверы останутся с 0644"
else
    D="$WORK/dest"
    mkdir -p "$D/clients/antizapret" "$D/clients/vpn3"
    printf '[Interface]\nPrivateKey = SECRET\n' > "$D/clients/antizapret/antizapret-bob-am.conf"
    printf 'PNG'  > "$D/clients/antizapret/antizapret-bob.png"
    printf 'vpn://' > "$D/clients/vpn3/vpn3-eve.vpn"
    printf 'x' > "$D/expiry.tsv"          # не секрет и не в clients — трогать нельзя
    chmod 755 "$D/clients" "$D/clients/antizapret" "$D/clients/vpn3"
    chmod 644 "$D"/clients/*/* "$D/expiry.tsv"

    ( set -euo pipefail
      # shellcheck disable=SC2034  # DEST читает вырезанный блок через eval
      DEST="$D"
      err() { printf 'ERR %s\n' "$*"; }
      eval "$FIX" ) > "$WORK/fix.log" 2>&1 || bad "блок починки упал" "$(cat "$WORK/fix.log")"

    m() { stat -c '%a' "$1" 2>/dev/null || echo '?'; }
    [ "$(m "$D/clients")" = 700 ] \
        && ok "каталог clients стал 700" || bad "clients остался $(m "$D/clients")"
    [ "$(m "$D/clients/antizapret")" = 700 ] \
        && ok "подкаталог сервиса стал 700" || bad "подкаталог остался $(m "$D/clients/antizapret")"
    bad_files=""
    for f in "$D"/clients/*/*; do
        [ "$(m "$f")" = 600 ] || bad_files="$bad_files $(basename "$f"):$(m "$f")"
    done
    [ -z "$bad_files" ] \
        && ok "все выданные файлы стали 600 (.conf, QR, vpn://)" \
        || bad "остались открытыми:$bad_files" "приватные ключи клиентов читает любой локальный пользователь"
    [ "$(m "$D/expiry.tsv")" = 644 ] \
        && ok "и ничего за пределами clients не тронуто" \
        || bad "починка вышла за clients: expiry.tsv стал $(m "$D/expiry.tsv")"
    [ -s "$WORK/fix.log" ] \
        && bad "починка что-то сказала на исправном стенде" "$(cat "$WORK/fix.log")" \
        || ok "и сделала это молча"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Архив закрыт с первой секунды, а не после упаковки"
# В архиве приватный ключ CA OpenVPN, ключи серверных интерфейсов и приватные
# ключи ВСЕХ клиентов. `chmod 600` ПОСЛЕ tar оставляет окно на всё время
# упаковки — на сотне клиентов это десятки секунд, — и открывший файл в этом
# окне дочитывает его до конца уже после chmod. --encrypt не спасает: он
# шифрует уже созданный открытый файл.
#
# Проверка структурная намеренно: само окно ловится только гонкой, а она в
# наборе была бы плавающей. Здесь фиксируется решение, которое окно закрывает.
BK=overlay/bin/awg-backup.sh
n_umask="$(grep -n '^[[:space:]]*umask 077' "$BK" | head -1 | cut -d: -f1)"
n_tar="$(grep -n '^[[:space:]]*tar -czf' "$BK" | head -1 | cut -d: -f1)"
if [ -z "$n_tar" ]; then
    bad "не нашли упаковку в $BK" "мерить нечего"
elif [ -z "$n_umask" ]; then
    bad "в $BK нет umask" "архив со всеми ключами создаётся с правами по умолчанию"
elif [ "$n_umask" -lt "$n_tar" ]; then
    ok "umask 077 стоит до упаковки (строка $n_umask против $n_tar)"
else
    bad "umask идёт после упаковки" "окно на всё время tar остаётся открытым"
fi
grep -q 'chmod 600 "$out"' "$BK" \
    && ok "и права закрепляются явно после" \
    || bad "нет chmod 600 на архиве" "umask не спасёт при перезаписи существующего файла"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Починка идёт на КАЖДОМ прогоне, а не только при установке"
# Если бы она стояла под условием «первая установка», работающие серверы
# остались бы с прежними правами навсегда — а именно они и пострадали.
DO="$(sed -n '/^deploy_overlay()/,/^}$/p' "$IN")"
case "$DO" in
    *'$DEST/clients'*) ok "блок починки лежит в deploy_overlay" ;;
    *) bad "починки в deploy_overlay нет" "старые серверы не вылечатся" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit "$fail"
