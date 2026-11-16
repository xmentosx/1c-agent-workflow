# Development inside a development branch

This reference routes work inside an existing `itldev/*` branch. It explains the lifecycle surface and selects exactly one leaf reference. After choosing the mode open only the matching file:

- `dev-branch-quick-fix.md`: `executionPath=quick-fix`, `planningMode=direct`;
- `dev-branch-direct.md`: `executionPath=full-cycle`, `planningMode=direct`;
- `dev-branch-openspec.md`: `planningMode=OpenSpec`, with `executionPath=quick-fix|full-cycle` chosen independently.

All four combinations of the two axes are valid. `direct` is the default planning mode. A promotion trigger changes only `executionPath` to `full-cycle`; by itself it does not require OpenSpec.

The developer does not pick `ai_rules_1c` roles; the agent chooses its internal specialization from the task.

Each leaf repeats the readiness rule (fresh passed `/itl-check`, `exportPath`/`extensionsPath`, `testsPath`, branch-safety on `master`), so it is self-contained.

## Running actions

The active client's ITL surface runs the branch lifecycle; `/itl` shows the exact commands, skills or prompts of the current client (Codex, for example, uses `$itl-check`). Commands below use the slash form. `update-dev-branch-base` and `verify-dev-branch` run through the compact runner `run-itl-command.ps1`; `vibecoding1c-mcp-*` actions run directly through `agent-1c.ps1 -Action` (`references/mcp.md`):

```text
/itl-status                     Show the branch, infobase and verification status.
/itl-check                      Load the branch changes into its infobase and run the selected checks.
/itl-refresh                    Update the branch with fresh master.
/itl-sync-master                Update master and force-recreate the latest-only seed.
/itl-refresh-lite               Update the branch from the current master without source or seed access.
/itl-result                     Export CF/CFE of the current branch.
update-dev-branch-base          Helper action: load the branch changes without tests.
verify-dev-branch               Helper action: compatible alias of check-dev-branch (/itl-check).
vibecoding1c-mcp-status         Helper action: show vibecoding1c MCP of the current scope; also -setup, -start, -select, -refresh-registry.
```

In the `native` mode upstream OpenSpec runs through separate commands, for example in Kilo Code:

```text
/opsx-propose                   Usual first step: proposal, design/tasks/spec deltas and verifiable scenarios; a separate test-plan only when needed; no code changes.
/opsx-apply                     Implement the agreed OpenSpec change by tasks.md.
/opsx-archive                   Archive the OpenSpec change after acceptance.
/opsx-explore                   Optional: research the task or code before a proposal when context is insufficient.
```

`/itl` detects the mode from the managed manifest and shows the active client's syntax. In the `natural` mode the user writes ordinary requests (user-facing examples, keep in Russian):

```text
Исследуй задачу в режиме OpenSpec, не создавая proposal и не меняя код
Подготовь OpenSpec proposal для <изменение>; создай proposal, design, tasks и spec deltas; отдельный test-plan только если нужен; код не меняй
Реализуй согласованный OpenSpec change <change-id> по tasks.md и утверждённым проверкам
Заархивируй принятый OpenSpec change <change-id> и синхронизируй specs
```

Both modes use one `openspec/` workspace, a shared preflight and a fresh `/itl-check`. A missing external `openspec` executable does not block the natural flow. Do not install the package automatically and do not run `openspec update`.

`/itl` in a development branch is a process panel, not only a command list: branch state, recommended next step, development path, the real native OpenSpec entrypoints or exact natural requests, and additional helper actions. In a fresh clean branch with `verification missing`, choose the upstream execution path `quick-fix|full-cycle` and the planning mode `direct|OpenSpec` independently; `direct` stays the default. Run `/itl-check` once verifiable changes exist or when the previous check is stale/failed/unknown.

In the worktree of the current `itldev/*` branch `vibecoding1c-mcp-setup` connects the selected vibecoding1c MCP endpoints. When a local branch scope is selected for `code` or `graph`, the helper starts a separate vibecoding1c MCP for the current branch. MCP servers of sibling branches are not added to the client config. Vanessa UI MCP is available separately as the pre-registered stdio server `itl-vanessa-ui`; it starts its private backend on the first call without a helper action or raw HTTP.

## Pending extension branch

Usually the agent collects the parameters on master and the helper runs a separate transactional initialization within extension-branch creation. When the parameters were unknown at creation, the branch stays `pending`: on first access ask whether to create an empty extension or load a CFE, get the name and, when needed, the CFE path, then call the internal action yourself:

