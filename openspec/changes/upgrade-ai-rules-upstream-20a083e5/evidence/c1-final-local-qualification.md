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

## New exact-input native producer

The coherent clean correction commit is `862406ca9c5430c13e601a1e5cb085acb3838d12`,
tree `1a95de71251d3e98cff50415678026a3a743c5c4`. The existing native builder
executed from that clean producer in a new unique output directory and private
service infobase. All 43 input hashes still matched after completion. The actual
modules, applicability and configuration Gate 6 steps each returned process exit
0 and dumpResult 0; the original DT was restored and owned processes released.

Actual CFE SHA256 is
`f454fd9b7cd75547346c2dabe871e39c19a6c0dc086ce91e53bc314d2ba65a77`.
The corresponding-source ZIP remains byte-identical at
`409253c0bc9abbbabf0797bde3a1316f8a95bfbdfbae0ec0709924eb24f95dcc`,
with the same 54 metadata files and source fingerprint
`sha256:997a67585cc064777162d2c66a14f99fa02780cb072aad3bc43272a6a3c66b13`.
The lock now pins these actual bytes. The CFE output is not assumed deterministic;
the unchanged source ZIP does not authorize reusing the old producer receipt.

New native provenance is retained in the publication checkout at
`build/third-party/client-mcp/v0.6.5-itl-r1/candidate-parent-862406ca/candidate.provenance.json`,
SHA256 `e1a676d5427f8939485813b5238f5d3912845177182b183df150fb0a7449af82`.
The public builder invocation and exact output are separately retained in
`build/c1-native-parent-862406ca/`. Earlier CFE/DT/provenance remain unchanged.
This native result is not final Develop/Release capability proof, remote asset
publication or installed live acceptance. Those original delivery paths remain
required.

## Stopped recovery and registration after 0bc3ff21

Public RegisterChange for exact commit
`0bc3ff2186db48fb18f17fcfcc24ac38c82e5115`, tree
`4ac4498b68ef436926957adcfed007870c78e63a`, failed at its existing
1200-second overall hard limit. The old successful pester-shards summary is
stale and is not evidence for this attempt. Current failed check-summary and
actual worker 56 output are retained in `build/c1-register-failed-0bc3ff21/`,
retention SHA256 `12a1417cbcb7036220ed0499506284eb03f2fea296e3e26be598dfc7ac2be066`.

The parallel cohort ran until 06:54:27Z; DevBranchLifecycle alone passed
295/0/0 in 917.257 seconds. The serial Compact worker then ran 25 passing cases
until 06:57:45Z. Its next fixture started one second before the overall deadline.
This demonstrates insufficient total gate capacity, not a proven hang in that
fixture. Test assertions, the Ctrl+C serialization boundary and installed
120-second stale watchdog remain unchanged. No passing exact Targeted record
was produced; the registered queue remains at 2584738f and activeOperation is
null according to public Status after failure.

The new executor also reached the original stopped main update without the
old stale-watchdog failure. It then failed because the existing receipt writer
replaced phase details during executor binding: aiRulesPathsBefore,
clientSurfacePathsBefore, preCommitHead and plannedChangePaths were lost.
The original snapshot 471126 remains master-committed with its source c6c829b
pinned. Its hash-bound before manifests and original single-parent Git commit
survive. Normal owner recovery must validate these proofs and preserve details;
empty defaults, direct receipt edits and replay of completed post-copy are not
acceptance. This observation is retained in `build/c1-recovery-old-payload-0bc3ff21/`
and does not qualify completion of the old update or publication of the new one.

## Receipt owner correction and source gate capacity

The receipt writer now retains prior nonreserved phase details before applying
explicit overrides. Reserved transaction fields still reject caller overrides.
Only the original master-committed executor-rebinding shape with all four
commit-detail fields absent permits reconstruction. The existing owner validates
recorded source and installed lock, every hash-bound before backup, current
snapshot state, branch, sole parent and exact update subject. It uses old AI and
client manifests, literal original snapshot capture and fixed workflow ownership;
current expanded claims, business paths and user OpenCode configs grant no rights.
The existing commit checkpoint runs before atomic receipt replacement. No package
post-copy, business merge, tests, UI or database load is replayed by reconstruction.

Read-only review of the actual original 1d3a52b8 -> 2b456cf3 commit confirmed
295/295 NUL-delimited paths against that independent ownership. The original
471126 transaction stayed byte-identical at SHA256
`d3503cf0` prefix until the later public continuation; this paragraph records
read-only scope proof, not successful live recovery.

