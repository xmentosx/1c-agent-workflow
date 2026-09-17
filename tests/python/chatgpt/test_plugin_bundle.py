from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[3]
CHATGPT = REPO / ".agents" / "skills" / "1c-workflow" / "chatgpt"
GUIDE = REPO / "docs" / "itl-workflow" / "CHATGPT.ru.md"


class SidecarIsolationTests(unittest.TestCase):
    def test_sidecar_has_no_discoverable_skill_or_plugin_bundle(self):
        self.assertEqual(list(CHATGPT.rglob("SKILL.md")), [])
        self.assertFalse((CHATGPT / ".agents" / "plugins" / "marketplace.json").exists())
        self.assertFalse((CHATGPT / "plugins").exists())
        self.assertFalse((CHATGPT / "generate_skills.py").exists())

    def test_chatgpt_uses_native_project_skills_via_project_instructions(self):
        text = GUIDE.read_text(encoding="utf-8")
        self.assertIn("session --server", text)
        self.assertIn("one-shot `tools-call`", text)
        self.assertIn("При любой команде itl-*", text)
        self.assertIn("локальный SKILL.md", text)
        self.assertNotIn("ChatGPT/RDC thin wrapper", text)

    def test_bridge_remains_inside_installed_workflow_package(self):
        self.assertTrue((CHATGPT / "mcp_bridge.py").is_file())
        self.assertTrue((CHATGPT / "bootstrap-prompt.ru.md").is_file())


if __name__ == "__main__":
    unittest.main()
