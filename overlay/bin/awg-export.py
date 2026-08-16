#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg-export.py — из клиентского AmneziaWG .conf делает:
  1. QR-код (PNG) с сырым текстом .conf  → импорт в приложение AmneziaWG
     (Android/iOS/Windows) и в Amnezia VPN «Сканировать QR». УНИВЕРСАЛЬНО.
  2. vpn:// URI (формат Qt qCompress + base64url)  → «вставить из буфера»
     в основном приложении Amnezia VPN (Android — в один тап).
  3. .conf в нативном формате (как есть) — для «Import tunnel from file».

Формат vpn:// (реверс из amnezia-client, issue #1407):
    payload = qCompress(json)              # 4 байта BE длины + zlib
    uri     = "vpn://" + base64url(payload).rstrip("=")

QR сырого .conf — гарантированно рабочий путь для нативного AmneziaWG-клиента;
vpn:// — «best-effort» для основного приложения (JSON-схема немного меняется
между версиями клиента, поэтому первый импорт стоит проверить вручную).

Зависимости: segno (чистый python, без Pillow) ИЛИ qrcode[pil].
"""

import argparse
import base64
import json
import os
import re
import struct
import sys
import zlib


# ── парсинг .conf ────────────────────────────────────────────────────────────

def parse_conf(text: str) -> dict:
    """Извлечь поля из [Interface]/[Peer] клиентского awg .conf."""
    data = {"interface": {}, "peer": {}, "awg": {}, "raw": text}
    section = None
    awg_keys = {"jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
                "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.lower().startswith("[interface]"):
            section = "interface"; continue
        if s.lower().startswith("[peer]"):
            section = "peer"; continue
        if "=" not in s or section is None:
            continue
        key, val = s.split("=", 1)
        key = key.strip(); val = val.strip()
        if section == "interface" and key.lower() in awg_keys:
            data["awg"][key] = val
        data[section][key] = val
    return data


def host_port(endpoint: str):
    """'1.2.3.4:52443' → ('1.2.3.4', '52443'). Поддержка [IPv6]:port."""
    m = re.match(r"^\[(.+)\]:(\d+)$", endpoint)
    if m:
        return m.group(1), m.group(2)
    if ":" in endpoint:
        h, p = endpoint.rsplit(":", 1)
        return h, p
    return endpoint, "51820"


# ── QR ───────────────────────────────────────────────────────────────────────

def write_qr(payload: str, path: str, scale: int = 6) -> bool:
    """Записать QR-код PNG. Предпочитаем segno (без Pillow).

    Возвращает False, если payload не влезает ни в один QR (типично для
    AntiZapret split-конфигов с огромным AllowedIPs). Вызывающий код должен
    продолжить без PNG и не ронять создание клиента.
    """
    # От меньшего ECC к большему: длинные payload сначала пытаемся вместить.
    ecc_levels = ("l", "m", "q", "h")
    try:
        import segno
        from segno.encoder import DataOverflowError as SegnoOverflow
    except ImportError:
        segno = None
    else:
        last_err = None
        for ecc in ecc_levels:
            try:
                segno.make(payload, error=ecc).save(path, scale=scale, border=2)
                return True
            except SegnoOverflow as exc:
                last_err = exc
        print(
            "[qr] skip %s: data too large for QR (%d chars)%s"
            % (path, len(payload), (": %s" % last_err) if last_err else ""),
            file=sys.stderr,
        )
        return False

    try:
        import qrcode
        from qrcode.exceptions import DataOverflowError as QrOverflow
    except ImportError:
        print("[qr] skip %s: no segno/qrcode installed" % path, file=sys.stderr)
        return False

    correction = (
        getattr(qrcode.constants, "ERROR_CORRECT_L", 1),
        getattr(qrcode.constants, "ERROR_CORRECT_M", 0),
        getattr(qrcode.constants, "ERROR_CORRECT_Q", 3),
        getattr(qrcode.constants, "ERROR_CORRECT_H", 2),
    )
    last_err = None
    for level in correction:
        try:
            qr = qrcode.QRCode(
                version=None,
                error_correction=level,
                box_size=scale,
                border=2,
            )
            qr.add_data(payload)
            qr.make(fit=True)
            qr.make_image(fill_color="black", back_color="white").save(path)
            return True
        except (QrOverflow, ValueError) as exc:
            last_err = exc
    print(
        "[qr] skip %s: data too large for QR (%d chars)%s"
        % (path, len(payload), (": %s" % last_err) if last_err else ""),
        file=sys.stderr,
    )
    return False


# ── vpn:// (Amnezia VPN app) ─────────────────────────────────────────────────

def qcompress(raw: bytes) -> bytes:
    """Аналог Qt qCompress: 4 байта BE несжатой длины + zlib."""
    return struct.pack(">I", len(raw)) + zlib.compress(raw, 8)


def build_amnezia_json(conf: dict, name: str) -> dict:
    """Собрать JSON-контейнер amnezia-awg для vpn:// URI."""
    endpoint = conf["peer"].get("Endpoint", "")
    host, port = host_port(endpoint)
    dns = conf["interface"].get("DNS", "1.1.1.1, 1.0.0.1")
    dns_parts = [d.strip() for d in dns.split(",")]
    dns1 = dns_parts[0] if dns_parts else "1.1.1.1"
    dns2 = dns_parts[1] if len(dns_parts) > 1 else dns1
    mtu = conf["interface"].get("MTU", "1420")

    awg = conf["awg"]
    last_config = {
        "H1": awg.get("H1", "1"), "H2": awg.get("H2", "2"),
        "H3": awg.get("H3", "3"), "H4": awg.get("H4", "4"),
        "Jc": awg.get("Jc", "0"), "Jmin": awg.get("Jmin", "0"),
        "Jmax": awg.get("Jmax", "0"),
        "S1": awg.get("S1", "0"), "S2": awg.get("S2", "0"),
        "S3": awg.get("S3", "0"), "S4": awg.get("S4", "0"),
        "config": conf["raw"],
        "client_ip": conf["interface"].get("Address", "").split("/")[0],
        "client_priv_key": conf["interface"].get("PrivateKey", ""),
        "client_pub_key": "",
        "hostName": host, "port": int(port) if port.isdigit() else 0,
        "psk_key": conf["peer"].get("PresharedKey", ""),
        "server_pub_key": conf["peer"].get("PublicKey", ""),
        "mtu": mtu,
    }
    for i in ("I1", "I2", "I3", "I4", "I5"):
        if i in awg:
            last_config[i] = awg[i]

    # Версия протокола для приложения Amnezia VPN.
    #
    # Без этого поля приложение показывает конфиг как «AmneziaWG Legacy»:
    # при импорте vpn:// оно не вычисляет версию само, а читает готовое
    # protocol_version из контейнера (configKey::protocolVersion), и пустое
    # значение трактует как легаси. Отдельно от отображения поле влияет на то,
    # подставит ли клиент дефолты для S3/S4, если те не заданы.
    #
    # Считаем ровно по логике самого клиента (ImportController::
    # extractWireGuardConfig): есть S3 и S4 → «2», иначе только I-пакеты → «1.5».
    has_s34 = bool(last_config.get("S3")) and bool(last_config.get("S4"))
    has_ijunk = any(last_config.get(i) for i in ("I1", "I2", "I3", "I4", "I5"))
    protocol_version = "2" if has_s34 else ("1.5" if has_ijunk else "")

    awg_container = {
        "H1": last_config["H1"], "H2": last_config["H2"],
        "H3": last_config["H3"], "H4": last_config["H4"],
        "Jc": last_config["Jc"], "Jmin": last_config["Jmin"],
        "Jmax": last_config["Jmax"],
        "S1": last_config["S1"], "S2": last_config["S2"],
        "last_config": json.dumps(last_config, ensure_ascii=False),
        "mtu": str(mtu), "port": port, "transport_proto": "udp",
    }
    if protocol_version:
        awg_container["protocol_version"] = protocol_version

    return {
        "containers": [{
            "container": "amnezia-awg",
            "awg": awg_container,
        }],
        "defaultContainer": "amnezia-awg",
        "description": name,
        "dns1": dns1, "dns2": dns2,
        "hostName": host,
    }


