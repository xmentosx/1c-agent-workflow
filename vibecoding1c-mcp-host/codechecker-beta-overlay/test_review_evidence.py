"""Offline review presentation regressions; never contact the provider."""
import ast
import asyncio
from copy import deepcopy
from dataclasses import dataclass, field
from hashlib import sha256
from pathlib import Path
import sys
from types import SimpleNamespace
from typing import Any, Dict, List, Optional
import unittest

from patch_mcp_server import patch_review_source
from review_evidence import split_review, evidence_for_answer


class SplitTests(unittest.TestCase):
    def assert_lossless(self, assembled, review, proof):
        self.assertEqual(proof["context"] + review, assembled)
        self.assertEqual(proof["assembled_sha256"], sha256(assembled.encode()).hexdigest())

    def test_search_documents_and_intermediate_summary_are_separate(self):
        text = "Замечание: имя ф неинформативно."
        context = "ИТС: материал со ссылками\n\nПромежуточная выжимка\n\n"
        tools = [{"tool_name": "Fetch_ITS", "tool_call_id": "e1",
                  "response_details": ["https://example.test/its"], "response_markdown": "Документ"}]
        result = {"final_text": text, "full_text": "Промежуточная выжимка\n\n"+text, "tool_results": tools}
        before = deepcopy(result)
        review, proof = split_review(result, context+text, str.strip)
        self.assertEqual(review, text)
        self.assertEqual(proof["status"], "separated")
        self.assertNotIn("tool_results", proof)
        self.assertEqual(result, before)
        self.assert_lossless(context+text, review, proof)
        proof["context"] = "changed"
        self.assertEqual(result, before)

    def test_no_additional_context_does_not_duplicate_review(self):
        review, proof = split_review({"final_text": "Один вывод"}, "Один вывод", str.strip)
        self.assertEqual(proof["status"], "unchanged")
        self.assertNotIn("review_text", evidence_for_answer(proof, review, review))
        self.assert_lossless(review, review, proof)

    def test_missing_or_empty_final_never_promotes_documentation_to_review(self):
        for final in (None, "", " \n ", 123):
            with self.subTest(final=final):
                review, proof = split_review({"final_text": final, "tool_results": [{"text": "ИТС"}]},
                                             "Материалы без итогового review", str.strip)
                self.assertEqual(proof["status"], "unseparated")
                self.assertEqual(review, "Материалы без итогового review")
                self.assert_lossless(review, review, proof)

    def test_unknown_order_and_deduplication_keep_complete_legacy_answer(self):
        for assembled in ("Итог\n\nПозднее уточнение", "Изменённый сборщиком итог"):
            review, proof = split_review({"final_text": "Итог"}, assembled, str.strip)
            self.assertEqual(proof["status"], "unseparated")
            self.assertEqual(review, assembled)
            self.assert_lossless(assembled, review, proof)

    def test_existing_sanitization_and_unicode_are_preserved(self):
        sanitize = lambda value: value.replace("<think>private</think>", "").strip()
        review, proof = split_review({"final_text": "<think>private</think>Ж🙂\r\n\tСтрока"},
                                     "ИТС\r\n\r\nЖ🙂\r\n\tСтрока", sanitize)
        self.assertEqual(review, "Ж🙂\r\n\tСтрока")
        self.assert_lossless("ИТС\r\n\r\nЖ🙂\r\n\tСтрока", review, proof)

    def test_reasoning_is_not_an_evidence_field_or_final_fallback(self):
        review, proof = split_review({"reasoning_text": "private", "full_text": ""}, "", str.strip)
        self.assertEqual(review, "")
        self.assertNotIn("private", repr(proof))

    def test_plugins_and_truncation_verdict_do_not_destroy_original_proof(self):
        review, proof = split_review({"final_text": "Исходный итог"}, "ИТС\n\nИсходный итог", str.strip)
        for answer in ("Вердикт усечения\n"+review, "Текст plugin"):
            retained = evidence_for_answer(proof, review, answer)
            self.assertEqual(retained["review_text"], review)
            self.assert_lossless("ИТС\n\nИсходный итог", retained["review_text"], retained)
        self.assertNotIn("review_text", proof)

    def test_no_json_or_source_binding_requirement(self):
        for text in ('Обычный текст', '{"invalid json', "Неверная цитата: отсутствующий метод"):
            review, proof = split_review({"final_text": text}, text, str.strip)
            self.assertEqual(review, text)
            self.assertNotIn("accepted", proof)


FIXTURE = '''
@dataclass
class PromptOutcome:
    text: str
    tool_results: List[Dict[str, Any]] = field(default_factory=list)

async def _send_prompt(owner, question, *, context=None):
    result = await collect(owner, question, context)
    cleaned = _sanitize_text(extract_best_text(result))
    if not cleaned:
        raise EmptyAnswerError("No answer")
    return PromptOutcome(text=cleaned, tool_results=result.get("tool_results", []))

@mcp.tool()
async def review_1c_code(code="", files=None) -> AnswerResult:
    call = {"code": code, "files": files}
    prompt = "Original review prompt: " + code
    outcome = await _send_prompt("review", prompt, context=call)
    return AnswerResult(answer=_answer(call, outcome.text), sources=["source"], truncation=["evidence"])

async def unrelated(code):
    return await _send_prompt("other", "Original other prompt: " + code)
'''


