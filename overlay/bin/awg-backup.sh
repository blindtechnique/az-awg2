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
# Метка незавершённого восстановления — по образцу .migrate-in-progress.
RESTORE_MARK="$AWG_DIR/.restore-in-progress"
AZ="/root/antizapret"
# Каталог слоя. Раньше здесь стояло "$AZ/awg", то есть /root/antizapret/awg —
# путь, которого не создаёт никто: весь остальной репозиторий (install.sh,
# antizapret-awg-integration.sh, awg-doctor.sh, awg_stats.py, client-awg.sh)
# знает только /opt/antizapret-awg. Из-за этого `[ -d "$DEST/clients" ]` был
# всегда ложен, и в архив НЕ попадали ни клиентские приватные ключи (а они
# существуют только там), ни stats.db, ни expiry.tsv — молча, потому что
# рядом стоял `|| true`. Восстановление клало их обратно в тот же мёртвый
# путь. Архив выглядел полным и не содержал главного.
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

    # Пересчитываем то, что уехало. Условие выше годами было ложным из-за
    # неверного DEST, и никто этого не заметил: `|| true` гасит и промах
    # условия, и отказ cp. Считать — единственный способ отличить «клиентов
    # нет» от «клиенты есть, но в архив не попали».
    local n_src n_dst
    if [ -d "$DEST/clients" ]; then
        # `|| true` обязателен: под pipefail отказ find роняет присваивание, а
        # значит и весь прогон — ровно в том случае, который надо сообщить.
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
    # Ненулевой код здесь означает «архив собран, но неполон». Бот отдаёт файл
    # только при rc = 0 (awg_bot.py:1396) — и это правильно: неполный архив,
    # уехавший в чат как хороший, обнаруживается только в день, когда по нему
    # пытаются восстановиться.
    return "$rc"
}

