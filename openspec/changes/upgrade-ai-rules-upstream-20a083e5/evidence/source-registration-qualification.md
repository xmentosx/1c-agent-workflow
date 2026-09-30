# Source registration qualification

The first `RegisterChange` for source commit
`fffaa4f34cece9845cbf775a97cacd5e07c4a2b3`, based on
`69612acc8cabecf8ee55f3aa485e999c774a73c7`, failed its owned Targeted gate:
366 passed and 22 failed in 594,414 ms. The runner stopped scheduling further
shards after failure. These counts do not qualify the remaining selection.
No queue entry was registered; the four unrelated entries and their ownership
were preserved, and subsequent read-only status reported `activeOperation=null`.

The original attempt is retained under `build/source-registration-attempt-fffaa4`.
Its shard summary SHA256 is
`69a1d05e6809a450705f42b14ca1aa7309164f8de6d83a2debdda4d1de05543f`.

## Documentation and diagnostic capture

Two BootstrapUpdate failures exposed a recovery paragraph placed between the
action-catalog heading and its list, two undocumented one-off actions, and lost
Vanessa authoring guidance. The guide now retains its original small-suite
heuristics conditionally: first decide current proof and retention; when retaining
new coverage, start with 1-2 representative integration/UI scenarios, parameterized
YAxUnit boundaries and one focused quick-fix regression. This does not reinstate
mandatory test retention rejected by D3.

The doctor failure was caused by `Out-String` formatting an InformationRecord and
wrapping its long capability message before the existing assertion. The test now
captures each original logical message before formatting. The actual doctor,
read-only checks, fixture paths, configured Kilo membership and before/after file
hash assertions are unchanged.

The same three cases passed in Windows PowerShell 5.1.26100.9549/Pester 5.8.0,
with unchanged recorded inputs. Diagnostic evidence:
`build/registration-docs-doctor-focused/result.json`, SHA256
`e3cc10eed82228974ef470040f8f2fea5bf125c64bdff64885bceb9464cd567d`.
Earlier partial and PowerShell Core diagnostic attempts are retained separately;
their harness accounting is not native acceptance.

## Existing Gate 6 load regressions

Nine existing cases assumed the old combined load/apply call and supplied no
rollback DT or fresh platform-check outputs. Their snapshot rejection was the
accepted EV8/D4 fail-closed behavior. The fake Designer boundary now produces
non-empty DT bytes and fresh Out/DumpResult artifacts. Snapshot selection,
verdicts, apply authorization and restore duty/hash validation remain real.

The original partial/full inventory, target paths, drain, failure/fallback,
diagnostic logs and state assertions remain. Load-attempt counters are explicitly
distinguished from the complete native-command sequence, which is independently
asserted. The former blanket textual warning-flag prohibition now checks ordinary
main apply, strict extension apply, rejected check warnings and rollback before
apply. No test is skipped and no runtime implementation was changed for these
cases. This is fixture proof, not another native 1C acceptance.

All nine passed in native Windows PowerShell 5.1/Pester 5.8.0. The combined frozen
test SHA256 was checked before and after:
`a675aa9feb3b3c6ea657ef4a7442165498dc699f566cf2399aa3d5696da67cbe`.
Evidence: `build/dev-branch-gate6-fixture-focused.json`, SHA256
`10f5495c2e6a16f9ff104499e284ed23b42de381fd91a7d8b4a9124871b70061`.

## Verification and client prerequisites

The remaining ten original failures were reviewed against EV3 and CL1. The
canonical fingerprint assertion must expect schema v5 while retaining all
content/staging/commit invariants; v4 remains an explicit stale negative case.
Corrective-refresh fixtures must supply current fingerprint and loaded-base
identity. A status-only `passed` is separately required to leave recovery pending
and state unchanged. Kilo-only initialization/MCP fixtures must identify their
Kilo execution target explicitly; attaching Codex or rewriting their membership
would change the original workload and is not the repair.

All twelve selected cases passed in Windows PowerShell 5.1.26100.9549/Pester
5.8.0, including the existing negative membership control. Both test files were
unchanged after execution; original Git paths, clients and workload were retained.
Evidence: `build/dev-branch-existing-focused-winps5.json`, SHA256
`3e51bdc299fc1ca01df20dc082ce761eecd6c0ce56023612f56dad69f03394e0`.

The three focused batches therefore passed 24/24. This does not substitute for
the subsequent script-owned Targeted registration gate. That gate's exact-tree
result and atomic queue receipt belong to the shared delivery ledger; publication
and project rollout remain separate steps.

## Second registration and read-only MCP status repair

The second `RegisterChange` for source commit
`435ee8fa0d11101f744f66e9270b692705256510` failed after 605,906 ms:
457 passed and two McpConfig cases failed. Previously repaired complete files
passed: BootstrapUpdate 73/73, ClientAdaptersAndModes 33/33 and
DevBranchLifecycle 238/238. Further unscheduled files remain unqualified.
The clean-tree attempt is retained under `build/source-registration-attempt-435ee8`;
its shard-summary SHA256 is
`5177d1887e1932cb08f7df8a3817bbde590c86e0a41b4216e44d2946ca8c5f74`.
No queue entry or publication resulted from this failed attempt.

