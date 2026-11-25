# Retained broker cleanup: consumed branch, not whole module

The previous advisory plan (`3c94ac48b2c07c6a668716a7fb8e24509bfd95e58b649c2cd124233d14fd6b41`,
candidate `ae24a94a218d4cdaa015408df43bd1f97f3d8bc9`) estimated 2:16:13:
19:58 static, 57:30 upgrade, 40:44 fresh and 18:01 broker Release. Its three
broker-independent fresh scenarios still rejected reuse because the complete
`agent-1c.ondemand-mcp.ps1` source hash changed.

The changed peer-ownership decision is inside `Stop-ItlOnDemandBackendInstanceCore`
only under `if ($retained)`. Retained state defaults to null. Ordinary lifecycle
drain enumerates project-local registrations and calls stop with
`ExpectedRuntimeState`, without retained state. Only internal broker stop and
recovery supply retained launch proof. Develop runners never request
`InternalOnDemandOperation`; the helper dispatches that operation separately.
Fresh provision copies project configuration and selected environment lines,
not the project-local `.agent-1c/mcp/ondemand` registrations. No RPC broker is
started by either Develop runner.

The authoritative source projection removes only the retained-only conditional
and the peer helper called exclusively inside it. It authenticates the original
source SHA before comparison, keeps registered drain and all other functions,
and refuses unknown conditional shape, changed null default/mode assignment,
or a new shared retained/peer-helper caller. Both selection and reuse consume
the same projection. No installed runtime, lock, rollback or artifact admission
changed. This is a stateless source-identity refinement, within the existing
architecture authority.

The new focused regression uses actual module source and the original retained
rejection topology. It stores real immutable qualification receipts, replaces
only the observed cleanup branch/helper, and checks all six fresh and all three
upgrade scenario receipts can be reused. Six negative mutations retain native
selection and reject reuse: registered drain, shared helper, shared retained
caller, non-null default, unknown function and top-level execution. A separate
set-completeness regression pins retained/recovery callers and internal dispatch.
The tests have their own catalog owner; the existing large incremental suite is
not made a consumer of every broker edit.

This removes an unnecessary cause of Develop repetition. It does not qualify a
new executable: the exact broker still requires Release on both backend families.
During this audit the queue also acquired `change-verification-model`, head
`174e77964abe1823c8a9746b798211b50763fe1c`, integrated candidate
`f15735e269107179536e164f97b46e6510993caf`. It changes installed check, Vanessa
execution, verification selection, artifact assessment and export/close handling.
Its actual native consumers must remain in the accumulated publication plan.
Compare official post-registration plans against their exact queue candidates;
do not report an isolated cleanup reuse result as whole-queue native reuse.
