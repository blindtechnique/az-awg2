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
    cp "$AZ"/config/*.txt "$stage/config/" 2>/dev/null || true
    cp /etc/knot-resolver/*.lua "$stage/knot/" 2>/dev/null || true
    cp "$AZ"/custom*.sh "$stage/custom/" 2>/dev/null || true
    [ -d "$AZ/client" ] && cp -r "$AZ/client/." "$stage/client/" 2>/dev/null || true
    cp "$DEST/stats.db" "$DEST/expiry.tsv" "$stage/awgstate/" 2>/dev/null || true

    echo "AntiZapret-AWG backup $(date -u +%FT%TZ)" > "$stage/MANIFEST"
    tar -czf "$out" -C "$stage" .
    rm -rf "$stage"
    chmod 600 "$out"
    log "Готово: $out ($(du -h "$out" | cut -f1))"
    echo "$out"
}

do_restore() {
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
    cp "$stage"/awgstate/* "$DEST/" 2>/dev/null || true
    chmod 600 "$AWG_DIR"/*.conf 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    systemctl restart awg-quick@antizapret awg-quick@vpn 2>/dev/null || err "awg-quick не стартовал"
    systemctl restart openvpn-server@antizapret openvpn-server@vpn 2>/dev/null || true
    systemctl restart knot-resolver 2>/dev/null || true
    bash "$AZ/doall.sh" 2>/dev/null || true      # пересобрать профили/маршрутизацию
    log "Восстановление завершено."
}

case "${1:-}" in
    backup)  do_backup "${2:-}" ;;
    restore) [ $# -ge 2 ] || { err "Укажи файл: restore <файл.tar.gz>"; exit 2; }; do_restore "$2" ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
