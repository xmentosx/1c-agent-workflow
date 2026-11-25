# Source delivery catalog qualification

The non-executing targeted planner initially rejected the migration inventory.
Two new Pester files had no declared owner, four new public helper actions were
missing from the lifecycle/semantic action inventory, and four runtime resource
paths were not assigned to a quality contract. These were delivery metadata
omissions; no source gate was run to discover them.

The existing catalog now assigns:

- `DesignerBatchChecks.Tests.ps1` and guarded Data MCP extension installation to
  the lifecycle owner, including its existing Designer verification tests.
- `VerificationAggregateAssessment.Tests.ps1` to the Vanessa verification owner.
- The exact OpenSpec npm package/lock resources to the OpenSpec runtime owner.
- `plugin-dispatch.json` to the clients/rules owner.
- `begin-one-off-proof` and `complete-one-off-proof` to the existing verification
  semantic owner; local OpenSpec new/archive actions to the OpenSpec owner.

The four actions are recorded in the boundary inventory. No new selective AST
node, gate, runtime authority or quality contract was introduced; unknown
semantic changes retain the existing complete lifecycle fallback.

After these corrections, `scripts/resolve-targeted-tests.ps1` accepted the
current migration paths and produced `build/migration-targeted-plan-final.json`:
12 existing contracts and 82 selected test files. The explicitly deferred
`add-external-openspec-store` change was excluded. This validates catalog
coverage and selection only. It is not a Targeted pass, source registration,
publication or final qualification of code still being corrected by the live
acceptance owners. Registration must run the selected tests on the final commit.

The subsequent nonexecuting C3 selection in
`build/migration-targeted-plan-c3.json` contains 135 paths, the same 12 existing
contracts and 82 test files. C3 is the private immutable source commit
`647df3dafd81c3bf0b18785a6861453fe320d943`, with the locally qualified r39 pin;
it does not change the published dependency defaults. Native Windows PowerShell
5.1 `ParseFile` accepted all 57 selected PowerShell files with zero errors
(`build/migration-parser-powershell51-c3.json`). This is syntax and delivery
inventory evidence, not an executed source gate or completed registration.

The owner-local cache correction was then frozen as private C4
`6c651f9b164ae1932c65bab661de315640017e83`. Its nonexecuting selection contains
137 paths, the same 12 contracts and 82 test files, with zero deferred external
storage paths. Native Windows PowerShell `ParseFile` again accepted all 57
PowerShell files (`build/migration-parser-powershell51-c4.json`). Source-delivery
Status found four other queues and no active operation; their entries were not
changed. Registration still belongs to the final coherent source commit.

## Windows PowerShell file decoding

The real Windows PowerShell 5.1 `ParseFile` inspection of all 57 changed
PowerShell files found 12 Pester files with UTF-8 bytes and no BOM. Their
Cyrillic fixture paths were decoded through the Windows ANSI code page,
causing parse errors. All package executable scripts parsed successfully.
Strict UTF-8 `ParseInput` accepted the unchanged bodies of those 12 tests.
The retained reports are `build/migration-parser-powershell51-final.json`
for immutable canary C and
`build/migration-parser-powershell51-before-bom-worktree.json` for the source
worktree; their raw file hashes differ where Git materialized line endings.

Only the UTF-8 BOM prefix was added to the 12 source test files. Exact
before bytes are retained under the owned ignored backup directory recorded
in `build/migration-test-bom-repair.json`; all 12 body-byte comparisons passed.
The original Unicode paths, test assertions and workload remain unchanged.
The same real PowerShell 5.1 inspection then parsed all 57 files with zero
errors: `build/migration-parser-powershell51-after-bom.json`.

An additional byte inventory found `VerificationProofReuse.Tests.ps1`
without a BOM. It parsed successfully but silently changed five Cyrillic
string literals under PowerShell 5.1. Comparison of real `ParseFile` literal
values against strict UTF-8 `ParseInput` proved five mismatches before and
zero after adding only its BOM. The exact test body was retained unchanged:
`build/proof-reuse-bom-repair.json` and
`build/proof-reuse-unicode-literals-{before,after}.json`. In total, 13 test
files received only this prefix; the earlier separate restoration of the
existing `ClientAdaptersAndModes.Tests.ps1` BOM is documented by its owner.

This is a nonexecuting encoding/syntax check, not a Pester or Targeted pass.
The canary C package runtime remains unchanged; its test-file BOM repair is
verified in the source worktree and will be included in final registration.

## Deferred specification preservation

The four untracked planning documents and `.openspec.yaml` schema marker for
`add-external-openspec-store` were transferred byte-exact to the existing separate worktree
`C:\Users\xment\.codex\worktrees\external-openspec-store\1c-agent-workflow`,
branch `codex/external-openspec-store`, for its already-created deferred chat.
No existing destination files were replaced and no external-store implementation
was started. Exact source/destination paths and five SHA256 values are recorded
in `build/deferred-openspec-spec-transfer.json`. These documents remain available
there and are excluded from this migration's coherent commit and Targeted range.
The current change retains the explicit local-only boundary and the deferred
architecture reference.
