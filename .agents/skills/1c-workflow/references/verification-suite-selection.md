# Branch-local verification suite selection

Read this file only when classifying branch tests or diagnosing why an ordinary
check selected a particular Vanessa suite.

Tests normally belong to the development branch. A branch may therefore commit
`tests/verification-suites.branch.json`; it must not wait for a catalog to
appear in `master`. A project that really has shared acceptance tests may also
commit `tests/verification-suites.shared.json`. The catalogs are additive, and
suite ids must be unique across them.

Schema 1 classifies feature files and the product paths that own their result:

```json
{
  "schemaVersion": 1,
  "suites": [
    {
      "id": "orders",
      "purpose": "acceptance",
      "always": false,
      "featurePaths": ["tests/features/Orders*.feature"],
      "ownerPaths": ["src/cf/Orders/**"]
    },
    {
      "id": "profiling",
      "purpose": "explicit",
      "featurePaths": ["tests/features/Profiling*.feature"],
      "ownerPaths": ["tools/profiling/**"]
    }
  ]
}
```

`purpose=acceptance` participates in ordinary `/itl-check` runs.
`purpose=explicit` is for profiling, an external instrument, or another test
started deliberately and excluded from normal acceptance. Reserve `always=true`
for a genuinely cheap invariant, not as a substitute for owner classification.

After refresh, the helper inventories current branch files into ignored local
state under `.agent-1c/verification-selection/`. This deterministic file and
catalog analysis does not run Vanessa or infer semantics. The first check, a
changed catalog, an unclassified or ambiguously classified feature, an unknown
changed product path, invalid JSON, an empty suite, or unavailable proof selects
the complete acceptance set. After that set passes, the ignored proof matrix
lets a later check run only acceptance suites owned by changed paths and carries
the unchanged suite proof to the new exact Git tree. If every changed path
belongs only to `explicit` suites, the helper carries the acceptance proof after
the event-log check and does not start Vanessa. A failed run never advances the
matrix. A new or changed suite has its own semantic fingerprint, so it remains
the only selected suite on every failed fix-and-retry iteration instead of
restarting the previously proved acceptance set.

The selector copies only chosen application feature files plus the complete
`Libraries` directory into the run directory; tracked sources are not edited.
Without a catalog, legacy behavior remains unchanged and every feature runs.
Diagnostic `VanessaFeaturePath` or tag-filter runs are separate evidence and do
not erase or replace the last complete acceptance proof.
