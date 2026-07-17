# Controlled ai_rules_1c upgrades

## Current qualified release

The workflow is pinned to `itl-main-b4d9875b-r10` at fork commit `760aab7fc2ef12d5019749e564803bbd4d6b1f5a`. Its exact upstream provenance is `refs/heads/main@b4d9875b15c6d93f493035aee51f077126e72a21`. `templates/dependency-lock.json` is the single source of this tag, commit, upstream provenance, downstream revision `10`, and `compatibilityStatus=passed`; project templates, code, docs, and tests must agree with it.

Fork `main` is the clean upstream snapshot. Downstream changes exist only on immutable branch/tag `release/itl-main-b4d9875b-r10` / `itl-main-b4d9875b-r10`, which point to the same qualified commit. Installed projects never consume moving `main`. The immutable `r8` and `r9` releases remain published for provenance: `r8` was superseded by `r9` after the Claude first-update idempotence defect, and `r9` was superseded by `r10` after the inherited full-remove runtime defect was found during the real `r7` migration.

## Intake discipline

Before an intake, resolve `git ls-remote upstream refs/heads/main`. If it differs from the audited SHA, stop and repeat the audit. Create the upgrade branch directly from the full upstream commit; do not merge or rebase the previous downstream release.

Maintain a `keep/drop/rewrite` ledger. For the b4d9875b intake the retained categories are immutable release/installer protocol 1.1, manifest ownership and rollback, delegated MCP, metadata safety, and the compact router. Upstream-native verification/development/project-memory/`LLM-RULES.md`/economy/lite/CAVEMAN/metadata features are kept. Superseded layout patches and the old CAVEMAN category override are dropped. Single-client installation, ITL preflight, command allowlist, verification modes, legacy bridges, economy integration, `/doctor`, and `/evolve` are rewritten as thin overlays.

Run the fork Full gate, preview publication with `publish-fork-release.ps1 -WhatIf`, then publish exactly one immutable branch/tag. Never repoint a release tag.

## Single-client migration

Each project has exactly one of `codex`, `kilocode`, `claude-code`, `cursor`, or `opencode`. New initialization requires the choice. Legacy `["codex","kilocode"]` normalizes to `["kilocode"]`; every other multi-client set requires an explicit selection.

`update-workflow` supports legacy upstream-to-fork and strictly monotonic controlled-fork upgrades, including `r7 -> r10`. Eligibility requires recorded installed commit/provenance, an immutable `itl-*` ref, no `userModified` managed files, supported client state, and upstream ancestry. A custom repository, missing provenance, tracked-config ambiguity, or modified managed file produces a recovery report instead of mutation.

The candidate is installed into a temporary project first. The transactional snapshot includes project/lock/manifest, `.dev.env`, `AGENTS.md`, `USER-RULES.md`, `LLM-RULES.md`, OpenSpec, `.agents`, all client directories, and local MCP configs. Failure restores the snapshot and reports recovery evidence. Repeating the update must be byte-idempotent.

Active `itldev/*` worktrees are never advanced automatically; update clean `master`, review/commit it, then use `/itl-refresh` per branch. Legacy user-global Codex prompts and RTK hooks are reported/preserved because they are outside project ownership.
