#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Доктор целиком: синтетическое состояние → настоящий awg-doctor.sh → разбор.
#
# Все прочие проверки доктора вырезают из него одну функцию и гоняют её
# отдельно. Это ловит логику функции, но НЕ ловит главного: кому её задают.
# Ровно на этом и вышла ложная тревога про `<iface>.env` у слоя 2.0 — сама
# функция была права, ошибкой был список интерфейсов, которым её задавали.
# Такой набор увидел бы это сразу: исправный сервер обязан молчать.
#
# Отсюда главное утверждение раздела 1: на полностью исправном сервере доктор
# не говорит НИЧЕГО — ни красного, ни жёлтого. Слово «замечаний: 0» тут не
# формальность: каждое лишнее замечание на здоровом сервере приучает
# пролистывать вывод мимо настоящего.
#
# Состояние собирается в пространстве имён поверх tmpfs, потому что пути в
# докторе прибиты (/etc/amnezia/amneziawg, /opt/antizapret-awg, /root). Ответы
# системы дают заглушки на PATH: они читают тот же стенд, поэтому «живое ядро»
# и «файлы на диске» расходятся ровно тогда, когда мы этого хотим.
#
#   bash tests/test_doctor_e2e.sh

fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }

if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — сквозной прогон доктора пропущен\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_doctor_e2e" \
        "пропущено: unshare -Urm недоступен, доктор целиком не запускался"
    exit 0
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
for d in /etc /root /opt /usr/local /run; do
    mount -t tmpfs none "$d" 2>/dev/null || { echo "  · не смонтировать tmpfs на $d"; exit 0; }
done
cp -a "$W/etc-orig/." /etc/ 2>/dev/null || true

AWG=/etc/amnezia/amneziawg
DEST=/opt/antizapret-awg
HOST=sdd.ftp.sh
export STUB_STATE="$W/stub-state"

# ── заглушки системы ────────────────────────────────────────────────────────
S="$W/stub"; mkdir -p "$S" "$STUB_STATE/if"
cat > "$S/ip" <<'EOS'
#!/bin/sh
case "$*" in
    *link*show*) i="${*##* }"; [ -f "$STUB_STATE/if/$i" ] && exit 0 || exit 1 ;;
    *addr*show*) i="${*##* }"; cat "$STUB_STATE/if/$i" 2>/dev/null && exit 0 || exit 1 ;;
esac
exit 0
EOS
cat > "$S/awg" <<'EOS'
#!/bin/sh
if [ "$1" = pubkey ]; then read -r k; printf 'PUB_%s\n' "$k"; exit 0; fi
if [ "$1" = show ]; then
    case "$3" in
        peers)      cat "$STUB_STATE/$2.peers" 2>/dev/null; exit 0 ;;
        public-key) cat "$STUB_STATE/$2.pub"   2>/dev/null; exit 0 ;;
    esac