The original implicit MCP status case exposed an actual CL1 runtime regression:
when the verified invoking client was not attached, status stopped inspecting
existing configured clients and falsely reported missing MCP configuration.
The existing status owner now inspects only the attached actor, or, for typed
NOT_ATTACHED/AMBIGUOUS selection outcomes, the validated configured set. A bounded
read-only scope line distinguishes that inspection from the unavailable actor's
own connection. No membership, actor, manifest, configuration or write authority
is changed. Other selection/manifest errors retain no-inspection behavior.

The PM4 BookStack cleanup case instead had a missing Kilo actor prerequisite:
its client-sensitive writer now explicitly names the original configured Kilo
client. Codex and external BookStack sentinels and original assertions remain.
The original implicit common-status reproducer has no actor override.

Native Windows PowerShell 5.1/Pester 5.8.0 first reproduced both failures with
three successful negative controls. After repair, 10/10 passed, including
singleton/multiple unattached, ambiguous, attached-self-only, invalid manifest,
missing actual configuration and existing membership guards. Test files remained
unchanged after execution. Evidence:
`build/mcp-config-current-focused-after-winps5.json`, SHA256
`90fab4dd88710da0f67307d8c129b1329132f4db673a4356db4cece460e4fda4`.
This is owner-focused runtime/fixture proof; external provider execution and the
next complete script-owned registration gate remain separate qualifications.

## Kilo provenance fixture

A read-only audit found the same missing actor prerequisite in the original
Kilo-only installed-skill provenance case. Its native before run failed through
NOT_ATTACHED, while preserving verified Codex markers and original test inputs.
The helper invocation now explicitly identifies Kilo; project membership,
provenance/cache-visibility assertions and configuration are unchanged.
The same native case passed 1/1 after repair with unchanged owner/test hashes;
`build/kilo-provenance-before.*` and `build/kilo-provenance-after.*` preserve both
outcomes. No client was attached and no skill-cache visibility was inferred.

## Causal controls preserved before the next gate

Two further original negative assertions could pass for unrelated reasons.
The native observer showed the YAxUnit applicability proof already stale before
its decision changed because loaded identity was missing. Its original Unicode,
legacy-baseline, dirty source and catalog assertions remain; the existing evidence
producer now supplies a complete synthetic loaded-target prerequisite, and the
case proves fresh-passed before versus stale after the applicability change,
with unchanged loaded identity. This remains a unit fixture, not native 1C proof.

The original four-phase OpenSpec case stopped at unattached Codex, then at an
incomplete USER preflight when Kilo was explicitly identified. Original legacy
USER bytes are retained as a negative control with a hash invariant. With the
current managed USER prerequisite, the same four original workflows/integration
bytes and hashes now reach and require OPEN_SPEC_CLI_NOT_PROVISIONED. Existing
direct-planning and unavailable-command assertions remain.

The exact two cases passed in native Windows PowerShell 5.1/Pester 5.8.0, before
and after correction; the read-only observer retained both masking causes.
The after run passed 2/2 in 18.86 seconds with owner/test inputs unchanged.
Evidence: `build/causal-prerequisites-after.json`, SHA256
`fbb746f788a67f4a98c34fcbd79d303167cbedfc9a88da82a49c4b68827ec041`.

## Third gate and measured on-demand guide limit

The third RegisterChange on `dee4d308b40844fe4b8e592919ddbff48e383680`
finished with 582 passed and one documentation-budget failure in 204,385 ms.
Seven successful files were reused under exact owner-input identity; five ran.
McpConfig passed its complete 53/53 and OnDemandMcp 56/56. Unscheduled files
remain unqualified. Original artifacts are retained under
`build/source-registration-attempt-dee4d30`; shard-summary SHA256:
`77807be654c44210d8c18aa2a59802343aca1cbbdc9dba2295c7caee2eabc2ff`.

Restoring retained-suite authoring guidance conditionally increased the measured
C4 Vanessa guide from 1439 words/2618 byte-4 proxy tokens to 1464/2656: +25 words
and +38 proxy tokens in an on-demand reference. No safe duplication was removed
merely to meet the count. Its explicit maxWords changes 1450 to 1475, preserving
the original eleven-word margin; review 2500 and hard 2800 proxy-token thresholds
and all semantic requirements remain. This follows the package's explicit
measured-budget policy and does not add always-on context. The other seven
budgeted documents remain within their hard limits.

The original complete budget case passed 1/1 in native Windows PowerShell 5.1 /
Pester 5.8.0. Guide and test hashes were unchanged during the focused run.
Evidence: `build/vanessa-budget-focused-winps5.json`, SHA256
`e85c228d4515bcc42870eec993711c4d8de1f295dff64c807de0812cd1910103`.

