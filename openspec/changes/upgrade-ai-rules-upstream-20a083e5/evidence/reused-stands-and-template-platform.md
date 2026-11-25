# Reused acceptance stands — 2026-09-30

No new user-provided project is required for the current canaries. Existing owned
resources were inventoried before any further stand request:

- Published-r33 installed fixture from `build/final-canary.json`, upgraded with
  exact fork `ee9d7b8815bfc32b2182cf7f601d439a843f7a1e`. Native OpenSpec phase
  evidence is separate from MCP capability evidence.
- Earlier disposable Gate 6 file infobase at `%TEMP%/itl Gate6 живая база
  313bb01ebd714f3fa4f22f260b2cb07a/База 1С`, platform `8.3.27.2130`, with its
  original `src/cf` and `Canary` extension retained. It is not a real PM5 project.
- Earlier isolated plugin-profile packaging proof remains in
  `plugin-qualification.md`; the ordinary Codex profile is not an install target.
- Existing dedicated PM5 E2E root `D:/Git/itl-workflow-e2e-pm5`, clean master
  `fb3ae31b568eebefca771426a3325a528d7397a4`, has a local source snapshot and
  registered disposable worktrees. Older `rel-e2e-r3` is clean at
  `f899f204a145dfbe07c8c7710ad1911c0c061ed6`, its lifecycle lease is terminal
  `succeeded`, and its ready file infobase is inside that worktree. Its old
  verification result is failed, not reusable proof. Current r5 and Develop
  worktrees and the master were inventoried only; none was updated or resumed
  by this inventory. Shared Release checkpoints remain outside this canary.

A subsequent source-wrapper attempt selected only r3, but the public update
owner correctly rejected a direct development-worktree invocation: normal
update starts from master and rolls out to registered branches. This is retained
as a failed probe, not a product defect or accepted branch update. Original r3
HEAD, `src/cf` tree, branch business-state hash and the 3.29 GB infobase SHA256
remained unchanged; the main/r5/Develop heads and owned project/lock hashes also
remained unchanged. Records: `build/pm5-r3-workflow-update-before.json` and
`build/pm5-r3-workflow-update-acceptance.json` (`passed=false`, exit 1). The
probe's optional `HEAD:src/cfe` lookup failed because that tree is absent;
its emitted string is not extension-tree proof. No context guard was removed
and no shared stand master was changed to force this canary through.

## Corrected candidate provenance and read-only doctor

The canonical rules candidate is the exact qualified fork `ee9d7b8`, based on
upstream `20a083e5bd9fa41402ad8428b740c4c01f0cc3d6`. Its release ordinal must
continue monotonically after r36: local canaries now use the immutable label
`itl-main-20a083e5-r37-canary-ee9d7b8`. The earlier r1 label and fixture source
lock that retained the old upstream provenance are not production release
identities. They were not repointed or published. Earlier native phase proof
still identifies its actual rules bytes and fixture; it does not qualify those
incorrect source-lock provenance fields.

A fresh fixture cloned the same actual published-master/r33 install, then
passed the normal source-wrapper update with corrected provenance. Record
`build/r33-provenance-corrected-acceptance.json` identifies source
`a9d36831bfd61186f9e92df0103179eb8fb38ea5`, installed head
`c83e02e4b49936f32ccc36f10c67ff0308116b47`, exact fork and upstream pins.
No infobase was touched. Native phase artifacts remain in the earlier fixture
identified by `build/final-canary-native-phases-completed.json`.

Inspection exposed a real diagnostic mutation: migration planning cleared
stale manifest ownership markers even when called by status. The unchanged
bytes/stale-marker reproducer failed before the fix
(`build/doctor-legacy-readonly-before.xml`). The status path now requests a
read-only plan; marker reconciliation remains with the mutating update owner.
Three focused migration tests passed, including original custom-repository and
USER-RULES ownership contracts (`build/doctor-legacy-readonly-after.xml`). Three
existing doctor/capability tests then passed in 156.54 seconds
(`build/doctor-capability-focused.xml`), covering configured set versus session,
natural OpenSpec mode and twelve concrete adapters without fabricated runtime
callability.

The corrected installed fixture was updated normally to source snapshot
`e898f9ff0efe7a3413c9ee5a9d0edcacf5d66d38`; the exact pinned CLI was explicitly
provisioned before the diagnostic preservation baseline. Installed doctor
passed in 4.88 seconds and preserved all nine selected ownership/configuration
paths, Git HEAD/index and tracked state. It reported correct upstream provenance,
CLI 1.13.1, configured clients separately from the invocation client, and honest
`providerCallability=unverified` / `pluginHostVersion=unobserved` states. No
diagnostic repair or installation occurred. Record:
`build/installed-doctor-readonly-acceptance.json`; diagnostic log SHA256
`b8a3d3e85ee843002f13c629d3ae92ebcc7eb2b3ebcebb68987e5cb4c422ce98`.
This closes diagnostic behavior qualification, not unavailable MCP execution or
plugin host acceptance.

## Actual Template metadata and platform qualification

The existing base was reused with a separate source copy under its ignored
`logs` directory. Qualified fork tools compiled `CanaryTemplateReport`, created
its `MainSchema` DataCompositionSchema Template, then completed the same
descriptor again. The completion preserved UUID
`e6d41542-6134-43f0-8d11-eb8f8577d817`, payload bytes and a single parent
ChildObjects registration. Local `meta-validate` accepted the Template
descriptor and `uuid-check` accepted the actual source tree.

