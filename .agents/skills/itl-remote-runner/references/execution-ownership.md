# Execution ownership

## Boundary and authority

`execution-guards-v2` protects one concrete bounded execution: a remote job,
facade tool call or native 1C phase. An idle backend, project, branch or agent
session is not a database owner. The operating-system handle held by the live
supervisor is the authority; JSON status is diagnostic and never blocks a later
command by itself.

Every producer declares its complete exact resource set before acquisition.
File bases use canonical absolute paths. Server bases use the configured
execution-host identity plus exact server and infobase names. Resources are
sorted and acquired all-or-none; a waiter never retains an earlier resource
while waiting for another one.

## Waiting, cancellation and target validation

Conflicts enter visible `waiting-for-base` state. Waits use the job/call cancel
signal and a finite deadline. Cancellation removes only the waiter. Timeout is a
bounded failure for the exact resource set and does not stop the owner.

Lifecycle and Git locks are released before waiting. After acquisition they are
re-entered and the target state, `.dev.env`, package/profile identity and other
producer inputs are revalidated before native start. A refresh with no native
work does not create a guard.

## Nested work

The root supervisor passes a signed execution context through a private process
environment boundary. A nested source capture, broker or native helper validates
the signature, execution identity and requested resource subset. It borrows the
root ownership and cannot reacquire or expand it. Context values are never
reported as public evidence.

## Process cleanup

Workflow-owned native children are attached to the root Windows Job Object.
Normal completion, cancellation and deadline perform bounded graceful cleanup
and then exact termination if necessary. A dead caller does not orphan a live
supervisor; a dead supervisor closes its Job Object. The next waiter proceeds
after the OS releases the guard and current process inspection confirms that no
conflicting owned tree remains.

Foreign or ambiguous processes are never terminated. If such a process still
uses the exact base, the current execution returns
`EXECUTION_GUARD_EXTERNAL_CONFLICT`; unrelated bases and file-only workflow
updates continue.

## Failure and evidence

A failed or interrupted execution remains failed/interrupted. Unknown effects
are not replayed automatically and do not create a recovery gate for later
commands. Operation-specific snapshots and checkpoints remain available only to
the operation that explicitly uses them. A later check must still produce fresh
passed evidence before export or publication.

The one-time cutover stops only exactly identified workflow-owned executors,
replaces managed helpers and removes obsolete protocol state without interpreting
ticket semantics or inspecting database health. Re-running cutover is idempotent.
