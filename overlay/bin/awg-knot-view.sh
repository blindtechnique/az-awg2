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
# awg-reintegrate.sh. Идемпотентен. Отсутствие kresd.conf или чужой режим —
# законное молчание с нулём; а вот «не нашёл, куда вставить» теперь код 1 и
# строка в stderr: раньше этот случай молчал, и пропажа view жила годами.
export LC_ALL=C
# Пути переопределяемы: стенду нужны свои копии, а на сервере значения те же.
KRESD="${AWG_KRESD:-/etc/knot-resolver/kresd.conf}"
SERVICES="${AWG_SERVICES:-/etc/amnezia/amneziawg/services.env}"

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
out="$(python3 - "$KRESD" $SUBNETS <<'PY'
import re, sys
path = sys.argv[1]
subnets = sys.argv[2:]
lines = open(path).read().splitlines(keepends=True)

# Формат берётся у ванили дословно, а не по догадке. Она пишет СЕТЕВОЙ адрес:
#   view:addr('10.29.8.0/24', … kres.str2ip('10.29.8.1') …)
# Прежняя редакция искала, вставляла и якорилась на форму с адресом шлюза
# ('10.29.9.1/24'), какой у ванили не бывает ни разу, — поэтому якорь не
# совпадал никогда, и скрипт молча ничего не делал.
def add_view(lines, subnet):
    net = subnet + ".0"                                 # 10.29.9.0
    gw = subnet + ".1"                                  # 10.29.9.1
    if any("view:addr('%s/24'" % net in l for l in lines):
        return lines, False                             # уже есть
    prefix = subnet.rsplit(".", 1)[0]                   # 10.29
    view = ("\tview:addr('%s/24', policy.domains(policy.ANSWER("
            "{[kres.type.A] = {rdata = kres.str2ip('%s'), ttl = min_ttl}}), "
            "{todname(hostname())}))\n") % (net, gw)
    # Якорь — ЛЮБАЯ строка view этого префикса, в какой бы форме ваниль её ни
    # писала. Вставляем после последней, чтобы не разорвать её блок.
    rx = re.compile(r"view:addr\('%s\." % re.escape(prefix))
    idx = None
    for i, l in enumerate(lines):
        if rx.search(l):
            idx = i
    if idx is None:
        return lines, None
    return lines[:idx + 1] + [view] + lines[idx + 1:], True

changed = False
missing = []
for s in subnets:
    lines, r = add_view(lines, s)
    if r is None:
        missing.append(s)
    changed = changed or bool(r)
if changed:
    open(path, "w").writelines(lines)
if missing:
    sys.stderr.write("не нашёл, куда вставить view для: %s\n" % " ".join(missing))
    print("noanchor")
elif changed:
    print("patched")
else:
    print("ok")
PY
)" || out="fail"

case "$out" in
    patched)
        systemctl restart kresd@1 kresd@2 2>/dev/null \
            || systemctl restart knot-resolver 2>/dev/null || true
        echo "[awg-knot-view] добавлены view для подсетей слоя, kresd перезапущен" ;;
    ok) ;;                                  # уже на месте — молчим
    *)
        # Молчать нельзя: без view клиент, спросивший имя своего сервера
        # изнутри туннеля, получит внешний адрес вместо адреса шлюза. Раньше
        # этот случай возвращал ноль и не печатал ничего.
        echo "[awg-knot-view] не удалось добавить view в $KRESD" >&2
        echo "[awg-knot-view] ваниль пишет их в другом формате или их там нет" >&2
        exit 1 ;;
esac
exit 0
