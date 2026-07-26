#!/usr/bin/env bash
# awg-backup.sh — бэкап и восстановление AntiZapret-AWG.
# Заменяет штатный `client.sh 8` (он после удаления ванильного WG падает на
# cp /etc/wireguard/...). Покрывает всё нужное для полного переноса на новый сервер:
#   * OpenVPN PKI + клиентские сертификаты (/etc/openvpn/easyrsa3)
#   * AmneziaWG: серверные конфиги + профиль обфускации (/etc/amnezia/amneziawg)
#   * списки include/exclude (/root/antizapret/config/*.txt)
#   * knot-resolver (/etc/knot-resolver/*.lua)
#   * custom-скрипты (/root/antizapret/custom*.sh)
#   * клиентские профили (/root/antizapret/client — вкл. .conf/QR/URI AmneziaWG)
#   * статистику и сроки временных клиентов (/opt/antizapret-awg/stats.db, expiry.tsv)
#
# Использование:
#   awg-backup.sh backup [файл.tar.gz]        # создать (default /opt/antizapret-awg-backup-<ip>.tar.gz)
#   awg-backup.sh restore <файл.tar.gz>       # восстановить и перезапустить сервисы
set -euo pipefail

AWG_DIR="/etc/amnezia/amneziawg"
AZ="/root/antizapret"
DEST="$AZ/awg"

log() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[backup]\033[0m %s\n' "$*" >&2; }
server_ip() { ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+' || echo server; }

do_backup() {
    local out="${1:-$AZ/awg-backup-$(server_ip).tar.gz}"
    local stage; stage="$(mktemp -d)"
    log "Сбор файлов…"
    mkdir -p "$stage"/{openvpn,amneziawg,config,knot,custom,client,awgstate}

    [ -d /etc/openvpn/easyrsa3 ] && cp -r /etc/openvpn/easyrsa3 "$stage/openvpn/" || err "нет easyrsa3?"
    cp -r "$AWG_DIR"/*.conf "$stage/amneziawg/" 2>/dev/null || true
    cp "$AWG_DIR/obfuscation.env" "$AWG_DIR/obfuscation.meta" "$AWG_DIR/server_host" \
        "$stage/amneziawg/" 2>/dev/null || true
    # слой 3.0: свой профиль, per-iface .env и UAPI-файлы .v3 (в них ключ header
    # protection — без него восстановленный сервер не сойдётся с клиентами)
    cp "$AWG_DIR/obfuscation3.env" "$AWG_DIR/obfuscation3.meta" \
        "$stage/amneziawg/" 2>/dev/null || true
    cp "$AWG_DIR"/*.v3 "$AWG_DIR"/*.env "$stage/amneziawg/" 2>/dev/null || true
    cp "$AZ"/config/*.txt "$stage/config/" 2>/dev/null || true
    cp /etc/knot-resolver/*.lua "$stage/knot/" 2>/dev/null || true
    cp "$AZ"/custom*.sh "$stage/custom/" 2>/dev/null || true
    [ -d "$AZ/client" ] && cp -r "$AZ/client/." "$stage/client/" 2>/dev/null || true
    cp "$DEST/stats.db" "$DEST/expiry.tsv" "$stage/awgstate/" 2>/dev/null || true
    # Клиентские профили слоя: приватные ключи клиентов есть ТОЛЬКО здесь —
    # в серверном конфиге лежат одни публичные. Без этого каталога восстановленный
    # сервер работает, но все выданные конфиги придётся создавать заново.
    [ -d "$DEST/clients" ] && cp -r "$DEST/clients" "$stage/awgstate/" 2>/dev/null || true

    echo "AntiZapret-AWG backup $(date -u +%FT%TZ)" > "$stage/MANIFEST"
    tar -czf "$out" -C "$stage" .
    rm -rf "$stage"
    chmod 600 "$out"

    # ── шифрование ──────────────────────────────────────────────────────────
    # В архиве приватные ключи сервера и всех клиентов. Бот умеет присылать его
    # в чат, а значит копия оседает на серверах Telegram и в истории переписки
    # навсегда. С --encrypt наружу уходит уже зашифрованный файл.
    if [ -n "${BACKUP_PASS:-}" ]; then
        if command -v openssl >/dev/null 2>&1; then
            openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
                -in "$out" -out "$out.enc" -pass env:BACKUP_PASS 2>/dev/null && {
                shred -u "$out" 2>/dev/null || rm -f "$out"
                out="$out.enc"; chmod 600 "$out"
                log "Архив зашифрован (AES-256, PBKDF2)"
            } || err "не удалось зашифровать — оставляю открытый архив"
        else
            err "openssl не найден — архив остаётся незашифрованным"
        fi
    fi

    log "Готово: $out ($(du -h "$out" | cut -f1))"
    echo "$out"
}

do_restore() {
    # зашифрованный архив расшифровываем во временный файл
    if [ "${1:-}" != "${1%.enc}" ]; then
        if [ -z "${BACKUP_PASS:-}" ]; then
            [ -r /dev/tty ] && { read -rsp "Пароль архива: " BACKUP_PASS < /dev/tty; echo >&2; }
        fi
        [ -n "${BACKUP_PASS:-}" ] || { err "нужен пароль для $1"; exit 2; }
        _dec="$(mktemp /tmp/awg-restore.XXXXXX.tar.gz)"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
            -in "$1" -out "$_dec" -pass env:BACKUP_PASS 2>/dev/null \
            || { rm -f "$_dec"; err "неверный пароль или битый архив"; exit 2; }
        set -- "$_dec"
        trap 'rm -f "$_dec"' EXIT
    fi
    local file="$1"
    [ -f "$file" ] || { err "Файл не найден: $file"; exit 1; }
    local stage; stage="$(mktemp -d)"
    log "Распаковка $file…"
    tar -xzf "$file" -C "$stage"
    [ -f "$stage/MANIFEST" ] || { err "Не похоже на бэкап AntiZapret-AWG"; exit 1; }

    log "Восстановление файлов…"
    mkdir -p "$AWG_DIR" "$AZ/config" /etc/knot-resolver "$AZ/client" "$DEST"
    [ -d "$stage/openvpn/easyrsa3" ] && { rm -rf /etc/openvpn/easyrsa3; cp -r "$stage/openvpn/easyrsa3" /etc/openvpn/; }
    cp "$stage"/amneziawg/* "$AWG_DIR/" 2>/dev/null || true
    cp "$stage"/config/* "$AZ/config/" 2>/dev/null || true
    cp "$stage"/knot/* /etc/knot-resolver/ 2>/dev/null || true
    cp "$stage"/custom/* "$AZ/" 2>/dev/null || true
    cp -r "$stage/client/." "$AZ/client/" 2>/dev/null || true
    cp -r "$stage"/awgstate/* "$DEST/" 2>/dev/null || true
    chmod 600 "$AWG_DIR"/*.conf "$AWG_DIR"/*.v3 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    # Имена интерфейсов берём из восстановленного services.env: в режиме parallel
    # они называются antizapret-awg/vpn-awg, а не как ванильные.
    # shellcheck disable=SC1090
    [ -f "$AWG_DIR/services.env" ] && . "$AWG_DIR/services.env" 2>/dev/null || true
    if [ "${LAYER2:-1}" = 1 ]; then
        systemctl restart "awg-quick@${AZ_IFACE:-antizapret}" "awg-quick@${VPN_IFACE:-vpn}" \
            2>/dev/null || err "awg-quick не стартовал"
    fi
    if [ "${LAYER3:-0}" = 1 ]; then
        systemctl restart "awg3@${AZ3_IFACE:-antizapret-awg3}" "awg3@${VPN3_IFACE:-vpn-awg3}" \
            2>/dev/null || err "awg3 не стартовал"
    fi
    systemctl restart openvpn-server@antizapret openvpn-server@vpn 2>/dev/null || true
    systemctl restart knot-resolver 2>/dev/null || true
    bash "$AZ/doall.sh" 2>/dev/null || true      # пересобрать профили/маршрутизацию
    log "Восстановление завершено."
}

# --encrypt [пароль]: если пароль не передан, спросим (или возьмём BACKUP_PASS)
if [ "${2:-}" = "--encrypt" ] || [ "${3:-}" = "--encrypt" ]; then
    if [ -z "${BACKUP_PASS:-}" ]; then
        if [ -r /dev/tty ]; then
            read -rsp "Пароль для архива: " BACKUP_PASS < /dev/tty; echo >&2
        else
            err "нужен пароль: BACKUP_PASS=... awg-backup backup --encrypt"; exit 2
        fi
    fi
    export BACKUP_PASS
fi

case "${1:-}" in
    backup)  do_backup "$(printf '%s' "${2:-}" | grep -v '^--' || true)" ;;
    restore) [ $# -ge 2 ] || { err "Укажи файл: restore <файл.tar.gz>"; exit 2; }; do_restore "$2" ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
