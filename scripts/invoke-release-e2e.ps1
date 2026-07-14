[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$AiRulesSource,
    [string]$HelperPath = "",
    [string]$OutputPath = ""
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

    return [pscustomobject]@{
        commit = (& git -C $worktreePath rev-parse HEAD).Trim()
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
    return [pscustomobject]@{ path = $featurePath; commit = (& git -C $worktreePath rev-parse HEAD).Trim() }
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
    return (& git -C $worktreePath rev-parse HEAD).Trim()
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

try {
    $branch = (& git -C $worktreePath branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -notlike "itldev/*") {
        throw "E2E worktree must be an itldev/* Git worktree: $worktreePath"
    }
    if (@(& git -C $worktreePath status --porcelain).Count -gt 0) {
        throw "E2E worktree must be clean before release verification."
    }
    [void](Get-E2EState)
    $fixture = New-E2ERootConfigurationCommentCommit
    $fixtureCommit = $fixture.commit
    $expectedComment = $fixture.comment
    $vanessaFixture = New-E2EVanessaFixtureCommit
    $vanessaFixtureCommit = $vanessaFixture.commit

    Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
        "-ConfigLoadMode", "Partial",
        "-VanessaFeaturePath", $vanessaFixture.path,
        "-VanessaFilterTags", "@itl_release_flat"
    ) | Out-Null
    $partialState = (Get-E2EState).value
    if ([string]$partialState.configLoadStatus -ne "passed" -or [string]$partialState.lastConfigLoadMode -ne "partial") {
        throw "Release E2E did not record a successful partial config load."
    }
    $partialListPath = [string]$partialState.lastConfigBaseUpdateListFile
    if (-not $partialListPath -or -not (Test-Path -LiteralPath $partialListPath -PathType Leaf)) {
        throw "Release E2E partial load list was not preserved."
    }
    $partialFiles = @(Get-Content -LiteralPath $partialListPath -Encoding UTF8 | Where-Object { $_ -ne "" })
    if ($partialFiles.Count -ne 1 -or [string]$partialFiles[0] -ne "Configuration.xml") {
        throw "Release E2E partial list must contain only Configuration.xml; actual: $($partialFiles -join ', ')"
    }
    $designerLoadedAt = [string]$partialState.lastConfigDesignerLoadedAt
    if (-not $designerLoadedAt) { throw "Release E2E did not persist the configuration Designer fingerprint timestamp." }

    $testOnlyCommit = Add-E2ETestOnlyCommit -FeaturePath $vanessaFixture.path
    Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
        "-VanessaFeaturePath", $vanessaFixture.path,
        "-VanessaFilterTags", "@itl_release_flat"
    ) | Out-Null
    $testOnlyState = (Get-E2EState).value
    if ([string]$testOnlyState.lastConfigDesignerLoadedAt -ne $designerLoadedAt -or [bool]$testOnlyState.designerInvoked -or [bool]$testOnlyState.enterpriseInvoked) {
        throw "Release E2E test-only iteration invoked Designer or Enterprise instead of running Vanessa only."
    }
    $junit = Get-E2EJunitTotals -RunDirectory ([string]$testOnlyState.lastVanessaReportPath)
    $vanessaJUnitTests = $junit.tests
    if ($junit.tests -ne 4 -or ($junit.failures + $junit.errors) -ne 0) {
        throw "Release E2E four flat scenarios must produce exactly four passing JUnit tests; tests=$($junit.tests), failures=$($junit.failures), errors=$($junit.errors)."
    }
    $vanessaPostProcessDurationMs = [int64]$testOnlyState.lastVanessaPostProcessDurationMs
    if ($vanessaPostProcessDurationMs -gt 30000) {
        throw "Release E2E Vanessa post-processing exceeded 30 seconds: $vanessaPostProcessDurationMs ms."
    }

    $stopOnErrorProbeCommit = Set-E2EVanessaFailureProbeCommit -FeaturePath $vanessaFixture.path -Fail $true
    $stopOnErrorProbe = Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AllowFailure -AdditionalArguments @(
        "-VanessaFeaturePath", $vanessaFixture.path,
        "-VanessaFilterTags", "@itl_release_flat"
    )
    if ($stopOnErrorProbe.exitCode -eq 0) {
        throw "Release E2E stop-on-error probe unexpectedly passed despite one deliberately failing scenario (exit=$($stopOnErrorProbe.exitCode), resultCount=$(@($stopOnErrorProbe).Count))."
    }
    $stopOnErrorProbeState = (Get-E2EState).value
    if ([string]$stopOnErrorProbeState.lastConfigDesignerLoadedAt -ne $designerLoadedAt -or [bool]$stopOnErrorProbeState.designerInvoked -or [bool]$stopOnErrorProbeState.enterpriseInvoked) {
        throw "Release E2E stop-on-error probe invoked Designer or Enterprise for a feature-only change."
    }
    $stopOnErrorJunit = Get-E2EJunitTotals -RunDirectory ([string]$stopOnErrorProbeState.lastVanessaReportPath)
    $stopOnErrorProbeTests = $stopOnErrorJunit.tests
    $stopOnErrorProbeFailures = $stopOnErrorJunit.failures
    $stopOnErrorProbeErrors = $stopOnErrorJunit.errors
    if ($stopOnErrorProbeTests -ne 4 -or ($stopOnErrorProbeFailures + $stopOnErrorProbeErrors) -ne 1) {
        throw "stoponerror=false did not preserve all four independent JUnit results; tests=$stopOnErrorProbeTests, failures=$stopOnErrorProbeFailures, errors=$stopOnErrorProbeErrors."
    }
    if ([int64]$stopOnErrorProbeState.lastVanessaPostProcessDurationMs -gt 30000) {
        throw "Release E2E failed-scenario post-processing exceeded 30 seconds: $($stopOnErrorProbeState.lastVanessaPostProcessDurationMs) ms."
    }

    $stopOnErrorRecoveryCommit = Set-E2EVanessaFailureProbeCommit -FeaturePath $vanessaFixture.path -Fail $false
    Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @(
        "-VanessaFeaturePath", $vanessaFixture.path,
        "-VanessaFilterTags", "@itl_release_flat"
    ) | Out-Null
    $recoveryState = (Get-E2EState).value
    if ([string]$recoveryState.lastConfigDesignerLoadedAt -ne $designerLoadedAt -or [bool]$recoveryState.designerInvoked -or [bool]$recoveryState.enterpriseInvoked) {
        throw "Release E2E passing recovery invoked Designer or Enterprise for a feature-only change."
    }
    $recoveryJunit = Get-E2EJunitTotals -RunDirectory ([string]$recoveryState.lastVanessaReportPath)
    $vanessaJUnitTests = $recoveryJunit.tests
    $vanessaPostProcessDurationMs = [int64]$recoveryState.lastVanessaPostProcessDurationMs
    if ($vanessaJUnitTests -ne 4 -or ($recoveryJunit.failures + $recoveryJunit.errors) -ne 0) {
        throw "Release E2E recovery must restore four passing JUnit tests; tests=$vanessaJUnitTests, failures=$($recoveryJunit.failures), errors=$($recoveryJunit.errors)."
    }
    if ($vanessaPostProcessDurationMs -gt 30000) {
        throw "Release E2E recovery post-processing exceeded 30 seconds: $vanessaPostProcessDurationMs ms."
    }

    $roundtripEvidencePath = Join-Path $worktreePath "build\test-results\release-e2e\config-roundtrip.json"
    Remove-Item -LiteralPath $roundtripEvidencePath -Force -ErrorAction SilentlyContinue
    Invoke-E2EHelper -Action "release-e2e-config-roundtrip" -TimeoutSeconds 7200 | Out-Null
    if (-not (Test-Path -LiteralPath $roundtripEvidencePath -PathType Leaf)) {
        throw "Release E2E roundtrip evidence was not created: $roundtripEvidencePath"
    }
    $roundtripEvidence = Get-Content -LiteralPath $roundtripEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$roundtripEvidence.parentConfigurationsPresentInDump -or [string]$roundtripEvidence.actualComment -cne $expectedComment) {
        throw "Release E2E roundtrip evidence does not prove Comment and ParentConfigurations.bin preservation."
    }

    $extensionSmokeEvidencePath = Join-Path $worktreePath "build\test-results\release-e2e\extension-smoke.json"
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
        -not [bool]$extensionSmokeEvidence.extensionUiTestClientPassed -or
        [int]$extensionSmokeEvidence.formRegistrationCount -ne 1 -or
        [int]$extensionSmokeEvidence.templateRegistrationCount -ne 1 -or
        [int]$extensionSmokeEvidence.extensionUiJunitTests -ne 1 -or
        [string]$extensionSmokeEvidence.extensionName -ne $extensionSmokeName) {
        throw "Release E2E extension evidence does not prove Empty/CFE roundtrip, idempotent form/template operations, real TestClient UI, and database restoration."
    }

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
    if (-not $verifiedAt -or ([DateTime]::Parse($verifiedAt).ToUniversalTime() -lt $startedAt)) {
        throw "E2E verification is not fresh for the current Release run."
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
    $artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($artifactSha256 -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) {
        throw "E2E artifact SHA256 does not match its result manifest."
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    foreach ($action in @("stop-dev-branch-test-clients", "stop-vanessa-mcp", "stop-roctup-mcp")) {
        try {
            $cleanup = Invoke-E2EHelper -Action $action -TimeoutSeconds 180 -AllowFailure
            if ($cleanup.exitCode -ne 0) { $cleanupFailures += "$action exit=$($cleanup.exitCode)" }
        } catch {
            $cleanupFailures += "$action $($_.Exception.Message)"
        }
    }
    if ($cleanupFailures.Count -gt 0 -and -not $failure) {
        $failure = "E2E cleanup failed: $($cleanupFailures -join '; ')"
    }

    $summary = [ordered]@{
        schemaVersion = 1
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        projectRoot = $ProjectRoot
        sourceSnapshotPath = $sourceSnapshotPath
        worktreePath = $worktreePath
        devBranchName = $devBranchName
        verifiedAt = $verifiedAt
        verifiedCommit = $verifiedCommit
        fixtureCommit = $fixtureCommit
        vanessaFixtureCommit = $vanessaFixtureCommit
        testOnlyCommit = $testOnlyCommit
        stopOnErrorProbeCommit = $stopOnErrorProbeCommit
        stopOnErrorRecoveryCommit = $stopOnErrorRecoveryCommit
        stopOnErrorProbeTests = $stopOnErrorProbeTests
        stopOnErrorProbeFailures = $stopOnErrorProbeFailures
        stopOnErrorProbeErrors = $stopOnErrorProbeErrors
        vanessaJUnitTests = $vanessaJUnitTests
        vanessaPostProcessDurationMs = $vanessaPostProcessDurationMs
        expectedComment = $expectedComment
        configLoadMode = "partial"
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
        extensionFormRegistrationCount = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.formRegistrationCount } else { 0 })
        extensionTemplateRegistrationCount = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.templateRegistrationCount } else { 0 })
        extensionUiTestClientPassed = $(if ($extensionSmokeEvidence) { [bool]$extensionSmokeEvidence.extensionUiTestClientPassed } else { $false })
        extensionUiJunitTests = $(if ($extensionSmokeEvidence) { [int]$extensionSmokeEvidence.extensionUiJunitTests } else { 0 })
        extensionUiReportPath = $(if ($extensionSmokeEvidence) { [string]$extensionSmokeEvidence.extensionUiReportPath } else { "" })
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
