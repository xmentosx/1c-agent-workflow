# Optional plugin qualification snapshot — 2026-09-29

## Consolidated plugin capabilities — 2026-09-30

The current `9ec86f75343ba4eded66e2085f097ff4baab7d67` candidate's exact Full
passed 137/137 Pester and 18/18 stages; its clean reusable record, Verify,
overlay-lock and local r39 are bound in [current fork proof](fork-alias-eol-qualification.md).
The matrix keeps each result's original commit/runtime;
historical native sessions are not relabelled as current-head acceptance.
The [twelve-client matrix](client-qualification.md) also distinguishes
configuration fixtures, native OpenSpec and MCP/model/restriction execution.

| Capability / host | Status and provenance |
| --- | --- |
| Codex CLI marketplace install/list/remove, persisted enable→disable→enable | **passed**, ee9, CLI 0.158.0-alpha.2.1, plugin 1.0.0; seven command exits and six unchanged project hashes in `build/client plugin проба a301248c7a9447b992a9e08401c0b9c6/summary.json` |
| Native Codex app-server discovery and disabled absence | **passed**, ee9, same CLI; both canonical skills plus both host-migrated commands discovered/removed, six unchanged hashes in `build/native plugin discovery e439f531-f896-4166-afa4-d7e8071c1811/summary.json` |
| One-call alpha configuration override | **failed**, ee9; `enabled=true` despite override, retained `build/client plugin проба e608b6df011f41b5b73e31862dd60335/`; accepted disable path is the persisted isolated preference |
| Native model invocation of a plugin skill | **unverified**; earlier fresh unauthenticated attempt returned HTTP 401 before a model response; ordinary credentials were not copied |
| Managed ensure/source doctor/project-pin failure propagation | **passed**, frozen C4 source `6c651f9` + current9ec/r39 real wrapper, `build/plugin-source-bridge-c4-qualification.json`; all 560 file hashes/277 directories unchanged, invalid pin exits 1; not a native host or installed-candidate receipt |
| OpenCode/Kilo Node event numeric failure, Unicode and read-only boundary | **passed**, current9ec exact Full `ManagedPluginDispatch.Tests.ps1`; historical 015 harness proof stays in [PL3](fork-pl3-qualification.md); native host event handling remains separate |
| OpenCode bundled backend event/coexistence/failure/recovery | **passed** for the stock headless backend from Desktop PE/ASAR 1.18.11, Electron 42.3.3/Node 24.15.0, frozen C4 + current9ec; [native three-phase proof](opencode-native-plugin-qualification.md). Invalid pin yields HTTP 200 before typed rejection and backend exit 1; same-profile pin restore/relaunch passes. GUI/auto-respawn/separate CLI/tool execution remain **unverified** |
| Cursor editor/agent, Claude Code, Kilo editor/CLI native hooks | **unverified**; fixture packaging/wrapper dispatch and inventory do not prove hook loading or execution |
| Codex desktop/IDE plugin invocation | **unverified**; CLI proof does not qualify another runtime; Codex package advertises `hooks: []` |
| Remaining seven client hosts | **unverified**, no host plugin advertised; twelve-client rule adapters are a separate capability |

Tasks 8.3 and 10.3 meet their qualification/status-provenance criteria. The exact
native OpenCode backend route is now observed; GUI and other host capabilities
remain explicitly unverified. No minimum client version is claimed from
inventory, and a skipped/unverified hook is not advertised as passed.

## Historical PL3 owner repair — 015 exact candidate

Fork `015cf9856c37fcecdf03df2faa8b8546f84849b4` passed its own
Full (137/137 Pester, 18/18 stages, clean/reusable), schema-3 Verify and
overlay-lock (472 paths). A real child-process Node harness now verifies
typed numeric failure, recovery diagnostics, Unicode transport and read-only
ensure for the OpenCode/Kilo variants. The local r38 canary points to this
exact commit. [PL3 fork qualification](fork-pl3-qualification.md) records
the artifact identities and native-host rejection limitation. Earlier native
Codex sessions below retain their ee9 identity; they are not current-head
runtime qualification.

The frozen C4 source helper and current9ec/r39 real wrapper passed a separate
[managed bridge qualification](plugin-source-bridge-qualification.md):
actual wrapper `ensure` and `doctor` preserve a complete isolated project
snapshot; a deliberately invalid project pin propagates the helper's failure.
The evidence distinguishes fixed version-1 dispatch, project pins and the
separate current-source recovery executor from native-host/install acceptance.

## Historical native qualification — ee9, 2026-09-30

