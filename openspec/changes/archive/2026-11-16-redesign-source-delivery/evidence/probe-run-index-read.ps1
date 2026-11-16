param([string]$RepositoryRoot, [string]$CommonGitDirectory)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $RepositoryRoot 'scripts/source-delivery-process.ps1')
function Get-DeliveryCommonGitDirectory { return $CommonGitDirectory }
$state = Read-DeliveryRunHotIndex
[pscustomobject][ordered]@{
    runtime = [string]$PSVersionTable.PSVersion
    edition = [string]$PSVersionTable.PSEdition
    status = [string]$state.status
    validRunCount = $(if ($state.index) { $state.index.validRunCount } else { $null })
    error = $(if ($state.PSObject.Properties['error']) { $state.error } else { '' })
} | ConvertTo-Json -Compress
