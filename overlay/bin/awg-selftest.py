#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-or-later
"""
awg-selftest.py — проверка того, что выдаваемые клиентам артефакты приложение
Amnezia VPN действительно поймёт.

Зачем это нужно. Приложение читает `vpn://` не как попало: оно берёт готовые
поля из JSON, а не разбирает текст конфига. Если поля не хватает, симптом
получается косвенный и ищется долго:

  * нет client_priv_key      → Android не поднимает туннель, ErrorCode 1000;
  * нет allowed_ips и в тексте конфига не ровно «AllowedIPs = 0.0.0.0/0, ::/0»
                             → приложение пишет «включено раздельное
                               туннелирование», хотя туннель полный;
  * нет protocol_version     → конфиг показывается как «AmneziaWG Legacy».

Здесь повторены проверки из самого клиента (ImportController::
extractWireGuardConfig и serversUiController::hasSplitTunnelingFromAllowedIps),
чтобы такие вещи ловились до того, как дойдут до пользователя.

    awg-selftest.py <клиентский .conf> [ещё .conf ...]
    awg-selftest.py --all          # все конфиги из /opt/antizapret-awg/clients
"""

import glob
import json
import os
import subprocess
import sys

CLIENT_DIR = os.environ.get("AWG_CLIENT_DIR", "/opt/antizapret-awg/clients")
# экспортёр ищем рядом со скриптом (репозиторий, до установки), иначе в /opt
_SIBLING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "awg-export.py")
EXPORT = os.environ.get("AWG_EXPORT_PY") or (
    _SIBLING if os.path.exists(_SIBLING) else "/opt/antizapret-awg/awg-export.py")

# поля last_config, которые читает AwgClientConfig::fromJson
REQUIRED = ("client_priv_key", "server_pub_key", "client_ip", "hostName", "port")
NICE = ("allowed_ips", "psk_key", "mtu", "config")


def decode_uri(uri: str) -> dict:
    import base64
    import zlib
    b = uri[len("vpn://"):]
    b += "=" * (-len(b) % 4)
    raw = base64.urlsafe_b64decode(b)
    return json.loads(zlib.decompress(raw[4:]))


def build_uri(conf_path: str) -> str:
    """Просим штатный экспортёр собрать ссылку — проверяем именно то, что
    получит пользователь, а не отдельную реализацию."""
    sys.path.insert(0, os.path.dirname(EXPORT))
    import importlib.util
    spec = importlib.util.spec_from_file_location("awg_export", EXPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    text = open(conf_path, encoding="utf-8").read()
    return mod.build_vpn_uri(mod.parse_conf(text), os.path.basename(conf_path))


def check(conf_path: str) -> list:
    """Возвращает список проблем; пустой список — всё хорошо."""
    problems = []
    try:
        uri = build_uri(conf_path)
    except Exception as e:  # noqa: BLE001
        return [f"экспортёр упал: {e}"]

    if not uri.startswith("vpn://"):
        return ["ссылка не начинается с vpn://"]

    try:
        js = decode_uri(uri)
    except Exception as e:  # noqa: BLE001
        return [f"ссылка не распаковывается: {e}"]

    conts = js.get("containers") or []
    if not conts:
        return ["в ссылке нет containers"]
    awg = conts[0].get("awg") or {}
    if not awg:
        return ["в контейнере нет секции awg"]

    try:
        lc = json.loads(awg.get("last_config", "{}"))
    except Exception as e:  # noqa: BLE001
        return [f"last_config не разбирается: {e}"]

    for f in REQUIRED:
        if not lc.get(f):
            problems.append(f"нет обязательного поля last_config.{f}")
    for f in NICE:
        if not lc.get(f):
            problems.append(f"нет поля last_config.{f} (не фатально, но лучше добавить)")

    # версия протокола
    pv = awg.get("protocol_version")
    if not pv:
        problems.append("нет protocol_version — приложение не покажет версию протокола")
    elif pv not in ("1.5", "2"):
        problems.append(f"protocol_version={pv!r} — приложение знает только 1.5 и 2")

    # без этого флага сервер подписывается как «AmneziaWG Legacy»
    # (serverDescription.cpp: контейнер amnezia-awg + isThirdPartyConfig == false)
    if not awg.get("isThirdPartyConfig"):
        problems.append("нет isThirdPartyConfig — приложение подпишет сервер "
                        "как «AmneziaWG Legacy»")

    # копия hasSplitTunnelingFromAllowedIps из клиента
    allowed = lc.get("allowed_ips") or []
    native = lc.get("config", "")
    split = bool(allowed) and "0.0.0.0/0" not in allowed
    if not split and native:
        split = "AllowedIPs" in native and "AllowedIPs = 0.0.0.0/0, ::/0" not in native
    full_tunnel = "0.0.0.0/0" in native
    if full_tunnel and split:
        problems.append("полный туннель, но приложение покажет раздельное "
                        "туннелирование: нужна строка «AllowedIPs = 0.0.0.0/0, ::/0» "
                        "либо поле allowed_ips")

    # параметры 3.0 должны доезжать целиком либо не быть вовсе
    v3 = [k for k in ("HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime")
          if lc.get(k)]
    if "HeaderProtectionKey" in native and "HeaderProtectionKey" not in lc:
        problems.append("в конфиге есть HeaderProtectionKey, а в ссылке его нет — "
                        "клиент не сможет подключиться к серверу с header protection")
    if v3 and len(uri) > 4000:
        problems.append(f"ссылка длиной {len(uri)} — близко к лимиту Telegram (4096)")

    return problems


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip())
        return 2
    if args == ["--all"]:
        files = sorted(glob.glob(os.path.join(CLIENT_DIR, "*", "*.conf")))
        if not files:
            print("клиентских конфигов не найдено"); return 0
    else:
        files = args

    total_bad = 0
    for f in files:
        probs = check(f)
        name = os.path.relpath(f, CLIENT_DIR) if f.startswith(CLIENT_DIR) else f
        if probs:
            total_bad += 1
            print(f"✗ {name}")
            for p in probs:
                print(f"    {p}")
        else:
            print(f"✓ {name}")
    print()
    if total_bad:
        print(f"конфигов с проблемами: {total_bad} из {len(files)}")
        return 1
    print(f"проверено {len(files)} — приложение примет все")
    return 0


if __name__ == "__main__":
    sys.exit(main())
