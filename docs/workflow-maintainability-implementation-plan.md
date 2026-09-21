# Workflow maintainability and compatibility implementation plan

Status: implementation authorized by the user on 2026-09-22; evidence is kept
in `workflow-maintainability-evidence.md`
Reviewed baseline: local `develop` and `origin/develop` at
`7bccc2691833ff12b2d10e53e8ad959682c4dd3a` (2026-09-21)
Delivery boundary: implement all named waves and use normal `RegisterChange`;
publication, installation, promotion, and release remain unauthorized

## Problem and intended outcome

The workflow needs enough architectural freedom to consolidate real shared
invariants, replace duplicated policy, and implement durable cross-process
safety. It must not turn every local requirement into another workflow-wide
coordinator, persistent state machine, blocking prerequisite, or recovery layer.

The durable outcome is a proportional decision model:

- normal architectural work remains autonomous;
- one invariant has one authoritative owner, even when it has many callers;
- shared stateless contracts are preferred before shared runtime authority;
- only high-blast-radius authority changes require an explicit user decision;
- supported Windows, non-elevated operation, terminal sessions, and client
  context cost are permanent compatibility constraints;
- repeated repair without acceptance progress causes redesign, not another
  layer of recovery.

## Scope

This plan covers source-maintainer guidance, package architecture guidance,
public support documentation, and small regression contracts for those rules.
It also defines bounded evidence audits for platform and client-context cost.

It does not by itself redesign or remove the existing database admission,
native recovery, on-demand MCP, lifecycle, delivery, port registry, or source
mode implementations. A concrete defect found by an audit becomes a separate
owner-local change with its own acceptance criteria.

## Non-goals

- Do not require an ADR, architecture manifest, approval file, or new workflow
  command for ordinary development.
- Do not classify architecture by changed-file count or component count.
- Do not prohibit cross-component refactoring, shared helpers, or a justified
  stateful coordinator.
- Do not force a local implementation when several callers share one semantic
  invariant.
- Do not retrospectively fail or rewrite the current recovery architecture
  solely because it predates these rules.
- Do not make every commit run a real Windows-version or terminal-server matrix.
- Do not optimize token use by weakening safety, correctness, diagnostics,
  evidence, or acceptance.
- Do not copy the source-only root `AGENTS.md` into installed projects.

## Decision model

### Normal architecture work

The agent may proceed without a separate architecture approval when it:

- moves one invariant to its existing or newly identified authoritative owner;
- replaces duplicated policy with one shared implementation;
- introduces or extends a stateless shared contract;
- refactors callers across several modules while preserving the same runtime
  authority, persistence, blocking, recovery, and support boundaries;
- consumes an existing coordinator through its documented contract without
  widening that coordinator's semantics or resource ownership;
- reduces complexity or replaces an existing mechanism without a new installed
  migration or rollback risk.

The agent still explains the selected owner and verifies every affected caller,
but no extra process artifact is required.

### Architecture checkpoint

Before implementation, stop and obtain explicit user approval when a proposal
introduces or widens any of the following:

- a machine-wide or workflow-wide coordinator, queue, lock, or persistent state;
- blocking, cancellation, cleanup, or recovery authority across independent
  runtime owners;
- an installed-state migration whose rollback needs compatibility handling;
- interception of lifecycle, update, verification, or delivery operations that
  were previously independent;
- an elevation requirement, Windows service or firewall change, machine-wide
  ACL, or other administrative prerequisite for normal operation;
- a reduction of the supported Windows or terminal-session contract;
- a material increase in always-on client instructions, tool schemas, or
  routine output that cannot be routed on demand.

The checkpoint is a short proposal in the active task or an already requested
implementation plan, not a mandatory new file. It contains:

1. the behavioral invariant and proposed authoritative owner;
2. a minimal cross-boundary reproducer when shared runtime authority is claimed;
3. owner-local and stateless alternatives and why they are insufficient;
4. affected and explicitly unaffected owners, operations, resources, clients,
   supported platforms, and installed state;
5. the one authoritative state machine and confirmation that no shadow
   coordinator is added;
6. bounded waiting/status/completion/cancellation/recovery behavior;
7. compatibility, client-context, canary, and rollback effects;
8. the original acceptance path that will decide whether the architecture works.

