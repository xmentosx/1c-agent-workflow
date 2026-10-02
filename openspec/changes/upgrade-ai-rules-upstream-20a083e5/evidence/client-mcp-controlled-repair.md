# Controlled client_mcp repair

On 2026-10-01 the user approved maintaining the minimal client_mcp metadata fix
and adding it to the existing component delivery owner. Publication and real
project rollout remain separately authorized.

The exact published v0.6.5 CFE (SHA d1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f)
fails full Gate 6 in the qualified Vanessa service template on DefaultLanguage.
The service template contains a valid Russian language. The retained binary,
unmodified XML roundtrip and name-bound Language diagnostic distinguish that
artifact defect from a template defect. Diagnostics restored their exact DTs.
No claim is made that the ai_rules_1c upgrade itself introduced this defect.

The controlled builder exports the exact immutable upstream CFE to Designer XML
using a pinned platform. Upstream commit 3f6a066913057c2d6f2d61c0b429fd0707ab271b
contains EDT source; no EDT build is claimed. Repair changes only ChildObjects
in Configuration.xml and adds one adopted Russian Language without binding its
metadata to a target-base UUID. All other exported source bytes are compared.
Complete patched XML sources, source inventory, provenance and licenses are
retained in a corresponding-source ZIP alongside the immutable resulting CFE.
Compatibility version stays v0.6.5; downstream revision and hashes are separate.

The existing service/TestManager installation owner remains responsible for
client_mcp; PM5/TestClient keeps the existing VAExtension. The builder uses
guarded native processes, a private qualified service base, unchanged Gate 6
and DT restoration. Exact CFE build proof is not live Vanessa acceptance.
Existing live ondemand-mcp qualification must also bind the installation owner's
client CFE SHA/version and runtime ownership proof to the candidate lock.

Supervisor support is optional under the previous external client pin. Owned
client CFE and source ZIP are required together once the candidate lock declares
them; missing assets select the existing ondemand-mcp capability. Unknown owned
assets and conflicting bytes/tags retain their strict refusal. Direct remote
URLs are verified again before installability is declared and before workflow
push/recovery. Source-build input identity includes the actual client CFE bytes.

The production template lock currently remains external. A compatible published
authority supervisor must precede an owned production pin. Local build/canary
proof cannot authorize publication or claim a not-yet-published URL installable.
Tasks 9.7, 10.2 and 10.4 remain open until their original live journeys pass.

The canonical cbd7d289 build passed all three native checks and exact restoration;
its independent source-pair reader confirmed all 54 exported files and notices.
The private package candidate 06572fc6 pins that pair by local file URI. Public
update-installed-workflow updated both isolated PM5 worktrees, preserving the
original business target A, pending merge stage, 2 configuration trees, base
bytes and repair-session budget. The two intended client artifact path/hash
settings changed; all other environment and client configuration bytes did not.
The original unfiltered repair attempt 2/5 installed the repaired client in the
service base after native Gate 6 results 0/0/0. It then stopped on the separate
VAExtension defect described in va-extension-html-handlers.md; no safe-mode,
Vanessa TestClient or full-check acceptance is inferred from these partial steps.

The first native build from e246f283 passed all three Gate 6 steps, restored
its exact DT and released the owned processes. Independent ZIP inspection
confirmed all 54 source files byte-for-byte, but found Windows Framework
backslash entry names instead of the canonical src/ paths. Retain that original
archive and diagnostic; source packaging now writes explicit slash paths with
UTF-8 entry names. The regression extracts a Cyrillic/whitespace-path archive
and compares the reconstructed source fingerprint, including opaque binary
bytes. Native build input identity prevents relabelling the old proof as proof
of the changed writer. This does not close service/TestClient acceptance.

Publication ordering diagnosis: the shared queue includes migration and four
other pending entries. PublishDevelop consumes the whole common-Git queue;
QueueId cannot select only support. The migration's strict Gate 6 rejects the
old external CFE, while the locally recorded published develop baseline
81f0a649fa98ece826aec97b60ed58202e208b2b uses the previous load owner. Therefore
prepare a support-only candidate from the freshly verified published baseline
in a separate clone/common Git and qualify it through ordinary delivery first.
Do not modify shared queued refs, weaken Gate 6, introduce an alternate gate,
or run a candidate as its own supervisor. Actual baseline and remote movement
must be reverified when publication is explicitly authorized.

The final private native build on 2026-10-02 used clean producer
`2c5935844b9e36817e7bfddb54cdb99e6fd753bb`, taking 143.838 seconds. All three
Gate 6 checks passed, its exact DT was restored and owned processes released.
Independent qualification matched all 41 current producer input hashes, all
54 source files and all seven source-archive support files. Receipt in E:
`build/e2e-client-selection-proof-20261002/native-client-independent-qualification.json`,
SHA256 `508f4c54a64cff762bb22eca536dbb44a352c52807791fb89f7c6535bfb8213f`.

The new CFE SHA256 is
`b663de4664d53a1f3abb14cba7b13582e91c4c639fa28e73e07330ae850e5643`;
the source ZIP remains
`409253c0bc9abbbabf0797bde3a1316f8a95bfbdfbae0ec0709924eb24f95dcc`.
The earlier successful PM5 run used a different exact CFE (`0472ce6e...`).
It cannot qualify the new binary merely because the source ZIP is identical.
Exact-CFE live acceptance remains in task 10.6 under the existing publication
qualification owner. The completed original repair session is not repeated,
and process-only environment substitution cannot bypass its installed lock.
This private build changed no production pin and started no publication.

## Paired publication candidate, 2026-10-03

After publication of prerequisite supervisor f5466e6f, the new source declares
an owned client CFE and corresponding-source ZIP together. The clean native
producer is 1e01117b1696b090972e15271bcdbe33ec0f9580, checked out in the
isolated publication repository. Its 43 producer inputs match the exact source
and future publication checkout, including both new Q24 libraries. Native
modules/applicability/configuration Gate 6 returned 0/0/0, the exact DT was
restored and owned processes released. The CFE SHA256 is
4deefb92aae3cbb70a28c8bf89a09c682ce7783746ba7df932dddc864ad2a245;
the unchanged source ZIP SHA256 remains 409253c0bc9abbbabf0797bde3a1316f8a95bfbdfbae0ec0709924eb24f95dcc.
Receipt SHA256: ff5b252871692000412427d0687b0e016fa44b5f477036ae0e40c7219f77fca6,
publication checkout build/third-party/client-mcp/v0.6.5-itl-r1/candidate/candidate.provenance.json.

The preceding clean-H build also passed Gate 6, but its raw helper text bytes
differed from a normal publication Git checkout in six files. Its native receipt
is retained, without being relabelled as publication proof. Matching the normal
checkout bytes leaves the Git source and index unchanged; the current native
build binds those exact bytes. Neither earlier b663 nor the intermediate
7353 artifact qualifies the current locked CFE. Missing release assets select
the existing ondemand-mcp Release capability automatically. Real service/client
installation and live qualification remain required before component/workflow
publication; no remote asset or real project was changed by these builds.
