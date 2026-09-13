# Workflow stabilization plan

Status: active  
Owner branch: `codex/workflow-stabilization`  
Baseline: `origin/develop` at `db5acb7db74b635c41deecb093fe965ade016c3e`  
Master promotion: blocked until the P0 fixes and core live acceptance below pass.
Develop publication: explicitly paused by the user after stabilization; stop at local registration until the follow-up problem review is complete.

## Goal and boundary

Stabilize the workflow changes published in `develop` after the reliability work,
without adding new product capabilities or weakening existing gates. The first
delivery batch contains only defects that can make release reuse unreliable or
make database admission degrade as historical state grows.

This file is the current execution checkpoint. A task is not complete merely
because code exists: implementation, registration, publication, installed proof,
and live proof are distinct states.

## Current state

Snapshot boundary: this table describes only the local stabilization branch
state recorded by this document. It does not infer publication, installation,
or live runtime state from implementation or registration proof.
Develop publication is on explicit user hold; every row therefore stops before
publication even when its registration is complete. Detailed chronological
evidence is preserved in the append-only
[stabilization history](workflow-stabilization-history.md).

| ID | Priority and problem | Implementation | Registration | Publication | Installation | Runtime |
|---|---|---|---|---|---|---|
| STAB-01 | P0: disposable Release evidence made a valid checkpoint unusable after cleanup. | Implemented; durable evidence and strict SHA validation have focused fixture proof. | Registered in the local queue. | Not published; user hold. | Not installed from this change. | No installed/live proof; local fixture regression only. |
| STAB-02 | P1: delivery-plan identity used a reactive volatile-value blacklist. | Implemented; the semantic-input identity contract has focused fixture proof. | Registered in the local queue. | Not published; user hold. | Not installed from this change. | No installed/live proof; local fixture regression only. |
| STAB-03 | P0: database-access lookup and retention scaled with all historical tickets. | Implemented; bounded lookup, migration, retention, and corruption isolation have local owner proof. | Registered in the local queue. | Not published; user hold. | Not installed from this change. | Local process/volume proof only; real SMB/two-host proof remains STAB-05. |
| STAB-04 | P1: access modes lacked explicit compatibility semantics. | Implemented and independently reviewed; rolling-compatible persisted projection, root-envelope semantics, transition proof propagation, and producer inventories have owner proof. A Targeted-only failure also exposed and fixed selection of an unrelated process-wide Vanessa source-build archive. Local component candidate is `itl-ondemand-mcp` 0.4.12. | Corrected head `e9747ff` registered after Targeted passed 1397/1397 in 548.833 seconds; 25 shards executed and 46 were safely reused. | Not published; user hold. The 0.4.12 tag and asset do not exist. | Not installed. | Local process/fixture proof only; component Release E2E and installed/live proof remain absent. |
| STAB-05 | P1: file/server and multi-host admission/recovery acceptance is incomplete. | Local protocol matrix audited and the missing file-alias cross-process regression added; see the [acceptance matrix](database-access-acceptance-matrix.md). A fresh host audit found no authorized disposable live contour. | Local evidence batch registered in the queue. | Not published; user hold. | Not installed. | Real SMB/two-host, installed file/server, server recovery, and foreign repository-owner scenarios remain `NOT RUN`: no second host, UNC coordinator, installed file/server pair, `recovery-observe` provider, or repository-user pair is configured. |
| STAB-06 | P2: ledger, refs, worktrees, and metrics need bounded hygiene. | Batches A-E are implemented. E adds manual-only, ref-only cleanup for exact published queue pairs and stale promotion refs through one case-sensitive `--no-deref` old-SHA CAS transaction; worktree/resource deletion remains disabled. | Batches A-E registered; E Targeted passed 202/202 in 189.010 seconds at `5701169`, reusing 16 exact shards and executing one after a diagnosed budget stop. | Not published; user hold. | Not installed. | Combined C+E owners passed 126/126 after E's initial review blocked and fixed gate-inventory, case-sensitivity, ABA, and fabricated-plan issues. Raw proofs remain immutable; candidate worktrees/resources are never selected by E. |
| STAB-07 | P1: `ResumePlan` selected a newer supervisor instead of its recorded trusted supervisor. | Implemented; recorded-supervisor and fail-closed cases have focused fixture proof. | Registered in the local queue. | Not published; user hold. | Not installed from this change. | No installed/live proof; local fixture regression only. |
| STAB-08 | P1: an entrypoint edit selected the whole lifecycle test inventory. | Implemented; semantic routing and fail-closed fallback have focused proof. | Registered in the local queue. | Not published; user hold. | Not installed from this change. | Fresh local Targeted proof only; no installed/live proof. |
| STAB-09 | P1: stale Pester estimates and serial-tail scheduling can exhaust the Targeted hard budget after every parallel owner has passed. | Queued from the STAB-06E registration evidence; fix must make the plan budget-aware without weakening owner selection or raising the hard limit as a substitute. | Not implemented or registered. | Not published; user hold. | Not installed. | Reproducer: 16 shards passed, `ReleaseGate.Tests.ps1` started last, and the run stopped at 1,202.113 seconds; exact cache recovery then passed 202/202 in 189.010 seconds. |

