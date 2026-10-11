[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# Explicit audit-document generation only; not a gate or installed runtime check.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$inventory=@(Import-Csv (Join-Path $evidence 'inventory/test-cases.csv'))
$sourceFiles=@(Import-Csv (Join-Path $evidence 'inventory/test-files.csv'))
$resolved=@{}
function Add-OriginalReview {
    param([string]$File,[int]$Line,[string]$Name,[string]$Reference,[string]$Decision,[string]$Scope,[string]$BodySha256='',[string]$SourceSha256='')
    $case=@($inventory|Where-Object {$_.file -ceq $File -and [int]$_.line -eq $Line -and $_.name -ceq $Name})
    if($case.Count -ne 1){throw "Review does not resolve to one original definition: $File : $Line : $Name"}
    $case=$case[0]
    if($BodySha256 -and $BodySha256 -cne $case.normalizedBodySha256){throw "Review body identity differs from original: $Name"}
    if($SourceSha256) {
        $source=@($sourceFiles|Where-Object file -CEQ $File)
        if($source.Count -ne 1 -or $SourceSha256 -cne $source[0].sourceSha256){throw "Review file identity differs from original: $File"}
    }
    $key=$case.family+'|'+$case.file+'|'+$case.line+'|'+$case.name
    if(-not $resolved.ContainsKey($key)) {
        $resolved[$key]=[ordered]@{family=$case.family;file=$case.file;originalLine=$case.line;name=$case.name;baselineBodySha256=$case.normalizedBodySha256;reviewReferences=@();decisions=@();scope=@()}
    }
    $entry=$resolved[$key]
    $entry.reviewReferences=@($entry.reviewReferences+$Reference|Sort-Object -Unique)
    $entry.decisions=@($entry.decisions+$Decision|Sort-Object -Unique)
    $entry.scope=@($entry.scope+$Scope|Sort-Object -Unique)
}
foreach($ledger in @('parser-docs-review.csv','release-gate-review.csv','nested-boundary-review.csv','local-quality-review.csv','compact-runner-review.csv','readiness-review.csv','develop-qualification-review.csv','static-cache-review.csv','source-queue-review.csv','source-plan-review.csv','source-publish-review.csv','node-proxy-review.csv')) {
    foreach($row in Import-Csv (Join-Path $evidence $ledger)) {
        Add-OriginalReview $row.file ([int]$row.originalLine) $row.name $ledger $row.decision 'Individual behavior/risk review; runtime acceptance is separate' -BodySha256 $row.normalizedBodySha256 -SourceSha256 $row.sourceSha256
    }
}
foreach($row in Import-Csv (Join-Path $evidence 'mantis-route-gap-review.csv')) {
    Add-OriginalReview $row.file ([int]$row.line) $row.name 'mantis-route-gap-review.csv;mantis-state-test-route.md' $row.decision 'Necessity reviewed; one State route accepted, other twelve routes pending' -SourceSha256 $row.sourceSha256
}
$parameters=Get-Content (Join-Path $evidence 'parameter-case-review.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($row in $parameters.resolutions) {
    Add-OriginalReview $row.file ([int]$row.definitionLine) $row.definitionName 'parameter-case-review.json;parameter-case-review.md' $row.decision 'Explicit parameter outcomes reviewed; one original definition counted' -SourceSha256 $row.sourceSha256
}
foreach($row in Import-Csv (Join-Path $evidence 'host-suite-transfers.csv')) {
    Add-OriginalReview $row.sourceFile ([int]$row.sourceLine) $row.name 'priority-test-review.md;host-suite-transfers.csv' 'retain boundary and split component environment' 'Wrapper boundary reviewed; does not count nested Python/Node cases'
}
foreach($line in @(1085,1632,1638,1650,1664)) {
    $case=@($inventory|Where-Object {$_.file -ceq 'tests/pester/CompactItlRunner.Tests.ps1' -and [int]$_.line -eq $line})
    if($case.Count -ne 1){throw "Compact review identity missing: $line"}
    Add-OriginalReview $case[0].file $line $case[0].name 'priority-test-review.md' 'retain native boundary' 'Five selected cases only; no review of remaining Compact definitions implied'
}
$rows=@($resolved.Values|ForEach-Object {
    [pscustomobject][ordered]@{family=$_.family;file=$_.file;originalLine=$_.originalLine;name=$_.name;baselineBodySha256=$_.baselineBodySha256;reviewReferences=($_.reviewReferences -join ';');decisions=($_.decisions -join ';');scope=($_.scope -join ';')}
}|Sort-Object family,file,@{Expression={[int]$_.originalLine}})
$baseline=Get-Content (Join-Path $evidence 'inventory/test-inventory-summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($baseline.sourceCommit -cne 'fa0e3c91694112c1da3ecda7209a8a81ea828264' -or [int]$baseline.definitions -ne $inventory.Count){throw 'Frozen inventory metadata differs from the selected audit baseline'}
$summary=[ordered]@{schemaVersion=1;baselineCommit='fa0e3c91694112c1da3ecda7209a8a81ea828264';baselineDefinitions=$inventory.Count;reviewedOriginalDefinitions=$rows.Count;pendingOriginalDefinitions=($inventory.Count-$rows.Count);indexIsComplete=$false;familyCoverage=@($inventory|Group-Object family|ForEach-Object {[pscustomobject]@{family=$_.Name;baseline=$_.Count;reviewed=@($rows|Where-Object family -EQ $_.Name).Count}});evidenceMeaning='Deduplicated navigation over explicit semantic reviews, not new acceptance or gate evidence';parameterMeaning='29 outcomes of seven definitions and 46 Release variants of 33 definitions are included, never added to original-definition totals';unreviewedMeaning='All original definitions absent from review-index.csv remain pending; transfer proof alone is not necessity review'}
$rows|Export-Csv (Join-Path $evidence 'review-index.csv') -NoTypeInformation -Encoding UTF8
$summary|ConvertTo-Json -Depth 5|Set-Content (Join-Path $evidence 'review-index-summary.json') -Encoding UTF8
[pscustomobject]$summary|Select-Object baselineDefinitions,reviewedOriginalDefinitions,pendingOriginalDefinitions,indexIsComplete|ConvertTo-Json -Compress
