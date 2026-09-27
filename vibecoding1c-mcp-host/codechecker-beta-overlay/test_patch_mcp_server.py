"""Exercise the stable logic-only tool contract against the beta adapter."""

import argparse
import ast
import asyncio
from pathlib import Path
import unittest

from patch_mcp_server import LOGIC_TOOL, patch_source


class ToolRegistry:
    def tool(self):
        return lambda function: function


class BetaLogicToolTests(unittest.TestCase):
    def test_empty_code_keeps_stable_message(self):
        calls = []

        async def ask(question, create_new_session=False):
            calls.append((question, create_new_session))

        scope = {"mcp": ToolRegistry(), "ask_1c_ai": ask}
        exec(LOGIC_TOOL, scope)
        self.assertEqual(asyncio.run(scope["check_1c_logic"]("  ")), "Ошибка: код не может быть пустым")
        self.assertEqual(calls, [])

    def test_logic_prompt_uses_new_session_and_returns_plain_text(self):
        calls = []

        async def ask(question, create_new_session=False):
            calls.append((question, create_new_session))
            return type("Answer", (), {"answer": "Найдена ошибка логики"})()

        scope = {"mcp": ToolRegistry(), "ask_1c_ai": ask}
        exec(LOGIC_TOOL, scope)
        self.assertEqual(asyncio.run(scope["check_1c_logic"]("Возврат Истина;")), "Найдена ошибка логики")
        self.assertEqual(len(calls), 1)
        prompt, new_session = calls[0]
        self.assertTrue(new_session)
        self.assertIn("ТОЛЬКО на логические ошибки", prompt)
        self.assertIn("Не выполняй синтаксическую проверку", prompt)
        self.assertIn("```bsl\nВозврат Истина;\n```", prompt)

    def test_layout_drift_fails_closed(self):
        fixture = "async def ask_1c_ai(question):\n    pass\n\ndef main():\n    pass\n\nif __name__ == \"__main__\":\n    main()\n"
        result = patch_source(fixture)
        functions = [node.name for node in ast.parse(result).body if isinstance(node, ast.AsyncFunctionDef)]
        self.assertEqual(functions, ["ask_1c_ai", "check_1c_logic"])
        with self.assertRaisesRegex(RuntimeError, "already provides"):
            patch_source(result)
        with self.assertRaisesRegex(RuntimeError, "layout changed"):
            patch_source(fixture.replace("ask_1c_ai", "other_tool"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-source", type=Path)
    args = parser.parse_args()
    if args.vendor_source:
        patched = patch_source(args.vendor_source.read_text(encoding="utf-8"))
        ast.parse(patched)
        print("Pinned beta vendor source accepts the compatibility patch")
    unittest.main(argv=[__file__])
