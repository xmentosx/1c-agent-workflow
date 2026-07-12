# ai_rules_1c r2 ITL qualification

## Immutable dependency

- Repository: `https://github.com/xmentosx/itl_ai_rules_1c.git`
- Tag: `itl-main-a421cf44-r2`
- Fork commit: `bcb662c1eb682c1eae94cef8ad56cec0983f41d5`
- Annotated tag object: `f53d3b9a0731eb03166a2de33c0c155e032ab4c7`
- Upstream ref: `refs/heads/main`
- Upstream commit: `a421cf44eb1f5859cf2a2b74884f8fbcaefc4826`
- Downstream revision: `2`

## Qualification results

- [x] Fork Full gate: 26/26 from the immutable tag in a fresh clone.
- [x] Kilo Code 7.4.5 runtime smoke after `/reload`.
- [x] ITL compatibility smoke: protocol 1.1, shared owners, one repo skill copy, no `.kilocode`, global prompts unchanged, rendered `AGENTS.md` below 32 KiB.
- [x] Real disposable controlled-fork migration `r1 → r2`: snapshot created, manifest upgraded to 1.1, Codex added, `.kilocode` removed, ITL skills preserved, exact r2 lock written, global prompts unchanged.
- [x] Migration rollback unit test restores config, lock, manifest, `.agents`, `.codex`, `.kilo`, and `.kilocode` scope after failure.
- [x] ITL Full gate with local controlled fork checkout: 197/197 tests, fork Full and compatibility stages passed.
- [ ] ITL Release gate on `D:\Git\itl-workflow-e2e-pm5` with 194+ Pester tests, fresh passed `/itl-check`, CF export, matching SHA, and cleanup.

The published tag is immutable. Any defect after qualification is released as `r3`; rollback in ITL is a new commit returning the template pin to `r1`.
