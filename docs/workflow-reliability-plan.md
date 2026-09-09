# Measurement and workflow reliability implementation ledger

This source-maintenance plan records fifteen tasks from the original seven PM5
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
| 4 | P0 | Shared database admission queue and inherited operation ownership | Two projects/chats/hosts; aliases; FIFO admission; cancellation; owner crash; nested calls; truthful cleanup | Common queue, portable runtime integration and pinned job recovery hooks implemented; live 1C recovery adapters, lifecycle/facade integration and multi-host proof remain required |
| 5 | P1 | Preserve both compatible semantic changes during merge recovery | Reproduce E2 loss; preserve both deltas; justified replacement report and relevant behavioral checks | Pending |
| 6 | P1 | Explicit multi-branch sync result and complete test classification | Three branches, final recipient trees, resumable plan; one non-runtime classification pass through public wrapper | Pending |
| 7 | P1 | Incremental progress, experiment provenance and actionable waiting | Interrupted operation retains stages/settings; queue distinct from execution; user cancellation; no polling a decision blocker forever | Command phase journal and asynchronous MCP progress evidence implemented; full scenario provenance and detailed runtime stages remain open |
| 8 | P1 | Diagnose and correct ambiguous owned debugger client on UFA | Retained discovery/launch evidence; exact own session among foreign clients; real remote short capture | Pending |
| 9 | P2 | Correct row selection for column captions containing spaces | Cyrillic plus spaces, multiple criteria, no match; owning backend delivery | Pending |
| 10 | P2 | Reliable client-code channel and diagnosed clipboard failures | Busy clipboard, explicit completion/errors, no duplicate replay, isolated files/cleanup; shared supported route | Pending |
| 11 | P2 | Correct release snapshot ownership and cleanup | Retention respected; old ledger handled through helper; foreign paths remain protected | Read-only follow-up confirms current producer writes run-root snapshots/baseline.dt and post-config.dt while cleanup accepts only the older .agent-1c/snapshots naming contract; common ledger retains the corresponding cleanup debt; owner correction and retention qualification pending |
| 12 | P1 | Make absent/empty command-handler diagnostics advisory and prevent unsolicited dummy handlers | Notify the user without blocking refresh/check or requiring agent repair; preserve genuine structural errors; deliver the validator and agent-guidance correction through their owners; verify real project updates without dummy handlers or the local workaround | Source correction prepared in controlled fork r34; workflow exposes warnings without repair/failure; 9 validator and 10 lifecycle cases pass, five actual branch11 forms retain 14 advisory actions and unchanged sources; normal delivery/install and full branch11 acceptance remain open |
| 13 | P1 | Distinguish accepted master changes from branch-owned changes when selecting tests | Imported master selects the existing acceptance set without invented tests/owners; own unknown changes still require classification; mixed dirty trees, CF/CFE, deletion/rename and Git failures covered | Independent branch11 handoff: local selector correction, 15/15 focused tests and subsequent Vanessa 49/49 plus YAxUnit 118/118 reported; current shared selector still lacks provenance handling; general implementation and delivery pending |
| 14 | P0 | Remove export/ROCTUP mutual waiting and complete the official artifact | Check then read-only ROCTUP query then unchanged-config export completes with verified CF/CFE and manifest; nested ownership, foreign sessions, failure/cancellation and preserved fresh proof covered | Shared standalone DumpCfg completion correction implemented; 45 Designer/export regressions pass, including public manifest and fresh-proof failures; real CF/CFE exports with an open technical file-base client pass; delivered facade/PM5, competing chats and server acceptance remain open |
| 15 | P1 | Resolve unsupported AI-review responses and demonstrably false blocking findings through an evidence-based decision | Original response and exact validation unit retained; every finding resolved or explicitly open; bounded recovery for non-analysis responses; no fabricated clean pass, harmful appeasement edits or repeated calls for a green answer | Fourth branch11 handoff and current controlled-fork rules confirm a missing decision route; recorded rebuttals exist, but clean AI acceptance and shared correction remain unconfirmed |

Implementation order: establish item 4 with the timeout and source-capture
contracts and resolve the concrete export deadlock in item 14; complete items
1-3; then 5-8, 12, the accepted-master selection contract in 13 and AI-review
adjudication in 15, followed by 9-11. Items 13-15 have their own acceptance below;
linking them to related tasks does not remove them from the plan. Each coherent source change
gets directly owned checks, a local commit and RegisterChange. Publication and
live installation/acceptance must be recorded explicitly, using normal helpers.
Investigations close only with an implemented correction or evidence explaining
why no workflow change is appropriate; an unresolved hypothesis stays open.

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

Focused tests use SQLite changes and separate processes, including a killed
Windows recovery owner after the restoration commit. They verify one original
action, no repeated restoration after that crash, honest failed-measurement
status, cancellation, bounded hangs, missing/tampered evidence and changed input
rejection. Initial fixture failures exposed unclosed SQLite connections in the
test harness; explicit closing fixed teardown without weakening the workload or
assertions. Real 1C/Vanessa recovery adapters, partial-artifact collection after
an engine crash with no result.json, legacy technical-run reconciliation and
two-host live proof remain open.
Focused recovery checks passed 28/28 and the owning RemotePerformance suite
passed 8/8 (including the portable Python inventory). The queued transport path
was additionally exercised through the public `worker --once` command: one
restoration, one original action, and no action on duplicate request delivery.

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
