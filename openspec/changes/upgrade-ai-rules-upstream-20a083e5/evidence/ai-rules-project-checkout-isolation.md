# Project-scoped mutable rules checkout

The actual C3 legacy pair exposed an independent-project collision: r11/Codex
and raw a421/Cursor updates simultaneously used user TEMP `ai_rules_1c`.
The r11 call failed before copy with Git configuration `Permission denied`;
the raw call completed. The unchanged r11 call passed after the cache became
idle. These original failed and serial receipts remain in
[legacy-file-layout-qualification.md](legacy-file-layout-qualification.md).

The owner is still `Sync-AiRules1cCheckout`. Its mutable Git checkout now uses
`ai_rules_1c-<SHA256(canonical project root)>` beneath the existing
`Get-Agent1cTempRoot` result. The identity resolves the full project path,
removes trailing separators and folds Windows case invariantly, then uses the
existing stateless `Get-StringSha256`. Different project roots select different
checkouts; equivalent spellings of the same root reuse the same checkout.

The old shared cache is not read, migrated or removed. No new machine-wide
lock, coordinator, public flag, installed record, barrier or recovery state
was introduced. Repository/source identity, local-source cleanliness,
fetch/retry, tag/ref selection and immutable tag/commit checks remain unchanged.
New clones use existing `Invoke-GitAt` with process Git `core.longpaths=true`
and clone-local `--config core.longpaths=true`, preserving long paths for later
Git operations without registry, elevation or global Git configuration.

## Causal native owner regression

One new case in the existing `AiRulesClients.Tests.ps1` creates two real Git
project roots whose paths contain spaces and Cyrillic, one real local rules
source with two distinct tags, and one owned writable TEMP directory. After
the first project selects tag1, the test keeps its actual `.git/index.lock`
open with an exclusive file handle. The second project must select tag2 without
touching the first checkout, lock, HEAD or configuration.

The unmodified C3 Sync function fails this original workload: project2 attempts
to acquire project1's index lock and throws while checking out its pinned tag.
No lock was removed, assertion relaxed, path shortened or workload changed to
obtain the after result.

| Native Windows PowerShell 5.1 / Pester 5.8 selection | Result |
| --- | --- |
| New real two-project lock/ref case, before source fix | failed, 0/1; exact owned active index-lock collision |
| Same case after source fix, with three existing pin/source cases | passed, 4/4; 31.573 s driver elapsed |

The passing case verifies distinct checkout roots and exact tag commits,
unchanged first-project HEAD/configuration while its lock stays open, unchanged
legacy shared-cache sentinel, clone-local longpaths, same-root Windows
case/trailing-separator reuse with an existing Git-owner marker, and rejection
of a genuine tag/commit mismatch without changing its cached HEAD. The existing
cases additionally prove configured-tag stability after source main advances,
explicit clean local controlled-fork discovery before its tag is remote, and
rejection of an absent immutable fork tag.

Before artifacts:
`build/ai-rules-cache-owner-33c63017ae974307b9eb1d7e07b91719`.
After artifacts:
`build/ai-rules-cache-owner-06a997b27e4b4939a254934d05a039be`.
Both retain Detailed logs, JUnit XML and 66 exact source/test input hashes;
all inputs stayed unchanged during their respective runs. The before failure
result SHA-256 is
`cac8134dfbe99fb67500053150bf133549086762879b2a8316c4532b8472abda`.
After result SHA-256 is
`526445b6cbc6aea2d553d0bd1416925a2a29f56ecf6e92bc2d385485073048cb`;
after inputs SHA-256
`3e8b11977521c92c83f02b52753bc4b5a2ac41505b3e62998a57eb7433cb7128`,
JUnit SHA-256
`11e1050248abc697f02af413e0572e7de5b7d252bcc658e312e2378d1852b084`.

`build/ai-rules-cache-owner-sync-delta.json` compares the current function with
immutable C3 `647df3dafd81c3bf0b18785a6861453fe320d943`: only project cache
identity and clone longpaths changed, leaving pin/fetch policy text identical.
Source and test UTF-8 BOMs are preserved; native PowerShell 5.1 loads both
without parse errors. No broad gate, registration, fork change or publication ran.

## Actual original parallel pair on C4

The same original r11/Codex and raw a421/Cursor projects were exactly restored
before running immutable C4 `6c651f9b164ae1932c65bab661de315640017e83`,
snapshot `ee3d58314a310e42798cd01a186fbae3271d4844`. Their original Unicode and
space paths, authentic old manifests, user additions, native TEMP selection,
profile isolation and acceptance assertions stayed unchanged. The sole product
change from C3 is the qualified project-cache owner repair.

Both public update calls passed in parallel: r11 117.448 s, raw a421 127.550 s,
with 117.448 s of actual native-process overlap. The native cold-clone output
identifies two different checkouts beneath the original user TEMP:

- `ai_rules_1c-0008448d24114a77bbfa1aafddba9321d192ffcb65861b876899c07cb16a87f2`
  for r11/Codex.
- `ai_rules_1c-8451a4e9f8a1e693624dfd926a5f095da5c73b9e0a5326693b8845eb950d8125`
  for raw a421/Cursor.

Both actual checkouts pin the unchanged qualified fork
`9ec86f75343ba4eded66e2085f097ff4baab7d67` and have clone-local longpaths
enabled. The old shared cache's complete 686-file raw inventory, including
`.git`, remained unchanged after the parallel pair and after both guarded
rollbacks. No old-cache Git refresh or cleanup was used.

The original pair proof is
`build/original-legacy-pair-c4-parallel-acceptance.json`, SHA-256
`333a29c69024ca3ababa68947db4f02dd1ac41b9e365677c289538e675a4fccf`.
Final raw shared-cache proof is
`build/original-legacy-pair-c4-old-shared-cache-restored.json`, SHA-256
`85b20369a5dc361bbf993527b85dadd77b3ac2adc3d6acb59b148166f7b0c2ac`.
Per-project sequential repeat/status/guarded restore and byte preservation
are recorded in
[legacy-file-layout-qualification.md](legacy-file-layout-qualification.md).
C3's initial failed parallel call and later serial passes remain historical
evidence; C4's actual overlap closes the observed independent-project
cache-collision defect.
