# Optional scoped Cognee memory

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

This explicit opt-in is separate from project association. Later/off/unattended
updates keep the legacy route. Enable uses one existing pinned applied context,
verifies the ordinary principal, allocates the initial cycle without resetting
the base and sends the stdio contribution through the existing client writer.
Reload the client; actual tool exposure, access and durability need actual calls.
Disable preserves datasets, source, pending and receipts. It removes only the
managed contribution for the selected clients; retained old processes fail the
binding check. External MCP and explicit disabled preferences retain their owner.
For writer conflict/partial apply use the same catalog status/resume/restore;
there is no memory updater or retry queue. Explicit enable may be repeated after
recovery; stable IDs are retained.

Keep the settings and ordinary-user token in the existing user-local MCP home
(`%LOCALAPPDATA%/ITL/MCP/vibecoding1c`), outside the project/Git/reset tree.
The token file is `{ "accessToken": "<ordinary user token>" }`; never print it.
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
An administrator prepares shared product/project/organization IDs and grants;
append explicit mappings to settings:

```json
{
  "scopeKind": "project", "scopeId": "<projectId>",
  "label": "itl_project_<projectId>", "datasetId": "<native UUID>",
  "ownerId": "<native owner ID>", "permissions": ["read", "write"], "admitted": true
}
```

Labels are routing metadata, not ACL. Mapping/grant admission comes from native
evidence/operator preparation; normal calls still enforce Cognee ACL. No shared
dataset is silently created under a developer. R6 currently assigns no product
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
known correction/deletion and A/B/outsider grants through the qualified procedure;
unknown scopes stay unadmitted. Re-enable only confirmed mappings, reload into a
fresh context and re-read originals. Local source/independent workflow remains
available while the port is closed; no new epoch/backup/admission service exists.
Use explicit `admitted=false` for retained unknown mappings, including private
ones; disable/enable preserves IDs and honours that explicit denial.
