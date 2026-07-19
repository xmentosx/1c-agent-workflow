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
$vanessaJUnitTests = 0
$vanessaPostProcessDurationMs = 0
$expectedComment = ""
$roundtripEvidencePath = ""
$roundtripEvidence = $null
$extensionSmokeEvidencePath = ""
$extensionSmokeEvidence = $null
$onDemandMcpEvidencePath = Join-Path $outputRoot "ondemand-mcp.json"
$onDemandMcpEvidence = $null
$onDemandMcpTestFixture = [Environment]::GetEnvironmentVariable("ITL_TEST_RELEASE_ONDEMAND_PROBE") -eq "true"
$configCadenceEvidencePath = Join-Path $outputRoot "config-cadence.json"
$extensionSmokeName = "ITLReleaseSmoke" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-E2EHelper {
    param(
        [string]$Action,
        [int]$TimeoutSeconds,
        [string[]]$AdditionalArguments = @(),
        [switch]$AllowFailure
    )
    $stdoutPath = Join-Path $outputRoot ($Action + ".stdout.log")
    $stderrPath = Join-Path $outputRoot ($Action + ".stderr.log")
    $parts = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (ConvertTo-NativeArgument $HelperPath),
        "-ProjectRoot", (ConvertTo-NativeArgument $worktreePath),
        "-Action", (ConvertTo-NativeArgument $Action),
        "-DevBranchName", (ConvertTo-NativeArgument $devBranchName)
    )
    foreach ($argument in @($AdditionalArguments)) {
        $parts += (ConvertTo-NativeArgument ([string]$argument))
    }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($parts -join " ") `
        -WorkingDirectory $worktreePath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath -PassThru
    # Windows PowerShell 5.1 may expose a null ExitCode after timed WaitForExit
    # unless the native process handle is materialized before the wait.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        if ($AllowFailure) { return [pscustomobject]@{ exitCode = -1; stdoutPath = $stdoutPath; stderrPath = $stderrPath } }
        throw "$Action timed out after $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$Action failed with exit code $exitCode. See $stdoutPath and $stderrPath"
    }
    return [pscustomobject]@{ exitCode = $exitCode; stdoutPath = $stdoutPath; stderrPath = $stderrPath }
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
    $roots = @($ProjectRoot, $worktreePath) | Sort-Object -Unique
    foreach ($root in $roots) {
        $stateRoot = Join-Path $root ".agent-1c\dev-branches"
        foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
            try {
                $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$state.devBranchName -eq $devBranchName -or [string]$state.devBranch -eq "itldev/$devBranchName") {
                    return [pscustomobject]@{ value = $state; path = $file.FullName }
                }
            } catch {}
        }
    }
    throw "Development branch state was not found for E2E branch '$devBranchName'."
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
    Copy-Item -LiteralPath ([string]$Record.stateCopyPath) -Destination ([string]$Record.actualStatePath) -Force
    if ([string]$Record.envCopyPath) {
        Assert-E2ECheckpointFile -Path ([string]$Record.envCopyPath) -Sha256 ([string]$Record.envSha256) -Label "saved .dev.env"
        Copy-Item -LiteralPath ([string]$Record.envCopyPath) -Destination ([string]$Record.actualEnvPath) -Force
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
    $record["status"] = $Status
    $record["updatedAt"] = [DateTime]::UtcNow.ToString("o")
    $record["error"] = $ErrorText
    $record["evidencePath"] = $EvidencePath
    $record["evidenceSha256"] = Get-E2EFileSha256 -Path $EvidencePath
    $checkpoint["expectedHead"] = (& git -C $worktreePath rev-parse HEAD).Trim()
    if ($Status -eq "passed") { $checkpoint["lastPassedStage"] = $Name }
    Write-E2ECheckpoint
}

function Test-E2EStagePassed {
    param([string]$Name)
    if (-not $checkpoint["stages"].Contains($Name)) { return $false }
    $record = $checkpoint["stages"][$Name]
    if ([string]$record.status -ne "passed") { return $false }
    if ([string]$record.evidencePath) {
        Assert-E2ECheckpointFile -Path ([string]$record.evidencePath) -Sha256 ([string]$record.evidenceSha256) -Label "$Name evidence"
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

$branch = (& git -C $worktreePath branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -notlike "itldev/*") { throw "E2E worktree must be an itldev/* Git worktree: $worktreePath" }
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
$workflowRoot = Split-Path -Parent $PSScriptRoot
$workflowCommit = (& git -C $workflowRoot rev-parse HEAD).Trim()
$workflowTree = (& git -C $workflowRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or -not $workflowCommit -or -not $workflowTree) { throw "Release workflow source is not a readable Git checkout: $workflowRoot" }
$runnerSha256 = Get-E2EFileSha256 -Path $PSCommandPath
$helperSha256 = Get-E2EFileSha256 -Path $HelperPath
$projectConfigSha256 = Get-E2EFileSha256 -Path (Join-Path $worktreePath ".agent-1c\project.json")

if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
    try { $checkpoint = ConvertTo-E2EHashtable (Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint is corrupt: $checkpointPath. $($_.Exception.Message)" }
}

if ($checkpoint) {
    $identity = $checkpoint["identity"]
    $scopeMatches = [int]$checkpoint["schemaVersion"] -eq 1 -and
        [string]$identity.projectRoot -eq $ProjectRoot -and
        [string]$identity.worktreePath -eq $worktreePath -and
        [string]$identity.branch -eq $branch
    if (-not $scopeMatches) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint belongs to another project/worktree/branch." }
    $releaseIdentityMatches =
        [string]$identity.workflowCommit -eq $workflowCommit -and
        [string]$identity.workflowTree -eq $workflowTree -and
        [string]$identity.runnerSha256 -eq $runnerSha256 -and
        [string]$identity.aiRulesCommit -eq $aiRulesCommit -and
        [string]$identity.helperSha256 -eq $helperSha256 -and
        [string]$identity.projectConfigSha256 -eq $projectConfigSha256
    if ($ResumeMode -eq "Auto" -and -not $releaseIdentityMatches) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: checkpoint identity does not match the current workflow/fork/helper/project config. Use -ResumeMode Restart for the scripted baseline rollback." }
    $currentHead = (& git -C $worktreePath rev-parse HEAD).Trim()
    if ($currentHead -ne [string]$checkpoint["expectedHead"]) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: current HEAD '$currentHead' differs from checkpoint HEAD '$($checkpoint['expectedHead'])'." }

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
    } else {
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
        schemaVersion = 1
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
    }
    Write-E2ECheckpoint
    $checkpoint["snapshots"]["baseline"] = Invoke-E2EInfobaseSnapshot -Path $baselineSnapshotPath
    Write-E2ECheckpoint
}

try {
    [void](Get-E2EState)
    if (-not (Test-E2EStagePassed -Name "config-cadence")) {
        if ($checkpoint["stages"].Contains("config-cadence")) {
            Restore-E2EInfobaseSnapshot -Snapshot $checkpoint["snapshots"]["baseline"] -StateFiles $checkpoint["stateFiles"]["baseline"]
            & git -C $worktreePath reset --hard ([string]$checkpoint["identity"]["initialHead"]) *> $null
            if ($LASTEXITCODE -ne 0) { throw "RELEASE_E2E_RESUME_STATE_MISMATCH: could not restore config-cadence baseline." }
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
                "-VanessaFeaturePath", $vanessaFixture.path, "-VanessaFilterTags", "@itl_release_flat"
            ) | Out-Null
            $recoveryState = (Get-E2EState).value
            if (-not [bool]$recoveryState.designerInvoked -or -not [bool]$recoveryState.enterpriseInvoked -or [string]$recoveryState.lastConfigDesignerLoadedAt -eq $designerLoadedAt) { throw "Release E2E second metadata plus feature recovery did not invoke Designer and Enterprise." }
            $recoveryJunit = Get-E2EJunitTotals -RunDirectory ([string]$recoveryState.lastVanessaReportPath)
            $vanessaJUnitTests = $recoveryJunit.tests
            $vanessaPostProcessDurationMs = [int64]$recoveryState.lastVanessaPostProcessDurationMs
            if ($vanessaJUnitTests -ne 4 -or ($recoveryJunit.failures + $recoveryJunit.errors) -ne 0) { throw "Release E2E recovery must restore four passing JUnit tests." }
            if ($vanessaPostProcessDurationMs -gt 30000) { throw "Release E2E recovery post-processing exceeded 30 seconds: $vanessaPostProcessDurationMs ms." }

            $checkpoint["stateFiles"]["postConfig"] = Save-E2EStateFiles -StateCopyPath $postConfigStateCopyPath -EnvCopyPath $postConfigEnvCopyPath
            $checkpoint["snapshots"]["postConfig"] = Invoke-E2EInfobaseSnapshot -Path $postConfigSnapshotPath
            $checkpoint["configEvidence"] = [ordered]@{
                fixtureCommit = $fixtureCommit; vanessaFixtureCommit = $vanessaFixtureCommit; testOnlyCommit = $testOnlyCommit
                secondMetadataCommit = $secondMetadataCommit; recoveryCommit = $stopOnErrorRecoveryCommit
                featurePath = $vanessaFixture.path; expectedComment = $expectedComment; designerLoadedAt = [string]$recoveryState.lastConfigDesignerLoadedAt
                junitTests = $vanessaJUnitTests; postProcessDurationMs = $vanessaPostProcessDurationMs
                probeTests = $stopOnErrorProbeTests; probeFailures = $stopOnErrorProbeFailures; probeErrors = $stopOnErrorProbeErrors
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
        $configEvidence = $checkpoint["configEvidence"]
        $fixtureCommit = [string]$configEvidence.fixtureCommit; $vanessaFixtureCommit = [string]$configEvidence.vanessaFixtureCommit
        $testOnlyCommit = [string]$configEvidence.testOnlyCommit; $secondMetadataCommit = [string]$configEvidence.secondMetadataCommit
        $stopOnErrorProbeCommit = $testOnlyCommit
        $stopOnErrorRecoveryCommit = [string]$configEvidence.recoveryCommit; $expectedComment = [string]$configEvidence.expectedComment
        $vanessaJUnitTests = [int]$configEvidence.junitTests; $vanessaPostProcessDurationMs = [int64]$configEvidence.postProcessDurationMs
        $stopOnErrorProbeTests = [int]$configEvidence.probeTests; $stopOnErrorProbeFailures = [int]$configEvidence.probeFailures; $stopOnErrorProbeErrors = [int]$configEvidence.probeErrors
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
        $extensionSmokeEvidence = Get-Content -LiteralPath $extensionSmokeEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if (-not (Test-E2EStagePassed -Name "ondemand-mcp")) {
        Set-E2EStageStatus -Name "ondemand-mcp" -Status "running"
        $executedStages += "ondemand-mcp"
        try {
            if ($onDemandMcpTestFixture) {
                $onDemandMcpEvidence = [ordered]@{
                    schemaVersion = 1
                    facadeSha256 = ("0" * 64)
                    testFixture = $true
                    families = [ordered]@{
                        roctup = [ordered]@{ toolCount = 13; instances = @([ordered]@{ pid = 101; port = 6003 }); cleanupPassed = $true; secondSurvivedFirstClose = $false }
                        "vanessa-ui" = [ordered]@{ toolCount = 38; instances = @([ordered]@{ pid = 201; port = 9876 }, [ordered]@{ pid = 202; port = 9877 }); cleanupPassed = $true; secondSurvivedFirstClose = $true }
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
                    [pscustomobject]@{ family = "roctup"; tool = "get_metadata"; instances = 1 },
                    [pscustomobject]@{ family = "vanessa-ui"; tool = "get_VanessaAutomation_state"; instances = 2 }
                )) {
                    $definition = $compatibility.families.([string]$spec.family)
                    $catalogPath = Join-Path $compatibilityRoot ([string]$definition.catalog)
                    $familyEvidencePath = Join-Path $outputRoot ("ondemand-mcp-{0}.json" -f $spec.family)
                    Push-Location $probeRoot
                    try {
                        & go run .\cmd\itl-ondemand-probe `
                            -exe ([string]$facadeBuild.path) `
                            -family ([string]$spec.family) `
                            -project-root $worktreePath `
                            -catalog $catalogPath `
                            -helper $HelperPath `
                            -tool ([string]$spec.tool) `
                            -instances ([int]$spec.instances) `
                            -output $familyEvidencePath
                        if ($LASTEXITCODE -ne 0) { throw "On-demand MCP live probe failed for $($spec.family)." }
                    } finally {
                        Pop-Location
                    }
                    $familyEvidence = Get-Content -LiteralPath $familyEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (-not [bool]$familyEvidence.cleanupPassed) { throw "On-demand MCP cleanup was not proven for $($spec.family)." }
                    if ([int]$spec.instances -eq 2 -and -not [bool]$familyEvidence.secondSurvivedFirstClose) {
                        throw "The second Vanessa facade did not survive closing the first facade."
                    }
                    $families[[string]$spec.family] = $familyEvidence
                }
                $onDemandMcpEvidence = [ordered]@{
                    schemaVersion = 1
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
        }
    } else {
        $resumedStages += "ondemand-mcp"
        $onDemandMcpEvidence = Get-Content -LiteralPath $onDemandMcpEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if (-not (Test-E2EStagePassed -Name "result-cleanup")) {
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
            $verificationFloor = [DateTime]::Parse([string]$checkpoint["createdAt"]).ToUniversalTime()
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
        $resultEvidence = $checkpoint["resultEvidence"]
        $verifiedAt = [string]$resultEvidence.verifiedAt
        $verifiedCommit = [string]$resultEvidence.verifiedCommit
        $artifactPath = [string]$resultEvidence.artifactPath
        $artifactSha256 = [string]$resultEvidence.artifactSha256
        $resultManifestPath = [string]$resultEvidence.manifestPath
        Assert-E2ECheckpointFile -Path $artifactPath -Sha256 $artifactSha256 -Label "result artifact"
        Assert-E2ECheckpointFile -Path $resultManifestPath -Sha256 ([string]$resultEvidence.manifestSha256) -Label "result manifest"
    }
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

    $summary = [ordered]@{
        schemaVersion = 2
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        resumeMode = $ResumeMode
        checkpointPath = $checkpointPath
        checkpointWasResumed = $checkpointWasResumed
        resumedStages = @($resumedStages)
        executedStages = @($executedStages)
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
        stopOnErrorProbeTests = $stopOnErrorProbeTests
        stopOnErrorProbeFailures = $stopOnErrorProbeFailures
        stopOnErrorProbeErrors = $stopOnErrorProbeErrors
        vanessaJUnitTests = $vanessaJUnitTests
        vanessaPostProcessDurationMs = $vanessaPostProcessDurationMs
        expectedComment = $expectedComment
        configLoadMode = "partial"
        configCadenceEvidencePath = $configCadenceEvidencePath
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
        onDemandRoctupToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.roctup.toolCount } else { 0 })
        onDemandVanessaToolCount = $(if ($onDemandMcpEvidence) { [int]$onDemandMcpEvidence.families.'vanessa-ui'.toolCount } else { 0 })
        onDemandVanessaInstances = $(if ($onDemandMcpEvidence) { @($onDemandMcpEvidence.families.'vanessa-ui'.instances).Count } else { 0 })
        onDemandVanessaSecondSurvived = $(if ($onDemandMcpEvidence) { [bool]$onDemandMcpEvidence.families.'vanessa-ui'.secondSurvivedFirstClose } else { $false })
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