One approval covers implementation inside the stated boundary. A newly affected
owner, resource class, administrative prerequisite, or installed migration is a
scope change and requires a renewed decision; ordinary implementation detail
does not.

### Repair stop rule

A repair cycle is a coherent implementation attempt followed by evaluation
against the same original acceptance path. Individual commits, fixture repairs,
or newly collected evidence are not automatically separate cycles.

After two cycles that neither restore the acceptance path nor reduce the proven
failure to a narrower owner, stop adding layers. Record the remaining blocker
and compare rollback/removal, an owner-local design, and a revised shared design.
This rule does not force removal when evidence is progressing, and it does not
turn a gate timeout into an architecture failure.

## Platform compatibility contract

Normal installed-workflow operation must run as a standard user without
elevation in local and terminal sessions on:

- Windows 10;
- Windows 11;
- Windows Server 2019 and later supported Windows Server releases.

Administrative host provisioning is allowed only as an optional, explicitly
invoked capability. Examples include enabling an SSH service, changing a
firewall, installing a machine service, or preparing a machine-wide writable
directory/ACL. Normal commands must never auto-elevate, mutate those facilities
implicitly, or claim equivalent multi-user isolation after falling back to a
weaker scope.

The implementation must document the oldest supported build/PowerShell/API
baseline after inventorying the APIs actually used. The family support above is
fixed; the inventory may not silently exclude one of those families.

Terminal-server support means that simultaneous standard-user sessions do not
collide through user-local paths, ports, process discovery, temporary files, or
credentials. When exact cross-user coordination is required, use an explicitly
provisioned shared writable root or another proven standard-user-safe mechanism;
do not assume that an arbitrary machine-wide directory is writable.

## Client context and token-cost contract

Treat always-on client instructions, generated command surfaces, MCP tool
schemas, and routine status/result output as compatibility budgets.

- Keep always-on routers compact and route detail to one relevant on-demand
  reference.
- Do not load full catalogs, lifecycle documentation, logs, or runtime state for
  a request that does not need them.
- Prefer script-owned orchestration and bounded structured results over repeated
  agent prose.
- Measure a changed client-facing surface against a recorded baseline; do not
  invent a percentage-saving target before a baseline exists.
- Use real client token counters where exposed. Otherwise record serialized UTF-8
  bytes/approximate tokens as a clearly labelled proxy.
- A necessary safety or compatibility contract may exceed a previous budget only
  after true duplication and on-demand routing have been considered. Update the
  budget explicitly with its rationale; do not telegraphically compress meaning.
- Token reduction never takes priority over the task goal, correctness, safety,
  actionable diagnostics, or required acceptance.

## Implementation waves

The waves are separate delivery boundaries. One explicit user approval may
cover several named waves, but Wave A alone does not implicitly authorize the
platform inventory or token baseline, and an evidence audit does not authorize
repairing every finding in the same change. Do not execute this plan as one
repository-wide refactor.

### Wave A — source-maintainer governance

#### GOV-01 — root architecture rule and bounded budget increase

Change the root `AGENTS.md` to state:

- optimize for the simplest coherent architecture, not the smallest diff or the
  fewest abstractions;
- one invariant has one authoritative owner and duplicated policy converges;
- shared stateless contracts and cross-component refactoring are normal work;
- only the architecture-checkpoint triggers above require explicit approval;
- two repair cycles without acceptance progress trigger redesign rather than
  additional layers.

Consolidate the existing `Context budget` wording instead of merely appending
new prose. Increase only the root source-maintainer budget in
`ParserDocsBudgets.Tests.ps1`:

```text
maxWords:          1150 -> 1250
reviewApproxTokens: 2000 -> 2200
maxApproxTokens:    2200 -> 2450
```

Keep the installed `templates/USER-RULES.append.md` budget unchanged. The root
file remains source-only and must not enter installed client context.

Acceptance:

- the root rule distinguishes normal shared architecture from authority
  escalation;
- it does not require approval merely because several modules/files change;
- existing delivery, safety, non-ASCII path, and byte-preservation contracts
  remain intact;
- the final root file stays within the revised limits;
- bootstrap/update tests still prove the root file is not copied to projects.

#### GOV-02 — package scope-expansion policy

