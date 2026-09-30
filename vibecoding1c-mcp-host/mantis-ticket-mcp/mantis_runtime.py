"""MCP integration; explicit opt-in starts only the Mantis-owned workers."""
from __future__ import annotations

import base64
import json
import os
import math
import logging
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from mantis_api import Api, ApiError
from mantis_index import Embeddings, Index, Vectors
from mantis_state import State, digest, object_id, sources, is_link, clean_issue
from mantis_write import ACTIONS, Writer
from mantis_tools import worker_tool


def actor_name(explicit=""):
    actor = explicit.strip()
    if not actor:
        try:
            from fastmcp.server.dependencies import get_http_headers
            actor = get_http_headers().get("x-mantis-actor", "").strip()
        except (ImportError, RuntimeError):
            pass
    if len(actor) > 120 or any(c in actor for c in "\r\n"):
        raise ValueError("Initiator name/login must be a single line of at most 120 characters")
    return actor or "не указан"


class Runtime:
    def __init__(self, settings, raw_client):
        self.settings, self.raw_client = settings, raw_client
        self.index = None
        self.error = "index_disabled"
        if os.environ.get("MANTIS_INDEX_ENABLED", "false").lower() not in {"true", "1", "yes"}:
            return
        try:
            state = State(Path(os.environ.get("MANTIS_STATE_PATH", "/data/mantis")), settings.attachment_cache_path)
        except (RuntimeError, OSError, ValueError, sqlite3.DatabaseError) as exc:
            self.error = "State unavailable; existing direct reading remains active: " + str(exc)[:180]
            return
        vectors = None
        try:
            vectors = Vectors(state)
        except (ImportError, RuntimeError, OSError, ValueError) as exc:
            self.error = "Vector backend unavailable: " + str(exc)[:160]
        key = os.environ.get("MANTIS_OPENROUTER_API_KEY", "")
        provider = Embeddings(state, key, cap=float(os.environ.get("MANTIS_MONTHLY_BUDGET_USD", "5")),
                              timeout=int(os.environ.get("MANTIS_EMBEDDING_TIMEOUT_SECONDS", "120"))) if key else None
        self.index = Index(state, Api(settings), vectors, provider,
                           interval=int(os.environ.get("MANTIS_SYNC_INTERVAL_SECONDS", "30")),
                           sync_projects=[int(p) for p in os.environ.get("MANTIS_SYNC_PROJECT_IDS", "").split(",") if p.strip()])
        self.writer = Writer(self.index, os.environ.get("MANTIS_WRITE_ENABLED", "false").lower() in {"true", "1", "yes"})
        if vectors:
            self.error = ""

    def require(self):
        if not self.index:
            raise RuntimeError("Mantis index is disabled; configure its separate state volume and MANTIS_INDEX_ENABLED=true")
        return self.index

    def audit(self, actor, action, target, outcome="succeeded"):
        self.require().state.audit(actor_name(actor), action, target, outcome)

    def get_issue(self, issue_id):
        issue, _, stale = self.require().refresh(int(issue_id))
        return issue

    def validate_issue_snapshot(self, issue):
        row = self.require().state.one("SELECT hash FROM issues WHERE id=?", (int(issue["id"]),))
        if not row or row["hash"] != digest(clean_issue(issue)):
            raise ApiError("Issue changed during reading; retry a fresh read")

    @contextmanager
    def attachment_guard(self, issue_id, file_id):
        state = self.require().state
        with state.lock:
            if not state.one("SELECT id FROM fragments WHERE issue_id=? AND file_id=?", (int(issue_id), int(file_id))):
                raise ApiError("Attachment access changed; retry its parent issue", 403)
            yield

    def get_issue_file(self, issue_id, file_id):
        issue, _, stale = self.require().refresh(int(issue_id))
        if not any(file == int(file_id) for _, _, _, file, _ in sources(issue)):
            raise ApiError("Attachment is not in the visible issue or comments", 403)
        if not stale:
            result = self.raw_client.get_issue_file(issue_id, file_id)
            if not self.index.state.one("SELECT id FROM fragments WHERE issue_id=? AND file_id=?", (int(issue_id), int(file_id))):
                raise ApiError("Attachment access changed during download; retry its parent issue", 403)
            return result
        directory = self.settings.attachment_cache_path / str(int(issue_id))
        if is_link(directory):
            raise ApiError("Unexpected attachment cache path")
        files = list(directory.glob(f"{int(file_id)}-*"))
        if len(files) == 1 and not files[0].is_symlink():
            return {"id": int(file_id), "filename": files[0].name.split("-", 1)[1],
                    "content": base64.b64encode(files[0].read_bytes()).decode("ascii"), "stale": True}
        raise ApiError("Mantis is unavailable and this original attachment is not cached")

    def register(self, mcp):
        @mcp.tool
        @worker_tool
        def search_tickets(query: str = "", actor: str = "", filters: dict | None = None,
                           mode: str = "all", limit: int = 10, cursor: str = "", semantic: bool = True,
                           sort_by: str = "relevance", similar_to: int = 0) -> dict:
            """Paged index snapshot search (10 default, max 20, 12000 chars), without live Mantis checks. Continue with next_cursor within 15 minutes; use query or similar_to and filter/sort via mantis_metadata."""
            person = actor_name(actor)
            started = time.monotonic()
            result = self.require().search(query, filters, mode, limit, cursor, semantic, sort_by, similar_to)
            search_seconds = time.monotonic() - started
            self.audit(person, "search", "", result.get("status", "succeeded"))
            audit_seconds = time.monotonic() - started - search_seconds
            if search_seconds > 10 or audit_seconds > 10:
                logging.getLogger(__name__).warning(
                    "Mantis search latency: compute=%.3fs audit=%.3fs", search_seconds, audit_seconds)
            from fastmcp.tools.tool import ToolResult
            from mcp.types import TextContent
            summary = f"Mantis search: {len(result.get('issues', []))} issue(s); next page: {bool(result.get('next_cursor'))}; status: {result.get('status', 'ok')}. Results are in structuredContent."
            return ToolResult(content=[TextContent(type="text", text=summary)], structured_content=result)

        @mcp.tool
        @worker_tool
        def mantis_metadata(project_id: int = 0, actor: str = "", participants_query: str = "",
                            participant_cursor: str = "", participant_limit: int = 10,
                            handlers_only: bool = False) -> dict:
            """Discover projects, filters and field definitions; participants_query searches project users in bounded pages."""
            person = actor_name(actor)
            index = self.require()
            self.audit(person, "metadata", project_id)
            if participants_query or participant_cursor or handlers_only:
                if not project_id:
                    raise ValueError("project_id is required for participant lookup")
                return index.project_participants(project_id, participants_query, participant_limit,
                                                  participant_cursor, handlers_only)
            if project_id:
                return index.metadata(project_id)
            projects = index.state.all("SELECT data,verified FROM projects WHERE status<>'access_removed'")
            return {"projects": [json.loads(p["data"]) for p in projects], "catalog_source": "local; status via index_control",
                    "write_actions": sorted(ACTIONS),
                    "write_enabled": self.writer.write_enabled,
                    "filters": ["project_id", "status", "tags", "custom_fields", "created_after", "created_before", "updated_after", "updated_before",
                                "handler_id", "reporter_id", "priority", "severity", "version", "target_version", "fixed_in_version"],
                    "sort_by": ["relevance", "updated_at", "created_at"],
                    "write_steps": {"action": "required", "issue_id": "existing target or previous create result",
                                    "project_id": "required for create", "fields": "API field values", "expected_version": "required for editing: inspect via write_operation",
                                    "note_id": "comment edit only", "file": "upload: name, base64 content, optional type", "tag_id": "attach/detach",
                                    "related_issue_id": "relationship target", "relationship_type": "attach: related-to, duplicate-of, parent-of, child-of",
                                    "relationship_id": "detach: read_ticket relationship ID"},
                    "identity": "Optional claimed client identity; absent names are recorded as unspecified. All users share the service account's visibility",
                    "concurrency": "Pre/post-read and MCP serialization; residual race with other Mantis clients remains"}

        @mcp.tool
        @worker_tool
        def execute_write(operation_id: str, steps: list[dict], actor: str = "") -> dict:
            """Execute an explicit user instruction, never a draft. Reuse operation_id unchanged after interruption; unknown steps are not reposted."""
            self.require()
            return self.writer.execute(operation_id, actor_name(actor), steps)

        @mcp.tool
        @worker_tool
        def write_operation(action: str, actor: str = "", operation_id: str = "", issue_id: int = 0,
                            step_number: int = 0, outcome: str = "", server_id: int = 0) -> dict:
            """inspect: get edit version; status/cancel: journal; resolve: explicit user outcome applied/not_applied for an unknown step."""
            person = actor_name(actor)
            index = self.require()
            if action == "inspect":
                issue, etag, _ = index.refresh(issue_id, allow_cache=False)
                self.audit(person, "inspect_write", issue_id)
                return {"issue": {key: issue.get(key) for key in ("id", "project", "status", "view_state", "updated_at")},
                        "expected_version": etag or digest(issue),
                        "detail": "Use read_ticket only when the edit requires source text; inspection does not dump comments"}
            if action == "status":
                self.audit(person, "write_status", operation_id)
                return self.writer.status(operation_id)
            if action == "cancel":
                return self.writer.cancel(operation_id, person)
            if action == "resolve":
                return self.writer.resolve(operation_id, step_number, person, outcome, server_id)
            raise ValueError("action must be inspect, status, cancel or resolve")

        @mcp.tool
        @worker_tool
        def index_control(action: str = "status", actor: str = "", charge_id: str = "", actual_cost_usd: float | None = None,
                          detail: bool = False) -> dict:
            """Index status/pause/resume/storage/compact_vectors/rebuild_vectors. Use detail for safe error diagnostics."""
            person = actor_name(actor)
            index = self.require()
            if action == "pause":
                with index.embedding_lock:
                    index.state.run("UPDATE meta SET value='1' WHERE key='index_paused'")
                    index.paused.set()
            elif action == "resume":
                with index.embedding_lock:
                    index.state.run("UPDATE meta SET value='0' WHERE key='index_paused'")
                    index.paused.clear()
            elif action == "settle_charge":
                if actual_cost_usd is None or not math.isfinite(actual_cost_usd) or actual_cost_usd < 0:
                    raise ValueError("Provide the confirmed non-negative actual_cost_usd")
                if not index.state.one("SELECT id FROM charges WHERE id=? AND status='unknown'", (charge_id,)):
                    raise ValueError("Unknown or already reconciled reservation")
                index.state.settle(charge_id, actual_cost_usd)
            elif action == "rebuild_vectors":
                if not index.paused.is_set() or index.embedding_active() or index.attachment_work_lock.locked() or not index.work_lock.acquire(blocking=False):
                    raise RuntimeError("Index work is still finishing; pause it and retry rebuild_vectors")
                try:
                    with index.embedding_lock, index.state.lock:
                        if index.vectors:
                            with index.vectors.lock:
                                index.vectors.close()
                            index.vectors = None
                        index.vectors = Vectors(index.state, rebuild=True)
                        index.semantic_status = "pending"
                        self.error = ""
                        index.cleanup()
                finally:
                    index.work_lock.release()
            elif action == "compact_vectors":
                if not index.paused.is_set() or index.embedding_active() or index.attachment_work_lock.locked() or not index.work_lock.acquire(blocking=False):
                    raise RuntimeError("Pause indexing and wait for work_in_progress=false before compact_vectors")
                try:
                    with index.embedding_lock:
                        if not index.vectors:
                            raise RuntimeError("Vector backend is unavailable")
                        storage = index.vectors.compact(clear_deletions=True)
                finally:
                    index.work_lock.release()
            elif action == "storage":
                storage = index.vectors.storage() if index.vectors else {"error": "Vector backend unavailable"}
            elif action != "status":
                raise ValueError("action must be status, pause, resume, storage, compact_vectors, rebuild_vectors or settle_charge")
            self.audit(person, "index_" + action, charge_id)
            return {**self.health(), "paused": index.paused.is_set(),
                    "work_in_progress": index.work_lock.locked() or index.attachment_work_lock.locked() or index.embedding_active(),
                    "index_diagnostics": index.embedding_diagnostics(detail),
                    **({"storage": storage} if action in {"storage", "compact_vectors"} else {}),
                    "unresolved_charges": index.state.all("SELECT id,month,reserved,created FROM charges WHERE status='unknown' ORDER BY created LIMIT 50")}

    def health(self):
        return {"enabled": bool(self.index), "error": self.error,
                **({"state": self.index.state.health(), "semantic": self.index.semantic_status,
                    "query_embedding_cache": self.index.query_cache_status(),
                    "sync_projects": sorted(self.index.sync_projects) or "all_accessible",
                    "mantis": self.index.remote_status, "write_enabled": self.writer.write_enabled,
                    "attachment_extraction": {"enabled": self.index.attachment_enabled,
                        "stage": self.index.attachment_stage, "error": self.index.attachment_error,
                        **self.index.state.attachment_status()}} if self.index else {})}
