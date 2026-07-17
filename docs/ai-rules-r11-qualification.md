# ai_rules_1c r11 qualification

- Release branch/tag: `release/itl-main-b4d9875b-r11` / `itl-main-b4d9875b-r11`
- Fork commit: `af82570afca06c40a9588c8a678bf3665bba4870`
- Upstream provenance: `refs/heads/main@b4d9875b15c6d93f493035aee51f077126e72a21`
- Downstream revision: `11`

## Qualified change

`r11` preserves the qualified `r10` downstream delta and replaces the always-loaded root `AGENTS.md` with the canonical compact contract from `templates/ai-rules-overlay/AGENTS.md`. The compact file is 8,874 characters, below the 20,000-character budget, while retaining rule precedence, routing, MCP activation conditions, and the mandatory 1C completion invariant: relevant Vanessa coverage, database update, and a fresh successful `/itl-check`.

The release was reconstructed by `scripts/build-ai-rules-release.ps1` directly from the full upstream commit. The builder produced the keep/drop/rewrite ledger and review diff, rejected drift fail-closed, and passed byte-idempotence on repeat. Fork `main` remained the clean upstream snapshot.

## Evidence

- Fork Full gate: 51/51 passed on the clean release tree.
- Compatibility bootstrap: passed for `codex`, `kilocode`, `claude-code`, `cursor`, and `opencode`.
- Immutable branch and annotated tag were pushed and resolve to the qualified commit.
- Overlay Pester coverage includes repeat application, added upstream sections, changed downstream-owned paths, and fail-closed behavior.

After this qualification the workflow lock may advance to `itl-main-b4d9875b-r11`. Older immutable tags remain historical provenance and are never moved.
