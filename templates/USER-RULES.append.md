## 1C Project Lifecycle

ITL owns lifecycle, bases, MCP, verification, and export. Use `1c-workflow-fast`; use `1c-workflow` plus one recovery reference. Helpers only. 1C Designer/Enterprise LoadConfigFromFiles/UpdateDBCfg actions need `timeout_ms >= 3900000`; status/help do not. Do not use `120000 ms`.

Native `/itl`: return exact helper stdout in one fenced `text` block; preserve line breaks, blank lines, and indentation; write nothing outside. Never summarize, reorder, omit, or merge sections.

One agent client is active. Its adapter owns commands/rules/agents; five ITL skills remain under `.agents/skills`. Switch only from clean `master` via `/itl-switch-client`; update worktrees later via `/itl-refresh`.

Classify code/metadata independently as `executionPath=quick-fix|full-cycle` and `planningMode=direct|OpenSpec`; all four pairs are valid. Default `direct`; use OpenSpec on request or for valuable formal agreement. Promotion triggers set only `executionPath=full-cycle`. Quick-fix obeys `QUICKFIX_MAX_LINES` and needs regression evidence. OpenSpec phases read rules, activate required skills/docs, record `Context Sources`, agree `test-plan.md` at propose, follow approved artifacts at apply, and finish with evidence. Never install missing `openspec` or run `openspec update`; memory cannot replace preflight.

For PM5 product logic, architecture, workflows, permissions, reports, integrations, acceptance tests, and OpenSpec work, activate `.agents/skills/product-docs/SKILL.md`. For the same OpenSpec scope, reuse current/proposal `Context Sources`; otherwise search `BookStack-product-docs-mcp` before broad repository traversal. Verify against code, tests, current 1C metadata, and available MCP evidence; cite sources and surface conflicts. PM4 uses a helper-installed replacement.

Use sibling `itldev/*` worktrees and only the state-proven copied branch infobase. Never run development load/dump/test commands against the source infobase. `/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`, and `/deploy-and-test` are thin ITL bridges and must reconcile branch state before acting. On `master` or outside managed `itldev/*`, they stop without mutation.

Pending extension branches ask Empty/CFE, name, and optional path, then initialize internally in their worktree. Never give PowerShell; blocked actions return `EXTENSION_INIT_REQUIRED`.

`ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG` accept `auto|manual|off`; default `auto`. Use targeted/static checks while implementing; run executable milestones only to decide continuation. Require Vanessa coverage and fresh unfiltered `/itl-check` after the last relevant edit. Vanessa UI MCP aids debugging; it creates no pass. Quick-fix is no exception; `verify_xml`/static are prechecks. Else report `pending verification`. `manual` runs for commands or requests; `off` runs only when the user explicitly requests that named component. Upstream `VERIFICATION_DEPTH` and `UI_TESTING` stay independent.

When Vanessa is `off`, do not automatically author scenarios or add them to a new plan. Preserve an already approved test plan, but execute components according to the effective mode. A skipped component records only `partial/skipped` evidence and never a normal fresh pass. With `verificationPolicy=block`, result/close requires full fresh evidence. With `warn`, partial export/close requires explicit confirmation and may be reported only as `implemented; executable verification skipped`, never `verified`, `ready`, or `done`.

Keep `USER-RULES.md` above `LLM-RULES.md` in precedence. `LLM-RULES.md` changes only through an explicit `/evolve`, one separately confirmed change at a time; `/evolve` cannot weaken branch safety, preflight, test-plan, verification-mode, result, or fresh-check gates. Rules updates preserve `LLM-RULES.md`.

Use pinned `update-ai-rules`, `update-workflow`, and `/itl-refresh`; never hidden `/installmcp`, `/updatemcp`, `/checkmcp`, or `/updaterules`. Use ITL MCP helper requests; ROCTUP and Vanessa UI MCP are on demand, not universal completion gates. After RTK setup, test `rtk rewrite` on the lifecycle helper command; add exclusions only for an observed rewrite, then restart the client. Event-log verification uses `.agent-1c/event-log-baselines/*.json`, and Vanessa must preserve the `TESTMANAGER -> TESTCLIENT` split. Search hygiene: keep secrets and runtime state in ignored files, preserve user-owned config keys, and ignore `.agent-1c/runs/` and `build/test-results/` unless diagnosing a specific run.

For native `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined, correctly quoted native command-line string.
