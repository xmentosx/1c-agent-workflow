# Client runtime and optional UI owner qualification — 2026-09-30

Rules candidate: clean controlled fork
`ee9d7b8815bfc32b2182cf7f601d439a843f7a1e`, upstream
`20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`. Source changes in this record
are local and unregistered. The default source dependency still points at r36.
No ordinary client profile, marketplace, project installation or publication
was changed by these isolated client probes.

## Actual native Codex plugin discovery and disable

On Codex CLI `0.158.0-alpha.2.1`, the exact ee9 candidate passed local
marketplace add → plugin add → enabled list → persisted isolated
`enabled=false` → disabled list → enabled again → remove → empty list. All
seven commands exited 0. Plugin version was `1.0.0`; project rules commit
remained independent. Six project inputs retained their SHA256: AGENTS,
USER-RULES, rules manifest, project config, dependency lock and Codex config.
The ignored record is
`build/client plugin проба a301248c7a9447b992a9e08401c0b9c6/summary.json`.

A separate fresh native app-server `initialize → initialized → skills/list`
probe discovered the plugin through the actual host. Besides
`1c-rules:install` and `1c-rules:update`, this alpha client converts the two
shared slash commands into `1c-rules:source-command-install/update`. All
four belong to `pluginId=1c-rules@1c-rules`. With the isolated persisted
disabled preference, all four disappeared from native discovery. Six project
hashes remained unchanged and native plugin removal exited 0. Record:
`build/native plugin discovery e439f531-f896-4166-afa4-d7e8071c1811/summary.json`.
This is native discovery, **not a model invocation of either skill**. No
credentials were copied. Hooks were disabled for these inspection sessions;
the Codex manifest itself advertises `hooks: []`.

The first app-server assertion incorrectly expected exactly two entries;
its retained failure exposed the host's command migration, not a package
execution failure. The continuation requires both canonical skill names
and records every host-generated entry rather than suppressing them.