Independent native public source status calls also passed for inherited
unattached Codex and explicit attached Kilo: both exit 0, empty stderr, exact
configured endpoint and all original status groups. Read-only scope is explicit
for the unavailable actor. Four original raw fixture files, five absence
contracts, six source inputs and clean source HEAD were unchanged. No client was
attached and no MCP/1C process started. This qualifies the current source status
owner, not installed C4 or external provider execution. Evidence:
`build/mcp-common-status-native-6f26a102e3194da3a1a178891397be21/acceptance.json`, SHA256 `9ab65de668ee54aed9adffe615c4a9090f71aa7fa31e1239dba0b01c37bb52a2`.

## Fourth gate: timeout and remaining owner defects

RegisterChange on `a1581fb1bdfa97421de52d36447efd9a5e40bace` stopped
at the unchanged 1200-second hard budget after 1,199,504 ms. Its authoritative
check-summary records a clean source tree and a Pester timeout, not a completed
test inventory. Archive: `build/source-registration-attempt-a1581fb`,
check-summary SHA256 `7aedada8d9bbbf55cd20c9d556194523b4dc1ea5dac42fb9e2ef05a7197d60b9`.
The archive's shard summary is stale from the third attempt (582/1) because the
collector was interrupted before replacing it; those counts are not fourth-run
totals. Neither registration nor publication succeeded.

Completed worker results exposed three additional owning defects:

- Ordinary extension initialization has no native-operation journal. Its
  enclosing snapshot was therefore not handed to the nested checked load;
  a lost completion acknowledgement incorrectly triggered rollback after a
  successful apply. Init now passes its actual snapshot and exact target through
  a private transient capsule. The existing snapshot validator checks target,
  bytes and any restoration duty; Init retains sole completion and rollback
  ownership. No journal, persisted state or recovery coordinator is introduced.
  The original lost-acknowledgement reproducer is unchanged and strengthened.
- Persisted artifact protection must work without an active run context. Optional
  run-path and lifecycle diagnostic variables now have safe absent-value reads.
  The original dirty-worktree deletion fixture imports its actual shared native
  transport. Its topology, managed state, original deletion assertions and
  Unicode paths remain; missing-state refusal separately proves no cleanup.
- A Codex obsolete-alias discovery check duplicated the fork's shared skill
  placement. The current-client manifest now supplies skill roots. Existing
  alias/version detection and user-file preservation remain; invalid declared
  paths are rejected before probes outside the project, with workflow-owner
  reconciliation and repetition of the original OpenSpec request.

After the first two repairs, native Windows PowerShell 5.1 / Pester 5.8.0
passed 9/9 snapshot cases and the complete artifact-retention/deletion file
15/15. Actual source/test inputs were unchanged during each run. These tests
use fake native 1C boundaries and do not qualify a live database. Evidence:
`build/extension-snapshot-handoff-after.json`, SHA256
`459aad312892e05efa7ef30252c8bdbdde40c497d47e98e535b87fdc62579fb9`;
`build/artifact-retention-current-focused-after-winps5.json`, SHA256
`77eef0f2375ea77ce1955cd3ee775da2064acfd3f8866a4099413a5629372b04`.

The namespace repair passed 6/6 native cases: the two unchanged original
assertions and four path/provenance negatives. Scope-local spies first prove
they detect actual foreign probes; the status path then performs none.
Restoring the same manifest bytes in the same project recovers all six native
phases. The foreign-client source retains its existing missing-phase outcome.
All helper and test inputs remain unchanged through execution. Evidence:
`build/native-skill-path-after-ffb2715df44a4754a017952f47e666a0/native-after.json`,
SHA256 `067f77fbb74659c37ef64ee7b18201b53591d70704003d99649a6eca927c03dd`.
This is source/fixture acceptance, not actual client skill discovery.

Independent review then found a non-SKILL target could skip that containment
check before native phase discovery. Source/target normalization, containment
and the existing managed-target assertion now precede filename filtering for
all declared current-client native entries; only SKILL-to-SKILL entries derive
legacy roots. The added sibling `explore.md` escape uses the same original
source, actual probe spies and same-manifest recovery. The expanded selection
passed 7/7 with unchanged owner inputs:
`build/native-skill-path-seven-after-6eacde5ca4bc4f958065e1af7d0ac62d/native-after.json`,
SHA256 `5b7e15ba6439beea4164d0920092ff4f2cae39e521d62f4bb8304fa7d6f57d3e`.

The original migration matrix retains all 250 revision/client combinations and
its cold helper invocation. The preserved instrumented vector identifies
2744.69 ms in the eager process-chain lookup (nine CIM calls) despite
authoritative Codex environment markers. Its total 3771.56 ms includes debugger
overhead and is not a comparable before/after result.

