"""Owner-local durable vectors; corpus generations remain immutable."""
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import numpy as np

from sppr_core import SpprError, atomic_json, now


SCHEMA = """
CREATE TABLE IF NOT EXISTS vectors(
    profile TEXT NOT NULL,
    hash TEXT NOT NULL,
    vector BLOB NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(profile, hash)
) WITHOUT ROWID;
"""


def cached_reader_file(path, *, keep):
    """Copy immutable publications off slow host mounts before random SQLite reads."""
    location = os.environ.get("SPPR_READER_CACHE_DIR")
    if not location:
        return path
    cache = Path(location)
    if not cache.is_absolute():
        raise SpprError("SPPR reader cache directory must be absolute.")
    try:
        cache.mkdir(parents=True, exist_ok=True)
        target = cache / path.name
        if not target.is_file() or target.stat().st_size != path.stat().st_size:
            staging = cache / (path.name + "." + uuid4().hex + ".tmp")
            try:
                shutil.copyfile(path, staging)
                os.replace(staging, target)
            finally:
                staging.unlink(missing_ok=True)
        pattern = (r"vectors-[0-9a-f]{32}\.sqlite" if path.name.startswith("vectors-")
                   else r"[0-9a-f]{32}\.sqlite")
        old = sorted((item for item in cache.iterdir() if re.fullmatch(pattern, item.name)),
                     key=lambda item: item.stat().st_mtime, reverse=True)
        for item in old[keep:]:
            if item != target:
                item.unlink(missing_ok=True)
        return target
    except OSError:
        raise SpprError("SPPR reader cache is unavailable; check free space and permissions.") from None


