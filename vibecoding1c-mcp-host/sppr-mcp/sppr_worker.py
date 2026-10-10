"""Bounded, restartable OpenRouter worker for a published SPPR corpus."""
from __future__ import annotations

import time
import json
import math
from collections import deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from threading import Lock

from sppr_core import Policy, SpprError, now
from sppr_embeddings import Embeddings
from sppr_odata import HttpNetworkError, HttpStatusError
from sppr_store import Store, atomic_json, writer_lock


def embed_pending(settings, credentials, session_check, *, workers=None, batch_size=None, max_seconds=None):
    workers = settings.embedding_workers if workers is None else workers
    batch_size = settings.embedding_batch_size if batch_size is None else batch_size
    max_seconds = settings.embedding_run_seconds if max_seconds is None else max_seconds
    if not 1 <= workers <= 6 or not 1 <= batch_size <= 32 or max_seconds < 1:
        raise SpprError("Embedding worker limits are invalid.")
    policy = Policy.load(settings.policy)
    store = Store(settings)
    started = time.monotonic()
    started_at = now()
    path = settings.state / "embed_attempt.json"
    metrics_lock = Lock()
    request_events = deque(maxlen=512)
    saved_events = deque(maxlen=512)

    def recent_metrics():
        cutoff = time.time() - 300
        with metrics_lock:
            while request_events and request_events[0][0] < cutoff:
                request_events.popleft()
            while saved_events and saved_events[0][0] < cutoff:
                saved_events.popleft()
            events = list(request_events)
            saved = sum(count for _, count in saved_events)
        durations = sorted(event[1] for event in events)
        failures = {}
        for event in events:
            if event[2] != "ok":
                failures[event[2]] = failures.get(event[2], 0) + 1
        def percentile(fraction):
            return durations[int((len(durations) - 1) * fraction)] if durations else None
        return {"batches": len(events), "failed_batches": sum(failures.values()),
                "failures": failures,
                "http_attempts": sum(event[3] for event in events),
                "request_bytes": sum(event[4] for event in events),
                "response_bytes": sum(event[5] for event in events),
                "seconds_p50": percentile(0.5), "seconds_p95": percentile(0.95),
                "saved_vectors": saved}

    def scope():
        session_check()
        policy.unchanged(settings.policy)

    def same_generation(generation):
        scope()
        if store.manifest()["generation"] != generation:
            raise SpprError("Published SPPR generation changed; resume against the current corpus.")

    def request(batch):
        # The worker owns the retry budget. Nested HTTP retries would turn
        # three failed batches into nine provider attempts.
        provider = Embeddings(settings, credentials.get("api_key", ""), before=scope, attempts=1)
        begun = time.monotonic()
        outcome = "ok"
        try:
            values = provider.embed([text for _, text in batch])
            if len(values) != len(batch):
                raise SpprError("Embedding batch length mismatch; no batch was saved.")
            return list(zip((hashed for hashed, _ in batch), values)), provider.usage
        except HttpStatusError as exc:
            outcome = "http_" + str(exc.status)
            raise
        except HttpNetworkError:
            outcome = "network"
            raise
        except SpprError:
            outcome = "provider_or_scope"
            raise
        except Exception:
            outcome = "unexpected"
            raise
        finally:
            http = getattr(provider, "http", None)
            with metrics_lock:
                request_events.append((time.time(), round(time.monotonic() - begun, 3), outcome,
                                       getattr(http, "requests", 1), getattr(provider, "request_bytes", 0),
                                       getattr(http, "bytes", 0)))

    with writer_lock(settings.state, "embeddings.lock"):
        scope()
        manifest = store.manifest()
        if manifest["profile"] != settings.profile:
            raise SpprError("Embedding profile changed; collect a new lexical generation first.")
        generation = manifest["generation"]
        try:
            previous_attempt = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous_attempt = {}
        recorded_retry = previous_attempt.get("retry_not_before", 0)
        remaining = (max(0, min(3600, recorded_retry - time.time()))
                     if previous_attempt.get("generation") == generation and
                     isinstance(recorded_retry, (int, float)) and math.isfinite(recorded_retry) else 0)
        progress = {"state": "running", "started": started_at, "generation": generation,
                    "requests": 0, "tokens": 0, "saved_vectors": 0, "batches": 0,
                    "workers": workers, "batch_size": batch_size, "max_seconds": max_seconds}
        if remaining:
            progress["retry_not_before"] = previous_attempt["retry_not_before"]
        atomic_json(path, progress)
        seen, futures = set(), {}
        retries = deque()
        retry_at = time.monotonic() + remaining
        lanes = {name: {"buffer": [], "after_id": 0, "exhausted": False}
                 for name in ("fresh", "all")}
        dispatched = 0
        error = None
        writer = None
        try:
            writer = store.vectors.open_writer()
            def next_batch(lane):
                state = lanes[lane]
                batch = []
                while len(batch) < batch_size and not state["exhausted"]:
                    if not state["buffer"]:
                        same_generation(generation)
                        with store.reader(live_vectors=True) as (db, current):
                            if current["generation"] != generation:
                                raise SpprError("Published SPPR generation changed; resume against the current corpus.")
                            state["buffer"].extend(store.pending_page(
                                db, policy, settings.profile, state["after_id"],
                                priority=1 if lane == "fresh" else None))
                        if not state["buffer"]:
                            state["exhausted"] = True
                            break
                    row = state["buffer"].pop(0)
                    state["after_id"] = row["id"]
                    if row["hash"] not in seen:
                        seen.add(row["hash"])
                        batch.append((row["hash"], row["text"]))
                return batch

            with ThreadPoolExecutor(max_workers=workers) as pool:
                while True:
                    while (error is None and len(futures) < workers and
                           time.monotonic() - started < max_seconds and time.monotonic() >= retry_at):
                        try:
                            if retries:
                                batch, failures = retries.popleft()
                            else:
                                # Reserve one slot per wave for fresh cards;
                                # the other slots drain the historic tail.
                                fresh = manifest.get("priority_schema") == 1 and dispatched % workers == 0
                                batch = next_batch("fresh") if fresh else []
                                if not batch:
                                    batch = next_batch("all")
                                failures = 0
                        except SpprError as exc:
                            error = str(exc)
                            break
                        if not batch:
                            break
                        futures[pool.submit(request, batch)] = (batch, failures)
                        dispatched += 1
                    if not futures:
                        if retries and error is None and time.monotonic() - started < max_seconds:
                            scope()
                            time.sleep(min(1.0, max(0.0, retry_at - time.monotonic())))
                            continue
                        break
                    done, _ = wait(futures, return_when=FIRST_COMPLETED)
                    for future in done:
                        batch, failures = futures.pop(future)
                        try:
                            rows, usage = future.result()
                            scope()
                            saved = store.vectors.insert(settings.profile, rows, writer)
                            progress["saved_vectors"] += saved
                            with metrics_lock:
                                saved_events.append((time.time(), saved))
                            progress["requests"] += usage.get("requests", 0)
                            progress["tokens"] += usage.get("tokens", 0)
                            progress["batches"] += 1
                            retry_at = 0.0
                            progress.pop("retry_not_before", None)
                            progress["provider_5m"] = recent_metrics()
                            atomic_json(path, progress)
                        except (HttpNetworkError, HttpStatusError) as exc:
                            transient = isinstance(exc, HttpNetworkError) or exc.status in (429, 502, 503, 504)
                            if transient and failures < 2:
                                retries.append((batch, failures + 1))
                                pause = max(min(60, 2 ** (failures + 1)),
                                            min(3600, getattr(exc, "retry_after", 0)))
                                retry_at = max(retry_at, time.monotonic() + pause)
                                progress["retry_seconds"] = round(pause, 3)
                                progress["retry_not_before"] = time.time() + pause
                                progress["transient_failures"] = progress.get("transient_failures", 0) + 1
                                progress["provider_5m"] = recent_metrics()
                                atomic_json(path, progress)
                            else:
                                error = str(exc)
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
                progress["vector_snapshot_bytes"] = published.get("snapshot_bytes")
                progress["vector_snapshot_seconds"] = published.get("elapsed_seconds")
            with store.reader() as (db, current):
                if current["generation"] == generation:
                    progress["semantic_progress"] = store.semantic_progress(db, current)
            progress["provider_5m"] = recent_metrics()
            progress["deferred_batches"] = len(retries)
            deferred = progress.get("retry_not_before", 0) > time.time()
            progress.update({"state": "failed" if error else "deferred" if deferred else "succeeded", "finished": now(),
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
