# Final c1 local qualification and publication continuation

## Exact file-only pair

The final file-only migration pair actually ran from registered clean source
`436842b6af159f3d23cdc852dccb0bcf88e7d318`, tree
`6c865cabad77b24b6f1180017c02bb57b57226c9`, through private source
`d177b3a278951eff32e5287b37247160149e9644`. That private transport preserves
the canonical controlled-fork repository and uses the existing clean local
source override; it does not change production pins or publication authority.

Fresh small file-only replicas preserve the original r33/master `c5fdcc4e`
and r36 `63e147bc` inputs and identical synthetic BOM/CRLF environment. Earlier
copies, completed capsules and failed transport evidence were not rewound or
deleted. The original complete 26 and 13 assertion scripts are byte-identical.

All 39 checks passed. r33 owner operations totalled 192.975 s, including first
update 113.527 s and rollback 55.406 s. r36 totalled 163.658 s, first update
106.216 s and rollback 53.366 s. Both original trees and environment bytes were
restored. Thirteen protected Git roots and 474 named hashes remained intact;
798 source files, including the 43 native producer inputs, remained frozen.
Actual client CFE `5222a74b`, source ZIP `409253c0` and producer provenance
`1d707689` are unchanged. Aggregate receipt:
`build/q23-lock-metadata-repeat/paired-file-only-qualification.json`, SHA256
`015e6bfc14c836ded769e714db8fdfc56487e01fc75190db86c45c1a1a3114a6`.

This evidence remains bound to source `436842b6`; subsequent test/document
changes do not rewrite its identity. It is file-only evidence, not live UI,
new-project bootstrap or public component availability.

## Full publication failure and narrow owning-test correction

Public PublishDevelop advanced beyond the former OpenSpec metadata blocker.
Its first compatibility Full failed at ImmutableDownloadRetry: 1,412 passed,
one failed, zero skipped; 57 completed result files from 110 planned files.
The other 53 lacked completed receipts and are not claimed passed. Source
remained clean, the queue remained `f5466e6 -> 436842b6`, and activeOperation
returned to null. Remote develop/master remained `f5466e6`/`69c0863b`; no
Develop journeys, component publication or push followed the failure.
Original Full logs, all shards and state are retained in the publication
checkout's `build/c1-full-red-436842b6/retention.json`, SHA256
`987009e7641165b733b7bc90412b3969d8917d230ac37dcda4b8446681d7950f`.

The assertion counted five immutable acquisition calls. Commit `692d72ac`
intentionally added the sixth in Save-VanessaMcpClientSourceBuildArtifact for
the approved exact native CFE provider; all five earlier routes are intact.
The correction changes only the owning test: it now requires the exact six
function owners, all five earlier routes once, and the new route once with
its Process-only source, active workflow pin, target, expected SHA and absence
of direct acquisition bypasses. Original ROCTUP, readiness, delivery and shard
GET checks, and all bytes outside this case, are preserved.

Native Windows PowerShell 5.1/Pester 5.8 reproduced the original case's RED
0/1 in 0.941 s, then passed the complete 14-case owning file in 2.865 s. All
38 captured inputs remained stable within each run; only the test changed
between RED/GREEN. Runtime, dependency pins and native producer inputs are
unchanged. Independent review found no material findings. Receipt:
`build/immutable-route-causal-f94e985578d341e8add19610421e7a82/qualification.json`,
SHA256 `49638a91a37cea0273a4819da019cd9a3d67c18b2fefd4b2d3c775444104c19b`.

Full/Develop/Release continuation and live EV9 remain pending; neither the
focused test nor the earlier passed migration pair promotes them to passed.

The existing vanessa-verification owner now selects ImmutableDownloadRetry
for changes to its owned Vanessa implementation. This closes the targeted
selection gap that allowed the producer addition to miss its static consumer
test. No new owner, gate or runtime check is introduced, and immutable helper
changes retain their existing seven-suite selection. The failed Full measured
this additional consumer suite at 4.707 s. A bounded static review of the 53
uncompleted suites found no additional confirmed stale assertions; they still
require actual Full qualification.

## Final-tag fork receipt and its source consumer

The next public attempt used source `f3736e07`, tree
`dc3467dd6d3d2431d5e0797d8734855f61238959`. Its source Pester inventory
completed all 110 files: 2,321 passed, zero failed and zero skipped. Overall
Full still failed: fork-check exhausted its existing 600-second budget.
Develop journeys and publication did not run. The original candidate, queue
and results are retained in the publication checkout's
`build/c1-full-pester-passed-fork-timeout-f3736e07/retention.json`, SHA256
`6dc7b36520d69f18c2b2d1ff63ab0bd12a5b45579809455ef7415a42a2d797c7`.
These passed source shards are not a passed Full or Develop result.

The historical native fork Full qualified exact commit `25b60321` with
`upstreamRef=explicit`, before its final annotated r40 tag. That tag declares
`refs/heads/main`, so the old receipt correctly fails canonical provenance
matching. Its measured duration was 762.583 seconds, exceeding the workflow
fallback budget. The old receipt is preserved unchanged; a separate actual
native Full from the final tag supplies new evidence. No timeout or acceptance
assertion is weakened.

The workflow consumer also expected exactly two script entries, whereas the
current fork Full producer and publisher qualify three, including
`scripts/full-check-contract.ps1`. The owning correction requires the exact
three-script inventory when that helper exists. A genuinely helper-absent
legacy fork retains its exact two-script contract. Existing commit/tree,
clean-state, upstream provenance, file hashes and JUnit checks remain intact.

Eight new cases invoke the real consumer extracted from its source AST.
Native Windows PowerShell 5.1/Pester 5.8 reproduced two causal failures
(6 passed, 2 failed), then passed all eight cases and the existing static
qualification case: 9 passed, zero failed/skipped, 1.414 seconds. All 39
captured inputs remained unchanged during each run. Receipt:
`build/fork-consumer-causal-49b963cdf6fb4f2b8be3505b589d670e/qualification.json`,
SHA256 `5dab49fe2d1ca707ac65e2022810a44ef620d2f78a74ab3388ac9b2e8a4cf387`.

The managed init reference now describes accepted Q21 behavior: the existing
update owner rolls out to eligible registered branches, defers live activity,
and resumes update recovery from master. Business-command continuation stays
separate. This is a documentation alignment, with no runtime or native-producer
change. The earlier 39-check migration proof keeps its original source identity;
it is not relabelled as an execution from this correction's head. Final-tag
Full, public delivery, fresh defaults and live EV9 still require their own
actual results.
