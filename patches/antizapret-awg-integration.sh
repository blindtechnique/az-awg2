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
#   --preset3 X --template3 Y    обфускация ОТДЕЛЬНО для слоя 3.0 (пусто = как 2.0)
#   --az3-port N / --vpn3-port N порты слоя 3.0 вручную (иначе рандом)
#   --update    обновить код/сервисы БЕЗ смены обфускации и портов
#   --reconfigure  выпустить НОВЫЙ профиль обфускации (клиентам нужен переимпорт)
#   --plan      показать, что сделает прогон, и выйти, ничего не изменив
#   --migrate   миграция старых режимов (replace/keep) на parallel
set -euo pipefail

PRESET="medium"; TEMPLATE=""; FP="chrome"; MTU=1320; HOST=""
UPDATE=0; MIGRATE=0; CLI_AZ_PORT=""; CLI_VPN_PORT=""
# Слой 3.0 настраивается отдельно. Пусто = «как у слоя 2.0»: именно так вели
# себя все установки до появления раздельных пресетов, и менять им профиль
# молча нельзя. Объявляем здесь, потому что скрипт работает под set -u.
RECONFIGURE=0
PLAN=0
PRESET3=""; TEMPLATE3=""; CLI_AZ3_PORT=""; CLI_VPN3_PORT=""
# какие версии протокола поднимать: 2 | 3 | both
AWG_VER="both"
# версии апстрима для слоя 3.0 (переопределяются переменными окружения)
# Последний тег серии 3.0. На 3.1 (RandomTrailers, DisableCookies) сознательно
# не идём: kernel-модуль issue #215 и amnezia-client issue #3043 — обе «хендшейк
# проходит, трафика нет», обе открыты без ответа мейнтейнеров, и #3043 прямо
# сообщает, что userspace 3.1 и kernel-модуль 3.1 ведут себя одинаково.
AWG_GO_REF="${AWG_GO_REF:-v3.0.20260805}"
# AWG_TOOLS_REF здесь больше нет: утилиты awg/awg-quick слой 2.0 берёт из PPA
# (install_awg), а слой 3.0 общается с датапасом через UAPI-сокет и от версии
# утилит не зависит. Переменная объявлялась, но не использовалась нигде —
# читатель считал, что версия зафиксирована, хотя это было не так.
SRC=/opt/src
while [ $# -gt 0 ]; do
    case "$1" in
        --awg) AWG_VER="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --fp) FP="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --az-port) CLI_AZ_PORT="$2"; shift 2 ;;
        --vpn-port) CLI_VPN_PORT="$2"; shift 2 ;;
        --preset3) PRESET3="$2"; shift 2 ;;
        --template3) TEMPLATE3="$2"; shift 2 ;;
        --az3-port) CLI_AZ3_PORT="$2"; shift 2 ;;
        --vpn3-port) CLI_VPN3_PORT="$2"; shift 2 ;;
        --update) UPDATE=1; shift ;;
        --plan) PLAN=1; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
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
# Метка незавершённой миграции: лежит рядом с планом сервисов, содержит режим,
# из которого мигрировали. Существует только между началом и концом do_migrate.
MIGRATE_MARK="$AWG_DIR/.migrate-in-progress"
# Взводится, если конфиги клиентов пересоздать не удалось. Прогон при этом
# доводится до конца — сервер уже настроен, — но код возврата обязан быть
# ненулевым: «не подключится никто» с нулём автоматика читает как успех.
_regen_failed=0

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

# Поле берём с конца, а не по номеру: `ss -lunH` печатает колонку Netid не
# на всех версиях iproute2 (при фильтре по одному протоколу она опускается),
# и жёсткий $4/$5 угадывает лишь на одной из раскладок. Локальный адрес —
# предпоследнее поле в любой. `|| true` обязателен: когда UDP-слушателей нет
# вовсе, grep не находит ничего и отдаёт 1, а pipefail протаскивает это в
# подстановку, где вызов стоит первым.
#
# До этой правки здесь стояло $5 — колонка Peer, «0.0.0.0:*». Она не
# заканчивается цифрой, поэтому список занятых портов был ПУСТ ВСЕГДА, а сам
# вызов возвращал 1 и ронял присваивание exclude под set -e.
busy_ports() { ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -oE '[0-9]+$' | sort -u || true; }

pick_random_port() {  # pick_random_port [исключить...] — свободный порт 20000-59999
    local exclude p tries=0
    # RESERVED_PORTS разделены пробелами, busy_ports отдаёт по строке на порт.
    # Приводим к одному разделителю СРАЗУ: сравнение ниже ищет " $p " и на
    # переводах строк промахнулось бы, вернув занятый порт как свободный.
    exclude="$RESERVED_PORTS $(busy_ports) $*"
    exclude="${exclude//$'\n'/ }"
    while :; do
        p="$(shuf -i 20000-59999 -n 1)"
        # Без трубы намеренно: `printf | grep -q` под pipefail отдаёт 141,
        # когда совпадение нашлось в начале длинного списка (grep выходит по
        # первому совпадению, printf ловит SIGPIPE). 141 ≠ 0 — то есть ветка
        # || срабатывала, и ЗАНЯТЫЙ порт объявлялся свободным, а на первой
        # установке он закрепляется в services.env навсегда.
        case " $exclude " in
            *" $p "*) ;;                        # занят — берём следующий
            *) echo "$p"; return 0 ;;
        esac
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
        # keyserver.ubuntu.com. Метод по гайду mk16.de (проверен на Debian 13).
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

