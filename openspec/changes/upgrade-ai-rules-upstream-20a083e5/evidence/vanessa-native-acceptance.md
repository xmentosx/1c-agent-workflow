# Vanessa qualification and the original refresh

## Why Vanessa appeared in this migration

The ai_rules intake did not introduce Vanessa 42. The separate workflow change
`57e36ab77d49374fdc6b07fcdec9a0b76470e2c2` upgraded it on 2026-09-26;
`a46f47d3ebedd7c4141cb6f9bd37e5f4f5062b6a` completed the selected-feature
patch and repin on 2026-09-27. Those artifacts were locally qualified and
registered, not proof of installation in every application configuration.

The agreed migration checks adopted metadata and extension applicability through
Gate 6 before applying an extension. The original stopped PM5 refresh exercised
this path and exposed inherited missing HTML form handlers and source-reference
diagnostics. A workflow-only update does not itself start 1C or Gate 6.

The cumulative `1.2.043.42-itl-r4` patch removes only the two orphan HTML commands
and their buttons; it preserves the executable form actions. Name-bound access
to the two supported system forms preserves their platform URIs and the
existing open/callback/block/close sequence. Unknown names fail before platform
form access. The report lookup retains the existing call arguments and fallback.
Full-index patch output makes the existing native resume SHA deterministic.
These are bounded component corrections, not a replacement Vanessa lifecycle.

## Observed native component result

The exact producer commit is `c281b5f2c74d5987127678e8ffb394562132aea9`,
tree `d619ef17523f1d5a6049251fdaa7a95db60a0fe3`. Producer inputs and the
original failed artifacts are retained. The supported resume reused the 145
already compiled EPFs, finished the unchanged 210-EPF workload, and released
its native owner. No licensing error was reclassified as a success.

The paired EPF SHA256 is
`b1e5d7111115b6cea4fdf64774f31de2f485579f024e6af81c2b361ecabd4e1b`;
the CFE SHA256 is
`24190cb07ad82ac49aacdd86c1fb6412cd2f6713758cde123b1bb4103b7b4c0c`.
The native checks used the original module, extension-applicability and
configuration-integrity arguments, including reference and extended-module
checks: all three passed with zero errors and warnings. Three real runtime
cases passed: the two supported system forms opened, blocked and closed, and
an unknown name was rejected. This does not qualify the separately observed
SelectedForm callback diagnostic; its original failed evidence stays unchanged
and it is not an established migration blocker.

`build/vanessa-r4-native-pair-qualified-20261001.json`, SHA256
`770cb365881d7541480b8107034d898f7c5d101a474d9a32cd56da7cd2cd4b83`,
binds the producer, native checks and runtime JUnit. Production dependency pins
and publication are separate from these unpublished local artifacts.

## Original PM5 attempt 3 and the checker defect

The single public workflow update installed private fixture
`f0d707744b62ac00e3315e05575b3434ad29c3f5` in the owned main and working
roots. Configuration/test bytes, infobase files and the stopped operation's
state were unchanged by the update. The original target remained
`ae6911539de91b2f60fc6ef420acafdacb995a37`; repair session
`fc750d84db284a789f4f474407094cbb` retained its five-attempt budget.

Attempt 3 used the same unfiltered public check. Source loading was skipped
because the configuration fingerprint matched. Gate 6 installed the qualified
pair; the real PM5 TestClient scenario passed, JUnit 1/1 with zero failures,
errors and skips. The event-log check found no blocking new error signatures;
its nine non-blocking warnings and fallback cursor scan are retained.

The final assessment nevertheless stayed partial. This was a defect in our
new per-suite coverage checker: it expected the feature filename as JUnit
`classname`, whereas the pinned producer emits the `Функционал`/`Feature`
title, optionally prefixed by the first relative directory. Exact producer
sources confirm header replacement in FeatureReader lines 3111-3117 and
the component parser line 458; the report emitter uses that node name at
VanessaAutomation ObjectModule lines 2801-2804 and 2869. Filename is only a
temporary node name before valid parsing, not an accepted reporting mode.

