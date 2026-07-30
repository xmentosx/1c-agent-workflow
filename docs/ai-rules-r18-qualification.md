# ai_rules_1c r18 qualification

- Release branch/tag: `release/itl-main-5ae333ed-r18` / `itl-main-5ae333ed-r18`
- Fork commit: `841b30af5d87eb212f497754f1328b38146cb279`
- Upstream provenance: `refs/heads/main@5ae333ed49dc66989e305b286acc93691bb96926`
- Scope: accept the audited upstream intake while preserving executable ITL lifecycle, form-edit, installer, migration, and ownership safeguards

Fork evidence:

- the schema-2 verifier accounted for all 51 upstream-changed paths and 93 downstream-only paths;
- targeted builder, guard, anchors, forms, Claude migration, OpenCode permission, command materialization, and doctor contracts: 56 passed;
- Full fork gate on the clean release tree: 76 passed;
- publication preview passed before the immutable branch and annotated tag were pushed;
- the remote branch and tag resolve to the qualified release commit.

Workflow qualification:

- dependency lock, project template, migration matrix, client-mode fixtures, and fork-upgrade documentation point to the exact immutable r18 release;
- `AiRulesOverlay.Tests.ps1` verifies Prepare/Verify behavior, path accounting, missing decisions, and result-hash drift;
- `AiRulesMigration.Tests.ps1` includes r17-to-r18 coverage for every supported single-client installation;
- the final workflow tree must pass the targeted migration/client/bootstrap suite, one Fast gate, and one Full gate with `-AiRulesSource` set to the clean r18 checkout.

No workflow Release gate or installed-project live smoke is part of this qualification. Installed projects remain unchanged until their normal `update-workflow`.
