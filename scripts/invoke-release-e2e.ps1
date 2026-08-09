[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$AiRulesSource,
    [string]$HelperPath = "",
    [string]$OutputPath = "",
    [ValidateSet("Auto", "Restart")]
    [string]$ResumeMode = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$AiRulesSource = [System.IO.Path]::GetFullPath($AiRulesSource)
if (-not (Test-Path -LiteralPath $AiRulesSource -PathType Container)) {
    throw "Release ai_rules source is missing: $AiRulesSource"
}
$configPath = Join-Path $ProjectRoot ".agent-1c\release-e2e.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Dedicated E2E stand config is missing: $configPath. Start from templates/release-e2e.example.json."
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$devBranchName = [string]$config.devBranchName
$worktreePath = [System.IO.Path]::GetFullPath([string]$config.worktreePath)
if (-not $devBranchName -or -not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
    throw "release-e2e.json must contain an existing worktreePath and devBranchName."
}

function Get-E2EDotEnvValue {
    param([string]$Name)

    $dotEnvPath = Join-Path $ProjectRoot ".dev.env"
    if (-not (Test-Path -LiteralPath $dotEnvPath -PathType Leaf)) {
        throw "Dedicated E2E stand .dev.env is missing: $dotEnvPath"
    }

    foreach ($line in Get-Content -LiteralPath $dotEnvPath -Encoding UTF8) {
        if ($line -match "^$([regex]::Escape($Name))=(.*)$") {
            return ([string]$Matches[1]).Trim().Trim('"')
        }
    }

    return ""
}

function Set-E2EDotEnvValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    $replacement = "$Name=$Value"
    $pattern = "^\s*$([regex]::Escape($Name))\s*="
    $lines = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))
    } else {
        @()
    }
    $updated = [System.Collections.Generic.List[string]]::new()
    $replaced = $false
    foreach ($line in $lines) {
        if ([string]$line -match $pattern) {
            if (-not $replaced) {
                $updated.Add($replacement) | Out-Null
                $replaced = $true
            }
            continue
        }
        $updated.Add([string]$line) | Out-Null
    }
    if (-not $replaced) {
        $updated.Add($replacement) | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        (($updated -join [Environment]::NewLine) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

$sourceSnapshotValue = Get-E2EDotEnvValue -Name "SOURCE_INFOBASE_PATH"
if (-not $sourceSnapshotValue) {
    throw "Dedicated E2E stand must define SOURCE_INFOBASE_PATH for its disposable source snapshot."
}
$sourceSnapshotPath = if ([System.IO.Path]::IsPathRooted($sourceSnapshotValue)) {
    [System.IO.Path]::GetFullPath($sourceSnapshotValue)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $sourceSnapshotValue))
}
$projectPrefix = $ProjectRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
if (-not $sourceSnapshotPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Dedicated E2E stand SOURCE_INFOBASE_PATH must be a disposable snapshot inside the stand: $sourceSnapshotPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceSnapshotPath "1Cv8.1CD") -PathType Leaf)) {
    throw "Dedicated E2E source snapshot does not contain 1Cv8.1CD: $sourceSnapshotPath"
}
if (-not $HelperPath) {
    $HelperPath = Join-Path $worktreePath ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
}
$HelperPath = [System.IO.Path]::GetFullPath($HelperPath)
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw "ITL helper was not found for the E2E stand: $HelperPath"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $ProjectRoot "build\test-results\release-e2e\release-e2e-summary.json"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputRoot = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$startedAt = [DateTime]::UtcNow
$failure = $null
$cleanupFailures = @()
$resultManifestPath = ""
$artifactPath = ""
$artifactSha256 = ""
$verifiedAt = ""
$verifiedCommit = ""
$fixtureCommit = ""
$vanessaFixtureCommit = ""
$testOnlyCommit = ""
$stopOnErrorProbeCommit = ""
$stopOnErrorRecoveryCommit = ""
$secondMetadataCommit = ""
$stopOnErrorProbeTests = 0
$stopOnErrorProbeFailures = 0
$stopOnErrorProbeErrors = 0
$partialConfigDumpInfoCommit = ""
$recoveryConfigDumpInfoCommit = ""
$vanessaJUnitTests = 0
$vanessaPostProcessDurationMs = 0
$expectedComment = ""
$roundtripEvidencePath = ""
$roundtripEvidence = $null
$extensionSmokeEvidencePath = ""
$extensionSmokeEvidence = $null
$onDemandMcpEvidencePath = Join-Path $outputRoot "ondemand-mcp.json"
$onDemandMcpEvidence = $null
$onDemandMaxConcurrentSessions = 0
$onDemandOwnedProcessExitWaitMs = 0
$onDemandMcpTestFixture = [Environment]::GetEnvironmentVariable("ITL_TEST_RELEASE_ONDEMAND_PROBE") -eq "true"
$configCadenceEvidencePath = Join-Path $outputRoot "config-cadence.json"
$seedParallelEvidencePath = Join-Path $outputRoot "seed-parallel.json"
$seedParallelEvidence = $null
$seedParallelTestFixture = [Environment]::GetEnvironmentVariable("ITL_TEST_RELEASE_SEED_PARALLEL") -eq "true"
$extensionSmokeName = "ITLReleaseSmoke" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-E2EHelperAtRoot {
    param(
        [string]$Root,
        [string]$BranchName,
        [string]$Action,
        [string[]]$AdditionalArguments = @(),
        [string]$LogPrefix = ""
    )
    if (-not $LogPrefix) { $LogPrefix = $Action }
    $stdoutPath = Join-Path $outputRoot ($LogPrefix + ".stdout.log")
    $stderrPath = Join-Path $outputRoot ($LogPrefix + ".stderr.log")
    $parts = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (ConvertTo-NativeArgument $HelperPath),
        "-ProjectRoot", (ConvertTo-NativeArgument $Root),
        "-Action", (ConvertTo-NativeArgument $Action)
    )
    if ($BranchName) {
        $parts += @("-DevBranchName", (ConvertTo-NativeArgument $BranchName))
    }
    foreach ($argument in @($AdditionalArguments)) {
        $parts += (ConvertTo-NativeArgument ([string]$argument))
    }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($parts -join " ") `
        -WorkingDirectory $Root -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath -PassThru
    $startedAtUtc = [DateTime]::UtcNow
    try {
        $processStartTime = $process.StartTime
        if ($null -ne $processStartTime) {
            $startedAtUtc = $processStartTime.ToUniversalTime()
        }
    } catch {}
    return [pscustomobject]@{
        process = $process
        action = $Action
        root = $Root
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        startedAtUtc = $startedAtUtc
        exitedAtUtc = $null
    }
}

function Complete-E2EHelperProcess {
    param(
        [object]$Invocation,
        [int]$TimeoutSeconds,
        [switch]$AllowFailure
    )
    $process = $Invocation.process
    # Windows PowerShell 5.1 may expose a null ExitCode after timed WaitForExit
    # unless the native process handle is materialized before the wait.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        if ($AllowFailure) { return [pscustomobject]@{ exitCode = -1; stdoutPath = $Invocation.stdoutPath; stderrPath = $Invocation.stderrPath } }
        throw "$($Invocation.action) timed out after $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitedAtUtc = [DateTime]::UtcNow
    try {
        $processExitTime = $process.ExitTime
        if ($null -ne $processExitTime) {
            $exitedAtUtc = $processExitTime.ToUniversalTime()
        }
    } catch {}
    $Invocation.exitedAtUtc = $exitedAtUtc
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$($Invocation.action) failed with exit code $exitCode. See $($Invocation.stdoutPath) and $($Invocation.stderrPath)"
    }
    return [pscustomobject]@{ exitCode = $exitCode; stdoutPath = $Invocation.stdoutPath; stderrPath = $Invocation.stderrPath }
}

function Test-E2EInvocationOverlap {
    param([object[]]$Invocations)

    if (@($Invocations).Count -ne 2) { return $false }
    $first = $Invocations[0]
    $second = $Invocations[1]
    if ($null -eq $first.startedAtUtc -or $null -eq $first.exitedAtUtc -or
        $null -eq $second.startedAtUtc -or $null -eq $second.exitedAtUtc) {
        return $false
    }
    return (
        ([DateTime]$first.startedAtUtc) -lt ([DateTime]$second.exitedAtUtc) -and
        ([DateTime]$second.startedAtUtc) -lt ([DateTime]$first.exitedAtUtc)
    )
}

function Assert-E2ELiteRefreshDidNotEnterSourceSync {
    param([object[]]$Invocations)

    foreach ($invocation in @($Invocations)) {
        $text = @(
            $(if (Test-Path -LiteralPath $invocation.stdoutPath -PathType Leaf) { Get-Content -LiteralPath $invocation.stdoutPath -Raw -Encoding UTF8 }),
            $(if (Test-Path -LiteralPath $invocation.stderrPath -PathType Leaf) { Get-Content -LiteralPath $invocation.stderrPath -Raw -Encoding UTF8 })
        ) -join [Environment]::NewLine
        if ($text -match '(?im)^==\s*Sync master\s*==\s*$|^Branch seed(?: sync ID)?:') {
            throw "Lite refresh entered a source/master seed synchronization stage. Log: $($invocation.stdoutPath)"
        }
    }
}

function Invoke-E2EHelperAtRoot {
    param(
        [string]$Root,
        [string]$BranchName,
        [string]$Action,
        [int]$TimeoutSeconds,
        [string[]]$AdditionalArguments = @(),
        [string]$LogPrefix = "",
        [switch]$AllowFailure
    )
    $invocation = Start-E2EHelperAtRoot `
        -Root $Root `
        -BranchName $BranchName `
        -Action $Action `
        -AdditionalArguments $AdditionalArguments `
        -LogPrefix $LogPrefix
    return (Complete-E2EHelperProcess -Invocation $invocation -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure)
}

function Invoke-E2EHelper {
    param(
        [string]$Action,
        [int]$TimeoutSeconds,
        [string[]]$AdditionalArguments = @(),
        [switch]$AllowFailure
    )
    return (Invoke-E2EHelperAtRoot `
        -Root $worktreePath `
        -BranchName $devBranchName `
        -Action $Action `
        -TimeoutSeconds $TimeoutSeconds `
        -AdditionalArguments $AdditionalArguments `
        -AllowFailure:$AllowFailure)
}

function Get-E2ERootConfigurationComment {
    param([Parameter(Mandatory = $true)][string]$Path)

    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($Path)
    $nodes = @($document.SelectNodes("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Comment']"))
    if ($nodes.Count -ne 1) {
        throw "Expected exactly one root Configuration/Properties/Comment node in '$Path'; found $($nodes.Count)."
    }
    return [string]$nodes[0].InnerText
}

function New-E2ERootConfigurationCommentCommit {
    $configurationPath = Join-Path $worktreePath "src\cf\Configuration.xml"
    $parentConfigurationsPath = Join-Path $worktreePath "src\cf\Ext\ParentConfigurations.bin"
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        throw "Release E2E root Configuration.xml is missing: $configurationPath"
    }
    if (-not (Test-Path -LiteralPath $parentConfigurationsPath -PathType Leaf)) {
        throw "Release E2E requires src/cf/Ext/ParentConfigurations.bin: $parentConfigurationsPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($configurationPath)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = New-Object System.Text.UTF8Encoding $hasUtf8Bom
    $original = [System.IO.File]::ReadAllText($configurationPath, $encoding)
    [void](Get-E2ERootConfigurationComment -Path $configurationPath)

    $commentPattern = New-Object System.Text.RegularExpressions.Regex(
        '<Comment(?<attributes>\s[^>]*)?\s*/>|<Comment(?<attributes>\s[^>]*)?>(?<value>.*?)</Comment>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $matches = $commentPattern.Matches($original)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one textual Comment element in root Configuration.xml; found $($matches.Count)."
    }

    $newComment = "ITL release E2E partial root roundtrip " + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    $escapedComment = [System.Security.SecurityElement]::Escape($newComment)
    $match = $matches[0]
    if ($match.Value -match '/>\s*$') {
        $attributes = [string]$match.Groups["attributes"].Value
        $replacement = "<Comment$attributes>$escapedComment</Comment>"
    } else {
        $openingEnd = $match.Value.IndexOf('>')
        $closingStart = $match.Value.LastIndexOf('</Comment>', [System.StringComparison]::Ordinal)
        $replacement = $match.Value.Substring(0, $openingEnd + 1) + $escapedComment + $match.Value.Substring($closingStart)
    }
    $updated = $commentPattern.Replace($original, $replacement, 1)
    if ($commentPattern.Replace($updated, $match.Value, 1) -cne $original) {
        throw "Release E2E edit would change content outside root Configuration Comment."
    }
    [System.IO.File]::WriteAllText($configurationPath, $updated, $encoding)
    if ((Get-E2ERootConfigurationComment -Path $configurationPath) -cne $newComment) {
        throw "Release E2E failed to persist the new root Configuration Comment."
    }

    $changedPaths = @(& git -C $worktreePath diff --name-only --)
    if ($LASTEXITCODE -ne 0 -or $changedPaths.Count -ne 1 -or [string]$changedPaths[0] -ne "src/cf/Configuration.xml") {
        throw "Release E2E must change only src/cf/Configuration.xml; changed: $($changedPaths -join ', ')"
    }
    & git -C $worktreePath add -- src/cf/Configuration.xml | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to stage the release E2E Configuration.xml change." }
    $stagedPaths = @(& git -C $worktreePath diff --cached --name-only --)
    if ($stagedPaths.Count -ne 1 -or [string]$stagedPaths[0] -ne "src/cf/Configuration.xml") {
        throw "Release E2E staged paths are not limited to root Configuration.xml: $($stagedPaths -join ', ')"
    }
    & git -C $worktreePath commit -m "test: release E2E partial root Configuration roundtrip" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the release E2E Configuration.xml fixture change." }
    if (@(& git -C $worktreePath status --porcelain).Count -gt 0) {
        throw "E2E worktree is dirty after committing the root Configuration.xml fixture."
    }

    $commit = (& git -C $worktreePath rev-parse HEAD).Trim()
    Register-E2EGeneratedCommit -Kind "configuration-comment" -Commit $commit
    return [pscustomobject]@{
        commit = $commit
        comment = $newComment
        configurationPath = $configurationPath
        parentConfigurationsPath = $parentConfigurationsPath
    }
}

function Save-E2EConfigDumpInfoCursorCommit {
    param([string]$Phase)

    $repoPath = "src/cf/ConfigDumpInfo.xml"
    $absolutePath = Join-Path $worktreePath $repoPath.Replace("/", "\")
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Release E2E ConfigDumpInfo cursor is missing after $Phase metadata check: $absolutePath"
    }

    & git -C $worktreePath diff --quiet -- $repoPath
    $diffExitCode = $LASTEXITCODE
    if ($diffExitCode -eq 0) {
        return ""
    }
    if ($diffExitCode -ne 1) {
        throw "Unable to inspect the Release E2E ConfigDumpInfo cursor after $Phase metadata check."
    }
    & git -C $worktreePath diff --cached --quiet --
    if ($LASTEXITCODE -ne 0) {
        throw "Release E2E found unexpected staged changes before persisting the $Phase ConfigDumpInfo cursor."
    }

    & git -C $worktreePath add -- $repoPath
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to stage the Release E2E $Phase ConfigDumpInfo cursor."
    }
    & git -C $worktreePath commit -m "test: persist release E2E $Phase ConfigDumpInfo cursor" -- $repoPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to commit the Release E2E $Phase ConfigDumpInfo cursor."
    }
    if (@(& git -C $worktreePath status --porcelain --untracked-files=all).Count -gt 0) {
        throw "E2E worktree is dirty after committing the $Phase ConfigDumpInfo cursor."
    }

    $commit = (& git -C $worktreePath rev-parse HEAD).Trim()
    Register-E2EGeneratedCommit -Kind "config-dump-info-$Phase" -Commit $commit
    return $commit
}

