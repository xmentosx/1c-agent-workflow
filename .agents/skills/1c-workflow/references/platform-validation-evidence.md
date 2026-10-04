# Platform Validation Evidence

Use this reference only when an authorized main-CF source load has a selected
small partial `quick-fix` and actual MCP validator responses already exist.
Pass the receipt through the existing helper `-VerificationEvidencePath`; this
does not authorize a load or invoke validators. Full loads, deletions, unknown
inputs, multiple metadata owners and deltas above `QUICKFIX_MAX_LINES` (default
40 added plus removed source lines) keep the platform fallback. The generated
`ConfigDumpInfo.xml` cursor does not count toward that source-line limit.

Store the receipt and actual request/response artifacts in ignored project
runtime. Receipt schema 1 has `kind=itl-mcp-source-validation`,
`taskPath=quick-fix`, absolute `projectRoot` and `sourceRoot`, the exact current
`sourceFingerprint`, and `entries`. An entry records its source-root-relative
`relativePath`, `inputSha256`, `checker` (`server`, `capability`, `versionOrId`),
and `request`/`result` (`path`, `sha256`). Artifact paths are relative to the
receipt directory or absolute and must remain inside the same project.
For a runtime source load, `infoBaseKind` and `infoBasePath` must match the actual target. A static-only receipt without that binding cannot waive that load's ladder.

Every changed BSL input needs the actual complete `syntaxcheck` request with
`code` exactly equal to the current strict UTF-8 decoded file, removing only
the encoding BOM. Preserve the raw file SHA, all source characters and EOLs;
a snippet is not eligible. Save the structured response with actual analyzer
identity, `whole_file` scope, complete diagnostic counts, no filters and no
request rewrite. Both `request_rewrite.requested.code` and `used.code` must
match the sent full text's Unicode character count, newline count plus one,
and the provider's actual 16-hex `sha256` prefix; any published `file_name`
must match the actual request. Do not pad that prefix into an invented full
SHA. A `syntaxcheck_file` path call is eligible only when its actual response
also proves the identical saved input descriptor. A local path and local SHA
alone cannot prove which bytes a remote server read; absent that binding, use
the full-text call or retain the platform fallback. This adds no file-tool or
mount support claim for a provider that does not expose it.

Every changed XML input needs
the actual `verify_xml` request with matching XML content/object type and the
complete valid result without errors. A summary, invented `passed` flag or
another file's response is insufficient. The helper rechecks receipt, source
and artifact bytes; a mismatch reports the reason and uses the existing
platform ladder. Do not rewrite checker output to make it eligible.

The same load owner separately assesses existing structural findings when
full platform checking is required. Its operation-local before-check comes
from the proven previously loaded corpus, with the existing DT snapshot and
the same target/platform/modes. It captures and rechecks original log/result
hashes. Only exact unchanged findings in proven unaffected object sources may
permit apply; unknown dependency impact keeps the strict path. There is no
global whitelist or manual baseline override. The receipt preserves both
native outcomes and the explicit non-clean assessment. Compilation,
applicability, source freshness, native completion, guards and rollback retain
their normal requirements and continuation through the original operation.
