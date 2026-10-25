# Scenario repeat audit, 2026-10-25

Scope: accumulated Develop candidate after `f252bf2`, compared with published
`4560884`. No publication or installed-stand mutation belongs to this audit.
The preceding full-workload forecast was static 17:53, upgrade 57:30, fresh
40:44 and the required on-demand component Release stage 18:01 (2:14:08 total).
These are forecasts, not completed qualification of the new binary.

## Actual changed inputs and the baseline boundary

The old native evidence uses broker SHA `f532ff8bfca922ec01bad3ad9953fa2be1ba74618c352790f3f57a67efb6d4be`.
The current exact lock/build uses `47234ea81544095a182f73a6d500008866b11f652c259284a4b015772be8af60`.
Vanessa archive `4a0283c645ecc15192e17fad9bee16ebfed0ecdcdbf67bff60b24fcacb4eab46`
and client CFE `29f741db8a379384cd8270398761ec96e7e8e548071a0c180d4ffc6ddd8443b6`
are unchanged. Old receipts have not been rewritten. The new executable cannot
inherit the old environment's acceptance just because an unchanged assertion is
being tested. This change retains all three physical SHA checks.
The read-only cache audit inspected 355 manifest records and found no record
bound to the current broker SHA; this is a missing baseline, not a lost warm hit.

Production differences are dependency-lock wire serialization and legacy update
executor selection/handoff, plus broker cancellation/startup/recovery and
classification of a proven peer during backend shutdown. They are not just test
or documentation differences. The broker still needs its native Release stage
on both backend families; static tests do not grant that qualification.

| Scenario | Changed owner or reason for retaining execution |
| --- | --- |
| upgrade.update | Legacy executor, post-copy child and dependency-mode handoff; `Update-DependencyLockEntry`, dependency wire format |
| upgrade.configuration-rejection | Its refresh continuation uses dependency synchronization and shared process dispatch. Gate6 assertions themselves are unchanged; prior evidence also has the old broker/environment. This is not a claim of a direct Gate6 code change. |
| upgrade.verification-export | Refresh synchronizes managed dependencies and restarts the helper; checking/exporting the updated branch retains exact-candidate verification. |
| fresh.install | Initialization writes managed dependencies and installs the new broker pin. |
| fresh.branch | Branch preparation/initialization and dependency/runtime setup. |
| fresh.verification | Suite assertions unchanged; native evidence has a different broker and shared runtime. No exact applicable certificate for the current environment. |
| fresh.stale-export | Stale-result refusal/export assertions unchanged; exact-environment proof missing. Not attributed to a direct export-code change. |
| fresh.refresh | `Sync-WorkflowManagedDependencyLockEntries` and `Get-WorkflowDependencySyncManifest` participate directly in refresh. |
| fresh.close | Merge/reexecution and backend cleanup share changed runtime. Fresh verification remains its prerequisite. |

Selection and proof admissibility remain distinct. A narrow source route cannot
manufacture missing proof for the rest of a complete certificate. Conversely,
adding a regression or routing metadata must not force an unchanged environment
to repeat native work. Unknown/new ambient dependencies remain conservative.

## Systemic repairs

* Routing ownership (`scenarioInputs`) is separated from native workload
  equivalence. Current mapping still projects SHA-authenticated original and
  current source; scenario operations, setup dependencies, other contract fields,
  unknown fields, current static proof and applicable newer failures still bind.
  This applies at the raw JSON catalog, input identity and scenario-certificate
  boundaries. Certificates remain immutable.
* Dependency synchronization has explicit caller-based ownership. A change only
  to the synchronizer selects fresh install/branch/verification/refresh, where
  verification is required setup. Independent stale-export and close evidence
  can be reused. `Update-DependencyLockEntry` and its wire-format helper retain
  the broader route because dependency provisioning has additional lazy callers.
* Main-package Go `_test.go` and README changes alone do not select native E2E.
  The native runner builds with `-SkipTests`; static Go tests remain selected.
  The exception pins the audited runner and builder and requires no compiled
  `go:embed`, in both source snapshots. New native source is never exempted.
* Plan records per-scenario source paths/functions and the reason for falling
  back to complete coverage. It does not hide environment/contract rejection
  behind a source-selection explanation.

## Regression acceptance

The incremental acceptance suite exercises real Git inventories and cached
certificates, including schema 3 execution-only certificates across catalog
policy additions, current-policy source rejection, all-six-scenario warm reuse
after Go test/README changes, runtime/embedding/consumer drift refusal and actual
dependency-owner selection. Existing native-child/composition, prerequisite,
artifact, rollback, newer-failure and input-tamper regressions remain enabled.
The helper-owned registration result and fresh candidate plan are saved as
ignored task reports; registration is not native qualification or publication.
