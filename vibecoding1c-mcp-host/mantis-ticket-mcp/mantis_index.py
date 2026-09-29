"""Incremental sync, hybrid search and recoverable vector projection."""
from __future__ import annotations

import base64
import json
import math
import os
import re
import shutil
import threading
import time
import uuid
from array import array
from collections import OrderedDict
from concurrent.futures import Future
from pathlib import Path
from urllib.request import Request, urlopen

from mantis_api import ApiError
from mantis_state import PROFILE, State, digest, encode, object_id, timestamp, is_link


QUERY_EMBEDDING_CACHE_SIZE = 256


class Vectors:
    def __init__(self, state: State, dimension=4096, rebuild=False):
        import zvec
        self.z = zvec
        self.state = state
        self.dimension = dimension
        self.lock = threading.RLock()
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

    def upsert(self, key, vector):
        if len(vector) != self.dimension or not all(math.isfinite(v) for v in vector):
            raise ValueError("Embedding dimension or finite-value check failed")
        with self.lock:
            result = self.collection.upsert(self.z.Doc(id=key, vectors={"embedding": vector}))
            if not result.ok():
                raise RuntimeError("Zvec rejected an embedding")
            self.collection.flush()

    def query(self, vector, limit=200):
        with self.lock:
            return [doc.id for doc in self.collection.query(self.z.Query(field_name="embedding", vector=vector), topk=limit)]

    def existing(self, keys):
        with self.lock:
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
            generation = uuid.uuid4().hex
            new = self._create(self.root / generation)
            try:
                rows = self.state.all("SELECT vector_id FROM fragments WHERE vector_id<>'' AND vector_version=version")
                for start in range(0, len(rows), 100):
                    docs = self.collection.fetch([r["vector_id"] for r in rows[start:start + 100]])
                    if docs:
                        result = new.upsert(list(docs.values()))
                        if not all(s.ok() for s in result):
                            raise RuntimeError("Zvec purge projection failed")
                new.flush()
                self.state.run("INSERT OR REPLACE INTO meta VALUES('vector_generation',?)", (generation,))
                old = self.collection
                self.collection, self.generation = new, generation
                old.close()
                self._remove_old()
                self.state.cleanup_files()
                self.state.run("DELETE FROM vector_deletes")
                self.state.run("UPDATE tombstones SET cleanup=0")
            except BaseException:
                if self.collection is not new:
                    new.close()
                raise

    def close(self):
        self.collection.close()


class Embeddings:
    def __init__(self, state, key, cap=5.0, max_price=0.04, timeout=20):
        if not math.isfinite(cap) or cap < 0 or not math.isfinite(max_price) or max_price <= 0:
            raise ValueError("Embedding budget and price must be finite non-negative amounts (price > 0)")
        self.state, self.key, self.cap, self.max_price, self.timeout = state, key, cap, max_price, timeout

    def embed(self, texts):
        if not self.key:
            raise RuntimeError("OpenRouter is not configured")
        # UTF-8 byte count is a conservative input-token bound for this tokenizer.
        reserve = (sum(len(text.encode("utf-8")) + 32 for text in texts)) * self.max_price / 1_000_000
        charge = self.state.reserve(reserve, self.cap)
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
        except Exception as exc:
            raise RuntimeError("Embedding request failed; its cost reservation remains pending") from exc


