# Database access acceptance matrix

This matrix separates source/protocol regressions from environment acceptance.
A local fixture must never be reported as proof of SMB locking, a server
infobase, an installed workflow, or a live configuration repository.

## Current evidence

| Contract | Evidence | Level | Current result | Remaining acceptance |
|---|---|---|---|---|
| Server connection aliases share one queue | `AccessTests.test_registered_connection_aliases_share_one_queue` | Local, separate Python processes | Covered | Repeat through two installed projects against one real server infobase. |
| File connection aliases share one queue | `AccessTests.test_registered_file_aliases_share_one_queue_across_projects` | Local, separate Python processes and fixture workspaces; not installed ITL projects | Covered | Repeat through two installed projects using the real file-base aliases configured by those projects. |
| Two local processes and two project workspaces serialize one resource in FIFO order | `AccessTests.test_different_projects_wait_in_order_for_the_same_database` | Local, separate OS processes and fixture workspaces; not installed ITL projects | Covered | No additional protocol fixture is required. Installed entrypoints remain part of file/server acceptance. |
| Two hosts use one shared coordinator | Protocol uses one filesystem authority and never falls back to a local queue | Static/local only | Not run | Two Windows execution hosts, one secured SMB directory supporting cross-client byte locks and atomic rename, synchronized clocks for diagnostics, and the same coordinator path/configuration on both hosts. |
| A crashed admitted owner remains fail-closed | `AccessTests.test_crashed_owner_blocks_replay_even_after_os_released_its_lock`; `RemotePerformance.Tests.ps1` native parent-process crash | Local, separate Python and PowerShell processes | Covered | Repeat with an installed operation that actually starts 1C; server recovery also needs the configured `recovery-observe` provider. |
| A live owner cannot be recovered or displaced | `RecoveryTests.test_live_owner_cannot_be_recovered`; `RemotePerformance.Tests.ps1` holder checks | Local, separate processes | Covered | Repeat across two real hosts to prove SMB ownership visibility. |
| A dead waiter is removed without executing and does not block its successor | `AccessTests.test_crashed_waiter_can_be_skipped_because_it_was_never_admitted`; cancelled-waiter regressions in Python, Go, and PowerShell | Local, separate processes | Covered | Repeat once through installed entrypoints; no 1C mutation is needed for the dead waiter itself. |
| An unrelated database progresses while another resource is owned or recovering | `AccessTests.test_unrelated_database_does_not_wait_for_a_busy_database`; `RecoveryTests.test_live_verification_releases_waiters_in_order_without_replay`; native host and source-sync regressions | Local, separate processes | Covered | Repeat across real hosts and installed projects to cover shared-authority routing. |
| A multi-resource request never retains a partial reservation | `AccessTests.test_multi_database_admission_is_atomic_and_order_independent`; `RecoveryTests.test_unproven_or_partial_verification_never_releases_resource_set` | Local, separate processes | Covered | Installed multi-database operations remain acceptance evidence, not a protocol gap. |
| Root-only and partial object locks report contention without losing prior outcomes | `ConfigRepositoryRootLock.Tests.ps1`, `ConfigRepositoryLockReport.Tests.ps1`, and the Release E2E root-lock roundtrip | Local fixtures plus one existing single-environment E2E route | Partially covered | Two installed projects on separate hosts and repository users, one holding the configuration root and the other requesting a partial object set; verify bounded failure, exact foreign owner, preserved partial outcomes, cleanup, and successful retry. |

## Live acceptance prerequisites and assertions

The live run is deliberately not automated from an arbitrary developer checkout.
It needs named disposable projects, infobases, credentials/providers, and hosts.
Before running it, record the exact package commit, installed workflow version,
coordinator UNC path, host identities, file/server connection identities, and the
configuration repository users. The coordinator share must be tested for byte
lock exclusion and atomic rename from both hosts before starting 1C work.

For each file and server contour, start the first operation from project A and
observe an admitted ticket. Start the conflicting operation from project B and
host B, then prove it is waiting on that exact ticket and has not launched 1C.
Also run an unrelated database operation to completion while the conflict is
held. Exercise orderly release, waiter crash, admitted-owner crash, rejection of
recovery while the owner is live, verified recovery after the owner is dead, and
FIFO admission after recovery. Tokens must not appear in logs or reports.

For repository contention, use a disposable repository state that requires one
root-only request followed by partial object requests. The second user must be a
real foreign repository owner. Prove that the conflict is bounded and names the
foreign owner, already captured outcomes remain recorded, cleanup releases only
owned work, and the same public action succeeds after the foreign lock is
released. A mocked Designer log or a single-host roundtrip is supporting fixture
evidence, not completion of this row.
