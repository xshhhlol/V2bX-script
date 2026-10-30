"""Exercise configuration prompts without running the installer or writing /etc."""

import json
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "initconfig.sh"


def generate(*answers, with_messages=False):
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
add_node_config >&2
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
    node = json.loads(result.stdout.strip().removesuffix(","))
    if with_messages:
        return node, result.stderr
    return node


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


class ShadowsocksConfigTests(unittest.TestCase):
    def test_tcp_defaults_preserve_ordinary_clients(self):
        node = generate("1", "7", "1", "", "")
        self.assertTrue(node["ShadowsocksConfig"]["TrafficShaping"]["Enable"])
        self.assertEqual(node["ShadowsocksConfig"]["HandshakeTimeout"], 30)
        self.assertTrue(node["MultiplexConfig"]["Enable"])
        self.assertFalse(node["MultiplexConfig"]["Padding"])
        self.assertNotIn("FallBackSite", node)
        self.assertTrue(node["ShadowsocksConfig"]["UDPPadding"]["Enable"])
        self.assertEqual(node["ShadowsocksConfig"]["UDPPadding"]["MaxPacketSize"], 1280)

    def test_tcp_shaping_can_be_disabled(self):
        node = generate("1", "7", "1", "n", "n")
        self.assertNotIn("ShadowsocksConfig", node)
        self.assertNotIn("MultiplexConfig", node)

    def test_udp_can_be_enabled_without_tcp_shaping(self):
        node = generate("1", "7", "1", "n", "")
        self.assertTrue(node["ShadowsocksConfig"]["UDPPadding"]["Enable"])
        self.assertNotIn("TrafficShaping", node["ShadowsocksConfig"])
        self.assertNotIn("MultiplexConfig", node)

    def test_tcp_can_be_enabled_without_udp_padding(self):
        node = generate("1", "7", "1", "", "n")
        self.assertTrue(node["ShadowsocksConfig"]["TrafficShaping"]["Enable"])
        self.assertNotIn("UDPPadding", node["ShadowsocksConfig"])

    def test_guide_explains_panel_settings_and_conditional_udp_support(self):
        node, messages = generate("1", "7", "1", "", "", with_messages=True)
        self.assertIn("已有 aes-128-gcm", messages)
        self.assertIn("普通 SS 会自动跳过", messages)
        self.assertIn("不需要申请 TLS 证书", messages)
        self.assertIn("连接端口与服务端口保持一致", messages)
        self.assertIn("仅更新安装脚本不会生效", messages)
        self.assertIn("V2bX v1.4.2", messages)
        self.assertIn("不强制客户端开启复用", messages)
        self.assertEqual(node["CertConfig"]["CertMode"], "none")
        self.assertNotIn("Cipher", node)
        self.assertNotIn("Method", node)


if __name__ == "__main__":
    unittest.main()