function New-E2EVanessaFixtureCommit {
    $featurePath = Join-Path $worktreePath "tests\features\ITLReleaseFourFlat.feature"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $featurePath) | Out-Null
    # Keep the PowerShell 5.1 script source ASCII-safe; otherwise Cyrillic literals in a
    # UTF-8-without-BOM .ps1 are decoded through the active ANSI code page before writing.
    $featureBase64 = 'I2xhbmd1YWdlOiBydQoKQGl0bF9yZWxlYXNlX2ZsYXQK0KTRg9C90LrRhtC40L7QvdCw0Ls6INCn0LXRgtGL0YDQtSDQvdC10LfQsNCy0LjRgdC40LzRi9GFIHJlbGVhc2Ut0YHRhtC10L3QsNGA0LjRjwoK0JrQvtC90YLQtdC60YHRgjoKCdCU0LDQvdC+INCvINC30LDQv9GD0YHQutCw0Y4g0YHRhtC10L3QsNGA0LjQuSDQvtGC0LrRgNGL0YLQuNGPIFRlc3RDbGllbnQg0LjQu9C4INC/0L7QtNC60LvRjtGH0LDRjiDRg9C20LUg0YHRg9GJ0LXRgdGC0LLRg9GO0YnQuNC5CgrQodGG0LXQvdCw0YDQuNC5OiBSZWxlYXNlIHNjZW5hcmlvIG9uZQoJ0Jgg0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LUKCSIiImJzbAoJCdCV0YHQu9C4INCb0L7QttGMINCi0L7Qs9C00LAg0JLRi9C30LLQsNGC0YzQmNGB0LrQu9GO0YfQtdC90LjQtSAib25lIjsg0JrQvtC90LXRhtCV0YHQu9C4OwoJIiIiCgrQodGG0LXQvdCw0YDQuNC5OiBSZWxlYXNlIHNjZW5hcmlvIHR3bwoJ0Jgg0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LUKCSIiImJzbAoJCdCV0YHQu9C4INCb0L7QttGMINCi0L7Qs9C00LAg0JLRi9C30LLQsNGC0YzQmNGB0LrQu9GO0YfQtdC90LjQtSAidHdvIjsg0JrQvtC90LXRhtCV0YHQu9C4OwoJIiIiCgrQodGG0LXQvdCw0YDQuNC5OiBSZWxlYXNlIHNjZW5hcmlvIHRocmVlCgnQmCDRjyDQstGL0L/QvtC70L3Rj9GOINC60L7QtCDQstGB0YLRgNC+0LXQvdC90L7Qs9C+INGP0LfRi9C60LAg0L3QsCDRgdC10YDQstC10YDQtQoJIiIiYnNsCgkJ0JXRgdC70Lgg0JvQvtC20Ywg0KLQvtCz0LTQsCDQktGL0LfQstCw0YLRjNCY0YHQutC70Y7Rh9C10L3QuNC1ICJ0aHJlZSI7INCa0L7QvdC10YbQldGB0LvQuDsKCSIiIgoK0KHRhtC10L3QsNGA0LjQuTogUmVsZWFzZSBzY2VuYXJpbyBmb3VyCgnQmCDRjyDQstGL0L/QvtC70L3Rj9GOINC60L7QtCDQstGB0YLRgNC+0LXQvdC90L7Qs9C+INGP0LfRi9C60LAg0L3QsCDRgdC10YDQstC10YDQtQoJIiIiYnNsCgkJ0JXRgdC70Lgg0JvQvtC20Ywg0KLQvtCz0LTQsCDQktGL0LfQstCw0YLRjNCY0YHQutC70Y7Rh9C10L3QuNC1ICJmb3VyIjsg0JrQvtC90LXRhtCV0YHQu9C4OwoJIiIi'
    [System.IO.File]::WriteAllBytes($featurePath, [System.Convert]::FromBase64String($featureBase64))
    & git -C $worktreePath add -- tests/features/ITLReleaseFourFlat.feature | Out-Null
    & git -C $worktreePath commit -m "test: add four flat Vanessa release scenarios" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the four-scenario Vanessa release fixture." }
    $commit = (& git -C $worktreePath rev-parse HEAD).Trim()
    Register-E2EGeneratedCommit -Kind "vanessa-fixture" -Commit $commit
    return [pscustomobject]@{ path = $featurePath; commit = $commit }
}

function Add-E2ETestOnlyCommit {
    param([string]$FeaturePath)
    [System.IO.File]::AppendAllText($FeaturePath, "`n# test-only release iteration " + [DateTime]::UtcNow.ToString("o") + "`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $worktreePath add -- tests/features/ITLReleaseFourFlat.feature | Out-Null
    & git -C $worktreePath commit -m "test: exercise test-only verification iteration" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the test-only release fixture change." }
    return (& git -C $worktreePath rev-parse HEAD).Trim()
}

function Set-E2EVanessaFailureProbeCommit {
    param(
        [Parameter(Mandatory = $true)][string]$FeaturePath,
        [Parameter(Mandatory = $true)][bool]$Fail
    )

    $falseCondition = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('0JXRgdC70Lgg0JvQvtC20Yw='))
    $trueCondition = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('0JXRgdC70Lgg0JjRgdGC0LjQvdCw'))
    $from = if ($Fail) { $falseCondition } else { $trueCondition }
    $to = if ($Fail) { $trueCondition } else { $falseCondition }
    $feature = [System.IO.File]::ReadAllText($FeaturePath, [System.Text.Encoding]::UTF8)
    $position = $feature.IndexOf($from, [System.StringComparison]::Ordinal)
    if ($position -lt 0) {
        throw "Unable to toggle the first Vanessa release scenario for the stop-on-error probe."
    }
    $feature = $feature.Substring(0, $position) + $to + $feature.Substring($position + $from.Length)
    [System.IO.File]::WriteAllText($FeaturePath, $feature, [System.Text.UTF8Encoding]::new($false))
    & git -C $worktreePath add -- tests/features/ITLReleaseFourFlat.feature | Out-Null
    $message = if ($Fail) { "test: probe Vanessa stop-on-error behavior" } else { "test: restore passing Vanessa release fixture" }
    & git -C $worktreePath commit -m $message | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit the Vanessa stop-on-error probe transition." }
    $commit = (& git -C $worktreePath rev-parse HEAD).Trim()
    Register-E2EGeneratedCommit -Kind $(if ($Fail) { "vanessa-failure-probe" } else { "vanessa-recovery" }) -Commit $commit
    return $commit
}

function Get-E2EJunitTotals {
    param([string]$RunDirectory)
    $totals = [ordered]@{ tests = 0; failures = 0; errors = 0 }
    foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue)) {
        $xml = New-Object System.Xml.XmlDocument; $xml.Load($file.FullName)
        $nodes = @($xml.SelectNodes('//*[local-name()="testsuite" and not(ancestor::*[local-name()="testsuite"])]'))
        if ($nodes.Count -eq 0 -and $xml.DocumentElement.LocalName -eq "testsuites") { $nodes = @($xml.DocumentElement) }
        foreach ($node in $nodes) {
            foreach ($name in @("tests", "failures", "errors")) {
                if ($node.Attributes[$name]) { $totals[$name] += [int]$node.Attributes[$name].Value }
            }
        }
    }
    return [pscustomobject]$totals
}

function Get-E2EState {
    $roots = @($ProjectRoot, $worktreePath) | Select-Object -Unique
    $expectedBranch = "itldev/$devBranchName"
    $expectedWorktree = $worktreePath.TrimEnd('\', '/')
    foreach ($root in $roots) {
        $stateRoot = Join-Path $root ".agent-1c\dev-branches"
        $candidates = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
            try {
                $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$state.devBranchName -eq $devBranchName -or [string]$state.devBranch -eq $expectedBranch) {
                    $candidates += [pscustomobject]@{ value = $state; path = $file.FullName }
                }
            } catch {}
        }
        if ($candidates.Count -eq 0) { continue }

        $matching = @($candidates | Where-Object {
            $stateWorktree = ""
            try { $stateWorktree = [System.IO.Path]::GetFullPath([string]$_.value.worktreePath).TrimEnd('\', '/') } catch {}
            [string]$_.value.devBranchName -ceq $devBranchName -and
                [string]$_.value.devBranch -ceq $expectedBranch -and
                $stateWorktree.Equals($expectedWorktree, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($matching.Count -eq 1) { return $matching[0] }
        if ($matching.Count -gt 1) {
            throw "RELEASE_E2E_BRANCH_STATE_CONTEXT_MISMATCH: multiple branch states match devBranchName='$devBranchName', devBranch='$expectedBranch', worktreePath='$worktreePath': $(@($matching.path) -join ', ')"
        }
        throw "RELEASE_E2E_BRANCH_STATE_CONTEXT_MISMATCH: branch state under '$stateRoot' does not exactly match devBranchName='$devBranchName', devBranch='$expectedBranch', worktreePath='$worktreePath'. Refusing to use state from another context."
    }
    throw "Development branch state was not found for E2E branch '$devBranchName'."
}

function Assert-E2EUnsafeActionProtectionConfirmed {
    $stateRecord = Get-E2EState
    $property = $stateRecord.value.PSObject.Properties["unsafeActionProtectionConfirmed"]
    if ($null -eq $property -or $property.Value -isnot [bool] -or -not [bool]$property.Value) {
        throw "RELEASE_E2E_UNSAFE_ACTION_PROTECTION_UNCONFIRMED: branch='$($stateRecord.value.devBranch)'; worktree='$worktreePath'; state='$($stateRecord.path)'; required=unsafeActionProtectionConfirmed:true. Run the monitored configure-dev-branch-unsafe-action-protection action for this worktree, complete its explicit confirmation, then rerun Release. This preflight does not confirm automatically or edit state/conf.cfg."
    }
    return $stateRecord
}

function ConvertTo-E2EHashtable {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-E2EHashtable $Value[$key] }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-E2EHashtable $property.Value }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-E2EHashtable $_ })
    }
    return $Value
}

function Get-E2EFileSha256 {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$safeRunName = ($devBranchName -replace '[^A-Za-z0-9_.-]', '_')
$preferredReleaseRunRoot = Join-Path $worktreePath ".agent-1c\runs\release-e2e\$safeRunName"
$legacyReleaseRunRoot = Join-Path $worktreePath ".agent-1c\release-e2e-runs\$safeRunName"
$capabilityCacheRoot = Join-Path $worktreePath ".agent-1c\runs\release-e2e-capabilities\$safeRunName"
$usingLegacyRunRoot = $false

function Set-E2ERunPaths {
    param([string]$Root)
    $script:releaseRunRoot = $Root
    $script:checkpointPath = Join-Path $Root "checkpoint.json"
    $script:baselineSnapshotPath = Join-Path $Root "snapshots\baseline.dt"
    $script:postConfigSnapshotPath = Join-Path $Root "snapshots\post-config.dt"
    $script:baselineStateCopyPath = Join-Path $Root "state\baseline.json"
    $script:baselineEnvCopyPath = Join-Path $Root "state\baseline.env"
    $script:postConfigStateCopyPath = Join-Path $Root "state\post-config.json"
    $script:postConfigEnvCopyPath = Join-Path $Root "state\post-config.env"
}

Set-E2ERunPaths -Root $preferredReleaseRunRoot
if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $legacyReleaseRunRoot "checkpoint.json") -PathType Leaf)) {
    Set-E2ERunPaths -Root $legacyReleaseRunRoot
    $usingLegacyRunRoot = $true
}
$checkpoint = $null
$checkpointWasResumed = $false
$resumedStages = @()
$executedStages = @()
$invalidatedStages = @()
$crossReleaseReuse = $false
$previousWorkflowCommit = ""
$previousRunnerSha256 = ""
$releaseContinuationProof = $null
$continuationBoundaryStage = ""
$promotedCapabilityPath = ""
$stageTimers = @{}

