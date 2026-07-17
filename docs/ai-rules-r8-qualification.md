# ai_rules_1c r8 superseded release

- Fork repo: `https://github.com/xmentosx/itl_ai_rules_1c.git`
- Release branch/tag: `release/itl-main-b4d9875b-r8` / `itl-main-b4d9875b-r8`
- Fork commit: `f71768eb2f968e1ca8c24f6de3f4406b2007efcd`
- Upstream: `https://github.com/comol/ai_rules_1c.git`, `refs/heads/main@b4d9875b15c6d93f493035aee51f077126e72a21`
- Downstream revision: `8`
- Compatibility: `superseded`

The immutable release remains published, but it is not consumed by the workflow. The workflow's five-client compatibility gate found that the first Claude `update` rebuilt the manifest without the clean adapter entry and incorrectly marked pristine `CLAUDE.md` as `userModified`. The correction is published as `r9`.

Historical evidence before the cross-repository defect was found:

- controlled-fork Fast and Full passed;
- `-WhatIf` provenance matched the published branch/tag;
- remote branch and annotated tag dereference to the qualified fork commit;
- the later workflow compatibility gate superseded this release before it was pinned.
