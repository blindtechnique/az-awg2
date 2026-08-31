#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-doctor.sh — самопроверка слоя AmneziaWG поверх AntiZapret.
#
#   awg-doctor              # быстрые проверки (секунды)
#   awg-doctor --deep       # + реальный клиент в network namespace и трафик
#   awg-doctor --json       # машинно-читаемо (для бота)
#
# Зачем: обычная беда — «клиент не подключается», а причина где-то между
# профилем обфускации, портом, NAT ванили и MTU. Скрипт проходит цепочку
# сверху вниз и говорит, на каком звене рвётся.
#
# --deep поднимает временный netns со своим клиентом, гоняет через туннель
# трафик и всё за собой убирает. Ничего в рабочей конфигурации не меняет.
set -uo pipefail

AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
DEST=/opt/antizapret-awg
DEEP=0; JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deep) DEEP=1; shift ;;
        --json) JSON=1; shift ;;
        # Справка — это шапка файла, а не диапазон строк: жёсткие номера не
        # знают, где она кончилась, и ошибаются молча в обе стороны.
        -h|--help) awk 'NR==1||/^# *SPDX-/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

PROBLEMS=0
declare -a REPORT=()

ok()   { REPORT+=("OK|$1"); [ "$JSON" = 1 ] || printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
# Второй аргумент — объяснение: что именно это значит и что делать. Раньше он
# принимался и молча выбрасывался, хотя пять вызовов в этом файле его передают.
# В REPORT клеится к той же строке через тире: бот разбирает отчёт по трём
# известным префиксам, и новый статус сломал бы ему разметку.
bad()  {
    local m="$1"
    [ $# -gt 1 ] && m="$1 — $2"
    REPORT+=("FAIL|$m"); PROBLEMS=$((PROBLEMS+1))
    if [ "$JSON" != 1 ]; then
        printf '  \033[1;31m✗\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '      %s\n' "$2"
    fi
    return 0
}
warn() {
    local m="$1"
    [ $# -gt 1 ] && m="$1 — $2"
    REPORT+=("WARN|$m")
    if [ "$JSON" != 1 ]; then
        printf '  \033[1;33m!\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '      %s\n' "$2"
    fi
    return 0
}
# заголовок секции попадает и в JSON: бот рисует по нему структуру,
# иначе в чат приезжает плоская простыня без разделов
head_() { REPORT+=("SECTION|$1"); [ "$JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── оборванные операции ─────────────────────────────────────────────────────
# Стоит ПЕРЕД требованием services.env: операция, убитая до копирования этого
# файла, иначе выглядела бы как «слой не установлен», и метка, объясняющая
# происходящее, не показалась бы никогда.
# Именована и закрыта `}` на своей строке — стенд вырезает её из файла sed-ом,
# как check_ports в tests/test_ports.sh.
check_marks() {
    local m found=0
    for m in "$AWG_DIR/.restore-in-progress" "$AWG_DIR/.migrate-in-progress"; do
        [ -f "$m" ] || continue
        [ "$found" = 1 ] || head_ "Оборванные операции"
        found=1
        MARK_STARTED=""; MARK_ARCHIVE=""; MARK_MODE=""
        # shellcheck disable=SC1090
        . "$m" 2>/dev/null || true
        case "$m" in
            *restore*)
                bad "восстановление не доведено до конца (начато ${MARK_STARTED:-?})"
                warn "файлы могли обновиться, а сервисы остаться на прежних —"
                warn "повтори: awg-backup restore ${MARK_ARCHIVE:-<архив>}" ;;
            *migrate*)
                bad "миграция ${MARK_MODE:-?} → parallel не доведена до конца"
                warn "повтори полный прогон установщика — он доделает начатое" ;;
        esac
    done
}
check_marks

[ -f "$SERVICES" ] || {
    echo "Слой не установлен: нет $SERVICES" >&2
    [ -f "$AWG_DIR/.restore-in-progress" ] && \
        echo "  восстановление оборвалось до копирования services.env — повтори awg-backup restore" >&2
    exit 3
}
# shellcheck disable=SC1090
. "$SERVICES"
LAYER2="${LAYER2:-1}"; LAYER3="${LAYER3:-0}"

# ── ваниль ──────────────────────────────────────────────────────────────────
head_ "Ванильный AntiZapret"
if [ -f /root/antizapret/client.sh ]; then ok "AntiZapret на месте"; else bad "нет /root/antizapret/client.sh"; fi
if systemctl is-active --quiet antizapret 2>/dev/null; then ok "antizapret.service работает"
else warn "antizapret.service не активен"; fi
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then ok "IP forwarding включён"
else bad "IP forwarding выключен"; fi

# ── интерфейсы слоёв ────────────────────────────────────────────────────────

# ── инвариант портов ────────────────────────────────────────────────────────
# Порт живёт в трёх местах сразу: в services.env (объявленный), в серверном
# конфиге (ListenPort) и в каждом выданном клиенте (Endpoint). Разъехаться они
# могут молча: правка конфига руками, оборванная миграция, перенос сервера. И
# тогда «порт не слушается» — это следствие, а не причина, а лечится оно
# переизданием клиентских конфигов, а не перезапуском сервиса.
# Порт годен, если это число из 1..65535. Вынесено, потому что сравнивать
# приходится в трёх местах, и `[ "$p" -gt 0 ]` на нечисле ещё и ругается.
valid_port() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Порт в Endpoint у выданных конфигов. Проверяется САМ ПО СЕБЕ, без сверки с
# объявленным: значение вне 1..65535 недействительно всегда и доказывается
# одним файлом. Раньше этот осмотр выключался ранним выходом из check_ports —
# то есть ровно там, где поломка гарантирована.
check_client_ports() {  # check_client_ports <каталог клиентов> <метка>
    local cldir="$1" label="$2" f ep p n=0 bad_n=0 sample=""
    [ -d "$cldir" ] || return 0
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        ep="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$ep" ] || continue
        p="${ep##*:}"
        n=$((n + 1))
        valid_port "$p" && continue
        bad_n=$((bad_n + 1))
        [ -n "$sample" ] || sample="$(basename "$f") → $ep"
    done
    [ "$bad_n" = 0 ] && return 0
    bad "$label: у $bad_n из $n конфигов недействительный порт ($sample)" \
        "такой конфиг не подключится никогда — переиздай клиентов после того, как порт будет объявлен"
}

check_ports() {  # check_ports <имя> <объявленный порт> <каталог клиентов> <имя переменной>
    local iface="$1" want="$2" cldir="$3" var="${4:-}"
    local conf="$AWG_DIR/${iface}.conf" got n=0 bad_n=0 sample=""
    # ДО раннего выхода: недействительный порт у клиента доказывается одним
    # файлом, и объявленное значение для этого не нужно.
    check_client_ports "$cldir" "$iface"
    if ! valid_port "$want"; then
        # «Переменной нет вовсе» и «переменная есть, но пуста или ноль» — разные
        # диагнозы. Первое бывает на установке прежних версий, доказать по нему
        # нечего. Второе — сломанный план: слой объявлен включённым, а порта у
        # него нет, и клиенты выписываются с нулевым или чужим портом.
        # [ -f ] перед grep обязателен: с пустым путём grep читает stdin и
        # прогон повисает молча — в стенде SERVICES может быть не задан.
        if [ -n "$var" ] && [ -f "${SERVICES:-}" ] && grep -q "^${var}=" "$SERVICES"; then
            bad "$iface: в services.env $var пуст или недействителен ($want)" \
                "клиенты выписываются с негодным портом — задай порт и переиздай их"
        else
            warn "порт $iface не объявлен в services.env"
        fi
        return
    fi

    got="$(sed -n 's/^ListenPort *= *//p' "$conf" 2>/dev/null | head -1 || true)"
    if [ -z "$got" ]; then
        bad "$conf: нет ListenPort — интерфейс не поднимется"
    elif [ "$got" != "$want" ]; then
        bad "$iface: в services.env порт $want, в конфиге $got" \
            "клиенты стучатся по одному из них, сервер слушает другой"
    else
        ok "$iface: порт в конфиге совпадает с объявленным ($want)"
    fi

    [ -d "$cldir" ] || return 0
    local f ep
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        # Endpoint = host:port — порт это хвост после последнего двоеточия,
        # так что IPv6-адрес в скобках он тоже переживёт.
        ep="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        ep="${ep##*:}"
        [ -n "$ep" ] && [ "$ep" != "$want" ] && {
            bad_n=$((bad_n + 1))
            [ -n "$sample" ] || sample="$(basename "$f") → $ep"
        }
    done
    if [ "$n" = 0 ]; then
        :
    elif [ "$bad_n" = 0 ]; then
        ok "$iface: у всех $n выданных конфигов Endpoint на порт $want"
    else
        bad "$iface: у $bad_n из $n конфигов Endpoint на чужой порт ($sample)" \
            "этим клиентам нужно раздать конфиги заново — перезапуск не поможет"
    fi
}


# Объявленный адрес — из живого файла ванили, как его берут client-awg.sh и
# бот. НЕ из $AWG_DIR/server_host: тот приезжает из архива и после переноса
# содержит адрес старой машины — сверка молчала бы ровно тогда, когда нужна.
AZ_HOST="$( [ -f /root/antizapret/setup ] && . /root/antizapret/setup 2>/dev/null; printf '%s' "${WIREGUARD_HOST:-}" )"

# ── хост в выданных конфигах ────────────────────────────────────────────────
# Endpoint пишется ровно в одном месте (add_client) и всегда из единственного
# объявленного хоста. Значит несовпадение — всегда настоящее расхождение, и
# сверка эта не ходит в сеть: файл против файла, без ложных тревог за NAT.
# regen-all его НЕ чинит: он правит только строки обфускации, сохраняя ключи,
# IP и peer, — поэтому в подсказке сказано «раздать заново», а не «пересобрать».
ep_host() {  # ep_host <строка Endpoint без имени поля>
    local e="$1"
    case "$e" in
        "[""$"*|"["*) e="${e#[}"; printf '%s' "${e%%]*}"; return ;;
    esac
    # хост — всё до ПОСЛЕДНЕГО двоеточия; без двоеточий вся строка (битый
    # Endpoint без порта тоже надо увидеть, а не молча принять за хост)
    case "$e" in
        *:*) printf '%s' "${e%:*}" ;;
        *)   printf '%s' "$e" ;;
    esac
}
# Скобки снимаются с ОБЕИХ сторон: ep_host отдаёт адрес уже без них, а
# объявленное значение может быть записано и так, и так — иначе одна и та
# же машина выглядела бы расхождением сама с собой.
norm_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/\.$//; s/^\[//; s/\]$//'; }

