"""SPPR MCP: four bounded read-only tools, no source credential or scanner."""
from __future__ import annotations

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

    def invoke(method, **kwargs):
        try:
            data = method(**kwargs)
            return ToolResult(content=[TextContent(type="text", text="SPPR result is in structuredContent.")], structured_content=data)
        except SpprError as exc:
            raise ToolError(str(exc)) from None
        except Exception:
            raise ToolError("Local index operation failed; inspect sppr_index_status and the collector runtime.") from None

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    def search_sppr(query: str, filters: dict[str, str] | None = None, limit: int = 10):
        """Find SPPR cards by meaning/ID/Mantis. Filters: project UUID, type, status, developer, tester, business_type, sprint. Top-k is not a complete relation traversal."""
        return invoke(service.search, query=query, filters=filters, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    def read_sppr_object(object_id: str, cursor: str | None = None, limit: int = 10, edge_id: str | None = None):
        """Read indexed fields with continuation. Use edge_id from search/relations for a specific TP–idea realization. Both navigation links are included."""
        return invoke(service.read, object_id=object_id, cursor=cursor, limit=limit, edge_id=edge_id)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    def list_sppr_relations(object_id: str, direction: str = "both", relation: str | None = None, cursor: str | None = None, limit: int = 10):
        """List stored adjacent relations, not semantic suggestions. direction: both/outgoing/incoming. Follow cursor to complete; then visit returned IDs for more hops."""
        return invoke(service.relations, object_id=object_id, direction=direction, relation=relation, cursor=cursor, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    def sppr_index_status():
        """Show current corpus, freshness, coverage and last collector outcome; does not start indexing."""
        return invoke(service.status)

    return mcp


def main():
    settings = Settings.load(os.environ["SPPR_CONFIG"])
    provider = Embeddings(settings, os.environ.get("SPPR_EMBEDDING_KEY", ""))
    create_mcp(Service(settings, provider)).run(transport="http", host="0.0.0.0", port=8000)


if __name__ == "__main__":
    main()
