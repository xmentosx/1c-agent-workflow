"""SPPR MCP: bounded read-only tools, no source credential or scanner."""
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
    async def search_sppr(query: str, filters: dict[str, str] | None = None, limit: int = 10,
                          object_ids: list[str] | None = None, fields: list[str] | None = None):
        """Top-k meaning/text/ID search. Exact filters: project UUID, type, status, developer, tester, business_type, sprint. Optional object_ids (<=200) include incident row texts; fields select stored names (trailing / means prefix). Excerpts identify source rows."""
        return await invoke(service.search, query=query, filters=filters, limit=limit, object_ids=object_ids, fields=fields)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def read_sppr_object(object_id: str | list[str], cursor: str | None = None, limit: int = 10,
                               edge_id: str | None = None, fields: list[str] | None = None):
        """Read one card or <=20 IDs; batch returns object/field items. fields selects stored names/prefixes; omitted means all. edge_id requires one source card. Follow cursor; navigation links included."""
        return await invoke(service.read, object_id=object_id, cursor=cursor, limit=limit, edge_id=edge_id, fields=fields)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def list_sppr_relations(object_id: str, direction: str = "both", relation: str | None = None, cursor: str | None = None, limit: int = 10, view: str = "stored"):
        """List stored links (view=stored), including idea-step row identities. For an idea, view=development explains ChTZ/developer-task roles and source evidence; use direction=both and no relation filter. Follow cursor for all indexed results."""
        return await invoke(service.relations, object_id=object_id, direction=direction, relation=relation, cursor=cursor, limit=limit, view=view)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def get_sppr_context(object_ids: list[str], depth: int = 2, direction: str = "both",
                               relations: list[str] | None = None, max_objects: int = 50,
                               fields: list[str] | None = None, cursor: str | None = None, limit: int = 10):
        """Traverse <=20 seeds locally: depth 0..6, max_objects <=200, direction both/outgoing/incoming. Returns paged objects, evidence links, development roles, boundaries. fields adds selected card/row texts; omitted is compact. Follow cursor then stop_reasons/frontier; one index generation."""
        return await invoke(service.context, object_ids=object_ids, depth=depth, direction=direction,
                            relations=relations, max_objects=max_objects, fields=fields, cursor=cursor, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def list_sppr_objects(filters: dict[str, str] | None = None, cursor: str | None = None, limit: int = 10):
        """Enumerate all indexed cards using search_sppr exact filters, without embeddings. Stable order, total and cursor; complete means final page under current policy."""
        return await invoke(service.list_objects, filters=filters, cursor=cursor, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def find_sppr_paths(source_id: str, target_id: str, depth: int = 4, direction: str = "both",
                              relations: list[str] | None = None, max_objects: int = 200,
                              max_paths: int = 5, cursor: str | None = None, limit: int = 10):
        """Explain shortest stored paths between cards, never semantic links. depth <=6, max_objects <=200, max_paths <=20. Follow cursor; stop_reasons means bounded/incomplete exploration, not proof of no connection."""
        return await invoke(service.paths, source_id=source_id, target_id=target_id, depth=depth, direction=direction,
                            relations=relations, max_objects=max_objects, max_paths=max_paths, cursor=cursor, limit=limit)

    @mcp.tool(annotations={"readOnlyHint": True, "destructiveHint": False})
    async def sppr_index_status():
        """Show corpus freshness, live semantic progress and separate collection/embedding outcomes; does not start indexing."""
        return await invoke(service.status)

    return mcp


def main():
    settings = Settings.load(os.environ["SPPR_CONFIG"])
    provider = Embeddings(settings, os.environ.get("SPPR_EMBEDDING_KEY", ""))
    create_mcp(Service(settings, provider)).run(transport="http", host="0.0.0.0", port=8000)


if __name__ == "__main__":
    main()
