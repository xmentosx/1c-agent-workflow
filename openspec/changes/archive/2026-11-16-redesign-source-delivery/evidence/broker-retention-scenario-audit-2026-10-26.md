# Broker and retention scenario audit, 2026-10-26

Scope: the registered seven-entry queue, accepted candidate
`d9a913a1b33e423824ded859dc121d47a7ca4a39`, source head `a6bc42d3`.
No publication or native 1C journey was authorized or started by this audit.
This records a negative optimization result; no extra scenario exemption is justified.

## Independent reuse blockers

The prior plan's first diagnostics are not an exhaustive causal explanation.
`Get-DevelopE2EAncestorQualification` rejects differing consumed artifacts first,
then the first changed native input without a projection. Consequently six broker
messages and three retention messages hide later binding differences.

Retained scenario manifests for both journeys bind controlled fork
`c91682404a498f356810b179ce8336711a411170`, tree
`0dd50116a602b09e51e3d8e3eee6e8ce3fa29596`.
The accepted queue locks r48 `b45e2164440b81ab0c68985da086341efa39c4da`, tree
`0576cb32303be1e9382f4cfa61d0877bbdc3a1b4`.
`Test-DevelopScenarioEquivalentInput` compares complete external identities after
its audited client/artifact projections; rulesCommit/rulesTree remain exact.
Even removal of both proposed source dependencies would not make a retained
scenario proof eligible. Passed fork Full proof is reusable static qualification,
not native installed-project qualification.

## Broker execution/installation matrix

| Scenario | Actual broker interaction | Decision |
| --- | --- | --- |
| upgrade.update | update-workflow installs exact locked broker | retain exact binding |
| upgrade.configuration-rejection | initial update; negative production load/rollback followed by development refresh | retain; not merely the negative load |
| upgrade.verification-export | initial update; separate positive stand update, branch refresh, check and export | retain; not merely export |
| fresh.install | configured init installs exact locked broker | retain |
| fresh.branch | new-dev-branch installs/reconciles managed tooling | retain |
| fresh.refresh | refresh-lite reconciles managed tooling, then fresh check | retain |
| fresh.verification/stale-export/close | existing audited opaque-broker projection | already reusable for broker-only changes; keep native setup |

Installation itself hashes and copies bytes, not a broker RPC invocation. This
must not be described as six runtime executions. However those native scenarios
qualify the corresponding lifecycle integration, and their present proof covers
only the old locked installation. A Release backend test is not a passed init,
new-branch or update/refresh result on these project topologies.

The actual broker delta is not confined to the signed retained-cleanup path:
`runtime.go` wraps broker-start, mcp-connect, catalog-verify, preflight and
mark-running with `backendPhase`; `broker.go` changes cancellation/error handling;
`owner_recovery.go` changes request-budget ownership. `startup_phase.go` joins
phase errors with context cancellation. It cannot be classified as inert logging
or retained-only code. Both Release backend families remain required.

## Retention delta

Only `Get-ItlArtifactProtectedPaths` changes: it protects immutable change history,
reads current-change.json, validates referenced requirements/plan containment and
throws on unreadable/escaping references. The surrounding automatic cleanup still
obtains this plan before testing policy.enabled; disabled cleanup is not evidence
that these reads cannot run.

Current absence of current-change.json on the master stand does not authenticate
historical absence, nested positive/develop state or future state after operations.
Existing immutable receipts do not contain that absence contract. Removing the
file from identity because an initial file probe is false would discard a real
runtime precondition. Function-name routing alone cannot distinguish this delta:
Get-ItlArtifactProtectedPaths is shared by the same automatic cleanup owner.

ArtifactRetentionAndBranchDeletion already covers current impact references,
unsafe paths and accepted history after retirement. That is useful local proof;
it does not establish equivalent lifecycle cleanup in every retained native run.
Do not change the fixture to cumulative verification or remove acceptance state
to obtain reuse. Such a reproducer change would hide the new behavior.

## Result and next valid baseline

No additional native repeat was proven redundant for this accumulated queue.
Keep the existing scenario and artifact projections, original assertions,
rollback/fresh-check/SHA/cleanliness gates and strict controlled-fork binding.
Do not create unmeasured timing discounts or new broad source exemptions.
This audit changes evidence only; executable selection/reuse policy is unchanged.

The last official advisory forecast was 8441s: static1466, upgrade3450,
fresh2444 and ondemand-mcp1081. Its 89 executed/126 reused Pester files are a
current-input result, not a promise that unchanged tests always rerun.
Once this exact queue has a real passed native baseline, reuse can apply to later
small changes when their declared scenario inputs, fork and environment match.
A new plan will be generated after registering this audit; no publication follows.