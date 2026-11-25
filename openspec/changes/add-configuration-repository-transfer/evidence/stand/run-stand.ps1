param([switch]$Clean)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stand-lib.ps1')
if ($Clean -and (Test-Path -LiteralPath $Root)) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null
$transcript = Join-Path $Root 'run.txt'
foreach ($step in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Name -match '^\d\d-.+\.ps1$' } | Sort-Object Name) {
    "### $($step.Name)" | Tee-Object -FilePath $transcript -Append
    & $step.FullName 2>&1 | Tee-Object -FilePath $transcript -Append
}
