"""Round-trip real SQLite/binary data, and prove rejection precedes deletion."""
import io
from contextlib import closing
from pathlib import Path
import runpy
import sqlite3
import sys
import tarfile
import tempfile
import unittest

helper = runpy.run_path(sys.argv.pop(1))
fixture_root = sys.argv.pop(1)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="индекс с пробелом ", dir=fixture_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.archive = self.root / "index.tar"
        self.database = self.data / "metadata.db"
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("create table objects (name text primary key)")
            db.execute("insert into objects values (?)", ("Справочники.Контрагенты",))
        (self.data / "vectors").mkdir()
        (self.data / "vectors" / "4096.bin").write_bytes(bytes(range(256)) * 16)

    def test_roundtrip_restores_database_and_removes_candidate_files(self):
        before = {str(p.relative_to(self.data)): p.read_bytes() for p in self.data.rglob("*") if p.is_file()}
        proof = helper["snapshot"](self.data, self.archive)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("delete from objects")
        (self.data / "vectors" / "4096.bin").unlink()
        (self.data / "candidate-only.db").write_bytes(b"new format")
        helper["restore"](self.data, self.archive, proof["sha256"])
        after = {str(p.relative_to(self.data)): p.read_bytes() for p in self.data.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute("select name from objects").fetchone()[0], "Справочники.Контрагенты")
        self.assertTrue(self.archive.exists())

    def test_wrong_hash_does_not_modify_candidate(self):
        helper["snapshot"](self.data, self.archive)
        before = self.database.read_bytes()
        with self.assertRaisesRegex(ValueError, "SHA256"):
            helper["restore"](self.data, self.archive, "0" * 64)
        self.assertEqual(before, self.database.read_bytes())

    def test_invalid_paths_and_links_do_not_modify_candidate(self):
        for name, target in (("../outside", None), ("/outside", None),
                             ("index/link", "../../outside"), ("index/link", "/outside")):
            with self.subTest(name=name, target=target):
                with tarfile.open(self.archive, "w") as archive:
                    member = tarfile.TarInfo(name)
                    if target:
                        member.type = tarfile.SYMTYPE
                        member.linkname = target
                    archive.addfile(member, io.BytesIO())
                before = self.database.read_bytes()
                with self.assertRaises(ValueError):
                    helper["restore"](self.data, self.archive, helper["digest"](self.archive))
                self.assertEqual(before, self.database.read_bytes())

    def test_existing_snapshot_cannot_be_overwritten(self):
        proof = helper["snapshot"](self.data, self.archive)
        with self.assertRaisesRegex(ValueError, "already exists"):
            helper["snapshot"](self.data, self.archive)
        self.assertEqual(proof["sha256"], helper["digest"](self.archive))


if __name__ == "__main__":
    print("Снимок: " + fixture_root)
    unittest.main()