Scoped native Windows PowerShell 5.1/Pester 5.8 proofs remain distinct:
original runtime RED 0/2 in 6.3260437 seconds; first correction 10/2 in
39.8846114 seconds; corrected reconstruction 1/0 in 5.507203 seconds;
negative boundaries 8/0 in 20.7592364 seconds. Inputs were unchanged per run.
The final freeze receipt is `build/workflow-receipt-details-causal/final-owner-freeze.json`,
SHA256 `f76c2246155aebadd4c7a17b53f1037890c95fd3e0804e29fbdb283cc03ad23c`.
Independent review found no material issues. These partial runs are not a whole
Rollback suite, exact Targeted pass or original stand completion.

Current source selection also owns the gate-capacity correction and therefore
contains 63 files, six more than the failed 57-file attempt. Its observed-component
capacity model is 1739.981 seconds including the mandatory serial Release tail.
The initially proposed 1800-second limit left only 60 seconds of model margin;
the final catalog allows 2100 seconds (35 minutes), leaving 360 seconds. This is
a composite capacity model, not a measured complete Compact49 or a promised run
duration. Source-only target stays five minutes; installed watchdogs, deadlines,
serial isolation, worker limits and no-progress checks are unchanged. Full already
allowed 2700 seconds; its old table entry is corrected to 45 minutes.

Original historical three/four-worker comparison at 1200 seconds is preserved.
Focused capacity tests and the initial fixture failure remain separate receipts.
Final2100 proof is `build/targeted-capacity-20261003/final2100/final-qualification.json`,
SHA256 `37a0708191e98231b067da0a0e64a37399ae4285c549cf6f7886326b306262f4`.
The current63 case passed 1/0 in 1.918 seconds with unchanged inputs. The normal
public RegisterChange is still required to qualify the coherent final commit.

## Native producer for e3b70610

The clean source correction e3b706106a30c9f06bc381782db975bd50a94e68
(tree 3f37ecffef3aab601ce1a56231bea234837c952a) ran the existing native
builder in a new private service base/output. All43 recorded input hashes
matched afterwards. Gate6 modules/applicability/configuration each passed
exitCode0/dumpResult0; original DT restored and owned processes released.
Actual CFE SHA256 is
`69cdd41c7052d12174760e399f5de2cfc8cf72174c57868839b7698c4ae397e2`;
source ZIP remains
`409253c0bc9abbbabf0797bde3a1316f8a95bfbdfbae0ec0709924eb24f95dcc`.
Native provenance at the delivery checkout
`build/third-party/client-mcp/v0.6.5-itl-r1/candidate-parent-e3b70610/candidate.provenance.json`
has SHA256 `cee01c5df2690662d9eb577fef1a0a68de811fd3f0d09e72aa389dd35adca653`.
Its public invocation/stdout/stderr are retained in `build/c1-native-parent-e3b70610/`.
The lock pins these actual bytes; earlier producers stay historical. No final
Develop/Release capability, component publication or live UI acceptance is
claimed by this native build.
## C5 exact client pin assertion correction

Public RegisterChange for c5bbc9830a356b60c339d32fe5382ead8a1a893f
failed after 1841.069 seconds. The final DependencyLocks worker reported
10 passed and one failure: its exact current-template assertion still expected
historical CFE `5222a74b...`, while the qualified E3 producer and C5 lock contain
`69cdd41c7052d12174760e399f5de2cfc8cf72174c57868839b7698c4ae397e2`.
The original worker plan/result/JUnit/stdout/stderr and failed gate summary are
retained under `build/c1-cfe-pin-assertion-causal/original-red/`.

Only that expected literal was updated. Other tuple/source/policy assertions
and historical fixtures are unchanged; the bounded current-test scan found no
other fixed `5222a74b...` expectation. All43 authoritative producer inputs match
E3 provenance in both source checkouts; actual CFE/source ZIP, all three Gate6
log/result hashes and recorded restored/released flags were independently checked.
No native rebuild, runtime or production pin change was needed.

The original affected case passed 1/0 in 1.751 seconds under native Windows
PowerShell 5.1/Pester 5.8, with strict UTF-8 output and 53 input hashes unchanged.
Its receipt is `build/c1-cfe-pin-assertion-causal/qualification.json`, SHA256
`b5d02acb8583cf92ec707cd45ecd3cfed33ba6d300fccf34279fc783640e1caa`.
This is focused test-contract correction, not a passed retry of the source gate.
## Managed package Python cache transport correction

