# Release ondemand: paired applied snapshot on candidate continuation

2026-10-09. Scope: the owned PM5 Release R8 stand and existing Release runner.

The failed native transition restored rollback baseline with Designer fingerprint
`v2|git-tree-sha256|2aa9360b7324b3000b0f53bae7bdfe63bdec49cbccf92bd3f8679f53def96eef`,
while source and the retained passed postConfig state have fingerprint
`v2|git-tree-sha256|8442b3b14156383cda1f93f0661d2265d2c0da411b5a8ccb95dd06b156526317`.
The only configuration payload difference was the existing cadence Comment.
The application guard correctly rejected this mismatch. Public native
`update-dev-branch-base` recovered the database, but another source promotion
would restore the old baseline again. Repeating that reload costs about 35 minutes
and does not repair its owning transition.

The existing Release runner now restores its verified postConfig snapshot/state
before ondemand preparation on cross-source continuation with passed
config-cadence. It uses `Restore-E2EInfobaseSnapshot`, including the existing
snapshot/state/environment SHA checks and helper-owned native restore. Same-source
retry does not undo a recovered live database. An unqualified config stage or
corrupt snapshot grants no admission. No checkpoint/proof is edited manually.

The focused regression executes the production preparation statements and actual
restore functions with both original fingerprints. Before repair it retained the
original application mismatch (2 passed, 2 failed). After the seven-line owner
repair all four cases passed. Raw logs:

- `build/gate6-r41-source-delivery/ondemand-snapshot-regression-red-20261009.stdout.log`
- `build/gate6-r41-source-delivery/ondemand-snapshot-regression-green-20261009.stdout.log`

Separate diagnostics of the subsequent ROCTUP idle-restart timeout passed using
unchanged backend code and its original 30-second limit, including idle cleanup,
restart and final cleanup. This does not replace Release proof or establish the
cause of that transient timeout.

The process fix `6f392ccf` is already integrated and registered (210/0). The first
registration retained a ReleaseGate worker timeout; the diagnosed ordinary
continuation reused 163 passed tests and executed all 47 ReleaseGate tests (47/0).
No assertions or deadlines were weakened for that continuation.

Published supervisor `dfe81865` conservatively plans fresh journey execution;
the current checker independently validated both qualified `66742` route reports.
The full external bindings and source fingerprints matched after materializing
the three clean source scripts through Git with normal checkout line endings.
No report, qualification manifest or proof bytes were changed.

Ordinary registration, native Release on both backend families, publication and
final EV8a/EV9 remain required. This evidence closes none of those tasks.
