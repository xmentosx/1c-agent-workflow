# Same-fork continuation after a package update

Status 2026-10-02: continuation source A5 passed registration and public package
rollout to all eight stand roots. Task 9.6 remains open: the subsequent same-fork
continuation stopped at the fixture dirty guard before runtime initialization.
The remaining package commit/stat defects are being fixed at their owner.

The historical Release fixture already committed facade compatibility 0.4.15
with dependency lock 0.4.14. Public creation of `rel-e2e-r6` stopped during MCP
setup after restoring its base. The original fork, snapshot and Release pointer
were retained. Updating its package alone previously left two recovery defects:
the fork demanded its old snapshot lock and copied the source dotenv again.

The existing fork owner now verifies consecutive retained workflow updates,
their branch/root, parent/tree, before/current lock hashes and owned paths.
Original business identity stays pinned. Target settings, generation and proven
completed restoration survive retry; reused mutable runtime cannot inherit the
old fresh verification. Nonready continuation permits later source business
movement; ready acknowledgement permits only proven workflow movement.

Namespace validation reuses the existing 33 snapshot paths and five exact
OpenSpec scaffold paths. Their original consumers retain the same lists and
order. It does not authorize arbitrary OpenSpec change artifacts or business
files through a new manifest claim. No extra recovery coordinator is added.

Final focused native PS 5.1 / Pester 5.8.0 batch: 35 passed, 0 failed, 0 skipped;
124.779 seconds, inputs unchanged. It covers real Git transitions, the public
fork function, all 12 client namespaces, root entries, scaffold, forged evidence,
Unicode paths and file/server restoration fixtures. Independent review found
no remaining material issue. This is fixture evidence, not live server proof.

Result: `build/fork-workflow-transition-focused-20261002/run-c2ac4da6bd7942b9ba4a53d27f929031/result.json`,
SHA256 `f1c0a54e7a085f8dad6cab8821ed784fbca203bead3f67a4aa6e098eeaf95fd3`.
The failed fixture runs remain alongside it; their encoding/isolation defects
were corrected without weakening the intended assertions.

Required live route: public workflow-only update from the owned test main,
then the original rebuild command with `rel-e2e-r6`. Before proof records all
eight worktree business indexes and original snapshot/lock identity. The old
Release pointer must stay unchanged until the fork owner completes successfully.

Registered source `dc4c0703c7852b7e9722f2fa80778402030ef167` passed its
owner-selected Targeted run: 936 passed, 0 failed/skipped, 1000.129 seconds.
Receipt `20261001-222828-350-targeted-e5fcf25b840446fcab1903d412bd941b.json`
SHA256 `88628383a742ed383352d49db6098799807499629be38712d2f73a04e7a50871`.
No tracked state changed. This registration is local, not publication.

The first public update took 334.157 seconds and returned exit 1: main and
five development roots completed; two roots were blocked. In the unfinished
fork, the old Kilo copy omitted `client-managed.json`, so the strict MCP writer
correctly rejected a copied endpoint without its ownership evidence. In the
external E: worktree, inventory found the registered root but its runtime state
still named the old D: worktree. Neither refusal is evidence of data damage.

All eight business source/test trees, their index/status, the immutable fork
manifest/artifact/lock, old Release pointer and branch identity settings survived.
Failed rollout SHA256 `f3844d433177722d61204103c67666e3746e4b9cfe77d043a0cc57afd84bf89b`;
partial-update preservation receipt SHA256
`92a377a9039db63ca78faaeaa57258172718bcbec3ecda7c98ca5cf153d00965`.
Both remain under `build/fork-workflow-transition-live-20261002` in the recorded
source checkout; the failed owner log is retained.

The recorded clean source remains at `dc4c0703` at its original path. Further
owner-local fixes use the separate `migration-native-source` checkout and the
existing newer-executor/old-payload recovery route. No capsule identity or
installed state is rewritten manually. Task 9.6 remains open until the public
update and the same original fork both succeed.

The continuation fixes stay with their existing owners. Package update can
validate a Git-registered external worktree against its branch, common Git,
saved main and local state without rebasing infobase/runtime paths. The ordinary
development operation guard still refuses a mismatched saved worktree root.

New Kilo config copies transfer only ownership proved by the exact source
config and ownership bytes. For the interrupted legacy fork, the post-copy
owner additionally verifies target-before bytes, the immutable same-fork
snapshot and retained main update capsules with exact Git ancestry and owned
write sets. Equivalent config/ownership hash pairs are interchangeable proof;
different ownership stays ambiguous. Unproved entries retain the ordinary
collision refusal. The endpoint config, other clients' owners and persisted
enable/disable policy are preserved; no manual adoption by key name is allowed.

Independent review caught and closed the equivalent-capsule ambiguity before
live retry. The first tagged caller run reached all 14 assertions but emitted
a setup error from incomplete fixture state. Its raw result remains retained
as setup-invalid evidence, not final qualification; production code was not
changed to accommodate that fixture.

