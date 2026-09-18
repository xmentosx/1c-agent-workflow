# On-demand configuration source mode implementation plan

This source-maintenance plan defines an optional ITL mode that avoids a full
configuration XML dump during project initialization and normal branch work.
It is not installed-project guidance and does not change the existing full-source
mode unless the project explicitly selects the new mode.

## Goals

- Make initial project creation viable for very large configurations without
  dumping the complete configuration to `src/cf/**`.
- Keep using native 1C `ConfigDumpInfo.xml` version tracking to determine source
  changes. ITL must not implement its own configuration-diff engine.
- Give every development branch an independent source baseline so branches may
  remain on different source revisions without sharing one synthetic delta.
- Preserve the existing semantic difference between full refresh and lite refresh:
  full refresh may update the source infobase from repository storage; lite refresh
  only captures the current state already present in the source infobase.
- Serialize access to the shared source infobase by the existing database access
  coordinator and wait for the owner instead of failing merely because another
  branch is currently exporting its delta.
- Keep branch merge/load work independent after its source export has completed,
  so unrelated branch work can proceed concurrently.
- Bound accumulated materialized XML by the lifetime of each branch baseline and
  recreate that baseline on branch reset.
## Non-goals

- Do not replace Git with a custom content store.
- Do not keep a global archive of every XML version ever observed.
- Do not introduce a workflow-computed global source delta and repartition it
  between branches.
- Do not silently fall back to a full XML dump in on-demand mode.
- Do not change existing `full` projects automatically.
- Do not infer deletion from a file being absent from a partial source tree.

## Project mode

Introduce one project-level source representation setting, provisionally:

```text
SOURCE_EXPORT_MODE=full|on-demand
```

`full` remains the default and retains the current behavior. New projects may
select `on-demand` in initialization. Existing projects require an explicit
migration operation before changing modes.

In `on-demand`, every lifecycle path must either support the partial source
representation or stop with an actionable unsupported-operation result. A full
`/DumpConfigToFiles` is never an automatic recovery fallback.

## Core branch model

For each ready configuration development branch:

```text
itldev/<name>       user development branch
itlbase/<name>      workflow-owned shadow baseline branch
```
The shadow baseline is machine-owned and is never a user development workspace.
Its worktree/export area is workflow-managed runtime. It contains only source
artifacts that became relevant after the branch baseline was created.

Each branch state records at least:

- shadow baseline ref and worktree/export path;
- source-baseline revision identity;
- source `ConfigDumpInfo.xml` identity and checksum;
- current shadow-baseline commit;
- last shadow-baseline commit successfully applied to the branch infobase;
- explicit structural operations that cannot be represented by file presence
  alone, including deletions;
- source provenance needed to prove that the cursor belongs to the configured
  source infobase/repository context.

The `ConfigDumpInfo.xml` stored for `itlbase/<name>` is a **source cursor**.
It is used only to ask 1C for changes between that branch's accepted source
baseline and the current source infobase. It must not be reused as a cursor for
the diverged development infobase.

## Phase 0 — platform capability spike

Before changing lifecycle behavior, prove the required 1C primitives on the
supported platform range with a technical configuration large enough to expose
performance and partial-dump behavior.

Verify and retain evidence for:

1. obtaining an initial version cursor without a full XML source dump;
2. exporting changes to an empty staging directory relative to an arbitrary
   saved `ConfigDumpInfo.xml`;
3. exporting a selected existing object to a partial/empty source area without
   requiring a complete previous XML tree;
4. how additions, renames and deletions are represented by native change export;
5. whether a new result `ConfigDumpInfo.xml` fully advances the supplied cursor
   after a successful incremental export;
6. whether two independent cursors from different source revisions can both be
   advanced directly to the same current source state;
7. behavior when the source configuration repository is updated between cursor
   creation and export;
8. interaction between partial load and a separate development-infobase cursor
   used to detect Configurator-side edits;
9. failure behavior for incompatible/corrupt cursors and whether 1C attempts an
   implicit full dump.

The spike must select native platform behavior wherever available. If a required
primitive cannot be proved without a full source tree, stop this design phase and
revise the representation instead of emulating platform object version logic.

## Phase 1 — initialization without full XML

Add the `on-demand` branch to `Initialize-Project`.

Initialization must:

1. prepare and validate source/repository settings exactly as today;
2. reserve the source infobase through existing database admission;
3. apply the existing source repository update policy where initialization
   currently does so;
