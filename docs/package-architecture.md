# Workflow package architecture

This source-only document describes the package layout for maintainers. It is not copied into initialized projects.

- `.agents/skills/1c-workflow` owns the full lifecycle router, references, helper scripts, and generated client templates.
- `.agents/skills/1c-workflow-fast` owns the compact routine-operation surface.
- `.agents/skills/product-docs`, `itl-roctup-1c-data`, and `itl-vanessa-ui-mcp` own optional product/runtime integrations.
- `itl-remote-runner`, `itl-remote-agent`, and `itl-performance` share a portable Python job/measurement runtime. A user-started worker normally uses an outbound pull control channel; an optional shared folder accelerates only immutable hash-addressed blobs, while preconfigured SSH/exchange remain compatibility adapters. Runner, agent policy and transport are independent. The same worker queue can also own explicitly authorized host-command jobs under the interactive Windows user; those jobs reuse pull transfer, claim/state/cancel/result IDs and owned process cleanup, and never acquire or bypass a declared 1C target guard on behalf of arbitrary code. The pairing token is therefore a broad user-account credential when host commands are enabled. A private user-local controller catalog owns named pairing discovery and on-demand broker startup across projects, while the worker spool remains the only job state owner; an authenticated health check reuses an existing broker and an unknown listener is left intact. One launcher staged through an explicitly trusted transfer folder performs first installation and writes status there; the folder never carries mutable job control. Compatible worker updates install into verified user-local generations and switch only while idle under a rollback-capable supervisor; the user-started supervisor renews bounded generations while its window remains open. The portable bundle includes the existing 1C process/session guard modules; it does not install the full lifecycle or require administrator rights. Remote worker startup remains an explicit user action. See [remote operation contracts](../.agents/skills/itl-remote-runner/references/operations.md) and [measurement recipes](../.agents/skills/itl-performance/references/measurements.md).
- `.agents/skills/1c-workflow/chatgpt` contains the optional ChatGPT/Remote Desktop Commander sidecar, MCP transport bridge, and ChatGPT-only plugin marketplace. It is installed and versioned with each project worktree but remains outside normal Codex command/MCP discovery.
- `docs/itl-workflow` contains the human-facing documentation installed into projects.
- `templates` contains tracked project defaults, ignored-file additions, dependency locks, and project guidance overlays.
- `install-agent-1c-workflow.ps1` installs the managed package and starts monitored initialization.
- `scripts/check.ps1` and `scripts/test-ai-rules-compatibility.ps1` own source-repository qualification.
- `scripts/source-delivery.ps1` pins the stable supervisor from the already
  published `origin/develop` for `Plan`/`PublishDevelop` and from `origin/master`
  for master publication; `source-delivery-supervisor.ps1` owns publication authority,
  while `source-delivery-plan.ps1` and `source-delivery-resources.ps1` own the
  immutable selective plan/evidence and common-Git resource ledger.

The approved source candidate protocol keeps the existing supervisor as its
single owner. RegisterChange, Plan, and PublishDevelop select published develop;
master promotion and release keep master authority. Registration constructs an
integrated candidate outside the operation lease, then atomically compares and
updates queue base/head and candidate head/membership refs in common Git. One
original deadline covers CAS retries and child gates. A failed attempt preserves
the source task, accepted refs, candidate worktree/checkpoint, and existing proof;
the continuation is the same RegisterChange from the source checkout. Legacy
base/head records remain readable and are integrated on the next registration.
This protocol checkpoint was approved by the user on 2026-10-11 in
`openspec/changes/redesign-source-delivery/design.md`. The existing publication
attempt freezes queue membership and its queued candidate; a saved plan also
binds membership, while legacy plans retain their original identity and authority.
Publication cleanup compares only frozen queue pairs, preserves later work, and
retries ref movement without repeating qualification. Post-push recovery uses
the frozen attempt rather than next-release registrations. Historical-plan
transition and functional rollback retaining a compatible queue decoder have
native acceptance in [candidate recovery](../openspec/changes/redesign-source-delivery/evidence/candidate-recovery.md).
Explicit PublishDevelop Replan archives the original checkpoint and rejected
proof through this same owner; unchanged inputs cannot reset its circuit breaker.
This adds no state owner, lock family or master-channel authority.

The user approved pinned Frozen repairs on 2026-10-27. This same Replan owner
may append explicitly named registered id/head pairs based on the original
candidate; it cannot replace frozen members or carry unselected later heads.
The ordinary immutable replacement plan, qualification and queue CAS remain
authoritative, including when the live repair registration advances afterward.

