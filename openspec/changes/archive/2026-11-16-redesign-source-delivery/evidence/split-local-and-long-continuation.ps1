param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
# One-shot exact source transfer; original workloads and native deadlines survive.
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$evidence=Join-Path $root 'openspec/changes/redesign-source-delivery/evidence'
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
$transfers=New-Object 'Collections.Generic.List[object]'
$proofs=New-Object 'Collections.Generic.List[object]'
$plans=@(
    @{file='LocalQualityGate';sha='72a9dae8ca9f1d04bd0d31248aea0566366a2c018f76911ccb2378e2e44f8ef6';count=24;mapping=[ordered]@{
        LocalGateTransport=@(35,69,155,624)
        LocalTargetedSelection=@(220,232,286,303,369,432)
        LocalShardCache=@(475,507,662,701,720,734,749)
    }}
    @{file='CompactRunnerFreshContinuation';sha='b0dbfe58f05a4bd4c72939c823a7f077ba2cacfcbdb90197ccbf6311487e8220';count=10;mapping=[ordered]@{
        CompactRunnerLongContinuation=@(267)
    }}
)
foreach($plan in $plans) {
    $relative='tests/pester/'+$plan.file+'.Tests.ps1'
    $path=Join-Path $root $relative
    if((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.sha){throw "Reviewed baseline changed: $relative"}
    $source=[IO.File]::ReadAllText($path);$ast=Parse-Suite $source
    $its=@(Commands $ast 'It');$describes=@(Commands $ast 'Describe')
    if($its.Count -ne $plan.count -or $describes.Count -ne 1){throw "Unexpected original suite: $relative"}
    $describe=$describes[0]
    $setup=@(Commands $ast 'BeforeAll')
    if($setup.Count -ne 1){throw "Expected exactly one original setup: $relative"}
    $scoped=$setup[0].Extent.StartOffset -gt $describe.Extent.StartOffset
    $before=if($scoped){''}else{$setup[0].Extent.Text+"`r`n`r`n"}
    $scopedBefore=if($scoped){$setup[0].Extent.Text+"`r`n`r`n"}else{''}
    $describeHeader=$source.Substring($describe.Extent.StartOffset,$describe.CommandElements[-1].Extent.StartOffset-$describe.Extent.StartOffset)+'{'
    $selected=New-Object 'Collections.Generic.List[object]'
    $files=@($relative)
    foreach($entry in $plan.mapping.GetEnumerator()) {
        $nodes=@($its|Where-Object {$_.Extent.StartLineNumber -in $entry.Value})
        if($nodes.Count -ne $entry.Value.Count){throw "Missing original definitions for $($entry.Key)"}
        $destination='tests/pester/'+$entry.Key+'.Tests.ps1'
        if(Test-Path -LiteralPath (Join-Path $root $destination)){throw "Destination exists: $destination"}
        $body=$before+$describeHeader+"`r`n    "+$scopedBefore+"    "+(($nodes|ForEach-Object {$_.Extent.Text}) -join "`r`n`r`n    ")+"`r`n}`r`n"
        [IO.File]::WriteAllText((Join-Path $root $destination),$body,[Text.UTF8Encoding]::new($true))
        $files+=@($destination)
        foreach($node in $nodes) {
            $selected.Add($node)
            $transfers.Add([pscustomobject]@{sourceFile=$relative;sourceLine=$node.Extent.StartLineNumber;name=$node.CommandElements[1].Value;destinationFile=$destination;normalizedBodySha256=(Hash-Body $node.Extent.Text)})
        }
    }
    $retained=@($its|Where-Object {$_.Extent.StartOffset -notin @($selected|ForEach-Object {$_.Extent.StartOffset})})
    $body=$before+$describeHeader+"`r`n    "+$scopedBefore+"    "+(($retained|ForEach-Object {$_.Extent.Text}) -join "`r`n`r`n    ")+"`r`n}`r`n"
    [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($true))
    $newIts=@(foreach($file in $files){
        $newAst=Parse-Suite ([IO.File]::ReadAllText((Join-Path $root $file)))
        $newSetup=@(Commands $newAst 'BeforeAll')
        if($newSetup.Count -ne 1 -or $newSetup[0].Extent.Text -cne $setup[0].Extent.Text){throw "Setup changed: $file"}
        $newDescribe=@(Commands $newAst 'Describe')[0]
        if(($newSetup[0].Extent.StartOffset -gt $newDescribe.Extent.StartOffset) -ne $scoped){throw "Setup scope changed: $file"}
        Commands $newAst 'It'
    })
    if(@(Compare-Object @($its|ForEach-Object {Hash-Body $_.Extent.Text}|Sort-Object) @($newIts|ForEach-Object {Hash-Body $_.Extent.Text}|Sort-Object)).Count){throw "It multiset changed: $relative"}
    $proofs.Add([pscustomobject]@{source=$relative;sourceSha256=$plan.sha;originalDefinitions=$its.Count;currentDefinitions=$newIts.Count;retainedDefinitions=$retained.Count;exactItMultiset=$true;exactSetupAndScope=$true;files=$files})
}
$transfers|Export-Csv (Join-Path $evidence 'local-and-long-suite-transfers.csv') -NoTypeInformation -Encoding UTF8
[ordered]@{sourceCommit='1af9455b2647abfa482aab342ef75dd2e57db434';suites=$proofs.ToArray();runtimeAcceptance='Separate; exact source equality does not prove executed scenarios'}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $evidence 'local-and-long-suite-proof.json') -Encoding UTF8
