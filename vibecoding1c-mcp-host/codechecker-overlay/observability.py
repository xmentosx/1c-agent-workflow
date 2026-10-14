"""Structured, content-safe timing telemetry for Code Checker requests."""

from __future__ import annotations

import asyncio
import contextvars
import functools
import hashlib
import inspect
import json
import logging
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any


LOGGER = logging.getLogger("MCP_1copilot.codechecker_observability")
LOGGER.setLevel(logging.INFO)
if not any(
    getattr(handler, "_itl_codechecker_telemetry", False)
    for handler in LOGGER.handlers
):
    _handler = logging.StreamHandler()
    _handler.setLevel(logging.INFO)
    _handler.setFormatter(logging.Formatter("%(message)s"))
    _handler._itl_codechecker_telemetry = True
    LOGGER.addHandler(_handler)
LOGGER.propagate = False
SCHEMA = "itl.codechecker.telemetry.v1"

_REQUEST_CONTEXT: contextvars.ContextVar[dict[str, Any] | None] = (
    contextvars.ContextVar("codechecker_request_context", default=None)
)
_MODERN_STATE: contextvars.ContextVar[dict[str, Any] | None] = contextvars.ContextVar(
    "codechecker_modern_state", default=None,
)


def _elapsed_ms(started: float) -> int:
    return max(0, round((time.perf_counter() - started) * 1000))


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _input_hash(value: Any) -> str | None:
    """Hash arguments without stringifying unknown objects or logging content."""
    try:
        text = value if isinstance(value, str) else json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        )
        return _sha256_text(text)
    except (TypeError, ValueError, UnicodeError):
        return None


def _exception_text(error: BaseException) -> str:
    parts = [type(error).__name__, str(error)]
    diagnostic_summary = getattr(error, "diagnostic_summary", None)
    if callable(diagnostic_summary):
        try:
            parts.append(str(diagnostic_summary()))
        except Exception:
            pass
    return " ".join(parts).casefold()


def classify_error(error: BaseException) -> str:
    """Return a stable content-safe class without logging exception text."""

    text = _exception_text(error)
    if "assistant_uuid" in text:
        return "direct_missing_assistant_uuid"
    if "tool_calls" in text and (
        "не вернул" in text or "missing" in text or "absent" in text
    ):
        return "direct_missing_tool_calls"
    expected_tool = getattr(error, "expected_tool", "")
    actual_tool = getattr(error, "actual_tool", "")
    if expected_tool and actual_tool and expected_tool != actual_tool:
        return "direct_wrong_tool"
    phase = str(getattr(error, "phase", "") or "").strip().casefold()
    if phase in {"request", "match", "ack", "parse"}:
        return f"direct_{phase}_error"
    error_type = type(error).__name__
    if error_type == "ApiError":
        return "upstream_api_error"
    if error_type == "DirectToolError":
        return "direct_tool_error"
    return "unexpected_error"


