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
                "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
                # параметры AmneziaWG 3.0 (у клиентов слоя 3.0)
                "headerprotectionkey", "contentpaddingaddition",
                "rekeyaftertime", "rekeytimeout", "rejectaftertime",
                "keepalivetimeout", "maxhandshakeattempts"}
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

def write_qr(payload: str, path: str, scale: int = 6):
    """Записать QR-код PNG. Предпочитаем segno (без Pillow)."""
    try:
        import segno
        segno.make(payload, error="m").save(path, scale=scale, border=2)
        return
    except ImportError:
        pass
    import qrcode
    img = qrcode.make(payload)
    img.save(path)


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
        # Явный список маршрутов. Без него приложение вычисляет режим туннеля по
        # тексту конфига и сравнивает его со строкой «AllowedIPs = 0.0.0.0/0, ::/0»
        # буквально — любое другое написание оно принимает за раздельное
        # туннелирование. С этим полем режим определяется однозначно.
        "allowed_ips": [a.strip() for a in
                        conf["peer"].get("AllowedIPs", "").split(",") if a.strip()],
        "persistent_keep_alive": conf["peer"].get("PersistentKeepalive", "25"),
    }
    for i in ("I1", "I2", "I3", "I4", "I5"):
        if i in awg:
            last_config[i] = awg[i]
    # Параметры AmneziaWG 3.0 кладём в last_config: приложение читает их именно
    # оттуда (AwgClientConfig::fromJson). Клиенты слоя 2.0 их просто не имеют.
    for k in ("HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime",
              "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout",
              "MaxHandshakeAttempts"):
        if k in awg:
            last_config[k] = awg[k]

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
    #
    # Версии «3» приложение пока не знает вообще (в protocolConstants.h есть
    # только 1.5 и 2), поэтому для клиентов слоя 3.0 максимум, который оно
    # способно показать, — «2»; сами v3-параметры при этом не теряются.
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
        # Метка «конфиг не от мастера установки Amnezia, а свой». Без неё
        # приложение подписывает сервер как «AmneziaWG Legacy»: в
        # serverDescription.cpp имя контейнера меняется на Legacy ровно при
        # условии «контейнер amnezia-awg И isThirdPartyConfig == false».
        # Сам импорт .conf в приложении выставляет этот флаг точно так же
        # (importController.cpp), так что мы просто повторяем его поведение.
        "isThirdPartyConfig": True,
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
        write_qr(text, base + ".png")
        print(f"[qr]  {base}.png  (сырой .conf — AmneziaWG native / WireGuard)")

    if do_uri:
        uri = build_vpn_uri(conf, name)
        with open(base + ".vpn", "w", encoding="utf-8") as f:
            f.write(uri + "\n")
        write_qr(uri, base + "-vpn.png")
        print(f"[uri] {base}.vpn  +  {base}-vpn.png  (Amnezia VPN app)")
        if args.print_uri:
            print(uri)

    if not (do_qr or do_uri):
        print("Укажи --qr-conf / --vpn-uri / --all", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
