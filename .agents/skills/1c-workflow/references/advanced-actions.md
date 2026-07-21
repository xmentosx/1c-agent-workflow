# Advanced Helper Actions

This reference is for diagnostics, recovery, and automation. Do not show this full list as the beginner command surface.

Run helper actions from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

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
prepare-vanessa-authoring
complete-vanessa-authoring
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
new-dev-branch
new-extension-dev-branch
configure-dev-branch-unsafe-action-protection
init-dev-branch-extension
set-dev-branch-extension
dump-dev-branch-extension
activate-dev-branch-context
update-dev-branch-base
run-dev-branch-tests
stop-dev-branch-test-clients
check-dev-branch
verify-dev-branch
refresh-dev-branch
export-dev-branch-result
close-dev-branch
switch-master
switch-dev-branch
list-dev-branches
status
release-e2e-snapshot
release-e2e-restore
release-e2e-config-roundtrip
release-e2e-extension-smoke
```

Extension helper actions are advanced/helper commands. `new-extension-dev-branch` normally collects and performs extension initialization as its second internal phase. If parameters are unknown, it records `pending`; on first entry the agent collects them in chat and invokes `init-dev-branch-extension` internally. Never expose that PowerShell invocation or generate a visible initialization slash command. Keep recovery-only `set-dev-branch-extension`/`dump-dev-branch-extension` available through helper actions or natural-language requests. `set-dev-branch-extension` records context only and never creates an extension. New development branches register `itl-roctup-data` and `itl-vanessa-ui`; their backend processes are private on-demand runtime, not helper actions.

`get-dev-workspace-plan` and `adopt-dev-worktree` are an internal pair used only by the managed OpenCode project plugin. The first performs a read-only native-workspace preflight; the second accepts the exact new `itldev/*` worktree created by OpenCode. `get-dev-workspace-close-plan` and `set-dev-workspace-deregistration` coordinate provider-aware close after the ordinary ITL verification/export gates have completed. They never migrate legacy development branches and must not be invoked as user-facing slash commands.

`configure-dev-branch-unsafe-action-protection` is an interactive recovery action for an existing development worktree when branch creation used `skip` before protection was actually disabled. Run it through `run-agent-1c-window.ps1`, optionally passing `-InfoBaseUser <name>` for an empty-password local user. It forces the normal visible Designer confirmation flow and records confirmation in branch state; it never disables protection automatically.

`stop-dev-branch-test-clients` stops only Vanessa `TESTMANAGER`/`TESTCLIENT` processes whose command line belongs to the current development branch infobase/worktree, then fails if any remain. Successful Vanessa verification performs the same cleanup automatically. It never stops foreign worktree test processes.

`release-e2e-config-roundtrip` is reserved for `scripts/invoke-release-e2e.ps1`. It dumps the dedicated branch infobase into ignored local state, writes evidence under ignored `build/test-results`, and proves that a root `Configuration.xml` `Comment` loaded in strict `Partial` mode roundtrips while `Ext/ParentConfigurations.bin` is present. Do not expose it as a slash command or use it for ordinary project work.

`release-e2e-snapshot` and `release-e2e-restore` are internal checkpoint actions for the same runner. They accept only a project-local ignored `.dt`; restore invalidates both configuration and extension fingerprints. Do not expose them as slash commands or use them as a general backup interface.

`release-e2e-extension-smoke` is also reserved for the Release runner. It uses the public extension initialization lifecycle to create an Empty extension, produce and reload a CFE, validate both normalized dumps, and restore the disposable infobase and worktree from a snapshot. It is not a project command and must not have a slash wrapper.

ROCTUP and Vanessa dependencies are cached by init/update. Agents call the stable `itl-roctup-data` and `itl-vanessa-ui` servers; private backends start on first use, stop on idle/client exit, and appear in general `status`/`doctor` diagnostics.

`context-benchmark` is a Kilo-only read-only diagnostic exposed through natural-language requests such as "measure context" or "замерь контекст"; it has no slash command. `-BenchmarkMode run` requires an explicit `-BenchmarkModel provider/model` and `-ConfirmTokenSpend`, then creates one fixed no-tool `OK` request through the Kilo CLI. `analyze` reads one real IDE session by `-BenchmarkSessionId`; `compare` accepts session ids or saved summaries through `-BenchmarkBaseline` and `-BenchmarkCandidate`. Summaries under ignored `.agent-1c/diagnostics/context-benchmark/` contain counters and provenance only, never transcript text, tool arguments, URLs, or secrets.

To measure Browser Automation, switch it manually in Kilo Settings, reload Kilo, create a fresh one-message session with `ITL_CONTEXT_BENCHMARK_V1: Reply with only OK. Do not call tools.`, analyze it with a `browser-off` or `browser-on` label, and repeat for the other state. Compare only the resulting compatible summaries. ITL reports the setting but never changes it. CLI `run` measures project rules and normal MCP configuration; it does not include the extension-only Browser Automation service.

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

`update-workflow` refreshes the installed ITL workflow package in an already initialized project. It must run from the `master` worktree. The pre-copy phase checks master/clean state, copies only managed workflow files (never root `AGENTS.md`), records `workflowPackage`, then always starts the installed helper in a fresh PowerShell process with internal `post-copy`; only that new process updates rules, MCP, the active client's generated command surface, and final checks. Generated client surfaces stay local and ignored. Projects whose old updater predates this re-exec contract need a one-time double run: the first installs it, the second guarantees all post-copy work runs on it. Later updates need one run. A client may still display primary-checkout master commands in linked worktrees; `/itl` lists inherited actions separately as invalid, while direct master actions fail before mutation.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