The user approved failing-range deferral on 2026-10-28. The queue owner adds one
record per entry, `refs/itl/develop-queue/<id>/deferred`, bound to the exact
failed head and written by the same compare-and-swap ref transaction; the next
registration of that id removes it. Publication and Plan exclude a deferred head
and rebuild from published develop. The publication supervisor attributes only a
product Pester failure: its files pass on published develop and fail with
exactly one range merged alone; integration, environment, stand and E2E
failures keep the existing stop. Before plan pinning the same operation and
deadline continue with the rest (at most two deferrals); a pinned plan keeps its
membership and names `-Replan`. No new lock, coordinator, installed state or
client surface is added. Rollback is the previous supervisor, which ignores the
record and integrates every head.

Delivery calculation is a stateless candidate contract, distinct from publication
authority. The existing supervisor calls the exact clean candidate's calculator
in a child scope, validates its envelope and input identity, and binds calculator
commit/SHA before saving. Its queue, locks, proof validation, approval, recovery
and push remain with the published owner. A newer shim talking to a legacy owner
returns one advisory candidate calculation through the owner's read-only readers
and queue/preflight functions; existing saved plans remain unchanged. The preview
is never persisted as resumable authority and the legacy calculator does not run.
The same child-scope calculation boundary admits only the candidate's stateless
remote asset query functions. The published component selection and preflight
still own required Release capabilities; changed candidate bytes are rejected
before and after inspection. Older planners use the advisory preview boundary
for this calculation too. This adds no coordinator,
installed migration, runtime owner or permission to execute a delivery stage.

The user approved scoped fork/native proof on 2026-10-26. The existing Develop
qualification owner retains exact fork provenance while comparing authenticated
native inputs separately. Its shared stateless fork contract admits only audited
instruction-body/static-checker deltas; the current Full owner binds exact fork
Full and old-to-new installation receipts. The same comparator serves planning,
execution and failure matching. Existing immutable reports, static cache and
continuation references carry the evidence; no new registry, runtime owner,
installed migration or publication authority is introduced. Missing proof falls
back to native qualification through the existing gate.

The user approved bounded frozen-scope recovery on 2026-10-16. Explicit
`PublishDevelop -Replan <originalPlanId> -ReplanQueueScope Frozen` transfers the
original checkpoint to a compatible published develop supervisor only after
checking recorded-supervisor ancestry, checkpoint SHA and immutable plan/queue/
candidate identity. That owner integrates the original candidate with published
develop and retains the original queue pairs; later and advanced registrations
remain queued. The replacement pins its supervisor and scope for retries.
Ordinary Replan still incorporates the current queue; ResumePlan still pins its
recorded supervisor. Support is published separately from a clean published
baseline before this recovery is used. Existing archives, lease, circuit breaker,
qualification and compare-and-swap cleanup remain authoritative.

The user approved bounded fixture Capture continuation on 2026-10-16.
Explicit `source-e2e-fixture.ps1 -Action Capture -AcknowledgeWorkflowUpdate`
may admit only a contiguous terminal update-workflow receipt chain from the
sealed capsule's master/branch commits. The update owner validates receipt
identity and backup bytes; Capture checks single-parent Git hops, endpoint-pinned
workflow ownership, no business/scenario changes or takeover of existing paths,
before/after path continuity and original environment provenance. Admission is
SHA-bound in the existing fixture descriptor, and ordinary Capture revalidates
the exact admission. New transitions require explicit acknowledgement again.
The immutable capsule/DT and published baseline, database SHA, semantic
pending/cursor/Designer state, context SHA and stand configuration remain fixed.
This adds no lifecycle write authority or state owner; it cannot replace
Recapture or authorize database restoration. Support is qualified/published
separately before frozen delivery resumes. The cost is bounded by the selected
receipt backups and current managed paths; no native database snapshot is rerun.
On the selected two-hop stand, proof inspection measured 35s for Develop and
40s for Release on 2026-10-16, excluding the unchanged database SHA check.
The native fixture suite now has 46 cases and measured 171.8s; its declared
contract budget is 240s rather than 120s, retaining every original assertion.

The develop authority boundary is channel-local, not candidate-local: the
supervisor is the tracked published tip before the operation, never the queued
candidate or a dirty checkout. It alone holds the existing operation lease and
mutates the queue, checkpoint, resource ledger, and remote ref. The immutable
plan pins its authority channel and commit; recovery uses that exact commit and
requires ancestry in the same channel. Plans made before this distinction keep
their recorded master authority, while channel-less plans from the first
develop-controller transition are accepted only when the recorded commit is
already trusted by `origin/develop`. Master promotion and release stay under
master authority. This changes no lock, state machine, installed state, client
surface, platform prerequisite, or cancellation rule. The canary is a divergent
master/develop fixture proving routing and resume before the normal Targeted
registration; rollback is to the previous published develop controller for an
existing plan, never a manual queue or checkpoint rewrite.

Client routine files are generated from `.agents/skills/1c-workflow/kilo-command-templates`. The capability registry maps them to native commands for Kilo, Claude Code, Cursor, OpenCode, Qwen, and Command Code; to skills for Kimi and Cline; and to prompts for Pi. Generated client surfaces are installed-project runtime state, not source files.

