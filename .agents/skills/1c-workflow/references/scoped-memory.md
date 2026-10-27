# Scoped Cognee memory

This is the G4 source contract. Native/installed qualification is G5; configuration
alone is not acceptance. Use a matching controlled-fork candidate and ITL host.
The ordinary r47 pin does not enable this route. No Cognee patch, Python runtime,
OpenViking installation, automatic migration or six-store replication is needed.
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
Startup/package update never enrolls old working projects. The old memoryOptIn
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

Private task/workspace/workplace datasets are lazy under the verified principal.
An uncertain creation is reconciled by exact name+native owner; no blind create.
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

`memory_status(local_only=true)` reads compact continuation and pending summaries
without a backend; `note_id` reads the exact pending source. It never scans 1C
state, transcripts or arbitrary logs. The local scan is capped at 24 recent records
and eight summaries; an exact known ID bypasses that listing cap.

`remember(data, dataset_name, note_id?, data_id?, status?, applicability?, evidence?, source?, revision?)`
saves one self-contained fact. Choose the narrowest sufficient destination from
local status. Missing destination/home/grant preserves the private pending source.
Use a stable explicit note ID for correction and the recalled native `data_id`
when this reader has no local receipt. Verified notes need identifiable evidence; product
facts require a confirmed area/home and independence from customer customization.
There is no default global/task destination or automatic organizational promotion.

`recall(query, datasets?, search_type="CHUNKS", top_k<=8)` sends one query over
the union of allowed exact IDs, at most 24 candidates, then checks authorized raw
original/current status/applicability. Stale fragments never override the original.
The optional public `datasets` argument accepts admitted labels, not UUIDs; the
owner resolves those labels to pinned native IDs. Omit it to use the current
admitted union. A lazy task destination without a created dataset is not an
admitted reader merely because local status lists its label.
Full output uses a conservative UTF-8 byte cap below 1600 (including provenance).
An on-recall PS5/.NET BPE counter measures serialized cards for pinned official
cl100k_base/o200k_base vocabularies (2.47 MB compressed assets, MIT license). Eight
frozen `tiktoken 0.12.0 encode_ordinary` vectors cover Russian, BSL, whitespace and
JSON. Non-BMP categories are reported unknown with the retained byte bound.
Mapping the named encoding to the actual client/model and whole-task costs/quality
remain G5; no measurement is invented for another tokenizer or hidden chat framing.
The total deadline is 20 seconds; write/status use 60 seconds. Capped/time-limited
results report partial coverage. Native original lookups are separate bounded calls.

`memory_status(dataset_name, note_id|data_id)` reconciles the exact source and
updates its local receipt/pending. Dataset
pipeline completion is not per-note retrieval proof. `history=true` with an exact
old task label and note/data ID permits history for this workspace; union recall
never includes old cycles. `retire_note` accepts the exact recalled `data_id` when
there is no local receipt; it addresses one note only, never a dataset.
Precise correction updates its original through the qualified native update API.

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
resume retains the reserve. Stale clients cannot write into the next cycle.
Private workspace/workplace and shared scopes survive. Reload after context/cycle
changes. Disabled memory never resets/reinitializes an infobase.

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
Standing/task/reformulation policy remains in the fork. One recall uses allowed
datasets, dedupes 24 candidates, reads at most two originals concurrently in
their original order and returns at most 8 cards/1600 tokens under one 20-second
deadline. A speculative in-flight original at early stop is counted and cleaned
up by this reader. No cross-operation original cache; partial is not absence.
