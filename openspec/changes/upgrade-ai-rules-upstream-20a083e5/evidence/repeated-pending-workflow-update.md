# Repeated workflow updates during one stopped merge

Independent review found a replay defect in `Apply-WorkflowBranchCommitPlan`.
The lifecycle correctly keeps `pendingMergeOriginalBranchCommit` at the branch
commit before the business merge. Each subsequent workflow update has a later
`Plan.oldHead`. After the second update advanced its checkpoint, an interruption
before terminal acknowledgement made its retry require the initial anchor to
equal that later parent. The retry therefore rejected its own completed effect.

The existing real-Git reproducer now has one-update and two-update cases. Both
retain an unresolved business conflict, its original `MERGE_HEAD`, exact
workflow-only receipts and temporary-index planning. The second case invokes
the real advance, then loses acknowledgement, reloads the saved receipt and
state in a fresh helper context, and retries the same plan. It also rejects an
unrelated target anchor, an unavailable SHA and the candidate itself as a false
original anchor. It finally resumes the original business merge and preserves
the original checkpoint and the resulting merge parents.

The corrected reproducer failed only the second case before the fix:
`build/pending-merge-second-advance-before.xml`, **1/2, 34.45 seconds**, with the
actual `WORKFLOW_UPDATE_PENDING_MERGE_CHECKPOINT_CHANGED` at the replay guard.
An earlier parameterized fixture reused one worktree across two cases; its
failure is retained in `build/pending-merge-second-advance-before-factory.xml`
and does not prove the product defect. A discovery filter selected no cases;
`build/pending-merge-second-advance-empty-filter.xml` is likewise not a pass.
The second case now has its own workspace namespace, retaining whitespace,
Cyrillic, topology, workload and the original one-update case's paths.

The stateless replay predicate accepts only the exact candidate checkpoint and
an existing original SHA connected to the planned old parent by the existing
linear-ancestry validator. Receipt validation still checks the immutable
candidate tree, single parent, actual changed paths, before-snapshot membership
and owned index state. The same predicate is used before and after application.
It does not rewrite the initial anchor, widen the write-set or add a coordinator,
persistent record or new recovery action. The initial anchor comes from the
authoritative lifecycle state: the root snapshot does not capture that state
file and is not presented as independent proof of the anchor.

After correction both original cases passed:
`build/pending-merge-second-advance-after.xml`, **2/2, 42.05 seconds**. The foreign
anchor negatives and original index/receipt protections remained in place.
This is executed Git/owner proof. It does not replace the representative native
PM5 refresh acceptance or qualify the prior immutable C2 payload, which lacks
this later replay correction.
