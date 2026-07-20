# Manual release gate

## One-time dedicated stand setup

1. Create `D:\Git\itl-workflow-e2e-pm5` and copy a safe non-production file
   infobase into the ignored local directory
   `D:\Git\itl-workflow-e2e-pm5\.agent-1c\infobases\source-snapshot`.
2. Initialize the project with the normal ITL wizard, but point
   `SOURCE_INFOBASE_PATH` only at that in-stand snapshot. Never point the
   dedicated stand at an external source or production infobase: even a
   read-only Designer dump can update the file container and its event log.
3. Verify that the original source repository remains clean after init.
4. Create a dedicated `itldev/workflow-release-e2e` worktree and database copy.
5. Add and commit a deterministic fixture change plus its Vanessa scenario.
6. Copy `templates/release-e2e.example.json` to the ignored local file
   `.agent-1c/release-e2e.json` and record the actual worktree path.
7. Run `/itl-check` once manually to prove the stand itself is healthy.

The fixture branch remains dedicated to workflow releases. Reset its disposable
database from the in-stand source snapshot whenever state may have leaked
between runs. Replace that snapshot explicitly when a new baseline is intended;
do not repoint the stand at the original external infobase.

## Each fork/workflow release

From a clean workflow checkout and a clean fork checkout at the annotated
`itl-*` tag, run:

