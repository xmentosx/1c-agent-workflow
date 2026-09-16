import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
BRIDGE_PATH = REPO / ".agents" / "skills" / "1c-workflow" / "chatgpt" / "mcp_bridge.py"
spec = importlib.util.spec_from_file_location("mcp_bridge_stdio", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bridge)


class StdioBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL stdio чат с пробелом ")
        self.root = Path(self.temp.name)
        (self.root / ".codex").mkdir()
        self.server = self.root / "fixture_mcp.py"
        self.server.write_text(
            """import json, sys
for line in sys.stdin:
    payload = json.loads(line)
    method = payload.get('method')
    if 'id' not in payload:
        continue
    if method == 'initialize':
        result = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}
""",
            encoding="utf-8",
        )
        self.server.write_text(
            self.server.read_text(encoding="utf-8")
            + """    elif method == 'tools/call':
        result = {'content': [{'type': 'text', 'text': payload.get('params', {}).get('arguments', {}).get('value', '')}]}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': payload['id'], 'result': result}, ensure_ascii=False), flush=True)
""",
            encoding="utf-8",
        )
        executable = json.dumps(sys.executable)
        script = json.dumps(str(self.server))
        (self.root / ".codex" / "config.toml").write_text(
            f'[mcp_servers."fixture"]\ncommand = {executable}\nargs = [{script}]\nenabled = true\ntool_timeout_sec = 10\n',
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_stdio_initialize_list_and_call(self):
        listed = bridge.list_tools(self.root, "fixture")
        self.assertEqual([tool["name"] for tool in listed["tools"]], ["echo"])
        called = bridge.call_tool(self.root, "fixture", "echo", {"value": "готово"})
        self.assertEqual(called["result"]["content"][0]["text"], "готово")


if __name__ == "__main__":
    unittest.main()
