"""Keep synchronous Mantis and index work outside the HTTP event loop."""
import asyncio
from functools import wraps
import inspect
import time
from typing import get_type_hints


def worker_tool(function):
    @wraps(function)
    async def run(*args, **kwargs):
        submitted = time.monotonic()
        def execute():
            started = time.monotonic()
            result = function(*args, **kwargs)
            structured = getattr(result, "structured_content", None)
            if isinstance(structured, dict) and isinstance(structured.get("timing_ms"), dict):
                structured["timing_ms"]["worker_queue"] = round((started - submitted) * 1000, 2)
            return result
        # to_thread preserves the MCP request context, including actor headers.
        result = await asyncio.to_thread(execute)
        structured = getattr(result, "structured_content", None)
        if isinstance(structured, dict) and isinstance(structured.get("timing_ms"), dict):
            structured["timing_ms"]["dispatch_total"] = round((time.monotonic() - submitted) * 1000, 2)
        return result

    # Preserve the public contract even for postponed annotations from another
    # module; FastMCP inspects this wrapper to construct its tool schema.
    run.__annotations__ = get_type_hints(function)
    run.__signature__ = inspect.signature(function, eval_str=True)
    return run
