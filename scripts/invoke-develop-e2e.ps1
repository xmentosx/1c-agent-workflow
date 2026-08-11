[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidateRoot,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$AiRulesSource,
    [string]$OutputPath = "",
    [string]$FreshProjectsRoot = "C:\itlj"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$CandidateRoot = [IO.Path]::GetFullPath($CandidateRoot)
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$AiRulesSource = [IO.Path]::GetFullPath($AiRulesSource)
foreach ($spec in @(@($CandidateRoot, "candidate"), @($ProjectRoot, "develop E2E stand"), @($AiRulesSource, "controlled fork"))) {
    if (-not (Test-Path -LiteralPath $spec[0] -PathType Container)) { throw "$($spec[1]) root is missing: $($spec[0])" }
}
if (-not $OutputPath) { $OutputPath = Join-Path $ProjectRoot "build\test-results\develop-e2e\develop-e2e-summary.json" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputRoot = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$startedAt = [DateTime]::UtcNow
$steps = New-Object System.Collections.Generic.List[object]
$failure = $null
$freshRoot = ""
$freshBranchRoot = ""
$candidateCommit = (& git -C $CandidateRoot rev-parse HEAD).Trim()
$candidateTree = (& git -C $CandidateRoot rev-parse 'HEAD^{tree}').Trim()
$onDemandSourceBuild = & (Join-Path $CandidateRoot "scripts\Build-ItlOnDemandMcp.ps1") -SkipTests
$onDemandLock = (
    Get-Content -LiteralPath (Join-Path $CandidateRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 |
        ConvertFrom-Json
).dependencies.itlOndemandMcp
if ([string]$onDemandSourceBuild.sha256 -cne ([string]$onDemandLock.sha256).ToLowerInvariant()) {
    throw "DEVELOP_E2E_ONDEMAND_SOURCE_BUILD_MISMATCH: expected='$(([string]$onDemandLock.sha256).ToLowerInvariant())' actual='$([string]$onDemandSourceBuild.sha256)'."
}
$env:ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE = [string]$onDemandSourceBuild.path
. (Join-Path $PSScriptRoot "develop-e2e-cleanup.ps1")

function ConvertTo-DevelopProcessArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Test-DevelopTransientNetworkFailure {
    param([string[]]$Output)
    $text = @($Output | ForEach-Object { [string]$_ }) -join "`n"
    return $text -match '(?i)(could not resolve host|failed to connect|could not connect|connection (was )?timed out|network is unreachable|temporary failure in name resolution|remote end hung up|http (500|502|503|504))'
}

function Assert-DevelopAiRulesRemoteReachable {
    param([string]$StandRoot, [int]$MaxAttempts = 3)
    $configPath = Join-Path $StandRoot ".agent-1c\project.json"
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $repo = [string]$config.aiRules.repo; $ref = [string]$config.aiRules.ref
    if (-not $repo -or -not $ref) { throw "Develop E2E stand must configure an immutable ai_rules_1c repository and ref before live journeys." }
    $remoteRef = "refs/tags/$ref"
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = @(& git ls-remote --exit-code $repo $remoteRef 2>&1)
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        if ($exitCode -eq 0 -and @($output | Where-Object { [string]$_ -match '^[a-f0-9]{40}\s+refs/tags/' }).Count -gt 0) { return }
        $transient = Test-DevelopTransientNetworkFailure -Output @($output)
        if (-not $transient -or $attempt -ge $MaxAttempts) { throw "Develop E2E cannot read immutable ai_rules_1c ref '$remoteRef' from '$repo': $(@($output | ForEach-Object { [string]$_ }) -join '; ')" }
        $delaySeconds = [int][Math]::Pow(2, $attempt)
        Write-Warning "Develop E2E ai_rules_1c remote preflight attempt $attempt/$MaxAttempts hit a transient network failure; retrying in $delaySeconds seconds."
        Start-Sleep -Seconds $delaySeconds
    }
}

function Stop-DevelopProcessTree {
    param([object]$Process)
    if (-not $Process -or $Process.HasExited) { return }
    $processId = [int]$Process.Id
    if ($env:OS -eq "Windows_NT") { & taskkill.exe /PID $processId /T /F *> $null } else { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    try { $Process.WaitForExit() } catch {}
}

function Invoke-DevelopProcess {
    param(
        [string]$Name,
        [string]$WorkingRoot,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 3600,
        [switch]$AllowFailure
    )
    $stdout = Join-Path $outputRoot ($Name + ".stdout.log")
    $stderr = Join-Path $outputRoot ($Name + ".stderr.log")
    $parts = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + @($Arguments)
    $argumentLine = @($parts | ForEach-Object { ConvertTo-DevelopProcessArgument -Value ([string]$_) }) -join " "
    $started = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -WorkingDirectory $WorkingRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    [void]$process.Handle
    $lastLength = -1L
    $lastProgress = [DateTime]::UtcNow
    $lastHeartbeat = [DateTime]::UtcNow
    try {
        while (-not $process.WaitForExit(5000)) {
            $length = 0L
            foreach ($path in @($stdout, $stderr)) { if (Test-Path $path) { $length += (Get-Item $path).Length } }
            if ($length -ne $lastLength) { $lastLength = $length; $lastProgress = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 30) { [Console]::Out.WriteLine("ITL develop E2E step '$Name': elapsed=$([int]$watch.Elapsed.TotalSeconds)s; noProgress=$([int]([DateTime]::UtcNow - $lastProgress).TotalSeconds)s."); $lastHeartbeat = [DateTime]::UtcNow }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or ([DateTime]::UtcNow - $lastProgress).TotalMinutes -ge 15) {
                Stop-DevelopProcessTree -Process $process
                throw "$Name exceeded its bounded runtime or made no progress for 15 minutes."
            }
        }
        $process.WaitForExit(); $process.Refresh()
        $status = if ([int]$process.ExitCode -eq 0) { "passed" } else { "failed" }
        $steps.Add([ordered]@{ name = $Name; status = $status; startedAt = $started.ToString("o"); durationMs = [int64]$watch.ElapsedMilliseconds; command = $argumentLine; stdout = $stdout; stderr = $stderr }) | Out-Null
        if ([int]$process.ExitCode -ne 0 -and -not $AllowFailure) { throw "$Name failed with exit code $($process.ExitCode). See $stdout and $stderr" }
        return [pscustomobject]@{ exitCode = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally {
        $watch.Stop()
    }
}

function Invoke-InstalledAction {
    param([string]$Name, [string]$Root, [string]$Action, [string[]]$AdditionalArguments = @(), [int]$TimeoutSeconds = 3600, [switch]$AllowFailure)
    $runner = Join-Path $Root ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Installed compact runner is missing: $runner" }
    [string[]]$runnerArguments = if ($Action -in @("new-dev-branch", "new-extension-dev-branch", "adopt-dev-worktree", "close-dev-branch")) { @("-Windowed", "--") } else { @("--") }
    $runnerArguments += @("-Action", $Action)
    $runnerArguments += @($AdditionalArguments)
    $result = Invoke-DevelopProcess -Name $Name -WorkingRoot $Root -ScriptPath $runner -Arguments $runnerArguments -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
    $summary = Read-CompactSummary -ProcessResult $result
    if ([string]$summary.action -ne $Action) { throw "$Name returned a summary for another action: $([string]$summary.action)" }
    if (-not $AllowFailure -and [string]$summary.status -ne "succeeded") { throw "$Name did not complete successfully: $([string]$summary.error)" }
    return $result
}

function Read-CompactSummary {
    param([Parameter(Mandatory = $true)][object]$ProcessResult)
    $lines = @(Get-Content -LiteralPath $ProcessResult.stdout -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Trim().StartsWith('{') })
    if ($lines.Count -eq 0) { throw "Compact action did not write its JSON summary: $($ProcessResult.stdout)" }
    return ($lines[-1] | ConvertFrom-Json)
}

function Assert-FailedRecoveryRoute {
    param([Parameter(Mandatory = $true)][object]$ProcessResult, [string]$ExpectedCategory = "")
    if ([int]$ProcessResult.exitCode -eq 0) { throw "Expected a public action failure, but it reported success: $($ProcessResult.stdout)" }
    $summary = Read-CompactSummary -ProcessResult $ProcessResult
    if ([string]$summary.status -ne "failed" -or [string]::IsNullOrWhiteSpace([string]$summary.nextAction)) { throw "Failed public action did not provide a recovery route." }
    if ($ExpectedCategory -and [string]$summary.errorCategory -ne $ExpectedCategory) { throw "Expected failure category '$ExpectedCategory', actual '$([string]$summary.errorCategory)'." }
    return $summary
}

function Assert-FreshVerificationResult {
    param([Parameter(Mandatory = $true)][object]$ProcessResult)
    $summary = Read-CompactSummary -ProcessResult $ProcessResult
    $runStatusPath = [string]$summary.statusPath
    if ([string]$summary.status -ne "succeeded" -or -not $runStatusPath -or -not (Test-Path -LiteralPath $runStatusPath -PathType Leaf)) { throw "Verification did not produce a successful compact status." }
    $runStatus = Get-Content -LiteralPath $runStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verificationRoot = [IO.Path]::GetFullPath([string]$runStatus.projectRoot)
    $branch = (& git -C $verificationRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -notlike "itldev/*") { throw "Verification did not run in an itldev branch worktree." }
    $stateName = $branch.Substring("itldev/".Length)
    $statusPath = Join-Path $verificationRoot (".agent-1c\dev-branches\{0}.json" -f $stateName)
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw "Verification did not update its authoritative branch state: $statusPath" }
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$status.lastVerificationStatus -ne "passed" -or [string]::IsNullOrWhiteSpace([string]$status.lastVerifiedFingerprint)) { throw "Verification status lacks a fresh passed fingerprint." }
    $reportPath = [string]$status.lastVerifiedReportPath
    if (-not $reportPath -or -not (Test-Path -LiteralPath $reportPath)) { throw "Verification status points to no report artifact." }
    if ((Get-Item -LiteralPath $reportPath).PSIsContainer -and @(Get-ChildItem -LiteralPath $reportPath -Filter "*.xml" -File -Recurse).Count -eq 0) { throw "Verification report directory contains no JUnit XML." }
    return $summary
}

function Assert-ExportResult {
    param([Parameter(Mandatory = $true)][object]$ProcessResult)
    $summary = Read-CompactSummary -ProcessResult $ProcessResult
    if ([string]$summary.status -ne "succeeded" -or -not (Test-Path -LiteralPath ([string]$summary.resultManifestPath) -PathType Leaf)) { throw "Export did not produce a successful result manifest." }
    $manifest = Get-Content -LiteralPath ([string]$summary.resultManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$manifest.verification.freshPassed -or [string]$manifest.artifact.sha256 -notmatch '^[a-f0-9]{64}$') { throw "Export manifest lacks fresh verification or artifact SHA256." }
    $actual = (Get-FileHash -LiteralPath ([string]$manifest.artifact.path) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) { throw "Export artifact SHA256 does not match its manifest." }
    return $summary
}

function Assert-TrackedClean {
    param([string]$Root, [string]$Label)
    if (@(& git -C $Root status --porcelain --untracked-files=no).Count -gt 0) { throw "$Label has tracked changes: $Root" }
}

function Assert-InitializedProject {
    param([string]$Root)
    $operationPath = Join-Path $Root ".agent-1c\locks\lifecycle-operation.json"
    if (-not (Test-Path -LiteralPath $operationPath -PathType Leaf)) { throw "init-project did not write lifecycle operation state." }
    $operation = Get-Content -LiteralPath $operationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$operation.action -ne "init-project" -or [string]$operation.status -ne "succeeded") {
        $requiredAction = if ($operation.PSObject.Properties["requiredAction"]) { [string]$operation.requiredAction } else { "<missing>" }
        throw "init-project did not complete successfully: status=$([string]$operation.status); requiredAction=$requiredAction"
    }
    $topLevel = (& git -C $Root rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($topLevel) -ne [IO.Path]::GetFullPath($Root)) { throw "init-project did not create the expected Git repository." }
    if ((& git -C $Root branch --show-current).Trim() -ne "master") { throw "init-project did not leave the fresh project on master." }
    if ((Get-WorkflowLockCommit -Root $Root) -ne $candidateCommit) { throw "init-project did not retain the exact develop candidate." }
    Assert-TrackedClean -Root $Root -Label "Fresh initialized project"
}

