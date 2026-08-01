# Controlled ai_rules_1c upgrades

## Current develop candidate

The `develop` workflow is pinned to `itl-main-410951e7-r22` at fork commit `bcd94d1723f26a0b0568869845484c8572c402a6`. Its exact upstream provenance is `refs/heads/main@410951e74fd3e6b7a763cf49757935b9a34d3f31`. `templates/dependency-lock.json` is the single source of this tag, commit, upstream provenance, downstream revision `22`, and compatibility state; project templates, code, docs, and tests must agree with it. Compatibility remains `pending` on `develop` until a separate evidence-backed promotion records `passed`.

Fork `main` mirrors upstream and is never consumed by installed projects. Downstream changes exist only on immutable release branches/tags; the current pair is `release/itl-main-410951e7-r22` / `itl-main-410951e7-r22`, which point to the same release commit. Older immutable releases remain published only for provenance. `r22` keeps the r21 baseline, separates execution depth from planning mode, and loads the full OpenSpec subagent pipeline only when apply actually delegates implementation.

## Intake discipline

Before an intake, resolve `git ls-remote upstream refs/heads/main`. If it differs from the audited SHA, stop and repeat the audit. Create the upgrade branch directly from the full upstream commit; do not merge or rebase the previous downstream release.

Use `scripts/build-ai-rules-release.ps1` as the only normal downstream reconstruction path. `templates/ai-rules-overlay/sections.json` is a schema-3 path ledger: every upstream or downstream release path has a requirement id, reason, disposition, and exact upstream/baseline/result SHA-256. `take-upstream` accepts the intake, `carry-forward` must remain byte-equivalent to the previous qualified release, `resolved` records a reviewed result, and `downstream-only` records a new path absent from both inputs. `templates/ai-rules-overlay/AGENTS.md` is the canonical compact root contract.

`-Mode Prepare` starts from a clean branch based directly on the exact upstream commit, reconstructs each `carry-forward` path from the baseline release, applies managed templates, and leaves `resolved`/`downstream-only` paths for ordinary Git editing. `-Mode Verify` (also available as the compatible `-CheckOnly` alias) validates the already committed candidate: complete path coverage, all three hashes, disposition semantics, managed template equality, a linear history without merge commits, no unresolved merge, and a clean tree. Git path discovery is NUL-delimited so Cyrillic, spaces, and unusual path characters remain unambiguous.

For a new upstream commit, create a new release branch from that commit, update only the path decisions and hashes affected by the audit, and rebuild. Never carry the previous release branch forward. A `resolved` entry is not a custom patch language: Git stores the reviewed merge result and the ledger only verifies its hash. If upstream did not change, increment the downstream revision while retaining the upstream short SHA in the immutable tag.

Run the fork Full gate, preview publication with `publish-fork-release.ps1 -WhatIf`, then publish exactly one immutable branch/tag. Never repoint a release tag.

## Single-client migration

Each project has exactly one of `codex`, `kilocode`, `claude-code`, `cursor`, `opencode`, `kimi`, `qwen`, `command-code`, `cline`, or `pi`. Interactive initialization offers `kilocode` first as the recommended default when the answer is left blank; configured/JSON initialization still requires an exact client value. Legacy `["codex","kilocode"]` normalizes to `["kilocode"]`; every other multi-client set requires an explicit selection. Generic `other` is not supported.

`update-workflow` supports legacy upstream-to-fork and strictly monotonic controlled-fork upgrades, including `r11` through `r21` to `r22` for every supported single-client installation. Eligibility requires recorded installed commit/provenance, an immutable `itl-*` ref, no `userModified` managed files, supported client state, and upstream ancestry. The workflow clears a stale `USER-RULES.md` marker only when removing the exact ITL-managed marker block reproduces the manifest `installedHash`; content changed outside that block remains protected and is listed in the recovery report. A custom repository is preserved with a recovery report. Other blocked managed migrations make `update-workflow` fail instead of reporting a successful dependency update.

OpenSpec remains an upstream-owned dependency. The host reports `native` only when the manifest owns an intact command/SKILL bundle, `natural` when `bundleSkipped` is intentional and the shared workspace/rules are complete, and `unavailable` otherwise. A damaged native bundle never falls back to natural. The external executable is diagnosed separately; the workflow neither installs it nor runs `openspec update`.

The candidate is installed into a temporary project first. The transactional snapshot includes project/lock/manifest, `.dev.env`, `AGENTS.md`, `USER-RULES.md`, `LLM-RULES.md`, OpenSpec, `.agents`, all client directories, and local MCP configs. Failure restores the snapshot and reports recovery evidence. Repeating the update must be byte-idempotent.

Active `itldev/*` worktrees are never advanced automatically; update clean `master`, review/commit it, then use `/itl-refresh` per branch. Legacy user-global Codex prompts and RTK hooks are reported/preserved because they are outside project ownership.
