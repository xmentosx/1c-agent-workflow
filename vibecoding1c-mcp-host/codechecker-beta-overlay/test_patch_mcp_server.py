"""Exercise logic-only prompt and evidence at the modern adapter boundary."""

import argparse
import ast
import asyncio
from pathlib import Path
from types import SimpleNamespace
import unittest

from patch_mcp_server import LOGIC_TOOL, patch_source


class ToolRegistry:
    def tool(self):
        return lambda function: function


class AnswerResult:
    def __init__(self, answer, truncation=None, sources=None):
        self.answer = answer
        self.truncation = truncation or []
        self.sources = sources or []


class ApiError(Exception):
    def __init__(self, message):
        self.message = message
        super().__init__(message)


class ConversationCapacityError(ApiError):
    pass


class BounderStub:
    """The upstream field-boundary dependency, without provider/config access."""

    def __init__(self, limit):
        self.limit = limit
        self.evidence = []

    def bound(self, field, value):
        transmitted = value[:self.limit]
        self.evidence.append({
            "field": field, "truncated": len(value) > self.limit,
            "original_length": len(value), "transmitted_length": len(transmitted),
        })
        return transmitted


def make_scope(limit=100000, answer="Найдена ошибка логики", failure=None, rewrite=None):
    calls = []
    errors = []
    bounder = BounderStub(limit)
    refusal = SimpleNamespace(is_error=True, structured_content={"retryable": True})

    def begin(tool, arguments):
        if rewrite is not None:
            arguments = {"code": rewrite(arguments["code"])}
        return SimpleNamespace(tool=tool, arguments=arguments)

    async def send(owner, question, create_new=True, *, context):
        calls.append((owner, question, create_new, context))
        if failure is not None:
            raise failure
        return SimpleNamespace(text=answer)

    def error_result(message, evidence=None, context=None):
        errors.append((message, evidence, context))
        return AnswerResult(message, evidence.evidence if evidence else [])

    scope = {
        "mcp": ToolRegistry(), "AnswerResult": AnswerResult,
        "ApiError": ApiError, "ConversationCapacityError": ConversationCapacityError,
        "plugin_runtime": SimpleNamespace(begin=begin),
        "_bounder": lambda: bounder, "_scope_owner": lambda task: task,
        "_send_prompt": send, "_answer": lambda context, text, **kwargs: text,
        "_evidence": lambda evidence: evidence.evidence,
        "_error_result": error_result, "_condition_text": lambda error: error.message,
        "_capacity_refusal": lambda error: refusal,
    }
    exec(LOGIC_TOOL, scope)
    return scope, calls, errors, refusal


