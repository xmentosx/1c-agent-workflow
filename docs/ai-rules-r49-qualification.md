# Combined r49 source qualification

The local candidate `df91727cc584a9b499cad1d9daa6ac22320486f9` on
`upgrade/r49-memory-acceptance` preserves r48
`b45e2164440b81ab0c68985da086341efa39c4da` and cherry-picks the four
memory files from `162f2ea7a5734b65bc1de80943d057e9b7c0a525` with `-x`
provenance. Upstream remains `2f640143756ecd01fed42100e412632aa9082385`.
The new local annotated tag is `itl-main-2f640143-r49` with explicit upstream
provenance; no existing tag is moved. The workflow installer pin, project template and
scoped-memory policy name this single combined candidate; compatibility remains
`pending` until the publication owner qualifies and finalizes it.

The schema-3 overlay verifies all 297 decisions with no blockers. The four
memory result hashes are unchanged: it already contained both r48 and memory
bytes. Those entries' reasons gain the composition provenance. The validator's
result hash accounts for the measured combined context budget below.
Initial composition evidence is in `build/r49-overlay-verification.json`.
The final exact-commit archive/overlay check is recorded with all 297 decisions
in `build/r49-compatibility-final.log` in the source task checkout.

The first twelve-client compatibility attempt correctly stopped at the old
assertion requiring project-isolated `1c-templates-mcp` memory. The approved
memory candidate explicitly corrects that false premise: global templates are
shared, while scoped Cognee needs qualification and explicit opt-in. The checker
now requires exact source/installed root memory bytes (LF/CRLF normalized), the
managed-project marker, all four strict root criteria, the ban on unqualified
project facts, the scoped capability, private pending, shared templates and the
standalone boundary. Nine focused cases cover acceptance, byte tampering and
removing each semantic boundary. Init, idempotent update, doctor, foreign client
configuration and user prompt preservation remain mandatory for all 12 clients.
Failed evidence is retained in `build/r49-compatibility.log`. The corrected
intermediate composition passed all clients in `build/r49-compatibility-v2.log`;
the final `df91727` candidate passed all twelve clients in
`build/r49-compatibility-final.log` after the validator adjustment.

The first fork Full passed all 182 Pester tests, then stopped at the context
budget: 143,908 bytes exceeded the 140 KiB (143,360-byte) limit by 548 bytes.
Relative to r48's 141,300 bytes, mandatory scoped-memory policy adds 2,608 bytes
(about 652 tokens at bytes/4). Its opt-in, grants, private pending and separation
of shared/project memory remain intact. The explicit hot-path ceiling grows only
to 141 KiB (144,384 bytes; 476 bytes headroom); always-on root (12,800 bytes),
subagent start (30,616 bytes), their ceilings and individual rule limits do not
change. Commit `df91727cc584a9b499cad1d9daa6ac22320486f9` records this adjustment
after the provenance-preserving composition at `9948f092febf9621dff2fd14ef33bcd3c752a859`.
Exact Full must pass after this checker change. Its authoritative status,
reusability, source identity and stage results are in the fork checkout's
`build/test-results/qualification/full.json`, with logs in
`build/test-results/r49-combined-full`. Registration does not substitute for that
receipt, native G5 or a publication qualification.

The scoped-memory policy's r47 baseline records historical provenance. Changing
its candidate identity does not pass native Cognee G5: that gate and publication
remain pending. Changed memory policy bytes cannot inherit native E2E proof via
the guidance-only fork bridge. No installed project or infobase is changed.

Plan preparation now warns above 120 seconds and rejects above 300 seconds;
the nested static preview uses the same owner contract. The actual 126/151-second
failures are retained as successful-plan regressions, with 300001ms still rejected.
The Core/Desktop child regression covers Unicode paths, the normal result and an
expired shared deadline with cleanup. Verification and 1C execution budgets are
unchanged. An already frozen plan retains its supervisor's original contract.
