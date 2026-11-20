"""Search deadline and embedding ownership for one JSON CHUNKS recall."""

import asyncio
from contextvars import ContextVar
from urllib.parse import urlsplit


DEADLINE_SECONDS = 20
# Seconds after the first query-vector request at which an identical request is
# added while none has answered. A single request to the hosted embedding API
# usually answers in 1-3 s, but individual requests stall for 15-120 s (TLS
# handshakes on the host uplink stall independently), so an extra short request
# is cheaper than losing the whole recall deadline.
HEDGE_DELAYS_SECONDS = (3.0, 6.0, 9.0)
OPENROUTER_HOST = "openrouter.ai"
QUERY_CACHE_TTL_SECONDS = 86400
# The SDK closes an idle connection after 5 s, so a recall minutes after the
# previous one paid a new TLS handshake over the slow host route (median 3 s,
# up to 10.6 s). Measured idle gaps up to 240 s reused the connection safely;
# after 7-10 min the peer had closed it and a new one was opened either way.
EMBEDDING_KEEPALIVE_SECONDS = 240.0
_embeddings = ContextVar("itl_recall_embeddings", default=None)
_query_vector_request = ContextVar("itl_recall_query_vector_request", default=False)


class RecallDeadlineExceeded(Exception):
    pass


async def run_chunks_recall(search):
    embeddings = {}
    token = _embeddings.set(embeddings)
    deadline = asyncio.timeout(DEADLINE_SECONDS)
    try:
        async with deadline:
            return await search()
    except TimeoutError as error:
        if not deadline.expired():
            raise
        raise RecallDeadlineExceeded from error
    finally:
        _embeddings.reset(token)
        tasks = tuple(embeddings.values())
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


def use_early_collection_lookup(collection_name):
    return collection_name == "DocumentChunk_text" and _embeddings.get() is not None


async def embed_chunk_query(gateway, query_text):
    embeddings = _embeddings.get()
    # The pinned Cognee factory shares this engine for equal effective configs.
    # Gateway wrappers can differ across dataset contexts.
    engine = getattr(gateway, "_engine", None)
    if embeddings is None or engine is None:
        return (await gateway.embed_text([query_text]))[0]

    key = (id(engine), query_text)
    task = embeddings.get(key)
    if task is None:
        task = asyncio.create_task(_hedged_query_vector(gateway, query_text))
        embeddings[key] = task
    # A single dataset can stop waiting while its siblings still need the vector.
    return (await asyncio.shield(task))[0]


async def _hedged_query_vector(gateway, query_text):
    # Attempts copy this task's context, so only query-vector requests of a
    # CHUNKS recall see the marker; ingestion keeps the native request body.
    _query_vector_request.set(True)
    loop = asyncio.get_running_loop()
    started_at = loop.time()
    attempts = []
    pending = set()
    failures = []
    hedges = list(HEDGE_DELAYS_SECONDS)

    def launch():
        attempt = asyncio.create_task(gateway.embed_text([query_text]))
        attempts.append(attempt)
        pending.add(attempt)

    launch()
    try:
        while True:
            timeout = max(0.0, started_at + hedges[0] - loop.time()) if hedges else None
            done, _ = await asyncio.wait(pending, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
            for attempt in attempts:
                if attempt in done:
                    pending.discard(attempt)
                    if attempt.exception() is None:
                        return attempt.result()
                    failures.append(attempt)
            if not done:
                hedges.pop(0)
                launch()
            elif not pending:
                # A provider error is the native engine's answer after its own
                # retries; a hedge is added only for silence, never for errors.
                return failures[0].result()
    finally:
        for attempt in attempts:
            attempt.cancel()
        await asyncio.gather(*attempts, return_exceptions=True)


def embedding_http_client():
    """SDK default HTTP client with a longer idle keep-alive; limits stay the SDK's."""
    import httpx
    from openai import DefaultAsyncHttpxClient

    return DefaultAsyncHttpxClient(
        limits=httpx.Limits(
            max_connections=1000,
            max_keepalive_connections=100,
            keepalive_expiry=EMBEDDING_KEEPALIVE_SECONDS,
        )
    )


def apply_query_request_options(endpoint, create_kwargs):
    """Enable the OpenRouter response cache for a recall query vector only."""
    if not _query_vector_request.get():
        return create_kwargs
    if (urlsplit(endpoint or "").hostname or "").lower() != OPENROUTER_HOST:
        return create_kwargs
    options = dict(create_kwargs)
    # The request body is unchanged; an identical earlier body under the same
    # key returns its complete stored vector instead of a new provider call.
    options["extra_headers"] = {
        **options.get("extra_headers", {}),
        "X-OpenRouter-Cache": "true",
        "X-OpenRouter-Cache-TTL": str(QUERY_CACHE_TTL_SECONDS),
    }
    return options
