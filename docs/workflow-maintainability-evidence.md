# Workflow maintainability implementation evidence

This source-only record implements the evidence waves from
`workflow-maintainability-implementation-plan.md`. It is a bounded snapshot of
the repository at base commit
`7bccc2691833ff12b2d10e53e8ad959682c4dd3a`; it is not installed into projects
and is not release qualification.

## Platform audit

The inventory used targeted searches for user/machine storage, Windows services
and firewall operations, registry and scheduled-task writes, native OS APIs,
PowerShell hosts, process ownership, port allocation, bootstrap, lifecycle,
on-demand MCP, verification, remote execution, and source delivery. The finding
classes are:

1. ordinary non-elevated behavior already compliant;
2. optional administrator provisioning already isolated;
3. optional capability that reports unavailable truthfully;
4. concrete compatibility defect needing a separate owner-local change;
5. unresolved evidence gap needing a disposable real-host check.

| Surface | Current implementation evidence | Class | Consequence |
|---|---|---:|---|
| Bootstrap and normal lifecycle | The installer writes the target project, unique user temporary directories, and project/user-local state. It launches Windows PowerShell without `RunAs`; no normal entrypoint changes a service, firewall, scheduled task, HKLM, or machine `PATH`. | 1 | No elevation prerequisite was found in the normal bootstrap/init/update/refresh routes. |
| Immutable tools and MCP state | Workflow dependencies, on-demand binaries, UI tools, host keys, and vibecoding1c state resolve below `%LOCALAPPDATA%` or an explicit writable override. Project runtime remains below `.agent-1c`. | 1 | These paths are per-user and do not depend on write access to program directories. |
| Temporary files | The core helper probes writable `%TEMP%`, `%TMP%`, user-profile/local-app-data alternatives, then a project-local fallback and fails if none is writable. Source-delivery fixtures use unique GUID paths. | 1 | Simultaneous sessions do not share fixed temporary filenames. |
| 1C installation discovery | `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` are discovery/read locations. The workflow tells the user to install 1C manually when absent. | 3 | Platform installation is an external prerequisite, not an implicit administrative action. |
| Remote Python worker | The pinned runtime is acquired into a user-local cache without registry, `PATH`, pip, NuGet-client, or `conf.cfg` changes. | 1 | Worker preparation without `-EnableSsh` is non-elevated. |
| Optional SSH provisioning | `Prepare-RemoteHost.ps1 -EnableSsh` checks the Administrator role before adding the Windows capability, configuring/starting `sshd`, and adding the firewall rule. Inspection does not make those changes. | 2 | SSH provisioning remains explicit and does not block exchange transport or unrelated local work. |
| Port coordination | `agent-1c.ports.ps1` owns one machine/user registry contract. Machine scope uses `%ProgramData%` or `ITL_PORT_REGISTRY_HOME`; an unwritable location fails with shared-root guidance. User scope warns that cross-user isolation is best effort. | 1, 5 | Semantics are truthful; writable-root and simultaneous cross-user behavior still need Server 2019 terminal-host proof. |
| Infobase admission | The existing database coordinator defaults to `%ProgramData%\ITL\infobase-access` or uses `ITL_INFOBASE_ACCESS_ROOT`/project configuration. Exact resources, foreign ownership, and recovery stay with that coordinator. | 1, 5 | No shadow coordinator was found. Default/shared-root ACL behavior needs the same real terminal-host proof. |
| Process discovery and cleanup | Workflow-owned launches record PID, start time, operation/resource identity, native journal evidence, or job/process-tree ownership before cleanup. Foreign or ambiguous work is not force-released. | 1, 5 | Static owner contracts are present; two-session cleanup isolation remains unverified on a terminal server. |
| Compact installed runner | The job-list process owner checks `RtlGetVersion` and requires Windows 10 or Windows Server 2016+, then starts Windows PowerShell 5.1. | 1 | The native API floor includes the public Windows 10/11/Server 2019+ support set. |
| Source delivery | The source-only supervisor uses the same Windows 10/Server 2016+ atomic process boundary. It is not copied into installed projects. | 1 | This maintainer path does not narrow installed support. |
| PowerShell and encoding | Installed entrypoints deliberately target Windows PowerShell 5.1; strict UTF-8/AST checks and the release decode probe cover the compatibility boundary. PowerShell Core callers reset incompatible module paths before invoking 5.1. | 1 | Parsing/encoding proof is necessary but is not evidence for every Windows version. |
| Registry and scheduled tasks | The bounded source search found no normal workflow writes to HKLM and no scheduled-task installation. | 1 | No hidden machine-state prerequisite was found. |

