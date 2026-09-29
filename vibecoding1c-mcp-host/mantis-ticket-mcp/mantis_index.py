"""Incremental sync, hybrid search and recoverable vector projection."""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from array import array
from collections import OrderedDict
from concurrent.futures import Future
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from mantis_api import ApiError
from mantis_state import PROFILE, State, digest, encode, object_id, timestamp, is_link, file_descriptors
from mantis_extract import MAX_INPUT


QUERY_EMBEDDING_CACHE_SIZE = 256
EMBEDDING_DISK_BATCH = 512
EMBEDDING_FLUSH_MAX_AGE = 60


class EmbeddingError(RuntimeError):
    """A safe provider failure category; the reservation remains conservative."""

    def __init__(self, category, status=0):
        self.category, self.status = category, status
        super().__init__(f"Embedding {category}" + (f" (HTTP {status})" if status else ""))


class Vectors:
    def __init__(self, state: State, dimension=4096, rebuild=False):
        import zvec
        self.z = zvec
        self.state = state
        self.dimension = dimension
        self.lock = threading.RLock()
        self.failed = False
        self.root = state.root / "vectors"
        self.root.mkdir(exist_ok=True)
        row = state.one("SELECT value FROM meta WHERE key='vector_generation'")
        self.generation = row["value"] if row and not rebuild else uuid.uuid4().hex
        if not re.fullmatch(r"[a-f0-9]{32}", self.generation) or is_link(self.root):
            raise RuntimeError("Invalid owned vector generation; inspect the Mantis volume")
        path = self.root / self.generation
        if is_link(path):
            raise RuntimeError("Unexpected link in Mantis vector generation")
        if row and not rebuild and not path.exists():
            raise RuntimeError("Vector generation is missing; index_control(rebuild_vectors) explicitly rebuilds it within the embedding budget, keeping journal and revocations")
        self.collection = zvec.open(str(path)) if path.exists() else self._create(path)
        with state.transaction():
            state.run("INSERT OR REPLACE INTO meta VALUES('vector_generation',?)", (self.generation,))
            if rebuild:
                state.run("UPDATE fragments SET vector_version='',vector_id=''")
                state.changed()
        self._remove_old()

    def _create(self, path):
        return self.z.create_and_open(str(path), self.z.CollectionSchema(name="mantis",
            vectors=self.z.VectorSchema("embedding", self.z.DataType.VECTOR_FP32, self.dimension)))

    def _remove_old(self):
        for path in self.root.iterdir():
            if path.name != self.generation:
                if is_link(path) or not re.fullmatch(r"[a-f0-9]{32}", path.name):
                    raise RuntimeError("Unexpected Mantis vector generation; inspect the owned volume")
                shutil.rmtree(path)

    def upsert_batch(self, rows):
        """Publish one durable Zvec segment for a bounded group of vectors."""
        for _, vector in rows:
            if len(vector) != self.dimension or not all(math.isfinite(v) for v in vector):
                raise ValueError("Embedding dimension or finite-value check failed")
        if not rows:
            return
        with self.lock:
            if self.failed:
                raise RuntimeError("Zvec write failed; restart the Mantis owner before retrying")
            try:
                result = self.collection.upsert([self.z.Doc(id=key, vectors={"embedding": list(vector)})
                                                 for key, vector in rows])
                if not all(item.ok() for item in result):
                    raise RuntimeError("Zvec rejected an embedding")
                self.collection.flush()
            except BaseException:
                self.failed = True
                raise

    def storage(self):
        """On-demand disk diagnostic; never scan files in a search call."""
        path = self.root / self.generation
        files = (p for p in path.rglob("*") if p.is_file())
        count = bytes_used = 0
        for file in files:
            count += 1
            bytes_used += file.stat().st_size
        return {"generation": self.generation, "files": count, "bytes": bytes_used,
                "free_bytes": shutil.disk_usage(self.root).free}

    def compact(self, clear_deletions=False, batch=512):
        """Copy current vectors into a compact generation without buying embeddings."""
        with self.state.lock, self.lock:
            ids = [row["vector_id"] for row in self.state.all(
                "SELECT vector_id FROM fragments WHERE vector_id<>'' AND vector_version=version")]
            if len(ids) != len(set(ids)):
                raise RuntimeError("Duplicate current vector IDs; inspect Mantis state before compaction")
            if shutil.disk_usage(self.root).free < max(1 << 30, len(ids) * self.dimension * 4 * 2):
                raise RuntimeError("Not enough free space for a second Mantis vector generation")
            generation = uuid.uuid4().hex
            new = self._create(self.root / generation)
            published = False
            try:
                for start in range(0, len(ids), batch):
                    keys = ids[start:start + batch]
                    docs = self.collection.fetch(keys)
                    if len(docs) != len(keys):
                        raise RuntimeError("A current Mantis vector is missing; keep the old generation")
                    result = new.upsert(list(docs.values()))
                    if not all(item.ok() for item in result):
                        raise RuntimeError("Zvec rejected a copied Mantis vector")
                    new.flush()
                new.close()
                new = self.z.open(str(self.root / generation))
                for start in range(0, len(ids), batch):
                    keys = ids[start:start + batch]
                    if len(new.fetch(keys, include_vector=False)) != len(keys):
                        raise RuntimeError("Copied Mantis vector generation failed reopen verification")
                self.state.run("INSERT OR REPLACE INTO meta VALUES('vector_generation',?)", (generation,))
                published = True
                old = self.collection
                self.collection, self.generation = new, generation
                old.close()
                self._remove_old()
                if clear_deletions:
                    self.state.cleanup_files()
                    self.state.run("DELETE FROM vector_deletes")
                    self.state.run("UPDATE tombstones SET cleanup=0")
                return {"vectors": len(ids), **self.storage()}
            except BaseException:
                if not published:
                    new.close()
                raise

    def query(self, vector, limit=200):
        with self.lock:
            return [doc.id for doc in self.collection.query(self.z.Query(field_name="embedding", vector=vector), topk=limit)]

    def existing(self, keys):
        with self.lock:
            if self.failed:
                raise RuntimeError("Zvec write failed; restart the Mantis owner before inspecting durability")
            return set(self.collection.fetch(keys, include_vector=False)) if keys else set()

    def purge(self):
        """Copy only current vectors, then physically retire old owned generations.

        SQLite is locked through the swap so a concurrent revoke cannot publish
        a copied stale generation. No embeddings are purchased for this rebuild.
        """
        with self.state.lock, self.lock:
            if not self.state.one("SELECT id FROM vector_deletes LIMIT 1") and not self.state.one("SELECT issue_id FROM tombstones WHERE cleanup=1 LIMIT 1"):
                self._remove_old()
                return
            self.compact(clear_deletions=True)

    def close(self):
        self.collection.close()


