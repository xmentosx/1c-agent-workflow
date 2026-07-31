# ai_rules_1c r19 targeted qualification

- Release branch/tag: `release/itl-main-5ae333ed-r19` / `itl-main-5ae333ed-r19`
- Fork commit: `7952e7d9bb050d67e145c0136e87b6855c353f58`
- Upstream provenance: `refs/heads/main@5ae333ed49dc66989e305b286acc93691bb96926`
- Scope: preserve the root `.dev.env` across legacy full and client-scoped removal

The installer now identifies the root `.dev.env` by its resolved project path.
It preserves the file independently of legacy `template`, `userModified`, and
`owners` metadata. Existing legacy manifest entries are normalized to
`template: true` without rewriting dotenv bytes, changing `installedHash`, or
clearing recorded drift.

Targeted evidence:

- fork `Installer.Tests.ps1`: 23 passed, including exact-byte full
  `remove -> init`, client-scoped removal, metadata backfill, and secret-canary
  log checks;
- schema-2 overlay verification: 51 upstream paths and 93 downstream-only
  paths accounted for on the clean linear release commit;
- workflow overlay, migration, client-replacement, and dependency-lock
  contracts: 40 passed;
- the affected natural OpenSpec doctor fixture: 1 passed;
- compatibility init, byte-idempotent update, doctor, manifest, and ITL
  ownership checks passed for all ten supported clients;
- PowerShell parser and `git diff --check`.

The immutable release branch and annotated tag both resolve to the fork commit
above. Per the maintainer's explicit instruction, fork Full and workflow
Fast/Full/Release gates were not run. No installed-project live smoke was run.
