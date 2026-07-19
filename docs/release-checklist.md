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

Run `Full` once on that exact clean workflow/fork pair before `Release`. Its
`build/test-results/qualification/full.json` inventories the exact tests,
gate scripts, JUnit, environment, workflow commit/tree and fork qualification.
`Release` may reuse only that exact proof for Pester, fork Full and compatibility;
it still runs `git diff --check`, helper parse/help and the complete runtime E2E.
Every summary stage records whether it was executed, reused or skipped and why.

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

Keep `build/test-results/local/check-summary.json` and the nested E2E summary as
release evidence. A failed cleanup, stale Vanessa result, unverified override,
missing `ParentConfigurations.bin`, non-partial load, extra list-file entry,
roundtrip mismatch, missing manifest, hash mismatch, dirty worktree, dynamic
fork branch, aggregated/missing JUnit results, a helper that masks a failed
scenario, non-idempotent form/template registration, failed extension TestClient
form opening, failed extension database restore or unpinned template is a
release failure.

## Resume after interruption

The runner checkpoints `config-cadence`, `config-roundtrip`, `extension-smoke`
and `result-cleanup` under the ignored branch-local
`.agent-1c/runs/release-e2e/<branch>/` directory. Baseline and post-config `.dt`
snapshots, state, `.dev.env`, evidence and expected HEAD are SHA-checked. Repeat
the same Release command with the default `-ReleaseResumeMode Auto` after a
transient failure. Passed stages are reused and a failed extension stage starts
from the exact post-config snapshot, so the three configuration checks are not
repeated.

If workflow/fork/helper/project-config identity changed, `Auto` stops with
`RELEASE_E2E_RESUME_STATE_MISMATCH`; after inspecting the expected change, use
`-ReleaseResumeMode Restart`. It validates the checkpoint scope and recorded
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
