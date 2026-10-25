---
description: "Memory-only entry point: provider policy, scoped recall, durable writes and failure handling. Load before a memory operation, a 1C change, or saving a user correction."
alwaysApply: false
category: workflow
---

# Project memory

Before the first memory operation, read this file and `content/rules/tool-policy.md`; reuse them until policy, target or session changes. This is the ordinary memory route: no `mcp-policy.md`, `mcp-1c-tools` router or template skill is needed. Those load separately when the task uses 1C tools. For optional provider arguments or setup, consult only the selected provider in `content/skills/mcp-1c-tools/docs/memory-providers.md`.

### Managed ITL project boundary

When `.agent-1c/project.json` exists and scoped Cognee has not been explicitly qualified/enabled, preserve the installed host route and strict root memory. Global templates memory is shared cross-project knowledge, not project-isolated storage. The generic Cognee → OpenViking priority and multi-provider recall below apply outside managed ITL projects. This upgrade does not enroll a project, migrate notes or provision a provider. Even an exposed tool or `TOOL_COGNEE`/`TOOL_OPENVIKING=auto` is not a verified project-isolated destination. If marked `required`, report no qualified binding and stop only the dependent memory operation. `templatesearch` remains independent.

<!-- ITL-SCOPED-MEMORY-V1 -->
In a managed ITL project, use scoped Cognee only after explicit ITL opt-in with `scoped-cognee-memory-v1`, a qualified matching policy/adapter, an applied registry context and an authenticated ordinary principal. Configuration, a server name and dataset labels are not grants or live readiness. Use the ITL-scoped frontend; never bypass `off`, missing grants or the applied scope through a direct backend, alias, CLI or broader provider.

Before recall or correction capture, call `memory_status(local_only=true)` once for the current context: read the compact goal/constraints/next step and pending references. Exact pending source is available by note ID without backend access. Keep root `memory.md` under all four strict criteria below. Pending facts, project corrections and unconfirmed writes go to private user-local pending through the frontend, outside Git/reset; they do not relax root eligibility. If the frontend is unavailable, preserve a dated private local note with source/intended scope and report the gap; do not expose it to shared templates.

Six destinations are task+branch+base cycle, local workspace, developer workplace, product, project and organization. Select the narrowest sufficient destination explicitly from `memory_status`; no default task/global write and no six-way copies. Product writes require the registry knowledge area's confirmed canonical home, conditions/version and evidence independent of customer customization. Missing home/applicability means a private task/project candidate, not inferred product sharing. One fact, one durable write. Organizational sharing is explicit and subject to native grants.

Preserve TOOL policy, full-cycle/spec versus quick-fix reader selection, separate standing query, correction-capture, /evolve and Memory line below. Within Cognee use one union CHUNKS query over admitted exact dataset IDs, up to 24 candidates and 8 compact cards; source/status lookups are bounded separately. Only current authorized originals with applicable verified evidence are reusable facts. Candidate, partial and unavailable are not confirmed absence. Old cycles are explicit history, never current instructions. Do not repeat unchanged recall or replay an uncertain write; reconcile exact note/data ID with `memory_status` first. Indexing is distinct from durability. Precise update/retirement changes only the exact old note; a supersedes reference alone does not suppress a stale original.

OpenViking remains optional; this integration neither provisions nor replicates it. Do not fallback a project fact to global templates. Independent templates recall is only for relevant shared non-confidential knowledge under host policy. Disable preserves private source, receipts and datasets; reload after a cycle/context change and use the existing ITL recovery owner for client conflicts.
<!-- /ITL-SCOPED-MEMORY-V1 -->

## Two layers

- Root `memory.md` holds only whole-project, critical, stable, non-derivable rules: violating one risks production, regulatory compliance or data confidentiality. No TODOs, style notes or subsystem facts; entry format is in that file.
- Connected memory holds useful project facts, confirmed solutions, user corrections and standing working conditions. Save what would change the next session's actions, unless already covered by a rule or an equivalent note. Memory is context; current instructions and verified source win.

## Provider routing

Apply `TOOL_COGNEE`, `TOOL_OPENVIKING`, `TOOL_TEMPLATES` under `tool-policy.md` before discovery. Check exposed read and write capabilities separately; config entries prove neither. Resolve namespaces and argument names from live descriptors. Known aliases of one store count once; different stores remain separate.

