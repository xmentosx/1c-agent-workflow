from __future__ import annotations

import asyncio
import unittest

from patch_mcp_server import patch_source
from retry_policy import is_transient_network_error, send_with_transient_network_retry


class FixtureApiError(Exception):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class FixtureClient:
    def __init__(self, outcomes: list[object]) -> None:
        self.outcomes = list(outcomes)
        self.created_sessions: list[str] = []

    async def get_or_create_session(self, *, create_new: bool) -> str:
        if not create_new:
            raise AssertionError("Every retry must request a new session")
        session_id = f"session-{len(self.created_sessions) + 1}"
        self.created_sessions.append(session_id)
        return session_id

    async def send_message(self, conversation_id: str, question: str) -> str:
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return str(outcome)


class RetryPolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_retries_incomplete_chunked_read_with_a_new_session(self) -> None:
        client = FixtureClient(
            [
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
        self.assertEqual(["session-1", "session-2"], client.created_sessions)
        self.assertEqual([0.25], delays)

    async def test_exhaustion_is_bounded_and_reraises_the_original_error(self) -> None:
        failures = [FixtureApiError("peer closed connection") for _ in range(3)]
        client = FixtureClient(failures)
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
        self.assertEqual(3, len(client.created_sessions))
        self.assertEqual([0.25, 0.75], delays)

    async def test_does_not_retry_non_network_api_errors(self) -> None:
        failure = FixtureApiError("HTTP 401: token is invalid")
        client = FixtureClient([failure, "must-not-be-used"])

        with self.assertRaises(FixtureApiError) as raised:
            await send_with_transient_network_retry(client, "question")

        self.assertIs(failure, raised.exception)
        self.assertEqual(["session-1"], client.created_sessions)

    def test_classifies_nested_transport_disconnect(self) -> None:
        outer = FixtureApiError("Ошибка 1C.ai")
        outer.__cause__ = RuntimeError("RemoteProtocolError: server disconnected")
        self.assertTrue(is_transient_network_error(outer))
        self.assertFalse(is_transient_network_error(FixtureApiError("HTTP 422")))

    def test_patcher_changes_only_check_prompt_calls_and_reraises_api_error(self) -> None:
        fixture = '''from .models import ApiError, DirectToolError

async def _send_prompt(question: str) -> str:
    return question

async def _call_direct_tool(tool_name: str) -> str:
    return tool_name

async def check_1c_code(code: str) -> str:
    try:
        logic_perf_part = await _send_prompt(logic_perf_prompt)
        return await _send_prompt(prompt)
    except ApiError as e:
        return f"Ошибка при обращении к 1C.ai: {e.message}"
    except Exception as e:
        return str(e)

@mcp.tool()
async def review_1c_code(code: str) -> str:
    return await _send_prompt(code)
'''

        patched = patch_source(fixture)

        self.assertIn("from .retry_policy import send_with_transient_network_retry", patched)
        self.assertIn("logic_perf_part = await _send_check_prompt(logic_perf_prompt)", patched)
        self.assertIn("return await _send_check_prompt(prompt)", patched)
        self.assertIn("except ApiError:\n        raise", patched)
        self.assertIn("async def review_1c_code", patched)
        self.assertIn("return await _send_prompt(code)", patched)


if __name__ == "__main__":
    unittest.main()
