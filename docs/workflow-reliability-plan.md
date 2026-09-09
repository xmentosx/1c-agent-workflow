# Measurement and workflow reliability implementation ledger

This source-maintenance plan records the eleven user-approved tasks from the
seven PM5 investigations. It is not installed-project guidance. A completed
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
| 1 | P0 | Include file-base ServerEmulation and validate profile coverage | Real client/server packets; missing family partial; foreign packet rejected | Pending; branch4 diagnostic patch is not package delivery |
| 2 | P0 | Phase-specific deadlines propagated through engine, adapter and MCP | Action beyond 300 seconds; cancellation; bounded hang; large branch6 calculation | Pending |
| 3 | P1 | Native module mapping and on-demand target source capture | Different database/checkout configurations; matching, partial and missing sources; extensions; version drift; unchanged database and working tree | Pending |
| 4 | P0 | Shared database admission queue and inherited operation ownership | Two projects/chats/hosts; aliases; FIFO admission; cancellation; owner crash; nested calls; truthful cleanup | In progress: common queue and portable runtime integration first; lifecycle/facade integration and multi-host proof remain required |
| 5 | P1 | Preserve both compatible semantic changes during merge recovery | Reproduce E2 loss; preserve both deltas; justified replacement report and relevant behavioral checks | Pending |
| 6 | P1 | Explicit multi-branch sync result and complete test classification | Three branches, final recipient trees, resumable plan; one non-runtime classification pass through public wrapper | Pending |
| 7 | P1 | Incremental progress, experiment provenance and actionable waiting | Interrupted operation retains stages/settings; queue distinct from execution; user cancellation; no polling a decision blocker forever | Pending |
| 8 | P1 | Diagnose and correct ambiguous owned debugger client on UFA | Retained discovery/launch evidence; exact own session among foreign clients; real remote short capture | Pending |
| 9 | P2 | Correct row selection for column captions containing spaces | Cyrillic plus spaces, multiple criteria, no match; owning backend delivery | Pending |
| 10 | P2 | Reliable client-code channel and diagnosed clipboard failures | Busy clipboard, explicit completion/errors, no duplicate replay, isolated files/cleanup; shared supported route | Pending |
| 11 | P2 | Correct release snapshot ownership and cleanup | Retention respected; old ledger handled through helper; foreign paths remain protected | Pending |

Implementation order: establish item 4 with the timeout and source-capture
contracts; complete items 1-3; then 5-8 and 9-11. Each coherent source change
gets directly owned checks, a local commit and RegisterChange. Publication and
live installation/acceptance must be recorded explicitly, using normal helpers.
Investigations close only with an implemented correction or evidence explaining
why no workflow change is appropriate; an unresolved hypothesis stays open.

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
