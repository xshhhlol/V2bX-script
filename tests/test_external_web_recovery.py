"""Run failure detection and rollback against a private directory, not /etc."""
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SOURCE=(Path(__file__).resolve().parents[1]/"initconfig.sh").read_text()
FAILURE=SOURCE[SOURCE.index("external_web_failed() {"):SOURCE.index("\nexternal_web_service_running() {")]
ROLLBACK=SOURCE[SOURCE.index("rollback_external_web() {"):SOURCE.index("\n# 生成伪装网站首页")]


class ExternalWebRecoveryTests(unittest.TestCase):
    def test_recorded_error_is_reported_without_waiting_for_live_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"failure.json"
            path.write_text(json.dumps({"pid":99999999,"error":"nginx configuration rejected"}))
            source=FAILURE.replace("/run/V2bX/external-web-ready.error.json",str(path))
            result=subprocess.run(["bash","-c",source+"\nexternal_web_failed"],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0)
            self.assertIn("nginx configuration rejected",result.stdout)

    def test_systemd_restart_loop_is_detected_without_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            source=FAILURE.replace("/run/V2bX/external-web-ready.error.json",str(Path(directory)/"missing"))
            result=subprocess.run(["bash","-c","systemctl() { echo auto-restart; }\n"+source+"\nexternal_web_failed"],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0)
            self.assertIn("进程已经退出",result.stdout)

    def rollback(self,was_running):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/"etc";root.mkdir()
            backup=Path(directory)/"backup";backup.mkdir()
            (root/"config.json").write_text("new config")
            (root/"cert.key").write_text("new key")
            (backup/"config.json").write_text("old config")
            calls=Path(directory)/"calls"
            source=ROLLBACK.replace("/etc/V2bX",str(root))
            harness=f"""
v2bx() {{ printf '%s\\n' "$*" >> {shlex.quote(str(calls))}; }}
journalctl() {{ echo saved-log; }}
external_web_service_running() {{ return 0; }}
web_backup={shlex.quote(str(backup))}
web_was_running={'true' if was_running else 'false'}
web_started_at=0
web_files=(config.json cert.key)
"""
            result=subprocess.run(["bash","-c",harness+source+"\nrollback_external_web"],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/"config.json").read_text(),"old config")
            self.assertFalse((root/"cert.key").exists())
            failed=list(root.glob("failed-external.*"))
            self.assertEqual(len(failed),1)
            self.assertEqual(failed[0].stat().st_mode&0o777,0o700)
            self.assertEqual((failed[0]/"config.json").read_text(),"new config")
            self.assertEqual((failed[0]/"cert.key").read_text(),"new key")
            self.assertIn("saved-log",(failed[0]/"service.log").read_text())
            self.assertEqual(calls.read_text().splitlines(),["stop","restart"] if was_running else ["stop"])

    def test_fresh_install_stays_stopped_after_failure(self):
        self.rollback(False)

    def test_existing_service_is_restarted_after_restoration(self):
        self.rollback(True)