class Embeddings:
    def __init__(self, state, key, cap=5.0, max_price=0.04, timeout=20):
        if not math.isfinite(cap) or cap < 0 or not math.isfinite(max_price) or max_price <= 0:
            raise ValueError("Embedding budget and price must be finite non-negative amounts (price > 0)")
        self.state, self.key, self.cap, self.max_price, self.timeout = state, key, cap, max_price, timeout

    def embed(self, texts):
        if not self.key:
            raise EmbeddingError("not_configured")
        # UTF-8 byte count is a conservative input-token bound for this tokenizer.
        reserve = (sum(len(text.encode("utf-8")) + 32 for text in texts)) * self.max_price / 1_000_000
        try:
            charge = self.state.reserve(reserve, self.cap)
        except RuntimeError as exc:
            raise EmbeddingError("budget") from exc
        body = {"model": "qwen/qwen3-embedding-8b", "input": texts, "dimensions": 4096,
                "encoding_format": "float", "provider": {"max_price": {"prompt": self.max_price}}}
        request = Request("https://openrouter.ai/api/v1/embeddings", encode(body).encode("utf-8"),
                          {"Authorization": "Bearer " + self.key, "Content-Type": "application/json"}, method="POST")
        try:
            with urlopen(request, timeout=self.timeout) as response:
                data = json.load(response)
            rows = sorted(data["data"], key=lambda r: r["index"])
            if [r["index"] for r in rows] != list(range(len(texts))):
                raise ValueError("Incomplete embeddings response")
            vectors = [r["embedding"] for r in rows]
            if any(len(v) != 4096 or not all(math.isfinite(x) for x in v) for v in vectors):
                raise ValueError("Invalid embedding vector")
            cost = data.get("usage", {}).get("cost")
            if cost is not None and (not math.isfinite(float(cost)) or float(cost) < 0):
                raise ValueError("Invalid provider cost")
            if cost is not None:
                self.state.settle(charge, float(cost))
            return vectors
        except HTTPError as exc:
            category = {401: "authentication", 402: "payment", 403: "permission", 429: "rate_limited"}.get(
                exc.code, "provider_unavailable" if exc.code >= 500 else "provider_rejected")
            raise EmbeddingError(category, exc.code) from exc
        except (TimeoutError, ConnectionError) as exc:
            raise EmbeddingError("timeout" if isinstance(exc, TimeoutError) else "network") from exc
        except URLError as exc:
            raise EmbeddingError("network") from exc
        except (KeyError, TypeError, ValueError, json.JSONDecodeError, IndexError) as exc:
            raise EmbeddingError("invalid_response") from exc
        except OSError as exc:
            raise EmbeddingError("network") from exc