- **Write priority: Cognee → OpenViking → templates MCP.** Skip `off`; unavailable `auto` advances. A selected unavailable `required` writer blocks that save; keep a dated pending note locally. Stop after one durable write. A later fallback's `required` setting does not require a duplicate.
- **Read scope:** full-cycle/spec searches every eligible connected provider, including templates memory. Quick-fix and standing-condition searches use the first eligible reader in the same priority order; write availability is irrelevant. One failed reader means partial coverage and does not suppress independent searches. A required reader's gap stays incomplete.
- Scope queries and notes to the established project dataset/namespace, or include the project identity when scoping is unsupported. Ignore unrelated hits; keep global preferences separate. Merge duplicate results with provider and note ID/URI attribution. Never invent a dataset or identity.
- One topic per query. Send task terms separately from `working conditions benchmark conventions`. Cognee uses `search_type="CHUNKS"`; generated completion prose with no identified project evidence is not a recalled fact.

| Provider | Read | Durable write |
|---|---|---|
| Cognee | `recall(query=..., search_type="CHUNKS")`; established `datasets` when supported | `remember(data=..., dataset_name=...)`; omit `session_id` |
| OpenViking | exposed `search(query=...)` / `find(query=...)`; established URI scope when supported | `remember(messages=[{"role":"user","content":...}])` |
| templates MCP | `recall(query=...)` | `remember(content=...)` |

These are routing examples, not permission to invent unsupported arguments. Current templates `remember` needs no operator token or write opt-in; older deployments follow their actual tool exposure and response. `templatesearch` is not memory retrieval.

## Gates (hard)

1. **Recall-first.** Before designing a 1C code or metadata change, quick-fix included, search task terms at the provider scope above. Docs-fix requires no recall unless user/global instructions require it; then use this memory-only route. On the session's first non-trivial task, separately query `working conditions benchmark conventions` on the first reader and reuse its answer for that session. Budget: one task query per selected reader plus that standing query; reformulate once after an empty answer. Widen quick-fix after an empty answer only when a project convention matters. Batch independent calls; never repeat unchanged queries merely for reassurance.
2. **Correction-capture.** Save a user correction, rejected approach, non-obvious clarification or standing condition in the same turn. Facts use ordinary notes; behaviour/process friction uses `rule-friction:`. Only requested `/evolve` edits `LLM-RULES.md`; explicit maintenance of this source ruleset remains ordinary authorized work.
3. **Memory line.** For every 1C code/metadata change and every memory operation, report: `Memory: searched <providers>; recalled <n relevant notes / nothing relevant>; saved <n notes / nothing to save>; <partial coverage or fallback, when applicable>`. Claim durability only after confirmation; pending indexing and an unconfirmed write are different states.

## Setup reminder

Once per session, check whether an eligible external memory tool is exposed. If none is exposed, load `content/rules/memory-setup.md` for configuration checks and the appropriate reminder. This never installs a server or interrupts independent work.

## Availability and fallback

- Missing readers: use root `memory.md`, report local-only coverage. Disabled/unreachable is not an empty successful search. `required` gaps remain incomplete; never bypass `off` through aliases, HTTP or CLI.
- Bad argument: inspect the live descriptor and retry once with the corrected name. A read timeout needs a narrower query or the next eligible provider, not the same call again; only a first-call `fetch failed` permits one reconnect retry. An untyped read error permits one reformulation, then fallback. 401/403 or definite rejection means unavailable; no blind retry or repeated probes of a known failure.
- No eligible writer succeeds: append a dated note to `memory.md`, temporarily relaxing its eligibility. Record the intended provider and failure; a required save remains pending. Migrate only after confirmed durable storage.
- **Ambiguous write:** timeout/interruption is not rejection. Check a returned ID/status before any other write. `stored=true` with `index_pending=true` is durable even if another success field is false. Never duplicate it. If unresolved, keep a dated local `write unconfirmed` note with provider/ID for reconciliation before migration; do not try another writer blindly.

## Note format

One self-contained fact per note, English narrative, original 1C identifiers unchanged, scope and date included; no secrets or PII. Record cause, verified fix and prevention for lessons. Update an existing note only through a precise supported operation; otherwise reference the old note in a correction. Do not duplicate known notes.

## Promote / demote

Promote to `memory.md` only when all four layer criteria hold. Retire only the exact old note through supported deletion; otherwise mark its ID/URI superseded. Never delete a dataset, unrelated notes or a memory root to retire one fact.
