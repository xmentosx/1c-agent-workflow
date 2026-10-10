# Q24: layered client observation and native OpenCode config loading

The working H source consumers now use `Read-ItlClientMcpEntries -Client` for
configured UI keys and ProductDocs presence. OpenCode observation therefore
includes `opencode.json`, `opencode.jsonc`, `.opencode/opencode.json`, and
`.opencode/opencode.jsonc` through the existing effective-view owner. Presence
still means configured; it does not imply attachment, enabled state, reachability,
or a successful MCP call. Other clients retain their adapter behavior.

## Source consumer proof

The unchanged seven cases in `LayeredClientObservation.Tests.ps1` passed under
Windows PowerShell 5.1.26100.9549 / Pester 5.8.0: **7 passed, 0 failed, 0 skipped**,
4.116 seconds. They cover nested JSONC and four-layer deep merging, unchanged
physical files, legacy OpenCode JSON, Codex TOML, Cursor JSON, foreign endpoints
without implicit attachment, and configured/installed membership rejection.

The original **4 passed / 3 failed** run remains at
`build/layered-consumer-native-1df89bab6f47441885a32069a04d8827`. Its three OpenCode
cases exposed the real parser-to-reader dictionary boundary (`Contains`
overload); the owning reader repair preceded the green run. The original test
workload and assertions were retained. Its input capture omitted the new JSONC
and OpenCode library names, so it is not a complete loaded-script inventory.

Green run:
`build/layered-consumer-native-after-fc3d067f58fc4c578f7bb19584c10470`.

| Artifact or owned input | SHA256 |
| --- | --- |
| `result.json` | `d61f785e48fb9c4c30e0d4d6dfccbe2f79ebb42db3de881b18e223cf827047bf` |
| `inputs.json` | `c9ab8311e26fab4b4990fdfabf62b1f11b9957ce93de32054bb1b22299649cb0` |
| `pester.xml` | `8ae4cd2fb2d2e2544cbd8c856efeebdcbc49fed088cc0c91abdfae3dd029bc49` |
| `LayeredClientObservation.Tests.ps1` | `8a7981e4b2d7c56a4bfd3baa28eef26ac64b6d33e60717af01561921f202a1de` |
| `agent-1c.ui-tools.ps1` | `cc1c26b438e638dabb156e1f324f547e058cb60165f993350cd31f5080d03ee1` |
| `agent-1c.vibecoding1c-mcp.ps1` | `fa8fe4bc13d060de99fc40bdfd822daf220f805354b308dfe92ef6d172c1fba9` |

## Exact native route

The installed OpenCode Desktop **1.18.11** PE/ASAR stock backend was exercised
under Electron **42.3.3** / Node **24.15.0**. This observes its config loader,
not Desktop GUI, a different CLI, the current controlled-fork plugin, or model
execution. The unmodified stock runner and private runtime SDK/plugin 1.18.11
dependencies were reused from the earlier named headless qualification. No
credentials or ordinary profile config were copied.

Owned area:
`build/OpenCode Q24 слои 098a6476c2374d53afa9132748f67e46`; project:
`Проект четыре слоя`. HOME, XDG, Windows profile, npm, Git config, and temporary
paths were private. The only native requests were `GET /global/health` and
`GET /config?directory=<exact owned project>`. Both returned 200 in each launch.
No session, provider, model, tool, MCP connection, or 1C call was requested.
All five effective MCP entries explicitly had `enabled=false`.

Each of the four project layers had a complete valid native MCP shape. Headers
merged across layers, Cyrillic strings survived, and higher command arrays
replaced lower arrays. A separate entry was produced by the real
`Write-ItlClientMcpEndpoints -Owner vibecoding1c` and then explicitly disabled
through the owning JSONC property writer before launch. Its `managedBy` and
`family` fields remained in the physical config. This exact stock decoder uses
Effect Schema `onExcessProperty: ignore`: the native effective projection omits
those two metadata fields. The comparison accounts for exactly that decoder
behavior; it does not sanitize the physical entry.

The first pure harness attempt failed before native launch because its module
list omitted the existing Vanessa library defining `ConvertTo-IntOrDefault`.
The failed driver/logs and original fixture were retained. Loading that existing
function-only library completed initialization without a product change or
fixture recreation.

