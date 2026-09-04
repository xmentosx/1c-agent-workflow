# Advanced Helper Actions

This reference is for diagnostics, recovery, and automation. Do not show this full list as the beginner command surface.

Run supported agent-facing executable actions from the project root through the compact runner; this includes both `/itl-verify-fix` repair calls:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -- -Action <compact-action>
```

When bounded JSON sets `userReportOmitted=true`, the complete report remains available through the full absolute `userReportPath`. Read only that path: use the file contents directly for `userReportSource=file`, or only its `userReport` JSON property for `userReportSource=status-json`. Return the recovered report verbatim. Transport omission never changes the helper's semantic status and never authorizes repeating a completed mutation.

Use direct `agent-1c.ps1` only for actions that the compact runner intentionally does not expose, including short read-only actions and explicitly documented internal diagnostics.

Mutating actions are serialized per worktree through the ignored lifecycle operation lock. Concurrent ordinary operations in separate development worktrees are allowed; actions that also mutate master acquire both scopes. On `LIFECYCLE_OPERATION_CONFLICT`, use `status`, `doctor`, or `help` and wait for or diagnose the recorded PID/phase. Do not delete lock files or edit operation JSON. Status remains observable during active work and removes proven-stale on-demand leases only when it can immediately take lifecycle then runtime locks without disturbing the active operation record.

Common internal actions:

```text
init-project
validate
check-tools
list-platforms
detect-web-publication
detect-apache
configure-web-publication
publish-dev-branch
install-vanessa-automation
install-yaxunit
install-agent-browser
install-windows-mcp
install-ui-tools
ui-tools-status
begin-verification-repair
vibecoding1c-mcp-setup
vibecoding1c-mcp-update
vibecoding1c-mcp-status
vibecoding1c-mcp-start
vibecoding1c-mcp-stop
vibecoding1c-mcp-select
vibecoding1c-mcp-refresh-registry
vibecoding1c-mcp-rotate-keys
vibecoding1c-mcp-ensure-model
vibecoding1c-mcp-write-client-config
context-benchmark
update-workflow
update-ai-rules
doctor
itl-litemode
itl-repository-mode
itl-switch-client
update1cbase
loadfrom1cbase
getconfigfiles
deploy-and-test
sync-master
get-dev-workspace-plan
get-dev-workspace-close-plan
set-dev-workspace-deregistration
adopt-dev-worktree
initialize-dev-branch-runtime
new-dev-branch
new-extension-dev-branch
fork-dev-branch
sync-dev-branches
configure-dev-branch-unsafe-action-protection
init-dev-branch-extension
set-dev-branch-extension
dump-dev-branch-extension
activate-dev-branch-context
update-dev-branch-base
cleanup-interrupted-vanessa-run
stop-dev-branch-test-clients
start-vanessa-profile
status-vanessa-profile
stop-vanessa-profile
check-dev-branch
verify-dev-branch
refresh-dev-branch
refresh-dev-branch-lite
refresh-all-dev-branches
reset-dev-branch
lock-config-repository-objects
export-dev-branch-result
close-dev-branch
switch-master
switch-dev-branch
list-dev-branches
status
configure-auxiliary-contour
status-auxiliary-contours
update-auxiliary-contour
dump-auxiliary-contour
check-auxiliary-contour
export-auxiliary-contour-result
reset-auxiliary-contour
release-e2e-snapshot
release-e2e-restore
release-e2e-prepare-ondemand
release-e2e-config-roundtrip
release-e2e-config-repository-lock-roundtrip
release-e2e-extension-smoke
```

Additional contours are optional advanced topology, not new routine slash commands. Route their agent-led questionnaire, configuration, safety modes, tests, CF, extensions, and MCP to `auxiliary-contours.md`; never tell the user to edit workflow files. Every mutating contour action requires an exact contour name; there is no implicit active-contour switch.

Extension helper actions are advanced/helper commands. `new-extension-dev-branch` normally collects and performs extension initialization as its second internal phase. If parameters are unknown, it records `pending`; on first entry the agent collects them in chat and invokes `init-dev-branch-extension` internally. Never expose that PowerShell invocation or generate a visible initialization slash command. Keep recovery-only `set-dev-branch-extension`/`dump-dev-branch-extension` available through helper actions or natural-language requests. `set-dev-branch-extension` records context only and never creates an extension. New development branches register `itl-roctup-data` and `itl-vanessa-ui`; their backend processes are private on-demand runtime, not helper actions.

`get-dev-workspace-plan` and `adopt-dev-worktree` are an internal pair used only by the managed OpenCode project plugin. The first performs a read-only native-workspace preflight; the second accepts the exact new `itldev/*` worktree created by OpenCode. `get-dev-workspace-close-plan` and `set-dev-workspace-deregistration` coordinate provider-aware close after the ordinary ITL verification/export gates have completed. They never migrate legacy development branches and must not be invoked as user-facing slash commands.

`configure-dev-branch-unsafe-action-protection` is an interactive recovery action for an existing development worktree when branch creation used `skip` before protection was actually disabled. Run it through `run-agent-1c-window.ps1`, optionally passing `-InfoBaseUser <name>` for an empty-password local user. It forces the normal visible Designer confirmation flow and records confirmation in branch state; it never disables protection automatically.

`stop-dev-branch-test-clients` stops only the Vanessa `TESTMANAGER` in the current worktree's service infobase and `TESTCLIENT` processes in its development infobase, then fails if any remain. Successful Vanessa verification performs the same cleanup automatically. It never stops foreign worktree test processes.

`cleanup-interrupted-vanessa-run` is private to the monitored `run-itl-command.ps1` parent after its exact child helper exits without terminal status. It requires matching lifecycle-owned infobase, `VAParams.json`, and TestClient ports, never falls back to branch-wide cleanup, and must not be invoked manually.

`Run-DevBranchTests` is a private phase of `check-dev-branch`, not a helper action. Automated performance profiling repeats canonical `check-dev-branch` with `VanessaFeaturePath` and/or `VanessaFilterTags`; filtered runs remain diagnostic-only and do not create full proof. When configuration sources are unchanged, the fingerprint preflight skips Designer, but canonical ownership, cleanup, event-log, and evidence preflight still add overhead. Finish with an unfiltered canonical check.

Manual profiling uses a separate interactive lifecycle:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-vanessa-profile -VanessaFeaturePath .\tests\features\Example.feature
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action status-vanessa-profile
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action stop-vanessa-profile
```

`start-vanessa-profile` opens exactly one ownership-proven branch-local `TESTMANAGER -> TESTCLIENT` pair, positively proves the manager connection, and opens the specified `.feature` without `StartFeaturePlayer` or `run_scenario`. The pair stays open until `stop-vanessa-profile`. Start/reuse/status return `ITL_VANESSA_PROFILE_REPORT` with safe PID, port, infobase, feature, and connection fields only; they do not create JUnit or verification verdicts. `stop-vanessa-profile` delegates to the shared branch-safe Vanessa runtime release primitive and is idempotent. These actions are manual diagnostics, not `/itl-check` or release-gate substitutes.

`release-e2e-config-roundtrip` is reserved for `scripts/invoke-release-e2e.ps1`. It dumps the dedicated branch infobase into ignored local state, writes evidence under ignored `build/test-results`, and proves that a root `Configuration.xml` `Comment` loaded in strict `Partial` mode roundtrips while `Ext/ParentConfigurations.bin` is present. Do not expose it as a slash command or use it for ordinary project work.

`release-e2e-config-repository-lock-roundtrip` is reserved for the same runner and a disposable test repository. It locks and then releases only the mapped objects from one XML object list; it is never exposed as a project command.

`release-e2e-snapshot` and `release-e2e-restore` are internal checkpoint actions for the same runner. They accept only a project-local ignored `.dt`; restore invalidates both configuration and extension fingerprints. Do not expose them as slash commands or use them as a general backup interface.

`release-e2e-prepare-ondemand` is reserved for the same runner. It requires fresh dependency mode, synchronizes the dedicated branch worktree to the workflow-pinned Vanessa Automation and facade locks, and installs the exact SHA-verified artifacts before live on-demand probes.

`release-e2e-extension-smoke` is also reserved for the Release runner. It uses the public extension initialization lifecycle to create an Empty extension, produce and reload a CFE, validate both normalized dumps, and restore the disposable infobase and worktree from a snapshot. It is not a project command and must not have a slash wrapper.

ROCTUP and Vanessa dependencies are cached by init/update. Agents call the stable `itl-roctup-data` and `itl-vanessa-ui` servers; private backends start on first use, stop on idle/client exit, and appear in general `status`/`doctor` diagnostics.

`context-benchmark` is a Kilo-only read-only diagnostic exposed through natural-language requests such as "measure context" or "замерь контекст"; it has no slash command. `-BenchmarkMode run` requires an explicit `-BenchmarkModel provider/model` and `-ConfirmTokenSpend`, then creates one fixed no-tool `OK` request through the Kilo CLI. `analyze` reads one real IDE session by `-BenchmarkSessionId`; `compare` accepts session ids or saved summaries through `-BenchmarkBaseline` and `-BenchmarkCandidate`. Summaries under ignored `.agent-1c/diagnostics/context-benchmark/` contain counters and provenance only, never transcript text, tool arguments, URLs, or secrets.

To measure Browser Automation, switch it manually in Kilo Settings, reload Kilo, create a fresh one-message session with `ITL_CONTEXT_BENCHMARK_V1: Reply with only OK. Do not call tools.`, analyze it with a `browser-off` or `browser-on` label, and repeat for the other state. Compare only the resulting compatible summaries. ITL reports the setting but never changes it. When it is enabled, recommend disabling its hidden Playwright MCP and using workflow `agent-browser`; show `install-agent-browser` when missing. CLI `run` measures project rules and normal MCP configuration; it does not include the extension-only Browser Automation service.

UI tool actions install the exact lock versions and reconcile direct `stdio` entries owned by `ui-tools`. They preserve foreign same-name entries, do not use the on-demand facade or ITL port registry, and never create a desktop lock. `ui-tools-status` reports `configured`, `external`, `missing`, or `degraded`; configured is not a runtime-health claim.

vibecoding1c MCP actions (`vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`) are exposed through helper actions or natural-language requests. They manage remote LAN registry discovery, per-server remote/local selection, private vibecoding1c MCP distribution, local key rotation, embedding model bootstrap, port allocation, Docker containers, and managed MCP entries for the single active client. Setup applies saved selection and runs selection first when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` for an explicit reselect. Remote is the default provider; config-specific remote vibecoding1c MCP always needs an explicit per-server `configId`, and `code`/`graph` selections do not inherit `configId` or `hostId` from each other. Local `code`/`graph` can be selected for project or branch scope. Vanessa UI MCP is managed separately by the on-demand facade and is always branch-local.

In the short `/itl` panel, show advanced/helper actions only as grouped additional capabilities, not as visible slash commands:

```text
ROCTUP data: itl-roctup-data on-demand facade and status diagnostics
vibecoding1c MCP: setup/status/select/refresh-registry/update
Vanessa UI MCP: itl-vanessa-ui on-demand facade and status diagnostics
Extension branches: initialize extension; set/dump are recovery actions
Maintenance/recovery: update base without tests, update workflow/rules, close/list/switch branches
```

`update-ai-rules` refreshes files from the configured `ai_rules_1c` source with `-McpMode delegated`. A configured immutable `aiRules.ref` remains pinned in both `fresh` and `locked`; the controlled fork never consumes `main`. The installer preserves client MCP entries while idempotently ensuring Kilo loads `USER-RULES.md`; ITL owns the only transactional MCP reconcile when ready vibecoding1c replacements exist. It records the resolved commit in `.agent-1c/dependency-lock.json` and reapplies the ITL overlay in `USER-RULES.md`. If selection/state is incomplete, existing MCP entries are preserved. It does not normally append to `AGENTS.md` when the configured `AGENTS.md` already points to `USER-RULES.md`.

`doctor` is read-only and reports the exact-one client, pinned provenance, five ITL skills, mode values, and master/dev state. `itl-litemode` atomically controls only the two ITL verification keys. `itl-switch-client` owns clean-master guards, snapshot, model reset, pinned adapter replacement, rollback, and reload guidance.

`update1cbase`, `loadfrom1cbase`, `getconfigfiles`, and `deploy-and-test` are the implementations behind the four upstream-visible bridges. They reconcile state, prove the branch infobase, refuse source/master execution, and retain rollback evidence for dumps.

`update-workflow` refreshes the installed ITL workflow package in an already initialized project. It can be invoked from `master` or an active `itldev/*` worktree. The compact runner resolves the checked-out `master` worktree before starting the mutating helper, so the clean-state check, managed copies, and local updater commit still apply only to `master`; the invoking development branch is neither switched nor modified. The pre-copy phase copies only managed workflow files (never root `AGENTS.md`), records `workflowPackage`, then always starts the installed helper in a fresh PowerShell process with internal `post-copy`; only that new process updates rules, MCP, the active client's generated command surface for `master`, and final checks. Generated client surfaces stay local and ignored. After success, refresh every affected development branch through `/itl-refresh` or `/itl-refresh-lite`. For Kilo, `status` and `doctor` report the installed `1c-workflow-fast` contract/SHA; the actually cached skill is not observable through a Kilo API. If behavior still follows an older route, perform `/reload` before diagnosing a workflow source defect. ITL never inspects or deletes Kilo's internal cache/hidden worktrees. Projects whose old updater predates this re-exec contract need a one-time double run: the first installs it, the second guarantees all post-copy work runs on it. Later updates need one run.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
