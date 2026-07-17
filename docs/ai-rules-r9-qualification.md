# ai_rules_1c r9 qualification

> Superseded by `itl-main-b4d9875b-r10`. The immutable r9 installer inherited
> an upstream runtime failure in the full `remove` path; keep this document only
> as release provenance.

- Fork repo: `https://github.com/xmentosx/itl_ai_rules_1c.git`
- Release branch/tag: `release/itl-main-b4d9875b-r9` / `itl-main-b4d9875b-r9`
- Fork commit: `c68824bca003cf84594e3dc8640f83a608607464`
- Upstream: `https://github.com/comol/ai_rules_1c.git`, `refs/heads/main@b4d9875b15c6d93f493035aee51f077126e72a21`
- Downstream revision: `9`
- Compatibility: `passed`

Qualification evidence:

- controlled-fork Full: 50 passed after the Claude manifest-idempotence hotfix;
- five-client `init -> update -> doctor` compatibility passed for Codex, Kilo, Claude, Cursor, and OpenCode;
- first update is byte-idempotent and does not create false `userModified` entries;
- `-WhatIf` publication and atomic publication matched the release branch/tag provenance;
- remote release branch and annotated tag dereference to the same qualified commit;
- workflow Full and Release evidence are produced by the workflow quality gates.
