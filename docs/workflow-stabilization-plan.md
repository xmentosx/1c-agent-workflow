# Workflow stabilization plan

Status: active  
Owner branch: `codex/workflow-stabilization`  
Baseline: `origin/develop` at `db5acb7db74b635c41deecb093fe965ade016c3e`  
Master promotion: blocked until the P0 fixes and core live acceptance below pass.

## Goal and boundary

Stabilize the workflow changes published in `develop` after the reliability work,
without adding new product capabilities or weakening existing gates. The first
delivery batch contains only defects that can make release reuse unreliable or
make database admission degrade as historical state grows.

This file is the current execution checkpoint. A task is not complete merely
because code exists: implementation, registration, publication, installed proof,
and live proof are distinct states.

## Current priorities

| ID | Priority | Problem | State | Completion evidence |
|---|---|---|---|---|
| STAB-01 | P0 | Release E2E evidence can remain in a disposable candidate worktree, so cleanup makes a valid checkpoint unusable. | registered at `fa7dd9c` | Focused regressions prove restart after candidate cleanup and strict SHA rejection. |
| STAB-02 | P1 | Delivery plan identity excludes volatile values with a reactive blacklist instead of defining semantic inputs. | implemented; focused proof passed; registration pending | Equivalent materializations have the same identity; every declared semantic input changes it. |
| STAB-03 | P0 | Database access scans and retains all historical tickets and `.alive` files; unrelated corruption has a global blast radius. | in analysis | Resource-bounded lookup, crash-safe retention, corruption isolation, and a historical-volume regression. |
| STAB-04 | P1 | Shared read, functional test, performance measurement, and mutation do not have sufficiently explicit compatibility semantics. | queued | Mode matrix and focused compatibility regressions exist; measurements are exclusive. |
| STAB-05 | P1 | File/server and multi-host admission/recovery acceptance is incomplete. | queued | Two-process, two-project, server-alias, SMB two-host, owner-crash, dead-waiter, and independent-resource scenarios pass. |
| STAB-06 | P2 | Operational ledger, stale refs, retained worktrees, and runtime metrics need bounded cleanup and a compact current-state view. | queued | Current checkpoint is concise; historical evidence remains available; cleanup is ancestry-checked. |
| STAB-07 | P1 | `ResumePlan` bootstraps the latest `origin/master` supervisor instead of the supervisor recorded by the immutable plan. | queued | Resume loads the recorded trusted ancestor; a new plan still uses current `origin/master`; malformed or untrusted plans fail closed. |

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

- [ ] active ownership and FIFO order survive migration;
- [ ] completed tickets and matching `.alive` files are compacted safely;
- [ ] interrupted compaction resumes without losing an active ticket;
- [ ] an unrelated malformed historical record does not block another resource;
- [ ] a focused volume test covers 10,000 terminal and 10 active tickets;
- [ ] `access-status` completes within one second on the reference workstation.

Each item is implemented as a coherent change, receives only its owner tests
during development, and is registered separately with `RegisterChange` after the
focused proof passes. A test contract is not weakened to make a failure disappear.

## Wave 2 - coordination semantics and live acceptance

Define and test these modes:

| Mode | Compatibility rule |
|---|---|
| `shared-read` | May coexist only with operations that promise a stable readable state. |
| `functional-test` | May coexist only with explicitly compatible diagnostic reads. |
| `measurement-exclusive` | Excludes tests, ROCTUP, and other background load. |
| `mutation-exclusive` | Excludes every independently owned operation on the same resource. |

Then complete the base admission contract before adding operation-specific
recovery: file/server aliases, two local processes, two projects, two hosts over
the shared coordinator, owner crash, live-owner protection, dead waiter cleanup,
unrelated database progress, and root/partial-lock contention.

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

- replace the long operational ledger with a compact generated/current view and
  retain the narrative as historical evidence;
- show implementation, registration, publication, installation, and runtime
  acceptance as separate facts;
- inspect ancestry/equivalence before archiving stale refs or worktrees;
- expose active/terminal ticket counts, oldest waiter age, evidence-store size,
  retained checkpoints, and stage-rerun reasons.

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

## Execution log

| Date | Event | Evidence |
|---|---|---|
| 2026-09-12 | Stabilization started in an isolated worktree. | Branch `codex/workflow-stabilization`, baseline `db5acb7`. |
| 2026-09-12 | STAB-01 implemented and its owner suite passed. | `ReleaseGate.Tests.ps1`: 13 passed, 0 failed, 175.97 seconds. Evidence is atomically copied to the persistent Release run before checkpoint publication; available legacy external evidence migrates on reuse. |
| 2026-09-12 | STAB-01 registered in the shared develop queue. | Queue item `codex/workflow-stabilization`, base `db5acb7`, head `fa7dd9c`. |
| 2026-09-12 | STAB-02 implemented and its owner suite passed. | `SourceDeliveryPlan.Tests.ps1`: 10 passed, 0 failed. Semantic `.dev.env` allowlist, canonical parsing, unknown-key stability, all declared inputs, and byte-based Vanessa source-build identity are covered. |