# ── 1b. amneziawg-go для слоя 3.0 ────────────────────────────────────────────
# Параметры 3.0 kernel-модуль уже знает — апстрим влил их в master 30.07.2026
# (PR #192). Но переезд отложен: на модуле открыты регрессии #215 и
# amnezia-client #3043, «хендшейк проходит, трафика нет». Поэтому 3.0 работает
# на userspace-демоне, который приходится собирать из исходников: пакетов нет.
# Слою 2.0 это никак не мешает — он остаётся на модуле.
install_awg3() {
    # Раньше здесь стояла проверка «бинарник на месте — выходим», без сверки
    # версии. Из-за неё пин AWG_GO_REF не действовал ни на одном установленном
    # сервере: awg-upstream-check сообщал о новой версии, обновление молча
    # ничего не делало, и уведомление приходило снова. Сверяем ревизию
    # исходников — она надёжнее строки версии и уже так используется в
    # overlay/bin/awg-upstream-check.sh.
    if command -v amneziawg-go >/dev/null 2>&1 && command -v awg >/dev/null 2>&1; then
        local cur
        cur="$(git -C "$SRC/amneziawg-go" describe --tags --exact-match 2>/dev/null || true)"
        if [ "$cur" = "$AWG_GO_REF" ]; then
            log "amneziawg-go $cur — актуален"
            return 0
        fi
        log "amneziawg-go ${cur:-неизвестной версии} → $AWG_GO_REF: пересборка…"
        AWG_GO_REBUILT=1
    fi
    export DEBIAN_FRONTEND=noninteractive GOFLAGS=-buildvcs=false
    apt-get install -y -qq build-essential git make curl ca-certificates >/dev/null
    install_go3
    export PATH="$PATH:/usr/local/go/bin"
    mkdir -p "$SRC"
    if [ ! -d "$SRC/amneziawg-go/.git" ]; then
        git clone -q https://github.com/amnezia-vpn/amneziawg-go.git "$SRC/amneziawg-go"
    fi
    cd "$SRC/amneziawg-go"; git fetch -q --all --tags; git checkout -q "$AWG_GO_REF"
    log "Сборка amneziawg-go $AWG_GO_REF (userspace-датапас для 3.0)…"
    make >/dev/null
    install -m0755 amneziawg-go /usr/local/bin/amneziawg-go
    # awg/awg-quick уже стоят из PPA для слоя 2.0 — не трогаем, версия совместима
    log "amneziawg-go установлен"
}

install_go3() {
    local want ver sha tgz
    if command -v go >/dev/null 2>&1; then
        # `|| true` на весь конвейер: command -v выше подтверждает наличие
        # файла, но не работоспособность. Битый GOROOT после оборванной
        # установки или чужая архитектура дают ненулевой код, и присваивание
        # убивало установщик ДО строки «Установка Go». Пустой ver ниже уже
        # трактуется как «не годится» и ведёт к переустановке.
        ver="$(go version 2>/dev/null | awk '{print $3}' || true)"
        # amneziawg-go 3.0 требует go >= 1.25 (его go.mod)
        [ "$(printf '%s\ngo1.25.0\n' "$ver" | sort -V | head -1)" = "go1.25.0" ] && return 0
    fi
    log "Установка Go с go.dev…"
    # `|| true` обязателен: без сети curl отдаёт ненулевой код, pipefail его
    # протаскивает, и присваивание убивало прогон ДО строки ниже — той самой,
    # что должна была сказать «не удалось узнать версию Go».
    want="$(curl -fsSL https://go.dev/VERSION?m=text | head -1 || true)"
    [ -n "$want" ] || { err "не удалось узнать версию Go"; exit 1; }
    tgz="${want}.linux-$(dpkg --print-architecture).tar.gz"
    sha="$(curl -fsSL 'https://go.dev/dl/?mode=json' | python3 -c "
import json,sys
want=sys.argv[1]; f=sys.argv[2]
for rel in json.load(sys.stdin):
    if rel.get('version')==want:
        for fl in rel.get('files',[]):
            if fl.get('filename')==f: print(fl.get('sha256','')); break
" "$want" "$tgz" || true)"
    [ -n "$sha" ] || { err "не нашёл sha256 для $tgz"; exit 1; }
    mkdir -p "$SRC"; cd "$SRC"
    curl -fsSLO "https://go.dev/dl/$tgz"
    echo "$sha  $tgz" | sha256sum -c - >/dev/null || { err "контрольная сумма Go не сошлась"; exit 1; }
    rm -rf /usr/local/go && tar -C /usr/local -xzf "$tgz" && rm -f "$tgz"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
}

