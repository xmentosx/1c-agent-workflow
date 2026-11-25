import asyncio
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "recall_policy", Path(__file__).with_name("cognee-recall") / "recall_policy.py"
)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class Gateway:
    def __init__(self, engine, wait=None):
        self._engine = engine
        self.wait = wait
        self.calls = []
        self.cancelled = False

    async def embed_text(self, queries):
        self.calls.extend(queries)
        try:
            if self.wait is not None:
                await self.wait.wait()
            return [[1.0]]
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class RecallPolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_reuse_is_scoped_to_one_request_engine_and_text(self):
        engine = object()
        first = Gateway(engine)
        second = Gateway(engine)
        other = Gateway(object())

        async def search():
            self.assertTrue(policy.use_early_collection_lookup("DocumentChunk_text"))
            self.assertFalse(policy.use_early_collection_lookup("Entity_name"))
            return await asyncio.gather(
                policy.embed_chunk_query(first, "a"),
                policy.embed_chunk_query(second, "a"),
                policy.embed_chunk_query(second, "b"),
                policy.embed_chunk_query(other, "a"),
            )

        self.assertEqual(await policy.run_chunks_recall(search), [[1.0]] * 4)
        self.assertEqual((first.calls, second.calls, other.calls), (["a"], ["b"], ["a"]))
        await policy.run_chunks_recall(search)
        self.assertEqual(first.calls, ["a", "a"])
        self.assertFalse(policy.use_early_collection_lookup("DocumentChunk_text"))

    async def test_deadline_releases_both_slots_and_drains_provider(self):
        semaphore = asyncio.Semaphore(2)
        blocked = Gateway(object(), wait=asyncio.Event())
        follower = Gateway(blocked._engine)
        both_held = asyncio.Event()
        entered = []

        async def dataset(gateway):
            async with semaphore:
                entered.append(gateway)
                if len(entered) == 2:
                    both_held.set()
                return await policy.embed_chunk_query(gateway, "a")

        async def stuck_search():
            await asyncio.gather(dataset(blocked), dataset(blocked))

        with patch.object(policy, "DEADLINE_SECONDS", 0.05):
            stuck = asyncio.create_task(policy.run_chunks_recall(stuck_search))
            await asyncio.wait_for(both_held.wait(), timeout=1)
            following = asyncio.create_task(dataset(follower))
            self.assertFalse(following.done())
            with self.assertRaises(policy.RecallDeadlineExceeded):
                await stuck
            self.assertTrue(blocked.cancelled)
            self.assertEqual(await asyncio.wait_for(following, timeout=1), [1.0])
        self.assertEqual(blocked.calls, ["a"])

    async def test_silent_query_vector_gets_hedged_and_losers_are_cancelled(self):
        engine = object()

        class Scripted:
            def __init__(self, waits):
                self._engine = engine
                self.waits = list(waits)
                self.calls = []
                self.cancelled = 0
                self.options = []

            async def embed_text(self, queries):
                self.calls.extend(queries)
                self.options.append(policy.apply_query_request_options("https://openrouter.ai/api/v1", {}))
                wait = self.waits.pop(0)
                try:
                    await asyncio.sleep(wait)
                    return [[float(len(self.calls))]]
                except asyncio.CancelledError:
                    self.cancelled += 1
                    raise

        stalled = Scripted([30, 0.01, 30])
        with patch.object(policy, "HEDGE_DELAYS_SECONDS", (0.05, 0.1)):
            loop = asyncio.get_running_loop()
            started = loop.time()
            vector = await policy.run_chunks_recall(lambda: policy.embed_chunk_query(stalled, "a"))
            elapsed = loop.time() - started
        self.assertEqual(vector, [2.0])
        self.assertLess(elapsed, 1)
        self.assertEqual((stalled.calls, stalled.cancelled), (["a", "a"], 1))
        self.assertTrue(all(options["extra_headers"]["X-OpenRouter-Cache"] == "true" for options in stalled.options))

        fast = Scripted([0])
        with patch.object(policy, "HEDGE_DELAYS_SECONDS", (0.05,)):
            await policy.run_chunks_recall(lambda: policy.embed_chunk_query(fast, "a"))
            await asyncio.sleep(0.1)
        self.assertEqual(fast.calls, ["a"])

    async def test_deadline_cancels_every_hedged_attempt(self):
        gateway = Gateway(object(), wait=asyncio.Event())
        with patch.object(policy, "HEDGE_DELAYS_SECONDS", (0.01, 0.02)), patch.object(policy, "DEADLINE_SECONDS", 0.1):
            with self.assertRaises(policy.RecallDeadlineExceeded):
                await policy.run_chunks_recall(lambda: policy.embed_chunk_query(gateway, "a"))
        self.assertEqual(gateway.calls, ["a", "a", "a"])
        self.assertTrue(gateway.cancelled)

    async def test_provider_error_is_not_hedged(self):
        class Failing:
            _engine = object()
            calls = 0

            async def embed_text(self, queries):
                Failing.calls += 1
                raise RuntimeError("credentials")

        with patch.object(policy, "HEDGE_DELAYS_SECONDS", (0.01,)):
            with self.assertRaisesRegex(RuntimeError, "credentials"):
                await policy.run_chunks_recall(lambda: policy.embed_chunk_query(Failing(), "a"))
        self.assertEqual(Failing.calls, 1)

    async def test_request_options_only_for_openrouter_query_vectors(self):
        native = {"model": "m", "input": ["a"], "extra_body": {"input_type": "query"}}
        self.assertIs(policy.apply_query_request_options("https://openrouter.ai/api/v1", native), native)

        async def query_request(endpoint):
            policy._query_vector_request.set(True)
            return policy.apply_query_request_options(endpoint, native)

        routed = await asyncio.create_task(query_request("https://OpenRouter.ai"))
        self.assertEqual(routed["extra_body"], {"input_type": "query"})
        self.assertEqual(routed["extra_headers"], {"X-OpenRouter-Cache": "true", "X-OpenRouter-Cache-TTL": "86400"})
        self.assertEqual(native, {"model": "m", "input": ["a"], "extra_body": {"input_type": "query"}})
        for endpoint in ("http://localhost:8080", "https://openrouter.ai.example/v1", None):
            self.assertIs(await asyncio.create_task(query_request(endpoint)), native)
        self.assertFalse(policy._query_vector_request.get())

    def test_embedding_client_keeps_sdk_limits_with_longer_keepalive(self):
        import sys
        import types

        captured = {}
        httpx = types.ModuleType("httpx")
        httpx.Limits = lambda **kwargs: ("limits", kwargs)
        openai = types.ModuleType("openai")
        openai.DefaultAsyncHttpxClient = lambda **kwargs: captured.setdefault("client", kwargs)
        with patch.dict(sys.modules, {"httpx": httpx, "openai": openai}):
            policy.embedding_http_client()
        self.assertEqual(
            captured["client"],
            {"limits": ("limits", {"max_connections": 1000, "max_keepalive_connections": 100, "keepalive_expiry": 240.0})},
        )

    async def test_provider_timeout_keeps_its_own_error(self):
        async def search():
            raise TimeoutError("provider")

        with self.assertRaisesRegex(TimeoutError, "provider"):
            await policy.run_chunks_recall(search)


if __name__ == "__main__":
    unittest.main()
