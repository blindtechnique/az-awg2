#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Переход main → beta не должен трогать выданные конфиги слоя 2.0.
#
# Опыт повторяет реальный порядок событий:
#   1) сервер живёт на ветке-эталоне, её regen-all выдаёт клиентам конфиги;
#   2) поверх ЭТОГО состояния запускается regen-all текущей ветки — ровно так
#      делает установщик beta в конце установки;
#   3) сравнивается побайтно и .conf, и ссылка vpn://, которую видит приложение.
#
# Конфиг «как его выдала main» берём не из рукописного образца, а из вывода
# самой main: только он канонический, и только с ним сравнение честное.
#
#   bash tests/test_migration_main_to_beta.sh [ветка-эталон]
BASE_REF="${1:-origin/main}"
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
    echo "  ⊘ ветки $BASE_REF нет в этом клоне — сравнивать не с чем, пропуск"
    echo "     (в CI нужен actions/checkout с fetch-depth: 0)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── стенд: сервер, поставленный из main ─────────────────────────────────────
mk_stand() {  # mk_stand <каталог>
    local d="$1" s
    mkdir -p "$d/etc" "$d/clients/antizapret" "$d/clients/vpn"
    # РОВНО те ключи, что писала main: ни LAYER2, ни *3_*
    cat > "$d/etc/services.env" <<'EOS'
MODE=parallel
AZ_IFACE=antizapret-awg
AZ_SUBNET=10.29.9
AZ_PORT=41234
AZ_DNS=10.29.8.1
AZ_SPLIT=1
VPN_IFACE=vpn-awg
VPN_SUBNET=10.28.9
VPN_PORT=42345
VPN_DNS=10.29.8.1
VPN_SPLIT=0
MTU=1320
EOS
    # значения в одинарных кавычках — так их пишет to_env в awg_obfuscate.py
    cat > "$d/etc/obfuscation.env" <<'EOS'
AWG_Jc='4'
AWG_Jmin='8'
AWG_Jmax='80'
AWG_S1='80'
AWG_S2='23'
AWG_S3='26'
AWG_S4='15'
AWG_H1='52587784-52618069'
AWG_H2='559414338-559451961'
AWG_H3='1366798142-1366837561'
AWG_H4='1485382529-1485414651'
AWG_I1='<b 0xc300000001099a91><t><r 999>'
AWG_I2='<b 0x160301003203035449><rc 14><t>'
EOS
    for s in antizapret-awg vpn-awg; do
        cat > "$d/etc/$s.conf" <<'EOS'
[Interface]
Address = 10.29.9.1/24
ListenPort = 41234
PrivateKey = QEDCBA0987654321abcdefghijklmnopqrstuvwxyzA=

[Peer]
PublicKey = ZYXWVU0987654321abcdefghijklmnopqrstuvwxyzB=
AllowedIPs = 10.29.9.2/32
EOS
    done
    cat > "$d/clients/antizapret/antizapret-ann-am.conf" <<'EOS'
[Interface]
PrivateKey = AAAABBBB0987654321abcdefghijklmnopqrstuvwx=
Address = 10.29.9.2/32
DNS = 10.29.8.1
MTU = 1320

[Peer]
PublicKey = ZYXWVU0987654321abcdefghijklmnopqrstuvwxyzB=
Endpoint = vpn.example.com:41234
AllowedIPs = 10.29.9.0/24, 10.29.8.1/32
PersistentKeepalive = 15
EOS
    cp "$d/clients/antizapret/antizapret-ann-am.conf" \
       "$d/clients/vpn/vpn-bob-am.conf"
}

# ── версия слоя из ветки, с путями, перенаправленными на стенд ──────────────
mk_script() {  # mk_script <ref|WORKTREE> <каталог стенда> → путь к скрипту
    local ref="$1" d="$2" bin="$2/bin"
    rm -rf "$bin"; mkdir -p "$bin"
    if [ "$ref" = WORKTREE ]; then
        cp overlay/bin/client-awg.sh overlay/bin/awg-export.py "$bin/"
    else
        git show "$ref:overlay/bin/client-awg.sh" > "$bin/client-awg.sh"
        git show "$ref:overlay/bin/awg-export.py"  > "$bin/awg-export.py"
    fi
    # переопределяются одинаково для обеих версий, поэтому сравнение не смещают
    sed -i "s#^AWG_DIR=\"/etc/amnezia/amneziawg\"#AWG_DIR=\"$d/etc\"#" "$bin/client-awg.sh"
    sed -i "s#^CLIENT_DIR=\"/opt/antizapret-awg/clients\"#CLIENT_DIR=\"$d/clients\"#" "$bin/client-awg.sh"
    chmod +x "$bin/client-awg.sh"
    echo "$bin/client-awg.sh"
}

