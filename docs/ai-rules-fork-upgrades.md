# Controlled ai_rules_1c upgrades

## Current qualified release

The workflow is pinned to `itl-main-72665287-r12` at fork commit `16e9e44318a79d9e82c12b19e6759cdf6492d9a4`. Its exact upstream provenance is `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`. `templates/dependency-lock.json` is the single source of this tag, commit, upstream provenance, downstream revision `12`, and `compatibilityStatus=passed`; project templates, code, docs, and tests must agree with it.

Fork `main` is the clean upstream snapshot. Downstream changes exist only on immutable branch/tag `release/itl-main-72665287-r12` / `itl-main-72665287-r12`, which point to the same qualified commit. Installed projects never consume moving `main`. Older immutable releases remain published only for provenance; `r12` adds all five upstream clients while retaining the r11 compact root contract and reproducible overlay builder.

## Intake discipline

Before an intake, resolve `git ls-remote upstream refs/heads/main`. If it differs from the audited SHA, stop and repeat the audit. Create the upgrade branch directly from the full upstream commit; do not merge or rebase the previous downstream release.

Use `scripts/build-ai-rules-release.ps1` as the only normal downstream reconstruction path. `templates/ai-rules-overlay/sections.json` pins the audited upstream sections, required anchors, qualified baseline release, and keep/drop/rewrite ownership; `templates/ai-rules-overlay/AGENTS.md` is the canonical compact root contract. The builder must run in a clean checkout whose branch is based directly on the requested full upstream commit. It refuses merge commits, unrelated committed or dirty changes, an added/changed/removed upstream section, a missing anchor, or upstream drift in any path touched by the downstream patch. It writes a section ledger and review diff, applies the overlay, and verifies byte-idempotence on repeat.

For a new upstream commit, create a new release branch from that commit, update only the classifications and hashes affected by the audit, and rebuild. Never carry the previous release branch forward. If upstream did not change, increment the downstream revision while retaining the upstream short SHA in the immutable tag.

Maintain a `keep/drop/rewrite` ledger. For the 72665287 intake the retained categories are immutable release/installer protocol 1.1, manifest ownership and rollback, delegated MCP, metadata safety, and the compact router. Upstream-native verification/development/project-memory/`LLM-RULES.md`/economy/lite/CAVEMAN/metadata features are kept. Superseded layout patches and the old CAVEMAN category override are dropped. Single-client installation, ITL preflight, command allowlist, verification modes, legacy bridges, economy integration, `/doctor`, and `/evolve` are rewritten as thin overlays.

Run the fork Full gate, preview publication with `publish-fork-release.ps1 -WhatIf`, then publish exactly one immutable branch/tag. Never repoint a release tag.

## Single-client migration

Each project has exactly one of `codex`, `kilocode`, `claude-code`, `cursor`, `opencode`, `kimi`, `qwen`, `command-code`, `cline`, or `pi`. New initialization requires the choice. Legacy `["codex","kilocode"]` normalizes to `["kilocode"]`; every other multi-client set requires an explicit selection. Generic `other` is not supported.

`update-workflow` supports legacy upstream-to-fork and strictly monotonic controlled-fork upgrades, including `r11 -> r12`. Eligibility requires recorded installed commit/provenance, an immutable `itl-*` ref, no `userModified` managed files, supported client state, and upstream ancestry. A custom repository, missing provenance, tracked-config ambiguity, or modified managed file produces a recovery report instead of mutation.

The candidate is installed into a temporary project first. The transactional snapshot includes project/lock/manifest, `.dev.env`, `AGENTS.md`, `USER-RULES.md`, `LLM-RULES.md`, OpenSpec, `.agents`, all client directories, and local MCP configs. Failure restores the snapshot and reports recovery evidence. Repeating the update must be byte-idempotent.

Active `itldev/*` worktrees are never advanced automatically; update clean `master`, review/commit it, then use `/itl-refresh` per branch. Legacy user-global Codex prompts and RTK hooks are reported/preserved because they are outside project ownership.