check_client_hosts() {  # check_client_hosts <объявленный хост> <каталог> <метка>
    local cldir="$2" label="$3" f raw h n=0 diff_n=0 sample="" broken=0
    local want; want="$(norm_host "$1")"
    [ -d "$cldir" ] || return 0
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        raw="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$raw" ] || continue          # нет Endpoint — не наш файл
        h="$(norm_host "$(ep_host "$raw")")"
        if [ -z "$h" ]; then
            bad "$(basename "$f"): в Endpoint нет адреса сервера ($raw)" \
                "этот конфиг не подключится ни при каких настройках"
            broken=$((broken + 1))
            continue
        fi
        n=$((n + 1))
        [ -n "$want" ] || continue          # объявленного нет — сравнивать не с чем
        if [ "$h" != "$want" ]; then
            diff_n=$((diff_n + 1))
            [ -n "$sample" ] || sample="$(basename "$f") → $h"
        fi
    done
    [ "$n" = 0 ] && return 0
    if [ -z "$want" ]; then
        [ "$broken" = 0 ] && return 0
        return 0
    fi
    if [ "$diff_n" = 0 ]; then
        ok "$label: у всех $n конфигов Endpoint на $want"
    else
        warn "$label: $diff_n из $n конфигов выданы на другой адрес ($sample), объявлен $want"
        warn "  этим клиентам надо раздать конфиги заново — regen-all адрес не меняет"
    fi
}


