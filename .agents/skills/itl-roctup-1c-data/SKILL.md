---
name: itl-roctup-1c-data
description: Use for read-only, token-bounded data exploration in the current itldev/* branch through branch-local ROCTUP/1c-mcp-toolkit. Prefer metadata-first queries and use the legacy web Branch Data MCP only when ROCTUP is unavailable or explicitly required.
---

# ITL ROCTUP 1C Data Skill

Use this skill when the agent needs to inspect data in the current `itldev/*` branch infobase through ROCTUP/1c-mcp-toolkit.

## Priority

- Call the pre-registered `itl-roctup-data` MCP server for data exploration in a development branch. It exposes compact `resolve_tool`, `call_tool`, and `finish_database_access` gateway tools; the verified full catalog stays inside the facade. Its branch-local backend starts only when `call_tool` invokes an inner tool. Inactivity may stop the native backend, but it does not release the agent-owned database phase.
- Use the legacy web-based Branch Data MCP only when ROCTUP is unavailable or the branch is intentionally published and the requested workflow depends on that legacy channel.
- Do not assume a database is web-published.

## Token Control

- For known parameterized tools, skip discovery: call `call_tool` with the exact inner `name` and `argumentsJson` containing one JSON-encoded object with only explicitly intended fields. This string form preserves arbitrary inner property names across schema-restricting clients. Omit absent optional fields. For a no-argument inner tool, use `arguments={}` instead. Never send `arguments` and `argumentsJson` together.
- Use `resolve_tool` once only when the inner tool name or exact schema is unknown. Its static catalog search does not start 1C.
- Start with inner `get_metadata` using filters and a small `limit`.
- Default `get_metadata.limit` to `50` or less.
- Run inner `execute_query` only after metadata has narrowed the target objects and fields.
- Default `execute_query.limit` to `100` or less.
- Select only the fields needed for the current question. Avoid broad table scans.
- Summarize query results; do not paste large raw result sets unless the user explicitly asks.

## Safety

- Do not pass `execute_code` or `restart_1c_session` to `call_tool` unless the user explicitly requests that exact operation. `close_1c_session` may be used without separate confirmation when releasing the current managed dev-branch session for lifecycle recovery; never use it against the source infobase or another branch.
- Do not pass a 1C password through ROCTUP startup parameters.
- Treat ROCTUP and Vanessa artifacts as runtime tooling; they must not be exported as product CF/CFE artifacts.
- Never start, stop, or call the backend through raw HTTP. If a call returns `ITL_INFOBASE_APPLICATION_NOT_READY`, run the supported `update-dev-branch-base` helper once and repeat the original call once. Report any other structured facade, catalog, or broker error.

## Database Access Handoff

Before an incompatible lifecycle, test, or measurement phase, explicitly choose one path: continue this task's current ROCTUP phase and postpone the next phase, or finish the phase and call `finish_database_access` on the same `itl-roctup-data` facade. Wait for that call to confirm release before starting the incompatible phase. `close_1c_session` alone is not this handoff.

Release only access owned by the current task and facade instance. Never finish or stop a foreign holder; report its owner as the blocker and leave its process and lease intact. Idle timeout or client exit is an abandonment fallback, not a normal handoff.

## On-Demand References

- Do not open the full ROCTUP reference files at session start.
- Read the downloaded `skills/composing-1c-queries` guidance only before a non-trivial query.
- Read `skills/tools-full-reference` only when the targeted schema returned by `resolve_tool` is insufficient for a correct call.
- ROCTUP upstream skills are cached under ignored `.agent-1c/tools/roctup-mcp-toolkit/skills` during workflow init/update and are not vendored into this repository.
