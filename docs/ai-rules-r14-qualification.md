# ai_rules_1c r14 qualification

- Release branch/tag: `release/itl-main-72665287-r14` / `itl-main-72665287-r14`
- Fork commit: `0888fcdaf223abf97cfba7450bf38454926ad384`
- Upstream provenance: `refs/heads/main@72665287e77361aea3aaf866fef163d98f0fabcd`
- Downstream revision: `14`
- Previous logical release: `itl-main-72665287-r13`
- Scope: policy-only clarification of mandatory `1c-form-edit` routing for supported structural changes to an existing `Form.xml`

The release does not change `verify_xml`, `1c-form-edit`, `1c-form-validate`,
lifecycle loading, Designer/`ibcmd` selection, or partial/full configuration
fallback behavior. It preserves the r13 runtime and tool implementation.

## Targeted evidence

- Fork policy contract (`tests/R8Policy.Tests.ps1`): 7 passed, 0 failed.
- Ten-client installation contract (the focused
  `LayoutAndManifest.Tests.ps1` case): 1 passed, 0 failed; the case installs
  every supported client and verifies that its installed
  `1c-metadata-manage/SKILL.md` contains the mandatory route.
- Workflow overlay, migration, and dependency-lock contracts
  (`AiRulesOverlay.Tests.ps1`, `AiRulesMigration.Tests.ps1`,
  `DependencyLocks.Tests.ps1`): 20 passed, 0 failed.
- Focused natural-client fixture
  (`ClientAdaptersAndModes.Tests.ps1`): 1 passed, 0 failed.
- Canonical overlay reconstruction:
  `scripts/build-ai-rules-release.ps1 -CheckOnly` passed against the exact fork
  release commit.

Per the maintainer's explicit policy-only release scope, the fork Full gate and
the workflow Fast, Full, and Release gates were not run. The fork publication
helper was therefore not invoked because it requires a Full qualification.
Its immutable publication steps were performed directly: an annotated tag and
release branch were created and pushed atomically, then the remote branch and
peeled tag were verified at the exact fork commit.

The r14 candidate, like r13, is reconstructed directly from the audited
upstream snapshot. Therefore r13 is the previous logical release rather than a
Git ancestor. The selected upstream snapshot remains reachable from the live
upstream `main` tip `5ae333ed49dc66989e305b286acc93691bb96926`;
intake of that newer upstream delta is intentionally deferred to a separate
upgrade.
