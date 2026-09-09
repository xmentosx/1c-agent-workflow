# Measurement and workflow reliability implementation ledger

This source-maintenance plan records seventeen tasks from the original seven PM5
investigations and the follow-up handoffs. It is not installed-project guidance. A completed
source change, registration, publication, installation and live acceptance are
different milestones; none implies the next one.

## Required contracts

- Measure an existing database without requiring its configuration to match a
  development checkout. Measurement does not authorize configuration updates,
  extension installation or data writes.
- Decide whether source-level analysis is necessary. Reuse matching modules or
  capture the target database configuration and relevant extensions separately
  from the working tree. Match actual packet identities and versions, not just
  the database address. Preserve raw packets for later mapping.
- Coordinate access by database identity across projects, branches, chats and
  execution hosts. Hold ownership through preparation, the complete series,
  necessary source capture, restoration and cleanup. Queue time is not timing.
- Nested processes inherit ownership. A crash or network interruption does not
  authorize replay or assuming that surviving database work has stopped.
- Uncoordinated external sessions remain observable limitations; never stop
  foreign processes. Distinct databases may execute concurrently.

## Work and acceptance

| ID | Priority | Deliverable | Required acceptance | Current evidence |
|---|---|---|---|---|
| 1 | P0 | Include file-base ServerEmulation and validate profile coverage | Real client/server packets; missing family partial; foreign packet rejected | Source implementation and retained real-packet analysis verified; installation and new live capture pending |
| 2 | P0 | Phase-specific deadlines propagated through engine, adapter and MCP | Action beyond 300 seconds; cancellation; bounded hang; large branch6 calculation | Source implementation and isolated engine/stdio/HTTP tests pass; exact component delivery and long live calculation remain open |
| 3 | P1 | Native module mapping and on-demand target source capture | Different database/checkout configurations; matching, partial and missing sources; extensions; version drift; unchanged database and working tree | Native binding, target CF/CFE capture and export producer implemented; real scratch-base configuration drift and extension capture verified; selected-module requirements and pinned snapshot reuse implemented; checkout binding production, Designer capacity integration and PM5/UFA acceptance pending |
| 4 | P0 | Shared database admission queue and inherited operation ownership | Two projects/chats/hosts; aliases; FIFO admission; cancellation; owner crash; nested calls; truthful cleanup | Common queue, portable runtime, pinned recovery hooks and native pipe-owner channel implemented; live 1C recovery adapters, lifecycle/facade entrypoint integration and multi-host proof remain required |
| 5 | P1 | Preserve both compatible semantic changes during merge recovery | Reproduce E2 loss; preserve both deltas; justified replacement report and relevant behavioral checks | Pending |
| 6 | P1 | Explicit multi-branch sync result and complete test classification | Three branches, final recipient trees, resumable plan; one non-runtime classification pass through public wrapper | Pending |
| 7 | P1 | Incremental progress, experiment provenance and actionable waiting | Interrupted operation retains stages/settings; queue distinct from execution; user cancellation; no polling a decision blocker forever | Command phase journal, asynchronous MCP progress and partial diagnostic collection implemented; full scenario provenance and detailed runtime stages remain open |
| 8 | P1 | Diagnose and correct ambiguous owned debugger client on UFA | Retained discovery/launch evidence; exact own session among foreign clients; real remote short capture | Pending |
| 9 | P2 | Correct row selection for column captions containing spaces | Cyrillic plus spaces, multiple criteria, no match; owning backend delivery | Pending |
| 10 | P2 | Reliable client-code channel and diagnosed clipboard failures | Busy clipboard, explicit completion/errors, no duplicate replay, isolated files/cleanup; shared supported route | Pending |
| 11 | P2 | Correct release snapshot ownership and cleanup | Retention respected; old ledger handled through helper; foreign paths remain protected | Shared cleanup now accepts actual current/legacy producer layouts, protects active/retained records sharing a filename, and reconciles obsolete generations after verified deletion; 32 ledger/cleanup tests pass; five real debt records checked read-only; normal delivered-supervisor cleanup remains pending |
| 12 | P1 | Make absent/empty command-handler diagnostics advisory and prevent unsolicited dummy handlers | Notify the user without blocking refresh/check or requiring agent repair; preserve genuine structural errors; deliver the validator and agent-guidance correction through their owners; verify real project updates without dummy handlers or the local workaround | Source correction prepared in controlled fork r34; workflow exposes warnings without repair/failure; 9 validator and 10 lifecycle cases pass, five actual branch11 forms retain 14 advisory actions and unchanged sources; normal delivery/install and full branch11 acceptance remain open |
| 13 | P1 | Distinguish accepted master changes from branch-owned changes when selecting tests | Imported master selects the existing acceptance set without invented tests/owners; own unknown changes still require classification; mixed dirty trees, CF/CFE, deletion/rename and Git failures covered | Shared selector now records pinned accepted-master provenance for CF/CFE and keeps unknown own paths blocking; 37 regressions pass including the permanent 13-path case; actual branch11 paths recognized read-only with unchanged index/proof; 6c577e9 registered successfully; delivery and installed full check pending |
| 14 | P0 | Remove export/ROCTUP mutual waiting and complete the official artifact | Check then read-only ROCTUP query then unchanged-config export completes with verified CF/CFE and manifest; nested ownership, foreign sessions, failure/cancellation and preserved fresh proof covered | Shared standalone DumpCfg completion correction implemented; 45 Designer/export regressions pass, including public manifest and fresh-proof failures; real CF/CFE exports with an open technical file-base client pass; delivered facade/PM5, competing chats and server acceptance remain open |
| 15 | P1 | Resolve unsupported AI-review responses and demonstrably false blocking findings through an evidence-based decision | Original response and exact validation unit retained; every finding resolved or explicitly open; bounded recovery for non-analysis responses; no fabricated clean pass, harmful appeasement edits or repeated calls for a green answer | Shared evidence/decision policy prepared in r35; fork Full passes 99 tests and actual installation preserves the rule for ten clients; exact branch11 findings, case-based acceptance and normal workflow delivery remain open |
| 16 | P1 | Report every repository-lock outcome, including partial failure | Every requested object has a proven captured/already-owned/conflict/absent/unknown disposition; conflicts name repository owners; full report survives failed status and compact-output limits | Named branch11 log confirms 24 captured objects, one conflict and four absent objects; helper throws before producing the partial report; implementation pending |
| 17 | P1 | Lock the configuration root for new top-level metadata objects | Root added once for top-level additions, without recursive whole-configuration capture; no root for new forms/attributes of existing objects; committed/dirty/untracked input and root conflicts covered | Transfer planner currently skips Configuration.xml and has no root dependency for top-level additions; implementation and native repository qualification pending |

Implementation order: establish item 4 with the timeout and source-capture
contracts and resolve the concrete export deadlock in item 14; complete items
1-3; then 5-8, 12, the accepted-master selection contract in 13 and AI-review
adjudication in 15, followed by 9-11. Items 13-15 have their own acceptance below;
linking them to related tasks does not remove them from the plan. Each coherent source change
gets directly owned checks, a local commit and RegisterChange. Publication and
live installation/acceptance must be recorded explicitly, using normal helpers.
Investigations close only with an implemented correction or evidence explaining
why no workflow change is appropriate; an unresolved hypothesis stays open.

## Item 11: release snapshot cleanup implementation and remaining acceptance

The current E2E producer writes `baseline.dt` and `post-config.dt` below its run
root, but the cleanup owner only recognized older filename-prefixed snapshots.
Four producer-path regressions reproduced the rejection before the correction.
The shared resource cleanup now accepts the current
`.agent-1c/runs/release-e2e/<run>/snapshots/` layout, the resumable legacy
`.agent-1c/release-e2e-runs/<run>/snapshots/` layout, and the older
`.agent-1c/snapshots/` filename contract. Tests execute the producer's actual path
assignments and `Set-E2ERunPaths`, so a future producer change must remain aligned.

Two further regressions reproduced unsafe deletion when an old pending record
shared a filename and SHA with another retained or active snapshot record.
Such records now protect their path until their ownership is released or the
existing retention policy expires. The policy remains the two newest failed
plans for at most seven days; a future `retainUntil` on a `cleanup-pending`
successful/evicted resource does not itself mean it remains retained.

SHA checks, active-process and tracked-drift guards remain required. Unknown
paths/names and reparse points below the owned worktree are rejected without
deleting files. After a matching pending owner removes a snapshot, obsolete
records for that now-missing filename are reconciled in the same sweep. A stale
SHA alone never authorizes deleting a new or unidentified generation.

