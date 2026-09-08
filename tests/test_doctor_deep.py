# SPDX-License-Identifier: GPL-3.0-or-later
"""No root/network needed: execute the actual probe with an isolated fake OS."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("deep", ROOT / "overlay/bin/awg-doctor-deep.py")
deep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deep)

CONF = """[Interface]
PrivateKey = secret-do-not-print
Address = 10.28.9.2/32
DNS = 10.29.8.1
MTU = 1320
Jc = 5
H1 = 10-20
I1 = <b0x001122>
[Peer]
PublicKey = peer-public
PresharedKey = preshared-do-not-print
Endpoint = vpn.example.test:36196
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
"""


class FakeOS:
    def __init__(self, probe, conf=CONF):
        self.probe = probe
        self.conf = conf
        self.calls = []
        self.routes = []
        self.fail = None
        self.stop_after = None
        self.handshake = "peer-public\t1234\n"
        self.configured = None

    def run(self, args, **_kwargs):
        a = list(args)
        self.calls.append(a)
        if len(a) > 3 and a[:3] == ["ip", "netns", "exec"]:
            a = a[4:]
        out, rc = "", 0
        if a[:2] == [str(self.probe.dest / "client-awg.sh"), "add"]:
            self.probe.client.parent.mkdir(parents=True, exist_ok=True)
            self.probe.client.write_text(self.conf)
        elif a[:2] == [str(self.probe.dest / "client-awg.sh"), "del"]:
            self.probe.client.unlink(missing_ok=True)
        elif a[:5] == ["ip", "-j", "-4", "route", "show"]:
            out = json.dumps(self.routes)
        elif a[:2] == ["awg", "setconf"]:
            self.configured = Path(a[3]).read_text()
        elif a[:2] == ["awg", "show"]:
            out = self.handshake
        if self.fail and self.fail(a):
            rc = 2
        if self.stop_after and self.stop_after(a):
            self.probe.stopping = True
        return subprocess.CompletedProcess(args, rc, out, "secret-do-not-print")


class DeepTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.p = deep.Probe("vpn", "vpn-awg", "10.28.9.1",
                            self.root / "awg", self.root / "dest", self.root / "run")
        self.os = FakeOS(self.p)

    def run_probe(self, resolve_error=None):
        with patch.object(deep.subprocess, "run", side_effect=self.os.run), \
             patch.object(deep, "resolve_ipv4", return_value="198.51.100.8",
                          side_effect=resolve_error), \
             patch.object(deep.time, "sleep"):
            return self.p.run()

    def test_domain_resolved_before_namespace_and_only_temp_copy_changed(self):
        report = self.run_probe()
        self.assertTrue(any("handshake проходит" in r["text"] for r in report))
        self.assertFalse(any(r["status"] == "FAIL" for r in report), report)
        self.assertIn("Endpoint = 198.51.100.8:36196", self.os.configured)
        self.assertNotIn("DNS =", self.os.configured)
        self.assertNotIn("Address =", self.os.configured)
        self.assertNotIn("MTU =", self.os.configured)
        self.assertIn("PrivateKey = secret-do-not-print", self.os.configured)
        self.assertIn("H1 = 10-20", self.os.configured)
        self.assertIn("vpn.example.test", self.os.conf)
        self.assertNotIn("secret-do-not-print", str(report))
        self.assertFalse(self.p.client.exists())
        self.assertEqual(list(self.p.run_dir.glob("awgdoc-*")), [])
        self.assertTrue(any(c[:3] == ["ip", "netns", "del"] for c in self.os.calls))
        nat = [c for c in self.os.calls if c[0] == "iptables"]
        self.assertEqual(len(nat), 2)
        self.assertEqual(nat[0][6:], nat[1][6:])
        self.assertIn("198.51.100.8/32", nat[0])
        self.assertIn(self.p.ns, nat[0])
        self.assertNotIn("10.199.0.0/24", nat[0])
        self.assertFalse(any("default" in c for c in self.os.calls))

    def test_dns_error_not_reported_as_handshake_failure_and_peer_cleaned(self):
        report = self.run_probe(deep.ProbeError("Endpoint не разрешается в IPv4 на VPS; клиент не запущен"))
        failures = [r["text"] for r in report if r["status"] == "FAIL"]
        self.assertTrue(any("Endpoint не разрешается" in r for r in failures))
        self.assertFalse(any(c[:3] == ["ip", "netns", "add"] for c in self.os.calls))
        self.assertFalse(self.p.client.exists())
        self.assertNotIn("secret-do-not-print", str(report))

    def test_each_setup_failure_is_distinct_and_owned_peer_is_removed(self):
        cases = [
            lambda a: a[:2] == [str(self.p.dest / "client-awg.sh"), "add"],
            lambda a: a[:3] == ["ip", "netns", "add"],
            lambda a: a[:3] == ["ip", "link", "add"],
            lambda a: a[:3] == ["ip", "addr", "add"],
            lambda a: a[:3] == ["ip", "route", "add"],
            lambda a: a[0] == "iptables" and "-A" in a,
            lambda a: a[:2] == ["awg", "setconf"],
        ]
        for fail in cases:
            with self.subTest(case=cases.index(fail)):
                self.os.calls.clear()
                self.p.reports.clear()
                self.p.namespace_owned = self.p.veth_owned = self.p.client_owned = False
                self.p.nat = None
                self.p.cleaning = False
                self.os.fail = fail
                report = self.run_probe()
                self.assertTrue(any(r["status"] == "FAIL" for r in report), report)
                self.assertFalse(any("handshake проходит" in r["text"] for r in report))
                self.assertNotIn("secret-do-not-print", str(report))
                self.assertFalse(self.p.client.exists())
                if any(c[0] == "iptables" and "-A" in c and not fail(c) for c in self.os.calls):
                    self.assertTrue(any(c[0] == "iptables" and "-D" in c for c in self.os.calls))

    def test_timeout_after_successful_start_is_not_a_setup_error(self):
        self.os.handshake = "peer-public\t0\n"
        report = self.run_probe()
        self.assertTrue(any("временный клиент AWG2 запущен" in r["text"] for r in report))
        self.assertTrue(any("не получен за 30 с" in r["text"] for r in report))
        self.assertFalse(self.p.client.exists())

    def test_empty_or_invalid_handshake_response_never_means_success(self):
        for value in ["", "peer-public\tnan\n", "peer1\t1\npeer2\t2\n"]:
            self.os.handshake = value
            self.p.reports.clear()
            report = self.run_probe()
            self.assertTrue(any("не вернул состояние" in r["text"] for r in report))
            self.assertFalse(any("handshake проходит" in r["text"] for r in report))

    def test_no_subnet_overlap(self):
        self.os.routes = [{"dst": "10.199.0.0/30"}, {"dst": "default"}]
        self.run_probe()
        self.assertTrue(any("10.199.0.5/30" in c for c in self.os.calls))

    def test_exhausted_subnet_does_not_create_a_client(self):
        self.os.routes = [{"dst": "10.199.0.0/24"}]
        report = self.run_probe()
        self.assertTrue(any("нет свободной /30" in r["text"] for r in report))
        self.assertFalse(self.p.client.exists())
        self.assertFalse(any("add" in c for c in self.os.calls))

    def test_stop_after_nat_add_still_removes_nat_and_peer(self):
        self.os.stop_after = lambda a: a[0] == "iptables" and "-A" in a
        report = self.run_probe()
        self.assertTrue(any("прерван" in r["text"] for r in report))
        self.assertTrue(any(c[0] == "iptables" and "-D" in c for c in self.os.calls))
        self.assertFalse(self.p.client.exists())

    def test_cleanup_failure_does_not_skip_remaining_cleanup(self):
        self.os.fail = lambda a: a[0] == "iptables" and "-D" in a
        report = self.run_probe()
        self.assertTrue(any("очистить" in r["text"] for r in report))
        self.assertTrue(any(c[:3] == ["ip", "netns", "del"] for c in self.os.calls))
        self.assertFalse(self.p.client.exists())

    def test_veth_disappearing_during_namespace_teardown_is_not_failure(self):
        real_run = self.os.run
        gone = False

        def racing_run(args, **kwargs):
            nonlocal gone
            result = real_run(args, **kwargs)
            if args[:3] == ["ip", "link", "del"]:
                gone = True
                result.returncode = 1
            if args[:3] == ["ip", "link", "show"] and gone:
                result.returncode = 1
            return result

        self.os.run = racing_run
        report = self.run_probe()
        self.assertFalse(any(r["status"] == "FAIL" for r in report), report)
        self.assertFalse(self.p.client.exists())

    def test_busy_lock_does_not_touch_network(self):
        with patch.object(deep.fcntl, "flock", side_effect=BlockingIOError):
            report = self.run_probe()
        self.assertEqual(report[0]["status"], "WARN")
        self.assertEqual(self.os.calls, [])

    def test_v3_forces_userspace_and_sends_header_protection_via_uapi(self):
        self.p.service, self.p.layer = "vpn3", 3
        self.os.conf = CONF.replace("Jc = 5", "HeaderProtectionKey = "
                                    + base64.b64encode(bytes(32)).decode()
                                    + "\nContentPaddingAddition = 44-127"
                                    + "\nRekeyAfterTime = 117-140"
                                    + "\nRekeyTimeout = 5-8"
                                    + "\nRejectAfterTime = 167-206"
                                    + "\nKeepaliveTimeout = 9-16"
                                    + "\nMaxHandshakeAttempts = 17-19\nJc = 5")
        daemon = MagicMock()
        def after_base(_pairs):
            self.assertIsNotNone(self.os.configured,
                                 "header protection must follow the base config")

        with patch.object(deep.subprocess, "Popen", return_value=daemon) as popen, \
             patch.object(self.p, "wait_v3"), \
             patch.object(self.p, "apply_v3", side_effect=after_base) as uapi:
            report = self.run_probe()
        self.assertTrue(any("handshake проходит" in r["text"] for r in report), report)
        self.assertEqual(popen.call_args.args[0][-3:], ["amneziawg-go", "-f", self.p.name])
        self.assertIn("header_protection_key=" + "00" * 32, uapi.call_args.args[0])
        for pair in ["content_padding_addition=44-127", "rekey_after_time=117-140",
                     "rekey_timeout=5-8", "reject_after_time=167-206",
                     "keepalive_timeout=9-16", "max_handshake_attempts=17-19"]:
            self.assertIn(pair, uapi.call_args.args[0])
        self.assertNotIn("HeaderProtectionKey", self.os.configured)
        self.assertNotIn("ContentPaddingAddition", self.os.configured)
        self.assertFalse(any("amneziawg" in c for c in self.os.calls))
        daemon.terminate.assert_called_once()

    def test_v3_scalar_supported_and_malformed_ranges_rejected(self):
        source, target = self.root / "source.conf", self.root / "probe.conf"
        source.write_text(CONF.replace("Jc = 5", "ContentPaddingAddition = 17"))
        with patch.object(deep, "resolve_ipv4", return_value="198.51.100.8"):
            self.assertEqual(deep.prepare_config(source, target, 3)[3],
                             ["content_padding_addition=17"])
            for value in ["127-44", "-1", "1-2-3", "1.2", "1 - 2", "secret"]:
                source.write_text(CONF.replace("Jc = 5", "RekeyTimeout = " + value))
                with self.subTest(value=value), self.assertRaises(deep.ProbeError) as error:
                    deep.prepare_config(source, target, 3)
                self.assertNotIn("secret", str(error.exception))

    def test_uapi_requires_complete_positive_ack(self):
        path = self.p.run_dir / "amneziawg" / f"{self.p.name}.sock"
        path.parent.mkdir(parents=True)
        path.touch()
        for response in [b"", b"errno=0\n", b"errno=22\n\n", b"junk\n\n"]:
            fake = MagicMock()
            fake.__enter__.return_value = fake
            fake.recv.side_effect = [response, b""]
            with patch.object(deep.socket, "socket", return_value=fake):
                with self.assertRaises(deep.ProbeError):
                    self.p.apply_v3(["header_protection_key=" + "00" * 32])
        fake = MagicMock()
        fake.__enter__.return_value = fake
        fake.recv.return_value = b"errno=0\n\n"
        with patch.object(deep.socket, "socket", return_value=fake):
            self.p.apply_v3(["content_padding_addition=17"])

    def test_installer_ships_helper_and_doctor_calls_it(self):
        install = (ROOT / "patches/antizapret-awg-integration.sh").read_text()
        doctor = (ROOT / "overlay/bin/awg-doctor.sh").read_text()
        self.assertIn('"$OVERLAY/bin/awg-doctor-deep.py"', install)
        self.assertIn('python3 "$deep_impl" "$DOC_SVC"', doctor)
        self.assertIn('DOC_SVC=vpn3;', doctor)

    def test_dns_lookup_is_bounded_and_numeric_address_needs_no_dns(self):
        with patch.object(deep.subprocess, "run") as run:
            self.assertEqual(deep.resolve_ipv4("198.51.100.8"), "198.51.100.8")
            run.assert_not_called()
        for result in [subprocess.CompletedProcess([], 2, "", "secret"),
                       subprocess.CompletedProcess([], 0, "", ""),
                       subprocess.TimeoutExpired([], 10)]:
            with patch.object(deep.subprocess, "run", return_value=result,
                              side_effect=result if isinstance(result, Exception) else None) as run:
                with self.assertRaises(deep.ProbeError) as error:
                    deep.resolve_ipv4("vpn.example.test")
                self.assertNotIn("secret", str(error.exception))
                self.assertEqual(run.call_args.kwargs["timeout"], 10)


if __name__ == "__main__":
    unittest.main()
