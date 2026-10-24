# Static reuse forecast and repeated preparation

2026-10-24. Owner: existing Pester shard reader and candidate plan calculator.
No publication, native E2E or release qualification is part of this change.

The previous static estimate used the historical whole-stage duration (2066 s)
without the current shard cache decision. The new advisory preview uses the
same fingerprint, legacy lookup, SHA/runtime/path acceptance and admission
barriers as execution. It revalidates on execution. It never starts test workers,
downloads dependencies, restores/promotes proof or changes the non-reuse list.
Compatibility remains parallel with Pester; unselected fixture capture is
excluded from historical overhead. Hard deadlines and all assertions remain.

Proven redundant work removed:
- repeated contract/test scans and wildcard inventory matching per shard;
- PowerShell provider/cmdlet overhead for existence checks: direct file APIs
  retain every existence check and reauthentication of dirty/unindexed bytes;
- parent-shell version in the actual worker identity key.
The next invocation recomputes its snapshot, including changed/missing inputs.
Actual child executable, Pester/module bytes and protected proof remain checked.

A Core preview of the accumulated candidate reported 162 execute / 32 reuse;
the checker Desktop host reported 71 execute / 123 reuse. Parent string sort
order affected the inventory serialization too. Preview now runs in the same
Desktop host as Develop, including when called from Core.

Read-only measurements on this checkout: previous published qualification
fingerprint planning 112604 ms; initial revised preview 34220 ms; with direct file APIs and cached ownership matching, the final strict Desktop
preview measured 6582 ms. An intermediate identity-line cache was rejected by
an existing in-lookup mutation regression and removed.
These are preparation measurements, not publication times.

All 20 explicitly non-reusable files remain required. They cover Windows
CIM/process/window/lock boundaries, installed engines and transport/host
runtimes whose external identities are not fully fingerprinted. Their reasons
and weights are exposed separately from ordinary changed/missing proof.
The accumulated queue also changes test ownership/selection and rollback tests;
those misses are not equivalent to the mandatory external-runtime cohort.

Focused acceptance: 52/52 tests across SourceDeliveryPlan, PesterRuntimeProof
and LocalShardCache, plus the subsequent Core-to-Desktop Unicode path regression
and 43/43 SourceQualityCatalog cases, including mutation within one lookup.
Coverage includes cold/warm lookup, no execution or cache mutation during preview,
corrupt proof refusal, changed inputs, mandatory non-reuse, legacy scheduler keys,
cross-parent actual runtime identity, and scheduling/fixture/parallel ETA.
The first registration rejected incomplete extracted-function setup; cache
initialization is now owned by the digest function, and fixtures describe the
actual required child version. No mutation assertion was removed. Registration
owns the final Targeted run on the integrated queue candidate.