# ── ключи и пиры ────────────────────────────────────────────────────────────
# Приватный ключ клиента есть ТОЛЬКО в его конфиге, публичный — в [Peer]
# серверного. Пара пишется не атомарно (три отдельные записи в add_client, две
# в del_client), поэтому расхождение достижимо обрывом, а не только переносом.
# Сверка идёт по КЛЮЧУ, а не по адресу: next_ip переиспользует освободившиеся
# адреса, и сверка по AllowedIPs дала бы ложное зелёное.
# ── застрявшие параметры 3.0 ────────────────────────────────────────────────
# Сверка файла с файлом, без демона: если профиль не объявляет header
# protection, а рядом с конфигом лежит .v3 с ключом, значит .v3 остался от
# прежнего профиля. Датапас применит его на ExecStartPost, и сервер разойдётся
# со всеми выданными конфигами.
check_v3_stale() {  # check_v3_stale <путь .v3> <объявлена ли в профиле> <пресет>
    local v3f="$1" want="$2" preset="$3"
    [ -f "$v3f" ] || return 0
    grep -q '^header_protection_key=' "$v3f" 2>/dev/null || return 0
    [ "$want" = 1 ] && return 0
    bad "$v3f содержит header_protection_key, а профиль $preset его не объявляет" \
        "файл остался от прежнего профиля — примени текущий заново: awg-obfuscation --v3 --apply"
}

# ── MTU в выданных конфигах ─────────────────────────────────────────────────
# regen-all MTU НЕ меняет (он правит только строки обфускации), поэтому после
# смены MTU выданные конфиги молча остаются на прежнем. Вред тише, чем у порта:
# соединение встаёт, мелкие запросы ходят, а крупные пакеты пропадают.
check_client_mtu() {  # check_client_mtu <объявленный MTU> <каталог> <метка>
    local want="$1" cldir="$2" label="$3" f got n=0 diff_n=0 sample=""
    [ -n "$want" ] || return 0            # не объявлен — сравнивать не с чем
    [ -d "$cldir" ] || return 0
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        got="$(sed -n 's/^MTU *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$got" ] || continue         # в конфиге нет MTU — не наш случай
        n=$((n + 1))
        [ "$got" = "$want" ] && continue
        diff_n=$((diff_n + 1))
        [ -n "$sample" ] || sample="$(basename "$f") → $got"
    done
    [ "$n" = 0 ] && return 0
    if [ "$diff_n" = 0 ]; then
        ok "$label: у всех $n конфигов MTU $want"
    else
        warn "$label: у $diff_n из $n конфигов другой MTU ($sample), объявлен $want" \
             "мелкие запросы ходят, крупные пропадают — раздай конфиги заново, regen-all MTU не меняет"
    fi
}

# ── живой интерфейс против конфига ──────────────────────────────────────────
# check_peers сверяет файлы между собой. Здесь — файл против ЯДРА: на диске
# может быть всё согласовано, а интерфейс поднят из прежнего состояния. Так
# выглядит «конфиг переписали, а awg setconf не сделали», и именно это остаётся
# после восстановления, убитого между копированием файлов и перезапуском.
check_live() {  # check_live <имя интерфейса> <серверный конфиг>
    local i="$1" conf="$2"
    [ -f "$conf" ] || return 0
    command -v awg >/dev/null 2>&1 || return 0
    ip link show "$i" >/dev/null 2>&1 || return 0   # не поднят — сказала check_iface

    local live_pub disk_priv disk_pub
    live_pub="$(awg show "$i" public-key 2>/dev/null || true)"
    disk_priv="$(sed -n 's/^PrivateKey *= *//p' "$conf" 2>/dev/null | head -1 || true)"
    disk_pub=""
    [ -n "$disk_priv" ] && disk_pub="$(printf '%s' "$disk_priv" | awg pubkey 2>/dev/null || true)"
    if [ -n "$live_pub" ] && [ -n "$disk_pub" ]; then
        if [ "$live_pub" = "$disk_pub" ]; then
            ok "$i: интерфейс поднят из нынешнего конфига"
        else
            bad "$i: интерфейс работает по ДРУГОМУ ключу, чем в $conf" \
                "конфиг переписан, а интерфейс не перезапущен — клиенты по нему не сойдутся"
        fi
    fi

    local live_peers conf_peers p n_only_conf=0 n_only_live=0
    live_peers="$(awg show "$i" peers 2>/dev/null | tr '\n' ' ' || true)"
    conf_peers="$(sed -n 's/^PublicKey *= *//p' "$conf" 2>/dev/null | tr '\n' ' ' || true)"
    for p in $conf_peers; do
        case " $live_peers " in
            *" $p "*) ;;
            *) n_only_conf=$((n_only_conf + 1)) ;;
        esac
    done
    for p in $live_peers; do
        case " $conf_peers " in
            *" $p "*) ;;
            *) n_only_live=$((n_only_live + 1)) ;;
        esac
    done
    if [ "$n_only_conf" != 0 ]; then
        bad "$i: $n_only_conf пиров есть в конфиге, но не загружены в интерфейс" \
            "эти клиенты не подключатся до перезапуска: systemctl restart на юните слоя"
    fi
    if [ "$n_only_live" != 0 ]; then
        warn "$i: $n_only_live пиров загружены в интерфейс, но их нет в конфиге" \
             "доступ переживёт только до перезапуска — добавь их в конфиг или убери"
    fi
    [ "$n_only_conf" = 0 ] && [ "$n_only_live" = 0 ] && [ -n "$conf_peers$live_peers" ] \
        && ok "$i: пиры в ядре и в конфиге совпадают"
    return 0
}