Get-ItlActiveClient now first invokes its existing resolver with the current
environment and an empty process chain. Only when no marker identifies the
actor does it acquire the actual chain and invoke the same resolver again.
Marker precedence, explicit selection, per-call manifest/membership checks,
foreign-client refusal and no-marker fallback are unchanged. No actor cache,
persisted state or authority is added. Two causal native tests passed 2/2:
conflicting markers retain precedence, removing markers causes fresh chain
detection, and existing help/manifest/ambiguity guards retain their outcomes.
The marker-only expected process-call count changes 1 to 0 because the resolver
already returned before examining that chain; no-marker help still requires
one lookup. Evidence: `build/cold-client-context-after.json`, SHA256
`bd8d3517c214b18484283ed6338f93bd5c33a8ff6c488684dc12ff1e34a91f37`.

One original r29/Pi cold vector without breakpoints measured helper/help
3217.20 ms before versus 1059.43 ms after (about 67% lower); the after plan
took 49.83 ms and retained the exact eligible r36 target. This is a single
representative observation, not a completed matrix or a general timing promise.
Both executions completed their source/fixture hash guards. An ignored driver
output-name defect overwrote the before JSON and the older coarse reference;
the before stdout and successful exit remain, but its full hash map is lost.
No synthetic replacement was reconstructed. The actual after JSON is separately
preserved, and the driver output names are corrected without another run.
Evidence: `build/ai-migration-cold-instrumented.json`,
`build/ai-migration-cold-uninstrumented-before.stdout.log` and
`build/ai-migration-cold-uninstrumented-after.json` (SHA256
`eb0c5d454c4e3b70856775948dd8d9042e71e813d1f7fb59810f76a5edb1e27c`).
Its legacy formatted dirty-path field is not authoritative path evidence;
root-owned source inventory uses the shared NUL-delimited Git path helper.
The preserved before driver/exit limitation is explicit in
`build/ai-migration-cold-uninstrumented-before-provenance.json`.
No matrix workload,
assertion, precondition or gate budget is relaxed.

## Current-source native snapshot handoff

The existing owned unmanaged tiny file infobase passed the actual native
handoff scenario on platform 8.3.27.2130 / Windows PowerShell 5.1 in 122.33 s.
All eleven Designer calls used the existing exact-infobase guard. The retained
missing-method source failed at CheckModules with exit 101. One real DT
(36,324 bytes, SHA256 `2a150a58da6d80576ec81d6248de0cabb14f79d056c8d6a5fe739acebe3950de`)
was handed explicitly to the checked load, retained after failure, and restored
by the outer disposable fixture. An independent dump confirmed the original
two extension files byte-for-byte. The same original source then passed all
three native checks and UpdateDBCfg while borrowing the same DT path/hash.

The inner checked load neither created another snapshot nor completed or
restored it. Only the outer fixture completed the actual nullable duty and
cleaned its DT. No ambient journal, managed project state or fake readiness was
introduced. Source/fixture inventories remained unchanged; final target-session
count was zero. The source Init completion/lost-acknowledgement boundary remains
unit-qualified, not native full installed Init acceptance. PM5 and external MCP
qualification remain separate open items.

Evidence: `build/gate6-snapshot-handoff-native-7055c39a97d6401cb31133bb2bb1090f/summary.json`,
SHA256 `5b075de0591f705fefc653aedb69d0e403db6f74f808d2e599a47f84f3e018d7`;
successful checked-load receipt SHA256
`f47a46ca889ea96de025621d3477d8115163cf4ddbc72965085171dfa3ce40ac`.
This proof and the 33 current focused source cases do not replace the subsequent
script-owned Targeted registration gate or permit publication/real-project rollout.

## Fifth gate and native PowerShell JSON fixtures

RegisterChange on `6ac73f7d238db4a0b83b4c9d4646076ace1e9cb8`
completed in 530,780 ms with 815 passed, one failed and zero skipped across
the completed/reused inventory. Eight files were reused and 23 executed;
unscheduled files remain unqualified. The original 250-combination migration
matrix passed in 86.06 s; its complete file took 122.66 s and failed only at
an unrelated fixture's unsupported ConvertFrom-Json -AsHashtable parameter.
The original edited-AGENTS guard was not reached by that failing fixture.
Archive: `build/source-registration-attempt-6ac73f7`, fresh shard-summary
SHA256 `5da452c6b324227ef2ad6afec62cebb8ea57e919aeefb9be598d189efdabfdd0`.
No registration or publication resulted.

A targeted audit found the same native-5.1 incompatibility in the pending
locked-project OpenSpec pin case. Native before selection reproduced both
parameter failures before the production calls. Both fixtures now use ordinary
ConvertFrom-Json and equivalent PSCustomObject property insertion/removal.
Original managed bytes, installed hash, absent userModified marker, user
addition, lock mode, project-specific pin, idempotence assertions and the entire
migration matrix remain unchanged. Production code is unchanged by this repair.
Reviewed proposal bytes retain the original UTF-8 BOM and line-ending contract.

Native Windows PowerShell 5.1 / Pester 5.8.0 after selection passed 4/4: both
original cases plus existing strict UTF-8 drift/invalid-byte and missing-locked-
dependency refusal controls. Runtime/test inputs remained unchanged during
execution. Evidence:
`build/ai-rules-native5-fixture-after-e444b7c81b0b4c4e9008db39e0fc5ec2.json`,
SHA256 `1707b2f6db994ae24fe8ce1f5c89e5afc39c05ead7462acf5ba25de0d31d670f`.

