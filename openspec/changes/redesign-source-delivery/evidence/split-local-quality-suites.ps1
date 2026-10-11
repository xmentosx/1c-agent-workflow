param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# One-shot source refactor and equivalence receipt, never a routine gate.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$relative='tests/pester/LocalQualityGate.Tests.ps1'
$path=Join-Path $root $relative
$source=[IO.File]::ReadAllText($path)
function Parse-Suite([string]$Text) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors){throw 'Suite parse error before/after transfer'}
    return $ast
}
function Get-Commands($Ast,[string]$Name) {
    @($Ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $Name},$true))
}
function Get-BodyHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}
$ast=Parse-Suite $source
$originalIts=@(Get-Commands $ast 'It')
if($originalIts.Count -ne 46){throw 'Expected the reviewed 46-definition pre-transfer suite'}
$before=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0].GetCommandName() -eq 'BeforeAll'})[0].Extent.Text
$mapping=[ordered]@{
    'Scheduler-independent Pester proof'='PesterCacheCompatibility'
    'Release native progress observation'='ReleaseProgressObservation'
    'Pester shard selected-test identity'='PesterShardIdentity'
    'Controlled fork qualification script inventory'='ForkQualificationInventory'
}
$removals=[Collections.Generic.List[object]]::new()
$transfers=[Collections.Generic.List[object]]::new()
foreach($name in $mapping.Keys) {
    $nodes=@(Get-Commands $ast 'Describe'|Where-Object {$_.CommandElements[1].Value -ceq $name})
    if($nodes.Count -ne 1){throw "Expected one original Describe: $name"}
    $node=$nodes[0];$destination='tests/pester/'+$mapping[$name]+'.Tests.ps1'
    if(Test-Path -LiteralPath (Join-Path $root $destination)){throw "Transfer already exists: $destination"}
    [IO.File]::WriteAllText((Join-Path $root $destination),($before+"`r`n`r`n"+$node.Extent.Text+"`r`n"),[Text.UTF8Encoding]::new($true))
    $removals.Add($node.Extent)
    $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;group=$name;destinationFile=$destination;definitions=@(Get-Commands $node 'It').Count;originalGroupSha256=(Get-BodyHash $node.Extent.Text);transfer='exact Describe with all scoped setup'})
}
$cleanup=@($originalIts|Where-Object {$_.CommandElements[1].Value -in @(
    'removes an exact disposable E2E repository, worktree, and launcher registration',
    'removes the owned Cyrillic-path branch left after Git unregisters it but fails to delete its directory',
    'bulk-removes only missing Develop E2E launcher registrations',
    'finds nested special-path fresh entries and retains only three launcher backups',
    'removes only exact missing release-seed launcher entries',
    'removes verified Develop E2E CF exports while preserving unrelated result files',
    'removes only unconfigured workflow Release E2E worktrees after a passed journey'
)})
if($cleanup.Count -ne 7){throw 'Expected all seven cleanup boundary definitions'}
$destination='tests/pester/E2EArtifactCleanup.Tests.ps1'
if(Test-Path -LiteralPath (Join-Path $root $destination)){throw 'Cleanup transfer already exists'}
$body=$before+"`r`n`r`nDescribe 'Owned E2E artifact cleanup' {`r`n"+(@($cleanup|ForEach-Object {$_.Extent.Text}) -join "`r`n`r`n")+"`r`n}`r`n"
[IO.File]::WriteAllText((Join-Path $root $destination),$body,[Text.UTF8Encoding]::new($true))
foreach($node in $cleanup){
    $removals.Add($node.Extent)
    $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;group=$node.CommandElements[1].Value;destinationFile=$destination;definitions=1;originalGroupSha256=(Get-BodyHash $node.Extent.Text);transfer='exact It; original Describe has no scoped setup'})
}
foreach($extent in @($removals|Sort-Object StartOffset -Descending)){$source=$source.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset)}
[IO.File]::WriteAllText($path,($source.TrimEnd()+"`r`n"),[Text.UTF8Encoding]::new($true))
$files=@($relative)+@($transfers.destinationFile|Sort-Object -Unique)
$currentIts=@(foreach($file in $files){Get-Commands (Parse-Suite ([IO.File]::ReadAllText((Join-Path $root $file)))) 'It'})
$oldHashes=@($originalIts|ForEach-Object {Get-BodyHash $_.Extent.Text}|Sort-Object)
$newHashes=@($currentIts|ForEach-Object {Get-BodyHash $_.Extent.Text}|Sort-Object)
if($currentIts.Count -ne 46 -or @(Compare-Object $oldHashes $newHashes).Count){throw 'It multiset changed during transfer'}
foreach($file in $files){
    $newAst=Parse-Suite ([IO.File]::ReadAllText((Join-Path $root $file)))
    $setup=@($newAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0].GetCommandName() -eq 'BeforeAll'})[0].Extent.Text
    if($setup -cne $before){throw "Top-level BeforeAll changed: $file"}
}
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
$transfers|Export-Csv (Join-Path $evidence 'local-quality-suite-transfers.csv') -NoTypeInformation -Encoding UTF8
[ordered]@{sourceCommit='012a122588fa78e674138760536101465b06db76';originalDefinitions=46;currentDefinitions=$currentIts.Count;exactItMultiset=$true;exactTopLevelBeforeAll=$true;exactTransferredDescribeAndScopedSetup=$true;retainedLocalDefinitions=@(Get-Commands (Parse-Suite $source) 'It').Count;files=$files;runtimeAcceptance='Separate; AST equality proves retained source, not executed scenarios'}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $evidence 'local-quality-suite-proof.json') -Encoding UTF8
