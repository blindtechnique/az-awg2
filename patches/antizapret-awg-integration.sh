#!/usr/bin/env bash
# antizapret-awg-integration.sh — слой настоящего AmneziaWG 2.0 ПОВЕРХ уже
# установленного AntiZapret. НЕРАЗРУШАЮЩИЙ: не удаляет /etc/wireguard/*.conf
# (иначе ломается штатный client.sh 7 при повторном setup.sh) — только отключает
# wg-сервисы.
#
# Два режима:
#   по умолчанию (replace): AmneziaWG заменяет WireGuard на ТЕХ ЖЕ портах
#     51443/51080 и интерфейсах antizapret/vpn. Резервные порты 540/580 и «amnezia»-
#     редирект 52xxx→51xxx автоматически ведут на AmneziaWG — up.sh НЕ трогаем.
#   --keep-wireguard: ванильный WG остаётся активным на 51443/51080, AmneziaWG
#     поднимается на отдельных интерфейсах antizapret-awg/vpn-awg (порты 52443/52080,
#     подсети 10.29.9/10.28.9), редирект 52xxx→51xxx убирается, порты 52xxx
#     открываются. Оба VPN работают параллельно.
#
# Параметры сервисов пишутся в /etc/amnezia/amneziawg/services.env — оттуда их
# читает client-awg.sh (интерфейс/порт/подсеть/DNS), поэтому клиенты не зависят
# от режима.
set -euo pipefail

PRESET="medium"; TEMPLATE=""; FP="chrome"; KEEP_WG=0; MTU=1320; HOST=""; UPDATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --fp) FP="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --keep-wireguard) KEEP_WG=1; shift ;;
        --update) UPDATE=1; shift ;;
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

# внутренний DNS сервера (knot AntiZapret) — стабильный внутренний адрес, не зависит
# от смены публичного IP. Полный туннель достаёт его через 0.0.0.0/0.
SERVER_DNS="10.29.8.1"

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
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" \
            | gpg --dearmor -o /usr/share/keyrings/amnezia.gpg
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

# ── 3. параметры режима + services.env ───────────────────────────────────────
plan_services() {
    # наследуем клиентские подсети от ванильного AntiZapret (он мог быть поставлен
    # с альтернативным диапазоном 172.x вместо 10.x). Fake-IP берётся отдельно из
    # /etc/wireguard/ips, поэтому здесь только базовые подсети клиентов.
    _subnet_of() {  # "10.29.8.1/24" → "10.29.8"; при отсутствии — fallback
        local addr; addr="$(awk -F'[ =/]+' '/^Address/{print $2; exit}' "$1" 2>/dev/null)"
        [ -n "$addr" ] && echo "${addr%.*}" || echo "$2"
    }
    local az_base vpn_base
    az_base="$(_subnet_of "$WG_DIR/antizapret.conf" "10.29.8")"
    vpn_base="$(_subnet_of "$WG_DIR/vpn.conf" "10.28.8")"
    # DNS = внутренний knot AntiZapret на шлюзе antizapret-подсети (стабилен)
    SERVER_DNS="${az_base}.1"

    if [ "$KEEP_WG" = 1 ]; then
        # AmneziaWG рядом с ванильным WG → отдельные подсети (третий октет +1) и порты
        AZ_IFACE=antizapret-awg; AZ_PORT=52443; AZ_SUBNET="${az_base%.*}.$(( ${az_base##*.} + 1 ))"
        VPN_IFACE=vpn-awg;       VPN_PORT=52080; VPN_SUBNET="${vpn_base%.*}.$(( ${vpn_base##*.} + 1 ))"
        MODE=keep
    else
        # AmneziaWG заменяет WG на тех же подсетях и портах
        AZ_IFACE=antizapret; AZ_PORT=51443; AZ_SUBNET="$az_base"
        VPN_IFACE=vpn;       VPN_PORT=51080; VPN_SUBNET="$vpn_base"
        MODE=replace
    fi
    mkdir -p "$AWG_DIR"; umask 077
    cat > "$SERVICES" <<EOF
# режим интеграции AmneziaWG (читается client-awg.sh)
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
    log "Режим: $MODE · подсети antizapret=$AZ_SUBNET.0/24 vpn=$VPN_SUBNET.0/24 · DNS=$SERVER_DNS"
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
    build_iface "$AZ_IFACE"  "$AZ_SUBNET"  "$AZ_PORT"  "$WG_DIR/antizapret.conf"
    build_iface "$VPN_IFACE" "$VPN_SUBNET" "$VPN_PORT" "$WG_DIR/vpn.conf"
}

