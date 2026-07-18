## 1C Project Lifecycle

ITL owns lifecycle, branch bases, MCP, verification, and export. Use `1c-workflow-fast` for routine work and `1c-workflow` plus one routed reference for recovery/explanation. Invoke helpers; never reproduce their flows. 1C Designer/Enterprise actions such as `LoadConfigFromFiles` and `UpdateDBCfg` need `timeout_ms >= 1800000`. Do not use `120000 ms`; status/help actions do not.

For Kilo `/itl`, return helper stdout verbatim, including `Lifecycle:` and `Additional helper actions:`; do not summarize, merge OpenSpec into it, or add a "no lifecycle actions executed" note.

One agent client is active. Its adapter owns commands/rules/agents; five ITL skills remain under `.agents/skills`. Switch only from clean `master` via `/itl-switch-client`; update worktrees later via `/itl-refresh`.

Before any code or metadata edit, mechanically classify the request as quick-fix or OpenSpec. Quick-fix is limited by `QUICKFIX_MAX_LINES` and still needs focused regression evidence. For every OpenSpec explore/propose/apply surface, run the installed ITL preflight: read `AGENTS.md` and `USER-RULES.md`, activate required project skills, consult required documentation sources first, record `Context Sources`, create `test-plan.md` at propose, follow it at apply, and finish with fresh applicable ITL evidence. Do not trust conversational memory as a substitute for this preflight.

For PM5 product logic, architecture, workflows, permissions, reports, integrations, acceptance tests, and OpenSpec work, activate `.agents/skills/product-docs/SKILL.md` before analysis or changes. Search `BookStack-product-docs-mcp` first, before broad repository traversal; verify against code, tests, current 1C metadata, and available MCP evidence; cite sources and surface conflicts. PM4 projects use the PM4 replacement rule installed by the helper.

Use sibling `itldev/*` worktrees and only the state-proven copied branch infobase. Never run development load/dump/test commands against the source infobase. `/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`, and `/deploy-and-test` are thin ITL bridges and must reconcile branch state before acting. On `master` or outside managed `itldev/*`, they stop without mutation.

Pending extension branches ask Empty/CFE, name, and optional path, then initialize internally in their worktree. Never give PowerShell; blocked actions return `EXTENSION_INIT_REQUIRED`.

`ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG` accept `auto|manual|off`; default `auto`. Before reporting 1C changes done, ensure coverage; new/changed `.feature` uses `/itl-vanessa-author`; then run fresh `/itl-check` after the last edit. Quick-fix is no exception: `verify_xml` and static checks are prechecks. Else report `pending verification`. `manual` runs for commands or requests; `off` runs only when the user explicitly requests that named component. Upstream `VERIFICATION_DEPTH` and `UI_TESTING` stay independent.

When Vanessa is `off`, do not automatically author scenarios or add them to a new plan. Preserve an already approved test plan, but execute components according to the effective mode. A skipped component records only `partial/skipped` evidence and never a normal fresh pass. With `verificationPolicy=block`, result/close requires full fresh evidence. With `warn`, partial export/close requires explicit confirmation and may be reported only as `implemented; executable verification skipped`, never `verified`, `ready`, or `done`.

Keep `USER-RULES.md` above `LLM-RULES.md` in precedence. `LLM-RULES.md` changes only through an explicit `/evolve`, one separately confirmed change at a time; `/evolve` cannot weaken branch safety, preflight, test-plan, verification-mode, result, or fresh-check gates. Rules updates preserve `LLM-RULES.md`.

Use pinned `update-ai-rules`, `update-workflow`, and `/itl-refresh`; never hidden `/installmcp`, `/updatemcp`, `/checkmcp`, or `/updaterules`. Use ITL MCP helper requests; ROCTUP and Vanessa UI MCP are on demand, not universal completion gates. After RTK setup, test `rtk rewrite` on the lifecycle helper command; add exclusions only for an observed rewrite, then restart the client. Event-log verification uses `.agent-1c/event-log-baselines/*.json`, and Vanessa must preserve the `TESTMANAGER -> TESTCLIENT` split. Search hygiene: keep secrets and runtime state in ignored files, preserve user-owned config keys, and ignore `.agent-1c/runs/` and `build/test-results/` unless diagnosing a specific run.

For native `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined, correctly quoted native command-line string.
