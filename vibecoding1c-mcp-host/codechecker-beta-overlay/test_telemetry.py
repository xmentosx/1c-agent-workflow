"""Modern adapter boundary tests; every upstream collector is an offline stub."""

import asyncio
import hashlib
import inspect
import json
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from patch_mcp_server import patch_source
from test_patch_mcp_server import ApiError, ConversationCapacityError, make_scope
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "codechecker-overlay"))
import observability


FIXTURE = '''from __future__ import annotations
def _get_client():
    return test_client
def _bounder():
    return bounder_factory()
def _scope_owner(tool):
    return tool
def _answer(context, text, **kwargs):
    return text
def _evidence(bounder):
    return bounder.evidence
def _error_result(*args, **kwargs):
    return error_callback(*args, **kwargs)
def _capacity_refusal(error):
    return refusal_callback(error)
def _condition_text(error):
    return error.message
def _is_direct_mode():
    return True
async def _send_prompt(owner, question, create_new=True, budget=None, *, context=None):
    client = _get_client()
    budget = budget or client.new_budget()
    attempts = 0
    while True:
        attempts += 1
        entry = await client.acquire_conversation(owner, create_new=create_new, budget=budget)
        try:
            result = await client.collect_prompt(entry, question, budget=budget)
        except ApiError:
            if create_new and await client.retry_transport(attempts, budget):
                continue
            raise
        return SimpleNamespace(text=result)
async def _call_capability(owner, capability, arguments, fallback_prompt="", *, context=None):
    client = _get_client()
    budget = client.new_budget()
    attempts = 0
    while True:
        attempts += 1
        entry = await client.acquire_conversation(owner, create_new=True, budget=budget)
        try:
            result = await client.call_capability(entry, capability, arguments, budget=budget)
        except ApiError:
            if await client.retry_transport(attempts, budget):
                continue
            if fallback_prompt:
                return await _send_prompt(owner, fallback_prompt, context=context)
            raise
        return SimpleNamespace(text=result)
@mcp.tool()
async def check_1c_code(code):
    try:
        outcome = await _call_capability("check_1c_code", "syntax.validate", {"code": code}, "fallback")
        return AnswerResult(outcome.text)
    except ConversationCapacityError as error:
        return _capacity_refusal(error)
    except ApiError as error:
        return _error_result(error.message)
@mcp.tool()
async def review_1c_code(code="", files=None):
    try:
        outcome = await _send_prompt("review_1c_code", code)
        return AnswerResult(outcome.text)
    except ApiError as error:
        return _error_result(error.message)
@mcp.tool()
async def ask_1c_ai(question, create_new_session=False):
    return await _send_prompt("ask_1c_ai", question, create_new=create_new_session)
def main():
    pass

if __name__ == "__main__":
    main()
'''


class Client:
    def __init__(self, outcomes=None, retries=0, acquisition_error=None, block=False, block_at=1):
        self.outcomes = list(outcomes or ["unsupported-response-secret"])
        self.retries = retries
        self.acquisition_error = acquisition_error
        self.block = block
        self.block_at = block_at
        self.calls = []
        self.budgets = []
        self.entered = asyncio.Event()

    def new_budget(self):
        return object()

    async def acquire_conversation(self, owner, **kwargs):
        if self.acquisition_error:
            raise self.acquisition_error
        return "conversation-token-secret"

    async def collect_prompt(self, entry, sent, *, budget):
        return await self.collect("prompt", sent, budget)

    async def call_capability(self, entry, capability, sent, *, budget):
        return await self.collect("direct", sent, budget)

    async def collect(self, route, sent, budget):
        self.calls.append((route, sent))
        self.budgets.append(budget)
        if len(self.calls) == self.block_at:
            self.entered.set()
        if self.block and len(self.calls) == self.block_at:
            await asyncio.Event().wait()
        await asyncio.sleep(0)
        outcome = self.outcomes.pop(0) if len(self.outcomes) > 1 else self.outcomes[0]
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    async def retry_transport(self, attempts, budget):
        return attempts <= self.retries


def scope_for(client):
    scope, _, _, refusal = make_scope()
    scope.update(bounder_factory=scope["_bounder"], error_callback=scope["_error_result"],
                 refusal_callback=scope["_capacity_refusal"], _get_client=lambda: client,
                 test_client=client, SimpleNamespace=SimpleNamespace, __name__="fixture")
    package = ModuleType("MCP_1copilot")
    package.observability = observability
    with patch.dict(sys.modules, {"MCP_1copilot": package,
                                  "MCP_1copilot.observability": observability}):
        exec(patch_source(FIXTURE), scope)
    return scope, refusal


