"""Run in the pinned native image, with no network or live data mounts."""
import tempfile
import threading
import unittest
import uuid
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, "/app")
from mantis_index import Index
from mantis_state import State
from mantis_vectors import Vectors


class NativeStorageOwner(unittest.TestCase):
    def test_deferred_admission_retries_after_capacity_returns_but_faults_stay_bounded(self):
        status = dict(oldest_at=1, phase="deferred", failures=3, retry_at=0,
                      reason="Not enough free space for a full Mantis Flat/HNSW generation and reserve",
                      required_bytes=15 << 30, candidate_peak_bytes=17 << 30)
        calls = []
        state = SimpleNamespace(clock=lambda: 100, maintenance_status=lambda: status,
                                maintenance_update=lambda **kw: status.update(kw))
        vectors = SimpleNamespace(root=Path("/tmp"), purge=lambda: calls.append("purge"))
        index = SimpleNamespace(state=state, vectors=vectors, maintenance_busy=False)
        with patch("shutil.disk_usage", return_value=SimpleNamespace(free=18 << 30)):
            self.assertFalse(Index.maintenance_once(index))
        self.assertEqual(calls, [])
        with patch("shutil.disk_usage", return_value=SimpleNamespace(free=53 << 30)):
            self.assertTrue(Index.maintenance_once(index))
        self.assertEqual(calls, ["purge"])
        status.update(failures=3, phase="failed", reason="native write failure")
        self.assertFalse(Index.maintenance_once(index))
        self.assertEqual(len(calls), 1)

    def fixture(self):
        tmp = tempfile.TemporaryDirectory(prefix="mantis-storage-owner-")
        self.addCleanup(tmp.cleanup)
        state = State(Path(tmp.name) / "state", Path(tmp.name) / "attachments")
        self.addCleanup(state.close)
        vectors = Vectors(state, dimension=16)
        self.addCleanup(vectors.close)
        keys = ["vector" + str(i) for i in range(8)]
        vectors.upsert_batch([(key, [1.0] + [0.0] * 15) for key in keys])
        for key in keys:
            state.run("INSERT INTO fragments(id,issue_id,kind,note_id,file_id,source,text,folded,version,vector_version,vector_id) "
                      "VALUES(?,1,'description',0,0,'fixture','fixture','fixture','v1','v1',?)", (key, key))
        state.changed()
        return state, vectors, keys

    def retained_build(self, state, vectors, value="unpublished"):
        name = uuid.uuid4().hex
        collection = vectors._create(vectors.root / name)
        collection.close()
        state.run("INSERT INTO meta VALUES(?,?)", ("vector_build_" + name, value))
        return name

    def test_verified_publication_retires_old_builds_and_preserves_actual_reader_lease(self):
        state, vectors, keys = self.fixture()
        stale = self.retained_build(state, vectors)
        pinned = self.retained_build(state, vectors, "recovery")
        old = vectors.generation
        lease = vectors._lease()
        handle = lease.__enter__()
        try:
            vectors.compact(clear_deletions=True)
            self.assertNotEqual(old, vectors.generation)
            self.assertEqual(vectors.existing(keys), set(keys))
            self.assertFalse((vectors.root / stale).exists())
            self.assertTrue((vectors.root / pinned).exists())
            self.assertTrue((vectors.root / old).exists())
            self.assertEqual(len(handle.collection.fetch(keys, include_vector=False)), len(keys))
        finally:
            lease.__exit__(None, None, None)
        vectors._remove_old()
        self.assertFalse((vectors.root / old).exists())
        self.assertTrue((vectors.root / pinned).exists())

    def test_missing_authoritative_vector_preserves_serving_and_retained_evidence(self):
        state, vectors, keys = self.fixture()
        stale = self.retained_build(state, vectors)
        old = vectors.generation
        state.run("UPDATE fragments SET vector_id='missing-paid-payload' WHERE id=?", (keys[0],))
        state.changed()
        with self.assertRaisesRegex(RuntimeError, "missing"):
            vectors.compact(clear_deletions=True)
        self.assertEqual(vectors.generation, old)
        self.assertTrue((vectors.root / stale).exists())
        self.assertTrue(state.one("SELECT 1 FROM meta WHERE key=?", ("vector_build_" + stale,)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
