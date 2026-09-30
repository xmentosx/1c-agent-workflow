from __future__ import annotations

import base64
import copy
import json
import io
import subprocess
import threading
from array import array
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from mantis_api import Api, ApiError
from mantis_index import Index
from mantis_state import (REHYDRATE_ATTACHMENT_QUERY, SearchReader, State, digest,
                          timestamp, file_descriptors)
from mantis_write import Writer, ACTIONS


class FakeEmbeddingResponse:
    def __init__(self, status=200, data=None, text="", headers=None):
        self.status = status
        self.payload = json.dumps(data).encode("utf-8") if data is not None else text.encode("utf-8")
        self.headers = headers or {}
        self.will_close = False

    def getheader(self, name):
        return self.headers.get(name)

    def read(self, limit):
        return self.payload[:limit]


class FakeEmbeddingConnection:
    def __init__(self, handler):
        self.handler = handler
        self.sock = None
        self.timeouts = []

    def connect(self):
        self.sock = SimpleNamespace(settimeout=self.timeouts.append)

    def request(self, method, path, body, headers):
        self.body = body
        self.headers = headers

    def getresponse(self):
        return self.handler(self)

    def close(self):
        self.sock = None


def ticket(issue_id=1, project=1, text="Описание решения", updated="2026-09-28T12:00:00+03:00"):
    return {"id": issue_id, "project": {"id": project}, "summary": "Решение проблемы",
            "description": text, "status": {"id": 90}, "reporter": {"id": 3025},
            "created_at": "2000-01-01T00:00:00+03:00", "updated_at": updated,
            "notes": [], "attachments": [], "tags": [], "relationships": [], "custom_fields": []}


class FakeApi:
    def __init__(self):
        self.settings = SimpleNamespace(base_url="https://mantis.test", timeout_seconds=1, max_attachment_bytes=100000)
        self.items = {1: ticket()}
        self.project_list = [{"id": 1, "access_level": {"id": 70}}]
        self.down = False
        self.sent = []
        self.lost = False
        self.ignore = False
        self.duplicate = False
        self.files = {}
        self.scans = 0
        self.page_hook = None
        self.level = 70
        self.block_upload = False
        self.definitions = []

    def me(self):
        if self.down:
            raise ApiError("unavailable")
        return {"id": 3025, "name": "service"}

    def projects(self):
        self.me()
        return copy.deepcopy(self.project_list)

    def project_users(self, project_id, page, size=100, handlers_only=False):
        self.me()
        users = [{"id": 10, "name": "ivan", "real_name": "Иван Петров", "access_level": {"id": 55}},
                 {"id": 11, "name": "ivanov", "real_name": "Иван Сидоров", "access_level": {"id": 55}},
                 {"id": 12, "name": "anna", "real_name": "Анна", "access_level": {"id": 25}}]
        if handlers_only:
            users = users[:2]
        return users[(page - 1) * size:page * size]

    def tags(self):
        return [{"id": 1, "name": "renamed"}]

    def headers(self, project_id, page, size):
        self.me()
        self.scans += 1
        if self.page_hook:
            self.page_hook(page, self.scans)
        rows = [v for v in self.items.values() if v["project"]["id"] == project_id]
        rows.sort(key=lambda v: (timestamp(v["updated_at"]), v["id"]), reverse=True)
        return [{k: copy.deepcopy(v[k]) for k in ("id", "project", "status", "updated_at")} for v in rows[(page-1)*size:page*size]]

    def visible_issue(self, issue_id):
        self.me()
        if issue_id not in self.items:
            raise ApiError("not visible", 404)
        value = copy.deepcopy(self.items[issue_id])
        return value, digest(value)

    issue = visible_issue

    def initial_page(self, project_id, page, size):
        return [{"issue": self.visible_issue(r["id"])[0]} for r in self.headers(project_id, page, size)]

    def confirm_absence(self, issue_id, error):
        return not self.down and error.status == 404 and issue_id not in self.items

    def context(self, project_id):
        if int(project_id) not in {int(project["id"]) for project in self.project_list}:
            raise ApiError("Project is not accessible", 403)
        config = {key: 25 for key in ["report_bug_threshold", "update_bug_threshold", "add_bugnote_threshold",
            "bugnote_user_edit_threshold", "upload_bug_file_threshold", "change_view_status_threshold",
            "change_view_status_bug_threshold", "tag_attach_threshold", "tag_detach_threshold", "reopen_bug_threshold", "update_bug_assign_threshold"]}
        config.update(update_bugnote_threshold=55, private_bugnote_threshold=55, private_bug_threshold=55,
                      bug_readonly_status_threshold=90, update_readonly_bug_threshold=70, bug_resolved_status_threshold=80,
                      set_status_threshold={"10": 25, "50": 40, "90": 25}, status_enum_workflow={}, max_file_size=100000,
                      allowed_files="", disallowed_files="exe")
        if self.block_upload:
            config["upload_bug_file_threshold"] = 80
        return {"user": self.me(), "project": {"id": project_id}, "level": self.level, "config": config}

    def metadata(self, project_id):
        return {**self.context(project_id), "custom_fields": self.definitions}

    def request(self, path, method="GET", payload=None, etag="", max_response_bytes=0):
        if method == "GET" and "/files/" in path:
            return {"files": [self.files[int(path.rsplit("/", 1)[1])]]}, ""
        self.sent.append((method, path, payload, etag))
        parts = path.split("/")
        if path == "issues":
            iid = max(self.items, default=0) + 1
            self.items[iid] = {**ticket(iid), **copy.deepcopy(payload)}
            result = {"issue": self.items[iid]}
        elif parts[-1] == "notes":
            issue = self.items[int(parts[1])]
            note = {"id": len(issue["notes"]) + 100, "reporter": {"id": 3025}, **copy.deepcopy(payload)}
            issue["notes"].append(note)
            for file in note.pop("files", []):
                fid = len(self.files) + 10
                self.files[fid] = {**file, "id": fid}
                note.setdefault("attachments", []).append({"id": fid, "filename": file["name"]})
            if self.duplicate:
                issue["notes"].append({**note, "id": note["id"] + 1000})
            result = {"note": note}
        elif parts[-1] == "files":
            file = copy.deepcopy(payload["files"][0])
            fid = len(self.files) + 10
            self.files[fid] = {**file, "id": fid}
            self.items[int(parts[1])]["attachments"].append({"id": fid, "filename": file["name"]})
            result = {}
        elif parts[-1] == "relationships" and method == "POST":
            issue = self.items[int(parts[1])]
            rid = 100 + len(issue["relationships"])
            issue["relationships"].append({"id": rid, "issue": payload["issue"], "type": payload["type"]})
            result = {"issue": issue}
        elif len(parts) == 4 and parts[2] == "relationships" and method == "DELETE":
            issue = self.items[int(parts[1])]
            issue["relationships"] = [r for r in issue["relationships"] if int(r["id"]) != int(parts[3])]
            result = {"issue": issue}
        elif method == "PATCH":
            if not self.ignore:
                self.items[int(parts[1])].update(copy.deepcopy(payload))
            result = {"issues": [self.items[int(parts[1])]]}
        elif parts[-1] == "tags":
            self.items[int(parts[1])]["tags"] += payload["tags"]
            result = {}
        elif method == "DELETE":
            self.items[int(parts[1])]["tags"] = [t for t in self.items[int(parts[1])]["tags"] if t["id"] != int(parts[-1])]
            result = {}
        else:
            raise AssertionError(path)
        if self.lost:
            raise ApiError("response lost after side effect")
        return result, "etag"

    def soap(self, method, payload):
        assert method == "mc_issue_note_update"
        self.sent.append(("SOAP", method, payload, ""))
        note = payload["note"]
        for issue in self.items.values():
            for target in issue["notes"]:
                if target["id"] == note["id"]:
                    target.update(note)
                    return True
        raise ApiError("unknown note")


