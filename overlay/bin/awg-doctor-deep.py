#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Internal, local handshake probe. Never prints configuration or command stderr."""

import argparse
import base64
import fcntl
import ipaddress
import json
from pathlib import Path
import re
import secrets
import signal
import socket
import subprocess
import tempfile
import time


V3_KEYS = {
    "headerprotectionkey": "header_protection_key",
    "contentpaddingaddition": "content_padding_addition",
    "rekeyaftertime": "rekey_after_time",
    "rekeytimeout": "rekey_timeout",
    "rejectaftertime": "reject_after_time",
    "keepalivetimeout": "keepalive_timeout",
    "maxhandshakeattempts": "max_handshake_attempts",
}


class ProbeError(Exception):
    pass


def resolve_ipv4(host):
    try:
        return str(ipaddress.IPv4Address(host))
    except ValueError:
        pass
    try:
        # getaddrinfo itself has no portable timeout. Bound the host-side lookup.
        result = subprocess.run(["getent", "ahostsv4", host], capture_output=True,
                                text=True, timeout=10)
        if result.returncode:
            raise ValueError
        return str(ipaddress.IPv4Address(result.stdout.split()[0]))
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        raise ProbeError("Endpoint не разрешается в IPv4 на VPS; клиент не запущен") from None


def prepare_config(source, target, layer):
    """Resolve in the HOST namespace. Only the private temporary copy is changed."""
    lines = []
    extra = []
    address = None
    mtu = "1320" if layer == 2 else "1380"
    endpoint = None
    peers = 0
    for raw in source.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.lower() == "[peer]":
            peers += 1
        if "=" not in line:
            lines.append(line)
            continue
        key, value = [x.strip() for x in line.split("=", 1)]
        key = key.lower()
        if key == "dns":
            continue
        if key == "address":
            address = str(ipaddress.IPv4Interface(value))
            continue
        if key == "mtu":
            mtu = str(int(value))
            if not 576 <= int(mtu) <= 9000:
                raise ProbeError("неверный MTU временного клиента")
            continue
        if key in V3_KEYS:
            if layer != 3:
                raise ProbeError("в конфиге AWG2 обнаружены параметры AWG3")
            if key == "headerprotectionkey":
                decoded = base64.b64decode(value, validate=True)
                if len(decoded) != 32:
                    raise ProbeError("неверный размер ключа header protection")
                value = decoded.hex()
            else:
                # AWG3 exports both scalars and inclusive ranges (e.g. 44-127).
                # Preserve the range; the daemon validates parameter-specific limits.
                if not re.fullmatch(r"[0-9]+(?:-[0-9]+)?", value):
                    raise ProbeError("неверный формат диапазона параметра AWG3")
                bounds = [int(part) for part in value.split("-")]
                if len(bounds) == 2 and bounds[0] > bounds[1]:
                    raise ProbeError("обратный диапазон параметра AWG3")
                value = "-".join(str(part) for part in bounds)
            extra.append(f"{V3_KEYS[key]}={value}")
            continue
        if key == "endpoint":
            if endpoint is not None:
                raise ProbeError("временный конфиг содержит несколько Endpoint")
            host, port = value.rsplit(":", 1)
            if not 1 <= int(port) <= 65535:
                raise ProbeError("неверный порт Endpoint")
            # The veth underlay is IPv4. Do not pretend to test IPv6-only hosts.
            endpoint = (resolve_ipv4(host.strip("[]")), str(int(port)))
            line = f"Endpoint = {endpoint[0]}:{endpoint[1]}"
        lines.append(line)
    if peers != 1 or not address or not endpoint:
        raise ProbeError("неполный конфиг временного клиента")
    target.write_text("\n".join(lines) + "\n")
    target.chmod(0o600)
    return address, mtu, endpoint, extra