Exact candidate `ee9d7b8815bfc32b2182cf7f601d439a843f7a1e` now passed native
Codex install/list, persisted isolated enable→disable→enable, and uninstall
with six protected project hashes unchanged. Fresh native app-server
`skills/list` discovered both explicit skills plus the host's two migrated
command skills, and removed all four from discovery when disabled. The
ordinary Codex profile and credentials were untouched. A one-call alpha CLI
config override did not disable its list entry and is retained as failed;
it is not the accepted disable path. Native skill **model invocation**, other
host hooks and live OpenCode workspace coexistence remain unverified.
Exact records and limitations are in
[client-runtime-and-ui-owner.md](client-runtime-and-ui-owner.md).

## Historical snapshots — earlier candidates

The earlier qualification snapshots below retain their own candidate identities.

Controlled-fork commit `0f58fbf47edf3fbcb022594a79a43ae448c9873f`
passed Full, including `ManagedPluginDispatch`, `marketplace-bootstrap` and
the Codex compatibility manifest checks. The managed dispatcher keeps
`ensure` read-only, routes explicit operations to the project helper, and
fails with an ITL upgrade continuation when the helper protocol is absent.
The Codex manifest advertises install/update skills and `hooks: []`; it does
not claim that the Claude shell hook is a Windows Codex hook.

On `codex-cli 0.158.0-alpha.2.1`, a disposable `CODEX_HOME` accepted this
exact checkout as a local marketplace via `.agents/plugins/marketplace.json` and
installed `1c-rules@1c-rules` version `1.0.0`. `codex plugin list --json` reported
it as `installed=true, enabled=true`. Removing that plugin succeeded with exit 0 and
left the installed list empty. SHA-256 of a
separate disposable project's `AGENTS.md`, `USER-RULES.md`, and
`.ai-rules.json` was unchanged across plugin removal. The operator's normal
Codex home and real projects were not used.

This proves local Codex marketplace packaging and uninstall isolation for
this host version. It does not prove an interactive Codex plugin skill
invocation, enable/disable transitions, Claude/Cursor/Kilo/OpenCode hooks,
plugin distribution from a published fork, or coexistence with a live
OpenCode workspace extension. Those remain unverified; no client plugin was
installed persistently on the user's normal profile.

The same marketplace add/install/list/remove/list sequence was repeated for
current clean fork commit `29583b9dc1a18c21c87245a935e0c613edd3453d`
in a new disposable `CODEX_HOME` at `%TEMP%/itl plugin 29583b9 ed09e518d79c4d29a80b76c854d78b7b`.
Codex again reported version `1.0.0`, `installed=true`, `enabled=true`, and
an empty installed list after removal. Startup warned that PATH aliases cannot
be created under a temporary home; all plugin commands exited successfully.
The same exact fork commit passed Full (128/128 Pester, 18/18 stages), including
the managed dispatcher and marketplace checks. This is exact-candidate packaging
proof, still not a live hook or skill run.

After the managed-memory clarification, the clean fork commit
`a6f175cc1099072d08134294c8acaf718d3e0b86` was checked again with
`codex-cli 0.158.0-alpha.2.1` and a disposable `CODEX_HOME`. Local marketplace
add, `1c-rules@1c-rules` add, list, remove and final list all exited 0;
the installed entry was version `1.0.0`, `enabled=true`, and the final installed
list was empty. The ordinary Codex profile and real projects were untouched.
This repeats packaging and removal only; native plugin invocation and host
hooks remain unverified. The same exact commit passed Full (129/129 Pester,
18/18 stages, clean and reusable qualification).

The current fork `2d3e7705f79e37a130349b88ecea78b964adabf5` has the
same plugin and marketplace-owned bytes as `a6f175c...` (`git diff --quiet`
on `plugins/` and `.agents/plugins/marketplace.json`). Its own Full gate passed
130/130 Pester and 18/18 stages with clean reusable qualification. The prior
local marketplace install/remove proves those unchanged package bytes; it
does not prove current native hook execution or disable behavior.

An earlier attempted ephemeral `codex exec` with a separate isolated plugin profile could
not qualify skill invocation: the fresh profile had no authentication and
returned HTTP 401 before a model response. During startup its separate
featured-plugin prewarm also encountered Windows long-path checkout errors
inside the disposable cache. Plugin removal still succeeded afterward. This
failure is recorded as an environment-limited **unverified** invocation,
not as a successful plugin execution or a defect proven in the 1c-rules
package. A future live probe needs an authenticated isolated host profile
and a bounded marketplace source without that unrelated prewarm checkout.
