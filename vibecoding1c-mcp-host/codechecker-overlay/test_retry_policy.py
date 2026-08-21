from __future__ import annotations

import io
import hashlib
import json
import unittest
from unittest.mock import patch

from observability import (
    LOGGER,
    _correlation_from_context,
    classify_error,
    log_event,
    observe_stage,
    observe_tool,
)
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
    def __init__(
        self,
        diagnostic: str,
        *,
        expected_tool: str = "mcp__syntax-checker__validate",
        actual_tool: str = "",
        phase: str = "match",
    ) -> None:
        super().__init__(diagnostic)
        self._diagnostic = diagnostic
        self.expected_tool = expected_tool
        self.actual_tool = actual_tool
        self.phase = phase

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
        self.assertEqual("transient_network", events[0]["errorClass"])
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

    async def test_missing_assistant_uuid_retries_once_with_a_fresh_session(self) -> None:
        failure = FixtureDirectToolError(
            "Upstream не вернул assistant_uuid",
        )
        client = FixtureClient(direct_outcomes=[failure, {"content": "ok"}])

        with self.assertLogs(
            "MCP_1copilot.codechecker_observability",
            level="INFO",
        ) as captured:
            result = await call_tool_with_transient_network_retry(
                client,
                "mcp__syntax-checker__validate",
                {"code": "Секретный код"},
                backoff_seconds=(0, 0),
            )

        self.assertEqual({"content": "ok"}, result)
        self.assertEqual([True, True], client.session_requests)
        events = [json.loads(record.getMessage()) for record in captured.records]
        self.assertEqual(
            ["retryable_direct_error", "success"],
            [event["outcome"] for event in events],
        )
        self.assertEqual(
            "direct_missing_assistant_uuid",
            events[0]["errorClass"],
        )
        self.assertNotIn("Секретный код", "\n".join(captured.output))

    async def test_other_direct_match_errors_keep_existing_fallback_boundary(self) -> None:
        failure = FixtureDirectToolError("Upstream не вернул tool_calls")
        client = FixtureClient(direct_outcomes=[failure, {"content": "unused"}])

        with self.assertRaises(FixtureDirectToolError) as raised:
            await call_tool_with_transient_network_retry(
                client,
                "mcp__syntax-checker__validate",
                {"code": "x"},
                backoff_seconds=(0, 0),
            )

        self.assertIs(failure, raised.exception)
        self.assertEqual([True], client.session_requests)

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
        other_tools = [
            f'''async def fetch_its(id: str = "root") -> str:
    try:
        return await _send_prompt(id)
{tool_error_handlers}
'''
        ]
        for index in range(7):
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
        compile(patched, "generated_mcp_server.py", "exec")

        self.assertIn("call_tool_with_transient_network_retry", patched)
        self.assertIn("send_with_transient_network_retry", patched)
        self.assertIn("send_with_reused_session_retry", patched)
        self.assertIn("from .observability import observe_stage, observe_tool", patched)
        self.assertIn('@observe_tool(\n    "check_1c_code"', patched)
        self.assertIn('@observe_tool(\n    "check_1c_logic"', patched)
        self.assertIn('@observe_tool(\n    "review_1c_code"', patched)
        self.assertIn('@observe_tool(\n    "fetch_its"', patched)
        self.assertIn("snapshot_argument=None", patched)
        self.assertIn('async with observe_stage(\n        "prompt"', patched)
        self.assertIn('async with observe_stage(\n            "direct_tool"', patched)
        self.assertIn("if create_new_session:", patched)
        self.assertIn("except ApiError:\n        raise", patched)
        self.assertEqual(12, patched.count("except ApiError:\n        raise"))
        self.assertEqual(
            14,
            patched.count("if is_transient_network_error(e):\n            raise"),
        )
        self.assertNotIn("MCP_TOOL_CALL_MODE", patched)
        self.assertNotIn("assistant_uuid", patched)

        logic_start = patched.index("async def check_1c_logic(")
        review_start = patched.index("async def review_1c_code(", logic_start)
        logic_tool = patched[logic_start:review_start]
        self.assertIn("async def check_1c_logic(code: str) -> str:", logic_tool)
        self.assertIn("return await _send_prompt(prompt)", logic_tool)
        self.assertNotIn("_call_direct_tool", logic_tool)
        self.assertNotIn("mcp__syntax-checker__validate", logic_tool)
        self.assertNotIn("syntax_result", logic_tool)
        self.assertEqual(1, patched.count("async def check_1c_logic("))

        check_start = patched.index("async def check_1c_code(")
        check_tool = patched[check_start:logic_start]
        self.assertIn("return await _send_prompt(code)", check_tool)