def build_vpn_uri(conf: dict, name: str) -> str:
    js = build_amnezia_json(conf, name)
    raw = json.dumps(js, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    packed = qcompress(raw)
    b64 = base64.urlsafe_b64encode(packed).decode("ascii").rstrip("=")
    return "vpn://" + b64


def decode_vpn_uri(uri: str) -> dict:
    """Обратная проверка (для self-test)."""
    b64 = uri[len("vpn://"):]
    b64 += "=" * (-len(b64) % 4)
    packed = base64.urlsafe_b64decode(b64)
    raw = zlib.decompress(packed[4:])
    return json.loads(raw)


# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="AmneziaWG .conf → QR + vpn:// URI")
    ap.add_argument("conf", help="путь к клиентскому .conf")
    ap.add_argument("--name", default="", help="имя профиля (для описания)")
    ap.add_argument("--outdir", default=".", help="куда класть артефакты")
    ap.add_argument("--qr-conf", action="store_true",
                    help="QR из сырого .conf (для нативного AmneziaWG-клиента)")
    ap.add_argument("--vpn-uri", action="store_true", help="сгенерировать vpn:// URI")
    ap.add_argument("--all", action="store_true", help="всё сразу")
    ap.add_argument("--print-uri", action="store_true", help="печатать URI в stdout")
    args = ap.parse_args()

    with open(args.conf, "r", encoding="utf-8") as f:
        text = f.read()
    conf = parse_conf(text)
    name = args.name or os.path.splitext(os.path.basename(args.conf))[0]
    os.makedirs(args.outdir, exist_ok=True)
    base = os.path.join(args.outdir, name)

    do_qr = args.qr_conf or args.all
    do_uri = args.vpn_uri or args.all

    if do_qr:
        qr_path = base + ".png"
        if write_qr(text, qr_path):
            print(f"[qr]  {qr_path}  (сырой .conf — AmneziaWG native / WireGuard)")
        else:
            print(
                "[qr]  skipped (conf too large for QR — use .conf / vpn:// download)",
                file=sys.stderr,
            )

    if do_uri:
        uri = build_vpn_uri(conf, name)
        with open(base + ".vpn", "w", encoding="utf-8") as f:
            f.write(uri + "\n")
        vpn_qr = base + "-vpn.png"
        if write_qr(uri, vpn_qr):
            print(f"[uri] {base}.vpn  +  {vpn_qr}  (Amnezia VPN app)")
        else:
            print(
                f"[uri] {base}.vpn  (vpn:// QR skipped — payload too large)",
                file=sys.stderr,
            )
        if args.print_uri:
            print(uri)

    if not (do_qr or do_uri):
        print("Укажи --qr-conf / --vpn-uri / --all", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
