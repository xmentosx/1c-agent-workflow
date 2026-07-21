from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple
from urllib import error, parse, request


DEFAULT_SEARCH_LIMIT = 5
MAX_SEARCH_LIMIT = 20
MAX_SEMANTIC_CANDIDATES = 20
DEFAULT_SEMANTIC_MIN_SCORE = 0.82
SEARCH_PREVIEW_CHARS = 180
DEFAULT_PAGE_MAX_CHARS = 12000
MAX_PAGE_MAX_CHARS = 50000
DEFAULT_STRUCTURE_LIMIT = 30
MAX_STRUCTURE_LIMIT = 100
EMBEDDING_PROFILE_VERSION = "retrieval-v2"


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
    semantic_min_score: float
    reset_database: bool
    embedding_api_base: str
    embedding_api_key: str
    embedding_model: str
    embedding_cache_dir: str

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
            semantic_min_score=float_env("BOOKSTACK_SEMANTIC_MIN_SCORE", DEFAULT_SEMANTIC_MIN_SCORE),
            reset_database=truthy(os.environ.get("RESET_DATABASE", os.environ.get("BOOKSTACK_RESET_DATABASE", "false"))),
            embedding_api_base=os.environ.get("BOOKSTACK_EMBEDDING_API_BASE", os.environ.get("OPENAI_API_BASE", "")).strip().rstrip("/"),
            embedding_api_key=os.environ.get("BOOKSTACK_EMBEDDING_API_KEY", os.environ.get("OPENAI_API_KEY", "")).strip(),
            embedding_model=os.environ.get("BOOKSTACK_EMBEDDING_MODEL", os.environ.get("EMBEDDING_MODEL", os.environ.get("OPENAI_MODEL", ""))).strip(),
            embedding_cache_dir=os.environ.get(
                "MODEL_CACHE_DIR",
                os.environ.get("SENTENCE_TRANSFORMERS_HOME", "/app/model_cache"),
            ).strip(),
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
        scopes = ["shelves", "books", "chapters", "pages"] if scope == "all" else [scope]
        scopes = [item_scope for item_scope in scopes if item_scope in {"shelves", "books", "chapters", "pages"}]
        if not scopes:
            return payload
        base_limit, remainder = divmod(limit, len(scopes))
        for index, item_scope in enumerate(scopes):
            scope_limit = base_limit + (1 if index < remainder else 0)
            if scope_limit <= 0:
                payload[item_scope] = []
                continue
            items = self.paginated(f"/api/{item_scope}", max_items=scope_limit)
            payload[item_scope] = [compact_structure_item(item, item_scope) for item in items]
        return payload


