---
name: itl-roctup-1c-data
description: Use for read-only, token-bounded data exploration in the current itldev/* branch through branch-local ROCTUP/1c-mcp-toolkit. Prefer metadata-first queries and use the legacy web Branch Data MCP only when ROCTUP is unavailable or explicitly required.
---

# ITL ROCTUP 1C Data Skill

Use this skill when the agent needs to inspect data in the current `itldev/*` branch infobase through ROCTUP/1c-mcp-toolkit.

## Priority

- Call the pre-registered `itl-roctup-data` MCP server for data exploration in a development branch. Its branch-local backend starts on the first tool call and stops automatically after inactivity or client exit.
- Use the legacy web-based Branch Data MCP only when ROCTUP is unavailable or the branch is intentionally published and the requested workflow depends on that legacy channel.
- Do not assume a database is web-published.

## Token Control

- Start with `get_metadata` using filters and a small `limit`.
- Default `get_metadata.limit` to `50` or less.
- Run `execute_query` only after metadata has narrowed the target objects and fields.
- Default `execute_query.limit` to `100` or less.
- Select only the fields needed for the current question. Avoid broad table scans.
- Summarize query results; do not paste large raw result sets unless the user explicitly asks.

## Safety

- Do not call `execute_code`, `restart_1c_session`, or `close_1c_session` unless the user explicitly requests that exact operation.
- Do not pass a 1C password through ROCTUP startup parameters.
- Treat ROCTUP and Vanessa artifacts as runtime tooling; they must not be exported as product CF/CFE artifacts.
- Never start, stop, or call the backend through raw HTTP. If `itl-roctup-data` reports a facade, catalog, or broker error, report that structured error.

## On-Demand References

- Do not open the full ROCTUP reference files at session start.
- Read the downloaded `skills/composing-1c-queries` guidance only before a non-trivial query.
- Read `skills/tools-full-reference` only when the MCP tool schema is insufficient for a correct call.
- ROCTUP upstream skills are cached under ignored `.agent-1c/tools/roctup-mcp-toolkit/skills` during workflow init/update and are not vendored into this repository.