class Probe:
    def __init__(self, service, iface, gateway, awg_dir, dest, run_dir="/run"):
        self.service, self.iface = service, iface
        self.layer = 3 if service == "vpn3" else 2
        self.gateway = str(ipaddress.IPv4Address(gateway))
        self.awg_dir, self.dest, self.run_dir = map(Path, (awg_dir, dest, run_dir))
        self.name = "doc" + secrets.token_hex(4)
        self.ns = "awg" + self.name
        self.host_veth, self.peer_veth = "h" + self.name, "p" + self.name
        self.client = self.dest / "clients" / service / f"{service}-{self.name}-am.conf"
        self.namespace_owned = False
        self.veth_owned = False
        self.client_owned = False
        self.nat = None
        self.daemon = None
        self.reports = []
        self.stopping = False
        self.cleaning = False

    def command(self, stage, args, timeout=20, required=True):
        if self.stopping and not self.cleaning:
            raise ProbeError("локальный тест прерван; выполняется очистка")
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            raise ProbeError(f"{stage}: команда недоступна или истёк таймаут") from None
        if required and result.returncode:
            raise ProbeError(f"{stage}: код {result.returncode}; handshake ещё не проверен")
        return result

    def net(self, stage, args, **kwargs):
        return self.command(stage, ["ip", "netns", "exec", self.ns, *args], **kwargs)

    def report(self, status, text):
        self.reports.append({"status": status, "text": text})

    def choose_subnet(self):
        result = self.command("чтение маршрутов VPS",
                              ["ip", "-j", "-4", "route", "show", "table", "all"])
        routes = [ipaddress.ip_network(r["dst"], strict=False)
                  for r in json.loads(result.stdout)
                  if r.get("dst") not in (None, "default", "0.0.0.0/0")]
        for i in range(64):
            candidate = ipaddress.ip_network(f"10.199.0.{i * 4}/30")
            if not any(candidate.overlaps(r) for r in routes):
                return candidate
        raise ProbeError("нет свободной /30 для теста в 10.199.0.0/24; маршруты VPS не менялись")

    def wait_v3(self):
        path = self.run_dir / "amneziawg" / f"{self.name}.sock"
        deadline = time.monotonic() + 10
        while not path.exists():
            if self.daemon.poll() is not None or time.monotonic() >= deadline:
                raise ProbeError("AWG3: временный userspace-клиент не создал UAPI-сокет")
            time.sleep(0.1)
        return path

    def apply_v3(self, pairs):
        path = self.wait_v3()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(5)
            conn.connect(str(path))
            conn.sendall(("set=1\n" + "\n".join(pairs) + "\n\n").encode())
            response = b""
            while not response.endswith(b"\n\n") and len(response) < 65536:
                part = conn.recv(4096)
                if not part:
                    break
                response += part
        # An empty/truncated answer is NOT an acknowledgement.
        if not response.endswith(b"\n\n") or response.splitlines() != [b"errno=0", b""]:
            raise ProbeError("AWG3: UAPI не подтвердил параметры временного клиента")

    def execute(self, temporary):
        if not re.fullmatch(r"[a-zA-Z0-9_=+.-]{1,15}", self.iface):
            raise ProbeError("некорректное имя серверного интерфейса")
        if self.client.exists() or (self.run_dir / "amneziawg" / f"{self.name}.sock").exists():
            raise ProbeError("имя временного клиента уже занято")
        subnet = self.choose_subnet()
        # Reserve cleanup before add: the exporter may fail AFTER writing the peer.
        self.client_owned = True
        self.command("создание временного клиента",
                     [str(self.dest / "client-awg.sh"), "add", self.name, self.service], timeout=60)
        self.report("OK", f"тестовый клиент создан ({self.service})")
        conf = temporary / f"{self.name}.conf"
        address, mtu, endpoint, extra = prepare_config(self.client, conf, self.layer)
        self.report("OK", "Endpoint разрешён на VPS до запуска изолированного клиента")
        # All names are unique; an unsuccessful create never grants ownership.
        self.command("создание network namespace", ["ip", "netns", "add", self.ns])
        self.namespace_owned = True
        self.command("создание veth", ["ip", "link", "add", self.host_veth, "type", "veth",
                                      "peer", "name", self.peer_veth])
        self.veth_owned = True
        self.command("перенос veth", ["ip", "link", "set", self.peer_veth, "netns", self.ns])
        host, client = str(subnet[1]), str(subnet[2])
        self.command("адрес veth VPS", ["ip", "addr", "add", host + "/30", "dev", self.host_veth])
        self.command("подъём veth VPS", ["ip", "link", "set", self.host_veth, "up"])
        self.net("loopback теста", ["ip", "link", "set", "lo", "up"])
        self.net("адрес veth клиента", ["ip", "addr", "add", client + "/30", "dev", self.peer_veth])
        self.net("подъём veth клиента", ["ip", "link", "set", self.peer_veth, "up"])
        self.net("маршрут до Endpoint", ["ip", "route", "add", endpoint[0] + "/32", "via", host])
        # Scoped to this probe and this endpoint, never all traffic of a shared /24.
        rule = ["POSTROUTING", "-s", client + "/32", "-d", endpoint[0] + "/32",
                "-p", "udp", "--dport", endpoint[1], "-m", "comment",
                "--comment", self.ns, "-j", "MASQUERADE"]
        self.command("NAT теста", ["iptables", "-w", "5", "-t", "nat", "-A", *rule])
        self.nat = rule
        if self.layer == 2:
            self.net("запуск kernel-клиента AWG2",
                     ["ip", "link", "add", self.name, "type", "amneziawg"])
        else:
            self.daemon = subprocess.Popen(
                ["ip", "netns", "exec", self.ns, "amneziawg-go", "-f", self.name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.wait_v3()
        self.net("применение конфига тестового клиента",
                 ["awg", "setconf", self.name, str(conf)])
        if self.layer == 3:
            # Header protection needs S1..S4 padding already configured.
            self.apply_v3(extra)
        self.net("адрес VPN-клиента", ["ip", "addr", "add", address, "dev", self.name])
        self.net("MTU и запуск VPN-клиента",
                 ["ip", "link", "set", "dev", self.name, "mtu", mtu, "up"])
        # Handshake only: do not install default routes or test WARP/internet speed.
        self.net("маршрут к VPN-шлюзу",
                 ["ip", "route", "add", self.gateway + "/32", "dev", self.name])
        self.net("инициация handshake",
                 ["ping", "-n", "-c", "1", "-W", "1", self.gateway], required=False, timeout=3)
        self.report("OK", f"временный клиент AWG{self.layer} запущен")
        for _ in range(30):
            result = self.net("чтение handshake", ["awg", "show", self.name, "latest-handshakes"])
            stamps = [row.split()[-1] for row in result.stdout.splitlines() if row.split()]
            if len(stamps) != 1 or not stamps[0].isdigit():
                raise ProbeError("тестовый интерфейс не вернул состояние единственного пира")
            if int(stamps[0]) > 0:
                self.report("OK", f"локальный handshake проходит ({self.service})")
                return
            time.sleep(1)
        raise ProbeError("локальный handshake не получен за 30 с; клиент запущен, "
                         "но путь из сети пользователя этим тестом не проверяется")

    def cleanup(self):
        self.cleaning = True
        if self.daemon is not None:
            try:
                self.daemon.terminate()
                try:
                    self.daemon.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.daemon.kill()
                    self.daemon.wait(timeout=3)
            except (OSError, subprocess.SubprocessError):
                self.report("FAIL", "не удалось остановить userspace-клиент " + self.name)
        actions = []
        if self.nat:
            actions.append(["iptables", "-w", "5", "-t", "nat", "-D", *self.nat])
        if self.namespace_owned:
            actions.append(["ip", "netns", "del", self.ns])
        if self.veth_owned:
            # netns deletion may already remove the other end of the veth.
            actions.append(["ip", "link", "del", self.host_veth])
        if self.client_owned and self.client.exists():
            actions.append([str(self.dest / "client-awg.sh"), "del", self.name, self.service])
        for args in actions:
            resource = ("NAT" if args[0] == "iptables" else
                        "namespace" if args[:2] == ["ip", "netns"] else
                        "veth" if args[:2] == ["ip", "link"] else "временного пира")
            try:
                if args[:3] == ["ip", "link", "del"]:
                    exists = self.command("осмотр временного veth",
                                          ["ip", "link", "show", self.host_veth], required=False)
                    if exists.returncode == 1:
                        continue
                    if exists.returncode != 0:
                        raise ProbeError("не удалось проверить временный veth")
                self.command("очистка временных ресурсов", args, timeout=60)
            except ProbeError:
                try:
                    # netns teardown is asynchronous: veth can disappear between
                    # link show and link del. Report the postcondition, not that race.
                    if resource == "veth":
                        remaining = self.command("проверка удаления veth",
                                                 ["ip", "link", "show", self.host_veth],
                                                 required=False)
                        if remaining.returncode == 1:
                            continue
                    if resource == "NAT":
                        remaining = self.command("проверка удаления NAT",
                                                 ["iptables", "-w", "5", "-t", "nat", "-C", *self.nat],
                                                 required=False)
                        if remaining.returncode == 1:
                            continue
                except ProbeError:
                    pass
                self.report("FAIL", f"не удалось полностью очистить {resource} теста {self.name}")

    def run(self):
        # A separate lock: client-awg.sh takes the layer lock itself.
        self.run_dir.mkdir(exist_ok=True)
        with open(self.run_dir / "awg-doctor-deep.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.report("WARN", "другая глубокая проверка уже выполняется; повторная пропущена")
                return self.reports
            with tempfile.TemporaryDirectory(prefix="awgdoc-", dir=self.run_dir) as work:
                try:
                    self.execute(Path(work))
                except ProbeError as exc:
                    self.report("FAIL", str(exc))
                except (OSError, ValueError, subprocess.SubprocessError, InterruptedError):
                    # Exception text may contain keys or a complete command/config.
                    self.report("FAIL", "подготовка или выполнение локального теста прерваны")
                finally:
                    self.cleanup()
        return self.reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=("vpn", "vpn3"))
    parser.add_argument("iface")
    parser.add_argument("gateway")
    parser.add_argument("awg_dir")
    parser.add_argument("dest")
    args = parser.parse_args()

    try:
        probe = Probe(**vars(args))

        def interrupted(_signum, _frame):
            # Finish the bounded command, record ownership, then roll back.
            probe.stopping = True

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        result = probe.run()
    except (OSError, ValueError, InterruptedError, ProbeError):
        result = [{"status": "FAIL", "text": "не удалось подготовить/очистить окружение deep-теста"}]
    for row in result:
        print(row["status"] + "|" + row["text"])


if __name__ == "__main__":
    main()
