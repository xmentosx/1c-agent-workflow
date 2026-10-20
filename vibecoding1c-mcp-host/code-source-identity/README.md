# Native Code source identity candidate

This is an optional, source-qualified extension of the existing Code generation
manifest. It is **not a deployed or release-qualified image**. No Graph adapter
is supplied: the available Graph build has no supported successful-index
manifest hook and its implementation sources are unavailable.

`patch.py` verifies both complete native input hashes before writing anything,
then inserts small metadata additions into the native fingerprint assembly,
`Manifest.add_generation`, `stats` and structural response budget boundary.
The existing five-component fingerprint, publication, reader pin, ingestion,
rollback and crash/resume owners remain authoritative. Never replace vendor
files with a retained full-file overlay. A vendor source change requires a new
owner review and qualification, not bypassing the hash guard.

`ITL_SOURCE_KEY` is a validated deployment host/config alias, frozen with the
native source inventory at generation creation. It is not a product ID or a
client-supplied expected value. Configuration Version is recorded only if its
exact XML bytes occur in that inventory. The source revision is the native
source-inventory SHA-256, with its extent and provenance. Current mount/Git HEAD,
backend build and registry revision do not substitute for indexed bytes. Old
generations are not backfilled or automatically reindexed.

`stats.data.sourceIdentity` describes the published generation pinned by the
existing reader guard. Existing `get_module_structure` / `search_function`
responses add a small top-level `sourceIdentity` stamp only when their existing
`include_provenance=true` option is requested. The stamp is added before the
existing response budget. Ordinary functional replies and tool schemas remain
unchanged. A live-file fallback or module response with live XML enrichment is
labelled accordingly and cannot prove an exact indexed revision. Consumers
compare metadata/read generation and stamp; missing, changed or budget-dropped
facts remain unverified.

The host descriptor must explicitly opt in with
`sourceIdentityContractVersion=1` **only after image qualification**; existing
images receive no new environment variable. A future image build uses the
Dockerfile with the separately verified immutable base reference. A local
Docker image ID is not a registry RepoDigest. Image build, native response-budget
integration, crash/resume qualification, deployment and normal reindex each
require their own applicable proof/authorization before replacement. See the
host contract in the parent README and the registry OpenSpec evidence
`g3-source-binding-implementation-2026-10-21` for current limitations.

Run the stdlib source tests with `python -X utf8 -B test_source_identity.py`.
Supplying `ITL_NATIVE_CODE_FIXTURE` enables the additional exact native-source
patch/AST case; without it that case is explicitly skipped. Unit/AST tests do
not qualify a new image or a live index.