class ModernTelemetryTests(unittest.IsolatedAsyncioTestCase):
    def events(self, captured):
        return [json.loads(record.getMessage()) for record in captured.records]

    async def test_request_hash_attempt_and_terminal_are_content_safe(self):
        code = 'СекретныйКод("credential-secret");\r\n'
        client = Client()
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_logic"](code)
        events = self.events(captured)
        self.assertEqual([e["event"] for e in events],
                         ["tool_start", "upstream_attempt_start", "upstream_attempt_end",
                          "upstream_attempt_start", "upstream_attempt_end", "tool_end"])
        self.assertEqual(len({e["requestId"] for e in events}), 1)
        self.assertEqual(events[0]["snapshotSha256"], hashlib.sha256(code.encode()).hexdigest())
        self.assertEqual(events[0]["inputSha256"], hashlib.sha256(
            json.dumps({"code": code}, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
        self.assertEqual(events[1]["upstreamInputSha256"], hashlib.sha256(client.calls[0][1].encode()).hexdigest())
        self.assertEqual(events[-1]["attempts"], 2)
        self.assertIs(client.budgets[0], client.budgets[1])
        self.assertEqual(events[3]["upstreamInputSha256"], hashlib.sha256(client.calls[1][1].encode()).hexdigest())
        self.assertEqual(events[-1]["outcome"], "returned")
        self.assertEqual(result.answer, "unsupported-response-secret")
        self.assertFalse(result.truncation[0]["truncated"])
        text = "\n".join(captured.output)
        for secret in [code, "credential-secret", "conversation-token-secret", result.answer, client.calls[0][1]]:
            self.assertNotIn(secret, text)

    async def test_existing_prompt_retry_counts_without_new_budget(self):
        client = Client([ApiError("upstream-token-secret"), "answer-secret"], retries=1)
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_logic"]("code-secret")
        events = self.events(captured)
        ends = [e for e in events if e["event"] == "upstream_attempt_end"]
        self.assertEqual([e["attempt"] for e in ends], [1, 2, 3])
        self.assertEqual([e["outcome"] for e in ends], ["error", "returned", "returned"])
        self.assertEqual(events[-1]["attempts"], 3)
        self.assertEqual(events[-1]["outcome"], "returned")
        self.assertIs(client.budgets[0], client.budgets[1])
        self.assertIs(client.budgets[1], client.budgets[2])
        self.assertEqual(result.answer, "answer-secret")
        self.assertNotIn("upstream-token-secret", "\n".join(captured.output))

    async def test_direct_retry_and_fallback_share_parent_request(self):
        for retries, outcomes, stages in [(1, [ApiError("private"), "ok"], ["direct", "direct"]),
                                         (0, [ApiError("private"), "ok"], ["direct", "prompt"])]:
            with self.subTest(retries=retries):
                client = Client(outcomes, retries=retries)
                scope, _ = scope_for(client)
                with self.assertLogs(observability.LOGGER, level="INFO") as captured:
                    result = await scope["check_1c_code"]("code-secret")
                events = self.events(captured)
                self.assertEqual(len({e["requestId"] for e in events}), 1)
                self.assertEqual([e["stage"] for e in events if e["event"] == "upstream_attempt_start"], stages)
                self.assertEqual(events[-1]["attempts"], 2)
                self.assertEqual(result.answer, "ok")

    async def test_returned_api_error_is_terminal_error(self):
        scope, _ = scope_for(Client([ApiError("private-exception-message")]))
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_logic"]("code-secret")
        events = self.events(captured)
        self.assertIn("private-exception-message", result.answer)
        self.assertEqual(events[-1]["outcome"], "error")
        self.assertEqual(events[-1]["attempts"], 1)
        self.assertNotIn("private-exception-message", "\n".join(captured.output))

    async def test_review_error_is_terminal_error_without_returning_the_draft(self):
        client = Client(["draft-private", ApiError("review-private")])
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_logic"]("code-private")
        events = self.events(captured)
        self.assertEqual([e["outcome"] for e in events if e["event"] == "upstream_attempt_end"],
                         ["returned", "error"])
        self.assertEqual(events[-1]["attempts"], 2)
        self.assertEqual(events[-1]["outcome"], "error")
        self.assertNotIn("draft-private", result.answer)
        for secret in ("draft-private", "review-private", "code-private"):
            self.assertNotIn(secret, "\n".join(captured.output))

    async def test_cancellation_during_review_has_one_terminal_and_shared_budget(self):
        client = Client(block=True, block_at=2)
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            task = asyncio.create_task(scope["check_1c_logic"]("code-private"))
            await client.entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        events = self.events(captured)
        self.assertEqual(len([e for e in events if e["event"] == "tool_end"]), 1)
        self.assertEqual(events[-1]["outcome"], "cancelled")
        self.assertEqual(events[-1]["attempts"], 2)
        self.assertIs(client.budgets[0], client.budgets[1])

    async def test_refusal_before_collector_has_zero_attempts(self):
        client = Client(acquisition_error=ConversationCapacityError("private refusal"))
        scope, refusal = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_code"]("code-secret")
        events = self.events(captured)
        self.assertIs(result, refusal)
        self.assertEqual([e["event"] for e in events], ["tool_start", "tool_end"])
        self.assertEqual(events[-1]["outcome"], "refused")
        self.assertEqual(events[-1]["attempts"], 0)
        self.assertEqual(client.calls, [])

    async def test_cancellation_has_exactly_one_terminal_outcome(self):
        client = Client(block=True)
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            task = asyncio.create_task(scope["check_1c_logic"]("code-secret"))
            await client.entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        events = self.events(captured)
        terminals = [e for e in events if e["event"] == "tool_end"]
        self.assertEqual(len(terminals), 1)
        self.assertEqual(terminals[0]["outcome"], "cancelled")
        self.assertEqual(terminals[0]["attempts"], 1)
        self.assertEqual(events[-2]["outcome"], "cancelled")

    async def test_concurrent_requests_keep_ids_hashes_and_counters_separate(self):
        scope, _ = scope_for(Client())
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            await asyncio.gather(scope["check_1c_logic"]("first-secret"),
                                 scope["check_1c_logic"]("second-secret"))
        groups = {}
        for event in self.events(captured):
            groups.setdefault(event["requestId"], []).append(event)
        self.assertEqual(len(groups), 2)
        self.assertEqual({g[0]["snapshotSha256"] for g in groups.values()},
                         {hashlib.sha256(s.encode()).hexdigest() for s in ["first-secret", "second-secret"]})
        self.assertTrue(all(g[-1]["attempts"] == 2 and g[-1]["outcome"] == "returned" for g in groups.values()))

    async def test_file_reference_is_not_logged_as_loaded_code(self):
        scope, _ = scope_for(Client())
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            await scope["review_1c_code"](files=["private/path/Модуль.bsl"])
        events = self.events(captured)
        self.assertEqual(events[0]["inputKind"], "files")
        self.assertNotIn("snapshotSha256", events[0])
        self.assertIn("inputSha256", events[0])
        self.assertNotIn("private/path", "\n".join(captured.output))

    async def test_reused_discussion_does_not_acquire_retry_authority(self):
        client = Client([ApiError("private")], retries=2)
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            with self.assertRaises(ApiError):
                await scope["ask_1c_ai"]("question-secret")
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(self.events(captured)[-1]["outcome"], "error")

    async def test_unobserved_helpers_and_completed_context_do_not_emit_or_leak(self):
        client = Client()
        scope, _ = scope_for(client)
        with self.assertLogs(observability.LOGGER, level="INFO"):
            await scope["check_1c_logic"]("first-secret")
        with self.assertNoLogs(observability.LOGGER, level="INFO"):
            await scope["_send_prompt"]("owner", "outside-secret")
        self.assertIsNone(observability._MODERN_STATE.get())
        self.assertIsNone(observability._REQUEST_CONTEXT.get())

    async def test_wrappers_preserve_registered_tool_signature(self):
        scope, _ = scope_for(Client())
        signature = inspect.signature(scope["review_1c_code"])
        self.assertEqual(list(signature.parameters), ["code", "files"])
        self.assertEqual(signature.parameters["code"].default, "")
        self.assertTrue(inspect.iscoroutinefunction(scope["review_1c_code"]))

    async def test_observation_does_not_read_mode_or_configuration(self):
        scope, _ = scope_for(Client())
        def unavailable_mode():
            raise AssertionError("Observation must not resolve configuration")
        scope["_is_direct_mode"] = unavailable_mode
        with self.assertLogs(observability.LOGGER, level="INFO") as captured:
            result = await scope["check_1c_code"]("code-secret")
        events = self.events(captured)
        self.assertEqual(result.answer, "unsupported-response-secret")
        self.assertNotIn("mode", events[0])
        self.assertEqual(events[1]["stage"], "direct")


if __name__ == "__main__":
    unittest.main()
