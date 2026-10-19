# Product/project registry: G2

Source-owned foundation only. It does not associate installed projects, update
client settings, fetch a registry or call Cognee. G3 owns those integrations.

`schemas/` contains version-1 JSON Schema contracts. The PowerShell 5.1 validator
evaluates the vocabulary used by these package-owned files: local definitions,
type, properties/required/additionalProperties, enum, pattern/minLength,
items/minItems/uniqueItems and minimum. Reference integrity, cycles, role matching,
canonical home and Mantis subsets/routes are checked by the same catalog owner.
Unknown optional metadata survives reading; it is not a new policy language.
Catalog IDs are lowercase stable business identifiers. Rename changes `name`.

`pilot/` is a prepared, **unpublished** minimal catalog. The user confirmed the
PM5 CORP product and its typical development project on 2026-10-19. Integrations
are deferred: the discovery inventory does not by itself approve all external
project routes or prove current source bindings. No knowledge areas/homes are
invented. An empty map is valid; it does not mean universal applicability.

## Calling the foundation

Within the existing ITL helper session, call the explicit owner entrypoint:

```powershell
Read-Vibecoding1cProductContext -RepositoryRoot $registryCheckout `
    -Commit $approvedCommit -ProjectId 'pm5-core-development'
```

It loads the owner-local `agent-1c.product-catalog.ps1` on demand. It reads
`registry.json`, `catalog/catalog.json`, and `catalog/product-relations.json`
from one resolved commit, independently of worktree changes and later tips.
`inputGitObjectIds` are Git blob hashes of the original committed bytes; parsing
JSON does not change that identity. Unsupported/incomplete snapshots fail before
any local apply. Legacy endpoint-only readers remain unchanged.

The result carries selected IDs, role/source references and provenance, external
links, catalog revision, knowledge constraints/read candidates, and separate
settings/knowledge SHA-256 hashes. Role resolution means a validated reference,
**not live readiness**. Canonical JSON sorts object keys ordinally; the selected
projection excludes publication timestamps and unrelated projects. Full catalogs
are never added to always-on agent instructions.

`Resolve-ItlProductKnowledge` accepts an original with `origin.source/revision`,
`evidence[]` (`source/revision/result`) and `applicability.knowledgeAreas`,
`verificationState=verified`. Optional constraints: `productIds`, `requiresProducts`,
`conditions`, `versionRange`, `independentOfCustomization`. Missing/unknown proof
or unsupported applicability fields gives `needs-review`; failed constraints give
`not-applicable`. The resolver returns the original origin/evidence unchanged.
Versions and condition values used by the selected context enter its knowledge
hash. `derivedFrom` never makes a note applicable. Ambiguous/missing homes do not
assign a write destination. Dataset scope and grants remain a future consumer's
responsibility; read candidates grant no access.

## Endpoint publication

The existing host publisher owns only `registry.json`. It preserves catalog files
and commits only that path. Foreign tracked changes (staged or unstaged) stop
before publication with an actionable continuation; they are never auto-stashed
or discarded. Untracked files are not added. Retry keeps the same owner and
rebases normally; no force push, second writer or catalog migration is introduced.

The versioned schemas/pilot files are source inputs, not a published catalog.
Do not copy source-only AGENTS/OpenSpec into installed projects. Deployment,
client support canary, native bindings, installed migration and memory G4/G5
remain separate work.