Final directly owned qualification uses native PS 5.1 / Pester 5.8.0:

- MCP adapter: 25 passed, 0 failed/skipped/not-run, 13.516 seconds. Receipt
  `build/copied-mcp-ownership-20261002/run-e0384521a0c246949f1aab37e05ece26/result.json`,
  SHA256 `16bbdf51e3e63392605895806957adbef04f5c8653da04d6c4f343e8edb852ee`.
- Same-fork callers: 14 passed, 0 failed/skipped, 278 unrelated cases filtered
  out, 62.585 seconds. Complete fixture setup explicitly checks helper exit 0;
  the raw log contains no ITL failure. Receipt
  `build/copied-mcp-ownership-20261002/caller-run-3b674905d4104728a560220e3d7b2ac5/result.json`,
  SHA256 `90d73953daa6fee714dd5162b3c87d29f2ee736b57e8f098eed38e342af19a03`.
- Moved worktree: four logical cases passed across the original two valid
  cases and the focused repair of two isolated negative fixtures. Production
  stayed unchanged between batches; the first failed setup raws remain.
  Receipt `build/moved-worktree-package-update-proof-20261002/review-receipt.json`,
  SHA256 `e24c30124fd7a7ce4f581eb7474aeace16e87fa77047f38bbd6a710a97ccfce9`.

Runtime and test inputs remained unchanged during their respective batches.
The moved-root validator text stayed identical through the subsequent disjoint
caller integration. At this fixture qualification, lifecycle SHA256 was
`7329a96f41837920e4f9fc1bf3f08a1ca8925b1bce5910aca722218667745d8f`;
MCP adapter SHA256
`72d79522803ba44d2f84aa423626b38a5d94598e08618a91cdb7e3c3aa459445`.
Independent review found no remaining material issue in the completed source
unit. These are fixtures, not a claim of successful live continuation.

Registration of `683d31fefcf3d29d2b336135d89fe33b33135c63` failed after
741.726 seconds: 457 passed and two failed in five executed Pester files;
fail-fast left 41 selected files unexecuted. The failures were the existing
bootstrap phase-only regression and the unchanged rendered-context budget.
This head was not installed on the stand or added to its delivery queue.
Run `20261001-234128-011-targeted-e9c29658acde4d308306613d0b8b9a24.json`,
SHA256 `efd20edd1cc67b252c6bea6208b7a60e34f22ac1c01f9b6474543123543b2f64`;
all original raws and the receipt are retained under
`build/register-stand-continuation-failed-683d31fe`.

The bootstrap fixture intentionally has no Git repository or legacy-fork
data. Recovery admission must check for its config/state before querying Git;
the original phase ordering and assertion remain the regression workload.

The budget difference is checkout EOL, not added instructions. Both sources
have `itl-switch-client.md.template` Git blob
`27c0c88d62805987ff4c33137bfafbbecc521222`: old working bytes 1184 versus
clean checkout bytes 1188; both are 1176 as LF. Generated ITL surfaces will
use canonical LF at their existing renderer owner. The measured value remains
the real serialized UTF-8 output and the existing ceilings stay unchanged.
Generic readers, config JSON, upstream assets and 1C transport are outside
this change.

Both failure owners were fixed and independently reviewed. Final focused
native PS 5.1 qualification:

- Original bootstrap phase regression plus the unchanged 14 provenance cases:
  15 passed, 0 failed/skipped, 350 unrelated cases filtered out, 65.422 seconds.
  Inputs unchanged, no raw failure markers. Receipt
  `build/copied-mcp-ownership-20261002/admission-run-3b71d3a9a99748fdb94ef81e52fa7330/result.json`,
  SHA256 `d32db5641f7af8e71b147d606db017aa44a50abc5c9df69ae4704feaf70dfdf0`.
- Generated-surface EOL regression and the original unchanged byte-budget
  case: 2 passed, 0 failed, 79 unrelated cases filtered out, 6.900 seconds.
  All 12 clients on master/dev, LF/CRLF/mixed input, routine/here-string and
  plugin branches produce identical real UTF-8 bytes. Template input hashes
  are unchanged; added instruction text still increases actual byte counts.
  Receipt `build/client-surface-lf-proof-20261002/focused.json`,
  SHA256 `efc12780e7a2e855020db6543f15ee05af6ec457c48d63d83fd82f81ddad3797`.

Measured master/Codex remains 24 files: old renderer/source 33424 bytes,
old renderer/clean checkout 33428, new renderer/clean checkout 33204.
All 72 actual before/after surface rows are retained in
`build/client-surface-lf-proof-20261002/rendered-actual-bytes.json`,
SHA256 `359cd197a74f38a5f2bfb93dc04d8e5aea1a22ab2069128f99655e14dc0ba8b4`.
The output boundary is canonicalized, not the metric or its ceilings.
Final lifecycle SHA256
`ab77e02e0df98ee33b86d383ff73ada0de1e5a770e1f4d39984d78d6f23b5a6d`;
adapter SHA256
`d03ed763beba6b724776b33fb547de12a6936bf92ecbc6bccf6a73a01a3df5c7`.
The recorded original checkout remains clean at `dc4c0703`.