No category-4 defect was proven by this static audit. The two category-5 items
must not be relabelled as passed or used to narrow support. If real-host evidence
shows the default shared roots cannot meet the standard-user contract, that is
a separate port-registry or database-admission owner change with its own
reproducer and tests, not a documentation workaround.

### Compatibility evidence matrix

| Required release evidence | State for this source change | Evidence or next action |
|---|---|---|
| Standard-user Windows 10 | Unverified | Run the ordinary installed bootstrap/status path on a disposable Windows 10 host at release qualification. |
| Standard-user Windows 11 | Partial, not release-qualified | The audit host reported Windows 11 Home `10.0.26200`, non-elevated, PowerShell Core 7.6.5. Focused source tests exercise the Windows PowerShell boundary, but no fresh installed-project lifecycle was run. |
| Standard-user Windows Server 2019 terminal session | Unverified | Use a disposable Server 2019 terminal host and the ordinary installed path. |
| Two simultaneous standard-user terminal sessions | Unverified | Required when shared port/runtime coordination changes; verify distinct users, shared roots, ports, owner-safe cleanup, and no credential/path crossover. |
| Optional administrator provisioning | Not applicable | SSH/service/firewall behavior did not change; do not spend or request an administrator token for this governance change. |

Unknown stands remain `unverified`. Documentation and PowerShell 5.1 tests do
not substitute for release-host evidence.

## Client-context baseline

All sizes below are serialized UTF-8 bytes from tracked package artifacts or
deterministically rendered client surfaces. `ceil(bytes/4)` is labelled a proxy,
not an exact model token count. The measurement reads files and renders existing
templates; it does not launch 1C, capture transcripts, store tool arguments or
URLs, or call a model.

### Source and installed routers

| Surface | Loading boundary | Bytes at snapshot | Approximate-token proxy |
|---|---|---:|---:|
| Root `AGENTS.md` before this change | Source-maintainer only; never installed | 8,406 | 2,102 |
| Root `AGENTS.md` after this change | Source-maintainer only; never installed | 9,268 | 2,317 |
| `templates/AGENTS.append.md` | Small installed bridge where needed | 673 | 169 |
| `templates/USER-RULES.append.md` | Installed always-on ITL overlay | 7,018 | 1,755 |
| `1c-workflow/SKILL.md` | Detailed router, activated on demand | 6,445 | 1,612 |
| `1c-workflow-fast/SKILL.md` | Routine router, activated on demand | 6,371 | 1,593 |

The governance change adds 862 bytes, 215 approximate-token proxy units, and 100
words to the source-only root. Installed surfaces have zero delta. The installed
`USER-RULES` limit stays at 850 words and 1,850 proxy units. Detailed lifecycle
topics remain behind `1c-workflow/references/workflow.md`, and that index routes
to one matching topic rather than loading every reference.

### Deterministically rendered command surfaces

These totals include every generated file available in the named branch surface
for one active client. They are installed inventory, not a claim that every
client injects every command body into each request.

| Client | Master files / bytes / proxy | Development files / bytes / proxy |
|---|---:|---:|
| Codex | 20 / 30,965 / 7,742 | 28 / 49,898 / 12,475 |
| Kilo Code | 10 / 29,995 / 7,499 | 14 / 48,608 / 12,152 |
| Claude Code | 10 / 29,865 / 7,467 | 14 / 48,426 / 12,107 |
| Cursor | 10 / 29,865 / 7,467 | 14 / 48,426 / 12,107 |
| OpenCode | 11 / 40,868 / 10,217 | 15 / 61,888 / 15,472 |
| Kimi Code | 10 / 30,080 / 7,520 | 14 / 48,693 / 12,174 |
| Qwen Code | 10 / 29,865 / 7,467 | 14 / 48,426 / 12,107 |
| Command Code | 10 / 29,865 / 7,467 | 14 / 48,426 / 12,107 |
| Cline | 10 / 30,080 / 7,520 | 14 / 48,693 / 12,174 |
| Pi | 10 / 29,865 / 7,467 | 14 / 48,426 / 12,107 |