```text
init-dev-branch-extension -ExtensionInitMode Empty -ExtensionName <extension-name>
init-dev-branch-extension -ExtensionInitMode Cfe -ExtensionName <extension-name> -ExtensionSourcePath <file.cfe>
```

These lines are an internal helper contract, not developer commands. The helper snapshots the infobase, loads the extension through Designer with `-Extension`, dumps normalized sources strictly into `src/cfe/<extension-name>` and rolls the infobase back on error. The CFE is not unpacked; Designer Agent and `AgentMode` are not used. `set-dev-branch-extension` only records the recovery context of a manually created extension; `dump-dev-branch-extension` remains a recovery dump. Until the status is `ready` every development action is blocked. After that `/update1cbase` is the ordinary development cycle, `/itl-check` the required check and `/itl-result` the `CFE` export.

A configuration branch may hold several features. An extension branch may also hold several features/OpenSpec changes, but all of them belong to one extension. For a second CFE create a separate branch, worktree and infobase copy: the workflow deliberately keeps no `extensions[]`. A changed second root `src/cfe/<OtherName>` blocks update/check/dump/result/close with `EXTENSION_BRANCH_SINGLE_ARTIFACT`; unchanged baseline directories do not interfere.

## Bridges and Enterprise update

Lifecycle commands activate the branch infobase context for `ai_rules_1c` automatically.

`/deploy-and-test` remains a bridge to the same `check-dev-branch`; it has no load path of its own. The ordinary ITL cycle name is `/itl-check`. To load the base without tests use `update-dev-branch-base`.

After a real file load, `/itl-check`, `update-dev-branch-base`, `verify-dev-branch`, `/itl-refresh`, `/itl-result` and advanced `close-dev-branch` automatically launch the branch infobase in Enterprise user mode through the bundled `ДляАвтоматическогоОбновленияИБ.epf`. This applies update handlers and answers the legal-copy prompt non-interactively. No-op updates do not launch Enterprise.

## Large OpenSpec changes

Large OpenSpec changes use the hybrid cadence: each slice with observable behavior gets sufficient current proof and the applicable targeted/static checks; a retained regression is added separately when useful for future runs. An intermediate `/itl-check` is needed at a milestone whose runtime result decides further implementation. Preparatory tasks are recorded as pending verification. After the last verification-relevant edit an ordinary unfiltered `/itl-check` assesses the whole applicable obligation set and reuses fresh proof.

## Choosing the mode

First apply upstream `AGENTS.md` and `verification-policy.md` without downstream overrides. Use **quick-fix** when all of these hold:

- the problem is understood;
- the change is local;
- one module is touched, or a new completely unwired metadata addition explicitly allowed by the upstream policy;
- the business process does not change;
- the public interface of modules does not change;
- there is no upstream promotion trigger;
- no agreement on architecture or approach is needed.

Quick-fix examples: fix a syntax error, a condition or a variable name; remove a crash in a specific procedure; add a simple `Неопределено` check; fix a message text; adjust a query without changing its business meaning.

Use **direct full-cycle** when quick-fix does not apply but the boundaries, the solution and the acceptance criteria are clear, for example:

- a change of an existing form or wired metadata;
- a transactional, write/posting or RLS path with an already defined expected result;
- several related places with an unambiguous implementation;
- a public contract whose requirements are already agreed.

Use **OpenSpec** when the user explicitly asks for it or requirements, architecture, acceptance criteria or implementation stages need formal research and agreement. A promotion trigger changes only the execution path and a regression risk strengthens the checks; neither by itself requires OpenSpec. When unsure between direct and OpenSpec, weigh the need for agreement, not the number of files.

After choosing, open exactly one matching reference from the list at the top of this file. Do not read the other paths "just in case".

## Short reminder

```text
Small local fault, no promotion triggers, no OpenSpec -> direct quick-fix -> dev-branch-quick-fix.md.
Clear change of an existing form, related metadata, several modules or a risk-bearing path -> direct full-cycle -> dev-branch-direct.md.
Requirements, architecture or acceptance criteria need formal research or agreement -> planningMode OpenSpec; execution path chosen independently -> dev-branch-openspec.md.
After changes run the single check cycle: /itl-check. To load the base without tests: update-dev-branch-base.
If a previous change may have missed a relevant scenario or the full check cycle, use /itl-verify-fix: it first looks for suitable existing coverage, does not create a new test without need, then fixes the test or the implementation and repeats the full check within one helper-owned repair session.
After three failed repairs without progress on the same obstacle, perform systemic diagnosis before another full run (verification-result.md).
CF/CFE of the current branch: /itl-result.
```