## Wave 0 - frozen scope and baselines

- [x] Preserve the user's main checkout and `handoffs/`.
- [x] Create an isolated worktree from the current `origin/develop`.
- [x] Freeze the first batch to STAB-01 through STAB-03.
- [x] Capture a minimal reproduction of disposable Release evidence loss.
- [ ] Capture the access-status baseline and ticket inventory without changing runtime state.
- [x] Record exact owner tests before editing.

Non-goals for the first batch:

- no new lifecycle recovery adapters;
- no expansion of supported operations;
- no broad gate while developing a focused fix;
- no `master` promotion;
- no cleanup of unrelated user branches, worktrees, or runtime state.

## Wave 1 - critical implementation batch

### STAB-01 - durable Release evidence

Contract:

1. Seal successful reusable stage evidence into the persistent Release stand run
   beside its checkpoint before writing a reusable checkpoint or cache record.
2. Address sealed evidence by candidate/stage identity and verify its SHA-256.
3. A checkpoint must not require the continued existence of a disposable source
   or candidate worktree.
4. Corrupt or missing sealed evidence remains fail-closed. A stage may become
   safely recomputable only through a separate explicit rollback contract.
5. Cleanup must not delete evidence referenced by an active checkpoint.

Acceptance:

- [x] delete the source candidate after a passed stage and resume without rerun;
- [x] reject changed bytes with a precise corruption diagnostic;
- [x] do not silently rerun a mutable stage when sealed evidence is missing;
- [x] preserve evidence referenced by an active checkpoint;
- [x] resume after a new PowerShell process starts.

### STAB-02 - semantic ResumePlan identity

Contract:

1. Build identity from an explicit versioned list of semantic inputs: candidate
   commit/tree, controlled-fork identity, protocol/checker/runtime versions, and
   stable stand configuration that changes qualification behavior.
2. Structurally exclude temporary paths, process identifiers, timestamps, export
   output locations, and mutable runtime state.
3. Keep the outer immutable plan protocol at schema v1, version the environment
   sub-identity as v2, and never rewrite already saved plans.

Acceptance:

- [x] equivalent rules checkouts and env materializations produce the same identity;
- [x] changing each declared semantic input changes the identity;
- [x] adding an unrelated runtime `.dev.env` key does not change the identity;
- [x] outer plan schema remains v1 while the environment identity is v2.

### STAB-03 - bounded database-access state

Contract:

1. Admission lookup must be bounded by the requested resource and active state,
   not by all historical tickets.
2. Terminal tickets and liveness markers have a documented retention lifecycle.
3. Retention/compaction is atomic, restartable, and idempotent.
4. A malformed historical record affects only the resource it belongs to when
   that resource can be identified; it cannot block unrelated databases.
5. Existing installations migrate without losing active ownership or wait order.

Acceptance:

- [x] active ownership and FIFO order survive migration;
- [x] completed tickets and matching `.alive` files are compacted safely;
- [x] interrupted compaction resumes without losing an active ticket;
- [x] an unrelated malformed historical record does not block another resource;
- [x] a focused volume test covers 10,000 terminal and 10 active tickets;
- [x] `access-status` completes within one second on the reference workstation.

Each item is implemented as a coherent change, receives only its owner tests
during development, and is registered separately with `RegisterChange` after the
focused proof passes. A test contract is not weakened to make a failure disappear.

## Wave 2 - coordination semantics and live acceptance

Define and test these modes:

| Mode | Compatibility rule |
|---|---|
| `shared-read` | May coexist only with operations that promise availability and structurally readable state; it does not promise a transactional data snapshot. |
| `functional-test` | May coexist only with explicitly compatible diagnostic reads. |
| `measurement-exclusive` | Excludes tests, ROCTUP, and other background load. |
| `mutation-exclusive` | Excludes every independently owned operation on the same resource. |

STAB-04 introduces these four canonical wire values, treats `test-run` as a
legacy alias for `functional-test`, and treats `exclusive` or a missing legacy
mode as fail-closed `legacy-exclusive`. The compatibility matrix must be
declarative, symmetric, and covered exhaustively. Production mode producers and
the mode recorded in measurement evidence are machine-inventoried. Admission
waiting stays outside measured time; the complete measured lifecycle stays under
`measurement-exclusive`. This semantic batch is separate from the real-host and
real-1C acceptance in STAB-05.

