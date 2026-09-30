# Published-master transition canary — 2026-09-30

Scope: isolated synthetic managed project in ignored
`build/r33-preflight-normal`, with no infobase. Before update it was a clean
Git project at `e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`; its installed
workflow helper, `AGENT-INSTALL.md` and dependency-lock template blobs matched
the currently published workflow `master`
`69c0863bfe3bd837543267f122e81a28dcfa5488` byte-for-byte. Its rules
lock was published r33 `9309bfbbc9f8d844a21bce55178c2e0d72eaf965`.
`git ls-remote origin refs/heads/master` confirmed the same published master
immediately before this canary.

The first update entered the new source-side
`scripts/update-installed-workflow.ps1` from a clean canary snapshot
`0ec89474bafef81a39cd64cef6af88ba2f8f6bc3` of the current source
implementation. That snapshot differs from the in-progress source checkout
only by a temporary local rules pin; it is not a published workflow candidate.
The pin used clean controlled-fork commit
`a6f175cc1099072d08134294c8acaf718d3e0b86` through a local-only canary
tag and `ITL_AI_RULES_SOURCE_PATH`. The external OpenSpec-store change was
excluded from the source snapshot.

The exact candidate preflight enumerated 274 Codex project-local rules paths
before the first project copy. The update exited 0 and created local master
commit `5e0b5f1fdade5f33508902b181d0dd84bf99f01d`, with the original
project commit as its parent. The installed workflow lock names the canary
source commit, the rules lock and manifest name the exact fork commit, and the
new root `AGENTS.md` contains the upstream headings and ITL ownership appendix.
The installed project remained Git-clean; 360 tracked paths changed, none
under `src/cf/**` or `src/cfe/**`. No infobase existed, so this run provides
no database or 1C test claim. The workflow-update snapshot directory had no
pending transaction. Repeating the same source-side update exited 0 in about
1.7 seconds with the same project HEAD and a clean tree.

The old project `memory.md` and comment-only `openspec/config.yaml` were
preserved as user-owned files. The helper reported that user-scope Codex
prompts were preserved for separate review. MCP client selection was absent,
so default upstream MCP entries were retained with a setup continuation;
optional UI tool preparation reported missing prerequisites but did not block
the file update. The raw ignored logs are `build/r33-to-a6f-canary.log` and
`build/r33-to-a6f-repeat.log`.

This canary proves the published-master file transition and idempotent repeat
in one synthetic single-client project. Rollback, stopped operations,
registered worktrees, live infobase/test behavior and multi-client rollout
remain separate acceptance cases.

## Exact follow-up candidate

After the transient `/test-fix-loop` routing fix, the same published-r33
baseline commit `e56326f6bdbe5f50c9218f6cfa59706aa16a19a3` was cloned into
another clean, disposable project in ignored `build/r33-preflight-2d3`.
The source implementation was captured without changing the dirty source
checkout or including the deferred external-store change: snapshot
`dc669946ad3a42e0bc94cd223d4a6272a3e44e6a`, then clean local rules-pin
commit `942141374325097fb6e106e4dc5a2ea0c48e46fc` in
`build/canary-source-2d3`. Its test-only tag
`itl-main-20a083e5-r1-canary-2d3e770` resolves to clean fork
`2d3e7705f79e37a130349b88ecea78b964adabf5`; neither tag nor source
snapshot is published.

The source-side handoff again preflighted 274 Codex rules paths and exited 0.
It created master commit `37a813faeb51cc2e0f91d7cbe5b3ef2536744e19`
directly on the r33 baseline. The installed workflow lock names `9421413…`;
the rules lock names `2d3e770…`, and the rules manifest names the matching
test-only tag. The project remained Git-clean, changed no `src/cf/**` or
`src/cfe/**` paths, retained `memory.md` and `openspec/config.yaml` unchanged,
and left no workflow-update snapshot directory entries. Repeating the same
handoff exited 0 in about two seconds with the same HEAD and a clean tree.
Raw logs are `build/r33-to-2d3-canary.log` and
`build/r33-to-2d3-repeat.log`. This remains a file-transition canary without
an infobase, live MCP providers, rollback or stopped-operation recovery.

## Source C/r39 follow-up

The direct published-master/r33 transition, repeat, exact rollback and custom
configuration preservation were exercised again on source C
`92964456bf1931ad3a3d24af1250f6e244ea5574` and fork r39 `9ec86f7…`.
The corresponding user-template and tracked-MCP failures are retained rather
than counted as accepted migration. Exact identities, per-action timing,
unchanged hashes and original continuation boundaries are in
[final C preservation qualification](published-master-final-c-preservation.md).