4. capture the initial source version cursor without dumping all source files;
5. persist a project source-revision record containing cursor hash, source
   identity and repository provenance;
6. create/refresh the branch seed without requiring a fingerprint of a complete
   `src/cf/**` tree;
7. install workflow/rules/tooling as today;
8. commit only the on-demand project metadata required for reproducibility.

Resume must recognize every completed on-demand stage and never restart a full
XML dump. The initialization readiness proof changes from "baseline source tree
committed" to "source revision cursor + seed/provenance committed and valid".

Seed compatibility must be redesigned explicitly. In on-demand mode it is bound
to the source revision identity/cursor provenance rather than to a hash of every
XML file. Existing full-mode fingerprint semantics remain unchanged.

## Phase 2 — create a branch and its shadow baseline

`new-dev-branch` in on-demand mode creates the ordinary isolated branch
infobase from the compatible seed, then creates `itlbase/<name>`.

At creation time:

1. obtain a cursor that describes the exact source state associated with the
   branch baseline;
2. create the shadow branch/worktree with no full configuration source tree;
3. store that cursor and provenance in the shadow baseline;
4. record the shadow ref/path and cursor identity in dev-branch state;
5. record `lastAppliedBaselineCommit` as the initial shadow commit;
6. finish branch normalization/runtime setup as today.

The source cursor and copied branch infobase must describe one coherent baseline.
If creation cannot prove this relationship, it must not mark the branch ready.

The shadow worktree should live in ignored workflow runtime and must not appear as
another user-editable project. Path-budget and cleanup behavior must be covered by
the same Windows whitespace+Cyrillic path rules as normal worktrees.
## Phase 3 — native per-branch source capture

Add one shared helper that advances a specific branch shadow baseline from its
own source cursor. This helper is the only normal path that asks 1C to determine
source changes for that branch.

Conceptual operation:

```text
source infobase current state
        +
itlbase/<name>/ConfigDumpInfo.xml
        |
        v
1C incremental export into empty staging
        |
        v
validated patch + new ConfigDumpInfo.xml
        |
        v
transactional update of itlbase/<name>
```

Rules:

- 1C determines changed objects; ITL does not diff configuration versions itself.
- Export starts in an empty transaction staging directory; never copy the whole
  current baseline tree merely to make partial export transactional.
- Apply only files/structural operations represented by the native result.
- Update the cursor only after the complete patch has been validated and the
  shadow baseline commit is durable.
- An interrupted export retains old cursor authority until continuation proves
  the new shadow commit and cursor were both installed.
- Failure never falls back to a full XML export.
## Phase 4 — `itl-refresh` semantics

In on-demand mode, full refresh keeps its current source-synchronizing meaning.

Source phase:

1. acquire the source-infobase database admission;
2. apply `SOURCE_REPOSITORY_UPDATE_MODE` exactly as the existing full workflow
   defines it (`workflow` updates from repository storage; `external` captures
   the source infobase as currently maintained outside ITL);
3. perform any seed/global source-state maintenance that belongs to full refresh;
4. advance **only the current branch's** `itlbase/<name>` using its own
   `ConfigDumpInfo.xml`;
5. release source-infobase admission as soon as this capture is durable.

Branch phase then runs without the source admission:

6. compute Git changes from `lastAppliedBaselineCommit` to the new shadow commit;
7. merge those source changes with branch-owned changes;
8. validate the resulting partial source set;
9. partially load the resulting change set into the branch infobase;
10. normalize as required;
11. advance `lastAppliedBaselineCommit` only after successful branch application;
12. mark verification stale exactly as required by the changed effective state.

The source infobase must not remain locked while Designer/Enterprise work runs
against the development infobase.

## Phase 5 — `itl-refresh-lite` semantics
`itl-refresh-lite` **does access the source infobase in on-demand mode**, because
its shadow baseline must reflect the source infobase's current configuration.
It does **not** update that source infobase from repository storage and does not
refresh/rebuild seed.

Source phase:

1. wait for source-infobase admission;
2. do not call `ConfigurationRepositoryUpdateCfg` or equivalent repository
   synchronization;
3. read the current source infobase exactly as it stands;
4. advance the current branch's shadow baseline using that branch's own cursor;
5. release source-infobase admission immediately after the shadow update commits.

