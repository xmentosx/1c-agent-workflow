"""BookStack-owned SQLite fragment storage and lossless token-bounded splitting."""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sqlite3
from array import array
from contextlib import closing
from pathlib import Path

CHUNK_VERSION = "sections-v1"


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def checked_vector(vector, dimensions=None):
    values = [float(value) for value in vector]
    if (not values or not all(math.isfinite(value) for value in values)
            or not any(values) or (dimensions is not None and len(values) != dimensions)):
        raise ValueError("Invalid embedding vector or incompatible dimensions")
    return values


def fragments(text, title, tokenizer, limit, overlap=64):
    """Offsets refer to the complete normalized source; no text is discarded."""
    if not text.strip():
        return []
    headings = []
    fenced = False
    for line in re.finditer(r"(?m)^.*(?:\n|$)", text):
        if re.match(r"\s*(```|~~~)", line[0]):
            fenced = not fenced
        match = re.match(r"(#{1,6})[ \t]+(.+?)[ \t]*\n?$", line[0])
        if match and not fenced:
            headings.append((line.start(), match[1], match[2]))
    sections, stack = [], []
    if not headings or headings[0][0] > 0:
        sections.append((0, headings[0][0] if headings else len(text), ""))
    for i, match in enumerate(headings):
        level = len(match[1])
        stack = [(depth, name) for depth, name in stack if depth < level]
        stack.append((level, match[2]))
        sections.append((match[0], headings[i + 1][0] if i + 1 < len(headings) else len(text),
                         " / ".join(name for _, name in stack)))
    result = []
    for section_start, section_end, heading in sections:
        prefix = title + "\n\n" + (heading + "\n\n" if heading else "")
        budget = limit - len(tokenizer.encode(prefix, add_special_tokens=False)) - 4
        if budget < 8:
            raise ValueError("Page title/heading exceeds fragment budget; increase the token limit")
        # Blank lines delimit paragraphs and complete list/table blocks. Blank
        # lines inside fenced code belong to the same block.
        boundaries, fenced = [], False
        for line in re.finditer(r"(?m)^.*(?:\n|$)", text[section_start:section_end]):
            if re.match(r"\s*(```|~~~)", line[0]):
                fenced = not fenced
            if not line[0].strip() and not fenced and line.end() > line.start():
                boundaries.append(section_start + line.end())
        boundaries.append(section_end)
        blocks, block_start = [], section_start
        for end in sorted(set(boundaries)):
            if end > block_start:
                blocks.append((block_start, end))
                block_start = end
        windows, pending = [], None
        for start, end in blocks:
            candidate_start = pending[0] if pending else start
            if len(tokenizer.encode(prefix + text[candidate_start:end], add_special_tokens=False)) <= limit:
                pending = (candidate_start, end)
            else:
                if pending:
                    windows.append(pending)
                pending = (start, end)
        if pending:
            windows.append(pending)
        for window_start, window_end in windows:
            start = window_start
            while start < window_end:
                remainder = text[start:window_end]
                encoded = tokenizer(remainder, add_special_tokens=False, return_offsets_mapping=True)
                offsets = encoded["offset_mapping"]
                end = window_end if len(tokenizer.encode(prefix + remainder, add_special_tokens=False)) <= limit else start + offsets[budget - 1][1]
                if end < window_end:
                    # Prefer a complete paragraph or line in the latter half of the window.
                    window = text[start:end]
                    boundary = window.rfind("\n\n", len(window) // 2)
                    width = 2
                    if boundary < 0:
                        boundary, width = window.rfind("\n", len(window) // 2), 1
                    if boundary >= 0:
                        end = start + boundary + width
                embedding_input = prefix + text[start:end]
                count = len(tokenizer.encode(embedding_input, add_special_tokens=False))
                while count > limit and end > start:
                    end -= 1
                    embedding_input = prefix + text[start:end]
                    count = len(tokenizer.encode(embedding_input, add_special_tokens=False))
                if end <= start:
                    raise ValueError("Tokenizer could not make progress")
                result.append(dict(start=start, end=end, heading=heading, input=embedding_input,
                                   input_hash=digest(embedding_input), tokens=count))
                if end == window_end:
                    break
                used = [pair for pair in offsets if pair[1] <= end - start]
                # Overlap only inside an oversized section, always make forward progress.
                next_start = start + used[-min(overlap, len(used) // 4)][0] if overlap and len(used) >= 4 else end
                start = max(start + 1, min(end, next_start))
    return result


class FragmentIndex:
    def __init__(self, cache):
        self.cache = cache
        self._search_cache = (None, None)
        with cache.connect() as conn:
            exists = conn.execute("SELECT 1 FROM sqlite_master WHERE name='fragment_profiles'").fetchone()
            if not exists and conn.execute("SELECT COUNT(*) FROM pages").fetchone()[0]:
                backup = Path(cache.path + ".pre-fragments.sqlite")
                if not backup.exists():
                    temporary = backup.with_suffix(".sqlite.tmp")
                    with closing(sqlite3.connect(str(temporary))) as target:
                        conn.backup(target)
                    os.replace(temporary, backup)
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS fragment_profiles (
                    profile TEXT PRIMARY KEY, dimensions INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS fragment_vectors (
                    profile TEXT NOT NULL, input_hash TEXT NOT NULL, tokens INTEGER NOT NULL,
                    vector_json TEXT NOT NULL, PRIMARY KEY(profile,input_hash));
                CREATE TABLE IF NOT EXISTS fragment_pages (
                    page_id INTEGER PRIMARY KEY, profile TEXT NOT NULL, page_hash TEXT NOT NULL,
                    chars INTEGER NOT NULL, chunks INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS fragments (
                    page_id INTEGER NOT NULL, ordinal INTEGER NOT NULL, input_hash TEXT NOT NULL,
                    start INTEGER NOT NULL, end INTEGER NOT NULL, heading TEXT NOT NULL,
                    PRIMARY KEY(page_id,ordinal));
                CREATE TABLE IF NOT EXISTS fragment_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS embedding_usage (
                    profile TEXT PRIMARY KEY, requests INTEGER NOT NULL, tokens INTEGER NOT NULL,
                    reported_cost REAL NOT NULL, cost_reports INTEGER NOT NULL);
            """)
            # Long cold-cache reads must not block completed provider usage or
            # atomic page publication. The pre-migration backup above stays intact.
            conn.execute("PRAGMA journal_mode=WAL")

    def state(self, **updates):
        with self.cache.connect() as conn:
            for key, value in updates.items():
                conn.execute("INSERT OR REPLACE INTO fragment_state VALUES (?,?)", (key, json.dumps(value)))
            return {row["key"]: json.loads(row["value"]) for row in conn.execute("SELECT * FROM fragment_state")}

    def current(self, page, profile):
        with self.cache.connect() as conn:
            return conn.execute("SELECT 1 FROM fragment_pages WHERE page_id=? AND profile=? AND page_hash=?",
                                (page["id"], profile, page["content_hash"])).fetchone() is not None

    def vector(self, profile, input_hash):
        with self.cache.connect() as conn:
            row = conn.execute("SELECT vector_json FROM fragment_vectors WHERE profile=? AND input_hash=?",
                               (profile, input_hash)).fetchone()
            return json.loads(row[0]) if row else None

    def save_vector(self, profile, chunk, vector):
        vector = checked_vector(vector)
        with self.cache.connect() as conn:
            row = conn.execute("SELECT dimensions FROM fragment_profiles WHERE profile=?", (profile,)).fetchone()
            checked_vector(vector, row[0] if row else None)
            conn.execute("INSERT OR IGNORE INTO fragment_profiles VALUES (?,?)", (profile, len(vector)))
            conn.execute("INSERT OR IGNORE INTO fragment_vectors VALUES (?,?,?,?)",
                         (profile, chunk["input_hash"], chunk["tokens"], json.dumps(vector)))

    def usage(self, profile, usage=None):
        with self.cache.connect() as conn:
            if usage is not None:
                cost = usage.get("cost")
                conn.execute("""INSERT INTO embedding_usage VALUES (?,1,?,?,?)
                    ON CONFLICT(profile) DO UPDATE SET requests=requests+1,tokens=tokens+excluded.tokens,
                    reported_cost=reported_cost+excluded.reported_cost,cost_reports=cost_reports+excluded.cost_reports""",
                             (profile, int(usage.get("prompt_tokens", usage.get("total_tokens", 0))),
                              float(cost or 0), int(cost is not None)))
            row = conn.execute("SELECT * FROM embedding_usage WHERE profile=?", (profile,)).fetchone()
            return dict(row) if row else {"requests": 0, "tokens": 0, "reported_cost": 0, "cost_reports": 0}

    def publish(self, page, profile, chunks):
        cursor = 0
        for chunk in chunks:
            if chunk["start"] > cursor and page["content_text"][cursor:chunk["start"]].strip():
                raise ValueError("Fragment coverage has a gap")
            if not 0 <= chunk["start"] < chunk["end"] <= len(page["content_text"]):
                raise ValueError("Fragment offsets are outside the page")
            cursor = max(cursor, chunk["end"])
        if page["content_text"][cursor:].strip():
            raise ValueError("Fragment coverage is missing the page tail")
        with self.cache.connect() as conn:
            current = conn.execute("SELECT content_hash FROM pages WHERE id=?", (page["id"],)).fetchone()
            if current is None or current[0] != page["content_hash"]:
                raise ValueError("Page changed while its fragments were being built; reindex_docs resumes it")
            for chunk in chunks:
                if not conn.execute("SELECT 1 FROM fragment_vectors WHERE profile=? AND input_hash=?",
                                    (profile, chunk["input_hash"])).fetchone():
                    raise ValueError("Incomplete fragment set; reindex_docs resumes it")
            conn.execute("DELETE FROM fragments WHERE page_id=?", (page["id"],))
            conn.executemany("INSERT INTO fragments VALUES (?,?,?,?,?,?)",
                             [(page["id"], i, chunk["input_hash"], chunk["start"], chunk["end"], chunk["heading"])
                              for i, chunk in enumerate(chunks)])
            conn.execute("INSERT OR REPLACE INTO fragment_pages VALUES (?,?,?,?,?)",
                         (page["id"], profile, page["content_hash"], len(page["content_text"]), len(chunks)))

    def reconcile(self, page_ids):
        with self.cache.connect() as conn:
            removed = [row[0] for row in conn.execute("SELECT id FROM pages") if row[0] not in page_ids]
            for page_id in removed:
                for table, key in (("pages", "id"), ("pages_fts", "rowid"), ("embeddings", "page_id"),
                                   ("fragments", "page_id"), ("fragment_pages", "page_id")):
                    conn.execute(f"DELETE FROM {table} WHERE {key}=?", (page_id,))
            return len(removed)

    def reset(self):
        with self.cache.connect() as conn:
            for table in ("fragments", "fragment_pages", "fragment_vectors", "fragment_profiles", "fragment_state"):
                conn.execute(f"DELETE FROM {table}")

    def status(self, profile):
        with self.cache.connect() as conn:
            row = conn.execute("""SELECT COUNT(*) AS ready_pages, COALESCE(SUM(fp.chunks),0) AS fragments,
                COALESCE(SUM(fp.chars),0) AS covered_chars,
                COALESCE(SUM(CASE WHEN fp.chunks=0 THEN 1 ELSE 0 END),0) AS empty_pages
                FROM fragment_pages fp JOIN pages p ON p.id=fp.page_id
                WHERE fp.profile=? AND fp.page_hash=p.content_hash""", (profile,)).fetchone()
            totals = conn.execute("SELECT COUNT(*),COALESCE(SUM(length(content_text)),0) FROM pages").fetchone()
        status = dict(row)
        state = self.state()
        status.update(total_chars=totals[1], pending_pages=totals[0] - status["ready_pages"],
                      semantic_ready=(state.get("complete_profile") == profile and not state.get("in_progress", False)
                                      and not state.get("error") and status["ready_pages"] == totals[0]),
                      inventory_completed_at=state.get("completed_at"), index_error=state.get("error", ""),
                      index_in_progress=state.get("in_progress", False))
        return status

    def all_vectors(self, profile):
        with self.cache.connect() as conn:
            # One SQLite snapshot owns both the revision key and its data. Usage
            # writes do not invalidate this read cache; page/profile changes do.
            conn.execute("BEGIN")
            revisions = conn.execute("""SELECT p.id,p.content_hash,p.indexed_at,fp.chunks
                FROM fragment_pages fp JOIN pages p ON p.id=fp.page_id
                WHERE fp.profile=? AND fp.page_hash=p.content_hash ORDER BY p.id""", (profile,)).fetchall()
            key = (profile, tuple(tuple(row) for row in revisions))
            cached_key, data = self._search_cache
            if key != cached_key:
                pages = {row["id"]: self.cache._row_to_page(row) for row in conn.execute("""
                    SELECT p.* FROM fragment_pages fp JOIN pages p ON p.id=fp.page_id
                    WHERE fp.profile=? AND fp.page_hash=p.content_hash""", (profile,))}
                rows = conn.execute("""SELECT f.page_id,f.start,f.end,f.heading,v.vector_json
                    FROM fragment_pages fp JOIN pages p ON p.id=fp.page_id
                    JOIN fragments f ON f.page_id=p.id
                    JOIN fragment_vectors v ON v.profile=fp.profile AND v.input_hash=f.input_hash
                    WHERE fp.profile=? AND fp.page_hash=p.content_hash ORDER BY p.id,f.ordinal""", (profile,))
                data = [(pages[row["page_id"]], row["start"], row["end"], row["heading"],
                         array("d", json.loads(row["vector_json"]))) for row in rows]
                self._search_cache = (key, data)
        for stored_page, start, end, heading, vector in data:
            page = dict(stored_page)
            page["fragment"] = {"heading": heading, "start": start, "end": end}
            page["fragment_text"] = page["content_text"][start:end]
            yield page, vector