# ── 2. overlay ───────────────────────────────────────────────────────────────
deploy_overlay() {
    log "Развёртывание overlay в $DEST"
    mkdir -p "$DEST"
    cp "$OVERLAY/obfuscation/awg_obfuscate.py" "$OVERLAY/bin/awg-obfuscation.sh" \
       "$OVERLAY/bin/awg-export.py" "$OVERLAY/bin/client-awg.sh" \
       "$OVERLAY/bin/awg-backup.sh" "$OVERLAY/bin/awg-reintegrate.sh" \
       "$OVERLAY/bin/awg-knot-view.sh" "$OVERLAY/bin/az_setup_runner.py" \
       "$OVERLAY/bin/awg_stats.py" \
       "$OVERLAY/bin/awg3-datapath.sh" "$OVERLAY/bin/awg3-uapi.py" \
       "$OVERLAY/obfuscation/awg3_obfuscate.py" \
       "$OVERLAY/bin/awg-doctor.sh" "$OVERLAY/bin/awg-selftest.py" \
       "$OVERLAY/bin/awg-upstream-check.sh" "$DEST/" 2>/dev/null || true
    chmod +x "$DEST"/*.sh "$DEST"/*.py 2>/dev/null || true
    ln -sf "$DEST/awg-obfuscation.sh" /usr/local/bin/awg-obfuscation
    ln -sf "$DEST/client-awg.sh" /usr/local/bin/awg-client
    ln -sf "$DEST/awg-backup.sh" /usr/local/bin/awg-backup
    ln -sf "$DEST/awg-doctor.sh" /usr/local/bin/awg-doctor
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
    # зафиксировать текущую ревизию слоя (HEAD форка) — для проверки обновлений.
    # берём из git-репозитория, откуда запущена установка, или через ls-remote.
    # ветку запоминаем отдельно: awg-upstream-check сравнивает ревизию именно
    # с ней, иначе установка с beta вечно «отставала» бы от main
    local branch; branch="$(git -C "$OVERLAY/.." rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ -n "$branch" ] && [ "$branch" != HEAD ] || branch="${AWG_REPO_BRANCH:-main}"
    echo "$branch" > "$DEST/.layer-branch"
    ( rev="$(git -C "$OVERLAY/.." rev-parse --short=12 HEAD 2>/dev/null)"
      [ -z "$rev" ] && rev="$(git ls-remote https://github.com/blindtechnique/az-awg2.git "refs/heads/$branch" 2>/dev/null | cut -c1-12)"
      [ -n "$rev" ] && echo "$rev" > "$DEST/.layer-rev" ) 2>/dev/null || true
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

    AZ_IFACE=antizapret-awg;  VPN_IFACE=vpn-awg
    # Подсети закрепляем так же, как порты: от них зависят Address и AllowedIPs
    # всех выданных конфигов. Пересчёт из конфига ванили на каждом прогоне
    # означал бы, что её переезд на другой диапазон уводит сервер, а у клиентов
    # остаётся прежний адрес — regen-all это не чинит, он адреса не трогает.
    local pin_az="" pin_vpn="" pin_az3="" pin_vpn3=""
    if [ -f "$SERVICES" ]; then
        # shellcheck disable=SC1090
        pin_az="$(. "$SERVICES" 2>/dev/null; echo "${AZ_SUBNET:-}")"
        # shellcheck disable=SC1090
        pin_vpn="$(. "$SERVICES" 2>/dev/null; echo "${VPN_SUBNET:-}")"
        # Слой 3.0 закрепляется ТАК ЖЕ. Раньше он пересчитывался на каждом
        # прогоне, то есть обоснование выше было написано и не применено к нему
        # двумя строками ниже. Достижимо не только настоящим переездом ванили:
        # _subnet_of при нечитаемом её конфиге отдаёт запасное значение, и один
        # такой прогон навсегда сдвигал подсети 3.0, пока у клиентов оставался
        # прежний Address.
        # shellcheck disable=SC1090
        pin_az3="$(. "$SERVICES" 2>/dev/null; echo "${AZ3_SUBNET:-}")"
        # shellcheck disable=SC1090
        pin_vpn3="$(. "$SERVICES" 2>/dev/null; echo "${VPN3_SUBNET:-}")"
    fi
    AZ_SUBNET="${pin_az:-${az_base%.*}.$(( ${az_base##*.} + 1 ))}"
    VPN_SUBNET="${pin_vpn:-${vpn_base%.*}.$(( ${vpn_base##*.} + 1 ))}"
    MODE=parallel

    # Слой 3.0 — ещё +1 к третьему октету, чтобы не пересечься со слоем 2.0.
    # Правила ванильного AntiZapret ходят по агрегатам /15 и /16, поэтому
    # NAT/DNS/защиты покрывают и эти подсети автоматически.
    AZ3_IFACE=antizapret-awg3
    AZ3_SUBNET="${pin_az3:-${az_base%.*}.$(( ${az_base##*.} + 2 ))}"
    VPN3_IFACE=vpn-awg3
    VPN3_SUBNET="${pin_vpn3:-${vpn_base%.*}.$(( ${vpn_base##*.} + 2 ))}"
    # у 3.0 транспортный паддинг S4 отъедает место — MTU ниже, чем у 2.0
    MTU3=1380

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

    # порты слоя 3.0 — тоже закрепляются один раз
    local pinned_az3="" pinned_vpn3=""
    if [ -f "$SERVICES" ]; then
        pinned_az3="$(. "$SERVICES" 2>/dev/null; echo "${AZ3_PORT:-}")"
        pinned_vpn3="$(. "$SERVICES" 2>/dev/null; echo "${VPN3_PORT:-}")"
    fi
    # Порядок важен: явно заданный порт сильнее закреплённого, закреплённый —
    # сильнее случайного. Раньше порты 3.0 всегда были случайными, задать их
    # было нечем.
    AZ3_PORT="${CLI_AZ3_PORT:-${pinned_az3:-$(pick_random_port "$AZ_PORT" "$VPN_PORT")}}"
    VPN3_PORT="${CLI_VPN3_PORT:-${pinned_vpn3:-$(pick_random_port "$AZ_PORT" "$VPN_PORT" "$AZ3_PORT")}}"

    # какие слои считаем установленными
    case "$AWG_VER" in
        2)    LAYER2=1; LAYER3=0 ;;
        3)    LAYER2=0; LAYER3=1 ;;
        *)    LAYER2=1; LAYER3=1 ;;
    esac
    # Запись вынесена к вызывающему: без этого --plan писал бы services.env,
    # то есть «показать, ничего не делая» было бы неправдой.
    log "Режим: parallel · подсети antizapret=$AZ_SUBNET.0/24 vpn=$VPN_SUBNET.0/24"
    log "Порты AmneziaWG: antizapret=$AZ_PORT vpn=$VPN_PORT (закреплены) · DNS=$SERVER_DNS"
}

write_services() {
    # Дойти сюда в режиме --plan можно только по ошибке в коде. Записать молча
    # значило бы соврать: пользователь просил показать, а не сделать.
    if [ "$PLAN" = 1 ]; then
        err "внутренняя ошибка: запись services.env в режиме --plan"
        exit 1
    fi
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
# ── слой AmneziaWG 3.0 (userspace amneziawg-go) ──
LAYER2=$LAYER2
LAYER3=$LAYER3
AZ3_IFACE=$AZ3_IFACE
AZ3_PORT=$AZ3_PORT
AZ3_SUBNET=$AZ3_SUBNET
AZ3_DNS=$SERVER_DNS
AZ3_SPLIT=1
VPN3_IFACE=$VPN3_IFACE
VPN3_PORT=$VPN3_PORT
VPN3_SUBNET=$VPN3_SUBNET
VPN3_DNS=$SERVER_DNS
VPN3_SPLIT=0
MTU3=$MTU3
EOF
}

# ── слой 3.0: интерфейсы, профиль обфускации, юниты ─────────────────────────
# Ключ сервера наследуется из своего же конфига, как и у слоя 2.0, — чтобы
# переустановка не выбивала уже розданных клиентов.
build_iface3() {
    local name="$1" subnet="$2" port="$3"
    local conf="$AWG_DIR/${name}.conf" priv="" peers=""
    # `|| true` обязателен: код функции — это код конвейера, а grep без
    # совпадения отдаёт 1. Присваивания ниже — простые, в теле if, поэтому
    # маскировки нет: build_iface умирал молча, и заготовленные ветки
    # «ключ отсутствует или битый» были недостижимы именно тогда, когда нужны
    # (конфиг перезаписывается усекающим редиректом — прерывание в этом окне
    # оставляет файл без строки PrivateKey). Пустую строку отбракует _valid_key.
    _extract_key3() { grep '^PrivateKey' "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t' || true; }
    _valid_key3()   { [ -n "$1" ] && printf '%s' "$1" | awg pubkey >/dev/null 2>&1; }
    if [ -f "$conf" ]; then
        priv="$(_extract_key3 "$conf")"
        peers="$(awk '/^\[Peer\]/{p=1} p{print}' "$conf")"
    fi
    if _valid_key3 "$priv"; then
        log "Интерфейс $name: ключ сервера сохранён"
    else
        priv="$(awg genkey)"
        log "Интерфейс $name: сгенерирован новый ключ"
    fi
    umask 077
    {
        echo "# AntiZapret-AWG — серверный интерфейс $name (слой 3.0)"
        echo "# Параметры 3.0 лежат отдельно в ${name}.v3: awg setconf их не понимает."
        echo "[Interface]"
        echo "PrivateKey = $priv"
        echo "Address = ${subnet}.1/24"
        echo "ListenPort = $port"
        echo "MTU = $MTU3"
        echo "__AWG3_OBFUSCATION__"
        [ -n "$peers" ] && { echo; printf '%s\n' "$peers"; }
    } > "$conf"
    chmod 600 "$conf"
    # параметры интерфейса для датапаса. NAT=0: за него отвечает AntiZapret,
    # свой MASQUERADE дал бы двойной NAT
    {
        echo "SUBNET=${subnet}.0/24"
        echo "PORT=$port"
        echo "NAT=0"
        echo "DNS=$SERVER_DNS"
    } > "$AWG_DIR/${name}.env"
    chmod 600 "$AWG_DIR/${name}.env"
}

build_interfaces3() {
    build_iface3 "$AZ3_IFACE"  "$AZ3_SUBNET"  "$AZ3_PORT"
    build_iface3 "$VPN3_IFACE" "$VPN3_SUBNET" "$VPN3_PORT"
}

gen_obfuscation3() {
    # Пусто — берём настройки слоя 2.0: так вели себя все установки до
    # появления раздельных пресетов, и молча менять им профиль нельзя.
    local p3="${PRESET3:-$PRESET}" t3="${TEMPLATE3:-$TEMPLATE}"
    # Пояснения — строго ДО строки с переносом: комментарий между `\` и
    # командой рвёт перенос, и префикс окружения становится обычным
    # присваиванием в текущей оболочке, до дочернего процесса не доходя.
    local mode3; mode3="$(obf_mode "$AWG_DIR/obfuscation3.env")"
    if [ "$mode3" = --reapply ]; then
        log "Профиль обфускации 3.0: применяется существующий (клиенты не трогаются)"
    else
        log "Профиль обфускации 3.0: preset=$p3 template=${t3:-default}"
    fi
    AWG3_AZ_CONF="$AWG_DIR/${AZ3_IFACE}.conf" AWG3_VPN_CONF="$AWG_DIR/${VPN3_IFACE}.conf" \
        "$DEST/awg-obfuscation.sh" --v3 --preset "$p3" ${t3:+--template "$t3"} \
        --fp "$FP" --mtu "$MTU3" ${HOST:+--host "$HOST"} "$mode3"
}

switch_services3() {
    cp "$OVERLAY/systemd/awg3@.service" /etc/systemd/system/awg3@.service
    systemctl daemon-reload
    systemctl enable "awg3@${AZ3_IFACE}" "awg3@${VPN3_IFACE}" >/dev/null 2>&1 || true
    local i
    for i in "$AZ3_IFACE" "$VPN3_IFACE"; do
        systemctl stop "awg3@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true
    done
    local failed=0
    for i in "$AZ3_IFACE" "$VPN3_IFACE"; do
        systemctl start "awg3@$i" 2>/dev/null && continue
        failed=1
        err "слой 3.0: awg3@$i не стартовал. Последние строки журнала:"
        journalctl -u "awg3@$i" -n 12 --no-pager 2>/dev/null | sed 's/^/    /' >&2
    done
    # Раньше здесь при любом исходе печаталось «Слой 3.0 поднят» — прямо после
    # сообщения об ошибке. Теперь итог соответствует тому, что произошло.
    if [ "$failed" = 0 ]; then
        log "Слой 3.0 поднят: $AZ3_IFACE (порт $AZ3_PORT), $VPN3_IFACE (порт $VPN3_PORT)"
    else
        err "слой 3.0 не поднялся; слой 2.0 и ваниль не затронуты. Диагностика: awg-doctor"
    fi
}

# внешний хост (домен/IP) для Endpoint клиентов.
# ВНИМАНИЕ: $AWG_DIR/server_host сегодня не читает НИКТО — ни client-awg.sh
# (он берёт WIREGUARD_HOST из /root/antizapret/setup), ни бот, ни доктор.
# Полагаться на него нельзя ещё и потому, что он уезжает в архив и после
# переноса содержит адрес прежней машины.
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
    # `|| true` обязателен: код функции — это код конвейера, а grep без
    # совпадения отдаёт 1. Присваивания ниже — простые, в теле if, поэтому
    # маскировки нет: build_iface умирал молча, и заготовленные ветки
    # «ключ отсутствует или битый» были недостижимы именно тогда, когда нужны
    # (конфиг перезаписывается усекающим редиректом — прерывание в этом окне
    # оставляет файл без строки PrivateKey). Пустую строку отбракует _valid_key.
    _extract_key() { grep '^PrivateKey' "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t' || true; }
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
# НОВЫЙ профиль — только по явному --reconfigure. Иначе раскладываем
# существующий: он уже согласован с выданными клиентами, и перевыпуск оборвал
# бы связь всем сразу. Файл проверяется для КАЖДОГО слоя отдельно — общая
# проверка по чужому перевыпускала бы клиентов на пустом месте.
#
# Функция одна на реальный прогон и на --plan: два разных вычисления одного
# решения рано или поздно разойдутся, и план начнёт врать.
obf_mode() {  # obf_mode <файл профиля> → --apply | --reapply
    if [ "$RECONFIGURE" != 1 ] && [ -s "$1" ]; then echo --reapply; else echo --apply; fi
}

gen_obfuscation() {
    local mode; mode="$(obf_mode "$AWG_DIR/obfuscation.env")"
    if [ "$mode" = --reapply ]; then
        log "Профиль обфускации 2.0: применяется существующий (клиенты не трогаются)"
    else
        log "Профиль обфускации 2.0: preset=$PRESET template=${TEMPLATE:-default}"
    fi
    AWG_AZ_CONF="$AWG_DIR/${AZ_IFACE}.conf" AWG_VPN_CONF="$AWG_DIR/${VPN_IFACE}.conf" \
        "$DEST/awg-obfuscation.sh" --preset "$PRESET" ${TEMPLATE:+--template "$TEMPLATE"} --fp "$FP" --mtu "$MTU" ${HOST:+--host "$HOST"} "$mode"
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
    # Метка незавершённой операции важнее записанного режима. write_services
    # пишет MODE=parallel вторым шагом, а восстановление ванили — пятым:
    # смерть между ними оставляла «заявлено parallel, работа не доделана», и
    # повторный запуск коротил ровно здесь, выходя с кодом 0. Вместе с MODE
    # терялся и старый режим, то есть доделать было уже нечем — метка хранит
    # его и снимается последним шагом.
    local resumed=0
    if [ -s "$MIGRATE_MARK" ]; then
        # shellcheck disable=SC1090
        . "$MIGRATE_MARK"
        old_mode="${MARK_MODE:-$old_mode}"
        resumed=1
        log "Найдена незавершённая миграция ($old_mode → parallel) — доделываю"
    elif [ "$old_mode" = parallel ]; then
        log "Уже режим parallel — миграция не нужна"; return 0
    fi
    # При ПОВТОРЕ имена старых интерфейсов брать из services.env нельзя: он уже
    # перезаписан, old_if совпал бы с new_if, ветка переименования пропустилась
    # бы целиком — а прогон всё равно дошёл бы до «✅ Миграция завершена».
    # Поэтому на этот случай они лежат в самой метке.
    local old_az_iface="$AZ_IFACE" old_vpn_iface="$VPN_IFACE"
    if [ "$resumed" = 1 ]; then
        old_az_iface="${MARK_AZ_IFACE:-$old_az_iface}"
        old_vpn_iface="${MARK_VPN_IFACE:-$old_vpn_iface}"
    fi
    local old_az_sub="$AZ_SUBNET" old_vpn_sub="$VPN_SUBNET"
    log "Миграция $old_mode → parallel…"

    # Метку кладём ДО первой необратимой записи, иначе смысла в ней нет.
    mkdir -p "$(dirname "$MIGRATE_MARK")"
    # Кладём всё, что понадобится повтору и чего он уже не найдёт в
    # services.env после первой же записи.
    {
        printf 'MARK_MODE=%s\n' "$old_mode"
        printf 'MARK_AZ_IFACE=%s\n' "$AZ_IFACE"
        printf 'MARK_VPN_IFACE=%s\n' "$VPN_IFACE"
        printf 'MARK_AZ_SUBNET=%s\n' "$AZ_SUBNET"
        printf 'MARK_VPN_SUBNET=%s\n' "$VPN_SUBNET"
    } > "$MIGRATE_MARK"

    # новый план (интерфейсы/подсети/рандомные порты); закреплённые 51xxx/52xxx
    # отбрасываются внутри plan_services
    plan_services
    write_services

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
        # `|| true`: статус подстановки — это статус всего конвейера, и под
        # pipefail он приезжает от ip (rc=2 на хосте без маршрута по умолчанию)
        # или от grep без совпадения. set -e убивал do_migrate прямо здесь —
        # уже ПОСЛЕ того, как конфиги переименованы и в services.env лёг
        # MODE=parallel. Повторный --migrate после этого коротит на «уже
        # parallel», и ванильный редирект не вернётся никогда. Пустой difc
        # законен: ветка `if [ -n "$difc" ]` ниже написана ровно на него.
        difc="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+' || true)"
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
    # Снимаем последним шагом: до этой строки операция считается незавершённой.
    rm -f "$MIGRATE_MARK"

    log "✅ Миграция завершена. ВАЖНО: всем клиентам AmneziaWG нужно раздать"
    log "   обновлённые конфиги/QR из /opt/antizapret-awg/clients/ —"
    if [ "$old_mode" = keep ]; then
        log "   изменился порт Endpoint (ключи и IP прежние)."
    else
        log "   изменились порт Endpoint и туннельный IP (ключи прежние)."
    fi
    log "   Порты: antizapret=$AZ_PORT vpn=$VPN_PORT"
}


# ── план: что сделает прогон, ничего при этом не делая ──────────────────────
# Порты и подсети считает тот же plan_services, режим профиля — тот же
# obf_mode. План не знает ничего сверх того, что знает реальный прогон.
plan_clients() {  # plan_clients <сервис…> → сколько конфигов выдано
    local svc n=0
    local -a f
    for svc in "$@"; do
        [ -d "$DEST/clients/$svc" ] || continue
        # Без find и без трубы: под pipefail ненулевой код find (подкаталог без
        # прав, файл, удалённый по истечении срока прямо во время обхода)
        # оборвал бы весь отчёт между заголовком и первым разделом — и молча,
        # его сообщение уже выброшено в /dev/null.
        f=( "$DEST/clients/$svc"/*-am.conf )
        [ -e "${f[0]}" ] && n=$(( n + ${#f[@]} ))
    done
    echo "$n"
}

plan_report() {
    if [ ! -f "$SERVICES" ]; then
        log "План: ПЕРВАЯ УСТАНОВКА"
        log "  Будет создано: интерфейсы слоя, случайные UDP-порты, ключи сервера,"
        log "  новый профиль обфускации."
        log "  Выданных клиентов ещё нет — ломать нечего."
        return 0
    fi

    # shellcheck disable=SC1090
    . "$SERVICES"
    # пересчитать порты и подсети ровно так же, как это сделает прогон;
    # plan_services только вычисляет, на диск не пишет
    if ! plan_services >/dev/null 2>&1; then
        # молча показать старые значения значило бы соврать именно там,
        # где план и нужен
        log "⚠️ пересчитать порты и подсети не удалось — ниже текущие значения"
    fi

    local op
    if   [ "$MIGRATE" = 1 ];     then op="МИГРАЦИЯ РЕЖИМА"
    elif [ "$UPDATE" = 1 ];      then op="ОБНОВЛЕНИЕ КОДА"
    elif [ "$RECONFIGURE" = 1 ]; then op="НОВЫЙ ПРОФИЛЬ ОБФУСКАЦИИ"
    else                              op="ПОВТОРНЫЙ ПРОГОН"
    fi
    log "План: $op"
    echo

    local n2 n3 m2 m3
    n2="$(plan_clients antizapret vpn)"
    n3="$(plan_clients antizapret3 vpn3)"
    m2="$(obf_mode "$AWG_DIR/obfuscation.env")"
    m3="$(obf_mode "$AWG_DIR/obfuscation3.env")"

    echo "  Не изменится:"
    printf '    ✓ порты          2.0 %s/%s' "${AZ_PORT:-?}" "${VPN_PORT:-?}"
    [ "${LAYER3:-0}" = 1 ] && printf '   3.0 %s/%s' "${AZ3_PORT:-?}" "${VPN3_PORT:-?}"
    printf '\n'
    printf '    ✓ подсети        %s.0/24, %s.0/24' "${AZ_SUBNET:-?}" "${VPN_SUBNET:-?}"
    [ "${LAYER3:-0}" = 1 ] && printf ', %s.0/24, %s.0/24' "${AZ3_SUBNET:-?}" "${VPN3_SUBNET:-?}"
    printf '\n'
    echo "    ✓ ключи сервера и клиентов"
    if [ "$UPDATE" = 1 ]; then
        [ "${LAYER2:-1}" = 1 ] && echo "    ✓ профиль обфускации 2.0"
        [ "${LAYER3:-0}" = 1 ] && echo "    ✓ профиль обфускации 3.0"
        # не ${LAYER3:+…}: «0» тоже непустое, и на сервере без слоя 3.0
        # отчёт дописывал бы «3.0 — 0»
        if [ "${LAYER3:-0}" = 1 ]; then
            echo "    ✓ конфиги клиентов: 2.0 — $n2, 3.0 — $n3"
        else
            echo "    ✓ конфиги клиентов: 2.0 — $n2"
        fi
    else
        [ "${LAYER2:-1}" = 1 ] && [ "$m2" = --reapply ] && \
            echo "    ✓ профиль обфускации 2.0 (применяется существующий)"
        [ "${LAYER3:-0}" = 1 ] && [ "$m3" = --reapply ] && \
            echo "    ✓ профиль обфускации 3.0 (применяется существующий)"
        [ "$m2" = --reapply ] && [ "${LAYER2:-1}" = 1 ] && \
            echo "    ✓ конфиги клиентов 2.0: $n2 — пересоздаются с тем же содержимым"
        [ "$m3" = --reapply ] && [ "${LAYER3:-0}" = 1 ] && \
            echo "    ✓ конфиги клиентов 3.0: $n3 — пересоздаются с тем же содержимым"
    fi
    echo

    echo "  Изменится:"
    echo "    ! код слоя, юниты systemd, симлинки, бот"
    [ "${LAYER3:-0}" = 1 ] && echo "    ! датапас amneziawg-go, если вышла новая пиновая версия"
    if [ "$UPDATE" != 1 ]; then
        if [ "${LAYER2:-1}" = 1 ] && [ "$m2" = --apply ]; then
            echo "    ! профиль обфускации 2.0 — НОВЫЙ"
            echo "    ! конфиги клиентов 2.0: $n2 — все перестанут подключаться"
        fi
        if [ "${LAYER3:-0}" = 1 ] && [ "$m3" = --apply ]; then
            echo "    ! профиль обфускации 3.0 — НОВЫЙ"
            echo "    ! конфиги клиентов 3.0: $n3 — все перестанут подключаться"
        fi
        [ "${LAYER2:-1}" = 1 ] && [ "$m2" = --reapply ] && \
            [ "${LAYER3:-0}" = 1 ] && [ "$m3" = --apply ] && \
            echo "    (слой 2.0 при этом не затрагивается)"
    fi
    echo

    echo "  НЕ будет сделано:"
    if [ "$UPDATE" = 1 ]; then
        echo "    ✗ перевыпуск профиля обфускации"
        echo "    ✗ пересоздание конфигов клиентов"
        echo "    ✗ смена портов и подсетей"
    else
        [ "$m2" = --reapply ] && echo "    ✗ перевыпуск профиля обфускации 2.0"
        [ "$m3" = --reapply ] && [ "${LAYER3:-0}" = 1 ] && \
            echo "    ✗ перевыпуск профиля обфускации 3.0"
        echo "    ✗ смена портов, подсетей и ключей"
    fi
    echo
    if [ "$UPDATE" != 1 ] && { [ "$m2" = --apply ] || \
       { [ "${LAYER3:-0}" = 1 ] && [ "$m3" = --apply ]; }; }; then
        log "⚠️ Затронутым клиентам придётся заново скачать и импортировать конфиг."
    else
        log "Переимпортировать конфиги никому не придётся."
    fi
    log "Это только план: ничего не изменено. Запусти ту же команду без --plan."
    return 0
}

main() {
    # План строится ДО любых действий и ничего не меняет.
    if [ "$PLAN" = 1 ]; then
        plan_report
        return 0
    fi
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
        # Датапас слоя 3.0 раньше не обновлялся ВООБЩЕ: install_awg3 отсюда не
        # вызывался, а на полном прогоне выходил по «бинарник есть». В сумме два
        # независимых блокиратора — amneziawg-go навсегда оставался той версии,
        # с которой сервер поставили, сколько бы раз ни запускали --update.
        if [ -f "$SERVICES" ] && grep -q '^LAYER3=1' "$SERVICES" 2>/dev/null; then
            install_awg3
            if [ "${AWG_GO_REBUILT:-0}" = 1 ]; then
                # shellcheck disable=SC1090
                . "$SERVICES"
                local i
                for i in "${AZ3_IFACE:-antizapret-awg3}" "${VPN3_IFACE:-vpn-awg3}"; do
                    systemctl is-enabled "awg3@$i" >/dev/null 2>&1 || continue
                    systemctl restart "awg3@$i" || {
                        err "слой 3.0: awg3@$i не перезапустился на новом датапасе."
                        journalctl -u "awg3@$i" -n 12 --no-pager 2>/dev/null | sed 's/^/    /' >&2
                    }
                done
            fi
        fi
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
    log "Слой AmneziaWG поверх AntiZapret (parallel: ваниль не трогается), версии: $AWG_VER"
    # kernel-модуль нужен только слою 2.0; для чистого 3.0 его не ставим
    case "$AWG_VER" in
        2|both) install_awg ;;
        3)      apt-get install -y -qq amneziawg-tools >/dev/null 2>&1 || install_awg ;;
    esac
    case "$AWG_VER" in 3|both) install_awg3 ;; esac
    deploy_overlay
    plan_services
    write_services
    resolve_host

    # Код 3 от обфускатора значит «в файлы легло, до туннеля не доехало». При
    # установке это ожидаемо: юниты ставит и запускает switch_services* СРАЗУ
    # ниже, там профиль и доедет. Валить установку из-за этого нельзя, но и
    # глотать молча — тоже: если switch_services тоже не справится, он скажет.
    if [ "$LAYER2" = 1 ]; then
        build_interfaces
        gen_obfuscation || { _orc=$?; [ "$_orc" = 3 ] || exit "$_orc"; }
        switch_services
    fi
    if [ "$LAYER3" = 1 ]; then
        build_interfaces3
        gen_obfuscation3 || { _orc=$?; [ "$_orc" = 3 ] || exit "$_orc"; }
        switch_services3
    fi

    # DNS-view для подсетей обоих слоёв. Здесь, а не только в switch_services:
    # при установке одного лишь слоя 3.0 тот вообще не вызывается.
    "$DEST/awg-knot-view.sh" 2>/dev/null || true

    # синхронизируем существующих клиентов с текущим профилем обфускации
    # (у сервера и клиентов S/H/I обязаны совпадать, иначе не будет handshake)
    # Отказ здесь НЕ должен ронять прогон: сервер уже переехал на новый профиль,
    # и аварийный выход сделал бы только хуже. Но и молчать нельзя — это самый
    # разрушительный из возможных отказов: сервер на новом профиле, клиенты на
    # старом, то есть не подключается никто. Раньше вывод уходил в /dev/null, а
    # `|| true` съедал код, и прогон допечатывал «Готово».
    if ! "$DEST/client-awg.sh" regen-all; then
        _regen_failed=1
        err "конфиги клиентов НЕ пересозданы, а сервер уже на новом профиле."
        err "Это значит, что сейчас не подключится никто. Запусти вручную:"
        err "    awg-client regen-all"
        err "и раздай клиентам обновлённые конфиги."
    fi
    echo
    log "Готово. Клиенты:"
    [ "$LAYER2" = 1 ] && {
        log "  awg-client add myphone antizapret    # 2.0, split-routing"
        log "  awg-client add laptop  vpn           # 2.0, полный туннель"; }
    [ "$LAYER3" = 1 ] && {
        log "  awg-client add myphone antizapret3   # 3.0, split-routing"
        log "  awg-client add laptop  vpn3          # 3.0, полный туннель"; }
    log "Проверка связности: awg-doctor"
    # Ненулевой код в самом конце: всё сказано, подсказки напечатаны, но для
    # автоматики этот прогон обязан считаться неуспешным.
    [ "$_regen_failed" = 0 ] || return 1
}
main
