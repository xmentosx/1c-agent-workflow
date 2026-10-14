"""Restore the stable check_1c_logic MCP tool in the pinned beta image."""

import argparse
import ast
from pathlib import Path


LOGIC_TOOL = '''@mcp.tool()
async def check_1c_logic(code: str) -> AnswerResult:
    """Check 1C code for logic, bugs, and performance without checking syntax or style."""
    if not code.strip():
        return _error_result("Ошибка: код не может быть пустым")

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
        return AnswerResult(
            answer=_answer(call, outcome.text, mode="prompt", bounder=bounder),
            truncation=_evidence(bounder),
            sources=[],
        )
    except ConversationCapacityError as e:
        return _capacity_refusal(e)
    except ApiError as e:
        return _error_result(_condition_text(e), bounder, call)
    except Exception as e:
        return _error_result(
            f"Произошла неожиданная ошибка: {str(e)}", bounder, call,
        )


'''

MAIN_ANCHOR = '\n\nif __name__ == "__main__":\n    main()\n'


def patch_source(source: str) -> str:
    tree = ast.parse(source)
    functions = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    if "check_1c_logic" in functions:
        raise RuntimeError("Beta image already provides check_1c_logic; review its contract before patching.")
    required_functions = {
        "_bounder", "_scope_owner", "_send_prompt", "_answer", "_evidence",
        "_error_result", "_condition_text", "_capacity_refusal", "main",
    }
    if not required_functions.issubset(functions):
        raise RuntimeError("Pinned beta CodeChecker layout changed.")
    if source.count(MAIN_ANCHOR) != 1:
        raise RuntimeError("Pinned beta CodeChecker entrypoint changed.")
    result = source.replace(MAIN_ANCHOR, "\n\n" + LOGIC_TOOL + MAIN_ANCHOR)
    ast.parse(result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=Path("/app/MCP_1copilot/mcp_server.py"))
    args = parser.parse_args()
    source = args.path.read_text(encoding="utf-8")
    args.path.write_text(patch_source(source), encoding="utf-8")


if __name__ == "__main__":
    main()
