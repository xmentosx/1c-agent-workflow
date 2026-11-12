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

    async def test_provider_timeout_keeps_its_own_error(self):
        async def search():
            raise TimeoutError("provider")

        with self.assertRaisesRegex(TimeoutError, "provider"):
            await policy.run_chunks_recall(search)


if __name__ == "__main__":
    unittest.main()
