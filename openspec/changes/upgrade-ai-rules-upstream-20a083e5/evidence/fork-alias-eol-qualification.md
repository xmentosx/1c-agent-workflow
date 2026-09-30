# Legacy OpenSpec alias EOL repair — 2026-09-30

Exact controlled-fork candidate:

- Commit `9ec86f75343ba4eded66e2085f097ff4baab7d67`.
- Tree `165a89a220820efa5d231c36c9d0d94a698b8b47`.
- Upstream `20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`.
- Local annotated canary `itl-main-20a083e5-r39-canary-9ec86f7`, revision 39,
  tag object `31e0aa6f5fb305e9b23a56f022c8bb0a4835641f`.

The prior 015/r38 and ee9/r37 refs and qualification records remain untouched.
The source default remains published r36. This local tag is a qualification
input, not a remote release or an installed-transition receipt. Source
executable files were not changed by this repair; its authoritative owner is
the controlled fork, never an installed copy.

## Cause and retained reproducer

A read-only representative-branch check found eight retired r33
`.agents/skills/opsx-*` bodies/metadata with LF working bytes whose CRLF
variants exactly matched all eight recorded installed hashes; `userModified`
was absent. Source artifact `build/legacy-opsx-newline-qualification.json`
retains that input evidence. The retirement function used raw SHA comparison
and incorrectly preserved Git-only newline changes as user edits.

The existing first `Installer.Tests.ps1` alias test now creates the same CRLF
hash/LF checkout condition through real Git add/checkout in its original
Unicode/space project. Before repair it failed at the unchanged removal
assertion (23.66 s). After repair it passed (22.21 s), preserving semantic
edits with `userModified=true`, unowned notes, unknown hashes and invalid
UTF-8 bytes. The final Full ran that same regression successfully (23.12 s).

Only `install.ps1` and the existing `tests/Installer.Tests.ps1` changed.
`Remove-LegacyCodexOpenSpec` now calls the already-owned
`Test-FileMatchesInstalledHash`, which accepts only strict UTF-8 known newline
variants and keeps BOM/binary protection. The phase/source/userModified and
containment guards were retained; no generic installer or new migration owner
was introduced.

Fork artifacts:

| Proof | Artifact / SHA-256 |
| --- | --- |
| Before: expected unchanged-alias cleanup failed | `build/test-results/legacy-alias-eol-before.xml`, `150e6ccbe190d0a0c779d2e9c719f6a786d4ee20799ffa4df1dfc6492b1bfdf6` |
| After: 1/1 selected owner regression passed | `build/test-results/legacy-alias-eol-after.xml`, `c5ba100ca0c69f6a02cc21dbd4161b82c420bc764db0e4bc54919c0067366d09` |
| Exact reusable Full | `build/test-results/qualification/alias-eol-9ec86f7-full.json`, `6c9b4ca27cc3d9af1693f2f06cbd620dcd419c389c962b3e34876f374e7eb647` |
| Exact Full JUnit | `build/test-results/alias-eol-9ec86f7/pester.xml`, `e2ceb2d07ead79e472f7070de56c247c4127b75b4628e8572ed6ecd9c52cfedd` |

## Full, ledger and local-only boundary

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full `
  -UpstreamCommit 20a083e5bd9fa41402ad8428b740c4c01f0cc3d6 `
  -OutputDirectory build/test-results/alias-eol-9ec86f7 `
  -QualificationPath build/test-results/qualification/alias-eol-9ec86f7-full.json
```

Full passed **137/137 Pester, 18/18 stages**, zero failures/skips,
`worktreeClean=true`, `reusable=true`, duration **1,083,269 ms**.
The read-only `publish-fork-release.ps1 -QualificationProbeOnly` confirmed
exact reuse before fetch/ref mutation paths. No publication invocation ran.

Source schema-3 Verify passed **472 decisions**, 379 upstream paths and 192
baseline downstream paths. Report: `build/overlay-alias-eol-9ec86f7-verify.json`.
Independent archived overlay-lock also passed 472 paths, retained under
`build/overlay-lock-alias-eol-9ec86f7/`. The ledger changed only the existing
installer/test result hashes and explanatory reasons; earlier path decisions,
upstream/baseline hashes and dispositions remain intact.

The current Full also passed the real child-process managed-plugin regressions.
Historical native ee9 Codex and 015 source-bridge receipts keep their original
identities; this is not new native client, MCP, model or 1C runtime proof. The
final canonical-source installed transition and read-only bridge/doctor remain
separate acceptance. No source Full/Smoke/Develop/Release, source registration,
remote refs or ordinary client-profile changes were performed by this owner.
