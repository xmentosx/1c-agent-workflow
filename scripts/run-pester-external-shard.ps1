[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProfilePath,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [string]$PlanPath='', [string]$JunitPath='', [switch]$RuntimeIdentityOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'invoke-pester-runtime.ps1')
. (Join-Path $PSScriptRoot 'pester-external-runtime.ps1')
$spec=Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8|ConvertFrom-Json
if($RuntimeIdentityOnly){
    $null=Get-PesterExternalRuntimeReceipt -RepositoryRoot $spec.repositoryRoot -Profiles $spec.profiles -ReceiptPath $ResultPath
    exit 0
}
$before=Get-PesterExternalRuntimeReceipt -RepositoryRoot $spec.repositoryRoot -Profiles $spec.profiles
# The ordinary worker and its assertions are unchanged. The adapter observes
# external inputs on both sides and adds only a reuse-eligibility witness.
& (Join-Path $PSScriptRoot 'run-pester-shard.ps1') -PlanPath $PlanPath -JunitPath $JunitPath -ResultPath $ResultPath
$after=Get-PesterExternalRuntimeReceipt -RepositoryRoot $spec.repositoryRoot -Profiles $spec.profiles
$result=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
$witness=[ordered]@{}
foreach($property in $before.PSObject.Properties){
    $last=$after.PSObject.Properties[$property.Name]
    $first=$property.Value
    $known=$first.status -eq 'known' -and $last -and $last.Value.status -eq 'known' -and $first.sha256 -ceq $last.Value.sha256
    $witness[$property.Name]=if($known){$first}else{[pscustomobject]@{status='unknown';sha256='';reason='External inputs unknown or changed during the original test.'}}
}
$result|Add-Member -NotePropertyName externalRuntimeIdentity -NotePropertyValue ([pscustomobject]$witness) -Force
[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
if($result.status -ne 'passed'){exit 1}