function Assert-ProjectStatusOutput {
    param([Parameter(Mandatory = $true)][object]$ProcessResult)
    $text = Get-Content -LiteralPath $ProcessResult.stdout -Raw -Encoding UTF8
    if ($text -notmatch '(?m)^Git branch: master\s*$' -or $text -notmatch '(?m)^Git worktree: clean\s*$') { throw "status did not report a clean fresh master worktree." }
}

function Get-WorkflowLockCommit {
    param([string]$Root)
    $lockPath = Join-Path $Root ".agent-1c\dependency-lock.json"
    if (-not (Test-Path $lockPath -PathType Leaf)) { return "" }
    return [string](Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.workflowPackage.commit
}

function Commit-StandUpdate {
    param([string]$Root, [string]$Message)
    $changed = @(& git -C $Root status --porcelain --untracked-files=no)
    if ($changed.Count -eq 0) { return (& git -C $Root rev-parse HEAD).Trim() }
    & git -C $Root add --all
    if ($LASTEXITCODE -ne 0) { throw "Unable to stage $Message." }
    # A fresh Windows checkout can report CRLF-only drift that git add normalizes back to a clean index.
    & git -C $Root commit -m $Message | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $remaining = @(& git -C $Root status --porcelain --untracked-files=no)
        if ($remaining.Count -ne 0) { throw "Unable to commit $Message." }
    }
    return (& git -C $Root rev-parse HEAD).Trim()
}