# ── 5. WireGuard: отключить сервисы (файлы НЕ удаляем) / оставить (keep) ──────
handle_wireguard() {
    if [ "$KEEP_WG" = 1 ]; then
        log "Ванильный WireGuard оставлен активным (--keep-wireguard)"
        # убрать редирект 52xxx→51xxx, чтобы 52xxx шли на настоящий AmneziaWG,
        # и открыть порты 52xxx во INPUT
        patch_up_for_keep
    else
        log "Отключаю сервисы ванильного WireGuard (конфиги сохраняю для совместимости)…"
        systemctl disable --now wg-quick@antizapret 2>/dev/null || true
        systemctl disable --now wg-quick@vpn 2>/dev/null || true
        # up.sh НЕ трогаем: 540/580 и 52xxx→51xxx теперь ведут на AmneziaWG (те же порты)
    fi
    patch_client_sh || log "патч client.sh пропущен (некритично)"
}

patch_up_for_keep() {
    local up="/root/antizapret/up.sh"
    [ -f "$up" ] || return 0
    cp "$up" "${up}.pre-awg.bak" 2>/dev/null || true
    sed -i '/dport 52080 -j REDIRECT/d;/dport 52443 -j REDIRECT/d' "$up" 2>/dev/null || true
    if ! grep -q 'dport 52443 -j ACCEPT' "$up"; then
        sed -i '/^# WireGuard\/AmneziaWG port redirection/i iptables -w -A INPUT -p udp --dport 52443 -j ACCEPT\niptables -w -A INPUT -p udp --dport 52080 -j ACCEPT' "$up" 2>/dev/null || true
    fi
    log "up.sh: убран редирект 52xxx→51xxx, открыты порты 52443/52080 (keep-режим)"
}

patch_client_sh() {
    local cs="/root/antizapret/client.sh" marker="/root/antizapret/.awg-clientsh-patched"
    [ -f "$cs" ] || return 0
    [ -f "$marker" ] && return 0
    sed -i 's@\(cp -r /etc/wireguard/[A-Za-z0-9._-]* /root/antizapret/backup/wireguard\)@\1 2>/dev/null || true@g' "$cs" || return 1
    touch "$marker"
    log "client.sh backup() пропатчен (не падает без активного WG)"
}

# ── 6. обфускация ────────────────────────────────────────────────────────────
gen_obfuscation() {
    log "Профиль обфускации: preset=$PRESET template=${TEMPLATE:-default}"
    AWG_AZ_CONF="$AWG_DIR/${AZ_IFACE}.conf" AWG_VPN_CONF="$AWG_DIR/${VPN_IFACE}.conf" \
        "$DEST/awg-obfuscation.sh" --preset "$PRESET" ${TEMPLATE:+--template "$TEMPLATE"} --fp "$FP" --mtu "$MTU" ${HOST:+--host "$HOST"} --apply
}

# ── 7. сервисы ───────────────────────────────────────────────────────────────
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
}

main() {
    # ── режим ОБНОВЛЕНИЯ: только код/сервисы/самовосстановление. НЕ трогаем
    #    обфускацию, серверные и клиентские конфиги — существующие клиенты продолжат
    #    работать без переимпорта.
    if [ "$UPDATE" = 1 ]; then
        log "Обновление слоя AmneziaWG (код и сервисы; конфиги и обфускация НЕ меняются)"
        install_awg
        deploy_overlay
        # берём режим/интерфейсы из уже установленного services.env (не перегенерируем)
        if [ -f "$SERVICES" ]; then
            # shellcheck disable=SC1090
            . "$SERVICES"
            AZ_IFACE="${AZ_IFACE:-antizapret}"; VPN_IFACE="${VPN_IFACE:-vpn}"
            [ "${MODE:-replace}" = keep ] && KEEP_WG=1
        else
            plan_services
        fi
        handle_wireguard        # погасить ванильный wg, если апдейт AntiZapret его вернул
        "$DEST/awg-reintegrate.sh" 2>/dev/null || true   # поднять awg-интерфейсы, если легли
        log "✅ Код обновлён. Обфускация и клиенты не тронуты."
        return
    fi

    log "Слой AmneziaWG 2.0 поверх AntiZapret (режим: $([ "$KEEP_WG" = 1 ] && echo keep || echo replace))"
    install_awg
    deploy_overlay
    plan_services
    resolve_host
    build_interfaces
    handle_wireguard
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
