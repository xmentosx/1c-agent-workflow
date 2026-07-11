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
$aiRulesRelease = $null
$e2eReportPath = ""

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
    return "https://github.com/xmentosx/itl_ai_rules_1c.git"
}

function Get-LocalForkRelease {
    param([string]$SourceRoot)

    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot ".git"))) {
        throw "Release requires a local Git checkout of the controlled ai_rules fork."
    }
    if (@(& git -C $SourceRoot status --porcelain).Count -gt 0) {
        throw "Controlled fork checkout must be clean for Release."
    }
    $origin = (& git -C $SourceRoot remote get-url origin).Trim()
    if ($origin.Replace('\', '/').TrimEnd('/').ToLowerInvariant() -notmatch 'github\.com/xmentosx/itl_ai_rules_1c(?:\.git)?$') {
        throw "Release aiRules source is not the controlled fork: $origin"
    }
    $commit = (& git -C $SourceRoot rev-parse HEAD).Trim()
    $tags = @(& git -C $SourceRoot tag --points-at HEAD --list "itl-*")
    if ($tags.Count -ne 1) {
        throw "Release fork HEAD must have exactly one immutable itl-* tag; found $($tags.Count)."
    }
    $tag = [string]$tags[0]
    if ((& git -C $SourceRoot cat-file -t "refs/tags/$tag").Trim() -ne "tag") {
        throw "Release fork tag must be annotated: $tag"
    }

    $projectTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $lockTemplate.dependencies.aiRules1c
    if ([string]$projectTemplate.aiRules.ref -ne $tag -or [string]$entry.ref -ne $tag -or [string]$entry.commit -ne $commit) {
        throw "Workflow templates do not pin the checked fork tag and commit: $tag@$commit"
    }
    if ([string]$entry.compatibilityStatus -ne "passed" -or -not [string]$entry.upstreamRef -or -not [string]$entry.upstreamCommit) {
        throw "Workflow aiRules lock lacks passed compatibility and upstream provenance."
    }
    return [ordered]@{
        repo = $origin
        tag = $tag
        commit = $commit
        upstreamRef = [string]$entry.upstreamRef
        upstreamCommit = [string]$entry.upstreamCommit
    }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Push-Location $repoRoot
try {
    if ($Mode -eq "Release") {
        if ($Offline) { throw "Release mode cannot run with -Offline." }
        if ([string]::IsNullOrWhiteSpace($E2EProjectRoot)) { throw "Release mode requires -E2EProjectRoot for the dedicated stand." }
        if (@(& git status --porcelain).Count -gt 0) { throw "ITL worktree must be clean for Release." }
        $releaseSource = Resolve-AiRulesSource
        if (-not (Test-Path -LiteralPath $releaseSource -PathType Container)) {
            throw "Release requires -AiRulesSource (or ITL_AI_RULES_SOURCE_PATH) pointing to a local controlled fork checkout."
        }
        $aiRulesRelease = Get-LocalForkRelease -SourceRoot ([System.IO.Path]::GetFullPath($releaseSource))
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
            ".\tests\pester\AiRulesMigration.Tests.ps1",
            ".\tests\pester\ReleaseGate.Tests.ps1",
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

    if ($Mode -in @("Full", "Release")) {
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

    if ($Mode -eq "Release") {
        $e2eReportPath = Join-Path $outputRoot "release-e2e-summary.json"
        $e2eScript = Join-Path $repoRoot "scripts\invoke-release-e2e.ps1"
        $releaseHelperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        Invoke-PowerShellChild -ScriptPath $e2eScript -Arguments @(
            "-ProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot)),
            "-HelperPath", $releaseHelperPath,
            "-OutputPath", $e2eReportPath
        ) -TimeoutSeconds 14400 -LogName "release-e2e"
        Add-StageResult -Name "release-e2e" -Status "passed" -Detail $e2eReportPath
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
        aiRulesRelease = $aiRulesRelease
        e2eReportPath = $e2eReportPath
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