The controlled `ai_rules_1c` fork owns general rules, the common OpenSpec workspace, upstream-native OpenSpec bundles, agents, and its installer manifest. ITL owns bootstrap, lifecycle, local MCP configuration, executable verification, result export, the managed ITL skills, and host UX for the `native`/`natural`/`unavailable` OpenSpec states. ITL provisions the exact project-pinned OpenSpec CLI in its local cache separately from the optional global installation. It does not generate client bundles or run `openspec update`; compatible bundle rendering remains with the fork installer. See `ai-rules-fork-upgrades.md` for the release boundary.

## Architecture scope and compatibility policy

Use the simplest coherent architecture that preserves the behavioral contract.
Do not optimize for the smallest diff, fewest files, or fewest abstractions. One
behavioral invariant has one authoritative owner, and duplicated policy must
converge on that owner. Superficially similar operations do not share runtime
authority unless one reproduced cross-boundary failure proves that a common
owner is needed.

Terms in this policy have narrow meanings:

- A **runtime owner** controls one running operation and its exact processes,
  resources, completion, cancellation, and cleanup.
- An **authoritative owner** is the one package component that defines a
  behavioral invariant. It may have many callers and need not be a runtime
  process.
- A **stateless contract** is shared validation, quoting, normalization,
  serialization, or pure planning that owns no durable record, lock, queue, or
  recovery transition.
- **Runtime authority** is permission to block, serialize, cancel, clean up, or
  recover work across otherwise independent runtime owners.
- A **repair cycle** is one coherent implementation attempt followed by the
  original acceptance path. Commits, fixture corrections, and evidence
  collection inside that attempt do not create extra cycles by themselves.

Normal architecture work does not require a separate approval merely because it
touches several files or components. It includes moving an invariant to its
authoritative owner, replacing duplicated policy, introducing a stateless shared
contract, refactoring all affected callers, consuming an existing coordinator
within its documented resource and recovery contract, and replacing a mechanism
without adding installed migration or rollback risk. State the selected owner
and verify every affected caller.

Before implementation, obtain an explicit architecture checkpoint when a
proposal introduces or widens any of these boundaries:

- a machine-wide or workflow-wide coordinator, queue, lock, or persistent state;
- blocking, cancellation, cleanup, or recovery authority across independent
  runtime owners;
- a new installed-state migration whose rollback needs compatibility handling;
- interception of lifecycle, update, verification, or delivery operations that
  were previously independent;
- an elevation requirement, Windows service/firewall change, machine-wide ACL,
  or reduction of supported Windows or terminal-session behavior;
- material growth in always-on client rules, tool schemas, command surfaces, or
  routine output that cannot be routed on demand.

The checkpoint is a short proposal in the active task or an already requested
plan, not a mandatory ADR, registry, manifest, command, or approval file. It
names the invariant and proposed owner; provides a minimal cross-boundary
reproducer when shared runtime authority is claimed; explains why owner-local
and stateless alternatives are insufficient; lists affected and unaffected
owners, resources, operations, clients, platforms, and installed state; confirms
there is one state machine and no shadow coordinator; defines bounded waiting,
status, completion, cancellation, and recovery; records compatibility,
client-context, canary, and rollback effects; and keeps the original acceptance
path as the deciding evidence. Approval covers that stated boundary. A newly
affected owner, resource class, administrative prerequisite, or installed
migration is a scope change; implementation details inside the boundary are not.

The user approved producer-marked diagnostic retention on 2026-10-22. The
existing artifact-retention owner consumes immutable completion receipts for
individual native temporary files and derived XML/ETLX, preserving original
ETL, raw responses, handoffs, databases and unfinished work. No new job state
machine, background service, elevation or lifecycle barrier is introduced.
Routine planning reads bounded metadata; full hashes run only at enrollment
and actual removal. Terminal measurement process cleanup invokes that same owner
and env policy; no running Codex or separate chat automation is required.
Windows 10/11 and Server 2019+ retain non-admin operation. Canary evidence is
the Unicode-path original/derivative cleanup, busy-file continuation, changed
byte/manifest rejection and existing clean-artifacts integration. Rollback stops
new enrollment/invocations; retained originals regenerate derived artifacts.
Unknown legacy investigations remain untouched. See
[diagnostic retention](../.agents/skills/1c-workflow/references/artifact-retention.md).

The user approved concurrent gate stand stages on 2026-10-28. The invariant
stays one state machine: the existing gate owner starts upgrade/fresh scenario
executions before static and, for a Release-requiring PublishDevelop, the
selected Release stages on their prepared fixture. Each child is the existing
journey/Release runner and saves proof through its existing owner. After the
complete current static proof the sequential journeys consume that proof or
execute as before; the later Release gate still requires Develop and reuses a
stage only through its own checkpoint admission. A stage starts only if
measured available memory and commit headroom below 90% cover 2 GiB and 4 GiB
per running stage; otherwise it stays sequential. Every started child finishes
within the original hard budget and keeps its proof; a failed journey fails
Develop after its siblings finish, a failed speculative Release stage never
decides Develop. Fixtures, per-infobase 1C guards, ports and locks keep stages
isolated; no new lock, queue, persistent state, elevation or installed
migration is added. The canary is the first parallel Develop, whose summary
records minimum available memory and peak commit for threshold tuning.
Rollback is the previous sequential gate; stand proofs remain valid.

