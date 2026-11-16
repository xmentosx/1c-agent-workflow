param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# One-shot source transfer and exact-equivalence receipt, not a routine gate.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$relative='tests/pester/CompactItlRunner.Tests.ps1'
$path=Join-Path $root $relative
$source=[IO.File]::ReadAllText($path)
if((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne '4892160074cde776872ef86a969291cfb73575bc5bfef6d2fb81a9e314ceb846'){throw 'Expected the unchanged fully reviewed Compact baseline'}
function Parse-Suite([string]$Text) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors){throw 'Suite parse failure'}
    return $ast
}
function Commands($Ast,[string]$Name) {
    @($Ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq $Name},$true))
}
function Hash-Body([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
}
$ast=Parse-Suite $source
$its=@(Commands $ast 'It')
$describes=@(Commands $ast 'Describe')
if($its.Count -ne 45 -or $describes.Count -ne 2){throw 'Expected45 definitions and2 complete Describes'}
$setup=@(Commands $describes[0] 'BeforeAll')[0].Extent.Text
$mapping=[ordered]@{
    CompactRunnerReports=@(67,102,134,175,239,279,466,486,563,594,1278,1305,1325,1348,1375)
    CompactRunnerRouting=@(37,300,350,411,506)
    CompactRunnerWatchdog=@(624,674,715,755,793,826,934,968,996,1029,1209,1246)
}
$transfers=New-Object 'Collections.Generic.List[object]'
$removals=New-Object 'Collections.Generic.List[object]'
foreach($entry in $mapping.GetEnumerator()) {
    $nodes=@($its | Where-Object {$_.Extent.StartLineNumber -in $entry.Value})
    if($nodes.Count -ne $entry.Value.Count){throw "Missing reviewed definition for $($entry.Key)"}
    $destination='tests/pester/'+$entry.Key+'.Tests.ps1'
    $body='Describe "compact ITL command runner" {'+"`r`n    "+$setup+"`r`n`r`n    "+(($nodes | ForEach-Object {$_.Extent.Text}) -join "`r`n`r`n    ")+"`r`n}`r`n"
    [IO.File]::WriteAllText((Join-Path $root $destination),$body,[Text.UTF8Encoding]::new($true))
    foreach($node in $nodes) {
        $removals.Add($node.Extent)
        $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;name=$node.CommandElements[1].Value;destinationFile=$destination;normalizedBodySha256=Hash-Body $node.Extent.Text;setupSha256=Hash-Body $setup;transfer='Exact original It and scoped BeforeAll; original Describe name retained'})
    }
}
$fresh=$describes[1]
$freshDestination='tests/pester/CompactRunnerFreshContinuation.Tests.ps1'
[IO.File]::WriteAllText((Join-Path $root $freshDestination),($fresh.Extent.Text+"`r`n"),[Text.UTF8Encoding]::new($true))
$removals.Add($fresh.Extent)
foreach($node in @(Commands $fresh 'It')) {
    $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;name=$node.CommandElements[1].Value;destinationFile=$freshDestination;normalizedBodySha256=Hash-Body $node.Extent.Text;setupSha256=Hash-Body (@(Commands $fresh 'BeforeAll')[0].Extent.Text);transfer='Complete original Describe, including BeforeAll and child fixtures'})
}
foreach($extent in @($removals | Sort-Object StartOffset -Descending)) {$source=$source.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset)}
$serialNodes=@(Commands (Parse-Suite $source) 'It')
$source='Describe "compact ITL command runner" {'+"`r`n    "+$setup+"`r`n`r`n    "+(($serialNodes | ForEach-Object {$_.Extent.Text}) -join "`r`n`r`n    ")+"`r`n}`r`n"
[IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
$files=@($relative)+@($transfers.destinationFile | Sort-Object -Unique)
$current=@(foreach($file in $files){Commands (Parse-Suite ([IO.File]::ReadAllText((Join-Path $root $file)))) 'It'})
$before=@($its | ForEach-Object {Hash-Body $_.Extent.Text} | Sort-Object)
$after=@($current | ForEach-Object {Hash-Body $_.Extent.Text} | Sort-Object)
if($current.Count -ne 45 -or @(Compare-Object $before $after).Count){throw 'Original It multiset changed'}
foreach($entry in $mapping.GetEnumerator()) {
    $new=Parse-Suite ([IO.File]::ReadAllText((Join-Path $root ('tests/pester/'+$entry.Key+'.Tests.ps1'))))
    if((Hash-Body (@(Commands $new 'BeforeAll')[0].Extent.Text)) -cne (Hash-Body $setup)){throw 'Scoped setup changed'}
}
$newFresh=Parse-Suite ([IO.File]::ReadAllText((Join-Path $root $freshDestination)))
if((Hash-Body (@(Commands $newFresh 'Describe')[0].Extent.Text)) -cne (Hash-Body $fresh.Extent.Text)){throw 'Fresh Describe changed'}
$retained=@(Commands (Parse-Suite $source) 'It' | ForEach-Object {$_.CommandElements[1].Value})
if($retained.Count -ne 3 -or @($its | Where-Object {$_.Extent.StartLineNumber -in @(18,858,1085)} | Where-Object {$_.CommandElements[1].Value -notin $retained}).Count){throw 'Serial Win32 boundaries changed'}
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$transfers | Export-Csv (Join-Path $evidence 'compact-suite-transfers.csv') -NoTypeInformation -Encoding UTF8
[ordered]@{sourceSha256='4892160074cde776872ef86a969291cfb73575bc5bfef6d2fb81a9e314ceb846';originalDefinitions=45;retainedSerialDefinitions=3;transferredDefinitions=$transfers.Count;exactItMultiset=$true;exactScopedSetup=$true;exactFreshDescribe=$true;files=$files;runtimeAcceptance='Separate native Targeted required; source transfer is not runtime or concurrent isolation proof'} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence 'compact-suite-proof.json') -Encoding UTF8
