"""Real Zvec qualification: run with the pinned runtime dependencies installed."""
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from mantis_state import State, digest
from mantis_index import Index, Vectors
from test_index import FakeApi, ticket


class FixedEmbeddings:
    def __init__(self):
        self.calls = []

    def embed(self, texts):
        self.calls.append(list(texts))
        return [[1.0] + [0.0] * 4095 for _ in texts]


def pump(index, batch=32, flush=False):
    """Exercise the production dispatch/publication path without a timer thread."""
    index.embedding_batch = batch
    with ThreadPoolExecutor(max_workers=1) as pool:
        index._dispatch_embedding(pool)
        for future in list(index.embedding_inflight):
            index._publish_embedding(future)
    if flush:
        index._flush_due_embeddings(force=True)


class ZvecTests(unittest.TestCase):
    def test_legacy_state_migrates_to_safe_pause(self):
        with tempfile.TemporaryDirectory(prefix="mantis Векторы ") as directory:
            root = Path(directory)
            state = State(root / "state", root / "files")
            state.run("DELETE FROM meta WHERE key='index_paused'")
            state.close()
            state = State(root / "state", root / "files")
            try:
                self.assertEqual(state.one("SELECT value FROM meta WHERE key='index_paused'")["value"], "1")
            finally:
                state.close()

    def test_full_disk_batch_uses_one_segment_and_reopens(self):
        with tempfile.TemporaryDirectory(prefix="mantis Векторы ") as directory:
            root = Path(directory)
            state = State(root / "state", root / "files")
            vectors = Vectors(state)
            try:
                rows = [(f"batch-{i}", [float(i + 1)] + [0.0] * 4095) for i in range(512)]
                vectors.upsert_batch(rows)
                data = vectors.storage()
                self.assertLess(data["bytes"], 24 << 20,
                                "One durable batch must not create a separate large segment per vector")
                self.assertEqual(len(vectors.existing([key for key, _ in rows])), 512)
                vectors.close()
                state.close()
                state = State(root / "state", root / "files")
                vectors = Vectors(state)
                self.assertEqual(len(vectors.existing([key for key, _ in rows])), 512)
            finally:
                vectors.close()
                state.close()

    def test_paid_spool_survives_restart_and_compaction_reuses_vectors(self):
        with tempfile.TemporaryDirectory(prefix="mantis Векторы ") as directory:
            root = Path(directory)
            state = State(root / "state", root / "files")
            api = FakeApi()
            provider = FixedEmbeddings()
            vectors = Vectors(state)
            index = Index(state, api, vectors, provider)
            index.refresh(1)
            pump(index, batch=1)
            self.assertEqual(state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 1)
            self.assertEqual(state.health()["embedding_backlog"], 2)
            state.run("UPDATE meta SET value='1' WHERE key='index_paused'")
            vectors.close()
            state.close()

            state = State(root / "state", root / "files")
            vectors = Vectors(state)
            index = Index(state, api, vectors, provider)
            try:
                self.assertTrue(index.paused.is_set(), "A restart must preserve the user pause")
                state.run("UPDATE meta SET value='0' WHERE key='index_paused'")
                index.paused.clear()
                pump(index, batch=1)
                pump(index, batch=1, flush=True)
                self.assertEqual(len(provider.calls), 2, "Durably spooled paid results must not be bought again")
                self.assertEqual(state.health()["embedding_backlog"], 0)
                self.assertEqual(state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)
                original_size = vectors.storage()["bytes"]
                old_generation = vectors.generation
                result = vectors.compact()
                self.assertLess(result["bytes"], original_size)
                self.assertNotEqual(vectors.generation, old_generation)
                self.assertFalse((root / "state" / "vectors" / old_generation).exists())
                self.assertEqual(len(provider.calls), 2, "Compaction must not call the embedding provider")
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 2)
            finally:
                vectors.close()
                state.close()

    def test_crash_after_zvec_flush_reconciles_spool_without_purchase(self):
        with tempfile.TemporaryDirectory(prefix="mantis Векторы ") as directory:
            root = Path(directory)
            state = State(root / "state", root / "files")
            api = FakeApi()
            provider = FixedEmbeddings()
            vectors = Vectors(state)
            index = Index(state, api, vectors, provider)
            index.refresh(1)
            pump(index, batch=1)
            paid = state.one("SELECT fragment_id,version,vector FROM embedding_spool")
            from array import array
            vector = array("f")
            vector.frombytes(paid["vector"])
            vectors.upsert_batch([(digest([paid["fragment_id"], paid["version"]]), vector)])
            vectors.close()
            state.close()

            state = State(root / "state", root / "files")
            vectors = Vectors(state)
            index = Index(state, api, vectors, provider)
            try:
                pump(index, batch=1)
                pump(index, batch=1, flush=True)
                self.assertEqual(len(provider.calls), 2)
                self.assertEqual(state.health()["embedding_backlog"], 0)
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 2)
                index.refresh(1)
                state.purge_issue(1)
                self.assertEqual(state.one("SELECT COUNT(*) AS n FROM embedding_spool")["n"], 0)
            finally:
                vectors.close()
                state.close()

    def test_projection_crash_replay_purge_regain_and_unicode_path(self):
        with tempfile.TemporaryDirectory(prefix="mantis Векторы ") as directory:
            root = Path(directory)
            state = State(root / "state", root / "files")
            api = FakeApi()
            api.items[2] = ticket(2, text="second")
            provider = FixedEmbeddings()
            vectors = Vectors(state)
            index = Index(state, api, vectors, provider)
            try:
                index.refresh(1)
                index.refresh(2)
                pump(index, flush=True)
                self.assertEqual(state.health()["embedding_backlog"], 0)
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 4)
                calls = len(provider.calls)
                index.refresh(1)
                pump(index, flush=True)
                self.assertEqual(len(provider.calls), calls)
                # Simulate crash after Zvec upsert, before SQLite completion.
                state.run("UPDATE fragments SET vector_version='' WHERE issue_id=1")
                orphan = root / "state" / "vectors" / uuid.uuid4().hex
                uncommitted = vectors._create(orphan)
                uncommitted.close()
                vectors.close()
                state.close()
                state = State(root / "state", root / "files")
                vectors = Vectors(state)
                self.assertFalse(orphan.exists(), "Unpublished generations must be retired before serving")
                index = Index(state, api, vectors, provider)
                pump(index, flush=True)
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 4)
                self.assertEqual(len(provider.calls), calls, "durable Zvec success must not be purchased again after a lost SQLite completion")
                old_generation = vectors.generation
                state.purge_issue(1)
                index.cleanup()
                self.assertNotEqual(vectors.generation, old_generation)
                self.assertFalse((root / "state" / "vectors" / old_generation).exists())
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 2)
                self.assertEqual(state.health()["cleanup_pending"], 0)
                index.refresh(1)
                pump(index, flush=True)
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 4)
                print("Unicode round trip: путь с пробелом / original имя.txt")
            finally:
                vectors.close()
                state.close()


if __name__ == "__main__":
    unittest.main()
