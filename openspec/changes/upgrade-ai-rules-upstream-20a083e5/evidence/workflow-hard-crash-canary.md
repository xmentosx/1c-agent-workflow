# Interrupted post-copy recovery — 2026-09-30

A real process interruption was exercised in disposable
`build/r33-hard-crash-canary`, initially at installed r33 baseline
`e56326f6bdbe5f50c9218f6cfa59706aa16a19a3`. The candidate source was the
clean ignored clone `2f684fe1e44d55c7ddf9bfd97fede22b9053a13c`, using exact
rules fork `2d3e7705f79e37a130349b88ecea78b964adabf5`. No infobase or real
project was involved.

The foreground canary monitor launched the source-side updater and watched
its persisted root receipt. After 52.8 seconds it observed `post-copy-running`
and an already updated ignore file. It verified the launched process identity
against the exact canary path, then terminated that process tree, including
the Windows PowerShell continuation. This is an abrupt interruption, not a
caught fixture exception. Snapshot id:
`a3e10b7b1ce544d89b0e315b2c95d818`.

Repeating the original updater exited 1 with
`WORKFLOW_UPDATE_RECONCILIATION_REQUIRED`, keeping the old HEAD and all current
bytes. Five paths differed from the last recorded checkpoint: managed Vanessa
libraries, dependency lock, `.gitignore`, `.gitattributes`, and `USER-RULES.md`.
The former refusal was safe but had no concrete owner-supported continuation.

The compatible source recovery helper at
`5bec340e512ad0d761126ee1a45a9aaee9cbb194` captured a scoped report with
preserved before/current/source bytes. Each path was reviewed by reconstructing
its writer in a separate disposable directory. The library layers, ignore
additions, attribute rule, user-rules overlay and lock output all matched exact
observed bytes. The lock reconstruction used the same Windows PowerShell
serializer and the known Vanessa writer's timestamp within the terminated
process interval; it did not relax the receipt's observed SHA checks.

An additional `.gitignore` edit made after that review was refused by
`-Recovery reconcile`: original receipt SHA and HEAD remained unchanged. After
removing only that known fixture edit, the reviewed acknowledgement succeeded.
It changed the transaction receipt and stored audit, without changing project
files, HEAD or business staging. The recorded candidate remained `2f684fe1...`;
the recovery helper's different source commit did not replace it.

Repeating the original exact-source updater then exited 0 at clean commit
`0edc5f66d239f9654b3e288fe642ec7049443115`, with the exact `2d3e7705...` rules
pin, completed root receipt, one retained capsule and zero pending capsules.
Another repeat exited 0 and kept the same HEAD and clean tree. This passes the
original file-update task through its recovery route.

The three focused reconciliation tests passed: preserved report and original
continuation with business staging, edit after review, and incomplete/tampered
review. `SourceUpgradeHandoff` passed 23/23 after this addition. The recovery
route remains an explicit review of confirmed interrupted helper outputs;
unknown or genuine later edits cannot be silently acknowledged. Their semantic
repair, a partly written directory, commit/branch crash windows and failures
after another client still need their corresponding owner acceptance.

Ignored artifacts include `build/r33-hard-crash-{metadata,decisions}.json`,
stdout/stderr/kill/repeat/report/late-review/ack/resume/idempotent logs, and
`build/reconstruct-hard-crash-owners.ps1`. Report copies remain in the retained
project capsule. UI-tool preparation warned that `uv/uvx` was unavailable; this
file-update success does not qualify those tools, live MCP or 1C verification.
Nothing was published or rolled out to real projects.