# Путь к скрипту считаем ДО cd: внутри подоболочки git show и cp искали бы файлы
# уже в каталоге стенда, regen-all не запускался бы вовсе, а сравнение двух
# нетронутых конфигов давало бы ложное зелёное.
regen() {  # regen <ref> <каталог стенда>
    local sh; sh="$(mk_script "$1" "$2")"
    if ! ( cd "$2" && bash "$sh" regen-all >"$2/regen.log" 2>&1 ); then
        echo "  ✘ regen-all ($1) упал:"; sed 's/^/      /' "$2/regen.log" | head -10
        return 1
    fi
    # признак версионно-независимый: экспортёр кладёт .vpn рядом с конфигом.
    # Формулировки в логе у веток разные, проверка по тексту отсекала бы эталон.
    if [ ! -f "$2/clients/antizapret/antizapret-ann.vpn" ]; then
        echo "  ✘ regen-all ($1) не дошёл до клиентов:"; sed 's/^/      /' "$2/regen.log" | head -10
        return 1
    fi
}

echo "══ Шаг 1: сервер живёт на $BASE_REF, конфиги выданы ею ═════════════════"
A="$WORK/base"; mk_stand "$A"
regen "$BASE_REF" "$A" || exit 1
echo "  ✔ эталонное состояние собрано"

echo
echo "══ Шаг 2: поверх запускается текущая ветка ═════════════════════════════"
B="$WORK/head"; cp -r "$A" "$B"; rm -f "$B/regen.log"
regen WORKTREE "$B" || exit 1

for f in clients/antizapret/antizapret-ann-am.conf clients/vpn/vpn-bob-am.conf; do
    if diff -u "$A/$f" "$B/$f" > "$WORK/d.txt" 2>&1; then
        echo "  ✔ $(basename "$f") — байт в байт, переимпорт не нужен"
    else
        echo "  ✘ $(basename "$f") — клиенту придётся импортировать заново:"
        sed 's/^/      /' "$WORK/d.txt" | head -30; fail=1
    fi
done

if grep -q "переимпорт не нужен" "$B/regen.log"; then
    echo "  ✔ regen-all сам сказал: переимпорт не нужен"
else
    echo "  ✘ regen-all не подтвердил, что ничего не изменилось:"
    grep "Конфиги клиентов" "$B/regen.log" | sed 's/^/      /'; fail=1
fi

echo
echo "══ Ссылка vpn:// ведёт в тот же туннель ════════════════════════════════"
python3 - "$A/clients/antizapret/antizapret-ann.vpn" \
           "$B/clients/antizapret/antizapret-ann.vpn" <<'PY' || fail=1
import base64, json, sys, zlib

def decode(path):
    uri = open(path, encoding="utf-8").read().strip()
    b = uri[len("vpn://"):]
    b += "=" * (-len(b) % 4)
    return json.loads(zlib.decompress(base64.urlsafe_b64decode(b)[4:]))

def awg(d):
    return (d.get("containers") or [{}])[0].get("awg") or {}

a, b = decode(sys.argv[1]), decode(sys.argv[2])
ka, kb = awg(a), awg(b)
bad = 0

def chk(label, x, y):
    global bad
    if x == y:
        print("  ✔ %s" % label)
    else:
        print("  ✘ %s\n     было: %r\n     стало: %r" % (label, x, y)); bad = 1

chk("сервер", a.get("hostName"), b.get("hostName"))
chk("порт", ka.get("port"), kb.get("port"))
chk("версия протокола", ka.get("protocol_version"), kb.get("protocol_version"))

la = json.loads(ka.get("last_config", "{}"))
lb = json.loads(kb.get("last_config", "{}"))
# всё, из чего собирается работающий туннель
for k in ("client_pub_key", "server_pub_key", "hostName", "port", "mtu",
          "client_ip", "config", "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
          "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"):
    if k in la or k in lb:
        chk("last_config.%s" % k, la.get(k), lb.get(k))

