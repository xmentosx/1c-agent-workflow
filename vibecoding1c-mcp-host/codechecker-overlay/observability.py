"""Structured, content-safe timing telemetry for Code Checker requests."""

from __future__ import annotations

import asyncio
import contextvars
import functools
import json
import logging
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any


LOGGER = logging.getLogger("MCP_1copilot.codechecker_observability")
LOGGER.setLevel(logging.INFO)
SCHEMA = "itl.codechecker.telemetry.v1"

_REQUEST_CONTEXT: contextvars.ContextVar[dict[str, Any] | None] = (
    contextvars.ContextVar("codechecker_request_context", default=None)
)


def _elapsed_ms(started: float) -> int:
    return max(0, round((time.perf_counter() - started) * 1000))


def log_event(event: str, **fields: Any) -> None:
    """Write one JSON log record without request or response content."""

    payload: dict[str, Any] = {"schema": SCHEMA, "event": event}
    context = _REQUEST_CONTEXT.get()
    if context:
        payload.update(context)
    payload.update({key: value for key, value in fields.items() if value is not None})
    LOGGER.info(
        json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def observe_tool(
    tool_name: str,
    *,
    mode_resolver: Callable[[], str] | None = None,
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Log start/end records and establish correlation context for an MCP tool."""

    def decorate(function: Callable[..., Any]) -> Callable[..., Any]:
        @functools.wraps(function)
        async def wrapped(*args: Any, **kwargs: Any) -> Any:
            code = kwargs.get("code")
            if code is None and args:
                code = args[0]
            mode = mode_resolver() if mode_resolver is not None else None
            context = {
                "requestId": uuid.uuid4().hex,
                "tool": tool_name,
            }
            token = _REQUEST_CONTEXT.set(context)
            started = time.perf_counter()
            log_event(
                "tool_start",
                mode=mode,
                codeChars=len(code) if isinstance(code, str) else None,
            )
            try:
                result = await function(*args, **kwargs)
            except asyncio.CancelledError:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome="cancelled",
                    elapsedMs=_elapsed_ms(started),
                )
                raise
            except Exception as error:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome="error",
                    elapsedMs=_elapsed_ms(started),
                    errorType=type(error).__name__,
                )
                raise
            else:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome="success",
                    elapsedMs=_elapsed_ms(started),
                    resultChars=len(result) if isinstance(result, str) else None,
                )
                return result
            finally:
                _REQUEST_CONTEXT.reset(token)

        return wrapped

    return decorate


@asynccontextmanager
async def observe_stage(stage: str, **fields: Any) -> AsyncIterator[None]:
    """Log a correlated stage even when it fails or is cancelled."""

    started = time.perf_counter()
    log_event("stage_start", stage=stage, **fields)
    try:
        yield
    except asyncio.CancelledError:
        log_event(
            "stage_end",
            stage=stage,
            outcome="cancelled",
            elapsedMs=_elapsed_ms(started),
            **fields,
        )
        raise
    except Exception as error:
        log_event(
            "stage_end",
            stage=stage,
            outcome="error",
            elapsedMs=_elapsed_ms(started),
            errorType=type(error).__name__,
            **fields,
        )
        raise
    else:
        log_event(
            "stage_end",
            stage=stage,
            outcome="success",
            elapsedMs=_elapsed_ms(started),
            **fields,
        )
