# Same-fork continuation after a package update

Status 2026-10-02: source qualification passed; public installed continuation
is still required before task 9.6 can close.

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
caller integration. Current lifecycle SHA256
`7329a96f41837920e4f9fc1bf3f08a1ca8925b1bce5910aca722218667745d8f`;
MCP adapter SHA256
`72d79522803ba44d2f84aa423626b38a5d94598e08618a91cdb7e3c3aa459445`.
Independent review found no remaining material issue in the completed source
unit. These are fixtures, not a claim of successful live continuation.
