[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RecordPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$record=[IO.File]::ReadAllText($RecordPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
$process=Get-Process -Id ([int]$record.pid) -ErrorAction Stop
if ($process.ProcessName -notin @('1cv8','1cv8c') -or
    $process.StartTime.ToUniversalTime() -ne ([datetime]$record.startedAt).ToUniversalTime()) {
    throw 'ITL_ONEC_PROCESS_IDENTITY_CHANGED'
}
$native=Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$record.pid)
$lib=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\1c-workflow\scripts\lib'))
foreach($name in @('core','runtime-values','ports','sessions')) { . (Join-Path $lib ('agent-1c.'+$name+'.ps1')) }
$actual=Get-SafeOneCProcessInfoBase -CommandLine ([string]$native.CommandLine)
if ($actual -ne [string]$record.infoBase.path) { throw 'ITL_ONEC_PROCESS_BASE_CHANGED' }
'{"ownedProcessVerified":true}'
