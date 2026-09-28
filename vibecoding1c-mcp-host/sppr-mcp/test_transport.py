"""Real HTTP OData/client boundaries and MCP initialize/tools/calls, synthetic content only."""
import asyncio
import base64
import json
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit
from dataclasses import replace
from unittest.mock import patch

from fastmcp import Client
import uvicorn

from server import create_mcp
from sppr_core import SpprError, guid, key
from sppr_odata import Http, OData
from sppr_service import Service
from test_sppr import A, TP, IDEA, fixture_schema, uuid
import test_sppr as fixtures


class TransportTests(unittest.TestCase):
    setUp = fixtures.SpprTests.setUp
    tearDown = fixtures.SpprTests.tearDown
    set_policy = fixtures.SpprTests.set_policy
    collect = fixtures.SpprTests.collect
    publish = fixtures.SpprTests.publish


def test_odata_projection_utf8_no_redirect(self):
    observed = []
    mode = {"redirect": False, "bad": False}
    row = self.source.data[key(TP, uuid(1))]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            observed.append((self.path, self.headers.get("Authorization")))
            if mode["redirect"]:
                self.send_response(302)
                self.send_header("Location", "/forbidden-target")
                self.end_headers()
                return
            if self.path.endswith("$metadata"):
                body = fixture_schema()
            else:
                query = parse_qs(urlsplit(self.path).query)
                select = query["$select"][0].split(",")
                value = {k: v for k, v in row.items() if k in select}
                if mode["bad"]:
                    value["Owner_Key"] = uuid(999)
                # Also send an unsolicited field: the client must not retain it.
                value["UNSOLICITED_SECRET"] = "http-source-trap"
                body = json.dumps({"value": [value]}, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        settings = replace(self.settings, odata_url=f"http://127.0.0.1:{server.server_port}/base/odata/standard.odata/")
        source = OData(settings, "Ермаков тест", "пароль-фикстура")
        fields = source.schema.projection(TP)
        result = source.read_scoped(TP, uuid(1), fields, self.source.header(TP, uuid(1)))
        self.assertNotIn("UNSOLICITED_SECRET", result)
        self.assertNotIn("ПарольПользователяХранилищаДляЗагрузкиМетаданных", result)
        auth = base64.b64decode(observed[-1][1][6:]).decode("utf-8")
        self.assertEqual(auth, "Ермаков тест:пароль-фикстура")
        query = parse_qs(urlsplit(observed[-1][0]).query)
        self.assertIn("Owner_Key eq guid'" + A + "'", query["$filter"][0])
        mode["bad"] = True
        with self.assertRaisesRegex(SpprError, "ownership/version"):
            source.read_scoped(TP, uuid(1), fields, self.source.header(TP, uuid(1)))
        mode["redirect"] = True
        with self.assertRaisesRegex(SpprError, "HTTP 302"):
            source.read(TP, uuid(1), fields)
        self.assertFalse(any(path == "/forbidden-target" for path, _ in observed))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_mcp_over_real_http_two_clients(self):
    self.source.lookup("Catalog_итлТипыТП", 51, "(Эпик)", СрезТП="ЧТЗ")
    self.source.lookup("Catalog_итлТипыТП", 52, "Разработка", СрезТП="ЗадачаРазработчику")
    self.source.data[key(TP, uuid(1))]["итлТип_Key"] = uuid(51)
    self.source.data[key(TP, uuid(2))].update({"итлТип_Key": uuid(52), "итлРодитель_Key": uuid(1)})
    self.publish()
    service = Service(self.settings, self.provider)
    mcp = create_mcp(service)
    app = mcp.http_app()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    runtime = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="on"))
    thread = threading.Thread(target=runtime.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    async def exercise():
        for _ in range(100):
            if runtime.started:
                break
            await asyncio.sleep(0.05)
        self.assertTrue(runtime.started)
        responses = []
        for _ in range(2):
            async with Client(f"http://127.0.0.1:{port}/mcp") as client:
                tools = await client.list_tools()
                self.assertEqual({t.name for t in tools}, {"search_sppr", "read_sppr_object", "list_sppr_relations", "sppr_index_status"})
                for tool in tools:
                    self.assertTrue(tool.annotations.readOnlyHint)
                hit = await client.call_tool("search_sppr", {"query": "54321"})
                responses.append(hit.structured_content["hits"])
                self.assertLess(len(hit.content[0].text), 100)
                obj = await client.call_tool("read_sppr_object", {"object_id": key(TP, uuid(1)), "limit": 1})
                self.assertTrue(obj.structured_content["cursor"])
                more = await client.call_tool("read_sppr_object", {"object_id": key(TP, uuid(1)), "limit": 1, "cursor": obj.structured_content["cursor"]})
                self.assertNotEqual(obj.structured_content["fields"], more.structured_content["fields"])
                links = await client.call_tool("list_sppr_relations", {"object_id": key(IDEA, uuid(3))})
                self.assertEqual(len(links.structured_content["relations"]), 2)
                roles = await client.call_tool("list_sppr_relations", {"object_id": key(IDEA, uuid(3)), "view": "development"})
                context, = roles.structured_content["contexts"]
                self.assertEqual(context["mode"], "separate_tp")
                self.assertEqual(context["chtz"]["id"], key(TP, uuid(1)))
                self.assertEqual(context["developer_task"]["id"], key(TP, uuid(2)))
                status = await client.call_tool("sppr_index_status", {})
                self.assertEqual(status.structured_content["state"], "available")
                self.assertNotIn("DO-NOT-READ-SECRET", json.dumps(status.structured_content))
        self.assertEqual(responses[0], responses[1])
    try:
        asyncio.run(exercise())
    finally:
        runtime.should_exit = True
        thread.join(timeout=10)
        sock.close()
    self.assertFalse(thread.is_alive())


def test_odata_failed_middle_page_and_duplicate_keys(self):
    original = self.publish()
    headers = [self.source.header(TP, uuid(1)), self.source.header(TP, uuid(2))]
    mode = {"value": "ok", "calls": 0}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            if self.path.endswith("$metadata"):
                body = fixture_schema()
            else:
                mode["calls"] += 1
                skip = int(parse_qs(urlsplit(self.path).query).get("$skip", ["0"])[0])
                if skip and mode["value"] in (401, 403, 503):
                    self.send_response(mode["value"])
                    self.end_headers()
                    self.wfile.write(b"REMOTE-SECRET-TRAP")
                    return
                if mode["value"] == "duplicate":
                    skip = 0
                body = json.dumps({"value": headers[skip:skip+1]}).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        settings = replace(self.settings, page_size=1, odata_url=f"http://127.0.0.1:{server.server_port}/base/odata/standard.odata/")
        source = OData(settings, "fixture", "fixture")
        self.assertEqual(len(list(source.inventory(TP, A))), 2)
        for value in (401, 403, 503, "duplicate"):
            mode.update(value=value, calls=0)
            with self.assertRaises(SpprError) as caught:
                list(source.inventory(TP, A))
            self.assertNotIn("REMOTE-SECRET-TRAP", str(caught.exception))
            self.assertEqual(mode["calls"], 4 if value == 503 else 2)
            self.assertEqual(self.store.manifest()["generation"], original["generation"])
        http = Http()
        with patch.object(http.opener, "open", side_effect=TimeoutError("REMOTE-SECRET-TRAP")) as open_request:
            with self.assertRaisesRegex(SpprError, "Details redacted"):
                http.request(settings.odata_url)
            self.assertEqual(open_request.call_count, 3)
        mode["value"] = "ok"
        with self.assertRaisesRegex(SpprError, "response exceeds"):
            Http(max_bytes=8).request(settings.odata_url + "$metadata")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


TransportTests.test_odata_failed_middle_page_and_duplicate_keys = test_odata_failed_middle_page_and_duplicate_keys
TransportTests.test_odata_projection_utf8_no_redirect = test_odata_projection_utf8_no_redirect
TransportTests.test_mcp_over_real_http_two_clients = test_mcp_over_real_http_two_clients


if __name__ == "__main__":
    unittest.main()