class BetaLogicToolTests(unittest.TestCase):
    def test_empty_code_keeps_stable_message_without_upstream_call(self):
        scope, calls, _, _ = make_scope()
        result = asyncio.run(scope["check_1c_logic"]("  "))
        self.assertEqual(result.answer, "Ошибка: код не может быть пустым")
        self.assertEqual(result.truncation, [])
        self.assertEqual(calls, [])

    def test_logic_prompt_uses_fresh_scope_and_preserves_answer_and_evidence(self):
        scope, calls, _, _ = make_scope(answer="unsupported API response")
        code = "Возврат Истина;"
        result = asyncio.run(scope["check_1c_logic"](code))
        self.assertEqual(result.answer, "unsupported API response")
        self.assertEqual(result.truncation, [{"field": "code", "truncated": False,
                                              "original_length": len(code), "transmitted_length": len(code)}])
        self.assertEqual(result.sources, [])
        self.assertEqual(len(calls), 1)
        owner, prompt, new_session, context = calls[0]
        self.assertEqual(owner, "check_1c_logic")
        self.assertEqual(context.tool, "check_1c_logic")
        self.assertTrue(new_session)
        self.assertIn("ТОЛЬКО на логические ошибки", prompt)
        self.assertIn("Не выполняй синтаксическую проверку", prompt)
        self.assertIn("```bsl\nВозврат Истина;\n```", prompt)

    def test_code_point_boundaries_preserve_crlf_unicode_and_closing_fence(self):
        for length in (31, 32, 33):
            with self.subTest(length=length):
                code = ("Ж\r\n🙂" * 9)[:length]
                scope, calls, _, _ = make_scope(limit=32)
                result = asyncio.run(scope["check_1c_logic"](code))
                self.assertEqual(result.truncation, [{"field": "code", "truncated": length > 32,
                                                      "original_length": length, "transmitted_length": min(length, 32)}])
                self.assertTrue(calls[0][1].endswith("```bsl\n" + code[:32] + "\n```"))
                self.assertGreater(len(calls[0][1]), 32)
                self.assertEqual(len(calls), 1)

    def test_r08_sized_code_does_not_lose_tail_to_prompt_overhead(self):
        code = "Ж" * (99820 - len("\nВозврат Истина;")) + "\nВозврат Истина;"
        scope, calls, _, _ = make_scope()
        result = asyncio.run(scope["check_1c_logic"](code))
        self.assertFalse(result.truncation[0]["truncated"])
        self.assertGreater(len(calls[0][1]), 100000)
        self.assertTrue(calls[0][1].endswith("```bsl\n" + code + "\n```"))

    def test_plugin_arguments_are_bounded_before_prompt_assembly(self):
        scope, calls, _, _ = make_scope(limit=12, rewrite=lambda code: code + "🙂" * 20)
        result = asyncio.run(scope["check_1c_logic"]("Возврат;"))
        self.assertEqual(result.truncation[0]["original_length"], 28)
        self.assertEqual(result.truncation[0]["transmitted_length"], 12)
        self.assertTrue(calls[0][1].endswith("```bsl\nВозврат;🙂🙂🙂🙂\n```"))

    def test_api_condition_keeps_truncation_and_does_not_fallback(self):
        scope, calls, errors, _ = make_scope(limit=4, failure=ApiError("transport failed"))
        result = asyncio.run(scope["check_1c_logic"]("Возврат Истина;"))
        self.assertEqual(result.answer, "transport failed")
        self.assertTrue(result.truncation[0]["truncated"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(errors[0][2].tool, "check_1c_logic")

    def test_capacity_refusal_retains_typed_error_without_retry(self):
        scope, calls, errors, refusal = make_scope(failure=ConversationCapacityError("full"))
        self.assertIs(asyncio.run(scope["check_1c_logic"]("Возврат Истина;")), refusal)
        self.assertTrue(refusal.is_error)
        self.assertEqual(len(calls), 1)
        self.assertEqual(errors, [])

    def test_unexpected_failure_retains_field_evidence(self):
        scope, calls, _, _ = make_scope(limit=4, failure=ValueError("broken"))
        result = asyncio.run(scope["check_1c_logic"]("Возврат Истина;"))
        self.assertIn("broken", result.answer)
        self.assertTrue(result.truncation[0]["truncated"])
        self.assertEqual(len(calls), 1)

    def test_layout_drift_fails_closed(self):
        helpers = ("_bounder", "_scope_owner", "_send_prompt", "_answer", "_evidence",
                   "_error_result", "_condition_text", "_capacity_refusal", "_call_capability", "main")
        fixture = "\n".join(f"def {name}():\n    pass\n" for name in helpers)
        fixture = fixture.replace('def _send_prompt():\n    pass',
                                  'async def _send_prompt():\n    return await client.collect_prompt(entry, sent)')
        fixture = fixture.replace('def _call_capability():\n    pass',
                                  'async def _call_capability():\n    return await client.call_capability(entry, capability, sent)')
        fixture += '\n\nif __name__ == "__main__":\n    main()\n'
        result = patch_source(fixture)
        functions = [node.name for node in ast.parse(result).body if isinstance(node, ast.AsyncFunctionDef)]
        self.assertEqual(functions, ["_send_prompt", "_call_capability", "check_1c_logic"])
        with self.assertRaisesRegex(RuntimeError, "already provides"):
            patch_source(result)
        with self.assertRaisesRegex(RuntimeError, "layout changed"):
            patch_source(fixture.replace("_bounder", "missing_bounder"))
        with self.assertRaisesRegex(RuntimeError, "entrypoint changed"):
            patch_source(fixture.replace('if __name__', 'if  __name__'))
        with self.assertRaisesRegex(RuntimeError, "attempt boundary changed"):
            patch_source(fixture.replace('client.collect_prompt', 'client.other_prompt'))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-source", type=Path)
    args = parser.parse_args()
    if args.vendor_source:
        patched = patch_source(args.vendor_source.read_text(encoding="utf-8"))
        ast.parse(patched)
        print("Pinned beta vendor source accepts the compatibility patch")
    unittest.main(argv=[__file__])
