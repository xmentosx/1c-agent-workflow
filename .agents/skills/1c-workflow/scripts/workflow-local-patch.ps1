[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Capture','Seal','Find')][string]$Action,
    [string]$ProjectRoot = (Get-Location).Path,
    [string[]]$Paths = @(),
    [string]$ReportPath = '',
    [string]$ArchiveId = '',
    [string]$Query = '',
    [ValidateRange(1,20)][int]$Limit = 10
)
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$LifecyclePhase = ''
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
. (Join-Path $PSScriptRoot 'lib/agent-1c.core.ps1')
. (Join-Path $PSScriptRoot 'lib/agent-1c.lifecycle.ps1')
. (Join-Path $PSScriptRoot 'lib/agent-1c.local-patch.ps1')
if ($Action -eq 'Find') { ConvertTo-Json -InputObject @(Find-WorkflowFixArchive -Query $Query -Limit $Limit) -Depth 5; return }
if ($Action -eq 'Capture') { $receipt = New-WorkflowPatchReceipt -Paths $Paths -ReportPath $ReportPath -ArchiveId $ArchiveId }
else { $receipt = Set-WorkflowPatchSealed }
[pscustomobject]@{ phase=$receipt.phase; projectRoot=$receipt.projectRoot; branch=$receipt.branch; reportPath=$receipt.reportPath; files=@($receipt.files | ForEach-Object { $_.path }) } | ConvertTo-Json -Depth 4