# ── копия параметров для датапаса ───────────────────────────────────────────
# <iface>.env пишет установщик, а читает датапас, поднимая интерфейс. Если она
# разошлась с services.env, датапас настроит интерфейс по своей копии, а весь
# остальной проект будет считать иначе — и никто об этом не скажет.
check_iface_env() {  # check_iface_env <иф> <подсеть> <порт> <mtu> <wan>
    local i="$1" want_sub="$2" want_port="$3" want_mtu="$4" want_wan="$5"
    local f="$AWG_DIR/${i}.env" got nat
    if [ ! -f "$f" ]; then
        # Раньше здесь стоял молчаливый возврат с объяснением «нет файла —
        # датапас и не работает». Объяснение было неверным: датапас стартует,
        # просто теряет параметры интерфейса. Уровень здесь ниже, чем в awg3:
        # NAT у этого датапаса выключен по умолчанию, за него отвечает ваниль,
        # поэтому связность обычно сохраняется — но файл всё равно пропал.
        if [ -f "$AWG_DIR/${i}.conf" ]; then
            warn "$i: нет $f — датапас не узнает подсеть и порт" \
                 "параметры интерфейса потеряны; пересоздаётся полным прогоном установщика"
        fi
        return 0
    fi
    _fld() { sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1 || true; }
    nat="$(_fld NAT)"

    got="$(_fld SUBNET)"
    if [ -n "$got" ] && [ -n "$want_sub" ] && [ "$got" != "${want_sub}.0/24" ]; then
        if [ "${nat:-0}" = 1 ]; then
            bad "$i: в $f подсеть $got, а объявлена ${want_sub}.0/24" \
                "MASQUERADE встанет на чужой диапазон — клиенты подключатся, интернета не увидят"
        else
            warn "$i: в $f подсеть $got, а объявлена ${want_sub}.0/24" \
                 "сейчас копия инертна (NAT=0, за него отвечает ваниль), но она устарела"
        fi
    fi

    got="$(_fld PORT)"
    if [ -n "$got" ] && [ -n "$want_port" ] && [ "$got" != "$want_port" ]; then
        bad "$i: в $f порт $got, а объявлен $want_port" \
            "интерфейс слушает не там, куда стучатся выданные конфиги"
    fi

    got="$(_fld MTU)"
    if [ -n "$got" ] && [ -n "$want_mtu" ] && [ "$got" != "$want_mtu" ]; then
        warn "$i: в $f MTU $got, а объявлен $want_mtu" \
             "интерфейс поднимется с чужим MTU — крупные пакеты будут пропадать"
    fi

    got="$(_fld WAN)"
    if [ -n "$got" ] && [ -n "$want_wan" ] && [ "$got" != "$want_wan" ]; then
        bad "$i: в $f внешний интерфейс $got, а объявлен $want_wan" \
            "MASQUERADE встанет на чужой выход — трафик клиентов наружу не пойдёт"
    fi
    return 0
}

# ── план против того, что лежит на диске ────────────────────────────────────
# LAYER2/LAYER3 читаются с умолчанием, поэтому обрезанный services.env
# объявляет слой выключенным — и все проверки по нему пропускаются молча, а
# внизу печатается «проблем не найдено». Сверка чисто файловая: «слой выключен,
# а его файлы на месте» доказывается двумя файлами и законного прочтения не
# имеет — либо план неполон, либо слой сняли не до конца.
check_plan() {  # check_plan <включён ли> <имя интерфейса> <каталог клиентов> <метка>
    local on="$1" iface="$2" cldir="$3" label="$4" what=""
    [ "$on" = 1 ] && return 0
    [ -f "$AWG_DIR/${iface}.conf" ] && what="$what конфиг"
    [ -f "$AWG_DIR/${iface}.env" ] && what="$what .env"
    [ -f "$AWG_DIR/${iface}.v3" ] && what="$what .v3"
    [ -n "$(ls -A "$cldir" 2>/dev/null || true)" ] && what="$what каталог клиентов"
    [ -n "$what" ] || return 0
    # Шапка печатается только при находке — как у check_marks. Иначе пустой
    # раздел висел бы на каждом исправном сервере.
    [ "${_plan_head:-0}" = 1 ] || { head_ "План против диска"; _plan_head=1; }
    bad "$label: слой объявлен выключенным, но его файлы на месте —$what" \
        "по нему не делается НИ ОДНА проверка: либо services.env неполон, либо слой сняли не до конца"
}

