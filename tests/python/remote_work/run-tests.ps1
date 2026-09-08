[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8='1'
$env:PYTHONDONTWRITEBYTECODE='1'
& python -X utf8 -m unittest discover -s $PSScriptRoot -v
exit $LASTEXITCODE
