# PL3 exact-fork qualification — 2026-09-30

## Candidate identity and local-only boundary

- Fork checkout: `D:/Git/itl_ai_rules_1c-upgrade-20a083e5`.
- Branch: `upgrade/main-20a083e5-r1`.
- Commit: `015cf9856c37fcecdf03df2faa8b8546f84849b4`.
- Tree: `a151392df2dcba4e8411359919b3ec2fb5b8d067`.
- Audited upstream: `20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`.
- Isolated annotated canary: `itl-main-20a083e5-r38-canary-015cf98`, tag object
  `49eba0ea563b5f3ad93d71f88b5e5d8991a92e16`, downstream revision **38**.

The existing r37/ee9 canary refs were not moved. The migration owner requires
the target downstream revision to exceed the installed revision for a changed
controlled-fork identity; r38 permits upgrading an existing r37 canary. The
source default lock/project pin remains published r36. No remote ref, source
registration or publication was performed. The local tag is acceptance input,
not a published release or a completed installed transition.

## Reproduced defect and bounded owner repair

The previous event handler logged a warning and resolved successfully after
the real PowerShell wrapper exited 1. The actual-child Node reproducer failed
on this missing rejection before the patch. A second real failure exposed
damaged Cyrillic in a diagnostic path because Windows PowerShell 5 emitted
its default encoding while Node expected UTF-8.

The four-file local commit changes `plugins/1c-rules/plugin.mjs`,
`plugins/1c-rules/scripts/invoke-install.ps1`,
`tests/ManagedPluginDispatch.Tests.ps1` and `tests/plugin-event-harness.mjs`:

- Nonzero ensure now warns with the numeric exit code and rejects with
  `OneCRulesEnsureError`, `code=ONEC_RULES_ENSURE_FAILED`, `exitCode` and the
  bounded diagnostic. Control characters are removed from that diagnostic.
- The wrapper establishes UTF-8 before output. Both Node streams use
  incremental UTF-8 decoding, and receipt completion uses `close` after drain.
- Real wrapper failures cover missing and unsupported managed helper protocols.
  The recovery text and an exact path containing Cyrillic and whitespace survive.
- Unrelated events and successful standalone/managed ensure leave the complete
  project file/directory snapshot unchanged. Session ensure does not invoke the
  installed lifecycle helper or attach/update a client.

These are owner-boundary checks using real Node and PowerShell child processes.
They do not simulate successful native host discovery or invocation.

## Exact Full and overlay proof

The authorized fork-only command was:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full `
  -UpstreamCommit 20a083e5bd9fa41402ad8428b740c4c01f0cc3d6 `
  -OutputDirectory build/test-results/pl3-015cf985 `
  -QualificationPath build/test-results/qualification/pl3-015cf985-full.json
```

It passed **137/137 Pester tests** and **18/18 required stages**, with zero
failed/skipped tests, `worktreeClean=true`, `reusable=true`. Duration was
1,206,864 ms. All recorded commit/tree identities match the candidate above.
The read-only `publish-fork-release.ps1 -QualificationProbeOnly` confirmed
current inventory, runtime and artifact reuse before its fetch/ref mutation
paths; this was not a publication invocation.

Artifacts relative to the fork checkout:

| Artifact | Identity/result |
|---|---|
| `build/test-results/qualification/pl3-015cf985-full.json` | SHA-256 `d26a546263278d991d1cf85f5712c4c3b6c1b964ab1fe9d608b6666d0a01aa5c` |
| `build/test-results/pl3-015cf985/check-summary.json` | Full passed; 137 tests, 18 stages |
| `build/test-results/pl3-015cf985/pester.xml` | SHA-256 `bf3c901145af294304c1ff194e23e5258d57198b641ba6c4897eb116d299bb08` |

The source schema-3 ledger keeps all earlier path decisions and adds one
downstream-only harness, reaching **472 paths**. Only three existing result
hashes/reasons changed for PL3; upstream/r36 hashes and dispositions remain.
`build-ai-rules-release.ps1 -Mode Verify` passed on the exact clean candidate;
its source-side report is `build/overlay-pl3-015cf985-verify.json`.
`test-ai-rules-overlay-lock.ps1` independently passed 472 archived paths;
its retained area is `build/overlay-lock-pl3-015cf985` in the source worktree.
No source Full/Smoke/Develop/Release gate was run for this subtask.

## Native host rejection handling remains unverified

The matching public OpenCode v1.18.11 source invokes the legacy event callback
with `void` and does not await/catch its returned Promise at that call site.
[OpenCode plugin handler, lines 235–242](https://github.com/anomalyco/opencode/blob/v1.18.11/packages/opencode/src/plugin/index.ts#L235-L242)

Node's default policy raises an unhandled rejection when no listener handles
it; the OpenCode package's dev/build commands use Bun. These facts do not prove
the installed desktop client's full rejection policy, including imported
runtime/TUI listeners. A whole-client crash, and the absence of such a crash,
remain **unverified**. No authenticated or ordinary-profile OpenCode session
was opened, and the fork was not altered based on that uncertainty.
[Node rejection policy](https://nodejs.org/api/cli.html#--unhandled-rejectionsmode),
[OpenCode v1.18.11 runtime commands](https://github.com/anomalyco/opencode/blob/v1.18.11/packages/opencode/package.json#L7-L16)

## Historical proof is preserved

The preceding ee9 commit/tree passed 136/136 Pester and 18 stages; its clean
reusable record remains `build/test-results/qualification/openspec-r33-alias-final.json`.
The unchanged default `build/test-results/qualification/full.json` contains the
earlier 2d3e770 candidate's 130-test record. Native ee9 Codex install/discovery/
disable evidence remains in [plugin qualification](plugin-qualification.md) and
[client/runtime evidence](client-runtime-and-ui-owner.md), with its original
candidate identity. Neither that evidence nor the earlier B3/r37 paused-case
result is relabelled as native acceptance of the current r38 candidate.
