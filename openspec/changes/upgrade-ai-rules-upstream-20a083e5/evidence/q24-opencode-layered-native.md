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
