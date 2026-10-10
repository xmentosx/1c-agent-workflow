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

Schema 1 classifies separately selectable feature files and the product paths
that own their result:

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

Schema 2 separates the behavior to prove from the decision to retain a test.
An obligation identifies its expected result, affected inputs, admissible proof,
retention decision, and cadence. A retained suite or YAxUnit group binds to one
obligation by `suiteId` or `groupId`; a one-off obligation has no retained test.
Schema 1 remains readable and maps existing acceptance/default-fast entries to
`affected` and existing explicit entries to `explicit`, without deleting tests.

```json
{
  "schemaVersion": 2,
  "suites": [
    { "id": "orders", "purpose": "acceptance", "featurePaths": ["tests/features/Orders.feature"], "ownerPaths": ["src/cf/Orders/**"] }
  ],
  "obligations": [
    { "id": "orders-result", "expectedResult": "Order total is correct", "inputPaths": ["src/cf/Orders/**"], "admissibleProof": ["vanessa-junit"], "retention": "retained", "retentionReason": "Recurring business rule", "cadence": "affected", "suiteId": "orders" }
  ]
}
```

One-off obligations remain classified without a suite. Their proof is a separate
readiness condition: missing or stale evidence blocks a fresh passed result,
but it does not prevent retained Vanessa/YAxUnit tests from running. Run the
ordinary unfiltered check first so the current source is loaded and retained
tests and event log are assessed. It may finish with partial readiness while
the one-off receipt is pending. For a named observed run, start the compact
helper with `-Action begin-one-off-proof
-DevBranchName <name> -VerificationObligationId <id>`. Record the returned
`runToken`, actually execute the declared check, retain a result artifact, and
write a UTF-8 JSON evidence file inside the project:

```json
{
  "obligationId": "orders-observed",
  "runToken": "<token from begin>",
  "expectedResult": "Order total is correct",
  "status": "passed",
  "proofType": "runtime-observation",
  "actualResult": "Observed total: 42",
  "providerId": "named UI client or data provider",
  "runnerVersion": "exact version",
  "steps": [{ "action": "Recalculate this order", "actual": "Total displayed as 42" }],
  "artifactPaths": [".agent-1c/runs/<run>/observed-result.json"],
  "limitations": "",
  "invocationProvenance": { "trigger": "named user request" }
}
```

Complete with `-Action complete-one-off-proof -DevBranchName <name>
-VerificationEvidencePath <path>`. The helper checks the run token, declared
expectation, exact checked inputs, loaded test infobase, allowed proof method,
observed steps, and artifact hashes before writing a passed receipt. A later
change to any of those dependent inputs makes the proof stale; an unrelated
commit does not. Starting again reuses fresh proof unless `-Force` explicitly
requests a new observed run. The existing check proof and this receipt are
assessed together by status, export, and close; they do not require rerunning
unchanged UI tests. If the source or loaded base changes, repeat the ordinary
check and the affected one-off run.
Current one-off proof can establish complete readiness without a retained suite:
the same read-only assessor requires exact source/load readiness, current
event-log evidence and every applicable obligation. Retained `affected` and
`handoff` suites keep their purpose and need observed unfiltered JUnit receipts
bound to declared inputs, expected result, runner/checker identity and artifact
SHA. A partial named run does not replace missing obligations.
Retained proof binds the exact branch/base and runner generations, while full
loaded source identity remains its original provenance. Separate current
source/load readiness and the suite's declared inputs decide applicability:
an unrelated source change followed by a valid load preserves unaffected
coverage. Unknown target/generation/auxiliary connection is never reused.
Each selected suite also needs observed native scenario identities in its
hashed JUnit. A matching whole-run count cannot fill a missing suite; missing,
duplicate or ambiguous cases remain partial. Preserve the reports and use the
existing runner/report owner to resolve the missing identity, then repeat the
original check. The assessor neither launches a runner nor changes a test.
With execution
off, the ordinary check assesses those receipts and starts no forbidden runner;
status, export and close use that same result. Old proof with unknown receipt
identity stays unverified until the existing permitted check supplies it.
Cleanup preserves artifacts referenced by current component and retained-suite
receipts as well as one-off proof.
Do not change a functional test's purpose to `explicit` to make a pending
missing handoff proof disappear.

