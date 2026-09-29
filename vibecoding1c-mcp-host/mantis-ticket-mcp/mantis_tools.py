"""Keep synchronous Mantis and index work outside the HTTP event loop."""
import asyncio
from functools import wraps
import inspect
from typing import get_type_hints


def worker_tool(function):
    @wraps(function)
    async def run(*args, **kwargs):
        # to_thread preserves the MCP request context, including actor headers.
        return await asyncio.to_thread(function, *args, **kwargs)

    # Preserve the public contract even for postponed annotations from another
    # module; FastMCP inspects this wrapper to construct its tool schema.
    run.__annotations__ = get_type_hints(function)
    run.__signature__ = inspect.signature(function, eval_str=True)
    return run