The public candidate `31d65d9a81df459abd88e8d8bc07309b` (source `8e8abb04`, tree
`00e88942`) stopped at Release preflight before gates or push. The dedicated main
stand contained 16 **tracked** remote-runner `__pycache__/*.cpython-313.pyc` files;
all 16 SHA256 values exactly matched ignored Python output in the source delivery
checkout S. The clean candidate and H contained none. The installed commit
`8af83dd67390b2a05278095fa862f95b33243a09` had admitted them during the C5 package
update. The separate installed C5 versus candidate8e8 workflow identity mismatch
still requires the ordinary exact-candidate update; this fix does not waive it.

One stateless package-content predicate now applies the existing source
`__pycache__/` and `*.pyc` policy to bootstrap copying, package-only staged update
copying, managed-worktree execution-guard cutover and Release package inventory. The installed ignore template and fallback
prevent subsequent generated cache from becoming new package content. Snapshot,
raw replacement and rollback retain their original byte-preserving behavior;
tracked historical cache deletions remain in the existing commit owner's scope.
Real `.py` changes still fail managed-package agreement. No state, schema, gate,
coordinator or new runtime authority was introduced.

Causal evidence is under `build/package-content-causal`: the first run retained a
real update-copy RED and an incomplete bootstrap AST-fixture setup failure. A
second bootstrap setup failure is retained separately; the completed fixture's
`red-bootstrap-complete` run then reproduced the same real cache-copy RED without
runtime changes. The connected native Windows PowerShell 5.1/Pester 5.8 batch
passed **6/0/0 in 16.144 s**, including historical tracked-cache retirement with
staged/unmerged business entries preserved, raw backup restoration, and the
unchanged atomic-copy failure and equivalent-stat regressions. After explicit
hidden-dotfile, empty Unicode-directory and legacy-template assertions were added,
only the four affected bootstrap/copy cases ran again: **4/0/0 in 7.295 s**.
These are separate input versions, not a newly claimed combined whole-file run.
Both runs retained strict UTF-8 stdout/stderr and unchanged captured inputs.

`build/package-content-causal/ownership/selection.json` records the actual pure
resolver result: changing only the shared module selects the existing lifecycle,
bootstrap-update and source-quality-gate contracts; bootstrap, rollback and
readiness all include it in their owner input sets. No owner test lists or budgets
changed. Historical cache reuse is not claimed. Readiness's separate causal and
positive results remain under `build/package-cache-readiness-causal`.

This source change alters native producer inputs, now 44 through the existing
authoritative getter. The earlier `69cdd41c...` build remains historical proof of
its recorded producer; it does not qualify this changed runtime. A new native
build, ordinary registration and the original public continuation remain pending.
The existing execution-guard cutover is a fourth package ingress: it copies from
main/source into managed child worktrees before its existing temporary-index
commit. It now consumes the same predicate for directory copying; file copying,
cutover state and guards are unchanged. Its actual existing managed-worktree
fixture reproduces regeneration in the source and historical tracked bytecode in
the branch. `cutover-red-correct-scope` failed the cache-absence assertion;
`cutover-green-correct-scope` passed **1/0/0 in 8.976 s**, retaining all original
assertions and exact staged business, main/source and unrelated-worktree bytes.
The two earlier cutover attempts are retained as an incorrect newly added test
expectation: cutover intentionally does not replace main itself, so requiring
main cache removal was invalid. Only that new assertion's scope was corrected;
the fixture paths, workload and original assertions were retained.
Review additionally reproduced a completed-rollback boundary: when an older
package had force-tracked bytecode despite its ignore rule, raw restoration
recovered the file but the inverse commit omitted it. The unchanged public
rollback path now supplies its recorded `preUpdateHead`, after the existing rollback checks, to the commit
planner. Only prior tracked, currently ignored, existing restored files inside
the snapshot write-set are force-staged as exact literals in the temporary
index; execution runtime stays excluded. Ordinary planning has no new input or
forced adoption. A file that was never tracked remains outside Git even when its
raw backup is restored. No receipt schema or recovery transition changed.

