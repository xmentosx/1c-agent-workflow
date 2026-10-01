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