Add the detailed decision model from this plan to
`docs/package-architecture.md`, close to the existing runtime blocking policy.
Define `runtime owner`, `authoritative owner`, `stateless contract`, `runtime
authority`, and `repair cycle` narrowly enough that an agent can classify a
proposal without a new registry.

Clarify these two boundaries explicitly:

- using the existing database-access coordinator without changing its contract
  is normal composition;
- adding a new access mode, resource class, persistent record, recovery adapter,
  automatic interception point, or foreign-owner action widens authority and
  invokes the architecture checkpoint.

Acceptance:

- one call-site-local fix cannot duplicate an already owned invariant;
- one superficial similarity cannot force unlike operations into a common
  coordinator;
- existing coordinators can be reused without ceremonial approval;
- authority expansion cannot be hidden as a helper refactor or recovery fix;
- no new command, state file, manifest, or automated approval detector exists.

#### GOV-03 — narrow regression contract

Extend the existing `ParserDocsBudgets.Tests.ps1` contract rather than adding a
new test framework. Assert stable concepts, not the entire English paragraph:

- `simplest coherent architecture`;
- one authoritative owner / no duplicated policy;
- explicit approval for new shared runtime authority;
- Windows/non-elevation support routing;
- client-context/token budget routing;
- revised root budget and unchanged installed-rule budget.

Do not encode a list of implementation file paths as the architecture policy.

### Wave B — platform contract and evidence

#### PLAT-01 — publish the support boundary

Add one compact source-maintainer rule to root `AGENTS.md`, detailed engineering
constraints to `docs/package-architecture.md`, and the user-facing support matrix
to `AGENT-INSTALL.md`.

The public documentation must distinguish normal standard-user operation from
optional administrative provisioning. It must state how unsupported optional
capabilities are reported without invalidating unrelated workflow operations.

Acceptance:

- Windows 10, Windows 11, and Windows Server 2019+ are named explicitly;
- local and terminal sessions are in scope;
- normal operation requires no elevation;
- services/firewall/machine ACL changes are opt-in provisioning;
- no silent elevation or unsafe fallback is permitted.

#### PLAT-02 — current implementation audit

Perform a bounded inventory, without changing behavior, of:

- writes below `%LOCALAPPDATA%`, `%APPDATA%`, `%TEMP%`, `%ProgramData%`, program
  directories, registry hives, services, firewall, scheduled tasks, and shared
  runtime roots;
- OS/version-specific native APIs and PowerShell edition/version assumptions;
- process discovery and cleanup across simultaneous terminal sessions;
- machine/user port-registry selection and the permissions expected from
  `ITL_PORT_REGISTRY_HOME`;
- installation, init/update/refresh, on-demand MCP, verification, remote worker,
  and source-delivery entrypoints.

Classify every finding as:

1. ordinary non-elevated path already compliant;
2. optional admin provisioning already isolated;
3. unsupported-but-truthfully-reported optional capability;
4. concrete compatibility defect requiring a separate owner-local change;
5. unresolved evidence gap requiring a disposable real-host check.

Do not turn the audit into a bulk compatibility rewrite. Each category-4 defect
gets its own reproducer, owner, affected platform, and acceptance criterion.

#### PLAT-03 — proportional compatibility proof

Add focused automated contracts for code that changes platform-sensitive
behavior. Retain Windows PowerShell 5.1 parsing/encoding checks, but do not treat
them as complete OS proof.

At release qualification, retain real evidence for:

- one standard-user Windows 10 path;
- one standard-user Windows 11 path;
- one standard-user Windows Server 2019 terminal-session path;
- two simultaneous standard-user terminal sessions when shared port/runtime
  coordination changed;
- explicit optional admin provisioning only when that capability changed.

An ordinary documentation or owner-local algorithm change does not rerun this
matrix. Unknown or unavailable stands are reported as unverified; support is not
silently narrowed.

### Wave C — client-context cost

#### CTX-01 — inventory and baseline client-facing surfaces

Build a read-only baseline from existing package artifacts rather than adding a
new runtime service. Inventory:

- always-on installed rules and routers per supported client;
- generated command/skill prompt bytes;
- workflow-owned MCP `tools/list` schema count and serialized size;
- routine `status`, blocker, recovery, and result payload sizes;
- which detailed references are loaded only on demand;
- real context/token counters from the existing Kilo benchmark where available.

