import importlib.util
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

REPO = Path(__file__).resolve().parents[3]
BRIDGE_PATH = REPO / ".agents" / "skills" / "1c-workflow" / "chatgpt" / "mcp_bridge.py"
spec = importlib.util.spec_from_file_location("mcp_bridge", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bridge)


class FakeMcpHandler(BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        type(self).calls.append((payload, self.headers.get("Mcp-Session-Id")))
        method = payload.get("method")
        if method == "notifications/initialized":
            self.send_response(202)
            self.end_headers()
            return
        if method == "initialize":
            result = {"protocolVersion": bridge.PROTOCOL_VERSION, "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo", "description": "Echo", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": payload["params"]["arguments"].get("value", "")}]}
        else:
            self.send_response(400)
            self.end_headers()
            return
        body = f"event: message\ndata: {json.dumps({'jsonrpc': '2.0', 'id': payload['id'], 'result': result})}\n\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Mcp-Session-Id", "fixture-session")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL Тест КОРП (ветка)-1 ")
        self.root = Path(self.temp.name)
        (self.root / ".codex").mkdir()
        FakeMcpHandler.calls = []

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, text):
        (self.root / ".codex" / "config.toml").write_text(text, encoding="utf-8")
    def test_reads_existing_config_without_mutation(self):
        self.write_config('''[mcp_servers."пример"]\nurl = "http://127.0.0.1:9999/mcp"\nenabled = true\n''')
        before = (self.root / ".codex" / "config.toml").read_bytes()
        servers = bridge.load_servers(self.root)
        self.assertEqual(servers["пример"]["url"], "http://127.0.0.1:9999/mcp")
        self.assertEqual(before, (self.root / ".codex" / "config.toml").read_bytes())

    def test_http_initialize_list_and_call_preserve_session(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeMcpHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.write_config(f'''[mcp_servers."fixture"]\nurl = "http://127.0.0.1:{server.server_port}/mcp"\nenabled = true\n''')
            listed = bridge.list_tools(self.root, "fixture")
            self.assertEqual([tool["name"] for tool in listed["tools"]], ["echo"])
            called = bridge.call_tool(self.root, "fixture", "echo", {"value": "готово"})
            self.assertEqual(called["result"]["content"][0]["text"], "готово")
            session_calls = [session for payload, session in FakeMcpHandler.calls if payload.get("method") != "initialize"]
            self.assertTrue(session_calls)
            self.assertTrue(all(value == "fixture-session" for value in session_calls))
        finally:
            server.shutdown()
            server.server_close()

    def test_cli_forces_utf8_and_preserves_relative_unicode_root(self):
        self.write_config('''[mcp_servers."one"]\nurl = "http://127.0.0.1:1/mcp"\n''')
        installed_bridge = self.root / ".agents" / "skills" / "1c-workflow" / "chatgpt" / "mcp_bridge.py"
        installed_bridge.parent.mkdir(parents=True)
        shutil.copy2(BRIDGE_PATH, installed_bridge)
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "cp1251"
        result = subprocess.run(
            [sys.executable, str(installed_bridge.relative_to(self.root)), "--project-root", ".", "project-info"],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        stdout = result.stdout.decode("utf-8")
        info = json.loads(stdout)
        self.assertEqual(info["projectRoot"], str(self.root.resolve()))
        self.assertIn("Тест КОРП (ветка)-1", info["projectRoot"])

    def test_project_info_reports_rules_skills_and_servers(self):
        self.write_config('''[mcp_servers."one"]\nurl = "http://127.0.0.1:1/mcp"\n''')
        (self.root / ".agents" / "skills").mkdir(parents=True)
        (self.root / "AGENTS.md").write_text("rules", encoding="utf-8")
        info = bridge.project_info(self.root)
        self.assertEqual(info["mcpServers"], ["one"])
        self.assertTrue(info["skillsRoot"].endswith(".agents\\skills") or info["skillsRoot"].endswith(".agents/skills"))
        self.assertTrue(info["ruleFilesInPrecedenceOrder"][0].endswith("AGENTS.md"))


if __name__ == "__main__":
    unittest.main()
