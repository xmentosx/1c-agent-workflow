from __future__ import annotations

import json
import unittest

from observability import observe_stage, observe_tool
from patch_mcp_server import patch_source
from retry_policy import (
    call_tool_with_transient_network_retry,
    is_transient_network_error,
    send_with_reused_session_retry,
    send_with_transient_network_retry,
)


class FixtureApiError(Exception):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class FixtureDirectToolError(Exception):
    def __init__(self, diagnostic: str) -> None:
        super().__init__("direct tool failed")
        self._diagnostic = diagnostic

    def diagnostic_summary(self) -> str:
        return self._diagnostic


class ReadError(Exception):
    pass


class FixtureClient:
    def __init__(
        self,
        *,
        send_outcomes: list[object] | None = None,
        direct_outcomes: list[object] | None = None,
        reused_session: str = "reused-session",
    ) -> None:
        self.send_outcomes = list(send_outcomes or [])
        self.direct_outcomes = list(direct_outcomes or [])
        self.reused_session = reused_session
        self.session_requests: list[bool] = []
        self.sent_sessions: list[str] = []
        self.direct_sessions: list[str] = []

    async def get_or_create_session(self, *, create_new: bool) -> str:
        self.session_requests.append(create_new)
        if create_new:
            return f"session-{self.session_requests.count(True)}"
        return self.reused_session

    async def send_message(self, conversation_id: str, question: str) -> str:
        self.sent_sessions.append(conversation_id)
        outcome = self.send_outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return str(outcome)

    async def call_exact_tool(
        self,
        conversation_id: str,
        tool_name: str,
        arguments: dict,
    ) -> object:
        self.direct_sessions.append(conversation_id)
        outcome = self.direct_outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class RetryPolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_prompt_retry_uses_a_new_session(self) -> None:
        client = FixtureClient(
            send_outcomes=[
                FixtureApiError(
                    "Ошибка сети при отправке сообщения: peer closed connection "
                    "without sending complete message body (incomplete chunked read)"
                ),
                "ok",
            ]
        )
        delays: list[float] = []

        async def fake_sleep(delay: float) -> None:
            delays.append(delay)

        result = await send_with_transient_network_retry(
            client,
            "question",
            backoff_seconds=(0.25, 0.75),
            sleep=fake_sleep,
        )

        self.assertEqual("ok", result)
        self.assertEqual([True, True], client.session_requests)
        self.assertEqual(["session-1", "session-2"], client.sent_sessions)
        self.assertEqual([0.25], delays)

    async def test_retry_emits_attempt_outcomes_without_request_content(self) -> None:
        secret_question = "Секретный текст проверяемого модуля"
        client = FixtureClient(
            send_outcomes=[
                FixtureApiError("peer closed connection"),
                "ok",
            ]
        )

        with self.assertLogs(
            "MCP_1copilot.codechecker_observability",
            level="INFO",
        ) as captured:
            await send_with_transient_network_retry(
                client,
                secret_question,
                backoff_seconds=(0,),
            )

        events = [json.loads(record.getMessage()) for record in captured.records]
        self.assertEqual(
            ["transient_error", "success"],
            [event["outcome"] for event in events],
        )
        self.assertEqual([1, 2], [event["attempt"] for event in events])
        self.assertNotIn(secret_question, "\n".join(captured.output))

    async def test_direct_retry_reads_diagnostic_and_uses_a_new_session(self) -> None:
        client = FixtureClient(
            direct_outcomes=[
                FixtureDirectToolError(
                    "[DIRECT_TOOL_ERROR] Ошибка сети при отправке сообщения: "
                    "Server disconnected without sending a response."
                ),
                {"content": "ok"},
            ]
        )

        result = await call_tool_with_transient_network_retry(
            client,
            "mcp__knowledge-hub__Fetch_ITS",
            {"id": "root"},
            backoff_seconds=(0, 0),
        )

        self.assertEqual({"content": "ok"}, result)
        self.assertEqual([True, True], client.session_requests)
        self.assertEqual(["session-1", "session-2"], client.direct_sessions)

    async def test_ask_continuation_retries_the_reused_session(self) -> None:
        client = FixtureClient(
            send_outcomes=[
                FixtureApiError("connection reset by peer"),
                "continued",
            ],
            reused_session="conversation-42",
        )

        result = await send_with_reused_session_retry(
            client,
            "follow-up",
            backoff_seconds=(0, 0),
        )

        self.assertEqual("continued", result)
        self.assertEqual([False, False], client.session_requests)
        self.assertEqual(
            ["conversation-42", "conversation-42"],
            client.sent_sessions,
        )

    async def test_exhaustion_is_bounded_and_reraises_original_error(self) -> None:
        failures = [FixtureApiError("peer closed connection") for _ in range(3)]
        client = FixtureClient(send_outcomes=failures)
        delays: list[float] = []

        async def fake_sleep(delay: float) -> None:
            delays.append(delay)

        with self.assertRaises(FixtureApiError) as raised:
            await send_with_transient_network_retry(
                client,
                "question",
                backoff_seconds=(0.25, 0.75),
                sleep=fake_sleep,
            )

        self.assertIs(failures[-1], raised.exception)
        self.assertEqual(3, len(client.sent_sessions))
        self.assertEqual([0.25, 0.75], delays)

    async def test_does_not_retry_non_network_errors(self) -> None:
        failure = FixtureApiError("HTTP 401: token is invalid")
        client = FixtureClient(send_outcomes=[failure, "must-not-be-used"])

        with self.assertRaises(FixtureApiError) as raised:
            await send_with_transient_network_retry(client, "question")

        self.assertIs(failure, raised.exception)
        self.assertEqual([True], client.session_requests)

    def test_classifies_nested_and_direct_transport_diagnostics(self) -> None:
        outer = FixtureApiError("Ошибка 1C.ai")
        outer.__cause__ = RuntimeError("RemoteProtocolError: server disconnected")
        direct = FixtureDirectToolError(
            "peer closed connection without sending complete message body "
            "(incomplete chunked read)"
        )
        self.assertTrue(is_transient_network_error(outer))
        self.assertTrue(is_transient_network_error(direct))
        self.assertTrue(is_transient_network_error(ReadError("")))
        self.assertFalse(is_transient_network_error(FixtureApiError("HTTP 422")))

    def test_patcher_applies_shared_contract_without_changing_direct_format(self) -> None:
        tool_error_handlers = '''    except ApiError as e:
        return f"Ошибка при обращении к 1C.ai: {e.message}"
    except Exception as e:
        return f"Произошла неожиданная ошибка: {str(e)}"'''
        ask = f'''async def ask_1c_ai(question: str, create_new_session: bool = False) -> str:
    try:
        client = _get_client()
        conversation_id = await client.get_or_create_session(create_new=create_new_session)
        answer = await client.send_message(conversation_id, _truncate_input(question))
        return _sanitize_text(answer)
{tool_error_handlers}
'''
        named_tools = []
        for tool_name in ("check_1c_code", "review_1c_code"):
            named_tools.append(
                f'''async def {tool_name}(code: str) -> str:
    try:
        return await _send_prompt(code)
{tool_error_handlers}
'''
            )
        other_tools = []
        for index in range(8):
            other_tools.append(
                f'''async def tool_{index}(prompt: str) -> str:
    try:
        return await _send_prompt(prompt)
{tool_error_handlers}
'''
            )
        fixture = f'''from .models import ApiError, DirectToolError

async def _send_prompt(question: str) -> str:
    client = _get_client()
    conversation_id = await client.get_or_create_session(create_new=True)
    answer = await client.send_message(conversation_id, _truncate_input(question))
    cleaned = _sanitize_text(answer)
    if not cleaned:
        return "empty"
    return cleaned

async def _call_direct_tool(tool_name: str, arguments: dict, fallback_prompt: str = "") -> str:
    return tool_name

# =============================================================================
# MCP Tools
# =============================================================================

{ask}
{''.join(named_tools)}
{''.join(other_tools)}
'''

        patched = patch_source(fixture)

        self.assertIn("call_tool_with_transient_network_retry", patched)
        self.assertIn("send_with_transient_network_retry", patched)
        self.assertIn("send_with_reused_session_retry", patched)
        self.assertIn("from .observability import observe_stage, observe_tool", patched)
        self.assertIn('@observe_tool(\n    "check_1c_code"', patched)
        self.assertIn('@observe_tool(\n    "review_1c_code"', patched)
        self.assertIn('async with observe_stage(\n        "prompt"', patched)
        self.assertIn('async with observe_stage(\n            "direct_tool"', patched)
        self.assertIn("if create_new_session:", patched)
        self.assertIn("except ApiError:\n        raise", patched)
        self.assertEqual(11, patched.count("except ApiError:\n        raise"))
        self.assertEqual(
            13,
            patched.count("if is_transient_network_error(e):\n            raise"),
        )
        self.assertNotIn("MCP_TOOL_CALL_MODE", patched)
        self.assertNotIn("assistant_uuid", patched)


class ObservabilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_tool_and_stage_logs_are_correlated_and_content_safe(self) -> None:
        source = "Процедура СекретнаяПроцедура()\nКонецПроцедуры"

        @observe_tool("check_1c_code", mode_resolver=lambda: "direct")
        async def checked(code: str) -> str:
            async with observe_stage("prompt", inputChars=len(code)):
                return "ok"

        with self.assertLogs(
            "MCP_1copilot.codechecker_observability",
            level="INFO",
        ) as captured:
            result = await checked(source)

        self.assertEqual("ok", result)
        events = [json.loads(record.getMessage()) for record in captured.records]
        self.assertEqual(
            ["tool_start", "stage_start", "stage_end", "tool_end"],
            [event["event"] for event in events],
        )
        self.assertEqual(1, len({event["requestId"] for event in events}))
        self.assertEqual("direct", events[0]["mode"])
        self.assertEqual(len(source), events[0]["codeChars"])
        self.assertEqual("success", events[-1]["outcome"])
        self.assertEqual(2, events[-1]["resultChars"])
        self.assertNotIn(source, "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()
