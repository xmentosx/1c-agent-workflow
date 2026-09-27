"""Restore the stable check_1c_logic MCP tool in the pinned beta image."""

import argparse
import ast
from pathlib import Path


LOGIC_TOOL = '''@mcp.tool()
async def check_1c_logic(code: str) -> str:
    """Check 1C code for logic, bugs, and performance without checking syntax or style."""
    if not code.strip():
        return "Ошибка: код не может быть пустым"

    prompt = (
        "Проверь этот код 1С ТОЛЬКО на логические ошибки и проблемы производительности.\\n"
        "Не выполняй синтаксическую проверку и не проверяй стиль/стандарты.\\n"
        "Найди: ошибки логики, потенциальные баги, запросы в цикле, "
        "неоптимальные конструкции.\\n\\n"
        f"Код:\\n```bsl\\n{code}\\n```"
    )
    result = await ask_1c_ai(prompt, create_new_session=True)
    return result.answer


'''

MAIN_ANCHOR = '\n\nif __name__ == "__main__":\n    main()\n'


def patch_source(source: str) -> str:
    tree = ast.parse(source)
    functions = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    if "check_1c_logic" in functions:
        raise RuntimeError("Beta image already provides check_1c_logic; review its contract before patching.")
    if not {"ask_1c_ai", "main"}.issubset(functions):
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