The file boundary is an execution boundary, not a place to accumulate every
scenario for a subsystem. One acceptance suite may contain at most eight flat
scenarios across all of its matched files. Its files must describe one coherent
behavior, cadence, and narrow owner set. Diagnostic and A/B tags (`@diag_*`,
`@ab_*`) and tags containing `profiling`, `benchmark`, or `measurement` are
explicit cadence and cannot remain in an acceptance file. New work must create
or choose the narrow file first; never append a scenario to a convenient large
feature and classify the whole file.

After refresh, the helper inventories current branch files into ignored local
state under `.agent-1c/verification-selection/inventory.json`. This deterministic
file and catalog analysis does not run Vanessa or infer semantics. If tests exist
and a catalog is absent, invalid, ambiguous, missing owners, leaves a feature
unclassified, exceeds the acceptance scope, or mixes ordinary and explicit
cadence, refresh succeeds with `requiredAction=classify-tests-after-refresh`.
The inventory lists every scenario with its file, source line, tags, current
suite, cadence hint, and behavior fingerprint. The agent must read those
scenarios and their production owners, preserve the scenario bodies, split
oversized or mixed files into coherent separately selectable files, update the
branch catalogs, and validate the assignments in the same task with the compact helper action
`run-itl-command.ps1 -- -Action validate-test-classification`, which never starts 1C, before reporting refresh
complete. A normal
`/itl-check` enforces the same contract before starting Designer or Enterprise.
An unknown changed verification-relevant product path owned by this branch is
also a classification error, not permission to run everything.

During delta selection in `itldev/*`, the helper pins the branch HEAD and local
master tip, resolves their unique common ancestor, and compares changed CF/CFE
paths with that accepted commit in the effective tree. Matching imported paths
select the full existing acceptance set without inventing tests or ownerPaths
for master input. The current master tip may be ahead of the accepted ancestor.
Configured extension roots, deletions and rename pairs participate; modified
imported files are branch-owned. Missing or ambiguous ancestry and Git failures
grant no imported-input exception. The temporary tree preserves the user's index.

The selector evaluates the complete changed-path list before applying these
full-suite reasons: an imported path, shared Vanessa support or runtime update
cannot conceal another unowned branch change. Catalog validity and YAxUnit
classification remain prerequisites; explicit profiling suites remain excluded.
The plan and completed proof record `acceptedMasterInput` with the reference,
pinned tips, accepted commit, imported paths and branch paths. Existing acceptance
coverage establishes tested compatibility, not exhaustive business correctness
or newly authored coverage for master changes.

The first check with a complete catalog or unavailable proof selects the complete
acceptance set once. After that set passes, the ignored proof matrix
lets a later check run only acceptance suites owned by changed paths and carries
the unchanged suite proof to the new exact Git tree. If every changed path
belongs only to `explicit` suites, the helper carries the acceptance proof after
the event-log check and does not start Vanessa. A failed run never advances the
matrix. A new or changed suite has its own semantic fingerprint, so it remains
the only selected suite on every failed fix-and-retry iteration instead of
restarting the previously proved acceptance set.

When an old proof predates workflow adoption, an unowned CF/CFE path whose
current content exactly matches the legacy adoption baseline (including an old
deletion or recorded dirty source OID) selects the complete existing acceptance
set without demanding a new suite owner. A later branch-owned change to that
path still requires classification. Test feature and catalog classification is
unchanged.

Changes outside the verification fingerprint do not force Vanessa. YAxUnit-only
test changes are handled by the YAxUnit contour and do not select Vanessa. When
ordinary YAxUnit execution is planned, a changed production path owned by a
`default-fast` YAxUnit group also reuses Vanessa proof unless a Vanessa suite
owns the same path. Disabling or skipping YAxUnit disables that exemption. A shared
Vanessa library or pinned verification runtime change still requires the complete
acceptance set because it can affect every suite.