## Retained stock mutation and normal continuation

First actual native launch: **effective projection passed; whole-project byte
invariance failed**. Stock OpenCode inserted `$schema` into all four schema-less
config files, removed both existing UTF-8 BOMs, and normalized the CRLF root
JSONC file to LF. The exact bundle's `loadConfig`, lines 184073–184079, performs
the optional `$schema` insertion and file write while loading. The other 3,689
project records were unchanged. Native shutdown completed normally with exit 0.
This is observed stock-host behavior, not an ITL read/write operation; helper
byte preservation cannot promise that starting the stock host is read-only.

One normal relaunch used the SAME fixture, current files, private profile,
dependencies, runner, and request workload after that actual stock transition.
No manual schema insertion, BOM/EOL repair, fixture recreation, or assertion
relaxation preceded it. The effective native MCP projection again matched the
source view; **all 3,693 project records were now unchanged**, the original
dependency tree was unchanged, and ordinary shutdown exited 0. The wrapper took
8.915 seconds. This proves idempotence after the observed transition; it does
not turn the first launch into a preservation pass.

| Native artifact | SHA256 |
| --- | --- |
| Original `native-config-report.json` (byte-invariance RED) | `f3078426d73ad0087aad9ee68f25744c60c63a724cdfb03a00dfdc55bc70d4b0` |
| `native-config-boundary.json` | `15e7faf3a432ada10ba626b0eb4d130bda3383e5397a21b907513d6f3a2b80b3` |
| `fixture-initialization-failure.json` | `fa1c2ebe8e155c1a34b466032e3ac4726f815bce9adeb4b5dc8fc55b26ec71f0` |
| `production-writer.json` | `1ffac6e31dad78c2a909bbfa5b49c04512ff85909aca8a77d8244c12a32d755a` |
| `phase2-native-config-report.json` | `705533ab21a39213e2c8dd29a150d7025a39262e9f60af646acecd1daf387f32` |
| Both phase-two project inventories | `470705b0646941501d94d2b28885aea6e62b4c3a010cbc36aac76c951a3ecd2a` |
| Native config body, both launches | `b4d588b40fd6c0894b991ea736999a90af9a8f8aed6afd36c19423bcad4e65a5` |
| Desktop executable | `1ada75de8559702b55a1f9d6536fb6b9a5ab7edde6caedefcb98221936f7fe0f` |
| `resources/app.asar` | `68391b7dd8050c1c371366f8b034e3c91b684113a6eeebc7044b097e81a11a70` |
| Stock `out/main/chunks/node-DjjWJ0_s.js` | `d87082b3f5f8a52f7a3ef4af940e2a9392f781919856c0dd72b36246947906ee` |
| Unchanged stock runner | `2a7d09de6c182c0f89b41c26f02c159a04a59855121039439660b13b0acb8b81` |
| Both copied runtime dependency locks | `b2510ccd0ed35460ef53fadb077620cc49ad24ebf1cf9fe281eae16a15f6d3a3` |

The source consumers and reader are current uncommitted H working inputs;
their focused proof is not exact published-tree or controlled-fork
qualification. Native model/MCP execution, plugin/event behavior for the new
fork, other native client versions, and a minimum supported version remain
unverified by this observation. The previous native plugin proof remains
historical and separate.

## Registration guard regression, 2026-10-03

The first registration of source a82cdf5b stopped at the unchanged
ClientAdaptersAndModes tracked-root guard assertion. It completed 457 passed
cases and one failed case; unstarted files do not constitute a passed gate.
The preflight OpenCode guard now checks the existing candidate write paths
when no physical path is supplied. The concrete writer checks only actual
changed paths. The original Kilo/root assertion remains unchanged. Native
focused acceptance passed both that original case and the layered tracked-path
case, with added preflight refusal/continuation assertions (2/0/0, 4.281 s).
Tracked read-only root coexistence remains supported. Registration of the
corrected complete source unit is still required.

## Snapshot observation and owned component contract, 2026-10-03

