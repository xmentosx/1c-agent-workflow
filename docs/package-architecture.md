# Workflow package architecture

This source-only document describes the package layout for maintainers. It is not copied into initialized projects.

- `.agents/skills/1c-workflow` owns the full lifecycle router, references, helper scripts, and generated client templates.
- `.agents/skills/1c-workflow-fast` owns the compact routine-operation surface.
- `.agents/skills/product-docs`, `itl-roctup-1c-data`, and `itl-vanessa-ui-mcp` own optional product/runtime integrations.
- `itl-remote-runner`, `itl-remote-agent`, and `itl-performance` share a portable Python job/measurement runtime. A user-started worker normally uses an outbound pull control channel; an optional shared folder accelerates only immutable hash-addressed blobs, while preconfigured SSH/exchange remain compatibility adapters. Runner, agent policy and transport are independent. The same worker queue can also own explicitly authorized host-command jobs under the interactive Windows user; those jobs reuse pull transfer, claim/state/cancel/result IDs and owned process cleanup, and never acquire or bypass a declared 1C target guard on behalf of arbitrary code. The pairing token is therefore a broad user-account credential when host commands are enabled. One launcher staged through an explicitly trusted transfer folder performs first installation and writes status there; the folder never carries mutable job control. Compatible worker updates install into verified user-local generations and switch only while idle under a rollback-capable supervisor; the user-started supervisor renews bounded generations while its window remains open. The portable bundle includes the existing 1C process/session guard modules; it does not install the full lifecycle or require administrator rights. Remote worker startup remains an explicit user action. See [remote operation contracts](../.agents/skills/itl-remote-runner/references/operations.md) and [measurement recipes](../.agents/skills/itl-performance/references/measurements.md).
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

The controlled `ai_rules_1c` fork owns general rules, the common OpenSpec workspace, upstream-native OpenSpec bundles, agents, and its installer manifest. ITL owns bootstrap, lifecycle, local MCP configuration, executable verification, result export, the managed ITL skills, and host UX for the `native`/`natural`/`unavailable` OpenSpec states. ITL does not generate client bundles, install `@fission-ai/openspec`, or run `openspec update`. See `ai-rules-fork-upgrades.md` for the release boundary.

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

## Runtime check blocking policy

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
