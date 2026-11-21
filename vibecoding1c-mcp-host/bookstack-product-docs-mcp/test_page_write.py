import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import httpx
import uvicorn

import server
from page_write import PageWriter, PageWriteError, PersonalAPI
from views import ViewRouter


class FixtureAPI:
    def __init__(self):
        self.page = dict(id=3, name="Title", book_id=1, chapter_id=2, editor="wysiwyg",
                         raw_html="<p>{{@1}}</p>", html="Rendered", revision_count=1)
        self.writes = []

    def request(self, method, path, fields=None):
        if method == "GET":
            return {"pages/3": self.page, "books/1": dict(id=1, name="Book"),
                    "chapters/2": dict(id=2, book_id=1, name="Chapter")}[path]
        self.writes.append((method, path, fields))
        if method == "PUT":
            self.page["revision_count"] += 1
            self.page.update(fields)
            return dict(id=3, updated_by={"id": 27, "name": "Personal User"})
        return dict(id=4, created_by={"id": 27, "name": "Personal User"})


class WriteTests(unittest.TestCase):
    def setUp(self):
        self.api = FixtureAPI()
        self.writer = PageWriter(SimpleNamespace(base_url="http://kb"), server.matches_filters,
                                 lambda settings, token: self.api)
        self.change = {"page_id": 3, "html": "<p>new</p>"}

    def call(self, change=None, confirmation="", token="one:secret", view="product", scope=None):
        return self.writer.run(self.change if change is None else change, confirmation, token, view,
                               {"book_ids": [1]} if scope is None else scope)

    def test_review_uses_editor_source_and_rejects_scope_or_identity_changes(self):
        self.assertEqual(self.call({"page_id": 3})["html"], self.api.page["raw_html"])
        result = self.call()
        self.assertIn("-<p>{{@1}}</p>", result["preview"]["diff"])
        for options in (dict(token="two:secret"), dict(view=""), dict(change=dict(self.change, name="extra"))):
            with self.assertRaises(PageWriteError):
                self.call(confirmation=result["confirmation"], **options)
        for change, scope in (({"page_id": 3}, {"book_ids": [20]}),
                              ({"name": "Title", "book_id": 1, "markdown": "text"}, {"page_ids": [3]}),
                              ({"name": "Title", "chapter_id": 2, "markdown": "text"}, {"chapter_ids": [4]})):
            with self.assertRaises(PageWriteError):
                self.call(change=change, scope=scope)
        with self.assertRaises(PageWriteError):
            self.call(token=None)
        with self.assertRaises(PageWriteError):
            self.call({"page_id": 3, "markdown": "would change editor"})
        self.assertFalse(self.api.writes)

    def test_concurrent_replays_publish_once_and_stale_approval_cannot_overwrite(self):
        first, second = self.call(), self.call()
        with ThreadPoolExecutor(2) as workers:
            results = list(workers.map(lambda _: self.call(confirmation=first["confirmation"]), range(2)))
        self.assertEqual([3, 3], [r["page_id"] for r in results])
        with self.assertRaisesRegex(PageWriteError, "fresh preview"):
            self.call(confirmation=second["confirmation"])
        self.assertEqual([("PUT", "pages/3", {"html": "<p>new</p>"})], self.api.writes)

    def test_uncertain_create_is_not_reposted(self):
        change = dict(name="Title", chapter_id=2, markdown="full text")
        preview = self.call(change)
        self.assertEqual(("Book", "Chapter", "full text"), tuple(preview["preview"][k] for k in ("book", "chapter", "content")))
        request = self.api.request

        def lose_reply(method, path, fields=None):
            result = request(method, path, fields)
            if method == "POST":
                raise PageWriteError("Transport failed.")
            return result

        self.api.request = lose_reply
        for _ in range(2):
            self.assertFalse(self.call(change, preview["confirmation"])["ok"])
        self.assertEqual([("POST", "pages", change)], self.api.writes)

    def test_api_errors_exclude_backends_response_and_credential(self):
        api = PersonalAPI(SimpleNamespace(base_url="http://fake", timeout_seconds=5), "one:secret")
        with mock.patch("httpx.request", return_value=httpx.Response(403, text="secret debug")) as request:
            with self.assertRaisesRegex(PageWriteError, "403") as caught:
                api.request("GET", "pages/3")
            self.assertNotIn("secret", str(caught.exception))
            self.assertFalse(request.call_args.kwargs["follow_redirects"])


