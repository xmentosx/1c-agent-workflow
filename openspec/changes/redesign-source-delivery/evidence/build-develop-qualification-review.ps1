param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# Explicit semantic audit, not a runtime gate or proof of a real Develop journey.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$file='tests/pester/DevelopE2EQualification.Tests.ps1'
$sourceSha=(Get-FileHash (Join-Path $root $file)).Hash.ToLowerInvariant()
# This checkout uses complete CRLF; the earlier mixed-ending review snapshot
# (50dd60ce...) has identical LF-normalized bytes (c282b395...).
if($sourceSha -cne '58679110977216022c200b774f5840cbc7d44b81556eb53d63c24e7c46f1face'){throw 'Reviewed Develop qualification source changed'}
$inventory=@(Import-Csv (Join-Path $evidence 'inventory/test-cases.csv')|Where-Object file -CEQ $file)
$originalFile=@(Import-Csv (Join-Path $evidence 'inventory/test-files.csv')|Where-Object file -CEQ $file)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
if($errors){throw 'Develop qualification AST cannot be inspected'}
$current=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'It'},$true))
function Hash-Body([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Text -replace '\s+',' ').Trim())))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
}
$records=@'
98|Release-only changes discard valid ancestor proof or alter its report|Actual Git ancestor, input fingerprint and continuation cache|native-Git/function|Release-only budget reuse retains original route report bytes|Targeted and journey results are synthetic records; no actual journey|retain
115|Missing or changed exact proof admits ancestor continuation|Actual raw-proof reader with private Git and controlled binding|native-Git/function|No proof rejected; exact synthetic raw proof accepted; changed runtime/external binding rejected|The fixture does not invoke Targeted despite the test title|retain
132|Routing or Develop budget changes reuse incompatible proof|Actual input identity and legacy binding compatibility|function|Develop budget/routing changes invalidate; incomplete binding returns null; ancestor schema1 rejected, exact restore retained|No native E2E execution|retain
148|Corrupt evidence or a newer comparable failure is ignored|Actual report reader and failed qualification lookup|function|Corrupt report rejected; matching newer journey failure blocks, unrelated static/environment failures do not|Synthetic history does not prove live failure reporting|retain
169|Written provenance can be forged or lost on roundtrip|Actual check AST writer/reader, Git ancestor and synthetic reports|native-Git/AST-function|Complete provenance survives; forged Targeted SHA rejected|GetInputIdentity mocked; no full check dispatch|retain
204|Physical stand or external build identity ignores a meaningful change|Actual binding constructor and controlled stand/native artifact|function|UI alias and semantic dotenv identity separated; physical binding retained|Go discovery/stand state mocked; artifact is four synthetic bytes|retain
232|Case-sensitive inventory changes are lost or unstable|Actual ordinal inventory and four synthetic tracked inputs|function/Git|Fixture membership and ordinal ordering stable|Exact fixture count is not a production inventory count or cross-host execution|retain
248|Docs-only ancestor rebind admits production deltas or tampered proof|Actual Git Unicode docs, catalog and continuation with synthetic Targeted record|native-Git/function|No proof, wrong tree, changed raw SHA and ps1/yaml/json neighbor deltas reject|No real Targeted gate invoked|retain
319|Unknown ownership silently skips required journeys|Actual journey router|function|Unknown rejects; orchestration/Git helper requests both; direct test requests neither|Route decision does not execute either journey|retain
334|BaseRef routing loses deleted or non-ASCII paths|Actual NUL-safe Git range and router|native-Git|Empty range fails closed; Unicode addition/deletion retained|Private repository only|retain
365|Unrelated stand HEAD invalidates proof or changed 1C source stays invisible|Actual stand content identity with private tracked repos|native-Git/function|README commit ignored; dirty tracked input and src/cf delta detected; legacy clean stand supported|No actual database or Designer baseline|retain
411|Qualification cache crosses tree, journey, stand or identity boundaries|Actual cache writer/reader|function/filesystem|Exact tree works; journey/identity/stand mismatch and tampering reject; upgrade/fresh separated|Passed route payloads are synthetic|retain
451|Empty static-only qualification loses proof or skips an unplanned route|Actual check carry/partial AST branches with controlled schema4/schema3 records|AST-block execution|Empty static-only route retained; missing required route rejected|Block execution does not establish complete check orchestration|retain
494|Post-journey proof binds the old stand identity|Actual check source offsets and call ordering|static-wiring|Stand identity recomputed after journey and before cache write|Does not execute mutation sequence; behavior-proof follow-up remains|retain; behavior-proof follow-up
517|Client build scope corrupts parent environment or source artifacts|Actual client scope enter/exit, project overwrite and injected failure|function/filesystem|Parent environment restored on failure; artifact bytes unchanged|No build or child launch|retain
547|Absent explicit source clears inherited source permanently or scopes the wrong owner|Actual E2E entrypoint/check AST wiring and scope helpers|function/static-wiring|Temporary inherited-source clearing restored; try/finally and check ownership retained|No actual E2E; static call ordering alone has limited proof|retain; behavior-proof follow-up
579|Sync loses inherited source or persists it in stand settings|Actual Release Sync function, Unicode Git branch and helper child|native-process/Git|Child inherits source; persisted Vanessa settings remain separate|Invoke-E2EHelper replaced by controlled child plus Git fast-forward; no actual refresh/checkpoint|retain
653|Missing dedicated config reaches a real E2E with leaked scope|Actual Release entrypoint and source scope|native-process/preflight|Missing dedicated config rejected; parent source environment restored|Stops before fixture database or native E2E|retain
666|Helper-owned incidental settings invalidate or conceal semantic stand changes|Actual check identity function|function|AgentTarget changes identity; active-context, port and default export do not|No process or live stand|retain
693|Full rebind admits malformed, tampered or wrong-stand journey proof|Actual check writer/reader/rebind, Git docs commit, synthetic Full/route reports|native-Git/AST-function|Six malformed proofs rejected; failed rebind does not mutate; valid rebind retains route/report SHA; tampered route rejected|No actual Full/Develop run; original738 extended with Full binding assertions, earlier assertions retained|retain
'@ -split '\r?\n'
$rows=@(foreach($record in $records) {
    $v=$record -split '\|',7
    if($v.Count -ne 7){throw 'Malformed individual Develop review'}
    $node=@($current|Where-Object {$_.Extent.StartLineNumber -eq [int]$v[0]})
    if($node.Count -ne 1){throw "Missing current definition: $($v[0])"};$node=$node[0]
    $old=@($inventory|Where-Object name -CEQ $node.CommandElements[1].Value)
    if($old.Count -ne 1){throw 'Original identity is not unique'};$old=$old[0]
    $block=@($node.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[-1]
    $bodySha=Hash-Body $block.ScriptBlock.Extent.Text
    $exact=$bodySha -ceq $old.normalizedBodySha256
    if(-not $exact -and [int]$old.line -ne 738){throw "Unexpected review body difference: original$($old.line)/current$($v[0]); expected$($old.normalizedBodySha256), actual$bodySha"}
    [pscustomobject][ordered]@{sourceCommit='fa0e3c91694112c1da3ecda7209a8a81ea828264';file=$file;originalLine=$old.line;name=$old.name;normalizedBodySha256=$old.normalizedBodySha256;sourceSha256=$originalFile[0].sourceSha256;owners=$old.owners;risk=$v[1];inputs=$v[2];level=$v[3];environment='Windows PowerShell 5.1/Pester; private Git and controlled synthetic evidence; no real infobase';resources='Original TestDrive/GUID temporary repositories and scope restoration retained';retainedProof=$v[4];limitation=$v[5];decision=$v[6];currentFile=$file;currentLine=$node.Extent.StartLineNumber;currentSourceSha256=$sourceSha;currentNormalizedBodySha256=$bodySha;originalBodyMatches=$exact;history='Current20 passed in accepted 2a8c2052 worker6, 201653 ms; original22 includes two earlier reviewed catalog transfers; no per-case flake history inferred'}
})
if($inventory.Count -ne 22 -or $current.Count -ne 20 -or $rows.Count -ne 20 -or @($rows|Where-Object originalBodyMatches -EQ $true).Count -ne 19){throw 'Develop original/current coverage changed'}
$rows|Export-Csv (Join-Path $evidence 'develop-qualification-review.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{reviewedOriginalDefinitions=$rows.Count;exactBodies=19;extendedBodies=1;wholeFileUnchanged=$false;newTestsRun=$false}|ConvertTo-Json -Compress
