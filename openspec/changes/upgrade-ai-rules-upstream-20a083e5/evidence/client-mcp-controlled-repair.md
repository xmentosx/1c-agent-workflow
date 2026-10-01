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
