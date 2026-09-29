"""One native writer publishes closed SQLite generations; MCP opens them read-only."""
from __future__ import annotations

import json
import os
import re
import sqlite3
from contextlib import closing, contextmanager
from pathlib import Path
from uuid import uuid4

from sppr_core import Policy, SpprError, atomic_json, canonical, digest, fragments, now
from sppr_vectors import VectorJournal, coverage as vector_coverage


@contextmanager
def writer_lock(state, name="collector.lock"):
    state.mkdir(parents=True, exist_ok=True)
    # OS releases this advisory lock on crash; never guess a PID or remove a stale lock.
    stream = (state / name).open("a+b")
    if os.fstat(stream.fileno()).st_size == 0:
        stream.write(b"0")
        stream.flush()
    stream.seek(0)
    locked = False
    try:
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locked = True
    except (OSError, BlockingIOError):
        stream.close()
        raise SpprError("A collection is already running; inspect index status and wait for completion.") from None
    try:
        yield
    finally:
        if locked:
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_UN)
        stream.close()


class Store:
    def __init__(self, settings):
        self.settings = settings
        self.state = settings.state
        self.vectors = VectorJournal(settings)

    def manifest(self):
        try:
            data = json.loads((self.state / "active.json").read_text(encoding="utf-8"))
            if not re.fullmatch(r"[0-9a-f]{32}", data["generation"]):
                raise ValueError()
            if data["source"] != self.settings.source_id:
                raise SpprError("Index belongs to another source; configure a separate SPPR state directory.")
            return data
        except FileNotFoundError:
            raise SpprError("No completed index; run the collector in its allowed window first.") from None
        except (ValueError, KeyError, TypeError):
            raise SpprError("Active manifest is invalid; use collector rollback to a verified generation.") from None

    @contextmanager
    def reader(self, *, live_vectors=False):
        manifest = self.manifest()
        path = self.state / (manifest["generation"] + ".sqlite")
        connection = None
        try:
            connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            connection.row_factory = sqlite3.Row
            self.vectors.attach_reader(connection, live=live_vectors)
        except sqlite3.Error:
            if connection is not None:
                connection.close()
            raise SpprError("Active generation is unavailable; retry or restore a completed generation.") from None
        try:
            yield connection, manifest
        finally:
            connection.close()

    def previous(self):
        if not (self.state / "active.json").exists():
            return {}, {}
        with self.reader() as (db, manifest):
            objects = {r["id"]: json.loads(r["data"]) for r in db.execute("SELECT id,data FROM objects")}
            vectors = {}
            if manifest["profile"] == self.settings.profile and manifest.get("vector_storage") != "journal":
                vectors = {r["hash"]: r["vector"] for r in db.execute("SELECT hash,vector FROM fragments WHERE vector IS NOT NULL")}
            return objects, vectors

    def semantic_progress(self, db, manifest):
        return vector_coverage(db, manifest["profile"])

    def pending_page(self, db, policy, profile, after_id, limit=256):
        if not policy.projects:
            return []
        placeholders = ",".join("?" for _ in policy.projects)
        return db.execute(f"""
            SELECT f.id,f.hash,f.text FROM fragments f
            WHERE f.id>? AND f.vector IS NULL
              AND NOT EXISTS(SELECT 1 FROM vec.vectors v WHERE v.profile=? AND v.hash=f.hash)
              AND EXISTS(SELECT 1 FROM roots r WHERE r.object_id=f.object_id AND r.project IN ({placeholders}))
            ORDER BY f.id LIMIT ?
        """, (after_id, profile, *sorted(policy.projects), limit)).fetchall()

    def publish(self, collection, policy, previous_vectors=None, before=lambda: None):
        before()
        self.state.mkdir(parents=True, exist_ok=True)
        # A one-time legacy import is committed before the new lexical snapshot.
        # Interrupted runs therefore never have to buy already saved vectors again.
        with closing(self.vectors.open_writer()) as journal:
            self.vectors.insert(self.settings.profile, (previous_vectors or {}).items(), journal)
        generation = uuid4().hex
        staging = self.state / (generation + ".staging")
        completed = self.state / (generation + ".sqlite")
        db = sqlite3.connect(staging, uri=True)
        coverage = dict(collection.coverage)
        coverage.update({"fragments": 0, "vectors": 0})
        manifest = {"generation": generation, "source": self.settings.source_id,
                    "profile": self.settings.profile, "observed_start": collection.started,
                    "observed_end": collection.finished, "published_at": now(), "coverage": coverage,
                    "mode": "nightly_reconciliation", "vector_storage": "journal",
                    "objects": len(collection.objects),
                    "edges": len(collection.edges), "policy": policy.token}
        try:
            db.executescript("""
                CREATE TABLE objects(id TEXT PRIMARY KEY,kind TEXT,project TEXT,data TEXT NOT NULL);
                CREATE TABLE roots(object_id TEXT,project TEXT,PRIMARY KEY(object_id,project));
                CREATE TABLE edges(id TEXT PRIMARY KEY,source TEXT,target TEXT,relation TEXT,data TEXT NOT NULL);
                CREATE INDEX edges_source ON edges(source); CREATE INDEX edges_target ON edges(target);
                CREATE TABLE fragments(id INTEGER PRIMARY KEY,object_id TEXT,edge_id TEXT,field TEXT,
                    offset INTEGER,text TEXT,hash TEXT,vector BLOB);
                CREATE INDEX fragments_object ON fragments(object_id);
                CREATE VIRTUAL TABLE search_text USING fts5(text,tokenize='unicode61');
                CREATE TABLE metadata(data TEXT NOT NULL);
            """)
            self.vectors.attach_reader(db)
            docs = []
            for obj in collection.objects.values():
                if not policy.permits(obj["roots"]):
                    raise SpprError("Object has no allowed provenance; discard collection and review scope.")
                db.execute("INSERT INTO objects VALUES(?,?,?,?)", (obj["id"], obj["kind"], obj["project"], canonical(obj)))
                db.executemany("INSERT INTO roots VALUES(?,?)", [(obj["id"], p) for p in obj["roots"]])
                fields = dict(obj["fields"])
                fields["title"] = {"state": "value", "value": obj["title"]}
                docs.extend((obj["id"], None, part) for part in fragments(fields, self.settings.chunk_chars))
            for edge in collection.edges:
                db.execute("INSERT INTO edges VALUES(?,?,?,?,?)", (edge["id"], edge["source"], edge["target"], edge["relation"], canonical(edge)))
                docs.extend((edge["source"], edge["id"], part) for part in fragments(edge["fields"], self.settings.chunk_chars))
            for index, (object_id, edge_id, part) in enumerate(docs):
                if index % 256 == 0:
                    before()
                    policy.unchanged(self.settings.policy)
                text = part["text"]
                hashed = digest([self.settings.profile, text])
                cursor = db.execute("INSERT INTO fragments(object_id,edge_id,field,offset,text,hash,vector) VALUES(?,?,?,?,?,?,?)",
                                    (object_id, edge_id, part["field"], part["offset"], text, hashed, None))
                db.execute("INSERT INTO search_text(rowid,text) VALUES(?,?)", (cursor.lastrowid, text))
                coverage["fragments"] += 1
            coverage["vectors"] = vector_coverage(db, self.settings.profile)["vectors"]
            manifest["semantic_complete"] = coverage["vectors"] == coverage["fragments"]
            db.execute("INSERT INTO metadata VALUES(?)", (canonical(manifest),))
            db.commit()
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise SpprError("Staged index integrity failed; previous generation retained.")
            db.close()
            before()
            policy.unchanged(self.settings.policy)
            os.replace(staging, completed)
            atomic_json(self.state / "active.json", manifest)
            self.prune(generation)
            try:
                # One immutable vector checkpoint per nightly reconciliation at
                # most, after the lexical corpus is already visible to readers.
                self.vectors.publish_snapshot(force=True)
            except (OSError, sqlite3.Error, SpprError):
                # The worker can republish durable journal rows independently.
                pass
            return manifest
        finally:
            db.close()
            staging.unlink(missing_ok=True)

    def prune(self, active):
        try:
            generations = sorted((p for p in self.state.glob("*.sqlite") if re.fullmatch(r"[0-9a-f]{32}", p.stem)),
                                 key=lambda p: p.stat().st_mtime, reverse=True)
        except OSError:
            # Cleanup is best effort after publication; it cannot invalidate an active snapshot.
            return
        for path in generations[self.settings.generations_to_keep:]:
            if path.stem != active and re.fullmatch(r"[0-9a-f]{32}", path.stem):
                try:
                    path.unlink()
                except OSError:
                    # Windows keeps an open reader's file pinned. Retry on the next publish.
                    pass
        try:
            retained = [p for p in generations if p.exists()]
            self.vectors.prune(retained)
        except (OSError, sqlite3.Error, ValueError, KeyError):
            # Reclaiming unused vectors is best effort, never a publication gate.
            pass

    def rollback(self, generation):
        if not re.fullmatch(r"[0-9a-f]{32}", generation):
            raise SpprError("Use a completed generation identifier from the state directory.")
        path = self.state / (generation + ".sqlite")
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise SpprError("Rollback generation failed integrity verification.")
            data = json.loads(db.execute("SELECT data FROM metadata").fetchone()[0])
            if data["source"] != self.settings.source_id or data["generation"] != generation:
                raise SpprError("Rollback source/generation mismatch.")
        Policy.load(self.settings.policy)  # Fail closed; never restore the old policy.
        atomic_json(self.state / "active.json", data)
        return data
