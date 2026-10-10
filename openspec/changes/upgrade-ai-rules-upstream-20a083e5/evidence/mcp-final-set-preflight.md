# Final-set placement and MCP preflight — 2026-09-30

The current clean controlled fork is
`38d315de9cf611ca211619fec7f9a2254e7ef04e`, tree
`3a9ec9b49444c9a6ae47affa83152fb9a30e76da`, reconstructed from immutable
upstream `20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`. Schema-3 Verify and
overlay-lock passed for 471 path decisions. The exact fork Full qualification
passed all 18 stages and 135/135 Pester tests, with `worktreeClean=true` and
`reusable=true`; duration 1,153,509 ms. Artifacts remain under the fork's
ignored `build/test-results/qualification/mcp-final-set-38d.json` and
`build/test-results/mcp-final-set-38d/`.

Fork placement now inventories the complete selected/retained client set
before the first placement or obsolete-file removal. Identical contributions
share the existing ownership accounting; different desired bytes at the same
physical path fail without changing files or the manifest. The preflight uses
the actual renderer and its actual command inclusion policy. Five regressions
cover shared owners, conflict and continuation after adapter repair, retained
owners on add, user-modified content, and all twelve production adapters.
Rendering is needed only for shared destinations. These are installer fixture
proofs, not twelve running client sessions.

The ITL MCP writer now plans the complete configuration contribution set for
all selected clients and the ai-rules, on-demand and UI families. File path,
container and native server key identify a contribution. Conflicting desired
values, unselected-owner changes and user-owned collisions stop before the
first configuration or ownership write. Exact input hashes are checked again
before replacement; late user edits are preserved rather than overwritten by
blind snapshot rollback. Existing ordinary write/prune failure rollback remains.
The same preflight runs before fork mutation and before client surface changes.

`MultiClientMcpOwnership` passed 13/13 on the final implementation (132.87 s),
including shared-file conflicts, flags/auth preservation, idempotent repeat,
late-edit refusal and original-operation continuation, TOML handoff, family
conflicts and owned OpenCode alias migration. Kilo retains its native `1C-*`
keys; OpenCode uses the existing `onec-*` conversion. Six selected contracts
also passed under native Windows PowerShell 5.1 (73.85 s). An unchanged empty
client detach regression exposed an empty-array defect in the writer; the
implementation was corrected and the original test passed. The existing
inactive Codex/Kilo legacy cleanup expectation was retained and its owner and
snapshot scope corrected. `SourceUpgradeHandoff` passed 23/23 (58.61 s).
Source XML results are in ignored `build/mcp-preflight-*.xml`.

No project has been rolled out and no remote release/tag was published. The
source release pin remains r36. Earlier r33 file-transition, rollback and hard
crash canaries explicitly used fork `2d3e7705...`; this newer exact-tree proof
does not silently upgrade their provenance. Live MCP initialization,
tools/list, provider calls and client invocation remain separate acceptance.