function Set-FreshConfigurationComment {
    param([string]$Root)
    $path = Join-Path $Root "src\cf\Configuration.xml"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fresh journey Configuration.xml is missing." }
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = [Text.UTF8Encoding]::new($bom)
    $text = [IO.File]::ReadAllText($path, $encoding)
    $regex = [regex]::new('<Comment(?<attributes>\s[^>]*)?\s*/>|<Comment(?<attributes>\s[^>]*)?>(?<value>.*?)</Comment>', [Text.RegularExpressions.RegexOptions]::Singleline)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) { throw "Fresh journey expected one root Configuration Comment." }
    $match = $matches[0]
    $value = "ITL develop journey " + [DateTime]::UtcNow.ToString("o")
    $escaped = [Security.SecurityElement]::Escape($value)
    $replacement = if ($match.Value -match '/>\s*$') {
        "<Comment$([string]$match.Groups['attributes'].Value)>$escaped</Comment>"
    } else {
        $open = $match.Value.IndexOf('>')
        $close = $match.Value.LastIndexOf('</Comment>', [StringComparison]::Ordinal)
        $match.Value.Substring(0, $open + 1) + $escaped + $match.Value.Substring($close)
    }
    [IO.File]::WriteAllText($path, $regex.Replace($text, $replacement, 1), $encoding)
}

