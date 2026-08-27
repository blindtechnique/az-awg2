# -*- coding: utf-8 -*-
"""Приёмка счётчика клиентов и автоопределения слоя 3.0."""
import io, os, sqlite3, sys, tempfile, time

# tests/ лежит внутри репозитория, поэтому корень берём от самого файла.
# AWG_REPO_ROOT позволяет проверить другую копию дерева, ничего не правя.
ROOT = os.environ.get("AWG_REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

SRC = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(ROOT, "overlay", "bin", "awg_stats.py")

TMP = tempfile.mkdtemp()
AWG = os.path.join(TMP, "awg"); WG = os.path.join(TMP, "wg")
os.makedirs(AWG, exist_ok=True); os.makedirs(WG, exist_ok=True)
os.environ.update(AWG_STATS_DB=os.path.join(TMP, "stats.db"), AWG_DIR=AWG, WG_DIR=WG)

fail = 0
def check(label, cond, extra=""):
    global fail
    print(("  ✔ " if cond else "  ✘ ") + label + ("" if cond else "  " + extra))
    if not cond: fail = 1

def conf(d, iface, peers):
    body = "[Interface]\nPrivateKey = x\n"
    for nm, pk in peers:
        body += "\n[Peer]\n# %s\nPublicKey = %s\n" % (nm, pk)
    io.open(os.path.join(d, iface + ".conf"), "w", encoding="utf-8").write(body)

def services(**kw):
    io.open(os.path.join(AWG, "services.env"), "w", encoding="utf-8").write(
        "".join("%s=%s\n" % (k, v) for k, v in kw.items()))

def load(mod="awg_stats"):
    import importlib.util
    spec = importlib.util.spec_from_file_location(mod, SRC)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

print("── [3] Слой 3.0 определяется по конфигам, когда LAYER3 в services.env нет ──")
services(MODE="parallel", AZ_IFACE="antizapret-awg", VPN_IFACE="vpn-awg")
m = load()
check("без конфигов 3.0 слой не опрашивается",
      not any(o == "awg3" for _i, _b, o in m.IFACES),
      str(m.IFACES))

conf(AWG, "antizapret-awg3", [("ivan", "k3")])
m = load("awg_stats2")
check("конфиг 3.0 появился → слой опрашивается",
      any(o == "awg3" for _i, _b, o in m.IFACES), str(m.IFACES))

services(MODE="parallel", AZ_IFACE="antizapret-awg", VPN_IFACE="vpn-awg", LAYER3="0")
m = load("awg_stats3")
check("явный LAYER3=0 сильнее автоопределения",
      not any(o == "awg3" for _i, _b, o in m.IFACES), str(m.IFACES))

print()
print("── [2] Счётчик считает людей, а не строки ──────────────────────────────")
os.remove(os.path.join(AWG, "antizapret-awg3.conf"))
services(MODE="parallel", AZ_IFACE="antizapret-awg", VPN_IFACE="vpn-awg", LAYER3="0")
# двое живых: у каждого ванильная пара (antizapret+vpn) и наш конфиг = 6 строк
conf(AWG, "antizapret-awg", [("ivan", "a1"), ("petr", "a2")])
conf(WG, "antizapret", [("ivan", "v1"), ("petr", "v2")])
conf(WG, "vpn", [("ivan", "v3"), ("petr", "v4")])
m = load("awg_stats4")
m.geo_str = lambda ip: ""
m._have = lambda b: True          # чтобы ванильные интерфейсы попали в опрос
m.IFACES = m._ifaces()
m.init_db()
now = int(time.time())
c = sqlite3.connect(os.environ["AWG_STATS_DB"])
MB = 1048576
for pk, nm, ifc, org, hs, mb in [("a1","ivan","antizapret-awg","awg2",now-30,50),
                                 ("a2","petr","antizapret-awg","awg2",0,0),
                                 ("v1","ivan","antizapret","vanilla",0,0),
                                 ("v2","petr","antizapret","vanilla",0,0),
                                 ("v3","ivan","vpn","vanilla",now-20,10),
                                 ("v4","petr","vpn","vanilla",0,0),
                                 ("dead","udalen","antizapret-awg","awg2",now-99999,900)]:
    c.execute("INSERT INTO peers(pubkey,name,iface,origin,first_seen,last_seen) VALUES(?,?,?,?,?,?)",
              (pk, nm, ifc, org, now-86400, now))
    c.execute("INSERT INTO totals(pubkey,rx_life,tx_life,last_handshake,endpoint) VALUES(?,?,?,?,?)",
              (pk, mb*MB, 0, hs, ""))
c.commit()

out = m.server_info()
cand = [l for l in out.split("\n") if "Клиентов" in l]
if not cand:
    print("     ] overview вернул:"); print("\n".join("     ] " + l for l in out.split("\n")[:8]))
line = (cand or [""])[0]
print("     | " + line)
check("людей 2, а не 7 строк", "Клиентов: 2" in line, line)
check("конфигов показано 6", "(6 конфигов)" in line, line)
check("удалённый клиент не посчитан в людях", "Клиентов: 3" not in line, line)
# в топ-5 по трафику удалённый остаётся намеренно: это исторический объём,
# а не список действующих клиентов
check("его трафик из топа не пропал", "udalen" in out)
check("онлайн 1 человек, а не 2 его peer'а", "онлайн 1" in line, line)

print()
print("═══ ВСЁ ЗЕЛЁНОЕ ═══" if not fail else "═══ ЕСТЬ ПАДЕНИЯ ═══")
sys.exit(fail)
