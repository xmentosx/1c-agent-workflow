param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$destination='tests/pester/SourceQualityCatalog.Tests.ps1'
if(Test-Path -LiteralPath (Join-Path $RepositoryRoot $destination)){throw 'One-shot transfer already applied.'}
$items=@(
    @{file='LocalQualityGate';kind='It';name='allows the observed passing cold cohorts and retains bounded aggregate budgets'}
    @{file='LocalQualityGate';kind='It';name='keeps the short modes cheap and reserves broad proof for Develop and Release'}
    @{file='LocalQualityGate';kind='It';name='uses the catalog Targeted worker default only when PesterWorkers is implicit'}
    @{file='LocalQualityGate';kind='It';name='keeps the exact stabilization E owner selection and models four workers with hard-budget reserve'}
    @{file='LocalQualityGate';kind='It';name='fits the observed lifecycle cohort and mandatory serial tail without changing runtime watchdogs'}
    @{file='LocalQualityGate';kind='It';name='does not cache a shard whose external runtime identity is not modeled'}
    @{file='LocalQualityGate';kind='It';name='classifies Release readiness repairs as resumable Release harness changes'}
    @{file='LocalQualityGate';kind='Describe';name='Develop journey catalog hard budgets'}
    @{file='ReleaseGate';kind='Describe';name='Shared Release budget projection'}
)
$transfers=[Collections.Generic.List[object]]::new()
$commands=[Collections.Generic.List[string]]::new()
$describes=[Collections.Generic.List[string]]::new()
foreach($group in @($items | Group-Object file)) {
    $relative='tests/pester/'+$group.Name+'.Tests.ps1'
    $path=Join-Path $RepositoryRoot $relative
    $source=[IO.File]::ReadAllText($path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Parse failed: $relative"}
    $removals=@(foreach($item in $group.Group) {
        $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $item.kind -and $node.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.CommandElements[1].Value -ceq $item.name},$true))
        if($nodes.Count -ne 1){throw "Expected exactly one command: $($item.name)"}
        $node=$nodes[0]
        if($item.kind -eq 'It'){$commands.Add($node.Extent.Text)}else{$describes.Add($node.Extent.Text)}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($node.Extent.Text.Replace("`r`n","`n")))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;kind=$item.kind;name=$item.name;originalCommandSha256=$digest;destinationFile=$destination})
        $node.Extent
    })
    foreach($extent in @($removals | Sort-Object StartOffset -Descending)) {
        $start=$extent.StartOffset
        while($start -gt 0 -and $source[$start-1] -in @(' ',"`t")){$start--}
        $source=$source.Remove($start,$extent.EndOffset-$start)
    }
    [IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
}
$prefix=@'
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Source quality catalog contracts' {
'@
$output=$prefix+"`r`n"+($commands -join "`r`n`r`n")+"`r`n}`r`n`r`n"+($describes -join "`r`n`r`n")+"`r`n"
[IO.File]::WriteAllText((Join-Path $RepositoryRoot $destination),$output,[Text.UTF8Encoding]::new($true))
$transfers | Export-Csv -LiteralPath (Join-Path $RepositoryRoot 'openspec/changes/redesign-source-delivery/evidence/quality-catalog-transfers.csv') -NoTypeInformation -Encoding UTF8