On 2026-10-28 the user approved serializing fixture Capture with stand updates.
Reproducer: a support publication from a separate clone (its own queue and
lock) ran Capture while another publisher's update had committed master
(13:38:17Z) but had not retained its completed receipt (13:40:32Z); the chain
proof failed `FIXTURE_WORKFLOW_UPDATE_CHAIN_UNPROVEN` at 13:40:11Z. The existing
per-worktree lifecycle lock is the owner: update-workflow holds it on master
through branch rollout and receipt retention. Capture's existing-capsule
proof/admission takes the same exclusive locks on the master and capsule branch
roots through `Wait-Agent1cLockSet`, waits at most 600 seconds (below the
900-second preparation budget) and otherwise fails `FIXTURE_STAND_BUSY` with
the holder's conflict record and a repeat-the-same-Capture continuation. Export
of a new capsule stays outside the lease because its installed child enters the
branch lock itself. No new lock family, state or migration; gates, capsules and
receipts are unchanged. Rollback removes the lease and restores the unguarded
read.

The 2026-10-26 branch-disk review extends this same producer handoff to explicitly
superseded check artifacts. Its owner still receives exact individual files
after terminal process cleanup, with a successful replacement receipt and the
producer's retained dependency list. It consumes these declarations inside the
existing branch commands and lifecycle lock. It gains no discovery, process
control, directory sweep, external service or authority over an active producer.
Unknown older attempts remain until their producer or a concrete evidence
review establishes completion and dependencies. The latest-directory heuristic
is invalid: PM5 branch11 attempt v66 explicitly depends on files from v58.
Acceptance covers Unicode paths, protected older dependencies, successor
changes/failure, original-data exclusions and the real branch cleanup command.
Rollback stops new enrollment; existing unknown kinds are retained by older
consumers. Registration remains distinct from publication and installation.

The user-requested project-local agent-artifact cleanup extends this same owner
only to producer-declared `build/agent-artifacts/<task>/tmp/` files. Terminal
completion and owned consumer cleanup authorize immediate eligibility for this
class; the older diagnostic classes keep their age policy. All clients use the
existing completion argument and lifecycle lock. Successful reset already calls
the same automatic cleanup, so there is no new reset interception, client hook,
timer, process-control authority, migration or shadow state machine. Unknown and
unfinished tasks remain untouched. Databases, DT backups, original traces,
source-snapshot trees and handoffs stay excluded; evidence/recovery directories,
retained dependencies and fresh workflow references remain protected. Immutable
batch identity makes retries safe after partial deletion without enrolling new
bytes at an old path. Acceptance covers the real completion command, the reset
archive/Git/automatic-cleanup sequence, Unicode paths, busy-file continuation,
cross-task/reparse rejection and proof/rollback preservation. Older consumers
retain the unknown kind on rollback; source registration is not installation or
native discovery proof for every client.

On 2026-10-29 the user approved a Pester warmup during the automatic stand
preparation described below. Measured preparation took about 7 minutes (update
222 s, Capture 168 + 18 s) before a 10-35 minute static Pester stage on the
critical path. The stand-preparation owner starts the candidate's own
`invoke-pester-shards.ps1` with the same candidate and fork as an owned job child
and stops it when preparation ends, successfully or not, so Develop scenarios
are not delayed. It only fills the existing shared shard cache; Develop reuses
exact passed shards through its unchanged digest/runtime checks and executes
the rest. The warmup never decides a gate, and a start or stop failure is only a
warning. Its duration and stop result are recorded in the same publication
checkpoint; no new state, lock, service or migration. Rollback removes the
warmup. The same change records one registered stand per publishing clone and
adds a publisher-to-real-Capture regression after a native lifecycle update.