class Index:
    def __init__(self, state, api, vectors=None, embeddings=None, interval=30, overlap=300, sync_projects=()):
        self.state, self.api, self.vectors, self.embeddings = state, api, vectors, embeddings
        self.interval, self.overlap = max(1, interval), max(1, overlap)
        self.sync_projects = {int(project) for project in sync_projects}
        self.stop = threading.Event()
        self.paused = threading.Event()
        if state.one("SELECT value FROM meta WHERE key='index_paused'")["value"] == "1":
            self.paused.set()
        self.worker = None
        self.work_lock = threading.Lock()
        self.attachment_worker = None
        self.attachment_work_lock = threading.Lock()
        self.attachment_enabled = os.environ.get("MANTIS_ATTACHMENT_EXTRACT_ENABLED", "false").lower() in {"true", "1", "yes"}
        self.attachment_stage = "disabled" if not self.attachment_enabled else "idle"
        self.attachment_error = ""
        self._initial_progress = {}
        self._query_cache = OrderedDict()
        self._query_pending = {}
        self._query_lock = threading.Lock()
        self._query_hits = self._query_misses = self._query_shared = 0
        self.remote_status = "not_checked"
        self.semantic_status = "not_configured" if not embeddings or not vectors else "pending"
        self.stage = "idle"
        self.embedding_attempts = 0
        self.embedding_retry_at = 0
        self.last_embedding_error = None
        self.cleanup()

    def embedding_diagnostics(self, detail=False):
        result = {"stage": self.stage, "last_error_category": (self.last_embedding_error or {}).get("category"),
                  "last_error_at": (self.last_embedding_error or {}).get("at"),
                  "consecutive_failures": self.embedding_attempts,
                  "next_retry_at": self.embedding_retry_at or None}
        if detail and self.last_embedding_error:
            result["last_error"] = dict(self.last_embedding_error)
        return result

    def _embedding_failure(self, exc):
        category = exc.category if isinstance(exc, EmbeddingError) else (
            "vector_storage" if isinstance(exc, (OSError, IOError)) else "internal")
        self.embedding_attempts += 1
        delay = min(900, 30 * 2 ** min(self.embedding_attempts - 1, 5))
        if category in {"authentication", "payment", "permission", "budget"}:
            delay = max(delay, 3600)
        self.embedding_retry_at = self.state.clock() + delay
        self.last_embedding_error = {"category": category, "at": self.state.clock(),
                                     "http_status": exc.status if isinstance(exc, EmbeddingError) else None,
                                     "reservation": "unknown_until_reconciled" if isinstance(exc, EmbeddingError)
                                     and category not in {"not_configured", "budget"} else "not_created"}
        self.semantic_status = "error:" + category

    def _embedding_success(self):
        self.embedding_attempts = 0
        self.embedding_retry_at = 0

    def query_vector(self, query):
        # Cache only the embedding of the exact model input, never result cards,
        # source text or permissions. Pagination/filter changes reuse this input.
        key = (PROFILE, digest(query))
        with self._query_lock:
            if key in self._query_cache:
                self._query_cache.move_to_end(key)
                self._query_hits += 1
                return list(self._query_cache[key]), "hit"
            pending = self._query_pending.get(key)
            owner = pending is None
            if owner:
                pending = Future()
                self._query_pending[key] = pending
                self._query_misses += 1
            else:
                self._query_shared += 1
        if not owner:
            return list(pending.result(timeout=self.api.settings.timeout_seconds + 1)), "shared"
        try:
            vector = array("d", self.embeddings.embed([query])[0])
            if not vector:
                raise ValueError("Empty query embedding")
            with self._query_lock:
                self._query_cache[key] = vector
                while len(self._query_cache) > QUERY_EMBEDDING_CACHE_SIZE:
                    self._query_cache.popitem(last=False)
                self._query_pending.pop(key)
            pending.set_result(vector)
            return list(vector), "miss"
        except BaseException as exc:
            with self._query_lock:
                self._query_pending.pop(key, None)
            pending.set_exception(exc)
            raise

    def query_cache_status(self):
        with self._query_lock:
            return {"storage": "memory", "entries": len(self._query_cache), "limit": QUERY_EMBEDDING_CACHE_SIZE,
                    "pending": len(self._query_pending), "hits": self._query_hits,
                    "misses": self._query_misses, "shared": self._query_shared}

    def cleanup(self):
        with self.state.lock:
            try:
                self.state.cleanup_files()
                if self.vectors:
                    self.vectors.purge()
                else:
                    # Keep pending cleanup until the vector backend is available.
                    if not (self.state.root / "vectors").exists():
                        self.state.run("UPDATE tombstones SET cleanup=0")
                return True
            except (RuntimeError, OSError) as exc:
                # SQLite has already excluded revoked sources. A broken vector
                # backend must not prevent independent lexical updates/reads.
                self.semantic_status = "cleanup pending: " + str(exc)[:160]
                return False

    def refresh(self, issue_id, allow_cache=True):
        observed_at = self.state.clock()
        try:
            issue, etag = self.api.visible_issue(issue_id)
            self.cleanup()
            self.state.put_issue(issue, etag, observed_at)
            self.remote_status = "available"
            return issue, etag, False
        except ApiError as exc:
            try:
                absent = self.api.confirm_absence(issue_id, exc)
            except ApiError:
                absent = False
            if absent:
                self.state.purge_issue(issue_id)
                self.cleanup()
                raise
            self.remote_status = "unavailable"
            cached = self.state.one("SELECT * FROM issues WHERE id=?", (issue_id,)) if allow_cache else None
            if cached:
                return json.loads(cached["data"]), cached["etag"], True
            raise

    def catalogs(self):
        projects = self.api.projects()
        current = {int(p["id"]) for p in projects}
        for project in projects:
            pid = int(project["id"])
            old = self.state.one("SELECT status FROM projects WHERE id=?", (pid,))
            if old:
                self.state.run("UPDATE projects SET data=?,status=CASE WHEN status='access_removed' THEN 'initializing' ELSE status END WHERE id=?",
                               (encode(project), pid))
            else:
                self.state.run("INSERT INTO projects(id,data) VALUES(?,?)", (pid, encode(project)))
        missing = [r["id"] for r in self.state.all("SELECT id FROM projects WHERE status<>'access_removed'") if r["id"] not in current]
        if missing:
            self.api.me()
            confirmed = {int(p["id"]) for p in self.api.projects()}
            for pid in missing:
                if pid not in confirmed:
                    self.state.purge_project(pid)
        try:
            tags = self.api.tags()
            previous = self.state.one("SELECT data FROM catalog WHERE key='tags'")
            self.state.put_catalog("tags", tags)
            if not previous or previous["data"] != encode(tags):
                self.state.changed()
        except ApiError:
            pass  # Issue delta is independent of the optional SOAP tag catalog.

    def _page(self, project_id, page, size=100):
        rows = self.api.headers(project_id, page, size)
        times = [timestamp(r.get("updated_at") or r.get("last_updated")) for r in rows]
        if times != sorted(times, reverse=True):
            raise RuntimeError("Mantis page is not ordered by modification date; checkpoint unchanged")
        return rows

    def sync_project(self, project_id, page_budget=40, work_budget=10):
        deadline = time.monotonic() + work_budget
        project = self.state.one("SELECT * FROM projects WHERE id=?", (project_id,))
        if not project or project["status"] == "access_removed":
            return
        if project["status"] == "initializing":
            page = project["import_page"]
            observed_at = self.state.clock()
            verifying = project["import_verify"]
            rows = self._page(project_id, page) if verifying else self.api.initial_page(project_id, page, 100)
            headers = rows if verifying else [r.get("issue") or {"id": r.get("denied_id") or r["skipped_id"], "updated_at": r["updated_at"]} for r in rows]
            signature = [(int(r["id"]), timestamp(r["updated_at"])) for r in headers]
            dates = [modified for _, modified in signature]
            if dates != sorted(dates, reverse=True):
                raise RuntimeError("Initial page is not ordered by modification date")
            if not project["import_start"] and dates:
                self.state.run("UPDATE projects SET import_start=? WHERE id=?",
                               (max(dates), project_id))
            # Resume a bounded slice of this exact visible page. No persistent
            # format changes: after a restart the page is safely replayed.
            identity = digest([page, verifying, rows])
            progress = self._initial_progress.get(project_id)
            if not progress or progress[0] != identity:
                progress = [identity, 0]
                self._initial_progress[project_id] = progress
            processed = False
            for position, row in enumerate(rows):
                if position < progress[1]:
                    continue
                if self.stop.is_set() or self.paused.is_set():
                    return
                if processed and time.monotonic() >= deadline:
                    return
                if row.get("skipped_id") or (verifying and object_id(row["project"]) != project_id):
                    progress[1] = position + 1
                    continue
                if verifying:
                    stored = self.state.one("SELECT modified FROM issues WHERE id=?", (int(row["id"]),))
                    modified = timestamp(row["updated_at"])
                    if not stored or stored["modified"] != modified or modified >= project["import_start"] - self.overlap:
                        try:
                            self.refresh(int(row["id"]), allow_cache=False)
                        except ApiError as exc:
                            if not self.state.one("SELECT issue_id FROM tombstones WHERE issue_id=?", (int(row["id"]),)) or exc.status not in (403, 404):
                                raise
                elif row.get("denied_id"):
                    self.state.purge_issue(row["denied_id"], project_id)
                else:
                    self.cleanup()
                    self.state.put_issue(row["issue"], observed_at=observed_at)
                progress[1] = position + 1
                processed = True
            self._initial_progress.pop(project_id, None)
            fingerprint = digest([project["import_digest"], signature])
            if len(rows) < 100:
                if verifying and fingerprint == project["previous_digest"]:
                    self.state.run("UPDATE projects SET status='catching_up',checkpoint=import_start WHERE id=?", (project_id,))
                else:
                    # Initial import alone enumerates the full project. Resume
                    # compact verification until two complete passes agree; a
                    # deletion ahead of a page must not skip an unchanged issue.
                    self.state.run("UPDATE projects SET import_page=1,import_verify=1,import_digest='',previous_digest=? WHERE id=?", (fingerprint, project_id))
            else:
                self.state.run("UPDATE projects SET import_page=?,import_digest=? WHERE id=?", (page + 1, fingerprint, project_id))
            self.state.run("UPDATE projects SET error='' WHERE id=?", (project_id,))
            return
        boundary = max(0, project["checkpoint"] - self.overlap)
        # Two complete recent-window enumerations must agree, including equal
        # timestamps. Otherwise retain the watermark and retry on the next tick.
        def scan():
            found = {}
            previous_page = None
            for page in range(1, page_budget + 1):
                if self.stop.is_set() or self.paused.is_set():
                    raise RuntimeError("Synchronization cancelled; checkpoint retained")
                if time.monotonic() >= deadline:
                    raise RuntimeError("Delta time budget reached; checkpoint retained, continuing on the next cycle")
                rows = self._page(project_id, page)
                signature = tuple((int(r["id"]), timestamp(r["updated_at"]), object_id(r["project"])) for r in rows)
                if signature and signature == previous_page:
                    raise RuntimeError("Mantis repeated a page; checkpoint retained")
                previous_page = signature
                for issue_id, modified, owner in signature:
                    if modified >= boundary:
                        found[issue_id] = (modified, owner)
                if len(rows) < 100 or (rows and timestamp(rows[-1]["updated_at"]) < boundary):
                    return found
            raise RuntimeError("Recent delta window exceeded its page budget; checkpoint retained")
        first, second = scan(), scan()
        if first != second:
            raise RuntimeError("Mantis pagination moved; checkpoint retained for the next bounded attempt")
        upper = max((modified for modified, _ in second.values()), default=project["checkpoint"])
        signature = digest(sorted(second.items()))
        server_time = getattr(self.api, "server_time", 0)
        for issue_id, (modified, owner) in second.items():
            if owner != project_id:
                continue
            stored = self.state.one("SELECT modified FROM issues WHERE id=?", (issue_id,))
            seen = self.state.one("SELECT signature,modified FROM delta_progress WHERE project_id=? AND issue_id=?", (project_id, issue_id))
            # Equal-second edits have no version in compact headers: refresh the
            # overlap, hash fragments, and never buy unchanged embeddings again.
            old_unchanged = stored and stored["modified"] == modified and server_time and modified < server_time - self.overlap
            already_fetched = seen and seen["signature"] == signature and seen["modified"] == modified
            if not old_unchanged and not already_fetched:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Delta fetch time budget reached; saved progress resumes on the next cycle")
                self.refresh(issue_id, allow_cache=False)
                self.state.run("INSERT OR REPLACE INTO delta_progress VALUES(?,?,?,?)", (project_id, issue_id, modified, signature))
        if scan() != second:
            raise RuntimeError("Mantis changed during delta fetch; checkpoint retained")
        with self.state.transaction():
            self.state.run("UPDATE projects SET checkpoint=?,status='current',verified=?,error='' WHERE id=?",
                           (upper, self.state.clock(), project_id))
            self.state.run("DELETE FROM delta_progress WHERE project_id=?", (project_id,))

    def flush_embedding_spool(self):
        """Flush paid vectors once, then atomically mark their SQLite versions ready."""
        if not self.vectors:
            return 0
        with self.state.lock:
            self.state.run("""DELETE FROM embedding_spool WHERE NOT EXISTS
                (SELECT 1 FROM fragments f WHERE f.id=embedding_spool.fragment_id
                 AND f.version=embedding_spool.version)""")
            rows = self.state.all("""SELECT s.fragment_id,s.version,s.vector FROM embedding_spool s
                JOIN fragments f ON f.id=s.fragment_id AND f.version=s.version
                ORDER BY s.created,s.fragment_id LIMIT ?""", (EMBEDDING_DISK_BATCH,))
            if not rows:
                return 0
            keys = {row["fragment_id"]: digest([row["fragment_id"], row["version"]]) for row in rows}
            present = self.vectors.existing(list(keys.values()))
            missing = []
            for row in rows:
                key = keys[row["fragment_id"]]
                if key not in present:
                    vector = array("f")
                    vector.frombytes(row["vector"])
                    missing.append((key, vector))
            self.vectors.upsert_batch(missing)
            with self.state.transaction():
                for row in rows:
                    self.state.run("UPDATE fragments SET vector_id=?,vector_version=? WHERE id=? AND version=?",
                                   (keys[row["fragment_id"]], row["version"], row["fragment_id"], row["version"]))
                    self.state.run("DELETE FROM embedding_spool WHERE fragment_id=? AND version=?",
                                   (row["fragment_id"], row["version"]))
                self.state.changed()
            return len(rows)

    def embed_pending(self, batch=16):
        if not self.vectors:
            return
        if not self.embeddings:
            self.flush_embedding_spool()
            return
        selected = sorted(self.sync_projects)
        scope = " AND issue_id IN (SELECT id FROM issues WHERE project_id IN (" + ",".join("?" for _ in selected) + "))" if selected else ""
        spool = self.state.one("SELECT COUNT(*) AS n,MIN(created) AS oldest FROM embedding_spool")
        if spool["n"] >= EMBEDDING_DISK_BATCH or (spool["oldest"] and self.state.clock() - spool["oldest"] >= EMBEDDING_FLUSH_MAX_AGE):
            self.flush_embedding_spool()
        rows = self.state.all("SELECT * FROM fragments WHERE version<>vector_version AND id NOT IN "
                              "(SELECT fragment_id FROM embedding_spool)" + scope + " LIMIT ?", (*selected, batch))
        present = self.vectors.existing([digest([r["id"], r["version"]]) for r in rows])
        pending = []
        for row in rows:
            key = digest([row["id"], row["version"]])
            if key in present:
                with self.state.transaction():
                    if self.state.run("UPDATE fragments SET vector_id=?,vector_version=? WHERE id=? AND version=?",
                                      (key, row["version"], row["id"], row["version"])).rowcount:
                        self.state.changed()
            else:
                pending.append(row)
        rows = pending
        if not rows:
            if self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"]:
                self.flush_embedding_spool()
            self.semantic_status = "partial" if self.state.health()["embedding_backlog"] else "ready"
            return
        values = self.embeddings.embed([r["text"] for r in rows])
        with self.state.transaction():
            for row, vector in zip(rows, values):
                if len(vector) != self.vectors.dimension or not all(math.isfinite(v) for v in vector):
                    raise ValueError("Embedding dimension or finite-value check failed")
                data = array("f", vector)
                if not all(math.isfinite(v) for v in data):
                    raise ValueError("Embedding cannot be represented by finite FP32 values")
                current = self.state.one("SELECT version FROM fragments WHERE id=?", (row["id"],))
                if not current or current["version"] != row["version"]:
                    continue
                self.state.run("INSERT OR REPLACE INTO embedding_spool VALUES(?,?,?,?)",
                               (row["id"], row["version"], data.tobytes(), self.state.clock()))
        spool = self.state.one("SELECT COUNT(*) AS n FROM embedding_spool")
        if spool["n"] >= EMBEDDING_DISK_BATCH or len(rows) < batch:
            self.flush_embedding_spool()
        self.semantic_status = "partial" if self.state.health()["embedding_backlog"] else "ready"

    def tick(self):
        if not self.work_lock.acquire(blocking=False):
            return
        try:
            self.stage = "catalogs"
            try:
                self.catalogs()
                self.remote_status = "available"
            except Exception:
                self.remote_status = "unavailable"
            next_embeddings = time.monotonic()
            for project in self.state.all("SELECT id,status FROM projects WHERE status<>'access_removed'"):
                if self.sync_projects and project["id"] not in self.sync_projects:
                    continue
                if self.stop.is_set() or self.paused.is_set():
                    return
                try:
                    self.stage = "sync_project"
                    self.sync_project(project["id"])
                except Exception as exc:
                    self.state.run("UPDATE projects SET error=?,status=CASE WHEN status='initializing' THEN status ELSE 'retrying' END WHERE id=?", (str(exc)[:300], project["id"]))
                # Do not defer all vectors until the last project's import.
                if not self.paused.is_set() and not self.stop.is_set() and time.monotonic() >= next_embeddings and self.state.clock() >= self.embedding_retry_at:
                    try:
                        self.stage = "embeddings"
                        self.embed_pending()
                        self._embedding_success()
                    except Exception as exc:
                        self._embedding_failure(exc)
                    next_embeddings = time.monotonic() + 5
            try:
                self.stage = "cleanup"
                self.cleanup()
                until = time.monotonic() + 5
                for _ in range(8):
                    if self.state.clock() < self.embedding_retry_at:
                        break
                    self.stage = "embeddings"
                    self.embed_pending(batch=64)
                    self._embedding_success()
                    if self.stop.is_set() or self.paused.is_set() or self.semantic_status == "ready" or time.monotonic() >= until:
                        break
            except Exception as exc:
                self._embedding_failure(exc)
        finally:
            self.stage = "idle"
            self.work_lock.release()

    def extract_pending(self, limit=2):
        if not self.attachment_enabled or self.paused.is_set() or self.stop.is_set():
            return 0
        if not self.attachment_work_lock.acquire(blocking=False):
            return 0
        completed = 0
        try:
            self.attachment_stage = "backfill"
            if self.state.rehydrate_attachment():
                completed += 1
            if not self.state.next_attachment():
                self.state.enqueue_existing_attachments(100)
            for slot in range(limit):
                if self.paused.is_set() or self.stop.is_set():
                    break
                row = self.state.next_attachment(retry_first=bool(slot % 2))
                if not row:
                    break
                issue_id, file_id = int(row["issue_id"]), int(row["file_id"])
                try:
                    self.attachment_stage = "verify_source"
                    issue, _, stale = self.refresh(issue_id, allow_cache=False)
                    if stale:
                        raise ApiError("Mantis did not freshly verify the attachment")
                    info = file_descriptors(issue).get(file_id)
                    if not info:
                        self.state.drop_attachment(issue_id, file_id)
                        continue
                    if row["descriptor"] != info["descriptor"]:
                        self.state.invalidate_attachment(issue_id, file_id, info["descriptor"])
                    if info["size"] > MAX_INPUT:
                        self.state.publish_attachment(issue_id,file_id,info["descriptor"],"",
                            {"status":"too_large","reason":"input_bytes","segments":[]})
                        completed += 1
                        continue
                    self.attachment_stage = "download"
                    response, _ = self.api.request(f"issues/{issue_id}/files/{file_id}",
                                                   max_response_bytes=8 * 1024 * 1024)
                    files = response.get("files") or []
                    source = next((file for file in files if object_id(file) == file_id), None)
                    if not source or not isinstance(source.get("content"), str) or \
                            (not source["content"] and info["size"] > 0):
                        self.state.defer_missing_attachment(issue_id, file_id)
                        self.attachment_error = "source_bytes_missing"
                        completed += 1
                        continue
                    payload = base64.b64decode(source["content"], validate=True)
                    if len(payload) > MAX_INPUT:
                        result = {"status":"too_large","reason":"input_bytes","segments":[]}
                    else:
                        self.attachment_stage = "parse"
                        child_env = {key: value for key, value in os.environ.items()
                                     if key.upper() in {"PATH", "SYSTEMROOT", "TEMP", "TMP"}}
                        child_env["PYTHONIOENCODING"] = "utf-8"
                        child_env["PYTHONPATH"] = str(Path(__file__).parent)
                        try:
                            child = subprocess.run([sys.executable, "-m", "mantis_extract", info["filename"]],
                                                   input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                   env=child_env, timeout=20, check=False)
                            if child.returncode or len(child.stdout) > 1_000_000:
                                raise RuntimeError("parser_failed")
                            result = json.loads(child.stdout.decode("utf-8"))
                            segments = result.get("segments")
                            if result.get("status") not in {"ready", "partial", "unsupported", "too_large", "failed"} or \
                                    not isinstance(segments, list) or len(segments) > 1000 or \
                                    any(not isinstance(s, dict) or not isinstance(s.get("location"), dict)
                                        for s in segments) or \
                                    sum(len(str(s.get("text", ""))) for s in segments) > 100_000:
                                raise RuntimeError("parser_contract")
                        except (subprocess.TimeoutExpired, RuntimeError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
                            result = {"status":"failed","reason":"parser_failed_or_timeout","segments":[]}
                    self.attachment_stage = "publish"
                    if self.state.publish_attachment(issue_id,file_id,info["descriptor"],
                                                     hashlib.sha256(payload).hexdigest(),result):
                        completed += 1
                    self.attachment_error = ""
                except ApiError as exc:
                    if exc.status == 413:
                        current = self.state.one("SELECT descriptor FROM attachment_extracts WHERE issue_id=? AND file_id=?",
                                                 (issue_id,file_id))
                        if current:
                            self.state.publish_attachment(issue_id,file_id,current["descriptor"],"",
                                {"status":"too_large","reason":"response_bytes","segments":[]})
                    else:
                        self.state.retry_attachment(issue_id,file_id,"mantis_unavailable",300)
                    self.attachment_error = "file_too_large" if exc.status == 413 else \
                        "mantis_unavailable" if not exc.status else f"mantis_http_{exc.status}"
                except Exception:
                    self.state.retry_attachment(issue_id,file_id,"extraction_retry",300)
                    self.attachment_error = "extraction_retry"
        finally:
            self.attachment_stage = "idle"
            self.attachment_work_lock.release()
        return completed

    def start(self):
        if self.worker and self.worker.is_alive():
            return
        self.stop.clear()
        def run():
            while not self.stop.is_set():
                if not self.paused.is_set():
                    self.tick()
                self.stop.wait(self.interval)
        self.worker = threading.Thread(target=run, name="mantis-index", daemon=True)
        self.worker.start()
        if self.attachment_enabled:
            def extract_loop():
                while not self.stop.is_set():
                    if not self.paused.is_set():
                        try:
                            self.extract_pending()
                        except Exception:
                            self.attachment_error = "extractor_cycle_failed"
                    self.stop.wait(self.interval)
            self.attachment_worker = threading.Thread(target=extract_loop, name="mantis-attachments", daemon=True)
            self.attachment_worker.start()

    def close(self):
        self.stop.set()
        if self.worker:
            self.worker.join(timeout=self.api.settings.timeout_seconds * 6 + 5)
            if self.worker.is_alive():
                raise RuntimeError("Mantis worker is still stopping; keep its state owner open")
        if self.attachment_worker:
            self.attachment_worker.join(timeout=self.api.settings.timeout_seconds * 6 + 45)
            if self.attachment_worker.is_alive():
                raise RuntimeError("Mantis attachment worker is still stopping; keep its state owner open")
        if self.vectors:
            self.vectors.close()
        self.state.close()

    def metadata(self, project_id):
        key = f"project:{int(project_id)}"
        try:
            value = self.api.metadata(project_id)
            self.state.put_catalog(key, value)
            return {**value, "access_check": "fresh", "last_verified": self.state.clock()}
        except ApiError:
            cached = self.state.one("SELECT data,verified FROM catalog WHERE key=?", (key,))
            if not cached:
                raise
            return {**json.loads(cached["data"]), "access_check": "cached", "last_verified": cached["verified"]}

    def project_participants(self, project_id, query="", limit=10, cursor="", handlers_only=False):
        if int(project_id) <= 0 or not isinstance(query, str) or len(query) > 120:
            raise ValueError("Provide a project_id and a query of at most 120 characters")
        limit = max(1, min(int(limit), 20))
        identity = digest([int(project_id), query.casefold(), bool(handlers_only)])
        page, position = 1, 0
        if cursor:
            try:
                token = json.loads(base64.urlsafe_b64decode(cursor))
                if token["identity"] != identity:
                    raise ValueError()
                page, position = int(token["page"]), int(token["position"])
                if not 1 <= page <= 10000 or not 0 <= position < 100:
                    raise ValueError()
            except Exception as exc:
                raise ValueError("Participant query changed or cursor is invalid; restart without cursor") from exc
        participants = []
        scanned = 0
        exhausted = False
        for _ in range(5):
            rows = self.api.project_users(project_id, page, 100, handlers_only)
            if position > len(rows):
                raise ValueError("Project participants changed during pagination; restart without cursor")
            for at in range(position, len(rows)):
                user = rows[at]
                name = str(user.get("name") or "")
                real_name = str(user.get("real_name") or "")
                if query.casefold() not in (name + " " + real_name).casefold():
                    continue
                participants.append({"id": object_id(user), "name": name[:120],
                                     "real_name": real_name[:120], "access_level": user.get("access_level")})
                if len(participants) >= limit:
                    next_page, next_position = (page + 1, 0) if at + 1 >= len(rows) else (page, at + 1)
                    more = at + 1 < len(rows) or len(rows) == 100
                    next_cursor = base64.urlsafe_b64encode(encode({"identity": identity,
                        "page": next_page, "position": next_position}).encode()).decode() if more else ""
                    return {"project_id": int(project_id), "participants": participants,
                            "next_cursor": next_cursor, "access_check": "fresh", "scanned_pages": scanned + 1}
            scanned += 1
            if len(rows) < 100:
                exhausted = True
                break
            page, position = page + 1, 0
        next_cursor = "" if exhausted else base64.urlsafe_b64encode(encode({"identity": identity,
            "page": page, "position": 0}).encode()).decode()
        return {"project_id": int(project_id), "participants": participants, "next_cursor": next_cursor,
                "access_check": "fresh", "scanned_pages": scanned}

    def search(self, query, filters=None, mode="all", limit=10, cursor="", semantic=True,
               sort_by="relevance", similar_to=0):
        if mode not in {"all", "comments", "filenames", "attachment_contents"}:
            raise ValueError("mode must be all, comments, filenames or attachment_contents")
        if sort_by not in {"relevance", "updated_at", "created_at"}:
            raise ValueError("sort_by must be relevance, updated_at or created_at")
        if not isinstance(query, str) or len(query) > 2000:
            raise ValueError("Query must be at most 2000 characters")
        if isinstance(similar_to, bool) or int(similar_to) < 0:
            raise ValueError("similar_to must be a positive issue ID")
        similar_to = int(similar_to)
        if similar_to:
            if query.strip():
                raise ValueError("Use either query or similar_to, not both")
            source, _, _ = self.refresh(similar_to)
            query = (str(source.get("summary") or "")[:240] + "\n" +
                     str(source.get("description") or "")[:900] + "\n" +
                     str(source.get("steps_to_reproduce") or "")[:400]).strip()
            if not query:
                raise ValueError("Source issue has no searchable summary or description")
        filters = filters or {}
        allowed = {"project_id", "status", "tags", "custom_fields", "created_after", "created_before", "updated_after", "updated_before",
                   "handler_id", "reporter_id", "priority", "severity", "version", "target_version", "fixed_in_version"}
        if set(filters) - allowed:
            raise ValueError("Unsupported filters: " + ", ".join(sorted(set(filters) - allowed)))
        for name in ("handler_id", "reporter_id", "priority", "severity"):
            if name in filters and (isinstance(filters[name], bool) or int(filters[name]) < 0):
                raise ValueError(name + " must be a non-negative Mantis ID")
        if filters.get("custom_fields"):
            if not filters.get("project_id"):
                raise ValueError("custom_fields requires project_id and project metadata")
            meta = self.metadata(filters["project_id"])
            definitions = {str(f["field"]["id"]): f for f in meta["custom_fields"]}
            if set(map(str, filters["custom_fields"])) - definitions.keys():
                raise ValueError("Unknown custom field for this project; call mantis_metadata")
        limit = max(1, min(int(limit), 20))
        identity = digest([query, filters, mode, semantic, sort_by, similar_to])
        offset = 0
        if cursor:
            try:
                token = json.loads(base64.urlsafe_b64decode(cursor))
                if token["query"] != identity or token["revision"] != self.state.revision():
                    raise ValueError()
                offset = int(token["offset"])
                if not 0 <= offset <= 10000:
                    raise ValueError()
            except Exception as exc:
                raise ValueError("Search changed or cursor is invalid; restart without cursor") from exc
        exact = re.fullmatch(r"#?(\d+)", query.strip())
        if exact:
            try:
                self.refresh(int(exact[1]))
            except ApiError:
                pass
        ranks = {}
        tokens = re.findall(r"\w+", query, re.UNICODE)
        if tokens:
            expression = " OR ".join('"' + t.replace('"', '""') + '"' for t in tokens)
            for rank, row in enumerate(self.state.all("SELECT id FROM search_text WHERE search_text MATCH ? ORDER BY bm25(search_text) LIMIT 10000", (expression,))):
                ranks[row["id"]] = 1 / (60 + rank)
        if query.strip():
            for row in self.state.all("SELECT id FROM fragments WHERE kind='filename' AND instr(folded,?)>0 LIMIT 10000", (query.casefold(),)):
                ranks[row["id"]] = ranks.get(row["id"], 0) + 1
        else:
            source_kind = {"comments": "comment", "filenames": "filename",
                           "attachment_contents": "attachment_content"}.get(mode)
            rows = self.state.all("SELECT MIN(f.id) AS id FROM fragments f JOIN issues i ON i.id=f.issue_id WHERE (? IS NULL OR f.kind=?) GROUP BY i.id ORDER BY i.modified DESC,i.id LIMIT 10000", (source_kind, source_kind))
            ranks.update({row["id"]: 1 / (60 + rank) for rank, row in enumerate(rows)})
        if exact:
            for row in self.state.all("SELECT id FROM fragments WHERE issue_id=?", (int(exact[1]),)):
                ranks[row["id"]] = 10
        query_semantics = "not_requested"
        query_cache = "not_requested"
        if semantic:
            query_semantics = "unavailable"
            query_cache = "unavailable"
            if self.vectors and self.embeddings and query.strip():
                try:
                    vector, query_cache = self.query_vector(query)
                    for rank, key in enumerate(self.vectors.query(vector)):
                        row = self.state.one("SELECT id FROM fragments WHERE vector_id=? AND version=vector_version", (key,))
                        if row:
                            ranks[row["id"]] = ranks.get(row["id"], 0) + 1 / (60 + rank)
                    query_semantics = "available"
                except Exception as exc:
                    query_semantics = str(exc)[:180]
        def matches(issue, names):
            if filters.get("project_id") and object_id(issue["project"]) != int(filters["project_id"]):
                return False
            if "status" in filters and object_id(issue.get("status")) != int(filters["status"]):
                return False
            for name, field in (("handler_id", "handler"), ("reporter_id", "reporter"),
                                ("priority", "priority"), ("severity", "severity")):
                if name in filters and object_id(issue.get(field)) != int(filters[name]):
                    return False
            for name in ("version", "target_version", "fixed_in_version"):
                if name in filters and str(issue.get(name) or "").casefold() != str(filters[name]).casefold():
                    return False
            tags = issue.get("tags", [])
            available = {str(object_id(t)) for t in tags} | {names.get(object_id(t), t.get("name", "")) for t in tags}
            if not set(map(str, filters.get("tags", []))) <= available:
                return False
            custom = {str(object_id(f.get("field"))): str(f.get("value", "")) for f in issue.get("custom_fields", [])}
            if any(custom.get(str(k)) != str(v) for k, v in filters.get("custom_fields", {}).items()):
                return False
            for field in ("created", "updated"):
                value = timestamp(issue.get(field + "_at"))
                if field + "_after" in filters and value < timestamp(filters[field + "_after"]):
                    return False
                if field + "_before" in filters and value > timestamp(filters[field + "_before"]):
                    return False
            return True
        def source_rows():
            records = {}
            keys = list(ranks)
            for start in range(0, len(keys), 400):
                batch = keys[start:start + 400]
                placeholders = ",".join("?" for _ in batch)
                records.update((row["id"], row) for row in self.state.all(
                    "SELECT f.id,f.issue_id,i.verified,i.hash AS issue_hash,f.kind,f.note_id,f.file_id,f.source,f.text"
                    " FROM fragments f JOIN issues i ON i.id=f.issue_id "
                    f"WHERE f.id IN ({placeholders})", batch))
            return records
        def source_version(records, tags):
            # put_issue commits the issue hash and all source fragments in one
            # transaction; vector-only progress does not change source content.
            return digest([sorted({(row["issue_id"], row["issue_hash"]) for row in records.values()}),
                           tags if filters.get("tags") else ""])
        def grouped():
            groups = {}
            records = source_rows()
            # Read only card/filter fields, once per issue. Joining the entire
            # issue (including every comment) to each fragment multiplies I/O.
            fields = ("summary", "project", "status", "tags", "custom_fields", "created_at", "updated_at",
                      "handler", "reporter", "priority", "severity", "version", "target_version", "fixed_in_version")
            paths = ",".join("'$." + field + "'" for field in fields)
            issue_ids = list({row["issue_id"] for row in records.values()})
            parsed = {}
            for start in range(0, len(issue_ids), 400):
                batch = issue_ids[start:start + 400]
                placeholders = ",".join("?" for _ in batch)
                for row in self.state.all(f"SELECT id,json_extract(data,{paths}) AS card FROM issues WHERE id IN ({placeholders})", batch):
                    parsed[row["id"]] = {key: value for key, value in zip(fields, json.loads(row["card"])) if value is not None}
            known_tags = self.state.one("SELECT data FROM catalog WHERE key='tags'")
            tags = known_tags["data"] if known_tags else "[]"
            names = {object_id(t): t.get("name", "") for t in json.loads(tags)}
            for key, rank in sorted(ranks.items(), key=lambda item: -item[1]):
                row = records.get(key)
                if not row or row["issue_id"] == similar_to or (mode != "all" and row["kind"] != {
                        "comments": "comment", "filenames": "filename",
                        "attachment_contents": "attachment_content"}[mode]):
                    continue
                issue = parsed.get(row["issue_id"])
                if not issue or not matches(issue, names):
                    continue
                entry = groups.setdefault(row["issue_id"], {"id": row["issue_id"], "summary": str(issue.get("summary", ""))[:240],
                    "project": {"id": object_id(issue.get("project")), "name": str((issue.get("project") or {}).get("name", ""))[:120]},
                    "status": issue.get("status"), "created_at": issue.get("created_at"), "updated_at": issue.get("updated_at"),
                    "handler": issue.get("handler"), "score": 0, "matches": [],
                    "last_verified": row["verified"], "url": self.api.settings.base_url + f"/view.php?id={row['issue_id']}"})
                entry["score"] = max(entry["score"], rank)
                if len(entry["matches"]) < 3:
                    position = next((row["text"].casefold().find(t.casefold()) for t in tokens if t.casefold() in row["text"].casefold()), 0)
                    attachment = json.loads(row["source"]) if row["kind"] == "attachment_content" else {}
                    filename = (attachment.get("filename", "") if attachment else row["source"]
                                if row["kind"] == "filename" else "")
                    match = {"type": row["kind"], "note_id": row["note_id"], "file_id": row["file_id"],
                        "filename": filename[:1000], "filename_truncated": len(filename) > 1000,
                        "snippet": row["text"][max(0, position - 70):max(0, position - 70) + 280],
                        "url": entry["url"] + (f"#c{row['note_id']}" if row["note_id"] else "")}
                    if attachment:
                        match["location"] = attachment.get("location", {})
                        match["file_url"] = self.api.settings.base_url + \
                            f"/file_download.php?file_id={int(row['file_id'])}&type=bug"
                    entry["matches"].append(match)
            if sort_by == "relevance":
                ordered = sorted(groups.values(), key=lambda r: (-r["score"], r["id"]))
            else:
                ordered = sorted(groups.values(), key=lambda r: (timestamp(r.get(sort_by)), r["id"]), reverse=True)
            return ordered, source_version(records, tags), issue_ids
        initial, initial_version, issue_ids = grouped()
        revision = self.state.revision()
        refresh_deadline = time.monotonic() + 10
        checked = set()
        for issue in initial[offset:offset + limit]:
            if time.monotonic() > refresh_deadline:
                break
            try:
                _, _, stale = self.refresh(issue["id"])
                if not stale:
                    checked.add(issue["id"])
                else:
                    break
            except ApiError:
                pass
        final_records = {}
        for start in range(0, len(issue_ids), 400):
            batch = issue_ids[start:start + 400]
            placeholders = ",".join("?" for _ in batch)
            final_records.update((row["issue_id"], row) for row in self.state.all(
                f"SELECT id AS issue_id,hash AS issue_hash,verified FROM issues WHERE id IN ({placeholders})", batch))
        final_tags = self.state.one("SELECT data FROM catalog WHERE key='tags'") if filters.get("tags") else None
        if self.state.revision() != revision and (mode == "attachment_contents" or any(
                match["type"] == "attachment_content" for issue in initial for match in issue["matches"])):
            return {"ok": False, "status": "results_changed",
                    "continuation": "Repeat search without cursor; attachment content changed during this page"}
        if source_version(final_records, final_tags["data"] if final_tags else "[]") != initial_version:
            # A refresh can invalidate the matching text, not just pagination.
            return {"ok": False, "status": "results_changed", "continuation": "Repeat search without cursor; matched issues were refreshed"}
        groups = initial
        verified = {row["issue_id"]: row["verified"] for row in final_records.values()}
        for entry in groups:
            entry["last_verified"] = verified[entry["id"]]
            entry["access_check"] = "fresh" if entry["id"] in checked else "cached"
        snapshot = self.state.health()
        corpus_status = "partial" if self.semantic_status == "ready" and snapshot["embedding_backlog"] else self.semantic_status
        result = {"ok": True, "issues": [], "next_cursor": "", "similar_to": similar_to or None,
                "similarity_mode": ("semantic" if query_semantics == "available" else "lexical_fallback") if similar_to else None,
                "candidate_limit": 10000, "candidate_window_limited": len(ranks) >= 10000,
                "semantic_query": query_semantics, "semantic_corpus": corpus_status,
                "query_embedding_cache": query_cache,
                "attachment_extraction": {"enabled": self.attachment_enabled,
                                           **self.state.attachment_status()},
                "mantis": self.remote_status, "silent_changes": "Newly visible sources without updated_at require an issue refresh",
                "index": {"issues": snapshot["issues"], "embedding_backlog": snapshot["embedding_backlog"],
                          "projects": len(snapshot["projects"]), "projects_pending": sum(p["status"] not in {"current", "access_removed"} for p in snapshot["projects"])},
                "output_char_limit": 12000}
        for entry in groups[offset:offset + limit]:
            result["issues"].append(entry)
            # Reserve space for the cursor; even an unfiltered request remains
            # bounded. Page advance uses emitted cards, not the requested limit.
            if len(encode(result)) > 11600:
                result["issues"].pop()
                if not result["issues"]:
                    raise ValueError("One result exceeds the compact output budget; narrow the query or read its exact issue ID")
                break
        emitted = len(result["issues"])
        if len(groups) > offset + emitted:
            result["next_cursor"] = base64.urlsafe_b64encode(encode({"query": identity, "revision": revision, "offset": offset + emitted}).encode()).decode()
        return result
