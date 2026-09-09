# Recovery of an interrupted measurement

Recovery belongs to the original execution host and immutable job package.
It keeps the original result, resources and permissions. It may stop owned work
and restore state, but never executes the measured action again or turns a failed
measurement into a passed one. Older jobs without the original owner/input
binding or an authored recovery adapter remain `needs-attention`; do not edit
their package or coordinator record to make them eligible.

## Commands

On the original execution host, run:

```text
remote_work.py recovery-plan --spool <spool> --id <job>
remote_work.py recover --spool <spool> --id <job> --plan-id <returned-plan-id>
remote_work.py recovery-cancel --spool <spool> --id <job> --plan-id <plan-id>
```

The first command records a reviewable plan without calling scenario hooks or
changing the database. Execution revalidates its revision, the original request,
target and packaged files, then claims the complete original resource set.
Changed inputs, a live owner or an obsolete plan cannot start restoration.
Cancellation belongs to that plan, separately from the original job's cancel
request. After a cancelled/failed attempt, inspect again to obtain a fresh plan.

Through SSH or an exchange connection use `remote --connection <profile>
--action recovery-plan|recover|recovery-cancel --id <job>` and `--plan-id` for
the latter two actions. Remote `recover` only queues the pinned plan; the worker
on the execution host performs it. It does not hold an SSH request open for the
duration of restoration. The local CLI can execute the same plan directly when
the authorized remote-agent route owns execution. Duplicate delivery preserves
one request; a recorded failure is not retried automatically.

Job status has a separate `recovery` object. Detailed phases, observations and
logs are retained under `runs/<job>/recovery/<attempt>/`; private `context.json`
is excluded from transfer. The original result remains unchanged. If no original
`result.json` exists, add `--allow-partial` to local `collect` or remote
`--action collect` to download the available diagnostics and recovery artifacts.
The returned collection manifest explicitly records a partial collection and
the observed job state. It is neither a measurement result nor authorization
to release database access. See `operations.md` for concurrent log changes and
transfer integrity. Do not invent a successful measurement result to enable transfer.

## Authored scenario contract

The optional `scenario.recovery` object has `schemaVersion: 1`, required
`inspect` argv, optional `quiesce` and `restore` argv, and explicit `operations`
(a list containing only needed `write-data`/`update` permissions, possibly empty).
Those operations must already be authorized by both original request and target.
Quiesce/restore hooks additionally require `repeatableActions: true`: their author
must make interrupted/repeated execution safe by inspecting persistent state.
This declaration is an adapter contract, not proof supplied by the coordinator.

Use the original package's `files` for hook dependencies. Substitutions are
`{python}`, `{runtime}`, `{workspace}`, `{input}`, `{run}` (original run),
`{context}` (new private context) and `{recovery}` (new step directory).
Parameters remain in JSON. All workflow-owned 1C launches still use the shared
per-infobase guard. The context carries a recovery-only lease; explicitly nested
recovery code uses `Lease(..., inherited=proof, purpose="recovery")`. Ordinary
measurement inheritance rejects that token. Hooks must not overwrite old run
artifacts, replay business actions, or stop foreign processes.

The runtime executes `inspect`; if owned work is not proven stopped, it invokes
`quiesce` when provided, then inspects again. Restoration cannot start until all
resources have stopped owned work. If restoration is required or unknown, it
invokes `restore` when provided, then performs a final fresh inspection. All
steps share one cleanup-phase deadline. A nonzero exit, missing observation,
cancel, timeout or unresolved resource retains database exclusion.

Each inspection writes JSON to `context.recovery.output` with:

- `schemaVersion: 1`, original `jobId`, current `attemptId` and `observationId`
  from the recovery context (never values copied from an earlier inspection).
- `resources`: exactly one entry per `context.recovery.resources` ID.
- Each entry: `resourceId`, `ownedWork` (`stopped`, `running`, `unknown`),
  `restoration` (`complete`, `required`, `unknown`), a nonempty `explanation`,
  and nonempty `artifacts` with step-relative `path` and exact `sha256`.

Inspection must query actual processes, unfinished database work and required
restoration, retaining those observations as artifacts. A free OS owner lock,
successful hook exit, or hand-written `passed: true` is insufficient. For server
databases, checking only the local client PID does not prove server work stopped.
Unknown work cannot be called stopped, and no restoration duty requires an
explanation based on the original operation, not an empty check list.

After a recovery crash, the next attempt inspects current state first. It can
skip a restoration already proven complete without repeating it. If release was
durable but publishing job status failed, repeating the same plan reconciles that
status without running hooks. Live 1C/Vanessa adapters and two-host qualification
remain separate acceptance work; SQLite/process regressions prove only the
portable protocol and its crash/cancellation behavior.
