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
   `.agent-1c/release-e2e.json` and record separate `developWorktreePath` and
   Release `worktreePath` values. They MUST name different disposable
   `itldev/*` worktrees: Develop refreshes only its own branch, so it cannot
   replace the generated fixture HEAD recorded by the Release checkpoint.
7. Run `/itl-check` once manually to prove the stand itself is healthy.

The Release seed probe creates its own disposable configuration repository inside
the temporary branch run root when the dedicated stand does not use a repository.
It binds only the disposable branch infobase, performs the mandatory exact-object
lock/unlock roundtrip, and restores the helper process environment afterward.

The fixture branch remains dedicated to workflow releases. Reset its disposable
database from the in-stand source snapshot whenever state may have leaked
between runs. Replace that snapshot explicitly when a new baseline is intended;
do not repoint the stand at the original external infobase.

## Each fork/workflow release

First publish and qualify the exact accumulated development candidate:

```powershell
.\scripts\source-delivery.ps1 -Action PublishDevelop `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

This is the only broad check for a batch of ordinary source tasks. It runs one
`Develop` gate on the final temporary candidate, publishes only after success,
and leaves the queue intact on failure. When a new controlled-fork lock is
`pending`, the same transaction first qualifies that exact preliminary tree,
promotes only the lock, then runs `Develop` on the final `passed` tree; neither
the preliminary workflow commit nor a pending dependency is pushed. A retry
restores the promotion checkpoint instead of repeating its preliminary gate.
No topic chat runs Full/Develop first.
A passed `Develop` already owns the exact-tree Full/static evidence; a separate
`Full` for that tree is redundant and must not be run.

When the accumulated queue must reach both `develop` and stable `master`, use one
release train instead of `PublishDevelop -RequireRelease` followed by
`ReleaseMaster`:

```powershell
.\scripts\source-delivery.ps1 -Action PromoteRelease `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

It runs `Develop`, then `Release`, on one temporary candidate, publishes that
candidate to `develop`, and promotes the same qualified tree to `master` without
running either gate again. Exact commit/tree and current-attempt passed run
records are mandatory for reuse; a reconciliation that changes the candidate
falls back to the complete release gate. Any failure before develop publication
preserves the queue and old remote refs.

If the process stops after publishing `develop`, the durable release-train
checkpoint remains in the common Git directory. Re-running `PromoteRelease`
with an empty queue resumes the exact qualified commit/tree and does not repeat
Develop or Release. The checkpoint is removed only after verified master
publication.

`PublishDevelop -RequireRelease` remains available only when the development
channel itself must be release-qualified but `master` is intentionally not being
moved. Do not follow it immediately with `ReleaseMaster`; use `PromoteRelease`
for that combined intent.

Successful `PublishDevelop` output must state `developPublished=true`,
`dependenciesInstallable=true`, and `masterReleased=false`. This completes the
installable development channel, including owned component publication, but
does not move stable `master`; only `PromoteRelease` or the explicit command below may report
`masterReleased=true`.

Every successful development publication or master release performs a
best-effort post-success cleanup of exact ITL-generated candidate worktrees,
disposable fresh/release-seed projects, stale 1C launcher registrations, and old
launcher backups. Configured reusable stands and any active path are preserved;
cleanup warnings do not rewrite a verified publication as failed.

When that remote development commit is ready for the stable channel, run:

