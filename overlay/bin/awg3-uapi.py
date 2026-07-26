#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-or-later
"""
awg3-uapi.py — тонкий клиент UAPI-сокета amneziawg-go.

Зачем нужен: параметры, появившиеся в AmneziaWG 3.0 (header_protection_key,
content_padding_addition, rekey_after_time, rekey_timeout, reject_after_time,
keepalive_timeout, max_handshake_attempts), НЕ поддерживаются утилитами
amneziawg-tools — `awg setconf` на них падает с «Line unrecognized». Поэтому на
сервере они применяются напрямую в UAPI-сокет демона:
    /var/run/amneziawg/<iface>.sock

Протокол UAPI (см. amneziawg-go/ipc): текстовый, запрос вида

    set=1\n
    key=value\n
    ...
    \n

ответ — `errno=0\n\n` при успехе, иначе errno != 0. Для чтения: `get=1\n\n`.

Использование:
    awg3-uapi.py set  <iface> key=value [key=value ...]
    awg3-uapi.py set  <iface> --from-file /path/params.uapi
    awg3-uapi.py get  <iface>
    awg3-uapi.py show <iface>            # только v3-параметры, человекочитаемо
    awg3-uapi.py wait <iface> [timeout]  # дождаться появления сокета

Ключи, задающие v3-параметры, при `get=1` возвращаются демоном — это
единственный способ проверить, что header protection реально включена
(`awg show` о них не знает).
"""

import os
import socket
import sys
import time

RUN_DIRS = ("/var/run/amneziawg", "/run/amneziawg")

V3_KEYS = (
    "header_protection_key",
    "content_padding_addition",
    "rekey_after_time",
    "rekey_timeout",
    "reject_after_time",
    "keepalive_timeout",
    "max_handshake_attempts",
)


def sock_path(iface: str) -> str:
    for d in RUN_DIRS:
        p = os.path.join(d, iface + ".sock")
        if os.path.exists(p):
            return p
    # вернём канонический путь — вызывающий получит понятную ошибку
    return os.path.join(RUN_DIRS[0], iface + ".sock")


def talk(iface: str, payload: str) -> str:
    path = sock_path(iface)
    if not os.path.exists(path):
        raise SystemExit(f"[awg3-uapi] нет UAPI-сокета {path} — интерфейс {iface} не поднят?")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(path)
        s.sendall(payload.encode())
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
            if b.endswith(b"\n\n"):
                break
        return b"".join(chunks).decode(errors="replace")
    finally:
        s.close()


def cmd_set(iface: str, pairs) -> int:
    pairs = [p.strip() for p in pairs if p.strip() and not p.strip().startswith("#")]
    if not pairs:
        print("[awg3-uapi] нечего применять")
        return 0
    bad = [p for p in pairs if "=" not in p]
    if bad:
        raise SystemExit(f"[awg3-uapi] некорректные пары: {bad}")
    resp = talk(iface, "set=1\n" + "".join(p + "\n" for p in pairs) + "\n")
    errno = None
    for line in resp.splitlines():
        if line.startswith("errno="):
            errno = line.split("=", 1)[1].strip()
    if errno not in ("0", None):
        # покажем, что именно не понравилось — без значения ключа (там секреты)
        keys = ", ".join(p.split("=", 1)[0] for p in pairs)
        raise SystemExit(f"[awg3-uapi] демон отверг параметры ({keys}): errno={errno}\n{resp.strip()}")
    print(f"[awg3-uapi] применено {len(pairs)} параметров к {iface}")
    return 0


def cmd_get(iface: str) -> int:
    sys.stdout.write(talk(iface, "get=1\n\n"))
    return 0


def cmd_show(iface: str) -> int:
    resp = talk(iface, "get=1\n\n")
    found = {}
    for line in resp.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k in V3_KEYS:
            if k == "header_protection_key":
                v = v[:8] + "…(скрыт)" if v else v
            found[k] = v
    if not found:
        print(f"{iface}: параметры AmneziaWG 3.0 не заданы (работает как 2.0)")
        return 0
    print(f"{iface}: активные параметры AmneziaWG 3.0")
    for k in V3_KEYS:
        if k in found:
            print(f"  {k} = {found[k]}")
    return 0


def cmd_wait(iface: str, timeout: float = 15.0) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        p = sock_path(iface)
        if os.path.exists(p):
            # сокет есть — убедимся, что демон уже отвечает
            try:
                talk(iface, "get=1\n\n")
                return 0
            except Exception:
                pass
        time.sleep(0.25)
    raise SystemExit(f"[awg3-uapi] {iface}: UAPI-сокет не появился за {timeout}s")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    action, iface = sys.argv[1], sys.argv[2]
    rest = sys.argv[3:]

    if action == "set":
        if rest and rest[0] == "--from-file":
            if len(rest) < 2:
                raise SystemExit("[awg3-uapi] --from-file без пути")
            with open(rest[1], encoding="utf-8") as fh:
                return cmd_set(iface, fh.read().splitlines())
        return cmd_set(iface, rest)
    if action == "get":
        return cmd_get(iface)
    if action == "show":
        return cmd_show(iface)
    if action == "wait":
        return cmd_wait(iface, float(rest[0]) if rest else 15.0)

    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main())