The next registration of 5a25da13 recorded 561 passed and four failed cases.
Two original UI snapshot cases were blocked too early by the new OpenCode
membership observation. The authoritative Get-AgentTargets resolver now has
AllowUnconfigured for exactly those two read-only callers. Ordinary selection
still rejects missing/unsupported clients; explicit empty sets and environment
precedence are unchanged. The unchanged original continuation/refusal cases,
selection controls and all seven existing OpenCode snapshot cases passed
native focused acceptance together: 10/0/0 in 28.300 s.

The other two cases exposed an intentional old external-client pin expectation
and an inherited candidate-CFE path contaminating a cache fixture. The wiring
test now binds the approved owned artifact pair to its authoritative controlled
manifest and unchanged immutable upstream baseline/licenses. Actual binary SHA
qualification remains with the native build/publication owner. The original
Unicode cache, worktree sharing and corrupted-SHA assertions are retained; the
fixture captures, clears and restores its inherited override. Both original
cases passed under the same candidate override: 2/0/0 in 3.534 s. The failed
registration records remain; complete registration is still pending.

## Exact build acquisition before publication, 2026-10-03

An additional native owner regression reproduced the actual stand topology:
the new owned client pin and an empty new cache were followed by persisted old
client paths being reimported during post-copy, then ForceDownload requested an
unpublished immutable URL (RED 0/1, 2.410 s). The existing artifact owner now
accepts an exact process-scoped client build only for the active owned pin with
matching asset, version and SHA, using the same immutable acquisition and cache.
Actual Develop/Release E2E entrypoints capture the input before project settings
are reimported and restore the transient source in finally. Release includes its
early preflight and cleanup; Full/Pester receives no injected build source.

Native focused acceptance passed 9/0/0 in 8.679 s, including the original failure
topology, no URL request on a match, old/mismatched requests, changed candidate
and cache bytes, actual preflight child inheritance and early Release rejection
with environment restoration. Independent scope/ownership review found no
remaining material findings. Fixture initialization failures are retained with
their causal corrections. The production lock/URL and native build/publication
qualification remain authoritative; these cases do not prove remote installability
or qualify the previous CFE after helper inputs changed. A clean final native
build, complete registration and paired publication are still required.

## Final registration findings and preservation, 2026-10-03

Registration of the isolated b6c07373 candidate ended with 703 passed and two
failed cases (13 executed files, 790.495 s worker span). Its queue stayed empty
and its source checkout stayed clean. The original summaries, shard plans,
results, JUnit and logs are retained under the publication clone's
`build/q24-register-red-b6c07373`; retention receipt SHA256 is
`9c0fd3886680e2426ac4c768b58482ccd2254b6f8bf0759fc30339293be3cc1d`.
Unstarted files and earlier shard files do not constitute passed registration.

The unchanged ten-client OnDemandMcp case exposed a real OpenCode migration
defect: old explicit workflow markers were skipped when physical owner bindings
were absent, so an obsolete service could remain alongside its replacement.
Cleanup now routes through the existing layered writer. Captured physical
`itl-branch-mcp`, `vanessa-mcp` and `vanessa-ui-mcp` markers prove deletion only;
they never become persisted ownership. Other proved owners, unrelated entries,
comments/BOM, legacy root scope, four-file/owner compare-and-swap and partial
write continuation remain protected. The original case remained unchanged:
native RED 0/1 became GREEN 22/0/0 with all existing layer cases and eight added
regressions, in 16.641 s. Independent final review found no material findings.

The green batch used a BOM-bearing predecessor of the ASCII-only library.
Restoring its original UTF-8 without BOM changed no body bytes, tokens or AST;
native PS5.1 parsed all three owner files without errors. These distinct proofs
are recorded in `build/q24-legacy-marker-causal/final-qualification.json`, SHA256
`28f3f83bcc025da51446655d4ca3ded33cbcc5eec790af4869f75d973f1ca74a`.
Complete registration and native qualification of the final bytes remain pending.