class ObservabilityTests(unittest.IsolatedAsyncioTestCase):
    def test_transport_correlation_hashes_only_real_available_identifiers(self) -> None:
        class FixtureContext:
            request_context = object()
            request_id = "request-secret"
            session_id = "session-secret"
            client_id = "client-secret"
            task_id = None
            transport = "streamable-http"

        correlation = _correlation_from_context(
            FixtureContext(),
            {
                "user-agent": "codex-secret-agent",
                "x-itl-mcp-proxy": "tools-list-proxy",
            },
        )

        self.assertEqual(
            hashlib.sha256(b"request-secret").hexdigest(),
            correlation["mcpRequestSha256"],
        )
        self.assertEqual(
            hashlib.sha256(b"session-secret").hexdigest(),
            correlation["mcpSessionSha256"],
        )
        self.assertEqual(
            hashlib.sha256(b"client-secret").hexdigest(),
            correlation["mcpClientSha256"],
        )
        self.assertNotIn("mcpTaskSha256", correlation)
        self.assertEqual("tools-list-proxy", correlation["transportPath"])
        self.assertNotIn("secret", json.dumps(correlation))

    def test_direct_error_classification_is_stable_and_content_safe(self) -> None:
        self.assertEqual(
            "direct_missing_assistant_uuid",
            classify_error(FixtureDirectToolError("Не вернул assistant_uuid")),
        )
        self.assertEqual(
            "direct_missing_tool_calls",
            classify_error(FixtureDirectToolError("Не вернул tool_calls")),
        )
        self.assertEqual(
            "direct_wrong_tool",
            classify_error(
                FixtureDirectToolError(
                    "wrong tool",
                    actual_tool="mcp__other__tool",
                )
            ),
        )

    def test_default_handler_writes_json_without_root_logging(self) -> None:
        handler = next(
            handler
            for handler in LOGGER.handlers
            if getattr(handler, "_itl_codechecker_telemetry", False)
        )
        stream = io.StringIO()
        original_stream = handler.stream
        handler.setStream(stream)
        try:
            log_event("probe", codeChars=17)
        finally:
            handler.setStream(original_stream)

        payload = json.loads(stream.getvalue())
        self.assertEqual("itl.codechecker.telemetry.v1", payload["schema"])
        self.assertEqual("probe", payload["event"])
        self.assertEqual(17, payload["codeChars"])
        self.assertFalse(LOGGER.propagate)

    async def test_tool_and_stage_logs_are_correlated_and_content_safe(self) -> None:
        source = "Процедура СекретнаяПроцедура()\nКонецПроцедуры"

        @observe_tool("check_1c_code", mode_resolver=lambda: "direct")
        async def checked(code: str) -> str:
            async with observe_stage("prompt", inputChars=len(code)):
                return "ok"

        correlation = {
            "mcpSessionSha256": hashlib.sha256(b"session-42").hexdigest(),
            "transportPath": "tools-list-proxy",
        }
        with patch("observability._transport_correlation", return_value=correlation):
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
        self.assertEqual(
            hashlib.sha256(source.encode("utf-8")).hexdigest(),
            events[0]["snapshotSha256"],
        )
        self.assertEqual(correlation["mcpSessionSha256"], events[0]["mcpSessionSha256"])
        self.assertEqual("tools-list-proxy", events[0]["transportPath"])
        self.assertEqual("success", events[-1]["outcome"])
        self.assertEqual(2, events[-1]["resultChars"])
        self.assertNotIn(source, "\n".join(captured.output))

    async def test_logic_only_tool_telemetry_keeps_snapshot_content_safe(self) -> None:
        source = "Процедура СекретнаяЛогика()\nКонецПроцедуры"

        @observe_tool("check_1c_logic", mode_resolver=lambda: "prompt")
        async def checked(code: str) -> str:
            async with observe_stage("prompt", inputChars=len(code)):
                return "ok"

        with self.assertLogs(
            "MCP_1copilot.codechecker_observability",
            level="INFO",
        ) as captured:
            await checked(source)

        events = [json.loads(record.getMessage()) for record in captured.records]
        self.assertEqual("check_1c_logic", events[0]["tool"])
        self.assertEqual("prompt", events[0]["mode"])
        self.assertEqual(
            hashlib.sha256(source.encode("utf-8")).hexdigest(),
            events[0]["snapshotSha256"],
        )
        self.assertNotIn(source, "\n".join(captured.output))

    async def test_fetch_its_parent_context_covers_direct_stage(self) -> None:
        @observe_tool("fetch_its", snapshot_argument=None)
        async def fetched(item_id: str) -> str:
            async with observe_stage(
                "direct_tool",
                upstreamTool="mcp__knowledge-hub__Fetch_ITS",
            ):
                return item_id

        with self.assertLogs(
            "MCP_1copilot.codechecker_observability",
            level="INFO",
        ) as captured:
            await fetched("its-secret-id")

        events = [json.loads(record.getMessage()) for record in captured.records]
        self.assertEqual(1, len({event["requestId"] for event in events}))
        self.assertNotIn("snapshotSha256", events[0])
        self.assertNotIn("its-secret-id", "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()
