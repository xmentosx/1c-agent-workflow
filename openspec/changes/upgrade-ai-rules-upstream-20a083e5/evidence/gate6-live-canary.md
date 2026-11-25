# Gate 6 disposable 1C canary — 2026-09-29

An isolated file infobase under a Cyrillic/whitespace `%TEMP%` path was created
through the ITL per-infobase guard with platform `8.3.27.2130`. Its empty
configuration was dumped to `src/cf` and reloaded from the exact effective
Git-tree fingerprint
`v2|git-tree-sha256|bfc05d2d778b3b901e23e86d925f1a56768584b4b2ac39d0537d1ef38186c9ed`.

The checked route executed four separate Designer calls: editable
`/LoadConfigFromFiles`, `/CheckModules -ThinClient -Server -ExternalConnection`,
`/CheckConfig -ConfigLogIntegrity -IncorrectReferences -ThinClient -Server
-ExternalConnection -HandlersExistence -ExtendedModulesCheck`, then
`/UpdateDBCfg`. Both checks returned process exit 0, fresh numeric
`/DumpResult=0`, and no `/Out` warnings/errors. The ignored receipt SHA256 is
`a88c9c7bbd1698833ba51d99e514c17fb58ed2dbdb7fc00efb7679d99969a997`;
editable-load log SHA256 is
`f1945cd6c19e56b3c1c78943ef5ec18116907a4ca1efc40a57d48ab1db7adfc5`.

Elapsed checked load/apply: **39.75 s**. Repeating the same source on the same
disposable base with the previous combined load/apply route took **11.03 s**.
This is a +28.72 s local overhead on an empty configuration, not a PM5 or
server infobase estimate. The original runtime receipt/logs remain outside Git
under `%TEMP%/itl Gate6 живая база 313bb01ebd714f3fa4f22f260b2cb07a`.

The same disposable base also passed the extension route. The controlled-fork
`cfe-init`/`cfe-validate` tools created a two-file `Canary` extension and
reported 13 validation checks. Its exact source fingerprint was
`v2|git-tree-sha256|5fcc19dbffe7e37944a098a427ad5e40ecfe5bc1eb8507dd8fc9c30527550275`.
Editable extension load was followed by `/CheckModules`,
`/CheckCanApplyConfigurationExtensions`, `/CheckConfig`, then
`/UpdateDBCfg -Dynamic- -WarningsAsErrors -Extension Canary`. Each check
returned exit 0, fresh `/DumpResult=0`, and a clean `/Out` log. The ignored
receipt SHA256 is
`dce276b37c750f90e83bf730ae20eaaeb4bdd4044c589775bd52abe41d3240371`.
Elapsed extension load/check/apply: **51.61 s** on the empty base.

On 2026-09-30 a separate source copy received an owned server common module
whose exported procedure calls `НеСуществующийМетодCanaryGate6`. The fork
metadata compiler created it and CFE structural validation passed 13 checks.
The original positive source files were not edited. The exact negative source
fingerprint was
`v2|git-tree-sha256|4133d01a4ad3cf5b58de682d05edf36746279775b586a64bd0718a3b3e42ff24`.

The real guarded editable load passed; `CheckModules` then returned process
exit **101**, fresh `DumpResult=101`, and native `/Out` missing-method errors
for Server and ExternalConnection. The trace contains exactly those two
Designer calls: no applicability/configuration check, fallback or
`UpdateDBCfg` was executed. Negative elapsed time was **34.88 s**. Native
error-log SHA256:
`4f58ce3e505a6704a40f7a0236d4566f9ba1bb11b70029c457fa0119f0323cb6`.

Repeating the checked operation with the original correct source passed
editable load, all three checks and database apply in **52.29 s**. Receipt
SHA256: `2d256718bf88efdd6f4820d64f1127a41cf92cf218408322b9d7a399a6a12649`.
Original source byte hashes remained identical. The ignored source artifact
is `build/gate6-negative-b68ba2361fdd4f01a566ecd448c04c6e/summary.json`, SHA256
`16de857bb2dc7a7a61dbaf161e119b2bcb4473873739e13a831641d6e2897c26`.
The first probe's final assertion looked for the method name in the helper
exception instead of the linked native Out log; recorded signals were
independently verified, and the probe now reads the native log. No product
assertion was weakened and no successful native run was repeated to hide it.

A second source copy used the qualified `meta-compile` and `cfe-borrow` tools
to borrow a common module from a separate synthetic source configuration. The
actual disposable base had no such module; no main configuration was changed.
Its fingerprint was
`v2|git-tree-sha256|f726e2dccf7fc11465a1f24936ef1c8949ddf76178f57f5866297a6112edad15`.
Editable load and `CheckModules` passed. The applicability check returned
exit **1**, fresh `DumpResult=1`, and `/Out` reported the missing borrowed
`ОбщийМодуль.Canary_Gate6Failure`. Exactly three Designer calls occurred;
neither `CheckConfig`, fallback nor database apply ran. Negative time was
**31.82 s**, error-log SHA256
`e942a12fcd17d73e3a3afa57afd632a72a60141878f1cec9cb9c45f3e175a25b`.
Correct-source continuation passed all checks/apply in **50.35 s**, receipt
SHA256 `899e9092dae04c1f2595beb292cc82b02b50d03b0037a644d052040b2e187d13`.
The corrected probe exited 0; original source bytes remained identical.
Ignored summary: `build/gate6-negative-ac3949220031407bb3269d46acb37230/summary.json`,
SHA256 `967df53e72a54aadf834ab1fb0819385848a8a7b411ac8db85e4f08c2c307197`.

