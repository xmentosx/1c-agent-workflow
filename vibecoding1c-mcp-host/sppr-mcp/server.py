"""SPPR MCP: four bounded read-only tools, no source credential or scanner."""
from __future__ import annotations

import asyncio
import os

from sppr_core import Settings, SpprError
from sppr_embeddings import Embeddings
from sppr_service import Service


def create_mcp(service):
    from fastmcp import FastMCP
    from fastmcp.exceptions import ToolError
    from fastmcp.tools.tool import ToolResult
    from mcp.types import TextContent

    mcp = FastMCP("sppr-knowledge", stateless_http=True)

    async def invoke(method, **kwargs):
        try:
            data = await asyncio.to_thread(method, **kwargs)
            return ToolResult(content=[TextContent(type="text", text="SPPR result is in structuredContent.")], structured_content=data)
        except SpprError as exc:
            raise ToolError(str(exc)) from None
        except Exception:
            raise ToolError("Local index operation failed; inspect sppr_index_status and the collector runtime.") from None

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def search_sppr(query: str, filters: dict[str, str] | None = None, limit: int = 10):
        """Find SPPR cards by meaning/ID/Mantis. Filters: project UUID, type, status, developer, tester, business_type, sprint. Top-k is not a complete relation traversal."""
        return await invoke(service.search, query=query, filters=filters, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def read_sppr_object(object_id: str, cursor: str | None = None, limit: int = 10, edge_id: str | None = None):
        """Read indexed fields with continuation. Use edge_id from search/relations for a specific TP–idea realization. Both navigation links are included."""
        return await invoke(service.read, object_id=object_id, cursor=cursor, limit=limit, edge_id=edge_id)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def list_sppr_relations(object_id: str, direction: str = "both", relation: str | None = None, cursor: str | None = None, limit: int = 10, view: str = "stored"):
        """List stored links (view=stored), including idea-step row identities. For an idea, view=development explains ChTZ/developer-task roles and source evidence; use direction=both and no relation filter. Follow cursor for all indexed results."""
        return await invoke(service.relations, object_id=object_id, direction=direction, relation=relation, cursor=cursor, limit=limit, view=view)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def sppr_index_status():
        """Show current corpus, freshness, coverage and last collector outcome; does not start indexing."""
        return await invoke(service.status)

    return mcp


def main():
    settings = Settings.load(os.environ["SPPR_CONFIG"])
    provider = Embeddings(settings, os.environ.get("SPPR_EMBEDDING_KEY", ""))
    create_mcp(Service(settings, provider)).run(transport="http", host="0.0.0.0", port=8000)


if __name__ == "__main__":
    main()
