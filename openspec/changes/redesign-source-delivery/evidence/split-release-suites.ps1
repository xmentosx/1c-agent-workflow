param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$relative='tests/pester/ReleaseGate.Tests.ps1'
$path=Join-Path $root $relative
$source=[IO.File]::ReadAllText($path)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors){throw 'Release suite must parse before transfer'}
$beforeAll=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0].GetCommandName() -eq 'BeforeAll'})[0].Extent.Text
$mapping=[ordered]@{
    'Release E2E orchestration'='ReleaseOrchestration'
    'Develop upgrade manifest continuation'='DevelopManifestContinuation'
    'Unattended E2E client selection'='E2EClientSelection'
    'Release on-demand application snapshot continuation'='ReleaseSnapshotContinuation'
    'Shared Release admission decisions'='ReleaseAdmission'
}
$transfers=[Collections.Generic.List[object]]::new()
$removals=@(foreach($name in $mapping.Keys){
    $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Describe' -and $n.CommandElements[1].Value -ceq $name},$true))
    if($node.Count -ne 1){throw "Expected one original Describe: $name"};$node=$node[0]
    $destination='tests/pester/'+$mapping[$name]+'.Tests.ps1'
    if(Test-Path -LiteralPath (Join-Path $root $destination)){throw "Transfer already applied: $destination"}
    [IO.File]::WriteAllText((Join-Path $root $destination),($beforeAll+"`r`n`r`n"+$node.Extent.Text+"`r`n"),[Text.UTF8Encoding]::new($true))
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($node.Extent.Text.Replace("`r`n","`n")))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    $transfers.Add([pscustomobject]@{sourceCommit='11680e140ff788702e6fb6e2bd2b48a6c92328a2';sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;describe=$name;originalDescribeSha256=$digest;destinationFile=$destination;originalItDefinitions=@($node.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It'},$true)).Count})
    $node.Extent
})
foreach($extent in @($removals|Sort-Object StartOffset -Descending)){$source=$source.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset)}
[IO.File]::WriteAllText($path,($source.TrimEnd()+"`r`n"),[Text.UTF8Encoding]::new($true))
$transfers|Export-Csv (Join-Path $root 'openspec/changes/redesign-source-delivery/evidence/release-suite-transfers.csv') -NoTypeInformation -Encoding UTF8