This proves positive main/extension paths, negative module and applicability
boundaries, and successful continuation on an empty file infobase.
A representative configuration,
native snapshot/rollback for ordinary source/tooling apply, and the complete
installed refresh remain unverified.

## Checked-load snapshot and scoped recovery completion — 2026-09-30

The checked-attempt owner now creates a native non-empty DT before an editable
source or CFE load. It registers the existing on-failure restoration duty and
records the snapshot SHA in the editable-load evidence. A failed editable load,
artifact identity check, platform check or apply restores that exact snapshot
through guarded Designer before surfacing the original failure. It preserves
the original failed Out log even though restore has its own log. After successful
restore or apply the local snapshot is removed; failed restore retains the DT,
pending duty, both diagnostics and the existing owner's scoped continuation.
A successful native apply is never rolled back after a lost completion ACK.

The enclosing extension-init/Release snapshot is reused for the same target,
with its hash checked and its original completion/rollback policy preserved.
This avoids a second snapshot or deployment owner. Known binary-only main loads
and unchanged-source skips retain their earlier route; file-only workflow update
does not run Designer or Gate 6.

Directly owned DesignerBatchChecks/DesignerLoadProof tests passed **17/17** in
10.98 s (`build/gate6-snapshot-owner-tests-after.xml`). Two subsequently added
focused regressions each passed **1/1**: CFE SHA drift stops before checks/apply,
restores, then the stable original artifact completes; completion ACK loss never
replays restore (`build/gate6-cfe-exact-artifact-test.xml`,
`build/gate6-apply-completion-ack-test.xml`). This is 19 covered cases across
those runs, not a claim of a repeated complete 19-test run. The first 11/17 run
is retained as `build/gate6-snapshot-owner-tests.xml`: its failures exposed shared
fixture journal state and native mocks that assumed only load calls. Fixture
isolation and explicit DumpIB/RestoreIB behavior were repaired while retaining
the original load failure, exact path, invalidated proof, fallback and apply
assertions.

The previous missing-method reproducer ran again against the same owned file
base and original negative source workload. Its call sequence was **DumpIB →
editable LoadConfigFromFiles → CheckModules → RestoreIB**. The module check again
returned exit/DumpResult **101** and the same native missing-method diagnostic;
Out SHA remained
`4f58ce3e505a6704a40f7a0236d4566f9ba1bb11b70029c457fa0119f0323cb6`.
There were zero database applies and one source load, with no full fallback.
The native DT was 33,491 bytes, SHA
`e69c063049a70326941c67689b75bbd95cfffdd2a0f38fbadb96aa5da33b7c08`.
Independent Designer dumps of the editable extension before failure and after
restore had the same two files and exact byte hashes. Correct-source continuation
then passed all three checks and applied successfully; original source bytes
remained unchanged. Negative/restore took **43.44 s**, successful continuation
**62.90 s**. Summary
`build/gate6-negative-d429b95232f34ff9b41d7fa6eb9a259c/summary.json`, SHA
`7524b818b1aec3cbce07425e584efc28408062143cb960ea689806010f35558d`;
passed receipt SHA
`aedcd6c40002538aec0db5584e90d3e9f496f92af8cf70242b334e0292266dc1`.

The previous missing borrowed-object reproducer also ran unchanged. Its sequence
was **DumpIB → editable LoadConfigFromFiles → CheckModules → applicability →
RestoreIB**. Applicability again returned exit/DumpResult **1**, with Out SHA
`e942a12fcd17d73e3a3afa57afd632a72a60141878f1cec9cb9c45f3e175a25b`.
No CheckConfig, fallback or apply followed the failure. The native DT was
35,936 bytes, SHA
`e50ab4e4bb2501b11a9985cb846c59c0864127d3638a68d7e34a8c396032f9ec`.
Independent before/after editable-extension dumps again matched exact bytes;
correct-source continuation passed all checks/apply and original sources were
preserved. Negative/restore took **51.57 s**, continuation **62.58 s**. Summary
`build/gate6-negative-91262e1df8fc41dd87869934b3ce4a55/summary.json`, SHA
`a4f353b7b151d5b35e7d0778b322330134fcb2c0caaf3eb3d95bfb296ddeff7c`;
passed receipt SHA
`f947792e93bcf40f2d9be8e30d6d921a5709e94728d39a4bb6bfae7ee055ccd7`.

Compared with earlier same-base correct-source continuations (52.29 / 50.35 s),
the checked snapshot routes took an additional **10.61 / 12.23 s**. The failed
routes also perform restore, so their added time is not a pure snapshot estimate.
These measurements apply only to this empty file base; representative PM5,
server and full installed-refresh acceptance remain part of tasks 10.2/10.4.

Platform fallback uses this already-authorized load/check/apply owner and its
exact-source/target evidence. It supplies syntax/context and structural checks,
not semantic logic or MCP standards proof. Unavailable platform targets remain
explicitly unverified before mutation; a read-only task cannot grant a load.
EDT's validation/update owner remains authoritative for EDT-format trees; an
explicit XML export/import route can use the ladder, but a second EDT deployment
owner is not introduced. The installed verification reference records these
boundaries. Remote MCP validator availability and representative runtime proof
remain separate acceptance; neither is inferred from the platform passes.
