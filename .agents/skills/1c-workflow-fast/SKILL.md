---
name: 1c-workflow-fast
description: Run routine helper commands in installed ITL 1C projects for status, branch creation, Vanessa verification, refresh, and CF/CFE export. Never use for development, review, tests, or docs of the 1c-agent-workflow source repository.
---

# 1C Workflow Fast

## Purpose

Map routine requests in an installed ITL project to one helper action. Use the monitored compact runner for mutations and long checks, then parse its terminal JSON. Open full workflow references only for failure recovery, missing setup, or explanation.

## Intent Map

- status or worktree paths: `status`
- vibecoding1c MCP: `vibecoding1c-mcp-setup|status|select|refresh-registry`
- package update: `update-workflow`
- new configuration branch: `new-dev-branch`
- new extension branch: `new-extension-dev-branch`; collect `Empty|Cfe`, name, and optional CFE path
- resume pending extension setup internally: `init-dev-branch-extension`
- post-change check: `check-dev-branch`
- explicitly requested base load without tests: `update-dev-branch-base`
- compatibility verification: `verify-dev-branch`
- refresh from source: `refresh-dev-branch`
- synchronize master and rebuild the latest-only seed: `sync-master`
- refresh only from the current master without source/seed access: `refresh-dev-branch-lite`
- export CF/CFE: `export-dev-branch-result`
- explicit advanced close: `close-dev-branch`

## Command Template

From the project root, run mutations and long checks with `timeout_ms >= 3900000` (or above the configured Designer timeout). Do not use `120000 ms`; `status`/`help` do not need it. 1C Designer/Enterprise may run `/LoadConfigFromFiles ... /UpdateDBCfg`.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -- -Action <action>
```

Use it for `init-*`, `update-*`, `check-*`, `verify-*`, `refresh-*`, `export-*`, and client switching. Short read-only `status`, `help`, and MCP status/catalog actions may call `agent-1c.ps1` directly; honor the exit code.

Branch creation and advanced close use the same runner with `-Windowed` so safety confirmation remains visible:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -Windowed -- -Action new-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -Windowed -- -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>" -ExtensionInitMode Empty -ExtensionName "<extension-name>" -OfferOpenAgent
```

For CFE, use `Cfe` plus `-ExtensionSourcePath`. Unknown extension values may be omitted for pending first-entry setup.

On `status=succeeded`, the final response must be exactly the non-empty `userReport` Markdown, including for refresh. It includes MCP/Browser state and advice. Do not translate it, use a code fence, convert it to a table, rename or merge fields, reorder or omit lines, summarize, substitute `requiredAction`, or read `console.log`. `-UseCurrentWorktree` is explicit-only.

Current-branch actions infer `itldev/<name>`; do not ask for a branch name. Data/UI work uses the matching MCP skill. `/itl-check` is Vanessa Automation verification, not MCP.

When the user requests an executable milestone or completion check, run `check-dev-branch` directly; do not pre-run base update or `/deploy-and-test`. Do not add `VanessaFeaturePath` or `VanessaFilterTags` to a final run. Its stderr heartbeat reports stage, elapsed time, liveness, no-progress time, timeout remaining, owned PIDs, CPU/log deltas, and working set. Never kill 1C manually: the helper warns at `stalled-suspected`, applies its bounded stall timeout, and cleans up exact tracked processes. Liveness never replaces or weakens the independent Designer memory guard or overall hard timeout.

For export/close, obey the helper's `verificationPolicy`.

## Failure Handling

Read `status`, exit code, `errorCategory`, `requiredAction`, and `nextAction`.

- `status=failed` means failed. Never relabel it as skipped; never call it ready, verified, or done.
- Report the action, concise error, and artifact paths. Read 80 console-log tail lines only for unclassified `runner` failure.
- Follow `requiredAction` or `nextAction` exactly. Ask only for a value that the helper explicitly identifies as missing.
- For an agent-made change with `requiredAction=/itl-verify-fix`, activate full `1c-workflow` and continue its bounded verification recovery. Do not return completion to the user. Standalone diagnostics only report failure.
- Development completion still requires fresh passed evidence after the last edit; partial/skipped is insufficient.
- Use full `1c-workflow` for recovery, unusual topology, or initialization.

For first-time project bootstrap, follow `AGENT-INSTALL.md`. This fast skill is optimized for regular branch operations after installation.