`completed-rollback-red-parsed-assertion` proves the missing original HEAD entry
before this correction; an earlier assertion-syntax mistake is retained in
`completed-rollback-red`. The same public rollback plus the original completed
rollback/business-index and default unmerged-index cases passed **3/0/0 in
18.762 s**. The new case checks exact original HEAD tree, blob/mode/index, raw
tracked and untracked cache bytes, business staging, and idempotent repetition.
After that batch, review removed an accidental duplicate fixture setup from an
unrelated receipt-recovery fixture; its normalized function AST was restored
exactly to the original HEAD (`unrelated-fixture-restoration.json`). The exercised
rollback and default fixture bodies and runtime remained unchanged. These focused
receipts and earlier copy/cutover runs retain their actual input identities;
final exact-source registration and native qualification are still pending.

## Native producer after package-content correction

Clean producer `26c72eb82ab9bc15fcdeb3c6762f9e70c6e3ec3e`, tree
`fc5fa690b5b560ea6222508c8010752c3d06c21a`, passed the existing native builder
and all three Gate6 steps (modules, applicability and configuration, each
exitCode0/dumpResult0). All44 recorded inputs match both clean source checkouts;
original DT restoration and owned process release are confirmed. Actual CFE
SHA256 is `29f741db8a379384cd8270398761ec96e7e8e548071a0c180d4ffc6ddd8443b6`;
source ZIP remains `409253c0bc9abbbabf0797bde3a1316f8a95bfbdfbae0ec0709924eb24f95dcc`.
Native provenance in the delivery checkout's
`build/third-party/client-mcp/v0.6.5-itl-r1/candidate-parent-26c72eb8/candidate.provenance.json`
has SHA256 `e87531d5c9e71236dd8c505305b82ae50a30fedbd80c06233f83003e8f87a871`.
The invocation, stdout/stderr and independent input/asset/Gate6 verification are
retained in `build/c1-native-parent-26c72eb8/`. The production lock and existing
exact pin assertion now refer to these actual bytes. Previous producers and
failed-publication receipts remain historical evidence. Registration, public
Develop qualification, component publication and live essential UI acceptance
remain separate, pending steps.

## Registration diagnostics and fixture dependency correction

The first `f66243cb` registration stopped with 562 passed and one failed case:
the original UTF-8 stdout read received a sharing violation after child exit.
Its retained failure and one unchanged native-PS5 focused pass are separate;
the historical holder remains unknown and no runtime fix is claimed.
The next public registration executed the whole DesignerMemoryGuard file,
passing all 10 cases, and the rollback file, passing all 52 cases. That registration
stopped separately at 1038 passed/two failed cases in PendingMergeWorkflowTransition.
Both synthetic initial installs copied the current cutover script without its
new sibling library while explicitly mocking out ordinary package copying.
Production bootstrap/update/cutover copy the complete workflow directory;
recovery executes the recorded target's own script. The two initial fixture
installs now include the real library before their base commits. The original
move, stopped operation, business staging, write-set and all 172 Should AST
expressions remain unchanged. The four affected original cases passed 4/0/0
in 26.508 s on Windows PowerShell 5.1/Pester 5.8, with 56 captured inputs unchanged.
Proof is retained in `build/pending-merge-cutover-fixture-causal/focused/`;
`result.json` SHA256 is `b2206f1f8572bf1455fe916915a9ff53387a0f8cfae1cdc201c6b1108afae42d`.
The failed 1040-case gate is retained in
`build/c1-register-f66243cb-diagnostic-retry-failed-final/`; its retention SHA256
is `e2c007bb89421cede67d6cea013699764ee078fff58a884ff702047c7c62d821`.
Only fixture setup and this evidence changed; all 44 native producer inputs and
the qualified 29f CFE remain unchanged. Final registration/publication remain pending.

## Registered 6a candidate and original upgrade continuation failure

Public RegisterChange subsequently passed for clean commit
`6a98343c770ad60a0eea566adcea777519533301`, tree
`c80f4a4292942f964b7d9881c5de525f2c6126e3`: 1120 passed, zero failed/skipped,
48 selected files (36 executed, 12 reused), 1663.441 seconds. All 11 original
PendingMergeWorkflowTransition cases passed. The immutable local receipt is
`build/c1-register-passed-6a98343c/retention.json`.

The ordinary public update installed that exact candidate in the master and
seven existing development worktrees. All eight remained tracked-clean, with
zero changes under `src/cf`/`src/cfe`, zero tracked Python cache artifacts and
`UI_TESTING=essential`. This proves file-only installation, not refresh or UI
verification. The family receipt
`build/c1-stand-update-6a98343c/family-qualification.json` has SHA256
`20b432688f5d3321ce83378bd1f9abcaa2fdcc6c51bf8374ffa6b12ced0df3d5`.

