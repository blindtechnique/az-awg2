# -*- coding: utf-8 -*-
"""Приёмка карточки клиента на данных, повторяющих боевой сервер."""
import io, os, sqlite3, sys, tempfile, time

# tests/ лежит внутри репозитория, поэтому корень берём от самого файла.
# AWG_REPO_ROOT позволяет проверить другую копию дерева, ничего не правя.
ROOT = os.environ.get("AWG_REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

SRC = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(ROOT, "overlay", "bin", "awg_stats.py")

TMP = tempfile.mkdtemp()
os.environ["AWG_STATS_DB"] = os.path.join(TMP, "stats.db")
os.environ["AWG_DIR"] = os.path.join(TMP, "awg")
os.environ["WG_DIR"] = os.path.join(TMP, "wg")
os.makedirs(os.environ["AWG_DIR"], exist_ok=True)
os.makedirs(os.environ["WG_DIR"], exist_ok=True)

import importlib.util
spec = importlib.util.spec_from_file_location("awg_stats", SRC)
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
S.geo_str = lambda ip: "Москва · Ростелеком"      # без похода в сеть

now = int(time.time())
S.init_db()
c = sqlite3.connect(os.environ["AWG_STATS_DB"])

def peer(pk, name, iface, origin, rx, tx, hs, ep=""):
    c.execute("INSERT INTO peers(pubkey,name,iface,origin,first_seen,last_seen) VALUES(?,?,?,?,?,?)",
              (pk, name, iface, origin, now - 86400, now))
    c.execute("INSERT INTO totals(pubkey,rx_life,tx_life,last_handshake,endpoint) VALUES(?,?,?,?,?)",
              (pk, rx, tx, hs, ep))

def conf(iface, peers):
    """Серверный конфиг: [Peer] + '# имя' над PublicKey, как пишет наш слой."""
    body = "[Interface]\nPrivateKey = x\n"
    for nm, pk in peers:
        body += "\n[Peer]\n# %s\nPublicKey = %s\n" % (nm, pk)
    io.open(os.path.join(os.environ["AWG_DIR"], iface + ".conf"),
            "w", encoding="utf-8").write(body)

MB = 1048576
fail = 0

def check(label, cond, extra=""):
    global fail
    print(("  ✔ " if cond else "  ✘ ") + label + ("" if cond else "  " + extra))
    if not cond: fail = 1

# grishanova с боевого: antizapret пустой, но с handshake; vpn — весь трафик
peer("g1", "grishanova", "antizapret", "vanilla", 0, 0, now - 7200)
peer("g2", "grishanova", "vpn", "vanilla", 60*MB, 32*MB, now - 30, "203.0.113.7:51820")
c.execute("INSERT INTO connections(pubkey,ts,ip,rx_start,tx_start) VALUES(?,?,?,?,?)",
          ("g2", now - 30, "203.0.113.7", 0, 0))
peer("a1", "anikaeva", "antizapret", "vanilla", 0, 0, 0)
peer("a2", "anikaeva", "vpn", "vanilla", 0, 0, 0)
peer("a3", "anikaeva", "antizapret-awg", "awg2", 30*MB, 10*MB, now - 60, "198.51.100.9:51820")
c.commit()

print("── A. Ванильный клиент: трафик лежит во втором интерфейсе ──────────────")
card = S.client("grishanova", "vanilla")
print("\n".join("     | " + l for l in card.split("\n")))
check("трафик просуммирован (92 МБ), а не ноль", "92" in card)
check("онлайн определён по свежему peer'у", "🟢 онлайн" in card)
check("IP и гео показаны", "203.0.113.7" in card and "Ростелеком" in card)
check("есть история подключений", "Подключения" in card)
check("оба интерфейса в заголовке", "antizapret+vpn" in card)
check("есть разбивка по интерфейсам", "По интерфейсам" in card)
check("слой назван верно", "стоковый WG" in card)

print()
print("── B. Наш слой не смешивается с ванилью ────────────────────────────────")
card2 = S.client("anikaeva", "awg2")
print("\n".join("     | " + l for l in card2.split("\n")[:3]))
check("слой AmneziaWG 2.0", "AmneziaWG 2.0" in card2)
check("интерфейс наш", "antizapret-awg" in card2)
check("ванильные не попали", "vpn" not in card2.split("\n")[0])
check("трафик 40 МБ", "40" in card2)

print()
print("── C. Ванильная карточка того же человека — пустая, но честная ─────────")
card3 = S.client("anikaeva", "vanilla")
check("офлайн", "⚪️ офлайн" in card3)
check("трафика нет", "Σ 0" in card3)
check("сказано, что не подключался", "ни разу не подключался" in card3)

print()
print("── D. Пересозданный клиент: мёртвый peer в сумму не идёт ───────────────")
peer("d_old", "petrov", "antizapret-awg", "awg2", 500*MB, 500*MB, now - 900000)
peer("d_new", "petrov", "antizapret-awg", "awg2", 5*MB, 1*MB, now - 45, "198.51.100.3:51820")
c.commit()
S.IFACES = [("antizapret-awg", "awg", "awg2")]
conf("antizapret-awg", [("petrov", "d_new")])          # в конфиге только новый ключ
card5 = S.client("petrov", "awg2")
print("\n".join("     | " + l for l in card5.split("\n")[:3]))
check("трафик только живого peer'а (6 МБ)", "6.0MB" in card5,
      "строка: " + card5.split("\n")[2])
check("гигабайт удалённого не приплюсован", "1.0GB" not in card5)

print()
print("── E. Клиент удалён целиком: история не пропадает ──────────────────────")
conf("antizapret-awg", [])                             # ни одного живого ключа
card6 = S.client("petrov", "awg2")
print("\n".join("     | " + l for l in card6.split("\n")[:3]))
check("карточка всё ещё показывается", "petrov" in card6)
check("виден исторический трафик", "1006.0MB" in card6, "строка: " + card6.split("\n")[2])

print()
print("═══ ВСЁ ЗЕЛЁНОЕ ═══" if not fail else "═══ ЕСТЬ ПАДЕНИЯ ═══")
sys.exit(fail)