def _correlation_from_context(
    context: Any,
    headers: dict[str, str],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    request_context = getattr(context, "request_context", None)
    if request_context is not None:
        try:
            result["mcpRequestSha256"] = _sha256_text(str(context.request_id))
        except Exception:
            pass
        try:
            result["mcpSessionSha256"] = _sha256_text(str(context.session_id))
        except Exception:
            pass

    try:
        client_id = getattr(context, "client_id", None)
    except Exception:
        client_id = None
    if client_id:
        result["mcpClientSha256"] = _sha256_text(str(client_id))
    try:
        task_id = getattr(context, "task_id", None)
    except Exception:
        task_id = None
    if task_id:
        result["mcpTaskSha256"] = _sha256_text(str(task_id))
    try:
        transport = getattr(context, "transport", None)
    except Exception:
        transport = None
    if transport:
        result["transport"] = str(transport)

    user_agent = headers.get("user-agent")
    if user_agent:
        result["userAgentSha256"] = _sha256_text(user_agent)
    if headers.get("x-itl-mcp-proxy") == "tools-list-proxy":
        result["transportPath"] = "tools-list-proxy"
    else:
        result["transportPath"] = "direct-or-unmarked"
    return result


def _transport_correlation() -> dict[str, Any]:
    """Read only correlation that FastMCP exposes for the active request."""

    try:
        from fastmcp.server.dependencies import get_context, get_http_headers

        return _correlation_from_context(get_context(), get_http_headers())
    except Exception:
        return {}


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
    snapshot_argument: str | None = "code",
    modern: bool = False,
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Log start/end records and establish correlation context for an MCP tool."""

    def decorate(function: Callable[..., Any]) -> Callable[..., Any]:
        signature = inspect.signature(function) if modern else None
        @functools.wraps(function)
        async def wrapped(*args: Any, **kwargs: Any) -> Any:
            snapshot = kwargs.get(snapshot_argument) if snapshot_argument else None
            if snapshot is None and snapshot_argument and args:
                snapshot = args[0]
            arguments = None
            files = None
            if signature is not None:
                try:
                    bound = signature.bind_partial(*args, **kwargs)
                    bound.apply_defaults()
                    arguments = dict(bound.arguments)
                    snapshot = arguments.get(snapshot_argument) if snapshot_argument else None
                    files = arguments.get("files")
                    if files and snapshot_argument == "code":
                        # A file reference is not proof of the loaded file bytes.
                        snapshot = None
                except TypeError:
                    pass
            mode = mode_resolver() if mode_resolver is not None else None
            context = {
                "requestId": uuid.uuid4().hex,
                "tool": tool_name,
                **_transport_correlation(),
            }
            if isinstance(snapshot, str):
                digest = _input_hash(snapshot) if modern else _sha256_text(snapshot)
                if digest is not None:
                    context["snapshotSha256"] = digest
            if modern:
                digest = _input_hash(arguments) if arguments is not None else None
                if digest is not None:
                    context["inputSha256"] = digest
                context["inputKind"] = "files" if files else "arguments"
            token = _REQUEST_CONTEXT.set(context)
            state = {"attempts": 0, "outcome": "returned"} if modern else None
            state_token = _MODERN_STATE.set(state)
            started = time.perf_counter()
            log_event(
                "tool_start",
                mode=mode,
                codeChars=len(snapshot) if isinstance(snapshot, str) else None,
            )
            try:
                result = await function(*args, **kwargs)
            except asyncio.CancelledError:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome="cancelled",
                    elapsedMs=_elapsed_ms(started),
                    attempts=state["attempts"] if state is not None else None,
                )
                raise
            except Exception as error:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome="error",
                    elapsedMs=_elapsed_ms(started),
                    errorType=type(error).__name__,
                    errorClass=classify_error(error),
                    attempts=state["attempts"] if state is not None else None,
                )
                raise
            else:
                log_event(
                    "tool_end",
                    mode=mode,
                    outcome=state["outcome"] if state is not None else "success",
                    elapsedMs=_elapsed_ms(started),
                    resultChars=len(result) if isinstance(result, str) else None,
                    attempts=state["attempts"] if state is not None else None,
                )
                return result
            finally:
                _MODERN_STATE.reset(state_token)
                _REQUEST_CONTEXT.reset(token)

        return wrapped

    return decorate


def observe_condition(outcome: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Record a typed condition even when the adapter returns it as a value."""
    if outcome not in {"error", "refused"}:
        raise ValueError("Unknown terminal condition")

    def decorate(function: Callable[..., Any]) -> Callable[..., Any]:
        @functools.wraps(function)
        def wrapped(*args: Any, **kwargs: Any) -> Any:
            result = function(*args, **kwargs)
            state = _MODERN_STATE.get()
            if state is not None:
                state["outcome"] = outcome
            return result
        return wrapped
    return decorate


async def observe_upstream_call(route: str, function: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Observe one existing collector invocation; never add retries or change budgets."""
    state = _MODERN_STATE.get()
    if state is None:
        return await function(*args, **kwargs)
    state["attempts"] += 1
    attempt = state["attempts"]
    payload_index = 1 if route == "prompt" else 2
    digest = _input_hash(args[payload_index]) if len(args) > payload_index else None
    fields = {"stage": route, "attempt": attempt, "upstreamInputSha256": digest}
    started = time.perf_counter()
    log_event("upstream_attempt_start", **fields)
    try:
        result = await function(*args, **kwargs)
    except asyncio.CancelledError:
        log_event("upstream_attempt_end", outcome="cancelled", elapsedMs=_elapsed_ms(started), **fields)
        raise
    except Exception as error:
        log_event("upstream_attempt_end", outcome="error", elapsedMs=_elapsed_ms(started),
                  errorType=type(error).__name__, errorClass=classify_error(error), **fields)
        raise
    else:
        log_event("upstream_attempt_end", outcome="returned", elapsedMs=_elapsed_ms(started), **fields)
        return result


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
            errorClass=classify_error(error),
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
