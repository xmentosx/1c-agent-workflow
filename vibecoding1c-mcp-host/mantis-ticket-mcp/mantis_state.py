"""The Mantis service's durable state. No dependency on another MCP owner."""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from mantis_extract import PARSER_VERSION, SUPPORTED, extension


SCHEMA_VERSION = 1
PROFILE = "qwen/qwen3-embedding-8b:4096:chars1800-overlap180-v1"
OWNER = "itl-mantis-ticket-state-v1"


def is_link(path):
    return path.is_symlink() or getattr(path, "is_junction", lambda: False)()


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(encode(value).encode("utf-8")).hexdigest()


def object_id(value):
    return int(value.get("id", 0) if isinstance(value, dict) else value or 0)


def timestamp(value):
    if not value:
        return 0.0
    if isinstance(value, (float, int)):
        return float(value)
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Mantis timestamp must include its server timezone")
    return parsed.timestamp()


def clean_issue(issue):
    """Retain API source text/metadata, never attachment bytes or extracted text."""
    result = json.loads(encode(issue))
    for owner in [result] + result.get("notes", []):
        for key in ("attachments", "files"):
            if key in owner:
                owner[key] = [{k: v for k, v in f.items() if k in {
                    "id", "filename", "name", "size", "content_type", "file_type",
                    "created_at", "reporter", "bugnote_id", "note_id"}}
                    for f in owner[key]]
    return result


def sources(issue):
    issue_id = int(issue["id"])
    for name in ("summary", "description", "steps_to_reproduce", "additional_information"):
        if issue.get(name):
            yield f"{issue_id}:{name}", name, 0, 0, str(issue[name])
    for note in issue.get("notes") or []:
        if note.get("text"):
            yield f"{issue_id}:note:{note['id']}", "comment", int(note["id"]), 0, str(note["text"])
    seen = set()
    # Notes first: the same file can also appear in the issue attachment list.
    for owner in (issue.get("notes") or []) + [issue]:
        note_id = int(owner["id"]) if owner is not issue else 0
        for file in (owner.get("attachments") or []) + (owner.get("files") or []):
            file_id = int(file["id"])
            if file_id not in seen:
                seen.add(file_id)
                parent = note_id or object_id(file.get("bugnote_id") or file.get("note_id"))
                yield f"{issue_id}:file:{file_id}", "filename", parent, file_id, str(file.get("filename") or file.get("name") or "")


def file_descriptors(issue):
    """Visible Mantis file IDs are immutable source identities; metadata detects replacement."""
    result = {}
    for owner in (issue.get("notes") or []) + [issue]:
        parent = int(owner["id"]) if owner is not issue else 0
        for file in (owner.get("attachments") or []) + (owner.get("files") or []):
            file_id = int(file["id"])
            if file_id in result:
                continue
            name = str(file.get("filename") or file.get("name") or "")
            note_id = parent or object_id(file.get("bugnote_id") or file.get("note_id"))
            descriptor = digest([PARSER_VERSION, file_id, note_id, name, file.get("size"),
                                 file.get("created_at"), file.get("content_type") or file.get("file_type")])
            result[file_id] = {"descriptor": descriptor, "filename": name, "note_id": note_id,
                               "size": int(file.get("size") or 0)}
    return result


