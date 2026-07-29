# ai_rules_1c r17 qualification

- Release branch/tag: `release/itl-main-72665287-r17` / `itl-main-72665287-r17`
- Fork commit: `27a898c426a1016fffc4a1b008e8ac0cb1490da2`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Scope: add explicit-only Codex `$opsx-*` aliases while retaining canonical implicit OpenSpec skills

Qualification:

- fork targeted alias reconstruction, installer, and layout/manifest contracts: 8 passed;
- fork Full gate on the clean release tree: 61 passed;
- workflow targeted dependency-lock, migration, client-mode, parser/docs, and compatibility contracts;
- PowerShell AST and `git diff --check`.

The four aliases delegate to the canonical `openspec-*` skills and set
`allow_implicit_invocation: false`. The canonical skills remain unchanged and
eligible for implicit routing.