fi
exit 0
EOS
cat > "$S/ss" <<'EOS'
#!/bin/sh
cat "$STUB_STATE/ports" 2>/dev/null
exit 0
EOS
printf '#!/bin/sh\nexit 0\n' > "$S/modinfo"
printf '#!/bin/sh\nexit 0\n' > "$S/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$S/dkms"
printf '#!/bin/sh\nexit 0\n' > "$S/amneziawg-go"
chmod +x "$S"/*
export PATH="$S:$PATH"

# ── стенд: полностью исправный сервер с обоими слоями ───────────────────────
mk_stand() {
    rm -rf "$AWG" "$DEST" /root/antizapret /etc/knot-resolver
    rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE/if"
    mkdir -p "$AWG" "$DEST/clients" /root/antizapret /etc/knot-resolver

    printf "WIREGUARD_HOST='%s'\n" "$HOST" > /root/antizapret/setup
    : > /root/antizapret/client.sh          # ваниль на месте
    # то, чем доктор спрашивает демона про состояние слоя 3.0
    printf '%s\n' 'print("header_protection_key=deadbeef")' > "$DEST/awg3-uapi.py"

    {
        echo "MODE=parallel"; echo "LAYER2=1"; echo "LAYER3=1"
        echo "AZ_IFACE=antizapret-awg";  echo "AZ_SUBNET=10.29.9";  echo "AZ_PORT=53820"
        echo "AZ_DNS=10.29.8.1";         echo "AZ_SPLIT=1"
        echo "VPN_IFACE=vpn-awg";        echo "VPN_SUBNET=10.28.9"; echo "VPN_PORT=47716"
        echo "VPN_DNS=10.29.8.1";        echo "VPN_SPLIT=0"
        echo "AZ3_IFACE=antizapret-awg3"; echo "AZ3_SUBNET=10.29.10"; echo "AZ3_PORT=24925"
        echo "AZ3_DNS=10.29.8.1";         echo "AZ3_SPLIT=1"
        echo "VPN3_IFACE=vpn-awg3";       echo "VPN3_SUBNET=10.28.10"; echo "VPN3_PORT=51530"
        echo "VPN3_DNS=10.29.8.1";        echo "VPN3_SPLIT=0"
        echo "MTU=1320"; echo "MTU3=1380"; echo "WAN=eth0"
    } > "$AWG/services.env"

    printf "AWG_Jc='4'\n" > "$AWG/obfuscation.env"
    printf "AWG_Jc='4'\nAWG_HPK_HEX='deadbeef'\n" > "$AWG/obfuscation3.env"

    : > "$STUB_STATE/ports"
    # <иф> <подсеть> <порт> <mtu> <слой> <каталог клиентов>
    while read -r i sub port mtu layer dir; do
        [ -n "$i" ] || continue
        printf '%s UNKNOWN %s.1/24\n' "$i" "$sub" > "$STUB_STATE/if/$i"
        printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$port" >> "$STUB_STATE/ports"
        printf 'PUB_SRV_%s\n' "$i" > "$STUB_STATE/$i.pub"
        : > "$STUB_STATE/$i.peers"
        mkdir -p "$DEST/clients/$dir"
        {
            echo "[Interface]"
            echo "PrivateKey = SRV_$i"
            echo "Address = ${sub}.1/24"
            echo "ListenPort = $port"
            echo "MTU = $mtu"
        } > "$AWG/$i.conf"
        [ "$layer" = 3 ] && {
            { echo "SUBNET=${sub}.0/24"; echo "PORT=$port"; echo "NAT=0"; echo "DNS=10.29.8.1"; } > "$AWG/$i.env"
            printf 'header_protection_key=deadbeef\n' > "$AWG/$i.v3"
        }
        # по одному клиенту на сервис: и в конфиге сервера, и в «живом ядре»
        {
            echo; echo "[Peer]"; echo "# alice"
            echo "PublicKey = PUB_CLI_${i}"
            echo "AllowedIPs = ${sub}.2/32"
        } >> "$AWG/$i.conf"
        printf 'PUB_CLI_%s\n' "$i" >> "$STUB_STATE/$i.peers"
        {
            echo "[Interface]"
            echo "PrivateKey = CLI_${i}"
            echo "Address = ${sub}.2/32"
            echo "MTU = $mtu"
            echo; echo "[Peer]"
            echo "PublicKey = PUB_SRV_${i}"
            echo "Endpoint = ${HOST}:${port}"
            echo "AllowedIPs = 0.0.0.0/0"
        } > "$DEST/clients/$dir/${dir}-alice-am.conf"
        printf 'view:addr(%s%s.1/24%s)\n' "'" "$sub" "'" >> /etc/knot-resolver/kresd.conf
    done <<EOT
antizapret-awg 10.29.9 53820 1320 2 antizapret
vpn-awg 10.28.9 47716 1320 2 vpn
antizapret-awg3 10.29.10 24925 1380 3 antizapret3
vpn-awg3 10.28.10 51530 1380 3 vpn3
EOT
}

run_doctor() {  # печатает json
    bash "$STAND_REPO/overlay/bin/awg-doctor.sh" --json 2>"$W/doc.err"
}
n_of() { grep -o "\"status\":\"$1\"" "$W/out" 2>/dev/null | wc -l; }
texts_of() { grep -o "\"status\":\"$1\",\"text\":\"[^\"]*\"" "$W/out" 2>/dev/null | sed 's/.*"text":"//;s/"$//'; }

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Исправный сервер: доктор молчит"
mk_stand
run_doctor > "$W/out"
nf="$(n_of FAIL)"; nw="$(n_of WARN)"; no="$(n_of OK)"
if [ "$no" -lt 20 ]; then
    bad "доктор сделал всего $no проверок" "стенд не доехал до настоящего осмотра: $(head -3 "$W/doc.err")"
elif [ "$nf" = 0 ] && [ "$nw" = 0 ]; then
    ok "ни одного замечания на $no проверках"
else
    bad "на исправном сервере $nf ошибок и $nw замечаний" "$(texts_of FAIL; texts_of WARN)"
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Пропажа <iface>.env у слоя 3.0 — замечание, и про тот интерфейс"
# Здесь файл настоящий: его читает userspace-датапас. Это и есть тот случай,
# ради которого проверка вообще нужна.
mk_stand
rm -f "$AWG/antizapret-awg3.env"
run_doctor > "$W/out"
case "$(texts_of WARN)" in
    *"antizapret-awg3"*"не узнает подсеть"*) ok "сказано, и названо чьё" ;;
    *) bad "пропажа .env у слоя 3.0 пропущена" "замечания: $(texts_of WARN)" ;;
esac
case "$(texts_of WARN)" in
    *"vpn-awg3"*) bad "заодно пожаловались на исправный vpn-awg3" "$(texts_of WARN)" ;;
    *) ok "и только про него" ;;
esac
[ "$(n_of FAIL)" = 0 ] && ok "и это замечание, а не поломка" \
    || bad "пропажа .env названа поломкой" "$(texts_of FAIL)"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. У интерфейса 2.0 .env нет НИКОГДА — и это не повод говорить"
# Слой 2.0 идёт на kernel-модуле: файла нет ни на одном исправном сервере.
# Раздел 1 это уже покрывает, но здесь проверка именная: если кто-то вернёт
# вопрос слою 2.0, покраснеет строка, прямо называющая причину.
mk_stand
run_doctor > "$W/out"
case "$(texts_of WARN)$(texts_of FAIL)" in
    *"antizapret-awg.env"*|*"vpn-awg.env"*)
        bad "доктор спросил .env у слоя 2.0" \
            "файла там не бывает — жалоба выпадет на каждом исправном сервере" ;;
    *) ok "про antizapret-awg.env и vpn-awg.env не сказано ни слова" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Клиенту выдан конфиг, а пира на сервере нет"
# Самый дорогой разлад: конфиг на руках, сервер его не пустит.
mk_stand
sed -i '/PUB_CLI_antizapret-awg$/d' "$AWG/antizapret-awg.conf"
run_doctor > "$W/out"
case "$(texts_of FAIL)$(texts_of WARN)" in
    *"antizapret-awg"*) ok "разлад клиента и сервера найден" ;;
    *) bad "клиент без пира пропущен" "ошибки: $(texts_of FAIL); замечания: $(texts_of WARN)" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Интерфейс поднят НЕ из нынешнего конфига"
# Конфиг переписали, юнит не перезапустили: клиенты не сойдутся с сервером.
mk_stand
printf 'PUB_ЧУЖОЙ\n' > "$STUB_STATE/vpn-awg3.pub"
run_doctor > "$W/out"
case "$(texts_of FAIL)" in
    *"vpn-awg3"*"ДРУГОМУ ключу"*) ok "чужой ключ на интерфейсе найден" ;;
    *) bad "подмена ключа интерфейса пропущена" "$(texts_of FAIL)" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Объявленный порт разошёлся с тем, что у клиентов"
mk_stand
sed -i 's/^AZ3_PORT=24925/AZ3_PORT=24926/' "$AWG/services.env"
run_doctor > "$W/out"
case "$(texts_of FAIL)$(texts_of WARN)" in
    *"24925"*|*"24926"*) ok "расхождение порта названо" ;;
    *) bad "расхождение порта пропущено" "ошибки: $(texts_of FAIL); замечания: $(texts_of WARN)" ;;
esac


# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Ключ header protection разъехался с профилем"
# Самый разрушительный исход слоя 3.0: сервер и выданные конфиги шифруют
# заголовки разными ключами, не проходит ни один хендшейк. Сверялось наличие
# строки, а не значение, поэтому доктор печатал «header protection применена»
# и уходил в зелёное — при том что CONSISTENCY.md обещает сверку значений.
mk_stand
sed -i "s/^header_protection_key=.*/header_protection_key=cafebabe/" "$AWG/antizapret-awg3.v3"
run_doctor > "$W/out"
case "$(texts_of FAIL)" in
    *"не тот, что в профиле"*) ok "расхождение ключа названо поломкой" ;;
    *) bad "разъехавшийся ключ 3.0 пропущен" \
           "слой не работает, а доктор молчит: $(texts_of FAIL)$(texts_of WARN)" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
