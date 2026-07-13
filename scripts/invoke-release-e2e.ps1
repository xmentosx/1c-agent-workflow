[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$HelperPath = "",
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
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
$expectedComment = ""
$roundtripEvidencePath = ""
$roundtripEvidence = $null

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

    Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @("-ConfigLoadMode", "Partial") | Out-Null
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

    Invoke-E2EHelper -Action "release-e2e-config-roundtrip" -TimeoutSeconds 7200 | Out-Null
    $roundtripEvidencePath = Join-Path $worktreePath "build\test-results\release-e2e\config-roundtrip.json"
    if (-not (Test-Path -LiteralPath $roundtripEvidencePath -PathType Leaf)) {
        throw "Release E2E roundtrip evidence was not created: $roundtripEvidencePath"
    }
    $roundtripEvidence = Get-Content -LiteralPath $roundtripEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$roundtripEvidence.parentConfigurationsPresentInDump -or [string]$roundtripEvidence.actualComment -cne $expectedComment) {
        throw "Release E2E roundtrip evidence does not prove Comment and ParentConfigurations.bin preservation."
    }

    $statusResult = Invoke-E2EHelper -Action "status" -TimeoutSeconds 120
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

    Invoke-E2EHelper -Action "export-dev-branch-result" -TimeoutSeconds 7200 | Out-Null
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
        expectedComment = $expectedComment
        configLoadMode = "partial"
        roundtripEvidencePath = $roundtripEvidencePath
        roundtripParentConfigurationsPresent = $(if ($roundtripEvidence) { [bool]$roundtripEvidence.parentConfigurationsPresentInDump } else { $false })
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
    Write-Error $failure
    exit 1
}
Write-Host "Release E2E passed. Summary: $OutputPath"