check_peers() {  # check_peers <серверный конфиг> <каталог клиентов> <метка>
    local conf="$1" cldir="$2" label="$3"
    [ -f "$conf" ] || return 0
    [ -d "$cldir" ] || return 0
    command -v awg >/dev/null 2>&1 || { warn "$label: нет awg — пары ключей не сверялись"; return 0; }

    local srv_priv srv_pub peers f cpriv cpub addr
    srv_priv="$(sed -n 's/^PrivateKey *= *//p' "$conf" 2>/dev/null | head -1 || true)"
    srv_pub=""
    [ -n "$srv_priv" ] && srv_pub="$(printf '%s' "$srv_priv" | awg pubkey 2>/dev/null || true)"
    peers="$(sed -n 's/^PublicKey *= *//p' "$conf" 2>/dev/null | tr '\n' ' ' || true)"

    local n=0 lost=0 lost_s="" wrongsrv=0 wrongsrv_s="" seen="" dup=0 dup_s="" matched=""
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        cpriv="$(sed -n 's/^PrivateKey *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$cpriv" ] || continue          # чужой файл — не наш формат
        cpub="$(printf '%s' "$cpriv" | awg pubkey 2>/dev/null || true)"
        [ -n "$cpub" ] || continue           # ключ не выводится — молчим, доказать нечем
        n=$((n + 1))
        case " $peers " in
            *" $cpub "*) matched="$matched $cpub" ;;
            *) lost=$((lost + 1)); [ -n "$lost_s" ] || lost_s="$(basename "$f")" ;;
        esac
        # Ключ сервера в [Peer] клиента: несовпадение делает handshake
        # невозможным, и законного состояния у него нет.
        if [ -n "$srv_pub" ]; then
            local cs
            cs="$(sed -n 's/^PublicKey *= *//p' "$f" 2>/dev/null | head -1 || true)"
            if [ -n "$cs" ] && [ "$cs" != "$srv_pub" ]; then
                wrongsrv=$((wrongsrv + 1))
                [ -n "$wrongsrv_s" ] || wrongsrv_s="$(basename "$f")"
            fi
        fi
        addr="$(sed -n 's/^Address *= *//p' "$f" 2>/dev/null | head -1 || true)"
        addr="${addr%%,*}"
        if [ -n "$addr" ]; then
            case " $seen " in
                *" $addr "*) dup=$((dup + 1)); [ -n "$dup_s" ] || dup_s="$addr" ;;
                *) seen="$seen $addr" ;;
            esac
        fi
    done
    # Ноль клиентских файлов — НЕ повод молчать: если в конфиге есть пиры, это
    # и есть худший случай. Поэтому ранний возврат снят, а отчёты о клиентах
    # просто пропускаются, когда клиентов нет.
    if [ "$n" != 0 ]; then
    if [ "$lost" = 0 ]; then
        ok "$label: все $n клиентов есть среди пиров сервера"
    else
        bad "$label: у $lost из $n клиентов ключа нет среди пиров ($lost_s)" \
            "эти конфиги выданы, но сервер их не примет — заведи клиентов заново"
    fi
    if [ "$wrongsrv" != 0 ]; then
        bad "$label: у $wrongsrv из $n конфигов чужой ключ сервера ($wrongsrv_s)" \
            "handshake невозможен: ключ сервера сменился, а конфиги несут прежний"
    fi
    if [ "$dup" != 0 ]; then
        bad "$label: $dup конфигов делят адрес с другим клиентом ($dup_s)" \
            "следующий выданный клиент заберёт маршрут у работающего"
    fi
    fi
    # Пир без клиентского файла — доступ, который нельзя отозвать по имени.
    local p orphan=0
    for p in $peers; do
        case " $matched " in *" $p "*) ;; *) orphan=$((orphan + 1)) ;; esac
    done
    if [ "$orphan" != 0 ] && [ "$n" = 0 ]; then
        # Пустой каталог при непустом конфиге: у людей на руках рабочие
        # конфиги, сервер их принимает, а владелец не видит ни одного имени.
        # «Пир мог быть заведён руками» объясняет одну-две штуки, но не это.
        bad "$label: в конфиге $orphan пиров, а клиентских файлов нет ни одного" \
            "доступ у людей на руках, отозвать его по имени нечем — так выглядит восстановление из архива без клиентских ключей"
    elif [ "$orphan" != 0 ]; then
        warn "$label: $orphan пиров без клиентского файла — доступ есть, отозвать по имени нечем"
    fi
}

check_iface() {  # check_iface <имя> <порт> <слой>
    local i="$1" p="$2" layer="$3" unit
    [ "$layer" = 3 ] && unit="awg3@$i" || unit="awg-quick@$i"
    if ip link show "$i" >/dev/null 2>&1; then
        ok "$i поднят ($(ip -4 -br addr show "$i" | awk '{print $3}'))"
    else
        bad "$i отсутствует — journalctl -u $unit"
        return
    fi
    if systemctl is-active --quiet "$unit"; then ok "$unit активен"; else bad "$unit не активен"; fi
    # Поле берём с конца, а не по номеру: `ss -lunH` печатает колонку Netid не
    # на всех версиях iproute2, и «четвёртая» верна лишь в одной раскладке.
    # Локальный адрес — предпоследнее поле в любой. Так же считает busy_ports.
    # grep -q оставлен сознательно: вывод ss короткий, в буфер трубы влезает,
    # и SIGPIPE тут не случается — а файл к тому же идёт без set -e.
    # Про недействительный порт уже сказала check_ports, и сказала точнее:
    # «порт 0 не слушается» уводит перезапускать сервис, тогда как чинить надо
    # объявление порта и переиздание конфигов.
    if valid_port "$p"; then
        if ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -qE ":$p\$"; then ok "порт $p слушается"
        else bad "порт $p не слушается"; fi
    fi
    local peers; peers="$(awg show "$i" peers 2>/dev/null | grep -c . || true)"
    ok "$i: клиентов $peers"
}

