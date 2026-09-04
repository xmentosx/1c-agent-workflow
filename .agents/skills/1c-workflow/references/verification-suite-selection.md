# Branch-local verification suite selection

Read this file whenever refresh reports `classify-tests-after-refresh`, whenever
creating or changing Vanessa/YAxUnit tests, or when diagnosing why an ordinary
check selected a particular suite. Classification is part of the same agent
task that introduced or discovered the tests; it is not deferred to the user.

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
state under `.agent-1c/verification-selection/inventory.json`. This deterministic
file and catalog analysis does not run Vanessa or infer semantics. If tests exist
and a catalog is absent, invalid, ambiguous, missing owners, or leaves a feature
unclassified, refresh succeeds with `requiredAction=classify-tests-after-refresh`.
The agent must read the inventory, update the branch catalogs, and validate the
assignments in the same task with the compact helper action
`validate-test-classification`, which never starts 1C, before reporting refresh
complete. A normal
`/itl-check` enforces the same contract before starting Designer or Enterprise.
An unknown changed verification-relevant product path is also a classification
error, not permission to run everything.

The first check with a complete catalog or unavailable proof selects the complete
acceptance set once. After that set passes, the ignored proof matrix
lets a later check run only acceptance suites owned by changed paths and carries
the unchanged suite proof to the new exact Git tree. If every changed path
belongs only to `explicit` suites, the helper carries the acceptance proof after
the event-log check and does not start Vanessa. A failed run never advances the
matrix. A new or changed suite has its own semantic fingerprint, so it remains
the only selected suite on every failed fix-and-retry iteration instead of
restarting the previously proved acceptance set.

Changes outside the verification fingerprint do not force Vanessa. YAxUnit-only
changes are handled by the YAxUnit contour and do not select Vanessa. A shared
Vanessa library or pinned verification runtime change still requires the complete
acceptance set because it can affect every suite.

The selector copies only chosen application feature files plus the complete
`Libraries` directory into the run directory; tracked sources are not edited.
Diagnostic `VanessaFeaturePath` or tag-filter runs are separate evidence and do
not erase or replace the last complete acceptance proof.

## YAxUnit catalog

When `tests/yaxunit` contains exported test `Module.bsl` files, commit
`tests/yaxunit-suites.branch.json` (or the genuinely shared variant). Every
test module must match exactly one group and every group must identify its
production owners. Declare ordinary registration infrastructure separately in
`registrationPaths`; it is not a test group:

```json
{
  "schemaVersion": 1,
  "registrationPaths": [
    "tests/yaxunit/CommonModules/ИсполняемыеСценарии/Ext/Module.bsl"
  ],
  "groups": [
    {
      "id": "plan-calculation",
      "purpose": "default-fast",
      "modulePaths": ["tests/yaxunit/CommonModules/ТестыРасчетаПлана*/Ext/Module.bsl"],
      "ownerPaths": ["src/cf/CommonModules/РасчетПлана/**"]
    },
    {
      "id": "plan-calculation-benchmark",
      "purpose": "explicit-benchmark",
      "modulePaths": ["tests/yaxunit/CommonModules/БенчмаркРасчетаПлана*/Ext/Module.bsl"],
      "ownerPaths": ["src/cf/CommonModules/РасчетПлана/**"]
    }
  ]
}
```

`default-fast` groups remain registered in the exported
`ИсполняемыеСценарии` and run together in one ordinary YAxUnit session.
`explicit-benchmark` modules must be separate common modules and must not be
referenced by any `registrationPaths`; they run only through an explicit project
benchmark harness. Adding or renaming a module without updating this catalog
blocks the normal check before 1C starts.
