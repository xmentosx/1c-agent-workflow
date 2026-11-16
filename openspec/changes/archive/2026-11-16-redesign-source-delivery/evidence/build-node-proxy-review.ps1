param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# Explicit source audit; this script never executes the Node suite.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$file='tests/node/tools-list-proxy.test.js'
$source=@(Import-Csv (Join-Path $evidence 'inventory/test-files.csv') | Where-Object file -CEQ $file)
$inventory=@(Import-Csv (Join-Path $evidence 'inventory/test-cases.csv') | Where-Object file -CEQ $file)
if($source.Count -ne 1 -or $source[0].sourceSha256 -cne (Get-FileHash (Join-Path $root $file)).Hash.ToLowerInvariant()){throw 'Node suite differs from the reviewed frozen source'}
$records=@'
1|Description compaction changes schema, annotations or unapproved descriptions; JSON/SSE adapters alter errors or lose typed fields|Actual describe/transform functions, captured BookStack tools fixture and actual tools-contract JSON|Exact tool names, structural SHA, required/default/schema fields, unchanged nested descriptions, approved shortening ratio, JSON/SSE result/error preservation and drift rejection|Top-level synchronous assertions, not a separate process; copied beta fixtures are synthetic SDK output|retain
149|CLI proxy cannot start before upstream or fails to recover through a normal client initialize|Real spawned Node CLI, private HTTP upstream started later, own temporary contract|Liveness before upstream, ready503 then client initialize200, exactly readiness+client initializations and ready health|reservePort closes before CLI bind: theoretical port-allocation race; no flake history inferred; child stop lacks explicit wait deadline|retain; bounded CLI cleanup and port-race follow-up
228|Concurrent first clients repeat readiness probes or fail on racing readiness state|Actual proxy and HTTP listeners on OS-assigned loopback ports, Promise.all clients|Two200 responses and exactly three upstream initializes: one shared readiness plus two clients|Counter is part of the causal protocol contract, not an arbitrary test-count assertion; no external MCP server|retain
278|Sessions leak, redirect is not normalized, safe list retry fails or mutating tool call is replayed|Actual HTTP redirect/session upstream, socket disconnects, delayed call and proxy|Session deletion/counts, normalized upstream, exact forwarded body and proxy marker, slow forwarding200, list retries exactly once, disconnected tools/call502 exactly once, bounded ready error|Several assertions share one deliberately stateful journey; splitting blindly would lose session/requalification history|retain
441|Legacy CodeChecker clients lose result string or additive sources when beta returns typed answer|Real loopback HTTP exchange and actual legacyCodeCheckerResult adapter|Public result schema, Unicode content/result agreement, preserved sources|Pure transformation overlap is intentional wiring proof at HTTP boundary; fixture is not actual CodeChecker SDK qualification|retain
499|Legacy docsearch/docinfo clients lose wrapped text, additive sources or original errors|Real loopback HTTP plus direct malformed-result/error transform negatives|Required result schema, x-fastmcp-wrap-result, two tool outputs, preserved sources/errors, missing text rejected|Two parameter outcomes explicitly inspected; no real documentation server|retain
561|Syntax adapter modifies plugin_state, drops structured diagnostics or accepts malformed TOON|Real loopback HTTP, typed beta fixture, actual syntax output adapter|Only syntax schema wrapped, additionalProperties preserved, exact Unicode JSONL events/metrics/asides, typed diagnostics retained, plugin output unchanged, error retained and malformed events rejected|Multiple distinct positive/negative transformations in one causal route; no real analyzer invocation|retain
661|Templates mutation token leaks, attaches to reads, overwrites explicit invalid auth or applies to foreign server|Real loopback HTTP auth fixture, own Unicode/spaced token file, actual proxy|Read receives no auth, mutations receive token, valid explicit auth retained, invalid auth401, health does not leak token, other server rejected|Token is a test literal in an owned temp directory; no user token or external API. Explicit policy differs from syntax/docs adapters|retain
'@ -split '\r?\n'
$rows=@(foreach($record in $records){
    $v=$record -split '\|',6
    $case=@($inventory | Where-Object {[int]$_.line -eq [int]$v[0]})
    if($v.Count -ne 6 -or $case.Count -ne 1){throw 'Node review must resolve to one frozen definition'}
    $case=$case[0]
    [pscustomobject][ordered]@{sourceCommit='fa0e3c91694112c1da3ecda7209a8a81ea828264';file=$file;originalLine=$case.line;name=$case.name;normalizedBodySha256=$case.normalizedBodySha256;sourceSha256=$source[0].sourceSha256;owners=$case.owners;risk=$v[1];inputs=$v[2];level='actual transform and loopback HTTP/process boundary';environment='Node built-in assert/http/fetch; original script and HostToolsProxy route';resources='OS-assigned loopback listeners, own temp files and CLI child; original finally cleanup';retainedProof=$v[3];limitation=$v[4];decision=$v[5];history='Read-only semantic review; no fresh execution, timing or flake claim'}
})
if($rows.Count -ne 8 -or $inventory.Count -ne 8){throw 'All eight original Node definitions must be represented'}
$rows | Export-Csv (Join-Path $evidence 'node-proxy-review.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{reviewedOriginalDefinitions=$rows.Count;sourceUnchanged=$true;testsRun=$false} | ConvertTo-Json -Compress
