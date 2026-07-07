[CmdletBinding()]
param(
    [switch]$CI,
    [string]$OutputFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    Import-Module Pester -MinimumVersion 5.0.0 -Force

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @(".\tests\pester")
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = $(if ($CI) { "Detailed" } else { "Normal" })

    if ($CI -and -not $OutputFile) {
        $OutputFile = "build\test-results\pester\testResults.xml"
    }

    if ($CI -or $OutputFile) {
        $resolvedOutputFile = if ([System.IO.Path]::IsPathRooted($OutputFile)) {
            [System.IO.Path]::GetFullPath($OutputFile)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputFile))
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutputFile) | Out-Null
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = "JUnitXml"
        $configuration.TestResult.OutputPath = $resolvedOutputFile
    }

    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0) {
        exit 1
    }
} finally {
    Pop-Location
}
