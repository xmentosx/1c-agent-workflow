"""Restore the SDK's handler cancellation in the pinned FastMCP session owner."""
import ast
from pathlib import Path


def patch_source(source: str) -> str:
    tree = ast.parse(source)
    classes = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'LowLevelServer']
    methods = [n for c in classes for n in c.body if isinstance(n, ast.AsyncFunctionDef) and n.name == 'run']
    if len(classes) != 1 or len(methods) != 1:
        raise RuntimeError('Pinned FastMCP session owner changed.')
    groups = [n for n in ast.walk(methods[0]) if isinstance(n, ast.AsyncWith)
              and len(n.items) == 1 and ast.unparse(n.items[0].context_expr) == 'anyio.create_task_group()'
              and isinstance(n.items[0].optional_vars, ast.Name) and n.items[0].optional_vars.id == 'tg']
    if len(groups) != 1:
        raise RuntimeError('Pinned FastMCP handler task group changed.')
    body = groups[0].body
    if (len(body) != 2 or ast.unparse(body[0]) != 'session._subscription_task_group = tg'
            or not isinstance(body[1], ast.AsyncFor)
            or ast.unparse(body[1].target) != 'message'
            or ast.unparse(body[1].iter) != 'session.incoming_messages'
            or body[1].orelse
            or len(body[1].body) != 1
            or ast.unparse(body[1].body[0]) != 'tg.start_soon(self._handle_message, message, session, lifespan_context, raise_exceptions)'):
        raise RuntimeError('Pinned FastMCP dispatch changed or cancellation is already present.')
    loop = body[1]
    lines = source.splitlines(keepends=True)
    indent = ' ' * loop.col_offset
    ending = '\r\n' if lines[loop.lineno - 1].endswith('\r\n') else '\n'
    original = lines[loop.lineno - 1:loop.end_lineno]
    lines[loop.lineno - 1:loop.end_lineno] = [indent+'try:'+ending] + [
        '    '+line if line.strip() else line for line in original
    ] + [indent+'finally:'+ending, indent+'    tg.cancel_scope.cancel()'+ending]
    result = ''.join(lines)
    ast.parse(result)
    return result


def main() -> None:
    from importlib.metadata import version
    import fastmcp.server.low_level as owner
    if version('fastmcp') != '3.4.7':
        raise RuntimeError('Requalify the cancellation repair for this FastMCP version.')
    path = Path(owner.__file__)
    with path.open('r', encoding='utf-8', newline='') as stream:
        source = stream.read()
    result = patch_source(source)
    with path.open('w', encoding='utf-8', newline='') as stream:
        stream.write(result)


if __name__ == '__main__':
    main()