On 2026-10-29 the user approved replacing the PM5 КОРП gate stand with a stand
built from a minimal repository configuration fixture for both Develop and
Release (`openspec/changes/minimal-gate-stand`). Measured publication was about
100 minutes, dominated by 1C operations whose cost follows configuration size
(674 MB of sources); no gate assertion depends on PM5 content. The accepted
support reduction is large-configuration coverage in gates; scenario and stage
assertions, timeouts and budgets stay unchanged, and configuration-dependent
expectations move into the stand configuration. One builder composes existing
owners (infobase creation, configured init, worktrees, Prepare/Capture); the
stand gets no lifecycle, state, lock or recovery of its own. Proofs never cross
stands, so the first qualification is cold. The PM5 stand remains for product
pilots outside gates; rollback points `-E2EProjectRoot` back to it.
The first stand publication exposed that a branch update's first ai_rules
claim on the OpenSpec scaffold file a master init left (EXPORT_PATH is empty on
master) was refused as a business change by both Capture and fork
continuation. The user approved one shared lifecycle rule: such a claim is the
update's only for the five scaffold paths and only when that hop's receipt
owns both states and its backup equals the old commit's blob.
The user then approved automatic stand selection so that every publisher
moves off the PM5 stand. Under the operation lock, Plan, DiagnoseFull and the
three publication actions resolve one stand per clone and fixture from a
derived path; no registry is stored. A missing stand is built once under a
per-stand file lock from published `origin/develop` with its baseline
capsules, and the builder's marker, written last, is the only completion
proof. A passed stand without the current fixture marker is replaced with a
warning, an exception to explicit-parameter precedence chosen by the user; a
failed build directory is refused with a removal continuation.
On 2026-10-30 the user approved closing two retention gaps that left about
60 GB behind. Recovery archives already had a policy (newest two per phase
within seven days) but ran only in manual Cleanup and were fully protected by
any open publication attempt, even a long-failed one. A successful PublishDevelop
now applies that same owner after closing its attempt, under its own operation
lease with the unchanged guards, and an open attempt protects only the archives
it references, like ledger resources and plan checkpoints; an unreadable
attempt still protects all. Each Release qualification registered its copy as a
permanent reusable stand, so no copy was ever archived; a copy whose capsule's
stand is no longer this clone's gate stand can never resume, so the sweep closes
that record and hands its snapshot and capability resources to their existing
removal adapters, after which the copy owner's ordinary retention applies.
Archives without an ownership proof stay for manual removal. No lock, state or
coordinator is added.
The Develop upgrade journey then showed that its configuration-rejection
refresh on PM5 resumed a merged refresh left by an older workflow whose refresh
ran the production Gate6 profile. The current refresh runs the development
profile and cannot produce that state, so the pending-refresh precondition was
legacy evidence: the production-check assertion no longer requires it, the
refusing-refresh assertion still does. Without it, the continuation refresh
synchronizes master from the in-project source infobase, which a fixture copy
did not carry. The user approved that Capture seals the closed `1Cv8.1CD` of a
file `SOURCE_INFOBASE_PATH` inside the seed project, refusing a busy file, and
Prepare places it at the mapped path inside the copy, with its bytes in the
space check; disposal removes it through the same exact-infobase guard. An
external or server source is never captured, and older capsules keep their
behaviour. No lock, state or coordinator is added.

On 2026-10-26 the user approved automatic E2E stand preparation in future
PublishDevelop operations. The existing publisher composes interrupted Release
recovery, the source-side update-workflow launcher and Capture admission before
freezing execution fingerprints. The reproducer was an expected 44-path package
update after plan freeze, followed by a ResumePlan mismatch despite an unchanged
candidate and scenario selection. Only the two capsule roots selected by the
checker's shared-master fixture closure are admitted for rollout; arbitrary
registered branches and read-only receipt references are not mutation roots.
The lifecycle transaction retains the exact root/source scope across post-copy
and recovery. Normal update-workflow still rolls out all development roots.
The same publication checkpoint records preparation and its owner logs; no new
coordinator, registry, lock family, service or machine prerequisite is added.
Update waits at most 3600 seconds, each Capture 900 seconds; interrupted Release
recovery retains its existing 7800-second allowance. Cancellation uses the
existing owned child/job cleanup. Retry continues the unplanned checkpoint and
the original lifecycle receipt; once a plan exists, unexpected drift still
requires the existing explicit Replan. Original capsules, databases and SHA,
business bytes, rollback snapshots, Windows/client/server support and all gates
remain with their owners. Native Unicode-path composition, durable scope retry,
ordinary full rollout and unexpected-drift regressions are the local canary;
live publication acceptance remains outstanding. Rollback stops the new
composition and retains all existing owner receipts for manual continuation.
The publication already running at approval time is outside this change.

On 2026-10-28 the user approved abandoning a failed uncommitted branch update.
Invariant: a defective candidate cannot lock a development branch, because the
update owner otherwise resumes the recorded post-copy with that same package.
The reproducer was a stand branch left in `post-copy-failed` by a deferred
candidate and restored by hand. The lifecycle update transaction owns
`-Recovery abandon -SnapshotId`: only a development-branch
`post-copy-running`/`post-copy-failed` receipt at its recorded HEAD and branch,
without owned staging, unmerged entries or a bound local patch. It reuses the
reconciliation scope and the atomic owned-path restore; every path must be the
recorded failed state or its saved before bytes, else reconciliation is required.
The candidate checkout is not consulted. The snapshot becomes
`itl-workflow-update-abandoned-<id>` evidence and a repeat is a no-op. Stand
preparation calls it before its update only for a selected branch whose pending
post-copy records another package base, and records the step in the same
publication checkpoint. Master, committed and rollback phases, business bytes,
completed-update chains, capsules, gates and lock families are unchanged; no
state migration. Rollback: an older publisher never calls the mode and the
owner's resume continuation still applies.

