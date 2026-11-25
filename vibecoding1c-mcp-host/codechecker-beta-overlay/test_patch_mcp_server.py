"""Exercise logic-only prompt and evidence at the modern adapter boundary."""

import argparse
import ast
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

from patch_mcp_server import LOGIC_TOOL, patch_source


class ToolRegistry:
    def tool(self):
        return lambda function: function


class AnswerResult:
    def __init__(self, answer, truncation=None, sources=None, **fields):
        self.answer = answer
        self.truncation = truncation or []
        self.sources = sources or []
        self.__dict__.update(fields)

    def model_dump(self):
        return dict(self.__dict__)


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


def make_scope(limit=100000, answer="provider actual result", failure=None, rewrite=None):
    calls = []
    errors = []
    bounder = BounderStub(limit)
    refusal = SimpleNamespace(is_error=True, structured_content={"retryable": True})

    def begin(tool, arguments):
        if rewrite is not None:
            arguments = {"code": rewrite(arguments["code"])}
        return SimpleNamespace(tool=tool, arguments=arguments)

    async def send(owner, question, create_new=True, budget=None, *, context):
        calls.append((owner, question, create_new, context, budget))
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
        "_get_client": lambda: SimpleNamespace(new_budget=object),
        "_evidence": lambda evidence: evidence.evidence,
        "_error_result": error_result, "_condition_text": lambda error: error.message,
        "_capacity_refusal": lambda error: refusal,
    }
    exec(LOGIC_TOOL, scope)
    return scope, calls, errors, refusal


