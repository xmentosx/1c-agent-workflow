function Get-VanessaInstallRoot {
    $value = Get-Setting -EnvName "VANESSA_AUTOMATION_ROOT" -ConfigName "vanessaAutomation.installRoot" -Default ".agent-1c/tools/vanessa-automation"
    return (Resolve-ProjectPath ([string]$value))
}

function Get-VanessaFeaturesPath {
    if ($VanessaFeaturePath) {
        return $VanessaFeaturePath
    }

    $value = Get-Setting -EnvName "VANESSA_FEATURES_PATH" -ConfigName "vanessaAutomation.featuresPath" -Default (Get-ConfigValue -Path "testsPath" -Default "tests/features")
    return [string]$value
}

function Get-VanessaReportsPath {
    $value = Get-Setting -EnvName "VANESSA_REPORTS_PATH" -ConfigName "vanessaAutomation.reportsPath" -Default (Get-ConfigValue -Path "testResultsPath" -Default "build/test-results/vanessa")
    return [string]$value
}

function Find-VanessaAutomationEpf {
    param([string]$Root)

    if (-not $Root -or -not (Test-Path -LiteralPath $Root -ErrorAction SilentlyContinue)) {
        return ""
    }

    if (Test-Path -LiteralPath $Root -PathType Leaf -ErrorAction SilentlyContinue) {
        if ($Root -like "*.epf") {
            return [System.IO.Path]::GetFullPath($Root)
        }
        return ""
    }

    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.epf" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "vanessa|automation|single" } |
        Sort-Object @{ Expression = { if ($_.Name -match "single") { 0 } else { 1 } } }, FullName)
    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }

    $fallback = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.epf" -ErrorAction SilentlyContinue | Sort-Object FullName)
    if ($fallback.Count -gt 0) {
        return $fallback[0].FullName
    }

    return ""
}

function Get-VanessaAutomationEpfPath {
    $configured = Get-Setting -EnvName "VANESSA_AUTOMATION_EPF" -ConfigName "vanessaAutomation.epfPath"
    if ($configured) {
        $path = [Environment]::ExpandEnvironmentVariables(([string]$configured).Trim())
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Resolve-ProjectPath $path
        }
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
            return [System.IO.Path]::GetFullPath($path)
        }
    }

    return Find-VanessaAutomationEpf -Root (Get-VanessaInstallRoot)
}

function Get-VanessaAutomationState {
    $epfPath = Get-VanessaAutomationEpfPath
    $version = Get-Setting -EnvName "VANESSA_AUTOMATION_VERSION" -ConfigName "vanessaAutomation.version" -Default ""
    if ($epfPath -and (Test-Path -LiteralPath $epfPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            ready = $true
            epfPath = $epfPath
            version = [string]$version
            message = "Vanessa Automation EPF found."
        }
    }

    return [pscustomobject]@{
        ready = $false
        epfPath = ""
        version = [string]$version
        message = "Vanessa Automation EPF was not found. Run install-vanessa-automation."
    }
}