The 19 source templates total 39,264 bytes; the largest is
`itl-sync-branches.md.template` at 4,455 bytes. Client differences are produced
by existing adapter frontmatter, Codex metadata, Kilo/OpenCode routing, and the
OpenCode workspace plugin. Growth in these surfaces is checked only when their
owners change.

### MCP and result surfaces

The on-demand MCP client sees exactly three tools per family:
`resolve_tool`, `call_tool`, and `finish_database_access`. Serializing the actual
Go SDK tool definitions as `{"tools":[...]}` produces 2,105 bytes for ROCTUP
and 2,117 bytes for Vanessa UI. The internal real catalogs remain behind the
facade: 13 tools / 90,805 bytes for ROCTUP and 38 tools / 110,132 bytes for
Vanessa UI. Those internal bytes are compatibility data, not always-on client
schema cost.

The compact routine runner already caps its returned JSON at 4,000 characters,
moves oversized reports to an artifact, and retains the complete status/log as
the owner. Blocker, recovery, and result variants share that same cap. Existing
tests exercise successful, failed, blocker, and omitted-report shapes.

Kilo's existing `context-benchmark` can record real client token counters for a
fixed no-tool prompt, but `run` intentionally requires `ConfirmTokenSpend`.
This source change did not spend model tokens merely to refresh a proxy baseline.
Clients without exact telemetry remain proxy-qualified, never token-qualified.

### Incremental policy and opportunities

`ParserDocsBudgets.Tests.ps1` owns the stable document and rendered-command
ceilings. A change that grows an always-on or generated surface must show its
before/after delta and update the explicit ceiling with a rationale. Reductions
remain valid without padding back to the snapshot. Source code changes outside
these surfaces incur no new context step.

The audit found no safety text that should be deleted. The useful routing
boundaries are already present: the root file is source-only; generated routines
run without preloading a router; detailed references load one at a time; backend
MCP catalogs remain behind three compact facade tools; and long result prose is
moved to artifacts. Browser Automation remains the known optional Kilo surface
that can materially increase tool/context cost and is already reported to the
user. Future work should remove demonstrated duplication, not compress these
safety boundaries telegraphically.

## Architecture decision scenarios

| Scenario | Classification | Reason |
|---|---|---|
| Two local tasks use one remote infobase through the same remote owner | Normal architecture work | The existing owner may serialize its exact resource without acquiring workflow-wide authority. |
| ROCTUP, Vanessa, lifecycle, and measurement contend for one exact infobase | Normal with current admission; checkpoint if modes/resources/recovery expand | Database admission is already the authoritative cross-owner contract. |
| Several callers need the same quoting or path-normalization invariant | Normal architecture work | Converge on one stateless helper instead of copying policy. |
| On-demand source mode consumes current database admission | Normal architecture work | The current plan forbids a second lock and releases admission before independent branch work. |
| Recovery adds a persisted resource, action, adapter, or interception point | Architecture checkpoint | It widens durable cross-owner recovery authority. |
| A fix bounds timeout, cancellation, logs, or error classification inside current authority | Normal architecture work | It narrows existing owner behavior without another state machine. |
| Terminal-server users need exact shared port coordination | Normal inside the existing registry contract; checkpoint for ACL/service/elevation or weaker isolation | The registry is the owner, while privilege or support changes cross the compatibility boundary. |
| A client adds a large always-on catalog or repeated routine prose | Architecture checkpoint when material growth cannot be routed on demand | It changes the installed client-context compatibility budget. |

This table permits shared architecture where the invariant is genuinely shared,
while preventing both call-site patchwork and unproved workflow-wide authority.
