"""Run the real installer function against local release fixtures and fake services."""
import hashlib
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text()
FUNCTION = SOURCE[SOURCE.index("install_V2bX() {"):SOURCE.index('\necho -e "${green}开始安装')]


class InstallUpdateTests(unittest.TestCase):
    def install(self, failure=None, requested="1.4.8", installed_version=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            program, config, units, commands = [root / name for name in ("program", "config", "units", "bin")]
            for path in (program, config, units, commands): path.mkdir()
            old = program / "V2bX"
            old.write_text("old-program\n")
            if installed_version:
                old.write_text(f"#!/bin/sh\necho 'V2bX {installed_version} (installed)'\n")
            old.chmod(0o755)
            (config / "config.json").write_text('{"existing":"configuration"}')
            (units / "V2bX.service").write_text("existing-custom-unit")
            manager = root / "manager"
            manager.write_text("#!/bin/sh\nexit 0\n")
            candidate_version = "v1.4.6" if failure == "wrong-version" else "v1.4.8"
            package = root / "release.zip"
            with zipfile.ZipFile(package, "w") as archive:
                archive.writestr("V2bX", f"#!/bin/sh\necho 'V2bX {candidate_version} (test binary)'\n")
                for name in ["geoip.dat", "geosite.dat", "dns.json", "route.json", "custom_outbound.json", "custom_inbound.json"]:
                    archive.writestr(name, "fixture")
            checksum = hashlib.sha256(package.read_bytes()).hexdigest()
            if failure == "bad-digest": checksum = "0" * 64
            digest = root / "release.dgst"
            digest.write_text(f"MD5= unused\nSHA2-256= {checksum}\nSHA2-512= unused\n")
            function = FUNCTION.replace("/usr/local/V2bX", str(program)).replace("/etc/V2bX", str(config))
            function = function.replace("/etc/systemd/system", str(units)).replace("/usr/bin/V2bX", str(commands / "V2bX")).replace("/usr/bin/v2bx", str(commands / "v2bx"))
            function = function.replace("/usr/bin/.v2bx-manager", str(commands / ".v2bx-manager"))
            harness = f"""
release=ubuntu
arch=64
cur_dir={shlex.quote(str(root))}
failure={shlex.quote(failure or '')}
curl() {{
    local url='' out=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) out=$2; shift 2 ;;
            --connect-timeout|--max-time|--retry) shift 2 ;;
            http*) url=$1; shift ;;
            *) shift ;;
        esac
    done
    case "$url" in
        */releases/latest) echo '{{"tag_name":"v1.4.8"}}' ;;
        *.zip) [[ "$failure" == download ]] && return 22; cp {shlex.quote(str(package))} "$out" ;;
        *.dgst) cp {shlex.quote(str(digest))} "$out" ;;
        */V2bX.sh) cp {shlex.quote(str(manager))} "$out" ;;
        *counter_v2bx) : ;;
        *) echo "unexpected-download:$url" >&2; return 99 ;;
    esac
}}
systemctl() {{ :; }}
sleep() {{ :; }}
check_status() {{ [[ "$failure" != startup ]]; }}
{function}
install_V2bX {shlex.quote(requested)}
"""
            result = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=5)
            state = {"program": old.read_text(), "config": (config / "config.json").read_text(),
                     "unit": (units / "V2bX.service").read_text(),
                     "previous": (program / "V2bX.previous").read_text() if (program / "V2bX.previous").exists() else None}
        self.assertEqual(state["config"], '{"existing":"configuration"}')
        self.assertEqual(state["unit"], "existing-custom-unit")
        return result, state

    def test_verified_update_preserves_configuration_and_service(self):
        result, state = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("V2bX v1.4.8", state["program"])
        self.assertEqual(state["previous"], "old-program\n")

    def test_missing_release_asset_keeps_old_program(self):
        result, state = self.install(failure="download")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["program"], "old-program\n")
        self.assertIsNone(state["previous"])

    def test_digest_mismatch_keeps_old_program(self):
        result, state = self.install(failure="bad-digest")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["program"], "old-program\n")

    def test_wrong_version_is_rejected_before_replacement(self):
        result, state = self.install(failure="wrong-version")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["program"], "old-program\n")

    def test_failed_start_rolls_back_binary(self):
        result, state = self.install(failure="startup")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["program"], "old-program\n")
        self.assertIn("已恢复", result.stdout)

    def test_latest_release_uses_same_verified_install_path(self):
        result, state = self.install(requested="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("V2bX v1.4.8", state["program"])

    def test_latest_never_automatically_downgrades_a_newer_install(self):
        result, state = self.install(requested="", installed_version="v1.4.9")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("v1.4.9", state["program"])
        self.assertIsNone(state["previous"])
        self.assertIn("不自动降级", result.stdout)

    def test_manager_download_failure_is_not_reported_as_success(self):
        source = (ROOT / "V2bX.sh").read_text()
        update = source[source.index("update() {"):source.index("\nconfig() {", source.index("update() {"))]
        result = subprocess.run(["bash", "-c", 'curl() { return 22; }\n' + update + '\nupdate 0 v1.4.8'],
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("更新完成", result.stdout)
