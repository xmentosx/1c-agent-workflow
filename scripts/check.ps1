[CmdletBinding()]
param(
    [ValidateSet("Targeted", "Smoke", "Fast", "Full", "Develop", "Release")]
    [string]$Mode = "Smoke",
    [string]$BaseRef = "",
    [string[]]$ChangedPath = @(),
    [string[]]$CoverageContract = @(),
    [string]$AiRulesSource = "",
    [switch]$Offline,
    [string]$E2EProjectRoot = "",
    [string]$OutputDirectory = "build\test-results\local",
    [string]$QualificationPath = "build\test-results\qualification\full.json",
    [string]$DevelopQualificationPath = "build\test-results\qualification\develop.json",
    [ValidateRange(1, 4)]
    [int]$PesterWorkers = 3,
    [ValidateSet("Auto", "Restart")]
    [string]$ReleaseResumeMode = "Auto"
)

$script:ExplicitAiRulesSource = $PSBoundParameters.ContainsKey("AiRulesSource") -and -not [string]::IsNullOrWhiteSpace($AiRulesSource)
$effectiveMode = $(if ($Mode -eq "Fast") { "Smoke" } else { $Mode })
if ($Mode -eq "Fast") { Write-Warning "Mode Fast is deprecated and now aliases Smoke. Use Targeted for a change or Smoke for a short source sanity check." }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$CoverageContract = @($CoverageContract | ForEach-Object { @(([string]$_) -split ',') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

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
        sha256 = Get-CanonicalTextSha256 -Path $Path
    }
}

function Get-CanonicalTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text.Replace("`r`n", "`n").Replace("`r", "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "release-qualification.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")
. (Join-Path $PSScriptRoot "develop-static-qualification.ps1")
. (Join-Path $PSScriptRoot "develop-e2e-qualification.ps1")
$qualityCatalog = Get-QualityContractCatalog -RepositoryRoot $repoRoot
$budgetPrefix = $effectiveMode.Substring(0, 1).ToLowerInvariant() + $effectiveMode.Substring(1)
$modeTargetBudgetSeconds = [int]$qualityCatalog.budgets.("${budgetPrefix}TargetSeconds")
$modeHardBudgetSeconds = [int]$qualityCatalog.budgets.("${budgetPrefix}HardSeconds")
if ($modeTargetBudgetSeconds -le 0 -or $modeHardBudgetSeconds -lt $modeTargetBudgetSeconds) { throw "Invalid $effectiveMode target/hard budget in the quality contract catalog." }
$outputRoot = Resolve-RepositoryPath -Path $OutputDirectory -Root $repoRoot
$qualificationFullPath = Resolve-RepositoryPath -Path $QualificationPath -Root $repoRoot
$developQualificationFullPath = Resolve-RepositoryPath -Path $DevelopQualificationPath -Root $repoRoot
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
$forkSourceRoot = ""
$forkQualificationPath = ""
$forkQualificationSha256 = ""
$e2eReportPath = ""
$developE2EReportPath = ""
$reuseQualification = $false
$qualificationReuseKind = ""
$existingQualification = $null
$parallelCompatibility = $null
$releaseContextPath = ""
$releaseContext = $null
$releaseDevelopProof = $null
$releaseFullProof = $null
$continuationProof = $null

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

function Start-PowerShellChildProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$LogName = "child"
    )
    $stdoutPath = Join-Path $outputRoot ($LogName + ".stdout.log")
    $stderrPath = Join-Path $outputRoot ($LogName + ".stderr.log")
    $argumentParts = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-NativeArgument $ScriptPath))
    foreach ($argument in @($Arguments)) { $argumentParts += (ConvertTo-NativeArgument ([string]$argument)) }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($argumentParts -join " ") -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $null = $process.Handle
    return [pscustomobject]@{ process = $process; stdoutPath = $stdoutPath; stderrPath = $stderrPath; logName = $LogName; startedAt = [DateTime]::UtcNow }
}

function Stop-GateChildProcessTree {
    param([object]$Process)
    if (-not $Process -or $Process.HasExited) { return }
    $processId = [int]$Process.Id
    if ($env:OS -eq "Windows_NT") { & taskkill.exe /PID $processId /T /F *> $null } else { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    try { $Process.WaitForExit() } catch {}
}

function Wait-PowerShellChildProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Child,
        [int]$TimeoutSeconds = 300,
        [int]$NoProgressSeconds = 600,
        [string[]]$ProgressPaths = @()
    )
    $process = $Child.process
    $started = [DateTime]::UtcNow
    $lastProgress = $started
    $lastHeartbeat = $started
    $remainingOverallSeconds = [Math]::Max(1, $modeHardBudgetSeconds - [int][Math]::Ceiling($overallStopwatch.Elapsed.TotalSeconds))
    $effectiveTimeoutSeconds = [Math]::Min($TimeoutSeconds, $remainingOverallSeconds)
    $lastLength = -1L
    $lastWriteTicks = -1L
    while (-not $process.WaitForExit(5000)) {
        $now = [DateTime]::UtcNow
        $length = 0L
        $latestWriteTicks = 0L
        foreach ($path in @($Child.stdoutPath, $Child.stderrPath) + @($ProgressPaths)) {
            if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
                $item = Get-Item -LiteralPath $path
                $length += $item.Length
                $latestWriteTicks = [Math]::Max($latestWriteTicks, $item.LastWriteTimeUtc.Ticks)
            }
            elseif (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) {
                foreach ($item in @(Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue)) {
                    $length += $item.Length
                    $latestWriteTicks = [Math]::Max($latestWriteTicks, $item.LastWriteTimeUtc.Ticks)
                }
            }
        }
        if ($length -ne $lastLength -or $latestWriteTicks -ne $lastWriteTicks) {
            $lastLength = $length
            $lastWriteTicks = $latestWriteTicks
            $lastProgress = $now
        }
        $elapsedSeconds = [int]($now - $started).TotalSeconds
        $idleSeconds = [int]($now - $lastProgress).TotalSeconds
        if ($elapsedSeconds -ge $effectiveTimeoutSeconds -or ($NoProgressSeconds -gt 0 -and $idleSeconds -ge $NoProgressSeconds)) {
            Stop-GateChildProcessTree -Process $process
            $reason = if ($elapsedSeconds -ge $effectiveTimeoutSeconds) { "remaining mode budget $effectiveTimeoutSeconds seconds" } else { "no progress for $NoProgressSeconds seconds" }
            throw "$($Child.logName) stopped after $reason. See $($Child.stdoutPath) and $($Child.stderrPath)"
        }
        if (($now - $lastHeartbeat).TotalSeconds -ge 30) {
            Write-Host "ITL gate stage '$($Child.logName)': elapsed=${elapsedSeconds}s; noProgress=${idleSeconds}s; hardRemaining=$($effectiveTimeoutSeconds - $elapsedSeconds)s."
            $lastHeartbeat = $now
        }
    }
    $process.WaitForExit(); $process.Refresh()
    if ([int]$process.ExitCode -ne 0) { throw "$($Child.logName) failed with exit code $($process.ExitCode). See $($Child.stdoutPath) and $($Child.stderrPath)" }
}

function Invoke-PowerShellChild {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 300,
        [int]$NoProgressSeconds = 600,
        [string[]]$ProgressPaths = @(),
        [string]$LogName = "child"
    )
    $child = Start-PowerShellChildProcess -ScriptPath $ScriptPath -Arguments $Arguments -LogName $LogName
    Wait-PowerShellChildProcess -Child $child -TimeoutSeconds $TimeoutSeconds -NoProgressSeconds $NoProgressSeconds -ProgressPaths $ProgressPaths
}

function Complete-ParallelGateStage {
    param([string]$Name, [string]$Reason, [string]$Detail, [object]$Child, [int]$TimeoutSeconds)
    try {
        Wait-PowerShellChildProcess -Child $Child -TimeoutSeconds $TimeoutSeconds
        Add-StageResult -Name $Name -Status "passed" -Execution "executed" -Reason $Reason -Detail $Detail -StartedAt $Child.startedAt -DurationMs ([int64]([DateTime]::UtcNow - $Child.startedAt).TotalMilliseconds)
    } catch {
        Add-StageResult -Name $Name -Status "failed" -Execution "executed" -Reason $Reason -Detail $_.Exception.Message -StartedAt $Child.startedAt -DurationMs ([int64]([DateTime]::UtcNow - $Child.startedAt).TotalMilliseconds)
        throw
    }
}