class VectorJournal:
    def __init__(self, settings):
        self.path = Path(settings.state) / "vectors.sqlite"
        self.active = Path(settings.state) / "vector_active.json"
        self.dimension = settings.dimension

    def open_writer(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        new_file = not self.path.exists()
        db = sqlite3.connect(self.path, timeout=30)
        try:
            # Readers run in a read-only Docker bind mount. DELETE mode needs no
            # writable -shm file and each short transaction is visible atomically.
            db.execute("PRAGMA journal_mode=DELETE")
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA busy_timeout=30000")
            if new_file:
                db.execute("PRAGMA auto_vacuum=INCREMENTAL")
                db.execute("VACUUM")
            db.executescript(SCHEMA)
            return db
        except Exception:
            db.close()
            raise

    def snapshot(self):
        try:
            data = json.loads(self.active.read_text(encoding="utf-8"))
            if not re.fullmatch(r"[0-9a-f]{32}", data["generation"]):
                raise ValueError()
            if type(data["count"]) is not int or data["count"] < 0:
                raise ValueError()
            if datetime.fromisoformat(data["published_at"]).tzinfo is None:
                raise ValueError()
            path = self.active.parent / ("vectors-" + data["generation"] + ".sqlite")
            if not path.is_file():
                raise ValueError()
            return data, path
        except FileNotFoundError:
            return None, None
        except (ValueError, KeyError, TypeError):
            raise SpprError("Published vector snapshot is invalid; restore a verified snapshot or republish from the journal.") from None

    def attach_reader(self, db, *, live=False):
        if live and self.path.exists():
            path, query = self.path, "?mode=ro"
        elif not live:
            _, path = self.snapshot()
            query = "?mode=ro&immutable=1"
        else:
            path = None
        if path is not None:
            if not live:
                path = cached_reader_file(path, keep=2)
            db.execute("ATTACH DATABASE ? AS vec", (path.resolve().as_uri() + query,))
        else:
            # Legacy snapshots and lexical-only corpora have no published vectors.
            db.execute("ATTACH DATABASE ':memory:' AS vec")
            db.executescript(SCHEMA.replace("vectors(", "vec.vectors("))

    def publish_snapshot(self, *, force=False, complete=False, min_new=5000, max_age_seconds=900):
        if not self.path.exists():
            return None
        prior, _ = self.snapshot()
        with closing(self.open_writer()) as source:
            count = source.execute("SELECT COUNT(*) FROM vectors").fetchone()[0]
            if count == 0:
                return prior
            old_count = prior["count"] if prior else 0
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(prior["published_at"])).total_seconds() if prior else float("inf")
            if not force and count == old_count:
                return prior
            if not force and not complete and abs(count - old_count) < min_new and age < max_age_seconds:
                return prior
            generation = uuid4().hex
            staging = self.path.parent / ("vectors-" + generation + ".staging")
            completed = self.path.parent / ("vectors-" + generation + ".sqlite")
            begun = time.monotonic()
            try:
                with closing(sqlite3.connect(staging)) as target:
                    source.backup(target)
                    if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                        raise SpprError("Vector snapshot integrity failed; previous vectors remain active.")
                os.replace(staging, completed)
                result = {"generation": generation, "count": count, "published_at": now(),
                          "snapshot_bytes": completed.stat().st_size,
                          "elapsed_seconds": round(time.monotonic() - begun, 3)}
                atomic_json(self.active, result)
                self.prune_snapshots(generation)
                return result
            finally:
                staging.unlink(missing_ok=True)

    def prune_snapshots(self, active):
        try:
            files = sorted((p for p in self.path.parent.glob("vectors-*.sqlite")
                            if re.fullmatch(r"vectors-[0-9a-f]{32}", p.stem)),
                           key=lambda p: p.stat().st_mtime, reverse=True)
        except OSError:
            return
        for path in files[2:]:
            if path.stem != "vectors-" + active:
                try:
                    path.unlink()
                except OSError:
                    pass

    def insert(self, profile, rows, db=None):
        if not rows:
            return 0
        values = []
        for hashed, value in rows:
            blob = value.astype(np.float32).tobytes() if isinstance(value, np.ndarray) else value
            if not isinstance(blob, bytes) or len(blob) != self.dimension * 4:
                raise SpprError("Embedding vector has an invalid size; no batch was saved.")
            values.append((profile, hashed, blob, now()))
        owned = db is None
        if owned:
            db = self.open_writer()
        try:
            before = db.total_changes
            db.executemany("INSERT OR IGNORE INTO vectors VALUES(?,?,?,?)", values)
            db.commit()
            return db.total_changes - before
        finally:
            if owned:
                db.close()

    def prune(self, generations):
        if not self.path.exists():
            return 0
        with closing(self.open_writer()) as db:
            db.execute("CREATE TEMP TABLE keep(profile TEXT,hash TEXT,PRIMARY KEY(profile,hash)) WITHOUT ROWID")
            for path in generations:
                with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as snapshot:
                    profile = json.loads(snapshot.execute("SELECT data FROM metadata").fetchone()[0])["profile"]
                    rows = snapshot.execute("SELECT DISTINCT hash FROM fragments")
                    while batch := rows.fetchmany(1000):
                        db.executemany("INSERT OR IGNORE INTO keep VALUES(?,?)",
                                       [(profile, hashed) for (hashed,) in batch])
            before = db.total_changes
            db.execute("DELETE FROM vectors WHERE NOT EXISTS(SELECT 1 FROM keep k WHERE k.profile=vectors.profile AND k.hash=vectors.hash)")
            deleted = db.total_changes - before
            db.commit()
            if deleted:
                db.execute("PRAGMA incremental_vacuum")
            return deleted


def coverage(db, profile):
    # Two sequential scans avoid one random lookup into the vector file per
    # fragment, which is prohibitively slow on Docker Desktop bind mounts.
    hashes = {row[0] for row in db.execute("SELECT hash FROM vec.vectors WHERE profile=?", (profile,))}
    fragments = ready = 0
    for hashed, embedded in db.execute("SELECT hash,vector IS NOT NULL FROM fragments"):
        fragments += 1
        ready += embedded or hashed in hashes
    return {"fragments": fragments, "vectors": ready, "pending": fragments - ready}
