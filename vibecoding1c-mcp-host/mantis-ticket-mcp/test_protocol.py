"""In-process MCP protocol acceptance using real FastMCP and Zvec, no network."""
import asyncio
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastmcp import Client
import server
from test_index import FakeApi, ticket
from test_server import FakeClient


class ProtocolTests(unittest.TestCase):
    def test_real_protocol_preserves_images_and_exposes_search(self):
        async def run():
            with tempfile.TemporaryDirectory(prefix="mantis MCP ") as directory:
                api = FakeApi()
                api.items[1]["attachments"] = [{"id": 10, "filename": "status.png", "content_type": "image/png"}]
                env = {"MANTIS_BASE_URL": "https://mantis.test", "MANTIS_API_TOKEN": "fixture",
                       "MANTIS_INDEX_ENABLED": "true", "MANTIS_STATE_PATH": str(Path(directory) / "state"),
                       "MANTIS_ATTACHMENT_CACHE_PATH": str(Path(directory) / "attachments")}
                with patch.dict(os.environ, env), patch("mantis_runtime.Api", return_value=api), patch("server.MantisClient", return_value=FakeClient()), patch("mantis_index.Index.start"), patch("fastmcp.server.dependencies.get_http_headers", return_value={"x-mantis-actor": "fixture analyst"}):
                    mcp, service = server.create_mcp()
                    service.client.index.refresh(1)
                    async with Client(mcp) as client:
                        tools = await client.list_tools()
                        schema = json.dumps([t.model_dump() for t in tools], ensure_ascii=False)
                        self.assertEqual(len(tools), 8)
                        search_schema = next(t.inputSchema for t in tools if t.name == "search_tickets")
                        self.assertEqual(search_schema["properties"]["limit"]["default"], 10)
                        self.assertNotIn("fixture analyst", schema)
                        found = await client.call_tool("search_tickets", {"query": "решения", "actor": "fixture analyst", "semantic": False})
                        self.assertEqual(found.structured_content["issues"][0]["id"], 1)
                        self.assertLess(len(found.content[0].text), 200)
                        self.assertNotIn("Описание решения", found.content[0].text, "Do not duplicate structured results in textual content")
                        read = await client.call_tool("read_ticket", {"url_or_id": "1"})
                        self.assertTrue(any(b.type == "image" for b in read.content))
                        self.assertIn("freshness", read.structured_content)
                        health = await client.call_tool("health", {})
                        self.assertTrue(health.structured_content["index"]["enabled"])
                        self.assertEqual(health.structured_content["index"]["query_embedding_cache"]["limit"], 256)
                        inspected = await client.call_tool("write_operation", {"action": "inspect", "issue_id": 1})
                        self.assertTrue(inspected.structured_content["expected_version"])
                        self.assertNotIn("description", inspected.structured_content["issue"])
                        self.assertNotIn("notes", inspected.structured_content["issue"])
                        index = service.client.index
                        charge = index.state.reserve(1, 5)
                        index.state.purge_issue(999)
                        service.client.writer.prepare("operation01", "fixture analyst", [{"action": "add_comment", "issue_id": 1, "fields": {"text": "draft"}}])
                        await client.call_tool("index_control", {"action": "pause"})
                        rebuilt = await client.call_tool("index_control", {"action": "rebuild_vectors"})
                        self.assertTrue(rebuilt.structured_content["paused"])
                        self.assertEqual(index.state.one("SELECT status FROM operations WHERE id='operation01'")["status"], "pending")
                        self.assertIsNotNone(index.state.one("SELECT issue_id FROM tombstones WHERE issue_id=999"))
                        self.assertEqual(index.state.one("SELECT status FROM charges WHERE id=?", (charge,))["status"], "unknown")
                        await client.call_tool("index_control", {"action": "settle_charge", "charge_id": charge, "actual_cost_usd": 0.25})
                        self.assertEqual(index.state.one("SELECT actual FROM charges WHERE id=?", (charge,))["actual"], 0.25)
                        tool_file = Path(directory) / "инструменты с пробелом.json"
                        tool_file.write_text(schema, encoding="utf-8")
                        proxy = Path(__file__).resolve().parents[1] / "tools-list-proxy"
                        code = "const fs=require('fs'); const p=require(process.argv[1]); const t=JSON.parse(fs.readFileSync(process.argv[2],'utf8')); console.log(JSON.stringify({...p.describeContract(t),legacy:p.describeContract(t.filter(x=>['read_ticket','get_attachment','health'].includes(x.name))).structuralSha256}));"
                        result = subprocess.run(["node", "-e", code, str(proxy / "mcp-tools-list-proxy.js"), str(tool_file)], capture_output=True, text=True, encoding="utf-8", check=True)
                        contract = json.loads(result.stdout)
                        expected = json.loads((proxy / "tools-contract.json").read_text(encoding="utf-8"))["servers"]["mantis"]
                        print(json.dumps({"tools": len(tools), "schema_utf8_bytes": len(schema.encode("utf-8")),
                            "legacy_schema_utf8_bytes": len(json.dumps([t.model_dump() for t in tools if t.name in {"read_ticket", "get_attachment", "health"}], ensure_ascii=False).encode("utf-8")),
                            "structuralSha256": contract["structuralSha256"]}))
                        self.assertEqual(contract["structuralSha256"], expected["structuralSha256"])
                        self.assertEqual(contract["toolCount"], expected["toolCount"])
                        self.assertEqual(contract["legacy"], "23f418064100f745af84d79896f8840c1ebff0df63a7c458285b25810ef591f1")
        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