function Write-E2ECheckpoint {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkpointPath) | Out-Null
    $checkpoint["updatedAt"] = [DateTime]::UtcNow.ToString("o")
    [System.IO.File]::WriteAllText($checkpointPath, (($checkpoint | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Register-E2EGeneratedCommit {
    param([string]$Kind, [string]$Commit)
    if ($null -eq $checkpoint) { throw "Release E2E checkpoint is not initialized before generated commit '$Commit'." }
    $records = @()
    if ($checkpoint.Contains("generatedCommits")) { $records = @($checkpoint["generatedCommits"]) }
    $checkpoint["generatedCommits"] = @($records + [ordered]@{
        kind = $Kind
        commit = $Commit
        recordedAt = [DateTime]::UtcNow.ToString("o")
    })
    $checkpoint["expectedHead"] = $Commit
    Write-E2ECheckpoint
}

function Assert-E2ECheckpointFile {
    param([string]$Path, [string]$Sha256, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-E2EFileSha256 -Path $Path) -ne $Sha256) {
        throw "RELEASE_E2E_RESUME_STATE_MISMATCH: $Label is missing or its SHA256 changed: $Path"
    }
}

function Save-E2EStateFiles {
    param([string]$StateCopyPath, [string]$EnvCopyPath)
    $stateRecord = Get-E2EState
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StateCopyPath) | Out-Null
    Copy-Item -LiteralPath $stateRecord.path -Destination $StateCopyPath -Force
    $envPath = Join-Path $worktreePath ".dev.env"
    if (Test-Path -LiteralPath $envPath -PathType Leaf) { Copy-Item -LiteralPath $envPath -Destination $EnvCopyPath -Force }
    return [ordered]@{
        actualStatePath = $stateRecord.path
        stateCopyPath = $StateCopyPath
        stateSha256 = Get-E2EFileSha256 -Path $StateCopyPath
        actualEnvPath = $envPath
        envCopyPath = $(if (Test-Path -LiteralPath $EnvCopyPath -PathType Leaf) { $EnvCopyPath } else { "" })
        envSha256 = Get-E2EFileSha256 -Path $EnvCopyPath
    }
}

function Restore-E2EStateFiles {
    param([object]$Record)
    Assert-E2ECheckpointFile -Path ([string]$Record.stateCopyPath) -Sha256 ([string]$Record.stateSha256) -Label "saved branch state"
    $actualStatePath = [string](Get-E2EState).path
    $actualEnvPath = Join-Path $worktreePath ".dev.env"
    Copy-Item -LiteralPath ([string]$Record.stateCopyPath) -Destination $actualStatePath -Force
    if ($script:e2eUnsafeActionProtectionConfirmation) {
        $restoredState = Get-Content -LiteralPath $actualStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @($script:e2eUnsafeActionProtectionConfirmation.Keys)) {
            $property = $restoredState.PSObject.Properties[$name]
            if ($null -eq $property) {
                $restoredState | Add-Member -NotePropertyName $name -NotePropertyValue $script:e2eUnsafeActionProtectionConfirmation[$name]
            } else {
                $property.Value = $script:e2eUnsafeActionProtectionConfirmation[$name]
            }
        }
        [IO.File]::WriteAllText(
            $actualStatePath,
            (($restoredState | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
    }
    if ([string]$Record.envCopyPath) {
        Assert-E2ECheckpointFile -Path ([string]$Record.envCopyPath) -Sha256 ([string]$Record.envSha256) -Label "saved .dev.env"
        Copy-Item -LiteralPath ([string]$Record.envCopyPath) -Destination $actualEnvPath -Force
    }
}

function Invoke-E2EInfobaseSnapshot {
    param([string]$Path)
    $relative = $Path.Substring($worktreePath.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    Invoke-E2EHelper -Action "release-e2e-snapshot" -TimeoutSeconds 7200 -AdditionalArguments @("-ReleaseSnapshotPath", $relative) | Out-Null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Release E2E snapshot helper did not create: $Path" }
    return [ordered]@{ path = $Path; sha256 = Get-E2EFileSha256 -Path $Path }
}

function Restore-E2EInfobaseSnapshot {
    param([object]$Snapshot, [object]$StateFiles)
    Assert-E2ECheckpointFile -Path ([string]$Snapshot.path) -Sha256 ([string]$Snapshot.sha256) -Label "infobase snapshot"
    $relative = ([string]$Snapshot.path).Substring($worktreePath.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    Restore-E2EStateFiles -Record $StateFiles
    Invoke-E2EHelper -Action "release-e2e-restore" -TimeoutSeconds 7200 -AdditionalArguments @("-ReleaseSnapshotPath", $relative) | Out-Null
    Restore-E2EStateFiles -Record $StateFiles
}

function Set-E2EStageStatus {
    param([string]$Name, [string]$Status, [string]$ErrorText = "", [string]$EvidencePath = "")
    if (-not $checkpoint["stages"].Contains($Name)) { $checkpoint["stages"][$Name] = [ordered]@{} }
    $record = $checkpoint["stages"][$Name]
    $now = [DateTime]::UtcNow
    if (-not $record.Contains("attempts")) { $record["attempts"] = @() }
    if ($Status -eq "running") {
        $script:stageTimers[$Name] = [System.Diagnostics.Stopwatch]::StartNew()
        $record["proofStartedAt"] = $now.ToString("o")
        $record["execution"] = "executed"
        $record["reuseReason"] = ""
        $record["fingerprint"] = Get-E2EStageFingerprint -Name $Name
    } elseif ($Status -in @("passed", "failed")) {
        $durationMs = 0
        if ($script:stageTimers.ContainsKey($Name)) {
            $script:stageTimers[$Name].Stop()
            $durationMs = [int64]$script:stageTimers[$Name].ElapsedMilliseconds
            $script:stageTimers.Remove($Name)
        }
        $record["proofFinishedAt"] = $now.ToString("o")
        $record["proofDurationMs"] = $durationMs
        $record["currentRunDurationMs"] = $durationMs
        $record["attempts"] = @($record["attempts"]) + @([ordered]@{
            status = $Status; startedAt = [string]$record["proofStartedAt"]; finishedAt = $now.ToString("o"); durationMs = $durationMs; error = $ErrorText
        })
    }
    $record["status"] = $Status
    $record["updatedAt"] = $now.ToString("o")
    $record["error"] = $ErrorText
    if ($EvidencePath -or $Status -ne "running") {
        $record["evidencePath"] = $EvidencePath
        $record["evidenceSha256"] = Get-E2EFileSha256 -Path $EvidencePath
    }
    $checkpoint["expectedHead"] = (& git -C $worktreePath rev-parse HEAD).Trim()
    if ($Status -eq "passed") { $checkpoint["lastPassedStage"] = $Name }
    Write-E2ECheckpoint
}

function Set-E2EStageReused {
    param([string]$Name, [string]$Reason)
    $record = $checkpoint["stages"][$Name]
    $record["execution"] = "reused"
    $record["reuseReason"] = $Reason
    $record["currentRunDurationMs"] = 0
    $record["updatedAt"] = [DateTime]::UtcNow.ToString("o")
    Write-E2ECheckpoint
}

function Test-E2EStagePassed {
    param([string]$Name)
    if (-not $checkpoint["stages"].Contains($Name)) { return $false }
    $record = $checkpoint["stages"][$Name]
    if ([string]$record.status -ne "passed") { return $false }
    $expectedFingerprint = Get-E2EStageFingerprint -Name $Name
    if ([string]$record.fingerprint -ne $expectedFingerprint) {
        $stageOrder = @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp", "verification-refresh", "result-cleanup")
        $stageIndex = [Array]::IndexOf($stageOrder, $Name)
        $boundaryIndex = [Array]::IndexOf($stageOrder, $continuationBoundaryStage)
        $legacyFingerprint = if ($previousRunnerSha256) { Get-E2EStageFingerprint -Name $Name -RunnerSha256 $previousRunnerSha256 } else { "" }
        $completedReleaseContinuation = $crossReleaseReuse -and $releaseContinuationProof -and -not $continuationBoundaryStage
        $beforeFailedStage = $boundaryIndex -ge 0 -and $stageIndex -ge 0 -and $stageIndex -lt $boundaryIndex
        $canRebind = $crossReleaseReuse -and $releaseContinuationProof -and ($completedReleaseContinuation -or $beforeFailedStage) -and
            [string]$record.fingerprint -eq $legacyFingerprint
        if ($canRebind) {
            $record["fingerprint"] = $expectedFingerprint
            $record["reuseReason"] = if ($completedReleaseContinuation) { "exact Targeted continuation after completed release" } else { "exact Targeted continuation before failed stage '$continuationBoundaryStage'" }
            Write-E2ECheckpoint
        } else {
            $script:invalidatedStages += $Name
            return $false
        }
    }
    if ([string]$record.evidencePath) {
        try { Assert-E2ECheckpointFile -Path ([string]$record.evidencePath) -Sha256 ([string]$record.evidenceSha256) -Label "$Name evidence" }
        catch { throw "RELEASE_E2E_CACHE_CORRUPT: $($_.Exception.Message)" }
    }
    return $true
}

function Sync-E2EWorktreeFromMaster {
    $masterBranch = "master"
    $projectConfigPath = Join-Path $worktreePath ".agent-1c\project.json"
    if (Test-Path -LiteralPath $projectConfigPath -PathType Leaf) {
        try {
            $projectConfig = Get-Content -LiteralPath $projectConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$projectConfig.masterBranch) { $masterBranch = [string]$projectConfig.masterBranch }
        } catch {
            throw "RELEASE_E2E_RESUME_STATE_MISMATCH: project config is unreadable before branch refresh: $($_.Exception.Message)"
        }
    }

    & git -C $worktreePath merge-base --is-ancestor $masterBranch HEAD
    $ancestryExitCode = $LASTEXITCODE
    if ($ancestryExitCode -eq 0) { return $false }
    if ($ancestryExitCode -ne 1) {
        throw "RELEASE_E2E_RESUME_STATE_MISMATCH: could not compare '$masterBranch' with the E2E branch."
    }

    Write-Host "Release E2E branch does not contain $masterBranch; running script-owned refresh-dev-branch before checkpointing."
    Invoke-E2EHelper -Action "refresh-dev-branch" -TimeoutSeconds 7200 | Out-Null
    if (@(& git -C $worktreePath status --porcelain --untracked-files=all).Count -gt 0) {
        throw "RELEASE_E2E_RESUME_STATE_MISMATCH: refresh-dev-branch left the E2E worktree dirty."
    }
    & git -C $worktreePath merge-base --is-ancestor $masterBranch HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "RELEASE_E2E_RESUME_STATE_MISMATCH: refresh-dev-branch did not integrate '$masterBranch'."
    }
    return $true
}

function Get-E2ESeedManifest {
    param([string]$MainRoot)

    $projectConfigPath = Join-Path $MainRoot ".agent-1c\project.json"
    $seedRoot = Join-Path $MainRoot ".agent-1c\branch-seed"
    if (Test-Path -LiteralPath $projectConfigPath -PathType Leaf) {
        $projectConfig = Get-Content -LiteralPath $projectConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $branchSeedRootProperty = $projectConfig.PSObject.Properties["branchSeedRoot"]
        if ($null -ne $branchSeedRootProperty -and [string]$branchSeedRootProperty.Value) {
            $configured = [Environment]::ExpandEnvironmentVariables([string]$branchSeedRootProperty.Value)
            $seedRoot = if ([IO.Path]::IsPathRooted($configured)) { [IO.Path]::GetFullPath($configured) } else { [IO.Path]::GetFullPath((Join-Path $MainRoot $configured)) }
        }
    }
    $envPath = Join-Path $MainRoot ".dev.env"
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $envPath -Encoding UTF8)) {
            if ($line -match '^\s*BRANCH_SEED_ROOT=(?<value>.*)$' -and $Matches.value.Trim()) {
                $configured = [Environment]::ExpandEnvironmentVariables($Matches.value.Trim().Trim('"'))
                $seedRoot = if ([IO.Path]::IsPathRooted($configured)) { [IO.Path]::GetFullPath($configured) } else { [IO.Path]::GetFullPath((Join-Path $MainRoot $configured)) }
            }
        }
    }
    $manifests = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -File -Filter "manifest.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $value = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$value.status -eq "ready") {
                [pscustomobject]@{ path = $_.FullName; value = $value; completedAt = [datetime]$value.completedAt }
            }
        } catch {
        }
    } | Sort-Object completedAt -Descending)
    if ($manifests.Count -eq 0) {
        throw "RELEASE_E2E_SEED_MISSING: no ready manifest under $seedRoot"
    }
    return $manifests[0]
}

function Get-E2EBranchStateAtRoot {
    param([string]$Root, [string]$Name)

    $safe = ($Name -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
    $path = Join-Path $Root ".agent-1c\dev-branches\$safe.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $candidate = @(Get-ChildItem -LiteralPath (Join-Path $Root ".agent-1c\dev-branches") -File -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
            try { [string](Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).devBranchName -eq $Name } catch { $false }
        } | Select-Object -First 1)
        if ($candidate.Count -gt 0) { $path = $candidate[0].FullName }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "RELEASE_E2E_SEED_BRANCH_STATE_MISSING: name=$Name root=$Root"
    }
    return [pscustomobject]@{ path = $path; value = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
}

function Get-E2ESourceFileObservation {
    param([string]$MainRoot)

    $envPath = Join-Path $MainRoot ".dev.env"
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return [ordered]@{ path = ""; length = 0; lastWriteTimeUtc = "" } }
    $sourcePath = ""
    foreach ($line in @(Get-Content -LiteralPath $envPath -Encoding UTF8)) {
        if ($line -match '^\s*SOURCE_INFOBASE_PATH=(?<value>.*)$') {
            $sourcePath = [Environment]::ExpandEnvironmentVariables($Matches.value.Trim().Trim('"'))
        }
    }
    if (-not $sourcePath) { return [ordered]@{ path = ""; length = 0; lastWriteTimeUtc = "" } }
    $resolvedSourcePath = if ([IO.Path]::IsPathRooted($sourcePath)) {
        [IO.Path]::GetFullPath($sourcePath)
    } else {
        [IO.Path]::GetFullPath((Join-Path $MainRoot $sourcePath))
    }
    $artifact = Join-Path $resolvedSourcePath "1Cv8.1CD"
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { return [ordered]@{ path = $artifact; length = 0; lastWriteTimeUtc = "" } }
    $file = Get-Item -LiteralPath $artifact
    return [ordered]@{ path = $artifact; length = [int64]$file.Length; lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o") }
}

function Remove-E2ESeedDisposableBranch {
    param(
        [string]$MainRoot,
        [object]$Spec,
        [System.Collections.Generic.List[string]]$CleanupErrors
    )

    $worktreeRemoved = $true
    if (Test-Path -LiteralPath $Spec.root -PathType Container) {
        try {
            Invoke-E2EHelperAtRoot -Root $Spec.root -BranchName $Spec.name -Action "close-dev-branch" -TimeoutSeconds 1800 -LogPrefix ("seed-parallel-close-" + $Spec.name) -AdditionalArguments @("-AllowUnverifiedClose") | Out-Null
        } catch {
            $CleanupErrors.Add("$($Spec.branch) close: $($_.Exception.Message)") | Out-Null
        }
        try {
            & git -C $MainRoot worktree remove --force -- $Spec.root *> $null
            if ($LASTEXITCODE -ne 0) {
                $worktreeRemoved = $false
                $CleanupErrors.Add("$($Spec.branch): Git worktree removal failed with exit code $LASTEXITCODE.") | Out-Null
            }
        } catch {
            $worktreeRemoved = $false
            $CleanupErrors.Add("$($Spec.branch): $($_.Exception.Message)") | Out-Null
        }
    }

    if ($worktreeRemoved) {
        & git -C $MainRoot show-ref --verify --quiet "refs/heads/$($Spec.branch)"
        $branchStatus = $LASTEXITCODE
        if ($branchStatus -eq 0) {
            try {
                & git -C $MainRoot branch -D -- $Spec.branch *> $null
                if ($LASTEXITCODE -ne 0) {
                    $CleanupErrors.Add("$($Spec.branch): Git branch deletion failed with exit code $LASTEXITCODE.") | Out-Null
                }
            } catch {
                $CleanupErrors.Add("$($Spec.branch): $($_.Exception.Message)") | Out-Null
            }
        } elseif ($branchStatus -ne 1) {
            $CleanupErrors.Add("$($Spec.branch): Git branch inspection failed with exit code $branchStatus.") | Out-Null
        }
    }
}

function Restore-E2ESeedMainBranch {
    param(
        [string]$MainRoot,
        [string]$MasterBranch,
        [string]$MasterAfterSync,
        [System.Collections.Generic.List[string]]$CleanupErrors
    )

    $currentBranch = (& git -C $MainRoot branch --show-current 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) {
        $CleanupErrors.Add("Could not determine the current main-worktree branch.") | Out-Null
        return
    }
    if ($currentBranch -ne $MasterBranch) {
        try {
            & git -C $MainRoot checkout --quiet $MasterBranch 2>$null
            if ($LASTEXITCODE -ne 0) {
                $CleanupErrors.Add("Could not checkout $MasterBranch during seed cleanup.") | Out-Null
                return
            }
        } catch {
            $CleanupErrors.Add("Could not checkout $MasterBranch during seed cleanup: $($_.Exception.Message)") | Out-Null
            return
        }
    }

    if ($MasterAfterSync) {
        & git -C $MainRoot merge-base --is-ancestor $MasterAfterSync HEAD *> $null
        if ($LASTEXITCODE -eq 0) {
            & git -C $MainRoot reset --hard $MasterAfterSync *> $null
            if ($LASTEXITCODE -ne 0) {
                $CleanupErrors.Add("Could not reset $MasterBranch to $MasterAfterSync.") | Out-Null
            }
        } else {
            $CleanupErrors.Add("Refusing to reset unexpected $MasterBranch history to $MasterAfterSync.") | Out-Null
        }
    }
    & git -C $MainRoot worktree prune *> $null
    if ($LASTEXITCODE -ne 0) {
        $CleanupErrors.Add("Git worktree prune failed during seed cleanup.") | Out-Null
    }
}

