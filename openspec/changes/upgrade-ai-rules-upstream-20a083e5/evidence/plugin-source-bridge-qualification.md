# Managed plugin/source bridge — 2026-10-01

## Frozen C4 source bridge

The same three-action owned driver was repeated after the source cache owner
correction, against immutable C4 commit
`6c651f9b164ae1932c65bab661de315640017e83`, tree
`389899420e3e26f10d341c5bb7b9d25262877e95`, snapshot identity
`ee3d58314a310e42798cd01a186fbae3271d4844`. The fork remains exact
`9ec86f75343ba4eded66e2085f097ff4baab7d67` / r39 with the same wrapper
SHA256 recorded below. Only driver input identity and owned output/fixture
paths changed from C3; no source or fork executable was edited by this run.

| Actual wrapper action | Observed result | Exact project state |
| --- | --- | --- |
| `ensure -Tool codex` | exit 0, 411 ms | All 560 file hashes and 277 directories unchanged |
| `doctor -Tool codex` | exit 0, 5,838 ms; read-only | Same complete snapshot unchanged |
| `doctor` with deliberately mismatched project ref | expected exit 1, 5,429 ms; source provenance FAIL | Complete seeded negative-case snapshot unchanged |

After restoring the negative seed, the original project snapshot matched
again. The source and fixture helper inventories both contain exactly 37
scripts; all source hashes remained unchanged after the run. Frozen C4 and
the fork remained Git-clean; the owned isolated `CODEX_HOME` remained empty.
PowerShell 7.6.5 and explicit UTF-8 transport were retained. The report is
`build/plugin-source-bridge-c4-qualification.json`, SHA256
`bb25628334dd84f84b2f224dc39ea32c518360ab70c082f4552ecb869dfb26f6`;
driver `build/qualify-plugin-source-bridge-c4.ps1`. All three logs have the
same SHA256 as their C3 counterparts. C3 artifacts remain intact.

The C3 structural-fixture and unavailable-capability boundaries below also
apply to C4. These actions do not execute the cache synchronization path,
mutating attach/update, live providers, 1C or native plugin host sessions.
The cache correction's own regression and installed migration evidence
remain separate; this receipt qualifies only the current bridge/read-only
doctor and failure propagation.

## Frozen C3 source bridge

The existing owned bridge driver was repeated against immutable source C3:
commit `647df3dafd81c3bf0b18785a6861453fe320d943`, tree
`5566a20b430666af959678d67facfedaeb418061`, snapshot identity
`b442c324a12bec221a3d10e82da77bbb322df4e4`. The real wrapper came from
controlled fork `9ec86f75343ba4eded66e2085f097ff4baab7d67`, local r39 ref
`itl-main-20a083e5-r39-canary-9ec86f7`. Its SHA256 is
`7d09f6901b845ef185bb344f4b16daf1471a5e06ab7591c34c2c961635ab1c5c`,
byte-identical to the earlier 015 wrapper. No wrapper/fork code changed.

`build/qualify-plugin-source-bridge-c3.ps1` retains the original driver's
three actions, fixture topology and complete project snapshot assertions.
Only the source/output roots and exact rules pin were substituted; its
additional identity check requires the frozen C3 HEAD and clean source.
Fixture/output files are outside C3. Child-process arguments use
`ProcessStartInfo.ArgumentList`; stdout/stderr decode and persist as UTF-8.
Runtime: PowerShell 7.6.5. A fresh owned Unicode/space project and empty
isolated `CODEX_HOME` were used; no plugin deployment or native client
session was started.

| Actual wrapper action | Observed result | Exact project state |
| --- | --- | --- |
| `ensure -Tool codex` | exit 0, 408 ms; no session mutation | All 560 file hashes and 277 directories unchanged |
| `doctor -Tool codex` | frozen C3 helper, exit 0, 6,682 ms; read-only report | Same complete snapshot unchanged |
| `doctor` with deliberately mismatched project ref | source provenance FAIL, expected exit 1, 6,539 ms; failure propagated | Complete seeded negative-case snapshot unchanged |

The harness restored the negative seed and checked the original snapshot
again. All 37 source script inputs were copied byte-for-byte and retained
their hashes after the run; the isolated profile remained empty. The exact
input hashes, dispatcher, project pin, runtime executable hash and log hashes
are in `build/plugin-source-bridge-c3-qualification.json`, SHA256
`722fb91fe85efc1c6e230fa13317429a9e360f5e40ad5dda9c51b58da705a2bf`.
The earlier report/logs remain intact.

