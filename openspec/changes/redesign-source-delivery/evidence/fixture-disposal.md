# Develop qualification database lifetime

Develop977a9674 failed during the positive fixture's initial RestoreIB, before
update/check/export: native exit1, database not fully loaded. The negative
configuration rejection and rollback had passed. The failed report remains failed.
C: had 1.45GiB free; this suggested storage exhaustion but did not prove it.

Six derived database files in four completed, exactly identified Develop targets
were released under the existing per-base guard and exclusive DeleteOnClose
handles. Seed bases, immutable capsules/DT, source, pending/cursor and logs were
preserved. C: recovered to13.67GiB. The initial cleanup log records each actual
removal; its final aggregation failed. The reconciled receipt records an
idempotent second pass (zero new bytes), not a second12GiB removal.

The owning source factory previously had no terminal database disposal. The
source-only native adapter now disposes only Develop claim-matching targets,
checks common Git and rejects reparse traversal, admits each exact base through
the configured guard, then requires an exclusive native file handle. Release
continuations remain outside this operation. Its original snapshots and failure
evidence remain available for a new nonce attempt.

Develop's finally consumes the Prepare receipt, written before native restore,
so failed materialization is covered too. A busy base is retained with a warning
and a recorded continuation command; cleanup cannot replace the journey outcome.
This is bounded owner completion, without a global sweeper or extra release gate.

One meaningful regression matrix covers ready/materializing targets, a real
locked file followed by successful retry, foreign candidate and Release refusal.
It uses the real guard with a custom root and Unicode/whitespace database path,
and proves seed/snapshot/log preservation. Five cases passed in10.68s; the full
owner file passed27/0/0 in47.17s. No extra scheduler shard was added. The fixture
owner declares the guard host/Python resolver in its reuse closure.

Same-capsule native RestoreIB replay after storage recovery passed: capsule
40c1e0c1bb4e32de8431fa8359d3b3a7697395e7e3af7f14246120a5818656da,
candidate977a9674, restore54463ms, complete preparation120539ms. The new adapter
then disposed its3295551488-byte database under the real guard. It also disposed
both completed977 targets, including the failed partial positive database; C:
then had16.57GiB free. No seed/capsule/log was removed.

696e4a63 registered with Targeted544/0/0,393606ms,16 executed/0 reused,
fingerprint8804ms,workerSpan378480ms. The current metadata contract deliberately
invalidates all selected Pester consumers; this is not a small-feature benchmark.

That run exposed an avoidable selection: invoke-develop-e2e selected all305
installed lifecycle cases via release-runtime. Those files and their shared
support do not load the Develop runner. Its new route retains its actual
configuration-rejection, ReleaseGate (which reads the runner), and local-gate
contracts plus the existing qualification/manifest/client routes. Lifecycle and
Release-specific suites remain selected by their original production owners and
by Full. The existing routing regression now protects both exclusions and
positive lifecycle/Release coverage, without a new test definition or shard.

This narrow reproduction does not qualify the new candidate or replace complete
Develop, warm continuation, concurrent registration or publication acceptance.