class Index:
    def __init__(self, state, api, vectors=None, embeddings=None, interval=30, overlap=300, sync_projects=()):
        self.state, self.api, self.vectors, self.embeddings = state, api, vectors, embeddings
        self.interval, self.overlap = max(1, interval), max(1, overlap)
        self.sync_projects = {int(project) for project in sync_projects}
        self.stop = threading.Event()
        self.paused = threading.Event()
        self.worker = None
        self.work_lock = threading.Lock()
        self._initial_progress = {}
        self._query_cache = OrderedDict()
        self._query_pending = {}
        self._query_lock = threading.Lock()
        self._query_hits = self._query_misses = self._query_shared = 0
        self.remote_status = "not_checked"
        self.semantic_status = "not_configured" if not embeddings or not vectors else "pending"
        self.cleanup()

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

    def embed_pending(self, batch=16):
        if not self.vectors or not self.embeddings:
            return
        selected = sorted(self.sync_projects)
        scope = " AND issue_id IN (SELECT id FROM issues WHERE project_id IN (" + ",".join("?" for _ in selected) + "))" if selected else ""
        rows = self.state.all("SELECT * FROM fragments WHERE version<>vector_version" + scope + " LIMIT ?", (*selected, batch))
        present = self.vectors.existing([digest([r["id"], r["version"]]) for r in rows])
        pending = []
        for row in rows:
            key = digest([row["id"], row["version"]])
            if key in present:
                with self.state.lock:
                    if self.state.run("UPDATE fragments SET vector_id=?,vector_version=? WHERE id=? AND version=?",
                                      (key, row["version"], row["id"], row["version"])).rowcount:
                        self.state.changed()
            else:
                pending.append(row)
        rows = pending
        if not rows:
            self.semantic_status = "partial" if self.state.health()["embedding_backlog"] else "ready"
            return
        values = self.embeddings.embed([r["text"] for r in rows])
        for row, vector in zip(rows, values):
            with self.state.lock:
                current = self.state.one("SELECT version FROM fragments WHERE id=?", (row["id"],))
                if not current or current["version"] != row["version"]:
                    continue
                key = digest([row["id"], row["version"]])
                self.vectors.upsert(key, vector)
                self.state.run("UPDATE fragments SET vector_id=?,vector_version=? WHERE id=? AND version=?",
                               (key, row["version"], row["id"], row["version"]))
                self.state.changed()
        self.semantic_status = "partial" if self.state.health()["embedding_backlog"] else "ready"

    def tick(self):
        if not self.work_lock.acquire(blocking=False):
            return
        try:
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
                    self.sync_project(project["id"])
                except Exception as exc:
                    self.state.run("UPDATE projects SET error=?,status=CASE WHEN status='initializing' THEN status ELSE 'retrying' END WHERE id=?", (str(exc)[:300], project["id"]))
                # Do not defer all vectors until the last project's import.
                if not self.paused.is_set() and not self.stop.is_set() and time.monotonic() >= next_embeddings:
                    try:
                        self.embed_pending()
                    except Exception as exc:
                        self.semantic_status = str(exc)[:200]
                    next_embeddings = time.monotonic() + 5
            try:
                self.cleanup()
                until = time.monotonic() + 5
                for _ in range(8):
                    self.embed_pending(batch=64)
                    if self.stop.is_set() or self.paused.is_set() or self.semantic_status == "ready" or time.monotonic() >= until:
                        break
            except Exception as exc:
                self.semantic_status = str(exc)[:200]
        finally:
            self.work_lock.release()

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

    def close(self):
        self.stop.set()
        if self.worker:
            self.worker.join(timeout=self.api.settings.timeout_seconds * 6 + 5)
            if self.worker.is_alive():
                raise RuntimeError("Mantis worker is still stopping; keep its state owner open")
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

    def search(self, query, filters=None, mode="all", limit=10, cursor="", semantic=True):
        if mode not in {"all", "comments", "filenames"}:
            raise ValueError("mode must be all, comments or filenames")
        if not isinstance(query, str) or len(query) > 2000:
            raise ValueError("Query must be at most 2000 characters")
        filters = filters or {}
        allowed = {"project_id", "status", "tags", "custom_fields", "created_after", "created_before", "updated_after", "updated_before"}
        if set(filters) - allowed:
            raise ValueError("Unsupported filters: " + ", ".join(sorted(set(filters) - allowed)))
        if filters.get("custom_fields"):
            if not filters.get("project_id"):
                raise ValueError("custom_fields requires project_id and project metadata")
            meta = self.metadata(filters["project_id"])
            definitions = {str(f["field"]["id"]): f for f in meta["custom_fields"]}
            if set(map(str, filters["custom_fields"])) - definitions.keys():
                raise ValueError("Unknown custom field for this project; call mantis_metadata")
        limit = max(1, min(int(limit), 20))
        identity = digest([query, filters, mode, semantic])
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
            source_kind = {"comments": "comment", "filenames": "filename"}.get(mode)
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
        def grouped():
            groups = {}
            versions = []
            records = {}
            keys = list(ranks)
            for start in range(0, len(keys), 400):
                batch = keys[start:start + 400]
                placeholders = ",".join("?" for _ in batch)
                records.update((row["id"], row) for row in self.state.all(
                    "SELECT f.*,i.data,i.verified,i.hash AS issue_hash FROM fragments f JOIN issues i ON i.id=f.issue_id "
                    f"WHERE f.id IN ({placeholders})", batch))
            known_tags = self.state.one("SELECT data FROM catalog WHERE key='tags'")
            names = {object_id(t): t.get("name", "") for t in json.loads(known_tags["data"])} if known_tags else {}
            parsed = {}
            for key, rank in sorted(ranks.items(), key=lambda item: -item[1]):
                row = records.get(key)
                if not row or (mode != "all" and row["kind"] != {"comments": "comment", "filenames": "filename"}[mode]):
                    continue
                version = (row["issue_id"], row["issue_hash"])
                if version not in parsed:
                    parsed[version] = json.loads(row["data"])
                issue = parsed[version]
                if not matches(issue, names):
                    continue
                versions.append((key, row["version"], row["issue_hash"]))
                entry = groups.setdefault(row["issue_id"], {"id": row["issue_id"], "summary": str(issue.get("summary", ""))[:240],
                    "project": {"id": object_id(issue.get("project")), "name": str((issue.get("project") or {}).get("name", ""))[:120]},
                    "status": issue.get("status"), "score": 0, "matches": [],
                    "last_verified": row["verified"], "url": self.api.settings.base_url + f"/view.php?id={row['issue_id']}"})
                entry["score"] = max(entry["score"], rank)
                if len(entry["matches"]) < 3:
                    position = next((row["text"].casefold().find(t.casefold()) for t in tokens if t.casefold() in row["text"].casefold()), 0)
                    entry["matches"].append({"type": row["kind"], "note_id": row["note_id"], "file_id": row["file_id"],
                        "filename": row["source"][:1000] if row["kind"] == "filename" else "",
                        "filename_truncated": row["kind"] == "filename" and len(row["source"]) > 1000,
                        "snippet": row["text"][max(0, position - 70):max(0, position - 70) + 280],
                        "url": entry["url"] + (f"#c{row['note_id']}" if row["note_id"] else "")})
            return sorted(groups.values(), key=lambda r: (-r["score"], r["id"])), digest(versions)
        initial, initial_version = grouped()
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
        groups, final_version = grouped()
        if final_version != initial_version:
            # A refresh can invalidate the matching text, not just pagination.
            return {"ok": False, "status": "results_changed", "continuation": "Repeat search without cursor; matched issues were refreshed"}
        for entry in groups:
            entry["access_check"] = "fresh" if entry["id"] in checked else "cached"
        snapshot = self.state.health()
        corpus_status = "partial" if self.semantic_status == "ready" and snapshot["embedding_backlog"] else self.semantic_status
        result = {"ok": True, "issues": [], "next_cursor": "",
                "candidate_limit": 10000, "candidate_window_limited": len(ranks) >= 10000,
                "semantic_query": query_semantics, "semantic_corpus": corpus_status,
                "query_embedding_cache": query_cache,
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
