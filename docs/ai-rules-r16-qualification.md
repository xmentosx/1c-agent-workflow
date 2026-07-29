# ai_rules_1c r16 targeted qualification

- Release branch/tag: `release/itl-main-72665287-r16` / `itl-main-72665287-r16`
- Fork commit: `0118493165fd9507169317be28d53c52803d52ed`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Scope: restore direct full-cycle routing without weakening verification

Targeted qualification:

- fork `R8Policy`, `Installer`, and `LayoutAndManifest`: 40 passed;
- workflow overlay reconstruction/idempotence, parser/docs budgets, bootstrap/update, dependency locks, migration, and client-mode contracts;
- PowerShell AST and `git diff --check`;
- Full and Release were intentionally not run per maintainer instruction.

The release keeps upstream promotion triggers and strict applicable validators.
Installed-project completion still requires relevant Vanessa coverage and a
fresh successful `/itl-check` after the last change for quick-fix, direct
full-cycle, and OpenSpec alike.