Six native Windows PowerShell regressions reproduced the wrong title mapping,
false acceptance of a fabricated basename, selected/unselected title collisions,
directory-qualified titles and duplicated case counts. Original scenario bodies,
paths and guard assertions are retained; fabricated fixture naming metadata was
corrected to the actual producer contract. The owner now obtains the title from
its existing feature parser and resolves against all declared suites. Ambiguous,
missing and duplicate cases remain unverified.

The directly owned native Windows PowerShell batch then passed 37/37 cases,
zero failures/skips, in 107.28 seconds: aggregate assessment, suite selection
and explicit-proof reuse. No native application launch is added by the fix.

Read-only before/after assessment of the same original attempt-3 JUnit changed
coverage from 0/1 partial to 1/1 passed, without modifying the feature, catalog,
JUnit or live state. Records are
`build/native-junit-coverage-{before,after}-title-fix-20261001.json`.
This causal proof does not finish the pending refresh: the corrected package
must still continue the original operation through its existing public owner
and repair session. Tasks 9.7 and 10.4 remain open until that actual completion.

## Original PM5 attempt 4: complete proof, pending refresh

The public main-root workflow update installed private fixture
`83207e00552cd0b707f97ef5fb20ff592a84a84c`, based on registered source
`6b525d1eb628701d9ce7017f161819fe11bee99b`. Its independent qualification
confirmed unchanged configuration/test bytes, infobase hash/size/mtime and
pending refresh/repair state. Only the two qualified client artifact PATH/SHA
fields changed in the environment. Update time was 131.39 seconds.

The same repair session then consumed attempt 4 of 5. Native extension checks
passed, the unchanged PM5 scenario passed 1/1 without failures/errors/skips,
and the event-log check found no blocking new signatures. Two non-blocking
warnings remain in the cursor-based observation. The actual verifier returned
`isFreshPassed=true`; the repair owner wrote `passed`, preserving session and
budget. The public run took 343.87 seconds including installation and checking.

The enclosing acceptance driver nevertheless failed because original target A
was still pending at stage `merged`. This was a separate migration defect in
`Complete-PendingDevBranchRefreshAfterVerifiedRecovery`: it accepted only
the legacy `full` evidence kind. The canonical verifier now writes
`complete/current-obligations` after assessing all current obligations; the
repair owner already accepts both complete kinds. The loaded configuration and
normalization were passed, and verification followed the configuration update.
This is not another Vanessa failure or a reason to rerun its successful scenario.

`build/pm5-original-refresh-title-attempt4-20261001.json` preserves the failed
enclosing result and the actual successful verifier/repair results. They must
not be relabelled as completion. The lifecycle consumer must accept the same
complete proof contract while retaining freshness, loaded-base, normalization,
timestamp and merge/target identity checks; diagnostic, partial or unknown kinds
remain insufficient. Continuing that original pending operation and D4 export
acceptance remain required.

The existing real-Git continuation fixture reproduced this specific consumer
failure: 15/18 passed; the three `complete/current-obligations` cases passed
actual freshness and then failed the expected completion assertion. Legacy
full, status-only/stale refusals and diagnostic/partial/unknown refusals stayed
intact. Two earlier harness limitations are preserved separately and are not
counted as the causal RED. After the single acceptance-condition correction,
the same 18 native Windows PowerShell/Pester cases passed without skips in
86.71 seconds. No state, runner, budget or merge guard was changed.
Frozen RED/GREEN records are
`build/pending-refresh-evidence-kind-{red-20261001-attempt3,green-20261001}/`.
GREEN receipt SHA256 is
`6ccc4d6fb5b0bf1e22e853dfaa9b119c02815436e988cba5f674ffc42c9fbf32`.
The installed original continuation remains separate from this source proof.

The first registration of that consumer fix (`cdff9df6`) failed before queue
registration. All 254 lifecycle cases passed. The bootstrap/update shard failed
while cloning the complete source fixture into the normal Windows TEMP path:
Git returned 128, `Filename too long`, before invoking the updater. The source
run is preserved in `build/source-registration-failed-cdff9df6-20261001/`; its
delivery-level zero test totals are not a claim that the shard cases did not run.

