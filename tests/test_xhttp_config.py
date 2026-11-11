"""Exercise panel-driven XHTTP setup without changing host configuration."""
import copy
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

SOURCE = (Path(__file__).resolve().parents[1] / "initconfig.sh").read_text()
TOKEN = 'test-key"with\\characters'
NODE = {
    "network": "xhttp", "tls": 1, "flow": "", "server_port": 443,
    "tls_settings": {"server_name": "node.example.com"},
    "network_settings": {"path": "/xhttp", "mode": "packet-up", "alpn": ["h3"],
                         "extra": {"downloadSettings": {"address": "download.example.com"}}},
}


class XHTTPConfigTests(unittest.TestCase):
    def generate(self, node=None, answers=None, version="v1.4.8", previous_cores=False, full=False, listener=True):
        requests = []
        body = json.dumps(NODE if node is None else node).encode()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(urlsplit(self.path))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "V2bX"
            binary.write_text(f"#!/bin/sh\necho 'V2bX {version} (test binary)'\n")
            binary.chmod(0o755)
            cert, key = Path(directory) / "chain file.pem", Path(directory) / "key file.pem"
            cert.write_text("certificate fixture")
            key.write_text("private key fixture")
            source = SOURCE.replace("local binary=/usr/local/V2bX/V2bX", "local binary=" + shlex.quote(str(binary)))
            config_dir = Path(directory) / "config"
            if full:
                config_dir.mkdir()
                (config_dir / "config.json").write_text('{"old":true}')
                (config_dir / "route.json").write_text('{"old_route":true}')
                source = source.replace("/etc/V2bX", str(config_dir))
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
            worker.start()
            try:
                harness = source + f"""
core_sing={'true' if previous_cores else 'false'}
core_hysteria2={'true' if previous_cores else 'false'}
core_xray=false
ApiHost=http://127.0.0.1:{server.server_port}
ApiKey={shlex.quote(TOKEN)}
nodes_config=()
xhttp_checks=()
check_ipv6_support() {{ echo 0; }}
add_node_config >&2 || exit $?
printf '%s\\n' "${{nodes_config[0]}}"
"""
                if answers == "file":
                    answers = ["3", "74", "2", "", str(cert), str(key)]
                if full:
                    harness = harness[:harness.index('add_node_config >&2')] + f"""
running=true
v2bx() {{ if [[ "$1" == stop ]]; then running=false; else running=true; fi; }}
systemctl() {{ running=true; }}
external_web_service_running() {{ [[ "$running" == true ]]; }}
ss() {{ {'true' if listener else 'false'} && echo 'UNCONN 0 0 *:443 *:* users:(("V2bX",pid=12,fd=4))'; }}
sleep() {{ :; }}
journalctl() {{ :; }}
generate_config_file >&2
status=$?
cat {shlex.quote(str(config_dir / 'config.json'))}
exit "$status"
"""
                    answers = ["", f"http://127.0.0.1:{server.server_port}", TOKEN, "y", "3", "74", "", "", "n"]
                result = subprocess.run(["bash", "-c", harness], input="\n".join(answers or ["3", "74", "", ""]) + "\n",
                                        text=True, capture_output=True, timeout=5,
                                        env={**os.environ, "NO_PROXY":"127.0.0.1,localhost", "no_proxy":"127.0.0.1,localhost"})
                if full and listener:
                    self.assertEqual((config_dir / "config.json").stat().st_mode & 0o777, 0o600)
                    self.assertEqual(json.loads((config_dir / "config.json.bak").read_text()), {"old": True})
                elif full:
                    self.assertEqual(json.loads((config_dir / "route.json").read_text()), {"old_route": True})
            finally:
                server.shutdown()
                server.server_close()
                worker.join()
        if requests:
            self.assertEqual(requests[0].path, "/api/v1/server/UniProxy/config")
            self.assertEqual(parse_qs(requests[0].query), {"node_type": ["vless"], "node_id": ["74"], "token": [TOKEN]})
        self.assertNotIn(TOKEN, result.stderr)
        return result

    def test_h3_defaults_use_panel_and_regular_certificate(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout.strip().removesuffix(","))
        self.assertEqual(config["Core"], "xray")
        self.assertEqual(config["NodeType"], "vless")
        self.assertEqual(config["ApiKey"], TOKEN)
        self.assertEqual(config["XrayOptions"]["ALPN"], ["h3"])
        self.assertFalse(config["XrayOptions"]["EnableProxyProtocol"])
        self.assertFalse(config["XrayOptions"]["EnableTFO"])
        self.assertEqual(config["CertConfig"]["CertMode"], "http")
        self.assertEqual(config["CertConfig"]["CertDomain"], "node.example.com")
        self.assertIn("/certs/node.example.com/", config["CertConfig"]["CertFile"])
        self.assertNotIn("network_settings", config)
        self.assertIn("UDP 443", result.stderr)

    def test_camel_case_and_string_settings(self):
        node = copy.deepcopy(NODE)
        node["network"] = "splithttp"
        node["networkSettings"] = json.dumps(node.pop("network_settings"))
        node["tlsSettings"] = node.pop("tls_settings")
        result = self.generate(node)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_h2_does_not_enable_h3(self):
        node = copy.deepcopy(NODE)
        node["network_settings"]["alpn"] = "h2, http/1.1"
        result = self.generate(node)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout.strip().removesuffix(","))
        self.assertEqual(config["XrayOptions"]["ALPN"], ["h2", "http/1.1"])
        self.assertIn("TCP 443", result.stderr)

    def test_rejects_invalid_panel_nodes_before_certificate_setup(self):
        for name in ["mixed-alpn", "vision", "reality", "empty-settings", "wrong-network"]:
            with self.subTest(name=name):
                node = copy.deepcopy(NODE)
                if name == "mixed-alpn": node["network_settings"]["alpn"] = ["h3", "h2"]
                elif name == "vision": node["flow"] = "xtls-rprx-vision"
                elif name == "reality": node["tls"] = 2
                elif name == "empty-settings": node["network_settings"] = None
                else: node["network"] = "ws"
                result = self.generate(node)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("XHTTP 的 TLS 证书需要", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_file_mode_accepts_paths_with_spaces(self):
        result = self.generate(answers="file")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout.strip().removesuffix(","))
        self.assertEqual(config["CertConfig"]["CertMode"], "file")
        self.assertTrue(config["CertConfig"]["CertFile"].endswith("chain file.pem"))

    def test_other_selected_cores_do_not_change_this_node(self):
        result = self.generate(previous_cores=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout.strip().removesuffix(","))
        self.assertEqual(config["NodeType"], "vless")
        self.assertNotIn("FallBackSite", config)

    def test_old_binary_is_rejected(self):
        result = self.generate(version="v1.4.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("V2bX update", result.stderr)

    def test_certificate_name_mismatch_is_rejected(self):
        result = self.generate(answers=["3", "74", "", "wrong.example.com"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不一致", result.stderr)

    def test_readiness_requires_our_process_and_correct_protocol(self):
        for process, port, active, expected in [("V2bX", 443, True, 0), ("other", 443, True, 1), ("V2bX", 444, True, 1), ("V2bX", 443, False, 1)]:
            harness = SOURCE + f"""
xhttp_checks=(u:443)
external_web_service_running() {{ return {0 if active else 1}; }}
ss() {{ [[ "$2" == -lunp ]] && printf '%s\\n' 'UNCONN 0 0 *:{port} *:* users:(("{process}",pid=12,fd=4))'; }}
sleep() {{ :; }}
wait_xhttp_ready
"""
            result = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_complete_wizard_writes_usable_private_configuration(self):
        result = self.generate(full=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(config["Cores"][0]["Type"], "xray")
        self.assertEqual(config["Nodes"][0]["XrayOptions"]["ALPN"], ["h3"])
        self.assertEqual(config["Nodes"][0]["ApiKey"], TOKEN)

    def test_full_wizard_restores_old_configuration_on_listener_failure(self):
        result = self.generate(full=True, listener=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"old": True})
        self.assertIn("恢复先前正在运行的配置", result.stderr)