Then complete the base admission contract before adding operation-specific
recovery: file/server aliases, two local processes, two projects, two hosts over
the shared coordinator, owner crash, live-owner protection, dead waiter cleanup,
unrelated database progress, and root/partial-lock contention.

### STAB-08 - semantic Targeted routing

Implemented after STAB-03 registration. The resolver compares named PowerShell
AST nodes for the exact entrypoint path. An informational owner mapping does not
permit selective execution: only an explicitly allowlisted node with a literal,
machine-validated test probe that invokes the public entrypoint may select a
small common-plus-domain contract. All parameters/functions and all but two
actions currently remain fail-closed. Shared startup, module ordering, re-exec,
admission, completion/error cleanup, parse failures, missing baselines, and
unknown or unproven nodes fall back to the full lifecycle contract. The selection
protocol includes the complete
changed entrypoint in `additionalInputs` for every selected shard digest, so a
domain test cannot reuse evidence from a different entrypoint version.

Acceptance:

- [x] one proven dispatch-arm edit selects only entrypoint-core plus its domain owner;
- [x] two proven arm edits select the union of their owners;
- [x] action `ValidateSet`, switch labels, and owner catalogue remain exactly equal;
- [x] unknown, shared, or merely classified changes select full lifecycle fail-closed;
- [x] a mutation-kill regression proves the selected public probe observes dispatch;
- [x] every selected shard digest changes when the entrypoint changes;
- [x] Full and Develop keep the complete inventory;
- [x] a fresh measured leaf Targeted finishes within 300 seconds.

## Wave 3 - remaining acceptance streams

Run independently where environments permit:

- profiling/provenance: fresh ServerEmulation, long branch6 cancellation,
  drift/extensions, PM5/UFA, loaded-state, thick client, and one-slot adapter;
- lifecycle/repository: installed merge preservation, three-branch sync,
  accepted-master full check, public partial lock, and two-host root lock;
- Vanessa/client channel: installed captions, original BDR, 49-scenario restart,
  empty Action, facade/server/two-chat, and export with ROCTUP;
- AI review policy: adjudicate every retained finding as confirmed, disproved,
  open, or requiring a human decision.

Every scenario ends as `PASS`, `FAIL`, or `NOT RUN` with evidence. A newly found
defect becomes a separate stabilization item; the reproducer remains equivalent.

## Wave 4 - documentation and bounded hygiene

Execute STAB-06 as four separately registered batches, never as an unbounded
cleanup: (A) archive the narrative ledger and keep a compact current view with
separate implementation/registration/publication/installation/runtime facts;
(B) add read-only ref/worktree disposition, then allow deletion only with exact
ownership, expected-SHA CAS, clean/process-free state, and published ancestry or
tree equivalence; (C) compact hot run/resource state without deleting raw proof
or breaking Targeted lookup; (D) add backward-compatible access summary metrics.
Expose active/terminal counts, oldest waiter age, store sizes, retained checkpoint
reasons, and stage-rerun reasons. Never select arbitrary `codex/*` worktrees or
age-delete content-addressed evidence/qualifications in this item.

## Wave 5 - frozen release

Release is allowed only after all P0 items and the core server/two-host acceptance
pass. Before starting, verify local artifacts, candidate/fork/runtime identity,
stable checkpoint paths, free disk space with 25% headroom, and supervisor protocol
compatibility. Freeze the candidate, run one `PublishDevelop -RequireRelease`, use
at most one valid restart, verify refs/queue/evidence, canary-install one project,
and observe it for one working day. Promotion to `master` remains a separate user
decision.

Expected release budget after readiness is proven: 15 minutes preflight, up to
45 minutes Develop, up to 75 minutes Release, and 15 minutes final verification.
Hard stop: three hours.

## Stop rules

- The same stage failure twice requires diagnosis and a minimal reproducer before
  another retry.
- Sixty to ninety minutes without a new falsifiable hypothesis stops that line of
  investigation and records a blocker.
- More than three new owner areas or ten unexpected files requires scope review.
- No candidate changes after the release candidate is frozen.
- At most one automatic retry and one deliberate restart per exact candidate.
- More than three distinct Release blockers, or more than 90 minutes of fixes
  after a passed Develop, moves the blockers into another stabilization batch.
- Poll only on meaningful state transitions or at three-to-five-minute intervals.
- After context compaction, resume from this file: goal, frozen scope, completed
  work, current blocker, next action, non-goals, and evidence.
