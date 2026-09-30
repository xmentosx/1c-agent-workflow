from __future__ import annotations

import json
import logging
import math
import os
import re
import sqlite3
import threading
import time
from array import array
from collections import OrderedDict
from concurrent.futures import Future
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple
from urllib import error, parse, request

import snowballstemmer

try:
    import numpy as np
except ImportError:  # Source tests can run before the server requirements are installed.
    np = None

from fragment_index import CHUNK_VERSION, FragmentIndex, checked_vector, fragments


DEFAULT_SEARCH_LIMIT = 5
MAX_SEARCH_LIMIT = 20
MAX_SEMANTIC_CANDIDATES = 20
DEFAULT_SEMANTIC_MIN_SCORE = 0.82
SEARCH_PREVIEW_CHARS = 180
DEFAULT_PAGE_MAX_CHARS = 12000
MAX_PAGE_MAX_CHARS = 50000
DEFAULT_STRUCTURE_LIMIT = 30
MAX_STRUCTURE_LIMIT = 100
EMBEDDING_PROFILE_VERSION = "retrieval-v3"
QWEN_TOKENIZER = "Qwen/Qwen3-Embedding-8B"
QWEN_REVISION = "c90816d848505624c2434128dfc61132162a0ee9"
QWEN_INSTRUCTION = "Given a product documentation question, retrieve relevant passages that answer the question"
QWEN_MIN_SCORE = 0.50
QUERY_EMBEDDING_CACHE_SIZE = 256
RECIPROCAL_RANK_CONSTANT = 60


class BookStackApiError(RuntimeError):
    pass


class EmbeddingUnavailable(BookStackApiError):
    pass


class IndexBusyError(BookStackApiError):
    pass


class HtmlTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: List[str] = []
        self.table_depth = 0
        self.list_depth = 0
        self.hidden_depth = 0

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        tag = tag.lower()
        if tag in {"script", "style"}:
            self.hidden_depth += 1
        if self.hidden_depth:
            return
        in_block = self.table_depth > 0 or self.list_depth > 0
        if tag == "table":
            self.table_depth += 1
        if tag in {"ul", "ol"}:
            self.list_depth += 1
        if re.fullmatch(r"h[1-6]", tag):
            self.parts.append(" " if in_block else "\n\n" + "#" * int(tag[1]) + " ")
        elif tag in {"p", "div", "section", "article", "ul", "ol", "table", "pre"}:
            self.parts.append(" " if in_block else "\n\n")
        elif tag in {"br", "li", "tr"}:
            self.parts.append("\n")
            if tag == "li":
                self.parts.append("- ")
        elif tag in {"td", "th"}:
            self.parts.append(" | ")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in {"script", "style"}:
            self.hidden_depth = max(0, self.hidden_depth - 1)
            return
        if self.hidden_depth:
            return
        if tag == "table":
            self.table_depth = max(0, self.table_depth - 1)
        if tag in {"ul", "ol"}:
            self.list_depth = max(0, self.list_depth - 1)
        if tag.lower() in {"p", "div", "section", "article", "ul", "ol", "table", "pre", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self.parts.append(" " if self.table_depth or self.list_depth else "\n\n")
        elif tag.lower() in {"li", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if data and not self.hidden_depth:
            self.parts.append(data)

    def text(self) -> str:
        return clean_text("".join(self.parts))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def clean_text(value: str) -> str:
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
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
    chunk_tokens: int = 1024
    chunk_overlap: int = 64

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
            semantic_min_score=float_env("BOOKSTACK_SEMANTIC_MIN_SCORE", QWEN_MIN_SCORE if "qwen3-embedding" in os.environ.get("BOOKSTACK_EMBEDDING_MODEL", "").lower() else DEFAULT_SEMANTIC_MIN_SCORE),
            reset_database=truthy(os.environ.get("RESET_DATABASE", os.environ.get("BOOKSTACK_RESET_DATABASE", "false"))),
            embedding_api_base=os.environ.get("BOOKSTACK_EMBEDDING_API_BASE", os.environ.get("OPENAI_API_BASE", "")).strip().rstrip("/"),
            embedding_api_key=os.environ.get("BOOKSTACK_EMBEDDING_API_KEY", os.environ.get("OPENAI_API_KEY", "")).strip(),
            embedding_model=os.environ.get("BOOKSTACK_EMBEDDING_MODEL", os.environ.get("EMBEDDING_MODEL", os.environ.get("OPENAI_MODEL", ""))).strip(),
            embedding_cache_dir=os.environ.get(
                "MODEL_CACHE_DIR",
                os.environ.get("SENTENCE_TRANSFORMERS_HOME", "/app/model_cache"),
            ).strip(),
            chunk_tokens=int_env("BOOKSTACK_CHUNK_TOKENS", 1024),
            chunk_overlap=int_env("BOOKSTACK_CHUNK_OVERLAP", 64),
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
        expected_total = None
        while True:
            payload = self.get_json(path, {"count": count, "offset": offset})
            batch = payload if isinstance(payload, list) else payload.get("data", [])
            if path == "/api/pages":
                if (not isinstance(payload, dict) or not isinstance(payload.get("total"), int)
                        or payload["total"] < 0 or not isinstance(batch, list)
                        or any(not isinstance(item, dict) or (to_int(item.get("id")) or 0) <= 0 for item in batch)):
                    raise BookStackApiError("Incomplete BookStack page inventory; retry reindex_docs")
                if expected_total is None:
                    expected_total = payload["total"]
                if payload["total"] != expected_total or len(items) + len(batch) > expected_total:
                    raise BookStackApiError("BookStack inventory changed during listing; retry reindex_docs")
                known = {item["id"] for item in items}
                if len({item["id"] for item in batch}) != len(batch) or any(item["id"] in known for item in batch):
                    raise BookStackApiError("Duplicate BookStack page inventory; retry reindex_docs")
                if not batch and len(items) < payload["total"]:
                    raise BookStackApiError("Interrupted BookStack page inventory; retry reindex_docs")
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
        page = self.get_json(f"/api/pages/{page_id}")
        # The page API may omit its URL. BookStack's ID permalink survives renames.
        if not page.get("url"):
            page["url"] = self._url(f"/link/{page_id}")
        return page

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
        self._tokenizer: Any = None
        self.chunk_tokens = settings.chunk_tokens
        self.chunk_overlap = settings.chunk_overlap
        self.on_usage = None
        self._query_cache = OrderedDict()
        self._query_pending = {}
        self._query_lock = threading.Lock()

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
        profile = dict(endpoint=self.api_base, instruction=QWEN_INSTRUCTION if self.is_qwen() else "",
                       tokenizer=QWEN_TOKENIZER if self.is_qwen() else self.model,
                       revision=QWEN_REVISION if self.is_qwen() else "default",
                       chunking=CHUNK_VERSION, tokens=self.fragment_limit(), overlap=self.chunk_overlap,
                       prefix="e5" if self.uses_e5_retrieval_prefixes() else "plain")
        return f"{self.model}::{EMBEDDING_PROFILE_VERSION}::{hash_text(json.dumps(profile, sort_keys=True))[:20]}"

    def is_qwen(self) -> bool:
        return self.model.lower().rsplit("/", 1)[-1] == "qwen3-embedding-8b"

    def fragment_limit(self) -> int:
        limit = min(self.chunk_tokens, 448 if self.uses_e5_retrieval_prefixes() else 8192)
        if limit < 64 or self.chunk_overlap < 0 or self.chunk_overlap >= limit // 2:
            raise BookStackApiError("Invalid BookStack chunk token/overlap settings")
        return limit

    def tokenizer(self):
        if self._tokenizer is None:
            from transformers import AutoTokenizer
            kwargs = {"cache_dir": self.cache_dir, "use_fast": True}
            if self.is_qwen():
                kwargs["revision"] = QWEN_REVISION
            self._tokenizer = AutoTokenizer.from_pretrained(QWEN_TOKENIZER if self.is_qwen() else self.model, **kwargs)
        return self._tokenizer

    def split_page(self, title: str, text: str):
        return fragments(text, title, self.tokenizer(), self.fragment_limit(), self.chunk_overlap)

    def embed_query(self, text: str, telemetry: Optional[Dict[str, Any]] = None) -> List[float]:
        prefix = "query: " if self.uses_e5_retrieval_prefixes() else ""
        if self.is_qwen():
            prefix = f"Instruct: {QWEN_INSTRUCTION}\nQuery:"
        input_text = prefix + text
        key = (self.storage_model(), hash_text(input_text))
        with self._query_lock:
            if key in self._query_cache:
                self._query_cache.move_to_end(key)
                if telemetry is not None:
                    telemetry["query_embedding_cache"] = "hit"
                return list(self._query_cache[key])
            pending = self._query_pending.get(key)
            owner = pending is None
            if owner:
                pending = Future()
                self._query_pending[key] = pending
            if telemetry is not None:
                telemetry["query_embedding_cache"] = "miss" if owner else "shared"
        if not owner:
            return list(pending.result())
        try:
            vector = array("d", self.embed(input_text))
            with self._query_lock:
                if vector:
                    self._query_cache[key] = vector
                    while len(self._query_cache) > QUERY_EMBEDDING_CACHE_SIZE:
                        self._query_cache.popitem(last=False)
                self._query_pending.pop(key)
                pending.set_result(vector)
            return list(vector)
        except BaseException as exc:
            with self._query_lock:
                self._query_pending.pop(key, None)
                pending.set_exception(exc)
            raise

    def embed_passage(self, text: str) -> List[float]:
        prefix = "passage: " if self.uses_e5_retrieval_prefixes() else ""
        return self.embed(prefix + text)

    def embed(self, text: str) -> List[float]:
        if not self.enabled():
            return []
        tokens = len(self.tokenizer().encode(text, add_special_tokens=True))
        maximum = 32768 if self.is_qwen() else (512 if self.uses_e5_retrieval_prefixes() else 8192)
        if tokens > maximum:
            raise BookStackApiError(f"Embedding input has {tokens} tokens, limit {maximum}; shorten the query or reindex with smaller fragments")
        if self.api_base:
            return self.embed_remote(text)
        return self.embed_local(text)

    def embed_remote(self, text: str) -> List[float]:
        return self._remote_batch([text])[0]

    def embed_passages(self, texts: List[str]) -> List[List[float]]:
        if not self.api_base:
            return [self.embed_passage(text) for text in texts]
        prefix = "passage: " if self.uses_e5_retrieval_prefixes() else ""
        inputs = [prefix + text for text in texts]
        maximum = 32768 if self.is_qwen() else (512 if self.uses_e5_retrieval_prefixes() else 8192)
        if any(len(self.tokenizer().encode(text, add_special_tokens=True)) > maximum for text in inputs):
            raise BookStackApiError("Embedding passage exceeds model token limit; lower BOOKSTACK_CHUNK_TOKENS")
        return self._remote_batch(inputs)

    def _remote_batch(self, texts: List[str]) -> List[List[float]]:
        body = {"model": self.model, "input": texts[0] if len(texts) == 1 else texts, "encoding_format": "float"}
        if parse.urlsplit(self.api_base).hostname == "openrouter.ai":
            body["provider"] = {"sort": "latency"}
        payload = json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = request.Request(f"{self.api_base}/embeddings", headers=headers, data=payload, method="POST")
        try:
            with request.urlopen(req, timeout=30) as response:
                result = json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            raise BookStackApiError(f"Embedding request failed ({type(exc).__name__}, HTTP {getattr(exc, 'code', 'unavailable')}); retry reindex_docs") from exc
        if self.on_usage is not None:
            self.on_usage(result.get("usage") or {})
        data = result.get("data", [])
        if (len(data) != len(texts) or {item.get("index", 0) for item in data} != set(range(len(texts)))
                or result.get("error") or result.get("model", self.model).lower() != self.model.lower()):
            raise BookStackApiError("Embedding provider returned an incomplete response")
        return [checked_vector(item.get("embedding", []), 4096 if self.is_qwen() else None)
                for item in sorted(data, key=lambda item: item.get("index", 0))]

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
            text,
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        if hasattr(vector, "tolist"):
            vector = vector.tolist()
        return checked_vector(vector)


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
        content_hash = hash_text(str(page.get("name", "")) + "\n\n" + content_text)
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
        fts_query = build_local_fts_query(query)
        rows: List[sqlite3.Row] = []
        with self.connect() as conn:
            if fts_query:
                try:
                    rows = conn.execute(
                        """
                        SELECT p.*, bm25(pages_fts, 4.0, 1.0, 2.0) AS rank
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
        pages = [page for page in pages if matches_filters(page, filters)]
        for rank, page in enumerate(pages, 1):
            page["_lexical_rank"] = rank
        return pages

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
        self.fragment_index = FragmentIndex(self.cache)
        self.embeddings = EmbeddingClient(settings)
        self.embeddings.on_usage = lambda usage: self.fragment_index.usage(self.embeddings.storage_model(), usage)
        self.last_embedding_error = ""
        self._index_lock = threading.RLock()

    def reset_cache(self) -> None:
        with self._index_lock:
            self.cache.reset()
            self.fragment_index.reset()

    def search_docs(
        self,
        query: str,
        filters: Optional[Dict[str, Any]],
        limit: int,
        cursor: int = 0,
        mode: str = "hybrid",
        diagnostics: bool = False,
    ) -> Dict[str, Any]:
        if not query or not query.strip():
            return {"ok": False, "error": "query is required", "results": []}
        effective_filters = filters or {}
        limit = max(1, min(int(limit or DEFAULT_SEARCH_LIMIT), MAX_SEARCH_LIMIT))
        cursor = int(cursor or 0)
        if cursor < 0:
            return {"ok": False, "error": "cursor must be zero or greater", "results": []}
        if mode not in ("hybrid", "text", "semantic"):
            return {"ok": False, "error": "mode must be hybrid, text or semantic", "results": []}
        started = time.perf_counter()
        text_started = time.perf_counter()
        cache_pages = self.cache.count_pages()
        results = self.cache.search(query, cache_pages, effective_filters) if cache_pages > 0 and mode != "semantic" else []
        text_ms = round((time.perf_counter() - text_started) * 1000, 1)
        semantic_trace: Dict[str, Any] = {}
        semantic = (self.semantic_results(query, min(cache_pages, MAX_SEMANTIC_CANDIDATES),
                                          effective_filters, semantic_trace, diagnostics)
                    if mode != "text" else [])
        rank_started = time.perf_counter()
        results = rank_search_results(merge_results(results, semantic), query)
        ranking_ms = round((time.perf_counter() - rank_started) * 1000, 1)
        live_used = False
        live_ms = 0.0
        requested_end = cursor + limit
        if mode != "semantic" and (not results or truthy(str(effective_filters.get("live", "false")))):
            live_used = True
            live_started = time.perf_counter()
            live_query = build_bookstack_search_query(query, effective_filters)
            live_limit = min(max(requested_end + 1, limit), 100)
            results = rank_search_results(
                merge_results(results, [normalize_search_item(item) for item in self.client.search(live_query, live_limit)]),
                query,
            )
            live_ms = round((time.perf_counter() - live_started) * 1000, 1)
        total_matches = len(results)
        page_results = results[cursor:requested_end]
        next_cursor = cursor + len(page_results) if requested_end < total_matches else None
        result = {
            "ok": True,
            "query": query,
            "mode": mode,
            "source": "cache+live" if live_used else "cache",
            "cursor": cursor,
            "limit": limit,
            "result_count": len(page_results),
            "total_matches": total_matches,
            "has_more": next_cursor is not None,
            "next_cursor": next_cursor,
            "results": [public_result(result, query) for result in page_results],
        }
        if mode != "text" and self.embeddings.enabled():
            coverage = self.fragment_index.status(self.embeddings.storage_model())
            if semantic_trace.get("embedding_error"):
                result["semantic_status"] = "degraded"
                result["semantic_continuation"] = "retry the query after the embedding provider recovers; index_status shows corpus readiness"
            elif not coverage["semantic_ready"]:
                result["semantic_status"] = "incomplete"
                result["semantic_continuation"] = "index_status; reindex_docs resumes incomplete indexing"
        if diagnostics:
            result["diagnostics"] = {
                "text_ms": text_ms if mode != "semantic" else 0.0,
                "query_embedding_ms": semantic_trace.get("query_embedding_ms", 0.0),
                "vector_scoring_ms": semantic_trace.get("vector_scoring_ms", 0.0),
                "ranking_ms": ranking_ms,
                "live_fallback_ms": live_ms,
                "total_ms": round((time.perf_counter() - started) * 1000, 1),
                "query_embedding_cache": semantic_trace.get("query_embedding_cache", "not_requested"),
                "scored_fragments": semantic_trace.get("scored_fragments", 0),
            }
            if semantic_trace.get("embedding_error"):
                result["diagnostics"]["embedding_error"] = semantic_trace["embedding_error"]
        return result

    def semantic_results(self, query: str, limit: int, filters: Dict[str, Any],
                         trace: Optional[Dict[str, Any]] = None, diagnostics: bool = False) -> List[Dict[str, Any]]:
        if not self.embeddings.enabled() or self.cache.count_pages() == 0:
            return []
        trace = trace if trace is not None else {}
        embedding_started = time.perf_counter()
        try:
            if diagnostics and isinstance(self.embeddings, EmbeddingClient):
                query_vector = self.embeddings.embed_query(query, telemetry=trace)
            else:
                query_vector = self.embeddings.embed_query(query)
            self.last_embedding_error = ""
        except Exception as exc:
            self.last_embedding_error = str(exc)
            trace["embedding_error"] = str(exc)[:180] if isinstance(exc, BookStackApiError) else type(exc).__name__
            if diagnostics:
                trace["query_embedding_ms"] = round((time.perf_counter() - embedding_started) * 1000, 1)
            return []
        if diagnostics:
            trace["query_embedding_ms"] = round((time.perf_counter() - embedding_started) * 1000, 1)
        scoring_started = time.perf_counter()
        candidates = [(page, vector) for page, vector in self.fragment_index.all_vectors(self.embeddings.storage_model())
                      if matches_filters(page, filters)]
        scores = cosine_scores(query_vector, [vector for _, vector in candidates])
        if diagnostics:
            trace["vector_scoring_ms"] = round((time.perf_counter() - scoring_started) * 1000, 1)
            trace["scored_fragments"] = len(candidates)
        best = {}
        for (page, _), score in zip(candidates, scores):
            if score >= self.settings.semantic_min_score:
                page["semantic_score"] = score
                page["source"] = "cache-semantic"
                if page["id"] not in best or score > best[page["id"]]["semantic_score"]:
                    best[page["id"]] = page
        scored = list(best.values())
        scored.sort(key=lambda item: float(item.get("semantic_score", 0)), reverse=True)
        for rank, page in enumerate(scored[:limit], 1):
            page["_semantic_rank"] = rank
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
            or str(cached.get("name", "")) != str(page.get("name", ""))
            or not self.embedding_is_current(cached)
        ):
            try:
                self.index_page(page)
            except IndexBusyError:
                # Reading live content does not wait for a corpus rebuild.
                cached = dict(normalize_search_item(page), markdown=page.get("markdown", ""),
                              html=page.get("html", ""), content_text=clean_text(page.get("markdown") or html_to_text(page.get("html", ""))))
            except EmbeddingUnavailable:
                # Content is already cached before embedding. A provider outage
                # must not prevent reading the live document.
                cached = self.cache.get_page(int(resolved_id))
            else:
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
        if not self._index_lock.acquire(blocking=False):
            return {"ok": False, "error": "Indexing is already running; inspect index_status and retry reindex_docs"}
        self.fragment_index.state(in_progress=True, error="")
        try:
            return self._reindex_docs(force, limit)
        except Exception as exc:
            self.fragment_index.state(in_progress=False, error=str(exc), complete_profile="")
            raise
        finally:
            self._index_lock.release()

    def _reindex_docs(self, force: bool, limit: int) -> Dict[str, Any]:
        effective_limit = limit or self.settings.max_index_pages
        pages = self.client.list_pages(max_items=effective_limit)
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
                and str(cached.get("name", "")) == str(page_summary.get("name", ""))
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
        deleted = 0
        if not errors and not effective_limit:
            deleted = self.fragment_index.reconcile({int(page["id"]) for page in pages})
            self.fragment_index.state(in_progress=False, error="", complete_profile=self.embeddings.storage_model(), completed_at=utc_now())
        else:
            self.fragment_index.state(in_progress=False, complete_profile="",
                                      error=errors[0]["error"] if errors else "Limited inventory; run reindex_docs without a limit")
        return {
            "ok": len(errors) == 0,
            "pages_seen": len(pages),
            "indexed": indexed,
            "skipped": skipped,
            "deleted": deleted,
            "errors": errors[:20],
            "error_count": len(errors),
            "cache_pages": self.cache.count_pages(),
            "indexed_at": utc_now(),
            "coverage": self.fragment_index.status(self.embeddings.storage_model()),
        }

    def index_status(self) -> Dict[str, Any]:
        status = self.cache.index_status(self.embeddings.storage_model())
        status.update(self.fragment_index.status(self.embeddings.storage_model()))
        status["embedded_pages"] = status["ready_pages"] - status["empty_pages"]
        status["provider_usage"] = self.fragment_index.usage(self.embeddings.storage_model())
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
        if not self._index_lock.acquire(blocking=False):
            raise IndexBusyError("Indexing is already running; reindex_docs resumes pending pages")
        try:
            self._index_page(page)
        finally:
            self._index_lock.release()

    def _index_page(self, page: Dict[str, Any]) -> None:
        markdown = str(page.get("markdown", "") or "")
        html = str(page.get("html", "") or "")
        content_text = clean_text(markdown or html_to_text(html))
        content_hash = self.cache.upsert_page(page, markdown=markdown, html=html, content_text=content_text)
        if self.embeddings.enabled():
            try:
                profile = self.embeddings.storage_model()
                cached = self.cache.get_page(int(page["id"]))
                if self.fragment_index.current(cached, profile):
                    return
                chunks = self.embeddings.split_page(str(page.get("name", "")), content_text) if content_text else []
                missing = list({chunk["input_hash"]: chunk for chunk in chunks
                                if self.fragment_index.vector(profile, chunk["input_hash"]) is None}.values())
                for offset in range(0, len(missing), 8):
                    batch = missing[offset:offset + 8]
                    vectors = self.embeddings.embed_passages([chunk["input"] for chunk in batch])
                    if len(vectors) != len(batch):
                        raise BookStackApiError("Incomplete embedding batch; retry reindex_docs")
                    for chunk, vector in zip(batch, vectors):
                        self.fragment_index.save_vector(profile, chunk, vector)
                self.fragment_index.publish(cached, profile, chunks)
                self.last_embedding_error = ""
            except Exception as exc:
                self.last_embedding_error = str(exc)
                self.fragment_index.state(error=str(exc))
                raise EmbeddingUnavailable(str(exc)) from exc

    def embedding_is_current(self, page: Dict[str, Any]) -> bool:
        if not self.embeddings.enabled():
            return True
        return self.fragment_index.current(page, self.embeddings.storage_model())

    def start_background_reindex(self, force: bool = False) -> None:
        def worker() -> None:
            result = self.reindex_docs(force=force)
            if result["ok"] and result["coverage"]["semantic_ready"]:
                self.start_background_warm()

        thread = threading.Thread(target=worker, name="bookstack-reindex", daemon=True)
        thread.start()

    def start_background_warm(self) -> Optional[threading.Thread]:
        if not self.embeddings.enabled():
            return None

        def worker() -> None:
            try:
                # Loading the SQLite vectors costs several seconds on a cold
                # Docker bind mount. Do it before the first user search.
                next(self.fragment_index.all_vectors(self.embeddings.storage_model()), None)
            except Exception:
                logging.exception("BookStack search vector warmup failed")

        thread = threading.Thread(target=worker, name="bookstack-vector-warmup", daemon=True)
        thread.start()
        return thread

    def start_scheduler(self) -> None:
        if self.settings.reindex_interval_hours <= 0:
            return

        def worker() -> None:
            interval = max(300.0, self.settings.reindex_interval_hours * 3600.0)
            while True:
                time.sleep(interval)
                try:
                    result = self.reindex_docs(force=False)
                    if result["ok"] and result["coverage"]["semantic_ready"]:
                        self.start_background_warm()
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
    result["preview"] = preview_for(str(page.get("fragment_text", "") or page.get("content_text", "") or page.get("preview", "")), query)
    if page.get("fragment"):
        result["fragment"] = page["fragment"]
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
                if "_semantic_rank" in item:
                    current["_semantic_rank"] = item["_semantic_rank"]
                if "fragment" in item:
                    current["fragment"] = item["fragment"]
                    current["fragment_text"] = item["fragment_text"]
            if "_lexical_rank" in item:
                current["_lexical_rank"] = item["_lexical_rank"]
    return list(by_key.values())


def build_local_fts_query(query: str) -> str:
    # Prefixes search the existing unicode61 index: no corpus migration or
    # replacement of the semantic index is needed. Keep identifiers exact and
    # avoid broad prefixes for very short Russian stems.
    stemmer = snowballstemmer.stemmer("russian")
    terms = []
    for token in dict.fromkeys(re.findall(r"[\w-]+", query.casefold(), flags=re.UNICODE)):
        russian = bool(re.fullmatch(r"[а-яё]+", token))
        stem = stemmer.stemWord(token) if russian else token
        # Uninflected nouns also need a prefix (редактор -> редакторе).
        terms.append(f'"{stem}"*' if russian and len(stem) >= 3 else f'"{token}"')
    return " AND ".join(terms)


def rank_search_results(results: List[Dict[str, Any]], query: str) -> List[Dict[str, Any]]:
    phrase = clean_text(query).casefold()
    indexed_results = list(enumerate(results))

    def rank(item: Tuple[int, Dict[str, Any]]) -> Tuple[int, float, float, int]:
        original_index, page = item
        searchable_text = clean_text(
            f"{page.get('title') or page.get('name') or ''}\n{page.get('content_text') or page.get('preview') or ''}"
        ).casefold()
        exact_phrase = bool(phrase and phrase in searchable_text)
        semantic_score = page.get("semantic_score")
        # Both channels contribute their order, so raw BM25 and cosine values
        # never need incomparable score scales or topic-specific boosts.
        fused_score = sum(1.0 / (RECIPROCAL_RANK_CONSTANT + page[key])
                          for key in ("_lexical_rank", "_semantic_rank") if key in page)
        return (
            0 if exact_phrase else 1,
            -fused_score,
            -float(semantic_score or 0.0),
            original_index,
        )

    return [page for _, page in sorted(indexed_results, key=rank)]


def cosine_scores(left: List[float], rights: List[List[float]]) -> List[float]:
    if np is None or not rights:
        return [cosine_similarity(left, right) for right in rights]
    scores = [0.0] * len(rights)
    if not left:
        return scores
    matching = [index for index, right in enumerate(rights) if len(right) == len(left)]
    if not matching:
        return scores
    query = np.asarray(left, dtype=np.float64)
    matrix = np.asarray([rights[index] for index in matching], dtype=np.float64)
    denominators = np.linalg.norm(matrix, axis=1) * np.linalg.norm(query)
    values = matrix @ query
    np.divide(values, denominators, out=values, where=denominators != 0)
    for index, value, denominator in zip(matching, values, denominators):
        if denominator:
            scores[index] = float(value)
    return scores


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
    mcp = FastMCP("bookstack-product-docs", stateless_http=True)

    def wrap_result(operation: str, result: Dict[str, Any]) -> Any:
        return ToolResult(content=tool_result_summary(operation, result), structured_content=result)

    @mcp.tool
    def search_docs(
        query: str,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = DEFAULT_SEARCH_LIMIT,
        cursor: int = 0,
        mode: str = "hybrid",
        diagnostics: bool = False,
    ):
        """Search product docs: hybrid (default), text (no embeddings), or semantic. Start with 3-5 results; follow next_cursor using the same mode. Set diagnostics=true for stage timings."""
        try:
            result = service.search_docs(query=query, filters=filters, limit=limit, cursor=cursor,
                                         mode=mode, diagnostics=diagnostics)
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
            if result["ok"] and result["coverage"]["semantic_ready"]:
                service.start_background_warm()
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
    else:
        service.start_background_warm()
    service.start_scheduler()
    mcp.run(transport="http", host=service.settings.host, port=service.settings.port)


if __name__ == "__main__":
    main()
