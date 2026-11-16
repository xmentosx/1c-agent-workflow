[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# Explicit source-audit document generation, never a gate or runtime barrier.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$path='tests/pester/ReleaseReadiness.Tests.ps1'
$inventory=@(Import-Csv (Join-Path $evidence 'inventory/test-cases.csv') | Where-Object file -CEQ $path)
$file=@(Import-Csv (Join-Path $evidence 'inventory/test-files.csv') | Where-Object file -CEQ $path)
if($file.Count -ne 1 -or (Get-FileHash (Join-Path $root $path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file[0].sourceSha256){throw 'Readiness source must still match the frozen audit baseline'}
$records=@'
131|Continuation silently admits unqualified stand or loses early encoding boundary|Actual readiness and encoding source|static-wiring|Named proof/develop exclusion/managed agreement and single batch decoder before loop|Markers do not prove continuation execution or native launch ordering|retain; behavior-proof follow-up
144|Canonical immutable archive cannot produce usable Full readiness|Actual readiness child, private Git repo and real zip containing synthetic EPF/CFE bytes|native-process/archive|Passed context, exact archive path and no issues|Synthetic archive, no real Vanessa or 1C|retain
159|Early check hides one of multiple dependency failures|Actual readiness child with missing archive and stale compatibility revision|native-process/archive|Failed context contains both missing archive and compatibility drift|No network provisioning or real release repair|retain
178|Archive outer SHA admits a different internal EPF|Actual readiness child and real private zip, changed immutable EPF expectations|native-process/archive|Internal EPF hash mismatch despite coherent outer fixture archive|Synthetic EPF bytes; distinct from paired-extension boundary|retain
200|Paired CFE bytes escape immutable verification|Actual readiness child and altered paired-extension lock/compatibility SHA|native-process/archive|Paired extension mismatch is surfaced|Synthetic CFE bytes, not protocol/runtime qualification|retain
222|Stale stand, checkpoint or failed verification reaches 1C or mutates saved evidence|Actual readiness child, private stand repos/checkpoint, repeated mismatch variants|native-process/Git/checkpoint|Exact drift/unsafe/head/fixture/snapshot/verification/marker codes, no checkpoint rewrite; schema2 rejected; Restart removes expected stale issues|Many child launches; retains distinct boundaries until equivalent proof established; does not execute 1C|retain; cost follow-up
345|Legitimate owned refresh is rejected, or dirty/untracked changes are admitted|Actual readiness child and real Git main/worktree with marker commit|native-process/Git|Clean branch may refresh before checkpoint; tracked dirty and untracked both rejected|No actual refresh or update side effect is dispatched|retain
404|Generated Python caches cause false drift or conceal real source changes|Actual readiness child, real Git stand, CRLF Unicode source and tracked generated cache|native-process/Git/bytes|Four outcomes: cache-only accepted; modified/missing/extra source rejected; original source/cache bytes unchanged|Synthetic Python source, no Python interpreter invocation; four variants are not equivalent|retain
486|Invalid UTF8 reaches test execution|Actual readiness child and tracked invalid byte sequence|native-process/encoding|Failed readiness with explicit PowerShell encoding issue|Different boundary from well-formed UTF8 decoded incorrectly by Desktop|retain
505|UTF8 without BOM silently corrupts Cyrillic under PS5 default decoder|Actual readiness child and native Desktop decoder with Unicode and ASCII controls|native-process/encoding|Names bad source and avoids batch-decoder failure; exact decoder contract|Source encoding proof, not stdout/stderr transport round trip|retain
529|Develop shares Release stand, accepts foreign repo, absent worktree or wrong branch|Actual readiness child, real Git worktree and independent foreign repository|native-process/Git|Valid separate configured branch passes; foreign/shared/missing/wrong-branch variants rejected|Does not launch Develop journey or create a real database|retain
664|Unsupported stand HEAD is accepted based on commit title alone|Actual extracted checkpoint preflight and admission, private Unicode Git worktree|function/Git|Cross-source runner mismatch rejects unsupported transition; checkpoint bytes unchanged; sentinel absent from result|Actual workflow-transition definitions loaded; no real update transaction|retain
677|Second stand mutation after successful early read escapes validation|Actual preflight/admission with two observations and a new real Git commit|function/Git|Initial exact identity allowed; later HEAD rejected with mismatch|Sequential mutation, not a concurrent stress test|retain
690|Missing source proof becomes a blanket blocker instead of stage rerun|Actual admission and stage definitions with synthetic failed ondemand stage|function/Git|Valid HEAD allowed, source proof false, one stage rerun, zero issues|Stage input fingerprints consume current definitions/files; does not run ondemand E2E|retain
702|Changed saved state or env bytes are reused or exposed|Actual preflight/admission, two private saved-file mutations|function/Git/bytes|Both state and env copies rejected by SHA; altered bytes unchanged; password sentinel absent|Separate saved-file roles; no real secret or restore operation|retain
'@ -split '\r?\n'
$rows=@(foreach($record in $records){
    $v=$record -split '\|',7
    if($v.Count -ne 7){throw 'Malformed readiness review record'}
    $old=@($inventory | Where-Object {[int]$_.line -eq [int]$v[0]})
    if($old.Count -ne 1){throw "Missing original definition $($v[0])"};$old=$old[0]
    [pscustomobject][ordered]@{sourceCommit='fa0e3c91694112c1da3ecda7209a8a81ea828264';file=$path;originalLine=$old.line;name=$old.name;normalizedBodySha256=$old.normalizedBodySha256;sourceSha256=$file[0].sourceSha256;owners=$old.owners;risk=$v[1];inputs=$v[2];level=$v[3];environment='Windows PowerShell 5.1/Pester; Git; private zip archives; no real infobase or network provisioning';resources='Private TestDrive/GUID temp repos and worktrees; original cleanup preserved';retainedProof=$v[4];limitation=$v[5];decision=$v[6];history='Unchanged source passed 19/0/0 in accepted 2a8c2052 worker4, 229278 ms; per-case flake history unknown; no fresh readiness run for source review'}
})
if($rows.Count -ne 15 -or $inventory.Count -ne $rows.Count -or @($rows.originalLine | Sort-Object -Unique).Count -ne 15){throw 'Every original readiness definition must be reviewed once'}
$rows | Export-Csv (Join-Path $evidence 'readiness-review.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{reviewedOriginalDefinitions=$rows.Count;unchangedSource=$true;newTestsRun=$false} | ConvertTo-Json -Compress