## Sixth gate and empty shared-MCP assertion

RegisterChange on `b8663621f483937d844419dfa677462f2600155a`
failed in 187,621 ms. Its fresh shard summary records 975 passed, one failed
and zero skipped across 42 completed/reused files (30 reused, 12 executed).
The other 40 selected files remain unqualified. The only recorded failure is
the original shared Claude/Command Code last-owner-departure case, at its final
Properties.Name assertion. Archive: `build/source-registration-attempt-b866362`,
shard-summary SHA256
`2394bb00899fbcaa920015421c380ea80dbb85540ad9dc8fafed4b5f80856ca5`.
No registration or publication resulted.

A native Windows PowerShell 5.1 / Pester 5.8.0 rerun of that unchanged original
case reproduced the same Name failure. A read-only breakpoint captured the
actual JSON immediately before the assertion: mcpServers is empty, itl-shared
is absent, and both original owner claims are empty. All test/runtime input
hashes remained unchanged. Two earlier observer attempts lacked access to the
test scope and are retained as unqualified diagnostics; they are not shape
evidence. Qualified before proof:
`build/shared-mcp-empty-properties-before-e14e0c862ae94343bd90fc0ad1d4fa82.json`,
SHA256 `795f074a6cbb3236c9fdf05e7a9de849431c427c639ef404194ac62d5112f915`;
its read-only capture SHA256
`85e5082e3eda47e57ccea6fcbc4a8229271b3d20c0a0829105343096e19d35ff`.

The test-only correction enumerates each property's Name explicitly, including
the empty collection. The forbidden-server expectation, original calls,
clients, ownership and workload are unchanged; production code is unchanged.
The original case and existing shared-cohort/foreign-content, owner/user-
collision and later-client preflight controls passed 4/4 in 3.04 s with zero
skipped and unchanged inputs. Evidence:
`build/shared-mcp-empty-properties-after-ce668c0641dd4d699cab696f2f4ce2be.json`,
SHA256 `0176d8cdfa384a216bf6e2f18ee997305b7472c09b491c87778fdfd77bff1f13`.
This focused fixture proof does not qualify an external MCP provider or replace
the subsequent script-owned registration gate.

## Seventh gate and transient-feature UTF-8 fixture

RegisterChange on `88e07345f927626c03b0d8c2ab74308d027d345b`
failed in 130,367 ms with a clean source worktree. Its fresh shard summary
records 1,146 passed, five failed and zero skipped across 56 completed/reused
files (40 reused, 16 executed). The remaining 26 selected files are unqualified.
The shared-MCP file passed all 13 cases. Four failures concern the shared
manifest reader's source field; one concerns the transient-feature test's JSON
decoding. Archive: `build/source-registration-attempt-88e0734`, shard-summary
SHA256 `6c0578964a118c91b60af29ecf2a1b46ede40fe41b949a08408e741f890529b3`.
No registration or publication resulted.

The unchanged original transient-feature case reproduced its exact Unicode
failure on Windows PowerShell 5.1 / Pester 5.8.0. Read-only observation showed
that the actual session is UTF-8 without BOM, and both strict UTF-8 decoding
and production Read-Utf8Text preserve the original feature path. Only the
test's default-code-page (1251) reader corrupts it. The original whitespace
and Cyrillic path, scenario-loop kind, three-attempt budget and zero attempts
at that boundary remain unchanged. Qualified before proof:
`build/transient-feature-utf8-before-bc9f408a72dc4de585aa298c3b3d176b.json`,
SHA256 `e19e1b2e658e97c98bf747f41075af0dafd679df0dc764c6fafa175e57e02cbb`;
read-only capture SHA256
`baa1066f548176a234867d62302792804d9f88d1973578d0495f4fd75c72ca4d`.

Only the two JSON reads inside that original case now specify Encoding UTF8.
Production code, fixture bytes, path, topology, workload and all assertions are
unchanged. The original case plus existing named-loop/unfiltered-proof,
provider-policy continuation and active-budget preservation controls passed
4/4 in 2.51 s, zero skipped, with unchanged runtime/test inputs. Evidence:
`build/transient-feature-utf8-after-ebdc8923b5b842aba6e6dcd0122e7d99.json`,
SHA256 `29b9aa32e06a02b5fbbcd89f5c87395f92e9498978042817afc688cdb032776a`.
This fixture repair is not native Vanessa or external-provider acceptance.

## Sparse manifest inspection without a provenance grant

The seventh gate's four original root/hash tests reached the shared manifest
getter and failed on its unconditional source-property access. Both actual
pinned r33 (`9309bfbbc9f8d844a21bce55178c2e0d72eaf965`) and r36 installers record
source explicitly; these four focused fixtures deliberately isolate target,
installedHash and userModified. They are not complete authentic r33 manifests.
Target/hash inspection now represents an absent source as an empty string,
without inferring a source, path, ownership or installation provenance.
Bundle validation excludes blank sources before its destination-winner
fallback, preserving the existing valid shared-destination owner contract.