The existing database-access coordinator is the authoritative owner for exact
infobase admission across ROCTUP, Vanessa, lifecycle, measurement, and remote
operations. Calling it with an already supported access mode, resource set, and
recovery contract is normal composition. Adding an access mode, resource class,
persistent record, recovery adapter, automatic interception point, or action
against a foreign owner widens authority and requires the checkpoint. A local
call site must not copy admission policy, but similarity alone must not pull an
unrelated operation into this coordinator.

After two repair cycles that neither restore the original acceptance path nor
narrow the proven failure to a smaller owner, stop adding recovery layers.
Record the remaining blocker and compare rollback/removal, an owner-local
design, and a revised shared design. New evidence or real acceptance progress
continues the current cycle; a timeout alone is not an architecture failure.

The user approved controlled `client_mcp` metadata maintenance during the
upstream migration on 2026-10-01. The existing component delivery owner owns
its immutable CFE and complete corresponding-source ZIP. Its builder exports
the exact published v0.6.5 baseline, adds one name-bound adopted Language and
its ChildObjects declaration, and uses the existing per-infobase guard, Gate 6
and restoration duty in a private service base. Installation remains owned by
the existing Vanessa service/TestManager path; PM5 keeps VAExtension. No new
runtime state machine, adapter, admission mode, platform requirement or client
context is introduced. Publish optional supervisor support before requiring
owned client assets in a production lock. Live service to TestClient acceptance
and exact hashes remain required; build checks alone do not qualify delivery.

### Supported Windows and privilege boundary

Normal installed-workflow operation supports Windows 10, Windows 11, and
Windows Server 2019 or later, in local and terminal sessions, under a standard
user token. It must not require elevation, silently request it, write protected
machine state, or substitute weaker isolation while reporting equivalent safety.
The normal baseline is Windows PowerShell 5.1 plus the package-pinned runtimes;
newer PowerShell may invoke the Windows PowerShell boundary where the workflow
contract requires it.

Administrative host preparation is an optional, explicitly invoked capability.
Examples are enabling SSH, installing or configuring a service, changing a
firewall, and provisioning a shared machine directory or ACL. An unavailable
optional capability is reported as unavailable with its prerequisite and does
not invalidate unrelated local workflow operations.

Terminal-server support requires simultaneous standard-user sessions not to
collide through user-local paths, temporary files, credentials, ports, process
discovery, or cleanup. Cross-user coordination that genuinely needs shared state
must use an explicitly provisioned writable root or another proven
standard-user-safe mechanism. User-local fallback may be offered only with an
explicit weaker-isolation warning; it is not equivalent terminal-server proof.
Unknown or unavailable Windows stands remain unverified rather than silently
narrowing the support promise.

### Client context and token cost

Always-on installed instructions, generated command/skill prompts, workflow MCP
`tools/list` schemas, and routine status/result payloads are compatibility
budgets. Keep routers compact, load one relevant reference on demand, and prefer
script-owned orchestration plus bounded structured results over repeated prose.
Do not load full catalogs, lifecycle documentation, logs, or runtime state for a
request that does not need them.

Measure changed client-facing surfaces against a recorded baseline. Use real
client token counters when exposed; otherwise label serialized UTF-8 bytes and
`ceil(bytes/4)` as proxies, never exact token counts. A surface increase must be
attributable in the change and update its explicit budget with a rationale after
duplication and on-demand routing are considered. Source-only maintainer rules
are measured separately from installed-project context. Token optimization must
never weaken the task goal, safety, diagnostics, tests, database work, evidence,
or completion gates, and it must not add a model call or cumulative token ledger
merely to estimate savings.

### Rule changes under documentation budgets

Before editing a workflow rule, identify its authoritative owner and loading
boundary. Compare the old and proposed trigger, required or forbidden action,
exceptions, precedence, and failure or result state. Record intended semantic
changes in the change description; preserve the other parts of the contract.
Keep rules that must apply to every task in an always-on surface. Move only
situational detail to a reference that the relevant route actually opens.

A documentation review threshold is a signal to inspect context cost, not an
instruction to shorten text. First remove proven duplication or route detail on
demand. If complete meaning still exceeds a hard limit, update that file's
budget in the same change with a short rationale and a measured before/after
delta. Measure source-only rules separately from installed client surfaces.
Text or marker assertions protect selected anchors but do not prove semantic
equivalence; use a focused behavioral contract when the rule governs a
verifiable safety or completion path. Do not add tests that only repeat prose.

