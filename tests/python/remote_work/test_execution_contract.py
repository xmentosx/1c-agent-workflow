import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class ExecutionProducerContractTests(unittest.TestCase):
    def test_project_tests_operation_is_complete_and_nested_capability_cannot_expand_guard(self):
        registry = json.loads((ROOT / "tests" / "execution-guard-producers.json").read_text(encoding="utf-8"))
        producers = {item["id"]: item for item in registry["producers"]}
        for identity in ("project-tests-settings-owner", "project-tests-designer-capability"):
            self.assertIn("project-tests-safe-mode", producers[identity]["resources"])
        self.assertEqual("nested", producers["project-tests-designer-capability"]["boundary"])
        helper = (ROOT / ".agents/skills/1c-workflow/scripts/lib/agent-1c.yaxunit.ps1").read_text(encoding="utf-8-sig")
        launcher = (ROOT / ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1").read_text(encoding="utf-8-sig")
        facade = (ROOT / "tools/itl-ondemand-mcp/designer_project_tests.go").read_text(encoding="utf-8")
        self.assertIn("-Purpose 'project-tests-safe-mode'", helper)
        self.assertIn("{ 'project-tests-safe-mode' }", launcher)
        self.assertIn('projectTestsSafeModeOperation = "project-tests-safe-mode"', facade)
        self.assertIn("Operation: projectTestsSafeModeOperation", facade)
        self.assertIn("InheritedContext: encodedContext, InheritedContextKey: encodedKey", facade)

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