Refresh records an ignored post-merge scenario baseline when splitting is
required. `validate-test-classification` compares the behavior fingerprints
after migration and rejects a lost or rewritten scenario. Moving an intact
scenario and adding or changing cadence tags is allowed; changing its name,
steps, or examples is separate development work, not classification.

The selector copies only chosen application feature files plus the complete
`Libraries` directory into the run directory; tracked sources are not edited.
Diagnostic `VanessaFeaturePath` or tag-filter runs are separate evidence and do
not erase or replace the last complete acceptance proof.

## YAxUnit catalog

The workflow records an exact Git commit when a development branch first adopts
this applicability rule, including when its first action is `/itl-check` rather
than refresh. A branch that existed before the update keeps all BSL at that
commit as a legacy baseline. Dirty CF/CFE source present at first adoption is preserved
by exact source OID until it changes again. Missing YAxUnit tests for this
pre-adoption content do not become mandatory, and refresh remains usable. The
inventory marks `legacyBaseline=true`.
Only later branch-owned BSL changes under the configured CF/CFE roots need an
applicability decision. Accepted unchanged master input is excluded. A deleted
module needs no new decision. Resetting a branch for a new task starts a fresh
baseline at its reset HEAD.

For each later changed production BSL, the agent first inspects the decision
points and searches existing YAxUnit and Vanessa coverage. Reuse or strengthen
a sufficient `default-fast` group; add one focused group only for a contract
that has no adequate coverage. If unit testing is genuinely inapplicable (for
example the changed behavior requires a real form or session), put an exact
`notApplicable` entry in the branch catalog with the current source blob OID
printed by the inventory and a concrete reason. Example:

```json
{
  "schemaVersion": 1,
  "notApplicable": [
    {
      "path": "src/cf/CommonModules/SessionCommand/Ext/Module.bsl",
      "sourceOid": "0123456789abcdef0123456789abcdef01234567",
      "reason": "Only the interactive form command changes; the existing Vanessa scenario checks it."
    }
  ]
}
```

The OID binds the decision to the exact BSL content and must be reconsidered
when that content changes. It is not a waiver for an algorithm that can be
tested locally. The agent owns this classification and runs
`validate-test-classification` before the final check; it does not ask the user
to author a catalog or choose a test framework. Catalog decisions do not create
new test processes or per-file reports. The normal check still runs all fast
YAxUnit groups in one session and keeps its final unfiltered verification.

When `tests/yaxunit` contains exported test `Module.bsl` files, commit
`tests/yaxunit-suites.branch.json` (or the genuinely shared variant). Every
test module must match exactly one group and every group must identify its
production owners. Declare a separate ordinary registration module, when one
exists, in `registrationPaths`; it is not a test group. Leave the list empty
when test modules register themselves through exported `ИсполняемыеСценарии`:

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

`default-fast` groups must either be referenced by ordinary registration or
provide their own exported `ИсполняемыеСценарии` in a discoverable common
module. The latter needs a runnable client or server context and must not set
`ServerCall=true`. All fast groups run together in one ordinary YAxUnit session.
`explicit-benchmark` modules must be separate common modules and must not be
referenced by any `registrationPaths` or export their own
`ИсполняемыеСценарии`; they run only through an explicit project benchmark
harness. Adding or renaming a module without updating this catalog blocks the
normal check before 1C starts.

The classification helper returns a complete `userReport` combining the same
refresh's saved load/Enterprise facts with completed classification. Return it
verbatim; retain the original refresh status/report unchanged as history. Saved
report context lives in the existing ignored verification-selection directory,
is bound to worktree, branch, infobase and refresh identity, and is not verification
evidence. Missing, stale or unreadable context only warns: return the original
refresh report verbatim followed by the standalone classification report. Never
repeat a successful refresh to reconstruct reporting. Classification does not
prove BSL validators or replace a fresh `/itl-check`.
