"""Restore logic checks and shared content-safe telemetry in the modern image."""

import argparse
import ast
from pathlib import Path


LOGIC_TOOL = '''class _ItlLogicResult(AnswerResult):
    # Keep the required FastMCP string-wrapper field for existing consumers.
    result: str


def _itl_logic_result(value: AnswerResult) -> _ItlLogicResult:
    payload = value.model_dump()
    payload["result"] = value.answer
    return _ItlLogicResult(**payload)


@mcp.tool()
async def check_1c_logic(code: str) -> _ItlLogicResult:
    """Check 1C code for logic, bugs, and performance without checking syntax or style."""
    if not code.strip():
        return _itl_logic_result(_error_result("Ошибка: код не может быть пустым"))

    bounder = _bounder()
    call = plugin_runtime.begin("check_1c_logic", {"code": code})
    bounded_code = bounder.bound("code", call.arguments["code"])

    prompt = (
        "Проверь этот код 1С ТОЛЬКО на логические ошибки и проблемы производительности.\\n"
        "Не выполняй синтаксическую проверку и не проверяй стиль/стандарты.\\n"
        "Найди: ошибки логики, потенциальные баги, запросы в цикле, "
        "неоптимальные конструкции.\\n\\n"
        f"Код:\\n```bsl\\n{bounded_code}\\n```"
    )
    try:
        outcome = await _send_prompt(
            _scope_owner("check_1c_logic"), prompt, context=call,
        )
        return _itl_logic_result(AnswerResult(
            answer=_answer(call, outcome.text, mode="prompt", bounder=bounder),
            truncation=_evidence(bounder),
            sources=[],
        ))
    except ConversationCapacityError as e:
        return _capacity_refusal(e)
    except ApiError as e:
        return _itl_logic_result(_error_result(_condition_text(e), bounder, call))
    except Exception as e:
        return _itl_logic_result(_error_result(
            f"Произошла неожиданная ошибка: {str(e)}", bounder, call,
        ))


'''

MAIN_ANCHOR = '\n\nif __name__ == "__main__":\n    main()\n'
TELEMETRY_IMPORT = (
    "from MCP_1copilot.observability import (observe_tool as _itl_observe_tool, "
    "observe_condition as _itl_observe_condition, "
    "observe_upstream_call as _itl_observe_upstream_call)\n"
)


def _instrument_source(source: str) -> str:
    """Observe the existing adapter boundaries without replacing its retry flow."""
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line))

    def offset(line: int, column: int) -> int:
        return offsets[line - 1] + len(lines[line - 1].encode("utf-8")[:column].decode("utf-8"))

    edits = []
    attempts = {"_send_prompt": ("collect_prompt", "prompt"),
                "_call_capability": ("call_capability", "direct")}
    found = set()
    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        is_tool = any(
            isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute)
            and isinstance(d.func.value, ast.Name) and d.func.value.id == "mcp"
            and d.func.attr == "tool" for d in node.decorator_list
        )
        if is_tool:
            parameters = {arg.arg for arg in node.args.args + node.args.kwonlyargs}
            snapshot = "code" if "code" in parameters else "question" if "question" in parameters else None
            decorator = (f'@_itl_observe_tool({node.name!r}, snapshot_argument={snapshot!r}, '
                         'modern=True)\n')
            edits.append((offset(node.lineno, 0), offset(node.lineno, 0), decorator))
        if node.name in {"_error_result", "_capacity_refusal"}:
            outcome = "error" if node.name == "_error_result" else "refused"
            edits.append((offset(node.lineno, 0), offset(node.lineno, 0),
                          f'@_itl_observe_condition({outcome!r})\n'))
        if node.name in attempts:
            method, route = attempts[node.name]
            matches = [n for n in ast.walk(node) if isinstance(n, ast.Await)
                       and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
                       and isinstance(n.value.func.value, ast.Name) and n.value.func.value.id == "client"
                       and n.value.func.attr == method]
            if len(matches) != 1:
                raise RuntimeError(f"Pinned beta {route} attempt boundary changed.")
            call = matches[0].value
            wrapped = ast.Call(func=ast.Name(id="_itl_observe_upstream_call", ctx=ast.Load()),
                               args=[ast.Constant(route), call.func, *call.args], keywords=call.keywords)
            edits.append((offset(call.lineno, call.col_offset), offset(call.end_lineno, call.end_col_offset),
                          ast.unparse(wrapped)))
            found.add(node.name)
    if found != set(attempts):
        raise RuntimeError("Pinned beta attempt functions changed.")
    import_after = 0
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            import_after = offsets[node.end_lineno]
        elif (import_after == 0 and isinstance(node, ast.Expr)
              and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
            import_after = offsets[node.end_lineno]
    edits.append((import_after, import_after, TELEMETRY_IMPORT))
    for start, end, replacement in sorted(edits, key=lambda edit: edit[0], reverse=True):
        source = source[:start] + replacement + source[end:]
    ast.parse(source)
    return source


def patch_source(source: str) -> str:
    tree = ast.parse(source)
    functions = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    if "check_1c_logic" in functions:
        raise RuntimeError("Beta image already provides check_1c_logic; review its contract before patching.")
    required_functions = {
        "_bounder", "_scope_owner", "_send_prompt", "_answer", "_evidence",
        "_error_result", "_condition_text", "_capacity_refusal", "_call_capability", "main",
    }
    if not required_functions.issubset(functions):
        raise RuntimeError("Pinned beta CodeChecker layout changed.")
    if source.count(MAIN_ANCHOR) != 1:
        raise RuntimeError("Pinned beta CodeChecker entrypoint changed.")
    result = source.replace(MAIN_ANCHOR, "\n\n" + LOGIC_TOOL + MAIN_ANCHOR)
    return _instrument_source(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=Path("/app/MCP_1copilot/mcp_server.py"))
    args = parser.parse_args()
    source = args.path.read_text(encoding="utf-8")
    args.path.write_text(patch_source(source), encoding="utf-8")


if __name__ == "__main__":
    main()