External Pester runtime witnesses are stateless inputs owned by the existing
shard scheduler/worker contract (`pester-external-runtime.ps1`). A per-file adapter
observes before/after bytes without changing the ordinary worker or installing
runtimes. Failure to observe identity disables cache admission only; original
execution, errors and assertions remain authoritative. No shared environment
manager, persistent runtime registry, lifecycle lease or installed migration is
introduced. Source host tests retain their checkout-local environment owner.

## Runtime check blocking policy

The workflow exists to complete users' project tasks. Every new barrier ships
with a practical agent-owned continuation: satisfy the requirement, recover
through its owner, or propose a concrete, user-authorized local exception.
Acceptance exercises the original task through that continuation, not just the
rejection. Block only the dependent operation; preserve completed work and let
independent work continue. A diagnostic must not create retroactive product work
or force valid project data to accommodate a defective validator.

Keep publication incremental and resumable using existing evidence and budgets.
For changes on frequent paths, compare representative before/after duration and
context size; explain material increases. Use existing measurements, not a new
always-on collector. An auxiliary cleanup failure after a proven installation
does not roll back that installation. Cancellation and safe discard have their
own prerequisites and must not require successful acceptance of unwanted work.

A runtime check may block only when continuing can lose data, mutate the wrong target, violate an explicit safety boundary, or produce false success or verification evidence. Every other diagnostic discrepancy is `WARN`, not `FAIL`.

Test classification is an executable-verification prerequisite, not a runtime
diagnostic. A normal check stops before launching 1C when Vanessa or YAxUnit
tests cannot be mapped to their declared cadence and production owners; silently
substituting the complete test inventory would misrepresent the intended
verification scope and consume an unbounded runner budget. Refresh only
inventories this contract and returns agent-owned continuation work, because the
helper cannot infer semantic ownership safely.

The YAxUnit production applicability check blocks only when a post-adoption,
branch-owned BSL change has no exact decision. Without that check, the normal
`not-applicable` result for an absent test extension could falsely present a
new, unit-testable product change as covered. A pre-adoption branch baseline
preserves previous coverage status; it is recorded as legacy rather than
creating retroactive test work. Classification may reuse an existing test group
or record a justified exact-content non-applicability decision; it does not
require one new test for every changed module.

Proven accepted-master input is a distinct selection case: unchanged imported
CF/CFE paths select complete existing acceptance coverage with recorded Git
provenance. They do not require invented tests or owner declarations. Own unknown
changes and invalid catalogs retain classification requirements; see
`.agents/skills/1c-workflow/references/verification-suite-selection.md`.

Keep integrity checks with their owning component. ITL may duplicate one only after a reproduced cross-boundary failure proves that the owner's check cannot protect the ITL operation.

Capability checks use only the minimum prerequisites needed to perform the operation. File identity, update safety, and exact-result verification are separate contracts; integrity does not participate in capability detection unless exact identity is itself required for execution.

### Local workflow incident contract

Refresh reporting keeps its optional load/Enterprise projection in the existing
worktree-local verification-selection runtime. Classification uses that projection
only to render the final report; it grants no verification, lifecycle or recovery
authority. Missing report context warns and preserves the successful operation.
MCP observation and continuation remain per server and within existing client and
runtime owners; no host-repair authority or persistent availability coordinator is
added. See `.agents/skills/1c-workflow/references/mcp.md` for the on-demand recovery
contract and client reload limitations.

Architecture checkpoint approved on 2026-10-22: development recovery may close
unneeded workflow-owned MCP processes automatically, across versions and chat
lifetimes. The facade remains the owner of retained signed execution cleanup.
A per-facade mailbox asks that owner to stop; it contains no admission secrets
or independent state machine. Same-resource guard waiting can invoke the
existing private broker to retire an obsolete exact-project connection that
predates mailbox support. That adapter verifies the configured caller, helper,
executable, creation identity, supervisor and full resource set, performs exact
native cleanup before guard release, and retains unknown prior outcomes as
diagnostic evidence. Active preparation, current facade processes, other
projects/contours/resources and unproven process identities remain untouched.
Waiting and cleanup inherit the original call deadline; each peer cleanup has
a one-minute ceiling. No new global coordinator, client-wide restart, elevation,
platform requirement or always-on client rule is added. Normal calls incur no
peer lookup unless resource admission actually waits. The cross-process canary
requires a new chat's original read to finish after retained owner cleanup for
both backend families, without replaying an applied mutation. A rollback removes
the recovery adapter and mailbox and retains the existing same-connection
recovery path; descriptors/receipts never replace OS guard authority. Unknown
outcomes require agent-owned readback/reconciliation, not a blanket approval.

Retained cleanup classifies registered warm peers without taking authority over
them. The existing native ownership, listener and immutable lease checks prove
each peer against a re-read project-local registration; unknown or ambiguous
same-base sessions still retain the original execution. This is owner-local
classification, with no peer stop, new coordinator, state migration or admission
mode. Same-connection recovery consumes the original request-phase budget,
including cold protocol readiness, rather than imposing a separate minute.
Per-phase elapsed/remaining timing and broker cancellation diagnostics are
bounded and contain no connection secrets. Source regression uses both families
with real isolated processes/listeners and the existing OS execution guard;
session discovery and port reservations are private fixtures, not live 1C proof.

