#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify AWG2 env, disk and runtime without printing any key material."""

import ipaddress
import shlex
import subprocess
import sys
from pathlib import Path

OBF_KEYS = (
    "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
    "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5",
)


def read_env(path):
    result = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        parts = shlex.split(value, comments=True)
        if len(parts) > 1:
            raise ValueError("invalid profile value")
        result[key.strip().removeprefix("AWG_")] = parts[0] if parts else ""
    return result


def parse_conf(text):
    blocks = []
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line in ("[Interface]", "[Peer]"):
            current = {"section": line}
            blocks.append(current)
        elif current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip()
    if (not blocks or blocks[0]["section"] != "[Interface]"
            or any(b["section"] != "[Peer]" for b in blocks[1:])):
        raise ValueError("missing interface section")
    return blocks


def normalized(key, values):
    value = values.get(key, "")
    if key.startswith("I"):
        return value
    if key.startswith("H"):
        value = value or key[1:]
        parts = value.split("-", 1)
        return (int(parts[0]), int(parts[-1]))
    return int(value or "0")


def identity(blocks):
    if not blocks[0].get("PrivateKey"):
        raise ValueError("missing server key")
    peers = {}
    for block in blocks[1:]:
        pubkey = block["PublicKey"]
        if pubkey in peers:
            raise ValueError("duplicate peer")
        allowed = tuple(sorted(
            str(ipaddress.ip_network(item.strip(), strict=False))
            for item in block.get("AllowedIPs", "").split(",") if item.strip()
        ))
        peers[pubkey] = (block.get("PresharedKey", ""), allowed)
    return blocks[0].get("PrivateKey", ""), peers


def main():
    if len(sys.argv) != 4:
        print("usage: awg2-verify-profile.py ENV CONF IFACE", file=sys.stderr)
        return 2
    env_path, conf_path, iface = sys.argv[1:]
    try:
        expected = read_env(env_path)
        disk = parse_conf(Path(conf_path).read_text())
        result = subprocess.run(
            ["awg", "showconf", iface], capture_output=True, text=True,
            timeout=10, check=False,
        )
        if result.returncode:
            print(f"Cannot read AWG2 runtime: {iface}", file=sys.stderr)
            return 1
        live = parse_conf(result.stdout)
        mismatches = []
        for key in OBF_KEYS:
            for label, values in (("disk", disk[0]), ("runtime", live[0])):
                if normalized(key, values) != normalized(key, expected):
                    mismatches.append(f"{label}.{key}")
        if identity(disk) != identity(live):
            mismatches.append("keys_or_peers")
        disk_port = int(disk[0].get("ListenPort", 0))
        live_port = int(live[0].get("ListenPort", 0))
        if not 1 <= disk_port <= 65535 or disk_port != live_port:
            mismatches.append("listen_port")
        if mismatches:
            print(f"AWG2 mismatch for {iface}: " + ", ".join(mismatches), file=sys.stderr)
            return 1
    except Exception as exc:
        # Exception messages can contain parsed secrets; report only their type.
        print(f"AWG2 verification failed for {iface}: {type(exc).__name__}", file=sys.stderr)
        return 1
    print(f"Verified AWG2 profile, keys, peers and port: {iface}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