For clients without token counters, store or report static byte/approximate-token
measurements as a proxy. Separate source-only root cost from installed-project
cost so increasing the root maintainer budget is not misreported as a customer
runtime regression.

Acceptance:

- every metric names the artifact/client and measurement method;
- no arbitrary global percentage target is introduced;
- secrets, transcript content, URLs, and tool arguments are not captured;
- the baseline can be recomputed without launching 1C;
- the audit identifies duplicated always-on content and on-demand routing
  opportunities without deleting safety meaning.

#### CTX-02 — incremental regression policy

Extend existing documentation budgets and context-benchmark reporting only where
the CTX-01 baseline proves a stable owner and measurement. A change that modifies
an always-on surface reports its before/after delta and explains any increase.

Prefer existing `ParserDocsBudgets` and `context-benchmark` mechanisms. Do not
introduce a cumulative per-task token ledger, mandatory model call, or gate that
spends tokens merely to estimate token savings.

Acceptance:

- ordinary source code changes with no client-surface delta incur no new step;
- client-surface growth is visible and attributable;
- necessary safety text can update a budget explicitly;
- token optimization cannot skip required tests, database work, or completion
  gates.

### Wave D — scenario validation and adoption

#### VAL-01 — decision-table regression review

Before registering the governance change, review the policy against at least
these scenarios:

1. two local tasks use one remote infobase through the same remote owner;
2. ROCTUP, Vanessa, lifecycle, and measurement independently contend for one
   exact infobase;
3. several callers need the same quoting/path-normalization invariant;
4. on-demand source mode consumes the existing database coordinator;
5. a recovery change adds a new persisted resource or action;
6. a bounded fix changes only timeout/cancellation inside existing authority;
7. terminal-server users require exact shared port coordination;
8. a client adds a large always-on tool catalog or repeated status prose.

For each scenario record `normal architecture work` or `architecture checkpoint`
and the reason. The expected classifications are captured in the freshness
review below.

#### VAL-02 — focused verification and delivery

For the eventual governance/documentation implementation:

- run the focused `ParserDocsBudgets.Tests.ps1` owner contract and any directly
  changed bootstrap/public-doc contract;
- confirm tracked state is unchanged by tests;
- keep implementation and evidence separate from this plan document;
- create one coherent commit and use the normal `RegisterChange` path;
- do not publish `develop`, promote, or release without separate authorization.

Platform or runtime fixes discovered by Wave B are separate changes with their
own owner tests and coverage contracts. Registration of the governance change
must not absorb an unreviewed compatibility rewrite.

## Freshness review against current develop

This section is the required second-pass review of the proposed tasks against
the current baseline, not a claim based on the pre-stabilization architecture.

### Recent recovery and admission work

Current `develop` already contains:

- `c964d41d` — self-healing database-access recovery and dispatch;
- `3269fdcc` — rebuildable resource classification and workflow scope binding;
- `aa3fe28f` — interrupted native verification recovery;
- `0bd09c3c` — develop-publication recovery integration;
- `128546a6` — lifecycle wait polling hardening;
- `7bccc269` — bounded on-demand recovery execution, owned process lifetime,
  cancellation, retained logs, and classified non-retryable workflow defects.

The current database-access contract already has one coordinator, exact resource
sets, operation-specific recovery adapters, no force unlock, foreign-owner
protection, and bounded trusted self-healing. Therefore:

- GOV-02 must treat this coordinator as the current authoritative baseline, not
  require its replacement or reapproval;
- future new resource classes, persisted recovery contracts, access modes, or
  interception points trigger the checkpoint because they widen authority;
- a bounded timeout/cancellation/logging fix such as `7bccc269` remains normal
  owner work when it does not widen that authority;
- a new recovery subsystem comparable in scope to the September additions would
  require the checkpoint before implementation under the new rule;
- the repair stop rule is prospective and cannot be used to erase retained
  recovery evidence or force-unlock current owners.

This makes GOV-01/GOV-02 applicable to the fresh implementation rather than a
generic objection to stateful recovery.

### Current on-demand source mode plan