Branch phase is the same as full refresh: merge the newly captured shadow delta,
partially update the branch infobase, normalize if needed, and advance
`lastAppliedBaselineCommit` only on success.

This preserves the full-source-mode distinction:

```text
itl-refresh
  = synchronize source according to repository policy
  + capture current branch delta
  + apply branch

itl-refresh-lite
  = capture current source state without repository synchronization
  + apply branch
```

## Source-infobase waiting and concurrency
Reuse the existing database-access coordinator/admission model. Do not introduce a
second ad-hoc lock file for on-demand source export.

Two concurrent lite refreshes for different branches behave as:

```text
task1: [wait/admit source][export task1 delta][release]----[apply task1]---->
task2: [--------wait source---------][export task2 delta][release]-[apply task2]->
```

Requirements:

- contention is waiting, not an immediate failure;
- waiting remains bounded/cancellable by the existing coordinator contract;
- owner diagnostics remain visible in run status;
- admission is acquired before lifecycle locks where required by the existing
  deadlock-prevention contract;
- no partial resource set survives a failed admission attempt;
- after source capture, each branch owns only its branch resources and different
  branch apply phases may run concurrently;
- source read/export operations must not be serialized by a broader global
  lifecycle lock for longer than the actual shared-source critical section.

## `refresh-all-dev-branches`

In on-demand mode, refresh-all must not synthesize one global XML delta.

Correctness-first flow:

1. synchronize the source infobase once using the normal full-refresh repository
   policy;
2. pin/prove the source state for the aggregate operation;
3. for every active branch, run native incremental export using that branch's own
   `ConfigDumpInfo.xml`;
4. keep the per-branch exports serialized while they require the shared source
   infobase;
5. after each branch's capture is durable, allow its apply phase to run in the
   existing bounded branch-worker pool where safe;
6. report each branch's captured source revision, shadow commit and apply result.

Optimization of repeated native exports is explicitly deferred until measurement
proves it necessary. Correctness must not be traded for a workflow-computed
cross-branch delta.

## Phase 6 — materialize an object for development

A branch may need to edit an object that has never appeared in its partial trees.

Introduce an internal "ensure source object" operation that:

1. proves the development infobase is at the branch's accepted effective state;
2. exports only the requested object/required structural parts;
3. records the source-side baseline content in `itlbase/<name>` when needed for
   future three-way merge;
4. materializes the editable copy in `itldev/<name>`;
5. records provenance so simply reading/materializing an object is not treated as
   a product modification.

Do not recursively materialize every dependency. Expand the working set only when
analysis or editing requires another object.

A separate development-infobase cursor/proof is required to distinguish
Configurator-side edits from source-baseline materialization. Its exact mechanism
must be selected from Phase 0 evidence; do not reuse the source cursor against the
development infobase after branch divergence.
## Phase 7 — additions, deletions and structural changes

Represent deletion explicitly. File absence in a partial tree means "not
materialized" unless a structural change record proves deletion.

The shadow/dev change model must distinguish:

- unchanged but absent;
- materialized for context;
- modified;
- added;
- deleted.

Prefer native 1C change metadata for determining source-side structural changes.
Persist a compact manifest/tombstone only where Git file presence cannot express
the native operation unambiguously.

Merge rules include:

- branch deletes / source unchanged -> retain branch deletion;
- branch deletes / source deletes -> compatible deletion;
- branch deletes / source modifies -> semantic conflict;
- branch modifies / source deletes -> semantic conflict;
- both modify -> normal three-way merge using the materialized common baseline.

Loading a structural change must build the minimum platform-valid package,
including required owner/root descriptors. Never interpret an incomplete local
tree as a full configuration.

## Phase 8 — reset and bounded accumulation

`reset-dev-branch` in on-demand mode establishes a new current baseline instead
of continuing the old shadow history indefinitely.
Reset flow:

1. checkpoint/archive branch-owned work using the existing reset safety contract;
2. obtain/prove the new source baseline and compatible seed;
3. recreate the branch infobase as the reset contract requires;
4. create a new `itlbase/<name>` generation with a fresh source cursor and an
   effectively empty materialized source set;
5. bind the dev-branch state to that new shadow generation;
6. set the new shadow commit as `lastAppliedBaselineCommit`;
7. retire the previous shadow ref/worktree only after the new generation is ready.

If bounded **Git object storage** is also a requirement, reset must make obsolete
shadow history unreachable except for explicit retained archives, and normal Git
GC may reclaim it later. Merely deleting files from the current tree does not
remove reachable historical blobs. This storage behavior must be documented and
tested separately from current-tree size.

