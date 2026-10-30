"""Exercise configuration prompts without running the installer or writing /etc."""

import json
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "initconfig.sh"


def generate(*answers):
    source = SCRIPT.read_text()
    start = source.index("add_node_config() {")
    end = source.index("\n# 生成伪装网站首页", start)
    harness = """core_sing=false
core_hysteria2=false
core_xray=false
ApiHost=https://panel.example
ApiKey=test-key
nodes_config=()
check_ipv6_support() { echo 0; }
""" + source[start:end] + """
add_node_config >/dev/null
printf '%s\\n' "${nodes_config[0]}"
"""
    result = subprocess.run(
        ["bash", "-c", harness],
        input="\n".join(answers) + "\n",
        text=True,
        capture_output=True,
        timeout=5,
    )
    if result.returncode:
        raise AssertionError(result.stderr)
    return json.loads(result.stdout.strip().removesuffix(","))


class VMessConfigTests(unittest.TestCase):
    def test_plain_defaults_preserve_old_encryption_clients(self):
        node = generate("1", "7", "3", "n", "", "")
        self.assertTrue(node["FallBackSite"]["Enable"])
        self.assertFalse(node["FallBackSite"]["RedirectHTTP"])
        self.assertFalse(node["VMessConfig"]["RequireEncryption"])
        self.assertTrue(node["VMessConfig"]["TrafficShaping"]["Enable"])
        self.assertEqual(node["VMessConfig"]["HandshakeTimeout"], 30)
        self.assertTrue(node["EnableTFO"])
        self.assertTrue(node["EnableSniff"])
        self.assertNotIn("TCPFastOpen", node)
        self.assertNotIn("SniffEnabled", node)

    def test_plain_encryption_restriction_is_explicit(self):
        node = generate("1", "7", "3", "n", "y", "y")
        self.assertTrue(node["VMessConfig"]["RequireEncryption"])

    def test_tls_preserves_none_clients(self):
        node = generate("1", "7", "3", "y", "1", "node.example", "")
        self.assertFalse(node["VMessConfig"]["RequireEncryption"])
        self.assertTrue(node["FallBackSite"]["RedirectHTTP"])
        self.assertTrue(node["CertConfig"]["RejectUnknownSni"])
        self.assertEqual(node["CertConfig"]["CertDomain"], "node.example")

    def test_hardening_can_be_disabled(self):
        node = generate("1", "7", "3", "n", "n")
        self.assertNotIn("VMessConfig", node)
        self.assertNotIn("FallBackSite", node)


if __name__ == "__main__":
    unittest.main()
