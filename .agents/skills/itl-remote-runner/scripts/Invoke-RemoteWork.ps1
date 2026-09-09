[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Arguments,
    [string]$Python = '',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'PythonRuntime.ps1')
if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'export' -and
    -not @($Arguments | Where-Object { $_ -eq '--python-archive' -or $_ -like '--python-archive=*' }).Count -and
    -not ($Arguments -contains '--help' -or $Arguments -contains '-h')) {
    $runtime = Get-ItlManagedPythonRuntime -Offline:$Offline -RequireArchive
    $Arguments += @('--python-archive', $runtime.archivePath)
}
$code = Invoke-ItlPythonCommand -Python $Python -Offline:$Offline -Arguments (@((Join-Path $PSScriptRoot 'remote_work.py')) + $Arguments)
exit $code