## Phase 9 — adapt the remaining lifecycle

Every command that currently assumes a complete `src/cf/**` tree needs an
explicit on-demand contract. At minimum review:

- `update-dev-branch-base` and partial-load fallback behavior;
- `loadfrom1cbase` / `getconfigfiles`;
- `check-dev-branch` freshness fingerprints;
- result export and repository-transfer object mapping;
- `sync-dev-branches`, including three-way baseline construction;
- `fork-dev-branch`;
- `lock-config-repository-objects`;
- merge preservation and source-integrity validators;
- extension mode, which should remain full-only until an equivalent contract is
  intentionally designed and proven;
- source indexes/search tools that currently infer non-existence from missing files.

For on-demand mode, effective configuration identity is no longer "hash every file
under the complete source root". Define a versioned fingerprint from:

```text
accepted source baseline identity
+ shadow baseline generation/commit
+ branch-owned effective changes
+ structural-operation manifest
```

Materializing additional unchanged context must not stale verification. Changing
effective configuration content must stale it.

A full Designer load fallback may only be used if ITL can first construct and
prove a complete effective configuration by a supported path that does not
silently perform the prohibited full source dump. Until such a recovery path is
implemented, on-demand mode should fail closed with a specific recovery action.

## Implementation order

1. Phase 0 native capability spike and retained evidence.
2. Project setting and initialization representation.
3. Shadow branch lifecycle and branch creation.
4. Per-branch native source capture helper.
5. `itl-refresh-lite` with source waiting and no repository update.
6. `itl-refresh` with repository policy + seed/global maintenance.
7. Branch apply/partial load and development-infobase cursor handling.
8. On-demand object materialization.
9. Add/delete/structural-change support.
10. Reset and shadow-generation retirement.
11. Refresh-all pipelining.
12. Verification/export/sync/fork/repository-lock adaptations.
13. Optional migration from existing `full` projects after the new-project path
    has passed installed acceptance.

Do not enable the mode by default before all completion-critical lifecycle paths
used by configuration branches have an explicit contract and installed acceptance.

## Required regression and acceptance matrix

At minimum cover:

- new project initialization completes without a full XML dump;
- resume at every initialization/source-capture transaction boundary;
- two branches created from different source states keep different cursors;
- advancing one branch cursor never mutates another branch cursor;
- lite refresh captures newer **current source DB** state without repository update;
- full refresh performs the configured repository update policy before capture;
- two simultaneous lite refreshes wait on the source DB and then both succeed;
- source admission is released before branch database load/normalization;
- different branch apply phases can overlap after their source captures;
- one object modified repeatedly in source yields the correct current branch delta;
- branch/source modify the same object and receive a valid three-way merge/conflict;
- branch deletion vs source unchanged/modified/deleted cases;
- source deletion vs branch modification;
- a newly materialized unchanged object does not count as a branch modification;
- manual Configurator-side edits are detected rather than overwritten silently;
- reset installs a new shadow generation and no longer depends on the old cursor;
- corrupt/incompatible cursor fails without starting a full XML dump;
- cancellation/interruption preserves the old authoritative cursor until recovery;
- whitespace+Cyrillic project/worktree paths;
- file and server source/branch infobases where supported.
## Performance evidence

Record phase timings and data volume separately so improvements cannot be hidden
by moving cost elsewhere:

- initialization cursor capture;
- seed creation/copy;
- per-branch native incremental source export;
- shadow transaction/Git commit;
- dev merge;
- partial Designer load;
- Enterprise normalization;
- verification.

Acceptance for the new mode is not merely "init is faster". The primary user
scenario must reach a fresh verified first change without ever requiring a full
configuration XML dump.

For refresh-all, report source-export time per branch and total serialized source
critical-section time. Optimize only after measurements show that independent
native per-cursor exports are the dominant remaining cost.

## Delivery discipline

Implement each coherent source change with focused owner tests and the normal
source-repository delivery contract. Do not weaken database admission, merge
preservation, fresh verification, seed safety or recovery semantics to make the
partial-source representation easier.

The new mode should prefer automatic acquisition of missing context and waiting
for owned shared resources. User intervention is reserved for genuine semantic
conflicts, unsafe ownership ambiguity, unsupported platform behavior, or a real
risk of data loss.
