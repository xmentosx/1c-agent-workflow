---
name: itl-roctup-1c-data
description: Use for read-only, token-bounded data exploration in the current itldev/* branch through branch-local ROCTUP/1c-mcp-toolkit. Prefer metadata-first queries and use the legacy web Branch Data MCP only when ROCTUP is unavailable or explicitly required.
---

# ITL ROCTUP 1C Data Skill

Use this skill when the agent needs to inspect data in the current `itldev/*` branch infobase through ROCTUP/1c-mcp-toolkit.

## Priority

- Call the pre-registered `itl-roctup-data` MCP server for data exploration in a development branch. It exposes compact `resolve_tool` and `call_tool` gateway tools; the verified full catalog stays inside the facade. Its branch-local backend starts only when `call_tool` invokes an inner tool and stops automatically after inactivity or client exit.
- Use the legacy web-based Branch Data MCP only when ROCTUP is unavailable or the branch is intentionally published and the requested workflow depends on that legacy channel.
- Do not assume a database is web-published.

## Token Control

- For known tools, skip discovery: call `call_tool` with the exact inner `name` and an `arguments` object containing only explicitly intended fields. Omit absent optional fields; use `{}` for a no-argument inner tool.
- Use `resolve_tool` once only when the inner tool name or exact schema is unknown. Its static catalog search does not start 1C.
- Start with inner `get_metadata` using filters and a small `limit`.
- Default `get_metadata.limit` to `50` or less.
- Run inner `execute_query` only after metadata has narrowed the target objects and fields.
- Default `execute_query.limit` to `100` or less.
- Select only the fields needed for the current question. Avoid broad table scans.
- Summarize query results; do not paste large raw result sets unless the user explicitly asks.

## Safety

- Do not pass `execute_code`, `restart_1c_session`, or `close_1c_session` to `call_tool` unless the user explicitly requests that exact operation.
- Do not pass a 1C password through ROCTUP startup parameters.
- Treat ROCTUP and Vanessa artifacts as runtime tooling; they must not be exported as product CF/CFE artifacts.
- Never start, stop, or call the backend through raw HTTP. If `itl-roctup-data` reports a facade, catalog, or broker error, report that structured error.

## On-Demand References

- Do not open the full ROCTUP reference files at session start.
- Read the downloaded `skills/composing-1c-queries` guidance only before a non-trivial query.
- Read `skills/tools-full-reference` only when the targeted schema returned by `resolve_tool` is insufficient for a correct call.
- ROCTUP upstream skills are cached under ignored `.agent-1c/tools/roctup-mcp-toolkit/skills` during workflow init/update and are not vendored into this repository.
