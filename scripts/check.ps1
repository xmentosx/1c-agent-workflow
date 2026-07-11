[CmdletBinding()]
param(
    [ValidateSet("Fast", "Full", "Release")]
    [string]$Mode = "Full",
    [string]$AiRulesSource = "",
    [switch]$Offline,
    [string]$E2EProjectRoot = "",
    [string]$OutputDirectory = "build\test-results\local"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$summaryPath = Join-Path $outputRoot "check-summary.json"
$junitPath = Join-Path $outputRoot "pester.xml"
$startedAt = [DateTime]::UtcNow
$stages = New-Object System.Collections.Generic.List[object]
$pesterResult = $null
$failure = $null

function Add-StageResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )
    $script:stages.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
    }) | Out-Null
}

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-PowerShellChild {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 300,
        [string]$LogName = "child"
    )

    $stdoutPath = Join-Path $outputRoot ($LogName + ".stdout.log")
    $stderrPath = Join-Path $outputRoot ($LogName + ".stderr.log")
    $argumentParts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (ConvertTo-NativeArgument -Value $ScriptPath)
    )
    foreach ($argument in @($Arguments)) {
        $argumentParts += (ConvertTo-NativeArgument -Value ([string]$argument))
    }

    $process = Start-Process -FilePath "powershell.exe" `
        -ArgumentList ($argumentParts -join " ") `
        -WorkingDirectory $repoRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw "$LogName timed out after $TimeoutSeconds seconds. See $stdoutPath and $stderrPath"
    }
    # Start-Process may not populate ExitCode after the timed overload until
    # output redirection is drained and the process object is refreshed.
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne 0) {
        throw "$LogName failed with exit code $exitCode. See $stdoutPath and $stderrPath"
    }
}

function Resolve-AiRulesSource {
    if (-not [string]::IsNullOrWhiteSpace($AiRulesSource)) {
        return $AiRulesSource
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ITL_AI_RULES_SOURCE_PATH)) {
        return $env:ITL_AI_RULES_SOURCE_PATH
    }
    return "https://github.com/comol/ai_rules_1c.git"
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Push-Location $repoRoot
try {
    if ($Mode -eq "Release") {
        throw "Release gate is intentionally unavailable until a verified immutable fork tag and the dedicated 1C E2E stand are integrated."
    }

    $trackedBefore = @(& git status --porcelain --untracked-files=no)
    & git diff --check HEAD -- .
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --check failed."
    }
    Add-StageResult -Name "git-diff-check" -Status "passed"

    Import-Module Pester -MinimumVersion 5.0.0 -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = if ($Mode -eq "Fast") {
        @(
            ".\tests\pester\ParserDocsBudgets.Tests.ps1",
            ".\tests\pester\HostTooling.Tests.ps1",
            ".\tests\pester\DependencyLocks.Tests.ps1",
            ".\tests\pester\AiRulesClients.Tests.ps1",
            ".\tests\pester\LocalQualityGate.Tests.ps1"
        )
    } else {
        @(".\tests\pester")
    }
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = $(if ($Mode -eq "Fast") { "Normal" } else { "Detailed" })
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = "JUnitXml"
    $configuration.TestResult.OutputPath = $junitPath
    $pesterResult = Invoke-Pester -Configuration $configuration
    if ([string]$pesterResult.Result -ne "Passed") {
        throw "Pester did not pass: result=$($pesterResult.Result), failed=$($pesterResult.FailedCount)."
    }
    Add-StageResult -Name "pester" -Status "passed" -Detail "$($pesterResult.PassedCount) passed"

    if ($Mode -eq "Full") {
        $helperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        Invoke-PowerShellChild -ScriptPath $helperPath -Arguments @("-Action", "help") -TimeoutSeconds 60 -LogName "helper-help"
        Add-StageResult -Name "helper-help" -Status "passed"

        $resolvedAiRulesSource = Resolve-AiRulesSource
        $sourceIsLocal = Test-Path -LiteralPath $resolvedAiRulesSource -PathType Container
        if ($Offline -and -not $sourceIsLocal) {
            Add-StageResult -Name "ai-rules-compatibility" -Status "skipped" -Detail "Offline mode and no local aiRules source"
        } else {
            if ($sourceIsLocal) {
                $forkGate = Join-Path ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) "scripts\check.ps1"
                if (Test-Path -LiteralPath $forkGate -PathType Leaf) {
                    Invoke-PowerShellChild -ScriptPath $forkGate -Arguments @("-Mode", "Full") -TimeoutSeconds 600 -LogName "fork-check"
                    Add-StageResult -Name "fork-check" -Status "passed" -Detail $resolvedAiRulesSource
                }
            }

            $compatibilityPath = Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1"
            Invoke-PowerShellChild -ScriptPath $compatibilityPath -Arguments @("-AiRulesSource", $resolvedAiRulesSource) -TimeoutSeconds 600 -LogName "ai-rules-compatibility"
            Add-StageResult -Name "ai-rules-compatibility" -Status "passed" -Detail $resolvedAiRulesSource
        }
    }

    & git diff --check HEAD -- .
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --check failed after tests."
    }
    $trackedAfter = @(& git status --porcelain --untracked-files=no)
    if (($trackedBefore -join "`n") -ne ($trackedAfter -join "`n")) {
        throw "The local gate changed tracked worktree state."
    }
    Add-StageResult -Name "tracked-state" -Status "passed" -Detail "Tests left tracked state unchanged"
} catch {
    $failure = $_.Exception.Message
    Add-StageResult -Name "gate" -Status "failed" -Detail $failure
} finally {
    $commit = (& git rev-parse HEAD 2>$null)
    $dirty = @(& git status --porcelain).Count -gt 0
    $summary = [ordered]@{
        schemaVersion = 1
        repository = "1c-agent-workflow"
        mode = $Mode
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        commit = [string]$commit
        worktreeClean = (-not $dirty)
        offline = [bool]$Offline
        tests = [ordered]@{
            passed = $(if ($pesterResult) { [int]$pesterResult.PassedCount } else { 0 })
            failed = $(if ($pesterResult) { [int]$pesterResult.FailedCount } else { 0 })
            skipped = $(if ($pesterResult) { [int]$pesterResult.SkippedCount } else { 0 })
        }
        stages = @($stages | ForEach-Object { $_ })
        error = $failure
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)
    Pop-Location
}

if ($failure) {
    Write-Error $failure
    exit 1
}

Write-Host "ITL $Mode gate passed. Summary: $summaryPath"