class BetaLogicToolTests(unittest.TestCase):
    def test_r05_guard_pair_keeps_exact_source_and_does_not_invent_a_verdict(self):
        guarded = (
            'Если КлючРаботы.ВидРаботы = "Задание" Тогда\n'
            '\tЕсли Не КлючРаботы.Свойство("Задание")\n'
            '\t\tИли ТипЗнч(КлючРаботы.Задание) <> Тип("СправочникСсылка.упо_Задания")\n'
            '\t\tИли Не ЗначениеЗаполнено(КлючРаботы.Задание) Тогда\n'
            '\t\tВызватьИсключение "Некорректная ссылка задания.";\n'
            '\tКонецЕсли;\nКонецЕсли;'
        )
        missing = guarded.replace('Если Не КлючРаботы.Свойство("Задание")\n\t\tИли ', 'Если ', 1)
        prefixes = []
        for code in (guarded, missing):
            scope, calls, _, _ = make_scope(answer="unsupported or contradictory provider answer")
            result = asyncio.run(scope["check_1c_logic"](code))
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0][2])
            prefix, actual = calls[0][1].split("Код:\n```bsl\n", 1)
            self.assertEqual(actual, code + "\n```")
            self.assertNotIn("КлючРаботы", prefix)  # No fixture-specific diagnosis in the instructions.
            prefixes.append(prefix)
            self.assertEqual(result.answer, "unsupported or contradictory provider answer")
            self.assertEqual(result.result, result.answer)
            self.assertFalse(result.truncation[0]["truncated"])
        self.assertEqual(prefixes[0], prefixes[1])
        self.assertIn('Свойство("Задание")', guarded)
        self.assertNotIn('Свойство("Задание")', missing)

    def test_logic_prompt_requires_correct_platform_paths_before_findings(self):
        scope, calls, _, _ = make_scope()
        asyncio.run(scope["check_1c_logic"]("Возврат Истина;"))
        instructions = calls[0][1].split("Код:\n```bsl\n", 1)[0]
        self.assertIn("Сначала проверь пути выполнения", instructions)
        self.assertLess(instructions.index("Сначала проверь пути выполнения"),
                        instructions.index("Затем перечисли только подтверждённые"))
        for required in (
            "В A Или B при A=Истина B НЕ вычисляется",
            "при A=Ложь B вычисляется. В A И B при A=Ложь B НЕ вычисляется",
            "при A=Истина B вычисляется",
            "«Поле объекта не обнаружено», а не возвращает Неопределено",
            "Существующее поле со значением Неопределено и отсутствующее поле — разные случаи",
            "Свойство проверяет наличие поля независимо от его значения",
            "дословная цитата", "конкретный вход/путь выполнения",
            "это не найденные ошибки", "это не доказательство полной корректности",
        ):
            self.assertIn(required, instructions)

    def test_all_sections_share_reachable_paths_and_a_final_consistency_check(self):
        scope, calls, _, _ = make_scope()
        asyncio.run(scope["check_1c_logic"]("Возврат Истина;"))
        instructions = calls[0][1].split("Код:\n```bsl\n", 1)[0]
        for required in (
            "Внешнее Не меняет результат скобок, но не порядок",
            "один согласованный разбор путей для карты и всех замечаний",
            "до первого возврата или исключения",
            "последующие операции на этом пути недостижимы",
            "проверь оба значения предшествующего условия",
            "не только в итоговом выводе",
            "без черновых версий и самоисправлений",
            "Карта защит и замечания — строки этой же таблицы",
            "Каждое утверждение запиши один раз",
            "не добавляй другой разбор или рекомендации после таблицы",
        ):
            self.assertIn(required, instructions)
        self.assertLess(instructions.index("один согласованный разбор путей"),
                        instructions.index("Затем перечисли только подтверждённые"))
        self.assertGreater(instructions.index("Перед ответом сверь каждое утверждение"),
                           instructions.index("Затем перечисли только подтверждённые"))

    def test_performance_requires_cost_evidence_without_hiding_provider_findings(self):
        answer = "Проблема: два чтения поля. Никогда вычисляется; всегда вычисляется."
        scope, calls, _, _ = make_scope(answer=answer)
        result = asyncio.run(scope["check_1c_logic"]("Возврат Данные.Порог;"))
        instructions = calls[0][1].split("Код:\n```bsl\n", 1)[0]
        for required in (
            "источник масштабируемых затрат и его достижимую кратность или рост стоимости",
            "либо предоставленный замер",
            "запросы или ввод-вывод на каждой итерации",
            "сами по себе не доказывают проблему производительности",
            "Дешёвая операция не становится дорогой только от повторения",
            "без замера её микрооптимизация не подтверждена",
            "гипотетической будущей заменой его типов",
            "Не дополняй список ошибками ради количества",
        ):
            self.assertIn(required, instructions)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result.answer, answer)
        self.assertEqual(result.result, answer)

    def test_regressions_and_holdouts_receive_identical_policy_and_exact_source(self):
        corpus = json.loads(Path(__file__).with_name("logic_review_cases.json").read_text(encoding="utf-8"))
        self.assertEqual({case["group"] for case in corpus}, {"regression", "control", "holdout"})
        instructions = set()
        for case in corpus:
            with self.subTest(case=case["id"]):
                scope, calls, _, _ = make_scope(answer="provider verdict")
                result = asyncio.run(scope["check_1c_logic"](case["code"]))
                self.assertEqual(len(calls), 1)
                prefix, actual = calls[0][1].split("Код:\n```bsl\n", 1)
                self.assertEqual(actual, case["code"] + "\n```")
                instructions.add(prefix)
                self.assertNotIn(case["id"], prefix)
                self.assertNotIn(case["expected"], prefix)
                self.assertEqual(result.answer, "provider verdict")
                self.assertFalse(result.truncation[0]["truncated"])
        self.assertEqual(len(instructions), 1)
        prefix = instructions.pop()
        for fixture_field in ("ДатаНачала", "ДатаОкончания", "Имя", "Сумма", "Баланс", "Остаток", "Контрагенты"):
            self.assertNotIn(fixture_field, prefix)

    def test_logic_findings_require_observed_required_result_and_requirement_evidence(self):
        scope, calls, _, _ = make_scope(answer="Недостижимость доказывает ошибку.")
        asyncio.run(scope["check_1c_logic"]("Возврат 0; Возврат 1;"))
        for prompt in [calls[0][1]]:
            for required in (
                "фактический наблюдаемый результат, требуемый результат и основание требования",
                "контракт языка/API, проверяемое условие кода или явно данное требование",
                "Факт о пути не равен дефекту поведения",
                "Их упрощение относится к исключённому анализу стиля",
                "Инициализация константой не доказывает, что значение должно меняться",
                "Не выводи требования только из имени метода",
                "ни в таблице, ни во вступлении, объяснениях или выводе",
            ):
                self.assertIn(required, prompt)

    def test_unreachable_required_behavior_must_keep_a_reachable_failure_witness(self):
        scope, calls, _, _ = make_scope()
        asyncio.run(scope["check_1c_logic"]("Возврат 0;"))
        for prompt in [calls[0][1]]:
            self.assertIn("Если обязательное действие недостижимо, покажи достижимый путь", prompt)
            self.assertIn("его отсутствие нарушает доказанное требование; сохрани такую ошибку", prompt)
            self.assertIn("Без доказанного расхождения фактического и требуемого результата", prompt)

    def test_unreachable_corpus_shares_policy_without_oracle_or_field_specific_dispatch(self):
        corpus = json.loads(Path(__file__).with_name("unreachable_findings_cases.json").read_text(encoding="utf-8"))
        self.assertEqual({c["group"] for c in corpus}, {"regression", "control", "holdout"})
        self.assertEqual({c["expected"] for c in corpus}, {"no-confirmed-error", "unsafe", "performance"})
        policies = set()
        for case in corpus:
            with self.subTest(case=case["id"]):
                scope, calls, _, _ = make_scope(answer=case["draft"])
                result = asyncio.run(scope["check_1c_logic"](case["code"]))
                prefix, body = calls[0][1].split("Код:\n```bsl\n", 1)
                policies.add(prefix)
                self.assertEqual(body, case["code"] + "\n```")
                self.assertEqual(result.answer, case["draft"])
                self.assertEqual(len(calls), 1)
        self.assertEqual(len(policies), 1)
        policy = policies.pop()
        for field in ("Редакция", "Переключатель", "ДатаОкончания", "Объем", "Признак", "Разрешено"):
            self.assertNotIn(field, policy)

    def test_unreachable_wording_never_triggers_local_output_suppression(self):
        for answer in ("Подтвержденная ошибка: обязательная ветка недостижима; результат неверен.",
                       "Ложное замечание о недостижимой ветке от провайдера."):
            scope, calls, _, _ = make_scope(answer=answer)
            result = asyncio.run(scope["check_1c_logic"]("Возврат 0;"))
            self.assertEqual(result.answer, answer)
            self.assertEqual(result.result, answer)

    def test_required_legacy_result_retains_answer_and_truncation(self):
        scope, calls, _, _ = make_scope(limit=5, answer="unsupported API response")
        result = asyncio.run(scope["check_1c_logic"]("АБВГДЕ"))
        self.assertEqual(result.result, "unsupported API response")
        self.assertEqual(result.result, result.answer)
        self.assertTrue(result.truncation[0]["truncated"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(scope["_ItlLogicResult"].__annotations__, {"result": str})

    def test_presence_and_negation_have_explicit_opposite_results(self):
        scope, calls, _, _ = make_scope(answer="untrusted polarity claim")
        asyncio.run(scope["check_1c_logic"]("Возврат Параметры.Свойство(ИмяПоля);"))
        self.assertEqual(len(calls), 1)
        for _, prompt, _, _, _ in calls:
            instructions = prompt.split("Код:\n```bsl\n", 1)[0]
            self.assertEqual(instructions.count("Таблица результатов вычисленного вызова:"), 1)
            for row in (
                "Поле отсутствует: С.Свойство(имя) = Ложь; Не С.Свойство(имя) = Истина.",
                "Поле существует: С.Свойство(имя) = Истина; Не С.Свойство(имя) = Ложь",
                "в том числе при значении поля Неопределено, Ложь, 0 или пустой строке",
                "Возвращаемое Булево и значение, полученное во второй параметр Свойство",
            ):
                self.assertIn(row, instructions)

    def test_boolean_claims_are_bound_to_evaluated_subexpressions_not_wrapper_results(self):
        scope, calls, _, _ = make_scope()
        asyncio.run(scope["check_1c_logic"]("Возврат Не (Не Параметры.Свойство(ИмяПоля));"))
        for _, prompt, _, _, _ in calls:
            instructions = prompt.split("Код:\n```bsl\n", 1)[0]
            for required in (
                "Каждое Истина/Ложь привязывай к точной цитате вычисленного подвыражения",
                "Не приписывай вызову результат его отрицания",
                "или всей цепочки И/Или",
                "Для пропущенного операнда указывай «не вычислялся», а не Истина/Ложь",
            ):
                self.assertIn(required, instructions)

    def test_polarity_corpus_has_one_policy_without_rewriting_provider_answer_or_source(self):
        corpus = json.loads(Path(__file__).with_name("predicate_polarity_cases.json").read_text(encoding="utf-8"))
        policies = set()
        for case in corpus:
            with self.subTest(case=case["id"]):
                scope, calls, _, _ = make_scope(answer=case["draft"])
                result = asyncio.run(scope["check_1c_logic"](case["code"]))
                self.assertEqual(len(calls), 1)
                prefix, actual = calls[0][1].split("Код:\n```bsl\n", 1)
                policies.add(prefix)
                self.assertEqual(actual, case["code"] + "\n```")
                self.assertEqual(result.answer, case["draft"])
                self.assertEqual(result.result, result.answer)
                for expected in case["oracle"]:
                    self.assertNotIn(expected["expression"], prefix)
        self.assertEqual(len(policies), 1)

    def test_required_legacy_result_is_retained_on_returned_errors(self):
        for code, failure in [(" ", None), ("АБВГДЕ", ApiError("broken")),
                              ("АБВГДЕ", RuntimeError("broken"))]:
            with self.subTest(failure=type(failure).__name__):
                scope, _, _, _ = make_scope(limit=5, failure=failure)
                result = asyncio.run(scope["check_1c_logic"](code))
                self.assertEqual(result.result, result.answer)
                self.assertIn("result", result.model_dump())

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
        owner, prompt, new_session, context, budget = calls[0]
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
                   "_error_result", "_condition_text", "_capacity_refusal", "_call_capability", "_get_client", "main")
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
        with self.assertRaisesRegex(RuntimeError, "layout changed"):
            patch_source(fixture.replace("def _get_client", "def missing_client"))
        with self.assertRaisesRegex(RuntimeError, "entrypoint changed"):
            patch_source(fixture.replace('if __name__', 'if  __name__'))
        with self.assertRaisesRegex(RuntimeError, "attempt boundary changed"):
            patch_source(fixture.replace('client.collect_prompt', 'client.other_prompt'))

    def test_complete_existing_prompt_is_preserved_exactly(self):
        import hashlib
        scope, _, _, _ = make_scope()
        # Fingerprint of the complete first prompt in queued 05327cf7, without code.
        self.assertEqual(hashlib.sha256(scope["_itl_logic_prompt"]("").encode()).hexdigest(),
                         "d4185cc2429c75633005da9f9dfa7978a9e5b49e6d26c418d88fd8bfa868d98a")

    def test_single_analysis_uses_one_budget_and_no_hidden_reviewer(self):
        scope, calls, errors, _ = make_scope(answer="Provider answer")
        budgets = []
        def new_budget():
            budget = object()
            budgets.append(budget)
            return budget
        scope["_get_client"] = lambda: SimpleNamespace(new_budget=new_budget)
        result = asyncio.run(scope["check_1c_logic"]("Возврат Истина;"))
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(budgets), 1)
        self.assertIs(calls[0][4], budgets[0])
        self.assertEqual(result.answer, "Provider answer")
        self.assertEqual(result.result, result.answer)
        self.assertEqual(errors, [])

    def test_recorded_findings_survive_without_lexical_or_semantic_requalification(self):
        import hashlib
        cases = json.loads(Path(__file__).with_name("single_pass_cases.json").read_text(encoding="utf-8"))
        self.assertEqual({case["id"] for case in cases},
                         {"r05-protected-first-analysis", "nonnegative-requirement", "zero-argument-requirement"})
        for case in cases:
            with self.subTest(case=case["id"]):
                self.assertEqual(hashlib.sha256(case["code"].encode()).hexdigest(), case["code_sha256"])
                scope, calls, errors, _ = make_scope(answer=case["answer"])
                result = asyncio.run(scope["check_1c_logic"](case["code"]))
                self.assertEqual(len(calls), 1)
                self.assertEqual(result.answer, case["answer"])
                self.assertEqual(result.result, result.answer)
                self.assertEqual(errors, [])
                self.assertTrue(calls[0][1].endswith("```bsl\n" + case["code"] + "\n```"))
                self.assertFalse(result.truncation[0]["truncated"])
                self.assertEqual(result.sources, [])

    def test_text_json_typos_and_empty_witness_are_not_local_error_conditions(self):
        answers = ["Обычный текст без JSON", '{"rows":[]}', '{"rows":',
                   "Параметры.Остатко; неотрицательное / неотрицательным",
                   '{"rows":[{"input":{"bindings":[],"path":""},"status":"ошибка логики"}]}']
        for answer in answers:
            with self.subTest(answer=answer):
                scope, calls, errors, _ = make_scope(answer=answer)
                result = asyncio.run(scope["check_1c_logic"]("Возврат Параметры.Остаток;"))
                self.assertEqual(result.answer, answer)
                self.assertEqual(result.result, answer)
                self.assertEqual(len(calls), 1)
                self.assertEqual(errors, [])

    def test_answer_hook_runs_once_and_owns_the_returned_text_and_legacy_alias(self):
        scope, calls, _, _ = make_scope(limit=4, answer="provider output")
        hooks = []
        def answer_hook(context, text, **kwargs):
            hooks.append((context, text, kwargs))
            return "hook output"
        scope["_answer"] = answer_hook
        result = asyncio.run(scope["check_1c_logic"]("Ж🙂АБВ"))
        self.assertEqual(len(hooks), 1)
        self.assertIs(hooks[0][0], calls[0][3])
        self.assertEqual(hooks[0][1], "provider output")
        self.assertEqual(hooks[0][2]["mode"], "prompt")
        self.assertEqual(result.answer, "hook output")
        self.assertEqual(result.result, "hook output")
        self.assertTrue(result.truncation[0]["truncated"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-source", type=Path)
    args = parser.parse_args()
    if args.vendor_source:
        patched = patch_source(args.vendor_source.read_text(encoding="utf-8"))
        ast.parse(patched)
        print("Pinned beta vendor source accepts the compatibility patch")
    unittest.main(argv=[__file__])
