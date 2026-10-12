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

Same-capsule native RestoreIB replay after storage recovery is in progress.
This narrow reproduction does not qualify the new candidate or replace complete
Develop, warm continuation, concurrent registration or publication acceptance.
