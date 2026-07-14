#!/usr/bin/env bash
# awg-reintegrate.sh — самовосстановление слоя AmneziaWG после обновления AntiZapret.
#
# Что переживает обновление само:
#   * серверное состояние AmneziaWG — /etc/amnezia/amneziawg/ (конфиги, ключи,
#     obfuscation.env, services.env);
#   * наш overlay и клиенты — /opt/antizapret-awg/ (вне /root/antizapret);
#   * systemd-юниты в /etc/systemd/system/.
#
# Что сбрасывает ручной `setup.sh` (rm -rf /root/antizapret) и что чиним здесь:
#   1. заново включённые ванильные wg-quick@ (конфликт портов) → отключаем;
#   2. отсутствующий хук в custom-up.sh → дописываем;
#   3. слетевшие симлинки /usr/local/bin → пересоздаём;
#   4. не поднятые awg-quick@ интерфейсы → поднимаем.
#
# Идемпотентно и НИКОГДА не фатально (always exit 0) — вызывается и из custom-up.sh
# (на каждом старте antizapret), и из awg-reintegrate.service (на загрузке).
export LC_ALL=C
DEST=/opt/antizapret-awg
AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
CU=/root/antizapret/custom-up.sh

log() { echo "[awg-reintegrate] $*"; }

# интеграция вообще выполнялась?
[ -f "$SERVICES" ] || { log "нет $SERVICES — слой не установлен, выход"; exit 0; }
# shellcheck disable=SC1090
. "$SERVICES" 2>/dev/null || true
AZ_IFACE="${AZ_IFACE:-antizapret}"; VPN_IFACE="${VPN_IFACE:-vpn}"
MODE="${MODE:-replace}"

# 1. симлинки CLI (могли слететь при rm -rf /root, если ссылки вели туда — у нас в /opt,
#    но пересоздадим на всякий случай, это дёшево и идемпотентно)
for pair in "awg-obfuscation.sh:awg-obfuscation" "client-awg.sh:awg-client" "awg-backup.sh:awg-backup"; do
    src="$DEST/${pair%%:*}"; dst="/usr/local/bin/${pair##*:}"
    [ -f "$src" ] && ln -sf "$src" "$dst" 2>/dev/null || true
done

# 2. hook в custom-up.sh (upstream мог сбросить его при setup.sh)
if [ -f "$CU" ] && ! grep -q 'awg-reintegrate' "$CU"; then
    printf '\n# AntiZapret-AWG: самовосстановление слоя AmneziaWG после обновления\n%s/awg-reintegrate.sh >/dev/null 2>&1 &\n' "$DEST" >> "$CU"
    log "hook добавлен в custom-up.sh"
fi

# 3. в replace-режиме ванильный wg-quick@ мог быть заново включён setup.sh — душим
#    (иначе конфликт за порты 51443/51080 с нашим AmneziaWG)
if [ "$MODE" = replace ]; then
    for s in wg-quick@antizapret wg-quick@vpn; do
        if systemctl is-enabled "$s" >/dev/null 2>&1 || systemctl is-active "$s" >/dev/null 2>&1; then
            systemctl disable --now "$s" 2>/dev/null && log "отключён ванильный $s"
        fi
    done
fi

# 4. наши awg-quick@ должны быть подняты И быть типа amneziawg. Проверяем ТИП
#    интерфейса напрямую (ip -d link), а не systemd-состояние: ванильный wg-quick мог
#    создать интерфейс с тем же именем (тип wireguard), и тогда awg show пустой.
for i in "$AZ_IFACE" "$VPN_IFACE"; do
    systemctl enable "awg-quick@$i" 2>/dev/null || true
    if ! ip -d link show "$i" 2>/dev/null | grep -q amneziawg; then
        systemctl stop "awg-quick@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true     # снести любой (в т.ч. wireguard) интерфейс
        systemctl start "awg-quick@$i" 2>/dev/null && log "поднят awg-quick@$i (amneziawg)" \
            || log "не удалось поднять awg-quick@$i"
    fi
done

# 5. keep-режим: setup.sh возвращает в up.sh редирект 52xxx→51xxx, который снова
#    перекрывает наш AmneziaWG (52443/52080) ванильным WG. up.sh применяет правило
#    ДО вызова custom-up.sh, поэтому чиним и файл (на будущее), и живой iptables.
if [ "$MODE" = keep ]; then
    up=/root/antizapret/up.sh
    if [ -f "$up" ] && grep -qE 'dport 5(2443|2080) -j REDIRECT' "$up"; then
        sed -i '/dport 52080 -j REDIRECT/d;/dport 52443 -j REDIRECT/d' "$up"
        log "up.sh: убран редирект 52xxx→51xxx (keep)"
    fi
    # удалить УЖЕ применённые живые правила редиректа (интерфейс -i берём из самого правила)
    iptables -w -t nat -S PREROUTING 2>/dev/null | grep -E 'dport (52443|52080) .*REDIRECT' \
        | while read -r r; do
            # shellcheck disable=SC2086
            iptables -w -t nat ${r/-A /-D } 2>/dev/null || true
        done
    # открыть порты AmneziaWG во INPUT (после снятия редиректа трафик идёт напрямую)
    for p in 52443 52080; do
        iptables -w -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -w -A INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    log "keep: живой редирект 52xxx снят, порты 52443/52080 открыты"
fi

exit 0