do_restore() {
    local _orig_arg="${1:-}"
    # зашифрованный архив расшифровываем во временный файл
    if [ "${1:-}" != "${1%.enc}" ]; then
        if [ -z "${BACKUP_PASS:-}" ]; then
            [ -r /dev/tty ] && { read -rsp "Пароль архива: " BACKUP_PASS < /dev/tty; echo >&2; }
            # export обязателен: openssl читает пароль ИЗ ОКРУЖЕНИЯ
            # (-pass env:…), а read создаёт обычную переменную оболочки.
            # Без него введённый с клавиатуры правильный пароль давал
            # «No environment variable BACKUP_PASS» и, с заглушённым stderr,
            # сообщение «неверный пароль или битый архив». То есть
            # восстановление зашифрованного архива в интерактиве не работало
            # никогда — работал только путь BACKUP_PASS=… в окружении.
            # На стороне создания архива export уже стоит, ниже по файлу.
            export BACKUP_PASS
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
    # rc — накопитель: прогон НЕ обрывается на первом отказе (сервер уже
    # частично переехал, аварийный выход сделал бы хуже), но код возврата
    # обязан быть ненулевым. Бот печатает «✅ Восстановлено.» ровно по rc = 0
    # (awg_bot.py:1424) и строкой раньше удаляет присланный архив — до сих пор
    # эта галочка приходила всегда, в том числе на мёртвом сервере.
    # svc — отдельно: только он решает судьбу метки, потому что метка говорит
    # именно про «файлы новые, сервисы старые».
    local rc=0 svc=0
    # Путь, который назвал владелец, а не расшифрованная копия в /tmp: её к
    # моменту повтора уже не будет, а в метке нужен работающий совет.
    local orig="$_orig_arg"
    local stage; stage="$(mktemp -d)"
    log "Распаковка $file…"
    tar -xzf "$file" -C "$stage"
    [ -f "$stage/MANIFEST" ] || { err "Не похоже на бэкап AntiZapret-AWG"; exit 1; }

    log "Восстановление файлов…"
    mkdir -p "$AWG_DIR" "$AZ/config" /etc/knot-resolver "$AZ/client" "$DEST"
    # Метка — по образцу .migrate-in-progress. Ставится ДО первой разрушающей
    # записи и снимается только если сервисы поднялись. Она переживает
    # перезагрузку и оборванный ssh, и её видит awg-doctor: это канал для
    # владельца, который вывод прогона не читал.
    # Имя с точки: cp по маске * его не затрёт и в следующий архив он не уедет.
    {
        printf 'MARK_STARTED=%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '?')"
        printf 'MARK_ARCHIVE=%s\n' "$orig"
    } > "$RESTORE_MARK"
    # НЕ «снести и положить»: это единственный шаг восстановления, который
    # делает состояние хуже исходного, а не просто неполным. Смерть между rm и
    # cp оставляла систему вообще без PKI ванильного OpenVPN, и взять его уже
    # неоткуда — в архиве он есть, но восстановление до него не дошло.
    # Кладём рядом, подменяем переименованием: окно сужается до одного rename.
    if [ -d "$stage/openvpn/easyrsa3" ]; then
        # Если ПРОШЛЫЙ прогон умер между двумя переименованиями ниже, каталога
        # easyrsa3 нет, а оригинал лежит в .old. Возвращаем его на место до
        # того, как что-либо удалять: без этого `rm -rf …old` четырьмя
        # строками ниже сносил единственную уцелевшую копию, и повтор,
        # умерший в том же окне, не оставлял вообще ничего.
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
    # Каталог клиентских ключей, stats.db и expiry.tsv. Архивы, снятые до
    # починки DEST, здесь пусты — и это не отказ копирования, а отсутствие
    # данных, о котором обязан узнать тот, кто на этот архив рассчитывает.
    if [ -n "$(ls -A "$stage/awgstate" 2>/dev/null || true)" ]; then
        cp -r "$stage"/awgstate/* "$DEST/" || {
            err "не скопированы клиентские ключи и статистика в $DEST"; rc=1; }
    else
        err "в архиве нет клиентских ключей, stats.db и сроков: он снят версией,"
        err "в которой awg-backup смотрел в несуществующий /root/antizapret/awg."
        err "Сервер восстановится, но выданные клиентам конфиги — нет."
        rc=1
    fi
    chmod 600 "$AWG_DIR"/*.conf "$AWG_DIR"/*.v3 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    # Имена интерфейсов берём из восстановленного services.env: в режиме parallel
    # они называются antizapret-awg/vpn-awg, а не как ванильные.
    # shellcheck disable=SC1090
    if [ -f "$AWG_DIR/services.env" ]; then
        # shellcheck disable=SC1090
        . "$AWG_DIR/services.env" 2>/dev/null || { err "services.env битый"; rc=1; }
    else
        err "services.env не восстановлен — план сервисов взят из умолчаний,"
        err "а в режиме parallel интерфейсы зовутся иначе, чем ванильные."
        rc=1; svc=1
    fi
    # 2>/dev/null снято сознательно: только так причина отказа доезжает до
    # бота — он показывает stderr исключительно при ненулевом коде.
    _svc() {  # _svc <что сломается, если не встанет> <юнит>...
        local why="$1"; shift
        systemctl restart "$@" || {
            err "не перезапущено: $* — $why"
            err "  смотри: journalctl -u $1 -n 30 --no-pager"
            rc=1; svc=1
        }
    }
    if [ "${LAYER2:-1}" = 1 ]; then
        _svc "тоннель 2.0 не поднят, не подключится никто" \
            "awg-quick@${AZ_IFACE:-antizapret}" "awg-quick@${VPN_IFACE:-vpn}"
    fi
    if [ "${LAYER3:-0}" = 1 ]; then
        _svc "тоннель 3.0 не поднят" \
            "awg3@${AZ3_IFACE:-antizapret-awg3}" "awg3@${VPN3_IFACE:-vpn-awg3}"
    fi
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
    # Метку снимает только успешный перезапуск: она и означает «файлы новые,
    # сервисы старые». Всё остальное уже сказано выше и живёт в коде возврата.
    if [ "$svc" = 0 ]; then rm -f "$RESTORE_MARK"; fi
    log "Восстановление завершено."
    if [ "$rc" != 0 ]; then
        err "восстановление доехало НЕ полностью — что именно, сказано выше."
        [ "$svc" = 0 ] || err "метка $RESTORE_MARK оставлена: awg-doctor напомнит."
    fi
    return "$rc"
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