function Invoke-E2ESeedParallelProof {
    param([string]$MainRoot)

    $masterBranch = "master"
    $projectConfigPath = Join-Path $MainRoot ".agent-1c\project.json"
    if (Test-Path -LiteralPath $projectConfigPath -PathType Leaf) {
        $projectConfig = Get-Content -LiteralPath $projectConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$projectConfig.infoBaseKind -and [string]$projectConfig.infoBaseKind -ne "file") {
            throw "RELEASE_E2E_FILE_SEED_REQUIRED: infoBaseKind=$($projectConfig.infoBaseKind)"
        }
        if ([string]$projectConfig.masterBranch) { $masterBranch = [string]$projectConfig.masterBranch }
    }
    $mainStatus = @(& git -C $MainRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $mainStatus.Count -gt 0) {
        throw "RELEASE_E2E_SEED_MAIN_NOT_CLEAN: $MainRoot"
    }

    Invoke-E2EHelperAtRoot -Root $MainRoot -Action "sync-master" -TimeoutSeconds 7200 -LogPrefix "seed-parallel-sync-master" | Out-Null
    $masterAfterSync = (& git -C $MainRoot rev-parse "refs/heads/$masterBranch").Trim()
    & git -C $worktreePath merge-base --is-ancestor $masterAfterSync HEAD *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "RELEASE_E2E_PRIMARY_BRANCH_STALE_AFTER_SEED_SYNC: refresh the configured E2E branch from $masterAfterSync before Release."
    }
    $seedBeforeRecord = Get-E2ESeedManifest -MainRoot $MainRoot
    $seedBefore = $seedBeforeRecord.value
    if ([string]$seedBefore.artifactKind -ne "file-1cd" -or -not (Test-Path -LiteralPath ([string]$seedBefore.artifactPath) -PathType Leaf)) {
        throw "RELEASE_E2E_FILE_SEED_REQUIRED: artifactKind=$($seedBefore.artifactKind)"
    }
    $sourceBefore = Get-E2ESourceFileObservation -MainRoot $MainRoot

    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $nameA = "release-seed-a-$suffix"
    $nameB = "release-seed-b-$suffix"
    $branchA = "itldev/$nameA"
    $branchB = "itldev/$nameB"
    $worktreeParent = Split-Path -Parent $MainRoot
    $worktreeA = Join-Path $worktreeParent ("itlsa-$suffix")
    $worktreeB = Join-Path $worktreeParent ("itlsb-$suffix")
    $probePath = Join-Path $MainRoot "itl-release-seed-parallel.txt"
    $runtimeInvocations = @()
    $refreshInvocations = @()
    $stateA = $null
    $stateB = $null
    $targetMasterCommit = ""
    $branchRuntimeConcurrent = $false
    $liteRefreshConcurrent = $false
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    try {
        & git -C $MainRoot worktree add --quiet -b $branchA $worktreeA $masterAfterSync
        if ($LASTEXITCODE -ne 0) { throw "Could not create seed proof worktree A." }
        & git -C $MainRoot worktree add --quiet -b $branchB $worktreeB $masterAfterSync
        if ($LASTEXITCODE -ne 0) { throw "Could not create seed proof worktree B." }
        foreach ($target in @($worktreeA, $worktreeB)) {
            $targetEnvPath = Join-Path $target ".dev.env"
            Copy-Item -LiteralPath (Join-Path $MainRoot ".dev.env") -Destination $targetEnvPath -Force
            Set-E2EDotEnvValue `
                -Path $targetEnvPath `
                -Name "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP" `
                -Value "skip"
        }

        $runtimeInvocations += Start-E2EHelperAtRoot -Root $worktreeA -BranchName $nameA -Action "initialize-dev-branch-runtime" -LogPrefix "seed-parallel-runtime-a" -AdditionalArguments @(
            "-DevBranch", $branchA, "-DevBranchKind", "configuration", "-MainWorktreePath", $MainRoot, "-DevBranchWorktreePath", $worktreeA
        )
        $runtimeInvocations += Start-E2EHelperAtRoot -Root $worktreeB -BranchName $nameB -Action "initialize-dev-branch-runtime" -LogPrefix "seed-parallel-runtime-b" -AdditionalArguments @(
            "-DevBranch", $branchB, "-DevBranchKind", "configuration", "-MainWorktreePath", $MainRoot, "-DevBranchWorktreePath", $worktreeB
        )
        foreach ($invocation in $runtimeInvocations) {
            Complete-E2EHelperProcess -Invocation $invocation -TimeoutSeconds 7200 | Out-Null
        }
        $branchRuntimeConcurrent = Test-E2EInvocationOverlap -Invocations $runtimeInvocations
        if (-not $branchRuntimeConcurrent) {
            throw "Seed branch runtime invocations did not overlap."
        }
        $stateA = Get-E2EBranchStateAtRoot -Root $worktreeA -Name $nameA
        $stateB = Get-E2EBranchStateAtRoot -Root $worktreeB -Name $nameB
        if ([string]$stateA.value.initializationStatus -ne "ready" -or [string]$stateB.value.initializationStatus -ne "ready") {
            throw "Parallel seed branch initialization did not reach ready."
        }
        if ([string]$stateA.value.branchSeedSyncId -cne [string]$seedBefore.syncId -or [string]$stateB.value.branchSeedSyncId -cne [string]$seedBefore.syncId) {
            throw "Parallel branches did not restore the exact synchronized seed."
        }
        if ([string]$stateA.value.devBranchInfoBasePath -ceq [string]$stateB.value.devBranchInfoBasePath) {
            throw "Parallel seed branches share one branch infobase path."
        }
        if ([string]$stateA.value.eventLogBaselineCacheStatus -ne "seeded" -or [string]$stateB.value.eventLogBaselineCacheStatus -ne "seeded") {
            throw "Parallel seed branches scanned their new logs instead of installing the seed baseline."
        }

        [IO.File]::WriteAllText($probePath, "ITL Release seed parallel $suffix`r`n", [Text.UTF8Encoding]::new($false))
        & git -C $MainRoot add -- "itl-release-seed-parallel.txt"
        if ($LASTEXITCODE -ne 0) { throw "Could not stage seed parallel probe commit." }
        & git -C $MainRoot commit -m "test: advance master for parallel lite refresh" *> $null
        if ($LASTEXITCODE -ne 0) { throw "Could not create seed parallel probe commit." }
        $targetMasterCommit = (& git -C $MainRoot rev-parse HEAD).Trim()

        $refreshInvocations += Start-E2EHelperAtRoot -Root $worktreeA -BranchName $nameA -Action "refresh-dev-branch-lite" -LogPrefix "seed-parallel-refresh-a"
        $refreshInvocations += Start-E2EHelperAtRoot -Root $worktreeB -BranchName $nameB -Action "refresh-dev-branch-lite" -LogPrefix "seed-parallel-refresh-b"
        foreach ($invocation in $refreshInvocations) {
            Complete-E2EHelperProcess -Invocation $invocation -TimeoutSeconds 7200 | Out-Null
        }
        $liteRefreshConcurrent = Test-E2EInvocationOverlap -Invocations $refreshInvocations
        if (-not $liteRefreshConcurrent) {
            throw "Lite refresh invocations did not overlap."
        }
        Assert-E2ELiteRefreshDidNotEnterSourceSync -Invocations $refreshInvocations
        $stateA = Get-E2EBranchStateAtRoot -Root $worktreeA -Name $nameA
        $stateB = Get-E2EBranchStateAtRoot -Root $worktreeB -Name $nameB
        foreach ($stateRecord in @($stateA, $stateB)) {
            if ([string]$stateRecord.value.lastRefreshMode -ne "lite" -or [string]$stateRecord.value.lastRefreshMasterCommit -cne $targetMasterCommit) {
                throw "Parallel lite refresh did not record the exact target master SHA."
            }
        }
        $seedAfter = (Get-E2ESeedManifest -MainRoot $MainRoot).value
        $sourceAfter = Get-E2ESourceFileObservation -MainRoot $MainRoot
        if ([string]$seedAfter.syncId -cne [string]$seedBefore.syncId -or [string]$seedAfter.artifactSha256 -cne [string]$seedBefore.artifactSha256) {
            throw "Lite refresh unexpectedly changed the seed."
        }
        if (($sourceBefore | ConvertTo-Json -Compress) -cne ($sourceAfter | ConvertTo-Json -Compress)) {
            throw "Lite refresh changed the observed source infobase artifact metadata."
        }

        return [ordered]@{
            schemaVersion = 1
            testFixture = $false
            status = "passed"
            seedSyncId = [string]$seedBefore.syncId
            seedArtifactKind = [string]$seedBefore.artifactKind
            seedArtifactSha256 = [string]$seedBefore.artifactSha256
            seedBaselineHash = [string]$seedBefore.baselineHash
            seedBaselineCount = [int]$seedBefore.baselineCount
            seedPreservedByLiteRefresh = $true
            sourceObservationPreservedByLiteRefresh = $true
            liteRefreshSourceCallCount = 0
            branchRuntimeConcurrent = $branchRuntimeConcurrent
            liteRefreshConcurrent = $liteRefreshConcurrent
            targetMasterCommit = $targetMasterCommit
            branchA = [ordered]@{
                branch = $branchA; worktreePath = $worktreeA; infoBasePath = [string]$stateA.value.devBranchInfoBasePath
                seedSyncId = [string]$stateA.value.branchSeedSyncId; refreshMasterCommit = [string]$stateA.value.lastRefreshMasterCommit
                baselineCacheStatus = [string]$stateA.value.eventLogBaselineCacheStatus
            }
            branchB = [ordered]@{
                branch = $branchB; worktreePath = $worktreeB; infoBasePath = [string]$stateB.value.devBranchInfoBasePath
                seedSyncId = [string]$stateB.value.branchSeedSyncId; refreshMasterCommit = [string]$stateB.value.lastRefreshMasterCommit
                baselineCacheStatus = [string]$stateB.value.eventLogBaselineCacheStatus
            }
            capturedAt = [DateTime]::UtcNow.ToString("o")
        }
    } finally {
        foreach ($spec in @(
            [pscustomobject]@{ root = $worktreeA; name = $nameA; branch = $branchA },
            [pscustomobject]@{ root = $worktreeB; name = $nameB; branch = $branchB }
        )) {
            Remove-E2ESeedDisposableBranch -MainRoot $MainRoot -Spec $spec -CleanupErrors $cleanupErrors
        }
        Restore-E2ESeedMainBranch -MainRoot $MainRoot -MasterBranch $masterBranch -MasterAfterSync $masterAfterSync -CleanupErrors $cleanupErrors
        if ($cleanupErrors.Count -gt 0) {
            throw "RELEASE_E2E_SEED_CLEANUP_FAILED: $($cleanupErrors -join '; ')"
        }
    }
}

$branch = (& git -C $worktreePath branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -notlike "itldev/*") { throw "E2E worktree must be an itldev/* Git worktree: $worktreePath" }
$unsafeActionProtectionState = Assert-E2EUnsafeActionProtectionConfirmed
$script:e2eUnsafeActionProtectionConfirmation = [ordered]@{}
foreach ($name in @(
    "unsafeActionProtectionResolution",
    "unsafeActionProtectionSetupMode",
    "unsafeActionProtectionConfirmed",
    "unsafeActionProtectionConfirmedAt",
    "unsafeActionProtectionUser",
    "unsafeActionProtectionSourceKey"
)) {
    $property = $unsafeActionProtectionState.value.PSObject.Properties[$name]
    if ($null -ne $property) {
        $script:e2eUnsafeActionProtectionConfirmation[$name] = $property.Value
    }
}
$worktreeStatus = @(& git -C $worktreePath status --porcelain --untracked-files=all)
if ($usingLegacyRunRoot -and $ResumeMode -eq "Restart") {
    $legacyRunRelative = $releaseRunRoot.Substring($worktreePath.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    $worktreeStatus = @($worktreeStatus | Where-Object {
        $statusPath = if ([string]$_ -and ([string]$_).Length -gt 3) { ([string]$_).Substring(3).Trim('"').Replace('\', '/') } else { "" }
        $statusPath -ne $legacyRunRelative -and -not $statusPath.StartsWith("$legacyRunRelative/", [StringComparison]::OrdinalIgnoreCase)
    })
}
if ($worktreeStatus.Count -gt 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: E2E worktree must be clean before release verification." }
$aiRulesCommit = (& git -C $AiRulesSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $aiRulesCommit) { throw "Release ai_rules source is not a readable Git checkout: $AiRulesSource" }
$aiRulesTree = (& git -C $AiRulesSource rev-parse 'HEAD^{tree}').Trim()
$workflowRoot = Split-Path -Parent $PSScriptRoot
$workflowCommit = (& git -C $workflowRoot rev-parse HEAD).Trim()
$workflowTree = (& git -C $workflowRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or -not $workflowCommit -or -not $workflowTree) { throw "Release workflow source is not a readable Git checkout: $workflowRoot" }
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "release-qualification.ps1")
$runnerSha256 = Get-E2EFileSha256 -Path $PSCommandPath
$helperSha256 = Get-E2EFileSha256 -Path $HelperPath
$projectConfigSha256 = Get-E2EFileSha256 -Path (Join-Path $worktreePath ".agent-1c\project.json")
$stageModuleRoot = Join-Path $PSScriptRoot "release-e2e"
. (Join-Path $stageModuleRoot "common.ps1")
foreach ($stageModule in @("seed-parallel.ps1", "config-cadence.ps1", "config-roundtrip.ps1", "extension-smoke.ps1", "ondemand-mcp.ps1", "result-cleanup.ps1")) {
    . (Join-Path $stageModuleRoot $stageModule)
}

function Get-E2EStageInputFiles {
    param([string]$Name)
    $definition = $script:ReleaseE2EStageDefinitions[$Name]
    if (-not $definition) { throw "Unknown Release E2E stage definition: $Name" }
    $allFiles = @(Get-ChildItem -LiteralPath $workflowRoot -Recurse -File)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($patternText in @($definition.paths)) {
        $normalizedPattern = ([string]$patternText).Replace('\', '/')
        if ($normalizedPattern.IndexOfAny([char[]]'*?') -ge 0) {
            $pattern = New-Object System.Management.Automation.WildcardPattern($normalizedPattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
            $matches = @($allFiles | Where-Object {
                $relative = $_.FullName.Substring($workflowRoot.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
                $pattern.IsMatch($relative)
            })
            if ($matches.Count -eq 0) { throw "Release E2E stage '$Name' input pattern matched no files: $patternText" }
            foreach ($match in $matches) { $resolved.Add($match.FullName) | Out-Null }
        } else {
            $path = Join-Path $workflowRoot $normalizedPattern.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release E2E stage '$Name' input is missing: $patternText" }
            $resolved.Add([System.IO.Path]::GetFullPath($path)) | Out-Null
        }
    }
    $resolved.Add((Join-Path $stageModuleRoot ([string]$definition.moduleFile))) | Out-Null
    $resolved.Add((Join-Path $stageModuleRoot "common.ps1")) | Out-Null
    return @($resolved | Sort-Object -Unique)
}

function Get-E2EStageFingerprint {
    param([string]$Name, [string]$RunnerSha256 = $runnerSha256)
    $definition = $script:ReleaseE2EStageDefinitions[$Name]
    $inputs = @()
    foreach ($path in @(Get-E2EStageInputFiles -Name $Name)) {
        $inputs += [ordered]@{ path = $path.Substring($workflowRoot.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/'); sha256 = Get-E2EFileSha256 -Path $path }
    }
    $dependencies = @()
    foreach ($dependency in @($definition.dependsOn)) { $dependencies += [ordered]@{ name = $dependency; fingerprint = Get-E2EStageFingerprint -Name $dependency -RunnerSha256 $RunnerSha256 } }
    $payload = [ordered]@{
        name = $Name; version = [int]$definition.version; runnerSha256 = $RunnerSha256; helperSha256 = $helperSha256
        aiRulesCommit = $aiRulesCommit; aiRulesTree = $aiRulesTree; projectConfigSha256 = $projectConfigSha256
        inputs = $inputs; dependencies = $dependencies
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Depth 12 -Compress))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Copy-E2ECapabilityFile {
    param([string]$Source, [string]$Destination, [string]$Label)
    if (-not $Source) { return "" }
    Assert-E2ECheckpointFile -Path $Source -Sha256 (Get-E2EFileSha256 -Path $Source) -Label $Label
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $Destination
}

function Save-E2ECapabilityCache {
    $cacheId = [string]$checkpoint["runId"]
    if (-not $cacheId) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint has no run id for capability promotion." }
    $target = Join-Path $capabilityCacheRoot $cacheId
    $manifestPath = Join-Path $target "manifest.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $existing = ConvertTo-E2EHashtable (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            if ([int]$existing["schemaVersion"] -ne 1 -or [string]$existing["sourceRunId"] -ne $cacheId) { throw "identity mismatch" }
            foreach ($stageName in @($existing["stages"].Keys)) {
                $record = $existing["stages"][$stageName]
                if ([string]$record["evidencePath"]) {
                    Assert-E2ECheckpointFile -Path ([string]$record["evidencePath"]) -Sha256 ([string]$record["evidenceSha256"]) -Label "$stageName immutable evidence"
                }
            }
            foreach ($snapshotName in @($existing["snapshots"].Keys)) {
                $record = $existing["snapshots"][$snapshotName]
                Assert-E2ECheckpointFile -Path ([string]$record["path"]) -Sha256 ([string]$record["sha256"]) -Label "$snapshotName immutable snapshot"
            }
            foreach ($stateName in @($existing["stateFiles"].Keys)) {
                $record = $existing["stateFiles"][$stateName]
                Assert-E2ECheckpointFile -Path ([string]$record["stateCopyPath"]) -Sha256 ([string]$record["stateSha256"]) -Label "$stateName immutable state"
                if ([string]$record["envCopyPath"]) {
                    Assert-E2ECheckpointFile -Path ([string]$record["envCopyPath"]) -Sha256 ([string]$record["envSha256"]) -Label "$stateName immutable env"
                }
            }
        } catch { throw "RELEASE_E2E_CACHE_CORRUPT: immutable capability manifest is unreadable or belongs to another run: $manifestPath. $($_.Exception.Message)" }
        return $manifestPath
    }
    $staging = Join-Path $capabilityCacheRoot (".$cacheId." + [guid]::NewGuid().ToString("N") + ".tmp")
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $cached = ConvertTo-E2EHashtable $checkpoint
        foreach ($snapshotName in @("baseline", "postConfig")) {
            if (-not $cached["snapshots"].Contains($snapshotName)) { continue }
            $source = [string]$cached["snapshots"][$snapshotName]["path"]
            $destination = Join-Path $target ("snapshots\$snapshotName.dt")
            [void](Copy-E2ECapabilityFile -Source $source -Destination (Join-Path $staging ("snapshots\$snapshotName.dt")) -Label "$snapshotName snapshot")
            $cached["snapshots"][$snapshotName]["path"] = $destination
        }
        foreach ($stateName in @("baseline", "postConfig")) {
            if (-not $cached["stateFiles"].Contains($stateName)) { continue }
            $record = $cached["stateFiles"][$stateName]
            foreach ($spec in @(
                [pscustomobject]@{ key = "stateCopyPath"; suffix = "json" },
                [pscustomobject]@{ key = "envCopyPath"; suffix = "env" }
            )) {
                $source = [string]$record[$spec.key]
                if (-not $source) { continue }
                $relative = "state\$stateName.$($spec.suffix)"
                [void](Copy-E2ECapabilityFile -Source $source -Destination (Join-Path $staging $relative) -Label "$stateName $($spec.key)")
                $record[$spec.key] = Join-Path $target $relative
            }
        }
        foreach ($stageName in @($cached["stages"].Keys)) {
            $record = $cached["stages"][$stageName]
            $source = [string]$record["evidencePath"]
            if (-not $source) { continue }
            try { Assert-E2ECheckpointFile -Path $source -Sha256 ([string]$record["evidenceSha256"]) -Label "$stageName evidence" }
            catch { throw "RELEASE_E2E_CACHE_CORRUPT: $($_.Exception.Message)" }
            $extension = [IO.Path]::GetExtension($source)
            if (-not $extension) { $extension = ".json" }
            $relative = "evidence\$stageName$extension"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $staging $relative)) | Out-Null
            Copy-Item -LiteralPath $source -Destination (Join-Path $staging $relative) -Force
            $record["evidencePath"] = Join-Path $target $relative
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            sourceRunId = $cacheId
            identity = $cached["identity"]
            stages = $cached["stages"]
            snapshots = $cached["snapshots"]
            stateFiles = $cached["stateFiles"]
            generatedCommits = @($cached["generatedCommits"])
            configEvidence = $(if ($cached.Contains("configEvidence")) { $cached["configEvidence"] } else { $null })
            createdAt = [DateTime]::UtcNow.ToString("o")
        }
        [IO.File]::WriteAllText((Join-Path $staging "manifest.json"), (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Force -Path $capabilityCacheRoot | Out-Null
        Move-Item -LiteralPath $staging -Destination $target
        return $manifestPath
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function Find-E2ECompletedCapabilityCache {
    $preferredPath = if ($checkpoint.Contains("capabilityCache")) { [string]$checkpoint["capabilityCache"]["manifestPath"] } else { "" }
    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ($preferredPath -and (Test-Path -LiteralPath $preferredPath -PathType Leaf)) {
        $candidates.Add((Get-Item -LiteralPath $preferredPath)) | Out-Null
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $capabilityCacheRoot -Recurse -File -Filter "manifest.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
        if ($preferredPath -and $file.FullName -eq $preferredPath) { continue }
        $candidates.Add($file) | Out-Null
    }

    $capabilityStages = @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")
    foreach ($file in $candidates) {
        try {
            $cache = ConvertTo-E2EHashtable (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
            $identity = $cache["identity"]
            if ([int]$cache["schemaVersion"] -ne 1 -or [string]$identity["projectRoot"] -ne $ProjectRoot -or
                [string]$identity["worktreePath"] -ne $worktreePath -or [string]$identity["branch"] -ne $branch -or
                [string]$identity["aiRulesCommit"] -ne $aiRulesCommit -or [string]$identity["aiRulesTree"] -ne $aiRulesTree -or
                [string]$identity["helperSha256"] -ne $helperSha256 -or [string]$identity["projectConfigSha256"] -ne $projectConfigSha256) { Write-Verbose "Completed capability cache identity mismatch: $($file.FullName)"; continue }
            $cacheContinuation = Get-WorkflowContinuationProof -RepositoryRoot $workflowRoot -QualifiedCommit ([string]$identity["workflowCommit"]) -CurrentCommit $workflowCommit -CurrentTree $workflowTree
            if (-not $cacheContinuation) { Write-Verbose "Completed capability cache has no exact Targeted continuation: $($file.FullName)"; continue }
            $compatible = $true
            foreach ($stageName in $capabilityStages) {
                if (-not $cache["stages"].Contains($stageName)) { Write-Verbose "Completed capability cache is missing stage '$stageName': $($file.FullName)"; $compatible = $false; break }
                $record = $cache["stages"][$stageName]
                if ([string]$record["status"] -ne "passed" -or [string]$record["fingerprint"] -ne (Get-E2EStageFingerprint -Name $stageName -RunnerSha256 ([string]$identity["runnerSha256"]))) { Write-Verbose "Completed capability cache stage '$stageName' is not a compatible pass: $($file.FullName)"; $compatible = $false; break }
                if ([string]$record["evidencePath"]) {
                    Assert-E2ECheckpointFile -Path ([string]$record["evidencePath"]) -Sha256 ([string]$record["evidenceSha256"]) -Label "$stageName completed cache evidence"
                }
            }
            if (-not $compatible) { continue }
            foreach ($snapshotName in @("baseline", "postConfig")) {
                if (-not $cache["snapshots"].Contains($snapshotName)) { $compatible = $false; break }
                $snapshot = $cache["snapshots"][$snapshotName]
                Assert-E2ECheckpointFile -Path ([string]$snapshot["path"]) -Sha256 ([string]$snapshot["sha256"]) -Label "$snapshotName completed cache snapshot"
            }
            if (-not $compatible) { continue }
            foreach ($stateName in @("baseline", "postConfig")) {
                if (-not $cache["stateFiles"].Contains($stateName)) { $compatible = $false; break }
                $state = $cache["stateFiles"][$stateName]
                Assert-E2ECheckpointFile -Path ([string]$state["stateCopyPath"]) -Sha256 ([string]$state["stateSha256"]) -Label "$stateName completed cache state"
                if ([string]$state["envCopyPath"]) {
                    Assert-E2ECheckpointFile -Path ([string]$state["envCopyPath"]) -Sha256 ([string]$state["envSha256"]) -Label "$stateName completed cache env"
                }
            }
            if ($compatible) { return $file.FullName }
        } catch { Write-Verbose "Completed capability cache rejected: $($file.FullName). $($_.Exception.Message)"; continue }
    }
    return ""
}

function Restore-E2EInterruptedCapabilityStage {
    param([string]$Name)
    if (-not $checkpoint["stages"].Contains($Name) -or [string]$checkpoint["stages"][$Name]["status"] -ne "running") { return $false }

    $preferredPath = if ($checkpoint.Contains("capabilityCache")) { [string]$checkpoint["capabilityCache"]["manifestPath"] } else { "" }
    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ($preferredPath -and (Test-Path -LiteralPath $preferredPath -PathType Leaf)) {
        $candidates.Add((Get-Item -LiteralPath $preferredPath)) | Out-Null
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $capabilityCacheRoot -Recurse -File -Filter "manifest.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
        if ($preferredPath -and $file.FullName -eq $preferredPath) { continue }
        $candidates.Add($file) | Out-Null
    }

    foreach ($file in $candidates) {
        try {
            $cache = ConvertTo-E2EHashtable (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
            $identity = $cache["identity"]
            if ([int]$cache["schemaVersion"] -ne 1 -or [string]$identity["projectRoot"] -ne $ProjectRoot -or
                [string]$identity["worktreePath"] -ne $worktreePath -or [string]$identity["branch"] -ne $branch -or
                [string]$identity["initialHead"] -ne [string]$checkpoint["identity"]["initialHead"] -or
                [string]$identity["aiRulesCommit"] -ne $aiRulesCommit -or [string]$identity["aiRulesTree"] -ne $aiRulesTree -or
                [string]$identity["helperSha256"] -ne $helperSha256 -or [string]$identity["projectConfigSha256"] -ne $projectConfigSha256 -or
                -not $cache["stages"].Contains($Name)) { continue }
            if (-not (Get-WorkflowContinuationProof -RepositoryRoot $workflowRoot -QualifiedCommit ([string]$identity["workflowCommit"]) -CurrentCommit $workflowCommit -CurrentTree $workflowTree)) { continue }
            $record = $cache["stages"][$Name]
            if ([string]$record["status"] -ne "passed" -or
                [string]$record["fingerprint"] -ne (Get-E2EStageFingerprint -Name $Name -RunnerSha256 ([string]$identity["runnerSha256"]))) { continue }
            if ([string]$record["evidencePath"]) {
                Assert-E2ECheckpointFile -Path ([string]$record["evidencePath"]) -Sha256 ([string]$record["evidenceSha256"]) -Label "$Name interrupted-stage evidence"
            }
            if ($Name -eq "config-cadence") {
                foreach ($supportName in @("postConfig")) {
                    if (-not $cache["snapshots"].Contains($supportName) -or -not $cache["stateFiles"].Contains($supportName)) { throw "missing $supportName support state" }
                    $snapshot = $cache["snapshots"][$supportName]
                    Assert-E2ECheckpointFile -Path ([string]$snapshot["path"]) -Sha256 ([string]$snapshot["sha256"]) -Label "$supportName interrupted-stage snapshot"
                    $state = $cache["stateFiles"][$supportName]
                    Assert-E2ECheckpointFile -Path ([string]$state["stateCopyPath"]) -Sha256 ([string]$state["stateSha256"]) -Label "$supportName interrupted-stage state"
                    if ([string]$state["envCopyPath"]) {
                        Assert-E2ECheckpointFile -Path ([string]$state["envCopyPath"]) -Sha256 ([string]$state["envSha256"]) -Label "$supportName interrupted-stage env"
                    }
                    $checkpoint["snapshots"][$supportName] = $snapshot
                    $checkpoint["stateFiles"][$supportName] = $state
                }
                $checkpoint["generatedCommits"] = @($cache["generatedCommits"])
                if ($cache["configEvidence"]) { $checkpoint["configEvidence"] = $cache["configEvidence"] }
            }
            $checkpoint["stages"][$Name] = $record
            $checkpoint["stages"][$Name]["recoveredFromCapabilityCache"] = $file.FullName
            Write-E2ECheckpoint
            return $true
        } catch {
            Write-Verbose "Interrupted capability stage '$Name' was not recovered from $($file.FullName): $($_.Exception.Message)"
        }
    }
    return $false
}

function Set-E2ECheckpointCapabilityEvidence {
    param([string]$ManifestPath)
    try { $cache = ConvertTo-E2EHashtable (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "RELEASE_E2E_CACHE_CORRUPT: capability manifest is unreadable: $ManifestPath. $($_.Exception.Message)" }
    foreach ($stageName in @($checkpoint["stages"].Keys)) {
        if (-not $cache["stages"].Contains($stageName)) { continue }
        $cachedRecord = $cache["stages"][$stageName]
        if ([string]$cachedRecord["evidencePath"]) {
            Assert-E2ECheckpointFile -Path ([string]$cachedRecord["evidencePath"]) -Sha256 ([string]$cachedRecord["evidenceSha256"]) -Label "$stageName sealed evidence"
            $checkpoint["stages"][$stageName]["evidencePath"] = [string]$cachedRecord["evidencePath"]
            $checkpoint["stages"][$stageName]["evidenceSha256"] = [string]$cachedRecord["evidenceSha256"]
        }
    }
    $checkpoint["capabilityCache"] = [ordered]@{ manifestPath = $ManifestPath; sealedAt = [DateTime]::UtcNow.ToString("o") }
    Write-E2ECheckpoint
}

function Import-E2ECapabilityCache {
    param([string]$ManifestPath)
    $cache = ConvertTo-E2EHashtable (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ([int]$cache["schemaVersion"] -ne 1) { throw "RELEASE_E2E_CACHE_CORRUPT: unsupported capability cache schema." }
    $oldInitialHead = [string]$cache["identity"]["initialHead"]
    # Rebinding must use the runner that created the imported stage records,
    # which can be older than the interrupted checkpoint's runner.
    $script:previousRunnerSha256 = [string]$cache["identity"]["runnerSha256"]
    $commitMap = @{}
    foreach ($record in @($cache["generatedCommits"])) {
        $oldCommit = [string]$record["commit"]
        & git -C $worktreePath cherry-pick $oldCommit *> $null
        if ($LASTEXITCODE -ne 0) {
            & git -C $worktreePath cherry-pick --abort *> $null
            throw "RELEASE_E2E_CAPABILITY_REPLAY_FAILED: could not replay generated commit '$oldCommit' on the new candidate baseline."
        }
        $newCommit = (& git -C $worktreePath rev-parse HEAD).Trim()
        $commitMap[$oldCommit] = $newCommit
        $record["commit"] = $newCommit
    }
    $checkpoint["generatedCommits"] = @($cache["generatedCommits"])
    $checkpoint["expectedHead"] = (& git -C $worktreePath rev-parse HEAD).Trim()
    foreach ($stageName in @($cache["stages"].Keys)) { $checkpoint["stages"][$stageName] = $cache["stages"][$stageName] }
    if ($cache["snapshots"].Contains("postConfig")) { $checkpoint["snapshots"]["postConfig"] = $cache["snapshots"]["postConfig"] }
    if ($cache["stateFiles"].Contains("postConfig")) { $checkpoint["stateFiles"]["postConfig"] = $cache["stateFiles"]["postConfig"] }
    if ($cache["configEvidence"]) {
        $checkpoint["configEvidence"] = $cache["configEvidence"]
        foreach ($key in @($checkpoint["configEvidence"].Keys)) {
            $value = [string]$checkpoint["configEvidence"][$key]
            if ($commitMap.ContainsKey($value)) { $checkpoint["configEvidence"][$key] = $commitMap[$value] }
        }
    }
    $checkpoint["capabilityCache"] = [ordered]@{ manifestPath = $ManifestPath; sourceInitialHead = $oldInitialHead; importedAt = [DateTime]::UtcNow.ToString("o") }
    Write-E2ECheckpoint
}

if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
    try { $checkpoint = ConvertTo-E2EHashtable (Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint is corrupt: $checkpointPath. $($_.Exception.Message)" }
}

if ($checkpoint) {
    $identity = $checkpoint["identity"]
    $checkpointSchema = [int]$checkpoint["schemaVersion"]
    $scopeMatches = $checkpointSchema -in @(1, 2, 3) -and
        [string]$identity.projectRoot -eq $ProjectRoot -and
        [string]$identity.worktreePath -eq $worktreePath -and
        [string]$identity.branch -eq $branch
    if (-not $scopeMatches) {
        throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint belongs to another project/worktree/branch. schema=$checkpointSchema project='$([string]$identity.projectRoot)' expectedProject='$ProjectRoot' worktree='$([string]$identity.worktreePath)' expectedWorktree='$worktreePath' branch='$([string]$identity.branch)' expectedBranch='$branch'."
    }
    if ($checkpointSchema -lt 3 -and $ResumeMode -eq "Auto") {
        throw "RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED: checkpoint schema v$checkpointSchema requires one scripted -ResumeMode Restart migration."
    }
    $releaseIdentityMatches =
        [string]$identity.workflowCommit -eq $workflowCommit -and
        [string]$identity.workflowTree -eq $workflowTree -and
        [string]$identity.runnerSha256 -eq $runnerSha256 -and
        [string]$identity.aiRulesCommit -eq $aiRulesCommit -and
        [string]$identity.helperSha256 -eq $helperSha256 -and
        [string]$identity.projectConfigSha256 -eq $projectConfigSha256
    if ($ResumeMode -eq "Auto" -and -not $releaseIdentityMatches) {
        $crossReleaseReuse = $true
        $previousWorkflowCommit = [string]$identity.workflowCommit
        $previousRunnerSha256 = [string]$identity.runnerSha256
        $releaseContinuationProof = Get-WorkflowContinuationProof -RepositoryRoot $workflowRoot -QualifiedCommit $previousWorkflowCommit -CurrentCommit $workflowCommit -CurrentTree $workflowTree
        if ($releaseContinuationProof) {
            foreach ($stageName in @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                [void](Restore-E2EInterruptedCapabilityStage -Name $stageName)
            }
            foreach ($stageName in @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp", "verification-refresh", "result-cleanup")) {
                if ($checkpoint["stages"].Contains($stageName) -and [string]$checkpoint["stages"][$stageName].status -ne "passed") {
                    $continuationBoundaryStage = $stageName
                    break
                }
            }
        }
    }
    $currentHead = (& git -C $worktreePath rev-parse HEAD).Trim()
    if ($ResumeMode -eq "Auto" -and $currentHead -ne [string]$checkpoint["expectedHead"]) {
        $managedRefreshMerge = $false
        $worktreeCleanForRefresh = @(& git -C $worktreePath status --porcelain --untracked-files=all).Count -eq 0
        $parents = @()
        $standMasterHead = ""
        if ($crossReleaseReuse -and $worktreeCleanForRefresh) {
            $parents = @((& git -C $worktreePath rev-list --parents -n 1 $currentHead).Trim() -split '\s+')
            $standMasterHead = (& git -C $ProjectRoot rev-parse HEAD).Trim()
            $managedRefreshMerge = $parents.Count -eq 3 -and $parents[1] -eq [string]$checkpoint["expectedHead"] -and $parents[2] -eq $standMasterHead
        }
        if (-not $managedRefreshMerge) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: current HEAD '$currentHead' differs from checkpoint HEAD '$($checkpoint['expectedHead'])'. crossRelease=$crossReleaseReuse continuation=$([bool]$releaseContinuationProof) clean=$worktreeCleanForRefresh parents='$($parents -join ',')' master='$standMasterHead'." }
    }

    if (-not $checkpoint["snapshots"].Contains("baseline")) {
        if ($checkpoint["stages"].Count -gt 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: baseline snapshot was not checkpointed before stage execution." }
        Remove-Item -LiteralPath $baselineSnapshotPath -Force -ErrorAction SilentlyContinue
        $checkpoint["snapshots"]["baseline"] = Invoke-E2EInfobaseSnapshot -Path $baselineSnapshotPath
        Write-E2ECheckpoint
    } else {
        Assert-E2ECheckpointFile -Path ([string]$checkpoint["snapshots"]["baseline"].path) -Sha256 ([string]$checkpoint["snapshots"]["baseline"].sha256) -Label "baseline infobase snapshot"
    }
    $baselineStateRecord = $checkpoint["stateFiles"]["baseline"]
    Assert-E2ECheckpointFile -Path ([string]$baselineStateRecord.stateCopyPath) -Sha256 ([string]$baselineStateRecord.stateSha256) -Label "baseline branch state"
    if ([string]$baselineStateRecord.envCopyPath) {
        Assert-E2ECheckpointFile -Path ([string]$baselineStateRecord.envCopyPath) -Sha256 ([string]$baselineStateRecord.envSha256) -Label "baseline .dev.env"
    }
    if ($checkpoint["stages"].Contains("config-cadence") -and [string]$checkpoint["stages"]["config-cadence"].status -eq "passed") {
        if (-not $checkpoint["snapshots"].Contains("postConfig") -or -not $checkpoint["stateFiles"].Contains("postConfig")) {
            throw "RELEASE_E2E_RESUME_STATE_MISMATCH: passed config-cadence has no post-config snapshot/state."
        }
        Assert-E2ECheckpointFile -Path ([string]$checkpoint["snapshots"]["postConfig"].path) -Sha256 ([string]$checkpoint["snapshots"]["postConfig"].sha256) -Label "post-config infobase snapshot"
        $postConfigStateRecord = $checkpoint["stateFiles"]["postConfig"]
        Assert-E2ECheckpointFile -Path ([string]$postConfigStateRecord.stateCopyPath) -Sha256 ([string]$postConfigStateRecord.stateSha256) -Label "post-config branch state"
        if ([string]$postConfigStateRecord.envCopyPath) {
            Assert-E2ECheckpointFile -Path ([string]$postConfigStateRecord.envCopyPath) -Sha256 ([string]$postConfigStateRecord.envSha256) -Label "post-config .dev.env"
        }
    }

    if ($ResumeMode -eq "Restart") {
        Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["baseline"] -StateFiles $checkpoint["stateFiles"]["baseline"]
        & git -C $worktreePath reset --hard ([string]$identity.initialHead) *> $null
        if ($LASTEXITCODE -ne 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: could not restore the exact baseline commit for Restart." }
        Remove-Item -LiteralPath $releaseRunRoot -Recurse -Force
        if ($usingLegacyRunRoot) {
            Set-E2ERunPaths -Root $preferredReleaseRunRoot
            $usingLegacyRunRoot = $false
        }
        if (@(& git -C $worktreePath status --porcelain --untracked-files=all).Count -gt 0) {
            throw "RELEASE_E2E_RESUME_STATE_MISMATCH: scripted Restart did not restore a clean E2E worktree."
        }
        $checkpoint = $null
    } elseif (-not $crossReleaseReuse) {
        $checkpointWasResumed = $true
    } else {
        $promotedCapabilityPath = Find-E2ECompletedCapabilityCache
        if (-not $promotedCapabilityPath) {
            # The immutable manifest for this run may predate a resumed stage.
            # Seal the now-current checkpoint under a new cache identity.
            $checkpoint["runId"] = [guid]::NewGuid().ToString("N")
            Write-E2ECheckpoint
            $promotedCapabilityPath = Save-E2ECapabilityCache
        }
        Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["baseline"] -StateFiles $checkpoint["stateFiles"]["baseline"]
        & git -C $worktreePath reset --hard ([string]$identity.initialHead) *> $null
        if ($LASTEXITCODE -ne 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: could not restore the prior rollback baseline before candidate promotion." }
        Remove-Item -LiteralPath $releaseRunRoot -Recurse -Force
        $checkpoint = $null
        $checkpointWasResumed = $true
    }
}

if (-not $checkpoint) {
    [void](Sync-E2EWorktreeFromMaster)
    $projectConfigSha256 = Get-E2EFileSha256 -Path (Join-Path $worktreePath ".agent-1c\project.json")
    New-Item -ItemType Directory -Force -Path $releaseRunRoot | Out-Null
    $baselineStateFiles = Save-E2EStateFiles -StateCopyPath $baselineStateCopyPath -EnvCopyPath $baselineEnvCopyPath
    $initialHead = (& git -C $worktreePath rev-parse HEAD).Trim()
    $checkpoint = [ordered]@{
        schemaVersion = 3
        runId = [guid]::NewGuid().ToString("N")
        status = "running"
        identity = [ordered]@{
            projectRoot = $ProjectRoot
            worktreePath = $worktreePath
            branch = $branch
            initialHead = $initialHead
            workflowCommit = $workflowCommit
            workflowTree = $workflowTree
            runnerSha256 = $runnerSha256
            aiRulesCommit = $aiRulesCommit
            aiRulesTree = $aiRulesTree
            helperSha256 = $helperSha256
            projectConfigSha256 = $projectConfigSha256
        }
        expectedHead = $initialHead
        snapshots = [ordered]@{}
        stateFiles = [ordered]@{ baseline = $baselineStateFiles }
        stages = [ordered]@{}
        generatedCommits = @()
        lastPassedStage = ""
        cleanup = [ordered]@{ status = "pending"; actions = @() }
        createdAt = [DateTime]::UtcNow.ToString("o")
        releaseStartedAt = $startedAt.ToString("o")
    }
    Write-E2ECheckpoint
    $checkpoint["snapshots"]["baseline"] = Invoke-E2EInfobaseSnapshot -Path $baselineSnapshotPath
    Write-E2ECheckpoint
    if ($promotedCapabilityPath) {
        Import-E2ECapabilityCache -ManifestPath $promotedCapabilityPath
    }
}

try {
    [void](Get-E2EState)
    if (-not (Test-E2EStagePassed -Name "seed-parallel")) {
        Set-E2EStageStatus -Name "seed-parallel" -Status "running"
        $executedStages += "seed-parallel"
        try {
            if ($seedParallelTestFixture) {
                $seedParallelEvidence = [ordered]@{
                    schemaVersion = 1
                    testFixture = $true
                    status = "passed"
                    seedSyncId = "test-fixture"
                    seedArtifactKind = "file-1cd"
                    seedArtifactSha256 = ("0" * 64)
                    seedBaselineHash = ("0" * 64)
                    seedBaselineCount = 1
                    seedPreservedByLiteRefresh = $true
                    sourceObservationPreservedByLiteRefresh = $true
                    liteRefreshSourceCallCount = 0
                    branchRuntimeConcurrent = $true
                    liteRefreshConcurrent = $true
                    targetMasterCommit = ("1" * 40)
                    branchA = [ordered]@{ branch = "itldev/test-a"; worktreePath = "test-a"; infoBasePath = "base-a"; seedSyncId = "test-fixture"; refreshMasterCommit = ("1" * 40); baselineCacheStatus = "seeded" }
                    branchB = [ordered]@{ branch = "itldev/test-b"; worktreePath = "test-b"; infoBasePath = "base-b"; seedSyncId = "test-fixture"; refreshMasterCommit = ("1" * 40); baselineCacheStatus = "seeded" }
                    capturedAt = [DateTime]::UtcNow.ToString("o")
                }
            } else {
                $mainRoot = [string](Get-E2EState).value.mainWorktreePath
                if (-not $mainRoot -or -not (Test-Path -LiteralPath $mainRoot -PathType Container)) {
                    throw "RELEASE_E2E_SEED_MAIN_WORKTREE_MISSING: $mainRoot"
                }
                $seedParallelEvidence = Invoke-E2ESeedParallelProof -MainRoot ([IO.Path]::GetFullPath($mainRoot))
            }
            if ([string]$seedParallelEvidence.status -ne "passed" -or
                [string]$seedParallelEvidence.seedArtifactKind -ne "file-1cd" -or
                -not [bool]$seedParallelEvidence.seedPreservedByLiteRefresh -or
                -not [bool]$seedParallelEvidence.sourceObservationPreservedByLiteRefresh -or
                [int]$seedParallelEvidence.liteRefreshSourceCallCount -ne 0 -or
                -not [bool]$seedParallelEvidence.branchRuntimeConcurrent -or
                -not [bool]$seedParallelEvidence.liteRefreshConcurrent -or
                [string]$seedParallelEvidence.branchA.seedSyncId -cne [string]$seedParallelEvidence.branchB.seedSyncId -or
                [string]$seedParallelEvidence.branchA.refreshMasterCommit -cne [string]$seedParallelEvidence.targetMasterCommit -or
                [string]$seedParallelEvidence.branchB.refreshMasterCommit -cne [string]$seedParallelEvidence.targetMasterCommit -or
                [string]$seedParallelEvidence.branchA.infoBasePath -ceq [string]$seedParallelEvidence.branchB.infoBasePath -or
                [string]$seedParallelEvidence.branchA.baselineCacheStatus -ne "seeded" -or
                [string]$seedParallelEvidence.branchB.baselineCacheStatus -ne "seeded") {
                throw "Release E2E seed-parallel evidence is incomplete."
            }
            [IO.File]::WriteAllText(
                $seedParallelEvidencePath,
                (($seedParallelEvidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false)
            )
            Set-E2EStageStatus -Name "seed-parallel" -Status "passed" -EvidencePath $seedParallelEvidencePath
        } catch {
            Set-E2EStageStatus -Name "seed-parallel" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } else {
        $resumedStages += "seed-parallel"
        Set-E2EStageReused -Name "seed-parallel" -Reason $(if ($crossReleaseReuse) { "exact stage fingerprint across workflow release" } else { "same release checkpoint" })
        $seedParallelEvidence = Get-Content -LiteralPath $seedParallelEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if (-not (Test-E2EStagePassed -Name "config-cadence")) {
        if ($checkpoint["stages"].Contains("config-cadence")) {
            Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["baseline"] -StateFiles $checkpoint["stateFiles"]["baseline"]
            & git -C $worktreePath reset --hard ([string]$checkpoint["identity"]["initialHead"]) *> $null
            if ($LASTEXITCODE -ne 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: could not restore config-cadence baseline." }
            $checkpoint["generatedCommits"] = @()
            $checkpoint.Remove("configEvidence")
            $checkpoint["snapshots"].Remove("postConfig")
            $checkpoint["stateFiles"].Remove("postConfig")
            Write-E2ECheckpoint
        }
        Set-E2EStageStatus -Name "config-cadence" -Status "running"
        $executedStages += "config-cadence"
        try {
            $fixture = New-E2ERootConfigurationCommentCommit
            $fixtureCommit = $fixture.commit
            $expectedComment = $fixture.comment
            $vanessaFixture = New-E2EVanessaFixtureCommit
            $vanessaFixtureCommit = $vanessaFixture.commit

            # Configuration check 1/3: metadata changed, all four flat scenarios pass.
            Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
                "-ConfigLoadMode", "Partial", "-VanessaFeaturePath", $vanessaFixture.path, "-VanessaFilterTags", "@itl_release_flat"
            ) | Out-Null
            $partialState = (Get-E2EState).value
            if ([string]$partialState.configLoadStatus -ne "passed" -or [string]$partialState.lastConfigLoadMode -ne "partial" -or -not [bool]$partialState.designerInvoked -or -not [bool]$partialState.enterpriseInvoked) {
                throw "Release E2E first metadata check did not invoke and record Designer plus Enterprise."
            }
            $partialListPath = [string]$partialState.lastConfigBaseUpdateListFile
            $partialFiles = @()
            if ($partialListPath -and (Test-Path -LiteralPath $partialListPath -PathType Leaf)) {
                $partialFiles = @(Get-Content -LiteralPath $partialListPath -Encoding UTF8 | Where-Object { $_ -ne "" })
            }
            if ($partialFiles.Count -ne 1 -or [string]$partialFiles[0] -ne "Configuration.xml") { throw "Release E2E partial list must contain only Configuration.xml; actual: $($partialFiles -join ', ')" }
            $designerLoadedAt = [string]$partialState.lastConfigDesignerLoadedAt
            $firstJunit = Get-E2EJunitTotals -RunDirectory ([string]$partialState.lastVanessaReportPath)
            if ($firstJunit.tests -ne 4 -or ($firstJunit.failures + $firstJunit.errors) -ne 0) { throw "Release E2E first check must produce four passing JUnit tests." }
            $partialConfigDumpInfoCommit = Save-E2EConfigDumpInfoCursorCommit -Phase "partial"

            # Configuration check 2/3: a feature-only edit deliberately fails one
            # scenario; Designer and Enterprise must remain skipped.
            $stopOnErrorProbeCommit = Set-E2EVanessaFailureProbeCommit -FeaturePath $vanessaFixture.path -Fail $true
            $testOnlyCommit = $stopOnErrorProbeCommit
            $stopOnErrorProbe = Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AllowFailure -AdditionalArguments @(
                "-VanessaFeaturePath", $vanessaFixture.path, "-VanessaFilterTags", "@itl_release_flat"
            )
            if ($stopOnErrorProbe.exitCode -eq 0) { throw "Release E2E intentional failing test-only check unexpectedly passed." }
            $stopOnErrorProbeState = (Get-E2EState).value
            if ([string]$stopOnErrorProbeState.lastConfigDesignerLoadedAt -ne $designerLoadedAt -or [bool]$stopOnErrorProbeState.designerInvoked -or [bool]$stopOnErrorProbeState.enterpriseInvoked) { throw "Release E2E test-only failing check invoked Designer or Enterprise." }
            $stopOnErrorJunit = Get-E2EJunitTotals -RunDirectory ([string]$stopOnErrorProbeState.lastVanessaReportPath)
            $stopOnErrorProbeTests = $stopOnErrorJunit.tests
            $stopOnErrorProbeFailures = $stopOnErrorJunit.failures
            $stopOnErrorProbeErrors = $stopOnErrorJunit.errors
            if ($stopOnErrorProbeTests -ne 4 -or ($stopOnErrorProbeFailures + $stopOnErrorProbeErrors) -ne 1) { throw "stoponerror=false did not preserve four independent results with one failure." }

            # Configuration check 3/3: a second metadata change and the feature
            # recovery are present together, so both Designer and Enterprise run.
            $secondFixture = New-E2ERootConfigurationCommentCommit
            $secondMetadataCommit = $secondFixture.commit
            $expectedComment = $secondFixture.comment
            $stopOnErrorRecoveryCommit = Set-E2EVanessaFailureProbeCommit -FeaturePath $vanessaFixture.path -Fail $false
            Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
                "-VanessaFeaturePath", $vanessaFixture.path
            ) | Out-Null
            $recoveryState = (Get-E2EState).value
            if (-not [bool]$recoveryState.designerInvoked -or -not [bool]$recoveryState.enterpriseInvoked -or [string]$recoveryState.lastConfigDesignerLoadedAt -eq $designerLoadedAt) { throw "Release E2E second metadata plus feature recovery did not invoke Designer and Enterprise." }
            $recoveryJunit = Get-E2EJunitTotals -RunDirectory ([string]$recoveryState.lastVanessaReportPath)
            $vanessaJUnitTests = $recoveryJunit.tests
            $vanessaPostProcessDurationMs = [int64]$recoveryState.lastVanessaPostProcessDurationMs
            if ($vanessaJUnitTests -ne 4 -or ($recoveryJunit.failures + $recoveryJunit.errors) -ne 0) { throw "Release E2E recovery must restore four passing JUnit tests." }
            if ($vanessaPostProcessDurationMs -gt 30000) { throw "Release E2E recovery post-processing exceeded 30 seconds: $vanessaPostProcessDurationMs ms." }
            $recoveryConfigDumpInfoCommit = Save-E2EConfigDumpInfoCursorCommit -Phase "recovery"

            $checkpoint["stateFiles"]["postConfig"] = Save-E2EStateFiles -StateCopyPath $postConfigStateCopyPath -EnvCopyPath $postConfigEnvCopyPath
            $checkpoint["snapshots"]["postConfig"] = Invoke-E2EInfobaseSnapshot -Path $postConfigSnapshotPath
            $checkpoint["configEvidence"] = [ordered]@{
                fixtureCommit = $fixtureCommit; vanessaFixtureCommit = $vanessaFixtureCommit; testOnlyCommit = $testOnlyCommit
                secondMetadataCommit = $secondMetadataCommit; recoveryCommit = $stopOnErrorRecoveryCommit
                featurePath = $vanessaFixture.path; expectedComment = $expectedComment; designerLoadedAt = [string]$recoveryState.lastConfigDesignerLoadedAt
                junitTests = $vanessaJUnitTests; postProcessDurationMs = $vanessaPostProcessDurationMs
                probeTests = $stopOnErrorProbeTests; probeFailures = $stopOnErrorProbeFailures; probeErrors = $stopOnErrorProbeErrors
                partialConfigDumpInfoCommit = $partialConfigDumpInfoCommit; recoveryConfigDumpInfoCommit = $recoveryConfigDumpInfoCommit
            }
            [System.IO.File]::WriteAllText(
                $configCadenceEvidencePath,
                (($checkpoint["configEvidence"] | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
                [System.Text.UTF8Encoding]::new($false)
            )
            Set-E2EStageStatus -Name "config-cadence" -Status "passed" -EvidencePath $configCadenceEvidencePath
        } catch {
            Set-E2EStageStatus -Name "config-cadence" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } else {
        $resumedStages += "config-cadence"
        Set-E2EStageReused -Name "config-cadence" -Reason $(if ($crossReleaseReuse) { "exact stage fingerprint across workflow release" } else { "same release checkpoint" })
        $configEvidence = $checkpoint["configEvidence"]
        $fixtureCommit = [string]$configEvidence.fixtureCommit; $vanessaFixtureCommit = [string]$configEvidence.vanessaFixtureCommit
        $testOnlyCommit = [string]$configEvidence.testOnlyCommit; $secondMetadataCommit = [string]$configEvidence.secondMetadataCommit
        $stopOnErrorProbeCommit = $testOnlyCommit
        $stopOnErrorRecoveryCommit = [string]$configEvidence.recoveryCommit; $expectedComment = [string]$configEvidence.expectedComment
        $vanessaJUnitTests = [int]$configEvidence.junitTests; $vanessaPostProcessDurationMs = [int64]$configEvidence.postProcessDurationMs
        $stopOnErrorProbeTests = [int]$configEvidence.probeTests; $stopOnErrorProbeFailures = [int]$configEvidence.probeFailures; $stopOnErrorProbeErrors = [int]$configEvidence.probeErrors
        if ($configEvidence -is [System.Collections.IDictionary]) {
            $partialConfigDumpInfoCommit = if ($configEvidence.Contains("partialConfigDumpInfoCommit")) { [string]$configEvidence["partialConfigDumpInfoCommit"] } else { "" }
            $recoveryConfigDumpInfoCommit = if ($configEvidence.Contains("recoveryConfigDumpInfoCommit")) { [string]$configEvidence["recoveryConfigDumpInfoCommit"] } else { "" }
        } else {
            $partialCursorProperty = $configEvidence.PSObject.Properties["partialConfigDumpInfoCommit"]
            $recoveryCursorProperty = $configEvidence.PSObject.Properties["recoveryConfigDumpInfoCommit"]
            $partialConfigDumpInfoCommit = if ($null -ne $partialCursorProperty) { [string]$partialCursorProperty.Value } else { "" }
            $recoveryConfigDumpInfoCommit = if ($null -ne $recoveryCursorProperty) { [string]$recoveryCursorProperty.Value } else { "" }
        }
        $vanessaFixture = [pscustomobject]@{ path = [string]$configEvidence.featurePath; commit = $vanessaFixtureCommit }
    }

    $roundtripEvidencePath = Join-Path $worktreePath "build\test-results\release-e2e\config-roundtrip.json"
    if (-not (Test-E2EStagePassed -Name "config-roundtrip")) {
        if ($checkpoint["stages"].Contains("config-roundtrip")) {
            Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["postConfig"] -StateFiles $checkpoint["stateFiles"]["postConfig"]
        }
        Set-E2EStageStatus -Name "config-roundtrip" -Status "running"
        $executedStages += "config-roundtrip"
        try {
            Remove-Item -LiteralPath $roundtripEvidencePath -Force -ErrorAction SilentlyContinue
            Invoke-E2EHelper -Action "release-e2e-config-roundtrip" -TimeoutSeconds 7200 | Out-Null
            if (-not (Test-Path -LiteralPath $roundtripEvidencePath -PathType Leaf)) {
                throw "Release E2E roundtrip evidence was not created: $roundtripEvidencePath"
            }
            $roundtripEvidence = Get-Content -LiteralPath $roundtripEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [bool]$roundtripEvidence.parentConfigurationsPresentInDump -or [string]$roundtripEvidence.actualComment -cne $expectedComment) {
                throw "Release E2E roundtrip evidence does not prove Comment and ParentConfigurations.bin preservation."
            }
            Set-E2EStageStatus -Name "config-roundtrip" -Status "passed" -EvidencePath $roundtripEvidencePath
        } catch {
            Set-E2EStageStatus -Name "config-roundtrip" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } else {
        $resumedStages += "config-roundtrip"
        Set-E2EStageReused -Name "config-roundtrip" -Reason $(if ($crossReleaseReuse) { "exact stage fingerprint across workflow release" } else { "same release checkpoint" })
        $roundtripEvidence = Get-Content -LiteralPath $roundtripEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $extensionSmokeEvidencePath = Join-Path $worktreePath "build\test-results\release-e2e\extension-smoke.json"
    if (-not (Test-E2EStagePassed -Name "extension-smoke")) {
        # The extension stage always starts from the exact post-configuration
        # snapshot so any resumed run starts from deterministic state.
        Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["postConfig"] -StateFiles $checkpoint["stateFiles"]["postConfig"]
        Set-E2EStageStatus -Name "extension-smoke" -Status "running"
        $executedStages += "extension-smoke"
        try {
            Remove-Item -LiteralPath $extensionSmokeEvidencePath -Force -ErrorAction SilentlyContinue
            Invoke-E2EHelper -Action "release-e2e-extension-smoke" -TimeoutSeconds 7200 -AdditionalArguments @(
                "-ExtensionName", $extensionSmokeName,
                "-ReleaseAiRulesSource", $AiRulesSource
            ) | Out-Null
            if (-not (Test-Path -LiteralPath $extensionSmokeEvidencePath -PathType Leaf)) {
                throw "Release E2E extension smoke evidence was not created: $extensionSmokeEvidencePath"
            }
            $extensionSmokeEvidence = Get-Content -LiteralPath $extensionSmokeEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [bool]$extensionSmokeEvidence.emptyInitialized -or
                -not [bool]$extensionSmokeEvidence.cfeCreated -or
                -not [bool]$extensionSmokeEvidence.cfeInitialized -or
                -not [bool]$extensionSmokeEvidence.databaseRestored -or
                -not [bool]$extensionSmokeEvidence.repeatedFormOperationsIdempotent -or
                -not [bool]$extensionSmokeEvidence.repeatedTemplateOperationsIdempotent -or
                -not [bool]$extensionSmokeEvidence.formContentPreserved -or
                -not [bool]$extensionSmokeEvidence.formModulePreserved -or
                -not [bool]$extensionSmokeEvidence.templateContentPreserved -or
                -not [bool]$extensionSmokeEvidence.explicitMetadataUpdatesPassed -or
                -not [bool]$extensionSmokeEvidence.extensionUiTestClientPassed -or
                [int]$extensionSmokeEvidence.formRegistrationCount -ne 1 -or
                [int]$extensionSmokeEvidence.templateRegistrationCount -ne 1 -or
                [int]$extensionSmokeEvidence.extensionUiJunitTests -ne 1 -or
                [string]$extensionSmokeEvidence.extensionName -ne $extensionSmokeName) {
                throw "Release E2E extension evidence does not prove transactional content preservation, explicit metadata updates, Empty/CFE roundtrip, idempotence, real TestClient UI, and database restoration."
            }
            Set-E2EStageStatus -Name "extension-smoke" -Status "passed" -EvidencePath $extensionSmokeEvidencePath
        } catch {
            Set-E2EStageStatus -Name "extension-smoke" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } else {
        $resumedStages += "extension-smoke"
        Set-E2EStageReused -Name "extension-smoke" -Reason $(if ($crossReleaseReuse) { "exact stage fingerprint across workflow release" } else { "same release checkpoint" })
        $extensionSmokeEvidence = Get-Content -LiteralPath $extensionSmokeEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if (-not (Test-E2EStagePassed -Name "ondemand-mcp")) {
        Set-E2EStageStatus -Name "ondemand-mcp" -Status "running"
        $executedStages += "ondemand-mcp"
        $e2eDependencyLockPath = Join-Path $worktreePath ".agent-1c\dependency-lock.json"
        if (-not (Test-Path -LiteralPath $e2eDependencyLockPath -PathType Leaf)) {
            throw "Release E2E dependency lock is missing: $e2eDependencyLockPath"
        }
        $e2eDependencyLockBytes = [IO.File]::ReadAllBytes($e2eDependencyLockPath)
        try {
            Invoke-E2EHelper -Action "release-e2e-prepare-ondemand" -TimeoutSeconds 1800 | Out-Null
            $vanessaSmokeDirectory = Join-Path $outputRoot "Vanessa путь с пробелами"
            $vanessaSmokeFeature = Join-Path $vanessaSmokeDirectory "Проверка пути.feature"
            New-Item -ItemType Directory -Force -Path $vanessaSmokeDirectory | Out-Null
            Copy-Item -LiteralPath $vanessaFixture.path -Destination $vanessaSmokeFeature -Force
            $canonicalVanessaLock = (Get-Content -LiteralPath (Join-Path $workflowRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
            if ($onDemandMcpTestFixture) {
                $onDemandMcpEvidence = [ordered]@{
                    schemaVersion = 2
                    facadeSha256 = ("0" * 64)
                    testFixture = $true
                    families = [ordered]@{
                        roctup = [ordered]@{ publicToolCount = 2; catalogToolCount = 13; instances = @([ordered]@{ pid = 101; port = 6003 }); cleanupPassed = $true; idleCleanupPassed = $true; secondSurvivedFirstClose = $false; maxConcurrentSessions = 1; ownedProcessExitWaitMs = 80 }
                        "vanessa-ui" = [ordered]@{ publicToolCount = 2; catalogToolCount = 38; instances = @([ordered]@{ pid = 201; port = 9876; testClientProfile = "itl-ondemand"; testClientPort = 48151; vanessaAutomationCompatibilityVersion = [string]$canonicalVanessaLock.compatibilityVersion; vanessaAutomationDownstreamRevision = [string]$canonicalVanessaLock.downstreamRevision; vanessaAutomationArchiveSha256 = [string]$canonicalVanessaLock.sha256; vanessaAutomationEpfSha256 = [string]$canonicalVanessaLock.epfSha256; clientMcpSafeMode = $false; vaExtensionSafeMode = $false }, [ordered]@{ pid = 202; port = 9877; testClientProfile = "itl-ondemand"; testClientPort = 48152; vanessaAutomationCompatibilityVersion = [string]$canonicalVanessaLock.compatibilityVersion; vanessaAutomationDownstreamRevision = [string]$canonicalVanessaLock.downstreamRevision; vanessaAutomationArchiveSha256 = [string]$canonicalVanessaLock.sha256; vanessaAutomationEpfSha256 = [string]$canonicalVanessaLock.epfSha256; clientMcpSafeMode = $false; vaExtensionSafeMode = $false }); cleanupPassed = $true; idleCleanupPassed = $true; vanessaUiSmokePassed = $true; vanessaFileAuthoringOutcome = "passed"; vanessaFileAuthoringCalls = @("open_feature_file:file", "check_syntax:file", "load_features:file"); vanessaFeature = $vanessaSmokeFeature; secondSurvivedFirstClose = $true; maxConcurrentSessions = 3; ownedProcessExitWaitMs = 120 }
                    }
                    capturedAt = [DateTime]::UtcNow.ToString("o")
                }
            } else {
                $facadeBuild = & (Join-Path $workflowRoot "scripts\Build-ItlOnDemandMcp.ps1")
                $compatibilityRoot = Join-Path $workflowRoot ".agents\skills\1c-workflow\assets\ondemand-mcp"
                $compatibility = Get-Content -LiteralPath (Join-Path $compatibilityRoot "compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                $probeRoot = Join-Path $workflowRoot "tools\itl-ondemand-mcp"
                $families = [ordered]@{}
                foreach ($spec in @(
                    [pscustomobject]@{ family = "roctup"; tool = "get_metadata"; instances = 1; vanessaSmoke = $false },
                    [pscustomobject]@{ family = "vanessa-ui"; tool = "get_VanessaAutomation_state"; instances = 2; vanessaSmoke = $true }
                )) {
                    $definition = $compatibility.families.([string]$spec.family)
                    $catalogPath = Join-Path $compatibilityRoot ([string]$definition.catalog)
                    $familyEvidencePath = Join-Path $outputRoot ("ondemand-mcp-{0}.json" -f $spec.family)
                    Push-Location $probeRoot
                    try {
                        $probeArguments = @(
                            "run", ".\cmd\itl-ondemand-probe",
                            "-exe", [string]$facadeBuild.path,
                            "-family", [string]$spec.family,
                            "-project-root", $worktreePath,
                            "-catalog", $catalogPath,
                            "-helper", $HelperPath,
                            "-tool", [string]$spec.tool,
                            "-instances", [string]([int]$spec.instances),
                            "-idle-timeout", "5s",
                            "-verify-idle",
                            "-output", $familyEvidencePath
                        )
                        if ([bool]$spec.vanessaSmoke) { $probeArguments += @("-vanessa-ui-smoke", "-vanessa-feature", $vanessaSmokeFeature) }
                        & go @probeArguments
                        if ($LASTEXITCODE -ne 0) { throw "On-demand MCP live probe failed for $($spec.family)." }
                    } finally {
                        Pop-Location
                    }
                    $familyEvidence = Get-Content -LiteralPath $familyEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (-not [bool]$familyEvidence.cleanupPassed) { throw "On-demand MCP cleanup was not proven for $($spec.family)." }
                    if (-not [bool]$familyEvidence.idleCleanupPassed) { throw "On-demand MCP idle cleanup was not proven for $($spec.family)." }
                    if ([int]$familyEvidence.maxConcurrentSessions -lt 1 -or [int]$familyEvidence.maxConcurrentSessions -gt 3) {
                        throw "On-demand MCP exceeded maxConcurrentSessions=3 for $($spec.family): $([int]$familyEvidence.maxConcurrentSessions)."
                    }
                    if ([int64]$familyEvidence.ownedProcessExitWaitMs -lt 0 -or [int64]$familyEvidence.ownedProcessExitWaitMs -gt 15000) {
                        throw "On-demand MCP owned process exit exceeded 15000 ms for $($spec.family): $([int64]$familyEvidence.ownedProcessExitWaitMs) ms."
                    }
                    if ([int]$spec.instances -eq 2 -and -not [bool]$familyEvidence.secondSurvivedFirstClose) {
                        throw "The second Vanessa facade did not survive closing the first facade."
                    }
                    if ([bool]$spec.vanessaSmoke -and -not [bool]$familyEvidence.vanessaUiSmokePassed) {
                        throw "VanessaExt/TestClient/UI/screenshot smoke was not proven."
                    }
                    if ([bool]$spec.vanessaSmoke) {
                        $authoringOutcome = [string]$familyEvidence.vanessaFileAuthoringOutcome
                        if ($authoringOutcome -ne "passed") {
                            throw "Vanessa file authoring smoke did not pass: $authoringOutcome"
                        }
                        $reportedAuthoringFeature = [System.IO.Path]::GetFullPath([string]$familyEvidence.vanessaFeature)
                        $expectedAuthoringFeature = [System.IO.Path]::GetFullPath([string]$vanessaSmokeFeature)
                        if ($reportedAuthoringFeature -ne $expectedAuthoringFeature) {
                            throw "Vanessa file authoring smoke did not target the release feature."
                        }
                        $actualAuthoringCalls = @($familyEvidence.vanessaFileAuthoringCalls)
                        $expectedAuthoringCalls = @("open_feature_file:file", "check_syntax:file", "load_features:file")
                        if (($actualAuthoringCalls -join ",") -cne ($expectedAuthoringCalls -join ",")) {
                            throw "Vanessa file authoring smoke did not prove ordinary file authoring and file loading in the expected order."
                        }
                        foreach ($instance in @($familyEvidence.instances)) {
                            if ([string]$instance.vanessaAutomationCompatibilityVersion -cne [string]$canonicalVanessaLock.compatibilityVersion -or
                                [string]$instance.vanessaAutomationDownstreamRevision -cne [string]$canonicalVanessaLock.downstreamRevision -or
                                [string]$instance.vanessaAutomationArchiveSha256 -cne [string]$canonicalVanessaLock.sha256 -or
                                [string]$instance.vanessaAutomationEpfSha256 -cne [string]$canonicalVanessaLock.epfSha256 -or
                                $null -eq $instance.clientMcpSafeMode -or [bool]$instance.clientMcpSafeMode -or
                                $null -eq $instance.vaExtensionSafeMode -or [bool]$instance.vaExtensionSafeMode) {
                                throw "Vanessa live smoke did not use the exact workflow-pinned artifact or did not prove safe mode disabled for both MCP extensions."
                            }
                        }
                    }
                    $families[[string]$spec.family] = $familyEvidence
                }
                $onDemandMcpEvidence = [ordered]@{
                    schemaVersion = 2
                    facadeSha256 = [string]$facadeBuild.sha256
                    testFixture = $false
                    families = $families
                    capturedAt = [DateTime]::UtcNow.ToString("o")
                }
            }
            [System.IO.File]::WriteAllText($onDemandMcpEvidencePath, (($onDemandMcpEvidence | ConvertTo-Json -Depth 12) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            Set-E2EStageStatus -Name "ondemand-mcp" -Status "passed" -EvidencePath $onDemandMcpEvidencePath
        } catch {
            Set-E2EStageStatus -Name "ondemand-mcp" -Status "failed" -ErrorText $_.Exception.Message
            throw
        } finally {
            [IO.File]::WriteAllBytes($e2eDependencyLockPath, $e2eDependencyLockBytes)
        }
    } else {
        $resumedStages += "ondemand-mcp"
        Set-E2EStageReused -Name "ondemand-mcp" -Reason $(if ($crossReleaseReuse) { "exact stage fingerprint across workflow release" } else { "same release checkpoint" })
        $onDemandMcpEvidence = Get-Content -LiteralPath $onDemandMcpEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $onDemandMaxConcurrentSessions = [int]((@(
        [int]$onDemandMcpEvidence.families.roctup.maxConcurrentSessions,
        [int]$onDemandMcpEvidence.families.'vanessa-ui'.maxConcurrentSessions
    ) | Measure-Object -Maximum).Maximum)
    $onDemandOwnedProcessExitWaitMs = [int64]((@(
        [int64]$onDemandMcpEvidence.families.roctup.ownedProcessExitWaitMs,
        [int64]$onDemandMcpEvidence.families.'vanessa-ui'.ownedProcessExitWaitMs
    ) | Measure-Object -Maximum).Maximum)

    if ($crossReleaseReuse -and $executedStages -notcontains "config-cadence") {
        Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["postConfig"] -StateFiles $checkpoint["stateFiles"]["postConfig"]
        Set-E2EStageStatus -Name "verification-refresh" -Status "running"
        $executedStages += "verification-refresh"
        try {
            Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
                "-VanessaFeaturePath", $vanessaFixture.path, "-VanessaFilterTags", "@itl_release_flat"
            ) | Out-Null
            $refreshState = (Get-E2EState).value
            if ([string]$refreshState.lastVerificationStatus -ne "passed" -or -not [string]$refreshState.lastVerifiedAt) {
                throw "Cross-release verification refresh did not produce a passed verification."
            }
            # Result/export deliberately restores post-config state. Promote the
            # freshly verified state and infobase into that checkpoint first so
            # the restore cannot resurrect stale verification from the prior
            # workflow release.
            $checkpoint["stateFiles"]["postConfig"] = Save-E2EStateFiles -StateCopyPath $postConfigStateCopyPath -EnvCopyPath $postConfigEnvCopyPath
            $checkpoint["snapshots"]["postConfig"] = Invoke-E2EInfobaseSnapshot -Path $postConfigSnapshotPath
            Set-E2EStageStatus -Name "verification-refresh" -Status "passed"
        } catch {
            Set-E2EStageStatus -Name "verification-refresh" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } elseif ($executedStages -contains "config-cadence") {
        if (-not $checkpoint["stages"].Contains("verification-refresh")) { $checkpoint["stages"]["verification-refresh"] = [ordered]@{} }
        $refreshRecord = $checkpoint["stages"]["verification-refresh"]
        $refreshRecord["status"] = "passed"; $refreshRecord["execution"] = "reused"; $refreshRecord["reuseReason"] = "current config-cadence final passing check"
        $refreshRecord["fingerprint"] = Get-E2EStageFingerprint -Name "verification-refresh"; $refreshRecord["currentRunDurationMs"] = 0; $refreshRecord["updatedAt"] = [DateTime]::UtcNow.ToString("o")
        Write-E2ECheckpoint
    }

    $resultPassed = Test-E2EStagePassed -Name "result-cleanup"
    if ($checkpointWasResumed) { $resultPassed = $false; $invalidatedStages += "result-cleanup" }
    if (-not $resultPassed) {
        Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["postConfig"] -StateFiles $checkpoint["stateFiles"]["postConfig"]
        Set-E2EStageStatus -Name "result-cleanup" -Status "running"
        $executedStages += "result-cleanup"
        try {
            $statusResult = Invoke-E2EHelper -Action "status" -TimeoutSeconds 120 -AdditionalArguments @(
                "-VanessaFeaturePath", $vanessaFixture.path
            )
            $statusText = Get-Content -LiteralPath $statusResult.stdoutPath -Raw -Encoding UTF8
            if ($statusText -notmatch '(?im)^Verification fresh passed:\s*True\s*$') {
                throw "E2E /itl-check did not produce fresh passed verification."
            }

            $stateRecord = Get-E2EState
            $state = $stateRecord.value
            if ([string]$state.lastVerificationStatus -ne "passed") {
                throw "E2E state does not record passed verification."
            }
            $verifiedAt = [string]$state.lastVerifiedAt
            $verifiedCommit = [string]$state.lastVerifiedCommit
            $verificationFloor = $(if ($crossReleaseReuse) { $startedAt.ToUniversalTime() } else { [DateTime]::Parse([string]$checkpoint["createdAt"]).ToUniversalTime() })
            if (-not $verifiedAt -or ([DateTime]::Parse($verifiedAt).ToUniversalTime() -lt $verificationFloor)) {
                throw "E2E verification is not fresh for the checkpointed Release run."
            }

            Invoke-E2EHelper -Action "export-dev-branch-result" -TimeoutSeconds 7200 -AdditionalArguments @(
                "-VanessaFeaturePath", $vanessaFixture.path
            ) | Out-Null
            $stateRecord = Get-E2EState
            $state = $stateRecord.value
            $artifactPath = [string]$state.lastResultPath
            if (-not $artifactPath -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                throw "E2E export artifact was not recorded or does not exist."
            }
            $resultManifestPath = "$artifactPath.manifest.json"
            if (-not (Test-Path -LiteralPath $resultManifestPath -PathType Leaf)) {
                throw "E2E result manifest was not created: $resultManifestPath"
            }
            $manifest = Get-Content -LiteralPath $resultManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [bool]$manifest.verification.freshPassed -or [bool]$manifest.unverifiedOverride) {
                throw "E2E result manifest does not prove fresh passed verification without override."
            }
            $artifactSha256 = Get-E2EFileSha256 -Path $artifactPath
            if ($artifactSha256 -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) {
                throw "E2E artifact SHA256 does not match its result manifest."
            }
            $checkpoint["resultEvidence"] = [ordered]@{
                verifiedAt = $verifiedAt; verifiedCommit = $verifiedCommit
                artifactPath = $artifactPath; artifactSha256 = $artifactSha256
                manifestPath = $resultManifestPath; manifestSha256 = Get-E2EFileSha256 -Path $resultManifestPath
            }
            Set-E2EStageStatus -Name "result-cleanup" -Status "passed" -EvidencePath $resultManifestPath
        } catch {
            Set-E2EStageStatus -Name "result-cleanup" -Status "failed" -ErrorText $_.Exception.Message
            throw
        }
    } else {
        $resumedStages += "result-cleanup"
        Set-E2EStageReused -Name "result-cleanup" -Reason "same release checkpoint"
        $resultEvidence = $checkpoint["resultEvidence"]
        $verifiedAt = [string]$resultEvidence.verifiedAt
        $verifiedCommit = [string]$resultEvidence.verifiedCommit
        $artifactPath = [string]$resultEvidence.artifactPath
        $artifactSha256 = [string]$resultEvidence.artifactSha256
        $resultManifestPath = [string]$resultEvidence.manifestPath
        Assert-E2ECheckpointFile -Path $artifactPath -Sha256 $artifactSha256 -Label "result artifact"
        Assert-E2ECheckpointFile -Path $resultManifestPath -Sha256 ([string]$resultEvidence.manifestSha256) -Label "result manifest"
    }
    $sealedCapabilityPath = Save-E2ECapabilityCache
    Set-E2ECheckpointCapabilityEvidence -ManifestPath $sealedCapabilityPath
    $checkpoint["status"] = "passed"
    Write-E2ECheckpoint
} catch {
    $failure = $_.Exception.Message
    if ($_.InvocationInfo.ScriptLineNumber) {
        $failure += " (invoke-release-e2e.ps1:$($_.InvocationInfo.ScriptLineNumber))"
    }
} finally {
    $cleanupActions = @()
    foreach ($cleanupSpec in @(
        [pscustomobject]@{ action = "stop-dev-branch-test-clients"; arguments = @() },
        [pscustomobject]@{ action = "stop-ondemand-vanessa"; arguments = @("-InternalOnDemandOperation", "stop-all", "-InternalOnDemandFamily", "vanessa-ui") },
        [pscustomobject]@{ action = "stop-ondemand-roctup"; arguments = @("-InternalOnDemandOperation", "stop-all", "-InternalOnDemandFamily", "roctup") }
    )) {
        $action = [string]$cleanupSpec.action
        try {
            $helperAction = $(if ($action -eq "stop-dev-branch-test-clients") { $action } else { "help" })
            $cleanup = Invoke-E2EHelper -Action $helperAction -TimeoutSeconds 180 -AdditionalArguments @($cleanupSpec.arguments) -AllowFailure
            $cleanupActions += [ordered]@{ action = $action; exitCode = [int]$cleanup.exitCode }
            if ($cleanup.exitCode -ne 0) { $cleanupFailures += "$action exit=$($cleanup.exitCode)" }
        } catch {
            $cleanupActions += [ordered]@{ action = $action; exitCode = -1; error = $_.Exception.Message }
            $cleanupFailures += "$action $($_.Exception.Message)"
        }
    }
    if ($cleanupFailures.Count -gt 0 -and -not $failure) {
        $failure = "E2E cleanup failed: $($cleanupFailures -join '; ')"
    }
    $checkpoint["cleanup"] = [ordered]@{
        status = $(if ($cleanupFailures.Count -eq 0) { "passed" } else { "failed" })
        actions = @($cleanupActions)
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
    if ($failure) {
        $checkpoint["status"] = "failed"
        $checkpoint["error"] = $failure
        if ($cleanupFailures.Count -gt 0 -and $checkpoint["stages"].Contains("result-cleanup")) {
            $checkpoint["stages"]["result-cleanup"]["status"] = "failed"
            $checkpoint["stages"]["result-cleanup"]["error"] = "E2E cleanup failed: $($cleanupFailures -join '; ')"
        }
    } else {
        $checkpoint["status"] = "passed"
        $checkpoint["error"] = ""
    }
    try { Write-E2ECheckpoint } catch {
        if (-not $failure) { $failure = "Could not persist the final E2E checkpoint: $($_.Exception.Message)" }
    }

    $finishedAt = [DateTime]::UtcNow
    $summary = [ordered]@{
        schemaVersion = 3
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = $finishedAt.ToString("o")
        durationMs = [int64]($finishedAt - $startedAt).TotalMilliseconds
        resumeMode = $ResumeMode
        checkpointPath = $checkpointPath
        checkpointWasResumed = $checkpointWasResumed
        crossReleaseReuse = $crossReleaseReuse
        previousWorkflowCommit = $previousWorkflowCommit
        resumedStages = @($resumedStages)
        executedStages = @($executedStages)
        invalidatedStages = @($invalidatedStages | Sort-Object -Unique)
        stages = $checkpoint["stages"]
        generatedCommits = $checkpoint["generatedCommits"]
        snapshots = $checkpoint["snapshots"]
        cleanup = $checkpoint["cleanup"]
        workflowCommit = $workflowCommit
        workflowTree = $workflowTree
        runnerSha256 = $runnerSha256
        aiRulesCommit = $aiRulesCommit
        projectRoot = $ProjectRoot
        sourceSnapshotPath = $sourceSnapshotPath
        worktreePath = $worktreePath
        devBranchName = $devBranchName
        verifiedAt = $verifiedAt
        verifiedCommit = $verifiedCommit
        fixtureCommit = $fixtureCommit
        vanessaFixtureCommit = $vanessaFixtureCommit
        testOnlyCommit = $testOnlyCommit
        secondMetadataCommit = $secondMetadataCommit
        stopOnErrorProbeCommit = $stopOnErrorProbeCommit
        stopOnErrorRecoveryCommit = $stopOnErrorRecoveryCommit
        partialConfigDumpInfoCommit = $partialConfigDumpInfoCommit
        recoveryConfigDumpInfoCommit = $recoveryConfigDumpInfoCommit
        stopOnErrorProbeTests = $stopOnErrorProbeTests
        stopOnErrorProbeFailures = $stopOnErrorProbeFailures
        stopOnErrorProbeErrors = $stopOnErrorProbeErrors
        vanessaJUnitTests = $vanessaJUnitTests
        vanessaPostProcessDurationMs = $vanessaPostProcessDurationMs
        expectedComment = $expectedComment
        configLoadMode = "partial"
        configCadenceEvidencePath = $configCadenceEvidencePath
        seedParallelEvidencePath = $seedParallelEvidencePath
        seedParallelTestFixture = $(if ($seedParallelEvidence) { [bool]$seedParallelEvidence.testFixture } else { $false })
        seedParallelSyncId = $(if ($seedParallelEvidence) { [string]$seedParallelEvidence.seedSyncId } else { "" })
        seedParallelTargetMasterCommit = $(if ($seedParallelEvidence) { [string]$seedParallelEvidence.targetMasterCommit } else { "" })
        seedParallelBranchRuntimeConcurrent = $(if ($seedParallelEvidence) { [bool]$seedParallelEvidence.branchRuntimeConcurrent } else { $false })
        seedParallelLiteRefreshConcurrent = $(if ($seedParallelEvidence) { [bool]$seedParallelEvidence.liteRefreshConcurrent } else { $false })
        seedParallelLiteRefreshSourceCallCount = $(if ($seedParallelEvidence) { [int]$seedParallelEvidence.liteRefreshSourceCallCount } else { -1 })
        seedParallelBaselineCount = $(if ($seedParallelEvidence) { [int]$seedParallelEvidence.seedBaselineCount } else { 0 })
        roundtripEvidencePath = $roundtripEvidencePath
        roundtripParentConfigurationsPresent = $(if ($roundtripEvidence) { [bool]$roundtripEvidence.parentConfigurationsPresentInDump } else { $false })
        extensionSmokeEvidencePath = $extensionSmokeEvidencePath
        extensionSmokeName = $extensionSmokeName
        extensionEmptyInitialized = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.emptyInitialized } else { $false })
        extensionCfeCreated = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.cfeCreated } else { $false })
        extensionCfeInitialized = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.cfeInitialized } else { $false })
        extensionDatabaseRestored = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.databaseRestored } else { $false })
        extensionFormOperationsIdempotent = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.repeatedFormOperationsIdempotent } else { $false })
        extensionTemplateOperationsIdempotent = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.repeatedTemplateOperationsIdempotent } else { $false })
        extensionFormContentPreserved = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.formContentPreserved } else { $false })
        extensionFormModulePreserved = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.formModulePreserved } else { $false })
        extensionTemplateContentPreserved = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.templateContentPreserved } else { $false })
        extensionExplicitMetadataUpdatesPassed = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.explicitMetadataUpdatesPassed } else { $false })
        extensionFormRegistrationCount = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.formRegistrationCount } else { 0 })
        extensionTemplateRegistrationCount = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.templateRegistrationCount } else { 0 })
        extensionUiTestClientPassed = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.extensionUiTestClientPassed } else { $false })
        extensionUiJunitTests = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.extensionUiJunitTests } else { 0 })
        extensionUiReportPath = $(if ($extensionSmokeEvidence) { [string]$extensionSmokeEvidence.extensionUiReportPath } else { "" })
        onDemandMcpEvidencePath = $onDemandMcpEvidencePath
        onDemandRoctupToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.roctup.catalogToolCount } else { 0 })
        onDemandVanessaToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.'vanessa-ui'.catalogToolCount } else { 0 })
        onDemandRoctupPublicToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.roctup.publicToolCount } else { 0 })
        onDemandVanessaPublicToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.'vanessa-ui'.publicToolCount } else { 0 })
        onDemandVanessaInstances = $(if ($onDemandMcpEvidence) { @($onDemandMcpEvidence.families.'vanessa-ui'.instances).Count } else { 0 })
        onDemandVanessaSecondSurvived = $(if ($onDemandMcpEvidence) { [bool]$onDemandMcpEvidence.families.'vanessa-ui'.secondSurvivedFirstClose } else { $false })
        maxConcurrentSessions = $onDemandMaxConcurrentSessions
        ownedProcessExitWaitMs = $onDemandOwnedProcessExitWaitMs
        onDemandMcpTestFixture = $(if ($onDemandMcpEvidence) { [bool]$onDemandMcpEvidence.testFixture } else { $false })
        artifactPath = $artifactPath
        artifactSha256 = $artifactSha256
        resultManifestPath = $resultManifestPath
        cleanupFailures = @($cleanupFailures)
        error = $failure
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)
}

if ($failure) {
    [Console]::Error.WriteLine($failure)
    exit 1
}
Write-Host "Release E2E passed. Summary: $OutputPath"
