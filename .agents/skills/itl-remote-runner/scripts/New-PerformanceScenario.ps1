[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectRoot,[Parameter(Mandatory=$true)][string]$Name)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'PythonRuntime.ps1')
$code = Invoke-ItlPythonCommand -Arguments @((Join-Path $PSScriptRoot 'remote_work.py'), 'scaffold', '--project', $ProjectRoot, '--name', $Name)
if ($code -ne 0) { throw 'SCENARIO_SCAFFOLD_FAILED' }
