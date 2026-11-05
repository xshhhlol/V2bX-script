"""Check external-mode preflight without changing packages or host services."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "initconfig.sh").read_text()
PREPARE = SOURCE[SOURCE.index("prepare_external_web() ("):SOURCE.index("\n# A root-owned readiness marker")]


class ExternalWebPreflightTests(unittest.TestCase):
    def run_preflight(self, capability=True, service_enabled=False, required="external-web-v1", lts_compatible=True):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "V2bX"
            binary.write_text("#!/bin/sh\n" + ("echo external-web-v1\n" + ("echo external-web-ubuntu-lts-v1\n" if lts_compatible else "") if capability else "exit 1\n"))
            binary.chmod(0o755)
            source = PREPARE.replace("local binary=/usr/local/V2bX/V2bX", "local binary=" + shlex.quote(str(binary)))
            # All dependencies are represented by functions, so apt/service
            # mutations must never be reached in this test harness.
            harness = """
nginx() { :; }
haproxy() { :; }
python3() { :; }
systemctl() { return %d; }
apt-get() { echo unexpected-package-install >&2; return 99; }
""" % (0 if service_enabled else 1)
            return subprocess.run(["bash", "-c", harness + source + "\nexternal_web_capability=" + shlex.quote(required) + "\nprepare_external_web\n"],
                                  capture_output=True, text=True, timeout=5, env=os.environ.copy())

    def test_old_binary_is_rejected_before_installing(self):
        result = self.run_preflight(capability=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected-package-install", result.stderr)

    def test_old_external_binary_is_rejected_before_changing_config(self):
        result=self.run_preflight(lts_compatible=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn("v1.4.5",result.stdout)

    def test_existing_system_service_is_preserved(self):
        result = self.run_preflight(service_enabled=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("保留现有服务", result.stdout)

    def test_installed_dependencies_need_no_package_or_service_changes(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("unexpected-package-install", result.stderr)

    def test_trojan_only_binary_cannot_enable_vmess_or_anytls_external_mode(self):
        result=self.run_preflight(required="external-web-v2")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("external-web-v2",result.stdout)
        self.assertNotIn("unexpected-package-install",result.stderr)
