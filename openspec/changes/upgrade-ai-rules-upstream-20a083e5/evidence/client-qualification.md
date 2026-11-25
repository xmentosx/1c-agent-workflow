# Client qualification snapshot — 2026-09-29

## Consolidated capability matrix — 2026-09-30

The current fork candidate is `9ec86f75343ba4eded66e2085f097ff4baab7d67`.
Its exact Full passed 137/137 Pester and 18/18 stages, with clean reusable
qualification; [current fork proof](fork-alias-eol-qualification.md) binds
the exact commit/tree. Historical all-twelve compatibility/native results do
not qualify all capabilities on this new commit.
Every **passed/failed** cell below names the evidence's own candidate/runtime.
Current-candidate provider/model qualification remains **unverified**; native
plugin backend evidence has the narrow scope recorded under **O** below.
No minimum-supported-version promise is inferred from an executable inventory.

Evidence keys:

- **F** — **passed** historical ee9 (`ee9d7b8815bfc32b2182cf7f601d439a843f7a1e`)
  isolated init/update/doctor for all twelve clients, delegated MCP and pinned
  OpenSpec 1.13.1: `build/compatibility-r33-alias-ee9.log` and retained
  `build/compatibility-r33-alias-ee9/`. Configuration/manifest proof only.
- **N** — historical ee9 Codex CLI `0.158.0-alpha.2.1`, standard Windows
  workspace permissions and unelevated sandbox: fresh discovery and all six
  OpenSpec phases **passed**, including a separate real spec sync/archive.
  `build/final-canary-native-phases-completed.json` binds the owned root/source;
  [canonical migration](openspec-canonical-migration.md) records native receipts.
  Read-only permission mode **failed** with ConstrainedLanguage on both old r33
  and new helper; standard workspace mode does not disable the sandbox.
- **P** — historical ee9 native Codex marketplace/discovery/disable proof:
  `build/client plugin проба a301248c7a9447b992a9e08401c0b9c6/summary.json` and
  `build/native plugin discovery e439f531-f896-4166-afa4-d7e8071c1811/summary.json`.
  Persisted isolated disable/enable/removal **passed**; the one-call alpha
  override **failed**, retained in `build/client plugin проба e608b6df011f41b5b73e31862dd60335/`.
  Earlier unauthenticated model invocation hit HTTP 401 and stays **unverified**,
  not a passed execution or a proven plugin defect.
- **I** — [runtime inventory](client-runtime-and-ui-owner.md): executable/build
  observations, not discovery/execution or support qualification. PATH absence
  does not establish that a product is absent from the machine.
- **M** — **unverified** live MCP initialize/tool calls, native restrictions and
  role/per-client model selection. Provider timeouts are recorded in
  [provider/Template acceptance](reused-stands-and-template-platform.md).
- **B** — frozen C4 source `6c651f9` with current9ec/r39 real wrapper:
  ensure/read-only doctor/invalid-pin failure passed without project mutation,
  [bridge](plugin-source-bridge-qualification.md). Historical 015 Node
  child-process proof remains [PL3](fork-pl3-qualification.md).
  No authenticated model invocation is claimed; native OpenCode event handling
  has its separate **O** evidence.
- **C** — **passed** current 9ec Full, including the real child-process
  `ManagedPluginDispatch.Tests.ps1` cases; artifact
  `D:/Git/itl_ai_rules_1c-upgrade-20a083e5/build/test-results/qualification/alias-eol-9ec86f7-full.json`.
  This is owner/fixture proof, not a fresh native host session.
- **O** — **passed** current9ec plugin + frozen C4 helper, unmodified bundled
  backend from OpenCode Desktop PE/ASAR 1.18.11, Electron 42.3.3/Node 24.15.0.
  Stock health reports `local`, headless client marker `cli`; real plugin/tool
  loading, invalid-pin event failure and same-profile restore/relaunch were
  observed in [native coexistence](opencode-native-plugin-qualification.md).
  Desktop UI/auto-respawn, separate CLI, tool execution and model remain unverified.

