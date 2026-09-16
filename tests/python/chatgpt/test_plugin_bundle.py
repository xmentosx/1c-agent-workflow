import json
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[3]
CHATGPT = REPO / ".agents" / "skills" / "1c-workflow" / "chatgpt"
PLUGIN = CHATGPT / "plugins" / "itl-workflow-chatgpt"


class PluginBundleTests(unittest.TestCase):
    def test_marketplace_is_chatgpt_only_and_worktree_scoped(self):
        marketplace = json.loads((CHATGPT / ".agents" / "plugins" / "marketplace.json").read_text(encoding="utf-8"))
        entry = marketplace["plugins"][0]
        self.assertEqual(entry["name"], "itl-workflow-chatgpt")
        self.assertEqual(entry["source"]["path"], "./plugins/itl-workflow-chatgpt")
        self.assertEqual(entry["policy"]["products"], ["CHATGPT"])
        self.assertFalse((REPO / ".agents" / "plugins" / "marketplace.json").exists())

    def test_plugin_manifest_exposes_only_skill_bundle(self):
        manifest = json.loads((PLUGIN / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "itl-workflow-chatgpt")
        self.assertEqual(manifest["skills"], "./skills/")
        self.assertNotIn("mcpServers", manifest)
        self.assertNotIn("apps", manifest)

    def test_generated_wrappers_match_itl_command_templates(self):
        templates = REPO / ".agents" / "skills" / "1c-workflow" / "kilo-command-templates"
        expected = {p.name.removesuffix(".md.template") for p in templates.rglob("*.md.template")}
        actual = {p.parent.name for p in (PLUGIN / "skills").glob("*/SKILL.md")}
        self.assertEqual(actual, expected | {"project-connect"})