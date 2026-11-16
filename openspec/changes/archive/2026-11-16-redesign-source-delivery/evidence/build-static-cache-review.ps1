param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# Explicit source audit only; synthetic Full payloads are not qualification.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$file='tests/pester/DevelopStaticQualificationCache.Tests.ps1'
$original=@(Import-Csv (Join-Path $evidence 'inventory/test-files.csv')|Where-Object file -CEQ $file)
$inventory=@(Import-Csv (Join-Path $evidence 'inventory/test-cases.csv')|Where-Object file -CEQ $file)
if($original.Count -ne 1 -or $original[0].sourceSha256 -cne (Get-FileHash (Join-Path $root $file)).Hash.ToLowerInvariant()){throw 'Static cache source differs from the fully reviewed frozen baseline'}
$records=@'
39|Valid exact-tree static proof is lost after qualification directory removal|Actual owner Save/Restore, Git fixture and synthetic schema2 Full/JUnit|native-Git/filesystem|Manifest exists, directory deleted, restored tree and exact JUnit SHA verified|No real Full or deleted Develop worktree; title describes modeled recovery|retain
50|A linked Unicode worktree uses a wrong per-worktree cache instead of common Git|Actual Git linked worktree and UTF8 common-directory helper|native-Git/path|Real worktree add succeeds, cache has exact common-Git root prefix, original cleanup retained|Private filesystem; no database or network|retain
65|Wrong tree or tampered cached JUnit is admitted|Actual owner cache validation and actual byte mutation|native-Git/filesystem|Wrong-tree save throws; modified cached JUnit causes restore false|Synthetic legacy proof; distinct from successful roundtrip39|retain
75|A retry reruns static work or skips the failed journey|Actual cache-match with controlled Validate and simulated Develop function|function/Git/filesystem|First fake E2E throws; deleted directory restored; second result reused, static1/E2E2 counters|Does not invoke check or an actual Develop/E2E process; title overstates proof|retain; live retry acceptance remains separate
114|Sibling equal-tree commits bypass ordinary trust or cannot use verified cache|Actual divergent Git commits, cache Save/Restore and trust callback|native-Git/function|Ordinary reuse rejects sibling; trusted cache admits independent-exact-tree; callback receives trust flag|Synthetic schema2 record; no Full execution|retain
162|Restore, Full validation, fail-fast E2E, Pester and save run in unsafe order|Actual check source offsets|static-wiring|Exact owner call order: restore/validation, early E2E/Pester, save/final route composition|Does not execute sequence or prove original-task recovery; behavior-proof follow-up|retain; behavior-proof follow-up
'@ -split '\r?\n'
$rows=@(foreach($record in $records) {
    $v=$record -split '\|',7
    if($v.Count -ne 7){throw 'Malformed individual static-cache review'}
    $old=@($inventory|Where-Object {[int]$_.line -eq [int]$v[0]})
    if($old.Count -ne 1){throw 'Original static-cache identity is not unique'};$old=$old[0]
    [pscustomobject][ordered]@{sourceCommit='fa0e3c91694112c1da3ecda7209a8a81ea828264';file=$file;originalLine=$old.line;name=$old.name;normalizedBodySha256=$old.normalizedBodySha256;sourceSha256=$original[0].sourceSha256;owners=$old.owners;risk=$v[1];inputs=$v[2];level=$v[3];environment='Windows PowerShell5.1/Pester, private Unicode/whitespace Git root';resources='Original GUID temp root and linked worktree cleanup; no real infobase';retainedProof=$v[4];limitation=$v[5];decision=$v[6];history='Unchanged six cases passed in accepted3e589904 worker7,19351ms; no per-case flake history inferred'}
})
if($rows.Count -ne 6 -or $inventory.Count -ne 6){throw 'All six original static-cache definitions must be reviewed'}
$rows|Export-Csv (Join-Path $evidence 'static-cache-review.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{reviewedOriginalDefinitions=$rows.Count;unchangedSource=$true;newTestsRun=$false}|ConvertTo-Json -Compress