check_plan "$LAYER2" "${AZ_IFACE:-antizapret-awg}" "$DEST/clients/antizapret" "${AZ_IFACE:-antizapret-awg}"
check_plan "$LAYER2" "${VPN_IFACE:-vpn-awg}" "$DEST/clients/vpn" "${VPN_IFACE:-vpn-awg}"
check_plan "$LAYER3" "${AZ3_IFACE:-antizapret-awg3}" "$DEST/clients/antizapret3" "${AZ3_IFACE:-antizapret-awg3}"
check_plan "$LAYER3" "${VPN3_IFACE:-vpn-awg3}" "$DEST/clients/vpn3" "${VPN3_IFACE:-vpn-awg3}"
if [ "$LAYER2" = 1 ]; then
    head_ "Слой AmneziaWG 2.0 (kernel-модуль)"
    if modinfo amneziawg >/dev/null 2>&1; then ok "модуль amneziawg собран"
    else bad "модуль amneziawg недоступен — dkms status"; fi
    check_iface "${AZ_IFACE:-antizapret-awg}" "${AZ_PORT:-0}" 2
    check_iface "${VPN_IFACE:-vpn-awg}" "${VPN_PORT:-0}" 2
    check_live "${AZ_IFACE:-antizapret-awg}" "$AWG_DIR/${AZ_IFACE:-antizapret-awg}.conf"
    check_live "${VPN_IFACE:-vpn-awg}" "$AWG_DIR/${VPN_IFACE:-vpn-awg}.conf"
    # check_iface_env здесь НЕ зовётся, и это не упущение. <iface>.env читает
    # userspace-датапас, а у слоя 2.0 его нет: он идёт на kernel-модуле под
    # awg-quick@, который берёт всё из .conf. Пишет этот файл только
    # build_iface3, поэтому у интерфейсов 2.0 его не бывает ни на одном
    # исправном сервере — и проверка, заданная им, жаловалась на всех подряд.
    check_ports "${AZ_IFACE:-antizapret-awg}" "${AZ_PORT:-}" "$DEST/clients/antizapret" AZ_PORT
    check_ports "${VPN_IFACE:-vpn-awg}" "${VPN_PORT:-}" "$DEST/clients/vpn" VPN_PORT
    check_client_hosts "$AZ_HOST" "$DEST/clients/antizapret" "${AZ_IFACE:-antizapret-awg}"
    check_client_hosts "$AZ_HOST" "$DEST/clients/vpn" "${VPN_IFACE:-vpn-awg}"
    check_peers "$AWG_DIR/${AZ_IFACE:-antizapret-awg}.conf" "$DEST/clients/antizapret" "${AZ_IFACE:-antizapret-awg}"
    check_peers "$AWG_DIR/${VPN_IFACE:-vpn-awg}.conf" "$DEST/clients/vpn" "${VPN_IFACE:-vpn-awg}"
    check_client_mtu "${MTU:-}" "$DEST/clients/antizapret" "${AZ_IFACE:-antizapret-awg}"
    check_client_mtu "${MTU:-}" "$DEST/clients/vpn" "${VPN_IFACE:-vpn-awg}"
fi