## A5 registration and installed rollout

Source `a5a89eb9baa4355557f61911564976e17bd2b2a8` passed the normal
RegisterChange Targeted run: 966 passed, 0 failed, 0 skipped, 46 executed
files with no reuse, 1036.291 seconds. Authoritative run
`20261002-000300-449-targeted-b633f671a2ee424c971aeb8e2c9098a5.json`,
SHA256 `bbda77f871cac235e9422ef17420d2a3cafc3bbe6acf0646feff4a63aaeeabc7`.
Registration stayed local; no publication or production rollout occurred.

The public source-side update completed in 403.984 seconds, exit 0. Main moved
to `53b9a347270c0ff68257f7b4a8bfca01f878c08f`; all seven registered development
roots reported completed, including the moved E: worktree and stopped r6 fork.
The copied rollout receipt is
`build/workflow-update-finalize-proof-20261002/a5-completed-update-rollout.json`,
SHA256 `5665f93bf32701082456b596cccbbd0dc8663a516304250654aa304ae895832b`.

An independent AfterUpdate oracle passed for all eight roots: business source,
tests, index entries and dirty status stayed unchanged. The original fork
manifest, immutable base artifact, source lock, old Release pointer, fork ID,
source anchor and protected branch settings were preserved. Receipt
`build/workflow-update-finalize-proof-20261002/a5-afterupdate-preservation.json`,
SHA256 `595bb542408623e8bbf16d39cdf4a01a20ae4c4acd6c27c58a460eec274bd63d`.

The public rebuild of the SAME `rel-e2e-r6` then stopped at its unchanged fixture
dirty guard, exit 1, before starting the fork runtime. This is not successful
continuation or restore-reuse evidence. Raw log
`build/workflow-update-finalize-proof-20261002/a5-rebuild-owned-stand-r6.log`,
SHA256 `975db9cf5b2a5d343d7c9db451b945e09c3e15848af97c31c7f734725ee22864`.

The fixture exposed two package completion defects. Its 102 reported modified
paths had equal normalized working blobs, index blobs and HEAD blobs: copied
unchanged files retained stale Git stat entries. Two real deletions, the known
legacy README and developer guide, were absent from the branch transaction's
snapshot and commit plan. Their HEAD text reconstructed with CRLF matches the
existing exact retirement hashes; custom project documentation remains outside
that ownership. The fix must retain those retirement backups, commit only
proven owned deletions and refresh equivalent owned stat entries without
altering business staged or unmerged index records. The original sources stay
clean at their recorded commits; no installed files or index entries are
manually repaired and the fixture dirty guard remains strict.

## Finalization fix: focused source proof

The existing update owner now snapshots eligible legacy documents before
removing them, includes proven retirement in branch commits and validates those
immutable old/new Git blobs in the retained fork and copied-MCP transition
chains. A same-named custom, staged or unmerged document cannot establish that
ownership. A document edited after capture is preserved and refused before
Ready; its existing recovery route retains user bytes and staging. Ready
lost-acknowledgement replay still accepts the exact committed candidate.

Equivalent owned index entries are refreshed even for unchanged copied files
and a no-op branch plan. The refresh compares only the named owned stage records;
it does not write-tree or reset unrelated business staging or merge conflicts.
A real late owned change remains preserved and refuses completion. This uses
the existing snapshot, plan and recovery owner without a new phase or schema.

The first focused run recorded 48 passed, 3 failed, 0 skipped in 193.178 seconds.
Two failures expected the user-file rollback refusal before the existing
pending-business-merge refusal; the original merge fixture and owner assertions
were retained when correcting that expectation. The third failed while preparing
an unmerged fixture: native PowerShell appended CRLF to its text stdin (180
expected bytes, 182 actual). Exact UTF-8 NUL-delimited native stdin repairs that
fixture without changing its three conflict stages.

The minimum ordinary rerun of the two parameterized test bodies passed 9/9 in
41.649 seconds. Combined proof covers 42 unchanged earlier cases plus those
nine corrected cases; it is not a single 51/0 run. Both original failure output
and corrected receipts are retained. Final qualification
`build/workflow-update-finalize-proof-20261002/qualification.json`, SHA256
`1b66c6f946a721b1da4c5f26d064e5ccf298b5228328cba7f2fa5ae30319a07d`.
Runtime SHA256
`2e5bf9ef3ff7adc941db88258a5591ddec096cc0bac75ee6aca16ffefeac9c61`;
final rollback test SHA256
`f4e84ed10cc231d1420221618517ed98c8f1d53cdcba651f5a0b6504ca5daa96`;
development lifecycle test SHA256
`d5b1f35e669a3ffa88cdca14a27f62b733f06d2fe1beee2e68858eaf9d1eb26e`.
AST parsing and diff checks passed. Normal registration and the public SAME
fork continuation remain required; this local proof does not close task 9.6.
