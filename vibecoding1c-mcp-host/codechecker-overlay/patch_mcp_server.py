"""Apply the ITL transport-retry overlay to the codechecker image entrypoint."""

from __future__ import annotations

import argparse
from pathlib import Path


IMPORT_ANCHOR = "from .models import ApiError, DirectToolError\n"
IMPORT_LINES = '''from .retry_policy import (
    call_tool_with_transient_network_retry,
    is_transient_network_error,
    send_with_reused_session_retry,
    send_with_transient_network_retry,
)
from .observability import observe_stage, observe_tool
'''

SEND_PROMPT_FUNCTION = '''async def _send_prompt(question: str) -> str:
    """Отправить промпт в 1C.ai с общим transport-retry и вернуть очищенный ответ."""
    client = _get_client()
    truncated_question = _truncate_input(question)
    async with observe_stage(
        "prompt",
        operation="prompt request",
        inputChars=len(truncated_question),
    ):
        answer = await send_with_transient_network_retry(
            client,
            truncated_question,
        )
    cleaned = _sanitize_text(answer)
    if not cleaned:
        return "Ошибка: API вернул пустой ответ (возможно, только reasoning без итогового текста)"
    return cleaned
'''

CALL_DIRECT_TOOL_FUNCTION = '''async def _call_direct_tool(tool_name: str, arguments: dict, fallback_prompt: str = "") -> str:
    """Вызвать read-only upstream-инструмент напрямую с transport-retry."""
    import logging
    _logger = logging.getLogger(__name__)

    client = _get_client()

    try:
        async with observe_stage(
            "direct_tool",
            operation="direct tool",
            upstreamTool=tool_name,
        ):
            result = await call_tool_with_transient_network_retry(
                client,
                tool_name,
                arguments,
            )
        text = _sanitize_text(client._extract_best_text(result))
        if text:
            return text
        _logger.warning(
            "Direct tool %s вернул пустой результат, переключаемся на fallback prompt",
            tool_name,
        )
    except DirectToolError as e:
        if is_transient_network_error(e):
            raise
        _logger.error(
            "Direct tool call failed:\\n%s", e.diagnostic_summary(),
        )
        if not fallback_prompt:
            return (
                f"Ошибка прямого вызова инструмента {tool_name}.\\n\\n"
                f"{e.diagnostic_summary()}"
            )
    except ApiError as e:
        if is_transient_network_error(e):
            raise
        _logger.error("API error in direct tool %s: %s", tool_name, e.message)
        if not fallback_prompt:
            return f"Ошибка при обращении к 1C.ai: {e.message}"

    if fallback_prompt:
        _logger.info("Fallback to prompt mode for tool %s", tool_name)
        return await _send_prompt(fallback_prompt)

    return f"Инструмент {tool_name} не вернул результата."
'''

ASK_ORIGINAL = '''        client = _get_client()
        conversation_id = await client.get_or_create_session(create_new=create_new_session)
        answer = await client.send_message(conversation_id, _truncate_input(question))
        return _sanitize_text(answer)'''

ASK_RETRY = '''        client = _get_client()
        truncated_question = _truncate_input(question)
        if create_new_session:
            answer = await send_with_transient_network_retry(
                client,
                truncated_question,
                operation_name="ask_1c_ai new conversation",
            )
        else:
            answer = await send_with_reused_session_retry(
                client,
                truncated_question,
            )
        return _sanitize_text(answer)'''

API_ERROR_HANDLER = '''    except ApiError as e:
        return f"Ошибка при обращении к 1C.ai: {e.message}"'''

API_ERROR_RERAISE = '''    except ApiError:
        raise'''

UNEXPECTED_ERROR_HANDLER = '''    except Exception as e:
        return f"Произошла неожиданная ошибка: {str(e)}"'''

UNEXPECTED_ERROR_RERAISE = '''    except Exception as e:
        if is_transient_network_error(e):
            raise
        return f"Произошла неожиданная ошибка: {str(e)}"'''

TOOL_OBSERVABILITY = {
    "check_1c_code": '''@observe_tool(
    "check_1c_code",
    mode_resolver=lambda: "direct" if _is_direct_mode() else "standard",
)\n''',
    "review_1c_code": '''@observe_tool(
    "review_1c_code",
    mode_resolver=lambda: "prompt",
)\n''',
}


def _replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected exactly one {description} anchor, found {count}; "
            "the upstream image layout changed."
        )
    return text.replace(old, new, 1)


def _replace_function(
    text: str,
    function_name: str,
    end_anchor: str,
    replacement: str,
) -> str:
    start = text.index(f"async def {function_name}(")
    end = text.index(end_anchor, start)
    return text[:start] + replacement + text[end:]


def patch_source(source: str) -> str:
    if IMPORT_LINES in source:
        raise RuntimeError("The codechecker transport-retry overlay is already applied.")

    patched = _replace_once(
        source,
        IMPORT_ANCHOR,
        IMPORT_ANCHOR + IMPORT_LINES,
        "transport retry import",
    )
    patched = _replace_function(
        patched,
        "_send_prompt",
        "\n\nasync def _call_direct_tool(",
        SEND_PROMPT_FUNCTION,
    )
    patched = _replace_function(
        patched,
        "_call_direct_tool",
        "\n\n# =============================================================================\n# MCP Tools",
        CALL_DIRECT_TOOL_FUNCTION,
    )

    tools_start = patched.index("# MCP Tools")
    before_tools = patched[:tools_start]
    tools = patched[tools_start:]
    for tool_name, decorator in TOOL_OBSERVABILITY.items():
        tools = _replace_once(
            tools,
            f"async def {tool_name}(",
            decorator + f"async def {tool_name}(",
            f"{tool_name} observability decorator",
        )
    tools = _replace_once(
        tools,
        ASK_ORIGINAL,
        ASK_RETRY,
        "ask_1c_ai session policy",
    )

    api_error_count = tools.count(API_ERROR_HANDLER)
    if api_error_count != 11:
        raise RuntimeError(
            f"Expected 11 MCP ApiError handlers, found {api_error_count}; "
            "the upstream tool layout changed."
        )
    tools = tools.replace(API_ERROR_HANDLER, API_ERROR_RERAISE)

    unexpected_error_count = tools.count(UNEXPECTED_ERROR_HANDLER)
    if unexpected_error_count != 11:
        raise RuntimeError(
            f"Expected 11 MCP unexpected-error handlers, found {unexpected_error_count}; "
            "the upstream tool layout changed."
        )
    tools = tools.replace(UNEXPECTED_ERROR_HANDLER, UNEXPECTED_ERROR_RERAISE)

    return before_tools + tools


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "path",
        nargs="?",
        default="/app/MCP_1copilot/mcp_server.py",
        type=Path,
    )
    args = parser.parse_args()
    source = args.path.read_text(encoding="utf-8")
    args.path.write_text(patch_source(source), encoding="utf-8")


if __name__ == "__main__":
    main()