The first actual Develop attempt stopped before Pester/static qualification.
Its upgrade update passed; ordinary branch refresh returned the documented
manifest-only merge conflict. The independent branch and master updates share
the r36 ancestor `1d3a52b8dfa862f09594de89d95b566d5d7ab014`. All 302 common
manifest file entries agree. The branch also owns generated
`openspec/project.md`; timestamps and recorded foreign command lists differ.
Taking the whole master manifest would discard branch intent. The existing
branch-lifecycle contract requires semantic repair, staging and the same public
refresh command; the unattended journey had no implementation of that step.
The original ten raw logs/reports and publication-attempt record are retained
under `build/c1-publish-failed-6a98343c-upgrade/`, with retention SHA256
`0a0836475af76384ca3ef0eb58fcc7caec36bc189a6a4552ead1833c7cd926cf`.

A read-only proposal reconstructed from immutable parents preserves the branch
generated context and compatible foreign lists. The existing strict
Test-AiRulesPendingMergeManifestProvenance admitted it against actual branch
bytes, without changing its HEAD. That diagnostic receipt
`build/upgrade-refresh-conflict-causal/read-only-proposal-qualification.json`
has SHA256 `d6838e9debc18cd7455800bebde2d5d75660ab79bbde25546644b60b5a7e383a`.
It is causal evidence, not a successful live refresh. The repair belongs only
to the source acceptance driver; production merge guards, fixture ancestry,
workflow runtime and the 44 qualified native build inputs remain unchanged.
Fresh Develop/Release, publication and essential UI proof remain pending.

## Source acceptance driver and current Q24 owner checks

The source driver now attempts the existing semantic continuation only for the
recorded manifest-only conflict. Exact pending transaction parents and all three
Git index stages must agree; the installed provenance verifier admits the
proposal before its sole manifest write/staging. Unknown metadata, ownership,
hashes, other conflicts or a later edit preserve the original failure. The same
public refresh completes the merge; source repair creates no merge commit and
does not change lifecycle state. Original verification/export assertions remain.

Focused native PS5/Pester evidence is deliberately separate: the first selected
batch executed 12 cases (30 discovered), with 11 passed and one failing mock
recursion fixture, in 314.3934913 seconds. The fixture-only late-edit injection
correction passed that exact case, 1/0 in 37.4506312 seconds. The corrected fresh
seed excludes only UI_TESTING from copied stand settings, preserving the Vanessa
switch and other setup. Its actual extracted provision AST passed the original
structured-journey case, 1/0 in 1.0498371 seconds. All captured inputs were stable;
no aggregate new 12/0 gate is claimed. Final distinct-run receipt SHA256 is
`8ca208ebe86c11a0c57ddd0a1dbfb1b79f2b7bb1f9b37dc7ca5bca6eff1297c4`, in
`build/upgrade-refresh-conflict-causal/source-driver-focused/final-qualification.json`.

The current Q24 directly owned native batch passed all 139 cases in five whole
files: OpenCodeConfigLayers21, ClientJsonc34, MultiClientMcpOwnership25,
LayeredClientObservation7 and WorkflowUpdateRollback52. It had zero failures,
skips or NotRun, took 270.8616077 seconds and retained all 57 input hashes. This
is working-tree owner proof with only the three named source/evidence changes,
not a clean-tree Full result. Its result SHA256 is
`63fff9adee23afba00cbe611815bd0f367fdd1694d69e93c9e58bd91efd0064e`, in
`build/q24-final-current-runtime-qualification/result.json`.
The original ClientAdapters root configuration case also passed separately,
1/0/0 in 3.0022859 seconds with 58 input hashes unchanged. The remaining 40 cases
were intentionally excluded; that ignored driver's inherited whole-file NotRun
rule returned exit1. Its raw result/JUnit remain unchanged, and neither a whole
ClientAdapters pass nor a combined 140-case gate is claimed.

Final public registration must qualify this coherent clean source candidate.
The changed source driver, its tests and this evidence are outside all 44 native
producer inputs; the qualified CFE/source ZIP remain valid. Live fresh default,
Develop/Release qualification and publication are still required.

## 2026-10-03: restore the qualified Vanessa pair to the production pins

