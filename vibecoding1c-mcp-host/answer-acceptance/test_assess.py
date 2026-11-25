import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("acceptance", Path(__file__).with_name("assess.py"))
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


class AnswerAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ответы с пробелом ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.code = self.root / "код с пробелом.bsl"
        self.code.write_bytes('Функция Итог()\r\n    Возврат 0;\r\nКонецФункции\r\n'.encode("utf-8"))
        self.answer = self.root / "ответ.txt"

    def packet(self, answer=None, response=False):
        if answer is None:
            answer = '| Статус | Факт |\n|---|---|\n| не подтверждено | Функция возвращает 0. |\n'
        self.answer.write_bytes(answer.encode("utf-8"))
        self.directory = self.root / "приёмка"
        api.prepare(self.code, self.answer, self.directory, response)
        self.review = api.load(self.directory / "review.json")
        return answer

    def complete(self):
        self.review["reviewer"] = "reviewer:offline"
        self.review["format"] = dict(verdict="pass", rationale="Одна согласованная таблица.")
        for decision in self.review["units"]:
            decision.update(verdict="not-a-claim", rationale="Заголовок/разделитель.")
        decision = self.review["units"][-1]
        decision.update(verdict="supported", rationale="Возвращаемое значение сопоставлено с кодом.",
                        witness="Любой вызов → Возврат 0; → результат 0. Требования вернуть другое число нет.",
                        evidence=[dict(kind="source", quote="Возврат 0;", line=2)])

    def evaluate(self):
        path = self.directory / "review.json"
        api.save(path, self.review)
        return api.assess(self.directory, path)

    def test_complete_supported_answer_is_accepted_without_provider(self):
        self.packet()
        self.complete()
        result = self.evaluate()
        self.assertTrue(result["accepted"])
        self.assertEqual("accepted", result["status"])
        self.assertIn("not product-code correctness", result["scope"])

    def test_primary_table_alone_cannot_cover_false_prose(self):
        self.packet('| Факт |\n|---|\n| Возвращается 0. |\n\nНо код обязан вернуть 5.\n')
        self.complete()
        last = self.review["units"].pop()
        self.assertEqual("u0004", last["id"])
        with self.assertRaisesRegex(api.EvidenceError, "every answer unit"):
            self.evaluate()

    def test_pending_outside_table_cannot_be_accepted(self):
        self.packet('| Факт |\n|---|\n| Возвращается 0. |\n\nВторой возврат означает обязательный результат 5.\n')
        self.complete()
        self.review["units"][2].update(self.review["units"][-1])
        self.review["units"][2]["id"] = "u0003"
        self.review["units"][2]["sha256"] = api.load(self.directory / "packet.json")["units"][2]["sha256"]
        self.review["units"][-1].update(verdict="pending", rationale="")
        result = self.evaluate()
        self.assertEqual("unverified", result["status"])
        self.assertFalse(result["accepted"])

    def test_false_addition_rejects_whole_answer_and_preserves_original(self):
        original = self.packet('| Факт |\n|---|\n| Возвращается 0. |\n\nИз имени функции следует требование вернуть 5.\n')
        self.complete()
        self.review["units"][-1].update(verdict="contradicted", rationale="Требование придумано; оно отсутствует в исходнике.")
        result = self.evaluate()
        self.assertEqual("rejected", result["status"])
        self.assertEqual(original.encode(), (self.directory / "answer.txt").read_bytes())
        self.assertEqual(self.review["units"][-1]["rationale"], result["rejected"][0]["rationale"])

    def test_quote_at_another_line_is_not_valid_evidence(self):
        self.packet()
        self.complete()
        self.review["units"][-1]["evidence"][0]["line"] = 1
        result = self.evaluate()
        self.assertEqual("unverified", result["status"])
        self.assertIn("claimed line", result["unresolved"][0]["reason"])

    def test_invented_quote_is_unverified_not_a_disproven_claim(self):
        self.packet()
        self.complete()
        self.review["units"][-1]["evidence"][0]["quote"] = "Возврат 5;"
        self.assertEqual("unverified", self.evaluate()["status"])

    def test_supported_claim_needs_a_witness_not_only_a_quote(self):
        self.packet()
        self.complete()
        self.review["units"][-1]["witness"] = ""
        self.assertEqual("unverified", self.evaluate()["status"])

    def test_source_change_invalidates_review_even_if_verdict_was_green(self):
        self.packet()
        self.complete()
        (self.directory / "source.raw.bsl").write_bytes(b"different code")
        with self.assertRaisesRegex(api.EvidenceError, "identity changed"):
            self.evaluate()

    def test_raw_response_change_invalidates_review(self):
        self.packet()
        self.complete()
        (self.directory / "response.raw").write_bytes(b"different answer")
        with self.assertRaisesRegex(api.EvidenceError, "identity changed"):
            self.evaluate()

    def test_display_copy_and_inventory_cannot_be_edited_to_hide_findings(self):
        self.packet()
        self.complete()
        path = self.directory / "answer.txt"
        original = path.read_bytes()
        path.write_bytes(b"clean")
        with self.assertRaisesRegex(api.EvidenceError, "Preserved answer changed"):
            self.evaluate()
        path.write_bytes(original)
        packet = api.load(self.directory / "packet.json")
        packet["units"].pop()
        api.save(self.directory / "packet.json", packet)
        with self.assertRaisesRegex(api.EvidenceError, "inventory changed"):
            self.evaluate()

    def test_duplicate_and_stale_unit_decisions_fail_closed(self):
        self.packet()
        self.complete()
        self.review["units"].append(copy.deepcopy(self.review["units"][0]))
        with self.assertRaisesRegex(api.EvidenceError, "exactly once"):
            self.evaluate()
        self.review["units"].pop()
        self.review["units"][-1]["sha256"] = "stale"
        with self.assertRaisesRegex(api.EvidenceError, "unit changed"):
            self.evaluate()

    def test_no_analysis_empty_or_links_only_is_not_clean(self):
        for answer in ("", "https://example.invalid/reference\n"):
            with self.subTest(answer=answer):
                self.directory = self.root / ("пусто" if not answer else "ссылки")
                self.answer.write_bytes(answer.encode())
                api.prepare(self.code, self.answer, self.directory)
                self.review = api.load(self.directory / "review.json")
                self.review["reviewer"] = "reviewer"
                self.review["format"] = dict(verdict="pass", rationale="Оформление отдельно.")
                for unit in self.review["units"]:
                    unit.update(verdict="not-a-claim", rationale="Нет содержательного анализа.")
                self.assertEqual("unverified", self.evaluate()["status"])

    def test_scope_and_format_do_not_disappear_behind_correct_main_finding(self):
        self.packet()
        self.complete()
        self.review["format"] = dict(verdict="fail", rationale="Добавлены отдельные версии анализа.")
        self.assertEqual("rejected", self.evaluate()["status"])
        self.review["format"]["verdict"] = "pass"
        self.review["units"][-1].update(verdict="out-of-scope", rationale="Непроверенная рекомендация по реализации.")
        self.assertEqual("rejected", self.evaluate()["status"])

    def test_platform_reference_must_be_exact_and_hash_bound(self):
        self.packet()
        self.complete()
        reference = self.root / "сохранённая справка.txt"
        reference.write_bytes("Правило API\nПример\n".encode())
        evidence = dict(kind="reference", path=str(reference), sha256=api.sha(reference.read_bytes()), quote="Правило API", line=1)
        self.review["units"][-1]["evidence"].append(evidence)
        self.assertEqual("accepted", self.evaluate()["status"])
        reference.write_bytes("Другое правило\n".encode())
        self.assertEqual("unverified", self.evaluate()["status"])

    def test_mcp_raw_bytes_and_metadata_are_preserved_and_copies_checked(self):
        answer = "Ответ с кириллицей\r\n| Факт |\r\n|---|\r\n| 0 |\r\n"
        structured = dict(answer=answer, result=answer, truncation=[dict(truncated=False)], sources=[])
        raw = dict(response=dict(structuredContent=structured, content=[dict(type="text", text=json.dumps(structured, ensure_ascii=False))]))
        self.packet(json.dumps(raw, ensure_ascii=False), response=True)
        self.assertEqual(self.answer.read_bytes(), (self.directory / "response.raw").read_bytes())
        self.assertEqual(answer.encode(), (self.directory / "answer.txt").read_bytes())
        structured["result"] = "a different convenient copy"
        with self.assertRaisesRegex(api.EvidenceError, "answer/result disagree"):
            api.extract_answer(json.dumps(raw, ensure_ascii=False).encode())

    def test_packet_never_overwrites_evidence_and_cli_continues_same_packet(self):
        self.packet()
        with self.assertRaisesRegex(api.EvidenceError, "directory exists"):
            api.prepare(self.code, self.answer, self.directory)
        command = [sys.executable, "-X", "utf8", "-B", str(Path(__file__).with_name("assess.py")), "assess", "--packet", str(self.directory), "--review", str(self.directory / "review.json")]
        pending = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(2, pending.returncode)
        self.assertFalse(json.loads(pending.stdout)["accepted"])
        self.complete()
        api.save(self.directory / "review.json", self.review)
        passed = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(0, passed.returncode, passed.stderr.decode())
        self.assertTrue(json.loads(passed.stdout)["accepted"])

    def test_arbitrary_markdown_fences_and_conclusions_remain_in_coverage(self):
        answer = "Введение\n\n```bsl\nВозврат 0;\n```\n\n| Факт |\n|---|\n| 0 |\n\n> Иное утверждение вне таблицы.\n"
        chunks = api.units(answer)
        covered = {i for u in chunks for i in range(u["start"], u["end"])}
        self.assertTrue(all(i in covered for i, char in enumerate(answer) if not char.isspace()))
        self.assertTrue(any("Иное утверждение" in u["text"] for u in chunks))
        self.assertTrue(any(u["text"].startswith("```bsl") for u in chunks))

    def test_bom_mixed_newlines_and_unicode_offsets_preserve_original_bytes(self):
        raw = b'\xef\xbb\xbf' + self.code.read_bytes()
        self.code.write_bytes(raw)
        answer = "Проверка 🔎\r\n\r\n| Факт |\n|---|\n| Возврат 0. |\r\n"
        self.packet(answer)
        self.assertEqual(raw, (self.directory / "source.raw.bsl").read_bytes())
        self.assertEqual(answer.encode(), (self.directory / "answer.txt").read_bytes())
        for unit in api.load(self.directory / "packet.json")["units"]:
            self.assertEqual(unit["text"], answer[unit["start"]:unit["end"]])
        self.complete()
        self.assertEqual("accepted", self.evaluate()["status"])

    def test_null_or_boolean_review_fields_do_not_count_as_completed_review(self):
        self.packet()
        self.complete()
        for field, value in (("rationale", None), ("witness", False)):
            with self.subTest(field=field):
                old = self.review["units"][-1][field]
                self.review["units"][-1][field] = value
                self.assertEqual("unverified", self.evaluate()["status"])
                self.review["units"][-1][field] = old
        self.review["reviewer"] = None
        self.assertEqual("unverified", self.evaluate()["status"])


if __name__ == "__main__":
    unittest.main()
