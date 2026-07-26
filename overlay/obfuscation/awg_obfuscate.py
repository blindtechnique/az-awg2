#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg_obfuscate.py — генератор параметров обфускации AmneziaWG 2.0 с мимикрией.

Порт логики из AmneziaWG-Architect (Vadim-Khristenko) и bivlked/amneziawg-installer
в самодостаточный Python без внешних зависимостей.

Ключевые принципы обфускации AmneziaWG 2.0:
  * H1..H4  — 4 НЕПЕРЕСЕКАЮЩИХСЯ диапазона magic-header, каждый >= 5
              (1..4 зарезервированы под типы сообщений ванильного WireGuard),
              в безопасной половине uint32 (<= 2^31-1) ради UI-валидатора
              Windows-клиента. Это то, чего НЕТ в AntiZapret (там H = 1,2,3,4).
  * S1..S4  — размеры junk-префиксов для handshake init/response/cookie и
              транспортных пакетов (S3/S4 — новшество 2.0). Ограничение спеки:
              S1 <= 1132, S2 <= 1188, S1 + 56 != S2 (иначе init/response
              совпадут по размеру → DPI-фингерпринт). S4 включает обфускацию
              ТРАНСПОРТНЫХ пакетов — то, ради чего и нужна 2.0.
  * Jc/Jmin/Jmax — «junk-поезд»: Jc мусорных пакетов размером [Jmin, Jmax]
              перед handshake. Единственные параметры, которые МОГУТ отличаться
              client<->server.
  * I1..I5  — «signature junk»: пакеты, имитирующие реальные протоколы
              (QUIC Initial, TLS ClientHello, DNS-запрос, DTLS, SIP). Строятся
              из CPS-тегов: <b 0x..> (байты), <r N> (случайный паддинг),
              <rc N>/<rd N>, <c> (счётчик), <t> (таймстамп).