| Client / concrete runtime variants | Fixture config | Native discovery | Native OpenSpec execution | Live MCP / native restrictions / selected role model | Optional plugin |
| --- | --- | --- | --- | --- | --- |
| Codex CLI 0.158.0-alpha.2.1 workspace/read-only; desktop/IDE separate | **passed F**; new9ec **unverified** | CLI **passed N**; desktop/IDE **unverified** | Workspace **passed N**, six phases; read-only **failed N**; desktop/IDE **unverified** | Each **unverified M** | Discovery/persisted disable/enable/remove **passed P**; one-call override **failed P**; model invocation **unverified** (401); no Codex hooks advertised |
| Kilo CLI / editor, native build unobserved (I) | **passed F**; new9ec **unverified** | Both **unverified** | Both **unverified**; native bundle fixture only | Each **unverified M** | Wrapper/event boundary **passed C**; both host hooks and coexistence **unverified** |
| Claude Code, native build unobserved (I) | **passed F**; new9ec **unverified** | **unverified** | **unverified**; native bundle fixture only | Each **unverified M** | Actual host hook/invocation **unverified** |
| Cursor editor launcher 3.21.16; agent CLI separate/unobserved (I) | **passed F**; new9ec **unverified** | Both **unverified**; launcher presence is inventory | Both **unverified**; native bundle fixture only | Each **unverified M** | Actual editor/agent hook and invocation **unverified** |
| OpenCode Desktop 1.18.11.0 PE; stock headless bundled backend (O); separate CLI unobserved (I) | **passed F**; new9ec initialized install **unverified** | Backend plugin/tool registry **passed O**; rules/UI/separate CLI **unverified** | **unverified**; native bundle fixture only | Each **unverified M** | Wrapper boundary **passed C**; real backend coexistence/fault/recovery **passed O**; GUI/auto-respawn/tool execution/OpenCode disable UI **unverified** |
| Kimi, native build unobserved (I) | **passed F**; new9ec **unverified** | **unverified** | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |
| Qwen, native build unobserved (I) | **passed F**; new9ec **unverified** | **unverified** | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |
| Command Code, native build unobserved (I) | **passed F**; new9ec **unverified** | **unverified** | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |
| Cline CLI; editor/older global-only runtime separate (I) | **passed F** project CLI adapter; new9ec **unverified** | Each **unverified**; global fallback is not supplied | Natural route execution **unverified** in each | Each **unverified M** | **unverified**; no host plugin advertised |
| Pi, native build unobserved (I) | **passed F** rules/settings; new9ec **unverified** | **unverified**, including required extension loading | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |
| ZCode, native build unobserved (I) | **passed F** project adapter; new9ec **unverified** | **unverified** | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |
| MiMo Code, native build unobserved (I) | **passed F** rules/settings; new9ec **unverified** | **unverified**, including native JSON/JSONC precedence | Natural route execution **unverified** | Each **unverified M** | **unverified**; no host plugin advertised |

Task 10.3's explicit RQ2 status/provenance criterion is complete for all twelve
clients and their separate variants. This closes the qualification inventory;
unverified native/provider/model capabilities remain unverified. Task 8.3 now
includes the exact observed OpenCode backend route. Provider calls in 10.2 and full
installed journeys in 10.4 remain open. Current candidate Full, a native phase,
MCP call and role/model restriction are different qualifications; they cannot
substitute for one another. Observed executable builds establish the named
tested build only, not a guaranteed minimum supported version.

## Historical runtime qualification — ee9 and earlier

The 2026-09-30 [runtime matrix and UI owner evidence](client-runtime-and-ui-owner.md)
adds actual native Codex plugin discovery/disable, exact host records, and
separate runtime variants. Cursor 3.21.16 is the editor launcher rather than
a qualified headless agent; OpenCode Desktop 1.18.11 was additionally found
outside PATH. Their presence does not qualify live discovery or execution.
Only the named Codex permission mode/CLI build has six actual native phase
passes. Other model/provider/hook capabilities remain explicitly unverified.

## Subsequent exact-candidate qualification — 2026-09-30