function Resolve-AiRulesSource {
    if (-not [string]::IsNullOrWhiteSpace($AiRulesSource)) { return $AiRulesSource }
    if (-not [string]::IsNullOrWhiteSpace($env:ITL_AI_RULES_SOURCE_PATH)) { return $env:ITL_AI_RULES_SOURCE_PATH }
    return "https://github.com/xmentosx/itl_ai_rules_1c.git"
}

function Get-LocalForkRelease {
    param([string]$SourceRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot ".git"))) { throw "Release requires a local Git checkout of the controlled ai_rules fork." }
    if (@(& git -C $SourceRoot status --porcelain).Count -gt 0) { throw "Controlled fork checkout must be clean for qualification." }
    $origin = (& git -C $SourceRoot remote get-url origin).Trim()
    if ($origin.Replace('\', '/').TrimEnd('/').ToLowerInvariant() -notmatch 'github\.com/xmentosx/itl_ai_rules_1c(?:\.git)?$') { throw "Release aiRules source is not the controlled fork: $origin" }
    $projectTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $lockTemplate.dependencies.aiRules1c
    $tag = [string]$entry.ref
    $commit = [string]$entry.commit
    if ([string]::IsNullOrWhiteSpace($tag) -or $commit -notmatch '^[0-9a-fA-F]{40}$' -or [string]$projectTemplate.aiRules.ref -ne $tag) { throw "Workflow templates do not define one valid pinned fork tag and commit." }
    if ((& git -C $SourceRoot cat-file -t "refs/tags/$tag" 2>$null).Trim() -ne "tag") { throw "Pinned fork tag must exist locally and be annotated: $tag" }
    $tagCommit = (& git -C $SourceRoot rev-parse "refs/tags/$tag^{}" 2>$null).Trim().ToLowerInvariant()
    if ($tagCommit -ne $commit.ToLowerInvariant()) { throw "Pinned fork tag does not resolve to the locked commit: $tag -> $tagCommit, lock=$commit" }
    $releaseBranch = "release/$tag"
    $branchCommit = [string](& git -C $SourceRoot rev-parse --verify "refs/heads/$releaseBranch" 2>$null)
    if (-not $branchCommit) { $branchCommit = [string](& git -C $SourceRoot rev-parse --verify "refs/remotes/origin/$releaseBranch" 2>$null) }
    if (-not $branchCommit -or $branchCommit.Trim().ToLowerInvariant() -ne $commit.ToLowerInvariant()) { throw "Pinned release branch '$releaseBranch' is missing or does not match $commit." }
    $tree = (& git -C $SourceRoot rev-parse "$commit^{tree}").Trim()
    $releaseRoot = ""
    $candidateRoot = ""
    foreach ($line in @(& git -C $SourceRoot worktree list --porcelain)) {
        if ($line -like "worktree *") { $candidateRoot = $line.Substring(9) }
        elseif ($line -like "HEAD *" -and $line.Substring(5).Trim().ToLowerInvariant() -eq $commit.ToLowerInvariant()) { $releaseRoot = $candidateRoot; break }
        elseif ([string]::IsNullOrWhiteSpace($line)) { $candidateRoot = "" }
    }
    if (-not $releaseRoot) { throw "No local clean worktree is checked out at pinned release $tag@$commit. Create one from the immutable tag before Full/Release qualification." }
    $releaseRoot = [System.IO.Path]::GetFullPath($releaseRoot)
    if (@(& git -C $releaseRoot status --porcelain).Count -gt 0) { throw "Pinned fork release worktree must be clean: $releaseRoot" }
    $compatibilityStatus = [string]$entry.compatibilityStatus
    $upstreamRef = [string]$entry.upstreamRef
    $upstreamCommit = [string]$entry.upstreamCommit
    $allowPendingQualification = $effectiveMode -in @("Full", "Develop") -and $script:ExplicitAiRulesSource -and $compatibilityStatus -eq "pending"
    if (($compatibilityStatus -ne "passed" -and -not $allowPendingQualification) -or -not $upstreamRef -or $upstreamCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Workflow aiRules lock lacks eligible compatibility and upstream provenance. Full may qualify pending only with an explicit local -AiRulesSource; Release and implicit sources require passed."
    }
    $upstreamObjectType = (& git -C $releaseRoot cat-file -t $upstreamCommit 2>$null).Trim()
    $upstreamMergeBase = (& git -C $releaseRoot merge-base $upstreamCommit $commit 2>$null).Trim().ToLowerInvariant()
    if ($upstreamObjectType -ne "commit" -or $upstreamMergeBase -ne $upstreamCommit.ToLowerInvariant()) {
        throw "Pinned fork provenance mismatch: upstream $upstreamCommit is not an ancestor of $commit."
    }
    return [ordered]@{ repo = $origin; tag = $tag; commit = $commit.ToLowerInvariant(); tree = $tree; sourceRoot = $releaseRoot; upstreamRef = $upstreamRef; upstreamCommit = $upstreamCommit; compatibilityStatus = $compatibilityStatus }
}

function Test-HasExactInventory {
    param([object[]]$Entries, [string[]]$ActualPaths, [string]$Root)
    try {
        $expectedPaths = @($Entries | ForEach-Object { ([string]$_.path).Replace('\', '/') } | Sort-Object)
        if (($expectedPaths -join "`n") -ne (@($ActualPaths | Sort-Object) -join "`n")) { return $false }
        foreach ($entry in @($Entries)) {
            $path = if ([System.IO.Path]::IsPathRooted([string]$entry.path)) { [string]$entry.path } else { Join-Path $Root ([string]$entry.path).Replace('/', '\') }
            if (-not (Test-Path $path -PathType Leaf)) { return $false }
            $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
            $canonicalHash = Get-CanonicalTextSha256 -Path $path
            $byteHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            # Workflow qualifications use canonical text hashes; controlled-fork schema 1 uses exact byte hashes.
            if ($canonicalHash -ne $expectedHash -and $byteHash -ne $expectedHash) { return $false }
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

function Get-WorkflowGateScriptPaths {
    $paths = @(
        (Join-Path $repoRoot "scripts\check.ps1"),
        (Join-Path $repoRoot "scripts\git-path-list.ps1"),
        (Join-Path $repoRoot "scripts\quality-contracts.ps1"),
        (Join-Path $repoRoot "scripts\resolve-targeted-tests.ps1"),
        (Join-Path $repoRoot "scripts\source-delivery.ps1"),
        (Join-Path $repoRoot "scripts\develop-static-qualification.ps1"),
        (Join-Path $repoRoot "scripts\develop-e2e-qualification.ps1"),
        (Join-Path $repoRoot "scripts\invoke-develop-e2e.ps1"),
        (Join-Path $repoRoot "scripts\test-release-readiness.ps1"),
        (Join-Path $repoRoot "scripts\invoke-release-e2e.ps1"),
        (Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1"),
        (Join-Path $repoRoot "scripts\invoke-pester-shards.ps1"),
        (Join-Path $repoRoot "scripts\run-pester-shard.ps1"),
        (Join-Path $repoRoot "scripts\pester-timings.json"),
        (Join-Path $repoRoot "scripts\release-qualification.ps1"),
        (Join-Path $repoRoot "scripts\promote-ai-rules-compatibility.ps1")
    )
    $stageRoot = Join-Path $repoRoot "scripts\release-e2e"
    if (Test-Path -LiteralPath $stageRoot -PathType Container) {
        $paths += @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object { $_.FullName })
    }
    return @($paths | Sort-Object -Unique)
}

function Test-WorkflowQualification {
    param([string]$Path, [string]$Commit, [string]$Tree, [object]$ForkIdentity, [switch]$AllowIndependentExactTree)
    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    try {
        $q = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$q.schemaVersion -notin @(1, 2, 3) -or [string]$q.kind -ne "itl-workflow-full-qualification" -or [string]$q.status -ne "passed" -or -not [bool]$q.reusable) { return $null }
        if (-not [bool]$q.repository.worktreeClean) { return $null }
        if ([int]$q.schemaVersion -eq 3 -and -not (Test-RecordedWorkflowContinuation -Record $q.continuation -Commit ([string]$q.repository.commit) -Tree ([string]$q.repository.tree))) { return $null }
        $evidenceCommit = if ([int]$q.schemaVersion -ge 2 -and [string]$q.repository.evidenceCommit) { [string]$q.repository.evidenceCommit } else { [string]$q.repository.commit }
        $continuation = $null
        $reuseArguments = @{
            RepositoryRoot = $repoRoot
            SchemaVersion = [int]$q.schemaVersion
            QualifiedCommit = [string]$q.repository.commit
            EvidenceCommit = $evidenceCommit
            QualifiedTree = [string]$q.repository.tree
            CurrentCommit = $Commit
            CurrentTree = $Tree
        }
        $reuseKind = if ($AllowIndependentExactTree) {
            Get-CachedWorkflowQualificationReuseKind @reuseArguments
        } else {
            Get-WorkflowQualificationReuseKind @reuseArguments
        }
        if (-not $reuseKind) {
            $continuation = Get-WorkflowContinuationProof -RepositoryRoot $repoRoot -QualifiedCommit ([string]$q.repository.commit) -CurrentCommit $Commit -CurrentTree $Tree
            if (-not $continuation) { return $null }
            $reuseKind = "targeted-continuation"
        }
        if ([string]$q.fork.commit -ne [string]$ForkIdentity.commit -or [string]$q.fork.tree -ne [string]$ForkIdentity.tree -or
            [string]$q.fork.tag -ne [string]$ForkIdentity.tag -or [string]$q.fork.upstreamRef -ne [string]$ForkIdentity.upstreamRef -or
            [string]$q.fork.upstreamCommit -ne [string]$ForkIdentity.upstreamCommit) { return $null }
        $forkQualification = [string]$q.fork.qualificationPath
        if (-not (Test-Path -LiteralPath $forkQualification -PathType Leaf) -or (Get-FileHash -LiteralPath $forkQualification -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$q.fork.qualificationSha256).ToLowerInvariant()) { return $null }
        $currentPester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
        $currentPlatform = if ($PSVersionTable.ContainsKey("Platform")) { [string]$PSVersionTable["Platform"] } else { "Win32NT" }
        $currentOs = if ($PSVersionTable.ContainsKey("OS")) { [string]$PSVersionTable["OS"] } else { [string][System.Environment]::OSVersion.VersionString }
        if ([string]$q.environment.powershellVersion -ne [string]$PSVersionTable.PSVersion -or
            [string]$q.environment.powershellEdition -ne [string]$PSVersionTable.PSEdition -or
            [string]$q.environment.pesterVersion -ne [string]$currentPester.Version -or
            [string]$q.environment.platform -ne $currentPlatform -or [string]$q.environment.os -ne $currentOs) { return $null }
        if (-not $continuation) {
            $actualTests = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "tests\pester") -Recurse -File -Filter "*.ps1" | ForEach-Object { Get-RelativeRepositoryPath -Path $_.FullName -Root $repoRoot })
            if (-not (Test-HasExactInventory -Entries @($q.inventory.tests) -ActualPaths $actualTests -Root $repoRoot)) { return $null }
            $requiredScripts = @(Get-WorkflowGateScriptPaths | ForEach-Object { Get-RelativeRepositoryPath -Path $_ -Root $repoRoot })
            if (-not (Test-HasExactInventory -Entries @($q.inventory.scripts) -ActualPaths $requiredScripts -Root $repoRoot)) { return $null }
        }
        $junit = if ([System.IO.Path]::IsPathRooted([string]$q.junit.path)) { [string]$q.junit.path } else { Join-Path $repoRoot ([string]$q.junit.path).Replace('/', '\') }
        if (-not (Test-Path $junit -PathType Leaf)) { return $null }
        if ((Get-FileHash -LiteralPath $junit -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$q.junit.sha256).ToLowerInvariant()) { return $null }
        return [pscustomobject]@{ qualification = $q; reuseKind = $reuseKind; evidenceCommit = $evidenceCommit; continuation = $continuation }
    } catch { return $null }
}

function Write-WorkflowQualification {
    param(
        [string]$Commit,
        [string]$Tree,
        [object]$Result,
        [string]$EvidenceCommit,
        [string]$ReuseKind,
        [object]$SourceQualification = $null,
        [object]$ContinuationProof = $null
    )
    $qualificationRoot = Split-Path -Parent $qualificationFullPath
    $qualificationJunitPath = Join-Path $qualificationRoot "pester.xml"
    New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
    if (-not $SourceQualification -and (Test-Path -LiteralPath $junitPath -PathType Leaf)) {
        Copy-Item -LiteralPath $junitPath -Destination $qualificationJunitPath -Force
    }
    if (-not (Test-Path -LiteralPath $qualificationJunitPath -PathType Leaf)) { throw "Reusable workflow qualification has no canonical JUnit evidence." }
    $testInventory = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "tests\pester") -Recurse -File -Filter "*.ps1" | Sort-Object FullName | ForEach-Object { New-InventoryEntry -Path $_.FullName -Root $repoRoot })
    $scriptInventory = @(Get-WorkflowGateScriptPaths | ForEach-Object { New-InventoryEntry -Path $_ -Root $repoRoot })
    $forkRecord = if ($SourceQualification) { $SourceQualification.fork } else {
        [ordered]@{
            repo = [string]$aiRulesRelease.repo; tag = [string]$aiRulesRelease.tag; commit = [string]$aiRulesRelease.commit; tree = [string]$aiRulesRelease.tree
            upstreamRef = [string]$aiRulesRelease.upstreamRef; upstreamCommit = [string]$aiRulesRelease.upstreamCommit
            qualificationPath = $forkQualificationPath; qualificationSha256 = $forkQualificationSha256
        }
    }
    $qualification = [ordered]@{
        schemaVersion = $(if ($ContinuationProof) { 3 } else { 2 })
        kind = "itl-workflow-full-qualification"
        status = "passed"
        reusable = $true
        repository = [ordered]@{ name = "1c-agent-workflow"; commit = $Commit; tree = $Tree; worktreeClean = $true; evidenceCommit = $EvidenceCommit; reuseKind = $ReuseKind }
        fork = $forkRecord
        environment = [ordered]@{
            powershellVersion = [string]$PSVersionTable.PSVersion; powershellEdition = [string]$PSVersionTable.PSEdition
            pesterVersion = $(if ($SourceQualification) { [string]$SourceQualification.environment.pesterVersion } else { $pesterVersion })
            platform = $(if ($PSVersionTable.ContainsKey("Platform")) { [string]$PSVersionTable["Platform"] } else { "Win32NT" })
            os = $(if ($PSVersionTable.ContainsKey("OS")) { [string]$PSVersionTable["OS"] } else { [string][System.Environment]::OSVersion.VersionString })
        }
        inventory = [ordered]@{ tests = $testInventory; scripts = $scriptInventory }
        junit = [ordered]@{ path = Get-RelativeRepositoryPath -Path $qualificationJunitPath -Root $repoRoot; sha256 = (Get-FileHash -LiteralPath $qualificationJunitPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        result = $Result
        stages = @($stages | ForEach-Object { $_ })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$overallStopwatch.ElapsedMilliseconds
        error = $null
    }
    if ($ContinuationProof) {
        $qualification["continuation"] = [ordered]@{
            qualifiedCommit = [string]$ContinuationProof.qualifiedCommit
            paths = @($ContinuationProof.paths)
            scopes = @($ContinuationProof.scopes)
            targetedRunPath = [string]$ContinuationProof.targetedRunPath
            targetedRunSha256 = [string]$ContinuationProof.targetedRunSha256
            targetedFinishedAt = [string]$ContinuationProof.targetedFinishedAt
        }
    }
    [System.IO.File]::WriteAllText($qualificationFullPath, (($qualification | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $qualification
}

function Test-DevelopQualification {
    param([string]$Commit, [string]$Tree, [object]$FullProof = $null, [string]$ExpectedIdentitySha256 = "", [string]$ExpectedStandStateSha256 = "")
    if (-not (Test-Path -LiteralPath $developQualificationFullPath -PathType Leaf) -or -not (Test-Path -LiteralPath $qualificationFullPath -PathType Leaf)) { return $null }
    try {
        $qualification = Get-Content -LiteralPath $developQualificationFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$qualification.schemaVersion -notin @(1, 2, 3) -or [string]$qualification.kind -ne "itl-workflow-develop-qualification" -or [string]$qualification.status -ne "passed") { return $null }
        if ([int]$qualification.schemaVersion -ge 2 -and $qualification.PSObject.Properties["continuation"] -and -not (Test-RecordedWorkflowContinuation -Record $qualification.continuation -Commit ([string]$qualification.repository.commit) -Tree ([string]$qualification.repository.tree))) { return $null }
        $reuseKind = Get-WorkflowQualificationReuseKind -RepositoryRoot $repoRoot -SchemaVersion 2 -QualifiedCommit ([string]$qualification.repository.commit) -EvidenceCommit ([string]$qualification.repository.evidenceCommit) -QualifiedTree ([string]$qualification.repository.tree) -CurrentCommit $Commit -CurrentTree $Tree
        $continuation = $null
        if (-not $reuseKind) {
            $continuation = Get-WorkflowContinuationProof -RepositoryRoot $repoRoot -QualifiedCommit ([string]$qualification.repository.commit) -CurrentCommit $Commit -CurrentTree $Tree
            if (-not $continuation -or @($continuation.scopes) -contains "develop") { return $null }
            $journeyPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $repoRoot -ChangedPath @($continuation.paths) -Catalog $qualityCatalog
            if (@($journeyPlan.journeys).Count -gt 0) { return $null }
            $reuseKind = "targeted-continuation"
        }
        $currentFullHash = (Get-FileHash -LiteralPath $qualificationFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentFullHash -ne ([string]$qualification.fullQualificationSha256).ToLowerInvariant()) {
            if (-not $FullProof -or [string]$FullProof.qualification.repository.commit -ne [string]$qualification.repository.commit -or [string]$FullProof.qualification.repository.tree -ne [string]$qualification.repository.tree) { return $null }
        }
        $reportPath = if ([IO.Path]::IsPathRooted([string]$qualification.e2e.path)) { [string]$qualification.e2e.path } else { Join-Path $repoRoot ([string]$qualification.e2e.path).Replace('/', '\') }
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return $null }
        if ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$qualification.e2e.sha256).ToLowerInvariant()) { return $null }
        if ([int]$qualification.schemaVersion -eq 3) {
            if ([string]$qualification.identitySha256 -notmatch '^[a-f0-9]{64}$' -or -not $qualification.PSObject.Properties["journeys"] -or
                ($ExpectedIdentitySha256 -and [string]$qualification.identitySha256 -ne $ExpectedIdentitySha256)) { return $null }
            foreach ($journey in @("upgrade", "fresh")) {
                $property = $qualification.journeys.PSObject.Properties[$journey]
                $record = if ($property) { $property.Value } else { $null }
                if (-not $record -or [string]$record.evidenceCommit -notmatch '^[a-f0-9]{40}$' -or [string]$record.evidenceTree -notmatch '^[a-f0-9]{40}$') { return $null }
                $journeyPath = if ([IO.Path]::IsPathRooted([string]$record.path)) { [string]$record.path } else { Join-Path $repoRoot ([string]$record.path).Replace('/', '\') }
                $routeValid = Test-DevelopE2ERouteReport -Path $journeyPath -Journey $journey -Tree ([string]$record.evidenceTree) -IdentitySha256 ([string]$qualification.identitySha256) -StandStateSha256 $ExpectedStandStateSha256
                if (-not $routeValid) { return $null }
                if ((Get-FileHash -LiteralPath $journeyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$record.sha256).ToLowerInvariant()) { return $null }
            }
        } elseif ($ExpectedIdentitySha256) { return $null }
        return [pscustomobject]@{ qualification = $qualification; reuseKind = $reuseKind; continuation = $continuation }
    } catch { return $null }
}

function Write-DevelopContinuationQualification {
    param([string]$Commit, [string]$Tree, [object]$SourceProof, [object]$ContinuationProof)

    $source = $SourceProof.qualification
    $qualification = [ordered]@{
        schemaVersion = $(if ([int]$source.schemaVersion -eq 3) { 3 } else { 2 })
        kind = "itl-workflow-develop-qualification"
        status = "passed"
        reusable = $true
        repository = [ordered]@{
            commit = $Commit
            tree = $Tree
            evidenceCommit = [string]$source.repository.evidenceCommit
            evidenceTree = [string]$source.repository.tree
            worktreeClean = $true
            reuseKind = "targeted-continuation"
        }
        fullQualificationSha256 = (Get-FileHash -LiteralPath $qualificationFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        e2e = $source.e2e
        continuation = [ordered]@{
            qualifiedCommit = [string]$ContinuationProof.qualifiedCommit
            paths = @($ContinuationProof.paths)
            scopes = @($ContinuationProof.scopes)
            targetedRunPath = [string]$ContinuationProof.targetedRunPath
            targetedRunSha256 = [string]$ContinuationProof.targetedRunSha256
            targetedFinishedAt = [string]$ContinuationProof.targetedFinishedAt
        }
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
    if ([int]$source.schemaVersion -eq 3) {
        $qualification["identitySha256"] = [string]$source.identitySha256
        $qualification["journeys"] = $source.journeys
    }
    [IO.File]::WriteAllText($developQualificationFullPath, (($qualification | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $qualification
}

function Write-DevelopQualification {
    param([string]$Commit, [string]$Tree, [string]$ReportPath, [string]$IdentitySha256, [object]$JourneyRecords)
    if (-not (Test-Path -LiteralPath $qualificationFullPath -PathType Leaf)) { throw "Develop qualification requires reusable Full evidence." }
    $root = Split-Path -Parent $developQualificationFullPath
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $canonicalReport = Join-Path $root "develop-e2e-summary.json"
    Copy-Item -LiteralPath $ReportPath -Destination $canonicalReport -Force
    $qualification = [ordered]@{
        schemaVersion = 3
        kind = "itl-workflow-develop-qualification"
        status = "passed"
        reusable = $true
        repository = [ordered]@{ commit = $Commit; tree = $Tree; evidenceCommit = $Commit; worktreeClean = $true }
        fullQualificationSha256 = (Get-FileHash -LiteralPath $qualificationFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        e2e = [ordered]@{ path = Get-RelativeRepositoryPath -Path $canonicalReport -Root $repoRoot; sha256 = (Get-FileHash -LiteralPath $canonicalReport -Algorithm SHA256).Hash.ToLowerInvariant() }
        identitySha256 = $IdentitySha256
        journeys = $JourneyRecords
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
    [IO.File]::WriteAllText($developQualificationFullPath, (($qualification | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $qualification
}

function Get-DevelopE2EIdentitySha256 {
    param([object]$ReleaseContext, [object]$ForkIdentity, [string]$ProjectRoot)

    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $projectConfig = Join-Path $root ".agent-1c\project.json"
    $standConfig = Join-Path $root ".agent-1c\release-e2e.json"
    $devEnv = Join-Path $root ".dev.env"
    $identity = [ordered]@{
        schemaVersion = 1
        fork = [ordered]@{ commit = [string]$ForkIdentity.commit; tree = [string]$ForkIdentity.tree; tag = [string]$ForkIdentity.tag }
        vanessaAutomationSha256 = [string]$ReleaseContext.artifacts.vanessaAutomation.sha256
        managedPackageSha256 = [string]$ReleaseContext.managedPackage.sha256
        projectRoot = $root.ToLowerInvariant()
        projectConfigSha256 = $(if (Test-Path -LiteralPath $projectConfig -PathType Leaf) { (Get-FileHash -LiteralPath $projectConfig -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" })
        standConfigSha256 = $(if (Test-Path -LiteralPath $standConfig -PathType Leaf) { (Get-FileHash -LiteralPath $standConfig -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" })
        devEnvSha256 = $(if (Test-Path -LiteralPath $devEnv -PathType Leaf) { (Get-FileHash -LiteralPath $devEnv -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" })
        powershellVersion = [string]$PSVersionTable.PSVersion
        powershellEdition = [string]$PSVersionTable.PSEdition
    }
    return Get-DevelopE2ECanonicalJsonSha256 -Value $identity
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Push-Location $repoRoot
try {
    $commit = (& git rev-parse HEAD).Trim()
    $tree = (& git rev-parse 'HEAD^{tree}').Trim()
    $worktreeCleanAtStart = @(& git status --porcelain).Count -eq 0
    $resolvedAiRulesSource = $(if ($effectiveMode -in @("Full", "Develop", "Release")) { Resolve-AiRulesSource } else { "" })
    $sourceIsLocal = $resolvedAiRulesSource -and (Test-Path -LiteralPath $resolvedAiRulesSource -PathType Container)

    if ($effectiveMode -in @("Develop", "Release")) {
        if ([string]::IsNullOrWhiteSpace($E2EProjectRoot)) { throw "$effectiveMode mode requires -E2EProjectRoot for the dedicated stand." }
        if (-not $worktreeCleanAtStart) { throw "$effectiveMode requires a clean candidate worktree." }
    }
    if ($effectiveMode -eq "Release") {
        if ($Offline) { throw "Release mode cannot run with -Offline." }
        if (-not $sourceIsLocal) { throw "Release requires -AiRulesSource (or ITL_AI_RULES_SOURCE_PATH) pointing to a local controlled fork checkout." }
    }
    if ($sourceIsLocal) {
        try { $aiRulesRelease = Get-LocalForkRelease -SourceRoot ([System.IO.Path]::GetFullPath($resolvedAiRulesSource)) } catch { if ($effectiveMode -eq "Release") { throw } }
    }
    if ($effectiveMode -eq "Release") {
        $releaseFullProof = Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease
        if (-not $releaseFullProof) { throw "Release requires reusable Full evidence or an exact Targeted continuation for the candidate tree." }
    }

    $trackedBefore = @(& git status --porcelain --untracked-files=no)
    Invoke-GateStage -Name "git-diff-check" -Reason "always-run preflight" -Body {
        & git diff --check HEAD -- .
        if ($LASTEXITCODE -ne 0) { throw "git diff --check failed." }
    } | Out-Null

    if ($effectiveMode -in @("Full", "Develop", "Release")) {
        $releaseContextPath = Join-Path $outputRoot "release-context.json"
        $readinessScript = Join-Path $repoRoot "scripts\test-release-readiness.ps1"
        Invoke-GateStage -Name "release-readiness" -Reason "aggregate dependency, candidate, encoding, and stand preflight" -Detail $releaseContextPath -Body {
            $readinessArguments = @("-Mode", $effectiveMode, "-RepositoryRoot", $repoRoot, "-OutputPath", $releaseContextPath)
            if ($Offline) { $readinessArguments += "-Offline" }
            $readinessRulesSource = if ($aiRulesRelease -and [string]$aiRulesRelease.sourceRoot) { [string]$aiRulesRelease.sourceRoot } elseif ($sourceIsLocal) { [System.IO.Path]::GetFullPath($resolvedAiRulesSource) } else { "" }
            if ($readinessRulesSource) { $readinessArguments += @("-AiRulesSource", $readinessRulesSource) }
            if ($effectiveMode -in @("Develop", "Release")) { $readinessArguments += @("-E2EProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot))) }
            if ($effectiveMode -eq "Release") { $readinessArguments += @("-ResumeMode", $ReleaseResumeMode) }
            Invoke-PowerShellChild -ScriptPath $readinessScript -Arguments $readinessArguments -TimeoutSeconds 300 -LogName "release-readiness"
            if (-not (Test-Path -LiteralPath $releaseContextPath -PathType Leaf)) { throw "Release readiness context was not created." }
            $script:releaseContext = Get-Content -LiteralPath $releaseContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$script:releaseContext.status -ne "passed") { throw "Release readiness context reports '$([string]$script:releaseContext.status)'." }
            $archivePath = [string]$script:releaseContext.artifacts.vanessaAutomation.path
            if (-not $archivePath) { throw "Release readiness did not resolve the Vanessa Automation archive." }
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archivePath
        } | Out-Null
    }

    $releaseDevelopIdentitySha256 = ""
    $releaseDevelopStandStateSha256 = ""
    if ($effectiveMode -eq "Release") {
        $releaseDevelopIdentitySha256 = Get-DevelopE2EIdentitySha256 -ReleaseContext $releaseContext -ForkIdentity $aiRulesRelease -ProjectRoot $E2EProjectRoot
        $releaseDevelopStandStateSha256 = Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
        $releaseDevelopProof = Test-DevelopQualification -Commit $commit -Tree $tree -FullProof $releaseFullProof -ExpectedIdentitySha256 $releaseDevelopIdentitySha256 -ExpectedStandStateSha256 $releaseDevelopStandStateSha256
        if (-not $releaseDevelopProof) { throw "Release requires a reusable route-aware Develop qualification with the current runtime identity. Run Develop once before Release." }
    }

    $reuseQualification = $false
    if ($effectiveMode -in @("Full", "Develop", "Release") -and $aiRulesRelease) {
        $qualificationMatch = if ($effectiveMode -eq "Develop") {
            Get-DevelopStaticQualificationCacheMatch `
                -RepositoryRoot $repoRoot `
                -QualificationRoot (Split-Path -Parent $qualificationFullPath) `
                -Tree $tree `
                -Validate {
                    param([bool]$AllowIndependentExactTree)
                    Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease -AllowIndependentExactTree:$AllowIndependentExactTree
                }
        } else {
            Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease
        }
        if ($qualificationMatch) {
            $reuseQualification = $true
            $existingQualification = $qualificationMatch.qualification
            $qualificationReuseKind = [string]$qualificationMatch.reuseKind
            $continuationProof = $qualificationMatch.continuation
            $qualifiedResult = $existingQualification.result
            $pesterVersion = [string]$existingQualification.environment.pesterVersion
        }
    }

    $forkReadyForParallel = -not $sourceIsLocal
    if ($sourceIsLocal -and $aiRulesRelease) {
        $preflightForkQualificationPath = Join-Path ([string]$aiRulesRelease.sourceRoot) "build\test-results\qualification\full.json"
        $forkReadyForParallel = Test-ForkQualification -SourceRoot ([string]$aiRulesRelease.sourceRoot) -Path $preflightForkQualificationPath -Identity $aiRulesRelease
    }
    if ($effectiveMode -in @("Full", "Develop", "Release") -and -not $reuseQualification -and -not ($Offline -and -not $sourceIsLocal) -and $forkReadyForParallel) {
        $compatibilityPath = Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1"
        $compatibilitySource = $(if ($aiRulesRelease -and [string]$aiRulesRelease.sourceRoot) { [string]$aiRulesRelease.sourceRoot } else { $resolvedAiRulesSource })
        $parallelCompatibility = Start-PowerShellChildProcess -ScriptPath $compatibilityPath -Arguments @("-AiRulesSource", $compatibilitySource) -LogName "ai-rules-compatibility"
    }

    if ($reuseQualification) {
        $pesterReuseReason = switch ($qualificationReuseKind) {
            "ancestor-same-tree" { "ancestor same-tree Full qualification" }
            "targeted-continuation" { "ancestor Full qualification plus exact Targeted continuation" }
            default { "exact clean Full qualification" }
        }
        Add-ReusedStage -Name "pester" -Reason $pesterReuseReason -Detail $qualificationFullPath
    } else {
        Invoke-GateStage -Name "pester" -Reason $(if ($effectiveMode -in @("Targeted", "Smoke")) { "$effectiveMode owner inventory" } else { "complete workflow inventory" }) -Body {
            if ($effectiveMode -in @("Targeted", "Smoke")) {
                $selectionPath = Join-Path $outputRoot "test-selection.json"
                if ($effectiveMode -eq "Targeted") {
                    $selector = Join-Path $repoRoot "scripts\resolve-targeted-tests.ps1"
                    $selectorArguments = @("-RepositoryRoot", $repoRoot, "-OutputPath", $selectionPath)
                    if ($BaseRef) { $selectorArguments += @("-BaseRef", $BaseRef) }
                    foreach ($path in @($ChangedPath | Where-Object { $_ })) { $selectorArguments += @("-ChangedPath", [string]$path) }
                    if ($CoverageContract.Count -gt 0) { $selectorArguments += @("-CoverageContract", ($CoverageContract -join ",")) }
                    Invoke-PowerShellChild -ScriptPath $selector -Arguments $selectorArguments -TimeoutSeconds 30 -NoProgressSeconds 20 -LogName "targeted-selector"
                } else {
                    $catalog = Get-Content -LiteralPath (Join-Path $repoRoot "tests\quality-contracts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                    $selection = [ordered]@{ schemaVersion = 1; paths = @("<smoke>"); contracts = @(); tests = @($catalog.smokeTests) }
                    [System.IO.File]::WriteAllText($selectionPath, (($selection | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
                }
                $selection = Get-Content -LiteralPath $selectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($effectiveMode -eq "Targeted") {
                    $shardRunner = Join-Path $repoRoot "scripts\invoke-pester-shards.ps1"
                    Invoke-PowerShellChild -ScriptPath $shardRunner -Arguments @("-RepositoryRoot", $repoRoot, "-OutputRoot", $outputRoot, "-JunitPath", $junitPath, "-WorkerCount", [string]$PesterWorkers, "-SelectionPath", $selectionPath) -TimeoutSeconds 900 -NoProgressSeconds 300 -ProgressPaths (Join-Path $outputRoot "pester-shards") -LogName "pester-selection-shards"
                    $selectionResult = Get-Content -LiteralPath (Join-Path $outputRoot "pester-shards\summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                } else {
                    $planPath = Join-Path $outputRoot "pester-selection-plan.json"; $resultPath = Join-Path $outputRoot "pester-selection-result.json"
                    $plan = [ordered]@{ schemaVersion = 1; worker = 0; paths = @($selection.tests) }
                    [System.IO.File]::WriteAllText($planPath, (($plan | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
                    Invoke-PowerShellChild -ScriptPath (Join-Path $repoRoot "scripts\run-pester-shard.ps1") -Arguments @("-PlanPath", $planPath, "-JunitPath", $junitPath, "-ResultPath", $resultPath) -TimeoutSeconds 120 -NoProgressSeconds 90 -LogName "pester-selection"
                    $selectionResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
                $script:pesterVersion = [string]$selectionResult.pesterVersion
                $script:pesterResult = [pscustomobject]@{ Result = $(if ([string]$selectionResult.status -eq "passed") { "Passed" } else { "Failed" }); PassedCount = [int]$selectionResult.passed; FailedCount = [int]$selectionResult.failed; SkippedCount = [int]$selectionResult.skipped }
            } else {
                $shardRunner = Join-Path $repoRoot "scripts\invoke-pester-shards.ps1"
                $shardArguments = @("-RepositoryRoot", $repoRoot, "-OutputRoot", $outputRoot, "-JunitPath", $junitPath, "-WorkerCount", [string]$PesterWorkers)
                if ($resolvedAiRulesSource) { $shardArguments += @("-AiRulesSource", $resolvedAiRulesSource) }
                Invoke-PowerShellChild -ScriptPath $shardRunner -Arguments $shardArguments -TimeoutSeconds 1200 -LogName "pester-shards"
                $shardSummaryPath = Join-Path $outputRoot "pester-shards\summary.json"
                if (-not (Test-Path -LiteralPath $shardSummaryPath -PathType Leaf)) { throw "Pester shard summary was not created." }
                $shardSummary = Get-Content -LiteralPath $shardSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:pesterVersion = [string]$shardSummary.pesterVersion
                $script:pesterResult = [pscustomobject]@{ Result = $(if ([string]$shardSummary.status -eq "passed") { "Passed" } else { "Failed" }); PassedCount = [int]$shardSummary.passed; FailedCount = [int]$shardSummary.failed; SkippedCount = [int]$shardSummary.skipped }
            }
            if ([string]$script:pesterResult.Result -ne "Passed") { throw "Pester did not pass: result=$($script:pesterResult.Result), failed=$($script:pesterResult.FailedCount)." }
        } | Out-Null
    }

    if ($effectiveMode -in @("Full", "Develop", "Release")) {
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
                $forkSourceRoot = [string]$aiRulesRelease.sourceRoot
                $forkQualificationPath = Join-Path $forkSourceRoot "build\test-results\qualification\full.json"
                if (Test-ForkQualification -SourceRoot $forkSourceRoot -Path $forkQualificationPath -Identity $aiRulesRelease) {
                    Add-ReusedStage -Name "fork-check" -Reason "exact clean fork Full qualification" -Detail $forkQualificationPath
                } else {
                    $forkGate = Join-Path $forkSourceRoot "scripts\check.ps1"
                    Invoke-GateStage -Name "fork-check" -Reason "missing, corrupt, or stale fork qualification" -Detail $forkSourceRoot -Body {
                        Invoke-PowerShellChild -ScriptPath $forkGate -Arguments @("-Mode", "Full", "-QualificationPath", $forkQualificationPath) -TimeoutSeconds 600 -LogName "fork-check"
                    } | Out-Null
                    if (-not (Test-ForkQualification -SourceRoot $forkSourceRoot -Path $forkQualificationPath -Identity $aiRulesRelease)) { throw "Fork Full did not produce an exact reusable qualification." }
                }
                $forkQualificationSha256 = (Get-FileHash -LiteralPath $forkQualificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            } else {
                Add-SkippedStage -Name "fork-check" -Reason "remote aiRules source has no reusable local qualification"
            }
            if ($parallelCompatibility) {
                Complete-ParallelGateStage -Name "ai-rules-compatibility" -Reason "workflow-to-fork integration boundary" -Detail $resolvedAiRulesSource -Child $parallelCompatibility -TimeoutSeconds 600
                $parallelCompatibility = $null
            } else {
                $compatibilityPath = Join-Path $repoRoot "scripts\test-ai-rules-compatibility.ps1"
                Invoke-GateStage -Name "ai-rules-compatibility" -Reason "workflow-to-fork integration boundary" -Detail $resolvedAiRulesSource -Body {
                    $compatibilitySource = $(if ($forkSourceRoot) { $forkSourceRoot } else { $resolvedAiRulesSource })
                    Invoke-PowerShellChild -ScriptPath $compatibilityPath -Arguments @("-AiRulesSource", $compatibilitySource) -TimeoutSeconds 600 -LogName "ai-rules-compatibility"
                } | Out-Null
            }
        }
    }

    if ($effectiveMode -in @("Full", "Develop", "Release")) {
        Invoke-GateStage -Name "static-tracked-state" -Reason "static qualification must preserve tracked state" -Body {
            & git diff --check HEAD -- .
            if ($LASTEXITCODE -ne 0) { throw "git diff --check failed after static qualification." }
            $trackedStatic = @(& git status --porcelain --untracked-files=no)
            if (($trackedBefore -join "`n") -ne ($trackedStatic -join "`n")) { throw "The static gate changed tracked worktree state." }
        } | Out-Null
        $staticResult = if ($pesterResult) {
            [ordered]@{ passed = [int]$pesterResult.PassedCount; failed = [int]$pesterResult.FailedCount; skipped = [int]$pesterResult.SkippedCount }
        } else {
            [ordered]@{ passed = [int]$qualifiedResult.passed; failed = [int]$qualifiedResult.failed; skipped = [int]$qualifiedResult.skipped }
        }
        if ($aiRulesRelease -and $worktreeCleanAtStart) {
            if ($reuseQualification) {
                $evidenceCommit = if ([string]$existingQualification.repository.evidenceCommit) { [string]$existingQualification.repository.evidenceCommit } else { [string]$existingQualification.repository.commit }
                $existingQualification = Write-WorkflowQualification -Commit $commit -Tree $tree -Result $staticResult -EvidenceCommit $evidenceCommit -ReuseKind $qualificationReuseKind -SourceQualification $existingQualification -ContinuationProof $continuationProof
            } else {
                $existingQualification = Write-WorkflowQualification -Commit $commit -Tree $tree -Result $staticResult -EvidenceCommit $commit -ReuseKind "executed" -SourceQualification $null
            }
        }
        if ($effectiveMode -eq "Develop" -and $existingQualification) {
            [void](Save-DevelopStaticQualification -RepositoryRoot $repoRoot -QualificationRoot (Split-Path -Parent $qualificationFullPath) -Tree $tree)
        }
    }

    if ($effectiveMode -eq "Release" -and [string]$releaseDevelopProof.reuseKind -eq "targeted-continuation") {
        [void](Write-DevelopContinuationQualification -Commit $commit -Tree $tree -SourceProof $releaseDevelopProof -ContinuationProof $releaseDevelopProof.continuation)
        $releaseDevelopProof = Test-DevelopQualification -Commit $commit -Tree $tree -ExpectedIdentitySha256 $releaseDevelopIdentitySha256 -ExpectedStandStateSha256 $releaseDevelopStandStateSha256
        if (-not $releaseDevelopProof) { throw "Release continuation did not materialize an exact reusable Develop qualification." }
    }

    if ($effectiveMode -eq "Develop") {
        $developE2EReportPath = Join-Path $outputRoot "develop-e2e-summary.json"
        $developScript = Join-Path $repoRoot "scripts\invoke-develop-e2e.ps1"
        $developRulesSource = $(if ($forkSourceRoot) { $forkSourceRoot } elseif ($aiRulesRelease) { [string]$aiRulesRelease.sourceRoot } else { $resolvedAiRulesSource })
        if (-not $developRulesSource) { throw "Develop E2E requires a local exact controlled-fork checkout." }
        if (-not $BaseRef) { throw "Develop E2E requires BaseRef so live journey ownership cannot be inferred from an unbounded candidate." }
        $developPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $repoRoot -BaseRef $BaseRef -Catalog $qualityCatalog
        $developIdentitySha256 = Get-DevelopE2EIdentitySha256 -ReleaseContext $releaseContext -ForkIdentity $aiRulesRelease -ProjectRoot $E2EProjectRoot
        $developStandStateSha256 = Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
        $qualificationRoot = Split-Path -Parent $developQualificationFullPath
        New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
        $routeRecords = [ordered]@{}
        $plannedJourneys = @($developPlan.journeys | ForEach-Object { [string]$_ })
        $allJourneys = @("upgrade", "fresh")
        $baseCommit = (& git rev-parse $BaseRef).Trim()
        $baseTree = (& git rev-parse "$BaseRef^{tree}").Trim()
        if ($LASTEXITCODE -ne 0 -or $baseCommit -notmatch '^[a-f0-9]{40}$' -or $baseTree -notmatch '^[a-f0-9]{40}$') { throw "Develop E2E cannot resolve BaseRef identity: $BaseRef" }
        $baseline = $null
        if (Test-Path -LiteralPath $developQualificationFullPath -PathType Leaf) {
            try { $baseline = Get-Content -LiteralPath $developQualificationFullPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $baseline = $null }
        }
        $baselineRepositoryMatches = $null -ne $baseline -and (([string]$baseline.repository.commit -eq $baseCommit -and [string]$baseline.repository.tree -eq $baseTree) -or
            ([string]$baseline.repository.commit -eq $commit -and [string]$baseline.repository.tree -eq $tree))
        $baselineValid = $null -ne $baseline -and [int]$baseline.schemaVersion -eq 3 -and [string]$baseline.status -eq "passed" -and $baselineRepositoryMatches -and
            [string]$baseline.identitySha256 -eq $developIdentitySha256 -and $baseline.PSObject.Properties["journeys"]
        if ($baselineValid) {
            foreach ($journey in @($allJourneys | Where-Object { $_ -notin $plannedJourneys })) {
                $property = $baseline.journeys.PSObject.Properties[$journey]
                $record = if ($property) { $property.Value } else { $null }
                $path = if ($record -and [IO.Path]::IsPathRooted([string]$record.path)) { [string]$record.path } elseif ($record) { Join-Path $repoRoot ([string]$record.path).Replace('/', '\') } else { "" }
                if (-not $record -or -not (Test-DevelopE2ERouteReport -Path $path -Tree ([string]$record.evidenceTree) -Journey $journey -IdentitySha256 $developIdentitySha256 -StandStateSha256 $developStandStateSha256) -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$record.sha256).ToLowerInvariant()) {
                    $baselineValid = $false
                    break
                }
                $routeRecords[$journey] = [ordered]@{ path = Get-RelativeRepositoryPath -Path $path -Root $repoRoot; sha256 = ([string]$record.sha256).ToLowerInvariant(); evidenceCommit = [string]$record.evidenceCommit; evidenceTree = [string]$record.evidenceTree; execution = "continued" }
            }
        }
        if (-not $baselineValid -and $plannedJourneys.Count -lt $allJourneys.Count) {
            $plannedJourneys = $allJourneys
            $routeRecords = [ordered]@{}
        }
        $effectivePlan = [pscustomobject][ordered]@{
            schemaVersion = 1; kind = "itl-develop-e2e-journey-plan"; reason = [string]$developPlan.reason
            paths = @($developPlan.paths); contracts = @($developPlan.contracts); journeys = @($plannedJourneys)
            unknownPaths = @($developPlan.unknownPaths); matchedFullPaths = @($developPlan.matchedFullPaths)
        }
        foreach ($journey in $plannedJourneys) {
            $routePath = Join-Path $qualificationRoot ("develop-e2e-$journey.json")
            $developStandStateSha256 = Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
            if (Restore-DevelopE2EQualification -RepositoryRoot $repoRoot -OutputPath $routePath -Tree $tree -Journey $journey -IdentitySha256 $developIdentitySha256 -StandStateSha256 $developStandStateSha256) {
                Add-ReusedStage -Name "develop-e2e-$journey" -Reason "exact-tree SHA-verified journey checkpoint" -Detail $routePath
            } else {
                $rawPath = Join-Path $outputRoot ("develop-e2e-$journey-raw.json")
                Invoke-GateStage -Name "develop-e2e-$journey" -Reason "owner-selected public $journey journey" -Detail $rawPath -Body {
                    Invoke-PowerShellChild -ScriptPath $developScript -Arguments @("-CandidateRoot", $repoRoot, "-ProjectRoot", ([IO.Path]::GetFullPath($E2EProjectRoot)), "-AiRulesSource", $developRulesSource, "-OutputPath", $rawPath, "-Journey", $journey) -TimeoutSeconds 5400 -NoProgressSeconds 900 -LogName "develop-e2e-$journey"
                    if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf)) { throw "Develop E2E $journey summary was not created." }
                    $raw = Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $result = @($raw.journeys | Where-Object { [string]$_.name -eq $journey }) | Select-Object -First 1
                    if ([int]$raw.schemaVersion -ne 2 -or [string]$raw.kind -ne "itl-develop-e2e" -or [string]$raw.status -ne "passed" -or
                        [string]$raw.candidate.tree -ne $tree -or @($raw.requestedJourneys).Count -ne 1 -or [string]$raw.requestedJourneys[0] -ne $journey -or [string]$result.status -ne "passed") {
                        throw "Develop E2E $journey did not qualify the exact candidate tree: $([string]$raw.error)"
                    }
                    $developStandStateSha256 = Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
                    $routeReport = New-DevelopE2ERouteReport -RepositoryRoot $repoRoot -Plan $effectivePlan -Journey $journey -IdentitySha256 $developIdentitySha256 -StandStateSha256 $developStandStateSha256 -JourneyResult $result
                    [IO.File]::WriteAllText($routePath, (($routeReport | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                    [void](Save-DevelopE2EQualification -RepositoryRoot $repoRoot -ReportPath $routePath -Tree $tree -Journey $journey -IdentitySha256 $developIdentitySha256 -StandStateSha256 $developStandStateSha256)
                } | Out-Null
            }
            $developStandStateSha256 = Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
            if (-not (Test-DevelopE2ERouteReport -Path $routePath -Tree $tree -Journey $journey -IdentitySha256 $developIdentitySha256 -StandStateSha256 $developStandStateSha256)) { throw "Develop E2E $journey route proof is invalid after execution or restore." }
            $routeRecords[$journey] = [ordered]@{ path = Get-RelativeRepositoryPath -Path $routePath -Root $repoRoot; sha256 = (Get-FileHash -LiteralPath $routePath -Algorithm SHA256).Hash.ToLowerInvariant(); evidenceCommit = $commit; evidenceTree = $tree; standStateSha256 = $developStandStateSha256; execution = $(if (@($stages | Where-Object { [string]$_.name -eq "develop-e2e-$journey" -and [string]$_.execution -eq "reused" }).Count -gt 0) { "reused" } else { "executed" }) }
        }
        foreach ($journey in $allJourneys) { if (-not $routeRecords.Contains($journey)) { throw "Develop E2E has no valid '$journey' journey evidence." } }
        $combined = [ordered]@{ schemaVersion = 2; kind = "itl-develop-e2e-combined"; status = "passed"; candidate = [ordered]@{ commit = $commit; tree = $tree }; identitySha256 = $developIdentitySha256; plan = $effectivePlan; journeys = $routeRecords; finishedAt = [DateTime]::UtcNow.ToString("o") }
        [IO.File]::WriteAllText($developE2EReportPath, (($combined | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [void](Write-DevelopQualification -Commit $commit -Tree $tree -ReportPath $developE2EReportPath -IdentitySha256 $developIdentitySha256 -JourneyRecords $routeRecords)
    }

    if ($effectiveMode -eq "Release") {
        Add-ReusedStage -Name "develop-e2e" -Reason "exact or ancestor same-tree Develop qualification" -Detail $developQualificationFullPath
        Invoke-GateStage -Name "ondemand-mcp-catalogs" -Reason "real backend catalogs are mandatory for release" -Detail "assets/ondemand-mcp/compatibility.json" -Body {
            $compatibilityPath = Join-Path $repoRoot ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json"
            $compatibility = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($family in @("roctup", "vanessa-ui")) {
                $definition = $compatibility.families.$family
                if ([string]$definition.qualification -ne "live-tools-list") {
                    throw "Release requires live-tools-list qualification for $family; actual: '$($definition.qualification)'."
                }
                $catalogPath = Join-Path (Split-Path -Parent $compatibilityPath) ([string]$definition.catalog)
                $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$catalog.generatedFrom -ne "mcp-tools-list" -or -not [string]$catalog.capturedAt) {
                    throw "Release catalog for $family was not generated from a captured real tools/list response."
                }
                $actualHash = Get-CanonicalTextSha256 -Path $catalogPath
                if ($actualHash -cne ([string]$definition.catalogSha256).ToLowerInvariant()) {
                    throw "Release catalog SHA256 mismatch for $family."
                }
            }
        }
        $e2eReportPath = Join-Path $outputRoot "release-e2e-summary.json"
        $e2eScript = Join-Path $repoRoot "scripts\invoke-release-e2e.ps1"
        $releaseHelperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        Invoke-GateStage -Name "release-e2e" -Reason "always-run release runtime proof" -Detail $e2eReportPath -Body {
            $releaseRulesSource = $(if ($forkSourceRoot) { $forkSourceRoot } elseif ($aiRulesRelease) { [string]$aiRulesRelease.sourceRoot } else { $resolvedAiRulesSource })
            $releaseProgressPaths = @($outputRoot, (Join-Path ([IO.Path]::GetFullPath($E2EProjectRoot)) ".agent-1c\locks"))
            Invoke-PowerShellChild -ScriptPath $e2eScript -Arguments @("-ProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot)), "-AiRulesSource", $releaseRulesSource, "-HelperPath", $releaseHelperPath, "-OutputPath", $e2eReportPath, "-ResumeMode", $ReleaseResumeMode) -TimeoutSeconds 7200 -NoProgressSeconds 900 -ProgressPaths $releaseProgressPaths -LogName "release-e2e"
            if (-not (Test-Path -LiteralPath $e2eReportPath -PathType Leaf)) { throw "Release E2E summary was not created: $e2eReportPath" }
            $e2eSummary = Get-Content -LiteralPath $e2eReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$e2eSummary.schemaVersion -ne 3) { throw "Release E2E summary schema must be 3; actual: $($e2eSummary.schemaVersion)." }
            if ([string]$e2eSummary.status -ne "passed") { throw "Release E2E summary reports '$($e2eSummary.status)': $([string]$e2eSummary.error)" }
            if ([bool]$e2eSummary.onDemandMcpTestFixture) { throw "Release E2E used the test-only on-demand MCP fixture." }
            if ([bool]$e2eSummary.seedParallelTestFixture) { throw "Release E2E used the test-only seed-parallel fixture." }
            if (-not [bool]$e2eSummary.seedParallelBranchRuntimeConcurrent -or -not [bool]$e2eSummary.seedParallelLiteRefreshConcurrent -or
                [string]$e2eSummary.seedParallelTargetMasterCommit -notmatch '^[a-f0-9]{40}$' -or
                [int]$e2eSummary.seedParallelLiteRefreshSourceCallCount -ne 0 -or
                [int]$e2eSummary.seedParallelBaselineCount -lt 0) {
                throw "Release E2E did not prove latest-only file seed plus parallel branch runtime and lite refresh."
            }
            if ([int]$e2eSummary.onDemandRoctupToolCount -ne 13 -or [int]$e2eSummary.onDemandVanessaToolCount -ne 38) { throw "Release E2E did not prove both complete on-demand MCP catalogs." }
            if ([int]$e2eSummary.onDemandRoctupPublicToolCount -ne 2 -or [int]$e2eSummary.onDemandVanessaPublicToolCount -ne 2) { throw "Release E2E did not prove both compact on-demand MCP gateway surfaces." }
            if ([int]$e2eSummary.onDemandVanessaInstances -ne 2 -or -not [bool]$e2eSummary.onDemandVanessaSecondSurvived) { throw "Release E2E did not prove isolated concurrent Vanessa facade instances." }
            if ([int]$e2eSummary.maxConcurrentSessions -lt 1 -or [int]$e2eSummary.maxConcurrentSessions -gt 3) { throw "Release E2E did not prove maxConcurrentSessions=3; observed $([int]$e2eSummary.maxConcurrentSessions)." }
            if ([int64]$e2eSummary.ownedProcessExitWaitMs -lt 0 -or [int64]$e2eSummary.ownedProcessExitWaitMs -gt 15000) { throw "Release E2E owned process exit wait exceeded 15000 ms: $([int64]$e2eSummary.ownedProcessExitWaitMs) ms." }
        } | Out-Null
    }

    if ($overallStopwatch.Elapsed.TotalSeconds -gt $modeHardBudgetSeconds) { throw "$effectiveMode exceeded its overall hard budget of $modeHardBudgetSeconds seconds." }

    Invoke-GateStage -Name "tracked-state" -Reason "tests must preserve tracked state" -Body {
        & git diff --check HEAD -- .
        if ($LASTEXITCODE -ne 0) { throw "git diff --check failed after tests." }
        $trackedAfter = @(& git status --porcelain --untracked-files=no)
        if (($trackedBefore -join "`n") -ne ($trackedAfter -join "`n")) { throw "The local gate changed tracked worktree state." }
    } | Out-Null
} catch {
    if ($parallelCompatibility -and -not $parallelCompatibility.process.HasExited) {
        Stop-GateChildProcessTree -Process $parallelCompatibility.process
    }
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
    $budgetStatus = $(if ($failure) { "failed" } elseif ($overallStopwatch.Elapsed.TotalSeconds -le $modeTargetBudgetSeconds) { "within-target" } else { "over-target" })
    $summary = [ordered]@{
        schemaVersion = 2
        repository = "1c-agent-workflow"
        mode = $Mode
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$overallStopwatch.ElapsedMilliseconds
        targetBudgetSeconds = $modeTargetBudgetSeconds
        hardBudgetSeconds = $modeHardBudgetSeconds
        budgetStatus = $budgetStatus
        commit = $commit
        tree = $tree
        worktreeClean = (-not $dirty)
        offline = [bool]$Offline
        aiRulesRelease = $aiRulesRelease
        qualificationPath = $qualificationFullPath
        developQualificationPath = $developQualificationFullPath
        developE2eReportPath = $developE2EReportPath
        e2eReportPath = $e2eReportPath
        releaseContextPath = $releaseContextPath
        qualificationReuseKind = $qualificationReuseKind
        tests = $result
        stages = @($stages | ForEach-Object { $_ })
        slowestStages = @($stages | Sort-Object { [int64]$_['durationMs'] } -Descending | Select-Object -First 5)
        error = $failure
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 12), $utf8NoBom)

    Pop-Location
}

if ($failure) { [Console]::Error.WriteLine($failure); exit 1 }
if ($budgetStatus -eq "over-target") { Write-Warning "ITL $Mode passed but exceeded its target budget of $modeTargetBudgetSeconds seconds. Inspect slowestStages in $summaryPath." }
Write-Host "ITL $Mode gate passed. Summary: $summaryPath"
if ($effectiveMode -in @("Full", "Develop")) { Write-Host "Qualification: $qualificationFullPath" }
if ($effectiveMode -eq "Develop") { Write-Host "Develop qualification: $developQualificationFullPath" }
