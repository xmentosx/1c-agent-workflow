# Consumed qualification inputs, 2026-10-25

Baseline: candidate `6208830e4767832df8b73292f71c63eb7de7f9c2`, advisory
plan `647077c881d6f2b7909acb5410d759797b879b2ceb4a3e1c7ffbd78a2075aa44`:
105 Pester executions / 89 reused, nine native scenarios, 8852 seconds.
The previous 88/106 snapshot lost 17 cache hits; this is not evidence that all
17 tests executed the modified planner functions.

## Broker

The early artifact filter compared the entire artifacts object before consulting
scenario source equivalence. Broker 0.4.25 -> 0.4.26 consequently rejected every
old native certificate. The runner validates the locked executable, installs it
through Install-ItlOnDemandMcp, and writes facade descriptors. Its RPC workload
belongs to the mandatory ondemand-mcp Release stage, for both backend families.
Invoke-DevBranchDefaultMcpSetup and restart-after-load stop backends and write
configuration; they do not launch the facade. This does not exempt their changed
PowerShell implementation from native source qualification.

| Native scope | Broker SHA / release identity | Retained evidence |
| --- | --- | --- |
| upgrade, including its update prerequisite | exact | successful/negative update, check/export |
| fresh install, branch, refresh | exact | installation, client configuration, dependency replacement |
| fresh verification, stale-export, close | opaque executable projected out | scenario workload, actual PS consumers, Vanessa/CFE, stands, runtime, fork |
| unknown or whole-journey request | exact | conservative full binding |

Current binding still hashes all three physical artifacts against the current
lock. Scoped projection never qualifies a new broker release or skips its native
Release E2E. Root Go implementation belongs to the opaque executable for the three
independent scenarios; builder/runner, platform/transport, compatibility minimum,
other dependencies and unknown fields remain bound. Original manifests and JSON
LF/CRLF source hashes are authenticated before semantic projection. Positive-stand
fingerprints are reconstructed with the original artifacts, never silently erased.

The accumulated candidate also changes legacy update/re-exec, dependency syncing
and PowerShell backend cleanup. An unchanged export assertion is not sufficient
to reuse an old journey when these consumed source inputs differ. The final Plan
must show the remaining real refusals, rather than attributing all of them to Go.
An authenticated changed input with no available projection now rejects before
report reconstruction and historical AST work, with NATIVE_CONSUMER_INPUT_CHANGED
and the concrete source path. This shortcut can only reject; eligible proof still
passes every original authentication and acceptance check.

## Pester

Get-ShardInputDigest unions paths and reuseInputPaths of every contract naming
the test. Frozen fixtures copied and the supervisor imported native qualification
modules even with an explicit custom gate, whose plan returns before using them.
Thus whole-file SHA changes contaminated unrelated publication/control proofs.

Native calculation and all five timing/workload helpers now live in
`scripts/delivery-native-plan.ps1`, loaded after the custom-gate return. The actual
candidate calculator remains isolated from the published queue/push owner.
Its consumed test set is SourceDeliveryPlan + SourceDeliveryIncremental instead
of the old plan module's 18 consumers. The orchestration wrapper keeps its real
consumers and strict identity, checkpoint, SHA, remote movement and rollback checks.

Removing the three unused qualification modules from five fixture contracts
reduces their consumer union from 24 to 10. Fourteen control suites retain proof
after native-only edits: Admission, CandidateIntegrity, CandidateRegistration,
ControllerRollback, EvidenceRepair, FinalizerIntegrity, FrozenPlan,
FrozenPublication, HistoricalTransition, LegacyPlan, PublicationCleanup,
ReleaseEvidenceRepair, RemoteMovement and Replan (SourceDelivery prefix).
Actual qualifier, checker, transport, catalog and selection suites remain owners.

Regressions execute the real custom-gate supervisor without native modules, then
exercise the production shard cache: native-only edits hit the cache; an
orchestration edit invalidates it. Broker regressions cover both stand layouts,
actual changed locked bytes/Go source, consumer and UI-policy drift, unknown inputs,
Vanessa/CFE changes, current artifact tampering, and setup dependency expansion.
This refactor itself needs its affected fixture suites once through registration;
future planner edits must not repeatedly pay for their unrelated publication work.

The live inventory also exposed references/mcp.md as a rejection. Runtime search
finds only links in client guidance; neither native runner reads this instruction.
That exact reference now uses current static proof. Unknown reference paths remain
bound, and a regression rejects a rehashed but unauthenticated historical source.
