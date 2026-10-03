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

## Passed preliminary Full and stopped stand preparation

The canonical final-tag fork receipt now exists for exact `25b60321`,
upstream `refs/heads/main` at `c1fb8e6`: native Full passed 166/0/0 and all
18 stages, with clean/reusable evidence. Its qualification SHA256 is
`1c1437c52c50711c821f5767b0f529ff6fa71e38262f5fd2d7f9c7119a459393`.
The old explicit-ref receipt remains historical. The corrected actual workflow
consumer accepted the new receipt and rejected the old one.

Public RegisterChange for `2584738f` passed 140/0/0 in 583.430 seconds.
The next public PublishDevelop preliminary Full passed all eight stages and
all 110 Pester files: 2,329/0/0 in 577.715 seconds. Its retained receipt is
`build/c1-full-passed-2584738f/retention.json` in the publication checkout,
SHA256 `de3df3403c32798693f97b09c9b1818971dbd9bfc7df927cb92ab366ab7efa42`.
This qualifies source `2584738f`, tree
`66f7986d42b5926652e255691bbd9aa8b282b372`; it does not qualify final
Develop journeys or later source changes.

The existing evidence-backed promoter changed only the rules compatibility
status and timestamp, producing `c6c829b6`, tree
`e10ff12efa49258c74c8f988531b9db2513b1806`. The first invocation stopped at
the existing immutable-plan mismatch after promotion. Resumption with the
retained promoted plan restored that exact candidate. Release readiness then
correctly refused the old installed stand before starting Develop. Neither
attempt published a remote ref.

Preparing only the owned stand through the public source-side compact
`update-workflow` installed the c6/r40 files and committed the main scope.
The first registered branch reached `post-copy-running`, but the compact
runner stopped the operation with `RUNNER_STATUS_STALE` at the unchanged
120-second watchdog. The branch receipt and output still progressed while
the outer status stopped refreshing: the watched original helper was PID
17132, the fresh helper was PID 55396, and the last outer stage timestamp
was `2026-10-03T08:21:05.9923914+03:00`. The branch transaction updated at
08:22:56.688; the runner stopped its owned tree at 08:23:06.849. This is a
fresh-helper status-transport failure, not an exhausted overall deadline.

The original invocation and exact stdout/stderr are retained in
`build/c1-release-stand-update-c6c829b6/`. Main and branch snapshots keep
their exact c6 payload and phases. Recovery must use the existing update owner
from main, retain that payload, and then apply a newer candidate separately.
No receipt reset, lifecycle bypass, business merge, database update, UI or
saved Vanessa run is justified by this package-only failure.

The earlier 39-case file-only proof did not execute this compact fresh-process
watchdog boundary. Its source identity is retained; it is not promoted to
proof of the new fix. Any correction to a lifecycle/native helper also changes
the client_mcp native-build input inventory, so the old 61036 producer receipt
and CFE SHA cannot be relabelled as qualification of the correction. The
original stand continuation and a new exact-input native build remain required.

## Fresh-helper correction: bounded causal results

The existing fresh-process owner now gives each invocation a private diagnostic
status channel. The original parent remains the only writer of the compact
runner's external status and publishes through the existing native-wait monitor.
It relays actual terminal fields immediately, continues to relay a later terminal
failure, and never replaces a terminal result with running. The authoritative
lifecycle record, operation generation, original owner, locks, payload and
recovery phases stay unchanged. A nested legacy final writer is accepted only
when its PID and terminal status/exit also match that same authoritative operation.
Native output remains live through optional UTF-8 line callbacks; other native
capture callers retain their previous default behavior. The original absolute
deadline and owned process-tree cleanup remain enforced.

The initial exact-c6 fixture runs failed before entering the continuation.
Retained native stderr proved a separate legacy argument serialization defect:
`OperationOwnerPid` received the Cyrillic word `с` instead of an integer when
another argument contained whitespace, Cyrillic and a final backslash. These
results are argument-transport failures, not short watchdog reproductions.
The original argument and assertions remain in the regression; shared native
quoting supplies the correction. The actual unchanged c6 stand refusal above
remains the watchdog RED.

Native Windows PowerShell 5.1/Pester 5.8 selected 16 relevant cases. The first
correction batch passed 14 and failed 2 in 292.4685669 seconds, with captured
inputs unchanged. Its unchanged-watchdog case waited 126 seconds silently and
passed in 132.8915554 seconds. Receipt
`build/fresh-helper-native-wait-causal/after-2/result.json`, SHA256
`7391d1d670a55720b23294d2db015a692c954eeb83189249737b2fa4f887a33c`,
remains a partial batch, not an all-green qualification.

The two failures had concrete causes: the new caller read an OrderedDictionary
through a property-only accessor and missed the valid nested continuation PID;
the test read live stderr with a file-share mode incompatible with the writer.
Direct existing-record access and an explicit shared-read test stream corrected
these boundaries without changing workload or assertions. The two affected
cases then passed 2/0/0 in 25.7890747 seconds, inputs unchanged. Their distinct
receipt is `build/fresh-helper-native-wait-causal/after-nested-streaming/result.json`,
SHA256 `b096d5887c4b55d677c13852fa78a4b07c98385cef084cac366826a9202df4d0`.
These results are not arithmetically merged or relabelled as one exact-tree gate.
The source owner must qualify the final committed bytes through RegisterChange;
the stopped original stand update and exact-input native producer still require
their original acceptance paths. The additional 126-second regression explains
the measured focused-check cost; runtime watchdog and deadline budgets are not
increased.

Final formatting restored eight bare line feeds to the existing CRLF style in
the lifecycle implementation and test fixture, preserving BOM, non-EOL payload
and the token stream after EOL-only normalization. Native PS5 parsed all four
runtime/test files without errors. Historical focused hashes remain historical;
`build/fresh-helper-native-wait-causal/final-eol-freeze.json` records the change.
One separate ten-second native-transport observation measured 10.6073464 seconds
wall time for 10.096051 seconds of child work, 43 wait callbacks and 265.625 ms
parent CPU. It proved the exact Unicode/trailing-backslash argument round trip.
This is not a comparative benchmark or a measurement of the complete lifecycle
relay; `steady-native-capture-10s.json` preserves that scope explicitly.