Fork `ee9d7b8815bfc32b2182cf7f601d439a843f7a1e`, tree
`03fe3e31770d102fb3eaae44f0b8d023ed9094c0`, passed Full 136/136,
18/18 stages and clean reusable qualification. The source compatibility
script completed exact-commit init/update/doctor for all 12 clients. The
updated acceptance compares phase bytes with its exact source checkout and
rejects retired Codex aliases for the pinned OpenSpec 1.13.1 bundle.

A fresh actual published-r33 source-wrapper update completed at installed
HEAD `20db908b67b36b9cb4f51eab1751f1fc58bd1181`, Git-clean. All six canonical
phase hashes match the helper's exact fork checkout; old `.codex` phase
copies and r33 `.agents/opsx-*` alias bodies/metadata are absent. Native
preflight reports CLI 1.13.1 and the local root. Detailed failure history
and preservation tests are in `openspec-canonical-migration.md`.

Native runtime qualification additionally distinguishes permission modes.
A fresh Codex explore probe in read-only unelevated Windows sandbox stopped
at a PowerShell `DotSourceNotSupported`/`ConstrainedLanguage` error, without
writing documents. Direct sandbox reproduction gives the same error with
the original r33 helper, so this is an existing mode limitation. The new
helper's context action passed in the standard workspace permissions
profile with unelevated sandbox still enabled. Fresh native explore then
passed in that profile: it used the helper and pinned CLI list, confirmed
the exact root/runtime pair and left Git state unchanged (127.61 s).
Native propose also passed: helper-created metadata, proposal/design/tasks,
Context Sources, no implementation, and a passed CLI validation (223.72 s).
The new upstream's documentation-only `skip_specs: true` path was followed
and reported explicitly. Native update passed next (144.44 s): it preserved
accepted decisions, Context Sources and documentation-only scope, updated the
expected two-line content, passed strict CLI validation and did not begin
implementation. Initial apply created the exact expected 65-byte document
(SHA256 `700e8647e84675d3ee3a9482f0fe66868da3740646013c1aa3d3b339e26b7521`)
and evidence, but paused at 1/2 tasks after its generated preservation check
misparsed Git's C-quoted Cyrillic paths. Its exit 0 is not completed apply.
The failure is retained; continuation uses the same scope and requirements
with NUL path transport, without weakening the preservation assertion.
Apply continuation completed 2/2 tasks (367.20 s): strict UTF-8/NUL Git path
transport established the exact permitted new-file set, unchanged tracked/index
state and preserved SHA256 for the other 493 files. The original failure and
its stricter continuation remain in evidence. Native sync correctly returned a
no-op for this approved `skip_specs: true` change (117.33 s), without writing a
main spec. Native archive then passed (172.35 s), using the ITL helper and pinned
CLI, preserving all five moved artifact hashes and the document bytes. Its
archive is `openspec/changes/archive/2026-09-30-native-openspec-canary`.
A second, separately prepared normative delta passed actual main-spec merge
and preservation (175.84 s): one requirement added, the existing requirement
bytes preserved and main-spec validation passed. Its archive exposed a shared
helper argument-list defect. The source fix passed a focused regression and was
installed through the normal workflow updater on that same paused fixture,
preserving all eighteen document/spec inputs. Fresh native archive continuation
then passed (173.93 s), preserving main-spec, first archive, document and moved
artifact bytes. Read-only checks with two real owned roots/runtime pairs also
rejected stale checkout and borrowed CLI bindings and accepted restoration of
the original selection. The first no-op is not used as evidence of a spec write;
full failure and continuation evidence is in `openspec-canonical-migration.md`.
The failed read-only probe
is retained and is not counted as accepted explore execution. No global
client profile or sandbox setting was changed.

## Historical snapshots — 2d3e770 and earlier

The older snapshots below retain their original candidate identities;
they are not exact-tree qualification of this later commit.

Candidate: controlled fork `2d3e7705f79e37a130349b88ecea78b964adabf5`
(`c7e11dd602944e462862e3cd3c6e28b8b58c5dfd` tree), upstream
`20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`. The fork is local and
unpublished; the workflow dependency lock still points at r36.

