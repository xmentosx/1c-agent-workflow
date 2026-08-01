# ai_rules_1c r22 develop publication

The controlled fork release `itl-main-410951e7-r22` was rebuilt from the exact
r21 baseline while retaining upstream
`410951e74fd3e6b7a763cf49757935b9a34d3f31`. It was published at fork commit
`bcd94d1723f26a0b0568869845484c8572c402a6`.

The release separates `executionPath=quick-fix|full-cycle` from
`planningMode=direct|OpenSpec` and makes direct planning the default. OpenSpec
apply now loads the full subagent pipeline only after implementation delegation
is selected; direct apply keeps compact structural spec-compliance and the same
closing verification contract.

Recorded fork evidence: schema-3 verification for all 118 path decisions on the
clean commit, focused triage/workflow/installer tests 40/40, fork Full 71/71,
and an atomic immutable branch/tag publication. The workflow lock remains
`compatibilityStatus=pending` on `develop`; Full can qualify it only with the
explicit local r22 checkout, and promotion to `passed` remains a separate
evidence-recording action.
