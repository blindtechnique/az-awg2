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
# Каталог слоя. Раньше здесь стояло "$AZ/awg", то есть /root/antizapret/awg —
# путь, которого не создаёт никто. Настоящий знает соседний client-awg.sh:
# CLIENT_DIR="/opt/antizapret-awg/clients". Из-за расхождения ни stats.db, ни
# expiry.tsv в архив не попадали, а восстановление клало их обратно туда же.
DEST="/opt/antizapret-awg"

log() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[backup]\033[0m %s\n' "$*" >&2; }
server_ip() { ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+' || echo server; }

do_backup() {
    local out="${1:-$AZ/awg-backup-$(server_ip).tar.gz}"
    local rc=0
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
    cp "$DEST/expiry.tsv" "$stage/awgstate/" 2>/dev/null || true
    # Клиентские профили слоя. Приватные ключи клиентов есть ТОЛЬКО здесь — в
    # серверном конфиге лежат одни публичные, переиздать их нечем. Этой строки
    # не было вовсе: архив выглядел полным и не содержал главного.
    [ -d "$DEST/clients" ] && cp -r "$DEST/clients" "$stage/awgstate/" 2>/dev/null || true

    # stats.db простым cp копировать НЕЛЬЗЯ: база открыта в режиме WAL
    # (awg_stats.py: PRAGMA journal_mode=WAL), свежие записи живут в
    # stats.db-wal, а сам файл остаётся заголовком в 4 КиБ. Такая копия
    # открывается с «no such table» — теряется вся схема, а не часть данных.
    # Снимок через backup API sqlite корректен при живом писателе. Системный
    # python3, а не venv: venv создаётся только вместе с ботом.
    if [ -f "$DEST/stats.db" ]; then
        if ! python3 - "$DEST/stats.db" "$stage/awgstate/stats.db" <<'PYBK'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1], timeout=15)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PYBK
        then
            # Не rc=1: архив со всеми ключами, но без статистики — хороший
            # архив, а бот отдаёт файл только при нулевом коде.
            err "снимок stats.db не снят — статистика в архив не попала (ключи на месте)"
        fi
    fi

    # Считаем, что уехало. `[ -d ] && cp || true` гасит и промах условия, и
    # отказ копирования — только счёт отличает «клиентов нет» от «клиенты
    # есть, но в архив не попали».
    local n_src n_dst
    if [ -d "$DEST/clients" ]; then
        n_src="$(find "$DEST/clients" -name '*.conf' 2>/dev/null | wc -l || true)"
        n_dst="$(find "$stage/awgstate/clients" -name '*.conf' 2>/dev/null | wc -l || true)"
        if [ "$n_dst" != "$n_src" ]; then
            err "в архив попало $n_dst клиентских конфигов из $n_src в $DEST/clients"
            err "приватные ключи клиентов есть ТОЛЬКО там — такой архив их не восстановит"
            rc=1
        elif [ "$n_src" != 0 ]; then
            log "клиентских конфигов в архиве: $n_src"
        fi
    else
        log "$DEST/clients нет — клиентов ещё не выдавали"
    fi

    echo "AntiZapret-AWG backup $(date -u +%FT%TZ)" > "$stage/MANIFEST"
    tar -czf "$out" -C "$stage" .
    rm -rf "$stage"
    chmod 600 "$out"
    log "Готово: $out ($(du -h "$out" | cut -f1))"
    echo "$out"
    # Неполный архив не должен уезжать в чат как хороший: бот отдаёт файл
    # только при нулевом коде.
    return "$rc"
}

