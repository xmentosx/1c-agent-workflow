"""Search deadline and embedding ownership for one JSON CHUNKS recall."""

import asyncio
from contextvars import ContextVar


DEADLINE_SECONDS = 20
_embeddings = ContextVar("itl_recall_embeddings", default=None)


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
        task = asyncio.create_task(gateway.embed_text([query_text]))
        embeddings[key] = task
    # A single dataset can stop waiting while its siblings still need the vector.
    return (await asyncio.shield(task))[0]
