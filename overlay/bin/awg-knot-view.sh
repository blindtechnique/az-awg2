#!/usr/bin/env bash
# awg-knot-view.sh — добавляет в kresd.conf AntiZapret view:addr для наших
# подсетей AmneziaWG (например 10.29.9/10.28.9), чтобы DNS отвечал этим клиентам
# правильным шлюзом (иначе запрос имени сервера у .9-клиентов резолвится неверно).
#
# Нужно в режимах parallel и keep (свои подсети). В legacy replace-режиме
# AmneziaWG использует те же подсети, что и ванильный WG, и штатные view
# AntiZapret уже подходят — тогда скрипт ничего не делает.
#
# Патч /etc/knot-resolver/kresd.conf теряется при обновлении AntiZapret (оно
# перезаписывает /etc), поэтому скрипт вызывается и из интеграции, и из
# awg-reintegrate.sh. Идемпотентен, никогда не фатален.
export LC_ALL=C
KRESD=/etc/knot-resolver/kresd.conf
SERVICES=/etc/amnezia/amneziawg/services.env

[ -f "$KRESD" ] || exit 0
[ -f "$SERVICES" ] || exit 0
# shellcheck disable=SC1090
. "$SERVICES" 2>/dev/null || true
case "${MODE:-replace}" in parallel|keep) ;; *) exit 0 ;; esac   # свои подсети → нужен view

# Подсети слоя 3.0 (третий октет +2) — им нужен такой же view, иначе клиенты
# 3.0 получат неверный ответ на имя сервера. Передаём их дополнительными
# аргументами; если слой не установлен, список просто короче.
SUBNETS="${AZ_SUBNET:-10.29.9} ${VPN_SUBNET:-10.28.9}"
if [ "${LAYER3:-0}" = 1 ]; then
    SUBNETS="$SUBNETS ${AZ3_SUBNET:-10.29.10} ${VPN3_SUBNET:-10.28.10}"
fi

# shellcheck disable=SC2086
out="$(python3 - "$KRESD" $SUBNETS <<'PY' 2>/dev/null || true
import re, sys
path = sys.argv[1]
subnets = sys.argv[2:]
lines = open(path).read().splitlines(keepends=True)

def add_view(lines, subnet):
    gw = subnet + ".1"                                  # 10.29.9.1
    if any("view:addr('%s/24'" % gw in l for l in lines):
        return lines, False                             # уже есть
    prefix = subnet.rsplit(".", 1)[0]                   # 10.29
    view = ("\tview:addr('%s/24', policy.domains(policy.ANSWER("
            "{[kres.type.A] = {rdata = kres.str2ip('%s'), ttl = min_ttl}}), "
            "{todname(hostname())}))\n") % (gw, gw)
    rx = re.compile(r"view:addr\('%s\.\d+\.1/" % re.escape(prefix))
    idx = None
    for i, l in enumerate(lines):
        if rx.search(l):
            idx = i                                     # вставляем после последнего view этого префикса
    if idx is None:
        return lines, None
    return lines[:idx + 1] + [view] + lines[idx + 1:], True

changed = False
for s in subnets:
    lines, r = add_view(lines, s)
    changed = changed or bool(r)
if changed:
    open(path, "w").writelines(lines)
    print("patched")
PY
)"

if [ "$out" = "patched" ]; then
    systemctl restart kresd@1 kresd@2 2>/dev/null \
        || systemctl restart knot-resolver 2>/dev/null || true
    echo "[awg-knot-view] добавлены view для keep-подсетей, kresd перезапущен"
fi
exit 0
