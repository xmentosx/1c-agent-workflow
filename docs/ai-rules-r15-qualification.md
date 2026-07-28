# ai_rules_1c r15 targeted qualification

- Release branch/tag: `release/itl-main-72665287-r15` / `itl-main-72665287-r15`
- Fork commit: `cf31a89deaee5d39bab5cce490330d204e6e1233`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Scope: quick-fix classification correction only

The compact router now applies the canonical upstream promotion triggers
without promoting an otherwise eligible internal BSL bug fix merely because it
corrects existing behavior. Public contract changes, wired metadata,
transactional/posting/write paths, adopted extension objects, RLS, event
subscriptions, and scheduled/background jobs still promote to full-cycle.

The completion requirement is unchanged: relevant Vanessa coverage and a fresh
successful `/itl-check` after the last edit remain mandatory before an agent
reports an installed-project configuration or extension change ready or done.

Targeted evidence:

- workflow overlay, documentation, lock, migration, and client-contract tests:
  84/84 passed;
- fork `R8Policy.Tests.ps1`: 8/8 passed;
- overlay reconstruction: generated with zero blockers and exact upstream
  provenance;
- canonical `verification-policy.md` blob:
  `906ae35d5b1323ad0bf396877d4f2d48eaa17f2a` in upstream, r14, and r15;
- r15 delta relative to r14: `AGENTS.md`, downstream ledger, r15 release note,
  and the focused fork policy regression only;
- PowerShell parser and `git diff --check`: passed.

Per the maintainer's explicit instruction, fork Full and workflow
Fast/Full/Release gates were not run. This is a targeted policy qualification,
not a full runtime/release qualification.
