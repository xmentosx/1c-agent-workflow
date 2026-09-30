# Completed workflow rollback — 2026-09-30

The disposable `build/r33-recovery-canary` began at synthetic installed
published-master/r33 commit `e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`.
The exact clean source-side updater at `f731e1cfc034fb6b620b2b43ca5bb72d3b74c8b5`
used the locally qualified rules fork `2d3e7705f79e37a130349b88ecea78b964adabf5`.
No real project, infobase, or live MCP was involved. The source migration lock
remains r36; the candidate pin exists only in the ignored canary clone.

The update exited 0 with clean HEAD
`bda8f987429752513c326562c401d8d61b87734c` and retained snapshot
`23a896ea3d0047dcbf197c7846943989`. Its before capsule occupies 8,063,506 bytes
(about 7.7 MiB). Retention is local ignored runtime; an unchanged repeat does
not create another capsule. Snapshot retention has no automatic age cleanup.
Source-side `-Recovery status` listed the completed capsule without treating it
as a pending update. Explicit project CLI provisioning also exited 0.

A later dotenv edit caused `-Recovery restore -SnapshotId <id>` to fail with
`WORKFLOW_UPDATE_RECONCILIATION_REQUIRED` before changing HEAD or those bytes.
After removing only that known fixture edit, the same command restored the
old package and ignored settings in inverse workflow commit
`c5fdcc4e5fe4ae8aff10c7fbf1a8c1145bf1347e`, a child of the update commit.
Its tree is exactly the baseline tree `fa481f93f9335aad58f13c1f00735f69fc0f33ed`.
Original dotenv and MCP ownership bytes returned, and the previously absent
Caveman migration receipt became absent again. The old installed helper's
`help` exited 0. There are two completed capsules and no pending capsule;
the second capsule retains the new package for an explicit forward recovery.

The first audit exposed that the old tracked `.gitignore` did not hide the new
CLI cache or execution-generation file. The existing local runtime ignore owner
now also records these two exact paths in Git's local `info/exclude`. This keeps
the old tracked tree intact and retains the cache. Repeating recovery from the
fixed clean canary source `2f684fe1e44d55c7ddf9bfd97fede22b9053a13c` exited 0,
kept the same inverse commit and left Git clean. The regression now reproduces
this boundary with an old ignore file and verifies cache bytes, business staged
and unstaged bytes, and byte-idempotent local excludes.

The retained runtime receipt and CLI entry hashes are unchanged, and OpenSpec
1.13.1 still executes. The parallel updated project `build/r33-preflight-lockfix`
remains clean at `ed1004b5db266119d8c5592de7da7114426e8eb5` and independently
executes its own 1.13.1 CLI. Neither project's cache was deleted.

`WorkflowUpdateRollback` passed all seven focused cases: exact retention,
successful return/repeat with unrelated business staging, two late-edit scopes,
corrupt before backup, interruption during restore, and lost acknowledgement
after ref movement. The successful return case passed again after adding the
old-ignore regression. `SourceUpgradeHandoff` passed 23/23. The affected
`BootstrapUpdate` fresh-process case and pending-merge retention case each passed
their focused check with retained terminal proof instead of deletion.

Raw ignored logs are `build/r33-recovery-{update,status,provision,late-edit,
restore,repeat,old-help}.log`; runtime hashes are in
`build/r33-recovery-metadata.json`. This qualifies file/settings rollback and
CLI coexistence. Normal update hard-crash recovery, backward rollback while a
business merge is unresolved, all client runtime variants, and live 1C/MCP
acceptance remain separate open checks. No source publication or real-project
rollout occurred.