class State:
    def __init__(self, root: Path, attachments: Path, clock=time.time):
        self.root = Path(root).resolve()
        self.attachments = Path(attachments).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        marker = self.root / "owner.json"
        if marker.exists():
            if json.loads(marker.read_text(encoding="utf-8")).get("owner") != OWNER:
                raise RuntimeError("State directory belongs to another owner; configure a separate empty Mantis statePath")
        elif any(p.name != "owner.lock" for p in self.root.iterdir()):
            raise RuntimeError("Unrecognized non-empty state directory; configure a separate empty Mantis statePath")
        self.clock = clock
        self.lock = threading.RLock()
        self.owner_file = (self.root / "owner.lock").open("a+b")
        self.owner_file.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                if self.owner_file.read(1) == b"":
                    self.owner_file.write(b"0")
                    self.owner_file.flush()
                self.owner_file.seek(0)
                msvcrt.locking(self.owner_file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.owner_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            self.owner_file.close()
            raise RuntimeError("Mantis state already has an owner; stop that Mantis instance before reusing its volume") from exc
        try:
            if not marker.exists():
                marker.write_text(encode({"owner": OWNER}), encoding="utf-8")
            existing_database = (self.root / "mantis.sqlite").exists()
            self.db = sqlite3.connect(str(self.root / "mantis.sqlite"), check_same_thread=False, isolation_level=None, timeout=10)
            self.db.row_factory = sqlite3.Row
            version = self.db.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, SCHEMA_VERSION):
                raise RuntimeError(f"Unsupported Mantis state schema {version}; use the matching binary and preserve this journal/revocation volume")
            self.db.executescript("""
                PRAGMA journal_mode=DELETE;
                PRAGMA secure_delete=ON;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT OR IGNORE INTO meta VALUES('revision','0');
                INSERT OR IGNORE INTO meta(key,value) SELECT 'source_revision',value FROM meta WHERE key='revision';
                UPDATE meta SET value=(SELECT value FROM meta WHERE key='revision')
                    WHERE key='source_revision' AND CAST(value AS INTEGER)<
                        (SELECT CAST(value AS INTEGER) FROM meta WHERE key='revision');
                CREATE TABLE IF NOT EXISTS projects(id INTEGER PRIMARY KEY, data TEXT NOT NULL,
                    checkpoint REAL NOT NULL DEFAULT 0, import_page INTEGER NOT NULL DEFAULT 1,
                    import_start REAL NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'initializing',
                    import_verify INTEGER NOT NULL DEFAULT 0, import_digest TEXT NOT NULL DEFAULT '',
                    previous_digest TEXT NOT NULL DEFAULT '',
                    verified REAL NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '');
                CREATE TABLE IF NOT EXISTS issues(id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL,
                    modified REAL NOT NULL, data TEXT NOT NULL, hash TEXT NOT NULL, etag TEXT NOT NULL,
                    verified REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS fragments(id TEXT PRIMARY KEY, issue_id INTEGER NOT NULL,
                    kind TEXT NOT NULL, note_id INTEGER NOT NULL, file_id INTEGER NOT NULL,
                    source TEXT NOT NULL, text TEXT NOT NULL, folded TEXT NOT NULL, version TEXT NOT NULL,
                    vector_version TEXT NOT NULL DEFAULT '', vector_id TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS fragments_issue ON fragments(issue_id);
                CREATE INDEX IF NOT EXISTS fragments_kind ON fragments(kind);
                CREATE INDEX IF NOT EXISTS fragments_vector ON fragments(vector_id);
                CREATE INDEX IF NOT EXISTS fragments_pending ON fragments(id) WHERE version<>vector_version;
                CREATE INDEX IF NOT EXISTS issues_search ON issues(id,hash,verified);
                CREATE INDEX IF NOT EXISTS issues_modified ON issues(modified DESC,id);
                CREATE VIRTUAL TABLE IF NOT EXISTS search_text USING fts5(id UNINDEXED, text, tokenize='unicode61');
                CREATE TABLE IF NOT EXISTS vector_deletes(id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS embedding_spool(fragment_id TEXT PRIMARY KEY,
                    version TEXT NOT NULL, vector BLOB NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS cache_deletes(issue_id INTEGER NOT NULL, file_id INTEGER NOT NULL,
                    PRIMARY KEY(issue_id,file_id));
                CREATE TABLE IF NOT EXISTS tombstones(issue_id INTEGER PRIMARY KEY, project_id INTEGER,
                    created REAL NOT NULL, cleanup INTEGER NOT NULL DEFAULT 1);
                CREATE TABLE IF NOT EXISTS project_revocations(project_id INTEGER PRIMARY KEY, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, actor TEXT NOT NULL,
                    issue_id INTEGER NOT NULL DEFAULT 0, project_id INTEGER NOT NULL DEFAULT 0,
                    payload_hash TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL,
                    steps TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL,
                    cancel_requested INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, actor TEXT NOT NULL,
                    action TEXT NOT NULL, object_id TEXT NOT NULL, outcome TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS charges(id TEXT PRIMARY KEY, month TEXT NOT NULL,
                    reserved REAL NOT NULL, actual REAL, status TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS catalog(key TEXT PRIMARY KEY, data TEXT NOT NULL, verified REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS delta_progress(project_id INTEGER NOT NULL, issue_id INTEGER NOT NULL,
                    modified REAL NOT NULL, signature TEXT NOT NULL, PRIMARY KEY(project_id,issue_id));
                CREATE TABLE IF NOT EXISTS attachment_extracts(issue_id INTEGER NOT NULL, file_id INTEGER NOT NULL,
                    descriptor TEXT NOT NULL, status TEXT NOT NULL, content_hash TEXT NOT NULL DEFAULT '',
                    segments TEXT NOT NULL DEFAULT '[]', error TEXT NOT NULL DEFAULT '',
                    retry_at REAL NOT NULL DEFAULT 0, updated REAL NOT NULL,
                    PRIMARY KEY(issue_id,file_id));
                CREATE INDEX IF NOT EXISTS attachment_extracts_work ON attachment_extracts(status,retry_at);
            """)
            self.db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
            # This is the sole profile in v1. Never silently rebuild a changed model.
            row = self.one("SELECT value FROM meta WHERE key='profile'")
            if row and row["value"] != PROFILE:
                raise RuntimeError("Mantis embedding profile differs; explicit index migration is required (keep journal and revocations)")
            self.run("INSERT OR IGNORE INTO meta VALUES('profile',?)", (PROFILE,))
            # An older index has no durable pause bit. Upgrading it starts paused
            # so a restarted worker cannot grow the disk before qualification.
            self.run("INSERT OR IGNORE INTO meta VALUES('index_paused',?)", ("1" if existing_database else "0",))
        except Exception:
            if hasattr(self, "db"):
                self.db.close()
            self.owner_file.close()
            raise

    def close(self):
        with self.lock:
            self.db.close()
            self.owner_file.close()

    @contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def run(self, sql, args=()):
        with self.lock:
            return self.db.execute(sql, args)

    def all(self, sql, args=()):
        with self.lock:
            return [dict(row) for row in self.db.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        rows = self.all(sql, args)
        return rows[0] if rows else None

    def revision(self):
        return int(self.one("SELECT value FROM meta WHERE key='revision'")["value"])

    def source_revision(self):
        return int(self.one("SELECT value FROM meta WHERE key='source_revision'")["value"])

    def changed(self, *, source=True):
        self.run("UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key IN ('revision','source_revision')"
                 if source else "UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")

    def audit(self, actor, action, target, outcome):
        self.run("INSERT INTO audit(actor,action,object_id,outcome,created) VALUES(?,?,?,?,?)",
                 (actor or "system", action, str(target), outcome, self.clock()))

    def put_catalog(self, key, data):
        self.run("INSERT OR REPLACE INTO catalog VALUES(?,?,?)", (key, encode(data), self.clock()))

    def put_issue(self, issue, etag="", observed_at=None):
        issue = clean_issue(issue)
        issue_id, project_id = int(issue["id"]), object_id(issue["project"])
        data, version = encode(issue), digest(issue)
        with self.transaction():
            revoked = self.one("SELECT created FROM tombstones WHERE issue_id=?", (issue_id,))
            if revoked and observed_at is not None and revoked["created"] >= observed_at:
                raise RuntimeError("Access changed during the read; retry a fresh issue read")
            revoked_project = self.one("SELECT created FROM project_revocations WHERE project_id=?", (project_id,))
            project = self.one("SELECT status FROM projects WHERE id=?", (project_id,))
            if (project and project["status"] == "access_removed") or (revoked_project and observed_at is not None and revoked_project["created"] >= observed_at):
                raise RuntimeError("Project access changed during the read; retry after a fresh project catalog")
            previous = self.one("SELECT hash FROM issues WHERE id=?", (issue_id,))
            self.run("INSERT OR REPLACE INTO issues VALUES(?,?,?,?,?,?,?)",
                     (issue_id, project_id, timestamp(issue.get("updated_at") or issue.get("last_updated")), data, version, etag, self.clock()))
            if previous and previous["hash"] == version:
                return False
            old = {row["id"]: row for row in self.all("SELECT * FROM fragments WHERE issue_id=?", (issue_id,))}
            visible = file_descriptors(issue)
            extracted = {row["file_id"]: row for row in self.all(
                "SELECT * FROM attachment_extracts WHERE issue_id=?", (issue_id,))}
            keep = set()
            replacements = []
            removed = set()
            for source, kind, note, file, text in sources(issue):
                plain = text if kind == "filename" else html.unescape(text)
                for index, start in enumerate(range(0, len(plain), 1620)):
                    fragment = plain[start:start + 1800]
                    key = f"{source}:{index}"
                    keep.add(key)
                    fragment_version = digest([PROFILE, fragment])
                    if key in old and old[key]["version"] == fragment_version:
                        continue
                    if key in old:
                        removed.add(key)
                    replacements.append((key, issue_id, kind, note, file, text if kind == "filename" else source,
                                         fragment, fragment.casefold(), fragment_version))
            for key, row in old.items():
                if row["kind"] == "attachment_content" and row["file_id"] in visible and \
                        row["file_id"] in extracted and extracted[row["file_id"]]["descriptor"] == visible[row["file_id"]]["descriptor"]:
                    keep.add(key)
            for key in old.keys() - keep:
                if old[key]["file_id"] and old[key]["file_id"] not in visible:
                    self.run("INSERT OR IGNORE INTO cache_deletes VALUES(?,?)", (issue_id, old[key]["file_id"]))
                removed.add(key)
            self._remove_fragments([old[key] for key in removed])
            for row in replacements:
                self.run("INSERT INTO fragments(id,issue_id,kind,note_id,file_id,source,text,folded,version) VALUES(?,?,?,?,?,?,?,?,?)", row)
                self.run("INSERT INTO search_text(id,text) VALUES(?,?)", (row[0], row[6]))
            for file_id, info in visible.items():
                previous_extract = extracted.get(file_id)
                if not previous_extract or previous_extract["descriptor"] != info["descriptor"]:
                    status = "pending" if extension(info["filename"]) in SUPPORTED else "unsupported"
                    self.run("INSERT OR REPLACE INTO attachment_extracts"
                             "(issue_id,file_id,descriptor,status,content_hash,segments,error,retry_at,updated)"
                             " VALUES(?,?,?,?,?,?,?,?,?)",
                             (issue_id, file_id, info["descriptor"], status, "", "[]",
                              "" if status == "pending" else "format", 0, self.clock()))
            for file_id in extracted.keys() - visible.keys():
                self.run("DELETE FROM attachment_extracts WHERE issue_id=? AND file_id=?", (issue_id, file_id))
            visible_notes = {int(note["id"]) for note in issue.get("notes", [])}
            visible_files = {file_id for _, _, _, file_id, _ in sources(issue) if file_id}
            if any((row["note_id"] and row["note_id"] not in visible_notes) or
                   (row["file_id"] and row["file_id"] not in visible_files) for row in old.values()):
                # A removed private source must not survive inside write payloads.
                self._redact_operations("issue_id", issue_id)
            self.changed()
        return True

    def _remove_fragments(self, rows):
        # FTS5's UNINDEXED id is not an ordinary indexed column. Resolve old
        # rowids once per batch, then delete by rowid. A new fragment never
        # scans the existing corpus. Existing v1 databases need no rebuild.
        for start in range(0, len(rows), 400):
            batch = rows[start:start + 400]
            ids = [row["id"] for row in batch]
            placeholders = ",".join("?" for _ in ids)
            spooled = {(row["fragment_id"], row["version"]) for row in self.all(
                f"SELECT fragment_id,version FROM embedding_spool WHERE fragment_id IN ({placeholders})", ids)}
            for row in self.all(f"SELECT rowid FROM search_text WHERE id IN ({placeholders})", ids):
                self.run("DELETE FROM search_text WHERE rowid=?", (row["rowid"],))
            for row in batch:
                # A flush can have read a paid vector from the spool but not
                # published its SQLite version yet. Queue its deterministic ID
                # before removing the spool so a crash cannot leave an orphan.
                key = row["vector_id"] or (digest([row["id"], row["version"]])
                                            if (row["id"], row["version"]) in spooled else "")
                if key:
                    self.run("INSERT OR IGNORE INTO vector_deletes VALUES(?)", (key,))
                self.run("DELETE FROM embedding_spool WHERE fragment_id=?", (row["id"],))
                self.run("DELETE FROM fragments WHERE id=?", (row["id"],))

    def enqueue_existing_attachments(self, limit=100):
        """Pace the v1 filename backfill; newly refreshed issues enqueue directly."""
        with self.transaction():
            saved = self.one("SELECT value FROM meta WHERE key='attachment_backfill_rowid'")
            cursor = int(saved["value"]) if saved else 0
            rows = self.all("SELECT f.rowid,f.issue_id,f.file_id,f.source FROM fragments f "
                            "JOIN issues i ON i.id=f.issue_id WHERE f.kind='filename' AND f.rowid>? "
                            "ORDER BY f.rowid LIMIT ?", (cursor, limit))
            for row in rows:
                status = "pending" if extension(row["source"]) in SUPPORTED else "unsupported"
                self.run("INSERT OR IGNORE INTO attachment_extracts"
                         "(issue_id,file_id,descriptor,status,content_hash,segments,error,retry_at,updated)"
                         " VALUES(?,?,?,?,?,?,?,?,?)", (row["issue_id"], row["file_id"], "", status,
                         "", "[]", "" if status == "pending" else "format", 0, self.clock()))
            if rows:
                self.run("INSERT OR REPLACE INTO meta VALUES('attachment_backfill_rowid',?)", (str(rows[-1]["rowid"]),))
            self.run("INSERT OR REPLACE INTO meta VALUES('attachment_backfill_complete',?)",
                     ("1" if len(rows) < limit else "0",))
            return len(rows)

    def next_attachment(self, retry_first=False):
        return self.one("SELECT e.*,i.data FROM attachment_extracts e JOIN issues i ON i.id=e.issue_id "
                        "WHERE e.status IN ('pending','source_unavailable') AND e.retry_at<=? "
                        "ORDER BY CASE WHEN (e.error<>'')=? THEN 0 ELSE 1 END,"
                        "e.updated DESC,e.issue_id,e.file_id LIMIT 1",
                        (self.clock(),int(retry_first)))

    def invalidate_attachment(self, issue_id, file_id, descriptor):
        with self.transaction():
            row = self.one("SELECT descriptor FROM attachment_extracts WHERE issue_id=? AND file_id=?", (issue_id,file_id))
            if not row or row["descriptor"] == descriptor:
                return
            old = self.all("SELECT * FROM fragments WHERE issue_id=? AND file_id=? AND kind='attachment_content'",
                           (issue_id,file_id))
            self._remove_fragments(old)
            self.run("UPDATE attachment_extracts SET descriptor=?,status='pending',content_hash='',segments='[]',"
                     "error='',retry_at=0,updated=? WHERE issue_id=? AND file_id=?",
                     (descriptor,self.clock(),issue_id,file_id))
            if old:
                self.changed()

    def publish_attachment(self, issue_id, file_id, descriptor, content_hash, result):
        """One transaction binds extracted text to the still-visible file descriptor."""
        with self.transaction():
            row = self.one("SELECT descriptor FROM attachment_extracts WHERE issue_id=? AND file_id=?",
                           (issue_id,file_id))
            issue_row = self.one("SELECT data FROM issues WHERE id=?", (issue_id,))
            if not row or not issue_row or row["descriptor"] != descriptor:
                return False
            info = file_descriptors(json.loads(issue_row["data"])).get(file_id)
            if not info or info["descriptor"] != descriptor:
                return False
            old = self.all("SELECT * FROM fragments WHERE issue_id=? AND file_id=? AND kind='attachment_content'",
                           (issue_id,file_id))
            self._remove_fragments(old)
            segments = result.get("segments", []) if result["status"] in {"ready", "partial"} else []
            for number, segment in enumerate(segments):
                text = str(segment["text"])
                key = f"{issue_id}:file:{file_id}:content:{number}"
                source = encode({"filename": info["filename"], "location": segment["location"]})
                self.run("INSERT INTO fragments(id,issue_id,kind,note_id,file_id,source,text,folded,version)"
                         " VALUES(?,?,?,?,?,?,?,?,?)", (key,issue_id,"attachment_content",info["note_id"],file_id,
                         source,text,text.casefold(),digest([PROFILE,text])))
                self.run("INSERT INTO search_text(id,text) VALUES(?,?)", (key,text))
            self.run("UPDATE attachment_extracts SET status=?,content_hash=?,segments=?,error=?,retry_at=0,updated=? "
                     "WHERE issue_id=? AND file_id=?", (result["status"],content_hash,encode(segments),
                     str(result.get("reason") or "")[:80],self.clock(),issue_id,file_id))
            self.changed()
            return True

    def retry_attachment(self, issue_id, file_id, error, delay=300):
        self.run("UPDATE attachment_extracts SET status='pending',error=?,retry_at=?,updated=? "
                 "WHERE issue_id=? AND file_id=?", (str(error)[:80],self.clock()+delay,self.clock(),issue_id,file_id))

    def defer_missing_attachment(self, issue_id, file_id):
        # Mantis 2.28.1 omits content when the backing file is absent. Retain
        # a visible coverage gap and retry daily in case storage is restored.
        self.run("UPDATE attachment_extracts SET status='source_unavailable',error='missing_source_bytes',"
                 "retry_at=?,updated=? WHERE issue_id=? AND file_id=?",
                 (self.clock()+86400,self.clock(),issue_id,file_id))

    def drop_attachment(self, issue_id, file_id):
        with self.transaction():
            old = self.all("SELECT * FROM fragments WHERE issue_id=? AND file_id=? AND kind='attachment_content'",
                           (issue_id,file_id))
            self._remove_fragments(old)
            self.run("DELETE FROM attachment_extracts WHERE issue_id=? AND file_id=?", (issue_id,file_id))
            if old:
                self.changed()

    def rehydrate_attachment(self):
        row = self.one("SELECT e.*,i.data FROM attachment_extracts e JOIN issues i ON i.id=e.issue_id "
                       "WHERE e.status IN ('ready','partial') AND e.segments<>'[]' AND NOT EXISTS "
                       "(SELECT 1 FROM fragments f WHERE f.issue_id=e.issue_id AND f.file_id=e.file_id "
                       "AND f.kind='attachment_content') LIMIT 1")
        if not row:
            return False
        info = file_descriptors(json.loads(row["data"])).get(row["file_id"])
        if not info:
            self.drop_attachment(row["issue_id"],row["file_id"])
            return False
        if info["descriptor"] != row["descriptor"]:
            self.invalidate_attachment(row["issue_id"],row["file_id"],info["descriptor"])
            return False
        return self.publish_attachment(row["issue_id"],row["file_id"],row["descriptor"],row["content_hash"],
                                       {"status":row["status"],"segments":json.loads(row["segments"]),
                                        "reason":row["error"]})

    def attachment_status(self):
        counts = {row["status"]: row["n"] for row in self.all(
            "SELECT status,COUNT(*) AS n FROM attachment_extracts GROUP BY status")}
        backfill = self.one("SELECT value FROM meta WHERE key='attachment_backfill_complete'")
        return {"counts": counts, "pending": counts.get("pending", 0), "ready": counts.get("ready", 0),
                "partial": counts.get("partial", 0), "unsupported": counts.get("unsupported", 0),
                "too_large": counts.get("too_large", 0), "failed": counts.get("failed", 0),
                "source_unavailable": counts.get("source_unavailable", 0),
                "backfill_complete": bool(backfill and backfill["value"] == "1")}

    def purge_issue(self, issue_id, project_id=0):
        with self.transaction():
            self._purge_issue(issue_id, project_id)

    def _redact_operations(self, column, target):
        assert column in {"issue_id", "project_id"}
        for row in self.all(f"SELECT id,steps FROM operations WHERE {column}=?", (target,)):
            minimal = [{"status": step["status"], "result": {
                key: value for key, value in (step.get("result") or {}).items()
                if key in {"issue_id", "note_id", "file_id", "file_ids", "tag_id"}}}
                for step in json.loads(row["steps"])]
            self.run("UPDATE operations SET payload='{}',steps=?,status='access_removed' WHERE id=?", (encode(minimal), row["id"]))

    def _purge_issue(self, issue_id, project_id=0):
        previous = self.one("SELECT project_id FROM issues WHERE id=?", (issue_id,))
        project_id = previous["project_id"] if previous else project_id
        self.run("INSERT OR REPLACE INTO tombstones VALUES(?,?,?,1)", (issue_id, project_id, self.clock()))
        self._remove_fragments(self.all("SELECT * FROM fragments WHERE issue_id=?", (issue_id,)))
        self.run("DELETE FROM attachment_extracts WHERE issue_id=?", (issue_id,))
        self.run("DELETE FROM issues WHERE id=?", (issue_id,))
        self._redact_operations("issue_id", issue_id)
        self.changed()

    def purge_project(self, project_id):
        with self.transaction():
            self.run("INSERT OR REPLACE INTO project_revocations VALUES(?,?)", (project_id, self.clock()))
            for row in self.all("SELECT id FROM issues WHERE project_id=?", (project_id,)):
                self._purge_issue(row["id"], project_id)
            self._redact_operations("project_id", project_id)
            self.run("DELETE FROM catalog WHERE key=?", (f"project:{project_id}",))
            self.run("DELETE FROM delta_progress WHERE project_id=?", (project_id,))
            self.run("UPDATE projects SET data=?,status='access_removed',checkpoint=0,import_page=1,import_start=0,import_verify=0,import_digest='',previous_digest='' WHERE id=?", (encode({"id": project_id}), project_id))

    def cleanup_files(self):
        for row in self.all("SELECT * FROM cache_deletes"):
            directory = self.attachments / str(int(row["issue_id"]))
            if is_link(directory):
                raise RuntimeError("Refusing symlink in Mantis attachment cache")
            if directory.exists():
                for path in directory.glob(f"{int(row['file_id'])}-*"):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
            self.run("DELETE FROM cache_deletes WHERE issue_id=? AND file_id=?", (row["issue_id"], row["file_id"]))
        for row in self.all("SELECT issue_id FROM tombstones WHERE cleanup=1"):
            # IDs are numeric; never follow symlinks or delete a foreign directory.
            directory = self.attachments / str(int(row["issue_id"]))
            if is_link(directory):
                raise RuntimeError("Refusing symlink in Mantis attachment cache")
            if directory.exists():
                for entry in directory.iterdir():
                    if entry.is_file() or entry.is_symlink():
                        entry.unlink()
                    else:
                        raise RuntimeError("Unexpected directory in Mantis attachment cache")
                directory.rmdir()

    def reserve(self, amount, cap):
        import uuid
        month = datetime.fromtimestamp(self.clock(), timezone.utc).strftime("%Y-%m")
        with self.transaction():
            spent = self.one("SELECT COALESCE(SUM(COALESCE(actual,reserved)),0) AS total FROM charges WHERE month=? OR status='unknown'", (month,))["total"]
            if amount <= 0 or spent + amount > cap:
                raise RuntimeError("Embedding monthly budget reached; lexical search remains available")
            charge = uuid.uuid4().hex
            self.run("INSERT INTO charges VALUES(?,?,?,?,?,?)", (charge, month, amount, None, "unknown", self.clock()))
            return charge

    def settle(self, charge, actual=None):
        # Missing actual billing retains the conservative reservation, not zero.
        self.run("UPDATE charges SET actual=COALESCE(?,reserved),status='settled' WHERE id=?", (actual, charge))

    def health(self):
        projects = self.all("SELECT id,status,checkpoint,verified,error FROM projects ORDER BY id")
        for project in projects:
            project["seconds_since_success"] = max(0, self.clock() - project["verified"]) if project["verified"] else None
        return {"schema": SCHEMA_VERSION, "profile": PROFILE, "revision": self.revision(),
                "issues": self.one("SELECT COUNT(*) AS n FROM issues")["n"],
                "embedding_backlog": self.one("SELECT COUNT(*) AS n FROM fragments WHERE version<>vector_version")["n"],
                "embedding_spooled": self.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"],
                "cleanup_pending": self.one("SELECT COUNT(*) AS n FROM tombstones WHERE cleanup=1")["n"],
                "vector_deletes_pending": self.one("SELECT COUNT(*) AS n FROM vector_deletes")["n"],
                "cache_deletes_pending": self.one("SELECT COUNT(*) AS n FROM cache_deletes")["n"],
                "catalog_verified": self.all("SELECT key,verified FROM catalog"),
                "projects": projects,
                "cost": self.all("SELECT month,SUM(COALESCE(actual,reserved)) AS accounted_usd,SUM(status='unknown') AS unresolved FROM charges GROUP BY month")}


class SearchReader:
    """A read-only connection keeps search independent of the writer's Python lock."""

    health = State.health
    attachment_status = State.attachment_status
    revision = State.revision
    source_revision = State.source_revision

    def __init__(self, state: State):
        self.clock = state.clock
        self.db = sqlite3.connect((state.root / "mantis.sqlite").as_uri() + "?mode=ro",
                                  uri=True, timeout=2)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA query_only=ON")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.db.close()

    def all(self, sql, args=()):
        return [dict(row) for row in self.db.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        rows = self.all(sql, args)
        return rows[0] if rows else None