function Add-FreshVanessaFeature {
    param([string]$Root)
    $path = Join-Path $Root "tests\features\ITLDevelopJourney.feature"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $base64 = 'I2xhbmd1YWdlOiBydQoKQGl0bF9kZXZlbG9wX2pvdXJuZXkK0KTRg9C90LrRhtC40L7QvdCw0Ls6IElUTCBkZXZlbG9wIGpvdXJuZXkKCtCh0YbQtdC90LDRgNC40Lk6INCR0LDQt9C+0LLQsNGPINGA0LDQsdC+0YLQsNC10YIKCtCa0L7QvdGC0LXQutGB0YI6CgkN0JTQsNC90L4g0K8g0LfQsNC/0YPRgdC60LDRjiDRgdGG0LXQvdCw0YDQuNC5INC+0YLQutGA0YvRgtC40Y8gVGVzdENsaWVudCDQuNC70Lgg0L/QvtC00LrQu9GO0YfQsNGOINGD0LbQtSDRgdGD0YnQtdGB0YLQstGD0Y7RidC40LkKCtCh0YbQtdC90LDRgNC40Lk6INCh0LXRgNCy0LXRgCDQstGL0L/QvtC70L3Rj9C10YIg0LrQvtC0CgkN0Jgg0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LUKCSIiImJzbAoJCdCV0YHQu9C4INCb0L7QttGMINCi0L7Qs9C00LAg0JLRi9C30LLQsNGC0YzQmNGB0LrQu9GO0YfQtdC90LjQtSAiZGV2ZWxvcCI7INCa0L7QvdC10YbQldGB0LvQuDsKCSIiIg=='
    [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($base64))
}

