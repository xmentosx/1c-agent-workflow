"""Compatible document/query vectors; only query vectors live in the bounded LRU."""
from __future__ import annotations

import json
from collections import OrderedDict
from concurrent.futures import Future, TimeoutError as FutureTimeout
from threading import Lock

import numpy as np

from sppr_core import SpprError
from sppr_odata import Http


class QueryWaitTimeout(SpprError):
    """Another call owns this query vector but exceeded the interactive wait."""


def vector(values, dimension):
    try:
        result = np.asarray(values, dtype=np.float32)
        norm = np.linalg.norm(result)
        if result.shape != (dimension,) or not np.isfinite(result).all() or not np.isfinite(norm) or norm <= 0:
            raise ValueError()
        return result / norm
    except (ValueError, TypeError, OverflowError):
        raise SpprError("Embedding dimension or values do not match the configured profile; rebuild with a verified profile.") from None


class Embeddings:
    def __init__(self, settings, api_key, before=lambda: None, *, timeout=None, attempts=3):
        self.settings = settings
        self.api_key = api_key
        self.http = Http(settings.embedding_timeout if timeout is None else timeout,
                         settings.max_response_bytes, before, attempts=attempts)
        self.usage = {"requests": 0, "tokens": 0}

    def embed(self, texts):
        if not self.api_key:
            raise SpprError("OpenRouter key unavailable; configure the external embedding credential.")
        body = {"model": self.settings.model, "input": texts, "encoding_format": "float"}
        if self.settings.dimension != 4096:
            body["dimensions"] = self.settings.dimension
        headers = {"Authorization": "Bearer " + self.api_key, "Content-Type": "application/json"}
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.request_bytes = len(payload)
        raw = self.http.request(self.settings.api_base.rstrip("/") + "/embeddings", headers=headers,
                                body=payload)
        self.usage["requests"] += 1
        try:
            data = json.loads(raw)
            rows = data["data"]
            if len(rows) != len(texts) or sorted(r["index"] for r in rows) != list(range(len(texts))):
                raise ValueError()
            results = [vector(r["embedding"], self.settings.dimension) for r in sorted(rows, key=lambda r: r["index"])]
            self.usage["tokens"] += int(data.get("usage", {}).get("total_tokens", 0))
            return results
        except (KeyError, TypeError, ValueError):
            raise SpprError("Embedding provider returned an invalid response; lexical search remains available.") from None


class QueryCache:
    def __init__(self, settings, provider):
        self.settings, self.provider = settings, provider
        self.values = OrderedDict()
        self.pending = {}
        self.lock = Lock()

    def get(self, query):
        marker = (self.settings.profile, query)
        with self.lock:
            if marker in self.values:
                self.values.move_to_end(marker)
                return self.values[marker], True
            future = self.pending.get(marker)
            owner = future is None
            if owner:
                future = self.pending[marker] = Future()
        # Coalesce identical misses without blocking other keys or ready vectors.
        if not owner:
            try:
                return future.result(timeout=self.settings.query_timeout + 1), True
            except FutureTimeout:
                raise QueryWaitTimeout("Query embedding timed out; lexical results remain available.") from None
        try:
            value = self.provider.embed([self.settings.query_instruction + query])[0]
        except BaseException as exc:
            with self.lock:
                self.pending.pop(marker)
                future.set_exception(exc)
            raise
        with self.lock:
            self.values[marker] = value
            while len(self.values) > self.settings.cache_size:
                self.values.popitem(last=False)
            self.pending.pop(marker)
            future.set_result(value)
            return value, False