The original four test bodies and five native containment cases are unchanged.
New missing/empty-source cases prove zero canonical-target probes, the existing
incomplete-bundle refusal, unchanged bytes and successful validation/native
routing after restoring the same valid manifest. Two additional missing/empty
global-source cases preserve the original absolute-path/ownership protections.
No installed copy, global client file or infobase is changed by this source fix.

Historical focused diagnostics are retained in
`build/handoff-source-provenance-review-88e0734`. The initial BEFORE was mixed:
three source errors and one Git path-length failure caused by the ignored
driver's artificial TEMP root, plus a separate causal getter trace. Initial
AFTER 13/8 failed on the same artificial path-length prerequisite. AFTER 20/1
under inherited TEMP failed on benign Git stderr because that driver invoked
Pester with ErrorActionPreference Stop. None is a passing qualification. The
final driver preserves inherited TEMP/TMP and matches the source gate's
Continue setting around Invoke-Pester; original test paths, Unicode, topology,
workload, Git exit assertions and all expectations remain unchanged.

Final native Windows PowerShell 5.1 / Pester 5.8.0 selection passed 21/21,
zero skipped, in 13.84 s including the wrapper, with unchanged owner inputs.
Evidence:
`build/handoff-source-provenance-review-88e0734/after-canonical-pester-af9fd85745db44d696d19012e58aac0a/after.json`,
SHA256 `985f219d437eb33e3ae8a6aa01eef5f550628cd613c17ddf4d77428f690f10b7`.

## Rollback fixture decoding and fresh-child result

A bounded audit of the 26 unrepresented selected files identified one more
concrete default-code-page read: rollback's positive case uses persisted
Unicode currentPath/beforePath immediately after reading a UTF-8 report.
Its original native rerun failed at that exact filesystem read. Only that
fixture read was first corrected. The next 3/5 run reached two further original
checks: a second ANSI read corrupted decision.reportPath, and the existing
fresh-child mock returned null rather than the actual ReturnExitStatus object.
That failed result is retained; its report SHA256 is
`4794c2b8eb5f5cbc919b88473d05d56c5194c9786589368e981a3d81c64ecf13`.

The two relevant reads now specify UTF8 and the original mock returns exitCode
zero. Actual workflow writers/readers and child dispatch are unchanged; no
child boundary is bypassed. Original Cyrillic/whitespace roots, business
staging/HEAD assertions, child-call count, incomplete-review versus tampered-
report categories, corrupted-backup refusal and interrupted-restore checks
are preserved. Report writer/reader function bytes are identical before and
after the separate sparse-manifest source fix; the whole lifecycle-file hash
change is recorded explicitly, not treated as unchanged runtime identity.

The final native selection passed all five original controls, zero skipped,
in 11.38 s of Pester / 12.74 s including the wrapper; all 66 captured inputs
were unchanged during that run. Evidence:
`build/workflow-rollback-utf8-after-94fc9d96b2a44e17b19a2b6f9757d05b/result.json`,
SHA256 `1b84f044718cc16ce72c92568ee4c10198bacc536b2647285764642c8937d3e7`.
These local fixture proofs still require script-owned Targeted registration;
PM5 business-refresh, live providers, publication and real-project rollout
remain separate open acceptance boundaries.

## Native missing-commit query and stopped-merge guard

The eighth registration for `0cf25012ea0c2be9f9e6dcd4d49a1d61995cee12`
failed in 526,852 ms: the fresh shard summary reports 1,147 passed, one
failed, zero skipped, with 35 executed and 21 reused worker results. The
remaining selection is unqualified; no migration queue entry was registered.
The terminal archive is `build/source-registration-attempt-0cf2501`.
Its check-summary SHA256 is
`0f3203c43aeaf8dfd43e38a0bac89eb7c40401c8aae85aa2b84be2116990da73`;
its shard-summary SHA256 is
`7ee9ef9644fccbbc2b324fb5ff430d4d63136c1fc88c048c9b8563a82a89baa5`.

The original two-update case had completed both real workflow advances,
including the second lost acknowledgement. Its negative check changes only
the recorded original branch anchor to a syntactically valid, nonexistent
40-zero commit. Under the helper's Stop preference, native Git stderr in
Test-GitCommitExists terminated before the boolean false could reach the
existing WORKFLOW_UPDATE_PENDING_MERGE_CHECKPOINT_CHANGED refusal.

Only this boolean query now uses the adjacent established Continue / finally
restore pattern. The Git command, commit peel, output suppression, exit-code
condition and empty-input false are preserved. Twelve calls in eleven owner
functions were reviewed: absent commits lead to existing typed refusals or
their intended fallback. No new guard, authority, lifecycle state or recovery
coordinator is introduced, and original test bodies remain unchanged.

