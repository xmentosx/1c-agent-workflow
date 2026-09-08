[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$FeaturePath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$lib=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\1c-workflow\scripts\lib'))
. (Join-Path $lib 'agent-1c.core.ps1')
$context=Read-Utf8Text -Path $env:ITL_RUN_CONTEXT | ConvertFrom-Json
$va=$context.target.vanessa
foreach($path in @($FeaturePath,$va.epf,$va.settingsTemplate)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'VANESSA_PINNED_INPUT_REQUIRED' }
}
if (-not $va.managerBase) { throw 'VANESSA_MANAGER_BASE_REQUIRED' }
$iteration=[string]$context.iteration
$private=Join-Path $iteration 'private'
New-Item -ItemType Directory -Path $private -Force | Out-Null
$settings=Read-Utf8Text -Path $va.settingsTemplate | ConvertFrom-Json
$values=@{ featurepath=[IO.Path]::GetFullPath($FeaturePath); logpath=$iteration; junitpath=$iteration; textlogname=(Join-Path $iteration 'vanessa.log'); 'ПутьКФайлуДляВыгрузкиСтатусаВыполненияСценариев'=(Join-Path $iteration 'vanessa-status.txt') }
foreach($key in $values.Keys) { $settings | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force }
# The pinned project's feature adapter reads ITL_RUN_CONTEXT. It owns readiness/assertions.
$settingsPath=Join-Path $private 'VAParams.json'
Write-Utf8TextAtomic -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 40)
$spec=@{ role='manager'; executable=$context.target.platform; mode='ENTERPRISE'; arguments=@('/TESTMANAGER','/Execute',[string]$va.epf,'/C',('StartFeaturePlayer;VAParams='+$settingsPath),'/Out',(Join-Path $iteration 'manager.log')) }
$specPath=Join-Path $private 'manager-spec.json'
Write-Utf8TextAtomic -Path $specPath -Value ($spec | ConvertTo-Json -Depth 8)
$launch=& (Join-Path $PSScriptRoot 'Invoke-OneCProcess.ps1') -SpecPath $specPath | ConvertFrom-Json
$process=Get-Process -Id $launch.pid -ErrorAction Stop
$process.WaitForExit()
if ($process.ExitCode -ne 0) { throw ('VANESSA_MANAGER_FAILED: '+$process.ExitCode) }