class AnswerResult:
    def __init__(self, **fields):
        self.__dict__.update(fields)
    def model_dump(self):
        return dict(self.__dict__)


def make_scope(hook=lambda value: value, result=None, failure=None):
    calls = []
    async def collect(*args):
        calls.append(args)
        if failure is not None:
            raise failure
        return result if result is not None else {
            "final_text": "Итог", "assembled": "ИТС\n\nИтог", "tool_results": [{"id": "source"}]}
    scope = dict(dataclass=dataclass, field=field, List=List, Dict=Dict, Any=Any, Optional=Optional,
        AnswerResult=AnswerResult, collect=collect, _sanitize_text=str.strip,
        extract_best_text=lambda r: r["assembled"], EmptyAnswerError=ValueError,
        _answer=lambda call, value: hook(value), mcp=SimpleNamespace(tool=lambda: lambda f: f),
        _itl_split_review=split_review, _itl_review_proof=evidence_for_answer)
    tree = ast.parse(patch_review_source(FIXTURE))
    tree.body = [n for n in tree.body if not isinstance(n, ast.ImportFrom)]
    exec(compile(tree, "<review-fixture>", "exec"), scope)
    return scope, calls


class IntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_only_review_opts_in_and_preserves_input_sources_and_truncation(self):
        scope, calls = make_scope()
        value = await scope["review_1c_code"]("Код Ж", ["Путь с пробелом/Модуль.bsl"])
        self.assertEqual(value.answer, "Итог")
        self.assertEqual(value.sources, ["source"])
        self.assertEqual(value.truncation, ["evidence"])
        self.assertEqual(calls, [("review", "Original review prompt: Код Ж",
                                 {"code": "Код Ж", "files": ["Путь с пробелом/Модуль.bsl"]})])
        other = await scope["unrelated"]("Другой код")
        self.assertEqual(other.text, "ИТС\n\nИтог")
        self.assertIsNone(other.review_evidence)
        self.assertEqual(other.tool_results, [{"id": "source"}])

    async def test_existing_hook_runs_once_and_evidence_survives(self):
        seen = []
        def hook(text):
            seen.append(text)
            return "Plugin changed review"
        scope, _ = make_scope(hook)
        result = await scope["review_1c_code"]("code")
        self.assertEqual(seen, ["Итог"])
        self.assertEqual(result.answer, "Plugin changed review")
        self.assertEqual(result.review_evidence["review_text"], "Итог")

    async def test_empty_answer_and_cancellation_remain_owned_by_existing_path(self):
        scope, _ = make_scope(result={"assembled": "", "final_text": ""})
        with self.assertRaises(ValueError):
            await scope["review_1c_code"]("code")
        scope, calls = make_scope(failure=asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError):
            await scope["review_1c_code"]("code")
        self.assertEqual(len(calls), 1)

    async def test_concurrent_reviews_do_not_exchange_evidence(self):
        scope, _ = make_scope()
        async def collect(owner, question, context):
            await asyncio.sleep(0)
            code = context["code"]
            return {"final_text": code, "assembled": "Evidence "+code+"\n\n"+code}
        scope["collect"] = collect
        values = await asyncio.gather(scope["review_1c_code"]("А"), scope["review_1c_code"]("Б"))
        self.assertEqual([v.answer for v in values], ["А", "Б"])
        self.assertEqual([v.review_evidence["context"] for v in values], ["Evidence А\n\n", "Evidence Б\n\n"])

    def test_pinned_boundaries_fail_closed_during_build_only(self):
        for source in (patch_review_source(FIXTURE), FIXTURE.replace("extract_best_text(result)", "other(result)"),
                       FIXTURE.replace("@dataclass", ""), FIXTURE.replace("class PromptOutcome", "class OtherOutcome")):
            with self.assertRaises(RuntimeError):
                patch_review_source(source)
        original, changed = ast.parse(FIXTURE), ast.parse(patch_review_source(FIXTURE))
        for name in ("unrelated",):
            a = next(n for n in original.body if getattr(n, "name", "") == name)
            b = next(n for n in changed.body if getattr(n, "name", "") == name)
            self.assertEqual(ast.dump(a), ast.dump(b))


if "--native" in sys.argv:
    sys.argv.remove("--native")

    class NativeModelTests(unittest.IsolatedAsyncioTestCase):
        async def test_real_review_result_serializes_evidence_without_network(self):
            from MCP_1copilot import mcp_server as server
            old = server._send_prompt
            calls = []
            async def retained(*args, **kwargs):
                calls.append(kwargs)
                return server.PromptOutcome(text="Итог", tool_results=[],
                    review_evidence={"status": "separated", "context": "ИТС\n\n",
                                     "assembled_sha256": sha256("ИТС\n\nИтог".encode()).hexdigest()})
            server._send_prompt = retained
            try:
                result = await server.review_1c_code(code="Функция Пример() Экспорт\nКонецФункции")
                self.assertEqual(len(calls), 1)
                self.assertTrue(calls[0]["_itl_review_parts"])
                self.assertEqual(result.model_dump()["review_evidence"]["context"], "ИТС\n\n")
                self.assertIn("Итог", result.answer)
            finally:
                server._send_prompt = old


if __name__ == "__main__":
    unittest.main()