```powershell
.\scripts\source-delivery.ps1 -Action ReleaseMaster `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r31-codechecker-logic `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

For a GitHub remote, `ReleaseMaster` completes the protected `master` update
through a generated pull request and the repository's allowed rebase merge. It
then reconciles that actual master commit into `develop` without force and
verifies that both remote branches contain the qualified tree. A retry resumes
this reconciliation when the pull request was already merged.

Qualification records the exact tests, gate scripts, merged shard JUnit,
environment, workflow tree, fork qualification and Develop live report. A
descendant commit may reuse it only when the evidence commit is its ancestor and
the tree plus every inventoried SHA remain identical. Release refuses to start
without matching Develop evidence, so standard user journeys are not repeated.
Server infobases remain supported, but a release may proceed without a configured
server stand. In that case the summary must report `server-reset: unverified`;
it must not claim passed server evidence. When any server stand field is present,
all three fields are required and the real server reset proof remains blocking.

`Full`, `Develop`, and `Release` first create one immutable
`build/test-results/local/release-context.json`. Do not start Designer,
Enterprise or a manual recovery while this context reports `failed`. Resolve
every listed issue and rerun the same gate. The preflight intentionally reports
all candidate, dependency, encoding and stand drift in one pass instead of
failing after an expensive stage.

The Develop journey installs the dedicated E2E master and configured branch from
the exact workflow candidate through normal `update-workflow`. Their managed package inventory and both
`.agent-1c/dependency-lock.json` files must match the candidate before Release.
The script commits the managed stand update and refreshes the disposable branch.
Never copy a lock or helper into the stand by hand.

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

Component publication is a finalize operation over already qualified bytes.
The candidate dependency lock MUST contain the final immutable tag, URL, and
SHA256 values before Develop/Release. Qualification resolves those exact local
bytes through the source-build override; publication uploads the same bytes and
verifies the remote digest. Do not commit a `pending`/`published` transition
after qualification: publication state is external release evidence, not an
input in the qualified Git tree.

`PublishDevelop` finalizes this contract after its required qualification and
before pushing `develop`. A live URL with the locked SHA is read-only. A missing
asset may be created only after Release, requested explicitly or selected by the
owned-component plan, from the exact SHA-matching local candidate: the GitHub
owner/repository, annotated tag, asset name, and candidate
commit must all match. Existing tags and assets are never repointed or
overwritten; any mismatch or failed remote verification preserves the queue.
The ai_rules finalizer additionally requires `compatibilityStatus=passed`; the
presence of its remote immutable tag alone is not publication success.

The finalizer covers every owned release surface: the controlled `ai_rules_1c`
branch plus annotated tag, the patched Vanessa Automation asset, and the
`itl-ondemand-mcp` asset. Missing high-risk assets automatically make
`PublishDevelop` run Release even when `-RequireRelease` was not supplied. The
rules release still requires an explicit clean `-AiRulesSource` with exact Full
qualification and local immutable refs. External dependency locks are verified
only and never republished. Component evidence is stored separately per exact
workflow candidate so a safe retry continues idempotently after a partial
cross-repository finalization.

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

For the patched Vanessa Automation artifact, pre-publication qualification must
set `ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE` to the exact local candidate.
The release smoke must record the canonical archive and EPF SHA-256, compatibility
version `1.2.043.28`, downstream revision `itl-r8`, a matching live `tools/list`
catalog, successful ordinary file and directory calls on a Windows path containing
spaces and Cyrillic text, and `client_mcp` plus `VAExtension` with safe mode
explicitly proven disabled. The live catalog must additionally expose
`get_data_from_knowledge_base.search_string` as `string` and direct
`get_window_screenshot_os` callers to `get_window_list_os`; every other pinned
tool contract remains exact, including upstream `reloadAndRunFromLine` behavior.
The real EPF smoke must first call `run_scenario(filePath=..., mode=reloadAndRun)`
for a feature that is not active, repeat it while the same feature is active, and
then make the first call for a second feature with
`mode=reloadAndRunFromLine` and a real scenario line number. Each run must be followed by state and
result calls with passed evidence bound to the expected feature path and SHA-256.
`runner-fallback-required` is not release evidence.
The 1C compiler output is qualified as exact bytes rather than assumed
reproducible: after live qualification, publish that same EPF/distribution
without rebuilding it. Deterministic ZIP packaging may be repeated only against
the unchanged qualified distribution and must retain the recorded EPF SHA-256.
Before `itl-r8` publication, the installed lock and compatibility manifest remain
on released `itl-r7`. The pre-publication candidate may use its exact local archive
override only on the dedicated release stand. After the same qualified bytes are
published, commit their lock, live catalog, and exact hashes together before
publishing `develop`; never expose an installed `published` pin whose asset URL is
not yet live.

The real file-infobase release gate must rebuild the single latest seed, restore
two disposable branches from that same seed under overlapping read leases,
advance installed-project `master` with a controlled commit, and run two
overlapping `refresh-dev-branch-lite` operations. Evidence must record the same
exact target SHA in both branches, unchanged seed/source observations, seeded
event-log baselines without a full branch-log scan, distinct branch infobases,
and successful cleanup while retaining only the current seed.

## Resume after interruption

The runner checkpoints `seed-parallel`, `config-cadence`, `config-roundtrip`, `extension-smoke`,
`ondemand-mcp`, verification refresh and `result-cleanup` under the ignored branch-local
`.agent-1c/runs/release-e2e/<branch>/` directory. Baseline and post-config `.dt`
snapshots, state, `.dev.env`, evidence and expected HEAD are SHA-checked.
The two-instance Vanessa UI probe keeps both facade/TestManager backends live in
their empty service infobase but closes each target-infobase TestClient after its
smoke before starting the next one. This preserves backend-isolation proof while
staying within each exact infobase's configured `ONEC_MAX_CONCURRENT_SESSIONS=3`
ceiling (two service TestManagers and one target TestClient).
Strict owned-process cleanup allows a bounded Windows exit-confirmation window
after force-stop; a PID still alive at the deadline retains runtime state and
leases and fails the release. Release evidence records the actually observed
`maxConcurrentSessions` (which must not exceed `3`) and
`ownedProcessExitWaitMs` (which must not exceed `15000`).
Checkpoint v3 separates mutable rollback state from immutable capability cache.
Before a temporary source candidate can be removed, passed evidence is sealed
under `.agent-1c/runs/release-e2e-capabilities/<branch>/<runId>/`.
Only the post-config snapshot/state needed by cross-release import is copied to
that immutable cache; the baseline stays in the current mutable checkpoint for
`Restart`. After a successful run, retention keeps only the current capability
generation and current CF/CFE plus its manifest, and removes older E2E exports
and completed `release-e2e-*`/`extension-init-*` recovery snapshots. A failed or
interrupted run retains its current rollback evidence for safe resume.
`Auto` resumes the same candidate in place. For a new workflow candidate it
SHA-checks and archives prior capability evidence, restores the prior baseline,
creates a new baseline/initial HEAD, replays owned fixture commits, and imports
only stages whose input fingerprints still match. It always executes a fresh
passing `/itl-check`, export/manifest SHA validation and cleanup.

If scope, expected E2E HEAD, evidence or snapshot integrity changed, `Auto` stops
fail-closed. A schema v1/v2 checkpoint requires one explicit `Restart` migration.
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