A separate one-call `-c plugins."1c-rules@1c-rules".enabled=false` attempt
returned `enabled=true` from this alpha client's `plugin list`. That failed
override is retained under
`build/client plugin проба e608b6df011f41b5b73e31862dd60335/`; it is not
used as disable proof. The supported preference in this qualification is
the persisted setting in the **owned isolated** CODEX_HOME. The official
[plugin documentation](https://developers.openai.com/plugins/build/plugins)
describes the `enabled` preference and trusted-project configuration scope.

## Concrete runtime variants

The exact-candidate twelve-client init/update/doctor and byte-idempotence
proof remains installer/manifest proof. It does not qualify an application
that was never started. The current host inventory found an additional
OpenCode Desktop executable outside PATH. Cursor's executable is an editor
launcher (`cursor.exe [options][paths...]`), not a proven headless agent.

| Client/runtime | Confirmed executable/build | Native skills/commands and OpenSpec | MCP tool call / restrictions / selected role model |
| --- | --- | --- | --- |
| Codex CLI, Windows workspace permissions, unelevated sandbox | 0.158.0-alpha.2.1 | **passed** six actual phase sessions; exact plugin discovery/disable passed separately | **unverified** live provider calls, native role restrictions and per-client model choice |
| Codex CLI, Windows read-only permission mode | same build | **failed** helper language-mode boundary, also reproduced with published r33 | unverified; no sandbox bypass |
| Codex desktop/IDE runtime | not independently measured | **unverified**; CLI proof is not desktop invocation proof | unverified |
| Cursor editor launcher | 3.21.16, `8ae78e8eee1e63479c7e0504b664bc0a80c68000`, x64 | executable/help inventory passed; agent discovery/invocation **unverified** | unverified |
| Cursor agent CLI | not found on PATH | unverified | unverified |
| OpenCode Desktop | PE ProductVersion 1.18.11.0, FileVersion 1.18.11 | executable inventory passed; live workspace/plugin coexistence **unverified** | unverified |
| OpenCode CLI | not found on PATH | unverified | unverified |
| Kilo CLI / Kilo editor | neither runtime found on PATH or separately opened | separately unverified | unverified |
| Claude Code | executable not found on PATH | unverified | unverified |
| Kimi | executable not found on PATH | intentional natural OpenSpec route; execution unverified | unverified |
| Qwen | executable not found on PATH | intentional natural route; execution unverified | unverified |
| Command Code | executable not found on PATH | intentional natural route; execution unverified | unverified |
| Cline CLI | executable not found on PATH | project MCP adapter fixture passed; natural route execution unverified | unverified |
| Cline editor / older global-only runtime | not opened | separately unverified; no automatic global fallback | unverified |
| Pi | executable not found on PATH | pinned extension fixture passed; natural route execution unverified | unverified |
| ZCode | executable not found on PATH | project adapter fixture passed; natural route execution unverified | unverified |
| MiMo Code | executable not found on PATH | JSON/JSONC ownership fixture passed; natural route execution unverified | unverified |

The sole lowest **tested** Codex build above is not a general
minimum-supported-version guarantee. No minimum execution build is claimed
for the other runtimes. Native hooks, actual OpenCode coexistence, model
invocation and provider callability remain acceptance gaps in tasks 8.3/10.3.
Remote provider initialize timeouts are recorded separately in
`reused-stands-and-template-platform.md`; endpoint presence is not a pass.

## UI preparation: reproduced causes and owner repairs

Three distinct installation failures were preserved rather than hidden:

1. npm lockfile v3 contains `packages[""]`. Windows PowerShell 5 cannot parse
   the empty property name; the warning surfaced as invalid argument `name`.
   The source reader renames only its parsed view, leaving the lock bytes
   and exact version/integrity checks intact. A mismatch is rejected before
   promotion and leaves the previously accepted package unchanged.
2. In Windows PowerShell 5, `& npm ... 2>&1` under Stop treats an ordinary
   stderr notice as an exception. UI commands now use the existing UTF8
   native capture helper and judge the native exit code. Owned npm shims
   resolve to Node's npm entrypoint; the browser shim resolves to the pinned
   Windows binary. Native output/arguments include whitespace and Cyrillic.
3. The original deep canary root produced a 260-character native exe path
   only because the generated staging name added a version label and a full
   GUID. An extended-path launch also failed; that experiment is retained.
   The owner now keeps the same root and full GUID but omits the redundant
   staging label. The equivalent original root/legacy-260 scenario proves
   the shorter internal stage can launch a real executable. It does not
   promise that Windows can launch arbitrary native paths over MAX_PATH.

The full upstream doctor revealed a separate runtime limitation: on this
Windows host it launches Chrome `--version`, which creates a persistent
Chromium tree rather than exiting. During the actual B1 workflow rollout,
only that verified tree (PID, creation time, parent and exact executable)
was stopped through `Stop-NativeProcessForSafety`. All ten stops were
confirmed; the original workflow owner then completed the rollout. The
record is `build/ui-owned-doctor-stop.json`, and the rollout agent retains
its lifecycle/configuration preservation proof. This is not an accepted
uninterrupted browser doctor run.

The source repair adds an **opt-in** bounded wait to the existing native
capture helper; old callers retain timeout 0. UI preparation supplies
30 seconds for version/core commands, 600 for browser download, and 90
for full doctor. On timeout its UI owner stops only the started process's
verified descendants and reports strict `NATIVE_PROCESS_TIMEOUT`. Best-effort
workflow preparation reports degradation and its existing recovery action;
an explicit install fails. A timeout never counts as passed doctor.

The same real Windows PowerShell 5.1 install workload, original Unicode and
space root, pinned archive and **full doctor** reached this new timeout
after 101.97 seconds, with `owned cleanup confirmed=True`:
`build/UI tools живая проба f5710e79d0fb43e7ac732c0e05a10975/summary.json`.
No quick/offline substitution or Chrome replacement was used. The browser
runtime remains unverified; this record qualifies bounded failure handling.

Automatic preparation now consults `TOOL_AGENT_BROWSER` and
`TOOL_WINDOWS_MCP` separately: off skips that provider; invalid values report
correction before dependent work. Explicit named install can override off
for that invocation without persisting a new preference. The MCP renderer
skips disabled/invalid provider probes and preserves existing owned entries.
Ordinary status/doctor inspect stored package/config identity and do not
launch the browser or run its readiness command. Callability remains
explicitly unverified.

The owned regressions additionally exercise a real stalled Node parent and
child, strict timeout, confirmed scoped cleanup, and retry of the original
command path after correcting the child behavior. The negative native exit
and wrong-integrity checks remain strict. UI fixtures render both direct
stdio entries for all twelve declared client adapters, including ZCode and
MiMo; these are still fixtures, not twelve live client invocations.

The final directly owned Pester suite passed **11/11 in 19.03 seconds**:
`build/ui-tools-owner-final.xml`. The earlier 9/11 run is retained: one
fixture lost its explicit client ID when dot-sourcing the helper, and one
new pipe-inheritance expectation did not reproduce the actual stalled
Windows workload. The corrected twelve-client fixture preserves its
explicit runtime selection. The timeout regression reproduces the observed
waiting parent/child behavior, retains strict cleanup and runs the original
command again after fixing the cause. A prior 3/3 run records the Unicode,
integrity and internal staging repairs separately.

## Bounded ClientAdapters timeout diagnostic and BOM correction

The unfinished ClientAdapters batch had printed the `.gitignore` newline
warning after its User environment case. That output locates a later fixture
case; it does not establish a registry hang. Only these two existing cases
were selected for the diagnostic, with unchanged paths, workloads and assertions:

- `keeps every generated Codex skill ignored when the dev surface is materialized`
- `keeps both attached surfaces and removes only the detached owner for every client pair`

The second case retains all 144 client pairs. Their audited call paths create
temporary Git projects and render, attach and remove managed fixture surfaces.
They do not invoke User registry/environment writers, global profiles, native
1C, MCP or UI readiness. Pester 5.8.0 Detailed output with ShowStartMarkers
records the active case. Each run captures 66 raw SHA256 input hashes, elapsed
times, a unique transcript and JUnit XML in ignored `build/` storage.

| Runtime and input | Parse / executed result | Case durations and total | Retained artifact directory |
| --- | --- | --- | --- |
| Windows PowerShell 5.1.26100.9549, test without BOM | ParseFile failed with 23 errors; strict UTF8 ParseInput passed; no cases executed | Discovery failure, 1.987 s total | `build/client-adapter-two-case-942354807e404c4191aa264570dc768a/` |
| PowerShell 7.6.5, same test without BOM | **passed 2/2**, no failed/skipped cases; 31 not selected | 73.920 s / 49.659 s; 125.608 s total | `build/client-adapter-two-case-bdee6cee38f74cf98741710dc4327e39/` |
| Windows PowerShell 5.1.26100.9549, BOM restored | ParseFile and strict UTF8 ParseInput both zero errors; **passed 2/2**, no failed/skipped cases; 31 not selected | 59.678 s / 40.757 s; 103.221 s total | `build/client-adapter-two-case-152b1568b45149edb7e79c852f3d9d47/` |

The original Git HEAD test blob has a UTF8 BOM. Root restored only those
three prefix bytes; the body is byte-identical, recorded in
`build/client-adapter-bom-restored.json`. The file SHA256 changed from
`1749f7e2d25c86a6978166cf18fcd830279f78742e3c1da17077edd5105db497`
to `363b5050f52585eeb1b44203eca57633caebe9f31a395a61d4b3522450d88371`.
That test file is the only differing input between the passing PowerShell 7
run and the passing Windows PowerShell 5 run. All 66 inputs remained unchanged
within each run. Both runs record source HEAD
`69612acc8cabecf8ee55f3aa485e999c774a73c7`; the input records describe the
actual working bytes rather than claiming clean-HEAD qualification.

The after record includes `parse-ps5.json`, `result.json`, `inputs.json`,
`detailed.log` and `pester.xml`. After input-record SHA256:
`288e5550f61badab12face45fcfd4d9e8fe37246ca6e31d2c86a49fdc2458b75`;
JUnit SHA256:
`125deb195d4276b6cb97650fb02af354b4af084ed6195670f96255d6269b7ee3`.
The retained before failure and after pass prove the BOM cause of the Windows
PowerShell test-file discovery failure. The two-case runs did not reproduce
the earlier indefinite batch delay and do not establish its cause, qualify
the whole test file or replace Targeted/native-runtime acceptance.
