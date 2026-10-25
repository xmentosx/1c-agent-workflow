# Current change verification

`ITL_VERIFICATION_MODEL=change` is the default for new and updated projects.
`cumulative` selects the previous catalog-wide assessment. Set it in the existing
project `.dev.env`; status reports the effective model. Switching starts no
runner and neither discards failures nor accepts pending task criteria.
`VERIFICATION_POLICY`, verification depth, UI/provider switches, named invocation
permission and repair budgets remain independent.

## Prepare one current plan

Use the existing helper action `begin-verification-change` without an evidence
path to inspect its accepted base, full unaccepted source delta and prior task
criteria. A new commit does not advance that base. Prepare the compact JSON in
the current ignored run directory, then invoke the same action with
`-VerificationEvidencePath <plan.json>`. This is a runtime record, not a new
planning document or a new user approval round.

For OpenSpec, reference the existing proposal/spec; include every AC, including
pending criteria. For a direct task, record its description and user-request
source in this same runtime record. Do not invent an OpenSpec change.

```json
{
  "taskId": "desktop-file-transfer",
  "requirementPaths": ["openspec/changes/desktop-file-transfer/proposal.md"],
  "checks": [{
    "id": "folder-result",
    "expectedResult": "The chosen folder contains the complete exported file",
    "inputPaths": ["src/cf/DataProcessors/Example/Forms/Export/Ext/**"],
    "admissibleProof": ["runtime-observation"]
  }],
  "paths": [{
    "path": "src/cf/DataProcessors/Example/Forms/Export/Ext/Module.bsl",
    "checkIds": ["folder-result"],
    "reason": "Check the changed folder selection, delivery and cancellation"
  }],
  "criteria": [
    {"id":"AC-01","expectedResult":"Files reach the chosen folder","decision":"check","checkIds":["folder-result"]},
    {"id":"AC-02","expectedResult":"Web delivery works","decision":"pending"}
  ],
  "retainedDispositions": []
}
```

Use actual project paths and the helper's exact path list, including deletions
and uncommitted edits. Each path needs a reason and sufficient current checks.
Instead of creating a new observation, `checks` may reference an existing
acceptance `suiteId` or default-fast `groupId`; use its existing obligation id in `checkIds`. A named explicit diagnostic run can supply a current one-off JUnit receipt; diagnostic status alone does not close acceptance.

The agent owns semantic sufficiency and impact analysis. Missing controls need
inspection of the actual form, not blind scenario rewrites. A product failure
remains a failure; do not change the expected outcome to make it pass. Unknown
mutation outcomes and foreign sessions retain their existing recovery rules.

## Execute and accept

Run the normal unfiltered `/itl-check` against the current branch copy. The
existing runner, applicability, event-log and load checks stay authoritative.
For a selected one-off observation, use `begin-one-off-proof`, perform the
authorized check, retain expected/actual evidence, then `complete-one-off-proof`.
No `.feature` is required for an admissible runtime observation.

Finish with `complete-verification-change`. It validates current receipts and
records an immutable accepted increment. A changed input after planning stops
completion and keeps the previous accepted base. Update the same plan and
continue; successful unchanged observations need not be repeated.

Task acceptance is separate. A criterion is `check`, `pending`, or `unaffected`.
`unaffected` requires a passed criterion from an accepted increment and an impact
rationale; it cannot excuse missing or failed proof. Retained suite dispositions
likewise require existing passed evidence. Shared/runtime full-coverage reasons
and an existing `always` policy cannot be narrowed this way. General load readiness always checks the current
whole source; it does not turn every historical observation into a new run.

Status distinguishes current-change checks from whole-task acceptance. Pending
criteria prevent an ordinary complete-result claim; warn/block and explicit
unverified-result handling keep their original policy. Switching to cumulative
does not erase a task remainder recorded in change mode.

The updater writes the default once using its existing transaction and rollback.
An explicit cumulative choice survives subsequent updates. Historical raw
evidence is retained; migration neither reruns it nor declares it newly passed.

At first adoption, a valid catalog one-off may be `unaffected` with its exact
expected result and impact reason. Prepare the plan before loading the new
source: the old receipt must still pass the existing input/loaded-target/checker
and artifact assessment. Missing or stale historical proof stays pending. The
accepted snapshot carries that history; it does not become a current runner.

Check inputs must belong to the existing 1C/test envelope or bounded catalog
input scopes. Declare an external source scope through the existing catalog
before planning; an ignored/unsnapshotted file cannot establish current proof.
The helper pins the latest accepted tree locally, even before a commit. An
explicit branch reset retires the active task into history through its existing
owner; ordinary commits and task labels cannot do so.
