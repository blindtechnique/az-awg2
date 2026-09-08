# SPDX-License-Identifier: GPL-3.0-or-later
"""AWG2 application regressions; all network/service commands are stubbed."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "overlay/bin"
PROFILE = """AWG_Jc=4
AWG_Jmin=10
AWG_Jmax=80
AWG_S1=63
AWG_S2=27
AWG_S3=0
AWG_S4=0
AWG_H1='10-20'
AWG_H2='30-40'
AWG_H3='50-60'
AWG_H4='70-80'
AWG_I1='<b0x001122>'
AWG_I2=''
"""
CONF = """[Interface]
PrivateKey = test-server-private
Address = 10.29.9.1/24
ListenPort = 53180
Jc = 2
S1 = 59
H1 = 100-200

# Client = preserved
# PrivateKey = test-client-private
[Peer]
PublicKey = test-client-public
PresharedKey = test-preshared
AllowedIPs = 10.29.9.2/32
"""
STUB = """import os, pathlib, re, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f: f.write(name+' '+' '.join(args)+'\\n')
if name=='systemctl':
    if args[0]=='cat' and os.environ.get('MOCK_NO_UNIT'): sys.exit(1)
    if args[0] in ('start','restart') and any(os.environ.get('MOCK_FAIL_IFACE','!') in a for a in args[1:]): sys.exit(1)
    sys.exit(0)
if name=='ip': sys.exit(0 if os.environ.get('MOCK_LIVE') else 1)
if name=='awg' and args[0]=='showconf':
    if os.environ.get('MOCK_READ_FAIL'): print('test-server-private',file=sys.stderr); sys.exit(1)
    text=(pathlib.Path(os.environ['AWG_DIR'])/(args[1]+'.conf')).read_text()
    if os.environ.get('MOCK_BAD_RUNTIME'): text=text.replace('H1 = 10-20','H1 = 1-2')
    if os.environ.get('MOCK_BAD_KEY'): text=text.replace('test-server-private','wrong-private')
    if os.environ.get('MOCK_OMIT_ZERO'): text=re.sub(r'^S[34] = 0\\n','',text,flags=re.M)
    if os.environ.get('MOCK_BAD_PSK'): text=text.replace('test-preshared','wrong-secret')
    if os.environ.get('MOCK_BAD_ALLOWED'): text=text.replace('10.29.9.2/32','10.29.9.3/32')
    if os.environ.get('MOCK_BAD_PORT'): text=text.replace('53180','53181')
    if os.environ.get('MOCK_MISSING_PEER'): text=text.split('[Peer]')[0]
    if os.environ.get('MOCK_EMPTY_RUNTIME'): text=''
    print(text,end=''); sys.exit(0)