function Get-VanessaAutomationDownloadInfo {
    if ((Get-DependencyMode) -eq "locked") {
        $locked = Get-DependencyLockEntry -Name "vanessaAutomation"
        $url = [string](Get-ConfigValueFromObject -Object $locked -Path "url" -Default "")
        if (-not $url) {
            throw "Dependency mode is locked, but vanessaAutomation.url is empty in .agent-1c/dependency-lock.json."
        }
        return [pscustomobject]@{
            url = $url
            version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
            expectedSha256 = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
            source = "dependency-lock"
        }
    }

    $override = Get-EnvValue -Name "VANESSA_AUTOMATION_ARCHIVE_URL"
    if ($override) {
        return [pscustomobject]@{
            url = [string]$override
            version = ""
            expectedSha256 = ""
            source = "VANESSA_AUTOMATION_ARCHIVE_URL"
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # Best effort for older Windows PowerShell hosts.
    }

    try {
        $release = Invoke-GitHubApiRestMethod -Uri "https://api.github.com/repos/Pr-Mex/vanessa-automation/releases/latest"
        $asset = @($release.assets | Where-Object { $_.name -like "vanessa-automation-single*.zip" } | Select-Object -First 1)
        if ($asset.Count -gt 0) {
            return [pscustomobject]@{
                url = [string]$asset[0].browser_download_url
                version = [string]$release.tag_name
                expectedSha256 = ""
                source = "GitHub releases Pr-Mex/vanessa-automation"
            }
        }
    } catch {
        $failure = Get-GitHubApiFailureInfo -ErrorRecord $_
        if ($failure.rateLimited) {
            $fallback = Get-DependencyLockRateLimitFallbackInfo -LockPath "vanessaAutomation" -DefaultFileName "vanessa-automation-single.zip"
            if ($fallback) {
                Write-Warning "GitHub API rate limit reached; using the Vanessa Automation dependency-lock fallback."
                return $fallback
            }
            throw (Get-GitHubRateLimitRecoveryMessage -Operation "resolving the latest Vanessa Automation release" -FailureInfo $failure)
        }
        Write-Host "[WARN] Could not read Vanessa Automation latest release from GitHub API: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        url = "https://github.com/Pr-Mex/vanessa-automation/releases/download/1.2.043.28/vanessa-automation-single.1.2.043.28.zip"
        version = "1.2.043.28"
        expectedSha256 = ""
        source = "fallback release URL"
    }
}

function Get-VanessaCacheDirectory {
    return (Join-Path (Get-Agent1cTempRoot) "1c-agent-workflow\vanessa-automation")
}

function Save-VanessaAutomationArchive {
    param([object]$DownloadInfo)

    $cacheDir = Get-VanessaCacheDirectory
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $archivePath = Join-Path $cacheDir "vanessa-automation-single.zip"
    $source = [string]$DownloadInfo.url

    Write-Host "Vanessa Automation archive source: $source"
    if (Test-Path -LiteralPath (ConvertFrom-FileUri -Value $source) -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath (ConvertFrom-FileUri -Value $source) -Destination $archivePath -Force
    } else {
        Invoke-WebRequest -Uri $source -UseBasicParsing -OutFile $archivePath
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    Write-Host "Vanessa Automation archive SHA256: $hash"

    $expected = [string](Get-ConfigValueFromObject -Object $DownloadInfo -Path "expectedSha256" -Default "")
    if ($expected) {
        $expected = $expected.ToLowerInvariant()
        if ($hash -eq $expected) {
            Write-Host "Vanessa Automation archive hash matches dependency lock."
        } elseif ((Get-DependencyMode) -eq "locked" -or (Test-DependencyLockRateLimitFallbackSource -Source ([string]$DownloadInfo.source))) {
            throw "Vanessa Automation archive SHA256 mismatch. Expected $expected, got $hash."
        } else {
            Write-Host "[WARN] Vanessa Automation archive hash differs from expected metadata. Actual SHA256 is logged above."
        }
    }

    if (-not (Test-DependencyLockRateLimitFallbackSource -Source ([string]$DownloadInfo.source))) {
        Update-DependencyLockEntry -Name "vanessaAutomation" -Values @{
            version = [string]$DownloadInfo.version
            url = $source
            sha256 = $hash
            source = [string]$DownloadInfo.source
        }
    }

    return $archivePath
}

function Expand-VanessaAutomationArchive {
    param(
        [string]$ArchivePath,
        [string]$InstallRoot
    )

    $existingEpf = Find-VanessaAutomationEpf -Root $InstallRoot
    if ($existingEpf) {
        Write-Host "Vanessa Automation EPF already exists: $existingEpf"
        return $existingEpf
    }

    if (Test-Path -LiteralPath $InstallRoot -ErrorAction SilentlyContinue) {
        $children = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Vanessa Automation install root already exists but does not contain an EPF: $InstallRoot"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    $extractRoot = Join-Path (Get-VanessaCacheDirectory) ("extract-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force
        Copy-Item -Path (Join-Path $extractRoot "*") -Destination $InstallRoot -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $epfPath = Find-VanessaAutomationEpf -Root $InstallRoot
    if (-not $epfPath) {
        throw "Downloaded Vanessa Automation archive did not contain a usable EPF."
    }

    return $epfPath
}

function Save-VanessaAutomationSettingsToDotEnv {
    param(
        [string]$EpfPath,
        [string]$Version = ""
    )

    $featuresPath = Get-VanessaFeaturesPath
    $reportsPath = Get-VanessaReportsPath
    New-Item -ItemType Directory -Force -Path (Resolve-ProjectPath $featuresPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Resolve-ProjectPath $reportsPath) | Out-Null

    Set-DotEnvValues -Values @{
        VANESSA_AUTOMATION_EPF = $EpfPath
        VANESSA_AUTOMATION_VERSION = $Version
        VANESSA_FEATURES_PATH = $featuresPath
        VANESSA_REPORTS_PATH = $reportsPath
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Vanessa Automation settings saved to .dev.env"
}

function Install-VanessaAutomation {
    Write-Section "Install Vanessa Automation"

    $state = Get-VanessaAutomationState
    if ($state.ready) {
        Write-Host "Vanessa Automation is already installed: $($state.epfPath)"
        Save-VanessaAutomationSettingsToDotEnv -EpfPath $state.epfPath -Version $state.version
        return
    }

    $installRoot = Get-VanessaInstallRoot
    Write-Host "Vanessa Automation install root: $installRoot"
    $downloadInfo = Get-VanessaAutomationDownloadInfo
    Write-Host "Vanessa Automation download metadata source: $($downloadInfo.source)"
    $archivePath = Save-VanessaAutomationArchive -DownloadInfo $downloadInfo
    $epfPath = Expand-VanessaAutomationArchive -ArchivePath $archivePath -InstallRoot $installRoot
    Save-VanessaAutomationSettingsToDotEnv -EpfPath $epfPath -Version $downloadInfo.version
    Write-Host "Vanessa Automation EPF: $epfPath"
}

function Ensure-VanessaAutomationForInit {
    param([object]$Answers)

    $state = Get-VanessaAutomationState
    if ($state.ready) {
        Save-VanessaAutomationSettingsToDotEnv -EpfPath $state.epfPath -Version $state.version
        return
    }

    Write-Host "Vanessa Automation is required for development branch tests and branch-local Vanessa UI MCP; installing it automatically."
    Install-VanessaAutomation
}

function Get-VanessaFeatureFiles {
    param([string]$FeaturePath)

    $resolvedPath = Resolve-ProjectPath $FeaturePath
    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf -ErrorAction SilentlyContinue) {
        if ($resolvedPath -notlike "*.feature") {
            throw "Vanessa feature path points to a file, but it is not a .feature file: $resolvedPath"
        }
        return @($resolvedPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Vanessa features path was not found: $resolvedPath"
    }

    return @(Get-ChildItem -LiteralPath $resolvedPath -Recurse -File -Filter "*.feature" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Get-VanessaApplicationFeatureFiles {
    param([string]$FeaturePath)

    $featuresRoot = Resolve-ProjectPath $FeaturePath
    return @(Get-VanessaFeatureFiles -FeaturePath $FeaturePath | Where-Object {
        $relative = [string]$_.Substring($featuresRoot.TrimEnd("\", "/").Length).TrimStart("\", "/")
        $relative -notmatch '^(?i)Libraries[\\/]'
    })
}

function Get-VanessaAuthoringStatePath {
    return (Join-Path $script:ProjectRoot ".agent-1c\vanessa-authoring\state.json")
}

function Read-VanessaAuthoringState {
    $path = Get-VanessaAuthoringStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    try { return (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { throw "Vanessa authoring state is invalid: $path. $($_.Exception.Message)" }
}

function Write-VanessaAuthoringState {
    param([object]$State)

    $path = Get-VanessaAuthoringStatePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Write-Utf8Text -Path $path -Value (($State | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    $script:RunAuthoringStatePath = $path
    $script:RunAuthoringStatus = [string](Get-StateValue -State $State -Name "phase" -Default "")
    return $path
}

function ConvertTo-ProjectRelativePath {
    param([string]$Path)

    $root = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $full = Resolve-Agent1cFullPath -Path $Path
    if (-not $full.StartsWith(($root + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project root: $full"
    }
    return $full.Substring($root.Length + 1).Replace("\", "/")
}

function Get-VanessaChangedFeatureFiles {
    $featuresRoot = Resolve-ProjectPath (Get-VanessaFeaturesPath)
    if (-not (Test-Path -LiteralPath $featuresRoot -ErrorAction SilentlyContinue)) { return @() }

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $master = Get-MasterBranch
        $base = (& git -C $script:ProjectRoot merge-base HEAD $master 2>$null | Select-Object -First 1)
        if (-not $base) { $base = "HEAD" }
        $names = @(& git -C $script:ProjectRoot -c core.quotepath=false -c core.safecrlf=false diff --name-only --diff-filter=ACMR $base -- 2>$null)
        $names += @(& git -C $script:ProjectRoot -c core.quotepath=false ls-files --others --exclude-standard 2>$null)
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($names | Sort-Object -Unique)) {
        if (-not $name -or [System.IO.Path]::GetExtension([string]$name) -ine ".feature") { continue }
        $candidate = Resolve-ProjectPath ([string]$name)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue)) { continue }
        $normalizedRoot = (Resolve-Agent1cFullPath -Path $featuresRoot).TrimEnd("\", "/")
        $normalizedCandidate = Resolve-Agent1cFullPath -Path $candidate
        if ($normalizedCandidate.StartsWith(($normalizedRoot + "\"), [System.StringComparison]::OrdinalIgnoreCase) -or $normalizedCandidate -eq $normalizedRoot) {
            $result.Add($normalizedCandidate)
        }
    }
    return @($result)
}

function Get-VanessaAuthoringFeatureRecords {
    return @(Get-VanessaChangedFeatureFiles | ForEach-Object {
        $contract = Get-VanessaFeatureContract -Path $_
        [pscustomobject][ordered]@{
            path = ConvertTo-ProjectRelativePath -Path $_
            sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
            title = $contract.title
            scenarios = @($contract.scenarios)
        }
    } | Sort-Object path)
}

function Get-VanessaFeatureContract {
    param([Parameter(Mandatory = $true)][string]$Path)

    $title = ""
    $scenarios = [System.Collections.Generic.List[object]]::new()
    $featureKeyword = [regex]::Escape((ConvertFrom-Utf8Base64 "0KTRg9C90LrRhtC40L7QvdCw0Ls="))
    $scenarioKeyword = [regex]::Escape((ConvertFrom-Utf8Base64 "0KHRhtC10L3QsNGA0LjQuQ=="))
    $scenarioOutlineKeyword = [regex]::Escape((ConvertFrom-Utf8Base64 "0KHRgtGA0YPQutGC0YPRgNCwINGB0YbQtdC90LDRgNC40Y8="))
    $featurePattern = "^\s*(?:$featureKeyword|Feature)\s*:\s*(?<name>.+?)\s*$"
    $scenarioPattern = "^\s*(?:$scenarioKeyword|$scenarioOutlineKeyword|Scenario|Scenario\s+Outline)\s*:\s*(?<name>.+?)\s*$"
    $lines = @((Read-Utf8Text -Path $Path) -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if (-not $title -and $line -match $featurePattern) {
            $title = [string]$Matches.name
        }
        if ($line -match $scenarioPattern) {
            $scenarios.Add([pscustomobject][ordered]@{ line = $index + 1; name = [string]$Matches.name })
        }
    }
    return [pscustomobject][ordered]@{ title = $title; scenarios = @($scenarios) }
}

function Get-VanessaItlLibraryFingerprint {
    $root = Join-Path (Resolve-ProjectPath (Get-VanessaFeaturesPath)) "Libraries\ITL"
    if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) { return "" }
    $parts = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        "$(ConvertTo-ProjectRelativePath -Path $_.FullName):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    })
    return Get-StringSha256 -Value ($parts -join "`n")
}

function Sync-ItlVanessaLibraries {
    $sourceRoot = Join-Path (Split-Path -Parent $script:Agent1cScriptRoot) "assets\vanessa-libraries"
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Managed Vanessa library assets are missing: $sourceRoot"
    }
    $featuresRoot = Resolve-ProjectPath (Get-VanessaFeaturesPath)
    $itlRoot = Join-Path $featuresRoot "Libraries\ITL"
    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $normalizedItlRoot = Resolve-Agent1cFullPath -Path $itlRoot
    if (-not $normalizedItlRoot.StartsWith(($projectRoot + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to install managed Vanessa libraries outside the project root: $normalizedItlRoot"
    }

    New-Item -ItemType Directory -Force -Path $itlRoot | Out-Null
    $edition = Get-BaseConfigurationVersion
    foreach ($name in @("Core", $edition)) {
        $source = Join-Path $sourceRoot $name
        $target = Join-Path $itlRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Managed Vanessa library layer is missing: $source" }
        if (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
    $inactive = Join-Path $itlRoot $(if ($edition -eq "PM4") { "PM5" } else { "PM4" })
    if (Test-Path -LiteralPath $inactive -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $inactive -Recurse -Force }
    Write-Host "Managed Vanessa libraries: Core + $edition ($itlRoot)"
}

function Test-VanessaAuthoringStateMatches {
    param([object]$State, [object[]]$FeatureRecords, [string]$LibraryFingerprint)

    if ($null -eq $State) { return $false }
    if ((ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "schemaVersion" -Default 0) -Default 0) -ne 3) { return $false }
    if ((Get-FullPathNormalized (Get-StateValue -State $State -Name "projectRoot" -Default "")) -ne (Get-FullPathNormalized $script:ProjectRoot)) { return $false }
    if ([string](Get-StateValue -State $State -Name "branch" -Default "") -ne (Get-CurrentBranch)) { return $false }
    if ([string](Get-StateValue -State $State -Name "libraryFingerprint" -Default "") -ne $LibraryFingerprint) { return $false }
    $currentCatalog = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
    if ([string](Get-StateValue -State $State -Name "catalogSha256" -Default "") -ne [string]$currentCatalog.catalogSha256) { return $false }
    $expected = @($FeatureRecords | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    $featuresProperty = $State.PSObject.Properties["features"]
    $stateFeatures = $(if ($null -eq $featuresProperty -or $null -eq $featuresProperty.Value) { @() } else { @($featuresProperty.Value) })
    $actual = @($stateFeatures | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    return ($expected -eq $actual)
}

function New-VanessaAuthoringState {
    param([string]$Phase, [object[]]$FeatureRecords, [string]$LibraryFingerprint)

    return [pscustomobject][ordered]@{
        schemaVersion = 3
        projectRoot = $script:ProjectRoot
        branch = (Get-CurrentBranch)
        productEdition = (Get-BaseConfigurationVersion)
        testsPath = (Get-VanessaFeaturesPath)
        phase = $Phase
        mcpFamily = "vanessa-ui"
        catalogSha256 = ""
        backendEvidence = @()
        features = @($FeatureRecords)
        libraryFingerprint = $LibraryFingerprint
        resultsPath = ""
        errorCategory = ""
        completionMode = ""
        verificationFallback = $null
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        passedAt = ""
    }
}

function Prepare-VanessaAuthoring {
    Write-Section "Prepare Vanessa authoring"
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "prepare-vanessa-authoring"
    Assert-DevBranchExtensionInitialized -State $state -Operation "prepare-vanessa-authoring"
    $decision = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger "command"
    $features = @(Get-VanessaAuthoringFeatureRecords)
    $libraryFingerprint = Get-VanessaItlLibraryFingerprint

    if (-not $decision.run) {
        $authoring = New-VanessaAuthoringState -Phase "skipped" -FeatureRecords $features -LibraryFingerprint $libraryFingerprint
        $authoring | Add-Member -NotePropertyName reason -NotePropertyValue $decision.reason -Force
        Write-VanessaAuthoringState -State $authoring | Out-Null
        Write-Host "Vanessa authoring: skipped ($($decision.reason))."
        return
    }
    if ($features.Count -eq 0) {
        $authoring = New-VanessaAuthoringState -Phase "not-required" -FeatureRecords @() -LibraryFingerprint $libraryFingerprint
        Write-VanessaAuthoringState -State $authoring | Out-Null
        Write-Host "Vanessa authoring: not required; no new or changed .feature files."
        return
    }
    $applicationFeatures = @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
    if ($applicationFeatures.Count -eq 0) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "/itl-verify-fix"
        throw "missing-suite: changed library features exist, but no application .feature provides product coverage. Run /itl-verify-fix."
    }

    $existing = Read-VanessaAuthoringState
    if ((Test-VanessaAuthoringStateMatches -State $existing -FeatureRecords $features -LibraryFingerprint $libraryFingerprint) -and [string]$existing.phase -eq "passed") {
        Write-VanessaAuthoringState -State $existing | Out-Null
        Write-Host "Vanessa authoring: existing pass is fresh."
        return
    }

    Set-RunStage -Stage "vanessa.authoring-update" -Detail "Updating the branch infobase before Vanessa MCP authoring."
    Update-DevBranchBase
    $definition = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
    $configPath = Write-ItlOnDemandMcpClientConfig
    if (-not $configPath) { throw "ITL on-demand MCP facade is not installed for Vanessa authoring." }
    $authoring = New-VanessaAuthoringState -Phase "ready" -FeatureRecords $features -LibraryFingerprint $libraryFingerprint
    $authoring.catalogSha256 = $definition.catalogSha256
    $authoring.updatedAt = (Get-Date).ToString("o")
    Write-VanessaAuthoringState -State $authoring | Out-Null
    Write-Host "Vanessa authoring state: ready"
    Write-Host "Use itl-vanessa-ui call_tool with exact inner names. The backend starts on the first inner call; no client reload or raw HTTP call is required."
}

function Approve-ReleaseE2EVanessaFixtureAuthoring {
    param([Parameter(Mandatory = $true)][string]$FeaturePath)

    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "release-e2e-approve-vanessa-fixture"
    $relativePath = ConvertTo-ProjectRelativePath -Path $FeaturePath
    if ($relativePath -cne "tests/features/ITLReleaseFourFlat.feature") {
        throw "Release E2E Vanessa approval is restricted to tests/features/ITLReleaseFourFlat.feature."
    }

    $features = @(Get-VanessaAuthoringFeatureRecords)
    $allowedPaths = @($relativePath, "tests/features/workflow-release-e2e.feature")
    $unexpected = @($features | Where-Object { [string]$_.path -cnotin $allowedPaths })
    $fixture = @($features | Where-Object { [string]$_.path -ceq $relativePath })
    if ($fixture.Count -ne 1 -or $unexpected.Count -gt 0) {
        throw "Release E2E Vanessa approval is restricted to the canonical release feature set."
    }
    $featureText = Read-Utf8Text -Path (Resolve-ProjectPath $relativePath)
    if ($featureText -notmatch '(?m)^\s*@itl_release_flat\s*$' -or -not [string]$fixture[0].title -or @($fixture[0].scenarios).Count -ne 4) {
        throw "Release E2E Vanessa approval requires the tagged four-scenario fixture contract."
    }

    $authoring = New-VanessaAuthoringState -Phase "passed" -FeatureRecords $features -LibraryFingerprint (Get-VanessaItlLibraryFingerprint)
    $definition = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
    $authoring.catalogSha256 = [string]$definition.catalogSha256
    $authoring.completionMode = "release-e2e-fixture"
    $authoring.updatedAt = (Get-Date).ToString("o")
    $authoring.passedAt = $authoring.updatedAt
    Write-VanessaAuthoringState -State $authoring | Out-Null
    Write-Host "Release E2E Vanessa fixture authoring: approved."
}

function Get-VanessaAuthoringOnDemandEvidence {
    param([object]$AuthoringState)
    $createdAt = [DateTimeOffset]::Parse([string]$AuthoringState.createdAt)
    $root = Join-Path (Get-ItlOnDemandRuntimeRoot) "vanessa-ui"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $evidence = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Filter "*.evidence.jsonl" -ErrorAction SilentlyContinue) {
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $item = $line | ConvertFrom-Json
                if ((ConvertTo-IntOrDefault -Value (Get-StateValue -State $item -Name "schemaVersion" -Default 0) -Default 0) -ne 2) { continue }
                $recordedAt = [DateTimeOffset]::Parse([string]$item.recordedAt)
                if ($recordedAt -ge $createdAt -and [string]$item.family -eq "vanessa-ui" -and [string]$item.catalogSha256 -eq [string]$AuthoringState.catalogSha256) {
                    $evidence += $item
                }
            } catch { }
        }
    }
    return @($evidence | Sort-Object recordedAt)
}

function Test-VanessaEvidenceFeatureIdentity {
    param([object]$Evidence, [object]$Feature)

    return ([string](Get-StateValue -State $Evidence -Name "featurePath" -Default "")).Replace("\", "/") -ieq [string]$Feature.path -and
        [string](Get-StateValue -State $Evidence -Name "featureSha256" -Default "") -eq [string]$Feature.sha256
}

function Get-VanessaAuthoringEvidenceValidation {
    param([object[]]$Evidence, [object[]]$Features)

    $passed = @($Evidence | Where-Object { [string]$_.outcome -eq "passed" })
    foreach ($feature in $Features) {
        if (-not [string](Get-StateValue -State $feature -Name "title" -Default "") -or @($feature.scenarios).Count -eq 0) {
            return [pscustomobject]@{ valid = $false; reason = "Feature '$($feature.path)' has no parseable title/scenario contract." }
        }
        $validated = $false
        $featureReason = "no single Vanessa instance contains the required chain"
        foreach ($instance in @($passed | Select-Object -ExpandProperty instanceId -Unique)) {
            $items = @($passed | Where-Object { [string]$_.instanceId -eq [string]$instance } | Sort-Object recordedAt)
            $search = @($items | Where-Object { [string]$_.tool -eq "search_for_steps_by_keywords" } | Select-Object -First 1)
            if ($search.Count -eq 0) { $featureReason = "search_for_steps_by_keywords is missing"; continue }
            $open = @($items | Where-Object { [string]$_.tool -eq "open_feature_file" -and (Test-VanessaEvidenceFeatureIdentity -Evidence $_ -Feature $feature) } | Select-Object -First 1)
            if ($open.Count -eq 0) { $featureReason = "feature-bound open_feature_file is missing"; continue }
            $openAt = [DateTimeOffset]::Parse([string]$open[0].recordedAt)
            $syntax = @($items | Where-Object { [string]$_.tool -eq "check_syntax" -and (Test-VanessaEvidenceFeatureIdentity -Evidence $_ -Feature $feature) -and [DateTimeOffset]::Parse([string]$_.recordedAt) -gt $openAt } | Select-Object -First 1)
            if ($syntax.Count -eq 0) { $featureReason = "ordered feature-bound check_syntax is missing"; continue }
            $cursor = [DateTimeOffset]::Parse([string]$syntax[0].recordedAt)
            $complete = $true
            foreach ($scenario in @($feature.scenarios)) {
                $line = [int]$scenario.line
                $info = @($items | Where-Object { [string]$_.tool -eq "get_info_about_line_scenario" -and (Test-VanessaEvidenceFeatureIdentity -Evidence $_ -Feature $feature) -and [int]$_.scenarioLine -eq $line -and [DateTimeOffset]::Parse([string]$_.recordedAt) -gt $cursor } | Select-Object -First 1)
                if ($info.Count -eq 0) { $featureReason = "scenario line $line is missing ordered get_info_about_line_scenario"; $complete = $false; break }
                $infoAt = [DateTimeOffset]::Parse([string]$info[0].recordedAt)
                $run = @($items | Where-Object { [string]$_.tool -eq "run_scenario" -and (Test-VanessaEvidenceFeatureIdentity -Evidence $_ -Feature $feature) -and [int]$_.scenarioLine -eq $line -and [DateTimeOffset]::Parse([string]$_.recordedAt) -gt $infoAt } | Select-Object -First 1)
                if ($run.Count -eq 0) { $featureReason = "scenario line $line is missing ordered run_scenario"; $complete = $false; break }
                $runAt = [DateTimeOffset]::Parse([string]$run[0].recordedAt)
                $results = @($items | Where-Object { [string]$_.tool -eq "get_test_results" -and (Test-VanessaEvidenceFeatureIdentity -Evidence $_ -Feature $feature) -and [int]$_.scenarioLine -eq $line -and [DateTimeOffset]::Parse([string]$_.recordedAt) -gt $runAt } | Select-Object -First 1)
                if ($results.Count -eq 0) { $featureReason = "scenario line $line is missing ordered get_test_results"; $complete = $false; break }
                $cursor = [DateTimeOffset]::Parse([string]$results[0].recordedAt)
            }
            if ($complete) { $validated = $true; break }
        }
        if (-not $validated) {
            return [pscustomobject]@{ valid = $false; reason = "Feature '$($feature.path)' does not have a complete ordered Vanessa authoring evidence chain: $featureReason." }
        }
    }
    return [pscustomobject]@{ valid = $true; reason = "All changed features have complete ordered Vanessa authoring evidence." }
}

function Test-VanessaAuthoringRunnerFallbackEligible {
    param([object]$State, [object[]]$FeatureRecords, [string]$LibraryFingerprint)

    if (-not (Test-VanessaAuthoringStateMatches -State $State -FeatureRecords $FeatureRecords -LibraryFingerprint $LibraryFingerprint)) { return $false }
    if ([string](Get-StateValue -State $State -Name "phase" -Default "") -ne "failed" -or [string](Get-StateValue -State $State -Name "errorCategory" -Default "") -ne "runner") { return $false }
    $failureTools = @("open_feature_file", "check_syntax", "get_info_about_line_scenario", "run_scenario", "get_test_results", "get_editor_state", "load_features")
    $failureCodes = @("ITL_ONDEMAND_BACKEND_CALL_FAILED", "ITL_VANESSA_TOOL_RESULT_FAILED", "ITL_ONDEMAND_EMPTY_RESULT")
    foreach ($item in @($State.backendEvidence)) {
        if ([string]$item.outcome -ne "failed" -or [string]$item.tool -notin $failureTools -or [string]$item.resultCode -notin $failureCodes) { continue }
        foreach ($feature in $FeatureRecords) {
            if (Test-VanessaEvidenceFeatureIdentity -Evidence $item -Feature $feature) { return $true }
        }
    }
    return $false
}

function Complete-VanessaAuthoring {
    param(
        [ValidateSet("", "passed", "failed")][string]$Result,
        [string]$ErrorCategory = "",
        [string]$ResultsPath = ""
    )

    if (-not $Result) { throw "complete-vanessa-authoring requires -AuthoringResult passed|failed." }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "complete-vanessa-authoring"
    $features = @(Get-VanessaAuthoringFeatureRecords)
    $libraryFingerprint = Get-VanessaItlLibraryFingerprint
    $authoring = Read-VanessaAuthoringState
    if ($null -eq $authoring -or
        (Get-FullPathNormalized ([string](Get-StateValue -State $authoring -Name "projectRoot" -Default ""))) -ne (Get-FullPathNormalized $script:ProjectRoot) -or
        [string](Get-StateValue -State $authoring -Name "branch" -Default "") -ne (Get-CurrentBranch)) {
        throw "Vanessa authoring state belongs to another branch/worktree or is missing. Rerun /itl-vanessa-author."
    }
    if ((ConvertTo-IntOrDefault -Value (Get-StateValue -State $authoring -Name "schemaVersion" -Default 0) -Default 0) -ne 3 -or [string]$authoring.phase -ne "ready") {
        throw "Vanessa authoring state is not schema v3 ready. Rerun /itl-vanessa-author."
    }
    if ($features.Count -eq 0) {
        throw "No changed .feature files remain to complete Vanessa authoring."
    }

    $evidence = @(Get-VanessaAuthoringOnDemandEvidence -AuthoringState $authoring)
    if ($Result -eq "passed") {
        $validation = Get-VanessaAuthoringEvidenceValidation -Evidence $evidence -Features $features
        if (-not $validation.valid) { throw "Vanessa authoring cannot pass: $($validation.reason)" }
    }
    Stop-ItlOnDemandBackends -Family "vanessa-ui"
    $authoring.features = @($features)
    $authoring.libraryFingerprint = $libraryFingerprint
    $authoring.phase = $Result
    $authoring.backendEvidence = @($evidence)
    $authoring.resultsPath = $ResultsPath
    $authoring.errorCategory = $(if ($Result -eq "failed") { $(if ($ErrorCategory) { $ErrorCategory } else { "runner" }) } else { "" })
    $authoring.completionMode = $(if ($Result -eq "passed") { "mcp" } else { "" })
    $authoring.updatedAt = (Get-Date).ToString("o")
    if ($Result -eq "passed") { $authoring.passedAt = $authoring.updatedAt }
    Write-VanessaAuthoringState -State $authoring | Out-Null
    if ($Result -eq "failed") {
        Set-RunFailureContext -Category $authoring.errorCategory -RequiredAction "/itl-vanessa-author"
        throw "Vanessa authoring failed ($($authoring.errorCategory)). Inspect MCP results: $ResultsPath"
    }
    Write-Host "Vanessa authoring: passed."
}

function Stop-VanessaAuthoringMcpForState {
    param(
        [object]$State,
        [switch]$Quiet
    )

    $instances = @(Get-ItlOnDemandRuntimeInstances | Where-Object { [string]$_.family -eq "vanessa-ui" })
    Stop-ItlOnDemandBackends -Family "vanessa-ui"
    $stopped = $instances.Count -gt 0
    $authoring = Read-VanessaAuthoringState
    if ($null -eq $authoring) { return $stopped }
    $sameContext = (Get-FullPathNormalized ([string](Get-StateValue -State $authoring -Name "projectRoot" -Default ""))) -eq (Get-FullPathNormalized $script:ProjectRoot) -and
        [string](Get-StateValue -State $authoring -Name "branch" -Default "") -eq (Get-CurrentBranch)
    if ($sameContext -and [string](Get-StateValue -State $authoring -Name "phase" -Default "") -eq "ready") {
        $authoring.phase = "stopped"
        $authoring.updatedAt = (Get-Date).ToString("o")
        Write-VanessaAuthoringState -State $authoring | Out-Null
    }
    return $stopped
}

function Assert-VanessaAuthoringPreflight {
    param([ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command", [string[]]$ExplicitComponents = @())

    $decision = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    if (-not $decision.run) { return }
    $featuresPath = Get-VanessaFeaturesPath
    $resolved = Resolve-ProjectPath $featuresPath
    if (-not (Test-Path -LiteralPath $resolved -ErrorAction SilentlyContinue)) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "/itl-verify-fix"
        throw "missing-suite: Vanessa testsPath was not found: $resolved"
    }
    $applicationFeatures = @(Get-VanessaApplicationFeatureFiles -FeaturePath $featuresPath)
    if ($applicationFeatures.Count -eq 0) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "/itl-verify-fix"
        throw "missing-suite: no application .feature files found under '$featuresPath'. Libraries do not count as product coverage."
    }
    $changed = @(Get-VanessaAuthoringFeatureRecords)
    if ($changed.Count -eq 0) { return }
    $authoring = Read-VanessaAuthoringState
    $libraryFingerprint = Get-VanessaItlLibraryFingerprint
    $matches = Test-VanessaAuthoringStateMatches -State $authoring -FeatureRecords $changed -LibraryFingerprint $libraryFingerprint
    if ($matches -and [string](Get-StateValue -State $authoring -Name "phase" -Default "") -eq "passed") {
        $script:RunAuthoringStatus = "passed"
        $script:RunAuthoringStatePath = Get-VanessaAuthoringStatePath
        return
    }
    if ($matches -and (Test-VanessaAuthoringRunnerFallbackEligible -State $authoring -FeatureRecords $changed -LibraryFingerprint $libraryFingerprint)) {
        $script:RunAuthoringStatus = "runner-fallback-pending"
        $script:RunAuthoringStatePath = Get-VanessaAuthoringStatePath
        Write-Host "[WARN] Vanessa MCP authoring runner failed with feature-bound infrastructure evidence; /itl-check will require canonical JUnit fallback proof."
        return
    }
    if (-not $matches -or [string](Get-StateValue -State $authoring -Name "phase" -Default "") -ne "passed") {
        Set-RunFailureContext -Category "unsupported-step" -RequiredAction "/itl-vanessa-author"
        $script:RunAuthoringStatus = [string](Get-StateValue -State $authoring -Name "phase" -Default "missing")
        $script:RunAuthoringStatePath = Get-VanessaAuthoringStatePath
        throw "Vanessa authoring pass is missing or stale for changed .feature files. Run /itl-vanessa-author before /itl-check."
    }
}

function Test-VanessaAuthoringRequired {
    $decision = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger "command"
    if (-not $decision.run) { return $false }
    $changed = @(Get-VanessaAuthoringFeatureRecords)
    if ($changed.Count -eq 0) { return $false }
    $authoring = Read-VanessaAuthoringState
    return (-not (Test-VanessaAuthoringStateMatches -State $authoring -FeatureRecords $changed -LibraryFingerprint (Get-VanessaItlLibraryFingerprint)) -or
        [string](Get-StateValue -State $authoring -Name "phase" -Default "") -ne "passed")
}

function New-VanessaRunDirectory {
    $reportsRoot = Resolve-ProjectPath (Get-VanessaReportsPath)
    New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
    $runDirectory = Join-Path $reportsRoot ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    return $runDirectory
}

function Get-StringSha256 {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (Get-Utf8Encoding).GetBytes([string]$Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Read-SharedTextFile {
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] $stream.Length
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -lt $buffer.Length) {
            [Array]::Resize([ref]$buffer, $read)
        }
    } finally {
        $stream.Dispose()
    }

    if ($buffer.Length -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($buffer, 3, $buffer.Length - 3)
    }
    if ($buffer.Length -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($buffer, 2, $buffer.Length - 2)
    }
    if ($buffer.Length -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($buffer, 2, $buffer.Length - 2)
    }
    return (Get-Utf8Encoding).GetString($buffer)
}

function Get-DevBranchEventLogDirectory {
    param([object]$State)

    $kind = Get-StateValue -State $State -Name "infoBaseKind" -Default "file"
    if ($kind -ne "file") {
        throw "Vanessa event log gate requires a local file development branch infobase. Current branch infobase kind: $kind"
    }

    $infoBasePath = Require-Value "devBranchInfoBasePath" (Get-StateValue -State $State -Name "devBranchInfoBasePath")
    $resolvedInfoBasePath = Resolve-InfoBasePath $infoBasePath
    return (Join-Path $resolvedInfoBasePath "1Cv8Log")
}

function Get-VanessaEventLogLevels {
    $raw = [string](Get-EnvValue -Name "VANESSA_EVENT_LOG_LEVELS" -Default "Error")
    $levels = @($raw -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($levels.Count -eq 0) {
        $levels = @("Error")
    }
    return @($levels | ForEach-Object { Normalize-OneCEventLogLevel -Value $_ } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-VanessaEventLogClockSkewSeconds {
    $value = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_EVENT_LOG_CLOCK_SKEW_SECONDS" -Default 5) -Default 5
    if ($value -lt 0) {
        throw "Invalid VANESSA_EVENT_LOG_CLOCK_SKEW_SECONDS '$value'. Use 0 or a positive value."
    }
    return $value
}

function Get-VanessaEventLogReader {
    $reader = [string](Get-EnvValue -Name "VANESSA_EVENT_LOG_READER" -Default "auto")
    $reader = $reader.Trim().ToLowerInvariant()
    if (-not $reader) {
        $reader = "auto"
    }
    if (@("auto", "direct", "fallback") -notcontains $reader) {
        throw "Invalid VANESSA_EVENT_LOG_READER '$reader'. Use auto, direct, or fallback."
    }
    return $reader
}

function Get-VanessaTestTimeoutSeconds {
    $value = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_TIMEOUT_SECONDS" -Default 1800) -Default 1800
    if ($value -le 0) {
        throw "Invalid VANESSA_TEST_TIMEOUT_SECONDS '$value'. Use a positive number of seconds."
    }
    return $value
}

function Normalize-OneCEventLogLevel {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = ([string]$Value).Trim()
    $lower = $normalized.ToLowerInvariant()
    $ruErrorStem = -join ([char[]](0x043E, 0x0448, 0x0438, 0x0431))
    $ruWarningStem = -join ([char[]](0x043F, 0x0440, 0x0435, 0x0434))
    $ruInfoStem = -join ([char[]](0x0438, 0x043D, 0x0444, 0x043E))
    $ruNoteStem = -join ([char[]](0x043F, 0x0440, 0x0438, 0x043C))

    if (@("e", "error", "4") -contains $lower -or $lower.Contains($ruErrorStem)) {
        return "Error"
    }
    if (@("w", "warning", "warn", "3") -contains $lower -or $lower.Contains($ruWarningStem)) {
        return "Warning"
    }
    if (@("i", "info", "information", "2") -contains $lower -or $lower.Contains($ruInfoStem)) {
        return "Info"
    }
    if (@("n", "note", "1") -contains $lower -or $lower.Contains($ruNoteStem)) {
        return "Info"
    }
    return ""
}

function ConvertFrom-OneCEventLogDate {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = ([string]$Value).Trim().Trim('"')
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parsed = [datetime]::MinValue
    if ($text -match '^\d{14}$' -and [datetime]::TryParseExact($text, "yyyyMMddHHmmss", $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    if ($text -match '^\d{8}T\d{6}$' -and [datetime]::TryParseExact($text, "yyyyMMddTHHmmss", $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse($text, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-OneCBracketRecords {
    param([string]$Text)

    $records = New-Object System.Collections.ArrayList
    $depth = 0
    $start = -1
    $inString = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                    $i++
                    continue
                }
                $inString = $false
            }
            continue
        }

        if ($ch -eq '"') {
            $inString = $true
            continue
        }
        if ($ch -eq '{') {
            if ($depth -eq 0) {
                $start = $i
            }
            $depth++
            continue
        }
        if ($ch -eq '}') {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0 -and $start -ge 0) {
                    [void]$records.Add($Text.Substring($start, $i - $start + 1))
                    $start = -1
                }
            }
        }
    }

    return @($records)
}

function Invoke-OneCBracketRecordStream {
    param(
        [string]$Path,
        [scriptblock]$OnRecord,
        [int64]$StartOffset = 0
    )

    $reader = $null
    $builder = New-Object System.Text.StringBuilder
    $depth = 0
    $inString = $false
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($StartOffset -gt 0) { [void]$stream.Seek($StartOffset, [System.IO.SeekOrigin]::Begin) }
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $reader.ReadLine())) {
            for ($i = 0; $i -lt $line.Length; $i++) {
                $ch = $line[$i]
                if ($depth -eq 0 -and $ch -ne '{') {
                    continue
                }

                [void]$builder.Append($ch)
                if ($inString) {
                    if ($ch -eq '"') {
                        if (($i + 1) -lt $line.Length -and $line[$i + 1] -eq '"') {
                            [void]$builder.Append($line[$i + 1])
                            $i++
                        } else {
                            $inString = $false
                        }
                    }
                    continue
                }

                if ($ch -eq '"') {
                    $inString = $true
                } elseif ($ch -eq '{') {
                    $depth++
                } elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -eq 0) {
                        & $OnRecord $builder.ToString()
                        [void]$builder.Clear()
                    }
                }
            }
            if ($depth -gt 0) {
                [void]$builder.Append("`n")
            }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }

    if ($depth -ne 0) {
        throw "Incomplete bracket record in 1C event log segment: $Path"
    }
}

function Get-OneCBracketTokens {
    param([string]$Text)

    $tokens = New-Object System.Collections.ArrayList
    $builder = New-Object System.Text.StringBuilder
    $inString = $false

    function Add-Token([bool]$Quoted) {
        $value = $builder.ToString()
        [void]$builder.Clear()
        if ($Quoted -or -not [string]::IsNullOrWhiteSpace($value)) {
            [void]$tokens.Add([pscustomobject]@{
                value = $(if ($Quoted) { $value } else { $value.Trim() })
                quoted = $Quoted
            })
        }
    }

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                    [void]$builder.Append('"')
                    $i++
                    continue
                }
                Add-Token $true
                $inString = $false
                continue
            }
            [void]$builder.Append($ch)
            continue
        }

        if ($ch -eq '"') {
            Add-Token $false
            $inString = $true
            continue
        }
        if ($ch -eq '{' -or $ch -eq '}' -or $ch -eq ',' -or [char]::IsWhiteSpace($ch)) {
            Add-Token $false
            continue
        }
        [void]$builder.Append($ch)
    }

    Add-Token $false
    return @($tokens)
}

function Normalize-EventLogSignaturePart {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $text = ([string]$Value).ToLowerInvariant()
    $text = $text -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<guid>'
    $text = $text -replace '\b\d{4}[-./]\d{2}[-./]\d{2}[t\s]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b', '<datetime>'
    $text = $text -replace '\b\d{8,}\b', '<num>'
    $text = $text -replace '(?i)[a-z]:\\[^\s,;"]+', '<path>'
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function New-EventLogErrorSignature {
    param([object]$Event)

    $parts = @(
        (Get-StateValue -State $Event -Name "level" -Default ""),
        (Get-StateValue -State $Event -Name "event" -Default ""),
        (Get-StateValue -State $Event -Name "metadata" -Default ""),
        (Get-StateValue -State $Event -Name "dataPresentation" -Default ""),
        (Get-StateValue -State $Event -Name "comment" -Default "")
    ) | ForEach-Object { Normalize-EventLogSignaturePart -Value $_ }

    $joined = ($parts -join "|")
    if (-not $joined.Trim("|")) {
        $joined = Normalize-EventLogSignaturePart -Value (Get-StateValue -State $Event -Name "raw" -Default "")
    }
    return (Get-StringSha256 -Value $joined)
}

function ConvertFrom-OneCEventLogRecord {
    param(
        [string]$RecordText,
        [hashtable]$WantedLevels = $null,
        [Nullable[datetime]]$StartTime = $null,
        [Nullable[datetime]]$EndTime = $null
    )

    $tokens = @(Get-OneCBracketTokens -Text $RecordText)
    if ($tokens.Count -eq 0) {
        return $null
    }

    $date = $null
    $dateToken = ""
    foreach ($token in $tokens) {
        $date = ConvertFrom-OneCEventLogDate -Value $token.value
        if ($null -ne $date) {
            $dateToken = [string]$token.value
            break
        }
    }
    if ($null -eq $date) {
        return $null
    }

    $level = ""
    foreach ($token in $tokens) {
        if ([string]$token.value -eq $dateToken) {
            continue
        }
        $level = Normalize-OneCEventLogLevel -Value $token.value
        if ($level) {
            break
        }
    }
    if (-not $level -and (($tokens | ForEach-Object { [string]$_.value }) -contains "Ошибка")) {
        $level = "Error"
    }
    if (-not $level) {
        $level = "Info"
    }
    if ($null -ne $WantedLevels -and $WantedLevels.Count -gt 0 -and -not $WantedLevels.ContainsKey($level)) {
        return $null
    }
    if ($null -ne $StartTime -and $date -lt $StartTime) {
        return $null
    }
    if ($null -ne $EndTime -and $date -gt $EndTime) {
        return $null
    }

    $quoted = @($tokens | Where-Object { $_.quoted -and -not [string]::IsNullOrWhiteSpace([string]$_.value) } | ForEach-Object { [string]$_.value })
    $event = ""
    foreach ($token in $tokens) {
        $value = [string]$token.value
        if ($value -match '^\s*\d{14}\s*$') {
            continue
        }
        if (Normalize-OneCEventLogLevel -Value $value) {
            continue
        }
        if ($value -match '(_\$.*\$_|^[^\s,;"]+\.[^\s,;"]+)') {
            $event = $value
            break
        }
    }

    $comment = ""
    if ($quoted.Count -gt 0) {
        $comment = [string]$quoted[-1]
    }
    $metadata = ""
    foreach ($value in $quoted) {
        if ($value -match '\.') {
            $metadata = $value
            break
        }
    }
    $dataPresentation = ""
    if ($quoted.Count -gt 1) {
        $dataPresentation = [string]$quoted[0]
    }

    $eventObject = [pscustomobject]@{
        date = $date
        level = $level
        event = $event
        metadata = $metadata
        dataPresentation = $dataPresentation
        comment = $comment
        raw = $RecordText
    }
    $eventObject | Add-Member -NotePropertyName signature -NotePropertyValue (New-EventLogErrorSignature -Event $eventObject) -Force
    return $eventObject
}

function Read-OneCEventLogDirect {
    param(
        [object]$State,
        [Nullable[datetime]]$StartTime = $null,
        [Nullable[datetime]]$EndTime = $null,
        [string[]]$Levels = (Get-VanessaEventLogLevels),
        [string[]]$SegmentPaths = @(),
        [object[]]$SegmentSelections = @()
    )

    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container -ErrorAction SilentlyContinue)) {
        throw "1C event log directory was not found: $logDirectory"
    }

    $lgfPath = Join-Path $logDirectory "1Cv8.lgf"
    $lgpFiles = @(
        if (@($SegmentSelections).Count -gt 0) {
            $SegmentSelections | ForEach-Object { Get-Item -LiteralPath $_.path -ErrorAction Stop } | Sort-Object Name
        } elseif (@($SegmentPaths).Count -gt 0) {
            $SegmentPaths | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction Stop } | Sort-Object Name
        } else {
            Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue | Sort-Object Name
        }
    )
    $lgdFiles = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgd" -ErrorAction SilentlyContinue)
    if (-not (Test-Path -LiteralPath $lgfPath -PathType Leaf -ErrorAction SilentlyContinue) -and $lgdFiles.Count -gt 0) {
        throw "Unsupported SQLite 1C event log format (.lgd) in '$logDirectory'. ITL verify requires sequential 8.3.22+ .lgf/.lgp event logs."
    }
    if (-not (Test-Path -LiteralPath $lgfPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "1C event log header 1Cv8.lgf was not found: $lgfPath"
    }
    if ($lgpFiles.Count -eq 0) {
        return @()
    }

    $wantedLevels = @{}
    foreach ($level in $Levels) {
        if ($level) {
            $wantedLevels[$level] = $true
        }
    }

    $events = New-Object System.Collections.ArrayList
    foreach ($file in $lgpFiles) {
        $startOffset = 0
        if (@($SegmentSelections).Count -gt 0) {
            $selection = @($SegmentSelections | Where-Object { [string]$_.path -eq $file.FullName } | Select-Object -First 1)
            if ($selection.Count -gt 0) { $startOffset = [int64]$selection[0].startOffset }
        }
        $processRecord = {
            param($record)
            $event = ConvertFrom-OneCEventLogRecord -RecordText $record -WantedLevels $wantedLevels -StartTime $StartTime -EndTime $EndTime
            if ($null -eq $event) {
                return
            }
            [void]$events.Add($event)
        }
        Invoke-OneCBracketRecordStream -Path $file.FullName -OnRecord $processRecord -StartOffset $startOffset
    }
    return @($events)
}

function Get-DevBranchEventLogSignatureCacheRoot {
    param([object]$State)

    # Installed-project cache path contract: .agent-1c/event-log-signature-cache/
    $mainRoot = [string](Get-StateValue -State $State -Name "mainWorktreePath" -Default "")
    if (-not $mainRoot) {
        $mainRoot = [string](Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    }
    return (Join-Path $mainRoot ".agent-1c\event-log-signature-cache")
}

function Get-DevBranchEventLogSourceKey {
    param([object]$State)

    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    $lgfPath = Join-Path $logDirectory "1Cv8.lgf"
    if (-not (Test-Path -LiteralPath $lgfPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "1C event log header 1Cv8.lgf was not found: $lgfPath"
    }
    $header = Get-Item -LiteralPath $lgfPath -ErrorAction Stop
    $kind = [string](Get-StateValue -State $State -Name "infoBaseKind" -Default "file")
    $normalizedLogDirectory = (Resolve-Agent1cFullPath -Path $logDirectory).ToLowerInvariant()
    return (Get-StringSha256 -Value ("$kind|$normalizedLogDirectory|$($header.CreationTimeUtc.Ticks)"))
}

function Get-OneCEventLogSafeTailOffset {
    param([string]$Path)

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -le 0) { return [int64]0 }
    $windowLength = [int][Math]::Min([int64](1024 * 1024), [int64]$file.Length)
    $windowStart = [int64]$file.Length - $windowLength
    $buffer = New-Object byte[] $windowLength
    $stream = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($windowStart, [System.IO.SeekOrigin]::Begin)
        $read = $stream.Read($buffer, 0, $buffer.Length)
    } finally { $stream.Dispose() }
    for ($index = $read - 2; $index -ge 0; $index--) {
        if ($buffer[$index] -eq 0x0A -and $buffer[$index + 1] -eq 0x7B) {
            return [int64]($windowStart + $index + 1)
        }
    }
    return [int64]0
}

function New-DevBranchEventLogCursor {
    param(
        [object]$State,
        [string]$Path
    )

    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    $files = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue | Sort-Object Name)
    $active = $files | Select-Object -Last 1
    $segments = @()
    foreach ($file in $files) {
        $segments += [ordered]@{
            name = $file.Name
            length = [int64]$file.Length
            lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
            startOffset = $(if ($null -ne $active -and $file.FullName -eq $active.FullName) { Get-OneCEventLogSafeTailOffset -Path $file.FullName } else { $null })
        }
    }
    $cursor = [ordered]@{
        schemaVersion = 1
        sourceKey = Get-DevBranchEventLogSourceKey -State $State
        capturedAt = (Get-Date).ToUniversalTime().ToString("o")
        activeSegment = $(if ($null -ne $active) { $active.Name } else { "" })
        segments = @($segments)
    }
    Write-Utf8Text -Path $Path -Value (($cursor | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    return $Path
}

function Test-OneCEventLogSegmentMayOverlapFallbackWindow {
    param(
        [System.IO.FileInfo]$File,
        [datetime]$Threshold
    )

    if ($File.LastWriteTimeUtc -ge $Threshold) { return $true }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    if ($stem -match '^(?<date>\d{8})') {
        $segmentDate = [datetime]::MinValue
        if ([datetime]::TryParseExact(
            [string]$Matches.date,
            "yyyyMMdd",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$segmentDate
        )) {
            return $segmentDate.Date -ge $Threshold.Date
        }
    }

    # An unfamiliar segment name is safer to scan than to silently omit. This
    # path is only used after a corrupt/mismatched cursor or truncation.
    return $true
}

function Get-DevBranchEventLogDeltaSelection {
    param(
        [object]$State,
        [string]$CursorPath,
        [datetime]$FallbackStartTime
    )

    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    $files = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue | Sort-Object Name)
    $mode = "cursor"
    $cursor = $null
    try {
        if (-not (Test-Path -LiteralPath $CursorPath -PathType Leaf)) { throw "cursor file is missing" }
        $cursor = Read-Utf8Text -Path $CursorPath | ConvertFrom-Json
        if ([int](Get-StateValue -State $cursor -Name "schemaVersion" -Default 0) -ne 1) { throw "cursor schema is invalid" }
        if ([string]$cursor.sourceKey -ne (Get-DevBranchEventLogSourceKey -State $State)) { throw "cursor source changed" }
    } catch {
        Write-Host "[WARN] Event log cursor cannot be used; scanning run-period segments: $($_.Exception.Message)"
        $mode = "fallback"
    }

    $selections = @()
    if ($mode -eq "cursor") {
        $captured = @{}
        foreach ($segment in @($cursor.segments)) { $captured[[string]$segment.name] = $segment }
        $activeName = [string]$cursor.activeSegment
        $activeFile = $files | Where-Object Name -eq $activeName | Select-Object -First 1
        if ($activeName -and (-not $captured.ContainsKey($activeName) -or $null -eq $activeFile -or [int64]$activeFile.Length -lt [int64]$captured[$activeName].length)) {
            Write-Host "[WARN] Event log active segment rotated or truncated; scanning run-period segments."
            $mode = "fallback"
        } else {
            foreach ($file in $files) {
                if (-not $captured.ContainsKey($file.Name)) {
                    $selections += [pscustomobject]@{ path = $file.FullName; startOffset = [int64]0 }
                    continue
                }
                $before = $captured[$file.Name]
                if ($file.Name -eq $activeName) {
                    $selections += [pscustomobject]@{ path = $file.FullName; startOffset = [int64]$before.startOffset }
                } elseif ([int64]$file.Length -ne [int64]$before.length -or $file.LastWriteTimeUtc.ToString("o") -ne [string]$before.lastWriteTimeUtc) {
                    $selections += [pscustomobject]@{ path = $file.FullName; startOffset = [int64]0 }
                }
            }
        }
    }

    if ($mode -eq "fallback") {
        $threshold = $FallbackStartTime.ToUniversalTime().AddMinutes(-1)
        $selections = @($files | Where-Object { Test-OneCEventLogSegmentMayOverlapFallbackWindow -File $_ -Threshold $threshold } | ForEach-Object {
            [pscustomobject]@{ path = $_.FullName; startOffset = [int64]0 }
        })
    }

    $scannedBytes = [int64]0
    foreach ($selection in $selections) {
        $item = Get-Item -LiteralPath $selection.path
        $scannedBytes += [Math]::Max([int64]0, [int64]$item.Length - [int64]$selection.startOffset)
    }
    return [pscustomobject]@{
        mode = $mode
        selections = @($selections)
        scannedBytes = $scannedBytes
    }
}

function Read-DevBranchEventLogBaselineWithCache {
    param([object]$State)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    $sourceKey = Get-DevBranchEventLogSourceKey -State $State
    $cacheRoot = Get-DevBranchEventLogSignatureCacheRoot -State $State
    $cachePath = Join-Path $cacheRoot ($sourceKey + ".json")
    $files = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue | Sort-Object Name)

    $cache = $null
    $cacheStatus = "rebuilt"
    if (Test-Path -LiteralPath $cachePath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $candidate = Read-Utf8Text -Path $cachePath | ConvertFrom-Json
            if ([int](Get-StateValue -State $candidate -Name "schemaVersion" -Default 0) -ne 1 -or
                [string](Get-StateValue -State $candidate -Name "sourceKey" -Default "") -ne $sourceKey) {
                throw "incompatible cache schema or source key"
            }
            $cache = $candidate
            $cacheStatus = "hit"
        } catch {
            Write-Host "[WARN] Event log signature cache is damaged or incompatible; rebuilding it: $cachePath"
            $cache = $null
            $cacheStatus = "rebuilt"
        }
    }

    $cachedByName = @{}
    if ($null -ne $cache) {
        foreach ($segment in @($cache.segments)) {
            $cachedByName[[string]$segment.name] = $segment
        }
        $currentNames = @($files | ForEach-Object { $_.Name })
        if (@($cache.segments | Where-Object { $currentNames -notcontains [string]$_.name }).Count -gt 0) {
            $cacheStatus = "updated"
        }
    }

    $segments = @()
    foreach ($file in $files) {
        $lastWrite = $file.LastWriteTimeUtc.ToString("o")
        $cached = if ($cachedByName.ContainsKey($file.Name)) { $cachedByName[$file.Name] } else { $null }
        $unchanged = $null -ne $cached -and [int64]$cached.length -eq [int64]$file.Length -and [string]$cached.lastWriteTimeUtc -eq $lastWrite
        if ($unchanged) {
            $segments += $cached
            continue
        }

        if ($cacheStatus -eq "hit") { $cacheStatus = "updated" }
        $events = @(Read-OneCEventLogDirect -State $State -Levels @("Error") -SegmentPaths @($file.FullName))
        $signatures = @($events | ForEach-Object { $_.signature } | Where-Object { $_ } | Sort-Object -Unique)
        $segments += [ordered]@{
            name = $file.Name
            length = [int64]$file.Length
            lastWriteTimeUtc = $lastWrite
            errorCount = $events.Count
            signatureCount = $signatures.Count
            signatures = @($signatures)
        }
    }

    if ($cacheStatus -ne "hit") {
        New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
        $cachePayload = [ordered]@{
            schemaVersion = 1
            sourceKey = $sourceKey
            reader = "direct-stream"
            updatedAt = (Get-Date).ToString("o")
            segments = @($segments)
        }
        Write-Utf8Text -Path $cachePath -Value (($cachePayload | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }

    $allSignatures = @($segments | ForEach-Object { @($_.signatures) } | Where-Object { $_ } | Sort-Object -Unique)
    $errorCount = 0
    foreach ($segment in $segments) { $errorCount += [int]$segment.errorCount }
    $stopwatch.Stop()
    return [pscustomobject]@{
        reader = "direct-stream"
        cacheStatus = $cacheStatus
        cachePath = $cachePath
        sourceKey = $sourceKey
        segmentCount = $segments.Count
        errorCount = $errorCount
        signatureCount = $allSignatures.Count
        signatures = @($allSignatures)
        logDirectory = $logDirectory
        durationMs = [int64]$stopwatch.ElapsedMilliseconds
    }
}

function Read-DevBranchEventLogBaselineData {
    param([object]$State)

    $reader = Get-VanessaEventLogReader
    $directError = $null
    if ($reader -eq "auto" -or $reader -eq "direct") {
        try {
            return (Read-DevBranchEventLogBaselineWithCache -State $State)
        } catch {
            $directError = $_
            if ($reader -eq "direct" -or $_.Exception.Message -match "Unsupported SQLite") { throw }
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $readResult = Read-DevBranchEventLogErrors -State $State
        $signatures = @($readResult.events | ForEach-Object { $_.signature } | Where-Object { $_ } | Sort-Object -Unique)
        $stopwatch.Stop()
        return [pscustomobject]@{
            reader = $readResult.reader
            readerDurationMs = $readResult.durationMs
            scannedErrorCount = $readResult.errorCount
            cacheStatus = "not-applicable"
            cachePath = ""
            sourceKey = ""
            segmentCount = 0
            errorCount = @($readResult.events).Count
            signatureCount = $signatures.Count
            signatures = @($signatures)
            logDirectory = $readResult.logDirectory
            durationMs = [int64]$stopwatch.ElapsedMilliseconds
        }
    } catch {
        if ($null -ne $directError) {
            throw "Could not build event log baseline by direct reader or fallback exporter. Direct error: $($directError.Exception.Message). Fallback error: $($_.Exception.Message)"
        }
        throw
    }
}

function Get-EventLogExporterRootFile {
    return (Join-Path $script:ProjectRoot ".agents\skills\1c-workflow\tools\event-log-exporter\EventLogExporter.xml")
}

function Get-EventLogExporterEpfPath {
    return (Resolve-ProjectPath ".agent-1c/tools/event-log-exporter/EventLogExporter.epf")
}

function Ensure-EventLogExporterEpf {
    param([object]$State)

    $sourceRoot = Get-EventLogExporterRootFile
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Event log exporter source was not found: $sourceRoot"
    }

    $epfPath = Get-EventLogExporterEpfPath
    $needsBuild = -not (Test-Path -LiteralPath $epfPath -PathType Leaf -ErrorAction SilentlyContinue)
    if (-not $needsBuild) {
        $epfFile = Get-Item -LiteralPath $epfPath
        $sourceNewest = @(Get-ChildItem -LiteralPath (Split-Path -Parent $sourceRoot) -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
        if ($null -ne $sourceNewest -and $sourceNewest.LastWriteTime -gt $epfFile.LastWriteTime) {
            $needsBuild = $true
        }
    }

    if ($needsBuild) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $epfPath) | Out-Null
        Invoke-Designer `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -DesignerArgs @("/LoadExternalDataProcessorOrReportFromFiles", $sourceRoot, $epfPath) | Out-Null
    }

    return $epfPath
}

function Read-OneCEventLogViaFallback {
    param(
        [object]$State,
        [Nullable[datetime]]$StartTime = $null,
        [Nullable[datetime]]$EndTime = $null,
        [string[]]$Levels = (Get-VanessaEventLogLevels)
    )

    $runRoot = Resolve-ProjectPath "build/event-log"
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $runDirectory = Join-Path $runRoot ("export-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $paramsPath = Join-Path $runDirectory "EventLogExportParams.json"
    $outputPath = Join-Path $runDirectory "EventLogExport.json"

    $payload = [ordered]@{
        startTime = $(if ($null -ne $StartTime) { $StartTime.ToString("o") } else { "" })
        endTime = $(if ($null -ne $EndTime) { $EndTime.ToString("o") } else { "" })
        levels = @($Levels)
        outputPath = $outputPath
    }
    Write-Utf8Text -Path $paramsPath -Value (($payload | ConvertTo-Json -Depth 5) + [Environment]::NewLine)

    $epfPath = Ensure-EventLogExporterEpf -State $State
    $command = "EventLogExport;Params=$paramsPath"
    try {
        Invoke-Enterprise `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -EnterpriseArgs @("/Execute", $epfPath, "/C$command") `
            -TimeoutSeconds (ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_EVENT_LOG_EXPORT_TIMEOUT_SECONDS" -Default 120) -Default 120) | Out-Null
    } catch {
        if (Test-Path -LiteralPath $outputPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $diagnostic = Read-Utf8Text -Path $outputPath | ConvertFrom-Json
            if ([string]$diagnostic.status -eq "failure") {
                throw "Event log fallback exporter failed. Output: $outputPath. Error: $($diagnostic.errorMessage). Details: $($diagnostic.errorDetails)"
            }
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Event log fallback exporter did not create output file: $outputPath"
    }

    $raw = Read-Utf8Text -Path $outputPath | ConvertFrom-Json
    if ([string]$raw.status -eq "failure") {
        throw "Event log fallback exporter failed. Output: $outputPath. Error: $($raw.errorMessage). Details: $($raw.errorDetails)"
    }

    $events = @()
    foreach ($item in @($raw.events)) {
        $event = [pscustomobject]@{
            date = [datetime]$item.date
            level = Normalize-OneCEventLogLevel -Value ([string]$item.level)
            event = [string]$item.event
            metadata = [string]$item.metadata
            dataPresentation = [string]$item.dataPresentation
            comment = [string]$item.comment
            raw = [string]$item.raw
        }
        $event | Add-Member -NotePropertyName signature -NotePropertyValue (New-EventLogErrorSignature -Event $event) -Force
        $events += $event
    }
    return @($events)
}

function Read-DevBranchEventLogErrors {
    param(
        [object]$State,
        [Nullable[datetime]]$StartTime = $null,
        [Nullable[datetime]]$EndTime = $null,
        [string]$CursorPath = ""
    )

    $reader = Get-VanessaEventLogReader
    $levels = Get-VanessaEventLogLevels
    $lastError = $null

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $delta = $null
    if ($CursorPath) {
        $delta = Get-DevBranchEventLogDeltaSelection -State $State -CursorPath $CursorPath -FallbackStartTime ([datetime]$StartTime)
    }
    if ($reader -eq "auto" -or $reader -eq "direct") {
        try {
            $events = if ($null -ne $delta) {
                @(Read-OneCEventLogDirect -State $State -StartTime $StartTime -EndTime $EndTime -Levels $levels -SegmentSelections $delta.selections)
            } else {
                @(Read-OneCEventLogDirect -State $State -StartTime $StartTime -EndTime $EndTime -Levels $levels)
            }
            $stopwatch.Stop()
            return [pscustomobject]@{
                reader = "direct-stream"
                events = $events
                logDirectory = (Get-DevBranchEventLogDirectory -State $State)
                errorCount = @($events).Count
                durationMs = [int64]$stopwatch.ElapsedMilliseconds
                scannedBytes = $(if ($null -ne $delta) { $delta.scannedBytes } else { -1 })
                scanMode = $(if ($null -ne $delta) { $delta.mode } else { "full" })
            }
        } catch {
            $lastError = $_
            if ($reader -eq "direct" -or $_.Exception.Message -match "Unsupported SQLite") {
                throw
            }
        }
    }

    if ($reader -eq "auto" -or $reader -eq "fallback") {
        try {
            $events = @(Read-OneCEventLogViaFallback -State $State -StartTime $StartTime -EndTime $EndTime -Levels $levels)
            $stopwatch.Stop()
            return [pscustomobject]@{
                reader = "fallback"
                events = $events
                logDirectory = (Get-DevBranchEventLogDirectory -State $State)
                errorCount = @($events).Count
                durationMs = [int64]$stopwatch.ElapsedMilliseconds
                scannedBytes = -1
                scanMode = "fallback-exporter"
            }
        } catch {
            if ($null -ne $lastError) {
                throw "Could not read 1C event log by direct reader or fallback exporter. Direct error: $($lastError.Exception.Message). Fallback error: $($_.Exception.Message)"
            }
            throw
        }
    }
}

function Get-DevBranchEventLogBaselinePath {
    param([object]$State)

    $safeName = Require-Value "safeDevBranchName" (Get-StateValue -State $State -Name "safeDevBranchName")
    $stateProjectRoot = Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot
    return (Join-Path $stateProjectRoot ".agent-1c\event-log-baselines\$safeName.json")
}

function Save-DevBranchEventLogBaseline {
    param(
        [object]$State,
        [string]$Reason = "created"
    )

    $readResult = Read-DevBranchEventLogBaselineData -State $State
    $signatures = @($readResult.signatures)
    $baselinePath = Get-DevBranchEventLogBaselinePath -State $State
    $createdAt = (Get-Date).ToString("o")
    $baseline = [ordered]@{
        schemaVersion = 2
        createdAt = $createdAt
        reason = $Reason
        reader = $readResult.reader
        logDirectory = $readResult.logDirectory
        errorCount = $readResult.errorCount
        signatureCount = @($signatures).Count
        signatures = @($signatures)
        durationMs = $readResult.durationMs
        cache = [ordered]@{
            status = $readResult.cacheStatus
            path = $readResult.cachePath
            sourceKey = $readResult.sourceKey
            segmentCount = $readResult.segmentCount
        }
    }
    Write-Utf8Text -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

    $hash = Get-StringSha256 -Value ((@($signatures) -join "`n"))
    $updates = @{
        eventLogBaselinePath = $baselinePath
        eventLogBaselineCreatedAt = $createdAt
        eventLogBaselineReader = $readResult.reader
        eventLogBaselineErrorCount = $readResult.errorCount
        eventLogBaselineSignatureCount = @($signatures).Count
        eventLogBaselineHash = $hash
        eventLogBaselineCacheStatus = $readResult.cacheStatus
        eventLogBaselineCachePath = $readResult.cachePath
        eventLogBaselineDurationMs = $readResult.durationMs
        eventLogBaselineSegmentCount = $readResult.segmentCount
    }
    if ($Reason -eq "backfill") {
        $updates["eventLogBaselineBackfilledAt"] = $createdAt
    }
    Update-DevBranchState -State $State -Updates $updates

    Write-Host "Event log baseline saved: $baselinePath"
    Write-Host "Event log baseline reader/cache: $($readResult.reader) / $($readResult.cacheStatus)"
    Write-Host "Event log baseline errors/signatures: $($readResult.errorCount) / $(@($signatures).Count)"
    Write-Host "Event log baseline duration: $($readResult.durationMs) ms"

    $statePath = Get-StateValue -State $State -Name "statePath" -Default ""
    if ($statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return (Read-DevBranchStateFile -Path $statePath)
    }
    return $State
}

function Initialize-DevBranchEventLogBaseline {
    param([object]$State)

    Write-Section "Initialize event log baseline"
    return (Save-DevBranchEventLogBaseline -State $State -Reason "created")
}

function Ensure-DevBranchEventLogBaseline {
    param([object]$State)

    $baselinePath = Get-StateValue -State $State -Name "eventLogBaselinePath" -Default ""
    if (-not $baselinePath) {
        $baselinePath = Get-DevBranchEventLogBaselinePath -State $State
    }

    if (Test-Path -LiteralPath $baselinePath -PathType Leaf -ErrorAction SilentlyContinue) {
        return $State
    }

    Write-Host "[WARN] Event log baseline is missing for this existing branch. Creating a backfill baseline before the test run."
    return (Save-DevBranchEventLogBaseline -State $State -Reason "backfill")
}

function Test-DevBranchEventLogAfterVanessa {
    param(
        [object]$State,
        [datetime]$RunStartedAt,
        [datetime]$RunFinishedAt,
        [string]$RunDirectory,
        [string]$CursorPath = ""
    )

    $stateWithBaseline = Ensure-DevBranchEventLogBaseline -State $State
    $baselinePath = Get-StateValue -State $stateWithBaseline -Name "eventLogBaselinePath" -Default (Get-DevBranchEventLogBaselinePath -State $stateWithBaseline)
    $baseline = Read-Utf8Text -Path $baselinePath | ConvertFrom-Json
    $known = @{}
    foreach ($signature in @($baseline.signatures)) {
        if ($signature) {
            $known[[string]$signature] = $true
        }
    }

    $skewSeconds = Get-VanessaEventLogClockSkewSeconds
    $endTime = $RunFinishedAt.AddSeconds($skewSeconds)
    $readResult = Read-DevBranchEventLogErrors -State $stateWithBaseline -StartTime $RunStartedAt -EndTime $endTime -CursorPath $CursorPath

    $newErrors = @()
    $legacyCount = 0
    foreach ($event in @($readResult.events)) {
        if ($known.ContainsKey([string]$event.signature)) {
            $legacyCount++
        } else {
            $newErrors += $event
        }
    }

    $reportPath = ""
    if ($newErrors.Count -gt 0) {
        $reportPath = Join-Path $RunDirectory "event-log-new-errors.json"
        $payload = [ordered]@{
            schemaVersion = 1
            startedAt = $RunStartedAt.ToString("o")
            finishedAt = $RunFinishedAt.ToString("o")
            checkedUntil = $endTime.ToString("o")
            reader = $readResult.reader
            baselinePath = $baselinePath
            newErrorCount = $newErrors.Count
            legacyErrorCount = $legacyCount
            errors = @($newErrors | ForEach-Object {
                [ordered]@{
                    date = $_.date.ToString("o")
                    level = $_.level
                    event = $_.event
                    metadata = $_.metadata
                    dataPresentation = $_.dataPresentation
                    comment = $_.comment
                    signature = $_.signature
                }
            })
        }
        Write-Utf8Text -Path $reportPath -Value (($payload | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }

    $status = if ($newErrors.Count -gt 0) { "failed" } else { "passed" }
    $reason = if ($newErrors.Count -gt 0) {
        "1C event log contains $($newErrors.Count) new error signature(s) not present in the branch baseline."
    } else {
        "1C event log contains no new error signatures. Legacy suppressed errors: $legacyCount."
    }

    return [pscustomobject]@{
        status = $status
        reason = $reason
        reader = $readResult.reader
        baselinePath = $baselinePath
        reportPath = $reportPath
        newErrorCount = $newErrors.Count
        legacyErrorCount = $legacyCount
        checkedUntil = $endTime
        scannedErrorCount = $readResult.errorCount
        readerDurationMs = $readResult.durationMs
        scannedBytes = $readResult.scannedBytes
        scanMode = $readResult.scanMode
    }
}

function New-VanessaTestClientInfoBaseArg {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath
    )

    if ($InfoBaseKind -eq "file") {
        return "/F $(Resolve-InfoBasePath $InfoBasePath)"
    }
    if ($InfoBaseKind -eq "server") {
        return "/S $InfoBasePath"
    }

    throw "Unknown infobase kind: $InfoBaseKind"
}

function New-VanessaTestClientAdditionalParams {
    param(
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $args = @("/VL", "ru")
    if ($User) {
        $args += @("/N", $User)
    }
    $Password = ConvertFrom-OptionalPasswordAnswer $Password
    if (-not [string]::IsNullOrEmpty($Password)) {
        $args += @("/P", $Password)
    }
    $args += "/DisableStartupMessages"

    return (Join-NativeCommandLineArguments -Arguments $args)
}

function New-VanessaStartFeaturePlayerCommand {
    param([string]$ParamsPath)

    if ($ParamsPath -match '"') {
        throw "Vanessa params path must not contain quote characters: $ParamsPath"
    }

    return "StartFeaturePlayer;VAParams=$ParamsPath"
}

function ConvertFrom-Utf8Base64 {
    param([string]$Value)

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function New-VanessaParamsFile {
    param(
        [string]$FeaturePath,
        [string]$RunDirectory,
        [string]$StatusPath,
        [object]$State,
        [int]$TestPort,
        [string]$VanessaVersion = ""
    )

    $resolvedFeaturePath = Resolve-ProjectPath $FeaturePath
    $infoBaseKind = Get-StateValue -State $State -Name "infoBaseKind" -Default (Get-InfoBaseKind)
    $infoBasePath = Require-Value "devBranchInfoBasePath" (Get-StateValue -State $State -Name "devBranchInfoBasePath")
    $user = Get-EnvValue -Name "IB_USER"
    $clientName = if ($user) { $user } else { "default" }
    $windowSearchTimeout = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS" -Default 60) -Default 60
    $actionAttempts = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_ACTION_ATTEMPTS" -Default 3) -Default 3
    $clientStartupTimeout = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS" -Default 300) -Default 300

    $scenarioSettings = [ordered]@{}
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90Y/RgtGM0KjQsNCz0LjQkNGB0YHQuNC90YXRgNC+0L3QvdC+")] = $false
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JjQvdGC0LXRgNCy0LDQu9CS0YvQv9C+0LvQvdC10L3QuNGP0KjQsNCz0LDQl9Cw0LTQsNC90L3Ri9C50J/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lw=")] = 0.1
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg=")] = $false
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JrQvtC70LjRh9C10YHRgtCy0L7QodC10LrRg9C90LTQn9C+0LjRgdC60LDQntC60L3QsA==")] = $windowSearchTimeout
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JrQvtC70LjRh9C10YHRgtCy0L7Qn9C+0L/Ri9GC0L7QutCS0YvQv9C+0LvQvdC10L3QuNGP0JTQtdC50YHRgtCy0LjRjw==")] = $actionAttempts
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0J/QsNGD0LfQsNCf0YDQuNCe0YLQutGA0YvRgtC40LjQntC60L3QsA==")] = 0

    $testClientRecord = [ordered]@{}
    $testClientRecord[(ConvertFrom-Utf8Base64 "0JjQvNGP")] = $clientName
    $testClientRecord[(ConvertFrom-Utf8Base64 "0KHQuNC90L7QvdC40Lw=")] = ""
    $testClientRecord[(ConvertFrom-Utf8Base64 "0J/Rg9GC0YzQmtCY0L3RhNC+0LHQsNC30LU=")] = New-VanessaTestClientInfoBaseArg -InfoBaseKind $infoBaseKind -InfoBasePath $infoBasePath
    $testClientRecord[(ConvertFrom-Utf8Base64 "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA=")] = $TestPort
    $testClientRecord[(ConvertFrom-Utf8Base64 "0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL")] = New-VanessaTestClientAdditionalParams -User $user -Password (Get-EnvValue -Name "IB_PASSWORD")
    $testClientRecord[(ConvertFrom-Utf8Base64 "0KLQuNC/0JrQu9C40LXQvdGC0LA=")] = ConvertFrom-Utf8Base64 "0KLQvtC90LrQuNC5"
    $testClientRecord[(ConvertFrom-Utf8Base64 "0JjQvNGP0JrQvtC80L/RjNGO0YLQtdGA0LA=")] = "localhost"
    $testClientRecord[(ConvertFrom-Utf8Base64 "UElE0JrQu9C40LXQvdGC0LDQotC10YHRgtC40YDQvtCy0LDQvdC40Y8=")] = 0

    $testClientSettings = [ordered]@{}
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JfQsNC/0YPRgdC60LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0KHQnNCw0LrRgdC40LzQuNC30LjRgNC+0LLQsNC90L3Ri9C80J7QutC90L7QvA==")] = $true
    $testClientSettings[(ConvertFrom-Utf8Base64 "0KLQsNC50LzQsNGD0YLQl9Cw0L/Rg9GB0LrQsDHQoQ==")] = $clientStartupTimeout
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JfQsNC60YDRi9Cy0LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0J/RgNC40L3Rg9C00LjRgtC10LvRjNC90L4=")] = $true
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw==")] = @($testClientRecord)

    $params = [ordered]@{}
    $params["Version"] = $VanessaVersion
    $params["Lang"] = "ru"
    $params["featurepath"] = $resolvedFeaturePath
    $params["projectpath"] = $script:ProjectRoot
    $params["gherkinlanguage"] = "ru"
    $params["createlogs"] = $true
    $params["logpath"] = $StatusPath
    $params["junitcreatereport"] = $true
    $params["junitpath"] = $RunDirectory
    $params["allurecreatereport"] = $false
    $params["pendingequalfailed"] = $true
    $params["stoponerror"] = $false
    $params[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90LXQvdC40LXQodGG0LXQvdCw0YDQuNC10LI=")] = $scenarioSettings
    $params[(ConvertFrom-Utf8Base64 "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP")] = $testClientSettings
    $params[(ConvertFrom-Utf8Base64 "0JLRi9Cz0YDRg9C20LDRgtGM0KHRgtCw0YLRg9GB0JLRi9C/0L7Qu9C90LXQvdC40Y/QodGG0LXQvdCw0YDQuNC10LLQktCk0LDQudC7")] = $true
    $params[(ConvertFrom-Utf8Base64 "0J/Rg9GC0YzQmtCk0LDQudC70YPQlNC70Y/QktGL0LPRgNGD0LfQutC40KHRgtCw0YLRg9GB0LDQktGL0L/QvtC70L3QtdC90LjRj9Ch0YbQtdC90LDRgNC40LXQsg==")] = $StatusPath
    $params[(ConvertFrom-Utf8Base64 "0JfQsNCy0LXRgNGI0LjRgtGM0KDQsNCx0L7RgtGD0KHQuNGB0YLQtdC80Ys=")] = $true
    $params[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90LjRgtGM0KHRhtC10L3QsNGA0LjQuA==")] = $true

    if ($VanessaFilterTags) {
        $params["filtertags"] = $VanessaFilterTags
        $params["tags"] = $VanessaFilterTags
    }

    $path = Join-Path $RunDirectory "VAParams.json"
    Write-Utf8Text -Path $path -Value (($params | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $path
}

function Get-VanessaJunitSummary {
    param([string]$RunDirectory)

    $summary = [ordered]@{
        found = $false
        tests = 0
        failures = 0
        errors = 0
        skipped = 0
        testCases = @()
        files = @()
    }

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container -ErrorAction SilentlyContinue)) {
        return [pscustomobject]$summary
    }

    $xmlFiles = @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue)
    foreach ($file in $xmlFiles) {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($file.FullName)
            $nodes = @($xml.SelectNodes('//*[local-name()="testsuite" and not(ancestor::*[local-name()="testsuite"])]'))
            if ($nodes.Count -eq 0 -and $xml.DocumentElement.LocalName -eq "testsuites") {
                $nodes = @($xml.DocumentElement)
            }
            foreach ($node in $nodes) {
                if ($node.Attributes["tests"]) {
                    $summary.tests += [int]$node.Attributes["tests"].Value
                    $summary.found = $true
                }
                if ($node.Attributes["failures"]) {
                    $summary.failures += [int]$node.Attributes["failures"].Value
                    $summary.found = $true
                }
                if ($node.Attributes["errors"]) {
                    $summary.errors += [int]$node.Attributes["errors"].Value
                    $summary.found = $true
                }
            }
            foreach ($case in @($xml.SelectNodes('//*[local-name()="testcase"]'))) {
                $caseSkipped = @($case.SelectNodes('./*[local-name()="skipped"]')).Count -gt 0
                $caseFailure = @($case.SelectNodes('./*[local-name()="failure"]')).Count -gt 0
                $caseError = @($case.SelectNodes('./*[local-name()="error"]')).Count -gt 0
                if ($caseSkipped) { $summary.skipped++ }
                $summary.testCases += [pscustomobject][ordered]@{
                    name = $(if ($case.Attributes["name"]) { [string]$case.Attributes["name"].Value } else { "" })
                    className = $(if ($case.Attributes["classname"]) { [string]$case.Attributes["classname"].Value } else { "" })
                    skipped = $caseSkipped
                    failure = $caseFailure
                    error = $caseError
                    source = $file.FullName
                }
            }
            $summary.files += [pscustomobject][ordered]@{
                path = $file.FullName
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } catch {
            Write-Host "[WARN] Could not parse Vanessa JUnit report: $($file.FullName)"
        }
    }

    return [pscustomobject]$summary
}

function Complete-VanessaAuthoringVerificationFallback {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)

    if ($script:RunAuthoringStatus -ne "runner-fallback-pending") { return }
    $features = @(Get-VanessaAuthoringFeatureRecords)
    $libraryFingerprint = Get-VanessaItlLibraryFingerprint
    $authoring = Read-VanessaAuthoringState
    if (-not (Test-VanessaAuthoringRunnerFallbackEligible -State $authoring -FeatureRecords $features -LibraryFingerprint $libraryFingerprint)) {
        throw "Vanessa authoring runner fallback is no longer eligible for the current feature/library fingerprint."
    }
    if ($VanessaFilterTags) {
        throw "Vanessa authoring runner fallback cannot accept a tag-filtered verification run."
    }

    $allTitles = @{}
    foreach ($path in @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))) {
        $title = [string](Get-VanessaFeatureContract -Path $path).title
        if (-not $title) { continue }
        $key = $title.ToLowerInvariant()
        if (-not $allTitles.ContainsKey($key)) { $allTitles[$key] = 0 }
        $allTitles[$key]++
    }
    $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
    if (-not $junit.found -or $junit.tests -le 0 -or ($junit.failures + $junit.errors) -gt 0) {
        throw "Vanessa authoring runner fallback requires a passing JUnit report with executed tests."
    }
    $matched = @()
    foreach ($feature in $features) {
        $title = [string]$feature.title
        if (-not $title -or -not $allTitles.ContainsKey($title.ToLowerInvariant()) -or [int]$allTitles[$title.ToLowerInvariant()] -ne 1) {
            throw "Vanessa authoring runner fallback requires a unique feature title for '$($feature.path)'."
        }
        $cases = @($junit.testCases | Where-Object {
            ([string]$_.className -ieq $title -or ([string]$_.className).EndsWith(".$title", [System.StringComparison]::OrdinalIgnoreCase))
        })
        if ($cases.Count -eq 0) {
            throw "Vanessa JUnit did not prove execution of changed feature '$($feature.path)' (title '$title')."
        }
        if (@($cases | Where-Object { $_.skipped -or $_.failure -or $_.error }).Count -gt 0) {
            throw "Vanessa JUnit contains skipped/failed/error testcases for changed feature '$($feature.path)'."
        }
        $matched += [pscustomobject][ordered]@{
            featurePath = [string]$feature.path
            featureSha256 = [string]$feature.sha256
            title = $title
            testCases = @($cases | ForEach-Object { [pscustomobject]@{ name = $_.name; className = $_.className } })
        }
    }
    $junitDigestInput = @($junit.files | Sort-Object path | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    $now = (Get-Date).ToString("o")
    $authoring.features = @($features)
    $authoring.libraryFingerprint = $libraryFingerprint
    $authoring.phase = "passed"
    $authoring.completionMode = "verification-fallback"
    $authoring.resultsPath = $RunDirectory
    $authoring.passedAt = $now
    $authoring.updatedAt = $now
    $authoring.verificationFallback = [pscustomobject][ordered]@{
        runId = Split-Path -Leaf $RunDirectory
        junitSha256 = Get-StringSha256 -Value $junitDigestInput
        junitFiles = @($junit.files)
        matchedFeatures = @($matched)
        completedAt = $now
    }
    Write-VanessaAuthoringState -State $authoring | Out-Null
    $script:RunAuthoringStatus = "passed"
    Write-Host "Vanessa authoring: passed via canonical verification fallback for $($matched.Count) changed feature(s)."
}

function Get-VanessaVerificationStatus {
    param(
        [string]$RunDirectory,
        [string]$StatusPath
    )

    $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
    if ($junit.found) {
        if (($junit.failures + $junit.errors) -gt 0) {
            return [pscustomobject]@{
                status = "failed"
                reason = "Vanessa JUnit report contains failures/errors: failures=$($junit.failures), errors=$($junit.errors)."
            }
        }
        if ($junit.tests -gt 0) {
            return [pscustomobject]@{
                status = "passed"
                reason = "Vanessa JUnit report contains $($junit.tests) tests without failures/errors."
            }
        }
    }

    if (Test-Path -LiteralPath $StatusPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $statusText = Read-Utf8Text -Path $StatusPath
        $failurePattern = '(?i)("failures?"\s*:\s*[1-9]|"failed"\s*:\s*true|"errors?"\s*:\s*[1-9]|\bfailed\b|\bfailure\b|\bexception\b|провален|ошиб[а-я]*\s*:\s*(true|[1-9]))'
        if ($statusText -match $failurePattern) {
            return [pscustomobject]@{
                status = "failed"
                reason = "Vanessa status file contains failure/error markers."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($statusText)) {
            return [pscustomobject]@{
                status = "unknown"
                reason = "Vanessa status file was created, but no JUnit report with executed tests was found."
            }
        }
    }

    return [pscustomobject]@{
        status = "unknown"
        reason = "Vanessa finished, but no reliable status or JUnit result was found."
    }
}

function Get-GitObjectIdForHeadPath {
    param([string]$RepoPath)

    $normalized = ($RepoPath -replace "\\", "/").Trim("/")
    if (-not $normalized) {
        return ""
    }

    & git -C $script:ProjectRoot rev-parse --verify --quiet "HEAD:$normalized" *> $null
    if ($LASTEXITCODE -ne 0) {
        return "<missing>"
    }

    $output = Get-GitOutput @("rev-parse", "HEAD:$normalized")
    if ($output) {
        return ([string]$output).Trim()
    }
    return "<missing>"
}

function Get-GitDiffDigestForFingerprintPaths {
    param([string[]]$PathSpec)

    $arguments = @("-c", "core.quotepath=false", "diff", "--binary", "--no-color", "--no-ext-diff", "HEAD", "--") + @($PathSpec)
    $output = & git -C $script:ProjectRoot @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Could not calculate the tracked verification diff."
    }
    return (Get-StringSha256 -Value (@($output) -join "`n"))
}

function Get-UntrackedDigestForFingerprintPaths {
    param([string[]]$PathSpec)

    $arguments = @("-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard", "--") + @($PathSpec)
    $paths = @(& git -C $script:ProjectRoot @arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not enumerate untracked verification files."
    }

    $parts = @()
    foreach ($repoPath in @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)) {
        $normalized = ([string]$repoPath -replace "\\", "/").TrimStart("/")
        $fullPath = Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $normalized)
        $rootPath = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd([char[]]@('\', '/'))
        if (-not $fullPath.StartsWith(($rootPath + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Verification untracked file resolved outside the project root: $normalized"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            $parts += "$normalized=<missing>"
            continue
        }
        $parts += "$normalized=$((Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant())"
    }
    return (Get-StringSha256 -Value ($parts -join "|"))
}

function Get-VerificationFingerprint {
    $paths = @(
        (Get-ExportPath),
        (Get-ExtensionsPath),
        (Get-VanessaFeaturesPath)
    )

    $parts = @("v2")
    foreach ($path in $paths) {
        $normalized = ($path -replace "\\", "/").Trim("/")
        if ($normalized) {
            $parts += "$normalized=$(Get-GitObjectIdForHeadPath -RepoPath $normalized)"
        }
    }

    $parts += "tracked=$(Get-GitDiffDigestForFingerprintPaths -PathSpec $paths)"
    $parts += "untracked=$(Get-UntrackedDigestForFingerprintPaths -PathSpec $paths)"

    return ($parts -join "|")
}

function Get-VerificationState {
    param(
        [object]$State,
        [string]$CurrentCommit = "",
        [string]$CurrentFingerprint = ""
    )

    $status = [string](Get-StateValue -State $State -Name "lastVerificationStatus" -Default "missing")
    $commit = [string](Get-StateValue -State $State -Name "lastVerifiedCommit" -Default "")
    $fingerprint = [string](Get-StateValue -State $State -Name "lastVerifiedFingerprint" -Default "")
    $currentCommitValue = $CurrentCommit
    $currentFingerprintValue = $CurrentFingerprint
    $isFresh = $false
    try {
        if (-not $currentCommitValue) {
            $currentCommitValue = Get-CurrentCommit
        }
        if (-not $currentFingerprintValue) {
            $currentFingerprintValue = Get-VerificationFingerprint
        }
        if ($fingerprint) {
            $isFresh = ($status -eq "passed" -and $fingerprint -eq $currentFingerprintValue)
        } else {
            $isFresh = ($status -eq "passed" -and $commit -and $commit -eq $currentCommitValue)
        }
    } catch {
        $currentCommitValue = ""
        $currentFingerprintValue = ""
        $isFresh = $false
    }

    $effectiveStatus = $status
    if ($status -eq "passed" -and -not $isFresh) {
        $effectiveStatus = "stale"
    }

    return [pscustomobject]@{
        status = $status
        effectiveStatus = $effectiveStatus
        isFreshPassed = $isFresh
        verifiedCommit = $commit
        currentCommit = $currentCommitValue
        verifiedFingerprint = $fingerprint
        currentFingerprint = $currentFingerprintValue
        verifiedAt = [string](Get-StateValue -State $State -Name "lastVerifiedAt" -Default "")
        reportPath = [string](Get-StateValue -State $State -Name "lastVerifiedReportPath" -Default "")
        logPath = [string](Get-StateValue -State $State -Name "lastVerificationLogPath" -Default "")
        reason = [string](Get-StateValue -State $State -Name "lastVerificationReason" -Default "")
    }
}

function Add-VerificationStaleIfNeeded {
    param(
        [object]$State,
        [hashtable]$Updates,
        [string]$Reason,
        [string]$CurrentCommit = (Get-CurrentCommit),
        [switch]$Force
    )

    $verification = Get-VerificationState -State $State
    $currentFingerprint = $verification.currentFingerprint
    if ($verification.status -eq "passed" -and ($Force -or $verification.verifiedFingerprint -ne $currentFingerprint)) {
        $Updates["lastVerificationStatus"] = "stale"
        $Updates["lastVerificationStaleAt"] = (Get-Date).ToString("o")
        $Updates["lastVerificationStaleReason"] = $Reason
    }
}

function Confirm-UnverifiedProceed {
    param(
        [object]$State,
        [string]$Operation,
        [switch]$Allow
    )

    $verification = Get-VerificationState -State $State
    if ($verification.isFreshPassed) {
        return $false
    }

    $policy = Get-VerificationPolicy
    if ($policy -eq "block") {
        throw "$Operation stopped because verificationPolicy=block and fresh passed full executable verification is missing. Run verify-dev-branch before exporting or closing the branch."
    }

    Write-Host "[WARN] Current development branch has no fresh successful Vanessa verification."
    Write-Host "Verification status: $($verification.effectiveStatus)"
    if ($verification.reason) {
        Write-Host "Verification reason: $($verification.reason)"
    }
    if ($verification.verifiedAt) {
        Write-Host "Last verified at: $($verification.verifiedAt)"
    }
    if ($verification.verifiedCommit) {
        Write-Host "Last verified commit: $($verification.verifiedCommit)"
    }
    if ($verification.currentCommit) {
        Write-Host "Current commit: $($verification.currentCommit)"
    }
    if ($verification.reportPath) {
        Write-Host "Last verification report: $($verification.reportPath)"
    }

    if ($Allow) {
        Write-Host "Explicit unverified override accepted for $Operation."
        if ($verification.status -eq "partial") {
            Write-Host "Result wording is restricted to: implemented; executable verification skipped. Do not report verified/done."
        }
        return $true
    }

    throw "$Operation stopped because fresh passed Vanessa verification is missing. Run verify-dev-branch or rerun with explicit unverified override."
}

function Run-DevBranchTests {
    Set-RunStage -Stage "vanessa.prepare" -Detail "Preparing Vanessa Automation verification."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "run-dev-branch-tests"
    Assert-DevBranchExtensionInitialized -State $state -Operation "run-dev-branch-tests"
    $state = Ensure-DevBranchEnterpriseNormalized -State $state -Reason "legacy-preflight"
    Sync-DevBranchContextToDotEnv -State $state

    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        throw "Vanessa Automation is not installed. Run install-vanessa-automation first."
    }

    $featuresPath = Get-VanessaFeaturesPath
    $featureFiles = @(Get-VanessaFeatureFiles -FeaturePath $featuresPath)
    if ($featureFiles.Count -eq 0) {
        throw "No Vanessa .feature files found under '$featuresPath'. Create tests in tests/features before running dev branch tests."
    }

    $testPort = Resolve-VanessaTestPort -State $state
    Update-DevBranchState -State $state -Updates @{
        vanessaTestPort = $testPort
        vanessaTestPortUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    Save-VanessaTestSettingsToDotEnv -Port $testPort
    Invoke-ForeignVanessaTestProcessPolicy -State $state -TestPort $testPort
    $state = Ensure-DevBranchEventLogBaseline -State $state

    $runDirectory = New-VanessaRunDirectory
    $statusPath = Join-Path $runDirectory "status.json"
    $eventLogCursorPath = Join-Path $runDirectory "event-log-cursor.json"
    New-DevBranchEventLogCursor -State $state -Path $eventLogCursorPath | Out-Null
    $paramsPath = New-VanessaParamsFile `
        -FeaturePath $featuresPath `
        -RunDirectory $runDirectory `
        -StatusPath $statusPath `
        -State $state `
        -TestPort $testPort `
        -VanessaVersion $vanessa.version

    Write-Host "Vanessa Automation EPF: $($vanessa.epfPath)"
    Write-Host "Vanessa features: $(Resolve-ProjectPath $featuresPath)"
    Write-Host "Vanessa report directory: $runDirectory"
    Write-Host "Vanessa params: $paramsPath"
    Write-Host "Vanessa TestClient port: $testPort"
    if ($VanessaFilterTags) {
        Write-Host "Vanessa tag filter: $VanessaFilterTags"
    }
    Write-Host "Dev branch tests use TESTMANAGER -> TESTCLIENT and do not load configuration files. Use check-dev-branch for the normal post-change update plus test cycle."

    $command = New-VanessaStartFeaturePlayerCommand -ParamsPath $paramsPath
    $enterpriseArgs = @("/Execute", $vanessa.epfPath, "/C$command")
    $logPath = ""
    $currentCommit = Get-CurrentCommit
    $currentFingerprint = Get-VerificationFingerprint
    $timeoutSeconds = Get-VanessaTestTimeoutSeconds
    $runStartedAt = Get-Date
    $runFinishedAt = $null
    $eventLogVerification = $null
    $authoringFallbackError = ""
    $runnerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDurationMs = [int64]0
    $eventLogDurationMs = [int64]0
    $postProcessStopwatch = $null
    Write-Host "Vanessa test timeout: $timeoutSeconds seconds"
    try {
        Set-RunStage -Stage "vanessa.run" -Detail "Running TESTMANAGER and TESTCLIENT."
        $logPath = Invoke-Enterprise `
            -InfoBasePath $state.devBranchInfoBasePath `
            -InfoBaseKind $state.infoBaseKind `
            -EnterpriseArgs $enterpriseArgs `
            -TestClientPort $testPort `
            -TimeoutSeconds $timeoutSeconds `
            -CompletionProbe {
                $probeStatus = Get-VanessaVerificationStatus -RunDirectory $runDirectory -StatusPath $statusPath
                return ($probeStatus.status -in @("passed", "failed"))
            } `
            -CompletionGraceSeconds 10 `
            -OnTimeout {
                Write-Host "[WARN] Vanessa verify exceeded timeout; stopping own TESTMANAGER/TESTCLIENT processes."
                Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
            }
        $runnerStopwatch.Stop()
    } catch {
        if ($runnerStopwatch.IsRunning) { $runnerStopwatch.Stop() }
        Set-RunStage -Stage "vanessa.postprocess" -Detail "Cleaning up and reading verification evidence after a failed runner."
        $postProcessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $runFinishedAt = Get-Date
        $logPath = $script:LastLogPath
        Write-OneCVanessaProcessDiagnostics -State $state -TestPort $testPort -Context "Vanessa verify failed; active 1C process diagnostics"
        $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
        $cleanupStopwatch.Stop(); $cleanupDurationMs = $cleanupStopwatch.ElapsedMilliseconds
        $eventLogReason = ""
        try {
            $eventLogStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $eventLogVerification = if ($script:ItlSkipEventLogForVerification) {
                [pscustomobject]@{ status = "skipped"; reason = "ITL_CHECK_EVENT_LOG=off skipped event-log verification."; reader = ""; baselinePath = ""; reportPath = ""; newErrorCount = 0; legacyErrorCount = 0; checkedUntil = $runFinishedAt; scannedBytes = 0; scanMode = "skipped" }
            } else {
                Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory -CursorPath $eventLogCursorPath
            }
            $eventLogStopwatch.Stop(); $eventLogDurationMs = $eventLogStopwatch.ElapsedMilliseconds
            $eventLogReason = $eventLogVerification.reason
        } catch {
            $eventLogReason = "1C event log check failed after Vanessa failure: $($_.Exception.Message)"
        }
        $failureReason = $_.Exception.Message
        if ($eventLogReason) {
            $failureReason = "$failureReason Event log: $eventLogReason"
        }
        $updates = @{
            lastVanessaTestAt = (Get-Date).ToString("o")
            lastVanessaStartedAt = $runStartedAt.ToString("o")
            lastVanessaFinishedAt = $runFinishedAt.ToString("o")
            lastVanessaFeaturePath = $featuresPath
            lastVanessaReportPath = $runDirectory
            lastVanessaParamsPath = $paramsPath
            lastVanessaStatusPath = $statusPath
            lastVanessaLogPath = $logPath
            lastVanessaTestPort = $testPort
            lastVanessaTestPid = $script:LastProcessId
            lastVanessaTimedOut = $script:LastProcessTimedOut
            lastVanessaTimeoutSeconds = $timeoutSeconds
            lastVerificationStatus = "failed"
            lastVerifiedCommit = $currentCommit
            lastVerifiedFingerprint = $currentFingerprint
            lastVerifiedAt = (Get-Date).ToString("o")
            lastVerifiedReportPath = $runDirectory
            lastVerificationLogPath = $logPath
            lastVerificationReason = $failureReason
        }
        if ($null -ne $eventLogVerification) {
            $updates["lastVanessaEventLogReader"] = $eventLogVerification.reader
            $updates["lastVanessaEventLogBaselinePath"] = $eventLogVerification.baselinePath
            $updates["lastVanessaEventLogNewErrorsPath"] = $eventLogVerification.reportPath
            $updates["lastVanessaEventLogNewErrorCount"] = $eventLogVerification.newErrorCount
            $updates["lastVanessaEventLogLegacyErrorCount"] = $eventLogVerification.legacyErrorCount
            $updates["lastVanessaEventLogCheckedUntil"] = $eventLogVerification.checkedUntil.ToString("o")
            $updates["lastVanessaEventLogScannedBytes"] = $eventLogVerification.scannedBytes
            $updates["lastVanessaEventLogScanMode"] = $eventLogVerification.scanMode
        }
        $postProcessStopwatch.Stop()
        $updates["lastVanessaRunnerDurationMs"] = [int64]$runnerStopwatch.ElapsedMilliseconds
        $updates["lastVanessaCleanupDurationMs"] = $cleanupDurationMs
        $updates["lastVanessaEventLogDurationMs"] = $eventLogDurationMs
        $updates["lastVanessaPostProcessDurationMs"] = [int64]$postProcessStopwatch.ElapsedMilliseconds
        Update-DevBranchState -State $state -Updates $updates
        throw
    }

    Set-RunStage -Stage "vanessa.postprocess" -Detail "Cleaning up and reading JUnit and event-log evidence."
    $runFinishedAt = Get-Date
    $postProcessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $verification = Get-VanessaVerificationStatus -RunDirectory $runDirectory -StatusPath $statusPath
    try {
        $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-OwnVanessaTestProcessesAndAssert -State $state
        $cleanupStopwatch.Stop(); $cleanupDurationMs = $cleanupStopwatch.ElapsedMilliseconds
    } catch {
        if ($cleanupStopwatch.IsRunning) { $cleanupStopwatch.Stop() }
        $cleanupDurationMs = $cleanupStopwatch.ElapsedMilliseconds
        $verification = [pscustomobject]@{
            status = "failed"
            reason = "$($verification.reason) Vanessa process cleanup: $($_.Exception.Message)"
        }
    }
    try {
        $eventLogStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $eventLogVerification = if ($script:ItlSkipEventLogForVerification) {
            [pscustomobject]@{ status = "skipped"; reason = "ITL_CHECK_EVENT_LOG=off skipped event-log verification."; reader = ""; baselinePath = ""; reportPath = ""; newErrorCount = 0; legacyErrorCount = 0; checkedUntil = $runFinishedAt; scannedBytes = 0; scanMode = "skipped" }
        } else {
            Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory -CursorPath $eventLogCursorPath
        }
        $eventLogStopwatch.Stop(); $eventLogDurationMs = $eventLogStopwatch.ElapsedMilliseconds
    } catch {
        if ($eventLogStopwatch.IsRunning) { $eventLogStopwatch.Stop() }
        $eventLogDurationMs = $eventLogStopwatch.ElapsedMilliseconds
        $eventLogVerification = [pscustomobject]@{
            status = "failed"
            reason = "1C event log check failed: $($_.Exception.Message)"
            reader = ""
            baselinePath = Get-StateValue -State $state -Name "eventLogBaselinePath" -Default ""
            reportPath = ""
            newErrorCount = 0
            legacyErrorCount = 0
            checkedUntil = $runFinishedAt
            scannedBytes = 0
            scanMode = "failed"
        }
    }
    $postProcessStopwatch.Stop()
    if ($eventLogVerification.status -eq "failed") {
        $verification = [pscustomobject]@{
            status = "failed"
            reason = "$($verification.reason) Event log: $($eventLogVerification.reason)"
        }
    } elseif ($eventLogVerification.status -eq "passed" -and $verification.status -eq "passed") {
        $verification = [pscustomobject]@{
            status = "passed"
            reason = "$($verification.reason) Event log: $($eventLogVerification.reason)"
        }
    }
    if ($verification.status -eq "passed" -and $script:RunAuthoringStatus -eq "runner-fallback-pending") {
        try {
            Complete-VanessaAuthoringVerificationFallback -RunDirectory $runDirectory
            $verification = [pscustomobject]@{
                status = "passed"
                reason = "$($verification.reason) Changed feature execution matched the Vanessa authoring runner fallback contract."
            }
        } catch {
            $authoringFallbackError = $_.Exception.Message
            $verification = [pscustomobject]@{
                status = "failed"
                reason = "Vanessa authoring runner fallback proof failed: $authoringFallbackError"
            }
        }
    }

    Update-DevBranchState -State $state -Updates @{
        lastVanessaTestAt = (Get-Date).ToString("o")
        lastVanessaStartedAt = $runStartedAt.ToString("o")
        lastVanessaFinishedAt = $runFinishedAt.ToString("o")
        lastVanessaFeaturePath = $featuresPath
        lastVanessaReportPath = $runDirectory
        lastVanessaParamsPath = $paramsPath
        lastVanessaStatusPath = $statusPath
        lastVanessaLogPath = $logPath
        lastVanessaTestPort = $testPort
        lastVanessaTestPid = $script:LastProcessId
        lastVanessaTimedOut = $script:LastProcessTimedOut
        lastVanessaTimeoutSeconds = $timeoutSeconds
        lastVanessaEventLogReader = $eventLogVerification.reader
        lastVanessaEventLogBaselinePath = $eventLogVerification.baselinePath
        lastVanessaEventLogNewErrorsPath = $eventLogVerification.reportPath
        lastVanessaEventLogNewErrorCount = $eventLogVerification.newErrorCount
        lastVanessaEventLogLegacyErrorCount = $eventLogVerification.legacyErrorCount
        lastVanessaEventLogCheckedUntil = $eventLogVerification.checkedUntil.ToString("o")
        lastVanessaEventLogScannedBytes = $eventLogVerification.scannedBytes
        lastVanessaEventLogScanMode = $eventLogVerification.scanMode
        lastVanessaRunnerDurationMs = [int64]$runnerStopwatch.ElapsedMilliseconds
        lastVanessaCleanupDurationMs = $cleanupDurationMs
        lastVanessaEventLogDurationMs = $eventLogDurationMs
        lastVanessaPostProcessDurationMs = [int64]$postProcessStopwatch.ElapsedMilliseconds
        lastVerificationStatus = $verification.status
        lastVerifiedCommit = $currentCommit
        lastVerifiedFingerprint = $currentFingerprint
        lastVerifiedAt = (Get-Date).ToString("o")
        lastVerifiedReportPath = $runDirectory
        lastVerificationLogPath = $logPath
        lastVerificationReason = $verification.reason
    }

    Write-Host "Vanessa tests finished."
    Write-Host "Verification status: $($verification.status)"
    Write-Host "Verification reason: $($verification.reason)"
    Write-Host "Report directory: $runDirectory"
    Write-Host "Status file: $statusPath"
    Write-Host "1C log: $logPath"
    Write-Host "Event log verification: $($eventLogVerification.reason)"
    if ($eventLogVerification.reportPath) {
        Write-Host "Event log new errors: $($eventLogVerification.reportPath)"
    }
    if ($verification.status -ne "passed") {
        Set-RunStage -Stage "vanessa.failed" -Detail $verification.reason
        if ($authoringFallbackError) {
            Set-RunFailureContext -Category "unsupported-step" -RequiredAction "/itl-vanessa-author"
        } elseif ($verification.status -eq "unknown") {
            Set-RunFailureContext -Category "runner"
            Write-OneCVanessaProcessDiagnostics -State $state -TestPort $testPort -Context "Vanessa verify produced no reliable JUnit/status; active 1C process diagnostics"
            Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
        } elseif ($eventLogVerification.status -eq "failed") {
            Set-RunFailureContext -Category "event-log" -RequiredAction "/itl-verify-fix"
        } elseif ([string]$verification.reason -match '(?i)(undefined step|step.+not found|unsupported-step)') {
            Set-RunFailureContext -Category "unsupported-step" -RequiredAction "/itl-vanessa-author"
        } elseif ([string]$verification.reason -match '(?i)(scenario context|scenario-context)') {
            Set-RunFailureContext -Category "scenario-context" -RequiredAction "/itl-vanessa-author"
        } else {
            Set-RunFailureContext -Category "product-assertion" -RequiredAction "/itl-verify-fix"
        }
        throw "Vanessa verification did not pass: $($verification.status). $($verification.reason)"
    }
    Set-RunStage -Stage "vanessa.complete" -Detail "Vanessa Automation verification passed."
}

function ConvertTo-IntOrDefault {
    param(
        [AllowNull()][object]$Value,
        [int]$Default = 0
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Get-VanessaTestPortRange {
    $range = [string](Get-EnvValue -Name "VANESSA_TEST_PORT_RANGE" -Default "")
    if ($range -match '^\s*(\d+)\s*(?:\.\.|-|:)\s*(\d+)\s*$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
    } else {
        $start = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_PORT_START" -Default 48051) -Default 48051
        $end = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_PORT_END" -Default 48150) -Default 48150
    }

    if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
        throw "Invalid Vanessa TestClient port range: $start..$end"
    }

    return [pscustomobject]@{
        start = $start
        end = $end
    }
}

function Get-OneCProcessInfo {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name = '1cv8.exe' OR Name = '1cv8c.exe'" -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                processId = [int]$_.ProcessId
                name = [string]$_.Name
                commandLine = [string]$_.CommandLine
                workingSetMb = [math]::Round(([double]$_.WorkingSetSize / 1MB), 1)
            }
        })
    } catch {
        Write-Host "[WARN] Could not inspect active 1C processes: $($_.Exception.Message)"
        return @()
    }
}

function Test-CommandLineContainsValue {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $haystack = ([string]$CommandLine).ToLowerInvariant() -replace "/", "\"
    $needle = ([string]$Value).Trim().ToLowerInvariant() -replace "/", "\"
    if (-not $needle) {
        return $false
    }

    return $haystack.Contains($needle)
}

function Test-CommandLineContainsPort {
    param(
        [AllowNull()][string]$CommandLine,
        [int]$Port
    )

    if ($Port -le 0 -or [string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    return ([string]$CommandLine) -match "(?<!\d)$Port(?!\d)"
}

function Test-OneCVanessaTestProcess {
    param([object]$ProcessInfo)

    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    if ($commandLine -match '(?i)runMcp\s*;\s*mcpPort=') { return $false }
    return ($commandLine -match "(?i)(/TESTMANAGER|/TESTCLIENT|StartFeaturePlayer|VAParams=)")
}

function Test-OneCProcessBelongsToState {
    param(
        [object]$ProcessInfo,
        [object]$State,
        [int]$TestPort = 0,
        [switch]$RequireTestPort
    )

    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    $stateValues = @(
        (Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default ""),
        (Get-StateValue -State $State -Name "worktreePath" -Default ""),
        (Get-StateValue -State $State -Name "stateProjectRoot" -Default ""),
        (Get-StateValue -State $State -Name "safeDevBranchName" -Default "")
    )

    $matchesState = $false
    foreach ($value in $stateValues) {
        if ($value -and (Test-CommandLineContainsValue -CommandLine $commandLine -Value $value)) {
            $matchesState = $true
            break
        }
    }

    if (-not $matchesState) {
        return $false
    }

    if ($RequireTestPort -and $TestPort -gt 0 -and -not (Test-CommandLineContainsPort -CommandLine $commandLine -Port $TestPort)) {
        return $false
    }

    return $true
}

function Format-OneCProcessInfo {
    param([object]$ProcessInfo)

    $pidValue = Get-StateValue -State $ProcessInfo -Name "processId" -Default ""
    $name = Get-StateValue -State $ProcessInfo -Name "name" -Default ""
    $workingSetMb = Get-StateValue -State $ProcessInfo -Name "workingSetMb" -Default ""
    $commandLine = Get-StateValue -State $ProcessInfo -Name "commandLine" -Default ""
    return "PID=$pidValue NAME=$name WS=${workingSetMb}MB CMD=$commandLine"
}

function Get-ForeignVanessaTestProcesses {
    param(
        [object]$State,
        [int]$TestPort = 0
    )

    return @(Get-OneCProcessInfo | Where-Object {
        (Test-OneCVanessaTestProcess -ProcessInfo $_) -and
        -not (Test-OneCProcessBelongsToState -ProcessInfo $_ -State $State -TestPort $TestPort)
    })
}

function Test-VanessaTestPortOwnedByState {
    param(
        [object]$State,
        [int]$Port
    )

    if ($Port -le 0) {
        return $false
    }

    foreach ($processInfo in Get-OneCProcessInfo) {
        if ((Test-CommandLineContainsPort -CommandLine $processInfo.commandLine -Port $Port) -and
            (Test-OneCProcessBelongsToState -ProcessInfo $processInfo -State $State -TestPort $Port)) {
            return $true
        }
    }

    return $false
}

function Test-VanessaTestPortUsedByForeignProcess {
    param(
        [object]$State,
        [int]$Port
    )

    if ($Port -le 0) {
        return $false
    }

    foreach ($processInfo in Get-OneCProcessInfo) {
        if ((Test-OneCVanessaTestProcess -ProcessInfo $processInfo) -and
            (Test-CommandLineContainsPort -CommandLine $processInfo.commandLine -Port $Port) -and
            -not (Test-OneCProcessBelongsToState -ProcessInfo $processInfo -State $State -TestPort $Port -RequireTestPort)) {
            return $true
        }
    }

    return $false
}

function Get-VanessaTestReservedPorts {
    param([object]$CurrentState)

    $currentSafeName = Get-StateValue -State $CurrentState -Name "safeDevBranchName" -Default ""
    $ports = @{}
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            $safeName = Get-StateValue -State $state -Name "safeDevBranchName" -Default ""
            if ($currentSafeName -and $safeName -eq $currentSafeName) {
                continue
            }

            $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $state -Name "vanessaTestPort" -Default 0)
            if ($port -gt 0) {
                $ports[$port] = $true
            }
        } catch {
        }
    }

    return $ports
}

function Resolve-VanessaTestPort {
    param([object]$State)

    $reserved = Get-VanessaTestReservedPorts -CurrentState $State
    $savedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
    $range = Get-VanessaTestPortRange
    $key = Get-ItlBranchManagedPortKey -Family "vanessa-testclient" -State $State

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $port = Resolve-ItlManagedPort `
            -Family "vanessa-testclient" `
            -Key $key `
            -Start $range.start `
            -End $range.end `
            -PreferredPort $savedPort `
            -ExplicitPort $VanessaTestPort `
            -ReservedPorts $reserved `
            -State $State `
            -Subject "Vanessa TestClient port"

        if (-not (Test-VanessaTestPortUsedByForeignProcess -State $State -Port $port)) {
            return $port
        }

        Release-ItlManagedPortAllocation -Family "vanessa-testclient" -Key $key
        if ($VanessaTestPort -gt 0) {
            throw "Requested Vanessa TestClient port $VanessaTestPort is already used by another branch 1C test process."
        }
        $reserved[$port] = $true
    }

    throw "No free Vanessa TestClient port found in range $($range.start)..$($range.end). Stop another branch Vanessa run or override VANESSA_TEST_PORT_RANGE."
}

function Save-VanessaTestSettingsToDotEnv {
    param([int]$Port)

    Set-DotEnvValues -Values @{
        VANESSA_TEST_PORT = $(if ($Port -gt 0) { [string]$Port } else { "" })
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Get-VanessaTestForeignWaitMode {
    $mode = [string](Get-EnvValue -Name "VANESSA_TEST_FOREIGN_WAIT_MODE" -Default "warn")
    $mode = $mode.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($mode)) {
        return "warn"
    }

    if ($mode -ne "warn" -and $mode -ne "wait") {
        throw "Invalid VANESSA_TEST_FOREIGN_WAIT_MODE '$mode'. Use 'warn' or 'wait'."
    }

    return $mode
}

function Write-ForeignVanessaTestProcessWarning {
    param(
        [object]$State,
        [int]$TestPort
    )

    $foreign = @(Get-ForeignVanessaTestProcesses -State $State -TestPort $TestPort)
    if ($foreign.Count -eq 0) {
        return
    }

    Write-Host "[WARN] Foreign Vanessa 1C test process(es) are active. Continuing because verify uses branch-local ports and infobases."
    Write-Host "[WARN] These processes will not be stopped by this helper unless they belong to the current branch."
    foreach ($processInfo in $foreign) {
        Write-Host "  $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
    }
}

function Invoke-ForeignVanessaTestProcessPolicy {
    param(
        [object]$State,
        [int]$TestPort
    )

    $waitMode = Get-VanessaTestForeignWaitMode
    if ($waitMode -eq "wait") {
        Wait-ForeignVanessaTestQuiet -State $State -TestPort $TestPort
        return
    }

    Write-ForeignVanessaTestProcessWarning -State $State -TestPort $TestPort
}

function Wait-ForeignVanessaTestQuiet {
    param(
        [object]$State,
        [int]$TestPort
    )

    $quietSeconds = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_FOREIGN_QUIET_SECONDS" -Default 60) -Default 60
    $timeoutSeconds = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_FOREIGN_WAIT_TIMEOUT_SECONDS" -Default 600) -Default 600
    if ($quietSeconds -le 0 -or $timeoutSeconds -le 0) {
        return
    }

    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $quietSince = $null
    $sawForeign = $false
    while ((Get-Date) -lt $deadline) {
        $foreign = @(Get-ForeignVanessaTestProcesses -State $State -TestPort $TestPort)
        if ($foreign.Count -gt 0) {
            $sawForeign = $true
            $quietSince = $null
            Write-Host "Waiting for foreign Vanessa 1C process(es) to finish before verify:"
            foreach ($processInfo in $foreign) {
                Write-Host "  $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
            }
            Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, $quietSeconds)))
            continue
        }

        if (-not $sawForeign) {
            return
        }

        if ($null -eq $quietSince) {
            $quietSince = Get-Date
        } elseif (((Get-Date) - $quietSince).TotalSeconds -ge $quietSeconds) {
            Write-Host "Foreign Vanessa 1C processes stayed quiet for $quietSeconds seconds."
            return
        }

        Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, $quietSeconds)))
    }

    $remaining = @(Get-ForeignVanessaTestProcesses -State $State -TestPort $TestPort)
    $details = ($remaining | ForEach-Object { Format-OneCProcessInfo -ProcessInfo $_ }) -join [Environment]::NewLine
    throw "Foreign Vanessa 1C processes did not stay quiet within $timeoutSeconds seconds. Active processes:$([Environment]::NewLine)$details"
}

function Stop-OwnHungVanessaTestClients {
    param(
        [object]$State,
        [int]$TestPort
    )

    $ownClients = @(Get-OneCProcessInfo | Where-Object {
        ([string]$_.commandLine) -match "(?i)(/TESTCLIENT|/TESTMANAGER|StartFeaturePlayer|VAParams=)" -and
        (Test-OneCProcessBelongsToState -ProcessInfo $_ -State $State -TestPort $TestPort)
    })

    foreach ($processInfo in $ownClients) {
        Write-Host "Stopping own hung Vanessa TESTMANAGER/TESTCLIENT process: $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
        Stop-Process -Id $processInfo.processId -Force -ErrorAction SilentlyContinue
    }
}

function Write-OneCVanessaProcessDiagnostics {
    param(
        [object]$State,
        [int]$TestPort,
        [string]$Context = "Vanessa process diagnostics"
    )

    Write-Host "${Context}:"
    $processes = @(Get-OneCProcessInfo | Where-Object { Test-OneCVanessaTestProcess -ProcessInfo $_ })
    if ($processes.Count -eq 0) {
        Write-Host "  No active 1C TESTMANAGER/TESTCLIENT/StartFeaturePlayer processes found."
        return
    }

    foreach ($processInfo in $processes) {
        $scope = if (Test-OneCProcessBelongsToState -ProcessInfo $processInfo -State $State -TestPort $TestPort) { "own" } else { "foreign" }
        Write-Host "  [$scope] $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
    }
}

function Write-VanessaTestStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
    $lastAt = Get-StateValue -State $State -Name "lastVanessaTestAt" -Default ""
    $baselinePath = Get-StateValue -State $State -Name "eventLogBaselinePath" -Default ""
    if ($port -le 0 -and -not $lastAt -and -not $baselinePath) {
        return
    }

    if ($port -gt 0) {
        Write-Host "${Indent}Vanessa TestClient port: $port"
    }
    if ($lastAt) {
        Write-Host "${Indent}Last Vanessa verify run: $lastAt"
    }
    $reportPath = Get-StateValue -State $State -Name "lastVanessaReportPath" -Default ""
    if ($reportPath) {
        Write-Host "${Indent}Last Vanessa report: $reportPath"
    }
    $logPath = Get-StateValue -State $State -Name "lastVanessaLogPath" -Default ""
    if ($logPath) {
        Write-Host "${Indent}Last Vanessa 1C log: $logPath"
    }
    if ($baselinePath) {
        Write-Host "${Indent}Event log baseline: $baselinePath"
        Write-Host "${Indent}Event log baseline reader/cache: $(Get-StateValue -State $State -Name 'eventLogBaselineReader' -Default '<unknown>') / $(Get-StateValue -State $State -Name 'eventLogBaselineCacheStatus' -Default '<unknown>')"
        Write-Host "${Indent}Event log baseline errors/signatures: $(Get-StateValue -State $State -Name 'eventLogBaselineErrorCount' -Default 0) / $(Get-StateValue -State $State -Name 'eventLogBaselineSignatureCount' -Default 0)"
        Write-Host "${Indent}Event log baseline duration: $(Get-StateValue -State $State -Name 'eventLogBaselineDurationMs' -Default 0) ms"
    }
    $newErrorCount = Get-StateValue -State $State -Name "lastVanessaEventLogNewErrorCount" -Default ""
    if ($newErrorCount -ne "") {
        Write-Host "${Indent}Last event log new errors: $newErrorCount"
    }
    $eventLogReport = Get-StateValue -State $State -Name "lastVanessaEventLogNewErrorsPath" -Default ""
    if ($eventLogReport) {
        Write-Host "${Indent}Last event log new-error report: $eventLogReport"
    }
    $postProcessMs = Get-StateValue -State $State -Name "lastVanessaPostProcessDurationMs" -Default ""
    if ($postProcessMs -ne "") {
        Write-Host "${Indent}Last Vanessa runner/cleanup/event-log/post-process ms: $(Get-StateValue -State $State -Name 'lastVanessaRunnerDurationMs' -Default 0) / $(Get-StateValue -State $State -Name 'lastVanessaCleanupDurationMs' -Default 0) / $(Get-StateValue -State $State -Name 'lastVanessaEventLogDurationMs' -Default 0) / $postProcessMs"
        Write-Host "${Indent}Last event log scan mode/bytes: $(Get-StateValue -State $State -Name 'lastVanessaEventLogScanMode' -Default '<unknown>') / $(Get-StateValue -State $State -Name 'lastVanessaEventLogScannedBytes' -Default 0)"
    }
}

function Get-VanessaMcpInstallRoot {
    $value = Get-EnvValue -Name "VANESSA_MCP_INSTALL_ROOT" -Default ".agent-1c/tools/vanessa-mcp"
    return (Resolve-ProjectPath ([string]$value))
}

function Get-VanessaMcpPortRange {
    $range = [string](Get-EnvValue -Name "VANESSA_MCP_PORT_RANGE" -Default "")
    if ($range -match '^\s*(\d+)\s*(?:\.\.|-|:)\s*(\d+)\s*$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
    } else {
        $start = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_MCP_PORT_START" -Default 9874) -Default 9874
        $end = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_MCP_PORT_END" -Default 9973) -Default 9973
    }

    if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
        throw "Invalid Vanessa UI MCP port range: $start..$end"
    }

    return [pscustomobject]@{
        start = $start
        end = $end
    }
}

function Get-VanessaMcpUrl {
    param([int]$Port)
    return "http://127.0.0.1:$Port/mcp"
}

function Test-TcpPortAvailable {
    param([int]$Port)

    $listener = $null
    try {
        $address = [System.Net.IPAddress]::Parse("127.0.0.1")
        $listener = New-Object System.Net.Sockets.TcpListener($address, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Test-TcpPortOpen {
    param(
        [int]$Port,
        [int]$TimeoutMilliseconds = 300
    )

    $client = $null
    $async = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $async) {
            $async.AsyncWaitHandle.Close()
        }
        if ($null -ne $client) {
            $client.Close()
        }
    }
}

function Get-ProcessByIdOrNull {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    try {
        return Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-VanessaMcpRuntimeInfo {
    param([object]$State)

    $pidValue = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPid" -Default 0)
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPort" -Default 0)
    $savedStatus = [string](Get-StateValue -State $State -Name "vanessaMcpStatus" -Default "")
    $process = Get-ProcessByIdOrNull -ProcessId $pidValue
    $portOpen = $false
    if ($port -gt 0) {
        $portOpen = Test-TcpPortOpen -Port $port
    }

    $status = "stopped"
    if ($null -ne $process -and $portOpen) {
        $status = "running"
    } elseif ($null -ne $process) {
        $status = "process-running-port-closed"
    } elseif ($portOpen) {
        $status = "port-open-unknown-process"
    } elseif (@("failed", "skipped", "disabled") -contains $savedStatus) {
        $status = $savedStatus
    }

    return [pscustomobject]@{
        status = $status
        processAlive = ($null -ne $process)
        pid = $pidValue
        port = $port
        url = $(if ($port -gt 0) { Get-VanessaMcpUrl -Port $port } else { "" })
        portOpen = $portOpen
    }
}

function Get-VanessaMcpReservedPorts {
    param([object]$CurrentState)

    $currentSafeName = Get-StateValue -State $CurrentState -Name "safeDevBranchName" -Default ""
    $ports = @{}
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            $safeName = Get-StateValue -State $state -Name "safeDevBranchName" -Default ""
            if ($currentSafeName -and $safeName -eq $currentSafeName) {
                continue
            }

            $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $state -Name "vanessaMcpPort" -Default 0)
            if ($port -gt 0) {
                $ports[$port] = $true
            }
        } catch {
        }
    }

    return $ports
}

function Resolve-VanessaMcpPort {
    param([object]$State)

    $reserved = Get-VanessaMcpReservedPorts -CurrentState $State
    $savedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPort" -Default 0)
    $range = Get-VanessaMcpPortRange
    return (Resolve-ItlManagedPort `
        -Family "vanessa-mcp" `
        -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $State) `
        -Start $range.start `
        -End $range.end `
        -PreferredPort $savedPort `
        -ExplicitPort $VanessaMcpPort `
        -ReservedPorts $reserved `
        -State $State `
        -Subject "Vanessa UI MCP port")
}

function Get-OwnVanessaTestProcesses {
    param([object]$State)

    return @(Get-OneCProcessInfo | Where-Object {
        (Test-OneCVanessaTestProcess -ProcessInfo $_) -and
        (Test-OneCProcessBelongsToState -ProcessInfo $_ -State $State)
    })
}

function Stop-OwnVanessaTestProcessesAndAssert {
    param([object]$State)

    $ownProcesses = @(Get-OwnVanessaTestProcesses -State $State)
    foreach ($processInfo in $ownProcesses) {
        Write-Host "Stopping own Vanessa TESTMANAGER/TESTCLIENT process: $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
        Stop-Process -Id $processInfo.processId -Force -ErrorAction SilentlyContinue
    }

    if ($ownProcesses.Count -gt 0) {
        Start-Sleep -Milliseconds 300
    }
    $remaining = @(Get-OwnVanessaTestProcesses -State $State)
    if ($remaining.Count -gt 0) {
        $details = ($remaining | ForEach-Object { Format-OneCProcessInfo -ProcessInfo $_ }) -join [Environment]::NewLine
        throw "Branch-local Vanessa TESTMANAGER/TESTCLIENT cleanup failed:$([Environment]::NewLine)$details"
    }

    Write-Host "Branch-local Vanessa test process cleanup passed. Stopped: $($ownProcesses.Count)"
}

function Stop-DevBranchTestClients {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "stop-dev-branch-test-clients"
    Stop-OwnVanessaTestProcessesAndAssert -State $state
}

function Read-CurrentDevBranchStateForVanessaMcp {
    param([string]$Operation)

    $currentBranch = Get-CurrentBranch
    if ($currentBranch -notlike "itldev/*") {
        throw "$Operation must be run from an active itldev/* development branch worktree. Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    }

    $state = Read-DevBranchState -Name ""
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation $Operation
    return $state
}

function Get-GitHubReleaseAssetInfo {
    param(
        [string]$Repository,
        [string]$AssetNameLike,
        [string]$OverrideEnvName,
        [string]$DefaultFileName,
        [int]$RetryCount = 3
    )

    $override = Get-EnvValue -Name $OverrideEnvName -Default ""
    if ($override) {
        $localOrUrl = [string]$override
        $fileName = Split-Path -Leaf (ConvertFrom-FileUri -Value $localOrUrl)
        if (-not $fileName) {
            $fileName = $DefaultFileName
        }
        return [pscustomobject]@{
            url = $localOrUrl
            name = $fileName
            version = ""
            source = $OverrideEnvName
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $release = Invoke-GitHubApiRestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest"
            $asset = @($release.assets | Where-Object { $_.name -like $AssetNameLike } | Select-Object -First 1)
            if ($asset.Count -eq 0) {
                throw "GitHub release $Repository/$($release.tag_name) does not contain asset matching '$AssetNameLike'."
            }

            return [pscustomobject]@{
                url = [string]$asset[0].browser_download_url
                name = [string]$asset[0].name
                version = [string]$release.tag_name
                source = "GitHub releases $Repository"
            }
        } catch {
            $lastError = $_.Exception.Message
            $failure = Get-GitHubApiFailureInfo -ErrorRecord $_
            if ($failure.rateLimited) {
                $fallback = Get-GitHubReleaseRateLimitFallbackInfo `
                    -Repository $Repository `
                    -AssetNameLike $AssetNameLike `
                    -DefaultFileName $DefaultFileName
                if ($fallback) {
                    Write-Warning "GitHub API rate limit reached; using the dependency-lock fallback for $Repository/$AssetNameLike."
                    return $fallback
                }
                throw (Get-GitHubRateLimitRecoveryMessage -Operation "resolving GitHub release asset $Repository/$AssetNameLike" -FailureInfo $failure)
            }
            if ($attempt -lt $RetryCount) {
                Write-Warning "Could not resolve GitHub release asset $Repository/$AssetNameLike (attempt $attempt of $RetryCount): $lastError"
                Start-Sleep -Seconds $attempt
            }
        }
    }

    throw "Could not resolve GitHub release asset $Repository/$AssetNameLike after $RetryCount attempts. $lastError"
}

function Get-VanessaMcpArtifactDefinitions {
    return @(
        [pscustomobject]@{
            lockKey = "clientMcp"
            repository = "1c-neurofish/onec-client-mcp-devkit"
            assetNameLike = "client_mcp.cfe"
            overrideEnvName = "VANESSA_MCP_CLIENT_CFE_URL"
            defaultFileName = "client_mcp.cfe"
            pathEnvName = "VANESSA_MCP_CLIENT_CFE_PATH"
            versionEnvName = "VANESSA_MCP_CLIENT_CFE_VERSION"
            sha256EnvName = "VANESSA_MCP_CLIENT_CFE_SHA256"
        },
        [pscustomobject]@{
            lockKey = "vaExtension"
            repository = "Pr-Mex/vanessa-automation"
            assetNameLike = "VAExtension*.cfe"
            overrideEnvName = "VANESSA_MCP_VA_EXTENSION_CFE_URL"
            defaultFileName = "VAExtension.cfe"
            pathEnvName = "VANESSA_MCP_VA_EXTENSION_CFE_PATH"
            versionEnvName = "VANESSA_MCP_VA_EXTENSION_CFE_VERSION"
            sha256EnvName = "VANESSA_MCP_VA_EXTENSION_CFE_SHA256"
        }
    )
}

function Resolve-VanessaMcpArtifactPath {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    $path = [Environment]::ExpandEnvironmentVariables((ConvertFrom-FileUri -Value $Value).Trim())
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Resolve-ProjectPath $path
    }
    return (Resolve-Agent1cFullPath -Path $path)
}

function Get-VanessaMcpArtifactLockEntry {
    param([object]$Definition)

    $lock = Get-DependencyLockEntry -Name "vanessaMcp"
    return Get-ConfigValueFromObject -Object $lock -Path ([string]$Definition.lockKey) -Default $null
}

function Find-VanessaMcpCachedArtifactPath {
    param([object]$Definition)

    $configured = Resolve-VanessaMcpArtifactPath -Value (Get-EnvValue -Name ([string]$Definition.pathEnvName) -Default "")
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $configured
    }

    $lockEntry = Get-VanessaMcpArtifactLockEntry -Definition $Definition
    $assetName = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "assetName" -Default "")
    $installRoot = Get-VanessaMcpInstallRoot
    if ($assetName) {
        $candidate = Join-Path $installRoot $assetName
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Resolve-Agent1cFullPath -Path $candidate)
        }
    }

    $candidates = @(Get-ChildItem -LiteralPath $installRoot -File -Filter ([string]$Definition.assetNameLike) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }

    return ""
}

function Get-VanessaMcpCachedArtifactInfo {
    param(
        [object]$Definition,
        [string]$Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    $lockEntry = Get-VanessaMcpArtifactLockEntry -Definition $Definition
    $expectedSha256 = [string](Get-EnvValue -Name ([string]$Definition.sha256EnvName) -Default "")
    if (-not $expectedSha256) {
        $expectedSha256 = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "sha256" -Default "")
    }
    $version = [string](Get-EnvValue -Name ([string]$Definition.versionEnvName) -Default "")
    if (-not $version) {
        $version = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "version" -Default "")
    }
    $source = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "source" -Default "existing cached artifact")
    $url = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "url" -Default "")
    $assetName = [string](Get-ConfigValueFromObject -Object $lockEntry -Path "assetName" -Default (Split-Path -Leaf $Path))
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()

    if ((Get-DependencyMode) -eq "locked") {
        if (-not $version -or -not $assetName -or -not $url -or -not $expectedSha256) {
            throw "Dependency mode is locked, but vanessaMcp.$($Definition.lockKey).version, assetName, url, and sha256 must all be set in .agent-1c/dependency-lock.json."
        }
    }
    if ($expectedSha256 -and $hash -ne $expectedSha256.ToLowerInvariant()) {
        throw "Vanessa UI MCP cached artifact SHA256 mismatch for $($Definition.lockKey). Expected $expectedSha256, got $hash. Artifact: $Path"
    }

    return [pscustomobject]@{
        key = [string]$Definition.lockKey
        path = (Resolve-Agent1cFullPath -Path $Path)
        assetName = $assetName
        version = $version
        url = $url
        sha256 = $hash
        source = $source
    }
}

function Get-VanessaMcpReleaseAssetInfo {
    param([object]$Definition)

    $mode = Get-DependencyMode
    $locked = Get-VanessaMcpArtifactLockEntry -Definition $Definition
    if ($mode -eq "locked") {
        $version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
        $assetName = [string](Get-ConfigValueFromObject -Object $locked -Path "assetName" -Default "")
        $url = [string](Get-ConfigValueFromObject -Object $locked -Path "url" -Default "")
        $sha256 = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
        if (-not $version -or -not $assetName -or -not $url -or -not $sha256) {
            throw "Dependency mode is locked, but vanessaMcp.$($Definition.lockKey).version, assetName, url, and sha256 must all be set in .agent-1c/dependency-lock.json."
        }
        $compatible = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
        $requiredVersion = $(if ([string]$Definition.lockKey -eq "clientMcp") { [string]$compatible.backendVersions.clientMcp } else { [string]$compatible.backendVersions.vaExtension })
        if ($version -ne $requiredVersion) {
            throw "ITL_ONDEMAND_BACKEND_UNSUPPORTED: locked Vanessa UI $($Definition.lockKey) version '$version' has no packaged compatibility catalog; required '$requiredVersion'."
        }
        return [pscustomobject]@{
            url = $url
            name = $assetName
            version = $version
            expectedSha256 = $sha256
            source = "dependency-lock"
        }
    }

    $compatible = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
    $requiredVersion = if ([string]$Definition.lockKey -eq "clientMcp") {
        [string]$compatible.backendVersions.clientMcp
    } else {
        [string]$compatible.backendVersions.vaExtension
    }
    $version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
    $assetName = [string](Get-ConfigValueFromObject -Object $locked -Path "assetName" -Default "")
    $url = [string](Get-ConfigValueFromObject -Object $locked -Path "url" -Default "")
    $sha256 = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
    if ($version -ne $requiredVersion -or -not $assetName -or -not $url -or -not $sha256) {
        throw "ITL_ONDEMAND_BACKEND_UNSUPPORTED: fresh Vanessa UI requires compatibility-manifest version '$requiredVersion' and a complete vanessaMcp.$($Definition.lockKey) lock entry. Actual version: '$version'."
    }
    return [pscustomobject]@{
        url = $url
        name = $assetName
        version = $version
        expectedSha256 = $sha256
        source = "compatibility-manifest"
    }
}

function Save-VanessaMcpArtifact {
    param(
        [object]$Definition,
        [object]$AssetInfo
    )

    $installRoot = Get-VanessaMcpInstallRoot
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $targetPath = Join-Path $installRoot ([string]$AssetInfo.name)
    $temporaryPath = "$targetPath.partial"
    $source = [string]$AssetInfo.url

    Write-Host "Vanessa UI MCP artifact source: $source"
    $localSource = ConvertFrom-FileUri -Value $source
    if (Test-Path -LiteralPath $localSource -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $localSource -Destination $targetPath -Force
    } else {
        $lastError = ""
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri $source -UseBasicParsing -OutFile $temporaryPath
                Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
                $lastError = ""
                break
            } catch {
                $lastError = $_.Exception.Message
                if ($attempt -lt 3) {
                    Write-Warning "Could not download Vanessa UI MCP artifact (attempt $attempt of 3): $lastError"
                    Start-Sleep -Seconds $attempt
                }
            }
        }
        if ($lastError) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            throw "Could not download Vanessa UI MCP artifact from $source after 3 attempts. $lastError"
        }
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
    Write-Host "Vanessa UI MCP artifact SHA256: $hash"
    $expected = [string](Get-ConfigValueFromObject -Object $AssetInfo -Path "expectedSha256" -Default "")
    if ($expected -and $hash -ne $expected.ToLowerInvariant()) {
        throw "Vanessa UI MCP artifact SHA256 mismatch for $($Definition.lockKey). Expected $expected, got $hash."
    }

    return [pscustomobject]@{
        key = [string]$Definition.lockKey
        path = $targetPath
        assetName = [string]$AssetInfo.name
        version = [string]$AssetInfo.version
        url = $source
        sha256 = $hash
        source = [string]$AssetInfo.source
    }
}

function Save-VanessaMcpArtifactSettingsToDotEnv {
    param([object[]]$Artifacts)

    $definitions = @{}
    foreach ($definition in Get-VanessaMcpArtifactDefinitions) {
        $definitions[[string]$definition.lockKey] = $definition
    }

    $values = @{}
    foreach ($artifact in @($Artifacts)) {
        $definition = $definitions[[string]$artifact.key]
        if ($null -eq $definition) {
            continue
        }
        $values[[string]$definition.pathEnvName] = [string]$artifact.path
        $values[[string]$definition.versionEnvName] = [string]$artifact.version
        $values[[string]$definition.sha256EnvName] = [string]$artifact.sha256
    }
    if ($values.Count -gt 0) {
        Set-DotEnvValues -Values $values
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    }
}

function Update-VanessaMcpArtifactLockEntry {
    param([object]$Artifact)

    if (Test-DependencyLockRateLimitFallbackSource -Source ([string]$Artifact.source)) {
        return
    }

    $values = @{}
    $values[[string]$Artifact.key] = [ordered]@{
        version = [string]$Artifact.version
        assetName = [string]$Artifact.assetName
        url = [string]$Artifact.url
        sha256 = [string]$Artifact.sha256
        source = [string]$Artifact.source
        updatedAt = (Get-Date).ToString("o")
    }
    Update-DependencyLockEntry -Name "vanessaMcp" -Values $values
}

function Install-VanessaMcpArtifact {
    param(
        [object]$Definition,
        [switch]$ForceDownload
    )

    $cachedPath = Find-VanessaMcpCachedArtifactPath -Definition $Definition
    if ($cachedPath -and -not $ForceDownload) {
        return Get-VanessaMcpCachedArtifactInfo -Definition $Definition -Path $cachedPath
    }

    try {
        $asset = Get-VanessaMcpReleaseAssetInfo -Definition $Definition
        $artifact = Save-VanessaMcpArtifact -Definition $Definition -AssetInfo $asset
        Update-VanessaMcpArtifactLockEntry -Artifact $artifact
        return $artifact
    } catch {
        $message = $_.Exception.Message
        if ($cachedPath) {
            Write-Warning "Could not refresh Vanessa UI MCP artifact $($Definition.lockKey). Reusing verified cached artifact. $message"
            return Get-VanessaMcpCachedArtifactInfo -Definition $Definition -Path $cachedPath
        }
        throw
    }
}

function Install-VanessaMcpArtifacts {
    param([switch]$ForceDownload)

    $artifacts = @()
    foreach ($definition in Get-VanessaMcpArtifactDefinitions) {
        $artifacts += Install-VanessaMcpArtifact -Definition $definition -ForceDownload:$ForceDownload
    }
    Save-VanessaMcpArtifactSettingsToDotEnv -Artifacts $artifacts
    return @($artifacts)
}

function Update-VanessaMcpArtifacts {
    Write-Section "Update Vanessa UI MCP artifacts"

    $artifacts = Install-VanessaMcpArtifacts -ForceDownload
    foreach ($artifact in $artifacts) {
        Write-Host "Vanessa UI MCP $($artifact.key) CFE: $($artifact.path)"
    }
}

function Save-VanessaMcpSettingsToDotEnv {
    param(
        [int]$Port,
        [string]$Url
    )

    Set-DotEnvValues -Values @{
        VANESSA_MCP_PORT = $(if ($Port -gt 0) { [string]$Port } else { "" })
        VANESSA_MCP_URL = $Url
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Install-VanessaMcpExtensionCfe {
    param(
        [object]$State,
        [string]$CfePath,
        [string]$ExtensionName
    )

    if (-not (Test-Path -LiteralPath $CfePath -PathType Leaf)) {
        throw "Vanessa UI MCP CFE was not found: $CfePath"
    }

    Write-Host "Installing 1C extension '$ExtensionName' from: $CfePath"
    Invoke-Designer `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -DesignerArgs @("/LoadCfg", $CfePath, "-Extension", $ExtensionName, "/UpdateDBCfg") | Out-Null

    return $script:LastLogPath
}

function Install-VanessaMcp {
    Write-Section "Install Vanessa UI MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "install-vanessa-mcp"
    $runtime = Get-VanessaMcpRuntimeInfo -State $state
    if ($runtime.processAlive) {
        throw "Stop Vanessa UI MCP for this branch before reinstalling MCP extensions. PID: $($runtime.pid)"
    }

    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        Write-Host "Vanessa Automation EPF is missing; installing it first."
        Install-VanessaAutomation
    }

    $artifactsByKey = @{}
    foreach ($artifact in Install-VanessaMcpArtifacts) {
        $artifactsByKey[[string]$artifact.key] = $artifact
    }
    $clientArtifact = $artifactsByKey["clientMcp"]
    $vaExtensionArtifact = $artifactsByKey["vaExtension"]

    $clientLog = Install-VanessaMcpExtensionCfe -State $state -CfePath $clientArtifact.path -ExtensionName "client_mcp"
    $vaExtensionLog = Install-VanessaMcpExtensionCfe -State $state -CfePath $vaExtensionArtifact.path -ExtensionName "VAExtension"

    Update-DevBranchState -State $state -Updates @{
        vanessaMcpClientMcpCfePath = $clientArtifact.path
        vanessaMcpClientMcpVersion = $clientArtifact.version
        vanessaMcpClientMcpSha256 = $clientArtifact.sha256
        vanessaMcpVaExtensionCfePath = $vaExtensionArtifact.path
        vanessaMcpVaExtensionVersion = $vaExtensionArtifact.version
        vanessaMcpVaExtensionSha256 = $vaExtensionArtifact.sha256
        vanessaMcpInstalledAt = (Get-Date).ToString("o")
        vanessaMcpClientMcpInstallLogPath = $clientLog
        vanessaMcpVaExtensionInstallLogPath = $vaExtensionLog
    }

    Write-Host "Vanessa UI MCP extensions installed in development branch infobase."
    Write-Host "client_mcp CFE: $($clientArtifact.path)"
    Write-Host "VAExtension CFE: $($vaExtensionArtifact.path)"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Ensure-VanessaMcpInstalled {
    param([object]$State)

    $clientPath = Get-StateValue -State $State -Name "vanessaMcpClientMcpCfePath" -Default ""
    $vaExtensionPath = Get-StateValue -State $State -Name "vanessaMcpVaExtensionCfePath" -Default ""
    if ($clientPath -and $vaExtensionPath -and
        (Test-Path -LiteralPath $clientPath -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath $vaExtensionPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $State
    }

    Write-Host "Vanessa UI MCP dependencies are not installed for this branch; installing them now."
    Install-VanessaMcp
    return Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
}

function Wait-VanessaMcpPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPortOpen -Port $Port -TimeoutMilliseconds 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Write-VanessaMcpClientSnippets {
    param([object]$State)

    $safeName = Get-StateValue -State $State -Name "safeDevBranchName" -Default (ConvertTo-SafeName (Get-StateValue -State $State -Name "devBranchName" -Default "dev-branch"))
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPort" -Default 0)
    $url = Get-StateValue -State $State -Name "vanessaMcpUrl" -Default $(if ($port -gt 0) { Get-VanessaMcpUrl -Port $port } else { "" })
    if (-not $url) {
        return
    }

    $serverName = "VanessaUi-$safeName"
    Write-Host "MCP server name: $serverName"
    Write-Host "MCP streamable-http URL: $url"
    Write-Host "MCP client snippets:"
    Write-Host @"
YAML:
mcpServers:
  - name: $serverName
    type: streamable-http
    url: $url

JSON:
{
  "mcpServers": {
    "$serverName": {
      "type": "streamable-http",
      "url": "$url"
    }
  }
}
"@
}

function Write-VanessaMcpKiloConfig {
    param([object]$State)

    $safeName = Get-StateValue -State $State -Name "safeDevBranchName" -Default (ConvertTo-SafeName (Get-StateValue -State $State -Name "devBranchName" -Default "dev-branch"))
    $devBranchName = Get-StateValue -State $State -Name "devBranchName" -Default $safeName
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPort" -Default 0)
    $url = Get-StateValue -State $State -Name "vanessaMcpUrl" -Default $(if ($port -gt 0) { Get-VanessaMcpUrl -Port $port } else { "" })
    if (-not $url) {
        return
    }

    $path = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        $current = Read-Utf8Text -Path $path | ConvertFrom-Json
        $config = ConvertTo-Vibecoding1cMcpHashtable -Object $current
    }

    $mcp = [ordered]@{}
    if ($config.Contains("mcp")) {
        $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $config["mcp"]
    }

    foreach ($key in @($mcp.Keys)) {
        $entry = $mcp[$key]
        $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "managedBy" -Default "")
        if (@("vanessa-mcp", "vanessa-ui-mcp") -contains $managedBy) {
            $mcp.Remove($key)
        }
    }

    $serverName = "VanessaUi-$safeName"
    $mcp[$serverName] = [ordered]@{
        type = "remote"
        url = $url
        enabled = $true
        timeout = 120000
        managedBy = "vanessa-ui-mcp"
        family = "vanessa-ui"
        scope = "branch"
        devBranchName = $devBranchName
        safeDevBranchName = $safeName
    }

    $config["mcp"] = $mcp
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
    Write-Host "Kilo Vanessa UI MCP config: $path"
    Write-Host "If Kilo Code does not show this MCP server immediately, reload or restart Kilo Code so it rereads .kilo/kilo.json."
}

function Write-VanessaMcpClientConfig {
    param([object]$State)

    if (Get-Command -Name Write-ItlBranchMcpClientConfig -ErrorAction SilentlyContinue) {
        Write-ItlBranchMcpClientConfig -State $State
        return
    }

    Write-VanessaMcpKiloConfig -State $State
}

function Write-VanessaMcpStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $runtime = Get-VanessaMcpRuntimeInfo -State $State
    $installedAt = Get-StateValue -State $State -Name "vanessaMcpInstalledAt" -Default ""
    $status = Get-StateValue -State $State -Name "vanessaMcpStatus" -Default ""
    if (-not $installedAt -and -not $status -and $runtime.port -le 0) {
        Write-Host "${Indent}Vanessa UI MCP: stopped (on-demand)"
        return
    }

    Write-Host "${Indent}Vanessa UI MCP: $($runtime.status)"
    if ($runtime.port -gt 0) {
        Write-Host "${Indent}Vanessa UI MCP port: $($runtime.port)"
        Write-Host "${Indent}Vanessa UI MCP URL: $($runtime.url)"
    }
    if ($runtime.pid -gt 0) {
        Write-Host "${Indent}Vanessa UI MCP PID: $($runtime.pid)"
    }
    $logPath = Get-StateValue -State $State -Name "vanessaMcpLogPath" -Default ""
    if ($logPath) {
        Write-Host "${Indent}Vanessa UI MCP log: $logPath"
    }
    if ($installedAt) {
        Write-Host "${Indent}Vanessa UI MCP installed: $installedAt"
    }
    $errorMessage = Get-StateValue -State $State -Name "vanessaMcpError" -Default ""
    if ($errorMessage) {
        Write-Host "${Indent}Vanessa UI MCP error: $errorMessage"
    }
}

function Stop-VanessaMcpForState {
    param(
        [object]$State,
        [switch]$Quiet
    )

    $runtime = Get-VanessaMcpRuntimeInfo -State $State
    $updates = @{
        vanessaMcpPid = ""
        vanessaMcpStatus = "stopped"
        vanessaMcpStoppedAt = (Get-Date).ToString("o")
        vanessaMcpUpdatedAt = (Get-Date).ToString("o")
    }

    if ($runtime.processAlive) {
        if (-not $Quiet) {
            Write-Host "Stopping Vanessa UI MCP process: PID $($runtime.pid)"
        }
        Stop-Process -Id $runtime.pid -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $State) -Status "stopped"
        Update-DevBranchState -State $State -Updates $updates
        $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
        Write-VanessaMcpClientConfig -State $state
        return $true
    }

    Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $State) -Status "stopped"
    Update-DevBranchState -State $State -Updates $updates
    $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    Write-VanessaMcpClientConfig -State $state
    if (-not $Quiet) {
        Write-Host "Vanessa UI MCP is not running for this branch."
    }
    return $false
}

function Start-VanessaMcp {
    Write-Section "Start Vanessa UI MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "start-vanessa-mcp"
    $state = Ensure-DevBranchEnterpriseNormalized -State $state -Reason "legacy-preflight"
    $runtime = Get-VanessaMcpRuntimeInfo -State $state
    if ($runtime.processAlive) {
        Save-VanessaMcpSettingsToDotEnv -Port $runtime.port -Url $runtime.url
        Update-DevBranchState -State $state -Updates @{
            vanessaMcpStatus = "running"
            vanessaMcpError = ""
            vanessaMcpUpdatedAt = (Get-Date).ToString("o")
        }
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        Write-VanessaMcpClientConfig -State $state
        Write-Host "Vanessa UI MCP process is already running for this branch."
        Write-VanessaMcpStatusLines -State $state
        Write-VanessaMcpClientSnippets -State $state
        return
    }

    try {
        $state = Ensure-VanessaMcpInstalled -State $state
    } catch {
        $message = $_.Exception.Message
        Update-DevBranchState -State $state -Updates @{
            vanessaMcpStatus = "failed"
            vanessaMcpError = $message
            vanessaMcpUpdatedAt = (Get-Date).ToString("o")
        }
        throw $message
    }
    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        throw "Vanessa Automation verification runtime is not installed. Run install-vanessa-automation first."
    }

    $port = Resolve-VanessaMcpPort -State $state
    $url = Get-VanessaMcpUrl -Port $port
    Save-VanessaMcpSettingsToDotEnv -Port $port -Url $url
    Update-DevBranchState -State $state -Updates @{
        vanessaMcpPort = $port
        vanessaMcpUrl = $url
        vanessaMcpStatus = "starting"
        vanessaMcpError = ""
        vanessaMcpUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    $command = "runMcp;mcpPort=$port"
    $result = Start-EnterpriseBackground `
        -InfoBasePath $state.devBranchInfoBasePath `
        -InfoBaseKind $state.infoBaseKind `
        -UseTestManager `
        -EnterpriseArgs @("/Execute", $vanessa.epfPath, "/C$command")

    Update-DevBranchState -State $state -Updates @{
        vanessaMcpPort = $port
        vanessaMcpUrl = $url
        vanessaMcpPid = $result.process.Id
        vanessaMcpStartedAt = (Get-Date).ToString("o")
        vanessaMcpLogPath = $result.logPath
        vanessaMcpStatus = "starting"
        vanessaMcpError = ""
        vanessaMcpUpdatedAt = (Get-Date).ToString("o")
    }
    Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $state) -Status "running" -ProcessId $result.process.Id
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    if (-not (Wait-VanessaMcpPort -Port $port -TimeoutSeconds 30)) {
        $message = "Vanessa UI MCP process was started, but port $port did not become reachable within 30 seconds. PID: $($result.process.Id). Log: $($result.logPath)"
        Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $state) -Status "failed" -ProcessId $result.process.Id
        Update-DevBranchState -State $state -Updates @{
            vanessaMcpStatus = "failed"
            vanessaMcpError = $message
            vanessaMcpUpdatedAt = (Get-Date).ToString("o")
        }
        throw $message
    }

    Update-DevBranchState -State $state -Updates @{
        vanessaMcpStatus = "running"
        vanessaMcpError = ""
        vanessaMcpUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    Write-Host "Vanessa UI MCP started."
    Write-VanessaMcpClientConfig -State $state
    Write-VanessaMcpStatusLines -State $state
    Write-VanessaMcpClientSnippets -State $state
}

function Stop-VanessaMcp {
    Write-Section "Stop Vanessa UI MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "stop-vanessa-mcp"
    Stop-VanessaMcpForState -State $state | Out-Null
}

function Show-VanessaMcpStatus {
    Write-Section "Vanessa UI MCP status"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "vanessa-mcp-status"
    Write-VanessaMcpStatusLines -State $state
    Write-VanessaMcpClientSnippets -State $state
}