class WindowsTransportTests(unittest.TestCase):
    def test_two_projects_one_prompt_real_shared_mcp_preview_and_commit(self):
        api = FixtureAPI()
        seen_auth = []

        class Handler(BaseHTTPRequestHandler):
            def handle_api(self):
                auth = self.headers.get("Authorization")
                seen_auth.append(auth)
                if auth != "Token personal:private-test-secret":
                    self.send_error(403)
                    return
                fields = json.loads(self.rfile.read(int(self.headers["Content-Length"]))) if self.command != "GET" else None
                result = api.request(self.command, self.path.removeprefix("/api/"), fields)
                data = json.dumps(result).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_POST = do_PUT = handle_api

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory(prefix="BookStack тест ") as root, socket.socket() as sock:
            backend = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            self.addCleanup(backend.server_close)
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            self.addCleanup(backend.shutdown)
            env = dict(BOOKSTACK_BASE_URL=f"http://127.0.0.1:{backend.server_port}",
                       BOOKSTACK_TOKEN_ID="read", BOOKSTACK_TOKEN_SECRET="readonly",
                       BOOKSTACK_CACHE_PATH=str(Path(root, "cache.sqlite")), BOOKSTACK_EMBEDDING_MODEL="",
                       BOOKSTACK_VIEWS_JSON='{"product":{"book_ids":[1]}}')
            with mock.patch.dict(os.environ, env):
                mcp, service = server.create_mcp()
            sock.bind(("127.0.0.1", 0))
            app = ViewRouter(mcp.http_app(path="/mcp"), service.views)
            runner = uvicorn.Server(uvicorn.Config(app, log_level="error"))
            thread = threading.Thread(target=runner.run, kwargs={"sockets": [sock]}, daemon=True)
            thread.start()
            try:
                deadline = time.monotonic() + 20
                while not runner.started and thread.is_alive() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(runner.started)
                helper = Path(__file__).resolve().parents[2] / ".agents/skills/product-docs/bookstack-write.ps1"
                endpoint = f"http://127.0.0.1:{sock.getsockname()[1]}/views/product/mcp"
                child_env = dict(os.environ, LOCALAPPDATA=root, ITL_TEST_HELPER=str(helper), ITL_TEST_MCP=endpoint)
                for number in (1, 2):
                    project = Path(root, f"Проект {number}")
                    project.mkdir()
                    (project / "draft.json").write_text(json.dumps(dict(chapter_id=2, name="Страница", markdown="Весь текст"),
                                                                    ensure_ascii=False), encoding="utf-8")
                    command = """
                    $ErrorActionPreference='Stop'
                    function Get-Credential($Message) {
                        if ($env:ITL_TEST_PROJECT -ne '1') { throw 'Unexpected repeat prompt' }
                        [pscredential]::new('personal',(ConvertTo-SecureString 'private-test-secret' -AsPlainText -Force))
                    }
                    $argsMap=@{Endpoint=$env:ITL_TEST_MCP;DraftPath='draft.json'}
                    if ($env:ITL_TEST_PROJECT -eq '2') { $argsMap.Confirmation=$env:ITL_TEST_CONFIRMATION }
                    $result = & $env:ITL_TEST_HELPER @argsMap | ConvertFrom-Json
                    if ($env:ITL_TEST_PROJECT -eq '2') {
                        $source = & $env:ITL_TEST_HELPER -Endpoint $env:ITL_TEST_MCP -ReadSource 3 | ConvertFrom-Json
                        if ($source.html -cne '<p>{{@1}}</p>') { throw 'Missing editable source' }
                        $edit = @{page_id=3; html=($source.html + '<p>updated</p>')} | ConvertTo-Json
                        [IO.File]::WriteAllText((Join-Path $pwd 'edit.json'),$edit)
                        $editArgs = @{Endpoint=$env:ITL_TEST_MCP; DraftPath='edit.json'}
                        $review = & $env:ITL_TEST_HELPER @editArgs | ConvertFrom-Json
                        if (-not $review.preview.diff) { throw 'Missing edit comparison' }
                        $updated = & $env:ITL_TEST_HELPER @editArgs -Confirmation $review.confirmation | ConvertFrom-Json
                        if ($updated.page_id -ne 3 -or $updated.author.id -ne 27) { throw 'Missing update receipt' }
                    }
                    $result | ConvertTo-Json -Depth 8
                    """
                    child = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                                           cwd=project, env=dict(child_env, ITL_TEST_PROJECT=str(number)),
                                           capture_output=True, timeout=45)
                    self.assertEqual(0, child.returncode, child.stderr.decode("utf-8", "replace"))
                    self.assertNotIn(b"private-test-secret", child.stdout)
                    reply = json.loads(child.stdout.decode("utf-8-sig"))
                    self.assertTrue(reply["ok"], reply)
                    if number == 1:
                        self.assertFalse(api.writes)
                        self.assertEqual("Весь текст", reply["preview"]["content"])
                        child_env["ITL_TEST_CONFIRMATION"] = reply["confirmation"]
                    else:
                        self.assertEqual((4, 27), (reply["page_id"], reply["author"]["id"]))
                self.assertEqual({"Token personal:private-test-secret"}, set(seen_auth))
                self.assertEqual(["POST", "PUT"], [write[0] for write in api.writes])
                self.assertEqual({"html": "<p>{{@1}}</p><p>updated</p>"}, api.writes[1][2])
                encrypted = Path(root, "ITL/BookStack/personal.clixml").read_bytes()
                self.assertNotIn(b"private-test-secret", encrypted)
                self.assertNotIn("private-test-secret".encode("utf-16le"), encrypted)
            finally:
                runner.should_exit = True
                thread.join(15)


if __name__ == "__main__":
    unittest.main()
