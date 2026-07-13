#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg_stats.py — сбор и хранение статистики AmneziaWG в SQLite (низкая нагрузка).

Собирает `awg show <iface> dump` по интерфейсам antizapret/vpn, сопоставляет
peer-pubkey с именем клиента (по комментарию '# name' в серверном конфиге) и
ведёт точный учёт трафика с обработкой СБРОСА счётчиков (рестарт интерфейса
обнуляет rx/tx — считаем это новым базовым уровнем, а не отрицательным дельтой).

Схема:
  peers   (pubkey PK, name, iface, first_seen, last_seen)
  totals  (pubkey PK, rx_life, tx_life, last_rx, last_tx, last_handshake, endpoint)
  daily   (pubkey, day, rx, tx, PRIMARY KEY(pubkey, day))
  samples (ts, pubkey, rx, tx, handshake)   — сырьё для графиков, авто-прунинг

Использование:
  awg_stats.py init
  awg_stats.py poll            # один опрос (запускать по таймеру/из бота)
  awg_stats.py overview        # сводка по всем клиентам
  awg_stats.py client <name>   # детально по клиенту (по дням)
  awg_stats.py prune [days]    # удалить сырые сэмплы старше N дней (default 14)

Онлайн = последний handshake < 180 секунд назад.
"""

import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

DB_PATH = os.environ.get("AWG_STATS_DB", "/root/antizapret/awg/stats.db")
AWG_DIR = os.environ.get("AWG_DIR", "/etc/amnezia/amneziawg")


def _ifaces():
    """Имена awg-интерфейсов из services.env (зависят от режима replace/keep)."""
    env = os.path.join(AWG_DIR, "services.env")
    az, vpn = "antizapret", "vpn"
    try:
        for line in open(env, encoding="utf-8"):
            line = line.strip()
            if line.startswith("AZ_IFACE="):
                az = line.split("=", 1)[1].strip()
            elif line.startswith("VPN_IFACE="):
                vpn = line.split("=", 1)[1].strip()
    except OSError:
        pass
    return (az, vpn)


IFACES = _ifaces()
ONLINE_WINDOW = 180          # сек: свежий handshake = онлайн
SAMPLE_RETENTION_DAYS = 14

SCHEMA = """
CREATE TABLE IF NOT EXISTS peers (
    pubkey TEXT PRIMARY KEY, name TEXT, iface TEXT,
    first_seen INTEGER, last_seen INTEGER
);
CREATE TABLE IF NOT EXISTS totals (
    pubkey TEXT PRIMARY KEY, rx_life INTEGER DEFAULT 0, tx_life INTEGER DEFAULT 0,
    last_rx INTEGER DEFAULT 0, last_tx INTEGER DEFAULT 0,
    last_handshake INTEGER DEFAULT 0, endpoint TEXT
);
CREATE TABLE IF NOT EXISTS daily (
    pubkey TEXT, day TEXT, rx INTEGER DEFAULT 0, tx INTEGER DEFAULT 0,
    PRIMARY KEY (pubkey, day)
);
CREATE TABLE IF NOT EXISTS samples (
    ts INTEGER, pubkey TEXT, rx INTEGER, tx INTEGER, handshake INTEGER
);
CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
CREATE TABLE IF NOT EXISTS connections (
    pubkey TEXT, ts INTEGER, ip TEXT, rx_start INTEGER, tx_start INTEGER
);
CREATE INDEX IF NOT EXISTS idx_conn_pubkey ON connections(pubkey, ts);
CREATE TABLE IF NOT EXISTS geoip (
    ip TEXT PRIMARY KEY, city TEXT, country TEXT, isp TEXT, ts INTEGER
);
"""


def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with db() as c:
        c.executescript(SCHEMA)


# ── маппинг pubkey → имя клиента ─────────────────────────────────────────────

def load_names() -> dict:
    """Прочитать серверные конфиги: '# name' над каждым [Peer] → {pubkey: (name, iface)}."""
    mapping = {}
    for iface in IFACES:
        path = os.path.join(AWG_DIR, f"{iface}.conf")
        if not os.path.exists(path):
            continue
        name = None
        for line in open(path, encoding="utf-8", errors="ignore"):
            s = line.strip()
            if s.startswith("[Peer]"):
                name = None
            elif s.startswith("#") and len(s) > 1:
                name = s[1:].strip()
            elif s.startswith("PublicKey"):
                pk = s.split("=", 1)[1].strip()
                mapping[pk] = (name or pk[:8], iface)
    return mapping


# ── парсинг awg dump ─────────────────────────────────────────────────────────

def dump_iface(iface: str) -> str:
    try:
        return subprocess.run(["awg", "show", iface, "dump"],
                              capture_output=True, text=True, timeout=15).stdout
    except Exception:  # noqa: BLE001
        return ""


def parse_dump(text: str) -> list:
    """Строки peer: pubkey psk endpoint allowed-ips handshake rx tx keepalive.
    Первая строка — сам интерфейс (пропускаем)."""
    peers = []
    for i, line in enumerate(text.splitlines()):
        f = line.split("\t")
        if i == 0 or len(f) < 8:
            continue
        peers.append({
            "pubkey": f[0], "endpoint": f[2],
            "handshake": int(f[4] or 0), "rx": int(f[5] or 0), "tx": int(f[6] or 0),
        })
    return peers


# ── опрос ────────────────────────────────────────────────────────────────────

def poll(dump_override: dict = None):
    """Один цикл сбора. dump_override={iface: dumptext} — для тестов."""
    init_db()
    names = load_names()
    now = int(time.time())
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    new_ips = set()
    with db() as c:
        for iface in IFACES:
            text = dump_override[iface] if dump_override and iface in dump_override else dump_iface(iface)
            for p in parse_dump(text):
                pk = p["pubkey"]
                name, ifc = names.get(pk, (pk[:8], iface))
                c.execute("""INSERT INTO peers(pubkey,name,iface,first_seen,last_seen)
                             VALUES(?,?,?,?,?)
                             ON CONFLICT(pubkey) DO UPDATE SET name=?,iface=?,last_seen=?""",
                          (pk, name, ifc, now, now, name, ifc, now))
                row = c.execute("SELECT last_rx,last_tx FROM totals WHERE pubkey=?",
                                (pk,)).fetchone()
                if row is None:
                    c.execute("""INSERT INTO totals(pubkey,rx_life,tx_life,last_rx,last_tx,
                                 last_handshake,endpoint) VALUES(?,?,?,?,?,?,?)""",
                              (pk, p["rx"], p["tx"], p["rx"], p["tx"],
                               p["handshake"], p["endpoint"]))
                    drx, dtx = p["rx"], p["tx"]
                else:
                    last_rx, last_tx = row
                    # сброс счётчика (рестарт iface) → дельта = текущее значение
                    drx = p["rx"] - last_rx if p["rx"] >= last_rx else p["rx"]
                    dtx = p["tx"] - last_tx if p["tx"] >= last_tx else p["tx"]
                    c.execute("""UPDATE totals SET rx_life=rx_life+?, tx_life=tx_life+?,
                                 last_rx=?, last_tx=?, last_handshake=?, endpoint=?
                                 WHERE pubkey=?""",
                              (drx, dtx, p["rx"], p["tx"], p["handshake"],
                               p["endpoint"], pk))
                if drx or dtx:
                    c.execute("""INSERT INTO daily(pubkey,day,rx,tx) VALUES(?,?,?,?)
                                 ON CONFLICT(pubkey,day) DO UPDATE SET rx=rx+?, tx=tx+?""",
                              (pk, day, drx, dtx, drx, dtx))
                c.execute("INSERT INTO samples(ts,pubkey,rx,tx,handshake) VALUES(?,?,?,?,?)",
                          (now, pk, p["rx"], p["tx"], p["handshake"]))
                # событие подключения: смена endpoint-IP или первое появление
                cur_ip = (p["endpoint"] or "").rsplit(":", 1)[0].strip("[]")
                if cur_ip and cur_ip not in ("(none)", ""):
                    last_conn = c.execute(
                        "SELECT ip FROM connections WHERE pubkey=? ORDER BY ts DESC LIMIT 1",
                        (pk,)).fetchone()
                    if last_conn is None or last_conn[0] != cur_ip:
                        c.execute("""INSERT INTO connections(pubkey,ts,ip,rx_start,tx_start)
                                     VALUES(?,?,?,?,?)""", (pk, now, cur_ip, p["rx"], p["tx"]))
                        new_ips.add(cur_ip)
    for ip in new_ips:      # гео-резолв вне транзакции (свои соединения к БД)
        geoip(ip)
    prune(SAMPLE_RETENTION_DAYS)


def geoip(ip: str) -> dict:
    """GeoIP через ip-api.com (бесплатно, без ключа), с кэшем в SQLite. Best-effort."""
    if not ip or ip.startswith(("10.", "192.168.", "127.")) or ip.startswith("172.16."):
        return {"city": "", "country": "", "isp": "локальный"}
    with db() as c:
        row = c.execute("SELECT city,country,isp FROM geoip WHERE ip=?", (ip,)).fetchone()
        if row:
            return {"city": row[0], "country": row[1], "isp": row[2]}
    city = country = isp = ""
    try:
        import urllib.request
        url = f"http://ip-api.com/json/{ip}?fields=city,country,isp"
        with urllib.request.urlopen(url, timeout=4) as r:
            import json as _j
            d = _j.loads(r.read().decode())
            city, country, isp = d.get("city", ""), d.get("country", ""), d.get("isp", "")
    except Exception:  # noqa: BLE001
        pass
    with db() as c:
        c.execute("""INSERT INTO geoip(ip,city,country,isp,ts) VALUES(?,?,?,?,?)
                     ON CONFLICT(ip) DO UPDATE SET city=?,country=?,isp=?,ts=?""",
                  (ip, city, country, isp, int(time.time()), city, country, isp, int(time.time())))
    return {"city": city, "country": country, "isp": isp}


def geo_str(ip: str) -> str:
    g = geoip(ip)
    parts = [x for x in (g.get("city"), g.get("country")) if x]
    loc = ", ".join(parts)
    isp = g.get("isp", "")
    if loc and isp:
        return f"{loc} · {isp}"
    return loc or isp or "?"


def prune(days: int = SAMPLE_RETENTION_DAYS):
    cutoff = int(time.time()) - days * 86400
    with db() as c:
        c.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))


# ── форматирование ───────────────────────────────────────────────────────────

def human(n: int) -> str:
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{u}" if u != "B" else f"{int(n)}B"
        n /= 1024
    return f"{n:.1f}PB"


def ago(ts: int) -> str:
    if not ts:
        return "никогда"
    d = int(time.time()) - ts
    if d < 60:
        return f"{d}с назад"
    if d < 3600:
        return f"{d//60}м назад"
    if d < 86400:
        return f"{d//3600}ч назад"
    return f"{d//86400}д назад"


# ── запросы ──────────────────────────────────────────────────────────────────

def overview() -> str:
    init_db()
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    now = int(time.time())
    with db() as c:
        rows = c.execute("""
            SELECT p.name, p.iface, t.rx_life, t.tx_life, t.last_handshake
            FROM peers p LEFT JOIN totals t ON p.pubkey=t.pubkey
            ORDER BY (t.rx_life+t.tx_life) DESC""").fetchall()
        if not rows:
            return "Пока нет данных (клиенты не подключались)."
        out = ["👥 Клиенты (по объёму трафика):", ""]
        online = 0
        for name, iface, rxl, txl, hs in rows:
            is_on = hs and (now - hs) < ONLINE_WINDOW
            online += 1 if is_on else 0
            dot = "🟢" if is_on else "⚪️"
            pk = c.execute("SELECT pubkey FROM peers WHERE name=? LIMIT 1", (name,)).fetchone()[0]
            drow = c.execute("SELECT rx,tx FROM daily WHERE pubkey=? AND day=?",
                             (pk, today)).fetchone()
            td = human((drow[0] if drow else 0) + (drow[1] if drow else 0))
            out.append(f"{dot} {name} [{iface}]  ↓{human(rxl)} ↑{human(txl)} "
                       f"· сегодня {td} · {ago(hs)}")
        tot = c.execute("SELECT SUM(rx_life),SUM(tx_life) FROM totals").fetchone()
        out += ["", f"Онлайн: {online}/{len(rows)} · всего "
                    f"↓{human(tot[0])} ↑{human(tot[1])}"]
        return "\n".join(out)


def dt(ts: int) -> str:
    """Точные дата и время (до минуты), локальное время сервера."""
    if not ts:
        return "—"
    try:
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
    except Exception:  # noqa: BLE001
        return "—"


def client(name: str) -> str:
    init_db()
    now = int(time.time())
    with db() as c:
        prow = c.execute("SELECT pubkey,iface FROM peers WHERE name=? LIMIT 1",
                         (name,)).fetchone()
        if not prow:
            return f"Клиент '{name}' не найден."
        pk, iface = prow
        t = c.execute("""SELECT rx_life,tx_life,last_handshake,endpoint
                         FROM totals WHERE pubkey=?""", (pk,)).fetchone() or (0, 0, 0, "")
        is_on = t[2] and (now - t[2]) < ONLINE_WINDOW
        cur_ip = (t[3] or "").rsplit(":", 1)[0].strip("[]")
        out = [f"📊 <b>{name}</b> [{iface}] {'🟢 онлайн' if is_on else '⚪️ офлайн'}",
               f"Последняя активность: {dt(t[2])} ({ago(t[2])})",
               f"Всего трафика: ↓{human(t[0])} ↑{human(t[1])} (Σ {human(t[0]+t[1])})"]
        conn = c.execute("""SELECT ts,ip,rx_start,tx_start FROM connections
                            WHERE pubkey=? ORDER BY ts DESC LIMIT 1""", (pk,)).fetchone()
        if conn and is_on:
            srx = max(0, t[0] - conn[2]); stx = max(0, t[1] - conn[3])
            out.append(f"Сессия с {dt(conn[0])}: ↓{human(srx)} ↑{human(stx)}")
        if cur_ip:
            out.append(f"IP сейчас: <code>{cur_ip}</code> · {geo_str(cur_ip)}")
        conns = c.execute("""SELECT ts,ip FROM connections WHERE pubkey=?
                             ORDER BY ts DESC LIMIT 10""", (pk,)).fetchall()
        if conns:
            out.append("\n🔌 Подключения (последние 10):")
            for ts, ip in conns:
                out.append(f"  {dt(ts)} · <code>{ip}</code> · {geo_str(ip)}")
        return "\n".join(out)


def _cpu_pct():
    try:
        def snap():
            f = open("/proc/stat").readline().split()[1:]
            v = list(map(int, f)); idle = v[3] + v[4]; return sum(v), idle
        t1, i1 = snap(); time.sleep(0.3); t2, i2 = snap()
        dt = t2 - t1; di = i2 - i1
        return 100.0 * (dt - di) / dt if dt else 0.0
    except Exception:  # noqa: BLE001
        return 0.0


def _mem():
    try:
        m = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":"); m[k] = int(v.split()[0]) * 1024
        total = m["MemTotal"]; avail = m.get("MemAvailable", m["MemFree"])
        return total, total - avail
    except Exception:  # noqa: BLE001
        return 0, 0


def _uptime():
    try:
        s = int(float(open("/proc/uptime").read().split()[0]))
        d, s = divmod(s, 86400); h, s = divmod(s, 3600); m = s // 60
        return f"{d}д {h}ч {m}м"
    except Exception:  # noqa: BLE001
        return "?"


def server_info() -> str:
    init_db()
    now = int(time.time())
    load = "?"
    try:
        load = " / ".join(open("/proc/loadavg").read().split()[:3])
    except Exception:  # noqa: BLE001
        pass
    cpu = _cpu_pct()
    mtot, muse = _mem()
    try:
        st = os.statvfs("/"); dtot = st.f_blocks * st.f_frsize; dfree = st.f_bfree * st.f_frsize
        dpct = 100.0 * (dtot - dfree) / dtot if dtot else 0
    except Exception:  # noqa: BLE001
        dtot = dpct = 0
    with db() as c:
        total_clients = c.execute("SELECT COUNT(*) FROM peers").fetchone()[0]
        online = c.execute("SELECT COUNT(*) FROM totals WHERE last_handshake > ?",
                           (now - ONLINE_WINDOW,)).fetchone()[0]
        tot = c.execute("SELECT SUM(rx_life),SUM(tx_life) FROM totals").fetchone()
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        d24 = c.execute("SELECT SUM(rx),SUM(tx) FROM daily WHERE day=?", (day,)).fetchone()
        top = c.execute("""SELECT p.name, (t.rx_life+t.tx_life) tot FROM peers p
                           JOIN totals t ON p.pubkey=t.pubkey ORDER BY tot DESC LIMIT 5""").fetchall()
    tot_all = human((tot[0] or 0) + (tot[1] or 0))
    d24_all = human((d24[0] or 0) + (d24[1] or 0)) if d24 else "0B"
    out = [
        "🖥 <b>Сервер</b>",
        f"CPU {cpu:.1f}% · RAM {100.0*muse/mtot if mtot else 0:.0f}% "
        f"({human(muse)} / {human(mtot)})",
        f"Диск {dpct:.0f}% · аптайм {_uptime()}",
        f"Load avg: {load}",
        "",
        f"👥 Клиентов: {total_clients} · онлайн {online}",
        f"За 24ч: {d24_all} · всего: {tot_all}",
    ]
    if top:
        out.append("\n🔝 Топ-5 по трафику:")
        for nm, tt in top:
            out.append(f"  {nm} — {human(tt)}")
    return "\n".join(out)


# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "overview"
    if cmd == "init":
        init_db(); print(f"DB готова: {DB_PATH}")
    elif cmd == "poll":
        poll()
    elif cmd == "overview":
        print(overview())
    elif cmd == "server":
        print(server_info())
    elif cmd == "client":
        print(client(sys.argv[2]) if len(sys.argv) > 2 else "Укажи имя клиента")
    elif cmd == "prune":
        prune(int(sys.argv[2]) if len(sys.argv) > 2 else SAMPLE_RETENTION_DAYS)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