An initial ignored harness selector selected zero tests and is retained as
unqualified evidence. The corrected uninstrumented native BEFORE selected the
original one-/two-update pair: one passed and one reproduced the exact raw
Git failure at the original typed-refusal assertion, with unchanged inputs.
Evidence: `build/pending-git-existence-before-afe0ce89e35346f3afb9e32d2b2cdfcd.json`,
SHA256 `f34ae462f555dd337a1d94eda304d390cd5c5e729b1acbf1d46212b1c91c662b`.

After the owner fix, native Windows PowerShell 5.1.26100.9549 / Pester 5.8.0
passed all four selected original controls, zero skipped, in 49.92 s of Pester:
the one-/two-update pair, parent-proven managed merge eligibility with its
user-edit/foreign-identity refusals, and stopped-update recovery with current
code. Original target, index, initial checkpoint, lost-ack replay, actual final
merge parents and later workflow continuation assertions are preserved.
All captured inputs were unchanged during the run. Evidence:
`build/pending-git-existence-after-8f7e9fc5c1844a84a5d635dad81f65f2.json`,
SHA256 `db3ed818bf6ed60592272869fd565bd40abd69433ecd45a0d3a737893ccc991d`.
The reviewed core SHA256 is
`4284988522ddbac095ca5931efce47acb13acfbf55a2d17fdf6a9155f79ccd3d`.
Fixture Git warnings and the existing stopped-update diagnostic are retained.
This is Git/native PowerShell proof, not full PM5 readiness, Init acknowledgement
or live MCP acceptance; script-owned Targeted registration still must pass.

## One-off evidence fixture entry context

The ninth registration for `002e6e55a6a153c04e1733b198ab669a18957c0b`
failed in 518,228 ms with a clean worktree. Its fresh shard summary reports
1,512 passed, one failed, zero skipped, with 47 executed and 26 reused worker
results. The previously failing PendingMergeWorkflowTransition file passed
all eight original cases. Remaining unscheduled selection is unqualified;
the migration was not registered. The terminal archive is
`build/source-registration-attempt-002e6e5`. Its check-summary SHA256 is
`31dc4eead6561184c99dea8050e895ae2f28118ca2771cefe4f202d9b7bcc5e5`;
its shard-summary SHA256 is
`4393232735e2cda9e88209242160135ff1c69b02b379222f062830bfb1f7817e`.

VerificationSelection's original observed one-off case imports only its
library and supplies the project/input/base context and branch-state mock,
but omitted DevBranchName. Production begin/complete dispatch always runs
after that parameter is declared by the helper entrypoint; a declared blank
value has an existing current-itldev inference path. Independent review found
no standalone context API or missing checker dependency requiring a runtime
change. The fixture now supplies local DevBranchName='branch', matching its
existing state mock. No checker, evidence, branch guard or assertion is mocked
out by this change; all original functions and test conditions are retained.

The uninstrumented native BEFORE reproduced the missing-variable failure in
the original case, one failed and zero skipped, with unchanged inputs:
`build/oneoff-branch-context-before-bcc73d99295d427f8dafe9c5ad0da0ac.json`,
SHA256 `9d153ac2961e8764abeb5fb7273c4fbd629807df9ccf9e37438ee392fd3d92bd`.
After the single fixture declaration, Windows PowerShell 5.1.26100.9549 /
Pester 5.8.0 passed four original controls, zero skipped, in 4.09 s of Pester,
with unchanged captured inputs. They retain changed-input/base/artifact and
tampered-receipt refusals, invalid-JUnit pending preservation, valid-JUnit
completion, unrelated-source identity reuse, pending-obligation classification
and a one-off-only assessment without an invented Vanessa run. Evidence:
`build/oneoff-branch-context-after-7c22179cc2014dfa808a5241968e16ae.json`,
SHA256 `f0a83e4fd761aa040ea6a4b5c52c5ae57eca4b04c7b48eb3cb741674267b23ed`.
The verification-selection runtime SHA256 is unchanged:
`daca938ca8c1266f90d5e0f0d4e70d0859ea970516ec09e43993bf7c68c38440`.
This remains local fixture proof requiring registration, separate from the
open live invocation/check/export, ROCTUP, PM5 and provider acceptance.

## Temporary-patch native transport dependency

The tenth registration for `9f37507d9615d3a90416b2f63bbc372c838bd3bd`
failed in 91,832 ms with a clean worktree. The fresh shard summary reports
1,565 passed, 37 failed, zero skipped, with 12 executed and 67 reused worker
results. VerificationSelection passed all 19 original cases. All 37 failures
belong to WorkflowLocalPatch and include Git collection ExitCode not-started
and a missing Invoke-ItlNativeProcessCapture dependency; their grouped original
NUnit message attributes are retained separately. No migration was registered.
Archive: `build/source-registration-attempt-9f37507`. Check-summary SHA256:
`0ca40cb101d3b566171ef5d467557dfb4b098146a136609016746a015b3da034`;
shard-summary SHA256:
`42db997a4cb4a1e97334177f430e4589295f086b20a7238207d093643b32289c`.

