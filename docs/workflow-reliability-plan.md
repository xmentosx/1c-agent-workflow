# Measurement and workflow reliability implementation ledger

This source-maintenance plan records the twelve user-approved tasks from the
original seven PM5 investigations and the added form-validator handoff. It is not installed-project guidance. A completed
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
| 4 | P0 | Shared database admission queue and inherited operation ownership | Two projects/chats/hosts; aliases; FIFO admission; cancellation; owner crash; nested calls; truthful cleanup | In progress: common queue and portable runtime integration first; lifecycle/facade integration and multi-host proof remain required |
| 5 | P1 | Preserve both compatible semantic changes during merge recovery | Reproduce E2 loss; preserve both deltas; justified replacement report and relevant behavioral checks | Pending |
| 6 | P1 | Explicit multi-branch sync result and complete test classification | Three branches, final recipient trees, resumable plan; one non-runtime classification pass through public wrapper | Pending |
| 7 | P1 | Incremental progress, experiment provenance and actionable waiting | Interrupted operation retains stages/settings; queue distinct from execution; user cancellation; no polling a decision blocker forever | Command phase journal and asynchronous MCP progress evidence implemented; full scenario provenance and detailed runtime stages remain open |
| 8 | P1 | Diagnose and correct ambiguous owned debugger client on UFA | Retained discovery/launch evidence; exact own session among foreign clients; real remote short capture | Pending |
| 9 | P2 | Correct row selection for column captions containing spaces | Cyrillic plus spaces, multiple criteria, no match; owning backend delivery | Pending |
| 10 | P2 | Reliable client-code channel and diagnosed clipboard failures | Busy clipboard, explicit completion/errors, no duplicate replay, isolated files/cleanup; shared supported route | Pending |
| 11 | P2 | Correct release snapshot ownership and cleanup | Retention respected; old ledger handled through helper; foreign paths remain protected | Pending |
| 12 | P1 | Investigate and correct false form validation failures for absent or empty command Action | Verify platform contract and current controlled-fork implementation; preserve genuine structural errors; deliver through the owning fork and workflow pin; refresh/check branch11 without the local workaround | Added from task 01a085aa-b4b8-75d2-a92e-acd4725b2d8d; local workaround and 13/13 regression reported, upstream correction and delivery unverified |

Implementation order: establish item 4 with the timeout and source-capture
contracts; complete items 1-3; then 5-8 and 12, followed by 9-11. Each coherent source change
gets directly owned checks, a local commit and RegisterChange. Publication and
live installation/acceptance must be recorded explicitly, using normal helpers.
Investigations close only with an implemented correction or evidence explaining
why no workflow change is appropriate; an unresolved hypothesis stays open.

## Added task 12: form command Action validation

Source: [Валидатор форм: пустой Action блокирует…](codex://threads/01a085aa-b4b8-75d2-a92e-acd4725b2d8d),
with `D:/Git/PM5 КОРП - Codex - 1-branch11/handoffs/handoff-20260909-local-form-validator.md`.
The handoff reports that form-validate v1.8 Check8 classified missing/empty
command Action as an error and blocked preparation on five forms/14 commands.
It cites the platform's disabled-command behavior when no handler exists. This
must be verified against the relevant platform documentation and current owner
implementation; the installed workaround is evidence, not the upstream source.

1. Reproduce absent, empty and whitespace Action plus a valid bound command;
   compare the five retained real forms and verify the platform contract.
2. Locate the actual validator in the controlled `itl_ai_rules_1c` fork and its
   current pin. If the defect persists, fix its diagnostic severity there on the
   prescribed upgrade/release branch. Do not add dummy business handlers, remove
   business commands, disable source-integrity or patch another installed copy.
3. Preserve regressions rejecting empty event handlers, duplicate command IDs,
   invalid callType and malformed XML. Reuse the retained 13-case reproducer as
   evidence, verifying its actual scope before adopting it upstream.
4. Deliver the owning fork correction and workflow pin through normal intake;
   remove only the now-redundant local workaround through managed update.
5. Qualify branch11 refresh and the complete check on the delivered version.
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
