# ai_rules_1c r23 develop publication

The controlled fork release `itl-main-410951e7-r23` retains audited upstream
`410951e74fd3e6b7a763cf49757935b9a34d3f31` and is published at fork commit
`609976be8fefdf1c0168c36ee92f4d985cfd2b09`.

Repeated `form-add` and `add-template` calls now update explicitly requested
metadata while keeping one child registration and preserving authored form,
module, and template bytes. Incompatible existing metadata remains a hard
failure.

Recorded fork evidence: schema-3 verification for all 121 path decisions,
focused release-tooling tests 7/7, fork Full 72/72, publication preview, and an
atomic immutable branch/tag publication. The workflow lock starts with
`compatibilityStatus=pending`; promotion to `passed` requires a separate exact
workflow Full qualification against the local r23 checkout.