The other failure was an outdated refresh fixture expectation. Relabelling a
current workflow-owned client pin as `compatibility-manifest` is noncanonical;
the unchanged runtime correctly refused it. The positive fixture now seeds the
actual published f5466e6 legacy client entry and invokes the actual managed-lock
synchronization owner before refresh. It proves the canonical new pin, one
workflow-only lock commit, updated load identity and clean Git. The original
corruption topology remains a strict negative with no HEAD advance, unchanged
corrupted bytes and retained dirty lock; the existing unmanaged-change negative
is unchanged. Native PS5.1/Pester 5.8 passed these three cases together in
6.098 s, with environment restored and captured source inputs unchanged.
Receipt `build/q24-refresh-pin-causal/qualification.json` SHA256:
`ec73fe7f53172dc8da6a97a8a05136c78afa4305d5f16c6b92bd6a4578f62981`.
No runtime guard was weakened. The preceding CFE proof becomes historical when
the helper inputs change; a new clean native build and full registration are
required before paired publication.

## Candidate override isolation, 2026-10-03

Registration of 49baa5aa completed 994 passed and one failed case: 17 executed
and nine reused files, 722.708 s worker span (824.344 s full gate). All 295
DevBranchLifecycle cases passed. The isolated queue remained empty and source
Git clean. Its complete failed summary, original JUnit, relevant shards and
gate logs are retained under publication checkout
`build/q24-register-red-49baa5aa`. Corrected retention receipt SHA256:
`49915827151f5c93f2013a837d18c26c13bf6b5fa42442151c046ddab3a78dae`.
The first retention tree probe's unquoted PowerShell argument failed and is
preserved separately; it is not an exact-tree receipt.

The sole failure was the unchanged stale-cache ArtifactCacheIsolation case.
Its old project dotenv competed with the exact new CFE path inherited from
the registering process; the normal process-first lookup correctly returned
that external override. The fixture now captures ten relevant cache/path
inputs and their exact AGENT_1C_ aliases, clears those inputs before each case
and restores their original values afterward. No runtime precedence, candidate
gate environment or dedicated source-provider input changed. All five original
test bodies, old paths, dotenv, workload and assertions remain identical.

Native PS5.1/Pester 5.8 passed all five cases together in 4.791 s under the same
actual final CFE override (5222a74b). All 20 environment values were restored;
the exact CFE and 32 captured focused source inputs were unchanged. This is
distinct from the native owner's 43-input qualification. Independent review
found no material findings. Receipt
`build/q24-cache-fixture-causal/qualification.json` SHA256:
`9e3e1432af2f509e60a5b6f3c94a1151f279a548857e03cc2697648399bfebd6`.
Final complete registration remains pending; unstarted files are not passes.

## Verified source fixture and pending-source refusal, 2026-10-03

Registration of 6c601bff completed 1,487 passed and 16 failed cases in the
single SourceUpgradeHandoff file: 40 executed and 24 reused files, 291.979 s
worker span (376.871 s full gate). Its source remained clean and queue empty.
Summary, JUnit, original shard and gate logs are retained under publication
checkout `build/q24-register-red-6c601bff`; retention receipt SHA256:
`cb2cd6c3856535ae48f597003f1cd82593584e9c96c7969b495873300809f089`.
Remaining unstarted files are not claimed as passes.

Those unit cases passed the current source templates directly to rules-root
admission. The c1 candidate deliberately remains compatibility pending until
the public qualification promoter runs, so it cannot supply that admission's
verified target precondition. Normal public update still invokes the actual
source-installability guard first and refuses pending before copying; neither
runtime guard nor production compatibility status changed.

The unit fixture now uses actual immutable published f5466e6 rules metadata
(r36/451c5a52, passed), checked against the original Git data through the shared
UTF-8 transport. BeforeAll proves the target is configured. Only nine source
arguments changed; all original It bodies are identical after reversing those
substitutions, including project topology, Unicode, user policy, foreign paths,
hash preservation and refusal assertions. The existing CRLF positive now also
reaches the real rules guard instead of passing through the pending early return.
A new public-update negative retains the real source-installability owner and
proves pending refusal, zero copy-owner calls, unchanged managed/env/project/
source-lock bytes and no snapshot.

