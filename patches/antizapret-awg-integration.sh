#!/usr/bin/env bash
# antizapret-awg-integration.sh — слой настоящего AmneziaWG 2.0 ПОВЕРХ уже
# установленного AntiZapret. ПАРАЛЛЕЛЬНЫЙ и НЕРАЗРУШАЮЩИЙ:
#
#   * ванильный AntiZapret не трогается НИ БАЙТОМ: wg-quick@ остаётся активным,
#     up.sh/client.sh не патчатся, редиректы 540/580 и 52xxx→51xxx работают штатно;
#   * AmneziaWG 2.0 живёт на своих интерфейсах antizapret-awg/vpn-awg, своих
#     подсетях (третий октет +1: 10.29.9/10.28.9) и своём UDP-порту;
#   * порт по умолчанию РАНДОМНЫЙ (не пересекается с зарезервированными и занятыми),
#     выбирается ОДИН РАЗ и дальше закреплён в services.env — повторные запуски
#     его не меняют (иначе умрут клиентские конфиги);
#   * NAT/DNS/защиты ванили покрывают наши подсети автоматически (правила up.sh
#     ходят по агрегатам $IP.29.0.0/16 и $IP.28.0.0/15), INPUT policy = ACCEPT,
#     поэтому наш порт открывать не нужно. Единственная точка касания ванили —
#     view:addr в kresd.conf для наших подсетей (awg-knot-view.sh, идемпотентно);
#   * совместимо с админ-панелями (AdminPanelAZ и т.п.) — они управляют ванилью
#     через client.sh и не видят наш слой.
#
# Флаги:
#   --preset X --template Y --fp Z --mtu N --host H   параметры обфускации
#   --az-port N / --vpn-port N   зафиксировать порты вручную (иначе рандом)
#   --update    обновить код/сервисы БЕЗ смены обфускации и портов
#   --migrate   миграция старых режимов (replace/keep) на parallel
set -euo pipefail

PRESET="medium"; TEMPLATE=""; FP="chrome"; MTU=1320; HOST=""
UPDATE=0; MIGRATE=0; CLI_AZ_PORT=""; CLI_VPN_PORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --fp) FP="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --az-port) CLI_AZ_PORT="$2"; shift 2 ;;
        --vpn-port) CLI_VPN_PORT="$2"; shift 2 ;;
        --update) UPDATE=1; shift ;;
        --migrate) MIGRATE=1; shift ;;
        # legacy-флаг старого установщика: parallel теперь единственный режим
        --keep-wireguard) shift ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done
[[ "$MTU" =~ ^[0-9]+$ ]] || MTU=1320

[ "$(id -u)" = 0 ] || { echo "Запускать под root"; exit 1; }
AWG_DIR="/etc/amnezia/amneziawg"
WG_DIR="/etc/wireguard"
OVERLAY="$(dirname "$(readlink -f "$0")")/../overlay"
DEST="/opt/antizapret-awg"
SERVICES="$AWG_DIR/services.env"

log() { printf '\033[1;32m[integration]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[integration]\033[0m %s\n' "$*" >&2; }

# ── порты ────────────────────────────────────────────────────────────────────
# Зарезервировано ванильным AntiZapret (up.sh + setup.sh):
#   51443/51080  ListenPort ванильных wg-интерфейсов
#   52443/52080  редирект 52xxx→51xxx для junk-only «-am» клиентов ванили
#   540/580      резервные UDP-порты WireGuard (REDIRECT → 51xxx)
#   80/443/504/508  резервные порты OpenVPN (REDIRECT → 50xxx)
#   50080/50443  реальные порты OpenVPN
#   1194         классический OpenVPN, 53 — DNS, 22 — ssh
RESERVED_PORTS="22 53 80 443 504 508 540 580 1194 50080 50443 51080 51443 52080 52443"

busy_ports() { ss -lunH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | sort -u; }

