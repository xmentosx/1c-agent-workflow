# Native input scope and independent workflow update workers

The accepted baseline is accumulated candidate
`56909a895fb547fd9bc39a1e1b40bcb7766c3738`, tree
`6013005b8062f5d10b6f5253689d07804ba099ba`. Its advisory plan
`c9a66a09c65b442582c79ad1be034a1d323c8a56408818ce60fc356622971262`
estimated 8838 seconds with 129 Pester executions / 67 reusable files. The
monolithic WorkflowUpdateRollback scheduler weight was 1110 seconds.

## Consumed native inputs

The main `1c-workflow/SKILL.md` is installed guidance. Native code checks skill
presence but does not interpret its body. Only content changes with an existing
historical/current file can avoid selection. Both source inventories and original
SHA remain authenticated during reuse; missing/new input cannot acquire old proof.
`1c-workflow-fast/SKILL.md` is different: `Get-KiloFastSkillProvenance` reads its
contract marker and SHA. It retains exact binding. Unknown instructions remain
conservative. Current static package-copy/presence proof is still required.

Product context is lazily imported behind configured productProject / pending
operation / explicit catalog dispatch. Develop requests no catalog operation.
The existing input identity observes main, develop and positive roots, their
configuration hashes and pending operations. The new catalog flag
`outsideWhenNoProductContext` requires `requiresNoProductContext=true`; it excludes
only the explicitly audited function names in the product-context module, and only
when all observed roots are known disabled. Unknown functions, ambient changes,
enabled context and pending/unknown context retain native proof dependencies.
The selector remains conservative without stand facts; the native proof owner
decides reuse using the complete authenticated binding.

Regressions exercise actual source modules and immutable native proof receipts:
main guidance content reuse, fast-skill rejection, missing file and forged old SHA,
disabled product context with both stand layouts, positive-root context changes,
unknown functions and enabled/pending/unknown context. No assertion, native runner,
artifact admission, rollback or runtime guard was relaxed.

## Preserved workflow scenarios

PowerShell AST extraction moved all 49 original It definitions verbatim, including
their full parameterized case data, into 11 workers. Shared fixture function bodies
were preserved in WorkflowUpdateRollback.TestSupport.ps1. A one-time exact-string
comparison of the old/new It multisets passed. Existing Describe setup, per-case
hooks, reproducer paths, native child calls and negative controls were preserved.
All **90 expanded cases passed**, no skips or failures, through the production
shard runner with four workers. Wall worker span was **375966 ms**. This is an
actual focused run; the old 1110-second number is the prior scheduler weight,
not a freshly rerun old monolith.

| Worker | Passed cases | Observed ms | New weight seconds |
| --- | ---: | ---: | ---: |
| Rollback | 9 | 81384 | 82 |
| CommitRecovery | 10 | 77455 | 78 |
| Finalization | 4 | 38795 | 39 |
| Handoff | 10 | 45498 | 46 |
| LegacyRecovery | 18 | 335874 | 336 |
| LegacyRetirement | 9 | 105627 | 106 |
| OpenCodeSnapshot | 7 | 36518 | 37 |
| ReceiptRecovery | 10 | 33328 | 34 |
| Reconciliation | 3 | 15054 | 16 |
| SnapshotStatus | 2 | 5770 | 6 |
| SourceCutover | 8 | 9412 | 10 |

The shared producer contract retains every previous production input, the complete
loaded helper library closure, templates and Git transport. Unloaded sibling test
files no longer invalidate each other. Each test file selects its own worker;
producer/fixture changes still select all actual consumers. The historical cohort
capacity assertions retain their old measurements and separately count the ten
newly extracted workers. No deadline or worker count changed.

Production cache regressions independently prove two-worker cold execution,
one-worker execution plus one reuse after a sibling edit, and two executions after
a shared fixture edit. The actual workflow cases above run separately from those
small cache fixtures. Registration remains responsible for Targeted on the combined
candidate; no Full, Develop, Release or publication is authorized by this change.
