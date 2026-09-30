"""In-process MCP protocol acceptance using real FastMCP and Zvec, no network."""
import asyncio
import json
import os
import subprocess
import threading
import time
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastmcp import Client
import server
from test_index import FakeApi, ticket
from test_server import FakeClient


class ProtocolTests(unittest.TestCase):
    def test_client_without_identity_can_read_and_write_with_explicit_audit_fallback(self):
        async def run():
            with tempfile.TemporaryDirectory(prefix="mantis optional identity ") as directory:
                api = FakeApi()
                env = {"MANTIS_BASE_URL": "https://mantis.test", "MANTIS_API_TOKEN": "fixture",
                       "MANTIS_INDEX_ENABLED": "true", "MANTIS_WRITE_ENABLED": "true",
                       "MANTIS_STATE_PATH": str(Path(directory) / "state"),
                       "MANTIS_ATTACHMENT_CACHE_PATH": str(Path(directory) / "attachments")}
                with patch.dict(os.environ, env), patch("mantis_runtime.Api", return_value=api), patch("server.MantisClient", return_value=FakeClient()), patch("mantis_index.Index.start"), patch("fastmcp.server.dependencies.get_http_headers", return_value={}):
                    mcp, service = server.create_mcp()
                    index = service.client.index
                    index.refresh(1)
                    async with Client(mcp) as client:
                        tools = await client.list_tools()
                        write_schema = next(t.inputSchema for t in tools if t.name == "execute_write")
                        self.assertNotIn("actor", write_schema["required"])
                        self.assertEqual(write_schema["properties"]["actor"]["default"], "")
                        for name, arguments in (
                            ("search_tickets", {"query": "решения", "semantic": False}),
                            ("read_ticket", {"url_or_id": "1", "include_attachments": False}),
                            ("read_comments", {"url_or_id": "1"}),
                            ("ticket_history", {"url_or_id": "1"}),
                            ("mantis_metadata", {"project_id": 1}),
                            ("index_control", {"action": "status"}),
                            ("write_operation", {"action": "inspect", "issue_id": 1}),
                        ):
                            result = await client.call_tool(name, arguments)
                            self.assertFalse(result.is_error, name)
                            self.assertNotEqual(result.structured_content.get("ok"), False, name)
                        arguments = {"operation_id": "anonymous-operation01", "steps": [
                            {"action": "add_comment", "issue_id": 1, "fields": {"text": "Без профиля"}}]}
                        for _ in range(2):
                            written = await client.call_tool("execute_write", arguments)
                            self.assertEqual(written.structured_content["status"], "succeeded")
                        self.assertEqual(len(api.items[1]["notes"]), 1, "Anonymous retry must not duplicate the write")
                        self.assertIn("инициатор не указан", api.items[1]["notes"][0]["text"])
                        self.assertEqual(index.state.one("SELECT actor FROM operations WHERE id=?", (arguments["operation_id"],))["actor"], "не указан")
                        self.assertEqual(index.state.one("SELECT actor FROM audit WHERE action='read_ticket'")["actor"], "не указан")
                        named = await client.call_tool("search_tickets", {"query": "решения", "semantic": False, "actor": "named analyst"})
                        self.assertFalse(named.is_error)
                        self.assertEqual(index.state.one("SELECT actor FROM audit WHERE action='search' ORDER BY id DESC LIMIT 1")["actor"], "named analyst")
        asyncio.run(run())

    def test_waiting_for_index_writer_does_not_block_mcp_protocol(self):
        async def run():
            with tempfile.TemporaryDirectory(prefix="mantis concurrent ") as directory:
                env = {"MANTIS_BASE_URL": "https://mantis.test", "MANTIS_API_TOKEN": "fixture",
                       "MANTIS_INDEX_ENABLED": "true", "MANTIS_STATE_PATH": str(Path(directory) / "state"),
                       "MANTIS_ATTACHMENT_CACHE_PATH": str(Path(directory) / "attachments")}
                with patch.dict(os.environ, env), patch("mantis_runtime.Api", return_value=FakeApi()), patch("mantis_index.Index.start"):
                    mcp, service = server.create_mcp()
                    state = service.client.index.state
                    entered, release = threading.Event(), threading.Event()
                    def writer():
                        with state.lock:
                            entered.set()
                            release.wait(3)  # Watchdog lets a broken implementation fail instead of hanging the test.
                    async with Client(mcp) as client:
                        thread = threading.Thread(target=writer)
                        thread.start()
                        await asyncio.to_thread(entered.wait, 1)
                        pending = asyncio.create_task(client.call_tool("health", {}))
                        start = time.monotonic()
                        try:
                            await asyncio.sleep(0.05)
                            tools = await asyncio.wait_for(client.list_tools(), 1)
                            self.assertEqual(len(tools), 10)
                            self.assertLess(time.monotonic() - start, 1,
                                            "A database writer must not freeze the MCP HTTP event loop")
                            health = await asyncio.wait_for(pending, 1)
                            self.assertTrue(health.structured_content["ok"])
                            self.assertTrue(health.structured_content["index"]["enabled"])
                        finally:
                            release.set()
                            await asyncio.to_thread(thread.join, 1)
        asyncio.run(run())

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
                        self.assertEqual(len(tools), 10)
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
                        self.assertEqual(service.client.index.state.one("SELECT actor FROM audit WHERE action='read_ticket'")["actor"], "fixture analyst")
                        history = await client.call_tool("ticket_history", {"url_or_id": "1"})
                        self.assertTrue(history.structured_content["ok"])
                        self.assertLess(len(history.content[0].text), 200)
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
                        self.assertEqual(index.state.one("SELECT value FROM meta WHERE key='index_paused'")["value"], "1")
                        storage = await client.call_tool("index_control", {"action": "storage"})
                        self.assertIn("bytes", storage.structured_content["storage"])
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
