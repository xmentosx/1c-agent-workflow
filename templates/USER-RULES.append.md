## 1C Project Lifecycle

ITL owns lifecycle, bases, MCP, verification, export. Explicit generated `itl-*` skills run alone; other routine requests use only `1c-workflow-fast`. Use `1c-workflow` plus one reference only for non-routine work or helper-directed recovery without an explicit wrapper. 1C Designer/Enterprise LoadConfigFromFiles/UpdateDBCfg actions need `timeout_ms >= 3900000`; status/help do not. Do not use `120000 ms`.

On Enterprise failure/timeout/suspected hang, inspect fresh branch `1Cv8Log` entries for its operation window; `/Out` is secondary. Correlate errors with process/state progress and expected duration. Proven failure/stall means stop waiting for the hard timeout; use helper recovery; never kill arbitrary 1C PIDs.

Native `/itl`: return exact helper stdout in one fenced `text` block; preserve line breaks, blank lines, and indentation; write nothing outside. Never summarize, reorder, omit, or merge sections.

One client is active: its adapter owns commands/rules/agents; five ITL skills stay in `.agents/skills`. Switch on clean `master` via `/itl-switch-client`; refresh worktrees via `/itl-refresh`.

Classify code/metadata independently as `executionPath=quick-fix|full-cycle` and `planningMode=direct|OpenSpec`; all four pairs are valid. Default `direct`; use OpenSpec on request or for agreement. Promotion triggers set only `executionPath=full-cycle`. Quick-fix obeys `QUICKFIX_MAX_LINES`; it needs regression evidence. OpenSpec phases read rules, activate required skills/docs, record `Context Sources`, agree `test-plan.md` at propose, follow approved artifacts at apply, and finish with evidence. Never install missing `openspec` or run `openspec update`; memory never replaces preflight.

For PM5 product logic, architecture, workflows, permissions, reports, integrations, acceptance tests, or OpenSpec, activate `.agents/skills/product-docs/SKILL.md`. For the same OpenSpec scope, reuse current/proposal `Context Sources`; otherwise search `BookStack-product-docs-mcp` before broad repository traversal. Use sufficient non-duplicative current evidence; never repeat native discovery after sufficient code/graph MCP results. Cite sources and surface conflicts. PM4 uses a helper-installed replacement.

Use sibling `itldev/*` worktrees and only the state-proven copied branch infobase. Never load/dump/test against the source infobase. `/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`, and `/deploy-and-test` are ITL bridges that reconcile branch state. On `master` or outside managed `itldev/*`, they stop without mutation.

Pending extension branches ask Empty/CFE, name, and optional path, then initialize internally there. Never give PowerShell; blocked actions return `EXTENSION_INIT_REQUIRED`.

`ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG` accept `auto|manual|off`; default `auto`. Use targeted/static checks while implementing; run executable milestones only to decide continuation. Require Vanessa coverage and fresh unfiltered `/itl-check` after the last relevant edit. Vanessa UI MCP aids debugging; it creates no pass. Quick-fix is no exception; `verify_xml`/static are prechecks. Else report `pending verification`. `manual` runs for commands or requests; `off` runs only when the user explicitly requests that named component. Upstream `VERIFICATION_DEPTH` and `UI_TESTING` stay independent.

After a failed check, classify ownership before editing: `runner` (ITL helper/topology/profiles/ports), `fixture` (scenario/data setup), or `product` (proven behavior/assertion). The ITL helper exclusively owns `TESTMANAGER -> TESTCLIENT`; runner/profile/port evidence never authorizes product/feature workarounds without proof of their defect. Do not repeat the same unchanged run without new evidence or a code/config change. On loaded-skill/installed-file conflict, stop lifecycle commands and resolve the stated `/reload` or version/cache mismatch. Preserve unrelated dirty changes; revert only owned diagnostic edits.

When Vanessa is `off`, do not automatically author scenarios or add them to a new plan. Preserve an already approved test plan, but execute components according to the effective mode. A skipped component records only `partial/skipped` evidence and never a normal fresh pass. With `verificationPolicy=block`, result/close requires full fresh evidence. With `warn`, partial export/close requires explicit confirmation and may be reported only as `implemented; executable verification skipped`, never `verified`, `ready`, or `done`.

Keep `USER-RULES.md` above `LLM-RULES.md` in precedence. `LLM-RULES.md` changes only through an explicit `/evolve`, one separately confirmed change at a time; `/evolve` cannot weaken branch safety, preflight, test-plan, verification-mode, result, or fresh-check gates. Rules updates preserve `LLM-RULES.md`.

## Shared Cross-Project Memory

Global `1c-templates-mcp` `remember`/`recall` is shared across projects, not project memory. `remember` only verified, non-confidential facts safe and useful across unrelated projects, preferably on an explicit cross-project retention request. Never store project objects/decisions, customer data, paths/endpoints, source/runtime evidence, secrets, or PII. Put project-specific facts and corrections in that project's `memory.md`; upstream correction capture never requires shared `remember`. Do not run shared `recall` by default: use it only when cross-project platform/tooling/workflow/team knowledge is relevant, and verify results against the current project. `templatesearch` is unaffected.

Use pinned `update-ai-rules`, `update-workflow`, and `/itl-refresh`; never hidden `/installmcp`, `/updatemcp`, `/checkmcp`, or `/updaterules`. Use ITL MCP helper requests. Qualify remote `vibecoding1c` and branch-local MCP separately; route deferred discovery, including Codex `ALL_TOOLS`, to `1c-workflow/references/mcp.md`. On-demand MCP is diagnostic, not a gate. Test `rtk rewrite` on the lifecycle helper; exclude only observed rewrites, then restart. Preserve `.agent-1c/event-log-baselines/*.json` and Vanessa `TESTMANAGER -> TESTCLIENT`. Search hygiene: ignore secrets/runtime, preserve user config; inspect only named runs under `.agent-1c/runs/` or `build/test-results/`.

1C launches use admission. On `session-capacity`, finish/close owned work before retry; never change limits or kill foreign PIDs.