`docs/on-demand-source-mode-implementation-plan.md` explicitly reuses the
existing database-access coordinator, forbids a second ad-hoc lock, holds source
admission only for source capture, and releases it before independent branch
work. Under the proposed policy this is normal architectural composition, not an
automatic checkpoint.

The checkpoint would be required only if implementation adds a new coordinator,
widens database admission with a new persistent resource/mode/recovery authority,
or makes unrelated lifecycle operations depend on the new mode. This confirms
that the governance rule does not prevent a coherent cross-component design.

### Platform tasks

The source already uses user-local immutable caches and documents remote Python
preparation without administrator rights. SSH enablement is explicitly admin
only. It also has machine/user port-registry scopes and terminal-server-specific
diagnostics. These are useful implementation pieces, but no root rule or public
support matrix currently makes them a complete Windows/non-elevation contract.

PLAT-01 and PLAT-02 therefore close a real governance/evidence gap. PLAT-02 is an
audit first because changing machine-scope port behavior without reproducing the
permissions and cross-user requirement could repeat the same over-expansion
problem this plan is intended to prevent.

### Client-context tasks

The repository already has documentation budgets, compact routers, an on-demand
reference model, bounded output, a Kilo context benchmark, and a warning for the
hidden Browser Automation MCP surface. CTX-01 does not replace them. It closes
the remaining gap between per-file documentation budgets and total installed
client-facing cost across rules, commands, tool schemas, and routine output.

Keeping `templates/USER-RULES.append.md` at its existing limit and separating the
source-only root measurement prevents the allowed root budget increase from
raising installed customer context. CTX-02 is conditional on a stable baseline,
so it does not create speculative flow-budget machinery.

### Adequacy verdict

The tasks remain applicable to current `develop` with these constraints:

- governance is prospective; it does not reopen completed recovery design by
  default;
- existing coordinator reuse is explicitly allowed;
- only authority expansion, platform-contract change, installed migration, or
  material always-on context growth needs the checkpoint;
- the Windows and token waves begin with evidence audits, not bulk rewrites;
- real compatibility matrices belong to release qualification, not every edit;
- the root budget increase is bounded and source-only;
- no new runtime mechanism is introduced merely to enforce the rules.

The required scenario classification on the reviewed baseline is:

| Scenario | Classification | Reason |
|---|---|---|
| Two local tasks use one remote infobase through the same remote owner | Normal architecture work | The existing owner may serialize its exact resource without creating workflow-wide authority. |
| ROCTUP, Vanessa, lifecycle, and measurement contend for one exact infobase | Normal when reusing current admission; checkpoint when its modes/resources/recovery expand | Current database admission is already the authoritative cross-owner contract. |
| Several callers need the same quoting or path-normalization invariant | Normal architecture work | Converge on one stateless helper; do not copy policy. |
| On-demand source mode uses existing database admission | Normal architecture work | The fresh plan explicitly forbids a second lock and releases admission before independent branch work. |
| Recovery adds a persisted resource class, action, adapter, or interception point | Architecture checkpoint | It widens durable cross-owner recovery authority. |
| A fix bounds timeout, cancellation, logs, or error classification inside existing recovery authority | Normal architecture work | It narrows behavior without adding an owner or persistent contract. |
| Terminal-server users need shared port coordination | Normal when extending the existing registry without new privilege; checkpoint for machine ACL/service/elevation or weaker isolation | The registry is the existing owner, but platform and privilege boundaries are compatibility decisions. |
| A client adds a large always-on tool catalog or repeated routine prose | Architecture checkpoint when the growth is material and cannot be routed on demand | It changes the installed client-context compatibility budget; an on-demand surface remains normal work. |

No task in this plan currently requires implementation outside the named source
documentation/tests until Wave B or CTX-01 produces a concrete, separately
approved defect or regression.

## Completion criteria

The implementation is complete only when:

- root and package rules preserve architectural freedom while defining the
  narrow high-impact checkpoint;
- duplicate local policy and premature global authority are both prohibited;
- Windows/non-admin/terminal support is explicit, public, and testable;
- client-context cost has a measured baseline and proportional regression rule;
- the root budget increase remains bounded and does not affect installed rules;
- scenario validation matches the current recovery and on-demand source designs;
- focused contracts pass, tracked state stays clean, and the coherent change is
  registered without publication.