sys.exit(2)
"""


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="azawg2-repair-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.awg = self.root / "awg"
        self.awg.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        for name in ("systemctl", "ip", "awg"):
            file = self.bin / name
            file.write_text("#!" + sys.executable + "\n" + STUB)
            file.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("AWG")}
        self.env.update(AWG_DIR=str(self.awg), MOCK_LOG=str(self.log), PATH=str(self.bin) + ":" + os.environ["PATH"])
        (self.awg / "services.env").write_text("MODE=parallel\nAZ_IFACE=antizapret-awg\nVPN_IFACE=vpn-awg\n")
        (self.awg / "obfuscation.env").write_text(PROFILE)
        for name in ("antizapret-awg", "vpn-awg", "antizapret", "vpn"):
            (self.awg / (name + ".conf")).write_text(CONF)

    def run_cli(self, *args):
        return subprocess.run(["bash", str(BASE / "awg-obfuscation.sh"), *(args or ("--reapply",))], env=self.env, capture_output=True, text=True, timeout=20)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_parallel_reapply_preserves_profile_keys_and_vanilla(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.awg / "obfuscation.env").read_text(), PROFILE)
        for name in ("antizapret", "vpn"):
            self.assertEqual((self.awg / (name + ".conf")).read_text(), CONF)
        for name in ("antizapret-awg", "vpn-awg"):
            text = (self.awg / (name + ".conf")).read_text()
            self.assertIn("S1 = 63", text)
            for key in ("test-server-private", "test-client-private", "test-client-public", "test-preshared"):
                self.assertIn(key, text)
            self.assertIn("systemctl restart awg-quick@" + name, self.calls())
        self.assertNotIn("ip link del", self.calls())

    def test_parallel_defaults_without_explicit_names(self):
        (self.awg / "services.env").write_text("MODE=parallel\n")
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertIn("restart awg-quick@antizapret-awg", self.calls())

    def test_custom_quoted_names(self):
        (self.awg / "services.env").write_text("MODE=parallel\nAZ_IFACE='custom-az'\nVPN_IFACE=\"custom-vpn\"\n")
        for name in ("custom-az", "custom-vpn"):
            (self.awg / (name + ".conf")).write_text(CONF)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertIn("restart awg-quick@custom-az", self.calls())

    def test_missing_target_prevents_any_profile_or_config_change(self):
        (self.awg / "vpn-awg.conf").unlink()
        for args in (("--reapply",), ("--preset", "high", "--apply")):
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.awg / "obfuscation.env").read_text(), PROFILE)
            self.assertEqual((self.awg / "antizapret-awg.conf").read_text(), CONF)
            self.assertEqual(self.calls(), "")

    def test_refuses_vanilla_override_in_parallel_mode(self):
        self.env["AWG_AZ_CONF"] = str(self.awg / "antizapret.conf")
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vanilla", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_refuses_awg3_target(self):
        self.env["AWG_AZ_CONF"] = str(self.awg / "antizapret-awg3.conf")
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_refuses_path_outside_awg_directory(self):
        other = self.root / "elsewhere.conf"
        other.write_text(CONF)
        self.env["AWG_AZ_CONF"] = str(other)
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(other.read_text(), CONF)
        self.assertEqual(self.calls(), "")

    def test_restart_failure_is_failure_even_when_initially_down(self):
        self.env["MOCK_FAIL_IFACE"] = "vpn-awg"
        result = self.run_cli()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn("ip link del", self.calls())

    def test_runtime_profile_mismatch_is_failure(self):
        self.env["MOCK_BAD_RUNTIME"] = "1"
        result = self.run_cli()
        self.assertEqual(result.returncode, 3)
        self.assertIn("runtime.H1", result.stderr)

    def test_runtime_key_mismatch_is_failure_without_key_disclosure(self):
        self.env["MOCK_BAD_KEY"] = "1"
        result = self.run_cli()
        self.assertEqual(result.returncode, 3)
        self.assertIn("keys_or_peers", result.stderr)
        self.assertNotIn("wrong-private", result.stdout + result.stderr)
        self.assertNotIn("test-server-private", result.stdout + result.stderr)

    def test_omitted_zero_padding_is_equivalent(self):
        self.env["MOCK_OMIT_ZERO"] = "1"
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_replace_mode_remains_supported(self):
        (self.awg / "services.env").write_text("MODE=replace\n")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl restart awg-quick@antizapret\n", self.calls())

    def test_v3_path_does_not_touch_v2(self):
        (self.awg / "obfuscation3.env").write_text(PROFILE)
        for name in ("antizapret-awg3", "vpn-awg3"):
            (self.awg / (name + ".conf")).write_text(CONF)
        result = self.run_cli("--v3", "--reapply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.awg / "antizapret-awg.conf").read_text(), CONF)
        self.assertIn("systemctl start awg3@antizapret-awg3", self.calls())

    def test_missing_units_are_not_a_successful_apply_even_when_down(self):
        self.env["MOCK_NO_UNIT"] = "1"
        result = self.run_cli()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn("systemctl restart", self.calls())

    def test_missing_units_with_live_interfaces_is_failure(self):
        self.env.update(MOCK_NO_UNIT="1", MOCK_LIVE="1")
        self.assertEqual(self.run_cli().returncode, 3)

    def test_disabled_awg2_cannot_regenerate_profile(self):
        (self.awg / "services.env").write_text("MODE=parallel\nLAYER2=0\n")
        self.assertNotEqual(self.run_cli("--preset", "high", "--apply").returncode, 0)
        self.assertEqual((self.awg / "obfuscation.env").read_text(), PROFILE)
        self.assertEqual(self.calls(), "")

    def test_duplicate_targets_fail_before_writing(self):
        self.env["AWG_VPN_CONF"] = str(self.awg / "antizapret-awg.conf")
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.awg / "antizapret-awg.conf").read_text(), CONF)
        self.assertEqual(self.calls(), "")

    def test_symlink_cannot_alias_an_awg3_target(self):
        other = self.awg / "antizapret-awg3.conf"
        other.write_text(CONF)
        target = self.awg / "antizapret-awg.conf"
        target.unlink()
        target.symlink_to(other)
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(other.read_text(), CONF)
        self.assertEqual(self.calls(), "")

    def test_services_env_is_data_not_executable_shell(self):
        marker = self.root / "must-not-exist"
        with (self.awg / "services.env").open("a") as stream:
            stream.write("IGNORED=$(touch " + shlex.quote(str(marker)) + ")\n")
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertFalse(marker.exists())

    def test_services_env_path_override(self):
        other = self.root / "installed.env"
        other.write_text("MODE=parallel\nAZ_IFACE=custom-az\nVPN_IFACE=custom-vpn\n")
        for name in ("custom-az", "custom-vpn"):
            (self.awg / (name + ".conf")).write_text(CONF)
        self.env["AWG_SERVICES_ENV"] = str(other)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertIn("restart awg-quick@custom-vpn", self.calls())

    def test_custom_awg3_interface_is_protected(self):
        with (self.awg / "services.env").open("a") as stream:
            stream.write("AZ3_IFACE=custom-three\n")
        (self.awg / "custom-three.conf").write_text(CONF)
        self.env["AWG_AZ_CONF"] = str(self.awg / "custom-three.conf")
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_second_apply_cannot_turn_restart_failure_into_success(self):
        self.env["MOCK_FAIL_IFACE"] = "vpn-awg"
        for _ in range(2):
            self.assertEqual(self.run_cli().returncode, 3)

    def test_runtime_peer_psk_allowedips_and_port_are_checked(self):
        for mode in ("MOCK_BAD_PSK", "MOCK_BAD_ALLOWED", "MOCK_BAD_PORT",
                     "MOCK_MISSING_PEER", "MOCK_EMPTY_RUNTIME", "MOCK_READ_FAIL"):
            with self.subTest(mode=mode):
                self.env[mode] = "1"
                result = self.run_cli()
                del self.env[mode]
                self.assertEqual(result.returncode, 3)
                for secret in ("test-server-private", "test-preshared", "wrong-secret"):
                    self.assertNotIn(secret, result.stdout + result.stderr)

    def test_scalar_and_single_value_h_ranges_are_equivalent(self):
        (self.awg / "obfuscation.env").write_text(PROFILE.replace("10-20", "10"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        conf = self.awg / "antizapret-awg.conf"
        conf.write_text(conf.read_text().replace("H1 = 10\n", "H1 = 10-10\n"))
        checked = self.run_verifier()
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def run_verifier(self):
        return subprocess.run(
            [sys.executable, str(BASE / "awg2-verify-profile.py"),
             str(self.awg / "obfuscation.env"), str(self.awg / "antizapret-awg.conf"),
             "antizapret-awg"], env=self.env, capture_output=True, text=True, timeout=20,
        )

    def test_verifier_rejects_disk_profile_mismatch(self):
        self.assertEqual(self.run_cli().returncode, 0)
        conf = self.awg / "antizapret-awg.conf"
        conf.write_text(conf.read_text().replace("S1 = 63", "S1 = 99"))
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("disk.S1", result.stderr)

    def test_verifier_rejects_missing_identity(self):
        self.assertEqual(self.run_cli().returncode, 0)
        conf = self.awg / "antizapret-awg.conf"
        original = conf.read_text()
        for changed in (original.replace("PrivateKey = test-server-private", ""),
                        original.replace("ListenPort = 53180", ""),
                        original + "\n[Interface]\n"):
            conf.write_text(changed)
            self.assertEqual(self.run_verifier().returncode, 1)

    def test_parse_errors_do_not_echo_profile_or_key_values(self):
        self.assertEqual(self.run_cli().returncode, 0)
        (self.awg / "obfuscation.env").write_text(PROFILE.replace("10-20", "test-secret"))
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("test-secret", result.stderr)
        self.assertNotIn("test-server-private", result.stderr)

    def test_direct_panel_style_regeneration_without_target_overrides(self):
        (self.awg / "obfuscation.meta").write_text(
            "META_PRESET=low\nMETA_TEMPLATE=web\nMETA_FP=chrome\nMETA_HOST=\nMETA_MTU=1280\n")
        result = self.run_cli("--regenerate")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("antizapret", "vpn"):
            self.assertEqual((self.awg / (name + ".conf")).read_text(), CONF)
        self.assertNotIn("ip link del", self.calls())

    def deployment_copy(self, overlay, dest):
        source = (ROOT / "patches/antizapret-awg-integration.sh").read_text()
        block = re.search(r'    cp "\$OVERLAY/obfuscation/awg_obfuscate.py".*?'
                          r'(?=    chmod \+x)', source, re.S).group()
        env = dict(self.env, OVERLAY=str(overlay), DEST=str(dest))
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\nerr(){ echo \"$*\" >&2; }\n"
             "copy_overlay(){\n" + block + "\n}\ncopy_overlay"],
            env=env, capture_output=True, text=True, timeout=20,
        )

    def test_installed_layout_includes_verifier_and_can_reapply(self):
        dest = self.root / "installed"
        dest.mkdir()
        copied = self.deployment_copy(ROOT / "overlay", dest)
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.assertEqual((dest / "awg2-verify-profile.py").read_bytes(),
                         (BASE / "awg2-verify-profile.py").read_bytes())
        result = subprocess.run(
            ["bash", str(dest / "awg-obfuscation.sh"), "--reapply"],
            env=self.env, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_verifier_delivery_is_not_ignored(self):
        overlay = self.root / "overlay"
        shutil.copytree(ROOT / "overlay", overlay, ignore=shutil.ignore_patterns("__pycache__"))
        (overlay / "bin/awg2-verify-profile.py").unlink()
        dest = self.root / "installed"
        dest.mkdir()
        self.assertNotEqual(self.deployment_copy(overlay, dest).returncode, 0)

    def test_installer_rejects_failed_or_mismatched_awg2_start(self):
        self.assertEqual(self.run_cli().returncode, 0)
        source = (ROOT / "patches/antizapret-awg-integration.sh").read_text()
        block = re.search(r"^switch_services\(\).*?^\}", source, re.M | re.S).group()
        dest = self.root / "installed"
        dest.mkdir()
        self.assertEqual(self.deployment_copy(ROOT / "overlay", dest).returncode, 0)
        # The real Knot script must never run on the host in this unit test.
        (dest / "awg-knot-view.sh").write_text("#!/bin/sh\nexit 0\n")
        (dest / "awg-knot-view.sh").chmod(0o700)
        for mode in ("MOCK_FAIL_IFACE", "MOCK_BAD_RUNTIME", ""):
            env = dict(self.env, DEST=str(dest),
                       AZ_IFACE="antizapret-awg", VPN_IFACE="vpn-awg")
            if mode:
                env[mode] = "vpn-awg" if mode == "MOCK_FAIL_IFACE" else "1"
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\nlog(){ :; }\nerr(){ echo \"$*\" >&2; }\n"
                 + block + "\nswitch_services"],
                env=env, capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode == 0, not mode, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