`scripts/test-ai-rules-compatibility.ps1` cloned that exact candidate and
completed init, byte-idempotent update and doctor for all twelve declared
clients in delegated MCP mode: Codex, Kilo, Claude Code, Cursor, OpenCode,
Kimi, Qwen, Command Code, Cline, Pi, ZCode and MiMo Code. These are isolated
installer/manifest fixtures, not invocations of the client applications. The
exact-candidate rerun also checked that the placed-once root `memory.md`
explicitly retains project-scoped templates memory in managed ITL projects.
The schema-3 overlay verifier and overlay-lock check passed for all 470 path
decisions. The exact candidate passed the fork Full gate: 130/130 Pester,
18/18 stages, `worktreeClean=true` and `reusable=true` in
`build/test-results/qualification/full.json` of the controlled fork.

The source host currently exposes `codex-cli 0.158.0-alpha.2.1` and Cursor
CLI `3.21.16` (`8ae78e8eee1e63479c7e0504b664bc0a80c68000`, x64).
The other ten client executables were not found on this host's PATH. This is
an environment inventory, not a minimum-supported-version claim. A fresh,
ephemeral, read-only `codex exec` session in a disposable project installed
from the preceding fork commit `42a7355530fb0662f38f314b1d865ca4242b4578` reported project-local discovery of
`1c-metadata-manage`, `test-fix-loop`, and all six native `openspec-*` skills
without opening files or invoking tools. Its CLI JSONL record is outside Git
at `%TEMP%/itl codex live 39241acb8eb647a1aa14c84ed6f794a0/codex-discovery.jsonl`;
the recorded usage was 20,697 input tokens (12,416 cached) and 261 output
tokens for that short probe. This establishes Codex's initial skill listing
for this host/version, not execution of a native phase. Model selection, MCP
connection/tool exposure, and a safe provider tool call are still unverified
for every client. Subsequent fork changes clarified README/AGENT-INSTALL,
corrected the OpenSpec config scaffold and delegated MCP plan text; native
skill and adapter bytes are unchanged. The isolated pinned OpenSpec CLI test exercised
version 1.13.1 and local context/new/archive; it did not invoke every native
client phase. These capabilities remain **unverified**, even though their
project files and configuration passed fixture checks.

The same ephemeral read-only Codex probe was repeated with the published-r33
rules commit `9309bfbbc9f8d844a21bce55178c2e0d72eaf965`, the same host and
prompt, and a second disposable project. It reported four native OpenSpec
skills (`explore/propose/apply/archive`) and 19,444 input tokens (12,416
cached). The preceding candidate reported six phases and 20,697 input tokens:
**+1,253 input tokens (about 6.4%)** in this isolated rules-only initial
context. `AGENTS.md` bytes were 13,524 → 13,410; `USER-RULES.md` bytes were
2,000 → 2,334; project skill directories were 31 → 37. The old JSONL record
is `%TEMP%/itl codex old b3590d537090449c8323e9d85a496081/project/codex-discovery.jsonl`.
This is a comparable local probe, not a measurement of the complete ITL
installed workflow or an unchanged-operation runtime cost.

A later read-only `codex exec` probe in the r33→`2d3e770...` disposable installed
project loaded `openspec-explore` but stopped at `OPEN_SPEC_CLI_LOCK_DRIFT`
before CLI execution. Windows Git had converted the pinned `package-lock.json`
to CRLF. The source and installed transport fix subsequently passed an exact
r33 file transition, explicit CLI provisioning, direct `list --json` and
installed `openspec-context`; the native Codex phase has **not** been rerun
after the fix. Details and limitations are in `evidence/openspec-lock-transport.md`.
That interrupted probe consumed 424,336 cumulative input tokens (373,504
cached); it is not a comparable context-budget measurement.

The doctor deliberately distinguishes configured MCP entries from live
callability. `1C-docs-mcp` standards and Templates metadata verification are
separate provider acceptances; neither was live-called by this run. Preceding-
commit Codex local marketplace install/remove was qualified separately; its
plugin-owned bytes are unchanged in this candidate. Plugin host hooks and
disable remain unverified. A later live
acceptance must record client/host version, project pin, active discovery,
provider identity, tool list and safe call result per claimed capability.
