#!/usr/bin/env bash
# awg-knot-view.sh — добавляет в kresd.conf AntiZapret view:addr для keep-режимных
# подсетей AmneziaWG (например 10.29.9/10.28.9), чтобы DNS отвечал этим клиентам
# правильным шлюзом (иначе запрос имени сервера у .9-клиентов резолвится неверно).
#
# Нужно только в keep-режиме. В replace-режиме AmneziaWG использует те же подсети,
# что и ванильный WG, и штатные view AntiZapret уже подходят — тогда скрипт ничего
# не делает.
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
[ "${MODE:-replace}" = keep ] || exit 0     # view нужны только в keep-режиме

out="$(python3 - "$KRESD" "${AZ_SUBNET:-10.29.9}" "${VPN_SUBNET:-10.28.9}" <<'PY' 2>/dev/null || true
import re, sys
path, az, vpn = sys.argv[1], sys.argv[2], sys.argv[3]
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
for s in (az, vpn):
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
