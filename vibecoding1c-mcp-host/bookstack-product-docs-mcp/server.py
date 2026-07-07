from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib import error, parse, request


class BookStackApiError(RuntimeError):
    pass


class HtmlTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag.lower() in {"br", "p", "div", "section", "article", "li", "tr", "h1", "h2", "h3", "h4"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"p", "div", "section", "article", "li", "tr", "h1", "h2", "h3", "h4"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if data:
            self.parts.append(data)

    def text(self) -> str:
        return clean_text(" ".join(self.parts))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def clean_text(value: str) -> str:
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def html_to_text(html: str) -> str:
    parser = HtmlTextExtractor()
    parser.feed(html or "")
    return parser.text()


def truthy(value: str, default: bool = False) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def int_env(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def float_env(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        return float(value)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    base_url: str
    token_id: str
    token_secret: str
    cache_path: str
    timeout_seconds: int
    host: str
    port: int
    reindex_interval_hours: float
    index_on_startup: bool
    max_index_pages: int
    reset_database: bool
    embedding_api_base: str
    embedding_api_key: str
    embedding_model: str

    @staticmethod
    def from_env() -> "Settings":
        return Settings(
            base_url=os.environ.get("BOOKSTACK_BASE_URL", "").strip().rstrip("/"),
            token_id=os.environ.get("BOOKSTACK_TOKEN_ID", "").strip(),
            token_secret=os.environ.get("BOOKSTACK_TOKEN_SECRET", "").strip(),
            cache_path=os.environ.get("BOOKSTACK_CACHE_PATH", "/data/bookstack-cache.sqlite").strip(),
            timeout_seconds=int_env("BOOKSTACK_TIMEOUT_SECONDS", 20),
            host=os.environ.get("BOOKSTACK_MCP_HOST", "0.0.0.0").strip(),
            port=int_env("BOOKSTACK_MCP_PORT", 8000),
            reindex_interval_hours=float_env("BOOKSTACK_REINDEX_INTERVAL_HOURS", 24.0),
            index_on_startup=truthy(os.environ.get("BOOKSTACK_INDEX_ON_STARTUP", "false")),
            max_index_pages=int_env("BOOKSTACK_MAX_INDEX_PAGES", 0),
            reset_database=truthy(os.environ.get("RESET_DATABASE", os.environ.get("BOOKSTACK_RESET_DATABASE", "false"))),
            embedding_api_base=os.environ.get("BOOKSTACK_EMBEDDING_API_BASE", os.environ.get("OPENAI_API_BASE", "")).strip().rstrip("/"),
            embedding_api_key=os.environ.get("BOOKSTACK_EMBEDDING_API_KEY", os.environ.get("OPENAI_API_KEY", "")).strip(),
            embedding_model=os.environ.get("BOOKSTACK_EMBEDDING_MODEL", os.environ.get("OPENAI_MODEL", "")).strip(),
        )

    def validate(self) -> None:
        missing = []
        if not self.base_url:
            missing.append("BOOKSTACK_BASE_URL")
        if not self.token_id:
            missing.append("BOOKSTACK_TOKEN_ID")
        if not self.token_secret:
            missing.append("BOOKSTACK_TOKEN_SECRET")
        if missing:
            raise BookStackApiError("Missing required BookStack settings: " + ", ".join(missing))


class BookStackClient:
    def __init__(self, settings: Settings) -> None:
        settings.validate()
        self.settings = settings

    def _url(self, path: str, query: Optional[Dict[str, Any]] = None) -> str:
        path = path if path.startswith("/") else "/" + path
        url = self.settings.base_url + path
        if query:
            compact = {key: value for key, value in query.items() if value is not None and value != ""}
            if compact:
                url += "?" + parse.urlencode(compact, doseq=True)
        return url

    def _request(self, path: str, query: Optional[Dict[str, Any]] = None, accept: str = "application/json") -> bytes:
        req = request.Request(
            self._url(path, query),
            headers={
                "Authorization": f"Token {self.settings.token_id}:{self.settings.token_secret}",
                "Accept": accept,
                "User-Agent": "bookstack-product-docs-mcp/1.0",
            },
            method="GET",
        )
        try:
            with request.urlopen(req, timeout=self.settings.timeout_seconds) as response:
                return response.read()
        except error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise BookStackApiError(f"BookStack API HTTP {exc.code} for {path}: {body[:500]}") from exc
        except error.URLError as exc:
            raise BookStackApiError(f"BookStack API request failed for {path}: {exc.reason}") from exc

    def get_json(self, path: str, query: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        data = self._request(path, query=query, accept="application/json")
        return json.loads(data.decode("utf-8"))

    def get_text(self, path: str, query: Optional[Dict[str, Any]] = None, accept: str = "text/plain") -> str:
        return self._request(path, query=query, accept=accept).decode("utf-8", errors="replace")

    def paginated(self, path: str, count: int = 500, max_items: int = 0) -> List[Dict[str, Any]]:
        offset = 0
        items: List[Dict[str, Any]] = []
        while True:
            payload = self.get_json(path, {"count": count, "offset": offset})
            batch = payload.get("data", payload if isinstance(payload, list) else [])
            if not isinstance(batch, list):
                break
            items.extend([item for item in batch if isinstance(item, dict)])
            if max_items and len(items) >= max_items:
                return items[:max_items]
            total = int(payload.get("total", len(items))) if isinstance(payload, dict) else len(items)
            offset += len(batch)
            if not batch or offset >= total:
                break
        return items

    def search(self, query: str, limit: int) -> List[Dict[str, Any]]:
        payload = self.get_json("/api/search", {"query": query, "count": max(1, min(limit, 100))})
        data = payload.get("data", payload if isinstance(payload, list) else [])
        return [item for item in data if isinstance(item, dict)]

    def list_pages(self, max_items: int = 0) -> List[Dict[str, Any]]:
        return self.paginated("/api/pages", max_items=max_items)

    def read_page(self, page_id: int) -> Dict[str, Any]:
        return self.get_json(f"/api/pages/{page_id}")

    def export_page(self, page_id: int, fmt: str) -> str:
        export_format = {"markdown": "markdown", "html": "html", "text": "plaintext"}.get(fmt, fmt)
        return self.get_text(f"/api/pages/{page_id}/export/{export_format}", accept="text/plain")

    def structure(self, scope: str, limit: int) -> Dict[str, List[Dict[str, Any]]]:
        payload: Dict[str, List[Dict[str, Any]]] = {}
        scopes = {"shelves", "books", "chapters", "pages"} if scope == "all" else {scope}
        for item_scope in scopes:
            if item_scope not in {"shelves", "books", "chapters", "pages"}:
                continue
            payload[item_scope] = self.paginated(f"/api/{item_scope}", max_items=limit)
        return payload


class EmbeddingClient:
    def __init__(self, settings: Settings) -> None:
        self.api_base = settings.embedding_api_base
        self.api_key = settings.embedding_api_key
        self.model = settings.embedding_model

    def enabled(self) -> bool:
        return bool(self.api_base and self.model)

    def embed(self, text: str) -> List[float]:
        if not self.enabled():
            return []
        payload = json.dumps({"model": self.model, "input": text[:6000]}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = request.Request(f"{self.api_base}/embeddings", headers=headers, data=payload, method="POST")
        try:
            with request.urlopen(req, timeout=30) as response:
                result = json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            raise BookStackApiError(f"Embedding request failed: {exc}") from exc
        data = result.get("data", [])
        if not data:
            return []
        vector = data[0].get("embedding", [])
        return [float(value) for value in vector]


class DocsCache:
    def __init__(self, path: str) -> None:
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS pages (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    book_id INTEGER,
                    chapter_id INTEGER,
                    book_name TEXT,
                    chapter_name TEXT,
                    tags_json TEXT,
                    updated_at TEXT,
                    markdown TEXT,
                    html TEXT,
                    content_text TEXT,
                    content_hash TEXT,
                    indexed_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts
                USING fts5(name, content_text, tags, tokenize='unicode61')
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS embeddings (
                    page_id INTEGER PRIMARY KEY,
                    model TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    vector_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS ix_pages_url ON pages(url)")
            conn.execute("CREATE INDEX IF NOT EXISTS ix_pages_updated_at ON pages(updated_at)")

    def reset(self) -> None:
        with self.connect() as conn:
            conn.execute("DELETE FROM pages")
            conn.execute("DELETE FROM pages_fts")
            conn.execute("DELETE FROM embeddings")

    def count_pages(self) -> int:
        with self.connect() as conn:
            row = conn.execute("SELECT COUNT(*) AS count FROM pages").fetchone()
            return int(row["count"])

    def get_page(self, page_id: int) -> Optional[Dict[str, Any]]:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM pages WHERE id = ?", (page_id,)).fetchone()
            return self._row_to_page(row) if row else None

    def find_page_id_by_url(self, url: str) -> Optional[int]:
        with self.connect() as conn:
            row = conn.execute("SELECT id FROM pages WHERE url = ?", (url,)).fetchone()
            if row:
                return int(row["id"])
            row = conn.execute("SELECT id FROM pages WHERE url LIKE ? ORDER BY id LIMIT 1", (f"%{url.rstrip('/')}",)).fetchone()
            return int(row["id"]) if row else None

    def upsert_page(self, page: Dict[str, Any], markdown: str, html: str, content_text: str) -> str:
        page_id = int(page.get("id", 0))
        if page_id <= 0:
            raise ValueError("BookStack page id is required for cache upsert.")
        tags = page.get("tags", [])
        tags_json = json.dumps(tags, ensure_ascii=False)
        tags_text = " ".join(str(tag.get("name", "")) for tag in tags if isinstance(tag, dict))
        content_hash = hash_text(content_text)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO pages (
                    id, name, url, book_id, chapter_id, book_name, chapter_name, tags_json,
                    updated_at, markdown, html, content_text, content_hash, indexed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    url = excluded.url,
                    book_id = excluded.book_id,
                    chapter_id = excluded.chapter_id,
                    book_name = excluded.book_name,
                    chapter_name = excluded.chapter_name,
                    tags_json = excluded.tags_json,
                    updated_at = excluded.updated_at,
                    markdown = excluded.markdown,
                    html = excluded.html,
                    content_text = excluded.content_text,
                    content_hash = excluded.content_hash,
                    indexed_at = excluded.indexed_at
                """,
                (
                    page_id,
                    str(page.get("name", "")),
                    str(page.get("url", "")),
                    to_int(page.get("book_id")),
                    to_int(page.get("chapter_id")),
                    nested_name(page.get("book")),
                    nested_name(page.get("chapter")),
                    tags_json,
                    str(page.get("updated_at", "")),
                    markdown,
                    html,
                    content_text,
                    content_hash,
                    utc_now(),
                ),
            )
            conn.execute("DELETE FROM pages_fts WHERE rowid = ?", (page_id,))
            conn.execute(
                "INSERT INTO pages_fts(rowid, name, content_text, tags) VALUES (?, ?, ?, ?)",
                (page_id, str(page.get("name", "")), content_text, tags_text),
            )
        return content_hash

    def upsert_embedding(self, page_id: int, model: str, content_hash: str, vector: List[float]) -> None:
        if not vector:
            return
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO embeddings(page_id, model, content_hash, vector_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(page_id) DO UPDATE SET
                    model = excluded.model,
                    content_hash = excluded.content_hash,
                    vector_json = excluded.vector_json,
                    updated_at = excluded.updated_at
                """,
                (page_id, model, content_hash, json.dumps(vector), utc_now()),
            )

    def search(self, query: str, limit: int, filters: Dict[str, Any]) -> List[Dict[str, Any]]:
        tokens = re.findall(r"[\w-]+", query, flags=re.UNICODE)
        fts_query = " OR ".join(f'"{token}"' for token in tokens if token.strip())
        rows: List[sqlite3.Row] = []
        with self.connect() as conn:
            if fts_query:
                try:
                    rows = conn.execute(
                        """
                        SELECT p.*, bm25(pages_fts) AS rank
                        FROM pages_fts
                        JOIN pages p ON p.id = pages_fts.rowid
                        WHERE pages_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """,
                        (fts_query, max(limit, 1)),
                    ).fetchall()
                except sqlite3.Error:
                    rows = []
            if not rows:
                like = f"%{query}%"
                rows = conn.execute(
                    """
                    SELECT *, 0.0 AS rank
                    FROM pages
                    WHERE name LIKE ? OR content_text LIKE ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                    (like, like, max(limit, 1)),
                ).fetchall()
        pages = [self._row_to_page(row) for row in rows]
        return [page for page in pages if matches_filters(page, filters)]

    def all_embeddings(self, model: str) -> List[Tuple[Dict[str, Any], List[float]]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT p.*, e.vector_json
                FROM embeddings e
                JOIN pages p ON p.id = e.page_id
                WHERE e.model = ? AND e.content_hash = p.content_hash
                """,
                (model,),
            ).fetchall()
        results: List[Tuple[Dict[str, Any], List[float]]] = []
        for row in rows:
            page = self._row_to_page(row)
            try:
                vector = [float(value) for value in json.loads(row["vector_json"])]
            except Exception:
                vector = []
            if vector:
                results.append((page, vector))
        return results

    def _row_to_page(self, row: sqlite3.Row) -> Dict[str, Any]:
        tags = []
        try:
            tags = json.loads(row["tags_json"] or "[]")
        except Exception:
            tags = []
        return {
            "id": int(row["id"]),
            "type": "page",
            "name": row["name"],
            "title": row["name"],
            "url": row["url"],
            "book_id": row["book_id"],
            "chapter_id": row["chapter_id"],
            "book_name": row["book_name"],
            "chapter_name": row["chapter_name"],
            "tags": tags,
            "updated_at": row["updated_at"],
            "markdown": row["markdown"],
            "html": row["html"],
            "content_text": row["content_text"],
            "indexed_at": row["indexed_at"],
            "source": "cache",
        }


class ProductDocsService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.client = BookStackClient(settings)
        self.cache = DocsCache(settings.cache_path)
        self.embeddings = EmbeddingClient(settings)
        self.last_embedding_error = ""

    def reset_cache(self) -> None:
        self.cache.reset()

    def search_docs(self, query: str, filters: Optional[Dict[str, Any]], limit: int) -> Dict[str, Any]:
        if not query or not query.strip():
            return {"ok": False, "error": "query is required", "results": []}
        effective_filters = filters or {}
        limit = max(1, min(int(limit or 10), 50))
        results = self.cache.search(query, limit * 2, effective_filters) if self.cache.count_pages() > 0 else []
        semantic = self.semantic_results(query, limit * 2, effective_filters)
        results = merge_results(results, semantic)
        live_used = False
        if len(results) < limit or truthy(str(effective_filters.get("live", "false"))):
            live_used = True
            live_query = build_bookstack_search_query(query, effective_filters)
            results = merge_results(results, [normalize_search_item(item) for item in self.client.search(live_query, limit)])
        return {
            "ok": True,
            "query": query,
            "source": "cache+live" if live_used else "cache",
            "cache_pages": self.cache.count_pages(),
            "embedding_enabled": self.embeddings.enabled(),
            "embedding_error": self.last_embedding_error,
            "results": [public_result(result, query) for result in results[:limit]],
        }

    def semantic_results(self, query: str, limit: int, filters: Dict[str, Any]) -> List[Dict[str, Any]]:
        if not self.embeddings.enabled() or self.cache.count_pages() == 0:
            return []
        try:
            query_vector = self.embeddings.embed(query)
        except Exception as exc:
            self.last_embedding_error = str(exc)
            return []
        scored = []
        for page, vector in self.cache.all_embeddings(self.embeddings.model):
            if not matches_filters(page, filters):
                continue
            score = cosine_similarity(query_vector, vector)
            if score > 0:
                page["semantic_score"] = score
                page["source"] = "cache-semantic"
                scored.append(page)
        scored.sort(key=lambda item: float(item.get("semantic_score", 0)), reverse=True)
        return scored[:limit]

    def read_page(self, page_id: Optional[int], url: str, fmt: str) -> Dict[str, Any]:
        resolved_id = page_id
        if not resolved_id and url:
            resolved_id = self.cache.find_page_id_by_url(url)
        if not resolved_id:
            return {"ok": False, "error": "page_id is required, or url must exist in the local cache"}
        page = self.client.read_page(int(resolved_id))
        cached = self.cache.get_page(int(resolved_id))
        if not cached or str(cached.get("updated_at", "")) != str(page.get("updated_at", "")):
            self.index_page(page)
            cached = self.cache.get_page(int(resolved_id))
        content_format = (fmt or "markdown").lower()
        content = ""
        if content_format == "html":
            content = str(page.get("html", "") or (cached or {}).get("html", ""))
        elif content_format in {"text", "plain", "plaintext"}:
            content = str((cached or {}).get("content_text", "")) or html_to_text(str(page.get("html", "")))
            content_format = "text"
        else:
            content_format = "markdown"
            content = str(page.get("markdown", "") or (cached or {}).get("markdown", ""))
            if not content:
                try:
                    content = self.client.export_page(int(resolved_id), "markdown")
                except Exception:
                    content = str((cached or {}).get("content_text", "")) or html_to_text(str(page.get("html", "")))
        return {
            "ok": True,
            "format": content_format,
            "metadata": public_page_metadata(cached or normalize_search_item(page)),
            "content": clean_text(content) if content_format != "html" else content,
        }

    def list_structure(self, scope: str, limit: int) -> Dict[str, Any]:
        scope = (scope or "all").lower()
        limit = max(1, min(int(limit or 200), 1000))
        structure = self.client.structure(scope, limit)
        return {"ok": True, "scope": scope, "structure": structure}

    def reindex_docs(self, force: bool = False, limit: int = 0) -> Dict[str, Any]:
        pages = self.client.list_pages(max_items=limit or self.settings.max_index_pages)
        indexed = 0
        skipped = 0
        errors = []
        for page_summary in pages:
            page_id = to_int(page_summary.get("id"))
            if not page_id:
                continue
            cached = self.cache.get_page(page_id)
            if cached and not force and str(cached.get("updated_at", "")) == str(page_summary.get("updated_at", "")):
                skipped += 1
                continue
            try:
                page = self.client.read_page(page_id)
                self.index_page(page)
                indexed += 1
            except Exception as exc:
                errors.append({"page_id": page_id, "error": str(exc)})
        return {
            "ok": len(errors) == 0,
            "pages_seen": len(pages),
            "indexed": indexed,
            "skipped": skipped,
            "errors": errors[:20],
            "cache_pages": self.cache.count_pages(),
            "indexed_at": utc_now(),
        }

    def index_page(self, page: Dict[str, Any]) -> None:
        markdown = str(page.get("markdown", "") or "")
        html = str(page.get("html", "") or "")
        content_text = clean_text(markdown or html_to_text(html))
        content_hash = self.cache.upsert_page(page, markdown=markdown, html=html, content_text=content_text)
        if self.embeddings.enabled() and content_text:
            try:
                vector = self.embeddings.embed(f"{page.get('name', '')}\n\n{content_text}")
                self.cache.upsert_embedding(int(page["id"]), self.embeddings.model, content_hash, vector)
                self.last_embedding_error = ""
            except Exception as exc:
                self.last_embedding_error = str(exc)

    def start_background_reindex(self, force: bool = False) -> None:
        thread = threading.Thread(target=lambda: self.reindex_docs(force=force), name="bookstack-reindex", daemon=True)
        thread.start()

    def start_scheduler(self) -> None:
        if self.settings.reindex_interval_hours <= 0:
            return

        def worker() -> None:
            interval = max(300.0, self.settings.reindex_interval_hours * 3600.0)
            while True:
                time.sleep(interval)
                try:
                    self.reindex_docs(force=False)
                except Exception as exc:
                    self.last_embedding_error = f"scheduled reindex failed: {exc}"

        threading.Thread(target=worker, name="bookstack-reindex-scheduler", daemon=True).start()


def to_int(value: Any) -> Optional[int]:
    try:
        if value is None or value == "":
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def nested_name(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("name", ""))
    return ""


def hash_text(value: str) -> str:
    import hashlib

    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def public_page_metadata(page: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": page.get("id"),
        "type": page.get("type", "page"),
        "title": page.get("title") or page.get("name"),
        "name": page.get("name") or page.get("title"),
        "url": page.get("url"),
        "book_id": page.get("book_id"),
        "chapter_id": page.get("chapter_id"),
        "book_name": page.get("book_name"),
        "chapter_name": page.get("chapter_name"),
        "tags": page.get("tags", []),
        "updated_at": page.get("updated_at"),
        "indexed_at": page.get("indexed_at"),
        "source": page.get("source", "live"),
    }


def public_result(page: Dict[str, Any], query: str) -> Dict[str, Any]:
    result = public_page_metadata(page)
    result["preview"] = preview_for(str(page.get("content_text", "") or page.get("preview", "")), query)
    if "semantic_score" in page:
        result["semantic_score"] = page["semantic_score"]
    return result


def preview_for(text: str, query: str, length: int = 280) -> str:
    text = clean_text(text)
    if not text:
        return ""
    tokens = re.findall(r"[\w-]+", query, flags=re.UNICODE)
    start = 0
    lowered = text.lower()
    for token in tokens:
        idx = lowered.find(token.lower())
        if idx >= 0:
            start = max(0, idx - 80)
            break
    snippet = text[start : start + length].strip()
    if start > 0:
        snippet = "..." + snippet
    if start + length < len(text):
        snippet += "..."
    return snippet


def normalize_search_item(item: Dict[str, Any]) -> Dict[str, Any]:
    entity = item.get("entity") if isinstance(item.get("entity"), dict) else item
    return {
        "id": to_int(entity.get("id")) or to_int(item.get("id")),
        "type": str(item.get("type") or entity.get("type") or "page"),
        "name": str(entity.get("name") or item.get("name") or item.get("title") or ""),
        "title": str(entity.get("name") or item.get("name") or item.get("title") or ""),
        "url": str(entity.get("url") or item.get("url") or ""),
        "book_id": entity.get("book_id") or item.get("book_id"),
        "chapter_id": entity.get("chapter_id") or item.get("chapter_id"),
        "book_name": nested_name(entity.get("book")) or nested_name(item.get("book")),
        "chapter_name": nested_name(entity.get("chapter")) or nested_name(item.get("chapter")),
        "tags": entity.get("tags", item.get("tags", [])),
        "updated_at": str(entity.get("updated_at") or item.get("updated_at") or ""),
        "content_text": clean_text(str(item.get("preview_html") or item.get("preview") or item.get("content") or "")),
        "preview": clean_text(html_to_text(str(item.get("preview_html", ""))) or str(item.get("preview", ""))),
        "source": "live",
    }


def matches_filters(page: Dict[str, Any], filters: Dict[str, Any]) -> bool:
    if not filters:
        return True
    item_type = str(filters.get("type", "")).lower()
    if item_type and str(page.get("type", "")).lower() != item_type:
        return False
    book = str(filters.get("book", "")).lower()
    if book and book not in str(page.get("book_name", "")).lower():
        return False
    tag = str(filters.get("tag", "")).lower()
    if tag:
        tag_names = " ".join(str(item.get("name", "")) for item in page.get("tags", []) if isinstance(item, dict)).lower()
        if tag not in tag_names:
            return False
    return True


def build_bookstack_search_query(query: str, filters: Dict[str, Any]) -> str:
    parts = [query.strip()]
    if filters.get("type"):
        parts.append("{" + f"type:{filters['type']}" + "}")
    if filters.get("book"):
        parts.append("{" + f"book:{filters['book']}" + "}")
    if filters.get("tag"):
        parts.append("{" + f"tag:{filters['tag']}" + "}")
    return " ".join(parts)


def merge_results(*result_sets: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    by_key: Dict[str, Dict[str, Any]] = {}
    for result_set in result_sets:
        for item in result_set:
            key = str(item.get("id") or item.get("url") or item.get("title"))
            if not key:
                continue
            if key not in by_key:
                by_key[key] = item
                continue
            current = by_key[key]
            if current.get("source") == "live" and item.get("source", "").startswith("cache"):
                current.update({key: value for key, value in item.items() if value})
            if item.get("semantic_score"):
                current["semantic_score"] = item["semantic_score"]
    return list(by_key.values())


def cosine_similarity(left: List[float], right: List[float]) -> float:
    if not left or not right or len(left) != len(right):
        return 0.0
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    if left_norm == 0 or right_norm == 0:
        return 0.0
    return dot / (left_norm * right_norm)


def create_mcp() -> Tuple[Any, ProductDocsService]:
    from fastmcp import FastMCP

    settings = Settings.from_env()
    service = ProductDocsService(settings)
    mcp = FastMCP("bookstack-product-docs")

    @mcp.tool
    def search_docs(query: str, filters: Optional[Dict[str, Any]] = None, limit: int = 10) -> Dict[str, Any]:
        """Search BookStack product documentation using local cache first, then live BookStack search as fallback."""
        try:
            return service.search_docs(query=query, filters=filters, limit=limit)
        except Exception as exc:
            return {"ok": False, "error": str(exc), "results": []}

    @mcp.tool
    def read_page(page_id: Optional[int] = None, url: str = "", format: str = "markdown") -> Dict[str, Any]:
        """Read a BookStack page by page_id or cached URL and refresh stale cached content before returning it."""
        try:
            return service.read_page(page_id=page_id, url=url, fmt=format)
        except Exception as exc:
            return {"ok": False, "error": str(exc)}

    @mcp.tool
    def list_structure(scope: str = "all", limit: int = 200) -> Dict[str, Any]:
        """List BookStack shelves, books, chapters, and pages for navigation."""
        try:
            return service.list_structure(scope=scope, limit=limit)
        except Exception as exc:
            return {"ok": False, "error": str(exc), "structure": {}}

    @mcp.tool
    def reindex_docs(force: bool = False, limit: int = 0) -> Dict[str, Any]:
        """Refresh the local BookStack cache and optional semantic embeddings."""
        try:
            return service.reindex_docs(force=force, limit=limit)
        except Exception as exc:
            return {"ok": False, "error": str(exc)}

    return mcp, service


def main() -> None:
    mcp, service = create_mcp()
    if service.settings.reset_database:
        service.reset_cache()
    if service.settings.index_on_startup or service.settings.reset_database:
        service.start_background_reindex(force=service.settings.reset_database)
    service.start_scheduler()
    mcp.run(transport="http", host=service.settings.host, port=service.settings.port)


if __name__ == "__main__":
    main()