pick_random_port() {  # pick_random_port [исключить...] — свободный порт 20000-59999
    local exclude p tries=0
    exclude="$RESERVED_PORTS $(busy_ports) $*"
    while :; do
        p="$(shuf -i 20000-59999 -n 1)"
        printf '%s\n' $exclude | grep -qx "$p" || { echo "$p"; return 0; }
        tries=$((tries + 1))
        [ "$tries" -gt 200 ] && { err "не нашёл свободный порт"; return 1; }
    done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ── 1. amneziawg ─────────────────────────────────────────────────────────────
install_awg() {
    if command -v awg >/dev/null 2>&1 && modinfo amneziawg >/dev/null 2>&1; then
        log "amneziawg уже установлен"; return
    fi
    export DEBIAN_FRONTEND=noninteractive
    local os_id="ubuntu"
    [ -r /etc/os-release ] && os_id="$(. /etc/os-release; echo "${ID:-ubuntu}")"
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg2 dkms build-essential \
        python3-pip python3-venv || true
    # kernel headers: имена различаются (Debian cloud vs обычные ядра)
    apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null \
        || apt-get install -y linux-headers-amd64 2>/dev/null \
        || apt-get install -y linux-headers-cloud-amd64 2>/dev/null \
        || err "kernel headers не установились — DKMS-сборка может провалиться"

    if [ "$os_id" = "ubuntu" ]; then
        log "Установка amneziawg (Ubuntu PPA + DKMS)…"
        apt-get install -y software-properties-common python3-launchpadlib
        add-apt-repository -y ppa:amnezia/ppa
        apt-get update -y
        apt-get install -y amneziawg
    else
        # Debian и прочие не-Ubuntu: PPA недоступны. Добавляем репозиторий Amnezia
        # вручную (deb822, Suites: focal — DKMS-исходники дистро-независимы). Ключ с
        # keyserver.ubuntu.com. Метод по гайду mk16.de (проверен на Debian 12/13).
        log "Установка amneziawg (Debian: ручной репозиторий Amnezia + DKMS)…"
        install -d -m 0755 /usr/share/keyrings
        # ВАЖНО: на Debian 13 верификатор sqv работает от пользователя _apt и
        # не может прочитать keyring, созданный с прежним umask (600) → ошибка
        # "Permission denied (os error 13)". Пишем во временный файл и ставим 0644.
        umask 022
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" \
            | gpg --dearmor > /usr/share/keyrings/amnezia.gpg.tmp
        install -m 0644 /usr/share/keyrings/amnezia.gpg.tmp /usr/share/keyrings/amnezia.gpg
        rm -f /usr/share/keyrings/amnezia.gpg.tmp
        chmod 0644 /usr/share/keyrings/amnezia.gpg
        cat > /etc/apt/sources.list.d/amnezia.sources <<'EOF'
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: focal
Components: main
Signed-By: /usr/share/keyrings/amnezia.gpg
EOF
        apt-get update -y
        apt-get install -y amneziawg amneziawg-tools
    fi
    pip3 install --break-system-packages segno >/dev/null 2>&1 || \
        pip3 install --break-system-packages "qrcode[pil]" >/dev/null 2>&1 || true

    if command -v awg >/dev/null 2>&1 && modprobe amneziawg 2>/dev/null; then
        log "amneziawg установлен"
    else
        err "Модуль amneziawg не загрузился. На свежих ядрах Debian сборка DKMS"
        err "может падать (upstream issue #143). Проверь:"
        err "    dkms status ; cat /var/lib/dkms/amneziawg/*/build/make.log"
        err "Рекомендуемая платформа — Ubuntu 24.04 (протестирована)."
    fi
}

# ── 2. overlay ───────────────────────────────────────────────────────────────
deploy_overlay() {
    log "Развёртывание overlay в $DEST"
    mkdir -p "$DEST"
    cp "$OVERLAY/obfuscation/awg_obfuscate.py" "$OVERLAY/bin/awg-obfuscation.sh" \
       "$OVERLAY/bin/awg-export.py" "$OVERLAY/bin/client-awg.sh" \
       "$OVERLAY/bin/awg-backup.sh" "$OVERLAY/bin/awg-reintegrate.sh" \
       "$OVERLAY/bin/awg-knot-view.sh" "$OVERLAY/bin/az_setup_runner.py" \
       "$OVERLAY/bin/awg_stats.py" "$DEST/" 2>/dev/null || true
    chmod +x "$DEST"/*.sh "$DEST"/*.py 2>/dev/null || true
    ln -sf "$DEST/awg-obfuscation.sh" /usr/local/bin/awg-obfuscation
    ln -sf "$DEST/client-awg.sh" /usr/local/bin/awg-client
    ln -sf "$DEST/awg-backup.sh" /usr/local/bin/awg-backup
    mkdir -p /etc/systemd/system/awg-quick@.service.d
    cp "$OVERLAY/systemd/awg-quick@.service.d/override.conf" \
        /etc/systemd/system/awg-quick@.service.d/override.conf
    # самовосстановление после обновления AntiZapret. Три якоря:
    #  1) drop-in ExecStartPost на antizapret.service — самый надёжный: срабатывает
    #     при КАЖДОМ старте antizapret (загрузка/авто-апдейт/setup), переживает rm -rf;
    #  2) awg-reintegrate.service — на загрузке;
    #  3) хук в custom-up.sh — на старте antizapret (пока его не стёр setup.sh).
    mkdir -p /etc/systemd/system/antizapret.service.d
    cp "$OVERLAY/systemd/antizapret.service.d/awg-reintegrate.conf" \
        /etc/systemd/system/antizapret.service.d/awg-reintegrate.conf 2>/dev/null || true
    cp "$OVERLAY/../bot/awg-reintegrate.service" /etc/systemd/system/ 2>/dev/null || true
    local cu=/root/antizapret/custom-up.sh
    if [ -f "$cu" ] && ! grep -q 'awg-reintegrate' "$cu"; then
        printf '\n# AntiZapret-AWG: самовосстановление слоя AmneziaWG после обновления\n%s/awg-reintegrate.sh >/dev/null 2>&1 &\n' "$DEST" >> "$cu"
        log "hook самовосстановления добавлен в custom-up.sh"
    fi
    systemctl daemon-reload
    systemctl enable awg-reintegrate.service 2>/dev/null || true
}

# ── 3. план сервисов: интерфейсы, подсети, ПОРТЫ (рандом с закреплением) ──────
plan_services() {
    # наследуем клиентские подсети от ванильного AntiZapret (он мог быть поставлен
    # с альтернативным диапазоном 172.x вместо 10.x). Наши подсети — третий октет +1;
    # правила ванили ходят по агрегатам /16 и /15, так что NAT/DNS/защиты покрывают
    # нас автоматически.
    _subnet_of() {  # "10.29.8.1/24" → "10.29.8"; при отсутствии — fallback
        local addr; addr="$(awk -F'[ =/]+' '/^Address/{print $2; exit}' "$1" 2>/dev/null)"
        [ -n "$addr" ] && echo "${addr%.*}" || echo "$2"
    }
    local az_base vpn_base
    az_base="$(_subnet_of "$WG_DIR/antizapret.conf" "10.29.8")"
    vpn_base="$(_subnet_of "$WG_DIR/vpn.conf" "10.28.8")"
    # DNS = внутренний knot AntiZapret на шлюзе ВАНИЛЬНОЙ antizapret-подсети
    SERVER_DNS="${az_base}.1"

    AZ_IFACE=antizapret-awg; AZ_SUBNET="${az_base%.*}.$(( ${az_base##*.} + 1 ))"
    VPN_IFACE=vpn-awg;       VPN_SUBNET="${vpn_base%.*}.$(( ${vpn_base##*.} + 1 ))"
    MODE=parallel

    # порты: закреплённые (services.env) > CLI > рандом. Один раз выбранный порт
    # больше НИКОГДА не меняется молча — от него зависят все клиентские конфиги.
    local pinned_az="" pinned_vpn=""
    if [ -f "$SERVICES" ]; then
        # shellcheck disable=SC1090
        pinned_az="$(. "$SERVICES" 2>/dev/null; echo "${AZ_PORT:-}")"
        pinned_vpn="$(. "$SERVICES" 2>/dev/null; echo "${VPN_PORT:-}")"
        # порты старых режимов не наследуем: 51xxx/52xxx заняты ванилью
        case "$pinned_az"  in 51443|52443) pinned_az="";;  esac
        case "$pinned_vpn" in 51080|52080) pinned_vpn="";; esac
    fi
    if [ -n "$CLI_AZ_PORT" ]; then
        valid_port "$CLI_AZ_PORT" || { err "--az-port: некорректный порт"; exit 2; }
        AZ_PORT="$CLI_AZ_PORT"
    else
        AZ_PORT="${pinned_az:-$(pick_random_port)}"
    fi
    if [ -n "$CLI_VPN_PORT" ]; then
        valid_port "$CLI_VPN_PORT" || { err "--vpn-port: некорректный порт"; exit 2; }
        VPN_PORT="$CLI_VPN_PORT"
    else
        VPN_PORT="${pinned_vpn:-$(pick_random_port "$AZ_PORT")}"
    fi
    [ "$AZ_PORT" != "$VPN_PORT" ] || { err "Порты antizapret и vpn совпадают ($AZ_PORT)"; exit 2; }

    write_services
    log "Режим: parallel · подсети antizapret=$AZ_SUBNET.0/24 vpn=$VPN_SUBNET.0/24"
    log "Порты AmneziaWG: antizapret=$AZ_PORT vpn=$VPN_PORT (закреплены) · DNS=$SERVER_DNS"
}

write_services() {
    mkdir -p "$AWG_DIR"; umask 077
    cat > "$SERVICES" <<EOF
# режим интеграции AmneziaWG (читается client-awg.sh и awg-reintegrate.sh)
MODE=$MODE
AZ_IFACE=$AZ_IFACE
AZ_PORT=$AZ_PORT
AZ_SUBNET=$AZ_SUBNET
AZ_DNS=$SERVER_DNS
AZ_SPLIT=1
VPN_IFACE=$VPN_IFACE
VPN_PORT=$VPN_PORT
VPN_SUBNET=$VPN_SUBNET
VPN_DNS=$SERVER_DNS
VPN_SPLIT=0
MTU=$MTU
EOF
}

# внешний хост (домен/IP) для Endpoint клиентов
resolve_host() {
    if [ -f "$WG_DIR/templates/antizapret-client-am.conf" ]; then
        grep -m1 -oE 'Endpoint = [^:]+' "$WG_DIR/templates/antizapret-client-am.conf" \
            | awk '{print $3}' > "$AWG_DIR/server_host" 2>/dev/null || true
    fi
    [ -s "$AWG_DIR/server_host" ] || curl -s https://api.ipify.org > "$AWG_DIR/server_host"
}

# ── 4. серверные awg-интерфейсы (ключи наследуются, не пересоздаются) ─────────
build_iface() {
    local name="$1" subnet="$2" port="$3" src_wg="$4"
    local conf="$AWG_DIR/${name}.conf" priv=""
    # извлечение ключа через cut (сохраняет хвостовой '=' base64) + валидация
    _extract_key() { grep '^PrivateKey' "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t'; }
    _valid_key()   { [ -n "$1" ] && printf '%s' "$1" | awg pubkey >/dev/null 2>&1; }

    if [ -f "$conf" ]; then priv="$(_extract_key "$conf")"; fi
    if ! _valid_key "$priv" && [ -f "$src_wg" ]; then priv="$(_extract_key "$src_wg")"; fi
    if _valid_key "$priv"; then
        log "Интерфейс $name: ключ сервера валиден, сохраняю"
    else
        priv="$(awg genkey)"
        log "Интерфейс $name: сгенерирован новый ключ (старый отсутствовал/битый)"
    fi
    # сохраняем существующие [Peer]-блоки
    local peers=""
    [ -f "$conf" ] && peers="$(awk '/^\[Peer\]/{p=1} p{print}' "$conf")"
    {
        echo "# AntiZapret-AWG server interface $name"
        echo "[Interface]"
        echo "PrivateKey = $priv"
        echo "Address = ${subnet}.1/24"
        echo "ListenPort = $port"
        echo "MTU = $MTU"
        echo "__AWG_OBFUSCATION__"
        if [ -n "$peers" ]; then echo; echo "$peers"; fi
    } > "$conf"
    chmod 600 "$conf"
}

build_interfaces() {
    # ключ сервера наследуем от ванильного WG только как fallback при первой
    # установке — иначе ключ берётся из нашего же существующего конфига
    build_iface "$AZ_IFACE"  "$AZ_SUBNET"  "$AZ_PORT"  "$WG_DIR/antizapret.conf"
    build_iface "$VPN_IFACE" "$VPN_SUBNET" "$VPN_PORT" "$WG_DIR/vpn.conf"
}

# ── 5. обфускация ────────────────────────────────────────────────────────────
gen_obfuscation() {
    log "Профиль обфускации: preset=$PRESET template=${TEMPLATE:-default}"
    AWG_AZ_CONF="$AWG_DIR/${AZ_IFACE}.conf" AWG_VPN_CONF="$AWG_DIR/${VPN_IFACE}.conf" \
        "$DEST/awg-obfuscation.sh" --preset "$PRESET" ${TEMPLATE:+--template "$TEMPLATE"} --fp "$FP" --mtu "$MTU" ${HOST:+--host "$HOST"} --apply
}

# ── 6. сервисы ───────────────────────────────────────────────────────────────
switch_services() {
    systemctl enable "awg-quick@${AZ_IFACE}" "awg-quick@${VPN_IFACE}"
    # Надёжный (пере)запуск: stop сбрасывает состояние сервиса и делает down,
    # ip link del принудительно убирает «зависший» интерфейс (иначе awg-quick up
    # падает с «already exists»), затем чистый start.
    for i in "$AZ_IFACE" "$VPN_IFACE"; do
        systemctl stop "awg-quick@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true
    done
    systemctl start "awg-quick@${AZ_IFACE}" "awg-quick@${VPN_IFACE}" || \
        err "awg-quick не стартовал — проверь modprobe amneziawg (возможен reboot) и логи"
    systemctl restart antizapret 2>/dev/null || true
    log "awg-quick@${AZ_IFACE} и awg-quick@${VPN_IFACE} перезапущены (чистый старт)"
    # DNS: view в kresd.conf для наших подсетей (идемпотентно)
    "$DEST/awg-knot-view.sh" 2>/dev/null || true
}

# ── 7. МИГРАЦИЯ старых режимов (replace/keep) → parallel ─────────────────────
# После миграции клиентам нужно раздать обновлённые конфиги: у keep меняется
# только порт Endpoint, у replace — ещё и туннельный IP (подсеть +1). Ключи
# клиентов НЕ меняются.
_rewrite_client_confs() {  # svc old_subnet new_subnet new_port
    local svc="$1" old_sub="$2" new_sub="$3" new_port="$4"
    local dir="/opt/antizapret-awg/clients/$svc" conf name
    [ -d "$dir" ] || return 0
    for conf in "$dir"/*-am.conf; do
        [ -f "$conf" ] || continue
        python3 - "$conf" "$old_sub" "$new_sub" "$new_port" <<'PY'
import re, sys
path, old, new, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
txt = open(path, encoding="utf-8").read()
txt = re.sub(r'(Endpoint = .*:)\d+', r'\g<1>' + port, txt)
if old != new:
    # Address = 10.29.8.X/32 → 10.29.9.X/32 ; AllowedIPs = 10.29.8.0/24 → 10.29.9.0/24
    txt = txt.replace(f"Address = {old}.", f"Address = {new}.")
    txt = txt.replace(f"AllowedIPs = {old}.0/24", f"AllowedIPs = {new}.0/24")
open(path, "w", encoding="utf-8").write(txt)
PY
        name="$(basename "$conf" | sed "s/^${svc}-//;s/-am.conf//")"
        python3 "$DEST/awg-export.py" "$conf" --name "${svc}-${name}" \
            --outdir "$dir" --all >/dev/null 2>&1 || true
        log "  клиент $svc/$name: конфиг и QR обновлены"
    done
}

_renumber_server_peers() {  # conf old_subnet new_subnet
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(path, encoding="utf-8").read()
txt = txt.replace(f"AllowedIPs = {old}.", f"AllowedIPs = {new}.")
open(path, "w", encoding="utf-8").write(txt)
PY
}

do_migrate() {
    [ -f "$SERVICES" ] || { err "Слой не установлен — мигрировать нечего"; exit 1; }
    # shellcheck disable=SC1090
    . "$SERVICES"
    local old_mode="${MODE:-replace}"
    if [ "$old_mode" = parallel ]; then
        log "Уже режим parallel — миграция не нужна"; return 0
    fi
    local old_az_iface="$AZ_IFACE" old_vpn_iface="$VPN_IFACE"
    local old_az_sub="$AZ_SUBNET" old_vpn_sub="$VPN_SUBNET"
    log "Миграция $old_mode → parallel…"

    # новый план (интерфейсы/подсети/рандомные порты); закреплённые 51xxx/52xxx
    # отбрасываются внутри plan_services
    plan_services

    # серверные конфиги: перенести на новые имена, переписать Address/ListenPort,
    # перенумеровать peer AllowedIPs при смене подсети (последний октет сохраняется)
    local pairs=("$old_az_iface:$AZ_IFACE:$old_az_sub:$AZ_SUBNET:$AZ_PORT"
                 "$old_vpn_iface:$VPN_IFACE:$old_vpn_sub:$VPN_SUBNET:$VPN_PORT")
    local p old_if new_if old_sub new_sub port oc nc
    for p in "${pairs[@]}"; do
        IFS=: read -r old_if new_if old_sub new_sub port <<< "$p"
        oc="$AWG_DIR/${old_if}.conf"; nc="$AWG_DIR/${new_if}.conf"
        if [ "$old_if" != "$new_if" ]; then
            systemctl disable --now "awg-quick@${old_if}" 2>/dev/null || true
            ip link del "$old_if" 2>/dev/null || true
            [ -f "$oc" ] && mv "$oc" "$nc"
        fi
        [ -f "$nc" ] || { err "нет $nc — пропускаю $new_if"; continue; }
        sed -i -E "s|^Address = .*|Address = ${new_sub}.1/24|; s|^ListenPort = .*|ListenPort = ${port}|" "$nc"
        [ "$old_sub" != "$new_sub" ] && _renumber_server_peers "$nc" "$old_sub" "$new_sub"
    done

    # replace-режим гасил ванильный WG — возвращаем к жизни
    if [ "$old_mode" = replace ]; then
        for s in wg-quick@antizapret wg-quick@vpn; do
            systemctl enable --now "$s" 2>/dev/null && log "включён ванильный $s" || true
        done
    fi

    # keep-режим удалял из up.sh редирект 52xxx→51xxx (порты отбирались под AWG)
    # и добавлял ACCEPT 52xxx — возвращаем ваниль в исходное состояние
    if [ "$old_mode" = keep ]; then
        local up=/root/antizapret/up.sh difc
        difc="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
        if [ -f "$up" ] && ! grep -q 'dport 52443 -j REDIRECT' "$up"; then
            # якорь — родной комментарий ванили (legacy-патч удалял только iptables-строки).
            # Вставка после якоря вида '/dport 580/a' НЕЛЬЗЯ: она попадает внутрь
            # блока if WIREGUARD_BACKUP, а у ванили редирект 52xxx безусловный.
            if grep -q '^# AmneziaWG redirection ports to WireGuard' "$up"; then
                sed -i '/^# AmneziaWG redirection ports to WireGuard/a iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080\niptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443' "$up" \
                    && log "up.sh: восстановлен ванильный редирект 52xxx→51xxx"
            else
                err "якорь для редиректа 52xxx в up.sh не найден — файл восстановится при следующем полном обновлении AntiZapret"
            fi
        fi
        sed -i '/dport 52443 -j ACCEPT/d;/dport 52080 -j ACCEPT/d' "$up" 2>/dev/null || true
        # живые правила: вернуть редирект, убрать наши ACCEPT
        if [ -n "$difc" ]; then
            for pp in "52080:51080" "52443:51443"; do
                iptables -w -t nat -C PREROUTING -i "$difc" -p udp --dport "${pp%%:*}" -j REDIRECT --to-ports "${pp##*:}" 2>/dev/null \
                    || iptables -w -t nat -A PREROUTING -i "$difc" -p udp --dport "${pp%%:*}" -j REDIRECT --to-ports "${pp##*:}" 2>/dev/null || true
            done
        fi
        for pp in 52443 52080; do
            iptables -w -D INPUT -p udp --dport "$pp" -j ACCEPT 2>/dev/null || true
        done
        log "живой iptables: редирект 52xxx возвращён ванили"
    fi

    switch_services
    _rewrite_client_confs antizapret "$old_az_sub" "$AZ_SUBNET" "$AZ_PORT"
    _rewrite_client_confs vpn        "$old_vpn_sub" "$VPN_SUBNET" "$VPN_PORT"

    echo
    log "✅ Миграция завершена. ВАЖНО: всем клиентам AmneziaWG нужно раздать"
    log "   обновлённые конфиги/QR из /opt/antizapret-awg/clients/ —"
    if [ "$old_mode" = keep ]; then
        log "   изменился порт Endpoint (ключи и IP прежние)."
    else
        log "   изменились порт Endpoint и туннельный IP (ключи прежние)."
    fi
    log "   Порты: antizapret=$AZ_PORT vpn=$VPN_PORT"
}

main() {
    # ── МИГРАЦИЯ старых режимов
    if [ "$MIGRATE" = 1 ]; then
        install_awg
        deploy_overlay
        do_migrate
        return
    fi

    # ── режим ОБНОВЛЕНИЯ: только код/сервисы/самовосстановление. НЕ трогаем
    #    обфускацию, порты, серверные и клиентские конфиги.
    if [ "$UPDATE" = 1 ]; then
        log "Обновление слоя AmneziaWG (код и сервисы; конфиги, порты и обфускация НЕ меняются)"
        install_awg
        deploy_overlay
        if [ -f "$SERVICES" ]; then
            # shellcheck disable=SC1090
            . "$SERVICES"
            if [ "${MODE:-replace}" != parallel ]; then
                log "⚠️ Обнаружен старый режим '${MODE:-replace}'. Он продолжит работать,"
                log "   но рекомендуется миграция на parallel (ваниль не трогается,"
                log "   совместимость с админ-панелями): install.sh --migrate"
            fi
        fi
        "$DEST/awg-reintegrate.sh" 2>/dev/null || true
        log "✅ Код обновлён. Обфускация и клиенты не тронуты."
        return
    fi

    # ── свежая установка / реконфигурация
    if [ -f "$SERVICES" ]; then
        # shellcheck disable=SC1090
        local cur_mode; cur_mode="$(. "$SERVICES" 2>/dev/null; echo "${MODE:-replace}")"
        if [ "$cur_mode" != parallel ]; then
            err "Установлен старый режим '$cur_mode'. Сначала миграция: install.sh --migrate"
            err "(она сохранит ключи клиентов; конфиги нужно будет раздать заново)"
            exit 1
        fi
    fi
    log "Слой AmneziaWG 2.0 поверх AntiZapret (parallel: ваниль не трогается)"
    install_awg
    deploy_overlay
    plan_services
    resolve_host
    build_interfaces
    gen_obfuscation
    switch_services
    # синхронизируем существующих клиентов с текущим профилем обфускации
    # (у сервера и клиентов S/H/I обязаны совпадать, иначе не будет handshake)
    "$DEST/client-awg.sh" regen-all 2>/dev/null || true
    echo
    log "Готово. Клиенты:"
    log "  awg-client add myphone antizapret   # split-routing (только блокировки → сервер)"
    log "  awg-client add laptop vpn           # полный туннель"
    log "Проверка: awg show — есть handshake и растёт transfer? трафик идёт?"
}
main
