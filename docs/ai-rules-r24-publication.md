# ai_rules_1c r24 develop publication

The controlled fork release `itl-main-410951e7-r24` retains audited upstream
`410951e74fd3e6b7a763cf49757935b9a34d3f31` and is published at fork commit
`83e179469363c16497d9cc389a9a814537cc076b`.

Managed strict UTF-8 text now treats a checkout-only LF/CRLF conversion as
content-equivalent and clears stale `userModified` markers left by older
installers. Invalid UTF-8 and binary-looking content remains byte-strict.
Update also prunes obsolete clean entries owned by `legacy` outside the old
hard-coded client layouts while preserving genuine edits.

Recorded fork evidence: schema-3 verification for all 122 path decisions,
focused installer tests 25/25, fork Full 73/73, publication preview, and an
atomic immutable branch/tag publication. The workflow lock starts with
`compatibilityStatus=pending`; promotion to `passed` requires a separate exact
workflow Full qualification against the immutable r24 tag checkout.
