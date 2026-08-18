"""Shared retry contract for transient 1C.ai transport disconnects."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Sequence
from typing import Any, TypeVar

try:
    from .observability import classify_error, log_event
except ImportError:  # pragma: no cover - supports direct local test execution
    from observability import classify_error, log_event


LOGGER = logging.getLogger(__name__)

DEFAULT_BACKOFF_SECONDS = (0.25, 0.75)

_TRANSIENT_NETWORK_MARKERS = (
    "incomplete chunked read",
    "peer closed connection",
    "server disconnected without sending a response",
    "server disconnected",
    "connection reset",
    "connection aborted",
    "connection closed",
    "remote protocol error",
    "remoteprotocolerror",
    "readerror",
    "writeerror",
    "connecterror",
    "network error while sending message",
    "ошибка сети при отправке сообщения",
)

_Result = TypeVar("_Result")


def _exception_text(error: BaseException) -> str:
    parts: list[str] = []
    current: BaseException | None = error
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        parts.append(type(current).__name__)
        parts.append(str(current))
        for attribute in ("message", "detail", "diagnostic"):
            value = getattr(current, attribute, None)
            if value is not None:
                parts.append(str(value))
        diagnostic_summary = getattr(current, "diagnostic_summary", None)
        if callable(diagnostic_summary):
            try:
                parts.append(str(diagnostic_summary()))
            except Exception:
                pass
        current = current.__cause__ or current.__context__
    return " ".join(parts).casefold()


def is_transient_network_error(error: BaseException) -> bool:
    """Return True only for known temporary transport-disconnect diagnostics."""

    text = _exception_text(error)
    return any(marker in text for marker in _TRANSIENT_NETWORK_MARKERS)


async def _run_with_transient_network_retry(
    operation: Callable[[], Awaitable[_Result]],
    *,
    operation_name: str,
    session_policy: str,
    backoff_seconds: Sequence[float] = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    retry_missing_assistant_uuid_once: bool = False,
) -> _Result:
    delays = tuple(backoff_seconds)
    for attempt in range(len(delays) + 1):
        started = time.perf_counter()
        try:
            result = await operation()
        except Exception as error:
            transient = is_transient_network_error(error)
            error_class = (
                "transient_network" if transient else classify_error(error)
            )
            recoverable_direct_match = (
                retry_missing_assistant_uuid_once
                and error_class == "direct_missing_assistant_uuid"
            )
            can_retry = (
                (transient and attempt < len(delays))
                or (recoverable_direct_match and attempt == 0 and bool(delays))
            )
            exhausted = (transient or recoverable_direct_match) and not can_retry
            log_event(
                "upstream_attempt_end",
                stage="upstream_attempt",
                operation=operation_name,
                sessionPolicy=session_policy,
                attempt=attempt + 1,
                maxAttempts=len(delays) + 1,
                outcome=(
                    "transient_error"
                    if transient
                    else "retryable_direct_error"
                    if can_retry
                    else "error"
                ),
                exhausted=exhausted,
                elapsedMs=max(0, round((time.perf_counter() - started) * 1000)),
                errorType=type(error).__name__,
                errorClass=error_class,
            )
            if not can_retry:
                raise
            delay = delays[attempt]
            LOGGER.warning(
                "Retryable 1C.ai failure (%s); retrying %s with %s "
                "in %.2fs (attempt %d/%d): %s",
                error_class,
                operation_name,
                session_policy,
                delay,
                attempt + 2,
                len(delays) + 1,
                error,
            )
            await sleep(delay)
        else:
            log_event(
                "upstream_attempt_end",
                stage="upstream_attempt",
                operation=operation_name,
                sessionPolicy=session_policy,
                attempt=attempt + 1,
                maxAttempts=len(delays) + 1,
                outcome="success",
                exhausted=False,
                elapsedMs=max(0, round((time.perf_counter() - started) * 1000)),
            )
            return result
    raise AssertionError("unreachable")


async def send_with_transient_network_retry(
    client: Any,
    question: str,
    *,
    operation_name: str = "prompt request",
    backoff_seconds: Sequence[float] = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> str:
    """Send a prompt, opening a fresh 1C.ai session for every attempt."""

    async def send() -> str:
        conversation_id = await client.get_or_create_session(create_new=True)
        return await client.send_message(conversation_id, question)

    return await _run_with_transient_network_retry(
        send,
        operation_name=operation_name,
        session_policy="a fresh session",
        backoff_seconds=backoff_seconds,
        sleep=sleep,
    )


async def send_with_reused_session_retry(
    client: Any,
    question: str,
    *,
    operation_name: str = "ask_1c_ai continuation",
    backoff_seconds: Sequence[float] = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> str:
    """Retry a dialogue request without replacing its reused conversation session."""

    async def send() -> str:
        conversation_id = await client.get_or_create_session(create_new=False)
        return await client.send_message(conversation_id, question)

    return await _run_with_transient_network_retry(
        send,
        operation_name=operation_name,
        session_policy="the reused session",
        backoff_seconds=backoff_seconds,
        sleep=sleep,
    )


async def call_tool_with_transient_network_retry(
    client: Any,
    tool_name: str,
    arguments: dict,
    *,
    backoff_seconds: Sequence[float] = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> Any:
    """Call a read-only direct tool, opening a fresh session for every attempt."""

    async def call() -> Any:
        conversation_id = await client.get_or_create_session(create_new=True)
        return await client.call_exact_tool(conversation_id, tool_name, arguments)

    return await _run_with_transient_network_retry(
        call,
        operation_name=f"direct tool {tool_name}",
        session_policy="a fresh session",
        backoff_seconds=backoff_seconds,
        sleep=sleep,
        retry_missing_assistant_uuid_once=True,
    )