Architecture checkpoint: the user authorized this continuation design and its
simplification on 2026-09-26. The existing update/refresh owner retains all
lifecycle, Git, database and rollback authority. One worktree-local patch receipt
records only ITL-owned files before/after a user-authorized temporary edit and a
report location. It is not an authorization registry, coordinator, general gate
override or evidence of a successful check. User messages supply authorization;
the agent records its exact scope in the report. General ai_rules_1c content,
product sources, secrets, runtime state and unrelated edits remain outside this
mechanism. Report writing does not depend on a generator.

Capture and sealing are explicit file-only actions. Only update/refresh consume
the receipt; normal commands do not inspect patch history. The owner validates
the actual project, branch, recorded bytes and Git state before replacing files.
Additional edits are preserved and reported for agent reconciliation. Retirement
of a committed patch is an ordinary corrective commit, never history rewriting.
Reports and byte snapshots survive replacement; replacement is not proof that
the original incident is fixed. Do not require replaying an expensive or
unavailable original scenario to update the workflow.

Second-part checkpoint: the user approved the shared-archive and conditional
retirement plan on 2026-09-26. A user's `%LOCALAPPDATA%/ITL/workflow-fixes` stores
reusable fix records for that user's projects; it has no runtime, permission or
cross-project recovery authority. The existing local-patch helper owns this
optional file cache, atomic writes and bounded cleanup. No service, global lock,
project inventory, elevation, new client surface or always-on archive scan is
introduced. Active receipts and rollback bytes remain worktree-local. Archive
failures warn and retain local evidence without blocking project work.

Refresh selects its exact incoming master commit before deciding retirement.
Only a proven workflow-package change retires a patch; configuration-only and
repeated same-version refresh retain it. Legacy receipts recover provenance from
their saved commit where possible; uncertainty preserves the patch. A repeated
same-version package update with an active patch skips copying instead of
overwriting that patch. The existing merge/copy transaction still owns recovery.

Archive records are candidates for agent review, never executable instructions
or transferable authorization. Store exact diffs and a report, deduplicate exact
records, and expire unused entries after 90 days with caps of 100 entries and
100 MiB. Access does not count as use. Cleanup only removes cache copies; active
patches, pending rollback and user handoffs are protected. One project's upgrade
does not prove a fix obsolete for other versions. Acceptance covers config-only
refresh, actual replacement, reapplication in another project, concurrent writes
and unavailable/expired cache. Rollback can stop consulting the cache; local
receipt schema 1 remains readable and no installed-wide migration is needed.

Refresh starts in the clean main-worktree runtime and later continues in the
branch runtime. A patch of the wrong copy is not a repair; any required change
to the shared runtime needs authorization covering that scope. No arbitrary
runtime-source switch or automatic patch reapplication is introduced. See the
installed [incident procedure](../.agents/skills/1c-workflow/references/workflow-incidents.md).

## 1C source byte-preservation policy

Git is transport for platform-generated `src/cf/**`, `src/cfe/**`, and optional auxiliary `src/configs/**` files, not their line-ending formatter. Installed projects carry a managed `.gitattributes` block with `-text` for these trees, so checkout, worktree creation, branch transfer, and result assembly preserve the bytes emitted by 1C even when global `core.autocrlf=true`.

The contract is activated only by `init-project` or an authoritative `sync-master`. The same commit rebuilds the configuration and extension indexes from the physical source trees. When an existing development branch first merges such a master, the transition merge ignores end-of-line whitespace only for that merge and immediately rebuilds both source indexes under `-text`; later merges remain strict. Do not apply the attributes alone during `update-workflow`, normalize all repository files globally, or use content hashes to compensate for transport mutation.

Before a workflow-owned checkpoint, configuration load, repository transfer plan, or completion of a merge, ITL inspects only the changed `.bsl` and `.xml` paths already reported by Git. If the corresponding local `master` blob uses one homogeneous line-ending style, ITL restores that style automatically without changing file content. New files, binary data, `ConfigDumpInfo.xml`, and references with mixed or ambiguous line endings are skipped; this repair does not block the operation or request user action.

Semantic source-integrity starts from that same changed-path set. A changed
`Templates/<Name>.xml` descriptor or `Templates/<Name>/Ext/Template.xml`
payload expands only to its exact owning metadata object, descriptor, and XML
payload. It never enumerates or validates every template or every configuration
file merely because one aggregate changed.

Managed source-only maintenance references:

- `local-quality-gate.md` — local Fast/Full checks;
- `ai-rules-fork-upgrades.md` — controlled-fork intake and migration;
- `release-checklist.md` — release-only 1C validation.