This is structural managed-bridge acceptance, not installation acceptance:
the fixture starts from historical owned tracked files and the rules lock
is supplied by the harness. Doctor confirmed its r39/9ec pin and refused the
deliberate ref mismatch; installed candidate rule bytes were not qualified
by this run. `configuredServers=0`, OpenSpec/UI pins unavailable,
`providerCallability=unverified` and `pluginHostVersion=unobserved` remain
explicit. Named WARN continuations were retained. Exit 0 proves neither
native discovery/hooks/model invocation nor external provider readiness.
Current-source attach/update and paused-refresh acceptance are separate.

## Historical managed bridge — 2026-09-30

The real wrapper at controlled-fork `015cf9856c37fcecdf03df2faa8b8546f84849b4`
was run against a fresh owned `plugin bridge проверка <uuid>` project. Its
helper script directory was copied byte-for-byte from the current source
worktree; every input SHA is in
`build/plugin-source-bridge-qualification.json`. This is a structural bridge
fixture derived from tracked historical canary files, not proof of a fresh
installation or a native client session. The fixture used no credentials,
no managed MCP endpoints, a fresh empty `CODEX_HOME`, and no 1C operations.

| Actual wrapper action | Observed result | Exact project state |
| --- | --- | --- |
| `ensure -Tool codex` | exit 0, 399 ms; no session mutation | All 560 file hashes and 277 directories unchanged |
| `doctor -Tool codex` | current source helper, exit 0, 5,518 ms; read-only report | Same complete snapshot unchanged |
| `doctor` with deliberately mismatched project ref | source provenance FAIL, exit 1, 5,814 ms; failure propagated | Complete seeded negative-case snapshot unchanged |

The negative seed was restored by the test harness and the original complete
snapshot was checked again. OpenSpec/UI dependency pins were intentionally
not provisioned in this minimal fixture; doctor reported their named WARN
continuations, `providerCallability=unverified`, and
`pluginHostVersion=unobserved`. Exit 0 qualifies the bridge/read-only contract,
not those capabilities. The report retains wrapper/helper hashes and logs;
the ordinary client profile was not used.

## Public contract and ownership

`plugin-dispatch.json` declares `protocolVersion=1`, `owner=itl-workflow`,
and exactly `update=update-ai-rules`, `attach=itl-switch-client`,
`doctor=doctor`. The real wrapper validates version/owner and the project's
40-character rules SHA before dispatch; these action names are fixed in its
version-1 dispatcher. The source helper's public validation and dispatch
support those same names and `-ProjectRoot`, with attach using
`-Mode attach -Client <tool>`.

The wrapper exposes `ensure/init/add/update/doctor` and its six plugin host
selectors (`auto` plus Codex/Cursor/Claude Code/OpenCode/Kilo Code). This does
not imply a plugin runtime for every one of the twelve source client adapters.
Managed `init/add` are attach, `update` is the project-pinned ai-rules update,
and `doctor` is read-only. `ensure` invokes neither attach nor update, and the
package has no unload-to-detach action. Explicit ITL detach remains a separate
source helper operation; removing/disabling the optional plugin does not reverse
project client membership.

The real managed wrapper was given an unrelated `-Source` URL. Its plan
discarded that source authority and doctor retained the project's r38/015cf985
pin. Project lock/config reconciliation and exact tag-to-commit checks remain
owned by the source ai-rules installer (`Sync-AiRules1cCheckout`). The observed
fixture pin is metadata supplied by the harness, not independent installed-byte
qualification of that candidate.

The already-passed fork Full 137/137 includes
`tests/ManagedPluginDispatch.Tests.ps1`: real wrapper `init/add/update`
arguments are checked through a recorder helper, and the Node child-process
harness covers missing/unsupported protocol failure, Unicode transport and
unchanged `ensure`. These unchanged tests were not rerun for this review. They
do not claim a current-source attach/update transaction or an authenticated
native-host invocation.

## Recovery executor is separate from plugin version

A missing/old bridge produces a named `/itl-update-workflow` continuation.
`scripts/update-installed-workflow.ps1 -SourceRoot <exact checkout>` starts
the current source helper before the old installed helper, preserves its exit,
and scopes/restores the source/clean-source environment overrides. The helper
resolves that checkout (including linked `.git` files) and requires a clean
exact source before copying. The launcher rejects identical/nested roots and
never substitutes plugin package HEAD for the project rules pin.

`SourceUpgradeHandoff.Tests.ps1` contains the existing regressions for
current-helper-first dispatch, source override restoration, missing/nested
source refusal, dirty-source refusal and failed-current-helper exit propagation.
This review checked those contracts without repeating unchanged tests or
starting a live refresh. Recovery transaction proof belongs to the separately
recorded paused-refresh/current-executor acceptance.
