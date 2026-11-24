# Scoped Cognee memory

This is the G4 source contract. Native/installed qualification is G5; configuration
alone is not acceptance. Use a matching controlled-fork candidate and ITL host.
The ordinary r47 pin does not enable this route. No Cognee patch, Python runtime,
OpenViking installation, automatic migration or per-scope replication is needed.
The existing dependency lock and `.ai-rules.json` must identify the exact qualified
candidate and own the selected installed `project-memory` file without an override.
The approved clause hash is checked as well; an ad hoc copied marker is insufficient.

## Enable / status / disable

First finish the existing registry association/apply. Use the existing helper:

```powershell
& $helper -ProjectRoot $root -Action vibecoding1c-mcp-select -MemoryAction enable `
  -Client cursor -MemorySettingsPath $privateSettings -MemoryPolicyPath $installedProjectMemoryRule
& $helper -ProjectRoot $root -Action vibecoding1c-mcp-status -MemoryAction status
& $helper -ProjectRoot $root -Action vibecoding1c-mcp-select -MemoryAction disable -Client cursor
```

Memory defaults on after ready explicit association or completion of a new
initialization, without another memory prompt. Common qualified settings live
at user-local MCP home/memory/provider.json; explicit enable establishes this
connection. Missing prerequisites mean unavailable/unconfigured and do not block
the catalog. Explicit off/disabled persists, including before the first binding.
Startup/package update never enrolls old working projects. Memory is enabled per
working copy, not per client: in a copy with an enabled binding, every owner
rewrite of a client configuration, update-workflow included, records the proof
and adds the endpoint for a client installed later whose own installed policy
qualifies; a plan only shows it. The old memoryOptIn
flag can be an automatic default: ambiguous provenance requires explicit setup.
`-MemoryAction auto` retries this setup after prerequisites are supplied;
explicit enable can override disable. Enable uses the applied pinned context,
ordinary principal and initial cycle without resetting the base, then the same writer.
Reload the client; actual tool exposure, access and durability need actual calls.
Disable preserves datasets, source, pending and receipts. It removes only the
managed contribution for the selected clients; retained old processes fail the
binding check. External MCP and explicit disabled preferences retain their owner.
For writer conflict/partial apply use the same catalog status/resume/restore;
there is no memory updater or retry queue. Explicit enable may be repeated after
recovery; stable IDs are retained.

Keep the settings and ordinary-account credentials in the existing user-local MCP home
(`%LOCALAPPDATA%/ITL/MCP/vibecoding1c`), outside the project/Git/reset tree.
Use `{ "apiKey": "<ordinary-account API key>" }` for the shared connection.
Native Cognee API keys use `X-Api-Key` and, in the qualified 1.6.5 deployment,
have no automatic expiry; they remain valid until revoked. An operator creates
the key through native `/api/v1/auth/api-keys` under the same ordinary account.
Never print it or put it in the registry, project, tool arguments or model context.
Legacy `{ "accessToken": "<ordinary user token>" }` remains supported as Bearer
authentication, but its login lifetime is not extended or refreshed by the adapter.
If both fields are present, `apiKey` takes precedence; a failed key is never
retried with Bearer. Credentials are reread for each request, so an operator can
replace the private file atomically before revoking the old key. Rotation keeps
the same principal and dataset IDs; it does not re-enable clients or replay writes.
The provider settings shape is:

```json
{
  "profile": "cognee-1.6.5-g1-c",
  "qualificationResultSha256": "be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d",
  "instanceId": "<explicit deployment identity>",
  "url": "https://<qualified Cognee root>/",
  "principalId": "<authenticated ordinary user ID>",
  "organizationId": "<explicit organization ID>",
  "credentialFile": "C:/Users/<user>/AppData/Local/ITL/MCP/vibecoding1c/credential.json",
  "toolPolicy": "auto",
  "datasets": []
}
```

The profile references the frozen G1 image, OpenAPI, models and ACL mode in
`assets/scoped-memory-policy.json`. It is an operator-selected qualified profile,
not automatic deployment/version attestation. If that deployment differs, qualify
the affected capability first; copying the label/hash does not qualify a server.
Only native ordinary-principal calls prove current rights. The adapter consumes
native exact-ID REST; it does not modify a server or provision an administrator.

Seven scopes: task cycle, workspace, workplace, host, product, project,
organization. `workspace` is the local project: the main copy together with all
of its branch copies, keyed by the main copy that lifecycle records for a branch
(`localProjectId`). Two main copies of one registry project stay different
workspaces. `workspaceId` keeps meaning the branch copy and still keys pending,
continuation and the lifecycle cycle; notes of a former per-copy workspace
dataset are not migrated and stay readable by exact ID with `history=true`.
`host` is one dataset per machine, shared by every project and Windows user that
works under the same technical Cognee account, for environment facts only
(platform, cluster, licences, tools). Its key is the Windows `MachineGuid` plus
the host name, read without elevation; without that value only this scope is
unavailable. `workplace` stays one Windows user on one machine.

Private task/workspace/workplace/host datasets are lazy under the verified
principal. Before creating one the adapter looks it up by exact name and native
owner and adopts it; after creating it confirms a single match, otherwise the
write is refused and nothing more is created. A reader adopts an existing
workspace, workplace or host dataset by exact name and owner. A reader creates
nothing. An uncertain creation is
reconciled the same way; no blind create.
An operator prepares shared product/project/organization IDs using the same
ordinary technical connection and appends verified mappings to settings. The
first release has no employee/group/outsider permission matrix. Keep the existing
technical `permissions` field fixed at read/write and `admitted` as mapping and
restore readiness, rather than membership:

```json
{
  "scopeKind": "project", "scopeId": "<projectId>",
  "label": "itl_project_<projectId>", "datasetId": "<native UUID>",
  "ownerId": "<native owner ID>", "permissions": ["read", "write"], "admitted": true
}
```

Labels are routing metadata. Mapping admission comes from native evidence and
operator preparation; normal calls still authenticate the common ordinary
account. No shared dataset is silently created under a developer. R6 currently assigns no product
homes: product writes remain unavailable until explicitly confirmed in registry.

## Agent operations

`memory_status()` at session start returns the local part below and, within one
15-second deadline, the server part: `standing` notes of the admitted scopes in
full (`level`, `dataId`, fact; a product rule also names its dataset, since
that level may hold several; `memory_status(dataset_name, data_id)` returns the
note ID for a correction) and `index`, per level the titles of the
other notes, verified unless marked `[candidate]`, plus `more` for what is not
shown. It replaces a separate standing query; topical `recall` stays required.
The index comes from one listing per dataset (one page, up to 1000 documents,
two requests in flight). Originals are read only for standing notes, which are
confirmed and fully checked by their original, and for at most six names of the
previous format; index rows carry no IDs and only the knowledge area of a
product row is checked. Order: project, workspace, organization, product, host,
workplace, task; inside a level verified before candidate, newest change first.
Maxima (standing/index rows): task -/10, workspace 2/10, workplace 3/10, host
3/10, project 5/30, product 3/20 per level, organization 5/30. The whole answer
is bounded at 3000 tokens by the recall counter; what does not fit is counted in
`more`. At session start `receipts` lists only writes still to reconcile;
confirmed ones are noted in `confirmedReceipts` and `local_only=true` lists them.
Index titles give way first, then those receipts (`localTrimmed`), then standing
notes. `serverCoverage` is `bounded`, `partial` (named datasets or originals
not read in time) or `unavailable`: then the local part is still returned and a
missing index is not absence of knowledge. No cache between operations.

`memory_status(local_only=true)` reads compact continuation and pending summaries
without a backend; `note_id` reads the exact pending source. It never scans 1C
state, transcripts or arbitrary logs. The local scan is capped at 24 recent records
and eight summaries; an exact known ID bypasses that listing cap. `destinations`
offers the write choices project, organization, workplace, host and task. A row
names its `scopeKind`; `dataset_name` and recall `datasets` accept that kind
(`task` too) and the server resolves this copy's exact label, which stays
accepted. A kind naming no single dataset, such as several product homes, needs
the exact label. The
project row lists the `knowledgeAreas` that route to a writable product home;
product rows are not offered. The local-project workspace stays readable and an
explicit workspace or product label is still accepted, but neither is offered.
`writeGuidance` explains the routing. Each row has `readState`:
`admitted` means the binding admits
its exact ID; `not_created` means the server listing confirmed absence under
the expected owner, so the row can still be used for a first write; `unknown`
means read access or existence is unconfirmed. Offline status reports
`admitted` or `unknown` using the local binding. Use `serverCoverage` for the
outcome of the current server reads.

`remember(data, dataset_name, note_id?, data_id?, status?, title?, applicability?, evidence?, source?, revision?)`
saves one self-contained fact that would change work in another session or
branch. A note is knowledge, not a work log: progress, run and attempt numbers,
SHAs, line numbers, counters and statuses stay in the `memory_status`
checkpoint, OpenSpec, evidence, Git or test results. `data` is at most 600
characters on every level: rule, why, when to apply, conditions and versions;
proofs go by reference in `evidence` and conditions in `applicability`, outside
that limit. A longer `data` is refused with `MEMORY_NOTE_TOO_LONG` before any
backend call; the pending source is kept and `remember` with the same `note_id`
and shortened data completes it. Notes stored before the limit are read as before.
While scoped memory is connected to Claude Code in an ITL project, ITL turns off
Claude's built-in auto memory (`autoMemoryEnabled: false` in
`.claude/settings.local.json`, unless the user set that key). An open Claude
chat can retain an earlier personal-memory instruction after the MCP tools
appear. Save durable lessons through scoped remember. On first connection
during a 1C task, read status and search the active topic before the next
related edit or check if it has not been searched successfully in this chat.
A successful empty search counts. Start the next independent task in a fresh
Claude chat after an update that first connects Cognee or turns off auto memory. A workaround for an ITL defect goes to one
`organization` note titled `Дефект ITL <CODE>@<owner>: …` with the same
`applicability.incidentKey`, never to project or client memory, as described in
`references/workflow-incidents.md`. When the installed
`references/known-defects.json` lists that key as fixed, `memory_status` names
the note in `fixedDefectNotes` with `fixedIn`; recall it for its `data_id` and
retire it.

| Choice | When to use it |
| --- | --- |
| project | A confirmed decision, fix, constraint or lesson for other branches or copies of the project, including customer customizations. Add `applicability.knowledgeArea` for base-product behaviour. |
| `organization` | Confirmed knowledge across projects and products (platform, BSP, tooling, company conventions), never client, project or configuration data. Organizational `standing` needs explicit user direction. |
| `workplace` | A practice of the same `workplaceId`. |
| `host` | Machine environment, such as the platform version or tool location. |
| `task` | Only the user's decisions and permissions for the current cycle, such as an approved exception or a chosen release version. Never a run result or interim state. |

A project write with `applicability.knowledgeArea` goes to the product home
when the area is applicable, has exactly one confirmed home among admitted
writable products, the note is not `candidate`, and the project is not
customized or `applicability.independentOfCustomization=true`. Otherwise it
stays in the project. An unsent draft that was already attempted and an
existing project note keep their dataset. The answer names `routedTo` and
`routeReason`: `product-home`, `no-area`, `candidate`, `area-not-applicable`,
`ambiguous-home`, `customization-unproven` or `existing-note`. An explicit
product label keeps its own rule (`MEMORY_PROJECT_CANDIDATE`).

For a project fix, record source branch and commit or a checked diff reference,
affected objects, applicable conditions and verification evidence. Put supported
machine-readable conditions and version bounds in `applicability`. Before
claiming the fix is present in another branch, check its current code and the
relevant test if needed. A confirmed original can inform analysis or a proposed
port if the branch lacks the fix. Record uncertainty when applicability is unclear.

Missing destination/home/grant preserves the private pending source; the
refusal names its `note_id` and both ways on: repeat `remember` with that ID and
a `dataset_name`, or `retire_note(note_id)`. The default note ID is derived from
the branch copy, project and fact, not from the destination, so repeating the
same fact with a chosen dataset completes the same pending record.
`status` is `candidate`, `verified` or `standing`. `standing` is a confirmed
working rule stated by the user: it needs evidence like `verified`, at most 400
characters, never the task scope, and at most the level maximum above (checked
by the target dataset's listing); a refusal keeps the pending source and says to
shorten it, save it as `verified` or move another note to `verified`. It is
stored as `status: verified` plus `standing: true`, so a copy on the previous
workflow reads an ordinary verified note; `verified` and `standing` are switched
by updating the same note. A user statement uses evidence
`{source:"user", reference:"chat <date>"}`. Optional `title` (80 characters)
names the note in the index, else its first sentence does. Either states the
claim, not its topic: `Date() takes three or six parts` lets an agent act on
the index line; `Date() parameters` sends it to recall.
Each note is one uploaded file, on creation and on update. Its document name is
`<status>~<knowledge area>~<title>~<id8>.txt`: derived from the original, unique
per note, without path separators, at most 200 UTF-8 bytes, replaced on every
update. A `409` for a taken name is reconciled by exact note ID, not replayed. A
name of another format (a note last written by a copy on the previous workflow)
is not an error: its row is read from the original.
An unsent draft (local `sent=false`) is completed under the same note ID with
changed status, evidence or destination; replaced intents stay in its private
record. A sent attempt keeps exact-ID reconciliation and its destination.
Use a stable explicit note ID for correction and the recalled native `data_id`
when this reader has no local receipt. Verified notes need identifiable evidence; a
user-confirmed decision, correction or standing condition is verified by that
confirmation. `recall` omits `candidate` notes; local status lists durable own
`candidates` until the same note is verified with evidence or retired. Product
facts require a confirmed area/home and independence from customer customization.
There is no default global/task destination or automatic organizational promotion.
The informational memory line of `/itl-check` lists up to eight titles of notes
saved from this copy in the current cycle with their level, newest first, from
local sources only, so the agent reviews them before completion.

`recall(query, datasets?, project_id?, search_type="CHUNKS", top_k<=8)` sends one query over
the union of allowed exact IDs, at most 24 candidates, then checks authorized raw
original/current status/applicability. Stale fragments never override the original.
Groups of datasets are interleaved so a large dataset cannot starve a small one;
inside each group, fragments beyond the calibrated relevance threshold are
dropped before originals are read. `CHUNKS` uses the native cosine distance with
a maximum per qualified profile in `assets/scoped-memory-policy.json`
(`cognee-qwen4096-v1`: 0.40); `CHUNKS_LEXICAL` has no native score and keeps a
fragment holding at least half of the query terms. A profile without a rule
drops nothing. `belowThreshold` counts dropped fragments; no remaining card is
not proof of absence. `coverage=partial` means incomplete coverage (a failed or
late group, an unattributed fragment, an unread or inapplicable original);
reaching `top_k`, the candidate cap or the token cap sets `truncated=true`
instead. Calibration: improve-memory-content-quality evidence.
The optional public `datasets` argument accepts admitted labels, not UUIDs; the
owner resolves those labels to pinned native IDs. Omit it to use the current
admitted union. An explicit list is validated before search. The denial names
the label and says whether its dataset is absent, outside admission, or
unverified. Correct the list or omit it to use the admitted union.

For a deliberate comparison, use `project_id` with a registry project ID and
omit `datasets`. The adapter searches only that project's dataset if its
pinned mapping is admitted for read and Cognee lists the same ID, label and
owner under the current account. The search uses the existing operation budget.
Cards carry `source.projectId` and `source.referenceOnly=true`; their
applicability describes the source fact, which the caller checks before using
it in the current project. Source standing notes are returned as references.
Full output uses a conservative UTF-8 byte cap below 1600 (including provenance).
An on-recall PS5/.NET BPE counter measures serialized cards for pinned official
cl100k_base/o200k_base vocabularies (2.47 MB compressed assets, MIT license). Eight
frozen `tiktoken 0.12.0 encode_ordinary` vectors cover Russian, BSL, whitespace and
JSON. Non-BMP categories are reported unknown with the retained byte bound.
Mapping the named encoding to the actual client/model and whole-task costs/quality
remain G5; no measurement is invented for another tokenizer or hidden chat framing.
Recall has a 20-second operation budget, overview status has 15 seconds,
and exact status and writes have 60 seconds. Discovery of unmapped private
datasets shares one listing and a deadline of at most two seconds inside recall
or overview status. If nothing needs discovery it is skipped. Confirmed absence
leaves coverage intact. An incomplete listing or adoption leaves unread scopes
`unknown`; the request closes and proceeds over admitted IDs in the remaining
time. Recall reports `coverageIssues` with the affected scopes and reasons,
including `operation_deadline` when original reads run out of time. If no time
remains before search, the operation reports a deadline failure.

A native `memory_warming_up` response indicates no indexed notes in the searched
datasets; coverage is `empty` when discovery has no outstanding issues. A
temporary recall failure leaves coverage unknown for that call. If the fact is
needed, use exact status for a known original. For unavailable coverage, retry
recall once with the same topic and scope before the next related edit or check. After another failure, continue with
available sources and report the gap. Recall once per topic before designing a
change, and by tool and action before writing a test or setting up a stand.
Search again for a new area or object, missing context, after such a failure,
or by symptom before retrying an unexpected failure (the exact error text with
`CHUNKS_LEXICAL`), not merely because a new turn started. Pitfalls are rarely
found by task topic: on PM5 memory (2026-11-20) topic queries returned 2 of 12
known pitfall notes, symptom queries 12 of 12. Reconcile uncertain writes by
exact IDs.

`memory_status(dataset_name, note_id|data_id)` reconciles the exact source and
updates its local receipt/pending. Dataset
pipeline completion is not per-note retrieval proof. `history=true` with an exact
old task label and note/data ID permits history for this workspace; union recall
never includes old cycles. `retire_note` accepts the exact recalled `data_id` when
there is no local receipt; it addresses one note only, never a dataset.
`note_id` alone discards only an own unsent draft, keeping a private audit copy;
retiring a note also discards its unsent update. A draft that was already sent
is reconciled by exact `memory_status(dataset_name, note_id)` first.
Precise correction updates its original through the qualified native update API.

A rejected or unconfirmed remember returns a tool error with the pending note ID.
Only a durable receipt confirms a save. A definite HTTP refusal reports its status;
after resolving it, retry the original arguments and note ID once. A timeout,
unresolved name conflict or older refusal without a recorded cause requires an
exact status lookup. Keep the pending source when there is no matching original.

Pending/source and receipts remain private outside reset. After durable receipt,
the pending owner saves its exact source separately and removes pending while
holding its stable private record guard, so completed notes do not crowd out unresolved notes.
Exact local note ID can read preserved source; it is not backend-currentness proof.
An ambiguous response
does not cause another POST/provider write: reconcile exact ID first. A bounded
lookup that found nothing is not proof of rejection. The attempt pins its exact
dataset, instance and principal; another label/provider cannot silently replay it.
No background replay exists.
`memory_status(checkpoint={goal,constraints,nextStep,proofs})` stores at most 4 KiB
of continuation, not a conversation. Strict root memory eligibility is unchanged.

## Cycle / recovery

Lifecycle owns current/reserved cycle IDs in its existing branch record. Reset
reserves once before replacement and activates only at successful completion;
resume retains the reserve. Private workspace/workplace/host and shared scopes
survive. Disabled memory never resets/reinitializes an infobase.

The binding gets a new `bindingId` only for a new task cycle (branch reset),
another project or product, on disable, and once when a binding of the previous
workflow is extended with `localProjectId`/`hostId`. Workflow, MCP, rule, policy
acknowledgement, connection setting and knowledge-area updates change it in
place. The extension keeps format version 1: the previous helper reads it after
a rollback, and its still-running server gets `MEMORY_STALE_CONTEXT` once and is
reloaded. Until extended, only workspace and host are unavailable.
The memory server rereads the binding before every call. An in-place update is
followed silently. Another `bindingId` of the same copy is followed too and the
answer carries `contextChanged` (`reason` cycle, project, product or binding,
previous and new cycle). After a cycle or project change the first `remember`,
`retire_note` or checkpoint is refused with `MEMORY_CONTEXT_CHANGED` (a refused
`remember` still keeps its pending source) until `memory_status`; reads continue
at once. This knowingly lets an old chat write into the new cycle after one
`memory_status`. Another copy, disabled memory and a reset in progress are still
refused; an unknown binding format answers "reload the client".

A private record that another operation holds or replaces is read up to three
times, then `MEMORY_RECORD_BUSY`: repeat the same operation.
`MEMORY_RECORD_INVALID` means damaged JSON and names the record kind (`binding`,
`branch-state`, `pending`, `receipt`, `continuation`, ...);
`MEMORY_RECORD_TOO_LARGE` is its own code. An owner refusal reaches the agent
with its continuation text; an unexpected cause stays in the client log.

Every call adds one entry to a private journal of the branch copy
(`memory/usage/<hash>.json`, last 200): tool, time, server-process session,
cycle, `ok` or the error code with the record kind, counts of cards and of
saved, updated and retired notes. New recall entries record elapsed milliseconds,
timings for principal, discovery, search and original reads, the failing stage
when known, and the result or coverage issues. Successful saves and updates
include the scope kind. Older entries remain readable. The journal contains
technical fields only. A journal failure
changes no call. `vibecoding1c-mcp-status -MemoryAction status` returns its
summary for the current cycle as `usage`; a passed `/itl-check` prints one
informational line while memory is enabled and is never blocked by it.

The existing pre-copy package compatibility guard refuses an older helper while
memory is enabled. Disable with the current helper, reload, then repeat the exact
update. Pending/receipts remain readable through the retained compatible helper;
no backward database or note migration runs. Existing writer backups/receipts own
MCP resume/restore; native backend restore remains the qualified Cognee procedure.

For a backend restore, the operator disables memory with this owner and closes
the ordinary Cognee port before native restoration. Recheck exact originals,
known correction/deletion through the qualified procedure;
unknown scopes stay unadmitted. Re-enable only confirmed mappings, reload into a
fresh context and re-read originals. Local source/independent workflow remains
available while the port is closed; no new epoch/backup/admission service exists.
Use explicit `admitted=false` for retained unknown mappings, including private
ones; disable/enable preserves IDs and honours that explicit denial.


## Search and budget

Known dataset/data ID uses exact memory_status. Choose CHUNKS for meaning or
qualified CHUNKS_LEXICAL for exact terms/errors, never both automatically.
Task/reformulation policy remains in the fork; standing rules come from `memory_status`. One recall uses allowed
datasets, dedupes 24 candidates, reads at most two originals concurrently in
their original order and returns at most 8 cards/1600 tokens under one 20-second
deadline. A speculative in-flight original at early stop is counted and cleaned
up by this reader. No cross-operation original cache; partial is not absence.
