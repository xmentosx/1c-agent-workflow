import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class ExecutionProducerContractTests(unittest.TestCase):
    def test_every_registered_producer_has_a_complete_execution_boundary(self):
        registry = json.loads((ROOT / "tests" / "execution-guard-producers.json").read_text(encoding="utf-8"))
        self.assertEqual(2, registry["schemaVersion"])
        self.assertEqual("execution-guards-v2", registry["protocol"])
        producers = registry["producers"]
        self.assertEqual(len(producers), len({item["id"] for item in producers}))
        self.assertGreaterEqual(len(producers), 6)
        for item in producers:
            with self.subTest(item=item["id"]):
                self.assertIn(item["boundary"], {"external", "nested", "external-or-nested"})
                for field in ("resources", "deadline", "cleanup"):
                    self.assertIsInstance(item[field], str)
                    self.assertTrue(item[field].strip())
                source = (ROOT / item["file"]).read_text(encoding="utf-8-sig")
                if item["function"] != "<script>":
                    name = re.escape(item["function"].split(".")[-1])
                    self.assertRegex(source, rf"(?m)(?:(?:def|function)\s+{name}\b|func\s+(?:\([^\r\n)]*\)\s*)?{name}\b)")

    def test_legacy_database_access_runtime_is_absent_after_cutover(self):
        self.assertFalse((ROOT / "tests" / "database-access-producers.json").exists())
        legacy = (
            ".agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1",
            ".agents/skills/itl-remote-runner/scripts/itl_remote/access.py",
            ".agents/skills/itl-remote-runner/scripts/itl_remote/access_host.py",
            ".agents/skills/itl-remote-runner/scripts/itl_remote/access_autorecovery.py",
            ".agents/skills/itl-remote-runner/scripts/itl_remote/ondemand_recovery.py",
        )
        for relative in legacy:
            with self.subTest(relative=relative):
                self.assertFalse((ROOT / relative).exists())
        cli = (ROOT / ".agents/skills/itl-remote-runner/scripts/remote_work.py").read_text(encoding="utf-8")
        for route in ("access-status", "access-recover", "access-recovery-plan",
                      "recovery-plan", "recovery-cancel", "--plan-id"):
            self.assertNotIn(route, cli)


if __name__ == "__main__":
    unittest.main()