lost = sorted(set(la) - set(lb))
if lost:
    print("  ✘ потеряны поля: %s" % ", ".join(lost)); bad = 1
added = sorted(set(lb) - set(la))
if added:
    print("  ℹ добавлены поля (существующему клиенту безразличны): %s" % ", ".join(added))
if ka.get("isThirdPartyConfig") != kb.get("isThirdPartyConfig"):
    print("  ℹ isThirdPartyConfig теперь %r — сервер перестаёт подписываться "
          "как «AmneziaWG Legacy»" % kb.get("isThirdPartyConfig"))
sys.exit(bad)
PY

echo
echo "══ Профиль обфускации 2.0 не перевыпускается ═══════════════════════════"
# Это главное. regen-all только раскладывает профиль по клиентам; если бы сам
# профиль сменился, совпадение конфигов выше ничего не значило бы — просто все
# клиенты получили бы одинаково новый и одинаково нерабочий.
E="$WORK/prof"; mk_stand "$E"
sum_before="$(md5sum "$E/etc/obfuscation.env" | cut -d" " -f1)"
if AWG_DIR="$E/etc" AWG_AZ_CONF="$E/etc/antizapret-awg.conf" \
   AWG_VPN_CONF="$E/etc/vpn-awg.conf" \
   bash overlay/bin/awg-obfuscation.sh --preset paranoid --reapply \
   > "$E/obf.log" 2>&1; then
    sum_after="$(md5sum "$E/etc/obfuscation.env" | cut -d" " -f1)"
    if [ "$sum_before" = "$sum_after" ]; then
        echo "  ✔ --reapply не тронул профиль даже с чужим --preset"
    else
        echo "  ✘ --reapply перевыпустил профиль — клиенты отвалятся"; fail=1
    fi
else
    echo "  ✘ --reapply не отработал:"; sed 's/^/      /' "$E/obf.log" | head -8; fail=1
fi

# а --apply обязан профиль сменить, иначе --reconfigure перестал бы работать
F="$WORK/prof2"; mk_stand "$F"
sum_before="$(md5sum "$F/etc/obfuscation.env" | cut -d" " -f1)"
AWG_DIR="$F/etc" AWG_AZ_CONF="$F/etc/antizapret-awg.conf" \
    AWG_VPN_CONF="$F/etc/vpn-awg.conf" \
    bash overlay/bin/awg-obfuscation.sh --preset paranoid --apply \
    > "$F/obf.log" 2>&1
if [ "$sum_before" != "$(md5sum "$F/etc/obfuscation.env" | cut -d" " -f1)" ]; then
    echo "  ✔ --apply профиль меняет — значит --reconfigure по-прежнему работает"
else
    echo "  ✘ --apply профиль не сменил"; fail=1
fi

echo
echo "══ Установщик выбирает режим правильно ═════════════════════════════════"
# Условие вырезаем из настоящего gen_obfuscation, а не переписываем в тесте
cond="$(sed -n 's/^    \(\[ "\$RECONFIGURE" != 1 \].*mode=--reapply\)$/\1/p' \
        patches/antizapret-awg-integration.sh | head -1)"
if [ -z "$cond" ]; then
    echo "  ✘ в gen_obfuscation нет выбора между --apply и --reapply"; fail=1
else
    # RECONFIGURE и AWG_DIR читает вырезанное из установщика условие под
    # eval — статически такую связь не увидеть
    # shellcheck disable=SC2034
    m() { ( RECONFIGURE="$1"; AWG_DIR="$2"; mode=--apply; eval "$cond"; echo "$mode" ); }
    HASENV="$WORK/has"; mkdir -p "$HASENV"; echo x > "$HASENV/obfuscation.env"
    NOENV="$WORK/none"; mkdir -p "$NOENV"
    [ "$(m 0 "$HASENV")" = "--reapply" ] \
        && echo "  ✔ обычный прогон поверх существующего профиля → --reapply" \
        || { echo "  ✘ обычный прогон перевыпускает профиль"; fail=1; }
    [ "$(m 1 "$HASENV")" = "--apply" ] \
        && echo "  ✔ --reconfigure по-прежнему выпускает новый" \
        || { echo "  ✘ --reconfigure перестал работать"; fail=1; }
    [ "$(m 0 "$NOENV")" = "--apply" ] \
        && echo "  ✔ первая установка выпускает профиль" \
        || { echo "  ✘ на первой установке профиль не выпускается"; fail=1; }
