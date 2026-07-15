[CmdletBinding()]
param(
    [ValidateSet("Fast", "Full", "Release")]
    [string]$Mode = "Full",
    [string]$AiRulesSource = "",
    [switch]$Offline,
    [string]$E2EProjectRoot = "",
    [string]$OutputDirectory = "build\test-results\local",
    [string]$QualificationPath = "build\test-results\qualification\full.json",
    [ValidateSet("Auto", "Restart")]
    [string]$ReleaseResumeMode = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-RepositoryPath {
    param([string]$Path, [string]$Root)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Get-RelativeRepositoryPath {
    param([string]$Path, [string]$Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Replace('\', '/')
    }
    return $fullPath.Substring($fullRoot.Length).TrimStart([char[]]'\/').Replace('\', '/')
}

function New-InventoryEntry {
    param([string]$Path, [string]$Root)
    return [ordered]@{
        path = Get-RelativeRepositoryPath -Path $Path -Root $Root
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Resolve-RepositoryPath -Path $OutputDirectory -Root $repoRoot
$qualificationFullPath = Resolve-RepositoryPath -Path $QualificationPath -Root $repoRoot
$summaryPath = Join-Path $outputRoot "check-summary.json"
$junitPath = Join-Path $outputRoot "pester.xml"
$startedAt = [DateTime]::UtcNow
$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stages = New-Object System.Collections.Generic.List[object]
$pesterResult = $null
$qualifiedResult = $null
$pesterVersion = ""
$failure = $null
$aiRulesRelease = $null
$forkQualificationPath = ""
$forkQualificationSha256 = ""
$e2eReportPath = ""
$reuseQualification = $false

function Add-StageResult {
    param(
        [string]$Name,
        [string]$Status,
        [ValidateSet("executed", "reused", "skipped")][string]$Execution,
        [string]$Reason,
        [string]$Detail,
        [datetime]$StartedAt,
        [int64]$DurationMs
    )
    $script:stages.Add([ordered]@{
        name = $Name
        status = $Status
        execution = $Execution
        reason = $Reason
        detail = $Detail
        startedAt = $StartedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = $DurationMs
    }) | Out-Null
}

function Invoke-GateStage {
    param(
        [string]$Name,
        [string]$Reason,
        [scriptblock]$Body,
        [string]$Detail = ""
    )
    $stageStartedAt = [DateTime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Body
        $stopwatch.Stop()
        Add-StageResult -Name $Name -Status "passed" -Execution "executed" -Reason $Reason -Detail $Detail -StartedAt $stageStartedAt -DurationMs $stopwatch.ElapsedMilliseconds
        return $result
    } catch {
        $stopwatch.Stop()
        Add-StageResult -Name $Name -Status "failed" -Execution "executed" -Reason $Reason -Detail $_.Exception.Message -StartedAt $stageStartedAt -DurationMs $stopwatch.ElapsedMilliseconds
        throw
    }
}

function Add-ReusedStage {
    param([string]$Name, [string]$Reason, [string]$Detail = "")
    Add-StageResult -Name $Name -Status "passed" -Execution "reused" -Reason $Reason -Detail $Detail -StartedAt ([DateTime]::UtcNow) -DurationMs 0
}

function Add-SkippedStage {
    param([string]$Name, [string]$Reason, [string]$Detail = "")
    Add-StageResult -Name $Name -Status "skipped" -Execution "skipped" -Reason $Reason -Detail $Detail -StartedAt ([DateTime]::UtcNow) -DurationMs 0
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
    $argumentParts = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $ScriptPath))
    foreach ($argument in @($Arguments)) { $argumentParts += (ConvertTo-NativeArgument ([string]$argument)) }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($argumentParts -join " ") -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw "$LogName timed out after $TimeoutSeconds seconds. See $stdoutPath and $stderrPath"
    }
    $process.WaitForExit(); $process.Refresh()
    if ([int]$process.ExitCode -ne 0) { throw "$LogName failed with exit code $($process.ExitCode). See $stdoutPath and $stderrPath" }
}

function Resolve-AiRulesSource {
    if (-not [string]::IsNullOrWhiteSpace($AiRulesSource)) { return $AiRulesSource }
    if (-not [string]::IsNullOrWhiteSpace($env:ITL_AI_RULES_SOURCE_PATH)) { return $env:ITL_AI_RULES_SOURCE_PATH }
    return "https://github.com/xmentosx/itl_ai_rules_1c.git"
}

function Get-LocalForkRelease {
    param([string]$SourceRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot ".git"))) { throw "Release requires a local Git checkout of the controlled ai_rules fork." }
    if (@(& git -C $SourceRoot status --porcelain).Count -gt 0) { throw "Controlled fork checkout must be clean for Release." }
    $origin = (& git -C $SourceRoot remote get-url origin).Trim()
    if ($origin.Replace('\', '/').TrimEnd('/').ToLowerInvariant() -notmatch 'github\.com/xmentosx/itl_ai_rules_1c(?:\.git)?$') { throw "Release aiRules source is not the controlled fork: $origin" }
    $commit = (& git -C $SourceRoot rev-parse HEAD).Trim()
    $tree = (& git -C $SourceRoot rev-parse 'HEAD^{tree}').Trim()
    $tags = @(& git -C $SourceRoot tag --points-at HEAD --list "itl-*")
    if ($tags.Count -ne 1) { throw "Release fork HEAD must have exactly one immutable itl-* tag; found $($tags.Count)." }
    $tag = [string]$tags[0]
    if ((& git -C $SourceRoot cat-file -t "refs/tags/$tag").Trim() -ne "tag") { throw "Release fork tag must be annotated: $tag" }
    $projectTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $lockTemplate.dependencies.aiRules1c
    if ([string]$projectTemplate.aiRules.ref -ne $tag -or [string]$entry.ref -ne $tag -or [string]$entry.commit -ne $commit) { throw "Workflow templates do not pin the checked fork tag and commit: $tag@$commit" }
    if ([string]$entry.compatibilityStatus -ne "passed" -or -not [string]$entry.upstreamRef -or -not [string]$entry.upstreamCommit) { throw "Workflow aiRules lock lacks passed compatibility and upstream provenance." }
    return [ordered]@{ repo = $origin; tag = $tag; commit = $commit; tree = $tree; upstreamRef = [string]$entry.upstreamRef; upstreamCommit = [string]$entry.upstreamCommit }
}

function Test-HasExactInventory {
    param([object[]]$Entries, [string[]]$ActualPaths, [string]$Root)
    try {
        $expectedPaths = @($Entries | ForEach-Object { ([string]$_.path).Replace('\', '/') } | Sort-Object)
        if (($expectedPaths -join "`n") -ne (@($ActualPaths | Sort-Object) -join "`n")) { return $false }
        foreach ($entry in @($Entries)) {
            $path = if ([System.IO.Path]::IsPathRooted([string]$entry.path)) { [string]$entry.path } else { Join-Path $Root ([string]$entry.path).Replace('/', '\') }
            if (-not (Test-Path $path -PathType Leaf)) { return $false }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$entry.sha256).ToLowerInvariant()) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-ForkQualification {
    param([string]$SourceRoot, [string]$Path, [object]$Identity)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }
    try {
        $q = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$q.kind -ne "itl-ai-rules-full-qualification" -or [string]$q.status -ne "passed" -or -not [bool]$q.reusable) { return $false }
        if ([string]$q.repository.commit -ne [string]$Identity.commit -or [string]$q.repository.tree -ne [string]$Identity.tree -or -not [bool]$q.repository.worktreeClean) { return $false }
        if ([string]$q.provenance.upstreamRef -ne [string]$Identity.upstreamRef -or [string]$q.provenance.upstreamCommit -ne [string]$Identity.upstreamCommit) { return $false }
        $actualTests = @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot "tests") -Recurse -File -Filter "*.ps1" | ForEach-Object { Get-RelativeRepositoryPath -Path $_.FullName -Root $SourceRoot })
        if (-not (Test-HasExactInventory -Entries @($q.inventory.tests) -ActualPaths $actualTests -Root $SourceRoot)) { return $false }
        $requiredScripts = @("scripts/check.ps1", "scripts/publish-fork-release.ps1")
        if (-not (Test-HasExactInventory -Entries @($q.inventory.scripts) -ActualPaths $requiredScripts -Root $SourceRoot)) { return $false }
        $junit = if ([System.IO.Path]::IsPathRooted([string]$q.junit.path)) { [string]$q.junit.path } else { Join-Path $SourceRoot ([string]$q.junit.path).Replace('/', '\') }
        if (-not (Test-Path $junit -PathType Leaf)) { return $false }
        return ((Get-FileHash -LiteralPath $junit -Algorithm SHA256).Hash.ToLowerInvariant() -eq ([string]$q.junit.sha256).ToLowerInvariant())
    } catch { return $false }
}

function Test-WorkflowQualification {
    param([string]$Path, [string]$Commit, [string]$Tree, [object]$ForkIdentity)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }
    try {
        $q = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$q.kind -ne "itl-workflow-full-qualification" -or [string]$q.status -ne "passed" -or -not [bool]$q.reusable) { return $false }
        if ([string]$q.repository.commit -ne $Commit -or [string]$q.repository.tree -ne $Tree -or -not [bool]$q.repository.worktreeClean) { return $false }
        if ([string]$q.fork.commit -ne [string]$ForkIdentity.commit -or [string]$q.fork.tree -ne [string]$ForkIdentity.tree -or
            [string]$q.fork.tag -ne [string]$ForkIdentity.tag -or [string]$q.fork.upstreamRef -ne [string]$ForkIdentity.upstreamRef -or
            [string]$q.fork.upstreamCommit -ne [string]$ForkIdentity.upstreamCommit) { return $false }
        $forkQualification = [string]$q.fork.qualificationPath
        if (-not (Test-Path -LiteralPath $forkQualification -PathType Leaf) -or (Get-FileHash -LiteralPath $forkQualification -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$q.fork.qualificationSha256).ToLowerInvariant()) { return $false }
        $currentPester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
        $currentPlatform = if ($PSVersionTable.ContainsKey("Platform")) { [string]$PSVersionTable["Platform"] } else { "Win32NT" }
        $currentOs = if ($PSVersionTable.ContainsKey("OS")) { [string]$PSVersionTable["OS"] } else { [string][System.Environment]::OSVersion.VersionString }
        if ([string]$q.environment.powershellVersion -ne [string]$PSVersionTable.PSVersion -or
            [string]$q.environment.powershellEdition -ne [string]$PSVersionTable.PSEdition -or
            [string]$q.environment.pesterVersion -ne [string]$currentPester.Version -or
            [string]$q.environment.platform -ne $currentPlatform -or [string]$q.environment.os -ne $currentOs) { return $false }
        $actualTests = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "tests\pester") -Recurse -File -Filter "*.ps1" | ForEach-Object { Get-RelativeRepositoryPath -Path $_.FullName -Root $repoRoot })
        if (-not (Test-HasExactInventory -Entries @($q.inventory.tests) -ActualPaths $actualTests -Root $repoRoot)) { return $false }
        $requiredScripts = @("scripts/check.ps1", "scripts/invoke-release-e2e.ps1", "scripts/test-ai-rules-compatibility.ps1")
        if (-not (Test-HasExactInventory -Entries @($q.inventory.scripts) -ActualPaths $requiredScripts -Root $repoRoot)) { return $false }
        $junit = if ([System.IO.Path]::IsPathRooted([string]$q.junit.path)) { [string]$q.junit.path } else { Join-Path $repoRoot ([string]$q.junit.path).Replace('/', '\') }
        if (-not (Test-Path $junit -PathType Leaf)) { return $false }
        return ((Get-FileHash -LiteralPath $junit -Algorithm SHA256).Hash.ToLowerInvariant() -eq ([string]$q.junit.sha256).ToLowerInvariant())
    } catch { return $false }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Push-Location $repoRoot
try {
    $commit = (& git rev-parse HEAD).Trim()
    $tree = (& git rev-parse 'HEAD^{tree}').Trim()
    $worktreeCleanAtStart = @(& git status --porcelain).Count -eq 0
    $resolvedAiRulesSource = Resolve-AiRulesSource
    $sourceIsLocal = Test-Path -LiteralPath $resolvedAiRulesSource -PathType Container

    if ($Mode -eq "Release") {
        if ($Offline) { throw "Release mode cannot run with -Offline." }
        if ([string]::IsNullOrWhiteSpace($E2EProjectRoot)) { throw "Release mode requires -E2EProjectRoot for the dedicated stand." }
        if (-not $worktreeCleanAtStart) { throw "ITL worktree must be clean for Release." }
        if (-not $sourceIsLocal) { throw "Release requires -AiRulesSource (or ITL_AI_RULES_SOURCE_PATH) pointing to a local controlled fork checkout." }
    }
    if ($sourceIsLocal) {
        try { $aiRulesRelease = Get-LocalForkRelease -SourceRoot ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) } catch { if ($Mode -eq "Release") { throw } }
    }

    $trackedBefore = @(& git status --porcelain --untracked-files=no)
    Invoke-GateStage -Name "git-diff-check" -Reason "always-run preflight" -Body {
        & git diff --check HEAD -- .
        if ($LASTEXITCODE -ne 0) { throw "git diff --check failed." }
    } | Out-Null

    $reuseQualification = $false
    if ($Mode -in @("Full", "Release") -and $aiRulesRelease) {
        $reuseQualification = Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease
        if ($reuseQualification) {
            $existingQualification = Get-Content -LiteralPath $qualificationFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $qualifiedResult = $existingQualification.result
        }
    }

    if ($reuseQualification) {
        Add-ReusedStage -Name "pester" -Reason "exact clean Full qualification" -Detail $qualificationFullPath
    } else {
        Invoke-GateStage -Name "pester" -Reason $(if ($Mode -eq "Fast") { "Fast inventory" } else { "complete workflow inventory" }) -Body {
            Import-Module Pester -MinimumVersion 5.0.0 -Force
            $script:pesterVersion = [string](Get-Module Pester | Select-Object -First 1 -ExpandProperty Version)
            $configuration = New-PesterConfiguration
            $configuration.Run.Path = if ($Mode -eq "Fast") {
                @(".\tests\pester\ParserDocsBudgets.Tests.ps1", ".\tests\pester\LifecycleOperationLock.Tests.ps1", ".\tests\pester\DesignerMemoryGuard.Tests.ps1", ".\tests\pester\HostTooling.Tests.ps1", ".\tests\pester\DependencyLocks.Tests.ps1", ".\tests\pester\AiRulesClients.Tests.ps1", ".\tests\pester\AiRulesMigration.Tests.ps1", ".\tests\pester\ReleaseGate.Tests.ps1", ".\tests\pester\LocalQualityGate.Tests.ps1")
            } else { @(".\tests\pester") }
            $configuration.Run.PassThru = $true
            $configuration.Output.Verbosity = $(if ($Mode -eq "Fast") { "Normal" } else { "Detailed" })
            $configuration.TestResult.Enabled = $true
            $configuration.TestResult.OutputFormat = "JUnitXml"
            $configuration.TestResult.OutputPath = $junitPath
            $script:pesterResult = Invoke-Pester -Configuration $configuration
            if ([string]$script:pesterResult.Result -ne "Passed") { throw "Pester did not pass: result=$($script:pesterResult.Result), failed=$($script:pesterResult.FailedCount)." }
        } | Out-Null
    }

    if ($Mode -in @("Full", "Release")) {
        $helperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        Invoke-GateStage -Name "helper-help" -Reason "always-run helper parse preflight" -Body {
            Invoke-PowerShellChild -ScriptPath $helperPath -Arguments @("-Action", "help") -TimeoutSeconds 60 -LogName "helper-help"
        } | Out-Null

        if ($Offline -and -not $sourceIsLocal) {
            Add-SkippedStage -Name "fork-check" -Reason "Offline mode and no local fork"
            Add-SkippedStage -Name "ai-rules-compatibility" -Reason "Offline mode and no local aiRules source"
        } elseif ($reuseQualification) {
            Add-ReusedStage -Name "fork-check" -Reason "exact workflow Full qualification" -Detail ([string]$aiRulesRelease.commit)
            Add-ReusedStage -Name "ai-rules-compatibility" -Reason "exact workflow Full qualification" -Detail $qualificationFullPath
        } else {
            if ($sourceIsLocal) {
                if (-not $aiRulesRelease) { $aiRulesRelease = Get-LocalForkRelease -SourceRoot ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) }
                $forkQualificationPath = Join-Path ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) "build\test-results\qualification\full.json"
                if (Test-ForkQualification -SourceRoot ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) -Path $forkQualificationPath -Identity $aiRulesRelease) {
                    Add-ReusedStage -Name "fork-check" -Reason "exact clean fork Full qualification" -Detail $forkQualificationPath
                } else {
                    $forkGate = Join-Path ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) "scripts\check.ps1"
                    Invoke-GateStage -Name "fork-check" -Reason "missing, corrupt, or stale fork qualification" -Detail $resolvedAiRulesSource -Body {
                        Invoke-PowerShellChild -ScriptPath $forkGate -Arguments @("-Mode", "Full", "-QualificationPath", $forkQualificationPath) -TimeoutSeconds 600 -LogName "fork-check"
                    } | Out-Null
                    if (-not (Test-ForkQualification -SourceRoot ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) -Path $forkQualificationPath -Identity $aiRulesRelease)) { throw "Fork Full did not produce an exact reusable qualification." }
                }
                $forkQualificationSha256 = (Get-FileHash -LiteralPath $forkQualificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            } else {
                Add-SkippedStage -Name "fork-check" -Reason "remote aiRules source has no reusable local qualification"
            }
            $compatibilityPath = Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1"
            Invoke-GateStage -Name "ai-rules-compatibility" -Reason "workflow-to-fork integration boundary" -Detail $resolvedAiRulesSource -Body {
                Invoke-PowerShellChild -ScriptPath $compatibilityPath -Arguments @("-AiRulesSource", $resolvedAiRulesSource) -TimeoutSeconds 600 -LogName "ai-rules-compatibility"
            } | Out-Null
        }
    }

    if ($Mode -eq "Release") {
        $e2eReportPath = Join-Path $outputRoot "release-e2e-summary.json"
        $e2eScript = Join-Path $repoRoot "scripts\invoke-release-e2e.ps1"
        $releaseHelperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        Invoke-GateStage -Name "release-e2e" -Reason "always-run release runtime proof" -Detail $e2eReportPath -Body {
            Invoke-PowerShellChild -ScriptPath $e2eScript -Arguments @("-ProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot)), "-AiRulesSource", $resolvedAiRulesSource, "-HelperPath", $releaseHelperPath, "-OutputPath", $e2eReportPath, "-ResumeMode", $ReleaseResumeMode) -TimeoutSeconds 14400 -LogName "release-e2e"
            if (-not (Test-Path -LiteralPath $e2eReportPath -PathType Leaf)) { throw "Release E2E summary was not created: $e2eReportPath" }
            $e2eSummary = Get-Content -LiteralPath $e2eReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$e2eSummary.status -ne "passed") { throw "Release E2E summary reports '$($e2eSummary.status)': $([string]$e2eSummary.error)" }
        } | Out-Null
    }

    Invoke-GateStage -Name "tracked-state" -Reason "tests must preserve tracked state" -Body {
        & git diff --check HEAD -- .
        if ($LASTEXITCODE -ne 0) { throw "git diff --check failed after tests." }
        $trackedAfter = @(& git status --porcelain --untracked-files=no)
        if (($trackedBefore -join "`n") -ne ($trackedAfter -join "`n")) { throw "The local gate changed tracked worktree state." }
    } | Out-Null
} catch {
    $failure = $_.Exception.Message
} finally {
    $overallStopwatch.Stop()
    $commit = [string](& git rev-parse HEAD 2>$null)
    $tree = [string](& git rev-parse 'HEAD^{tree}' 2>$null)
    $dirty = @(& git status --porcelain).Count -gt 0
    $result = if ($pesterResult) {
        [ordered]@{ passed = [int]$pesterResult.PassedCount; failed = [int]$pesterResult.FailedCount; skipped = [int]$pesterResult.SkippedCount }
    } elseif ($qualifiedResult) {
        [ordered]@{ passed = [int]$qualifiedResult.passed; failed = [int]$qualifiedResult.failed; skipped = [int]$qualifiedResult.skipped }
    } else { [ordered]@{ passed = 0; failed = 0; skipped = 0 } }
    $summary = [ordered]@{
        schemaVersion = 2
        repository = "1c-agent-workflow"
        mode = $Mode
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$overallStopwatch.ElapsedMilliseconds
        commit = $commit
        tree = $tree
        worktreeClean = (-not $dirty)
        offline = [bool]$Offline
        aiRulesRelease = $aiRulesRelease
        qualificationPath = $qualificationFullPath
        e2eReportPath = $e2eReportPath
        tests = $result
        stages = @($stages | ForEach-Object { $_ })
        error = $failure
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 12), $utf8NoBom)

    if ($Mode -eq "Full" -and -not $reuseQualification) {
        $qualificationRoot = Split-Path -Parent $qualificationFullPath
        $qualificationJunitPath = Join-Path $qualificationRoot "pester.xml"
        New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
        if (Test-Path -LiteralPath $junitPath -PathType Leaf) {
            Copy-Item -LiteralPath $junitPath -Destination $qualificationJunitPath -Force
        }
        $testInventory = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "tests\pester") -Recurse -File -Filter "*.ps1" | Sort-Object FullName | ForEach-Object { New-InventoryEntry -Path $_.FullName -Root $repoRoot })
        $scriptInventory = @(
            New-InventoryEntry -Path $PSCommandPath -Root $repoRoot
            New-InventoryEntry -Path (Join-Path $repoRoot "scripts\invoke-release-e2e.ps1") -Root $repoRoot
            New-InventoryEntry -Path (Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1") -Root $repoRoot
        )
        $qualification = [ordered]@{
            schemaVersion = 1
            kind = "itl-workflow-full-qualification"
            status = $(if ($failure) { "failed" } else { "passed" })
            reusable = (-not $failure -and -not $dirty -and $null -ne $aiRulesRelease -and $forkQualificationSha256)
            repository = [ordered]@{ name = "1c-agent-workflow"; commit = $commit; tree = $tree; worktreeClean = (-not $dirty) }
            fork = [ordered]@{
                repo = $(if ($aiRulesRelease) { [string]$aiRulesRelease.repo } else { "" })
                tag = $(if ($aiRulesRelease) { [string]$aiRulesRelease.tag } else { "" })
                commit = $(if ($aiRulesRelease) { [string]$aiRulesRelease.commit } else { "" })
                tree = $(if ($aiRulesRelease) { [string]$aiRulesRelease.tree } else { "" })
                upstreamRef = $(if ($aiRulesRelease) { [string]$aiRulesRelease.upstreamRef } else { "" })
                upstreamCommit = $(if ($aiRulesRelease) { [string]$aiRulesRelease.upstreamCommit } else { "" })
                qualificationPath = $forkQualificationPath
                qualificationSha256 = $forkQualificationSha256
            }
            environment = [ordered]@{
                powershellVersion = [string]$PSVersionTable.PSVersion
                powershellEdition = [string]$PSVersionTable.PSEdition
                pesterVersion = $pesterVersion
                platform = $(if ($PSVersionTable.ContainsKey("Platform")) { [string]$PSVersionTable["Platform"] } else { "Win32NT" })
                os = $(if ($PSVersionTable.ContainsKey("OS")) { [string]$PSVersionTable["OS"] } else { [string][System.Environment]::OSVersion.VersionString })
            }
            inventory = [ordered]@{ tests = $testInventory; scripts = $scriptInventory }
            junit = [ordered]@{
                path = Get-RelativeRepositoryPath -Path $qualificationJunitPath -Root $repoRoot
                sha256 = $(if (Test-Path $qualificationJunitPath -PathType Leaf) { (Get-FileHash -LiteralPath $qualificationJunitPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" })
            }
            result = $result
            stages = @($stages | ForEach-Object { $_ })
            startedAt = $startedAt.ToString("o")
            finishedAt = [DateTime]::UtcNow.ToString("o")
            durationMs = [int64]$overallStopwatch.ElapsedMilliseconds
            error = $failure
        }
        [System.IO.File]::WriteAllText($qualificationFullPath, ($qualification | ConvertTo-Json -Depth 14), $utf8NoBom)
    }
    Pop-Location
}

if ($failure) { [Console]::Error.WriteLine($failure); exit 1 }
Write-Host "ITL $Mode gate passed. Summary: $summaryPath"
if ($Mode -eq "Full") { Write-Host "Qualification: $qualificationFullPath" }