All 25 ledger tests plus seven cleanup integration tests pass (32/32), including
the original culture/retention cases, current and legacy layouts, foreign paths,
junction redirection, changed SHA, active/dirty worktrees, retained ownership,
expiration and same-pass reconciliation. Paths contain spaces and Cyrillic
together. Read-only examination of five real debt records accepts their layouts:
three match current file hashes, while two refer to older generations of a reused
filename. Evidence is in the snapshot-cleanup source worktree under
`build/diagnostics/release-snapshot-cleanup/qualification.json`.

Remaining acceptance: register/deliver the correction and execute normal
`source-delivery.ps1 -Action Cleanup` with a stable supervisor that contains it.
The entrypoint currently selects the supervisor from `origin/master`, so a local
source correction alone does not replace the executing cleanup implementation.
No real snapshot or shared ledger entry was manually removed or rewritten during
this work. Actual debt retirement and unchanged retained/foreign resources must
be verified after the normal delivered helper sweep.

## Added task 12: advisory command-handler diagnostics and agent behavior

Source: [Валидатор форм: пустой Action блокирует…](codex://threads/01a085aa-b4b8-75d2-a92e-acd4725b2d8d),
with `D:/Git/PM5 КОРП - Codex - 1-branch11/handoffs/handoff-20260909-local-form-validator.md`.
The handoff reports that form-validate v1.8 Check8 classified missing/empty
command Action as an error and blocked preparation on five forms/14 commands.
It cites the platform's disabled-command behavior when no handler exists. This
must be verified against the relevant platform documentation and current owner
implementation; the installed workaround is evidence, not the upstream source.

The user's additional requirement covers the agent's reaction as well as the
validator: missing/empty command handlers must be reported to the user as
non-blocking advice. They must not fail preparation, refresh, verification or
completion merely because that diagnostic remains, and must not enter a
mandatory repair loop. This category does not authorize creating empty BSL
handler procedures, adding dummy Action bindings, removing commands, or other
business-source changes solely to silence the warning. Implementing a command's
behavior belongs to a separately requested functional change. The priority P1
above is the priority of fixing workflow behavior, not the diagnostic severity.

1. Reproduce absent, empty and whitespace Action plus a valid bound command;
   distinguish an unspecified Action from an existing procedure with an empty
   body. Inspect actual update cases in the referenced PM5 projects, beginning
   with the five retained forms/14 commands, and verify the platform contract.
2. Locate the actual validator in the controlled `itl_ai_rules_1c` fork and its
   current pin. If the defect persists, fix its diagnostic severity there on the
   prescribed upgrade/release branch. Do not add dummy business handlers, remove
   business commands, disable source-integrity or patch another installed copy.
3. Trace warning propagation through workflow/helper output and agent rules.
   Correct the owning guidance so the agent reports the form/command and the
   advisory nature of the finding, continues authorized work, and does not
   invent a mandatory fix or a confirmation request just for this warning.
   A warning must remain advisory through every wrapper and completion check.
4. Preserve regressions for genuinely invalid event-handler bindings (separate
   from this command-handler category), duplicate command IDs,
   invalid callType and malformed XML. Reuse the retained 13-case reproducer as
   evidence, verifying its actual scope before adopting it upstream.
5. Deliver the owning fork correction and workflow pin through normal intake;
   remove only the now-redundant local workaround through managed update.
6. Qualify branch11 refresh and the complete check on the delivered version.
   Retain a regression with the command handler still empty: the warning is
   visible, no gate fails because of it, and no dummy handler or Action binding
   is added to product sources. Check agent-facing guidance for the same behavior.
   The task reports local Vanessa 49/49, YAxUnit 118/118 and validator 13/13;
   those results do not establish upstream delivery or installed-candidate proof.

Related follow-ups from the same task remain tracked under item 6: verify the
documented classification action against compact-runner dispatch, exact-HEAD
resume behavior, and why four nested Vanessa scenarios disappeared in the
combined run despite passing separately (3/3 and 1/1). Later aggregate success
does not prove that the runtime cause was corrected. Each needs reproduction,
an owning-layer fix if confirmed, and a regression preserving combined nesting.

### Item 6 follow-ups: explicit implementation and acceptance

Rechecked against all available messages in task
`01a085aa-b4b8-75d2-a92e-acd4725b2d8d`, including its fourth handoff. These
subtasks remain independently open; completing master-input selection in item 13
does not close them.

**6a — Public classification command, P1.** The installed documentation tells
the agent to run `run-itl-command.ps1 -Action validate-test-classification`, but
that compact runner rejects the action while the underlying helper supports it.
Reproduce with the reported installed version and compare current entrypoint
validation, dispatch and generated references. Select one supported public route,
implement missing dispatch or correct the owning documentation, and keep this
classification-only action read-only: it must not start 1C, run business tests or
manufacture verification proof. Acceptance: the exact documented command works
in an installed project, reports ready/missing-suite/unowned-path distinctly,
preserves tracked files and proof, and remains covered by an entrypoint/dispatch
contract regression. Do not work around the defect by disabling classification.

The source reproducer confirms that the compact runner rejects this action before
dispatch, including both successful and failed classification results. The public
allowlist now accepts the existing helper action; the reference spells out the
exact compact invocation. Three process-boundary cases preserve ready,
missing-catalog and missing-owner diagnostics, exit codes, and an existing proof
file in a path containing Cyrillic and spaces. They invoke the real runner,
helper and classification owner against isolated project catalogs, and preserve
the original feature bytes. No classification or verification policy is loosened. Registration and
the installed-project public command acceptance must still be recorded.

The first registration gate exposed an exit-path failure in the unchanged
lifecycle cancellation reproducer: cancelled JSON was emitted, but the process
returned `0x80131029` instead of 2. The CLR names this code
[`HOST_E_EXITPROCESS_TIMEOUT`](https://github.com/dotnet/coreclr/blob/v2.0.0/src/inc/corerror.xml).
That observation alone does not prove the particular shutdown race. Extending
the same real-runner reproducer established a deterministic defect:
`Environment.Exit` prevents the calling script's finally block from executing.
The runner now returns with PowerShell `exit`, retaining its result code and
allowing caller cleanup. All ten lifecycle waiting tests pass with the added
finally assertion; no holder, lock, cancellation assertion or timeout was weakened.

**6b — Missing nested scenarios in a combined Vanessa run, P1.** The handoff
reports 49 expected scenarios but only 45 loaded, despite both nested feature
files being present in `FeaturesToRun` and execution-features. Separate runs
passed 3/3 and 1/1. Moving the two unchanged files into the root restored the
49-scenario aggregate; that is a local workaround, not proof that nested loading
works. Preserve the original nested layout in the reproducer. Inspect selection,
staging and the pinned Vanessa tree/filter behavior to establish the owning layer;
the reported loss of directory nodes with retained levels is a hypothesis to test.
Fix the confirmed owner or qualify a supported dependency update through its
normal delivery route. Acceptance: the original combined nested layout loads and
executes all 49 expected scenarios exactly once, including paths with spaces and
Cyrillic together. Compare expected and actual scenario identities, not only
counts; omitted or duplicated scenarios cannot produce a passing complete-suite
result. Retain focused regressions for multiple nesting levels and mixed root /
nested files. Moving fixtures to the root or lowering the expected count is not
an acceptable correction.

**6c — Resume after a corrective descendant commit, P1 investigation.** After
the local validator correction was committed, ordinary resume rejected a changed
HEAD with `LIFECYCLE_MERGE_POST_HEAD_MISMATCH`. The task reports taking the
documented corrective-descendant/check route. The exact-HEAD guard itself is not
established as defective. Reproduce that transition and verify that the helper's
diagnostic and agent-facing reference identify the supported next action. If the
route is already correct, close this investigation with concrete evidence; if
routing or recovery is broken, fix that owner and retain a regression. Acceptance:
the legitimate descendant resumes through the prescribed helper and fresh check,
while an unrelated HEAD or mismatched operation remains rejected. No manual
lifecycle edits, lock removal or weakening of exact-tree proof is permitted.

The remaining messages are covered separately: empty command actions by item 12,
accepted master inputs by item 13, export/ROCTUP coordination by item 14, and
unsupported or disputed AI findings by item 15. Local successful checks and
export recovery are evidence for those incidents, not automatic closure of their
shared implementation and delivered acceptance.

## Starting source and evidence

- Source baseline: `2d390d654a6dbcbaf72b4097f0e209d55b2b8582`.
- Worktree: `codex/workflow-measurement-reliability`.
- Existing fixes for tooling generations, primary YAxUnit errors, facade-owned
  TestClient startup, pending refresh recovery and delivery timestamps already
  exist in the baseline. Do not repeat their implementation.
- Named live acceptance routes: local PM5 branch4/branch10 profiles, branch6
  long calculation, and authorized UFA/private Tabakov remote capture. Inspect
  current owners and installed state before operating any route.

## Implementation evidence

Item 4 first source slice implements a filesystem coordinator with ordered,
atomic resource-set admission, explicit alias registration, inherited ownership,
cancellation, crash distinction and portable-engine integration. Focused tests
exercise separate processes and the real fixture engine, not live 1C/SMB. The
public result distinguishes execution-host-only and configured authority scope.
Lifecycle/facade integration, supported recovery and actual multi-host proof
remain open. No installed project or target database has been changed.

Local verification: `python -X utf8 -m unittest discover -s
tests/python/remote_work -v` passed 69/69, including 21 admission/integration
cases. These are separate-process and fixture-engine checks on Windows; they
are not evidence of real two-host SMB admission or 1C runtime qualification.

Item 1 source slice includes ServerEmulation, requires the correct families for
each base kind, retains incomplete profile artifacts and exposes coverage in the
engine verdict. Discovery rejects duplicate owned IDs and foreign identities;
uncertain attach attempts receive cleanup, whose failures reach cleanupErrors.
Eleven focused profile tests passed, including engine-level partial/error paths.
Fixtures derive from retained 8.3.27.2074 branch4 packets with native identities;
their provenance records original hashes. Offline analysis of the full originals
found both families: client 37 modules/4299 lines, server emulation 63 modules/
11421 lines. Client-only input remains incomplete. This verifies retained real
data analysis, not a new live capture with the delivered collector.

Items 2/7 next source slice introduces per-phase timeout overrides, inherited
execution-host deadlines, independent cleanup, cancellation without replay, and
truthful facade shutdown errors. Python engine/adapter tests pass 87/87; the Go
component suite and reproducible build pass. A retained deadline after simulated
301-second elapsed time verifies removal of the Python default cap; this is not
a real 16-23-minute 1C run. Go request metadata propagates the remaining budget
through HTTP and broker startup without the earlier 10/5-minute caps. Version
0.4.10 is a local candidate until exact Release E2E and component publication.

The full Go suite exposed a pre-existing progress evidence race: go-sdk v1.6.1
dispatches notification handlers asynchronously relative to request responses.
A completed response therefore cannot guarantee those handlers already updated
the final counter. Successful forwarding now gets a separate correlated event;
the completion counter is explicitly a snapshot. The prior transport assertion
is retained against events, with an additional deterministic regression that
holds one notification until after two completed calls reusing a caller token.
Both calls retain isolated evidence. The two progress tests passed 25 repeated
runs; no notification delay or guessed sleep is added to the runtime.

Items 2/7 registered as `0e3f771079b3b4d44e498d9fb69196dd571e36ea` after
Targeted passed. Version fixture mismatches were corrected without changing the
old-version rejection, exact-hash or backend ownership assertions. Publication,
installation and long-running live acceptance remain separate open milestones.

Item 3 first source slice adds native identity/version bindings, byte hashes,
line-range validation, manifest-relative paths and explicit optional/required
source analysis. Fourteen focused tests use retained native packet shapes and
synthetic UTF-8/CRLF sources to exercise matching and mismatch behavior. This is
an analyzer contract, not proof of a source capture from a real database. The
authoritative manifest producer and read-only target capture are implemented in
the next slice below; full end-to-end acceptance remains required.

Item 3 next slice adds an explicit optional/required scenario source policy and
the inherited-lease capture phase. Fixed Designer operations read the database
configuration plus its extensions, then load/export only in an owned scratch
base. Native object versions and module properties produce the source bindings;
unmatched or ambiguous exports stay unresolved. Process cleanup failures retain
the database admission, and raw profile coverage survives source-analysis failure.
Python checks passed 114/114 and the owned Pester file passed 7/7 before the final
progress/cleanup diagnostics addition; registration verifies the final tree.

Real source-capture qualification on 8.3.27.2074 used an isolated technical base
under `build/diagnostics/source-capture-live/Снимок базы b34fa6d8357e42749523c17e8e66adac`.
Its database module returns `database`, while a fresh export of its editable
Designer module returns `designer-only`. Capture preserved the database version,
exported the YAXUNIT extension and removed its extraction scratch base without
cleanup errors. `qualification.json` records the exact paths and hashes; snapshot
`93cbd9ee41a1450582170e517ceb8930` retains the nine successful native steps.
This is live configuration/export evidence on an owned fixture, not a new PM5
measurement or proof of snapshot reuse. The first extension fixture lacked its
borrowed Russian language; a corrected fixture supplied that dependency. No
runtime assertion or target-capture operation was weakened to qualify it.

The next item 3 slice adds explicit native-module selection to scenarios and the
offline CLI. Missing selections stay unmet; excluded rows remain visible.
Execution-host pinned source manifests are checked before capture, with exact
module versions and byte hashes. Reused sources and their binding evidence are
copied into the new run. Complete selected coverage skips Designer; partial reuse
retains matching modules and captures remaining bindings. Invalid cache entries
are diagnostic and may be repaired by capture. Synthetic/native-packet tests
cover drift, conflicts, source removal, selected scope and engine capture routing.
This does not yet prove PM5/UFA integration or produce checkout bindings without
existing authoritative source evidence.

Items 3/4 capacity integration removes the automatic stop-all-target-sessions
callbacks from on-demand MCP and Vanessa verification. Admission waits outside
the allocator lock, honors cancellation and the original performance deadline,
and retries only a capacity rejection proven to precede any native start attempt.
Impossible requests and uncertain launch results are not retried. Source capture
and portable 1C launch now import the target workspace's `.dev.env` session ceiling.
An exited single-process leader no longer leaves a phantom reservation merely
because its launching PowerShell is alive; promised child reservations remain.

The native fixture at `build/diagnostics/source-capture-live/Ожидание сеанса a1ff903c6a3d48298f1648d166e6347b`
qualified waiting on 8.3.27.2074 with the configured limit of one: client PID 48344
remained alive until the fixture owner stopped it, then Designer PID 35704 ran
`list-extensions` successfully. Its result records 1.324 seconds of admission
wait and no cleanup errors. Native qualification exposed Windows hostname casing
differences between Python/.NET and the stale single-process reservation; both
were corrected without changing the contention workload. A prior diagnostic
log reader also needed file sharing while redirect output remained open.
Failed technical-run access records remain retained for supported coordinator
recovery; none was edited to retry the measurement. This is session-capacity
evidence, not the still-required multi-host operation-queue qualification or
automatic quiescence of an operation's persistent client when no slot exists.
The prior Vanessa topology assertion explicitly required stopping every target
base's sessions on capacity failure. The user's shared-base requirement replaces
that behavior with waiting; topology, feature selection and scenario-count
assertions remain, with a ban on that destructive callback and behavioral waiting
regressions plus the native contention qualification above.

Item 4 recovery protocol now provides read-only revisioned inspection and an
exclusive recovery owner for the original complete resource set. Old inherited
tokens and late original-owner releases are fenced; original ownership and
attempt history remain available. A trusted operation adapter must perform live
verification before completion; a success flag or dead process is insufficient.
Incomplete/crashed recovery retains attention, while active recovery preserves
FIFO waiters. Separate-process regressions exercise these coordinator contracts.
This is not live 1C recovery: operation-specific verifiers/restoration adapters,
reconciliation of retained technical-run debts, and multi-host proof remain open.
Focused admission/recovery checks passed 33/33; the owning RemotePerformance
Pester suite passed 8/8, including the complete portable Python suite. The public
inspection command also read retained technical-run ticket
`cbbfb220f6c2418fa12c72721b1c85e3` and reported its cleanup-unproven condition;
it did not claim or release that database.

Item 4 next slice connects the recovery protocol to immutable portable jobs.
Original admission records bind the request and target before execution. Pinned
scenario hooks inspect real state, optionally quiesce owned work, and restore
only after quiescence is proven. Every resource requires fresh correlated
observations and hashed artifacts; a successful command exit alone cannot
release the resource set. Local commands and queued SSH/exchange requests share
the implementation. Recovery status is separate from the unchanged measurement
result, and a completed restoration is inspected before deciding whether another
restoration call is necessary. Recovery-only inherited tokens cannot run normal
measurement jobs.

The native caller channel now uses the same coordinator through private stdio,
with a PowerShell adapter and no second lock algorithm. Separate-process tests
cover portable/native exclusion, complete resource sets, unrelated databases,
inheritance, cancellation, failed cleanup and parent disconnection. A real
PowerShell parent crash closes its pipe host and leaves the original database
reservation for recovery. Tokens are excluded from progress and error messages.
The first PS5.1 execution exposed multiple `Get-Command python` matches being
joined as one executable name; selecting the first application fixes the native
launch without changing the process/Unicode-path test. Invalid inheritance also
exits while stdin is still open, without a buffered-reader finalization failure.

Entrypoint integration remains open. Inspection identified two required ordering
constraints: database admission precedes lifecycle/runtime locks, and persistent
facade stop/idle cleanup uses existing ownership rather than queuing behind an
operation waiting for that backend to close. The complete initial resource set
must include a pinned newly generated Vanessa manager base when one is needed.
These are requirements of item 4, not optional follow-up investigations.

The service-base producer now separates read-only planning from creation.
`Get-VanessaServiceInfoBasePlan` selects a qualified existing manager or pins a
new generation and its resource path. `Ensure-VanessaServiceInfoBase` accepts
that admission plan and revalidates the relevant state, marker, database presence
and currently verified template before any 1C call. It rejects changed inputs,
redirected paths and a new-generation path occupied during the wait. It never
executes template paths supplied by the serialized plan. Existing callers use
the same planner internally; moving their initial planning before global
admission remains part of the lifecycle/facade integration.

All 31 Vanessa Designer Agent tests passed, including eight new admission-plan
cases. A real pipe-owner queue reserves target plus manager atomically and a
real blocked wait changes an input before admission; creation is rejected before
the mocked native boundary. Native CREATE/Restore calls in these tests are
fixtures, so they are not live 1C qualification. Qualified reuse, unchanged state
during planning, missing database, occupied path, template replacement and
malformed plans are covered with paths containing spaces and Cyrillic together.

Entrypoint integration is in development in the database-entrypoints checkout.
The Go private-pipe client in `tools/itl-ondemand-mcp/database_access*.go` now
shares the Python coordinator and has focused process-boundary checks. The
production PowerShell broker now exposes the read-only complete-resource plan
and accepts a private, context-scoped proof from Go children. With that explicit
context it revalidates actual resources through a native inherited pipe host
before taking the start lock or dispatching an operation. Ensure/recover pass a
freshly checked, pinned manager plan through `Ensure-VanessaMcpInstalled`;
stop uses recorded runtime connections without planning a new manager. A
single-instance context cannot authorize stop-all. Target, manager generation or
template drift is rejected before native work; the same manager becoming
qualified for reuse after our own creation is accepted with its fresh input hash.
No process-global proof override is used for concurrent Go broker calls.

Sixteen planning/admission Pester cases pass, including native inherited
ownership and missing/replaced runtime cleanup cases. A Go-to-PowerShell-to-Python process-boundary regression reaches
the simulated 1C launch only under a live parent and rejects the same proof after
release; the private token is absent from returned diagnostics. All Go tests and
nine Python pipe-host regressions passed. Before the latest runtime integration,
full OnDemandMcp Pester reported 61/63:
the changed executable does not match the old candidate hash, and the identical
source-build install case consequently attempts a download and fails. The build
pin must be updated with the completed component, not by weakening these checks.
This WIP is not registered, published or qualified as installed facade exclusion.

The pipe protocol's new `validate` control rechecks inherited fencing/outer-owner
liveness before another call. `runtime.callNamed` now acquires cancellable
per-backend serialization, global database ownership, then the runtime read lock.
Standalone ownership survives the tool response and idle period; idle/stop
inherits that same owner and releases only after broker cleanup succeeds. A
regular inherited call closes its backend before returning control. Cached calls
recheck target, manager/template and resource scope before using their existing
connection. Private `itlDatabaseAccess` metadata is consumed locally and removed
before forwarding to the backend. Process environment is not overridden globally.

Eight runtime integration tests use real Python owners and an HTTP MCP backend
with a simulated native 1C boundary. They cover two projects on one base,
unrelated-base concurrency, cancellation while another call is active, inherited
cleanup/private metadata, failed stop followed by confirmed retry, missing runtime
state, cached-target drift, the explicit outer-owned interactive lifetime, and a
Windows exclusive runtime writer. No waiting caller acquires a local runtime lock
before global admission. The latest full Go suite passed; the directly affected
Pester group passes 16/16. These are source/process-boundary results, not live 1C
or installed component qualification.

The broker retains cleanup uncertainty when its caller's native state is missing
or incomplete. A known PID/port must also match the caller's recorded process
start time before strict stop. Recovery attempts track both the original and
replacement instance; absence alone never clears pending native work. Durable
confirmed-cleanup evidence for internal recovery/pre-launch failure paths still
needs completion so a proven no-work failure does not manufacture recovery debt.

Standalone manual profile ownership now has a source implementation. A hidden
Windows owner process holds the coordinator reservation after the launching
helper exits; generation-scoped open/stop requests cannot replay an interrupted
open. Stop cancels only the accepted request, waits for its completion, then
performs strict native cleanup before releasing the reservation. A failed stop
keeps ownership and permits an explicit stop retry. A crashed owner retains
recovery debt and cannot silently restart native work. Status checks native PID,
creation time and executable identity. Public control files contain no private
lease proof. The PowerShell profile marker routes stop/status to this owner;
legacy profiles retain their original lifecycle route.

Native subprocess tests cover launcher exit, reservation exclusion, normal stop,
exact-process owner crash, scoped cancellation, failed cleanup and request replay.
A separate qualification crossed two actual Codex command invocations: the
launcher command completed, the owner remained alive and excluded a competing
reservation, then a second command stopped it and reacquired the database.
Evidence is retained in the integration worktree at
`build/diagnostics/profile-owner/Ручной профиль через завершение команды/qualification.json`.
It explicitly records `native1C=false`: real Windows/Python process ownership is
proven; the 1C boundary is simulated. The final-response reader also handles the
race where normal stop persists its response and exits between the client's
initial file read and process inspection. Missing final evidence remains an error.
The full Go suite at that stage passed (18.2 seconds); the manual-profile Pester
file and database-admission Pester group each passed 16/16.

The explicit `stop-dev-branch-test-clients` entrypoint now delegates an existing
manual profile stop to its owner before database admission and local locks. It
then reserves its target, recorded service base and matching runtime managers;
unrelated runtime databases are excluded and no new service base is created.
After local lock acquisition, it rechecks the resource set and live reservation
before invoking the existing strict cleanup. Successful cleanup releases the
reservation; an admission/precondition failure with no native work also releases
it, while an unconfirmed native stop retains recovery debt. A live inherited
reservation is validated and remains owned by its parent after nested cleanup.
Shared coordinator settings are used by this entrypoint and the facade planner.

Eight new cleanup-admission tests use the actual Python pipe owner with a
simulated native stop boundary. They cover exclusion before local locking,
recorded-resource selection, manager drift, failed cleanup, owner-mediated stop
ordering/failure, inherited ownership and entrypoint ordering. The three directly
affected cleanup/profile Pester files pass 38/38; the facade admission group
passes 16/16. This is not yet installed/real-1C cleanup qualification.

Manual-profile reuse is now bound to a caller ID in configuration, public owner
state and every mutating control request. Codex defaults to `CODEX_THREAD_ID`;
non-chat use supports explicit `-VanessaProfileOwnerId` or a newly generated
session ID returned in the report. An unidentified caller never adopts another
session's ID from branch state. A different caller waits before opening; foreign
open/stop/cancel requests are rejected by both client and owner. Cancellation of
that wait does not stop the active pair. After confirmed cleanup and process exit,
the waiting caller can start its own owner generation. Reports preserve the old
start time only for reuse of the same generation and caller.

A native two-launcher regression now starts two caller processes against one
branch concurrently and proves feature preservation plus admission of the second
caller after normal stop of the first. It exposed Windows sharing/access races
on control files. Control-file reads/atomic rename now retry only bounded native
sharing/access conflicts; owner lifetime locks are never stolen and native open
requests are not replayed. Process inspection retries transient access denial but
never treats denial itself as proof of exit. A losing startup waits for the
verified other owner rather than reclaiming its native pair. The final full Go
suite passes (22.1 seconds); the current profile and cleanup-admission Pester files
pass 26/26. The two-launcher test uses actual Windows processes and Python leases
with simulated 1C; installed two-chat/real-1C acceptance remains pending.

Remaining integration before registration/delivery:

- Complete per-action lifecycle resource planning and admission before its local
  locks, including service and scratch bases. Do not reserve unrelated bases.
- Integrate the persistent manual owner with branch-wide cleanup invoked by
  verification preflight and lifecycle admission. These paths still have
  legacy writer-lock/stop sequencing and must not stop an owner's native clients
  behind its reservation or hold a writer lock while asking it to stop. Preserve
  standalone manual use and qualify its actual 1C windows before delivery.
- Qualify caller-bound manual-profile waiting with two actual chats and real 1C,
  including installed non-chat owner-ID propagation and observable wait progress.
- Integrate full-resource planning and native cleanup with composed measurement
  owners; distinguish confirmed pre-launch failure from an interrupted launch.
- Qualify installed Python/runtime availability, update the finished component's
  version/build pin, run its owned registration checks, and retain exact real
  Release E2E proof for both backend families before publishing its asset.
- Complete live 1C recovery observations, PM5/UFA and multi-host qualification.

This remains an unregistered integration WIP and is not a completed global gate.

Persistent backend lifetime must be included in admission: returning a tool
response alone does not free a database held by an idle backend. Calls on one
backend require cancellable serialization; idle/stop uses its existing owner.
An inherited facade backend must be stopped before returning control to the
outer operation unless an explicit outer-lifetime cleanup contract owns it.
This prevents a cached backend from outliving a released measurement lease.
Actual 1C recovery observations and multi-host qualification remain required.

Focused tests use SQLite changes and separate processes, including a killed
Windows recovery owner after the restoration commit. They verify one original
action, no repeated restoration after that crash, honest failed-measurement
status, cancellation, bounded hangs, missing/tampered evidence and changed input
rejection. Initial fixture failures exposed unclosed SQLite connections in the
test harness; explicit closing fixed teardown without weakening the workload or
assertions. Real 1C/Vanessa recovery adapters, legacy technical-run reconciliation
and two-host live proof remain open. Partial-artifact collection is implemented
as described below; it does not replace recovery or quiescence evidence.
Focused recovery checks passed 28/28 and the owning RemotePerformance suite
passed 8/8 (including the portable Python inventory). The queued transport path
was additionally exercised through the public `worker --once` command: one
restoration, one original action, and no action on duplicate request delivery.

Item 7 now supports explicit `collect --allow-partial` on local and remote
routes. Without a result it returns a diagnostic manifest, retaining the observed
job state even when an engine crash left it as `running`. It never manufactures
result.json, changes job state, replays work or releases a database lease.
Each downloaded file is hash verified, including the inventoried prefix of an
appending log; replaced/truncated bytes fail without a completed manifest.
Private recovery contexts stay excluded, and output cannot overwrite previous
evidence or write into the exchange spool. Focused regressions reproduce an
actual subprocess crash without a result and exercise local, exchange and CLI
RPC collection with paths containing spaces and Cyrillic together. Full remote
host acceptance and scenario provenance remain separate open requirements.
All twelve focused collection regressions and the owning RemotePerformance
suite passed (8/8, including the complete portable Python inventory). Missing or
unreadable job state is recorded as unavailable without hiding available logs.

Item 12 source correction is prepared as controlled fork
`itl-main-410951e7-r34@ed2a1e3b44ace1e359d922adfcb70c3dfb874f3b`.
The schema-3 reconstruction verifies all 195 decisions; the fork Full gate
passed 99/99 on its clean committed tree. The workflow lock remains `pending`
until ordinary delivery qualifies and promotes it. No remote fork ref was
published by this preparation.

The validator, managed-form router, verification gate and error-fixer agree:
report unassigned command Action to the user and continue; no mandatory repair,
dummy handlers, automatic binding or command removal. The host helper exposes
form warnings with their source path even under `WarningPreference=Stop`, while
retaining the validator exit code for actual structural errors. Ten reset/merge
cases preserve the original staged, unstaged, reverted-index and explicit-repair
topologies, with both advisory commands and genuinely duplicate command IDs.
The former regression's unassigned Action is no longer a valid structural-error
fixture; the duplicate-ID case retains its blocking and path-selection contract.
All 198 lifecycle tests passed on the changed implementation.

The new validator was run read-only against all five retained branch11 forms:
all exited zero and reported the same 14 unassigned command actions. Form and
module hashes stayed unchanged. Evidence is retained under
`build/diagnostics/form-command-advisory/` (`verify.json`, `branch11-forms.json`).
The nine focused validator tests also cover mixed warnings/errors and warning
counts not exhausting MaxErrors. The invalid-callType fixture retains the
extension BaseForm precondition from the original reproducer. Full branch11
refresh/check after managed delivery, including removal of the local workaround,
remains open; current source replay is not installed runtime qualification.
Dependency and migration checks passed 35/35, including r33-to-r34 for all ten
supported clients. Candidate preparation initially changed unrelated dependency
statuses and retained revision 33 in the migration fixture; both were corrected
without changing eligibility assertions or the protected user-modified cases.

## Added task 13: accepted master input in verification selection

Source: the updated [Валидатор форм: пустой Action блокирует…](codex://threads/01a085aa-b4b8-75d2-a92e-acd4725b2d8d)
and `D:/Git/PM5 КОРП - Codex - 1-branch11/handoffs/handoff-20260909-verification-master-input.md`.

Problem: after accepting master, the next ordinary check compares the effective
tree with the previous verification proof. Thirteen imported master paths have
no owner in this branch's test catalog, so selection stops before 1C starts and
asks for additional tests/classification. The current shared
`New-VerificationSelectionPlan` has this unconditional unowned-path branch and
does not distinguish accepted input from the branch's own implementation.
This is a selection defect, not evidence of a defect in master business logic.

Implementation:

1. Define and record accepted-master provenance using the actual branch ancestry
   and an immutable Git reference. Compare against the effective tree including
   staged and unstaged edits, through the existing temporary-index mechanism;
   never replace or modify the user's index. Do not assume the current master
   tip has already been accepted by the branch.
2. Evaluate every relevant changed path before choosing the plan. Proven imported
   master input may select the full existing acceptance set without requiring
   new tests or invented ownerPaths for that input. A branch-owned unknown path
   still requires classification even when an imported path occurs first. A
   modified imported file must be evaluated as a branch change. Keep malformed
   or incomplete test catalogs rejected and preserve the normal own-change gates.
3. Preserve the distinction between acceptance and explicit profiling suites;
   ordinary checks must not start performance experiments as a fallback. Keep
   the existing Vanessa/YAxUnit layers and incremental/reuse semantics where
   their proofs remain applicable.
4. Report the accepted reference, imported paths, own paths, selected suites and
   reason for full compatibility verification. Passing existing acceptance tests
   proves only that tested behavior remains compatible; it does not establish
   full business correctness or newly authored coverage of all master changes.
5. Generalize the local CF-only correction deliberately. Cover CF and CFE with
   their real source roots, deletions, renames, new files, changes in both diff
   orders, mixed staged/unstaged content, absent/ahead/unrelated master, invalid
   trees and Git errors. Unproven provenance must not grant the imported-input
   exception. Reuse the 13 real paths and the 15-case reproducer; retain prior
   incremental/reuse and catalog-negative regressions.
6. Fix the shared selection owner, update `verification-suite-selection.md`,
   register and deliver normally, then repeat the full branch11 check on the
   delivered helper. Preserve all 38 option values and existing optimization
   regression coverage. Remove only the identified obsolete local workaround
   through the managed update path, preserving unrelated changes.

Evidence: the handoff records Pester 15/15 and successful canonical check
`compact-20260909-163435-297-2d8737a7`: YAxUnit 118/118, Vanessa 49/49, no failures
or skips, and unchanged 38 options. These are reported local results, not shared
delivery proof. Item 6 still owns its separate classification-command dispatch,
exact-HEAD resume and multi-branch convergence checks; they are not closed by
this selector correction.

Shared implementation now resolves one immutable common ancestor from pinned
local master and branch tips. It compares the effective tree against that
accepted commit through the NUL-delimited Git path helper, including configured
extension roots, additions, deletions and rename pairs. A newer master tip is
not assumed accepted. Missing/unrelated master, ambiguous ancestry, malformed
trees and Git errors grant no provenance exception. Modified imports remain
branch-owned. Imported paths trigger complete existing acceptance, while all
delta paths are examined before imported/support/runtime full-suite reasons
can be applied; a different unknown own path still requires classification.
The plan and successful proof retain the accepted reference, commit, both tips
and imported/branch paths. Existing generic first-check/no-proof fallbacks and
catalog prerequisites remain unchanged.

All 24 new Git/contract cases plus 13 existing selection tests passed (37/37).
They cover CF, CFE, configured Cyrillic/spaced extension roots, literal bracketed
paths, additions, deletions, renames, staged/unstaged imports, index-only drift,
own changes before/after imported paths, newer/missing/unrelated master,
ambiguous ancestry, Git errors and mixed support/runtime plus unowned changes.
All real-tree cases verify that the user's index bytes remain unchanged.

Read-only replay against branch11 HEAD
`5aabbffdce1efc34e7ce041597b5ed6401ee1b2b` and master
`9ce64fc77c98a0d5421577fd25a14ed75e781c91` recognized all 13 retained unowned
imported paths and kept the branch-modified optimization form module separate.
The actual index and existing verification proof hashes were unchanged; no 1C
process was started. Evidence is retained in the source selection worktree at
`build/diagnostics/accepted-master/qualification.json`. The same 13 path names
are added to the isolated Git regression without copying business code.
This is source/provenance proof, not a new business check or installed delivery.

## Added task 14: export blocked by its own ROCTUP runtime coordination

Source: the same updated task and
`D:/Git/PM5 КОРП - Codex - 1-branch11/handoffs/handoff-20260909-export-roctup-lock.md`.

Problem: a successful check was followed by a read-only ROCTUP query and ordinary
export. With unchanged configuration the load was skipped; Designer produced a
CF and logged successful completion, but the helper waited for the file infobase
to be released. ROCTUP kept it open, while `close_1c_session` was denied by the
export's exclusive `runtime-mcp.lock`. Thus the waiting export prevented the
session closure needed by its completion condition. No official manifest was
created, so the isolated CF was not a completed export.

Implementation:

1. Reproduce the exact sequence with an active facade backend and skipped load.
   Trace `Export-DevBranchResult`, `Export-DevBranchResultFile`, `Invoke-Designer`
   and its invocation-release probe together with the runtime lease. Preserve
   the distinction between process completion, database availability and artifact
   validity; determine which postcondition this read-only DumpCfg actually needs.
2. Implement the smallest evidence-backed correction: either arrange normal
   shutdown of the operation's owned backend before exclusive export admission,
   or use a justified operation-specific read-only completion condition. Preserve
   authoritative Designer completion, owned-process evidence, log/error checks,
   artifact stability and hashes. File existence or a success log alone is not
   enough. Do not broadly disable database-release checks for mutating operations.
3. Integrate with item 4's database identity and ownership protocol. Required
   nested closure/cleanup inherits the operation lease and must not reacquire
   the same lock. Never bypass the broker/shared lease, remove lock files, or
   stop unrelated 1C sessions. A conflicting owner must have a bounded,
   diagnosable wait/cancel path, with no circular dependency on the waiting job.
4. Add public-path regressions for check/query/export, skipped and actual load,
   active owned and foreign backends, two competing chats, failed Designer,
   incomplete output, cancellation and retry. Cover CF and CFE and retain server
   support; record backend-specific live proof separately rather than inferring
   it from the file-base incident. A forced helper exit remains failed and may
   never manufacture a successful manifest or trigger unproven replay.
5. Preserve fresh verification proof when business sources/runtime inputs have
   not changed. An export-coordination failure alone is not a reason to rerun
   all business tests. Complete normal export with the official manifest and
   matching SHA on a delivered helper, without manual process interruption.

Evidence: the handoff identifies failed export
`compact-20260909-164419-033-22de3835`. Only the exact waiting helper was stopped;
the normal parent recorded failure and completed its lifecycle record. After
normal `close_1c_session`, retry `compact-20260909-164938-375-a2802801` succeeded
with fresh passed, CF and `.cf.manifest.json`. This confirms operational recovery,
not an upstream fix. Historical PIDs from that handoff must not be reused for
future operations. The source correction and its current qualification follow.

The shared `Invoke-Designer` now omits the exclusive file-base release probe only
for the exact standalone `/DumpCfg <file> [-Extension <name>]` shapes used by
CF/CFE export. Owned Designer process completion, exit status, error-log checks
and stable nonempty output remain required. Unknown/combined commands, DumpIB
and mutating operations retain their prior release conditions. This eliminates
the demonstrated circular dependency without a backend close or lock bypass.

The original completion condition failed the CF/CFE regression with an actually
held file handle. After correction, 14 new cases plus all 31 existing Designer
completion cases pass. New public `Export-DevBranchResult` cases use the real
export and manifest producers with a simulated native boundary and skipped load;
they verify hashes and fresh evidence, and reject source drift, lost freshness,
nonzero Designer exit and surviving owned processes without a manifest. Separate
negative cases retain the release requirement for DumpIB and mixed dump/update.

Live technical qualification on platform 8.3.27.2074 created a new file base and
loaded the retained technical configuration plus YAXUNIT extension. With its
guarded thin client alive and holding the base open, real CF and CFE exports each
completed in about 5.9 seconds; actual manifests and hashes matched. The session
limit stayed 3 and only the created client was stopped during cleanup. Evidence:
`build/diagnostics/export-shared-base/Экспорт с открытым клиентом f8f78dfb660043aab85e8658effa2f46/qualification.json`.
These technical manifests truthfully say `warn-unverified`; no PM5 business gate
or live public facade qualification is inferred. An earlier qualification-script
variable collided with the helper's typed Client parameter; that failed run and
the identity-checked cleanup of its own client are retained separately. The
fixture was corrected without modifying product behavior or clearing locks.

Remaining item-14 acceptance: delivered check/query/export through the live
facade, actual-load behavior under coordination, two competing chats, cancellation
and retry ownership, and server-family evidence. Item 4 still owns the broader
cross-project/cross-host database admission contract.

## Added task 15: unsupported AI review and false blocking findings

Source: the fourth handoff in
[Валидатор форм: пустой Action блокирует…](codex://threads/01a085aa-b4b8-75d2-a92e-acd4725b2d8d),
`D:/Git/PM5 КОРП - Codex - 1-branch11/handoffs/handoff-20260909-ai-review-false-positive.md`,
and the retained `release-preparation-20260909-final/ENGINE-REVIEW-RECOVERY.md`
with both raw review responses and `release-static-evidence.json` under
`C:/Users/xment/.codex/visualizations/2026/09/08/01a08088-9d59-75f3-8387-c54fee76082f/`.

Problem: the first review returned only ITS links, without substantive analysis.
One explicitly authorized repeat returned three must-fix recommendations. The
retained rebuttal identifies an inverted parameter-passing claim, an access to
a nonexistent cache field despite an existing guard, and an unconditional
calendar restriction that ignores a separate astronomical-duration path. These
are reported rebuttals to inspect against the exact original validation unit;
they are not a new independent audit of the PM5 engine in this workflow task.
An inherited or out-of-scope risk must be distinguished from a disproven claim.

The current controlled-fork rules require correction plus a clean confirming
response, prohibit repeats on unchanged code, and prescribe documenting the
remaining nondeterministic findings. They do not define how such documentation
can result in a valid acceptance decision. An agent can therefore become stuck
or make an incorrect source edit solely to satisfy an AI recommendation. The
confirmed defect is this missing evidence/decision contract; a defect in the MCP
server implementation or in PM5 business logic is not established by the handoff.

Implementation:

1. Preserve and replay the original evidence without another live validator
   call: validation-unit content/hash, source snapshot, tool identity and call
   parameters, timestamps, raw responses and individual findings. Check each
   rebuttal against the submitted code and relevant primary documentation.
   Record separately: confirmed defect, disproven finding, unsupported claim,
   inherited/out-of-scope risk, and unresolved finding. The last three categories
   must not silently become false positives or accepted changes.
2. Define a result for an unusable response (`unsupported-result`): links alone,
   empty output, wrong scope or missing analysis cannot count as a clean review.
   Specify an explicit bounded recovery allowance and the evidence needed to
   use it, coordinated with the existing per-validator call budget. Record the
   recovery reason and result. Exhaustion remains visibly unverified; do not
   keep requesting the same review until it happens to return green text.
3. Define evidence-based adjudication for an actual finding. Retain the original
   severity and text, exact source references, proof/reproducer, disposition,
   decision authority and rationale. Specify which mechanically verifiable
   contradictions the workflow may resolve autonomously under the new policy;
   ambiguous business semantics or risk acceptance require a concrete decision
   from the authorized user/reviewer. A request to implement a change does not
   itself waive a reported risk, and the tool authoring a finding does not make
   that finding authoritative evidence of a defect.
4. Make the final result distinguish a clean tool response from acceptance with
   adjudicated findings (`adjudicated-false-positive`). Such acceptance requires
   an allowed decision for every blocking finding; any unresolved blocker keeps
   the corresponding gate open. Bind decisions to the validation unit and its
   relevant context; changed inputs invalidate affected decisions. Preserve
   syntax, logic, metadata, runtime and fresh-proof requirements independently.
   Neither passing business tests nor a manually edited proof file substitutes
   for the required AI-review disposition. No business edit is required merely
   to appease a disproven recommendation.
5. Reconcile the canonical retry, verification, final-review and error-fixer
   rules in the controlled `itl_ai_rules_1c` fork on an upgrade/release branch.
   Update the MCP usage reference and all generated rule variants through their
   owners. Where the workflow consumes these results, add structured decision
   evidence and truthful reporting/export eligibility; do not patch an installed
   project or loosen all blocking diagnostics. An MCP-server change is a separate
   conditional subtask only if the retained response contract proves one needed.
6. Add regressions for links-only/empty output, the three retained findings,
   mixed true/false blockers, incomplete rebuttal, inherited risk, missing
   authority, exhausted retry allowance, stale or changed validation units,
   altered raw evidence and actual syntax/runtime failure. Prove that false
   advice cannot force harmful edits and that unresolved or genuine defects
   cannot gain acceptance through this route. Tests must exercise the actual
   evidence consumer where one exists, as well as consistency of the rules.
7. Register and deliver through the normal controlled-fork/workflow process.
   Reassess the retained branch11 evidence using the delivered policy and record
   its actual disposition. Reuse valid syntax/runtime proof where applicable;
   no new runtime run is required solely to interpret an unchanged review.
   This task closes only with consistent delivered rules and acceptance evidence,
   or an explicit evidenced finding that a proposed conditional code change is
   unnecessary. Unresolved review findings remain visible in the plan.

Current evidence: the handoff reports the unchanged engine SHA256
`578DCB5A64DAA5F7BBCE239143A67DEC89B2CE752841761700437CCB1045882B`, standalone
syntax with zero errors, and the existing check
`compact-20260909-163435-297-2d8737a7` (YAxUnit 118/118, Vanessa 49/49). These
results do not establish a clean AI-review pass. Neither product code nor proof
files were changed in that episode; no source correction for item 15 is claimed.

Item 15 source work has now started in the isolated controlled-fork candidate
`D:/Git/itl_ai_rules_1c-r35-review-adjudication`, branch
`upgrade/main-410951e7-r35` (the future immutable release is
`release/itl-main-410951e7-r35`), rebuilt from the unchanged pinned upstream
`410951e74fd3e6b7a763cf49757935b9a34d3f31` using the normal Prepare helper.
The 124 reviewed r34 results were restored only after their ledger text hashes
were verified (including intentional absent paths and UTF-8 BOM decoding).
The tagged r34 stand remains unchanged. The new canonical
`verification-ai-evidence.md` defines evidence preservation, one in-budget
unsupported-result recovery, autonomous mechanical rebuttal versus authorized
risk decisions, freshness and truthful outcomes. Gate, retry, delivery, root and
six agent call sites route to it. The existing four ValidatorExecutionPolicy
tests pass. This is uncommitted work, not a qualified r35 release: complete
conflict/consumer inventory, case-based regressions, original-evidence assessment,
installation coverage, path-ledger hashes, version pins, fork qualification and
normal workflow registration/delivery remain required.

The r35 candidate is now committed at
`228dede770213b627159c60de8c04cdbb9930010` (tree
`7905f33af1978790a79bea10722a2a8b0aab017d`). The normal reconstruction Verify
passed all 197 path decisions. Actual installation/validator-policy tests passed
16/16, and the final fork Full gate passed 99/99 with a clean tree (195193 ms).
The first Full run found only an empty retired opsx directory left by this
checkout's reconstruction; its absence requirement was retained, the confirmed
empty/untracked directory removed, and the complete gate then passed unchanged.
The normal publisher preview passed and created the local immutable r35 refs
without Push; no remote ref was changed. Workflow dependency and migration
tests passed 35/35 against the new pending pin. Registration and delivery remain
separate, as does independent assessment of the original branch11 findings.

The facade/update admission candidate was registered at `6f74741` with 903
passing Targeted tests, no failures/skips and a clean tree (757319 ms; tree
`5c33871b0d64e54c13adbbd8565f7526d9e05d1b`). The shared integration branch
fast-forwarded to it. This is source qualification, not completion of the
remaining per-action, two-chat, real-1C or multi-host requirements in item 4.

## Item 4: exact database scope after source load

The post-load MCP refresh previously stopped every registered backend in the
branch, including auxiliary databases. It now stops only backends for the database
identified by the load result and checks the current branch target against that
recorded identity before cleanup. `Load-ConfigFromFiles` returns the actual kind
and path for both completed and skipped loads; a missing identity cannot turn into
stop-all. This applies to update, source synchronization, refresh and result export
through their existing shared post-load route.

Five focused regressions cover file/server targets, preservation of auxiliary
ROCTUP and Vanessa runtimes, missing identity, changed target and skipped load.
The server case also exposed Windows path parsing of unequal quoted connection
strings; the match helper now returns false for non-file strings rejected by path
APIs, while exact opaque server matches retain their existing behavior. Load-proof
tests verify the identity producer for completed recovery and an unchanged load.

This fixes post-load cleanup scope. It does not by itself complete admission
before lifecycle locks, native-operation cleanup accounting, or real 1C acceptance.

Registered as `0e75c4457fd42b492b9035cfcc01fef3043c98b7` in queue
`workflow-measurement-reliability`; the owning Targeted run passed in 736.695
seconds. An earlier registration attempt stopped at selector validation because
the new test file lacked a quality-contract owner; adding it to `mcp-hosts`
resolved that defect without weakening or skipping the regression. The isolated
registration worktree is clean. The database-integration worktree now uses this
registered commit as its base; its remaining uncommitted changes were preserved.
No publication or installed-project acceptance is claimed for this correction.

## Item 4: native-operation accounting before aggregate release

The shared session launch boundary now supports an aggregate operation journal.
Each nested launch has its own record and becomes pending immediately before the
native start attempt. A capacity or preparation failure before that boundary can
release the aggregate; a thrown launch without a process handle remains uncertain.
Removing a session-capacity reservation or returning from a background launcher
does not confirm that its database work has stopped. The journal retains the
returned process object and distinguishes separate launches even on the same base.

Designer supplies its existing invocation-specific descendant-release evidence
and actual launcher-exit result after completion-probe cleanup. Business failure
can coexist with confirmed native cleanup; a surviving owned process cannot.
Unrelated sessions do not prevent this owned-process proof. A later contradictory
observation withdraws an earlier release confirmation. No aggregate entrypoint is
enabled by this slice alone: update admission, Enterprise completion accounting,
runtime-drain accounting and actual shared-base acceptance remain required.

Nine journal regressions cover prelaunch rejection, uncertain start, background
lifetime, both parts of release proof, contradictory evidence and nested launches.
The retained public CF/CFE export reproducer also asserts journal release on
success/business failure and retained ownership for a surviving Designer process,
while keeping an unrelated database holder open. These use simulated native 1C
boundaries; they do not establish live concurrent database admission.

The next unregistered slice requires owned-process completion for Enterprise
normalization after configuration load. Ordinary Enterprise calls retain their
existing completion contract. The new probe composes with an application probe,
uses the existing bounded native process inventory, and requires a fresh second
empty observation after the quiet interval, not merely a cached empty result.
A delayed descendant therefore keeps ownership pending. Nonzero launcher exits
still fail the operation even when native cleanup is confirmed; the native wait
can explicitly retain its bounded post-exit probe on failure for this purpose.
The focused seven-case fixture includes unrelated clients, delayed and surviving
owned children, application completion failure, uncertain launch, nonzero exit
and unchanged ordinary-call behavior. This still does not activate update's
aggregate admission or replace runtime-drain ownership accounting.

## Item 4: Enterprise owned-process completion

Enterprise normalization after a configuration load now explicitly waits for its
owned native processes. Ordinary Enterprise calls retain their previous contract.
The bounded process inventory supplies two fresh empty observations separated by
a quiet interval; a cached result alone cannot confirm release. An asynchronous
scan remains pending without discarding the first completed empty observation.
Application-result stability is measured independently of those pending scans,
so the existing grace period cannot be reset forever by normal worker polling.

A nonzero native exit remains an application failure even when native cleanup
succeeds. The caller explicitly enables bounded post-exit probing on failure to
avoid releasing an uncertain descendant or confusing business failure with
unconfirmed cleanup. Missing native proof never produces successful normalization.
The update call site requests this behavior; its existing lifecycle regression
now checks that request. Nine focused cases include pending scans, delayed and
surviving descendants, inherited application-probe stability, unrelated clients,
uncertain start, native failure and unchanged ordinary-call behavior.

The first lifecycle run exposed the pending-scan and grace-period interaction;
its four original branch-creation reproducers are retained. A diagnostic using a
real command process and the real bounded CIM worker confirms normal completion
after the correction. This is native process-control evidence, not live 1C/PM5
acceptance. Registration and delivered database-admission acceptance remain
separate milestones.

Item 4 update admission is wired in the unregistered integration worktree
before lifecycle locks, with target/recorded-manager revalidation, inherited
private proof, per-native-launch resource/fencing checks and native journal
release. Its mutation drain preserves foreign sessions and retains unconfirmed
owned cleanup instead of using stop-all-infobase fallback. All ten real
Python-host admission cases pass after the nested protocol correction below.
This is not yet delivered or complete.

## Item 4: nested database ownership and cleanup evidence

The Enterprise completion slice is registered at `248d7f6`: its normal Targeted
gate passed 554 tests with no failures or skips and a clean worktree. Publication
and installed 1C acceptance remain separate.

A permanent integration reproducer found that an inherited native host could
report uncertain cleanup while its parent still released the shared database.
The coordinator now records each borrowed participant under the parent's ticket.
Admission and release use the same allocator mutex. A live, crashed or uncertain
participant prevents a clean root release; merely closing its OS process or pipe
does not prove that its native database work stopped. A successful child removes
only its own participation, including when another descendant remains active.

The pipe host reports the actual release disposition and validates its current
fencing authority without creating another work participant. A completed workload
with unresolved nested cleanup remains needs-attention in its authoritative result,
preserving collected measurements. Source capture keeps its participation through
scratch cleanup and distinguishes a known capture failure from unproven native
cleanup. Recovery retains old participant evidence until fresh full-resource
verification; current recovery participants must finish before release, and old
fenced children cannot modify the new recovery generation.

Inherited admission requires participant protocol v1. Its private proof is
domain-separated from the stored owner token, so old children cannot silently
borrow new ownership without registering; new children reject legacy parents
which cannot preserve their records. Existing top-level tickets still serialize
through the same authority. A diagnostic loaded the actual pre-participant
implementation from `248d7f6` and confirmed rejection in both directions before
database work. Ordinary recovery upgrades only the newly claimed generation.

Focused evidence: 52 access/host/recovery/runtime Python tests and 14 source
capture tests pass. The integration worktree's ten update-admission Pester cases
now pass, including the original failing borrowed-host case. Its Go facade suite
also passes with explicit child-disconnect and failed-cleanup cases. Those facade
and update entrypoint changes are separate unregistered integration work; this
protocol slice does not claim delivered cross-chat or cross-host 1C acceptance.

The four unchanged branch-creation reproducers now pass (4/4, 66.47 seconds),
including resume and legacy checkout mode. The nine focused Enterprise cases
also pass. The participant protocol was subsequently registered at `d934199`:
its owning Targeted gate passed 50 Pester tests, including the portable Python
suite, with no failures or skips and a clean worktree.

## Item 4: facade and update admission integration candidate

The integration candidate connects facade calls and development-base updates to
the shared coordinator. It pins target/manager resources before local locks,
revalidates them after waiting, and holds native ownership through cleanup.
Standalone interactive profiles retain a caller-bound owner after their launcher
exits. Native uncertainty keeps the reservation unavailable for competing work;
neither a closed pipe nor an absent caller proves native release.

A failed inherited broker request before native work now releases only that
request's participation. Previously, refusal at the local start lock incorrectly
left an uncertain child behind even though no native call occurred. A native
start failure still leaves recovery evidence. Both paths have permanent tests;
the parent's previous native work is never declared quiescent by this distinction.

Terminal facade close now closes its HTTP MCP transport even when bounded native
cleanup fails. It preserves the native/backend evidence and disconnects the
private owner without claiming successful database release. Persistent profile
stop uses a separate retryable cleanup path so an explicit stop retry can still
finish under its existing owner. The original failed-stop/retry test remains;
the new inherited-failure regression also proves that a fenced parent cannot
restart native work and that terminal cleanup does not leak the HTTP session.

The 0.4.11 candidate was built from the current Go source. Its executable SHA256
is `aaf13fb5d51f8dac37560d1d0aa643484fd31240beedfa03342e1f429b8af0a2`;
the dependency lock and deterministic-build assertion use that same value.
The full Go suite passed in 25.822 seconds. The final OnDemandMcp and
DevBranchLifecycle Pester run passed 263 tests with no failures or skips
(325.26 seconds), including the current build pin and broker admission cases.
These results precede this candidate's normal RegisterChange gate.

The independent public classification/runner cleanup correction was registered
at `ccce8af`: Targeted passed 664 tests with no failures or skips and a clean
worktree (498412 ms; 31 executed workers and one valid reused worker). Advancing
the integration base to that registered commit preserved all 435 tracked and
untracked source-file byte hashes and left the index unstaged.

This candidate does not complete item 4. Remaining work includes admission for
all other lifecycle actions and complete service/scratch resource sets, native
recovery adapters, installed two-chat/manual-profile acceptance, real PM5/UFA
and two-host coordination. The component has not been tagged or published;
exact-source/executable Release E2E for both ROCTUP and Vanessa remains required.

## Added task 16: complete repository-lock reports after partial failure

Source: user request and [Использовать результат ITL](codex://threads/01a087cd-0fee-7112-afe0-6774f6f38ed8),
branch11 run `compact-20260909-231456-271-f748a8ca`. Read-only inspection of its
`repository-lock.log` confirms 24 successful captures, one object held by
Проценко2 (`Справочник.упо_Планы.Форма.ФормаЭлемента`), and four entries under
objects absent from both configurations. The public failed result has an empty
userReport and names only the conflict. No new repository operation was run.

Current `Lock-ConfigRepositoryObjects` throws the parsed conflict before building
its success-only report. Existing commit `0cad454` added conflict-owner reporting;
that is not evidence that complete partial reporting was ever delivered. Compare
source and installed versions during implementation rather than assuming a
reintroduced regression from the user's recollection alone.

Implementation and acceptance:

1. Produce one structured per-object outcome inventory and the corresponding
   Russian report on both success and failure. Preserve requested scope and
   distinguish captured, already held by this repository user, conflict with
   named owner, absent/new object and unconfirmed/not attempted. Do not infer
   successful capture merely because an object is absent from conflict lines.
2. Parse the platform's actual operation boundaries and retain evidence for each
   outcome. Where logs cannot prove a result, use a supported read-only ownership
   inspection or explicitly report unknown; never fabricate the owner.
3. Persist report/artifacts before propagating failure. Keep partial failure
   visibly unsuccessful and do not automatically unlock successfully captured
   objects or retry the whole operation. Update compact transport and the
   generated explicit wrapper so the full failure report is returned, including
   its existing file fallback when output is too large. Preserve secret redaction.
4. Retain the exact 24-success/one-conflict/four-absent reproducer and cover
   multiple owners, existing ownership, unrecognized/truncated logs, cancellation,
   zero/all success, missing objects and a report larger than the compact limit.
   Verify the public wrapper response, not only the parser. Repository ownership
   remains shared state coordinated under item 4.
5. Deliver normally and confirm a partial-conflict run on an authorized technical
   repository. Report all objects and owners without manually disturbing foreign
   locks. The original branch11 source repository is evidence, not an implicit
   target for another lock/unlock operation in this task.

## Added task 17: configuration-root dependency for top-level additions

User requirement: adding a top-level catalog, document, common form, common
module, constant, session parameter, role or another top-level metadata object
requires capture of the configuration root. Adding a form, attribute or other
child of an existing object does not trigger this rule.

The current transfer planner skips Configuration.xml and maps changed object
files independently. Its XML writer uses includeChildObjects=true for full
objects; blindly adding the root as another full object would widen the request
to the entire configuration and must not be the implementation.

Implementation and acceptance:

1. Determine actual top-level additions against the pinned comparison input and
   effective current metadata, including committed, staged, unstaged and untracked
   changes. Use object identities and metadata structure to distinguish additions
   from modified existing objects, nested additions, renames and moves. Git/path
   or XML ambiguity must be explicit before the mutation, not guessed from a
   filename or a changed Configuration.xml alone.
2. Add one explicit root-only lock dependency with includeChildObjects=false
   using the platform-supported identity. Explain in the report which new objects
   require it. Preserve exact object/child scopes for all other entries; root
   ownership is not recursive ownership of the configuration.
3. Coordinate dependency order so an unavailable root is reported with its owner
   and dependent additions remain incomplete. New objects absent from the source
   repository are reported as new/dependent; never claim that the root lock alone
   means those objects were individually captured. Do not load configuration or
   create objects as a side effect of /itl-lock-objects.
4. Test the metadata categories named by the user and another supported category,
   several additions requiring one root, an already-owned/foreign-owned root,
   Cyrillic and spaces, mixed new/existing objects, dirty/untracked additions,
   renames and malformed metadata. Negative cases retain no root capture for a
   new form or attribute inside an existing object. Verify serialized object-list
   scope and a real technical repository roundtrip; no full-configuration fallback.
5. Update the lock helper, transfer/root-dependency report and generated command
   guidance together, integrate the outcome inventory from item 16, register and
   deliver normally. Preserve all earlier plan items; these are additional tasks,
   not replacements for database coordination or AI-review correction.
