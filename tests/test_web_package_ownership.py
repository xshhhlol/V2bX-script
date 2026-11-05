import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
INIT=(ROOT/"initconfig.sh").read_text()
MANAGER=(ROOT/"V2bX.sh").read_text()
TRACKING=INIT[INIT.index("external_web_package_inventory() {"):INIT.index("\n# Optional dependencies")]
REMOVAL=MANAGER[MANAGER.index("external_web_package_inventory() {"):MANAGER.index("\nuninstall() {")]
STATE="/var/lib/V2bX-script/external-packages"


class WebPackageOwnershipTests(unittest.TestCase):
    def test_only_new_web_packages_are_recorded_and_python_is_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/"state"/"external-packages"
            script=TRACKING.replace(STATE,str(state))+"""
apt-get() { :; }
dpkg-query() { printf 'nginx\\tinstalled\\nnginx-common\\tinstalled\\nhaproxy\\tinstalled\\npython3\\tinstalled\\n'; }
record_external_web_packages 'haproxy'
"""
            result=subprocess.run(["bash","-c",script],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(state.read_text().splitlines(),["nginx","nginx-common"])
            self.assertEqual(state.stat().st_mode&0o777,0o600)
            self.assertEqual(state.parent.stat().st_mode&0o777,0o700)

    def run_removal(self,owned=None,answers="",plan="Remv nginx [1.18]\nRemv haproxy [2.4]\n",active_nginx=False):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);state=root/"state"/"external-packages"
            if owned is not None:
                state.parent.mkdir();state.write_text("\n".join(owned)+"\n")
            inventory=root/"inventory";inventory.write_text("nginx\tinstalled\nhaproxy\tinstalled\npython3\tinstalled\n")
            plan_path=root/"plan";plan_path.write_text(plan)
            calls=root/"calls"
            script=REMOVAL.replace(STATE,str(state))+f"""
systemctl() {{ {'if [[ "$*" == *" nginx" ]]; then return 0; fi;' if active_nginx else ''} return 1; }}
dpkg-query() {{ cat {shlex.quote(str(inventory))}; }}
apt-get() {{
 printf '%s\\n' "$*" >> {shlex.quote(str(calls))}
 if [[ "$1" == -s ]]; then cat {shlex.quote(str(plan_path))}; else
  local selected=false item
  for item in "$@"; do
   if [[ "$item" == -- ]]; then selected=true; continue; fi
   if [[ "$selected" == true ]]; then
    awk -v package="$item" '$1 != package' {shlex.quote(str(inventory))} > {shlex.quote(str(inventory)+'.tmp')}
    mv {shlex.quote(str(inventory)+'.tmp')} {shlex.quote(str(inventory))}
   fi
  done
 fi
}}
uninstall_external_web_packages
"""
            result=subprocess.run(["bash","-c",script],input=answers,text=True,capture_output=True,timeout=5)
            return result,calls.read_text().splitlines() if calls.exists() else [],state.read_text() if state.exists() else ""

    def test_default_retains_everything(self):
        result,calls,state=self.run_removal(owned=["nginx","haproxy"],answers="\n")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(calls,[])
        self.assertIn("nginx",state)

    def test_owned_packages_can_be_removed_without_python_or_autoremove(self):
        result,calls,state=self.run_removal(owned=["nginx","haproxy"],answers="y\n")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(calls),2)
        self.assertIn("-s",calls[0]);self.assertIn("-y",calls[1])
        self.assertTrue(all("python" not in c and "autoremove" not in c for c in calls))
        self.assertTrue(all("AutomaticRemove=false" in c for c in calls))
        self.assertEqual(state,"")

    def test_unknown_installation_is_explicit_and_defaults_to_keep(self):
        result,calls,_=self.run_removal()
        self.assertEqual(result.returncode,0)
        self.assertIn("没有本脚本安装记录",result.stdout)
        self.assertEqual(calls,[])

    def test_unknown_installation_can_be_explicitly_removed(self):
        result,calls,_=self.run_removal(answers="y\n")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(calls),2)

    def test_python_reverse_dependency_blocks_actual_removal(self):
        result,calls,_=self.run_removal(owned=["nginx","haproxy"],answers="y\n",plan="Remv nginx [1.18]\nRemv python3 [3.10]\n")
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(calls),1)
        self.assertIn("额外删除 python3",result.stdout)

    def test_independently_enabled_nginx_is_preserved(self):
        result,calls,state=self.run_removal(owned=["nginx","haproxy"],answers="y\n",plan="Remv haproxy [2.4]\n",active_nginx=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("保留该组件",result.stdout)
        self.assertEqual(len(calls),2)
        self.assertNotIn("nginx",calls[1])
        self.assertEqual(state,"nginx\n")
