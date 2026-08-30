#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-or-later
"""
awg3_obfuscate.py — генератор параметров обфускации AmneziaWG **3.0**.

Отличие от генератора для 2.0 (az-awg2): кроме Jc/S1-S4/H1-H4/I1-I5 здесь
генерируются параметры, появившиеся только в AmneziaWG 3.0:

  * HeaderProtectionKey     — ChaCha20-ключ (32 байта). Шифрует низкоэнтропийные
                              поля заголовка каждого пакета. Nonce берётся из
                              крипто-паддинга S1..S4, поэтому ВСЕ S1..S4 обязаны
                              быть >= HeaderCipherNonceSize (12). В коде
                              amneziawg-go проверка `padding < 12` (текст ошибки
                              там говорит «more then 8» — это опечатка апстрима,
                              фактическая граница 12).
  * ContentPaddingAddition  — диапазон дополнительного паддинга контента.
  * RekeyAfterTime / RekeyTimeout / RejectAfterTime / KeepaliveTimeout /
    MaxHandshakeAttempts    — рандомизация таймингов WireGuard: убирает
                              характерный «пульс» ретраев handshake, по которому
                              DPI опознаёт протокол по тайминг-сигнатуре.

Что важно знать про совместимость:
  * HeaderProtectionKey задаётся в клиентском .conf в BASE64, а в UAPI сервера —
    в HEX. Здесь генерируются оба представления.
  * Linux-утилиты amneziawg-tools (v1.0.20260618-2) НЕ умеют читать v3-ключи из
    конфига — на сервере они применяются через UAPI-сокет (awg3-uapi.py).
    Клиентские приложения AmneziaWG на базе amneziawg-go/v3 читают их из .conf.

Инварианты, которые генератор соблюдает:
  * H1..H4 — 4 НЕПЕРЕСЕКАЮЩИХСЯ диапазона, low >= 5 (1..4 заняты типами
    сообщений ванильного WireGuard), в пределах [5, 2^31-1] ради UI-валидаторов.
    Пересечение диапазонов amneziawg-go отвергает («headers must not overlap»).
  * S1 + 56 != S2 — иначе handshake init и response совпадут по длине и дадут
    DPI стабильный фингерпринт.
  * S1 <= 1132, S2 <= 1188 (границы спеки).
  * при включённой header protection: S1..S4 >= 12.
  * Jmax < MTU системы, иначе junk-пакет фрагментируется — само по себе подозрительно.

Профили (кроме Jc/Jmin/Jmax и «client-side» таймингов) обязаны совпадать на
сервере и клиенте.
"""

import argparse
import json
import os
import secrets
import sys

# ─────────────────────────────────────────────────────────────────────────────
# CSPRNG helpers
# ─────────────────────────────────────────────────────────────────────────────

# nonce ChaCha20 в amneziawg-go: HeaderCipherNonceSize = 12
HEADER_CIPHER_NONCE_SIZE = 12
HEADER_CIPHER_KEY_SIZE = 32


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
# CPS-теги (I1..I5)
# ─────────────────────────────────────────────────────────────────────────────

TAG_MAX = 999  # один тег <r>/<rc>/<rd> должен быть <= 999, 1000 ломает парсер


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
# Пулы доменов/адресов для мимикрии
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

# Реальные размеры UDP-payload популярных клиентов — junk совпадает по объёму
# с настоящим трафиком браузера.
BFP = {
    "chrome":  {"qi": (1250, 1250), "q0": (1250, 1350), "tls": (512, 800), "dtls": (1100, 1200)},
    "firefox": {"qi": (1200, 1252), "q0": (1200, 1300), "tls": (512, 700), "dtls": (1050, 1200)},
    "safari":  {"qi": (1250, 1252), "q0": (1250, 1300), "tls": (512, 750), "dtls": (1100, 1200)},
}