if [ "$LAYER3" = 1 ]; then
    head_ "Слой AmneziaWG 3.0 (userspace)"
    if command -v amneziawg-go >/dev/null 2>&1; then ok "amneziawg-go установлен"
    else bad "нет amneziawg-go"; fi
    check_iface "${AZ3_IFACE:-antizapret-awg3}" "${AZ3_PORT:-0}" 3
    check_iface "${VPN3_IFACE:-vpn-awg3}" "${VPN3_PORT:-0}" 3
    check_live "${AZ3_IFACE:-antizapret-awg3}" "$AWG_DIR/${AZ3_IFACE:-antizapret-awg3}.conf"
    check_live "${VPN3_IFACE:-vpn-awg3}" "$AWG_DIR/${VPN3_IFACE:-vpn-awg3}.conf"
    check_iface_env "${AZ3_IFACE:-antizapret-awg3}" "${AZ3_SUBNET:-}" "${AZ3_PORT:-}" "" ""
    check_iface_env "${VPN3_IFACE:-vpn-awg3}" "${VPN3_SUBNET:-}" "${VPN3_PORT:-}" "" ""
    check_ports "${AZ3_IFACE:-antizapret-awg3}" "${AZ3_PORT:-}" "$DEST/clients/antizapret3" AZ3_PORT
    check_ports "${VPN3_IFACE:-vpn-awg3}" "${VPN3_PORT:-}" "$DEST/clients/vpn3" VPN3_PORT
    check_client_hosts "$AZ_HOST" "$DEST/clients/antizapret3" "${AZ3_IFACE:-antizapret-awg3}"
    check_client_hosts "$AZ_HOST" "$DEST/clients/vpn3" "${VPN3_IFACE:-vpn-awg3}"
    check_peers "$AWG_DIR/${AZ3_IFACE:-antizapret-awg3}.conf" "$DEST/clients/antizapret3" "${AZ3_IFACE:-antizapret-awg3}"
    check_peers "$AWG_DIR/${VPN3_IFACE:-vpn-awg3}.conf" "$DEST/clients/vpn3" "${VPN3_IFACE:-vpn-awg3}"
    check_client_mtu "${MTU3:-}" "$DEST/clients/antizapret3" "${AZ3_IFACE:-antizapret-awg3}"
    check_client_mtu "${MTU3:-}" "$DEST/clients/vpn3" "${VPN3_IFACE:-vpn-awg3}"
    # Параметры 3.0 живут только в памяти демона — спрашиваем через UAPI.
    # Но их отсутствие само по себе НЕ поломка: пресеты router и low объявлены
    # без header protection, паддинга и таймингов. Раньше доктор в обоих случаях
    # писал «параметры 3.0 не применены», и владелец исправного сервера шёл
    # искать несуществующую проблему. Поэтому сначала смотрим, что за пресет.
    v3_preset="$(sed -n 's/^META_PRESET=//p' "$AWG_DIR/obfuscation3.meta" 2>/dev/null | head -1)"
    # Источник истины — ПРОФИЛЬ, а не имя пресета: имя это ярлык, а клиентские
    # конфиги выписываются по профилю. Решаем так же, как генератор
    # (awg-obfuscation.sh: `[ -n "${AWG_HPK_HEX:-}" ]`), иначе доктор и
    # генератор разойдутся в понимании одного и того же файла.
    hpk_want=0
    # shellcheck disable=SC1090
    if [ -n "$( . "$AWG_DIR/obfuscation3.env" 2>/dev/null || true; printf '%s' "${AWG_HPK_HEX:-}" )" ]; then
        hpk_want=1
    fi
    v3_uapi="$DEST/awg3-uapi.py"
    # Спрашиваем ОБА интерфейса. Раньше проверялся только antizapret-awg3, и
    # полный туннель мог сколько угодно работать как 2.0 — доктор молчал.
    # Бит +x не проверяем: скрипт запускается через python3, и потеря права на
    # исполнение раньше давала диагноз «параметры не применены» на пустом месте.
    v3_missing=""
    for local_i in "${AZ3_IFACE:-antizapret-awg3}" "${VPN3_IFACE:-vpn-awg3}"; do
        if [ ! -f "$v3_uapi" ]; then
            warn "нечем спросить демона: нет $v3_uapi — состояние 3.0 неизвестно"
            v3_missing=""
            break
        fi
        # «Спросить не удалось» и «ключа нет» — разные диагнозы, и чинятся они
        # по-разному. Прежде обе ситуации сваливались в одну ветку.
        v3_live="$(python3 "$v3_uapi" show "$local_i" 2>/dev/null || true)"
        if [ -z "$v3_live" ]; then
            warn "$local_i: демон не ответил по UAPI — состояние 3.0 неизвестно"
            echo "     смотри: journalctl -u awg3@$local_i -n 30 --no-pager" >&2
            continue
        fi
        case "$v3_live" in
            *header_protection_key*)
                if [ "$hpk_want" = 1 ]; then
                    ok "$local_i: header protection применена (пресет ${v3_preset:-?})"
                else
                    # Применена, хотя профиль её не объявляет: так выглядит
                    # застрявший .v3 от прежнего, более сильного профиля.
                    # Сервер ждёт header protection, клиентские конфиги выданы
                    # без неё — не сходится НИКТО. Раньше здесь печаталось ok,
                    # то есть самый разрушительный исход был зелёным.
                    bad "$local_i: header protection есть, а профиль ${v3_preset:-?} её не объявляет" \
                        "клиенты выданы без неё и не подключатся — awg-obfuscation --v3 --apply"
                fi ;;
            *) v3_missing="$v3_missing $local_i" ;;
        esac
    done
    if [ -n "$v3_missing" ]; then
        if [ "$hpk_want" = 1 ]; then
            warn "профиль ${v3_preset:-?} объявляет header protection, но её нет:${v3_missing}" \
                 "починить: awg-obfuscation --v3 --regenerate --apply"
            echo "     профиль: $AWG_DIR/obfuscation3.env (ищи AWG_HPK_HEX)" >&2
            echo "     параметры:$(for i in $v3_missing; do printf ' %s' "$AWG_DIR/$i.v3"; done)" >&2
        else
            ok "профиль ${v3_preset:-?} — без header protection, так и задумано (${v3_missing# })"
            echo "     обфускация на уровне 2.0; нужен полный набор 3.0 —" >&2
            echo "     в боте: 🛡 Обфускация → 🛠 Сменить пресет," >&2
            echo "     или руками: awg-obfuscation --v3 --preset medium --regenerate --apply" >&2
            echo "     и раздай клиентам свежие конфиги: awg-client regen-all" >&2
        fi
    fi
    # Та же сверка, но файла с файлом: работает и тогда, когда демона спросить
    # нечем, и ловит застрявший .v3 ДО перезапуска датапаса.
    for local_i in "${AZ3_IFACE:-antizapret-awg3}" "${VPN3_IFACE:-vpn-awg3}"; do
        check_v3_stale "$AWG_DIR/$local_i.v3" "$hpk_want" "${v3_preset:-?}"
    done
fi

# ── профиль обфускации ──────────────────────────────────────────────────────
head_ "Профиль обфускации"
for pair in "obfuscation.env|2.0|$LAYER2" "obfuscation3.env|3.0|$LAYER3"; do
    f="${pair%%|*}"; rest="${pair#*|}"; ver="${rest%%|*}"; on="${rest##*|}"
    [ "$on" = 1 ] || continue
    if [ -s "$AWG_DIR/$f" ]; then ok "профиль $ver есть ($f)"; else bad "нет $AWG_DIR/$f"; fi