Все параметры (кроме Jc/Jmin/Jmax) ОБЯЗАНЫ совпадать между сервером и клиентом.
"""

import argparse
import json
import os
import secrets
import sys

# ─────────────────────────────────────────────────────────────────────────────
# CSPRNG helpers
# ─────────────────────────────────────────────────────────────────────────────

def rnd(a: int, b: int) -> int:
    """Инклюзивное случайное целое [a, b] на базе secrets (CSPRNG)."""
    if b < a:
        a, b = b, a
    return a + secrets.randbelow(b - a + 1)

def rh(n: int) -> str:
    """n случайных байт → hex (2n символов)."""
    return secrets.token_bytes(n).hex()

def pick(seq):
    return seq[secrets.randbelow(len(seq))]

def hexpad(value: int, byte_len: int) -> str:
    h = format(int(value), "x")
    h = h.rjust(byte_len * 2, "0")
    return h[-(byte_len * 2):]

def even(h: str) -> str:
    return h if len(h) % 2 == 0 else h + "0"

# ─────────────────────────────────────────────────────────────────────────────
# CPS-теги
# ─────────────────────────────────────────────────────────────────────────────

TAG_MAX = 999  # AmneziaWG: один тег <r>/<rc>/<rd> должен быть <= 999 (1000 ломает парсер)

def split_pad(n: int, tag: str = "r") -> str:
    """Разбить N байт паддинга на CPS-теги не длиннее TAG_MAX каждый."""
    n = max(0, int(n))
    if n == 0:
        return ""
    out = []
    while n > TAG_MAX:
        out.append(f"<{tag} {TAG_MAX}>")
        n -= TAG_MAX
    if n > 0:
        out.append(f"<{tag} {n}>")
    return "".join(out)

# ─────────────────────────────────────────────────────────────────────────────
# Пулы доменов/адресов для мимикрии (доступны из РФ на Q1 2026, не в блок-листах;
# крупный трафик → блокировка причиняет экономический ущерб = «дорого» блокировать).
# Полный список в hostpools.py; здесь — репрезентативная выборка.
# ─────────────────────────────────────────────────────────────────────────────

HOSTPOOLS = {
    "quic": [
        "yandex.net", "yastatic.net", "storage.yandexcloud.net", "vk.com",
        "mycdn.me", "mail.ru", "ozon.ru", "wildberries.ru", "kinopoisk.ru",
        "sber.ru", "gosuslugi.ru", "mts.ru", "rutube.ru", "dzen.ru",
        "gcore.com", "cdn.gcore.com", "bunny.net", "cloudfront.net",
        "akamaiedge.net", "github.com", "cdn.jsdelivr.net", "steamstatic.com",
        "spotify.com", "wikipedia.org", "icloud.com", "microsoft.com",
    ],
    "tls": [
        "yandex.ru", "vk.com", "mail.ru", "ozon.ru", "wildberries.ru",
        "sberbank.ru", "gosuslugi.ru", "kinopoisk.ru", "avito.ru", "rbc.ru",
        "habr.com", "gcore.com", "cloudfront.net", "akamaiedge.net",
        "github.com", "objects.githubusercontent.com", "cdn.jsdelivr.net",
        "microsoft.com", "apple.com", "steampowered.com", "wikipedia.org",
    ],
    "dtls": [
        "stun.yandex.net", "turn.vk.com", "stun.mail.ru", "stun.sipnet.ru",
        "stun.l.google.com", "meet.jit.si", "stun.services.mozilla.com",
        "global.stun.twilio.com", "stun.livekit.cloud", "openrelay.metered.ca",
    ],
    "sip": [
        "sip.beeline.ru", "sip.mts.ru", "sip.megafon.ru", "sip.sipnet.ru",
        "sip.mango-office.ru", "sip.zadarma.com", "sip.novofon.ru",
        "sip.exolve.ru", "sip.telnyx.com", "sip.twilio.com",
    ],
    "dns": [
        "77.88.8.8", "77.88.8.1", "8.8.8.8", "1.1.1.1", "9.9.9.9",
        "94.140.14.14", "208.67.222.222", "195.46.39.39", "223.5.5.5",
    ],
}

# Реальные размеры UDP-payload (byte) популярных клиентов — чтобы junk совпадал
# по объёму с настоящим трафиком браузера (Browser Fingerprint).
BFP = {
    "chrome":  {"qi": (1250, 1250), "q0": (1250, 1350), "tls": (512, 800), "dtls": (1100, 1200)},
    "firefox": {"qi": (1200, 1252), "q0": (1200, 1300), "tls": (512, 700), "dtls": (1050, 1200)},
    "safari":  {"qi": (1250, 1252), "q0": (1250, 1300), "tls": (512, 750), "dtls": (1100, 1200)},
}

# ─────────────────────────────────────────────────────────────────────────────
# Генераторы I-пакетов (мимикрия). Каждый возвращает строку из CPS-тегов.
# ─────────────────────────────────────────────────────────────────────────────

def _host(profile_key: str, custom_host: str = "") -> str:
    if custom_host:
        return custom_host
    return pick(HOSTPOOLS[profile_key])

def mk_quic_initial(mtu: int, fp: str = "chrome") -> str:
    """Имитация QUIC Initial (long header, version 1, DCID/SCID/token)."""
    dcid = rnd(8, 20)
    scid = rnd(0, 20)
    token_len = 0 if rnd(0, 1) == 0 else rnd(8, 32)
    hdr = even(
        hexpad(0xc0 | rnd(0, 3), 1) + "00000001" +
        hexpad(dcid, 1) + rh(dcid) +
        hexpad(scid, 1) + rh(scid) +
        hexpad(token_len, 1) + rh(token_len) + rh(4)
    )
    header_b = len(hdr) // 2
    lo, hi = BFP.get(fp, BFP["chrome"])["qi"]
    target = rnd(lo, min(hi, mtu - 28))
    pad = max(0, target - header_b - 4)  # -4 за <t>
    return f"<b 0x{hdr}>" + "<t>" + split_pad(pad)

def mk_quic_0rtt(mtu: int, fp: str = "chrome") -> str:
    dcid = rnd(8, 20)
    scid = rnd(0, 20)
    hdr = even(
        hexpad(0xd0 | rnd(0, 3), 1) + "00000001" +
        hexpad(dcid, 1) + rh(dcid) +
        hexpad(scid, 1) + rh(scid) + rh(4)
    )
    header_b = len(hdr) // 2
    lo, hi = BFP.get(fp, BFP["chrome"])["q0"]
    target = rnd(lo, min(hi, mtu - 28))
    pad = max(0, target - header_b - 4)
    return f"<b 0x{hdr}>" + "<t>" + split_pad(pad)

def mk_tls_client_hello(mtu: int, host: str = "", fp: str = "chrome") -> str:
    """Имитация TLS 1.3 ClientHello (record 0x16, version 0303, SNI-подобный размер)."""
    host = _host("tls", host)
    sni_len = min(len(host) + rnd(0, 6), 64)
    body = even("0303" + rh(32) + hexpad(rnd(0, 32), 1) + rh(rnd(0, 16)))
    rec = even("160301" + hexpad(len(body) // 2 + 2, 2) + body)
    header_b = len(rec) // 2
    lo, hi = BFP.get(fp, BFP["chrome"])["tls"]
    target = rnd(lo, min(hi, mtu - 28))
    pad = max(0, target - header_b - sni_len - 4)
    return f"<b 0x{rec}>" + f"<rc {sni_len}>" + "<t>" + split_pad(pad)

def mk_dns_query(mtu: int, host: str = "") -> str:
    """Имитация DNS-запроса (txid, flags 0100, 1 вопрос, A/AAAA)."""
    host = _host("dns", host)
    # для DNS host — это IP-строка из пула резолверов; имя-запрос собираем случайное
    qname = _host("tls", "") if "." in host and not host[0].isdigit() else "www." + pick(HOSTPOOLS["tls"])
    qhex = ""
    for label in qname.split("."):
        qhex += hexpad(len(label), 1) + "".join(hexpad(ord(c), 1) for c in label)
    qhex += "00"
    txid = rh(2)
    qtype = "0001" if rnd(0, 1) == 0 else "001c"
    dns = even(txid + "0100" + "0001" + "0000" + "0000" + "0000" + qhex + qtype + "0001")
    header_b = len(dns) // 2
    target = rnd(64, min(512, mtu - 20))
    pad = max(0, target - header_b)
    return f"<b 0x{dns}>" + split_pad(min(pad, 200)) + "<t>"

def mk_dtls(mtu: int, fp: str = "chrome") -> str:
    """Имитация DTLS 1.2 ClientHello (content type 0x16, version fefd)."""
    body = even("fefd" + rh(rnd(24, 40)))
    rec = even("16fefd" + rh(4) + hexpad(len(body) // 2, 2) + body)
    header_b = len(rec) // 2
    lo, hi = BFP.get(fp, BFP["chrome"])["dtls"]
    target = rnd(lo, min(hi, mtu - 28))
    pad = max(0, target - header_b - 4)
    return f"<b 0x{rec}>" + "<t>" + split_pad(pad)

def mk_sip(mtu: int, host: str = "") -> str:
    """Имитация SIP OPTIONS (текстовый протокол поверх UDP)."""
    host = _host("sip", host)
    line = f"OPTIONS sip:{host} SIP/2.0\r\n".encode()
    hdr = even(line.hex())
    header_b = len(hdr) // 2
    target = rnd(200, min(700, mtu - 28))
    pad = max(0, target - header_b)
    return f"<b 0x{hdr}>" + split_pad(pad) + "<t>"

def mk_noise(mtu: int) -> str:
    """Нейтральный шум без протокольной сигнатуры — чистый случайный паддинг."""
    return split_pad(rnd(60, min(300, mtu - 40)))

MIMIC = {
    "quic_initial": lambda mtu, host, fp: mk_quic_initial(mtu, fp),
    "quic_0rtt":    lambda mtu, host, fp: mk_quic_0rtt(mtu, fp),
    "tls":          lambda mtu, host, fp: mk_tls_client_hello(mtu, host, fp),
    "dns":          lambda mtu, host, fp: mk_dns_query(mtu, host),
    "dtls":         lambda mtu, host, fp: mk_dtls(mtu, fp),
    "sip":          lambda mtu, host, fp: mk_sip(mtu, host),
    "noise":        lambda mtu, host, fp: mk_noise(mtu),
}

# ─────────────────────────────────────────────────────────────────────────────
# H1..H4 — 4 непересекающихся диапазона
# ─────────────────────────────────────────────────────────────────────────────

def gen_h_ranges(spread: int = 500_000, extreme: bool = False) -> list:
    """8 случайных точек → sort → 4 пары (low, high), гарантированно
    непересекающихся, low >= 5, в [5, 2^31-1]. Возвращает ['a-b','c-d',...]."""
    cap = 2_147_483_647
    base_spread = 10_000_000 if extreme else spread
    for _ in range(40):
        pts = sorted(rnd(5, cap - base_spread) for _ in range(4))
        ranges = []
        ok = True
        prev_end = 0
        for start in pts:
            if start <= prev_end:
                ok = False
                break
            width = rnd(1000, min(50_000, base_spread))
            end = min(start + width, cap)
            if end <= start or start <= prev_end:
                ok = False
                break
            ranges.append((start, end))
            prev_end = end
        if ok and len(ranges) == 4:
            return [f"{s}-{e}" for s, e in ranges]
    # детерминированный fallback
    return ["10-20000", "40000-60000", "80000-100000", "120000-140000"]

# ─────────────────────────────────────────────────────────────────────────────
# Пресеты интенсивности
# ─────────────────────────────────────────────────────────────────────────────

PRESETS = {
    # router: минимальные шумы для слабых устройств (Keenetic/MikroTik/RPi)
    "router": dict(jc=(3, 5), jmin=8, jmax=80, s1=(15, 60), s2=(15, 60),
                   s3=(0, 0), s4=(0, 0), i_profiles=[], mtu=1420),
    # low: лёгкая обфускация, минимум оверхеда
    "low": dict(jc=(3, 6), jmin=8, jmax=80, s1=(15, 80), s2=(15, 80),
                s3=(0, 0), s4=(0, 0), i_profiles=["dns"], mtu=1420),
    # medium (по умолчанию): H рандом + S1..S4 + 1 профиль мимикрии
    "medium": dict(jc=(4, 8), jmin=8, jmax=120, s1=(30, 120), s2=(30, 120),
                   s3=(20, 80), s4=(4, 16), i_profiles=["quic_initial"], mtu=1420),
    # high: полный набор + 2 I-пакета + транспортная обфускация
    "high": dict(jc=(6, 12), jmin=16, jmax=250, s1=(50, 150), s2=(50, 150),
                 s3=(40, 120), s4=(8, 24), i_profiles=["quic_initial", "tls"], mtu=1420),
    # paranoid: максимум, 3 профиля, широкий H-разброс
    "paranoid": dict(jc=(8, 15), jmin=24, jmax=400, s1=(80, 150), s2=(80, 150),
                     s3=(60, 130), s4=(16, 32), i_profiles=["quic_initial", "tls", "dns"],
                     mtu=1280),
}

# Готовые шаблоны мимикрии «под один протокол» (автогенерация I1..I5)
TEMPLATES = {
    "quic":  ["quic_initial", "quic_0rtt"],
    "tls":   ["tls"],
    "web":   ["quic_initial", "tls"],        # смешанный веб-трафик
    "voip":  ["dtls", "sip"],                # звонки/WebRTC
    "dns":   ["dns"],
    "mixed": ["quic_initial", "tls", "dns"],
}

# ─────────────────────────────────────────────────────────────────────────────
# Главная сборка
# ─────────────────────────────────────────────────────────────────────────────

def _range(v):
    return rnd(v[0], v[1]) if isinstance(v, (list, tuple)) else int(v)

def generate(preset: str = "medium",
             template: str = "",
             mtu: int = 0,
             fp: str = "chrome",
             custom_host: str = "",
             extreme: bool = False,
             seedless_jc: bool = False) -> dict:
    """Собрать полный, согласованный набор параметров AmneziaWG 2.0.

    Возвращает dict с ключами Jc,Jmin,Jmax,S1,S2,S3,S4,H1..H4,I1..I5,MTU.
    Пустые I-слоты не включаются (их нельзя оставлять как I2= — клиенты падают).
    """
    if preset not in PRESETS:
        preset = "medium"
    p = PRESETS[preset]
    mtu = mtu or p["mtu"]

    jc = _range(p["jc"])
    jmin = int(p["jmin"])
    jmax = int(p["jmax"])
    if jmax <= jmin:
        jmax = jmin + 40
    jmax = min(jmax, mtu - 40)

    s1 = _range(p["s1"])
    s2 = _range(p["s2"])
    # инвариант спеки: S1 + 56 != S2 (иначе init/response совпадут по размеру)
    while s1 + 56 == s2:
        s2 += 1
    s1 = min(s1, 1132)
    s2 = min(s2, 1188)
    s3 = _range(p["s3"])
    s4 = _range(p["s4"])
    s3 = min(s3, 1132)
    s4 = min(s4, 32)

    h = gen_h_ranges(extreme=extreme)

    profiles = TEMPLATES.get(template, p["i_profiles"]) if template else p["i_profiles"]
    profiles = profiles[:5]  # максимум I1..I5

    out = {
        "preset": preset,
        "template": template or "(preset default)",
        "Jc": jc, "Jmin": jmin, "Jmax": jmax,
        "S1": s1, "S2": s2, "S3": s3, "S4": s4,
        "H1": h[0], "H2": h[1], "H3": h[2], "H4": h[3],
        "MTU": mtu,
    }
    for idx, prof in enumerate(profiles, start=1):
        out[f"I{idx}"] = MIMIC[prof](mtu, custom_host, fp)
    out["_profiles"] = profiles
    return out

# Ключи, которые пишутся в [Interface] (в правильном порядке).
IFACE_KEYS = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
              "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]

def to_interface_block(params: dict) -> str:
    """Готовый фрагмент для [Interface] сервера/клиента."""
    lines = []
    for k in IFACE_KEYS:
        if k in params and params[k] != "" and params[k] is not None:
            lines.append(f"{k} = {params[k]}")
    return "\n".join(lines)

def to_env(params: dict) -> str:
    """Экспорт для bash: AWG_Jc=.. AWG_H1=.. (используется awg-obfuscation.sh)."""
    lines = []
    for k in IFACE_KEYS + ["MTU"]:
        if k in params and params[k] not in ("", None):
            val = str(params[k]).replace("'", "'\\''")
            lines.append(f"AWG_{k}='{val}'")
    return "\n".join(lines)

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="AmneziaWG 2.0 obfuscation generator")
    ap.add_argument("--preset", default="medium",
                    choices=list(PRESETS.keys()))
    ap.add_argument("--template", default="", choices=[""] + list(TEMPLATES.keys()),
                    help="готовый профиль мимикрии (переопределяет I-пакеты пресета)")
    ap.add_argument("--mtu", type=int, default=0)
    ap.add_argument("--fp", default="chrome", choices=list(BFP.keys()))
    ap.add_argument("--host", default="", help="кастомный домен для мимикрии")
    ap.add_argument("--extreme", action="store_true", help="широкий H-разброс (10M)")
    ap.add_argument("--format", default="interface",
                    choices=["interface", "env", "json"])
    args = ap.parse_args()

    params = generate(preset=args.preset, template=args.template, mtu=args.mtu,
                      fp=args.fp, custom_host=args.host, extreme=args.extreme)

    if args.format == "interface":
        print(to_interface_block(params))
    elif args.format == "env":
        print(to_env(params))
    else:
        pub = {k: v for k, v in params.items() if not k.startswith("_")}
        print(json.dumps(pub, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        os._exit(0)
