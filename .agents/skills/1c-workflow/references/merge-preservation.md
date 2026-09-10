# Preserve compatible changes during lifecycle merges

On `LIFECYCLE_MERGE_PRESERVATION_REVIEW_REQUIRED`, read the named `review.json`
and its per-side patches. The helper compares both parents to their merge bases
and the staged result. It flags a both-sided changed path replaced by one parent
or reverted to the base, including deletion, and new BSL declarations missing
from a mixed result. Identical parent additions are still checked for loss.
ConfigDumpInfo paths retain their separate helper-owned cursor contract.
These are concrete loss risks, not a claim that every flagged replacement is wrong
or that an unflagged merge is semantically correct.

A parent that is already the clean three-way text result needs no replacement
decision. Identical new BSL methods or XML definitions added in different places
can also be deduplicated without a decision when their complete definitions match
and removing the additions restores the unchanged base. Different method bodies,
XML properties or existing element order do not qualify for this exception.

Restore compatible intent from both sides, inspect the affected callers/tests,
run the relevant checks, stage the repair and repeat the same ITL command.
Do not choose a whole parent merely to remove conflict markers. Do not manually
commit a lifecycle merge or change pending lifecycle state. The helper retains
its transaction and owns the eventual commit.

When authoritative evidence proves a replacement intentional, write the named
`decisions.json` as an object with `schemaVersion: 1`, the current report's
`planId`, and one `items` record for every report item. Each record must contain:

- `path` and `baseCommit` copied exactly from the item.
- `disposition`: `equivalent-result`, `superseded-by-authoritative-change`, or
  `authorized-incompatible-change`.
- `reason`: why the chosen result is correct for the requested work.
- `preservationEvidence`: account for the discarded side's changes, identifying
  retained equivalents or the authoritative requirement that supersedes them.
- `verificationEvidence`: concrete checks and outcomes relevant to those changes;
  distinguish static evidence from runtime proof and state material limitations.
- `userAuthorization`: the actual user decision, required only for
  `authorized-incompatible-change`.

The agent can decide proven-compatible/equivalent cases without asking again.
Ask the user only when evidence leaves incompatible business outcomes or an
intentional loss lacks authorization. Never fabricate authorization, test results
or an equivalence explanation to satisfy the file format. A structured decision
records an accountable analysis; it does not make an unsupported claim true.
Changed parents or any staged delta invalidate the decision. A successful
review retains the report and its evidence paths for the merge record.
Reports live in the common Git directory, separately keyed by checkout and merge
parents, so closing a linked worktree preserves its evidence and another checkout
cannot silently reuse its decision.