# ─────────────────────────────────────────────────────────────────────────────
# Генераторы I-пакетов (мимикрия)
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
    """Нейтральный шум без протокольной сигнатуры."""
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
    """4 непересекающихся диапазона (low, high), low >= 5, в [5, 2^31-1].

    amneziawg-go отвергает пересекающиеся диапазоны («headers must not
    overlap»), поэтому проверка на пересечение здесь строгая.
    """
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
            if end <= start:
                ok = False
                break
            ranges.append((start, end))
            prev_end = end
        if ok and len(ranges) == 4:
            return [f"{s}-{e}" for s, e in ranges]
    return ["10-20000", "40000-60000", "80000-100000", "120000-140000"]


# ─────────────────────────────────────────────────────────────────────────────
# Пресеты интенсивности
#
# s_min — нижняя граница S1..S4. При включённой header protection она
# поднимается до 12 автоматически (см. clamp_for_header_protection).
# ─────────────────────────────────────────────────────────────────────────────

PRESETS = {
    # router: минимальные шумы для слабых устройств (Keenetic/MikroTik/RPi)
    "router": dict(jc=(3, 5), jmin=8, jmax=80, s1=(15, 60), s2=(15, 60),
                   s3=(12, 40), s4=(12, 16), i_profiles=[], mtu=1400,
                   header_protection=False, content_padding=None, timings=False),
    # low: лёгкая обфускация, минимум оверхеда
    "low": dict(jc=(3, 6), jmin=8, jmax=80, s1=(15, 80), s2=(15, 80),
                s3=(12, 40), s4=(12, 16), i_profiles=["dns"], mtu=1400,
                header_protection=False, content_padding=None, timings=False),
    # medium (по умолчанию): полный набор 2.0 + header protection 3.0
    "medium": dict(jc=(4, 8), jmin=16, jmax=120, s1=(30, 120), s2=(30, 120),
                   s3=(20, 80), s4=(12, 20), i_profiles=["quic_initial"], mtu=1380,
                   header_protection=True, content_padding=(40, 160), timings=True),
    # high: + 2 I-пакета, шире паддинги
    "high": dict(jc=(6, 12), jmin=24, jmax=250, s1=(50, 150), s2=(50, 150),
                 s3=(40, 120), s4=(16, 28), i_profiles=["quic_initial", "tls"], mtu=1360,
                 header_protection=True, content_padding=(80, 320), timings=True),
    # paranoid: максимум, 3 профиля, широкий H-разброс, MTU под сотовые
    "paranoid": dict(jc=(8, 15), jmin=32, jmax=400, s1=(80, 150), s2=(80, 150),
                     s3=(60, 130), s4=(20, 32), i_profiles=["quic_initial", "tls", "dns"],
                     mtu=1280, header_protection=True, content_padding=(120, 480),
                     timings=True),
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
# Тайминги 3.0
#
# Дефолты WireGuard: REKEY_AFTER_TIME 120, REKEY_TIMEOUT 5, REJECT_AFTER_TIME 180,
# KEEPALIVE_TIMEOUT 10, MAX_HANDSHAKE_ATTEMPTS 18. Рандомизируем вокруг них
# диапазонами — сохраняем работоспособность, ломаем тайминг-сигнатуру.
#
# Инвариант WireGuard: REKEY_AFTER_TIME < REJECT_AFTER_TIME, и
# REJECT_AFTER_TIME должен с запасом превышать REKEY_AFTER_TIME + время на
# ретраи, иначе сессия будет рваться. Держим нижнюю границу reject выше верхней
# границы rekey.
# ─────────────────────────────────────────────────────────────────────────────

def gen_timings() -> dict:
    rekey_lo = rnd(100, 118)
    rekey_hi = rekey_lo + rnd(6, 24)                 # <= 142
    reject_lo = rekey_hi + rnd(20, 40)               # строго выше rekey_hi
    reject_hi = reject_lo + rnd(10, 40)
    return {
        "RekeyAfterTime": f"{rekey_lo}-{rekey_hi}",
        "RekeyTimeout": f"{rnd(4, 5)}-{rnd(6, 9)}",
        "RejectAfterTime": f"{reject_lo}-{reject_hi}",
        "KeepaliveTimeout": f"{rnd(7, 10)}-{rnd(11, 18)}",
        "MaxHandshakeAttempts": f"{rnd(14, 18)}-{rnd(19, 26)}",
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
             header_protection: bool = None,
             timings: bool = None,
             content_padding: bool = None) -> dict:
    """Собрать полный согласованный набор параметров AmneziaWG 3.0.

    Возвращает dict: Jc,Jmin,Jmax,S1..S4,H1..H4,I1..I5,MTU и — если включены —
    HeaderProtectionKey (base64), _HeaderProtectionKeyHex, ContentPaddingAddition,
    RekeyAfterTime, RekeyTimeout, RejectAfterTime, KeepaliveTimeout,
    MaxHandshakeAttempts.
    """
    if preset not in PRESETS:
        preset = "medium"
    p = PRESETS[preset]
    mtu = mtu or p["mtu"]

    use_hp = p["header_protection"] if header_protection is None else bool(header_protection)
    use_tm = p["timings"] if timings is None else bool(timings)
    cp_range = p["content_padding"]
    if content_padding is False:
        cp_range = None
    elif content_padding is True and cp_range is None:
        cp_range = (40, 160)

    jc = _range(p["jc"])
    jmin = int(p["jmin"])
    jmax = int(p["jmax"])
    # junk-пакет не должен фрагментироваться на системном MTU (1500), иначе
    # фрагменты сами по себе выглядят аномально. Потолок здесь константный, а не
    # от MTU, поэтому пресеты в него упираются с запасом — но порядок всё равно
    # такой же, как в генераторе 2.0: сначала потолок, потом инвариант. Иначе
    # пресет с jmin >= 1400 однажды выдал бы Jmin > Jmax, а такую пару не
    # отвергает ни одна сторона (см. пояснение в awg_obfuscate.py).
    jmax = min(jmax, 1400)
    if jmin >= jmax:
        jmin = max(1, jmax - 40)

    s1 = _range(p["s1"])
    s2 = _range(p["s2"])
    s3 = _range(p["s3"])
    s4 = _range(p["s4"])

    if use_hp:
        # nonce header-шифра берётся из крипто-паддинга → каждый S >= 12
        s1 = max(s1, HEADER_CIPHER_NONCE_SIZE)
        s2 = max(s2, HEADER_CIPHER_NONCE_SIZE)
        s3 = max(s3, HEADER_CIPHER_NONCE_SIZE)
        s4 = max(s4, HEADER_CIPHER_NONCE_SIZE)

    # инвариант спеки: S1 + 56 != S2 (иначе init/response совпадут по размеру)
    while s1 + 56 == s2:
        s2 += 1
    s1 = min(s1, 1132)
    s2 = min(s2, 1188)
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

    if use_hp:
        raw = secrets.token_bytes(HEADER_CIPHER_KEY_SIZE)
        # клиентский .conf ожидает base64, UAPI сервера — hex
        import base64
        out["HeaderProtectionKey"] = base64.b64encode(raw).decode()
        out["_HeaderProtectionKeyHex"] = raw.hex()

    if cp_range:
        lo = rnd(cp_range[0], (cp_range[0] + cp_range[1]) // 2)
        hi = rnd(lo + 8, cp_range[1])
        out["ContentPaddingAddition"] = f"{lo}-{hi}"

    if use_tm:
        out.update(gen_timings())

    for idx, prof in enumerate(profiles, start=1):
        out[f"I{idx}"] = MIMIC[prof](mtu, custom_host, fp)
    out["_profiles"] = profiles
    return out


# Ключи, которые пишутся в [Interface] клиентского/серверного конфига.
# Порядок фиксирован — так конфиги диффаются глазами.
IFACE_KEYS_20 = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
                 "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]

# v3-ключи. На сервере их применяет awg3-uapi.py (amneziawg-tools их не парсит),
# в клиентский .conf они пишутся как есть.
IFACE_KEYS_30 = ["HeaderProtectionKey", "ContentPaddingAddition",
                 "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
                 "KeepaliveTimeout", "MaxHandshakeAttempts"]

IFACE_KEYS = IFACE_KEYS_20 + IFACE_KEYS_30

# Соответствие имён конфига именам UAPI amneziawg-go.
UAPI_NAMES = {
    "Jc": "jc", "Jmin": "jmin", "Jmax": "jmax",
    "S1": "s1", "S2": "s2", "S3": "s3", "S4": "s4",
    "H1": "h1", "H2": "h2", "H3": "h3", "H4": "h4",
    "I1": "i1", "I2": "i2", "I3": "i3", "I4": "i4", "I5": "i5",
    "ContentPaddingAddition": "content_padding_addition",
    "RekeyAfterTime": "rekey_after_time",
    "RekeyTimeout": "rekey_timeout",
    "RejectAfterTime": "reject_after_time",
    "KeepaliveTimeout": "keepalive_timeout",
    "MaxHandshakeAttempts": "max_handshake_attempts",
    # header_protection_key передаётся в UAPI в HEX — берём из _HeaderProtectionKeyHex
}


def to_interface_block(params: dict, v3: bool = True) -> str:
    """Фрагмент [Interface] для клиентского конфига."""
    keys = IFACE_KEYS if v3 else IFACE_KEYS_20
    lines = []
    for k in keys:
        if k in params and params[k] != "" and params[k] is not None:
            lines.append(f"{k} = {params[k]}")
    return "\n".join(lines)


def to_env(params: dict) -> str:
    """Экспорт для bash: AWG_Jc=…, AWG_HeaderProtectionKey=…, AWG_HPK_HEX=…"""
    lines = []
    for k in IFACE_KEYS + ["MTU"]:
        if k in params and params[k] not in ("", None):
            val = str(params[k]).replace("'", "'\\''")
            lines.append(f"AWG_{k}='{val}'")
    if params.get("_HeaderProtectionKeyHex"):
        lines.append("AWG_HPK_HEX='%s'" % params["_HeaderProtectionKeyHex"])
    return "\n".join(lines)


def to_uapi(params: dict) -> str:
    """Строки `key=value` для UAPI-сокета amneziawg-go (по одной на строку)."""
    lines = []
    for k in IFACE_KEYS_20 + IFACE_KEYS_30:
        if k == "HeaderProtectionKey":
            continue
        if k in params and params[k] not in ("", None):
            lines.append(f"{UAPI_NAMES[k]}={params[k]}")
    if params.get("_HeaderProtectionKeyHex"):
        lines.append("header_protection_key=%s" % params["_HeaderProtectionKeyHex"])
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="AmneziaWG 3.0 obfuscation generator")
    ap.add_argument("--preset", default="medium", choices=list(PRESETS.keys()))
    ap.add_argument("--template", default="", choices=[""] + list(TEMPLATES.keys()),
                    help="готовый профиль мимикрии (переопределяет I-пакеты пресета)")
    ap.add_argument("--mtu", type=int, default=0)
    ap.add_argument("--fp", default="chrome", choices=list(BFP.keys()))
    ap.add_argument("--host", default="", help="кастомный домен для мимикрии")
    ap.add_argument("--extreme", action="store_true", help="широкий H-разброс (10M)")
    ap.add_argument("--no-header-protection", action="store_true",
                    help="выключить header protection (совместимость со старыми клиентами)")
    ap.add_argument("--no-timings", action="store_true",
                    help="не рандомизировать тайминги")
    ap.add_argument("--no-content-padding", action="store_true")
    ap.add_argument("--format", default="interface",
                    choices=["interface", "interface20", "env", "uapi", "json"])
    args = ap.parse_args()

    params = generate(
        preset=args.preset, template=args.template, mtu=args.mtu,
        fp=args.fp, custom_host=args.host, extreme=args.extreme,
        header_protection=False if args.no_header_protection else None,
        timings=False if args.no_timings else None,
        content_padding=False if args.no_content_padding else None,
    )

    if args.format == "interface":
        print(to_interface_block(params, v3=True))
    elif args.format == "interface20":
        print(to_interface_block(params, v3=False))
    elif args.format == "env":
        print(to_env(params))
    elif args.format == "uapi":
        print(to_uapi(params))
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
