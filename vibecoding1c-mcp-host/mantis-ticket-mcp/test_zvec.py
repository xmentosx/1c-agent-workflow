"""Real Zvec qualification: run with the pinned runtime dependencies installed."""
import tempfile
import unittest
import uuid
from pathlib import Path

from mantis_state import State
from mantis_index import Index, Vectors
from test_index import FakeApi, ticket


class FixedEmbeddings:
    def __init__(self):
        self.calls = []

    def embed(self, texts):
        self.calls.append(list(texts))
        return [[1.0] + [0.0] * 4095 for _ in texts]


class ZvecTests(unittest.TestCase):
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
                index.embed_pending()
                self.assertEqual(state.health()["embedding_backlog"], 0)
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 4)
                calls = len(provider.calls)
                index.refresh(1)
                index.embed_pending()
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
                index.embed_pending()
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
                index.embed_pending()
                self.assertEqual(len(vectors.query([1.0] + [0.0] * 4095)), 4)
                print("Unicode round trip: путь с пробелом / original имя.txt")
            finally:
                vectors.close()
                state.close()


if __name__ == "__main__":
    unittest.main()
