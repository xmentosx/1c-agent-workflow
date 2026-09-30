# User-owned project templates during update

## Observed failure and authoritative behavior

The real published-master/r33 canary `build/r39-r33-preservation-34a0f8947bf84114bd7363bdeb2b90f0`
added legitimate user policy and memory notes without changing the old manifest.
The public update refused before copying with
`WORKFLOW_UPDATE_RULES_USER_MODIFIED: memory.md, USER-RULES.md`.
The unchanged manifest declares `USER-RULES.md`, `memory.md` and `LLM-RULES.md`
as project templates with `template=true` and a matching root source filename.

The controlled fork's `Place-RootTemplates` owner places these files once and
preserves existing content. Their original `installedHash` is not an ongoing
requirement that user notes remain identical to the shipped template. This
applies to both the original r33 layout and the new fork. D1 also requires the
user-owned portion of `USER-RULES.md` to survive migration. The preliminary ITL
guard incorrectly applied the managed-file hash rule to these three templates.

## Correction and preserved boundaries

One stateless predicate, `Test-AiRulesPlacedOnceProjectTemplate`, identifies
only those three existing root files, a real boolean `template=true`, an exact
corresponding root source filename, and strictly valid UTF-8 content. Both the
marked-file scan and root update preflight use this same predicate. It can
inspect an explicit project root for pending-merge validation.

This grants no replacement or deletion rights and changes no snapshot or
recovery state. It leaves legitimate user-modified manifest markers intact.
`Update-UserRules` still owns the ITL block; report-only override diagnosis and
blocking of the dependent action remain applicable. Ordinary rules, `AGENTS.md`
and executable assets retain their existing modification protection. Invalid
UTF-8 and an untrusted template declaration do not receive the exemption.

## Focused evidence and limits

The corrected legacy-lock reproducer failed all six cases before the fix and
passed after it: all three templates, with both marked and unmarked user edits.
`build/placed-once-project-template-legacy-lock-before.xml` retains the causal
before result. The first factory omitted the legacy dependency lock and did not
reach the same preflight in three cases; that incomplete result is retained in
`build/placed-once-project-template-before.xml` and is not the causal proof.

An existing `AiRulesMigration` expectation required `user-modified` even when
`USER-RULES.md` was explicitly a placed-once template. Its original text and
marker were preserved, and the expectation was split into two cases: a declared
template remains eligible with both files byte-exact; an undeclared managed
`USER-RULES.md` remains protected. The actual fork contract and original r33
manifest, rather than a passing-test preference, justify this correction.
The intermediate 8/9 result remains in
`build/placed-once-project-template-after.xml`.

The final focused selection passed 10/10 in 20.56 seconds, including edited
`AGENTS.md`, invalid managed-root UTF-8 and both USER-RULES ownership cases:
`build/placed-once-project-template-final.xml`. Four additional boundary cases
passed 4/4 in 2.73 seconds:
`build/placed-once-template-boundary.xml`. They retain protection for an
ordinary rule carrying `template=true`, a different declared source filename,
a string instead of a boolean template flag, and invalid bytes in an otherwise
declared template. File and manifest hashes remain unchanged and no snapshot
is created by the read-only guard.

The original real user-additions canary subsequently passed its public update,
repeat and guarded rollback with immutable C2. The user prefix, complete memory,
foreign MCP configuration, runtime environment and original helper were
preserved; rollback returned the exact original Git tree. See
[the published-master preservation proof](published-master-final-c-preservation.md).
This qualifies the placed-once correction on that original installed r33 case.
It does not close the other legacy variants in 9.4, constitute Targeted
registration, or authorize publication or updates of real projects. The
historical C929 payload remains unchanged for its recovery receipts.