The real standalone workflow-local-patch entrypoint, as well as the fixture
setup, imported core/lifecycle/local-patch without the actual shared native
capture owner. The original Windows PowerShell child-entrypoint case proves
a product dependency defect, so a fixture-only correction would be incomplete.
Both now import the existing agent-1c.vanessa library after core and before
lifecycle, matching the main helper. Its 234 top-level statements are function
definitions; this import starts no Vanessa, MCP or 1C process. Lifecycle already
imports runtime-values, so no redundant second dependency is added. Native
capture, quoting, UTF-8, NUL-delimited Git transport, guards and patch policy
remain under their existing owners; no fallback or duplicate transport is added.

Uninstrumented native BEFORE selected the original exact-Unicode capture and
real Windows PowerShell entrypoint cases. Both reproduced the same missing
capture / not-started failure, zero skipped, with unchanged captured inputs:
`build/local-patch-native-capture-before-162493dcbb9b4f95ad0d43470b2f7edd.json`,
SHA256 `91e7e09a67409455cdbf9d0541d4300d35dddcbb4f3b4fc56ae77d043a624415`.
After the two imports, Windows PowerShell 5.1.26100.9549 / Pester 5.8.0 passed
all six original controls, zero skipped, in 14.57 s of Pester, with unchanged
captured inputs. The original Unicode/whitespace roots and exact bytes,
unstaged retirement, corrective commit with staged product preservation,
interrupted retirement/resume, additional-edit and foreign-staging refusals,
and real child Capture/Seal assertions are unchanged. Evidence:
`build/local-patch-native-capture-after-c059c1e036d04113a2e27bd897819081.json`,
SHA256 `63aca4c995a834bcee94b22818132bef0b90a03f6a4efffb6b26e607bdcf1e1e`.
This proves the original temporary-patch task through its actual native
entrypoint; full PM5 refresh, live provider and release acceptance remain open.

## Package-copy fixture prerequisite context

The eleventh registration for `4cb17b6e867bb140bc9f0f14e408b3bdc362c4d0`
failed in 500,814 ms with a clean worktree. The fresh shard summary reports
1,591 passed, four failed, zero skipped, with 37 executed and 42 reused worker
results. DevBranchLifecycle passed all 238 cases; WorkflowLocalPatch passed
34 of 38, including its actual Windows PowerShell child entrypoint. Only the
four original Package copy boundary cases failed. No migration was registered.
Archive: `build/source-registration-attempt-4cb17b6`. Check-summary SHA256:
`e617a0de581871b5677f8c779b8dab185e3f021ed7e8a5d497957f3efc9644c5`;
shard-summary SHA256:
`ef377041274da5813b9342bccea83205a379f7497caef5a82567ee7b83d9a39b`.

The original module-only fixture omitted the helper entrypoint's declared
WorkflowUpdateRecovery and other default parameters. Its incoming source
contained only the workflow replacement file, so declaring defaults alone
would still fail the real pinned-rules preflight and candidate inventory
before reaching the original copying/retirement cases. Production dispatch
already supplies those parameters; no runtime default or guard is changed.

The fixture now initializes the real helper with Action help on the same
original project and uses its normal SkipAiRules=false route. A miniature
local Git candidate with an actual commit/tag, source templates, dependency
lock, project-scoped Codex adapter and bounded installer supplies the required
candidate data. Normal candidate sync, install inventory and snapshot guards
remain real. The pre-existing collaborator mocks are retained; no new guard
mock or skipped rules/empty-tool shortcut is introduced. Candidate/runtime
files stay in TestDrive, with process TEMP/TMP/AGENT_TOOLS/source override
restored after each case. No network, global profile, MCP or 1C is involved.
The complete original four It bodies are byte-identical, including a/b/unknown
workflow source identity, partial-copy failure, post-copy reexecution failure,
exact Unicode bytes and active/retired receipt assertions.

Uninstrumented native BEFORE selected all four original cases: zero passed,
four reproduced the undefined WorkflowUpdateRecovery failure, zero skipped,
with unchanged captured inputs. Evidence:
`build/local-patch-package-context-before-6562f696beec42df95124530d3ce812a.json`,
SHA256 `3766bc89a5ee9944f8a07cb60d0dbc8412cef0b863317f7688a2165158c9277d`.
After the fixture preparation, Windows PowerShell 5.1.26100.9549 / Pester 5.8.0
passed those four and the original corrective-commit/staged-product and
interrupted-retirement controls: six passed, zero failed/skipped, 22.49 s of
Pester, with unchanged captured inputs. Evidence:
`build/local-patch-package-context-after-15dc56ea6bcf405f9e1cba4ca9850396.json`,
SHA256 `97f1339d360cda3e5b7573bbe3036c3b90fd80a20c705b06ba09916d2fb896fe`.
Reviewed fixture SHA256:
`9a9c36808876a9c94e59ef7c7119213771692c3743b7a300b69faa368a52fffb`.
This is local prerequisite/copy-boundary proof, not qualification of the real
controlled fork or native clients. Script-owned registration, live acceptance
and publication remain separate pending steps.