Public registration of clean `db12e9d7`, tree
`547e82ac9ba3c249d32b63fc7a6bdcda5b5f135c`, passed 135 owner checks with
zero failures. The ordinary file-only update then passed for all eight owned
stand roots: exact workflow/rules/client identities, clean tracked state,
zero changed `src/cf` or `src/cfe` paths, and unchanged UI/Vanessa settings.
The stopped refresh retained target `56f477c8`; its updated branch anchor was
recorded by the existing owner. Receipt
`build/c1-stand-update-db12e9d7/family-qualification.json` has SHA256
`67e83eb5683c8156b712bf9317a2228f39b91f64a6cef17ca21cf6dc9bb5aea7`.

Actual Develop resumed that refresh successfully through the documented
semantic repair and repeated public command. The original target and subsequent
refresh to current master both passed, with unchanged configuration fingerprints
and Designer skipped. The following original unfiltered check failed: native
Gate 6 configuration result 101 reported the same seven old VAExtension
diagnostics retained in `va-extension-html-handlers.md`. Static/Full, fresh,
Release and publication were not reached. Immutable failed-run retention is
`build/c1-publish-failed-db12e9d7-gate6/retention.json`, SHA256
`68a5493675b9608c96cf08e65fd9372840b31c49bc9b443ab8218d6302708b4f`.

The candidate still pinned the published r1 pair. Update and native load logs,
installed locks and actual cached CFE hashes all agree; this was production
dependency selection, not an unexplained stale cache. The Gate 6 arguments are
unchanged from the pre-c1 owner. The already qualified r4 correction had been
left unpublished and had not yet been promoted to the production lock.

The bounded correction promotes both existing Vanessa lock tuples together to
r4 and updates their five existing golden assertions. It preserves the version,
protocol, client29 and every other dependency. No runtime, BSL, check flags,
scenario, paths, workload or native producer source is changed. The original
r1 result stays failed; its pin expectation is superseded by the accepted,
qualified component correction described in `vanessa-native-acceptance.md`.

The exact immutable r4 archive is SHA256
`84aabfbf77511abd432c235625afb543aa3c182654e08a24bda3c4312c7d5f4c`;
its EPF is `b1e5d7111115b6cea4fdf64774f31de2f485579f024e6af81c2b361ecabd4e1b`
and paired CFE is
`24190cb07ad82ac49aacdd86c1fb6412cd2f6713758cde123b1bb4103b7b4c0c`.
Archive entries, embedded manifest, patch and component build sources match the
retained producer `c281b5f2`, its native three-step pass and three runtime cases.
This reuses an exact historical artifact; it does not claim a new producer or
unchanged generic helper inputs. Existing delivery extracts and verifies the
paired CFE, selects required `extension-smoke`/`config-cadence` capabilities,
and publishes the pair only after current candidate qualification. The separate
`ondemand-mcp` capability and its two-backend acceptance remain required.
The retained causal/admission receipt is
`build/vanessa-r4-production-pin-causal/admission.json`, SHA256
`05272c322ba2556ec2aaaa2e446643c5383b18fcd793bfcba3d56fefc7f913ff`.

The next candidate still requires public registration, the same unfiltered
stand check, fresh default/UI acceptance and all selected publication stages.

The first repin commit `792cdff6`, tree
`4922e3260d4aeafbf41b03ed107564be90610810`, did not register: Targeted
retained 55 passes, six failures and zero skips. Five failures still expected
production r1 literals; the sixth fixture archive still contained the r1 paired
filename while its copied current lock correctly required r4. Original results
and logs remain in `build/c1-register-failed-792cdff6/retention.json`, SHA256
`30b94aa91a2f7b3010463a924aa8ea25d8e2edcd5cad33a0bab3f47785b84fff`.

The follow-up completes current production consumers in the artifact integration,
GitHub fallback, MCP configuration and generated on-demand manifest tests, plus
the bootstrap fixture's canonical archive fallback. It changes exact current
pin expectations and the paired fixture filename, preserving test identities,
assertions, negative cases, mocked transport, Unicode paths and workloads.
Independent historical r1 component/own-lock fixtures remain unchanged.
The production-source search found no remaining old pair literals in runtime,
scripts, templates or Go sources; no runtime or build edit is needed.
The failed registration is not relabelled as passed, and the follow-up still
requires its own public registration and current live publication qualification.
Static follow-up receipt
`build/vanessa-r4-production-pin-causal/test-consumers-792cdff6/amendment.json`
has SHA256 `f8630a542410082536e7be51221dfd3ec4ba510029461449c441f9e8abb4adbc`:
27 literal-line updates in five test files, 1675 Should commands and 206 It
declarations preserved, native PS5 parse0, original BOM/CRLF and all 44 runtime
inputs unchanged. This is static preservation evidence, not test execution.