done
# незаменённый плейсхолдер — классический признак, что обфускация не применилась
if grep -rqs '__AWG3\?_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
    # Плейсхолдер у слоёв разный, и лечить надо тот слой, где он остался:
    # awg-obfuscation без --v3 перегенерирует профиль 2.0, а конфиг 3.0 как был
    # сломан, так и останется. Поэтому смотрим, в каком именно файле нашли.
    if grep -rqs '__AWG3_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
        bad "в конфиге слоя 3.0 остался плейсхолдер обфускации — awg-obfuscation --v3 --regenerate --apply && awg-client regen-all"
    fi
    if grep -rqs '__AWG_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
        bad "в конфиге слоя 2.0 остался плейсхолдер обфускации — awg-obfuscation --regenerate --apply && awg-client regen-all"
    fi
else
    ok "плейсхолдеров в конфигах нет"
fi

# ── DNS ─────────────────────────────────────────────────────────────────────
head_ "DNS"
if [ -f /etc/knot-resolver/kresd.conf ]; then
    miss=0
    for s in "${AZ_SUBNET:-}" "${VPN_SUBNET:-}" "${AZ3_SUBNET:-}" "${VPN3_SUBNET:-}"; do
        [ -n "$s" ] || continue
        grep -q "view:addr('$s.1/24'" /etc/knot-resolver/kresd.conf && continue
        # Свой view нужен только там, где ваниль сама их держит: она описывает
        # view для split-подсетей, а для полного VPN их может не быть вовсе —
        # тогда и нам добавлять некуда, и это не проблема.
        if grep -q "view:addr('${s%.*}\." /etc/knot-resolver/kresd.conf; then
            miss=$((miss+1))
        fi
    done
    [ "$miss" = 0 ] && ok "view для подсетей слоя на месте" \
                    || warn "в kresd.conf не хватает view для $miss подсетей (awg-knot-view.sh)"
else
    warn "kresd.conf не найден — DNS-проверка пропущена"
fi

# ── глубокая проверка ───────────────────────────────────────────────────────
if [ "$DEEP" = 1 ]; then
    head_ "Проверка связности (реальный клиент)"
    NS=awgdoc$$
    TMPNAME="doctor$$"
    cleanup_deep() {
        ip netns exec "$NS" awg-quick down "$TMPNAME" >/dev/null 2>&1
        ip netns del "$NS" >/dev/null 2>&1
        ip link del "vd$$" >/dev/null 2>&1
        "$DEST/client-awg.sh" del "$TMPNAME" "$DOC_SVC" >/dev/null 2>&1
        rm -f "$AWG_DIR/$TMPNAME.conf" 2>/dev/null
    }
    trap cleanup_deep EXIT
    DOC_SVC=vpn; [ "$LAYER2" = 1 ] || DOC_SVC=vpn3
    if "$DEST/client-awg.sh" add "$TMPNAME" "$DOC_SVC" >/dev/null 2>&1; then
        ok "тестовый клиент создан ($DOC_SVC)"
        CONF="$(ls -1 /opt/antizapret-awg/clients/$DOC_SVC/*"$TMPNAME"*-am.conf 2>/dev/null | head -1)"
        [ -n "$CONF" ] || CONF="$(ls -1 /opt/antizapret-awg/clients/$DOC_SVC/*"$TMPNAME"* 2>/dev/null | head -1)"
        if [ -n "$CONF" ]; then
            ip netns add "$NS" 2>/dev/null
            ip link add "vd$$" type veth peer name vdp 2>/dev/null
            ip link set vdp netns "$NS" 2>/dev/null
            ip addr add 10.199.0.1/24 dev "vd$$" 2>/dev/null; ip link set "vd$$" up
            ip netns exec "$NS" ip link set lo up
            ip netns exec "$NS" ip addr add 10.199.0.2/24 dev vdp
            ip netns exec "$NS" ip link set vdp up
            ip netns exec "$NS" ip route add default via 10.199.0.1
            iptables -w -t nat -A POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null
            grep -v '^DNS' "$CONF" > "$AWG_DIR/$TMPNAME.conf"; chmod 600 "$AWG_DIR/$TMPNAME.conf"
            ip netns exec "$NS" awg-quick up "$TMPNAME" >/dev/null 2>&1
            hs=0
            for _ in $(seq 1 15); do
                hs="$(ip netns exec "$NS" awg show "$TMPNAME" latest-handshakes 2>/dev/null | awk '{print $2}')"
                [ "${hs:-0}" != 0 ] && break
                sleep 1
            done
            [ "${hs:-0}" != 0 ] && ok "handshake проходит" || bad "handshake не проходит"
            iptables -w -t nat -D POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null
        else
            warn "не нашёл конфиг тестового клиента — глубокая проверка пропущена"
        fi
    else
        bad "не удалось создать тестового клиента"
    fi
    cleanup_deep; trap - EXIT
fi

# ── вывод ───────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
    printf '{"problems": %d, "checks": [' "$PROBLEMS"
    first=1
    for r in "${REPORT[@]}"; do
        st="${r%%|*}"; msg="${r#*|}"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"status":"%s","text":"%s"}' "$st" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
else
    echo
    if [ "$PROBLEMS" = 0 ]; then
        printf '\033[1;32mПроверка завершена: проблем не найдено\033[0m\n'
    else
        printf '\033[1;31mПроверка завершена: проблем — %d\033[0m\n' "$PROBLEMS"
    fi
fi
exit 0