The fixture clone now explicitly enables Git's existing `core.longpaths`
support for that clone and its repository. The TEMP path, complete metadata
fixture, update operation and assertions are unchanged; no user/global Git
configuration is modified. The same failed update case then passed 1/1 without
failures/skips in 35.64 seconds under native Windows PowerShell 5.1/Pester 5.8,
using the same normal TEMP directory. This corrects test setup rather than
Vanessa or the installed workflow. The focused record is
`build/bootstrap-longpath-20261001/result.json`. Source registration and the
installed original continuation still require their own successful results.

## Workflow rollback content detection

Registration of `30309559` passed 727 cases and failed one existing workflow
rollback case: the owner reported a restored commit, but HEAD still contained
the newer package. This was a Git workflow defect, separate from Vanessa.
The preserved registration is in
`build/source-registration-failed-30309559-20261001/`.

A separate real-Git regression made the cause deterministic with supported
repository-local `core.trustctime=false` / `core.checkStat=minimal`: old and new
package bytes had equal length and the restored timestamp matched the index.
The existing change selector returned no changed paths despite different actual
content and HEAD blobs. The causal RED and read-only index observations are in
`build/workflow-rollback-stat-observer-20261001/run-e290f66a2c5b4beb8130ef4715503985/`;
observation SHA256 is
`77e56b7c6618df2b91c6a3f612746bff3d56015d1823f209d86c73375f2dfddf`.

The existing branch commit planner now reads allowed tracked and nonignored
untracked content into its fresh temporary index. Immutable tree differences
identify content changes; captured owned staged differences retain the existing
index reconciliation behavior. The actual index is not used as a stat-based
content selector. Apply-time HEAD/index/pending-merge guards, literal/NUL path
handling, business staging and runtime untracking remain with the same owner.
No additional lifecycle state, native 1C call or blocking policy was added.

The native Windows PowerShell 5.1/Pester 5.8 directly owned batch passed all
19 rollback and stopped-merge transition cases, with zero failures/skips, in
112.38 seconds. It includes the original rollback case and the separate cached
metadata case. An earlier batch preserved 18 passes and a new-test setup
collision; only the new case's isolated directory name was corrected, retaining
whitespace, Cyrillic and all metadata/content preconditions. Final inputs were
unchanged during the run. The GREEN record is
`build/workflow-commit-owned-green-v2-20261001/result.json`.
Independent review confirmed the planner and unchanged Apply guard boundaries.
Source registration and installed continuation remain separate required proof.

## Completed original PM5 continuation

The corrected source commit `224c5fd85e1b451a9df6458f81a99c7a995850e8`
passed script-owned registration: 760 passed, zero failed/skipped. The local
canary uses its direct private child
`aed396b2724c57d0f5151e0d35d6be925ee64735`, with only the three qualified
artifact pins changed. Those native artifacts retain their historical producer
identities; this is consumer qualification, not a new native build or release.

The public workflow-only updater completed on the owned main root and its
working branch. Only the dependency lock and lifecycle implementation changed;
configuration/test bytes, branch-local environment/MCP configuration, database
hash/size/mtime, pending business target and repair budget remained unchanged.
The qualification is
`build/pm5-r39-completion-workflow-update-20261001/qualification.json`.

One subsequent ordinary unfiltered `check-dev-branch` completed the original
stopped operation in 52.13 seconds. It reused the actual retained 1/1 result
and passed event-log verification, with no new native 1C artifacts or runner.
Pending target/stage/operation are empty; the completed business target remains
`ae6911539de91b2f60fc6ef420acafdacb995a37`, while branch HEAD is the separate
workflow descendant `4bf0d223d492392d9303b59df333d821426cab14`.
The original repair receipt is byte-unchanged: the same session remains passed
at attempt 4 of 5. No reset, additional repair attempt or new refresh was used.

Actual completion evidence is
`build/pm5-original-refresh-complete-obligation-kind-20261001.json`, SHA256
`a1f1cbf8d963db4dbc035ee22be120a490b090b6ba01f54cb4363bf66acd5368`.
This closes the previously open original-continuation boundary in 9.7.
D4 one-off/named-policy/export acceptance and publication remain separate.

A read-only `git ls-remote origin refs/heads/master` on 2026-10-01 confirmed
`69c0863bfe3bd837543267f122e81a28dcfa5488` again. The published-master
baseline used by the separate migration canaries has not moved.