do_restore() {
    local file="$1"
    [ -f "$file" ] || { err "Файл не найден: $file"; exit 1; }
    # rc — накопитель: прогон НЕ обрывается на первом отказе (файлы уже
    # частично подменены, аварийный выход сделал бы хуже), но код возврата
    # обязан быть ненулевым. Бот печатает «✅ Восстановлено.» ровно по rc = 0 —
    # до сих пор эта галочка приходила всегда, в том числе на мёртвом сервере.
    local rc=0
    local stage; stage="$(mktemp -d)"
    log "Распаковка $file…"
    tar -xzf "$file" -C "$stage"
    [ -f "$stage/MANIFEST" ] || { err "Не похоже на бэкап AntiZapret-AWG"; exit 1; }

    log "Восстановление файлов…"
    mkdir -p "$AWG_DIR" "$AZ/config" /etc/knot-resolver "$AZ/client" "$DEST"
    # НЕ «снести и положить»: это единственный шаг восстановления, который
    # делает состояние ХУЖЕ исходного, а не просто неполным. Смерть между rm и
    # cp оставляла систему вообще без PKI ванильного OpenVPN, и взять его уже
    # неоткуда — в архиве он есть, но восстановление до него не дошло.
    # Кладём рядом, подменяем переименованием: окно сужается до одного rename.
    if [ -d "$stage/openvpn/easyrsa3" ]; then
        # Если ПРОШЛЫЙ прогон умер между двумя переименованиями, каталога нет,
        # а оригинал лежит в .old — вернём его до того, как что-то удалять.
        if [ ! -d /etc/openvpn/easyrsa3 ] && [ -d /etc/openvpn/easyrsa3.old ]; then
            err "прошлое восстановление оборвалось — возвращаю /etc/openvpn/easyrsa3 из .old"
            mv /etc/openvpn/easyrsa3.old /etc/openvpn/easyrsa3
        fi
        rm -rf /etc/openvpn/easyrsa3.restore
        cp -r "$stage/openvpn/easyrsa3" /etc/openvpn/easyrsa3.restore
        rm -rf /etc/openvpn/easyrsa3.old
        [ -d /etc/openvpn/easyrsa3 ] && mv /etc/openvpn/easyrsa3 /etc/openvpn/easyrsa3.old
        mv /etc/openvpn/easyrsa3.restore /etc/openvpn/easyrsa3
        rm -rf /etc/openvpn/easyrsa3.old
    fi
    cp "$stage"/amneziawg/* "$AWG_DIR/" 2>/dev/null || true
    cp "$stage"/config/* "$AZ/config/" 2>/dev/null || true
    cp "$stage"/knot/* /etc/knot-resolver/ 2>/dev/null || true
    cp "$stage"/custom/* "$AZ/" 2>/dev/null || true
    cp -r "$stage/client/." "$AZ/client/" 2>/dev/null || true
    # Клиентские ключи, stats.db и сроки. Пустой каталог здесь означает не
    # отказ копирования, а архив без ключей — и тот, кто на него рассчитывает,
    # обязан это узнать.
    if [ -n "$(ls -A "$stage/awgstate" 2>/dev/null || true)" ]; then
        cp -r "$stage"/awgstate/* "$DEST/" || {
            err "не скопированы клиентские ключи и статистика в $DEST"; rc=1; }
    else
        err "в архиве нет клиентских ключей, stats.db и сроков: он снят версией,"
        err "в которой awg-backup смотрел в несуществующий /root/antizapret/awg."
        err "Сервер восстановится, но выданные клиентам конфиги — нет."
        rc=1
    fi
    # Осиротевшие журналы прежней базы. Без этого sqlite при следующем открытии
    # проигрывает старый -wal ПОВЕРХ положенного файла и отдаёт данные прежней
    # установки вместо восстановленных — молча, без ошибки.
    rm -f "$DEST/stats.db-wal" "$DEST/stats.db-shm"
    chmod 600 "$AWG_DIR"/*.conf 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    # 2>/dev/null снято сознательно: только так причина отказа доезжает до
    # бота — он показывает stderr исключительно при ненулевом коде.
    _svc() {  # _svc <что сломается, если не встанет> <юнит>...
        local why="$1"; shift
        systemctl restart "$@" || {
            err "не перезапущено: $* — $why"
            err "  смотри: journalctl -u $1 -n 30 --no-pager"
            rc=1
        }
    }
    _svc "тоннель не поднят, не подключится никто" awg-quick@antizapret awg-quick@vpn
    _svc "OpenVPN остался на прежнем PKI в памяти" \
        openvpn-server@antizapret openvpn-server@vpn
    _svc "раздельный DNS не применён — весь смысл AntiZapret" knot-resolver
    if [ -f "$AZ/doall.sh" ]; then
        bash "$AZ/doall.sh" || {          # пересобрать профили/маршрутизацию
            err "doall.sh не отработал — восстановленные списки не применены,"
            err "трафик пойдёт мимо VPN. Повтори: bash $AZ/doall.sh"
            rc=1; }
    else
        err "нет $AZ/doall.sh — списки и маршрутизация не пересобраны"; rc=1
    fi
    log "Восстановление завершено."
    [ "$rc" = 0 ] || err "восстановление доехало НЕ полностью — что именно, сказано выше."
    return "$rc"
}

case "${1:-}" in
    backup)  do_backup "${2:-}" ;;
    restore) [ $# -ge 2 ] || { err "Укажи файл: restore <файл.tar.gz>"; exit 2; }; do_restore "$2" ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
