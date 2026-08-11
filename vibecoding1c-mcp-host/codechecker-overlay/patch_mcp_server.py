"""Apply the ITL retry overlay to the closed-source codechecker image entrypoint."""

from __future__ import annotations

import argparse
from pathlib import Path


IMPORT_ANCHOR = "from .models import ApiError, DirectToolError\n"
IMPORT_LINE = "from .retry_policy import send_with_transient_network_retry\n"

CHECK_PROMPT_HELPER = '''\n\nasync def _send_check_prompt(question: str) -> str:
    """Send a check_1c_code prompt with bounded transient-network retries."""
    client = _get_client()
    answer = await send_with_transient_network_retry(
        client,
        _truncate_input(question),
    )
    cleaned = _sanitize_text(answer)
    if not cleaned:
        return "Ошибка: API вернул пустой ответ (возможно, только reasoning без итогового текста)"
    return cleaned
'''


def _replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected exactly one {description} anchor, found {count}; "
            "the upstream image layout changed."
        )
    return text.replace(old, new, 1)


def patch_source(source: str) -> str:
    if IMPORT_LINE in source:
        raise RuntimeError("The codechecker retry overlay is already applied.")

    patched = _replace_once(
        source,
        IMPORT_ANCHOR,
        IMPORT_ANCHOR + IMPORT_LINE,
        "retry import",
    )
    patched = _replace_once(
        patched,
        "\n\nasync def _call_direct_tool(",
        CHECK_PROMPT_HELPER + "\n\nasync def _call_direct_tool(",
        "check prompt helper",
    )

    tool_start = patched.index("async def check_1c_code(")
    tool_end = patched.index("\n\n@mcp.tool()", tool_start)
    before = patched[:tool_start]
    tool = patched[tool_start:tool_end]
    after = patched[tool_end:]

    tool = _replace_once(
        tool,
        "logic_perf_part = await _send_prompt(logic_perf_prompt)",
        "logic_perf_part = await _send_check_prompt(logic_perf_prompt)",
        "direct-mode logic prompt",
    )
    tool = _replace_once(
        tool,
        "return await _send_prompt(prompt)",
        "return await _send_check_prompt(prompt)",
        "standard-mode check prompt",
    )
    tool = _replace_once(
        tool,
        'except ApiError as e:\n        return f"Ошибка при обращении к 1C.ai: {e.message}"',
        "except ApiError:\n        raise",
        "check_1c_code API error handler",
    )

    return before + tool + after


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