class EmbeddingClient:
    def __init__(self, settings: Settings) -> None:
        self.api_base = settings.embedding_api_base
        self.api_key = settings.embedding_api_key
        self.model = settings.embedding_model
        self.cache_dir = settings.embedding_cache_dir or "/app/model_cache"
        self._local_model: Any = None

    def mode(self) -> str:
        if not self.model:
            return "disabled"
        if self.api_base:
            return "remote"
        return "local"

    def enabled(self) -> bool:
        return self.mode() != "disabled"

    def uses_e5_retrieval_prefixes(self) -> bool:
        model_name = self.model.lower().rsplit("/", 1)[-1]
        return re.search(r"(^|[-_])e5($|[-_])", model_name) is not None

    def storage_model(self) -> str:
        if not self.enabled():
            return ""
        input_profile = "e5-prefixed" if self.uses_e5_retrieval_prefixes() else "plain"
        return f"{self.model}::{EMBEDDING_PROFILE_VERSION}::{input_profile}"

    def embed_query(self, text: str) -> List[float]:
        prefix = "query: " if self.uses_e5_retrieval_prefixes() else ""
        return self.embed(prefix + text)

    def embed_passage(self, text: str) -> List[float]:
        prefix = "passage: " if self.uses_e5_retrieval_prefixes() else ""
        return self.embed(prefix + text)

    def embed(self, text: str) -> List[float]:
        if not self.enabled():
            return []
        if self.api_base:
            return self.embed_remote(text)
        return self.embed_local(text)

    def embed_remote(self, text: str) -> List[float]:
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

    def embed_local(self, text: str) -> List[float]:
        if self._local_model is None:
            Path(self.cache_dir).mkdir(parents=True, exist_ok=True)
            os.environ.setdefault("SENTENCE_TRANSFORMERS_HOME", self.cache_dir)
            os.environ.setdefault("HF_HOME", self.cache_dir)
            try:
                from sentence_transformers import SentenceTransformer
            except Exception as exc:
                raise BookStackApiError(f"Local embedding runtime is unavailable: {exc}") from exc
            self._local_model = SentenceTransformer(self.model, cache_folder=self.cache_dir)
        vector = self._local_model.encode(
            text[:6000],
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        if hasattr(vector, "tolist"):
            vector = vector.tolist()
        return [float(value) for value in vector]


class DocsCache:
    def __init__(self, path: str) -> None:
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

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

    def index_status(self, embedding_model: str) -> Dict[str, Any]:
        with self.connect() as conn:
            page_row = conn.execute(
                """
                SELECT
                    COUNT(*) AS cache_pages,
                    MIN(NULLIF(updated_at, '')) AS oldest_page_updated_at,
                    MAX(NULLIF(updated_at, '')) AS newest_page_updated_at,
                    MIN(NULLIF(indexed_at, '')) AS oldest_indexed_at,
                    MAX(NULLIF(indexed_at, '')) AS newest_indexed_at
                FROM pages
                """
            ).fetchone()
            embedded_pages = 0
            if embedding_model:
                embedding_row = conn.execute(
                    """
                    SELECT COUNT(*) AS count
                    FROM embeddings e
                    JOIN pages p ON p.id = e.page_id
                    WHERE e.model = ? AND e.content_hash = p.content_hash
                    """,
                    (embedding_model,),
                ).fetchone()
                embedded_pages = int(embedding_row["count"]) if embedding_row else 0
        return {
            "cache_pages": int(page_row["cache_pages"]) if page_row else 0,
            "embedded_pages": embedded_pages,
            "oldest_page_updated_at": page_row["oldest_page_updated_at"] if page_row else None,
            "newest_page_updated_at": page_row["newest_page_updated_at"] if page_row else None,
            "oldest_indexed_at": page_row["oldest_indexed_at"] if page_row else None,
            "newest_indexed_at": page_row["newest_indexed_at"] if page_row else None,
        }

    def has_embedding(self, page_id: int, embedding_model: str, content_hash: str) -> bool:
        if not embedding_model or not content_hash:
            return False
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT 1
                FROM embeddings
                WHERE page_id = ? AND model = ? AND content_hash = ?
                LIMIT 1
                """,
                (page_id, embedding_model, content_hash),
            ).fetchone()
        return row is not None

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
        fts_query = " AND ".join(f'"{token}"' for token in tokens if token.strip())
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
            "content_hash": row["content_hash"],
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

    def search_docs(
        self,
        query: str,
        filters: Optional[Dict[str, Any]],
        limit: int,
        cursor: int = 0,
    ) -> Dict[str, Any]:
        if not query or not query.strip():
            return {"ok": False, "error": "query is required", "results": []}
        effective_filters = filters or {}
        limit = max(1, min(int(limit or DEFAULT_SEARCH_LIMIT), MAX_SEARCH_LIMIT))
        cursor = int(cursor or 0)
        if cursor < 0:
            return {"ok": False, "error": "cursor must be zero or greater", "results": []}
        cache_pages = self.cache.count_pages()
        results = self.cache.search(query, cache_pages, effective_filters) if cache_pages > 0 else []
        semantic = self.semantic_results(query, min(cache_pages, MAX_SEMANTIC_CANDIDATES), effective_filters)
        results = rank_search_results(merge_results(results, semantic), query)
        live_used = False
        requested_end = cursor + limit
        if not results or truthy(str(effective_filters.get("live", "false"))):
            live_used = True
            live_query = build_bookstack_search_query(query, effective_filters)
            live_limit = min(max(requested_end + 1, limit), 100)
            results = rank_search_results(
                merge_results(results, [normalize_search_item(item) for item in self.client.search(live_query, live_limit)]),
                query,
            )
        total_matches = len(results)
        page_results = results[cursor:requested_end]
        next_cursor = cursor + len(page_results) if requested_end < total_matches else None
        return {
            "ok": True,
            "query": query,
            "source": "cache+live" if live_used else "cache",
            "cursor": cursor,
            "limit": limit,
            "result_count": len(page_results),
            "total_matches": total_matches,
            "has_more": next_cursor is not None,
            "next_cursor": next_cursor,
            "results": [public_result(result, query) for result in page_results],
        }

    def semantic_results(self, query: str, limit: int, filters: Dict[str, Any]) -> List[Dict[str, Any]]:
        if not self.embeddings.enabled() or self.cache.count_pages() == 0:
            return []
        try:
            query_vector = self.embeddings.embed_query(query)
        except Exception as exc:
            self.last_embedding_error = str(exc)
            return []
        scored = []
        for page, vector in self.cache.all_embeddings(self.embeddings.storage_model()):
            if not matches_filters(page, filters):
                continue
            score = cosine_similarity(query_vector, vector)
            if score >= self.settings.semantic_min_score:
                page["semantic_score"] = score
                page["source"] = "cache-semantic"
                scored.append(page)
        scored.sort(key=lambda item: float(item.get("semantic_score", 0)), reverse=True)
        return scored[:limit]

    def read_page(
        self,
        page_id: Optional[int],
        url: str,
        fmt: str,
        query: str = "",
        heading: str = "",
        cursor: int = 0,
        max_chars: int = DEFAULT_PAGE_MAX_CHARS,
    ) -> Dict[str, Any]:
        resolved_id = page_id
        if not resolved_id and url:
            resolved_id = self.cache.find_page_id_by_url(url)
        if not resolved_id:
            return {"ok": False, "error": "page_id is required, or url must exist in the local cache"}
        page = self.client.read_page(int(resolved_id))
        cached = self.cache.get_page(int(resolved_id))
        if (
            not cached
            or str(cached.get("updated_at", "")) != str(page.get("updated_at", ""))
            or not self.embedding_is_current(cached)
        ):
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
        normalized_content = clean_text(content) if content_format != "html" else content
        selection = select_content(
            normalized_content,
            query=query,
            heading=heading,
            cursor=cursor,
            max_chars=max_chars,
            markdown=content_format == "markdown",
        )
        if not selection["ok"]:
            return {
                "ok": False,
                "error": selection["error"],
                "metadata": compact_page_metadata(cached or normalize_search_item(page)),
                "available_headings": selection.get("available_headings", []),
            }
        return {
            "ok": True,
            "format": content_format,
            "metadata": compact_page_metadata(cached or normalize_search_item(page)),
            "content": selection["content"],
            "total_chars": len(normalized_content),
            "selection": selection["selection"],
            "match_found": selection["match_found"],
            "cursor": selection["cursor"],
            "next_cursor": selection["next_cursor"],
            "truncated": selection["truncated"],
        }

    def list_structure(self, scope: str, limit: int) -> Dict[str, Any]:
        scope = (scope or "all").lower()
        if scope not in {"all", "shelves", "books", "chapters", "pages"}:
            return {"ok": False, "error": "scope must be all, shelves, books, chapters, or pages", "structure": {}}
        limit = max(1, min(int(limit or DEFAULT_STRUCTURE_LIMIT), MAX_STRUCTURE_LIMIT))
        structure = self.client.structure(scope, limit)
        return {
            "ok": True,
            "scope": scope,
            "limit": limit,
            "result_count": sum(len(items) for items in structure.values()),
            "structure": structure,
        }

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
            if (
                cached
                and not force
                and str(cached.get("updated_at", "")) == str(page_summary.get("updated_at", ""))
                and self.embedding_is_current(cached)
            ):
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

    def index_status(self) -> Dict[str, Any]:
        status = self.cache.index_status(self.embeddings.storage_model())
        status.update(
            {
                "ok": True,
                "cache_path": self.settings.cache_path,
                "embedding_enabled": self.embeddings.enabled(),
                "embedding_mode": self.embeddings.mode(),
                "embedding_model": self.embeddings.model,
                "embedding_profile": self.embeddings.storage_model(),
                "embedding_cache_dir": self.embeddings.cache_dir,
                "last_embedding_error": self.last_embedding_error,
                "reindex_interval_hours": self.settings.reindex_interval_hours,
                "index_on_startup": self.settings.index_on_startup,
                "max_index_pages": self.settings.max_index_pages,
                "semantic_min_score": self.settings.semantic_min_score,
            }
        )
        return status

    def index_page(self, page: Dict[str, Any]) -> None:
        markdown = str(page.get("markdown", "") or "")
        html = str(page.get("html", "") or "")
        content_text = clean_text(markdown or html_to_text(html))
        content_hash = self.cache.upsert_page(page, markdown=markdown, html=html, content_text=content_text)
        if self.embeddings.enabled() and content_text:
            try:
                vector = self.embeddings.embed_passage(f"{page.get('name', '')}\n\n{content_text}")
                self.cache.upsert_embedding(int(page["id"]), self.embeddings.storage_model(), content_hash, vector)
                self.last_embedding_error = ""
            except Exception as exc:
                self.last_embedding_error = str(exc)

    def embedding_is_current(self, page: Dict[str, Any]) -> bool:
        if not self.embeddings.enabled():
            return True
        return self.cache.has_embedding(
            int(page.get("id", 0)),
            self.embeddings.storage_model(),
            str(page.get("content_hash", "")),
        )

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


def compact_dict(value: Dict[str, Any]) -> Dict[str, Any]:
    return {key: item for key, item in value.items() if item not in {None, "", False}}


def compact_page_metadata(page: Dict[str, Any]) -> Dict[str, Any]:
    return compact_dict({
        "id": page.get("id"),
        "title": page.get("title") or page.get("name"),
        "url": page.get("url"),
        "book_name": page.get("book_name"),
        "chapter_name": page.get("chapter_name"),
        "updated_at": page.get("updated_at"),
    })


def compact_structure_item(item: Dict[str, Any], scope: str) -> Dict[str, Any]:
    item_type = {"shelves": "shelf", "books": "book", "chapters": "chapter", "pages": "page"}.get(scope, scope)
    return compact_dict({
        "id": to_int(item.get("id")),
        "type": item_type,
        "name": item.get("name") or item.get("title"),
        "url": item.get("url"),
        "book_id": to_int(item.get("book_id")),
        "chapter_id": to_int(item.get("chapter_id")),
        "shelf_id": to_int(item.get("shelf_id")),
    })


def public_result(page: Dict[str, Any], query: str) -> Dict[str, Any]:
    result = compact_page_metadata(page)
    result["preview"] = preview_for(str(page.get("content_text", "") or page.get("preview", "")), query)
    if "semantic_score" in page:
        result["semantic_score"] = round(float(page["semantic_score"]), 4)
    return result


def preview_for(text: str, query: str, length: int = SEARCH_PREVIEW_CHARS) -> str:
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


def markdown_headings(content: str) -> List[Dict[str, Any]]:
    headings: List[Dict[str, Any]] = []
    for match in re.finditer(r"(?m)^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$", content):
        headings.append(
            {
                "level": len(match.group(1)),
                "title": clean_text(match.group(2)),
                "start": match.start(),
                "content_start": match.end(),
            }
        )
    return headings


def markdown_section(content: str, heading: str) -> Tuple[Optional[str], str, List[str]]:
    headings = markdown_headings(content)
    available = [str(item["title"]) for item in headings[:50]]
    requested = clean_text(heading).casefold()
    selected_index = next(
        (index for index, item in enumerate(headings) if requested in str(item["title"]).casefold()),
        None,
    )
    if selected_index is None:
        return None, "", available
    selected = headings[selected_index]
    end = len(content)
    for following in headings[selected_index + 1 :]:
        if int(following["level"]) <= int(selected["level"]):
            end = int(following["start"])
            break
    return content[int(selected["start"]) : end].strip(), str(selected["title"]), available


def query_match_offset(content: str, query: str) -> Optional[int]:
    lowered = content.casefold()
    requested = clean_text(query).casefold()
    if requested:
        exact = lowered.find(requested)
        if exact >= 0:
            return exact
    for token in re.findall(r"[\w-]+", requested, flags=re.UNICODE):
        position = lowered.find(token)
        if position >= 0:
            return position
    return None


def select_content(
    content: str,
    query: str = "",
    heading: str = "",
    cursor: int = 0,
    max_chars: int = DEFAULT_PAGE_MAX_CHARS,
    markdown: bool = True,
) -> Dict[str, Any]:
    try:
        cursor = max(0, int(cursor or 0))
        requested_max = int(DEFAULT_PAGE_MAX_CHARS if max_chars is None else max_chars)
    except (TypeError, ValueError):
        return {"ok": False, "error": "cursor and max_chars must be integers"}
    if requested_max < 0:
        return {"ok": False, "error": "max_chars must be zero or a positive integer"}
    effective_max = 0 if requested_max == 0 else max(1, min(requested_max, MAX_PAGE_MAX_CHARS))
    selected_content = content
    selection = "full"
    match_found = False
    if heading:
        if not markdown:
            return {"ok": False, "error": "heading selection is available only for markdown pages"}
        section, matched_heading, available = markdown_section(content, heading)
        if section is None:
            return {
                "ok": False,
                "error": f"heading not found: {heading}",
                "available_headings": available,
            }
        selected_content = section
        selection = f"heading:{matched_heading}"
    start = cursor
    if query and cursor == 0:
        match_offset = query_match_offset(selected_content, query)
        match_found = match_offset is not None
        if match_offset is not None and effective_max:
            start = max(0, match_offset - min(500, effective_max // 4))
        if match_offset is not None:
            selection = f"{selection}+query" if heading else "query"
    if start > len(selected_content):
        return {"ok": False, "error": f"cursor {start} is beyond selected content length {len(selected_content)}"}
    end = len(selected_content) if effective_max == 0 else min(len(selected_content), start + effective_max)
    next_cursor = end if end < len(selected_content) else None
    return {
        "ok": True,
        "content": selected_content[start:end],
        "selection": selection,
        "match_found": match_found,
        "cursor": start,
        "next_cursor": next_cursor,
        "truncated": start > 0 or end < len(selected_content),
    }


def tool_result_summary(operation: str, result: Dict[str, Any]) -> str:
    if not result.get("ok"):
        return f"BookStack {operation} failed: {result.get('error', 'unknown error')}"
    if operation == "search":
        suffix = f"; next_cursor={result['next_cursor']}" if result.get("next_cursor") is not None else ""
        return (
            f"BookStack search returned {result.get('result_count', 0)}/"
            f"{result.get('total_matches', result.get('result_count', 0))} compact result(s){suffix}."
        )
    if operation == "read":
        content_chars = len(str(result.get("content", "")))
        suffix = f"; next_cursor={result['next_cursor']}" if result.get("next_cursor") is not None else ""
        return f"BookStack page excerpt returned {content_chars}/{result.get('total_chars', content_chars)} chars{suffix}."
    if operation == "structure":
        return f"BookStack structure returned {result.get('result_count', 0)} compact item(s)."
    if operation == "reindex":
        return f"BookStack reindex saw {result.get('pages_seen', 0)} page(s), indexed {result.get('indexed', 0)}."
    if operation == "status":
        return f"BookStack index contains {result.get('cache_pages', 0)} cached page(s)."
    return f"BookStack {operation} completed."


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


def rank_search_results(results: List[Dict[str, Any]], query: str) -> List[Dict[str, Any]]:
    phrase = clean_text(query).casefold()
    indexed_results = list(enumerate(results))

    def rank(item: Tuple[int, Dict[str, Any]]) -> Tuple[int, int, float, int]:
        original_index, page = item
        searchable_text = clean_text(
            f"{page.get('title') or page.get('name') or ''}\n{page.get('content_text') or page.get('preview') or ''}"
        ).casefold()
        exact_phrase = bool(phrase and phrase in searchable_text)
        semantic_score = page.get("semantic_score")
        has_semantic_score = semantic_score is not None
        return (
            0 if exact_phrase else 1,
            0 if has_semantic_score else 1,
            -float(semantic_score or 0.0),
            original_index,
        )

    return [page for _, page in sorted(indexed_results, key=rank)]


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
    from fastmcp.tools.tool import ToolResult

    settings = Settings.from_env()
    service = ProductDocsService(settings)
    mcp = FastMCP("bookstack-product-docs")

    def wrap_result(operation: str, result: Dict[str, Any]) -> Any:
        return ToolResult(content=tool_result_summary(operation, result), structured_content=result)

    @mcp.tool
    def search_docs(
        query: str,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = DEFAULT_SEARCH_LIMIT,
        cursor: int = 0,
    ):
        """Search BookStack product docs. Start with 3-5 results; follow next_cursor when broader coverage is needed."""
        try:
            result = service.search_docs(query=query, filters=filters, limit=limit, cursor=cursor)
        except Exception as exc:
            result = {"ok": False, "error": str(exc), "results": []}
        return wrap_result("search", result)

    @mcp.tool
    def read_page(
        page_id: Optional[int] = None,
        url: str = "",
        format: str = "markdown",
        query: str = "",
        heading: str = "",
        cursor: int = 0,
        max_chars: int = DEFAULT_PAGE_MAX_CHARS,
    ):
        """Read a bounded page excerpt. Narrow with query/heading; follow next_cursor. Use max_chars=0 only for explicit full reads."""
        try:
            result = service.read_page(
                page_id=page_id,
                url=url,
                fmt=format,
                query=query,
                heading=heading,
                cursor=cursor,
                max_chars=max_chars,
            )
        except Exception as exc:
            result = {"ok": False, "error": str(exc)}
        return wrap_result("read", result)

    @mcp.tool
    def list_structure(scope: str = "all", limit: int = DEFAULT_STRUCTURE_LIMIT):
        """List a compact, bounded BookStack structure. Prefer a specific scope and use only when search is insufficient."""
        try:
            result = service.list_structure(scope=scope, limit=limit)
        except Exception as exc:
            result = {"ok": False, "error": str(exc), "structure": {}}
        return wrap_result("structure", result)

    @mcp.tool
    def reindex_docs(force: bool = False, limit: int = 0):
        """Refresh the local BookStack cache and optional semantic embeddings."""
        try:
            result = service.reindex_docs(force=force, limit=limit)
        except Exception as exc:
            result = {"ok": False, "error": str(exc)}
        return wrap_result("reindex", result)

    @mcp.tool
    def index_status():
        """Return local BookStack cache and embedding index status without refreshing the index."""
        try:
            result = service.index_status()
        except Exception as exc:
            result = {"ok": False, "error": str(exc)}
        return wrap_result("status", result)

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