function Get-BranchWorktree {
    param([string]$Root, [string]$Name)
    $lines = @(& git -C $Root worktree list --porcelain)
    $currentPath = ""
    foreach ($line in $lines) {
        if ($line -like "worktree *") { $currentPath = $line.Substring(9) }
        if ($line -eq "branch refs/heads/itldev/$Name") { return [IO.Path]::GetFullPath($currentPath) }
    }
    throw "Fresh journey branch worktree was not registered: itldev/$Name"
}

$previousWorkflowSource = $env:ITL_WORKFLOW_SOURCE_PATH
$previousRulesSource = $env:ITL_AI_RULES_SOURCE_PATH
try {
    $env:ITL_WORKFLOW_SOURCE_PATH = $CandidateRoot
    $env:ITL_AI_RULES_SOURCE_PATH = $AiRulesSource
    Assert-DevelopAiRulesRemoteReachable -StandRoot $ProjectRoot
    Assert-TrackedClean -Root $ProjectRoot -Label "Develop E2E master"
    $standConfig = Get-Content -LiteralPath (Join-Path $ProjectRoot ".agent-1c\release-e2e.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $standBranchRoot = [IO.Path]::GetFullPath([string]$standConfig.worktreePath)
    Assert-TrackedClean -Root $standBranchRoot -Label "Develop E2E branch"

    [void](Invoke-InstalledAction -Name "upgrade-update-workflow" -Root $ProjectRoot -Action "update-workflow" -TimeoutSeconds 3600)
    if ((Get-WorkflowLockCommit -Root $ProjectRoot) -ne $candidateCommit) { throw "update-workflow did not install the exact develop candidate." }
    [void](Commit-StandUpdate -Root $ProjectRoot -Message "test: install develop journey candidate")
    [void](Invoke-InstalledAction -Name "upgrade-refresh-branch" -Root $standBranchRoot -Action "refresh-dev-branch" -TimeoutSeconds 5400)
    [void](Assert-FreshVerificationResult -ProcessResult (Invoke-InstalledAction -Name "upgrade-check" -Root $standBranchRoot -Action "check-dev-branch" -TimeoutSeconds 5400))
    [void](Assert-ExportResult -ProcessResult (Invoke-InstalledAction -Name "upgrade-export" -Root $standBranchRoot -Action "export-dev-branch-result" -TimeoutSeconds 3600))
    if ((Get-WorkflowLockCommit -Root $standBranchRoot) -ne $candidateCommit) { throw "Refreshed branch did not receive the exact develop candidate." }
    Assert-TrackedClean -Root $standBranchRoot -Label "Develop E2E branch after upgrade journey"

    New-Item -ItemType Directory -Force -Path $FreshProjectsRoot | Out-Null
    $cyrillicPathSegment = -join ([char[]](0x041F, 0x0440, 0x043E, 0x0435, 0x043A, 0x0442))
    $specialProjectsRoot = Join-Path ([IO.Path]::GetFullPath($FreshProjectsRoot)) "p $cyrillicPathSegment"
    $freshRoot = Join-Path $specialProjectsRoot ("d-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    if ($freshRoot -notmatch '\s' -or $freshRoot -notmatch '[^\x00-\x7F]') {
        throw "DEVELOP_E2E_SPECIAL_PATH_REQUIRED: fresh project root must contain both whitespace and non-ASCII text: '$freshRoot'."
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $freshRoot ".agent-1c") | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectRoot ".agent-1c\project.json") -Destination (Join-Path $freshRoot ".agent-1c\project.json")
    $envLines = @([IO.File]::ReadAllLines((Join-Path $ProjectRoot ".dev.env"), [Text.Encoding]::UTF8) | Where-Object { $_ -notmatch '^(INFOBASE_PATH|INFOBASE_PUBLISH_URL|ITL_ACTIVE_|ROCTUP_MCP_|VANESSA_MCP_|VANESSA_TEST_PORT|SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE)=' })
    $envLines += "SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed"
    [IO.File]::WriteAllText((Join-Path $freshRoot ".dev.env"), (($envLines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [void](Invoke-DevelopProcess -Name "fresh-bootstrap-init-project" -WorkingRoot $freshRoot -ScriptPath (Join-Path $CandidateRoot "install-agent-1c-workflow.ps1") -Arguments @("-ProjectRoot", $freshRoot, "-SourceRoot", $CandidateRoot, "-InitMode", "configured", "-AgentTarget", "kilocode", "-SkipWorkflowSourceFreshnessCheck") -TimeoutSeconds 5400)
    Assert-InitializedProject -Root $freshRoot
    $freshHelper = Join-Path $freshRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    Assert-ProjectStatusOutput -ProcessResult (Invoke-DevelopProcess -Name "fresh-status" -WorkingRoot $freshRoot -ScriptPath $freshHelper -Arguments @("-ProjectRoot", $freshRoot, "-Action", "status") -TimeoutSeconds 120)
    $branchName = "develop-golden"
    $cyrillicBranchSegment = -join ([char[]](0x0432, 0x0435, 0x0442, 0x043A, 0x0430))
    $freshBranchRoot = Join-Path ([IO.Path]::GetFullPath($FreshProjectsRoot)) ("b-$cyrillicBranchSegment-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    if ($freshBranchRoot -match '\s' -or $freshBranchRoot -notmatch '[^\x00-\x7F]') {
        throw "DEVELOP_E2E_SPECIAL_BRANCH_PATH_REQUIRED: fresh branch root must contain non-ASCII text without whitespace: '$freshBranchRoot'."
    }
    [void](Invoke-InstalledAction -Name "fresh-new-dev-branch" -Root $freshRoot -Action "new-dev-branch" -AdditionalArguments @("-DevBranchName", $branchName, "-DevBranchWorktreePath", $freshBranchRoot) -TimeoutSeconds 3600)
    $requestedFreshBranchRoot = $freshBranchRoot
    $freshBranchRoot = Get-BranchWorktree -Root $freshRoot -Name $branchName
    if ([IO.Path]::GetFullPath($freshBranchRoot) -ne [IO.Path]::GetFullPath($requestedFreshBranchRoot)) {
        throw "new-dev-branch ignored the requested special branch path: requested='$requestedFreshBranchRoot'; actual='$freshBranchRoot'."
    }
    [void](Assert-FailedRecoveryRoute -ProcessResult (Invoke-InstalledAction -Name "fresh-missing-suite" -Root $freshBranchRoot -Action "check-dev-branch" -TimeoutSeconds 300 -AllowFailure) -ExpectedCategory "missing-suite")
    Set-FreshConfigurationComment -Root $freshBranchRoot
    Add-FreshVanessaFeature -Root $freshBranchRoot
    & git -C $freshBranchRoot add -- src/cf/Configuration.xml tests/features/ITLDevelopJourney.feature
    & git -C $freshBranchRoot commit -m "test: add develop golden change" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the fresh develop journey change." }
    [void](Assert-FreshVerificationResult -ProcessResult (Invoke-InstalledAction -Name "fresh-check" -Root $freshBranchRoot -Action "check-dev-branch" -TimeoutSeconds 5400))
    [IO.File]::AppendAllText((Join-Path $freshBranchRoot "tests\features\ITLDevelopJourney.feature"), "`n# stale verification boundary`n", [Text.UTF8Encoding]::new($false))
    & git -C $freshBranchRoot add -- tests/features/ITLDevelopJourney.feature
    & git -C $freshBranchRoot commit -m "test: make verification stale" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the stale-verification boundary." }
    [void](Assert-FailedRecoveryRoute -ProcessResult (Invoke-InstalledAction -Name "fresh-stale-export" -Root $freshBranchRoot -Action "export-dev-branch-result" -TimeoutSeconds 300 -AllowFailure))
    [void](Assert-FreshVerificationResult -ProcessResult (Invoke-InstalledAction -Name "fresh-recovery-check" -Root $freshBranchRoot -Action "check-dev-branch" -TimeoutSeconds 5400))
    [void](Assert-ExportResult -ProcessResult (Invoke-InstalledAction -Name "fresh-export" -Root $freshBranchRoot -Action "export-dev-branch-result" -TimeoutSeconds 3600))
    [IO.File]::WriteAllText((Join-Path $freshRoot "develop-journey.txt"), "refresh boundary" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    & git -C $freshRoot add develop-journey.txt
    & git -C $freshRoot commit -m "test: advance develop journey master" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to advance fresh journey master." }
    [void](Invoke-InstalledAction -Name "fresh-refresh-lite" -Root $freshBranchRoot -Action "refresh-dev-branch-lite" -TimeoutSeconds 5400)
    [void](Assert-FreshVerificationResult -ProcessResult (Invoke-InstalledAction -Name "fresh-recheck" -Root $freshBranchRoot -Action "check-dev-branch" -TimeoutSeconds 5400))
    [void](Invoke-InstalledAction -Name "fresh-close" -Root $freshBranchRoot -Action "close-dev-branch" -TimeoutSeconds 3600)
    Remove-DevelopE2EFreshProject -FreshProjectsRoot $FreshProjectsRoot -Path $freshRoot -BranchPath $freshBranchRoot
    $freshBranchRoot = ""
    $freshRoot = ""
} catch {
    $failure = $_.Exception.Message
} finally {
    $env:ITL_WORKFLOW_SOURCE_PATH = $previousWorkflowSource
    $env:ITL_AI_RULES_SOURCE_PATH = $previousRulesSource
    $payload = [ordered]@{
        schemaVersion = 1
        kind = "itl-develop-e2e"
        status = $(if ($failure) { "failed" } else { "passed" })
        candidate = [ordered]@{ commit = $candidateCommit; tree = $candidateTree }
        projectRoot = $ProjectRoot
        freshProjectRoot = $freshRoot
        freshBranchRoot = $freshBranchRoot
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        steps = @($steps | ForEach-Object { $_ })
        error = $failure
    }
    [IO.File]::WriteAllText($OutputPath, (($payload | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

if ($failure) { [Console]::Error.WriteLine($failure); exit 1 }
Write-Host "Develop E2E passed: $OutputPath"
