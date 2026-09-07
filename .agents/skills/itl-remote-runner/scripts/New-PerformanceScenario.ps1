[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectRoot,[Parameter(Mandatory=$true)][string]$Name)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8='1'
& python (Join-Path $PSScriptRoot 'remote_work.py') scaffold --project $ProjectRoot --name $Name
if ($LASTEXITCODE) { throw 'SCENARIO_SCAFFOLD_FAILED' }