Native PS5.1/Pester 5.8 retained the original two RED cases (0/2, 2.130 s) and
passed the complete corrected owning file once: 58/0/0 in 43.040 s under the
actual CFE 5222a74b override. Captured inputs stayed unchanged and environment
was restored. The existing cross-checkout lock LF/CRLF difference is recorded
separately with identical normalized UTF-8 content. Independent review found
no material findings. Receipt `build/q24-upgrade-fixture-causal/qualification.json`
SHA256: `13785a22d2e6c3e1b90271395098ec8df1d7d8d8fd9b5d1981f4d8882d0640c8`.
Native component inputs and the production pending pin remain unchanged;
complete registration, installed canaries and paired publication are still pending.

## Legacy GitHub fallback fixture, 2026-10-03

Registration of 5c985557 completed 2,000 passed and one failed case: 27 executed
and 59 reused files, 328.523 s worker span. The only failure was in
GitHubDependencyFallback; three unstarted files are not passes. Source Git
remained clean and the isolated queue empty. Summary, JUnit, original shard
and gate logs are retained under publication checkout
`build/q24-register-red-5c985557`; retention receipt SHA256:
`8415f5c7a5587cd783bd03868bb67ab9ba73d778c4d4fec4a1dfd48de14851e7`.

The original legacy request asked for `client_mcp.cfe`, while the current lock
correctly describes `client_mcp.v0.6.5-itl-r1.cfe`. The unchanged fallback owner
refuses this incompatible asset name. The legacy positive now temporarily uses
the complete actual published f5466e6 client entry, with exact byte restoration
in finally. All three original requests and assertions, and every other original
case, remain unchanged. A separate negative retains the current owned pin and
the same legacy request: one actual mocked rate-limit response still produces
the strict refusal and leaves lock bytes unchanged. No runtime mapping,
production pin, artifact acquisition policy or gate assertion was weakened.

Native PS5.1/Pester 5.8 retained the original RED (0/1, 1.701 s) and passed the
complete corrected file once (14/0/0, 2.511 s), under actual CFE 5222a74b.
All 37 captured inputs were unchanged and all 26 environment values restored.
Receipt `build/q24-github-fallback-causal/qualification.json` SHA256:
`22d9f40cf84b50b74a72987b05f59a01a2d7cebe85afa6bbd16e901a27c312b3`.
The native component's 43 inputs remain frozen; this test-only repair does not
require a rebuild. Independent read-only review found no material findings;
strict OpenSpec validation passed after this evidence update. Complete
registration and final installed acceptance remain pending.

## Final dependency-lock fixture, 2026-10-03

Registration of f7e63714 reached every selected file: 2,068 passed and two
failed cases, nine executed and 80 reused files, 497.072 s worker span. Both
failures were in DependencyLocks. Source stayed clean and the isolated queue
empty. The complete summary, aggregate/original JUnit, shard and gate logs are
retained under publication checkout `build/q24-register-red-f7e63714`;
complete retention-v2 receipt SHA256:
`6d9e7db59cd6520f0752a62bcbe3aa52d57feecb945b3bab5b86666199c9ba61`.
The first receipt, before adding the aggregate JUnit, is preserved separately.

The wiring test still asserted the former r36 rules and external CFE. Its exact
expectations now follow the accepted r40/25b60321/c1fb8e6/5222a74b pins. The
runtime-metadata fixture also assumed an existing updatedAt property and the
legacy template-baseline source policy. The unchanged synchronizer preserves
custom source only under that legacy policy; the owned pin requires its
canonical workflow-pinned source. The original path/topology, version, ROCTUP
and repeat assertions are retained for both policies. The legacy branch uses
the complete actual published f5466e6 entry through the real fixture-local
template resolver; the owned branch checks every canonical client field,
including correspondingSource. Eight other original case bodies are unchanged.

Native PS5.1/Pester 5.8 retained original RED 0/2 in 1.416 s and passed the full
corrected file once, 11/0/0 in 13.578 s. All 43 focused test inputs were frozen
and all 26 environment values restored; this focused inventory is separate
from the native component inventory. Independent review found no material
findings. Receipt `build/q24-dependency-lock-causal/qualification.json` SHA256:
`030120cf5599e61353f9e7bb786a570a364dcbd19ecf334277e927eb1bdfd00d`.
Runtime, production pins and exact CFE remain unchanged. Complete registration
and final installed acceptance remain pending.
