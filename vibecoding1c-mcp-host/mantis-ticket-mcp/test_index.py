from __future__ import annotations

import base64
import copy
import json
from pathlib import Path
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from mantis_api import Api, ApiError
from mantis_index import Index
from mantis_state import State, digest, timestamp
from mantis_write import Writer, ACTIONS


def ticket(issue_id=1, project=1, text="Описание решения", updated="2026-09-28T12:00:00+03:00"):
    return {"id": issue_id, "project": {"id": project}, "summary": "Решение проблемы",
            "description": text, "status": {"id": 90}, "reporter": {"id": 3025},
            "created_at": "2000-01-01T00:00:00+03:00", "updated_at": updated,
            "notes": [], "attachments": [], "tags": [], "custom_fields": []}


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
        self.definitions = []

    def me(self):
        if self.down:
            raise ApiError("unavailable")
        return {"id": 3025, "name": "service"}

    def projects(self):
        self.me()
        return copy.deepcopy(self.project_list)

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
        config = {key: 25 for key in ["report_bug_threshold", "update_bug_threshold", "add_bugnote_threshold",
            "bugnote_user_edit_threshold", "upload_bug_file_threshold", "change_view_status_threshold",
            "change_view_status_bug_threshold", "tag_attach_threshold", "tag_detach_threshold", "reopen_bug_threshold", "update_bug_assign_threshold"]}
        config.update(update_bugnote_threshold=55, private_bugnote_threshold=55, private_bug_threshold=55,
                      bug_readonly_status_threshold=90, update_readonly_bug_threshold=70, bug_resolved_status_threshold=80,
                      set_status_threshold={"10": 25, "50": 40, "90": 25}, status_enum_workflow={}, max_file_size=100000,
                      allowed_files="", disallowed_files="exe")
        return {"user": self.me(), "project": {"id": project_id}, "level": self.level, "config": config}

    def metadata(self, project_id):
        return {**self.context(project_id), "custom_fields": self.definitions}

    def request(self, path, method="GET", payload=None, etag=""):
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


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mantis Пробел ")
        self.root = Path(self.temp.name)
        self.state = State(self.root / "state", self.root / "files")
        self.api = FakeApi()
        self.index = Index(self.state, self.api)
        self.writer = Writer(self.index, ACTIONS, [1])
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
        self.assertEqual(len(blank["issues"]), 5)
        self.assertTrue(blank["next_cursor"])
        self.assertNotIn("description", blank["issues"][0])

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
        import io
        provider = Embeddings(self.state, "fixture")
        data = {"data": [{"index": 0, "embedding": [1.0] + [0.0] * 4095}]}
        with patch("mantis_index.urlopen", return_value=io.BytesIO(json.dumps(data).encode())):
            provider.embed(["test"])
        self.assertEqual(self.state.one("SELECT status FROM charges")["status"], "unknown")
        with self.assertRaises(ValueError):
            Embeddings(self.state, "fixture", cap=float("nan"))

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

    def test_unchanged_fragments_and_status_do_not_reembed(self):
        self.index.refresh(1)
        self.state.run("UPDATE fragments SET vector_version=version,vector_id=id")
        self.api.items[1]["status"] = {"id": 50}
        self.index.refresh(1)
        self.assertEqual(self.state.health()["embedding_backlog"], 0)
        self.api.items[1]["description"] += " edited"
        self.index.refresh(1)
        self.assertEqual(self.state.health()["embedding_backlog"], 1)

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
        with patch.object(api, "request", return_value=({"issues": [{**ticket(), "notes": None, "attachments": None}]}, "")):
            self.assertEqual(api.issue(1)[0]["notes"], [])

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

    def test_grouping_pagination_and_stale_cursor(self):
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
        with self.assertRaisesRegex(ValueError, "restart"):
            self.search("решения", cursor=first["next_cursor"])

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

    def test_new_project_cannot_inherit_write_qualification(self):
        self.api.items[2] = ticket(2, project=2)
        result = self.writer.execute("operation01", "analyst", [{"action": "add_comment", "issue_id": 2, "fields": {"text": "publish"}}])
        self.assertEqual(result["status"], "failed")
        self.assertIn("MANTIS_WRITE_PROJECT_IDS", result["steps"][0]["error"])
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
        self.writer = Writer(self.index, ACTIONS, [1])
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
        self.writer.enabled.remove("upload_file")
        result = self.writer.execute("operation01", "analyst", steps)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(len(self.api.sent), 2)
        self.writer.enabled.add("upload_file")
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
        self.index.embeddings = SimpleNamespace(embed=lambda texts: (_ for _ in ()).throw(RuntimeError("provider unavailable")))
        self.index.semantic_status = "ready"
        result = self.index.search("решения", semantic=True)
        self.assertEqual(result["issues"][0]["id"], 1)
        self.assertIn("unavailable", result["semantic_query"])
        self.assertEqual(result["semantic_corpus"], "partial")

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