fi

echo
echo "══ Пути, которые ПРОСЯТ новый профиль, его получают ════════════════════"
# Обратная сторона --reapply: если бы он поглотил и эти пути, вместо «конфиги
# не ломаются» вышло бы «профиль не меняется никогда», и ротация обфускации
# при блокировках тихо перестала бы работать.

# 1) решение о флаге — вырезаем из настоящего awg_layer
dec="$(grep -n 'rec=--reconfigure; fi' install.sh | head -1 | cut -d: -f2-)"
if [ -z "$dec" ]; then
    echo "  ✘ в awg_layer нет решения о --reconfigure"; fail=1
else
    # переменные ниже читает вырезанный из установщика кусок под eval —
    # статически такую связь не увидеть
    # shellcheck disable=SC2034
    r() { ( RECONFIGURE="$1"; CLI_PRESET="$2"; rec=""; eval "$dec"; echo "${rec:-нет}" ); }
    [ "$(r 0 '')"    = "нет" ]           && echo "  ✔ обычное обновление профиль не трогает" \
        || { echo "  ✘ обычное обновление перевыпускает профиль"; fail=1; }
    [ "$(r 1 '')"    = "--reconfigure" ] && echo "  ✔ --reconfigure выпускает новый" \
        || { echo "  ✘ --reconfigure не доходит до обфускатора"; fail=1; }
    [ "$(r 0 high)" = "--reconfigure" ] && echo "  ✔ явный --preset тоже выпускает новый" \
        || { echo "  ✘ --preset молча не меняет профиль"; fail=1; }
fi

# 2) пункт меню «новый профиль с текущими настройками» обязан ставить флаг
menu="$(sed -n '/^menu_existing()/,/^}/p' install.sh)"
got="$(printf '%s\n' "$menu" | awk '
    /^        2\)/      {on=1}
    on && /RECONFIGURE=1/ {print "yes"; exit}
    on && /^        3\)/  {exit}')"
if [ "$got" = yes ]; then
    echo "  ✔ пункт 2 меню выставляет RECONFIGURE=1"
else
    echo "  ✘ пункт 2 обещает новый профиль, но флага не ставит — тихий отказ"; fail=1
fi

echo
echo "══ Подсети закрепляются так же, как порты ══════════════════════════════"
pin="$(sed -n '/^    local pin_az="" pin_vpn=""$/,/^    VPN_SUBNET=/p' \
       patches/antizapret-awg-integration.sh)"
if [ -z "$pin" ]; then
    echo "  ✘ подсети не закрепляются — переезд ванили уведёт сервер от клиентов"; fail=1
else
    p() {  # p <есть services.env: 1|0> → AZ_SUBNET
        local d; d="$(mktemp -d)"
        [ "$1" = 1 ] && printf 'AZ_SUBNET=10.29.9\nVPN_SUBNET=10.28.9\n' > "$d/services.env"
        # shellcheck disable=SC2034
        ( SERVICES="$d/services.env"; az_base=10.29.99; vpn_base=10.28.99
          eval "$pin"; echo "$AZ_SUBNET" )
        rm -rf "$d"
    }
    [ "$(p 1)" = "10.29.9" ] \
        && echo "  ✔ закреплённая подсеть переживает переезд ванили" \
        || { echo "  ✘ подсеть пересчитана заново — у клиентов остался старый Address"; fail=1; }
    [ "$(p 0)" = "10.29.100" ] \
        && echo "  ✔ на первой установке считается от ванили" \
        || { echo "  ✘ на первой установке подсеть не вычисляется: $(p 0)"; fail=1; }
fi

echo
echo "══ А настоящую смену профиля тот же счётчик обязан заметить ════════════"
D="$WORK/changed"; cp -r "$A" "$D"; rm -f "$D/regen.log"
sed -i "s/^AWG_Jc='4'/AWG_Jc='7'/" "$D/etc/obfuscation.env"
regen WORKTREE "$D" || exit 1
if grep -q "изменено" "$D/regen.log" && grep -q "antizapret/ann" "$D/regen.log"; then
    echo "  ✔ названы и число, и имена"
else
    echo "  ✘ смена профиля осталась незамеченной:"
    grep "Конфиги клиентов" "$D/regen.log" | sed 's/^/      /'; fail=1
fi

echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
