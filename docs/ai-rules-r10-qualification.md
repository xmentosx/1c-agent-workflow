# ai_rules_1c r10 qualification

- Fork repo: `https://github.com/xmentosx/itl_ai_rules_1c.git`
- Release branch/tag: `release/itl-main-b4d9875b-r10` / `itl-main-b4d9875b-r10`
- Fork commit: `760aab7fc2ef12d5019749e564803bbd4d6b1f5a`
- Upstream: `https://github.com/comol/ai_rules_1c.git`, `refs/heads/main@b4d9875b15c6d93f493035aee51f077126e72a21`
- Downstream revision: `10`
- Compatibility: `passed`

Qualification evidence:

- controlled-fork Full: 51 passed, including real full Kilo removal;
- five-client `init -> update -> doctor` compatibility passed for Codex, Kilo, Claude, Cursor, and OpenCode;
- full removal no longer executes the inherited orphan `else` and preserves RTK-owned `.kilocode/rules/rtk-rules.md`;
- `-WhatIf` publication and atomic publication matched the release branch/tag provenance;
- remote release branch and annotated tag dereference to the same qualified commit;
- fresh-clone Full: 51 passed at the exact release commit;
- workflow Full and Release evidence are produced by the workflow quality gates.