The ITL helper's per-infobase guarded Designer created a nonempty native DT
snapshot, loaded this exact source fingerprint, passed `/CheckModules` in
ThinClient/Server/ExternalConnection modes and `/CheckConfig`, and only then
applied the configuration. Both checks returned exit 0 and fresh DumpResult 0.
The real platform dump contained the Template with the same UUID and payload;
the local descriptor validator also accepted that dumped descriptor. Platform
serialization produced a different payload byte hash, so it is not claimed to
be a byte-preserving Designer round trip. Descriptor completion itself preserved
the original authored payload bytes exactly.

The unchanged DT snapshot was restored through the same guarded Designer owner.
A fresh dump proved restoration of the original configuration UUID and absence
of the canary report. Original source file count and every SHA256 were unchanged.
This proves this concrete Template descriptor, compatible completion and platform
load on the disposable base; it is not acceptance of all template types, MCP
Templates search, representative PM5, or installed branch refresh.

Ignored summary:
`build/template-platform-092a94baf2bb4b7ea148e1d3d67c91ff/summary.json`, SHA256
`43508806915c0b1bc0dccfd4bdf1151c1e61228558a414eaf558f5201e3fac99`.
DT snapshot SHA256:
`37926aff8b9a28b86388ed7f662e2c7279dcf5e7aab7e8af0b4c2fabc21afb9e`.
The first fixture incorrectly put its copied load source outside the selected
project root. The existing path guard rejected it before editable load; its
snapshot was restored and source preserved. The failed record is retained at
`build/template-platform-6d24d9be6b0242d9a16f260dd9e4e50f/summary.json`. Moving
the fixture copy into that same project's ignored area retained the Cyrillic
and whitespace workload and all validation/preservation assertions; no runtime
guard or product contract was changed.

## Earlier live MCP availability boundary

The operator's existing, enabled endpoint selections were read without changing
configuration or copying credentials. Unlike the older registry's proxy ports,
the current profile selects native `dev-ermakov.itland.local` ports 18000 docs,
18001 Templates, 18002 syntax and 18003 Code Checker. Each targeted 20-second
initialize attempt timed out before a session or tool list. DNS resolved the
host to `10.0.12.53`, but the docs-port TCP attempt also failed its three-second
budget. No server/container was restarted, connection disabled, provider
replaced, or repeated polling started.

The four failed `build/mcp-live-{docs,templates,syntax,codechecker}-*/summary.json`
records preserve the observations. These endpoint probes do not establish tool
attachment to this chat. No live validator call, standards retrieval or
templatesearch is reported as passed. Configured/enabled, initialized, tools
exposed and actual tool execution remain separate states. This network/provider
limitation affects the dependent live-MCP acceptance; local Template metadata
and platform checks above remain valid and independent.

## Current r39 Template acceptance — 2026-10-01

The same disposable base was reused with current registered source `ea910da6`
and exact fork `9ec86f75343ba4eded66e2085f097ff4baab7d67`. This is a new run,
not relabelling the earlier ee9d7b8 proof. The original driver created a new
isolated report and MainSchema Template, repeated descriptor completion, and
preserved UUID `6652b196-9e0e-4729-9934-687deb9b095d`, authored payload bytes
and the single parent registration. Six real metadata tooling checks passed.
Guarded native Designer load, unchanged Gate 6 modules/configuration checks,
apply and platform dump passed, followed by DT restoration and proof that
every original source file was preserved. Platform serialization still has a
different payload hash; byte preservation is claimed for completion, not for
the platform's serialization.

Record `build/template-platform-647ef3014b994d15b1a048b4363a2365/summary.json`,
SHA256 `03986926591f273e0e76eb9c194a13f7726b14ce02aaa27454a5ca18deed24b5`,
contains native logs and the unchanged snapshot identity. Snapshot SHA256 is
`83c0b13f3785efa5d08ceacde48cc2676adeb0bf04aff6a81494fa956f069e26`.

Independent current-r39 aggregate acceptance passed 11/11 without mocks:
actual installed Template descriptor and SKD validators, IntegrationService
structural validation, descriptor-only and payload-only scope, two actual
`Assert-OneCConfigurationSourceIntegrity` calls, and four original negative
cases covering registration, name, type and reference integrity. All 16
protected source/script hashes stayed unchanged. The minimal SKD fixture's
two warnings for absent dataset/settings variant are retained, with zero
errors; no check or input was weakened.

Record `build/meta-template-r39-5a6b7eece52647f4a4fe3b4d46b10549/summary.json`,
SHA256 `fcc7fba7ca29bbf0afa36d210d47c3d8bfb356c3eccc86bd4768b6e8771192f3`,
preserves commands, validator identities, original negative cases and their
expected codes. The four installed validator hashes also match the controlled
fork's current tools. This confirms preservation of our configuration Template
integrity checks; it introduces no new template-verification workstream or
automatic generic metadata-validator call for a Template descriptor. The local
aggregate remains authoritative for owner/reference/registration closure.

IntegrationService evidence is structural, not live message exchange. This
small native base does not prove representative PM5 refresh/check/export.
Provider standards/code-template retrieval is now qualified separately in
`mcp-live-availability.md`; general executed agent evaluations are not inferred
from a protocol driver or rendered fixtures.