class MemoryVectors:
    dimension = 2
    failed = False

    def __init__(self):
        self.docs = {}
        self.lock = threading.Lock()

    def existing(self, keys):
        with self.lock:
            return set(keys) & self.docs.keys()

    def upsert_batch(self, rows):
        with self.lock:
            self.docs.update(rows)

    def purge(self):
        pass

    def close(self):
        pass


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mantis Пробел ")
        self.root = Path(self.temp.name)
        self.state = State(self.root / "state", self.root / "files")
        self.api = FakeApi()
        self.index = Index(self.state, self.api)
        self.writer = Writer(self.index, True)
        self.index.catalogs()

    def tearDown(self):
        self.state.close()
        self.temp.cleanup()

    def search(self, query, **kwargs):
        result = self.index.search(query, semantic=False, **kwargs)
        if result.get("status") == "results_changed":
            result = self.index.search(query, semantic=False, **kwargs)
        return result

    def test_initial_closed_old_creation_and_new_modified(self):
        self.index.sync_project(1)
        self.index.sync_project(1)
        self.api.items[1]["description"] = "новаяфраза"
        self.api.items[1]["updated_at"] = "2026-09-28T12:01:00+03:00"
        self.index.sync_project(1)
        self.assertEqual(self.search("новаяфраза")["issues"][0]["id"], 1)
        self.assertEqual(self.state.one("SELECT status FROM projects WHERE id=1")["status"], "current")

    def test_equal_timestamp_boundary_spans_pages(self):
        self.api.items = {n: ticket(n) for n in range(1, 222)}
        self.state.run("UPDATE projects SET status='current',checkpoint=?", (timestamp(ticket()["updated_at"]),))
        self.index.sync_project(1)
        self.assertEqual(self.state.health()["issues"], 221)

    def test_initial_import_repairs_unchanged_record_skipped_by_deleted_page_head_after_restart(self):
        self.api.items = {n: ticket(n, updated="2020-01-01T00:00:00Z") for n in range(1, 151)}
        self.api.items[151] = ticket(151)
        self.index.sync_project(1)
        del self.api.items[151]
        self.index.sync_project(1)
        self.assertIsNone(self.state.one("SELECT id FROM issues WHERE id=51"))
        self.state.close()
        self.state = State(self.root / "state", self.root / "files")
        self.index = Index(self.state, self.api)
        for _ in range(8):
            self.index.sync_project(1)
            if self.state.one("SELECT status FROM projects WHERE id=1")["status"] == "current":
                break
        self.assertEqual(self.state.one("SELECT status FROM projects WHERE id=1")["status"], "current")
        self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=51"))
        self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM issues WHERE id<=150")["n"], 150)

    def test_project_purge_is_atomic_and_survives_restart(self):
        self.state.put_issue(ticket(1))
        self.state.put_issue(ticket(2))
        original = self.state._purge_issue
        def fail_after_one(issue_id, project_id):
            original(issue_id, project_id)
            raise RuntimeError("interrupted project purge")
        with patch.object(self.state, "_purge_issue", side_effect=fail_after_one):
            with self.assertRaises(RuntimeError):
                self.state.purge_project(1)
        self.assertEqual(self.state.health()["issues"], 2)
        self.state.close()
        self.state = State(self.root / "state", self.root / "files")
        self.state.purge_project(1)
        self.assertEqual(self.state.health()["issues"], 0)
        self.assertEqual(len(self.state.all("SELECT * FROM tombstones")), 2)

    def test_hidden_comment_is_removed_from_journal_without_losing_confirmed_ids(self):
        result = self.writer.execute("operation01", "analyst", [{"action": "add_comment", "issue_id": 1, "fields": {"text": "PRIVATE_REMOVED_891723"}}])
        self.assertEqual(result["status"], "succeeded")
        self.api.items[1]["notes"] = []
        self.index.refresh(1)
        operation = self.writer.status("operation01")
        self.assertEqual(operation["status"], "access_removed")
        self.assertEqual(operation["steps"][0]["result"]["note_id"], 100)
        self.assertNotIn(b"PRIVATE_REMOVED_891723", (self.root / "state" / "mantis.sqlite").read_bytes())

    def test_raw_angle_bracket_source_is_searchable(self):
        self.api.items[1]["description"] = "Code <UniqueIdentifier234> remains a source"
        self.index.refresh(1)
        self.assertEqual(self.search("UniqueIdentifier234")["issues"][0]["id"], 1)

    def test_all_query_terms_rank_a_relevant_issue_before_single_word_hits(self):
        self.api.items = {
            1: ticket(1, text="Excel " * 80),
            2: ticket(2, text="Загрузка данных из Excel"),
            3: ticket(3, text="Загрузка данных из файла"),
        }
        for issue in self.api.items.values():
            self.state.put_issue(issue)
        result = self.search("загрузка excel", limit=3)
        self.assertEqual([item["id"] for item in result["issues"]], [2, 1, 3])

    def test_semantic_fragment_lookup_uses_search_reader_during_index_writes(self):
        self.state.put_issue(ticket(1))
        self.state.run("UPDATE fragments SET vector_id='semantic-key',vector_version=version")
        self.index.vectors = SimpleNamespace(query=lambda vector: ["semantic-key"], purge=lambda: None)
        self.index.embeddings = SimpleNamespace()
        original = self.state.one
        def guarded(sql, args=()):
            if "SELECT id FROM fragments WHERE vector_id=?" in sql:
                raise AssertionError("Semantic lookups must not contend for the writer connection")
            return original(sql, args)
        with patch.object(self.index, "query_vector", return_value=([0.0], "hit")), \
             patch.object(self.state, "one", side_effect=guarded):
            result = self.index.search("unrelated phrase", semantic=True)
        self.assertTrue(result["ok"])
        self.assertEqual(result["semantic_query"], "available")
        self.assertEqual(result["issues"][0]["id"], 1)

    def test_broad_and_empty_search_are_paged_under_the_output_budget(self):
        for number in range(1, 26):
            issue = ticket(number, text="совпадение " * 1000)
            issue["notes"] = [{"id": number * 10 + n, "text": "совпадение " * 1000} for n in range(3)]
            self.api.items[number] = issue
            self.state.put_issue(issue)
        first = self.search("совпадение", limit=999)
        self.assertLessEqual(len(json.dumps(first, ensure_ascii=False, separators=(",", ":"))), 12000)
        self.assertTrue(first["next_cursor"])
        self.assertLess(len(first["issues"]), 20, "The text budget must trim broad pages before the count cap")
        second = self.search("совпадение", limit=999, cursor=first["next_cursor"])
        self.assertFalse({i["id"] for i in first["issues"]} & {i["id"] for i in second["issues"]})
        self.assertEqual(second["issues"][0]["id"], first["issues"][-1]["id"] + 1)
        blank = self.search("")
        self.assertEqual(len(blank["issues"]), 10)
        self.assertTrue(blank["next_cursor"])
        self.assertNotIn("description", blank["issues"][0])

    def test_query_embedding_reused_across_pages_filters_and_source_changes(self):
        from mantis_index import Embeddings
        for number in range(1, 13):
            self.api.items[number] = ticket(number)
            self.state.put_issue(self.api.items[number])
        self.state.run("UPDATE fragments SET vector_id=id,vector_version=version")
        self.index.vectors = SimpleNamespace(
            query=lambda vector: [r["vector_id"] for r in self.state.all("SELECT vector_id FROM fragments WHERE vector_id<>''")],
            purge=lambda: None)
        response = {"data": [{"index": 0, "embedding": [1.0] + [0.0] * 4095}], "usage": {"cost": 0.001}}
        requests = []
        def serve(request):
            requests.append(request)
            return FakeEmbeddingResponse(data=response)
        self.index.embeddings = Embeddings(self.state, "fixture",
                                           connection_factory=lambda: FakeEmbeddingConnection(serve))
        try:
            first = self.index.search("решения", limit=2)
            second = self.index.search("решения", limit=2, cursor=first["next_cursor"])
            self.assertEqual(first["query_embedding_cache"], "miss")
            self.assertEqual(second["query_embedding_cache"], "hit")
            self.assertFalse({r["id"] for r in first["issues"]} & {r["id"] for r in second["issues"]})
            self.api.items[1]["description"] = "уже изменённое содержание"
            self.index.refresh(1)
            del self.api.items[2]
            with self.assertRaises(ApiError):
                self.index.refresh(2)
            with patch.object(self.index, "refresh", wraps=self.index.refresh) as refreshed:
                changed = self.index.search("решения", filters={"project_id": 1, "status": 90})
            self.assertGreater(refreshed.call_count, 0, "Cached vectors must not bypass fresh issue access checks")
            self.assertEqual(changed["query_embedding_cache"], "hit")
            self.assertNotIn(2, {r["id"] for r in changed["issues"]})
            self.assertNotIn("Описание решения", " ".join(m["snippet"] for r in changed["issues"] if r["id"] == 1 for m in r["matches"]))
            self.assertEqual(len(requests), 1)
        finally:
            self.index.embeddings.close()
        self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM charges")["n"], 1)
        self.assertEqual(self.state.one("SELECT SUM(actual) AS n FROM charges")["n"], 0.001)

    def test_parallel_query_embeddings_share_one_provider_call(self):
        started, release = threading.Event(), threading.Event()
        calls = []
        def embed(texts, **kwargs):
            calls.append(texts)
            started.set()
            if not release.wait(3):
                raise TimeoutError("fixture release missing")
            return [[0.125, 0.25]]
        self.index.embeddings = SimpleNamespace(embed=embed)
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(self.index.query_vector, "одновременный запрос") for _ in range(4)]
            try:
                self.assertTrue(started.wait(1))
                deadline = time.monotonic() + 1
                while self.index.query_cache_status()["shared"] < 3 and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertEqual(self.index.query_cache_status()["shared"], 3)
            finally:
                release.set()
            results = [future.result(timeout=2) for future in futures]
        self.assertEqual(len(calls), 1)
        self.assertEqual(sorted(status for _, status in results), ["miss", "shared", "shared", "shared"])
        results[0][0][0] = 999
        self.assertEqual(self.index.query_vector("одновременный запрос"), ([0.125, 0.25], "hit"))

    def test_failed_query_embedding_releases_waiters_and_is_retried(self):
        started, release = threading.Event(), threading.Event()
        def fail(texts, **kwargs):
            started.set()
            release.wait(3)
            raise RuntimeError("provider unavailable")
        self.index.embeddings = SimpleNamespace(embed=fail)
        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(self.index.query_vector, "retry me")
            self.assertTrue(started.wait(1))
            second = executor.submit(self.index.query_vector, "retry me")
            deadline = time.monotonic() + 1
            while self.index.query_cache_status()["shared"] < 1 and time.monotonic() < deadline:
                time.sleep(0.005)
            release.set()
            for future in (first, second):
                with self.assertRaisesRegex(RuntimeError, "provider unavailable"):
                    future.result(timeout=2)
        self.assertEqual(self.index.query_cache_status()["pending"], 0)
        self.assertEqual(self.index.query_cache_status()["entries"], 0)
        self.index.embeddings = SimpleNamespace(embed=lambda texts, **kwargs: [[0.5]])
        self.assertEqual(self.index.query_vector("retry me"), ([0.5], "miss"))

    def test_query_cache_is_bounded_profile_scoped_and_not_persistent(self):
        calls = []
        def embed(texts, **kwargs):
            calls.append(texts)
            return [[0.125] * 4096]
        self.index.embeddings = SimpleNamespace(embed=embed)
        for number in range(256):
            self.index.query_vector(f"query {number}")
        self.index.query_vector("query 0")  # Most recently used survives eviction.
        self.index.query_vector("query 256")
        self.assertEqual(self.index.query_cache_status()["entries"], 256)
        self.assertEqual(self.index.query_vector("query 0")[1], "hit")
        self.assertEqual(self.index.query_vector("query 1")[1], "miss")
        self.assertEqual(len(calls), 258)
        with patch("mantis_index.PROFILE", "different-model-profile"):
            self.assertEqual(self.index.query_vector("query 0")[1], "miss")
        self.assertEqual(self.index.query_cache_status()["entries"], 256)
        recreated = Index(self.state, self.api, embeddings=self.index.embeddings)
        self.assertEqual(recreated.query_vector("query 0")[1], "miss")
        self.assertEqual(len(calls), 260)

    def test_delta_time_budget_resumes_fetched_progress_without_false_checkpoint(self):
        self.api.items[2] = ticket(2)
        self.state.run("UPDATE projects SET status='current',checkpoint=1")
        original = self.index.refresh
        fetched = []
        now = [0]
        def slow_refresh(issue_id, **kwargs):
            fetched.append(issue_id)
            value = original(issue_id, **kwargs)
            now[0] += 11
            return value
        with patch("mantis_index.time.monotonic", side_effect=lambda: now[0]), patch.object(self.index, "refresh", side_effect=slow_refresh):
            with self.assertRaisesRegex(RuntimeError, "time budget"):
                self.index.sync_project(1)
        self.assertEqual(self.state.one("SELECT checkpoint FROM projects")["checkpoint"], 1)
        self.assertEqual(len(fetched), 1)
        self.index.sync_project(1)
        self.assertEqual(self.state.health()["issues"], 2)
        self.assertEqual(self.state.one("SELECT status FROM projects")["status"], "current")

    def test_old_unchanged_issue_not_reread_on_every_delta_cycle(self):
        self.index.refresh(1)
        self.state.run("UPDATE projects SET status='current',checkpoint=?", (timestamp(ticket()["updated_at"]),))
        self.api.server_time = timestamp("2026-09-29T12:00:00+03:00")
        with patch.object(self.api, "visible_issue", wraps=self.api.visible_issue) as fetch:
            self.index.sync_project(1)
            self.index.sync_project(1)
        fetch.assert_not_called()

    def test_cached_custom_filter_survives_api_outage(self):
        self.api.definitions = [{"field": {"id": 7}}]
        self.api.items[1]["custom_fields"] = [{"field": {"id": 7}, "value": "abc"}]
        self.index.metadata(1)
        self.index.refresh(1)
        self.api.down = True
        result = self.search("решения", filters={"project_id": 1, "custom_fields": {"7": "abc"}})
        self.assertEqual(result["issues"][0]["id"], 1)
        self.assertEqual(self.index.metadata(1)["access_check"], "cached")

    def test_late_attachment_cache_write_cannot_resurrect_revoked_file(self):
        from mantis_runtime import Runtime
        from server import MantisTicketService, Settings
        self.api.items[1]["attachments"] = [{"id": 9, "filename": "secret.txt"}]
        self.index.refresh(1)
        runtime = Runtime.__new__(Runtime)
        runtime.index = self.index
        service = MantisTicketService(Settings("https://mantis.test", "fixture", self.root / "files"), runtime)
        self.state.purge_issue(1)
        self.index.cleanup()
        with self.assertRaises(ApiError):
            service.cache_attachment(1, 9, "secret.txt", b"secret")
        self.assertFalse((self.root / "files" / "1").exists())

    def test_missing_billing_stays_unknown_and_invalid_budget_is_rejected(self):
        from mantis_index import Embeddings
        data = {"data": [{"index": 0, "embedding": [1.0] + [0.0] * 4095}]}
        provider = Embeddings(self.state, "fixture", connection_factory=lambda: FakeEmbeddingConnection(
            lambda request: FakeEmbeddingResponse(data=data)))
        try:
            provider.embed(["test"])
        finally:
            provider.close()
        self.assertEqual(self.state.one("SELECT status FROM charges")["status"], "unknown")
        with self.assertRaises(ValueError):
            Embeddings(self.state, "fixture", cap=float("nan"))

    def test_embedding_errors_keep_reservations_and_expose_safe_categories(self):
        from mantis_index import Embeddings, EmbeddingError
        mode = ["rate"]
        def serve(request):
            if mode[0] == "rate":
                return FakeEmbeddingResponse(429, text="private provider detail")
            raise ConnectionError("private hostname")
        provider = Embeddings(self.state, "fixture", retries=0,
                              connection_factory=lambda: FakeEmbeddingConnection(serve))
        try:
            with self.assertRaises(EmbeddingError) as caught:
                provider.embed(["private search text"])
            self.assertEqual((caught.exception.category, caught.exception.status), ("rate_limited", 429))
            self.assertNotIn("private", str(caught.exception))
            self.assertEqual(self.state.one("SELECT status FROM charges")["status"], "unknown")
            mode[0] = "network"
            with self.assertRaises(EmbeddingError) as caught:
                provider.embed(["another private text"])
            self.assertEqual(caught.exception.category, "network")
            diagnostic = provider.diagnostics()
            self.assertEqual(diagnostic["failures_5m"], {"rate_limited": 1, "network": 1})
            self.assertEqual(diagnostic["last_attempt"]["error_type"], "ConnectionError")
            self.assertNotIn("private", json.dumps(diagnostic))
        finally:
            provider.close()
        self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM charges WHERE status='unknown'")["n"], 2)

    def test_embedding_retry_uses_separate_reservations_and_records_attempts(self):
        from mantis_index import Embeddings
        calls = []
        response = {"data": [{"index": 0, "embedding": [1.0] + [0.0] * 4095}],
                    "usage": {"cost": 0.001}}
        def serve(request):
            calls.append(request)
            if len(calls) == 1:
                raise TimeoutError("private transient detail")
            return FakeEmbeddingResponse(data=response)
        connections = []
        def factory():
            connection = FakeEmbeddingConnection(serve)
            connections.append(connection)
            return connection
        provider = Embeddings(self.state, "fixture", retries=2, connection_factory=factory)
        try:
            self.assertEqual((provider.connect_timeout, provider.timeout), (5, 120))
            with patch("mantis_index.time.sleep"):
                self.assertEqual(len(provider.embed(["test"])[0]), 4096)
            self.assertEqual(len(calls), 2)
            self.assertEqual(connections[0].timeouts, [30, 120])
            rows = self.state.all("SELECT status,actual FROM charges ORDER BY created,id")
            self.assertEqual([row["status"] for row in rows].count("unknown"), 1)
            self.assertEqual([row["status"] for row in rows].count("settled"), 1)
            diagnostic = provider.diagnostics()
            self.assertEqual(diagnostic["attempts_5m"], 2)
            self.assertEqual(diagnostic["failures_5m"], {"timeout": 1})
            self.assertEqual(diagnostic["last_attempt"]["attempt"], 2)
            self.assertGreater(diagnostic["request_bytes_p50"], 0)
            self.assertNotIn("test", json.dumps(diagnostic))
        finally:
            provider.close()

    def test_interactive_embedding_uses_one_short_network_attempt(self):
        from mantis_index import Embeddings, EmbeddingError
        connections = []
        def factory():
            connection = FakeEmbeddingConnection(lambda request: (_ for _ in ()).throw(TimeoutError("slow provider")))
            connections.append(connection)
            return connection
        provider = Embeddings(self.state, "fixture", retries=2, connection_factory=factory)
        try:
            with self.assertRaises(EmbeddingError) as caught:
                provider.embed(["interactive query"], timeout=25, retries=0)
            self.assertEqual(caught.exception.category, "timeout")
            self.assertEqual(len(connections), 1)
            self.assertEqual(connections[0].timeouts, [25, 25])
            self.assertEqual(provider.diagnostics()["attempts_5m"], 1)
        finally:
            provider.close()

    def test_embedding_provider_error_retries_but_invalid_response_does_not(self):
        from mantis_index import Embeddings, EmbeddingError
        calls = []
        response = {"data": [{"index": 0, "embedding": [1.0] + [0.0] * 4095}]}
        def serve(request):
            calls.append(request)
            return FakeEmbeddingResponse(503) if len(calls) == 1 else FakeEmbeddingResponse(data=response)
        provider = Embeddings(self.state, "fixture",
                              connection_factory=lambda: FakeEmbeddingConnection(serve))
        try:
            with patch("mantis_index.time.sleep"):
                provider.embed(["test"])
            self.assertEqual(len(calls), 2)
            self.assertEqual(provider.diagnostics()["failures_5m"], {"provider_unavailable": 1})
        finally:
            provider.close()
        provider = Embeddings(self.state, "fixture", connection_factory=lambda: FakeEmbeddingConnection(
            lambda request: FakeEmbeddingResponse(text="private invalid payload")))
        try:
            with self.assertRaises(EmbeddingError) as caught:
                provider.embed(["private text"])
            self.assertEqual(caught.exception.category, "invalid_response")
            self.assertEqual(provider.diagnostics()["attempts_5m"], 1)
            self.assertNotIn("private", json.dumps(provider.diagnostics()))
        finally:
            provider.close()

    def test_embedding_long_retry_after_returns_to_scheduler(self):
        from mantis_index import Embeddings, EmbeddingError
        calls = []
        def serve(request):
            calls.append(request)
            return FakeEmbeddingResponse(429, headers={"Retry-After": "120"})
        provider = Embeddings(self.state, "fixture",
                              connection_factory=lambda: FakeEmbeddingConnection(serve))
        try:
            with self.assertRaises(EmbeddingError) as caught:
                provider.embed(["test"])
            self.assertEqual(len(calls), 1)
            self.assertEqual(caught.exception.retry_after, 120)
            self.index._embedding_failure(caught.exception)
            self.assertGreaterEqual(self.index.embedding_retry_at - self.state.clock(), 119)
        finally:
            provider.close()

    def test_embedding_worker_backs_off_and_reports_diagnostics(self):
        from mantis_index import EmbeddingError
        self.index.sync_projects = {1}
        self.state.run("UPDATE projects SET status='current',checkpoint=1")
        self.index.refresh(1)
        self.index.vectors = SimpleNamespace(existing=lambda keys: set(), dimension=2, failed=False)
        calls = []
        def denied(texts):
            calls.append(texts)
            raise EmbeddingError("rate_limited", 429)
        self.index.embeddings = SimpleNamespace(embed=denied)
        worker = threading.Thread(target=self.index._embedding_loop)
        worker.start()
        try:
            deadline = time.monotonic() + 2
            while not self.index.embedding_diagnostics()["next_retry_at"] and time.monotonic() < deadline:
                time.sleep(0.01)
        finally:
            self.index.stop.set()
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(calls), 1)
        status = self.index.embedding_diagnostics(detail=True)
        self.assertEqual(status["last_error_category"], "rate_limited")
        self.assertEqual(status["last_error"]["http_status"], 429)
        self.assertEqual(status["consecutive_failures"], 1)
        self.assertGreater(status["next_retry_at"], self.state.clock())

    def test_network_backoff_is_bounded_and_successful_query_unblocks_backfill(self):
        from mantis_index import EmbeddingError
        for _ in range(5):
            self.index._embedding_failure(EmbeddingError("network"))
        self.assertLessEqual(self.index.embedding_retry_at - self.state.clock(), 61)
        self.assertEqual(self.index.embedding_attempts, 5)
        self.index.embeddings = SimpleNamespace(embed=lambda texts, **kwargs: [[0.25, 0.5]])
        self.assertEqual(self.index.query_vector("provider recovered"), ([0.25, 0.5], "miss"))
        self.assertEqual(self.index.embedding_attempts, 0)
        self.assertEqual(self.index.embedding_retry_at, 0)


    def test_embedding_requests_overlap_and_claim_distinct_fragments(self):
        for number in range(1, 9):
            self.state.put_issue(ticket(number, text=f"independent fragment {number}"))
        self.index.vectors = MemoryVectors()
        self.index.embedding_workers = 4
        self.index.embedding_batch = 2
        started, release = threading.Event(), threading.Event()
        calls = []
        lock = threading.Lock()
        def embed(texts, **kwargs):
            with lock:
                calls.append(list(texts))
                if len(calls) == 4:
                    started.set()
            if not release.wait(3):
                raise TimeoutError("fixture release missing")
            return [[0.25, 0.5] for _ in texts]
        self.index.embeddings = SimpleNamespace(embed=embed, timeout=1)
        worker = threading.Thread(target=self.index._embedding_loop)
        worker.start()
        try:
            self.assertTrue(started.wait(2), "Four provider calls should overlap without waiting for Mantis sync")
            self.assertEqual(self.index.embedding_diagnostics()["in_flight_batches"], 4)
            self.assertEqual(len(self.index.embedding_claimed), 8)
        finally:
            self.index.stop.set()
            release.set()
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(self.index.vectors.docs), 8)
        self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)
        self.assertEqual(self.index.embedding_diagnostics()["ready_5m"], 8)

    def test_recent_embedding_lane_protects_fresh_issue_from_old_backlog(self):
        self.state.put_issue(ticket(1, updated="2020-01-01T00:00:00Z"))
        self.state.put_issue(ticket(2, updated="2026-09-29T12:00:00Z"))
        self.index.embedding_batch = 1
        self.assertEqual(self.index._embedding_candidates(recent=True)[0]["issue_id"], 2)
        self.assertEqual(self.index._embedding_candidates(recent=False)[0]["issue_id"], 1)

    def test_embedding_queue_does_not_scan_ready_corpus_when_empty_or_sparse(self):
        self.state.put_issue(ticket(1, updated="2020-01-01T00:00:00Z"))
        self.state.put_issue(ticket(2, text="ready " * 300, updated="2026-09-29T12:00:00Z"))
        with self.state.transaction():
            self.state.run("UPDATE fragments SET vector_version=version")
            for number in range(3, 3003):
                self.state.run("INSERT INTO issues SELECT ?,project_id,modified,data,hash,etag,verified "
                               "FROM issues WHERE id=2", (number,))
                self.state.run("INSERT INTO fragments SELECT ?,?,kind,note_id,file_id,source,text,folded,"
                               "version,vector_version,vector_id FROM fragments "
                               "WHERE issue_id=2 AND kind='description' LIMIT 1", (f"ready:{number}", number))
        for pending in (False, True):
            if pending:
                self.state.run("UPDATE fragments SET vector_version='' WHERE issue_id=1 AND kind='description'")
            for recent in (False, True):
                with self.subTest(pending=pending, recent=recent):
                    steps = 0
                    def instruction_budget():
                        nonlocal steps
                        steps += 1000
                        return int(steps > 10000)
                    self.state.db.set_progress_handler(instruction_budget, 1000)
                    try:
                        rows = self.index._embedding_candidates(recent=recent)
                    finally:
                        self.state.db.set_progress_handler(None, 0)
                    self.assertEqual([r["issue_id"] for r in rows], [1] if pending else [])

    def test_embedding_continues_while_mantis_page_is_slow(self):
        self.index.refresh(1)
        self.index.vectors = MemoryVectors()
        self.index.embeddings = SimpleNamespace(embed=lambda texts, **kwargs: [[0.25, 0.5] for _ in texts], timeout=1)
        entered, release = threading.Event(), threading.Event()
        original = self.api.initial_page
        def slow_page(*args):
            entered.set()
            if not release.wait(3):
                raise TimeoutError("fixture release missing")
            return original(*args)
        self.api.initial_page = slow_page
        self.index.start()
        try:
            self.assertTrue(entered.wait(2))
            deadline = time.monotonic() + 2
            while not self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"] and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertGreater(self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0,
                               "Embedding must progress before the Mantis page returns")
        finally:
            release.set()
            self.index.stop.set()
            self.index.worker.join(timeout=3)
            self.index.embedding_worker.join(timeout=3)
        self.assertFalse(self.index.worker.is_alive())
        self.assertFalse(self.index.embedding_worker.is_alive())

    def test_revoked_inflight_fragment_is_never_published(self):
        self.index.refresh(1)
        self.index.vectors = MemoryVectors()
        entered, release = threading.Event(), threading.Event()
        def embed(texts, **kwargs):
            entered.set()
            if not release.wait(3):
                raise TimeoutError("fixture release missing")
            return [[0.25, 0.5] for _ in texts]
        self.index.embeddings = SimpleNamespace(embed=embed)
        with ThreadPoolExecutor(max_workers=1) as pool:
            self.assertTrue(self.index._dispatch_embedding(pool))
            future = next(iter(self.index.embedding_inflight))
            self.assertTrue(entered.wait(1))
            self.state.purge_issue(1)
            release.set()
            self.index._publish_embedding(future)
        self.index._flush_due_embeddings(force=True)
        self.assertFalse(self.index.vectors.docs)
        self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)

    def test_slow_vector_flush_does_not_block_search_or_publish_revoked_source(self):
        self.index.refresh(1)
        entered, release = threading.Event(), threading.Event()
        class SlowVectors(MemoryVectors):
            def upsert_batch(self, rows):
                entered.set()
                if not release.wait(3):
                    raise TimeoutError("fixture release missing")
                super().upsert_batch(rows)
        self.index.vectors = SlowVectors()
        row = self.state.one("SELECT id,version FROM fragments WHERE kind='description' LIMIT 1")
        key = digest([row["id"], row["version"]])
        self.state.run("INSERT INTO embedding_spool VALUES(?,?,?,?)",
                       (row["id"], row["version"], array("f", [0.25, 0.5]).tobytes(), self.state.clock()))
        with ThreadPoolExecutor(max_workers=2) as pool:
            flushed = pool.submit(self.index.flush_embedding_spool)
            try:
                self.assertTrue(entered.wait(1))
                result = pool.submit(self.index.search, "решения", semantic=False).result(timeout=2)
                self.assertEqual(result["issues"][0]["id"], 1)
                cache = self.root / "files" / "1"
                cache.mkdir(parents=True)
                (cache / "9-secret.txt").write_text("revoked", encoding="utf-8")
                self.state.purge_issue(1)
                self.assertFalse(self.index.cleanup(), "Physical cleanup must wait for the active flush")
                self.assertFalse(cache.exists(), "Revoked attachment cache must be erased even while Zvec flushes")
            finally:
                release.set()
            self.assertEqual(flushed.result(timeout=2), 0)
        self.assertFalse(self.state.all("SELECT * FROM fragments WHERE issue_id=1"))
        self.assertIsNone(self.state.one("SELECT * FROM embedding_spool WHERE fragment_id=?", (row["id"],)))
        self.assertIsNone(self.state.one("SELECT * FROM fragments WHERE vector_id=?", (key,)))
        self.assertIsNotNone(self.state.one("SELECT * FROM vector_deletes WHERE id=?", (key,)))

    def test_crash_after_vector_flush_replays_paid_spool_without_new_embedding(self):
        self.index.refresh(1)
        self.index.vectors = MemoryVectors()
        row = self.state.one("SELECT id,version FROM fragments WHERE kind='description' LIMIT 1")
        self.state.run("INSERT INTO embedding_spool VALUES(?,?,?,?)",
                       (row["id"], row["version"], array("f", [0.25, 0.5]).tobytes(), self.state.clock()))
        with patch.object(self.state, "transaction", side_effect=OSError("simulated crash after Zvec flush")):
            with self.assertRaisesRegex(OSError, "simulated crash"):
                self.index.flush_embedding_spool()
        self.assertEqual(len(self.index.vectors.docs), 1)
        self.assertIsNotNone(self.state.one("SELECT * FROM embedding_spool WHERE fragment_id=?", (row["id"],)))
        self.assertEqual(self.index.flush_embedding_spool(), 1)
        self.assertEqual(len(self.index.vectors.docs), 1)
        self.assertEqual(self.state.one("SELECT vector_version FROM fragments WHERE id=?", (row["id"],))["vector_version"], row["version"])

    def test_pause_waits_for_inflight_result_and_flushes_paid_vector(self):
        self.index.refresh(1)
        self.index.vectors = MemoryVectors()
        entered, release = threading.Event(), threading.Event()
        calls = []
        def embed(texts, **kwargs):
            calls.append(texts)
            entered.set()
            if not release.wait(3):
                raise TimeoutError("fixture release missing")
            return [[0.25, 0.5] for _ in texts]
        self.index.embeddings = SimpleNamespace(embed=embed, timeout=1)
        worker = threading.Thread(target=self.index._embedding_loop)
        worker.start()
        try:
            self.assertTrue(entered.wait(2))
            with self.index.embedding_lock:
                self.index.paused.set()
            self.assertTrue(self.index.embedding_active())
            release.set()
            deadline = time.monotonic() + 2
            while self.index.embedding_active() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(self.index.embedding_active())
            self.assertTrue(self.index.vectors.docs)
            self.assertEqual(self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)
            self.assertEqual(len(calls), 1)
        finally:
            self.index.stop.set()
            release.set()
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())

    def test_one_network_failure_does_not_stall_other_embedding_batches(self):
        from mantis_index import EmbeddingError
        for number in range(1, 5):
            self.state.put_issue(ticket(number, text=f"body {number}"))
        self.index.vectors = MemoryVectors()
        self.index.embedding_workers = 2
        self.index.embedding_batch = 1
        calls = []
        lock = threading.Lock()
        def embed(texts, **kwargs):
            with lock:
                calls.append(texts)
                first = len(calls) == 1
            if first:
                raise EmbeddingError("timeout")
            return [[0.25, 0.5]]
        self.index.embeddings = SimpleNamespace(embed=embed, timeout=1)
        worker = threading.Thread(target=self.index._embedding_loop)
        worker.start()
        try:
            deadline = time.monotonic() + 2
            while not self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"] and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertGreater(self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)
            self.assertGreaterEqual(len(calls), 2)
            self.assertLessEqual(self.index.embedding_retry_at, self.state.clock())
        finally:
            self.index.stop.set()
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertTrue(self.index.vectors.docs)

    def test_parallel_budget_reservations_share_one_limit(self):
        def reserve(_):
            try:
                self.state.reserve(0.3, 0.5)
                return "reserved"
            except RuntimeError:
                return "budget"
        with ThreadPoolExecutor(max_workers=4) as pool:
            outcomes = list(pool.map(reserve, range(4)))
        self.assertEqual(outcomes.count("reserved"), 1)
        self.assertEqual(outcomes.count("budget"), 3)
        self.assertLessEqual(self.state.health()["cost"][0]["accounted_usd"], 0.5)

    def test_extended_filters_sorting_and_participant_resolution(self):
        first = self.api.items[1]
        first.update(handler={"id": 10}, priority={"id": 30}, severity={"id": 50},
                     version="5.1", target_version="5.2", fixed_in_version="")
        second = ticket(2, updated="2026-09-29T12:00:00+03:00")
        second["created_at"] = "1999-01-01T00:00:00+03:00"
        second.update(handler={"id": 11}, priority={"id": 30}, severity={"id": 50},
                      version="5.1", target_version="5.3", fixed_in_version="")
        self.api.items[2] = second
        self.index.refresh(1)
        self.index.refresh(2)
        result = self.search("решения", filters={"handler_id": 10, "reporter_id": 3025,
                         "priority": 30, "severity": 50, "version": "5.1", "target_version": "5.2"})
        self.assertEqual([i["id"] for i in result["issues"]], [1])
        recent = self.search("решения", sort_by="updated_at")
        created = self.search("решения", sort_by="created_at")
        self.assertEqual([i["id"] for i in recent["issues"]], [2, 1])
        self.assertEqual([i["id"] for i in created["issues"]], [1, 2])
        with self.assertRaisesRegex(ValueError, "Unsupported filters"):
            self.search("решения", filters={"unknown": 1})
        with self.assertRaisesRegex(ValueError, "sort_by"):
            self.search("решения", sort_by="anything")
        page = self.index.project_participants(1, "Иван", limit=1)
        self.assertEqual(page["participants"][0]["id"], 10)
        self.assertTrue(page["next_cursor"])
        follow = self.index.project_participants(1, "Иван", limit=1, cursor=page["next_cursor"])
        self.assertEqual(follow["participants"][0]["id"], 11)

    def test_similar_issue_uses_source_text_excludes_self_and_falls_back(self):
        self.api.items[2] = ticket(2, text="Описание решения для похожего обращения")
        self.index.refresh(1)
        self.index.refresh(2)
        result = self.search("", similar_to=1)
        self.assertEqual(result["similar_to"], 1)
        self.assertEqual(result["similarity_mode"], "lexical_fallback")
        self.assertNotIn(1, {issue["id"] for issue in result["issues"]})
        self.assertIn(2, {issue["id"] for issue in result["issues"]})
        with self.assertRaisesRegex(ValueError, "either query or similar_to"):
            self.search("both", similar_to=1)
        del self.api.items[1]
        with self.assertRaises(ApiError):
            self.search("", similar_to=1)

    def test_moving_pages_retain_checkpoint_then_converge(self):
        self.api.items = {n: ticket(n) for n in range(1, 122)}
        self.state.run("UPDATE projects SET status='current',checkpoint=1")
        def move(page, scan):
            if scan == 2:
                self.api.items[1]["updated_at"] = "2026-09-28T12:30:00+03:00"
        self.api.page_hook = move
        with self.assertRaisesRegex(RuntimeError, "pagination moved"):
            self.index.sync_project(1)
        self.assertEqual(self.state.one("SELECT checkpoint FROM projects")["checkpoint"], 1)
        self.api.page_hook = None
        self.index.sync_project(1)
        self.assertEqual(self.state.health()["issues"], 121)

    def test_full_text_filenames_and_no_file_content(self):
        name = "Длинное имя " + "я" * 190 + ".txt"
        self.api.items[1]["notes"] = [{"id": 7, "text": "а" * 17000 + " поздниймаркер", "attachments": [{"id": 9, "filename": name, "content": "SECRETBODY"}]}]
        self.index.refresh(1)
        result = self.search("поздниймаркер")["issues"][0]
        self.assertEqual(result["matches"][0]["note_id"], 7)
        self.assertEqual(self.search("Длинное имя")["issues"][0]["matches"][0]["filename"], name)
        self.assertNotIn("SECRETBODY", self.state.one("SELECT data FROM issues")["data"])
        self.assertFalse(self.search("SECRETBODY")["issues"])
        print("Mantis UTF-8: путь с пробелом / original имя.txt")

    def test_attachment_content_search_survives_issue_edit_and_obeys_revocation(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "sample.xlsx", "size": 120}]
        self.index.refresh(1)
        info = file_descriptors(self.api.items[1])[91]
        self.assertTrue(self.state.publish_attachment(1, 91, info["descriptor"], "sha-fixture",
            {"status": "ready", "segments": [{"location": {"sheet": "План", "cell": "B4"},
                "text": "уникальныйтексттаблицы"}]}))
        match = self.search("уникальныйтексттаблицы", mode="attachment_contents")["issues"][0]["matches"][0]
        self.assertEqual(match["file_id"], 91)
        self.assertEqual(match["location"], {"sheet": "План", "cell": "B4"})
        self.assertIn("file_download.php?file_id=91", match["file_url"])
        fallback = self.index.search("уникальныйтексттаблицы", mode="attachment_contents", semantic=True)
        self.assertTrue(fallback["issues"])
        self.assertEqual(fallback["semantic_query"], "unavailable")
        self.api.items[1]["description"] = "Unrelated issue edit"
        self.index.refresh(1)
        self.assertEqual(self.state.attachment_status()["ready"], 1)
        self.assertTrue(self.search("уникальныйтексттаблицы", mode="attachment_contents")["issues"])
        self.api.items[1]["attachments"] = []
        self.index.refresh(1)
        self.assertFalse(self.search("уникальныйтексттаблицы", mode="attachment_contents")["issues"])
        self.assertEqual(self.state.attachment_status()["ready"], 0)

    def test_extraction_worker_reuses_unchanged_file_after_restart(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "sample.pdf", "size": 24}]
        self.api.files[91] = {"id": 91, "content": base64.b64encode(b"pdf-fixture").decode()}
        self.index.refresh(1)
        self.index.attachment_enabled = True
        parsed = {"status": "ready", "segments": [{"location": {"page": 1}, "text": "текстизвлечённогофайла"}]}
        process = SimpleNamespace(returncode=0, stdout=json.dumps(parsed, ensure_ascii=False).encode(), stderr=b"")
        with patch("mantis_index.subprocess.run", return_value=process) as runner:
            self.assertEqual(self.index.extract_pending(), 1)
            self.assertEqual(self.state.attachment_status()["ready"], 1)
            self.state.close()
            self.state = State(self.root / "state", self.root / "files")
            self.index = Index(self.state, self.api)
            self.index.attachment_enabled = True
            self.api.items[1]["description"] = "Unrelated edit"
            self.index.refresh(1)
            self.assertEqual(self.index.extract_pending(), 0)
            self.assertEqual(runner.call_count, 1)
        with self.state.transaction():
            self.state._remove_fragments(self.state.all(
                "SELECT * FROM fragments WHERE kind='attachment_content' AND issue_id=1"))
            self.state.changed()
        self.assertTrue(self.state.rehydrate_attachment())
        self.assertTrue(self.search("текстизвлечённогофайла", mode="attachment_contents")["issues"])

    def test_attachment_rehydration_uses_issue_index(self):
        # A global kind scan is repeated for every ready attachment and held
        # the state lock for minutes on the production corpus.
        plan = self.state.all("EXPLAIN QUERY PLAN " + REHYDRATE_ATTACHMENT_QUERY)
        self.assertTrue(any("SEARCH f USING INDEX fragments_issue" in row["detail"]
                            for row in plan), plan)

    def test_missing_mantis_file_bytes_are_visible_and_retried_after_recovery(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "old.docx", "size": 12}]
        self.api.files[91] = {"id": 91, "filename": "old.docx", "size": 12}
        self.index.refresh(1)
        self.index.attachment_enabled = True
        self.assertEqual(self.index.extract_pending(), 1)
        self.assertEqual(self.state.attachment_status()["source_unavailable"], 1)
        self.assertEqual(self.state.attachment_status()["pending"], 0)
        self.assertIsNone(self.state.next_attachment())
        self.assertFalse(self.search("восстановленныйдокумент", mode="attachment_contents")["issues"])

        self.api.files[91]["content"] = base64.b64encode(b"docx-fixture").decode()
        self.state.run("UPDATE attachment_extracts SET retry_at=0 WHERE file_id=91")
        parsed = {"status": "ready", "segments": [{"location": {"paragraph": 1},
            "text": "восстановленныйдокумент"}]}
        child = SimpleNamespace(returncode=0, stdout=json.dumps(parsed, ensure_ascii=False).encode(), stderr=b"")
        with patch("mantis_index.subprocess.run", return_value=child):
            self.assertEqual(self.index.extract_pending(), 1)
        self.assertEqual(self.state.attachment_status()["source_unavailable"], 0)
        self.assertEqual(self.state.attachment_status()["ready"], 1)
        self.assertTrue(self.search("восстановленныйдокумент", mode="attachment_contents")["issues"])

    def test_attachment_queue_alternates_new_and_due_retry_work(self):
        self.api.items[1]["attachments"] = [
            {"id": 91, "filename": "old.pdf", "size": 12},
            {"id": 92, "filename": "new.pdf", "size": 12},
        ]
        self.index.refresh(1)
        self.state.retry_attachment(1, 91, "previous_failure", delay=0)
        self.assertEqual(self.state.next_attachment()["file_id"], 92)
        self.assertEqual(self.state.next_attachment(retry_first=True)["file_id"], 91)

    def test_unrelated_attachment_import_does_not_invalidate_content_page(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "first.pdf", "size": 12}]
        self.api.items[2] = ticket(2, text="Other issue")
        self.api.items[2]["attachments"] = [{"id": 92, "filename": "second.pdf", "size": 12}]
        self.index.refresh(1)
        self.index.refresh(2)
        first = file_descriptors(self.api.items[1])[91]
        second = file_descriptors(self.api.items[2])[92]
        self.state.publish_attachment(1, 91, first["descriptor"], "sha-first",
            {"status": "ready", "segments": [{"location": {"page": 1}, "text": "уникальныйпервый"}]})
        original = self.index.refresh
        imported = [False]
        def concurrent_import(issue_id, *args, **kwargs):
            if not imported[0]:
                imported[0] = True
                self.state.publish_attachment(2, 92, second["descriptor"], "sha-second",
                    {"status": "ready", "segments": [{"location": {"page": 1}, "text": "другойфайл"}]})
            return original(issue_id, *args, **kwargs)
        with patch.object(self.index, "refresh", side_effect=concurrent_import):
            result = self.index.search("уникальныйпервый", mode="attachment_contents", semantic=False)
        self.assertTrue(result["ok"])
        self.assertEqual([issue["id"] for issue in result["issues"]], [1])

    def test_removed_matching_attachment_invalidates_content_page(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "first.pdf", "size": 12}]
        self.index.refresh(1)
        info = file_descriptors(self.api.items[1])[91]
        self.state.publish_attachment(1, 91, info["descriptor"], "sha-first",
            {"status": "ready", "segments": [{"location": {"page": 1}, "text": "уникальныйпервый"}]})
        original = self.index.refresh
        def revoke_during_search(issue_id, *args, **kwargs):
            self.state.drop_attachment(1, 91)
            return original(issue_id, *args, **kwargs)
        with patch.object(self.index, "refresh", side_effect=revoke_during_search):
            result = self.index.search("уникальныйпервый", mode="attachment_contents", semantic=False)
        self.assertEqual(result["status"], "results_changed")

    def test_timed_out_parser_is_bounded_and_does_not_publish_text(self):
        self.api.items[1]["attachments"] = [{"id": 91, "filename": "sample.pdf", "size": 20}]
        self.api.files[91] = {"id": 91, "content": base64.b64encode(b"pdf-fixture").decode()}
        self.index.refresh(1)
        self.index.attachment_enabled = True
        with patch("mantis_index.subprocess.run", side_effect=subprocess.TimeoutExpired("parser", 20)):
            self.assertEqual(self.index.extract_pending(), 1)
        self.assertEqual(self.state.attachment_status()["failed"], 1)
        self.assertFalse(self.state.all("SELECT id FROM fragments WHERE kind='attachment_content'"))

    def test_unchanged_fragments_and_status_do_not_reembed(self):
        self.index.refresh(1)
        self.state.run("UPDATE fragments SET vector_version=version,vector_id=id")
        self.api.items[1]["status"] = {"id": 50}
        self.index.refresh(1)
        self.assertEqual(self.state.health()["embedding_backlog"], 0)
        self.api.items[1]["description"] += " edited"
        self.index.refresh(1)
        self.assertEqual(self.state.health()["embedding_backlog"], 1)

    def test_new_fragment_write_cost_does_not_scan_the_existing_corpus(self):
        def measured(issue):
            steps = [0]
            def progress():
                steps[0] += 100
                return 0
            self.state.db.set_progress_handler(progress, 100)
            try:
                self.state.put_issue(issue)
            finally:
                self.state.db.set_progress_handler(None, 0)
            return steps[0]
        baseline = measured(ticket(10001, text="new marker " * 400))
        for issue_id in range(10, 510):
            self.state.put_issue(ticket(issue_id, text="background content"))
        populated = measured(ticket(10002, text="new marker " * 400))
        self.assertLess(populated, baseline * 4 + 2000,
                        "A new issue must not scan every existing FTS row for each fragment")
        self.assertEqual(len(self.state.all('SELECT id FROM search_text WHERE search_text MATCH ?', ('"marker"',))), 6)
        self.assertEqual(self.state.health()["issues"], 502)

    def test_bulk_fragment_edit_preserves_other_issues_and_revokes_old_vectors(self):
        self.index.refresh(1)
        changed = ticket(2, text="oldmarker " * 1800)
        self.state.put_issue(changed)
        self.state.run("UPDATE fragments SET vector_id=id,vector_version=version WHERE issue_id=2")
        old = self.state.all("SELECT * FROM fragments WHERE issue_id=2 AND kind='description'")
        changed["description"] = "newmarker " * 1800
        self.state.put_issue(changed)
        self.assertFalse(self.state.all('SELECT id FROM search_text WHERE search_text MATCH ?', ('"oldmarker"',)))
        self.assertTrue(self.state.all('SELECT id FROM search_text WHERE search_text MATCH ?', ('"newmarker"',)))
        self.assertEqual(len(self.state.all("SELECT * FROM vector_deletes")), len(old))
        self.assertEqual(self.search("решения")["issues"][0]["id"], 1)

    def test_initial_import_budget_resumes_without_advancing_an_incomplete_page(self):
        self.api.items = {n: ticket(n) for n in range(1, 5)}
        original = self.state.put_issue
        written, now = [], [0]
        def slow_put(issue, *args, **kwargs):
            result = original(issue, *args, **kwargs)
            written.append(issue["id"])
            now[0] += 11
            return result
        with patch("mantis_index.time.monotonic", side_effect=lambda: now[0]), patch.object(self.state, "put_issue", side_effect=slow_put):
            for expected in range(1, 5):
                self.index.sync_project(1)
                self.assertEqual(len(written), expected)
                if expected < 4:
                    self.assertEqual(self.state.one("SELECT import_verify FROM projects WHERE id=1")["import_verify"], 0)
        self.assertEqual(len(set(written)), 4, "Do not starve behind the already imported prefix")
        self.assertEqual(self.state.one("SELECT import_verify FROM projects WHERE id=1")["import_verify"], 1)

    def test_unrelated_import_does_not_invalidate_a_completed_search(self):
        self.index.refresh(1)
        original = self.index.refresh
        def concurrent_import(issue_id, *args, **kwargs):
            self.state.put_issue(ticket(99, text="unrelated corpus addition"))
            return original(issue_id, *args, **kwargs)
        with patch.object(self.index, "refresh", side_effect=concurrent_import):
            result = self.index.search("решения", semantic=False)
        self.assertTrue(result["ok"])
        self.assertEqual([issue["id"] for issue in result["issues"]], [1])

    def test_compact_search_does_not_load_unmatched_comment_bodies(self):
        self.api.items[1]["summary"] = "needle"
        self.api.items[1]["notes"] = [{"id": 9, "text": "unrelated history " * 10000}]
        self.index.refresh(1)
        original = SearchReader.all
        loaded = [0]
        def measured(reader, sql, args=()):
            rows = original(reader, sql, args)
            loaded[0] += len(json.dumps(rows, ensure_ascii=False))
            return rows
        with patch.object(SearchReader, "all", measured), patch.object(self.index, "refresh", return_value=(None, "", True)):
            result = self.index.search("needle", semantic=False)
        self.assertEqual([item["id"] for item in result["issues"]], [1])
        self.assertLess(loaded[0], 20000, "A compact card must not materialize the issue's unrelated history")

    def test_tag_rename_during_search_invalidates_filter_selection(self):
        self.api.items[1]["tags"] = [{"id": 7}]
        self.index.refresh(1)
        self.state.put_catalog("tags", [{"id": 7, "name": "old"}])
        original = self.index.refresh
        def rename(issue_id, *args, **kwargs):
            self.state.put_catalog("tags", [{"id": 7, "name": "new"}])
            return original(issue_id, *args, **kwargs)
        with patch.object(self.index, "refresh", side_effect=rename):
            result = self.index.search("решения", filters={"tags": ["old"]}, semantic=False)
        self.assertEqual(result["status"], "results_changed")

    def test_outage_has_no_ttl_and_partial_page_no_tombstone(self):
        self.index.refresh(1)
        self.api.down = True
        self.state.run("UPDATE issues SET verified=0")
        self.assertEqual(self.search("решения")["issues"][0]["id"], 1)
        self.assertEqual(self.index.remote_status, "unavailable")
        self.assertFalse(self.state.all("SELECT * FROM tombstones"))

    def test_confirmed_revoke_clears_text_file_and_journal(self):
        self.index.refresh(1)
        directory = self.root / "files" / "1"
        directory.mkdir(parents=True)
        (directory / "9-original.txt").write_text("secret", encoding="utf-8")
        self.writer.prepare("operation01", "analyst", [{"action": "add_comment", "issue_id": 1, "fields": {"text": "confidential"}}])
        del self.api.items[1]
        with self.assertRaises(ApiError):
            self.index.refresh(1)
        self.assertFalse(directory.exists())
        self.assertFalse(self.state.all("SELECT * FROM fragments"))
        row = self.state.one("SELECT * FROM operations")
        self.assertEqual(row["payload"], "{}")
        self.assertEqual(row["actor"], "analyst")
        self.api.items[1] = ticket(text="new scope")
        self.index.refresh(1)
        self.assertEqual(self.state.health()["issues"], 1)

    def test_silent_deleted_file_is_removed_on_refresh(self):
        self.api.items[1]["attachments"] = [{"id": 9, "filename": "obsolete.txt"}]
        self.index.refresh(1)
        directory = self.root / "files" / "1"
        directory.mkdir(parents=True)
        (directory / "9-obsolete.txt").write_bytes(b"old")
        self.api.items[1]["attachments"] = []
        result = self.index.search("obsolete", semantic=False)
        self.assertEqual(result["status"], "results_changed")
        self.index.cleanup()
        self.assertFalse((directory / "9-obsolete.txt").exists())
        self.assertFalse(self.search("obsolete")["issues"])

    def test_revoked_text_is_absent_from_managed_sqlite_bytes(self):
        secret = "CONFIDENTIAL_SOURCE_9172836490"
        self.api.items[1]["description"] = secret
        self.index.refresh(1)
        self.state.purge_issue(1)
        self.index.cleanup()
        self.assertNotIn(secret.encode(), (self.root / "state" / "mantis.sqlite").read_bytes())
        self.assertNotIn(secret.lower().encode(), (self.root / "state" / "mantis.sqlite").read_bytes().lower())

    def test_api_private_note_file_guard_and_missing_lists(self):
        api = Api(SimpleNamespace(validate=lambda: None, base_url="https://mantis.test", api_token="fixture", timeout_seconds=1))
        issue = ticket()
        issue["notes"] = [{"id": 7, "view_state": {"id": 50}, "attachments": [{"id": 9}]}]
        issue["attachments"] = [{"id": 9}, {"id": 10, "bugnote_id": 7}]
        self.api.level = 25
        with patch.object(api, "request", return_value=({"issues": [issue]}, "full-etag")), patch.object(api, "context", return_value=self.api.context(1)):
            visible, etag = api.visible_issue(1)
        self.assertEqual(visible["notes"], [])
        self.assertEqual(visible["attachments"], [])
        self.assertEqual(etag, "full-etag")
        with patch.object(api, "request", return_value=({"issues": [{**ticket(), "notes": None, "attachments": None,
                                                                        "relationships": None}]}, "")):
            issue = api.issue(1)[0]
            self.assertEqual(issue["notes"], [])
            self.assertEqual(issue["relationships"], [])

    def test_attachment_api_response_is_capped_before_json_decode(self):
        api = Api(SimpleNamespace(validate=lambda: None, base_url="https://mantis.test", api_token="fixture", timeout_seconds=1))
        class Response(io.BytesIO):
            headers = {}
        with patch.object(api.opener, "open", return_value=Response(b"x" * 101)):
            with self.assertRaisesRegex(ApiError, "extraction limit"):
                api.request("issues/1/files/9", max_response_bytes=100)

    def test_parent_import_keeps_child_only_page_and_never_uses_parent_acl_for_children(self):
        api = Api(SimpleNamespace(validate=lambda: None, base_url="https://mantis.test", api_token="fixture", timeout_seconds=1))
        children = [ticket(n, project=2) for n in range(2, 102)]
        own = ticket(updated="2020-01-01T00:00:00Z")
        self.api.items = {1: own, **{r["id"]: r for r in children}}
        self.state.put_issue(children[0])  # Existing child data must not be purged.
        self.state.run("UPDATE projects SET error='previous page failed' WHERE id=1")
        pages = [children, [own]]
        def response(path):
            page = int(parse_qs(urlsplit(path).query)["page"][0])
            return {"issues": copy.deepcopy(pages[page - 1]) if page <= 2 else []}, ""
        self.index.api = api
        with patch.object(api, "request", side_effect=response), patch.object(api, "context", return_value=self.api.context(1)) as context, patch.object(api, "visible_issue", side_effect=self.api.visible_issue) as visible:
            self.index.sync_project(1)
            self.assertEqual(self.state.one("SELECT import_page,error FROM projects WHERE id=1"), {"import_page": 2, "error": ""})
            self.assertEqual(self.state.health()["issues"], 1)
            self.index.sync_project(1)
            self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=1"))
            for _ in range(2):  # Compact verification agrees with the full import.
                self.index.sync_project(1)
            self.assertEqual(self.state.one("SELECT status FROM projects WHERE id=1")["status"], "catching_up")
            self.assertTrue(all(call.args == (1,) for call in visible.call_args_list))
            self.assertTrue(all(call.args == (1,) for call in context.call_args_list))
        self.assertEqual(self.state.health()["issues"], 2)
        self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=2"))

    def test_parent_delta_preserves_raw_pages_but_fetches_only_its_own_issues(self):
        own = ticket(updated="2026-09-28T11:59:00+03:00")
        children = [ticket(n, project=2) for n in range(2, 102)]
        self.api.items = {1: own, **{r["id"]: r for r in children}}
        self.state.run("UPDATE projects SET status='current',checkpoint=? WHERE id=1", (timestamp(own["updated_at"]),))
        with patch.object(self.api, "headers", side_effect=lambda project, page, size: copy.deepcopy(children if page == 1 else [own] if page == 2 else [])), patch.object(self.api, "visible_issue", wraps=self.api.visible_issue) as visible:
            self.index.sync_project(1)
            visible.assert_called_once_with(1)
        self.assertEqual(self.state.health()["issues"], 1)
        self.assertEqual(self.state.one("SELECT checkpoint,status FROM projects WHERE id=1"), {"checkpoint": timestamp(children[0]["updated_at"]), "status": "current"})

    def test_create_reconciliation_does_not_adopt_matching_child_issue(self):
        child = ticket(2, project=2)
        self.api.items[2] = child
        with patch.object(self.api, "headers", return_value=[child]), patch.object(self.api, "visible_issue", wraps=self.api.visible_issue) as visible:
            result = self.writer.reconcile({"action": "create_issue", "project_id": 1, "fields": {"summary": child["summary"]}}, {"user_id": 3025}, 0)
            self.assertIsNone(result)
            visible.assert_not_called()

    def test_read_only_rollback_also_checks_file_parent(self):
        from server import MantisClient, Settings, MantisApiError
        client = MantisClient(Settings("https://mantis.test", "fixture", self.root / "files"))
        with patch.object(client, "get_issue", return_value={**ticket(), "notes": None}), patch.object(client, "request_json") as request:
            with self.assertRaises(MantisApiError):
                client.get_issue_file(1, 999)
        request.assert_not_called()

    def test_private_reporter_exception_matches_mantis_access_contract(self):
        self.api.level = 25
        issue = {**ticket(), "view_state": {"id": 50}, "notes": [
            {"id": 7, "text": "own", "view_state": {"id": 50}, "reporter": {"id": 3025}},
            {"id": 8, "text": "other", "view_state": {"id": 50}, "reporter": {"id": 123}}]}
        visible = Api.filter_visible(issue, self.api.context(1))
        self.assertEqual([n["id"] for n in visible["notes"]], [7])

    def test_foreign_state_directory_is_not_modified(self):
        foreign = self.root / "foreign"
        foreign.mkdir()
        sentinel = foreign / "bookstack.sqlite"
        sentinel.write_bytes(b"unchanged")
        with self.assertRaisesRegex(RuntimeError, "separate empty"):
            State(foreign, self.root / "files")
        self.assertEqual(list(foreign.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"unchanged")

    def test_stale_cache_survives_failed_access_confirmation(self):
        self.index.refresh(1)
        with patch.object(self.api, "visible_issue", side_effect=ApiError("forbidden", 403)), patch.object(self.api, "confirm_absence", side_effect=ApiError("auth unavailable", 401)):
            _, _, stale = self.index.refresh(1)
        self.assertTrue(stale)
        self.assertFalse(self.state.all("SELECT * FROM tombstones"))

    def test_manual_resolution_selects_one_ambiguous_note(self):
        self.api.lost = self.api.duplicate = True
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "x"}}]
        self.writer.execute("operation01", "analyst", steps)
        self.api.lost = False
        self.writer.execute("operation01", "analyst", steps)
        result = self.writer.resolve("operation01", 0, "analyst", "applied", 100)
        self.assertEqual(result["steps"][0]["result"]["note_id"], 100)
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "succeeded")
        self.assertEqual(len(self.api.sent), 1)

    def test_new_project_does_not_reset_existing(self):
        self.index.sync_project(1)
        self.index.sync_project(1)
        previous = self.state.one("SELECT checkpoint FROM projects WHERE id=1")["checkpoint"]
        self.api.project_list.append({"id": 2})
        self.api.items[2] = ticket(2, project=2)
        self.index.catalogs()
        self.index.sync_project(2)
        self.assertEqual(self.state.one("SELECT checkpoint FROM projects WHERE id=1")["checkpoint"], previous)
        self.assertEqual(self.state.health()["issues"], 2)

    def test_budget_reserves_unknown_across_month_boundary(self):
        self.state.clock = lambda: 1704067200
        first = self.state.reserve(4, 5)
        with self.assertRaises(RuntimeError):
            self.state.reserve(2, 5)
        self.state.clock = lambda: 1706745600
        with self.assertRaises(RuntimeError):
            self.state.reserve(2, 5)
        self.state.settle(first, 0.5)
        self.state.reserve(2, 5)

    def test_project_status_tag_and_date_filters(self):
        self.api.items[1]["tags"] = [{"id": 1, "name": "old"}]
        self.index.refresh(1)
        self.assertTrue(self.search("решения", filters={"project_id": 1, "status": 90, "tags": ["renamed"], "created_before": "2001-01-01T00:00:00Z"})["issues"])
        self.assertFalse(self.search("решения", filters={"status": 10})["issues"])
        with self.assertRaises(ValueError):
            self.search("x", filters={"made_up": True})

    def test_grouping_pagination_survives_source_changes_without_repeats(self):
        for n in range(1, 4):
            self.api.items[n] = ticket(n)
            self.api.items[n]["notes"] = [{"id": 100 + n, "text": "решения комментарий"}]
            self.index.refresh(n)
        first = self.search("решения", limit=1)
        second = self.search("решения", limit=1, cursor=first["next_cursor"])
        self.assertNotEqual(first["issues"][0]["id"], second["issues"][0]["id"])
        self.assertEqual(len(self.search("решения")["issues"]), 3)
        self.api.items[1]["description"] += " changed"
        self.index.refresh(1)
        self.api.items[4] = ticket(4, text="решения newly indexed")
        self.index.refresh(4)
        third = self.search("решения", limit=1, cursor=second["next_cursor"])
        self.assertTrue(third["ok"])
        self.assertNotIn(third["issues"][0]["id"], {first["issues"][0]["id"], second["issues"][0]["id"]})
        with self.assertRaisesRegex(ValueError, "restart"):
            self.search("other query", cursor=third["next_cursor"])
        with self.assertRaisesRegex(ValueError, "restart"):
            self.search("решения", cursor=first["next_cursor"])

    def test_search_cursor_survives_vector_progress_in_both_modes(self):
        for issue_id in range(1, 4):
            self.api.items[issue_id] = ticket(issue_id, text="needle")
            self.index.refresh(issue_id)
        lexical = self.index.search("needle", semantic=False, limit=1)
        self.assertTrue(lexical["next_cursor"])
        source_revision = self.state.source_revision()
        self.state.changed(source=False)
        self.assertEqual(self.state.source_revision(), source_revision)
        following = self.index.search("needle", semantic=False, limit=1, cursor=lexical["next_cursor"])
        self.assertTrue(following["ok"])
        self.assertNotEqual(following["issues"][0]["id"], lexical["issues"][0]["id"])

        self.index.vectors = SimpleNamespace(query=lambda vector: [], purge=lambda: None)
        self.index.embeddings = SimpleNamespace()
        with patch.object(self.index, "query_vector", return_value=([0], "hit")):
            semantic = self.index.search("needle", semantic=True, limit=1)
            self.assertEqual(semantic["semantic_query"], "available")
            self.state.changed(source=False)
            next_semantic = self.index.search("needle", semantic=True, limit=1, cursor=semantic["next_cursor"])
            self.assertTrue(next_semantic["ok"])
            self.assertNotEqual(next_semantic["issues"][0]["id"], semantic["issues"][0]["id"])

    def test_search_cursor_is_bounded_and_expires(self):
        for issue_id in range(1, 4):
            self.api.items[issue_id] = ticket(issue_id, text="needle")
            self.index.refresh(issue_id)
        with patch("mantis_index.SEARCH_CURSOR_CAPACITY", 2):
            oldest = self.index.search("needle", semantic=False, limit=1)
            self.index.search("needle", semantic=False, limit=1, filters={"status": 90})
            self.index.search("needle", semantic=False, limit=1, sort_by="updated_at")
        self.assertEqual(len(self.index.search_cursors), 2)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.index.search("needle", semantic=False, limit=1, cursor=oldest["next_cursor"])
        live = self.index.search("needle", semantic=False, limit=1)
        session_id = json.loads(base64.urlsafe_b64decode(live["next_cursor"]))["session"]
        self.index.search_cursors[session_id]["touched"] -= 901
        with self.assertRaisesRegex(ValueError, "expired"):
            self.index.search("needle", semantic=False, limit=1, cursor=live["next_cursor"])

    def test_source_revision_catches_up_after_legacy_runtime_restart(self):
        self.index.refresh(1)
        old_revision = self.state.revision()
        self.state.close()
        import sqlite3
        from contextlib import closing
        with closing(sqlite3.connect(self.root / "state" / "mantis.sqlite")) as db:
            db.execute("UPDATE meta SET value=? WHERE key='revision'", (str(old_revision + 3),))
            db.commit()
        self.state = State(self.root / "state", self.root / "files")
        self.assertEqual(self.state.source_revision(), old_revision + 3)

    def test_single_owner_and_schema_guard(self):
        with self.assertRaisesRegex(RuntimeError, "owner"):
            State(self.root / "state", self.root / "files")
        self.state.run("PRAGMA user_version=999")
        self.state.close()
        with self.assertRaisesRegex(RuntimeError, "schema"):
            State(self.root / "state", self.root / "files")
        import sqlite3
        with sqlite3.connect(self.root / "state" / "mantis.sqlite") as db:
            db.execute("PRAGMA user_version=1")
        db.close()
        self.state = State(self.root / "state", self.root / "files")

    def test_new_accessible_project_uses_current_permissions_without_config_list(self):
        self.api.items[2] = ticket(2, project=2)
        self.api.project_list.append({"id": 2, "access_level": {"id": 70}})
        result = self.writer.execute("operation01", "analyst", [{"action": "add_comment", "issue_id": 2, "fields": {"text": "publish"}}])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(len(self.api.sent), 1)

    def test_write_switch_and_revoked_project_access_block_before_dispatch(self):
        self.writer.write_enabled = False
        with self.assertRaisesRegex(PermissionError, "maintenance switch"):
            self.writer.execute("operation01", "analyst", [{"action": "add_comment", "issue_id": 1, "fields": {"text": "no"}}])
        self.assertEqual(self.api.sent, [])
        self.writer.write_enabled = True
        self.api.project_list = []
        result = self.writer.execute("operation02", "analyst", [{"action": "add_comment", "issue_id": 1, "fields": {"text": "no"}}])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.api.sent, [])

    def test_relationship_attach_and_detach_confirmed_by_readback(self):
        self.api.items[1]["status"] = {"id": 10}
        self.api.items[2] = ticket(2)
        _, version = self.api.visible_issue(1)
        attached = self.writer.execute("relation01", "analyst", [{"action": "attach_relationship", "issue_id": 1,
            "related_issue_id": 2, "relationship_type": "parent-of", "expected_version": version}])
        self.assertEqual(attached["status"], "succeeded")
        relation_id = attached["steps"][0]["result"]["relationship_id"]
        self.assertEqual(self.api.items[1]["relationships"][0]["type"]["name"], "parent-of")
        _, version = self.api.visible_issue(1)
        detached = self.writer.execute("relation02", "analyst", [{"action": "detach_relationship", "issue_id": 1,
            "related_issue_id": 2, "relationship_id": relation_id, "expected_version": version}])
        self.assertEqual(detached["status"], "succeeded")
        self.assertEqual(self.api.items[1]["relationships"], [])

    def test_relationship_target_must_be_visible_before_write(self):
        self.api.items[1]["status"] = {"id": 10}
        _, version = self.api.visible_issue(1)
        result = self.writer.execute("relation03", "analyst", [{"action": "attach_relationship", "issue_id": 1,
            "related_issue_id": 999, "relationship_type": "related-to", "expected_version": version}])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.api.sent, [])

    def test_concrete_write_signature_and_idempotent_repeat(self):
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "Принято"}}]
        result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "succeeded")
        self.assertIn("инициатор analyst", self.api.items[1]["notes"][0]["text"])
        self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(len(self.api.sent), 1)
        with self.assertRaises(ValueError):
            self.writer.execute("operation01", "another", steps)

    def test_viewer_cannot_write_even_if_server_would_accept(self):
        self.api.level = 10
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "test"}}]
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "failed")
        self.assertEqual(self.api.sent, [])

    def test_lost_response_ambiguous_never_posts_again(self):
        self.api.lost = self.api.duplicate = True
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "test"}}]
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "unknown")
        self.api.lost = False
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "unknown")
        self.assertEqual(len(self.api.sent), 1)

    def test_lost_response_reconciles_after_restart(self):
        self.api.lost = True
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "test"}}]
        self.writer.execute("operation01", "analyst", steps)
        self.api.lost = False
        self.state.close()
        self.state = State(self.root / "state", self.root / "files")
        self.index = Index(self.state, self.api)
        self.writer = Writer(self.index, True)
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "succeeded")
        self.assertEqual(len(self.api.sent), 1)

    def test_known_conflict_and_silently_ignored_field(self):
        issue, etag = self.api.visible_issue(1)
        steps = [{"action": "update_issue", "issue_id": 1, "fields": {"summary": "new"}, "expected_version": "old"}]
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "conflict")
        self.assertFalse(self.api.sent)
        steps[0]["expected_version"] = etag
        self.api.ignore = True
        self.assertEqual(self.writer.execute("operation02", "analyst", steps)["status"], "partial")

    def test_compound_continues_only_failed_step(self):
        steps = [{"action": "create_issue", "project_id": 1, "fields": {"summary": "new", "description": "detail"}},
                 {"action": "add_comment", "fields": {"text": "comment"}},
                 {"action": "upload_file", "file": {"name": "file.txt", "content": base64.b64encode(b"payload").decode()}}]
        self.api.block_upload = True
        result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(len(self.api.sent), 2)
        self.api.block_upload = False
        result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(len(self.api.sent), 3)

    def test_own_and_other_notes_have_numeric_thresholds(self):
        self.api.items[1]["status"] = {"id": 10}
        self.api.items[1]["notes"] = [{"id": 7, "reporter": {"id": 3025}, "text": "old"}]
        self.api.level = 10
        _, etag = self.api.visible_issue(1)
        steps = [{"action": "update_comment", "issue_id": 1, "note_id": 7, "fields": {"text": "new"}, "expected_version": etag}]
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "failed")
        self.assertFalse(self.api.sent)
        self.api.level = 25
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "succeeded")

    def test_status_only_does_not_create_comment(self):
        _, etag = self.api.visible_issue(1)
        result = self.writer.execute("operation01", "analyst", [{"action": "update_issue", "issue_id": 1,
            "fields": {"status": {"id": 50}}, "expected_version": etag}])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(self.api.items[1]["notes"], [])
        self.assertEqual(self.api.sent[0][3], etag)

    def test_unsupported_existing_comment_file_does_not_substitute(self):
        result = self.writer.execute("operation01", "analyst", [{"action": "upload_file", "issue_id": 1, "note_id": 7,
            "file": {"name": "x.txt", "content": "eA=="}}])
        self.assertEqual(result["status"], "failed")
        self.assertFalse(self.api.sent)

    def test_cancel_keeps_confirmed_steps_and_unknown(self):
        self.api.lost = True
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "x"}},
                 {"action": "add_comment", "issue_id": 1, "fields": {"text": "y"}}]
        self.writer.execute("operation01", "analyst", steps)
        self.writer.cancel("operation01", "analyst")
        self.api.lost = False
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "cancelled")
        self.assertEqual(len(self.api.sent), 1)

    def test_cancel_during_response_does_not_send_next_step(self):
        original = self.api.request
        def cancel_during_response(*args, **kwargs):
            result = original(*args, **kwargs)
            self.writer.cancel("operation01", "analyst")
            return result
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "first"}},
                 {"action": "add_comment", "issue_id": 1, "fields": {"text": "second"}}]
        with patch.object(self.api, "request", side_effect=cancel_during_response):
            result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["steps"][0]["status"], "succeeded")
        self.assertEqual(len(self.api.sent), 1)

    def test_old_read_cannot_resurrect_a_revoked_issue_or_project(self):
        self.index.refresh(1)
        self.state.purge_issue(1)
        self.index.cleanup()
        with self.assertRaisesRegex(RuntimeError, "Access changed"):
            self.state.put_issue(ticket(), observed_at=1)
        self.index.refresh(1)  # A new authoritative read can restore this scope.
        with self.assertRaisesRegex(RuntimeError, "Access changed"):
            self.state.put_issue(ticket(), observed_at=1)
        self.state.purge_project(1)
        with self.assertRaisesRegex(RuntimeError, "Project access"):
            self.state.put_issue(ticket(999), observed_at=1)

    def test_partial_delta_failure_preserves_watermark_and_replays(self):
        self.api.items[2] = ticket(2)
        self.state.run("UPDATE projects SET status='current',checkpoint=1")
        original = self.api.visible_issue
        def fail_second(issue_id):
            if issue_id == 1:
                raise ApiError("network interruption")
            return original(issue_id)
        with patch.object(self.api, "visible_issue", side_effect=fail_second):
            with self.assertRaises(ApiError):
                self.index.sync_project(1)
        self.assertEqual(self.state.one("SELECT checkpoint FROM projects")["checkpoint"], 1)
        self.assertEqual(self.state.health()["issues"], 1)
        self.index.sync_project(1)
        self.assertEqual(self.state.health()["issues"], 2)

    def test_embedding_outage_keeps_lexical_and_marks_incomplete_corpus(self):
        self.index.refresh(1)
        self.index.vectors = SimpleNamespace(query=lambda vector: [], purge=lambda: None)
        self.index.embeddings = SimpleNamespace(embed=lambda texts, **kwargs: (_ for _ in ()).throw(RuntimeError("provider unavailable")))
        self.index.semantic_status = "ready"
        result = self.index.search("решения", semantic=True)
        self.assertEqual(result["issues"][0]["id"], 1)
        self.assertIn("unavailable", result["semantic_query"])
        self.assertEqual(result["semantic_corpus"], "partial")

    def test_slow_interactive_embedding_returns_lexical_results(self):
        from mantis_index import EmbeddingError
        self.index.refresh(1)
        self.index.vectors = SimpleNamespace(query=lambda vector: [], purge=lambda: None)
        calls = []
        def slow(texts, **kwargs):
            calls.append((texts, kwargs))
            raise EmbeddingError("timeout")
        self.index.embeddings = SimpleNamespace(embed=slow)
        result = self.index.search("решения", semantic=True)
        self.assertEqual(result["issues"][0]["id"], 1)
        self.assertIn("timeout", result["semantic_query"])
        self.assertEqual(calls, [(["решения"], {"timeout": 40, "retries": 0})])

    def test_broad_candidate_window_still_uses_semantics_and_reports_limit(self):
        self.index.refresh(1)
        calls = []
        self.index.vectors = SimpleNamespace(query=lambda vector: calls.append("vector") or [], purge=lambda: None)
        def embed(texts, **kwargs):
            calls.append("embedding")
            return [[1.0] + [0.0] * 4095]
        self.index.embeddings = SimpleNamespace(embed=embed)
        with patch("mantis_index.SEARCH_CANDIDATE_LIMIT", 1):
            result = self.index.search("решения", semantic=True, limit=1)
        self.assertEqual(result["issues"][0]["id"], 1)
        self.assertEqual(result["candidate_limit"], 1)
        self.assertTrue(result["candidate_window_limited"])
        self.assertEqual(result["semantic_query"], "available")
        self.assertEqual(result["query_embedding_cache"], "miss")
        self.assertEqual(calls, ["embedding", "vector"])

    def test_slow_semantic_query_falls_back_within_interactive_budget(self):
        self.index.refresh(1)
        self.index.vectors = SimpleNamespace(query=lambda vector: [], purge=lambda: None)
        self.index.embeddings = SimpleNamespace()
        release, finished = threading.Event(), threading.Event()
        def slow_query(query):
            try:
                release.wait(1)
                return [0], "miss"
            finally:
                finished.set()
        try:
            with patch.object(self.index, "query_vector", side_effect=slow_query), \
                 patch("mantis_index.QUERY_SEMANTIC_BUDGET_SECONDS", 0.03):
                started = time.monotonic()
                result = self.index.search("решения", semantic=True, limit=1)
                elapsed = time.monotonic() - started
            self.assertTrue(result["ok"])
            self.assertLess(elapsed, 0.5)
            self.assertEqual(result["semantic_query"], "timeout:interactive_semantic_budget")
            self.assertEqual(result["query_embedding_cache"], "unavailable")
        finally:
            release.set()
            self.assertTrue(finished.wait(1))
            for thread in threading.enumerate():
                if thread.name.startswith("mantis-search-semantic"):
                    thread.join(timeout=1)

    def test_semantic_budget_allows_provider_to_finish_after_network_target(self):
        self.index.refresh(1)
        self.index.vectors = SimpleNamespace(query=lambda vector: [], purge=lambda: None)
        self.index.embeddings = SimpleNamespace()
        def delayed_vector(query):
            time.sleep(0.05)
            return [1.0], "miss"
        with patch.object(self.index, "query_vector", side_effect=delayed_vector), \
             patch("mantis_index.QUERY_EMBEDDING_TIMEOUT_SECONDS", 0.03), \
             patch("mantis_index.QUERY_SEMANTIC_BUDGET_SECONDS", 0.1):
            result = self.index.search("решения", semantic=True, limit=1)
        self.assertEqual(result["semantic_query"], "available")
        self.assertEqual(result["query_embedding_cache"], "miss")

    def test_slow_access_probe_does_not_hold_search_response(self):
        from server import Settings
        self.state.put_issue(ticket(1, text="needle"))
        self.index.api = Api(Settings("https://mantis.test", "fixture", self.root / "files"))
        release, finished = threading.Event(), threading.Event()
        def slow_refresh(issue_id, **kwargs):
            try:
                release.wait(1)
                return ticket(issue_id, text="needle"), "", False
            finally:
                finished.set()
        try:
            with patch.object(self.index, "refresh", side_effect=slow_refresh), \
                 patch("mantis_index.SEARCH_REFRESH_BUDGET_SECONDS", 0.03):
                started = time.monotonic()
                result = self.index.search("needle", semantic=False, limit=1)
                elapsed = time.monotonic() - started
            self.assertTrue(result["ok"])
            self.assertLess(elapsed, 0.5)
            self.assertEqual(result["issues"][0]["access_check"], "cached")
        finally:
            release.set()
            self.assertTrue(finished.wait(1))

    def test_search_reads_while_writer_holds_its_python_lock(self):
        from server import Settings
        self.state.put_issue(ticket(1, text="needle"))
        self.index.api = Api(Settings("https://mantis.test", "fixture", self.root / "files"))
        acquired, release = threading.Event(), threading.Event()
        def hold_writer():
            with self.state.lock:
                acquired.set()
                release.wait(2)
        worker = threading.Thread(target=hold_writer)
        worker.start()
        self.assertTrue(acquired.wait(1))
        try:
            with patch.object(self.index, "refresh", return_value=(ticket(1, text="needle"), "", False)):
                started = time.monotonic()
                result = self.index.search("needle", semantic=False, limit=1)
                elapsed = time.monotonic() - started
            self.assertTrue(result["ok"])
            self.assertEqual(result["issues"][0]["id"], 1)
            self.assertLess(elapsed, 1.0)
        finally:
            release.set()
            worker.join(2)

    def test_relevance_pages_read_only_the_needed_broad_candidates(self):
        for issue_id in range(1, 651):
            self.state.put_issue(ticket(issue_id, text="needle"))
        self.api.down = True
        read = SearchReader.all
        fetched = []
        def counted(reader, sql, args=()):
            if "FROM fragments f JOIN issues i" in sql:
                fetched.append(len(args))
            return read(reader, sql, args)
        with patch.object(SearchReader, "all", counted):
            first = self.index.search("needle", semantic=False, limit=10)
            first_reads = sum(fetched)
            fetched.clear()
            second = self.index.search("needle", semantic=False, limit=10, cursor=first["next_cursor"])
            second_reads = sum(fetched)
        self.assertEqual(len(first["issues"]), 10)
        self.assertEqual(len(second["issues"]), 10)
        self.assertFalse({issue["id"] for issue in first["issues"]} & {issue["id"] for issue in second["issues"]})
        self.assertLessEqual(first_reads, 400, "First page must not load the full lexical window")
        self.assertLessEqual(second_reads, 400, "Second page should retain bounded source reads")

    def test_search_limits_fresh_access_probes_and_reuses_project_context(self):
        from server import Settings
        real = Api(Settings("https://mantis.test", "fixture", self.root / "files"))
        for issue_id in range(1, 11):
            self.api.items[issue_id] = ticket(issue_id, text="needle")
            visible = real.filter_visible(real.normalize_lists(copy.deepcopy(self.api.items[issue_id])),
                                          {"config": {}, "level": 70, "user": {"id": 3025}})
            self.state.put_issue(visible)
        requested = []
        threads = set()
        calls_lock = threading.Lock()
        def respond(client, path, **kwargs):
            with calls_lock:
                requested.append((path, client.settings.timeout_seconds))
            if path.startswith("issues/"):
                with calls_lock:
                    threads.add(threading.get_ident())
                time.sleep(0.02)
                return {"issues": [copy.deepcopy(self.api.items[int(path.split("/")[1])])]}, "fixture-etag"
            if path == "users/me":
                return {"user": {"id": 3025, "name": "service"}}, ""
            if path == "projects":
                return {"projects": [{"id": 1, "access_level": {"id": 70}}]}, ""
            if path.startswith("config?"):
                return {"configs": []}, ""
            self.fail("Unexpected Mantis endpoint: " + path)
        self.index.api = real
        with patch.object(Api, "request", autospec=True, side_effect=respond):
            result = self.index.search("needle", semantic=False, limit=10)
        self.assertEqual(len(result["issues"]), 10)
        self.assertEqual(sum(path.startswith("issues/") for path, _ in requested), 10)
        self.assertGreater(len(threads), 1)
        self.assertLessEqual(len(threads), 4)
        self.assertLessEqual(sum(path == "users/me" for path, _ in requested), 4)
        self.assertLessEqual(sum(path == "projects" for path, _ in requested), 4)
        self.assertLessEqual(sum(path.startswith("config?") for path, _ in requested), 4)
        self.assertTrue(all(timeout == 3 for _, timeout in requested))
        self.assertEqual(sum(card["access_check"] == "fresh" for card in result["issues"]), 10)

    def test_custom_field_requirements_and_regex_are_checked_before_post(self):
        self.api.definitions = [{"field": {"id": 5}, "require_report": 1, "access_level_rw": 25,
                                 "length_min": 2, "length_max": 5, "valid_regexp": "^[A-Z]+$"}]
        steps = [{"action": "create_issue", "project_id": 1, "fields": {"summary": "new", "description": "body"}}]
        self.assertEqual(self.writer.execute("operation01", "analyst", steps)["status"], "failed")
        steps[0]["fields"]["custom_fields"] = [{"field": {"id": 5}, "value": "12"}]
        self.assertEqual(self.writer.execute("operation02", "analyst", steps)["status"], "failed")
        self.assertFalse(self.api.sent)
        steps[0]["fields"]["custom_fields"][0]["value"] = "ABC"
        self.assertEqual(self.writer.execute("operation03", "analyst", steps)["status"], "succeeded")

    def test_file_can_be_attached_when_creating_a_comment(self):
        steps = [{"action": "add_comment", "issue_id": 1, "fields": {"text": "with file",
                  "files": [{"name": "Данные отчёта.txt", "content": "eA=="}]}}]
        result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["steps"][0]["result"]["file_ids"], [10])
        self.assertEqual(len(self.api.sent), 1)

    def test_failed_project_does_not_block_another_project(self):
        self.api.project_list.append({"id": 2})
        self.api.items[2] = ticket(2, project=2)
        original = self.api.initial_page
        def fail_one(project_id, page, size):
            if project_id == 1:
                raise ApiError("project temporarily unavailable")
            return original(project_id, page, size)
        with patch.object(self.api, "initial_page", side_effect=fail_one):
            self.index.tick()
        self.assertIn("unavailable", self.state.one("SELECT error FROM projects WHERE id=1")["error"])
        self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=2"))

    def test_worker_starts_stops_and_releases_its_own_volume(self):
        self.index.start()
        deadline = time.monotonic() + 3
        while not self.state.health()["issues"] and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.state.health()["issues"], 1)
        self.index.close()
        self.assertFalse(self.index.worker.is_alive())
        self.state = State(self.root / "state", self.root / "files")
        self.assertEqual(self.state.health()["issues"], 1)

    def test_canary_only_synchronizes_selected_project(self):
        self.api.project_list.append({"id": 2})
        self.api.items[2] = ticket(2, project=2)
        self.index.sync_projects = {2}
        self.index.tick()
        self.assertIsNone(self.state.one("SELECT id FROM issues WHERE id=1"))
        self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=2"))
        progress = self.state.one("SELECT import_page,import_start FROM projects WHERE id=2")
        self.index.sync_projects.clear()
        self.index.sync_project(1)
        self.assertIsNotNone(self.state.one("SELECT id FROM issues WHERE id=1"))
        self.assertEqual(self.state.one("SELECT import_page,import_start FROM projects WHERE id=2"), progress)


if __name__ == "__main__":
    unittest.main()
