param([Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$AcceptedSummary,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'

. (Join-Path $RepositoryRoot 'scripts/quality-contracts.ps1')
. (Join-Path $RepositoryRoot 'scripts/git-path-list.ps1')
. (Join-Path $RepositoryRoot 'scripts/invoke-pester-runtime.ps1')
$tokens=$null;$errors=$null
$current=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Current parser errors'}
$oldText=@(& git -C $RepositoryRoot show '3e589904:scripts/invoke-pester-shards.ps1') -join "`n"
$old=[Management.Automation.Language.Parser]::ParseInput($oldText,[ref]$tokens,[ref]$errors)
if($errors){throw 'Baseline parser errors'}
foreach($name in @('Get-TextSha256','Get-ShardRelativeTestPath','Get-ShardTrackedFileIdentity','Initialize-PesterTrackedIdentityCache','Get-ExternalInputIdentity')) {
    $definition=$current.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$catalog=Get-QualityContractCatalog -RepositoryRoot $RepositoryRoot
$sharedInputs=@('tests/pester/TestSupport.ps1','scripts/run-pester-shard.ps1','scripts/invoke-pester-runtime.ps1')
$pesterExternalInputsByTest=@{}
foreach($property in $catalog.pesterExternalInputs.PSObject.Properties){$pesterExternalInputsByTest[$property.Name]=@($property.Value)}
$accepted=Get-Content $AcceptedSummary -Raw -Encoding UTF8|ConvertFrom-Json
$script:pesterRuntimeReceipt=[pscustomobject]@{status='known';identity=$accepted.runtimeIdentity}
$tests=@($accepted.workers|ForEach-Object {$_.paths[0]})
$variants=@(@{})+@(1..4|ForEach-Object {@{LegacyWorkerCount=$_}})+@(
    @{LegacyWorkerCount=4;IncludeLegacyGlobalExternalInputs=$true}
    @{LegacyWorkerCount=4;IncludeLegacyGlobalExternalInputs=$true;ExternalIdentityOverrides=@{ITL_AI_RULES_SOURCE_PATH='env:ITL_AI_RULES_SOURCE_PATH=<unset>'}}
    @{LegacyWorkerCount=4;IncludeLegacyGlobalExternalInputs=$true;ExternalIdentityOverrides=@{ITL_AI_RULES_SOURCE_PATH='env:ITL_AI_RULES_SOURCE_PATH=<unset>';ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE='env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE=<unset>'}}
)
function Measure-Definition($Ast,[bool]$Prepared) {
    $definition=$Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-ShardInputDigest'},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $script:pesterTrackedIdentityCache=@{};$script:pesterExternalIdentityCache=@{}
    Initialize-PesterTrackedIdentityCache
    $values=New-Object 'Collections.Generic.List[string]'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    foreach($test in $tests) {
        $preparedInputs=$null
        foreach($variant in $variants) {
            if($Prepared){$digest=Get-ShardInputDigest -Paths @($test) -PreparedInputs ([ref]$preparedInputs) @variant}
            else{$digest=Get-ShardInputDigest -Paths @($test) @variant}
            if(-not $digest){throw "Unexpected unknown identity: $test"}
            $values.Add($digest)
        }
    }
    $watch.Stop()
    [pscustomobject]@{durationMs=$watch.ElapsedMilliseconds;digests=$values.ToArray()}
}
$before=Measure-Definition $old $false
$after=Measure-Definition $current $true
if(@(Compare-Object $before.digests $after.digests).Count){throw 'Existing fingerprint values changed'}
$receipt=[ordered]@{baseline='3e589904';selectedFiles=$tests.Count;variantsPerFile=$variants.Count;keysCompared=$before.digests.Count;identicalDigests=$true;beforeMs=$before.durationMs;afterMs=$after.durationMs;speedup=([double]$before.durationMs/$after.durationMs);evidence='Definition-only actual repository input resolution; fixed recent observed runtime identity, no Pester or gate dispatch; both definitions see the same current bytes'}
$receipt|ConvertTo-Json|Set-Content $OutputPath -Encoding UTF8
$receipt|ConvertTo-Json -Compress
