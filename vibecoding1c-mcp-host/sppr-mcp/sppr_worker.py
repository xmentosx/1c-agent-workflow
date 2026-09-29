"""Bounded, restartable OpenRouter worker for a published SPPR corpus."""
from __future__ import annotations

import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

from sppr_core import Policy, SpprError, now
from sppr_embeddings import Embeddings
from sppr_store import Store, atomic_json, writer_lock


def embed_pending(settings, credentials, session_check, *, workers=None, batch_size=None, max_seconds=None):
    workers = settings.embedding_workers if workers is None else workers
    batch_size = settings.embedding_batch_size if batch_size is None else batch_size
    max_seconds = settings.embedding_run_seconds if max_seconds is None else max_seconds
    if not 1 <= workers <= 4 or not 1 <= batch_size <= 32 or max_seconds < 1:
        raise SpprError("Embedding worker limits are invalid.")
    policy = Policy.load(settings.policy)
    store = Store(settings)
    started = time.monotonic()
    started_at = now()
    path = settings.state / "embed_attempt.json"

    def scope():
        session_check()
        policy.unchanged(settings.policy)

    def same_generation(generation):
        scope()
        if store.manifest()["generation"] != generation:
            raise SpprError("Published SPPR generation changed; resume against the current corpus.")

    def request(batch):
        provider = Embeddings(settings, credentials.get("api_key", ""), before=scope)
        values = provider.embed([text for _, text in batch])
        if len(values) != len(batch):
            raise SpprError("Embedding batch length mismatch; no batch was saved.")
        return list(zip((hashed for hashed, _ in batch), values)), provider.usage

    with writer_lock(settings.state, "embeddings.lock"):
        scope()
        manifest = store.manifest()
        if manifest["profile"] != settings.profile:
            raise SpprError("Embedding profile changed; collect a new lexical generation first.")
        generation = manifest["generation"]
        progress = {"state": "running", "started": started_at, "generation": generation,
                    "requests": 0, "tokens": 0, "saved_vectors": 0, "batches": 0}
        atomic_json(path, progress)
        buffer, seen, futures = [], set(), {}
        after_id = 0
        exhausted = False
        error = None
        writer = None
        try:
            writer = store.vectors.open_writer()
            def next_batch():
                nonlocal after_id, exhausted
                batch = []
                while len(batch) < batch_size and not exhausted:
                    if not buffer:
                        same_generation(generation)
                        with store.reader(live_vectors=True) as (db, current):
                            if current["generation"] != generation:
                                raise SpprError("Published SPPR generation changed; resume against the current corpus.")
                            buffer.extend(store.pending_page(db, policy, settings.profile, after_id))
                        if not buffer:
                            exhausted = True
                            break
                    row = buffer.pop(0)
                    after_id = row["id"]
                    if row["hash"] not in seen:
                        seen.add(row["hash"])
                        batch.append((row["hash"], row["text"]))
                return batch

            with ThreadPoolExecutor(max_workers=workers) as pool:
                while True:
                    while error is None and len(futures) < workers and time.monotonic() - started < max_seconds:
                        try:
                            batch = next_batch()
                        except SpprError as exc:
                            error = str(exc)
                            break
                        if not batch:
                            break
                        futures[pool.submit(request, batch)] = batch
                    if not futures:
                        break
                    done, _ = wait(futures, return_when=FIRST_COMPLETED)
                    for future in done:
                        futures.pop(future)
                        try:
                            rows, usage = future.result()
                            scope()
                            progress["saved_vectors"] += store.vectors.insert(settings.profile, rows, writer)
                            progress["requests"] += usage.get("requests", 0)
                            progress["tokens"] += usage.get("tokens", 0)
                            progress["batches"] += 1
                            atomic_json(path, progress)
                        except SpprError as exc:
                            error = str(exc)
                        except Exception:
                            error = "Unexpected embedding failure; saved batches remain durable."
            with store.reader(live_vectors=True) as (db, current):
                if current["generation"] == generation:
                    progress["journal_progress"] = store.semantic_progress(db, current)
                    progress["semantic_complete"] = progress["journal_progress"]["pending"] == 0
            published = store.vectors.publish_snapshot(complete=progress.get("semantic_complete", False))
            if published:
                progress["published_vector_snapshot"] = published["generation"]
            with store.reader() as (db, current):
                if current["generation"] == generation:
                    progress["semantic_progress"] = store.semantic_progress(db, current)
            progress.update({"state": "failed" if error else "succeeded", "finished": now(),
                             "elapsed_seconds": round(time.monotonic() - started, 3)})
            if error:
                progress["message"] = error
            atomic_json(path, progress)
            if error:
                raise SpprError(error)
            return progress
        except BaseException as exc:
            if progress["state"] == "running":
                progress.update({"state": "failed", "finished": now(),
                                 "message": str(exc) if isinstance(exc, SpprError) else "Unexpected embedding failure; saved batches remain durable."})
                atomic_json(path, progress)
            raise
        finally:
            if writer is not None:
                writer.close()