```powershell
.\scripts\check.ps1 -Mode Release `
  -AiRulesSource D:\Git\itl_ai_rules_1c `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Run `Full` once on the clean topic commit before the PR. Qualification v2 records
the exact tests, gate scripts, merged shard JUnit, environment, workflow tree and
fork qualification. A merge commit may reuse it only when the evidence commit is
its ancestor and the tree plus every inventoried SHA remain identical. If no
valid proof exists, `Release` executes and persists the static prefix before E2E,
so a runtime retry does not repeat Pester/fork/compatibility. Cheap preflights
still run every time.

The command runs or exactly reuses the qualified static/fork/compatibility
stages, then makes two sequential generated commits that each change only the
root `src/cf/Configuration.xml` `Comment` in the dedicated E2E branch. The
branch must also contain
`src/cf/Ext/ParentConfigurations.bin`. The runner invokes `/itl-check` with
`ConfigLoadMode=Partial`, requires the preserved list file to contain only
`Configuration.xml`, dumps the resulting branch infobase back to ignored local
state, and compares the `Comment` plus the presence of
`Ext/ParentConfigurations.bin`. This is a real partial-load roundtrip; automatic
full fallback is deliberately disabled for this release assertion.

Vanessa is restricted to the generated four-scenario feature file. The runner
performs exactly three configuration checks: metadata plus four passing tests;
a feature-only commit with one intentional failure and no Designer/Enterprise;
then a second metadata commit plus feature recovery with Designer/Enterprise
and four passing tests. `stoponerror=false` is qualified only when the failed
run still emits all four independent results with exactly one failure/error and
the helper returns a non-zero exit code. Every completed JUnit run must finish
post-processing within 30 seconds.

The same disposable branch infobase then runs the extension lifecycle smoke.
Its scaffold and validation tools are loaded from the exact clean/tagged
`-AiRulesSource` checkout already qualified by the fork and compatibility gates,
not from a potentially stale installed copy in the stand.
The helper creates an Empty extension from `cfe-init.ps1`, adds a data processor
and a report, and invokes `form-add`/`add-template` repeatedly. It requires one
registration of each processor child, preserves authored `Form.xml`,
`Module.bsl`, text-template and data-composition-schema content, and proves
explicit Synonym, default-form and `SetMainSKD` updates. It loads that extension
and opens its real managed form through a one-scenario Vanessa
`TESTMANAGER -> TESTCLIENT` run. It then dumps a non-empty CFE, restores the
pre-smoke `.dt` snapshot, initializes the same extension from that CFE,
revalidates the normalized `src/cfe/<ExtensionName>` dump and child counts, and
restores the database and worktree again. The specialized-tool authored hashes
are captured before the binary roundtrip. The evidence is
recorded in `extension-smoke.json` and the combined release summary.

The check and export use the helper from the clean workflow checkout being
released, not a possibly stale helper copy in the stand. Success also requires
a verification timestamp from the current run,
`Verification fresh passed: True`, a CF/CFE manifest without override, matching
artifact SHA256, and successful Vanessa UI MCP/ROCTUP MCP cleanup. A successful
run leaves the E2E worktree clean at the generated fixture commit.

For an `itl-ondemand-mcp` release, capture the complete paginated `tools/list`
from the pinned real ROCTUP and Vanessa backends, regenerate both catalogs with
`scripts/New-ItlOnDemandCatalog.ps1`, and change each compatibility family
`qualification` from `pending-live-tools-list` to `live-tools-list`. Publish the
Windows amd64 EXE built by `scripts/Build-ItlOnDemandMcp.ps1`, then copy that
exact asset SHA256 into `templates/dependency-lock.json`. A source-extracted
candidate catalog is never release evidence.

The public facade `tools/list` must contain exactly `resolve_tool` and
`call_tool` for each family while the release probe still qualifies every tool
in the complete internal catalog. Prove that `resolve_tool` does not start the
backend and that a resolved exact name plus arguments reaches the intended
backend tool through `call_tool`. Do not replace the gateway count with the
internal ROCTUP/Vanessa catalog count in client-facing evidence.

The Vanessa live gate must also confirm silent VanessaExt readiness, connect
TestClient through the reserved `itl-ondemand` profile, call a TestClient UI
tool, and call an OS-window/screenshot tool. Two simultaneous facade clients
must have distinct manager and TestClient ports; closing one must leave the
other usable. EOF and a shortened idle-timeout probe must both remove the owned
manager/TestClient processes and release both leases. Do not qualify a release
from `connect_test_client` text alone.

Keep `build/test-results/local/check-summary.json` and the nested E2E summary as
release evidence. A failed cleanup, stale Vanessa result, unverified override,
missing `ParentConfigurations.bin`, non-partial load, extra list-file entry,
roundtrip mismatch, missing manifest, hash mismatch, dirty worktree, dynamic
fork branch, aggregated/missing JUnit results, a helper that masks a failed
scenario, non-idempotent form/template registration, failed extension TestClient
form opening, failed extension database restore or unpinned template is a
release failure.

## Resume after interruption

The runner checkpoints `config-cadence`, `config-roundtrip`, `extension-smoke`,
`ondemand-mcp`, verification refresh and `result-cleanup` under the ignored branch-local
`.agent-1c/runs/release-e2e/<branch>/` directory. Baseline and post-config `.dt`
snapshots, state, `.dev.env`, evidence and expected HEAD are SHA-checked.
Checkpoint v2 records fingerprints, proof/current-run durations and attempts.
`Auto` resumes the same release and keeps cross-release capability evidence only
when every input fingerprint matches. A cross-release reuse still executes a
fresh passing `/itl-check`, export/manifest SHA validation and cleanup.

If scope, expected E2E HEAD, evidence or snapshot integrity changed, `Auto` stops
fail-closed. A schema v1 checkpoint requires one explicit `Restart` migration.
`-ReleaseResumeMode Restart` validates the checkpoint scope and recorded
baseline hashes, restores the baseline database and state, and resets only the
dedicated E2E worktree to the recorded initial commit before beginning a new
run. A corrupt checkpoint, changed HEAD, damaged evidence/snapshot or different
project/worktree/branch is refused even for `Restart`; do not edit checkpoint or
state by hand.

## Reset and rollback

- A failed E2E run does not qualify a release tag or workflow baseline.
- For a transient interruption, use `Auto` resume. When the cause or state is
  uncertain, use the scripted `Restart` rollback; do not manually repair the
  database, checkpoint or lifecycle state.
- Never repair an already published fork tag. Publish the next `rN` revision.
- Roll back a workflow baseline by restoring the previous fork tag and exact
  commit in both templates, then rerun the entire Release gate.
