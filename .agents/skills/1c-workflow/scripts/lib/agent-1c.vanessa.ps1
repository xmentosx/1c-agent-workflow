function Get-VanessaInstallRoot {
    $legacyRelative = ".agent-1c/tools/vanessa-automation"
    $currentRelative = ".agent-1c/tools/va"
    $value = Get-Setting -EnvName "VANESSA_AUTOMATION_ROOT" -ConfigName "vanessaAutomation.installRoot" -Default $currentRelative
    $resolved = Resolve-ProjectPath ([string]$value)
    if ([string]::Equals($resolved, (Resolve-ProjectPath $legacyRelative), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Resolve-ProjectPath $currentRelative)
    }
    return $resolved
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
        $legacyRoot = Resolve-ProjectPath ".agent-1c/tools/vanessa-automation"
        $resolvedPath = Resolve-Agent1cFullPath -Path $path
        $isLegacyManagedPath = $resolvedPath.StartsWith(($legacyRoot.TrimEnd("\", "/") + "\"), [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isLegacyManagedPath -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            return $resolvedPath
        }
    }

    return Find-VanessaAutomationEpf -Root (Get-VanessaInstallRoot)
}

function Get-VanessaAutomationState {
    $epfPath = Get-VanessaAutomationEpfPath
    $entry = Get-DependencyLockEntry -Name "vanessaAutomation"
    $version = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityVersion" -Default (Get-ConfigValueFromObject -Object $entry -Path "version" -Default ""))
    $downstreamRevision = [string](Get-ConfigValueFromObject -Object $entry -Path "downstreamRevision" -Default "")
    $archiveSha256 = ([string](Get-ConfigValueFromObject -Object $entry -Path "sha256" -Default "")).ToLowerInvariant()
    $expectedEpfSha256 = ([string](Get-ConfigValueFromObject -Object $entry -Path "epfSha256" -Default "")).ToLowerInvariant()
    if ($epfPath -and (Test-Path -LiteralPath $epfPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $epfSha256 = (Get-FileHash -LiteralPath $epfPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedEpfSha256 -and $epfSha256 -cne $expectedEpfSha256) {
            return [pscustomobject]@{
                ready = $false
                epfPath = $epfPath
                version = $version
                downstreamRevision = $downstreamRevision
                archiveSha256 = $archiveSha256
                epfSha256 = $epfSha256
                expectedEpfSha256 = $expectedEpfSha256
                message = "Vanessa Automation EPF SHA256 does not match the workflow pin."
            }
        }
        return [pscustomobject]@{
            ready = $true
            epfPath = $epfPath
            version = $version
            downstreamRevision = $downstreamRevision
            archiveSha256 = $archiveSha256
            epfSha256 = $epfSha256
            expectedEpfSha256 = $expectedEpfSha256
            message = "Vanessa Automation EPF found."
        }
    }

    return [pscustomobject]@{
        ready = $false
        epfPath = ""
        version = $version
        downstreamRevision = $downstreamRevision
        archiveSha256 = $archiveSha256
        epfSha256 = ""
        expectedEpfSha256 = $expectedEpfSha256
        message = "Vanessa Automation EPF was not found. Run install-vanessa-automation."
    }
}

function Get-VanessaAutomationPinnedEntry {
    $entry = Get-DependencyLockEntry -Name "vanessaAutomation"
    if ($null -eq $entry) {
        throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: vanessaAutomation is missing from .agent-1c/dependency-lock.json."
    }

    foreach ($field in @("compatibilityVersion", "downstreamRevision", "assetName", "url", "sha256", "epfSha256", "manifestSha256", "patchSha256", "upstreamCommit")) {
        if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValueFromObject -Object $entry -Path $field -Default ""))) {
            throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: vanessaAutomation.$field is missing from .agent-1c/dependency-lock.json."
        }
    }
    foreach ($field in @("sha256", "epfSha256", "manifestSha256", "patchSha256")) {
        if ([string](Get-ConfigValueFromObject -Object $entry -Path $field -Default "") -notmatch '^[a-fA-F0-9]{64}$') {
            throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: vanessaAutomation.$field is not a SHA-256 value."
        }
    }
    if ([string](Get-ConfigValueFromObject -Object $entry -Path "upstreamCommit" -Default "") -notmatch '^[a-fA-F0-9]{40}$') {
        throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: vanessaAutomation.upstreamCommit is not a full Git commit."
    }
    $version = [string](Get-ConfigValueFromObject -Object $entry -Path "version" -Default "")
    $compatibilityVersion = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityVersion" -Default "")
    if ($version -and $version -cne $compatibilityVersion) {
        throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: version '$version' differs from compatibilityVersion '$compatibilityVersion'."
    }
    return $entry
}

function Get-VanessaAutomationDownloadInfo {
    $entry = Get-VanessaAutomationPinnedEntry
    $sourceBuild = Get-EnvValue -Name "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE"
    $legacyOverride = Get-EnvValue -Name "VANESSA_AUTOMATION_ARCHIVE_URL"
    $override = $(if ($sourceBuild) { [string]$sourceBuild } else { [string]$legacyOverride })
    if ($sourceBuild -and -not (Test-Path -LiteralPath (ConvertFrom-FileUri -Value $override) -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ITL_VANESSA_SOURCE_BUILD_NOT_FOUND: $override"
    }
    return [pscustomobject]@{
        url = $(if ($override) { $override } else { [string]$entry.url })
        version = [string]$entry.compatibilityVersion
        compatibilityVersion = [string]$entry.compatibilityVersion
        downstreamRevision = [string]$entry.downstreamRevision
        assetName = [string]$entry.assetName
        expectedSha256 = ([string]$entry.sha256).ToLowerInvariant()
        expectedEpfSha256 = ([string]$entry.epfSha256).ToLowerInvariant()
        source = $(if ($sourceBuild) { "source-build override" } elseif ($legacyOverride) { "archive URL override" } else { "workflow-pinned" })
    }
}

function Assert-VanessaSourceBuildArchiveMatchesActivePin {
    $sourceBuild = Get-EnvValue -Name "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE"
    if (-not $sourceBuild) {
        return
    }

    $downloadInfo = Get-VanessaAutomationDownloadInfo
    $sourcePath = ConvertFrom-FileUri -Value ([string]$sourceBuild)
    $actualSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne ([string]$downloadInfo.expectedSha256).ToLowerInvariant()) {
        throw "ITL_VANESSA_SOURCE_BUILD_SHA_MISMATCH: source-build archive does not match the active project pin. Expected $($downloadInfo.expectedSha256), got $actualSha256. Install or update the workflow lock before starting Vanessa."
    }
}

function Sync-VanessaAutomationDependencyLock {
    if ((Get-DependencyMode) -ne "fresh") {
        return $false
    }
    $template = New-DefaultDependencyLockManifest
    $entry = Get-ConfigValueFromObject -Object $template -Path "dependencies.vanessaAutomation" -Default $null
    if ($null -eq $entry) {
        throw "templates/dependency-lock.json has no vanessaAutomation entry."
    }
    Update-DependencyLockEntry -Name "vanessaAutomation" -Values (ConvertTo-Agent1cHashtable -Object $entry)
    Write-Host "Vanessa Automation fresh lock synchronized to workflow pin $($entry.compatibilityVersion)-$($entry.downstreamRevision)."
    return $true
}

function Get-VanessaCacheDirectory {
    return (Join-Path (Get-Agent1cTempRoot) "1c-agent-workflow\vanessa-automation")
}

function Save-VanessaAutomationArchive {
    param([object]$DownloadInfo)

    $cacheDir = Get-VanessaCacheDirectory
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $archivePath = Join-Path $cacheDir ("vanessa-automation-single-" + [guid]::NewGuid().ToString("N") + ".zip")
    $source = [string]$DownloadInfo.url
    $expected = ([string](Get-ConfigValueFromObject -Object $DownloadInfo -Path "expectedSha256" -Default "")).ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$') {
        throw "ITL_VANESSA_WORKFLOW_PIN_INCOMPLETE: expected archive SHA256 is empty or invalid."
    }

    Write-Host "Vanessa Automation archive source: $source"
    [void](Invoke-ItlImmutableFileAcquire -Source (ConvertFrom-FileUri -Value $source) -DestinationPath $archivePath -ExpectedSha256 $expected -Label "Vanessa Automation archive")

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    Write-Host "Vanessa Automation archive SHA256: $hash"

    if ($hash -cne $expected) {
        throw "Vanessa Automation archive SHA256 mismatch. Expected $expected, got $hash."
    }
    Write-Host "Vanessa Automation archive hash matches the workflow pin."

    return $archivePath
}

function Expand-VanessaAutomationArchiveContents {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $selected = [ordered]@{
            "vanessa-automation-single.epf" = "vanessa.epf"
            "LICENSE" = "LICENSE"
            "ITL-NOTICE.txt" = "ITL-NOTICE.txt"
            "ITL-PROVENANCE.json" = "ITL-PROVENANCE.json"
        }
        $epfPath = ""
        foreach ($sourceName in $selected.Keys) {
            $matches = @($archive.Entries | Where-Object {
                ([string]$_.FullName).Replace("\", "/").TrimStart("/") -ceq $sourceName
            })
            if ($sourceName -eq "vanessa-automation-single.epf" -and $matches.Count -ne 1) {
                throw "Downloaded Vanessa Automation archive must contain exactly one root vanessa-automation-single.epf entry."
            }
            if ($matches.Count -eq 0) {
                continue
            }
            if ($matches.Count -gt 1) {
                throw "Downloaded Vanessa Automation archive contains duplicate root entry: $sourceName"
            }

            $targetPath = Join-Path $DestinationPath ([string]$selected[$sourceName])
            $inputStream = $null
            $outputStream = $null
            try {
                $inputStream = $matches[0].Open()
                $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $inputStream.CopyTo($outputStream)
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }
            if ($sourceName -eq "vanessa-automation-single.epf") {
                $epfPath = $targetPath
            }
        }
        return $epfPath
    } finally {
        $archive.Dispose()
    }
}

function Expand-VanessaAutomationArchive {
    param(
        [string]$ArchivePath,
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedEpfSha256
    )

    $existingEpf = Find-VanessaAutomationEpf -Root $InstallRoot
    if ($existingEpf) {
        $existingHash = (Get-FileHash -LiteralPath $existingEpf -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -ceq $ExpectedEpfSha256.ToLowerInvariant()) {
            Write-Host "Vanessa Automation EPF already matches the workflow pin: $existingEpf"
            return $existingEpf
        }
    }

    if (-not $existingEpf -and (Test-Path -LiteralPath $InstallRoot -ErrorAction SilentlyContinue)) {
        $children = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Vanessa Automation install root already exists but does not contain an EPF: $InstallRoot"
        }
    }

    $transaction = Initialize-Agent1cProjectTransactionSlot -Kind "v" -Target $InstallRoot
    $stageRoot = $transaction.stage
    $rollbackRoot = $transaction.backup
    $movedExisting = $false
    try {
        $candidateEpf = Expand-VanessaAutomationArchiveContents -ArchivePath $ArchivePath -DestinationPath $stageRoot
        if (-not $candidateEpf) {
            throw "Downloaded Vanessa Automation archive did not contain a usable EPF."
        }
        $candidateHash = (Get-FileHash -LiteralPath $candidateEpf -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($candidateHash -cne $ExpectedEpfSha256.ToLowerInvariant()) {
            throw "Vanessa Automation EPF SHA256 mismatch. Expected $ExpectedEpfSha256, got $candidateHash."
        }
        if (Test-Path -LiteralPath $InstallRoot) {
            Move-Item -LiteralPath $InstallRoot -Destination $rollbackRoot
            $movedExisting = $true
            Write-Agent1cProjectTransactionState -Paths $transaction -Kind "v" -Phase "target-backed-up" -Target $InstallRoot
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $InstallRoot) | Out-Null
        Move-Item -LiteralPath $stageRoot -Destination $InstallRoot
        Write-Agent1cProjectTransactionState -Paths $transaction -Kind "v" -Phase "installed" -Target $InstallRoot
        $epfPath = Find-VanessaAutomationEpf -Root $InstallRoot
        $installedHash = $(if ($epfPath) { (Get-FileHash -LiteralPath $epfPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" })
        if (-not $epfPath -or $installedHash -cne $ExpectedEpfSha256.ToLowerInvariant()) {
            throw "Installed Vanessa Automation EPF did not preserve the workflow-pinned SHA256."
        }
        Complete-Agent1cProjectTransactionSlot -Paths $transaction
        $movedExisting = $false
        return $epfPath
    } catch {
        if ($movedExisting) {
            if (Test-Path -LiteralPath $InstallRoot) {
                Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $rollbackRoot) {
                Move-Item -LiteralPath $rollbackRoot -Destination $InstallRoot
            }
        }
        Complete-Agent1cProjectTransactionSlot -Paths $transaction
        throw
    }
}

function Save-VanessaAutomationSettingsToDotEnv {
    param(
        [string]$EpfPath,
        [string]$Version = "",
        [string]$DownstreamRevision = ""
    )

    $featuresPath = Get-VanessaFeaturesPath
    $reportsPath = Get-VanessaReportsPath
    New-Item -ItemType Directory -Force -Path (Resolve-ProjectPath $featuresPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Resolve-ProjectPath $reportsPath) | Out-Null

    Set-DotEnvValues -Values @{
        VANESSA_AUTOMATION_EPF = $EpfPath
        VANESSA_AUTOMATION_VERSION = $Version
        VANESSA_AUTOMATION_DOWNSTREAM_REVISION = $DownstreamRevision
        VANESSA_FEATURES_PATH = $featuresPath
        VANESSA_REPORTS_PATH = $reportsPath
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Vanessa Automation settings saved to .dev.env"
}

function Install-VanessaAutomation {
    Write-Section "Install Vanessa Automation"

    $downloadInfo = Get-VanessaAutomationDownloadInfo
    $state = Get-VanessaAutomationState
    if ($state.ready) {
        Write-Host "Vanessa Automation is already installed: $($state.epfPath)"
        Save-VanessaAutomationSettingsToDotEnv -EpfPath $state.epfPath -Version $downloadInfo.compatibilityVersion -DownstreamRevision $downloadInfo.downstreamRevision
        return
    }

    $installRoot = Get-VanessaInstallRoot
    Write-Host "Vanessa Automation install root: $installRoot"
    Write-Host "Vanessa Automation download metadata source: $($downloadInfo.source)"
    $archivePath = Save-VanessaAutomationArchive -DownloadInfo $downloadInfo
    $epfPath = Expand-VanessaAutomationArchive -ArchivePath $archivePath -InstallRoot $installRoot -ExpectedEpfSha256 $downloadInfo.expectedEpfSha256
    Save-VanessaAutomationSettingsToDotEnv -EpfPath $epfPath -Version $downloadInfo.compatibilityVersion -DownstreamRevision $downloadInfo.downstreamRevision
    Write-Host "Vanessa Automation EPF: $epfPath"
}

function Ensure-VanessaAutomationForInit {
    param([object]$Answers)

    $state = Get-VanessaAutomationState
    if ($state.ready) {
        Save-VanessaAutomationSettingsToDotEnv -EpfPath $state.epfPath -Version $state.version -DownstreamRevision $state.downstreamRevision
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

function ConvertTo-VanessaTagFilterList {
    param([AllowNull()][string]$Value)

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($part in @([regex]::Split([string]$Value, '[,;]'))) {
        $tag = ([string]$part).Trim()
        while ($tag.StartsWith("@", [System.StringComparison]::Ordinal)) {
            $tag = $tag.Substring(1).TrimStart()
        }
        if (-not $tag) { continue }
        $key = $tag.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result.Add($tag)
    }
    return @($result.ToArray())
}

function ConvertFrom-VanessaFeatureTableRow {
    param([string]$Line)

    $trimmed = ([string]$Line).Trim()
    if (-not ($trimmed.StartsWith("|") -and $trimmed.EndsWith("|"))) {
        return @()
    }
    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
    return @($inner.Split("|") | ForEach-Object { ([string]$_).Trim().Trim("'", '"') })
}

function Get-VanessaFeatureScenarioDefinitions {
    param([string[]]$FeatureFiles)

    $scenarios = New-Object System.Collections.Generic.List[object]
    foreach ($featureFile in @($FeatureFiles)) {
        $featureTags = @()
        $pendingTags = New-Object System.Collections.Generic.List[string]
        $backgroundSteps = New-Object System.Collections.Generic.List[string]
        $current = $null
        $inBackground = $false
        $inExamples = $false
        $exampleHeaders = @()

        foreach ($line in @(Get-Content -LiteralPath $featureFile -Encoding UTF8)) {
            if ($line -match '^\s*@') {
                foreach ($token in @([regex]::Matches($line, '@(?<tag>[^\s@]+)'))) {
                    $pendingTags.Add([string]$token.Groups['tag'].Value)
                }
                continue
            }

            if ($line -match '^\s*(?:Функционал|Feature)\s*:') {
                $featureTags = @($pendingTags.ToArray())
                $pendingTags.Clear()
                continue
            }

            if ($line -match '^\s*(?:Контекст|Background)\s*:') {
                $inBackground = $true
                continue
            }

            $scenarioMatch = [regex]::Match(
                $line,
                '^\s*(?<kind>Структура\s+сценария|Сценарий-шаблон|Scenario\s+Outline|Scenario\s+Template|Сценарий|Scenario)\s*:\s*(?<name>.*)$',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if ($scenarioMatch.Success) {
                if ($null -ne $current) { $scenarios.Add($current) }
                $kind = [string]$scenarioMatch.Groups['kind'].Value
                $current = [pscustomobject][ordered]@{
                    source = $featureFile
                    name = ([string]$scenarioMatch.Groups['name'].Value).Trim()
                    isOutline = ($kind -match '(?i)Структура|шаблон|Outline|Template')
                    tags = @($featureTags + @($pendingTags.ToArray()))
                    steps = (New-Object System.Collections.Generic.List[string])
                    exampleRows = (New-Object System.Collections.Generic.List[object])
                }
                foreach ($backgroundStep in @($backgroundSteps.ToArray())) {
                    $current.steps.Add($backgroundStep)
                }
                $pendingTags.Clear()
                $inBackground = $false
                $inExamples = $false
                $exampleHeaders = @()
                continue
            }

            if ($null -eq $current) {
                if ($inBackground -and -not [string]::IsNullOrWhiteSpace($line)) {
                    $backgroundSteps.Add([string]$line)
                }
                continue
            }
            if ($line -match '^\s*(?:Примеры|Examples|Scenarios)\s*:') {
                $inExamples = $true
                $exampleHeaders = @()
                continue
            }
            if ($inExamples -and $line -match '^\s*\|') {
                $cells = @(ConvertFrom-VanessaFeatureTableRow -Line $line)
                if ($exampleHeaders.Count -eq 0) {
                    $exampleHeaders = @($cells)
                } elseif ($cells.Count -eq $exampleHeaders.Count) {
                    $values = @{}
                    for ($index = 0; $index -lt $exampleHeaders.Count; $index++) {
                        $values[[string]$exampleHeaders[$index]] = [string]$cells[$index]
                    }
                    $current.exampleRows.Add([pscustomobject]$values)
                }
                continue
            }
            if ($inExamples -and -not [string]::IsNullOrWhiteSpace($line)) {
                $inExamples = $false
                $exampleHeaders = @()
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $current.steps.Add([string]$line)
            }
        }
        if ($null -ne $current) { $scenarios.Add($current) }
    }
    return @($scenarios.ToArray())
}

function Get-VanessaScenarioInstances {
    param([object]$Scenario)

    if (-not $Scenario.isOutline) {
        return @([pscustomobject]@{ values = @{} })
    }
    return @($Scenario.exampleRows.ToArray() | ForEach-Object { [pscustomobject]@{ values = $_ } })
}

function Resolve-VanessaScenarioValue {
    param(
        [string]$Value,
        [object]$ExampleValues
    )

    $match = [regex]::Match(([string]$Value).Trim(), '^<(?<name>[^>]+)>$')
    if (-not $match.Success) {
        return [pscustomobject]@{ resolved = $true; value = ([string]$Value).Trim(); placeholder = "" }
    }
    $placeholder = [string]$match.Groups['name'].Value
    if ($null -ne $ExampleValues) {
        $property = $ExampleValues.PSObject.Properties[$placeholder]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [pscustomobject]@{ resolved = $true; value = ([string]$property.Value).Trim(); placeholder = $placeholder }
        }
    }
    return [pscustomobject]@{ resolved = $false; value = ""; placeholder = $placeholder }
}

function Get-VanessaFeatureTestClientRequirements {
    param(
        [string[]]$FeatureFiles,
        [string]$FilterTags = ""
    )

    $requiredProfiles = @{}
    $unresolved = New-Object System.Collections.Generic.List[object]
    $maximumConcurrency = 0
    $requiresExtensionTestClient = $false
    $normalizedFilterTags = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    $wantedTags = @{}
    foreach ($filterTag in $normalizedFilterTags) { $wantedTags[$filterTag.ToLowerInvariant()] = $true }
    foreach ($scenario in @(Get-VanessaFeatureScenarioDefinitions -FeatureFiles $FeatureFiles)) {
        if ($wantedTags.Count -gt 0) {
            $selectedByTag = $false
            foreach ($scenarioTag in @($scenario.tags)) {
                if ($wantedTags.ContainsKey(([string]$scenarioTag).ToLowerInvariant())) {
                    $selectedByTag = $true
                    break
                }
            }
            if (-not $selectedByTag) { continue }
        }
        $instances = @(Get-VanessaScenarioInstances -Scenario $scenario)
        if ($scenario.isOutline -and $instances.Count -eq 0) {
            $unresolved.Add([pscustomobject][ordered]@{
                source = $scenario.source
                scenario = $scenario.name
                placeholder = "<examples>"
                reason = "scenario-outline-has-no-example-rows"
            })
            continue
        }
        foreach ($instance in $instances) {
            $active = @{}
            $currentClientKey = ""
            $awaitDirectClientTableHeader = $false
            $awaitDirectClientTableRow = $false
            foreach ($step in @($scenario.steps.ToArray())) {
                if ($step -match '(?i)\(Расширение\)') {
                    $requiresExtensionTestClient = $true
                    $currentClientKey = '__itl_current_testclient__'
                    if (-not $active.ContainsKey($currentClientKey)) {
                        $active[$currentClientKey] = 'extension'
                        $maximumConcurrency = [Math]::Max($maximumConcurrency, $active.Count)
                    }
                }
                if ($awaitDirectClientTableHeader) {
                    if ($step -match '(?i)^\s*\|\s*["'']?Имя подключения["'']?\s*\|\s*["'']?Логин["'']?\s*\|\s*["'']?Пароль["'']?\s*\|\s*$') {
                        $awaitDirectClientTableHeader = $false
                        $awaitDirectClientTableRow = $true
                        continue
                    }
                    $awaitDirectClientTableHeader = $false
                }
                if ($awaitDirectClientTableRow) {
                    $directTableRow = [regex]::Match($step, '^\s*\|\s*(?<name>[^|]+?)\s*\|')
                    $awaitDirectClientTableRow = $false
                    if ($directTableRow.Success) {
                        $directName = ([string]$directTableRow.Groups['name'].Value).Trim().Trim("'", '"')
                        if ($directName) {
                            $resolved = Resolve-VanessaScenarioValue -Value $directName -ExampleValues $instance.values
                            if ($resolved.resolved) {
                                $currentClientKey = $resolved.value.ToLowerInvariant()
                                $active[$currentClientKey] = $resolved.value
                                $maximumConcurrency = [Math]::Max($maximumConcurrency, $active.Count)
                            }
                        }
                        continue
                    }
                }

                if ($step -match '(?i)я\s+запускаю\s+сценарий\s+открытия\s+TestClient\s+или\s+подключаю\s+уже\s+существующий') {
                    $currentClientKey = '__itl_current_testclient__'
                    $active[$currentClientKey] = 'current'
                    $maximumConcurrency = [Math]::Max($maximumConcurrency, $active.Count)
                    continue
                }

                $connect = [regex]::Match($step, '(?i)подключаю\s+профиль\s+TestClient\s+["''](?<name>[^"'']+)["'']')
                if ($connect.Success) {
                    $resolved = Resolve-VanessaScenarioValue -Value $connect.Groups['name'].Value -ExampleValues $instance.values
                    if (-not $resolved.resolved) {
                        $unresolved.Add([pscustomobject][ordered]@{
                            source = $scenario.source
                            scenario = $scenario.name
                            placeholder = "<$($resolved.placeholder)>"
                            reason = "profile-placeholder-is-not-resolved-by-examples"
                        })
                        continue
                    }
                    $requiredProfiles[$resolved.value.ToLowerInvariant()] = $resolved.value
                    $currentClientKey = $resolved.value.ToLowerInvariant()
                    $active[$currentClientKey] = $resolved.value
                    $maximumConcurrency = [Math]::Max($maximumConcurrency, $active.Count)
                    continue
                }

                $directConnect = [regex]::Match($step, '(?i)я\s+подключаю\s+TestClient\s+["''](?<name>[^"'']+)["'']\s+логин\s+["''][^"'']*["'']\s+пароль\s+["'']')
                if ($directConnect.Success) {
                    $resolved = Resolve-VanessaScenarioValue -Value $directConnect.Groups['name'].Value -ExampleValues $instance.values
                    if ($resolved.resolved) {
                        $currentClientKey = $resolved.value.ToLowerInvariant()
                        $active[$currentClientKey] = $resolved.value
                        $maximumConcurrency = [Math]::Max($maximumConcurrency, $active.Count)
                    }
                    continue
                }

                if ($step -match '(?i)я\s+подключаю\s+клиент\s+тестирования\s+с\s+параметрами\s*:\s*$') {
                    $awaitDirectClientTableHeader = $true
                    continue
                }

                $close = [regex]::Match($step, '(?i)закрываю\s+TestClient\s+["''](?<name>[^"'']+)["'']')
                if ($close.Success) {
                    $resolved = Resolve-VanessaScenarioValue -Value $close.Groups['name'].Value -ExampleValues $instance.values
                    if (-not $resolved.resolved) {
                        $unresolved.Add([pscustomobject][ordered]@{
                            source = $scenario.source
                            scenario = $scenario.name
                            placeholder = "<$($resolved.placeholder)>"
                            reason = "profile-placeholder-is-not-resolved-by-examples"
                        })
                    } else {
                        $closedKey = $resolved.value.ToLowerInvariant()
                        [void]$active.Remove($closedKey)
                        if ($currentClientKey -eq $closedKey) { $currentClientKey = "" }
                    }
                    continue
                }
                if ($step -match '(?i)закрываю\s+сеанс\s+текущего\s+клиента\s+тестирования') {
                    if ($currentClientKey) {
                        [void]$active.Remove($currentClientKey)
                        $currentClientKey = ""
                    }
                    continue
                }
                if ($step -match '(?i)закрываю\s+все\s+(?:сеансы\s+)?TestClient') {
                    $active.Clear()
                    $currentClientKey = ""
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        requiredProfiles = @($requiredProfiles.Values | Sort-Object)
        unresolvedProfileReferences = @($unresolved.ToArray())
        maximumConcurrency = $maximumConcurrency
        requiresExtensionTestClient = $requiresExtensionTestClient
    }
}

function Get-VanessaFilteredScenarioCount {
    param(
        [string[]]$FeatureFiles,
        [string]$FilterTags
    )

    $filters = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    if ($filters.Count -eq 0) { return 0 }
    $wanted = @{}
    foreach ($filter in $filters) { $wanted[$filter.ToLowerInvariant()] = $true }

    $count = 0
    foreach ($scenario in @(Get-VanessaFeatureScenarioDefinitions -FeatureFiles $FeatureFiles)) {
        $selected = $false
        foreach ($tag in @($scenario.tags)) {
            if ($wanted.ContainsKey(([string]$tag).ToLowerInvariant())) {
                $selected = $true
                break
            }
        }
        if (-not $selected) { continue }
        if ($scenario.isOutline) {
            $count += $scenario.exampleRows.Count
        } else {
            $count++
        }
    }
    return $count
}

function Get-VanessaTestClientManifestPath {
    $value = [string](Get-Setting `
        -EnvName "VANESSA_TESTCLIENT_MANIFEST" `
        -ConfigName "vanessaAutomation.testClientManifestPath" `
        -Default "")
    if ([string]::IsNullOrWhiteSpace($value)) { return "" }
    return (Resolve-ProjectPath $value)
}

function Get-VanessaTestClientSecretValue {
    param(
        [string]$EnvironmentName,
        [string]$ProfileName
    )

    if ($EnvironmentName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "ITL_VANESSA_TESTCLIENT_SECRET_SOURCE_INVALID: profile='$ProfileName' environment='$EnvironmentName'."
    }
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName, "Process")
    if ([string]::IsNullOrEmpty($value)) {
        $value = [Environment]::GetEnvironmentVariable("AGENT_1C_$EnvironmentName", "Process")
    }
    if ([string]::IsNullOrEmpty($value)) {
        throw "ITL_VANESSA_TESTCLIENT_SECRET_MISSING: profile='$ProfileName' environment='$EnvironmentName'. Define it in ignored .dev.env or the process environment."
    }
    return $value
}

function Read-VanessaTestClientManifest {
    $path = Get-VanessaTestClientManifestPath
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ITL_VANESSA_TESTCLIENT_MANIFEST_NOT_FOUND: $path"
    }

    try {
        $manifest = Read-Utf8Text -Path $path | ConvertFrom-Json
    } catch {
        throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: '$path' is not valid JSON. $($_.Exception.Message)"
    }
    if ([int](Get-StateValue -State $manifest -Name "schemaVersion" -Default 0) -ne 1) {
        throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: '$path' must use schemaVersion=1."
    }

    $allowedRoot = @("schemaVersion", "maxConcurrency", "profiles")
    foreach ($property in @($manifest.PSObject.Properties)) {
        if ($allowedRoot -notcontains [string]$property.Name) {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: unsupported root property '$($property.Name)' in '$path'."
        }
    }

    $profiles = New-Object System.Collections.Generic.List[object]
    $seenNames = @{}
    $profilesProperty = $manifest.PSObject.Properties["profiles"]
    $manifestProfiles = $(if ($null -eq $profilesProperty -or $null -eq $profilesProperty.Value) { @() } else { @($profilesProperty.Value) })
    foreach ($profile in $manifestProfiles) {
        $allowedProfile = @("name", "user", "userEnv", "passwordEnv", "synonym", "clientType")
        foreach ($property in @($profile.PSObject.Properties)) {
            $propertyName = [string]$property.Name
            if ($propertyName -match '(?i)^password(?:Value)?$|secret') {
                throw "ITL_VANESSA_TESTCLIENT_MANIFEST_SECRET_FORBIDDEN: profile property '$propertyName' must be replaced with passwordEnv in '$path'."
            }
            if ($allowedProfile -notcontains $propertyName) {
                throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: unsupported profile property '$propertyName' in '$path'."
            }
        }

        $name = ([string](Get-StateValue -State $profile -Name "name" -Default "")).Trim()
        if (-not $name -or $name -match '^<[^>]+>$') {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: every profile in '$path' needs a literal non-placeholder name."
        }
        $nameKey = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($nameKey)) {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: duplicate profile name '$name' in '$path'."
        }
        $seenNames[$nameKey] = $true

        $user = [string](Get-StateValue -State $profile -Name "user" -Default "")
        $userEnv = [string](Get-StateValue -State $profile -Name "userEnv" -Default "")
        if ($user -and $userEnv) {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: profile '$name' cannot define both user and userEnv."
        }
        if ($userEnv) {
            $user = Get-VanessaTestClientSecretValue -EnvironmentName $userEnv -ProfileName $name
        }

        $password = ""
        $passwordEnv = [string](Get-StateValue -State $profile -Name "passwordEnv" -Default "")
        if ($passwordEnv) {
            $password = Get-VanessaTestClientSecretValue -EnvironmentName $passwordEnv -ProfileName $name
        }
        $clientType = ([string](Get-StateValue -State $profile -Name "clientType" -Default "Thin")).Trim()
        if ($clientType -notin @("Thin", "Thick")) {
            throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: profile '$name' clientType must be Thin or Thick."
        }

        $profiles.Add([pscustomobject][ordered]@{
            name = $name
            user = $user
            password = $password
            synonym = [string](Get-StateValue -State $profile -Name "synonym" -Default "")
            clientType = $clientType
        })
    }

    $maxConcurrencyValue = Get-StateValue -State $manifest -Name "maxConcurrency" -Default $null
    if ($null -eq $maxConcurrencyValue -or [string]$maxConcurrencyValue -notmatch '^\d+$') {
        throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: '$path' must declare non-negative integer maxConcurrency."
    }
    $maxConcurrency = [int]$maxConcurrencyValue
    if ($profiles.Count -gt 0 -and $maxConcurrency -lt 1) {
        throw "ITL_VANESSA_TESTCLIENT_MANIFEST_INVALID: maxConcurrency=$maxConcurrency is incompatible with profiles=$($profiles.Count) in '$path'."
    }

    return [pscustomobject][ordered]@{
        configured = $true
        path = $path
        maxConcurrency = $maxConcurrency
        profiles = @($profiles.ToArray())
    }
}

function Get-VanessaTestClientTopology {
    param(
        [string[]]$FeatureFiles,
        [string]$FilterTags = ""
    )

    $requirements = Get-VanessaFeatureTestClientRequirements -FeatureFiles $FeatureFiles -FilterTags $FilterTags
    if (@($requirements.unresolvedProfileReferences).Count -gt 0) {
        $details = @($requirements.unresolvedProfileReferences | ForEach-Object {
            [ordered]@{
                source = ConvertTo-ProjectRelativePath $_.source
                scenario = $_.scenario
                placeholder = $_.placeholder
                reason = $_.reason
            }
        }) | ConvertTo-Json -Compress -Depth 5
        throw "ITL_VANESSA_TEST_FIXTURE_UNRESOLVED_PROFILE: references=$details"
    }

    $manifest = Read-VanessaTestClientManifest
    if ($null -eq $manifest) {
        $legacyUser = [string](Get-EnvValue -Name "IB_USER")
        $manifest = [pscustomobject][ordered]@{
            configured = $false
            path = "<legacy-default>"
            maxConcurrency = 1
            profiles = @([pscustomobject][ordered]@{
                name = $(if ($legacyUser) { $legacyUser } else { "default" })
                user = $legacyUser
                password = [string](Get-EnvValue -Name "IB_PASSWORD")
                synonym = ""
                clientType = "Thin"
            })
        }
    }

    $configuredNames = @{}
    foreach ($profile in @($manifest.profiles)) {
        $configuredNames[([string]$profile.name).ToLowerInvariant()] = $true
    }
    $missing = @($requirements.requiredProfiles | Where-Object {
        -not $configuredNames.ContainsKey(([string]$_).ToLowerInvariant())
    } | Sort-Object)
    if ($missing.Count -gt 0) {
        $missingJson = ConvertTo-Json -InputObject @($missing) -Compress
        throw "ITL_VANESSA_TESTCLIENT_PROFILES_MISSING: profiles=$missingJson manifest='$($manifest.path)'"
    }
    if ([int]$requirements.maximumConcurrency -gt [int]$manifest.maxConcurrency) {
        throw "ITL_VANESSA_TESTCLIENT_CONCURRENCY_INSUFFICIENT: requiredTestClientSlots=$($requirements.maximumConcurrency) declaredTestClientCeiling=$($manifest.maxConcurrency) manifest='$($manifest.path)'"
    }

    return [pscustomobject][ordered]@{
        configured = $manifest.configured
        path = $manifest.path
        declaredTestClientCeiling = [int]$manifest.maxConcurrency
        profiles = @($manifest.profiles)
        requiredProfiles = @($requirements.requiredProfiles)
        requiredTestClientSlots = [int]$requirements.maximumConcurrency
        requiresExtensionTestClient = [bool]$requirements.requiresExtensionTestClient
    }
}

function Get-VanessaApplicationFeatureFiles {
    param([string]$FeaturePath)

    $featuresRoot = Resolve-ProjectPath $FeaturePath
    return @(Get-VanessaFeatureFiles -FeaturePath $FeaturePath | Where-Object {
        $relative = [string]$_.Substring($featuresRoot.TrimEnd("\", "/").Length).TrimStart("\", "/")
        $relative -notmatch '^(?i)Libraries[\\/]'
    })
}

function Throw-VanessaFeatureByteSafetyError {
    param(
        [string]$Path,
        [string]$Reason,
        [long]$ByteOffset,
        [string]$Detail = ""
    )

    $relativePath = ConvertTo-ProjectRelativePath -Path $Path
    $detailSuffix = $(if ($Detail) { " $Detail" } else { "" })
    Set-RunFailureContext -Category "test-fixture" -RequiredAction "/itl-verify-fix"
    throw "ITL_VANESSA_TEST_FIXTURE_INVALID_FEATURE_BYTES: reason=$Reason path='$relativePath' byteOffset=$ByteOffset$detailSuffix"
}

function Get-VanessaInvalidUtf8ByteOffset {
    param([byte[]]$Bytes, [int]$Offset)

    for ($index = $Offset; $index -lt $Bytes.Length; ) {
        $first = [int]$Bytes[$index]
        if ($first -le 0x7F) {
            $index++
            continue
        }

        $length = 0
        $secondMinimum = 0x80
        $secondMaximum = 0xBF
        if ($first -ge 0xC2 -and $first -le 0xDF) {
            $length = 2
        } elseif ($first -eq 0xE0) {
            $length = 3
            $secondMinimum = 0xA0
        } elseif (($first -ge 0xE1 -and $first -le 0xEC) -or ($first -ge 0xEE -and $first -le 0xEF)) {
            $length = 3
        } elseif ($first -eq 0xED) {
            $length = 3
            $secondMaximum = 0x9F
        } elseif ($first -eq 0xF0) {
            $length = 4
            $secondMinimum = 0x90
        } elseif ($first -ge 0xF1 -and $first -le 0xF3) {
            $length = 4
        } elseif ($first -eq 0xF4) {
            $length = 4
            $secondMaximum = 0x8F
        } else {
            return $index
        }

        if ($index + $length -gt $Bytes.Length) { return $index }
        $second = [int]$Bytes[$index + 1]
        if ($second -lt $secondMinimum -or $second -gt $secondMaximum) { return $index }
        for ($continuation = 2; $continuation -lt $length; $continuation++) {
            $value = [int]$Bytes[$index + $continuation]
            if ($value -lt 0x80 -or $value -gt 0xBF) { return $index }
        }
        $index += $length
    }
    return -1
}

function Assert-VanessaFeatureByteSafety {
    param([Parameter(Mandatory = $true)][string[]]$FeatureFiles)

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    foreach ($featureFile in @($FeatureFiles | Sort-Object)) {
        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($featureFile)
        $contentOffset = $(if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 })
        try {
            $null = $strictUtf8.GetString($bytes, $contentOffset, $bytes.Length - $contentOffset)
        } catch {
            $invalidOffset = Get-VanessaInvalidUtf8ByteOffset -Bytes $bytes -Offset $contentOffset
            if ($invalidOffset -lt 0) { $invalidOffset = $contentOffset }
            Throw-VanessaFeatureByteSafetyError -Path $featureFile -Reason "invalid-utf8" -ByteOffset $invalidOffset
        }

        for ($index = $contentOffset; $index -lt $bytes.Length; $index++) {
            $value = [int]$bytes[$index]
            if ($value -eq 0) {
                Throw-VanessaFeatureByteSafetyError -Path $featureFile -Reason "nul" -ByteOffset $index
            }
            $isDisallowedC0 = (($value -ge 1 -and $value -le 0x1F) -or $value -eq 0x7F) -and $value -notin @(0x09, 0x0A, 0x0D)
            if ($isDisallowedC0) {
                Throw-VanessaFeatureByteSafetyError -Path $featureFile -Reason "control-character" -ByteOffset $index -Detail ("codePoint=U+{0:X4}" -f $value)
            }
            if ($value -eq 0xC2 -and $index + 1 -lt $bytes.Length -and $bytes[$index + 1] -ge 0x80 -and $bytes[$index + 1] -le 0x9F) {
                Throw-VanessaFeatureByteSafetyError -Path $featureFile -Reason "control-character" -ByteOffset $index -Detail ("codePoint=U+{0:X4}" -f [int]$bytes[$index + 1])
            }
        }
    }
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

function Get-VanessaChangedFeatureRecords {
    return @(Get-VanessaChangedFeatureFiles | ForEach-Object {
        [pscustomobject][ordered]@{
            path = ConvertTo-ProjectRelativePath -Path $_
        }
    } | Sort-Object path)
}

function Get-VanessaAuthoringLintWarnings {
    param(
        [Parameter(Mandatory = $true)][object[]]$FeatureRecords,
        [ValidateRange(1, 100)][int]$MaxWarnings = 20
    )

    $warnings = [System.Collections.Generic.List[object]]::new()
    $currentRowPhrase = ConvertFrom-Utf8Base64 "0Y8g0LLRi9Cx0LjRgNCw0Y4g0YLQtdC60YPRidGD0Y4g0YHRgtGA0L7QutGD"
    $positionPhrases = @(
        (ConvertFrom-Utf8Base64 "0Y8g0L/QtdGA0LXRhdC+0LbRgyDQuiDRgdGC0YDQvtC60LU="),
        (ConvertFrom-Utf8Base64 "0Y8g0YPRgdGC0LDQvdCw0LLQu9C40LLQsNGOINGC0LXQutGD0YnRg9GOINGB0YLRgNC+0LrRgw==")
    )
    $pauseKeyword = [regex]::Escape((ConvertFrom-Utf8Base64 "0J/QsNGD0LfQsA=="))
    $stepKeywords = @(
        "And", "When", "Then", "Given",
        (ConvertFrom-Utf8Base64 "0Jg="),
        (ConvertFrom-Utf8Base64 "0JrQvtCz0LTQsA=="),
        (ConvertFrom-Utf8Base64 "0KLQvtCz0LTQsA=="),
        (ConvertFrom-Utf8Base64 "0J/Rg9GB0YLRjA=="),
        (ConvertFrom-Utf8Base64 "0JTQsNC90L4=")
    )
    $scenarioKeywords = @(
        "Scenario", "Scenario Outline", "Background",
        (ConvertFrom-Utf8Base64 "0KHRhtC10L3QsNGA0LjQuQ=="),
        (ConvertFrom-Utf8Base64 "0KHRgtGA0YPQutGC0YPRgNCwINGB0YbQtdC90LDRgNC40Y8="),
        (ConvertFrom-Utf8Base64 "0J/RgNC10LTRi9GB0YLQvtGA0LjRjw==")
    )
    $stepPrefixPattern = "(?:" + (($stepKeywords | ForEach-Object { [regex]::Escape($_) }) -join "|") + "|\*)"
    $stepPattern = "^\s*$stepPrefixPattern\s+"
    $pausePattern = "$stepPattern$pauseKeyword(?:\s|$)"
    $scenarioPattern = "^\s*(?:" + (($scenarioKeywords | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")\s*:"
    $quotedValuePattern = [regex]"'(?:\\'|[^']|'')*'"
    $serverCodePhrase = ConvertFrom-Utf8Base64 "0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LU="
    $clientCodePhrase = ConvertFrom-Utf8Base64 "0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwICjQoNCw0YHRiNC40YDQtdC90LjQtSk="
    $serverExtensionCodePhrase = $serverCodePhrase + " " + (ConvertFrom-Utf8Base64 "KNCg0LDRgdGI0LjRgNC10L3QuNC1KQ==")
    $unsupportedStateCalls = @(
        (ConvertFrom-Utf8Base64 "0KHQvtGF0YDQsNC90LjRgtGM0JfQvdCw0YfQtdC90LjQtQ=="),
        (ConvertFrom-Utf8Base64 "0JLQvtGB0YHRgtCw0L3QvtCy0LjRgtGM0JfQvdCw0YfQtdC90LjQtQ==")
    )
    $metadataManagers = @(
        "0KHQv9GA0LDQstC+0YfQvdC40LrQuA==",
        "0JTQvtC60YPQvNC10L3RgtGL",
        "0J/Qu9Cw0L3Ri9CS0LjQtNC+0LLQpdCw0YDQsNC60YLQtdGA0LjRgdGC0LjQug==",
        "0J/Qu9Cw0L3Ri9Ch0YfQtdGC0L7Qsg==",
        "0J/Qu9Cw0L3Ri9CS0LjQtNC+0LLQoNCw0YHRh9C10YLQsA==",
        "0KDQtdCz0LjRgdGC0YDRi9Ch0LLQtdC00LXQvdC40Lk=",
        "0KDQtdCz0LjRgdGC0YDRi9Cd0LDQutC+0L/Qu9C10L3QuNGP",
        "0KDQtdCz0LjRgdGC0YDRi9CR0YPRhdCz0LDQu9GC0LXRgNC40Lg=",
        "0KDQtdCz0LjRgdGC0YDRi9Cg0LDRgdGH0LXRgtCw",
        "0JHQuNC30L3QtdGB0J/RgNC+0YbQtdGB0YHRiw==",
        "0JfQsNC00LDRh9C4"
    ) | ForEach-Object { ConvertFrom-Utf8Base64 $_ }
    $metadataManagerPattern = "\b(?:" + (($metadataManagers | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")\s*\."
    $clientModuleSuffix = ConvertFrom-Utf8Base64 "0JrQu9C40LXQvdGC"
    $clientModulePattern = "\b[\p{L}\p{Nd}_]*" + [regex]::Escape($clientModuleSuffix) + "\s*\."

    foreach ($feature in @($FeatureRecords)) {
        if ($warnings.Count -ge $MaxWarnings) { break }
        $relativePath = [string](Get-StateValue -State $feature -Name "path" -Default "")
        if (-not $relativePath -or [System.IO.Path]::GetExtension($relativePath) -ine ".feature") { continue }
        $fullPath = Resolve-ProjectPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf -ErrorAction SilentlyContinue)) { continue }

        $lines = @((Read-Utf8Text -Path $fullPath) -split "`r?`n")
        $insideDocString = $false
        $pendingCodeContext = ""
        $docStringCodeContext = ""
        $docStringWarnedState = $false
        $docStringWarnedContext = $false
        $positionPending = $false
        $positionTableRows = 0
        $hasReliablePosition = $false

        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($warnings.Count -ge $MaxWarnings) { break }
            $line = [string]$lines[$index]
            $trimmed = $line.Trim()
            $docStringMarkers = ([regex]::Matches($line, '"""')).Count
            if (-not $insideDocString -and $line -match $stepPattern) {
                $pendingCodeContext = ""
                if ($line.IndexOf($serverExtensionCodePhrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $pendingCodeContext = "server"
                } elseif ($line.IndexOf($serverCodePhrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $pendingCodeContext = "manager-server"
                } elseif ($line.IndexOf($clientCodePhrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $pendingCodeContext = "client"
                }
            }
            if ($insideDocString) {
                if ($docStringMarkers -eq 0 -and $docStringCodeContext) {
                    if (-not $docStringWarnedState) {
                        foreach ($callName in $unsupportedStateCalls) {
                            if ($line.IndexOf($callName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                $warnings.Add([pscustomobject][ordered]@{
                                    code = "ITL_VANESSA_LINT_UNSUPPORTED_STATE"
                                    path = $relativePath
                                    line = $index + 1
                                    message = "VAExtension arbitrary code uses unsupported cross-step state; use a supported Vanessa variable or library step."
                                })
                                $docStringWarnedState = $true
                                break
                            }
                        }
                    }
                    if (-not $docStringWarnedContext -and $docStringCodeContext -eq "manager-server" -and $line -match $metadataManagerPattern) {
                        $warnings.Add([pscustomobject][ordered]@{
                            code = "ITL_VANESSA_LINT_MANAGER_METADATA"
                            path = $relativePath
                            line = $index + 1
                            message = "Plain server arbitrary-code block runs in the empty TestManager infobase; use the server (Extension) step for product metadata or data access."
                        })
                        $docStringWarnedContext = $true
                    } elseif (-not $docStringWarnedContext -and $docStringCodeContext -eq "client" -and $line -match $metadataManagerPattern) {
                        $warnings.Add([pscustomobject][ordered]@{
                            code = "ITL_VANESSA_LINT_CLIENT_METADATA"
                            path = $relativePath
                            line = $index + 1
                            message = "Client arbitrary-code block directly references a metadata manager; split server data access from client UI work."
                        })
                        $docStringWarnedContext = $true
                    } elseif (-not $docStringWarnedContext -and $docStringCodeContext -in @("manager-server", "server") -and $line -match $clientModulePattern) {
                        $warnings.Add([pscustomobject][ordered]@{
                            code = "ITL_VANESSA_LINT_SERVER_CLIENT_MODULE"
                            path = $relativePath
                            line = $index + 1
                            message = "Server arbitrary-code block references a client-only module name; split server data access from client UI work."
                        })
                        $docStringWarnedContext = $true
                    }
                }
                if (($docStringMarkers % 2) -eq 1) {
                    $insideDocString = $false
                    $pendingCodeContext = ""
                    $docStringCodeContext = ""
                }
                continue
            }
            if ($docStringMarkers -gt 0) {
                if (($docStringMarkers % 2) -eq 1) {
                    $insideDocString = $true
                    $docStringCodeContext = $pendingCodeContext
                    $docStringWarnedState = $false
                    $docStringWarnedContext = $false
                }
                continue
            }

            if (($trimmed.StartsWith("|") -or $line -match $stepPattern) -and -not $trimmed.StartsWith("#")) {
                foreach ($quotedValue in @($quotedValuePattern.Matches($line))) {
                    if ($quotedValue.Length -le 2) { continue }
                    $innerValue = $quotedValue.Value.Substring(1, $quotedValue.Length - 2)
                    if ($innerValue.Contains("''")) {
                        $warnings.Add([pscustomobject][ordered]@{
                            code = "ITL_VANESSA_LINT_APOSTROPHE"
                            path = $relativePath
                            line = $index + 1
                            message = "Doubled apostrophe in a single-quoted Gherkin value; use \'."
                        })
                        break
                    }
                }
            }
            if ($warnings.Count -ge $MaxWarnings) { break }

            if ($line -match $scenarioPattern) {
                $positionPending = $false
                $positionTableRows = 0
                $hasReliablePosition = $false
                continue
            }
            if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith("@")) { continue }

            if ($trimmed.StartsWith("|")) {
                if ($positionPending) {
                    $tableValue = ($trimmed -replace '[|''"\s]', '')
                    if ($tableValue) { $positionTableRows++ }
                    if ($positionTableRows -ge 2) { $hasReliablePosition = $true }
                }
                continue
            }

            if ($line -match $stepPattern -and $line.IndexOf($currentRowPhrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                if (-not $hasReliablePosition) {
                    $warnings.Add([pscustomobject][ordered]@{
                        code = "ITL_VANESSA_LINT_CURRENT_ROW"
                        path = $relativePath
                        line = $index + 1
                        message = "Current-row selection has no immediately preceding concrete row/key positioning."
                    })
                }
                $positionPending = $false
                $positionTableRows = 0
                $hasReliablePosition = $false
                continue
            }
            if ($warnings.Count -ge $MaxWarnings) { break }

            $isPositionStep = $false
            foreach ($phrase in $positionPhrases) {
                if ($line -match $stepPattern -and $line.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $isPositionStep = $true
                    break
                }
            }
            if ($isPositionStep) {
                $positionPending = $trimmed.EndsWith(":")
                $positionTableRows = 0
                $hasReliablePosition = -not $positionPending -and (
                    $quotedValuePattern.Matches($line).Count -gt 0 -or
                    $line -match '\$[^$]+\$|<[^>]+>'
                )
            } else {
                $positionPending = $false
                $positionTableRows = 0
                $hasReliablePosition = $false
            }

            if ($line -match $pausePattern) {
                $previousLine = $(if ($index -gt 0) { [string]$lines[$index - 1] } else { "" })
                if ($previousLine -notmatch '^\s*#\s*\S.{5,}\s*$') {
                    $warnings.Add([pscustomobject][ordered]@{
                        code = "ITL_VANESSA_LINT_BLIND_PAUSE"
                        path = $relativePath
                        line = $index + 1
                        message = "Blind pause has no immediate explanatory comment; prefer an observable-state wait."
                    })
                }
            }
        }
    }
    return @($warnings)
}

function Write-VanessaAuthoringLintWarnings {
    param([Parameter(Mandatory = $true)][object[]]$FeatureRecords)

    try {
        $warnings = @(Get-VanessaAuthoringLintWarnings -FeatureRecords $FeatureRecords -MaxWarnings 21)
    } catch {
        Write-Warning "Vanessa authoring lint [ITL_VANESSA_LINT_UNAVAILABLE]: source-only warnings could not be produced; verification continues."
        return
    }
    foreach ($warning in @($warnings | Select-Object -First 20)) {
        $safePath = ([string]$warning.path -replace '[\x00-\x1f\x7f]', "?")
        if ($safePath.Length -gt 240) { $safePath = $safePath.Substring(0, 240) }
        Write-Warning ("Vanessa authoring lint [{0}] {1}:{2}: {3}" -f $warning.code, $safePath, $warning.line, $warning.message)
    }
    if ($warnings.Count -gt 20) {
        Write-Warning "Vanessa authoring lint reached the 20-warning output limit; inspect the remaining changed .feature files locally."
    }
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

function Assert-VanessaVerificationPreflight {
    param([ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command", [string[]]$ExplicitComponents = @())

    $decision = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    if (-not $decision.run) { return }

    $featuresPath = Get-VanessaFeaturesPath
    $resolved = Resolve-ProjectPath $featuresPath
    if (-not (Test-Path -LiteralPath $resolved -ErrorAction SilentlyContinue)) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "/itl-verify-fix"
        throw "missing-suite: Vanessa testsPath was not found: $resolved"
    }

    $featureFiles = @(Get-VanessaFeatureFiles -FeaturePath $featuresPath)
    Assert-VanessaFeatureByteSafety -FeatureFiles $featureFiles

    $applicationFeatures = @(Get-VanessaApplicationFeatureFiles -FeaturePath $featuresPath)
    if ($applicationFeatures.Count -eq 0) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "/itl-verify-fix"
        throw "missing-suite: no application .feature files found under '$featuresPath'. Libraries do not count as product coverage."
    }

    $changed = @(Get-VanessaChangedFeatureRecords)
    if ($changed.Count -gt 0) {
        Write-VanessaAuthoringLintWarnings -FeatureRecords $changed
    }
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
        [int64]$StartOffset = 0,
        [int64]$EndOffset = -1
    )

    $reader = $null
    $sourceStream = $null
    $snapshotStream = $null
    $builder = New-Object System.Text.StringBuilder
    $depth = 0
    $inString = $false
    try {
        $sourceStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($EndOffset -lt 0) { $EndOffset = [int64]$sourceStream.Length }
        if ($StartOffset -lt 0 -or $EndOffset -lt $StartOffset -or $EndOffset -gt [int64]$sourceStream.Length) {
            throw "EVENT_LOG_SEGMENT_RANGE_INVALID: path=$Path; start=$StartOffset; end=$EndOffset; length=$($sourceStream.Length)"
        }

        [void]$sourceStream.Seek($StartOffset, [System.IO.SeekOrigin]::Begin)
        $snapshotLength = [int64]$EndOffset - $StartOffset
        $snapshotStream = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 65536
        $remaining = $snapshotLength
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $sourceStream.Read($buffer, 0, $requested)
            if ($read -le 0) {
                throw "EVENT_LOG_SEGMENT_RANGE_CHANGED: path=$Path; start=$StartOffset; end=$EndOffset; remaining=$remaining"
            }
            $snapshotStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $snapshotStream.Position = 0
        $reader = New-Object System.IO.StreamReader($snapshotStream, [System.Text.Encoding]::UTF8, $true)
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
        elseif ($null -ne $snapshotStream) { $snapshotStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }

    if ($depth -ne 0) {
        throw "Incomplete bracket record in 1C event log segment: $Path"
    }
}

function Get-OneCBracketTopLevelFields {
    param([string]$Text)

    $source = ([string]$Text).Trim()
    if ($source.Length -lt 2 -or $source[0] -ne '{' -or $source[$source.Length - 1] -ne '}') {
        throw "Invalid bracket record in 1C event log."
    }

    $rawFields = New-Object System.Collections.ArrayList
    $builder = New-Object System.Text.StringBuilder
    $nestedDepth = 0
    $inString = $false
    for ($index = 1; $index -lt ($source.Length - 1); $index++) {
        $character = $source[$index]
        if ($inString) {
            [void]$builder.Append($character)
            if ($character -eq '"') {
                if (($index + 1) -lt ($source.Length - 1) -and $source[$index + 1] -eq '"') {
                    [void]$builder.Append($source[$index + 1])
                    $index++
                } else {
                    $inString = $false
                }
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
            continue
        }
        if ($character -eq '{') {
            $nestedDepth++
            [void]$builder.Append($character)
            continue
        }
        if ($character -eq '}') {
            if ($nestedDepth -le 0) {
                throw "Invalid nested bracket depth in 1C event log record."
            }
            $nestedDepth--
            [void]$builder.Append($character)
            continue
        }
        if ($character -eq ',' -and $nestedDepth -eq 0) {
            [void]$rawFields.Add($builder.ToString().Trim())
            [void]$builder.Clear()
            continue
        }
        [void]$builder.Append($character)
    }
    if ($inString -or $nestedDepth -ne 0) {
        throw "Incomplete top-level field in 1C event log record."
    }
    [void]$rawFields.Add($builder.ToString().Trim())

    return @($rawFields | ForEach-Object {
        $raw = [string]$_
        $quoted = $raw.Length -ge 2 -and $raw[0] -eq '"' -and $raw[$raw.Length - 1] -eq '"'
        [pscustomobject]@{
            raw = $raw
            quoted = $quoted
            value = $(if ($quoted) { $raw.Substring(1, $raw.Length - 2).Replace('""', '"') } else { $raw })
        }
    })
}

function Read-OneCEventLogDictionary {
    param([string]$Path)

    $eventNames = @{}
    $metadataNames = @{}
    $processRecord = {
        param($record)
        $fields = @(Get-OneCBracketTopLevelFields -Text $record)
        if ($fields.Count -eq 3 -and [string]$fields[0].value -eq "4") {
            $eventNames[[string]$fields[2].value] = [string]$fields[1].value
        } elseif ($fields.Count -eq 4 -and [string]$fields[0].value -eq "5") {
            $metadataNames[[string]$fields[3].value] = [string]$fields[2].value
        }
    }
    Invoke-OneCBracketRecordStream -Path $Path -OnRecord $processRecord
    return [pscustomobject]@{
        eventNames = $eventNames
        metadataNames = $metadataNames
    }
}

function Resolve-OneCEventLogDictionaryValue {
    param(
        [hashtable]$Values,
        [AllowNull()][string]$Key,
        [string]$FallbackPrefix
    )

    $normalizedKey = ([string]$Key).Trim()
    if (-not $normalizedKey -or $normalizedKey -eq "0") { return "" }
    if ($null -ne $Values -and $Values.ContainsKey($normalizedKey)) {
        return [string]$Values[$normalizedKey]
    }
    if ($normalizedKey -notmatch '^\d+$') { return $normalizedKey }
    return "$FallbackPrefix$normalizedKey"
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
        [object]$Dictionary = $null,
        [hashtable]$WantedLevels = $null,
        [Nullable[datetime]]$StartTime = $null,
        [Nullable[datetime]]$EndTime = $null
    )

    $fields = @(Get-OneCBracketTopLevelFields -Text $RecordText)
    if ($fields.Count -eq 0) {
        return $null
    }

    $date = ConvertFrom-OneCEventLogDate -Value ([string]$fields[0].value)
    if ($null -eq $date) {
        return $null
    }

    $sequential = $fields.Count -ge 13 -and (Normalize-OneCEventLogLevel -Value ([string]$fields[8].value))
    $level = if ($sequential) {
        Normalize-OneCEventLogLevel -Value ([string]$fields[8].value)
    } elseif ($fields.Count -ge 2) {
        Normalize-OneCEventLogLevel -Value ([string]$fields[1].value)
    } else { "" }
    if (-not $level) {
        throw "EVENT_LOG_RECORD_LEVEL_UNRESOLVED: $($RecordText.Substring(0, [Math]::Min(240, $RecordText.Length)))"
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

    $event = if ($sequential) {
        Resolve-OneCEventLogDictionaryValue `
            -Values $(if ($null -ne $Dictionary) { $Dictionary.eventNames } else { $null }) `
            -Key ([string]$fields[7].value) `
            -FallbackPrefix "event-id:"
    } elseif ($fields.Count -ge 3) { [string]$fields[2].value } else { "" }
    $comment = if ($sequential -and $fields.Count -ge 10) {
        [string]$fields[9].value
    } elseif ($fields.Count -ge 6) { [string]$fields[5].value } else { "" }
    $metadata = if ($sequential -and $fields.Count -ge 11) {
        Resolve-OneCEventLogDictionaryValue `
            -Values $(if ($null -ne $Dictionary) { $Dictionary.metadataNames } else { $null }) `
            -Key ([string]$fields[10].value) `
            -FallbackPrefix "metadata-id:"
    } elseif ($fields.Count -ge 4) { [string]$fields[3].value } else { "" }
    $dataPresentation = if ($sequential -and $fields.Count -ge 13) {
        [string]$fields[12].value
    } elseif ($fields.Count -ge 5) { [string]$fields[4].value } else { "" }

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

    $dictionary = Read-OneCEventLogDictionary -Path $lgfPath

    $wantedLevels = @{}
    foreach ($level in $Levels) {
        if ($level) {
            $wantedLevels[$level] = $true
        }
    }

    $events = New-Object System.Collections.ArrayList
    foreach ($file in $lgpFiles) {
        $startOffset = 0
        $endOffset = [int64]$file.Length
        if (@($SegmentSelections).Count -gt 0) {
            $selection = @($SegmentSelections | Where-Object { [string]$_.path -eq $file.FullName } | Select-Object -First 1)
            if ($selection.Count -gt 0) {
                $startOffset = [int64]$selection[0].startOffset
                $endOffset = [int64](Get-StateValue -State $selection[0] -Name "endOffset" -Default $endOffset)
            }
        }
        $processRecord = {
            param($record)
            $event = ConvertFrom-OneCEventLogRecord -RecordText $record -Dictionary $dictionary -WantedLevels $wantedLevels -StartTime $StartTime -EndTime $EndTime
            if ($null -eq $event) {
                return
            }
            [void]$events.Add($event)
        }
        Invoke-OneCBracketRecordStream -Path $file.FullName -OnRecord $processRecord -StartOffset $startOffset -EndOffset $endOffset
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
    $sourceKeyKind = "event-log-header"
    $sourceKey = try {
        Get-DevBranchEventLogSourceKey -State $State
    } catch {
        $sourceKeyKind = "provisional-path"
        $kind = [string](Get-StateValue -State $State -Name "infoBaseKind" -Default "file")
        $normalizedLogDirectory = (Resolve-Agent1cFullPath -Path $logDirectory).ToLowerInvariant()
        Get-StringSha256 -Value ("$kind|$normalizedLogDirectory|pending-event-log-header")
    }
    $cursor = [ordered]@{
        schemaVersion = 1
        sourceKey = $sourceKey
        sourceKeyKind = $sourceKeyKind
        capturedAt = (Get-Date).ToUniversalTime().ToString("o")
        activeSegment = $(if ($null -ne $active) { $active.Name } else { "" })
        segments = @($segments)
    }
    Write-Utf8TextAtomic -Path $Path -Value (($cursor | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    return $Path
}

function Get-DevBranchEventLogPendingCursorPath {
    param([object]$State)

    $safeName = [string](Get-StateValue -State $State -Name "safeDevBranchName" -Default "")
    if (-not $safeName) {
        $safeName = ConvertTo-SafeName ([string](Get-StateValue -State $State -Name "devBranchName" -Default "current"))
    }
    $stateProjectRoot = [string](Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    return (Join-Path $stateProjectRoot ".agent-1c\event-log-cursors\$safeName.pending.json")
}

function Read-DevBranchEventLogCursorInfo {
    param([string]$Path)

    $cursor = Read-Utf8Text -Path $Path | ConvertFrom-Json
    $capturedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$cursor.capturedAt, [ref]$capturedAt)) {
        throw "Event log cursor capturedAt is invalid: $Path"
    }
    return [pscustomobject]@{
        path = $Path
        sourceKey = [string]$cursor.sourceKey
        capturedAt = $capturedAt
        activeSegment = [string]$cursor.activeSegment
    }
}

function Ensure-DevBranchEventLogPendingCursor {
    param(
        [object]$State,
        [string]$Reason = "workflow-operation"
    )

    $path = Get-DevBranchEventLogPendingCursorPath -State $State
    $created = -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)
    if ($created) {
        New-DevBranchEventLogCursor -State $State -Path $path | Out-Null
        $previousCheck = [string](Get-StateValue -State $State -Name "lastVanessaEventLogCheckedUntil" -Default "")
        if ($previousCheck) {
            $baselineAtText = [string](Get-StateValue -State $State -Name "eventLogBaselineCreatedAt" -Default "")
            if (-not $baselineAtText) {
                $baselinePath = [string](Get-StateValue -State $State -Name "eventLogBaselinePath" -Default "")
                if ($baselinePath -and (Test-Path -LiteralPath $baselinePath -PathType Leaf -ErrorAction SilentlyContinue)) {
                    try { $baselineAtText = [string]((Read-Utf8Text -Path $baselinePath | ConvertFrom-Json).createdAt) } catch { $baselineAtText = "" }
                }
            }
            $baselineAt = [datetime]::MinValue
            if ($baselineAtText -and [datetime]::TryParse($baselineAtText, [ref]$baselineAt)) {
                $migrationCursor = Read-Utf8Text -Path $path | ConvertFrom-Json
                $physicalCapturedAt = [string]$migrationCursor.capturedAt
                $migrationCursor.capturedAt = $baselineAt.ToString("o")
                $migrationCursor | Add-Member -NotePropertyName fallbackRequired -NotePropertyValue $true -Force
                $migrationCursor | Add-Member -NotePropertyName boundaryKind -NotePropertyValue "baseline-migration" -Force
                $migrationCursor | Add-Member -NotePropertyName physicalCapturedAt -NotePropertyValue $physicalCapturedAt -Force
                Write-Utf8TextAtomic -Path $path -Value (($migrationCursor | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
            }
        }
    }
    $info = Read-DevBranchEventLogCursorInfo -Path $path
    $result = [pscustomobject]@{
        path = $info.path
        sourceKey = $info.sourceKey
        capturedAt = $info.capturedAt
        activeSegment = $info.activeSegment
        reason = $Reason
        created = $created
    }

    $statePath = [string](Get-StateValue -State $State -Name "statePath" -Default "")
    if ($statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        Update-DevBranchState -State $State -Updates @{
            eventLogPendingCursorPath = $path
            eventLogPendingCursorCreatedAt = $info.capturedAt.ToString("o")
            eventLogPendingCursorSourceKey = $info.sourceKey
            eventLogPendingCursorReason = $(if ($created) { $Reason } else { [string](Get-StateValue -State $State -Name "eventLogPendingCursorReason" -Default $Reason) })
        }
    }
    return $result
}

function Complete-DevBranchEventLogObservation {
    param(
        [object]$State,
        [ValidateSet("passed", "failed")][string]$Status,
        [string]$Fingerprint = "",
        [string]$ReportPath = ""
    )

    $path = Get-DevBranchEventLogPendingCursorPath -State $State
    $previous = $null
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        try { $previous = Read-DevBranchEventLogCursorInfo -Path $path } catch { $previous = $null }
    }
    New-DevBranchEventLogCursor -State $State -Path $path | Out-Null
    $current = Read-DevBranchEventLogCursorInfo -Path $path
    $updates = @{
        eventLogPendingCursorPath = $path
        eventLogPendingCursorCreatedAt = $current.capturedAt.ToString("o")
        eventLogPendingCursorSourceKey = $current.sourceKey
        eventLogPendingCursorReason = "verification-boundary"
        lastEventLogObservationStatus = $Status
        lastEventLogObservationStartedAt = $(if ($null -ne $previous) { $previous.capturedAt.ToString("o") } else { "" })
        lastEventLogObservationCompletedAt = $current.capturedAt.ToString("o")
    }
    if ($Status -eq "failed") {
        $updates["eventLogDebtStatus"] = "failed"
        $updates["eventLogDebtFingerprint"] = $Fingerprint
        $updates["eventLogDebtReportPath"] = $ReportPath
        $updates["eventLogDebtDetectedAt"] = $current.capturedAt.ToString("o")
    }
    return $updates
}

function Resolve-DevBranchEventLogDebt {
    param(
        [object]$State,
        [object]$Verification,
        [string]$Fingerprint,
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command"
    )

    $updates = @{}
    $newErrorCount = [int](Get-StateValue -State $Verification -Name "newErrorCount" -Default 0)
    if ([string]$Verification.status -eq "failed" -and $newErrorCount -gt 0) {
        $updates["eventLogDebtStatus"] = "failed"
        $updates["eventLogDebtFingerprint"] = $Fingerprint
        $updates["eventLogDebtReportPath"] = [string](Get-StateValue -State $Verification -Name "reportPath" -Default "")
        $updates["eventLogDebtDetectedAt"] = (Get-Date).ToString("o")
        return [pscustomobject]@{ verification = $Verification; updates = $updates }
    }

    $debtStatus = [string](Get-StateValue -State $State -Name "eventLogDebtStatus" -Default "")
    if ([string]$Verification.status -eq "passed" -and $debtStatus -eq "failed") {
        $debtFingerprint = [string](Get-StateValue -State $State -Name "eventLogDebtFingerprint" -Default "")
        if ($Trigger -ne "repair" -and $debtFingerprint -eq $Fingerprint) {
            $reportPath = [string](Get-StateValue -State $State -Name "eventLogDebtReportPath" -Default "")
            $Verification = [pscustomobject]@{
                status = "failed"
                reason = "A previous event-log failure remains unresolved for the same verification fingerprint. Change the verification scope or use /itl-verify-fix before accepting a clean retry. Previous evidence: $reportPath"
                reader = [string](Get-StateValue -State $Verification -Name "reader" -Default "")
                baselinePath = [string](Get-StateValue -State $Verification -Name "baselinePath" -Default "")
                reportPath = $reportPath
                newErrorCount = 0
                legacyErrorCount = [int](Get-StateValue -State $Verification -Name "legacyErrorCount" -Default 0)
                checkedUntil = Get-StateValue -State $Verification -Name "checkedUntil" -Default (Get-Date)
                scannedBytes = [int64](Get-StateValue -State $Verification -Name "scannedBytes" -Default 0)
                scanMode = [string](Get-StateValue -State $Verification -Name "scanMode" -Default "cursor")
            }
            $updates["eventLogDebtStatus"] = "failed"
            $updates["eventLogDebtFingerprint"] = $debtFingerprint
            $updates["eventLogDebtReportPath"] = $reportPath
        } else {
            $updates["eventLogDebtStatus"] = ""
            $updates["eventLogDebtFingerprint"] = ""
            $updates["eventLogDebtReportPath"] = ""
            $updates["eventLogDebtDetectedAt"] = ""
        }
    }
    return [pscustomobject]@{ verification = $Verification; updates = $updates }
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
        if ([bool](Get-StateValue -State $cursor -Name "fallbackRequired" -Default $false)) {
            Write-Host "[WARN] Event log cursor requests a one-time bounded fallback scan from its migration boundary."
            $mode = "fallback"
        }
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

function Get-OneCEventLogFileRangeSha256 {
    param(
        [string]$Path,
        [int64]$Offset,
        [int]$Length
    )

    if ($Length -le 0) { return (Get-StringSha256 -Value "") }
    $buffer = New-Object byte[] $Length
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -ne $Length) {
            throw "EVENT_LOG_SEGMENT_RANGE_CHANGED: path=$Path; offset=$Offset; expected=$Length; actual=$read"
        }
    } finally { $stream.Dispose() }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($buffer))).Replace("-", "").ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Test-OneCEventLogCompleteBoundary {
    param(
        [string]$Path,
        [int64]$EndOffset = -1
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($EndOffset -lt 0) { $EndOffset = [int64]$file.Length }
    if ($EndOffset -lt 0 -or $EndOffset -gt [int64]$file.Length) { return $false }
    if ($EndOffset -eq 0) { return $true }
    $length = [int][Math]::Min([int64]4096, $EndOffset)
    $offset = $EndOffset - $length
    $buffer = New-Object byte[] $length
    $stream = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
        $read = $stream.Read($buffer, 0, $buffer.Length)
    } finally { $stream.Dispose() }
    for ($index = $read - 1; $index -ge 0; $index--) {
        if ($buffer[$index] -in @(0x09, 0x0A, 0x0D, 0x20)) { continue }
        return $buffer[$index] -eq 0x7D
    }
    return $true
}

function Get-OneCEventLogSegmentProof {
    param(
        [System.IO.FileInfo]$File,
        [int64]$EndOffset = -1
    )

    if ($EndOffset -lt 0) { $EndOffset = [int64]$File.Length }
    if ($EndOffset -lt 0 -or $EndOffset -gt [int64]$File.Length) {
        throw "EVENT_LOG_SEGMENT_RANGE_INVALID: path=$($File.FullName); end=$EndOffset; length=$($File.Length)"
    }
    $probeLength = [int][Math]::Min([int64]4096, $EndOffset)
    $boundaryStart = $EndOffset - $probeLength
    return [ordered]@{
        creationTimeUtcTicks = [int64]$File.CreationTimeUtc.Ticks
        prefixLength = $probeLength
        prefixSha256 = Get-OneCEventLogFileRangeSha256 -Path $File.FullName -Offset 0 -Length $probeLength
        boundaryStart = $boundaryStart
        boundaryLength = $probeLength
        boundarySha256 = Get-OneCEventLogFileRangeSha256 -Path $File.FullName -Offset $boundaryStart -Length $probeLength
        completeBoundary = Test-OneCEventLogCompleteBoundary -Path $File.FullName -EndOffset $EndOffset
    }
}

function Test-OneCEventLogAppendOnlyChange {
    param(
        [System.IO.FileInfo]$File,
        [object]$Cached
    )

    $cachedLength = [int64](Get-StateValue -State $Cached -Name "length" -Default -1)
    if ($cachedLength -lt 0 -or [int64]$File.Length -le $cachedLength) { return $false }
    if (-not [bool](Get-StateValue -State $Cached -Name "completeBoundary" -Default $false)) { return $false }
    if (-not (Test-OneCEventLogCompleteBoundary -Path $File.FullName)) { return $false }
    if ([int64](Get-StateValue -State $Cached -Name "creationTimeUtcTicks" -Default -1) -ne [int64]$File.CreationTimeUtc.Ticks) { return $false }

    $prefixLength = [int](Get-StateValue -State $Cached -Name "prefixLength" -Default -1)
    $boundaryStart = [int64](Get-StateValue -State $Cached -Name "boundaryStart" -Default -1)
    $boundaryLength = [int](Get-StateValue -State $Cached -Name "boundaryLength" -Default -1)
    if ($prefixLength -lt 0 -or $boundaryStart -lt 0 -or $boundaryLength -lt 0 -or ($boundaryStart + $boundaryLength) -gt $cachedLength) { return $false }
    if ((Get-OneCEventLogFileRangeSha256 -Path $File.FullName -Offset 0 -Length $prefixLength) -ne [string](Get-StateValue -State $Cached -Name "prefixSha256" -Default "")) { return $false }
    if ((Get-OneCEventLogFileRangeSha256 -Path $File.FullName -Offset $boundaryStart -Length $boundaryLength) -ne [string](Get-StateValue -State $Cached -Name "boundarySha256" -Default "")) { return $false }
    return $true
}

function Test-OneCEventLogSegmentMayOverlapBaselineWindow {
    param(
        [System.IO.FileInfo]$File,
        [datetime]$StartTime
    )

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    if ($stem -match '^(?<date>\d{8})') {
        $segmentDate = [datetime]::MinValue
        if ([datetime]::TryParseExact(
            [string]$Matches.date,
            "yyyyMMdd",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$segmentDate
        )) {
            return $segmentDate.Date -ge $StartTime.Date
        }
    }

    return $File.LastWriteTime -ge $StartTime
}

function Read-DevBranchEventLogBaselineWithCache {
    param(
        [object]$State,
        [Nullable[datetime]]$StartTime = $null,
        [switch]$BestEffort
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    $sourceKey = Get-DevBranchEventLogSourceKey -State $State
    $cacheRoot = Get-DevBranchEventLogSignatureCacheRoot -State $State
    $cachePath = Join-Path $cacheRoot ($sourceKey + ".json")
    $cacheWindowStart = if ($null -ne $StartTime) { ([datetime]$StartTime).ToUniversalTime().ToString("o") } else { "" }
    $files = @(
        Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue |
            Where-Object { $null -eq $StartTime -or (Test-OneCEventLogSegmentMayOverlapBaselineWindow -File $_ -StartTime ([datetime]$StartTime)) } |
            Sort-Object Name
    )

    $cache = $null
    $cacheStatus = "rebuilt"
    if (Test-Path -LiteralPath $cachePath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $candidate = Read-Utf8Text -Path $cachePath | ConvertFrom-Json
            if ([int](Get-StateValue -State $candidate -Name "schemaVersion" -Default 0) -ne 2 -or
                [string](Get-StateValue -State $candidate -Name "sourceKey" -Default "") -ne $sourceKey) {
                throw "incompatible cache schema or source key"
            }
            if ([string](Get-StateValue -State $candidate -Name "windowStart" -Default "") -ne $cacheWindowStart) {
                Write-Host "Event log signature cache window changed; rebuilding the bounded source baseline."
            } else {
                $cache = $candidate
                $cacheStatus = "hit"
            }
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
    $scannedBytes = [int64]0
    $appendSegmentCount = 0
    $fullSegmentCount = 0
    $failures = @()
    foreach ($file in $files) {
        $cached = if ($cachedByName.ContainsKey($file.Name)) { $cachedByName[$file.Name] } else { $null }
        $appendOnly = $false
        try {
            $snapshot = Get-Item -LiteralPath $file.FullName -ErrorAction Stop
            $snapshotLength = [int64]$snapshot.Length
            $lastWrite = $snapshot.LastWriteTimeUtc.ToString("o")
            $unchanged = $null -ne $cached -and [int64]$cached.length -eq $snapshotLength -and [string]$cached.lastWriteTimeUtc -eq $lastWrite
            if ($unchanged) {
                $segments += $cached
                continue
            }

            if ($cacheStatus -eq "hit") { $cacheStatus = "updated" }
            $appendOnly = $null -ne $cached -and (Test-OneCEventLogAppendOnlyChange -File $snapshot -Cached $cached)
            if ($appendOnly) {
                $startOffset = [int64]$cached.length
                $events = @(Read-OneCEventLogDirect -State $State -StartTime $StartTime -Levels @("Error") -SegmentSelections @([pscustomobject]@{
                    path = $snapshot.FullName
                    startOffset = $startOffset
                    endOffset = $snapshotLength
                }))
                $signatures = @(
                    @($cached.signatures) + @($events | ForEach-Object { $_.signature }) |
                        Where-Object { $_ } |
                        Sort-Object -Unique
                )
                $errorCount = [int]$cached.errorCount + $events.Count
                $scanMode = "append"
                $scannedBytes += $snapshotLength - $startOffset
                $appendSegmentCount++
            } else {
                $events = @(Read-OneCEventLogDirect -State $State -StartTime $StartTime -Levels @("Error") -SegmentSelections @([pscustomobject]@{
                    path = $snapshot.FullName
                    startOffset = [int64]0
                    endOffset = $snapshotLength
                }))
                $signatures = @($events | ForEach-Object { $_.signature } | Where-Object { $_ } | Sort-Object -Unique)
                $errorCount = $events.Count
                $scanMode = "full"
                $scannedBytes += $snapshotLength
                $fullSegmentCount++
            }
            $proofFile = Get-Item -LiteralPath $snapshot.FullName -ErrorAction Stop
            $proof = Get-OneCEventLogSegmentProof -File $proofFile -EndOffset $snapshotLength
            if (-not [bool]$proof.completeBoundary) {
                throw "EVENT_LOG_SEGMENT_UNSAFE_BOUNDARY: full rescan did not reach a complete record boundary: $($file.FullName)"
            }
            $segments += [ordered]@{
                name = $snapshot.Name
                length = $snapshotLength
                lastWriteTimeUtc = $lastWrite
                errorCount = $errorCount
                signatureCount = $signatures.Count
                signatures = @($signatures)
                scanMode = $scanMode
                creationTimeUtcTicks = $proof.creationTimeUtcTicks
                prefixLength = $proof.prefixLength
                prefixSha256 = $proof.prefixSha256
                boundaryStart = $proof.boundaryStart
                boundaryLength = $proof.boundaryLength
                boundarySha256 = $proof.boundarySha256
                completeBoundary = $proof.completeBoundary
            }
        } catch {
            if (-not $BestEffort) { throw }
            $failure = [ordered]@{ segment = $file.FullName; error = $_.Exception.Message }
            $failures += $failure
            Write-Host "[WARN] Source event log segment was skipped; seed baseline remains usable: $($file.FullName). $($_.Exception.Message)"
            if ($appendOnly -and $null -ne $cached) {
                $segments += $cached
            }
        }
    }

    if ($cacheStatus -ne "hit") {
        New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
        $cachePayload = [ordered]@{
            schemaVersion = 2
            sourceKey = $sourceKey
            reader = "direct-stream"
            windowStart = $cacheWindowStart
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
        scannedBytes = $scannedBytes
        appendSegmentCount = $appendSegmentCount
        fullSegmentCount = $fullSegmentCount
        failedSegmentCount = $failures.Count
        failures = @($failures)
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
    $effectiveStartTime = $StartTime
    $effectiveEndTime = $EndTime
    if ($null -ne $delta -and $delta.mode -eq "cursor") {
        # The byte cursor is authoritative for segment selection, while a
        # skew-tolerant timestamp removes the deliberately repeated safe-tail
        # record without discarding a newly appended record whose 1C clock is
        # slightly behind the workflow clock.
        $effectiveStartTime = $(if ($null -ne $StartTime) { ([datetime]$StartTime).AddSeconds(-(Get-VanessaEventLogClockSkewSeconds)) } else { $null })
        $effectiveEndTime = $null
    }
    if ($reader -eq "auto" -or $reader -eq "direct") {
        try {
            $events = if ($null -ne $delta) {
                @(Read-OneCEventLogDirect -State $State -StartTime $effectiveStartTime -EndTime $effectiveEndTime -Levels $levels -SegmentSelections $delta.selections)
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

function Install-DevBranchEventLogSeedBaseline {
    param(
        [object]$State,
        [string]$SeedBaselinePath
    )

    if (-not (Test-Path -LiteralPath $SeedBaselinePath -PathType Leaf)) {
        throw "BRANCH_SEED_BASELINE_MISSING: $SeedBaselinePath"
    }
    $seedBaseline = Read-Utf8Text -Path $SeedBaselinePath | ConvertFrom-Json
    $signatures = @($seedBaseline.signatures | Where-Object { $_ } | Sort-Object -Unique)
    $baselinePath = Get-DevBranchEventLogBaselinePath -State $State
    $createdAt = (Get-Date).ToString("o")
    $baseline = [ordered]@{
        schemaVersion = 2
        createdAt = $createdAt
        reason = "source-seed"
        reader = [string]$seedBaseline.reader
        logDirectory = Join-Path (Resolve-InfoBasePath (Get-StateValue -State $State -Name "devBranchInfoBasePath")) "1Cv8Log"
        errorCount = [int]$seedBaseline.errorCount
        signatureCount = $signatures.Count
        signatures = $signatures
        durationMs = [int64]$seedBaseline.durationMs
        cache = [ordered]@{
            status = "seeded"
            path = [string]$seedBaseline.cache.path
            sourceKey = [string]$seedBaseline.cache.sourceKey
            segmentCount = [int]$seedBaseline.cache.segmentCount
        }
        seedBaselinePath = $SeedBaselinePath
    }
    Write-Utf8Text -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    $hash = Get-StringSha256 -Value (($signatures -join "`n"))
    Update-DevBranchState -State $State -Updates @{
        eventLogBaselinePath = $baselinePath
        eventLogBaselineCreatedAt = $createdAt
        eventLogBaselineReader = [string]$seedBaseline.reader
        eventLogBaselineErrorCount = [int]$seedBaseline.errorCount
        eventLogBaselineSignatureCount = $signatures.Count
        eventLogBaselineHash = $hash
        eventLogBaselineCacheStatus = "seeded"
        eventLogBaselineCachePath = [string]$seedBaseline.cache.path
        eventLogBaselineDurationMs = [int64]$seedBaseline.durationMs
        eventLogBaselineSegmentCount = [int]$seedBaseline.cache.segmentCount
        eventLogSeedBaselinePath = $SeedBaselinePath
    }
    Write-Host "Event log baseline installed from branch seed: $baselinePath"
    return (Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default ""))
}

function Initialize-DevBranchEventLogBaseline {
    param(
        [object]$State,
        [string]$SeedBaselinePath = ""
    )

    Write-Section "Initialize event log baseline"
    if ($SeedBaselinePath) {
        return (Install-DevBranchEventLogSeedBaseline -State $State -SeedBaselinePath $SeedBaselinePath)
    }
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
        [string]$CursorPath = "",
        [Nullable[datetime]]$BoundaryStartedAt = $null,
        [string]$CursorScope = "vanessa-only"
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
    $effectiveStartTime = if ($null -ne $BoundaryStartedAt) { [datetime]$BoundaryStartedAt } else { $RunStartedAt }
    $cursorInfo = $null
    if ($CursorPath) {
        try { $cursorInfo = Read-DevBranchEventLogCursorInfo -Path $CursorPath } catch { $cursorInfo = $null }
    }
    $readResult = Read-DevBranchEventLogErrors -State $stateWithBaseline -StartTime $effectiveStartTime -EndTime $endTime -CursorPath $CursorPath
    $checkedUntil = Get-Date

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
            startedAt = $effectiveStartTime.ToString("o")
            finishedAt = $RunFinishedAt.ToString("o")
            checkedUntil = $checkedUntil.ToString("o")
            reader = $readResult.reader
            baselinePath = $baselinePath
            cursor = [ordered]@{
                scope = $CursorScope
                sourceKey = $(if ($null -ne $cursorInfo) { $cursorInfo.sourceKey } else { "" })
                capturedAt = $(if ($null -ne $cursorInfo) { $cursorInfo.capturedAt.ToString("o") } else { "" })
                activeSegment = $(if ($null -ne $cursorInfo) { $cursorInfo.activeSegment } else { "" })
                scanMode = $readResult.scanMode
            }
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
        "1C event log contains $($newErrors.Count) new error signature(s) not present in the branch baseline. Scope: $CursorScope; scan mode: $($readResult.scanMode)."
    } else {
        "1C event log contains no new error signatures in scope '$CursorScope' from '$($effectiveStartTime.ToString("o"))'. Legacy suppressed errors: $legacyCount; scan mode: $($readResult.scanMode)."
    }

    return [pscustomobject]@{
        status = $status
        reason = $reason
        reader = $readResult.reader
        baselinePath = $baselinePath
        reportPath = $reportPath
        newErrorCount = $newErrors.Count
        legacyErrorCount = $legacyCount
        checkedUntil = $checkedUntil
        checkedFrom = $effectiveStartTime
        cursorScope = $CursorScope
        cursorSourceKey = $(if ($null -ne $cursorInfo) { $cursorInfo.sourceKey } else { "" })
        cursorCapturedAt = $(if ($null -ne $cursorInfo) { $cursorInfo.capturedAt } else { $null })
        cursorActiveSegment = $(if ($null -ne $cursorInfo) { $cursorInfo.activeSegment } else { "" })
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
        return (Join-NativeCommandLineArguments -Arguments @("/F", (Resolve-InfoBasePath $InfoBasePath)))
    }
    if ($InfoBaseKind -eq "server") {
        return (Join-NativeCommandLineArguments -Arguments @("/S", $InfoBasePath))
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

function Get-VanessaServiceInfoBasePath {
    param(
        [object]$State,
        [Parameter(Mandatory = $true)][string]$Generation
    )

    $saved = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default "")
    $savedSchema = [int](Get-StateValue -State $State -Name "vanessaServiceInfoBaseSchemaVersion" -Default 0)
    $savedGeneration = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseGeneration" -Default "")
    if ($savedSchema -ge 3 -and $savedGeneration -ceq $Generation -and
        -not [string]::IsNullOrWhiteSpace($saved)) {
        $resolvedSaved = Resolve-Agent1cFullPath -Path $saved
        $expected = Resolve-ProjectPath (".agent-1c/infobases/vanessa-service-" + $Generation)
        if (-not [string]::Equals($resolvedSaved, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "ITL_VANESSA_SERVICE_INFOBASE_PATH_INVALID: saved='$resolvedSaved' expected='$expected'."
        }
        return $resolvedSaved
    }
    if ($Generation -notmatch '^[a-f0-9]{32}$') {
        throw "ITL_VANESSA_SERVICE_INFOBASE_GENERATION_INVALID: '$Generation'."
    }
    return (Resolve-ProjectPath (".agent-1c/infobases/vanessa-service-" + $Generation))
}

function Get-VanessaSelectedScenarioCount {
    param(
        [string[]]$FeatureFiles,
        [string]$FilterTags = ""
    )

    $filters = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    $wanted = @{}
    foreach ($filter in $filters) { $wanted[$filter.ToLowerInvariant()] = $true }

    $count = 0
    foreach ($scenario in @(Get-VanessaFeatureScenarioDefinitions -FeatureFiles $FeatureFiles)) {
        if ($wanted.Count -gt 0) {
            $selected = $false
            foreach ($tag in @($scenario.tags)) {
                if ($wanted.ContainsKey(([string]$tag).ToLowerInvariant())) {
                    $selected = $true
                    break
                }
            }
            if (-not $selected) { continue }
        }
        if ($scenario.isOutline) {
            $count += $scenario.exampleRows.Count
        } else {
            $count++
        }
    }
    return $count
}

function Get-VanessaServiceInfoBaseTemplate {
    $assetRoot = Resolve-Agent1cFullPath -Path (Join-Path $PSScriptRoot "..\..\assets\vanessa-service")
    $manifestPath = Join-Path $assetRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ITL_VANESSA_SERVICE_INFOBASE_TEMPLATE_MANIFEST_MISSING: '$manifestPath'."
    }
    try {
        $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    } catch {
        throw "ITL_VANESSA_SERVICE_INFOBASE_TEMPLATE_MANIFEST_INVALID: '$manifestPath': $($_.Exception.Message)"
    }
    $artifactName = [string](Get-StateValue -State $manifest -Name "artifact" -Default "")
    $expectedSha256 = [string](Get-StateValue -State $manifest -Name "sha256" -Default "")
    $user = [string](Get-StateValue -State $manifest -Name "serviceUser" -Default "")
    if ([int](Get-StateValue -State $manifest -Name "schemaVersion" -Default 0) -ne 1 -or
        $artifactName -cne "service-infobase.dt" -or
        $expectedSha256 -notmatch '^[a-f0-9]{64}$' -or
        [string]::IsNullOrWhiteSpace($user) -or
        [bool](Get-StateValue -State $manifest -Name "passwordRequired" -Default $true) -or
        -not [bool](Get-StateValue -State $manifest -Name "unsafeActionProtectionDisabled" -Default $false)) {
        throw "ITL_VANESSA_SERVICE_INFOBASE_TEMPLATE_MANIFEST_INVALID: '$manifestPath' does not describe the qualified service template."
    }
    $artifactPath = Join-Path $assetRoot $artifactName
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ITL_VANESSA_SERVICE_INFOBASE_TEMPLATE_MISSING: '$artifactPath'."
    }
    $actualSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $expectedSha256) {
        throw "ITL_VANESSA_SERVICE_INFOBASE_TEMPLATE_HASH_MISMATCH: expected='$expectedSha256' actual='$actualSha256' path='$artifactPath'."
    }
    return [pscustomobject][ordered]@{
        path = $artifactPath
        sha256 = $actualSha256
        user = $user
        password = ""
    }
}

function Ensure-VanessaServiceInfoBase {
    param([Parameter(Mandatory = $true)][object]$State)

    $template = Get-VanessaServiceInfoBaseTemplate
    $savedSchema = [int](Get-StateValue -State $State -Name "vanessaServiceInfoBaseSchemaVersion" -Default 0)
    $savedGeneration = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseGeneration" -Default "")
    $savedTemplateSha256 = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseTemplateSha256" -Default "")
    $savedUser = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseUser" -Default "")
    $savedPath = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default "")
    $markerMatches = $false
    $savedPathIsOwned = $false
    if ($savedGeneration -match '^[a-f0-9]{32}$' -and -not [string]::IsNullOrWhiteSpace($savedPath)) {
        $expectedSavedPath = Resolve-ProjectPath (".agent-1c/infobases/vanessa-service-" + $savedGeneration)
        $savedPathIsOwned = [string]::Equals(
            (Resolve-Agent1cFullPath -Path $savedPath),
            $expectedSavedPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
    if ($savedPathIsOwned) {
        $savedMarkerPath = Join-Path (Resolve-Agent1cFullPath -Path $savedPath) ".itl-service-template.json"
        if (Test-Path -LiteralPath $savedMarkerPath -PathType Leaf -ErrorAction SilentlyContinue) {
            try {
                $savedMarker = Read-Utf8Text -Path $savedMarkerPath | ConvertFrom-Json
                $markerMatches = (
                    [int](Get-StateValue -State $savedMarker -Name "schemaVersion" -Default 0) -eq 1 -and
                    [string](Get-StateValue -State $savedMarker -Name "generation" -Default "") -ceq $savedGeneration -and
                    [string](Get-StateValue -State $savedMarker -Name "templateSha256" -Default "") -ceq $template.sha256 -and
                    [string](Get-StateValue -State $savedMarker -Name "serviceUser" -Default "") -ceq $template.user
                )
            } catch {
                $markerMatches = $false
            }
        }
    }
    $canReuse = ($savedSchema -ge 3 -and $savedGeneration -match '^[a-f0-9]{32}$' -and
        $savedTemplateSha256 -ceq $template.sha256 -and $savedUser -ceq $template.user -and
        $savedPathIsOwned -and $markerMatches)
    $generation = $(if ($canReuse) { $savedGeneration } else { [guid]::NewGuid().ToString("N") })
    $path = Get-VanessaServiceInfoBasePath -State $State -Generation $generation
    $databasePath = Join-Path $path "1Cv8.1CD"
    $created = $false
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) {
            $unexpected = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)
            if ($unexpected.Count -gt 0) {
                throw "ITL_VANESSA_SERVICE_INFOBASE_INVALID: '$path' exists without 1Cv8.1CD and is not empty. Move it aside and repeat the command."
            }
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        }

        $platformPath = Get-PlatformPath
        $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
        New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
        $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-vanessa-service-create-" -Extension ".log"
        $script:LastLogPath = $logPath
        $arguments = @(
            "CREATEINFOBASE",
            (New-FileInfoBaseConnectionString -Path $path),
            "/DisableStartupDialogs",
            "/Out", $logPath
        )
        Write-Host "Creating branch-local empty Vanessa service infobase: $path"
        Write-Host "1C command: $(ConvertTo-NativeCommandLineArgument $platformPath) $(Join-OneCCreateInfoBaseCommandLineArguments -Arguments $arguments)"
        $nativeArguments = @($arguments)
        $result = Invoke-WithOneCSessionAdmissionContext `
            -InfoBaseKind "file" `
            -InfoBasePath $path `
            -RequiredSessions 1 `
            -Purpose "vanessa-service-infobase-create" `
            -ScriptBlock {
                Invoke-NativeProcessAndWaitResult `
                    -FilePath $platformPath `
                    -Arguments $nativeArguments `
                    -OneCCreateInfoBaseSyntax `
                    -TimeoutSeconds 300
            }
        if ($result.timedOut -or $result.exitCode -ne 0 -or
            -not (Test-Path -LiteralPath $databasePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "ITL_VANESSA_SERVICE_INFOBASE_CREATE_FAILED: exitCode=$($result.exitCode) timedOut=$($result.timedOut) path='$path' log='$logPath'."
        }
        $created = $true
    }

    $restored = $false
    if ($created) {
        Write-Host "Restoring qualified Vanessa service infobase template: $($template.path)"
        try {
            Invoke-Designer `
                -InfoBasePath $path `
                -InfoBaseKind "file" `
                -User "" `
                -Password "" `
                -DesignerArgs @("/RestoreIB", $template.path) | Out-Null
        } catch {
            throw "ITL_VANESSA_SERVICE_INFOBASE_RESTORE_FAILED: path='$path' template='$($template.path)': $($_.Exception.Message)"
        }
        $marker = [ordered]@{
            schemaVersion = 1
            generation = $generation
            templateSha256 = $template.sha256
            serviceUser = $template.user
        }
        Write-Utf8TextAtomic `
            -Path (Join-Path $path ".itl-service-template.json") `
            -Value (($marker | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        $restored = $true
    }

    $savedKind = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseKind" -Default "")
    if ($created -or $savedKind -cne "file" -or [string]::IsNullOrWhiteSpace($savedPath) -or
        $savedSchema -lt 3 -or [string]::IsNullOrWhiteSpace($savedGeneration) -or
        $savedTemplateSha256 -cne $template.sha256 -or $savedUser -cne $template.user -or
        -not [string]::Equals((Resolve-Agent1cFullPath -Path $savedPath), $path, [System.StringComparison]::OrdinalIgnoreCase)) {
        Update-DevBranchState -State $State -Updates @{
            vanessaServiceInfoBaseKind = "file"
            vanessaServiceInfoBasePath = $path
            vanessaServiceInfoBaseGeneration = $generation
            vanessaServiceInfoBaseSchemaVersion = 3
            vanessaServiceInfoBaseTemplateSha256 = $template.sha256
            vanessaServiceInfoBaseUser = $template.user
            vanessaServiceInfoBaseUpdatedAt = (Get-Date).ToString("o")
        }
    }
    return [pscustomobject][ordered]@{
        kind = "file"
        path = $path
        generation = $generation
        created = $created
        restored = $restored
        templateSha256 = $template.sha256
        user = $template.user
        password = $template.password
    }
}

function New-VanessaExecutionFeaturePath {
    param(
        [string]$FeaturePath,
        [string]$RunDirectory,
        [object]$TestClientTopology
    )

    $resolvedFeaturePath = Resolve-ProjectPath $FeaturePath
    if ($null -eq $TestClientTopology -or [int]$TestClientTopology.requiredTestClientSlots -le 0) {
        return $resolvedFeaturePath
    }

    $profiles = @($TestClientTopology.profiles)
    if ($profiles.Count -eq 0) {
        return $resolvedFeaturePath
    }

    $genericOpenPattern = '^(?<indent>[^\S\r\n]*)(?:Дано|И|Когда|Тогда|Но)[^\S\r\n]+Я[^\S\r\n]+запускаю[^\S\r\n]+сценарий[^\S\r\n]+открытия[^\S\r\n]+TestClient[^\S\r\n]+или[^\S\r\n]+подключаю[^\S\r\n]+уже[^\S\r\n]+существующий[^\S\r\n]*$'
    $featureFiles = @(Get-VanessaFeatureFiles -FeaturePath $resolvedFeaturePath)
    $filesToNormalize = New-Object System.Collections.Generic.List[string]
    foreach ($featureFile in $featureFiles) {
        $hasGenericOpener = @([System.IO.File]::ReadAllLines($featureFile) | Where-Object {
            [regex]::IsMatch([string]$_, $genericOpenPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }).Count -gt 0
        if ($hasGenericOpener) {
            $filesToNormalize.Add($featureFile)
        }
    }
    if ($filesToNormalize.Count -eq 0) {
        return $resolvedFeaturePath
    }

    $defaultProfileName = [string]$profiles[0].name
    if ([string]::IsNullOrWhiteSpace($defaultProfileName) -or $defaultProfileName.Contains("'")) {
        throw "ITL_VANESSA_DEFAULT_TESTCLIENT_PROFILE_INVALID: the first TestClient profile must have a non-empty name without a single quote when a scenario uses the generic TestClient opener. Use an explicit named-profile step instead."
    }

    $stagedRoot = Join-Path $RunDirectory "execution-features"
    if (Test-Path -LiteralPath $resolvedFeaturePath -PathType Container) {
        Copy-Item -LiteralPath $resolvedFeaturePath -Destination $stagedRoot -Recurse -Force
        $stagedFeaturePath = $stagedRoot
    } else {
        New-Item -ItemType Directory -Force -Path $stagedRoot | Out-Null
        $stagedFeaturePath = Join-Path $stagedRoot (Split-Path -Leaf $resolvedFeaturePath)
        Copy-Item -LiteralPath $resolvedFeaturePath -Destination $stagedFeaturePath -Force
    }

    $normalizedCount = 0
    foreach ($sourceFeatureFile in @($filesToNormalize.ToArray())) {
        if (Test-Path -LiteralPath $resolvedFeaturePath -PathType Container) {
            $relativePath = $sourceFeatureFile.Substring($resolvedFeaturePath.Length).TrimStart([char[]]@('\', '/'))
            $stagedFeatureFile = Join-Path $stagedRoot $relativePath
        } else {
            $stagedFeatureFile = $stagedFeaturePath
        }
        $sourceLines = @([System.IO.File]::ReadAllLines($stagedFeatureFile))
        $normalizedLines = New-Object System.Collections.Generic.List[string]
        $changed = $false
        foreach ($sourceLine in $sourceLines) {
            $match = [regex]::Match([string]$sourceLine, $genericOpenPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $normalizedLines.Add($match.Groups['indent'].Value + "И в таблице клиентов тестирования я активизирую строку '$defaultProfileName'")
                $changed = $true
            }
            $normalizedLines.Add([string]$sourceLine)
        }
        if ($changed) {
            [System.IO.File]::WriteAllLines($stagedFeatureFile, $normalizedLines.ToArray(), [System.Text.UTF8Encoding]::new($false))
            $normalizedCount++
        }
    }

    Write-Host "Vanessa generic TestClient opener normalized to product profile '$defaultProfileName' in $normalizedCount execution feature file(s); sources were not modified."
    return $stagedFeaturePath
}

function New-VanessaParamsFile {
    param(
        [string]$FeaturePath,
        [string]$RunDirectory,
        [string]$StatusPath,
        [object]$State,
        [int]$TestPort,
        [string]$VanessaVersion = "",
        [object]$TestClientTopology = $null,
        [int[]]$TestPorts = @(),
        [string]$FilterTags = $VanessaFilterTags
    )

    $resolvedFeaturePath = New-VanessaExecutionFeaturePath `
        -FeaturePath $FeaturePath `
        -RunDirectory $RunDirectory `
        -TestClientTopology $TestClientTopology
    $infoBaseKind = Get-StateValue -State $State -Name "infoBaseKind" -Default (Get-InfoBaseKind)
    $infoBasePath = Require-Value "devBranchInfoBasePath" (Get-StateValue -State $State -Name "devBranchInfoBasePath")
    $windowSearchTimeout = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS" -Default 60) -Default 60
    $actionAttempts = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_ACTION_ATTEMPTS" -Default 3) -Default 3
    $clientStartupTimeout = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS" -Default 300) -Default 300
    $vanessaTextLogPath = Join-Path $RunDirectory "vanessa.log"
    $vanessaErrorsDirectory = Join-Path $RunDirectory "errors"

    $configuredTestClientRun = ($null -ne $TestClientTopology -and
        [int]$TestClientTopology.requiredTestClientSlots -gt 0 -and
        ([bool]$TestClientTopology.configured -or [bool](Get-StateValue -State $TestClientTopology -Name "requiresExtensionTestClient" -Default $false)))
    $scenarioSettings = [ordered]@{}
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90Y/RgtGM0KjQsNCz0LjQkNGB0YHQuNC90YXRgNC+0L3QvdC+")] = $false
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JjQvdGC0LXRgNCy0LDQu9CS0YvQv9C+0LvQvdC10L3QuNGP0KjQsNCz0LDQl9Cw0LTQsNC90L3Ri9C50J/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lw=")] = 0.1
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg=")] = $configuredTestClientRun
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JrQvtC70LjRh9C10YHRgtCy0L7QodC10LrRg9C90LTQn9C+0LjRgdC60LDQntC60L3QsA==")] = $windowSearchTimeout
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0JrQvtC70LjRh9C10YHRgtCy0L7Qn9C+0L/Ri9GC0L7QutCS0YvQv9C+0LvQvdC10L3QuNGP0JTQtdC50YHRgtCy0LjRjw==")] = $actionAttempts
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0J/QsNGD0LfQsNCf0YDQuNCe0YLQutGA0YvRgtC40LjQntC60L3QsA==")] = 0

    if ($null -eq $TestClientTopology) {
        $user = [string](Get-EnvValue -Name "IB_USER")
        $TestClientTopology = [pscustomobject][ordered]@{
            configured = $false
            path = "<legacy-default>"
            declaredTestClientCeiling = 1
            requiredTestClientSlots = 1
            requiresExtensionTestClient = $false
            profiles = @([pscustomobject][ordered]@{
                name = $(if ($user) { $user } else { "default" })
                user = $user
                password = [string](Get-EnvValue -Name "IB_PASSWORD")
                synonym = ""
                clientType = "Thin"
            })
        }
    }
    $profiles = @($TestClientTopology.profiles)
    $assignedPorts = @($TestPorts | Where-Object { $_ -gt 0 })
    if ($assignedPorts.Count -eq 0 -and $TestPort -gt 0) { $assignedPorts = @($TestPort) }
    if ($profiles.Count -gt $assignedPorts.Count) {
        throw "ITL_VANESSA_TESTCLIENT_PORTS_INSUFFICIENT: profiles=$($profiles.Count) ports=$($assignedPorts.Count)."
    }

    $testClientRecords = New-Object System.Collections.Generic.List[object]
    for ($profileIndex = 0; $profileIndex -lt $profiles.Count; $profileIndex++) {
        $profile = $profiles[$profileIndex]
        $testClientRecord = [ordered]@{}
        $testClientRecord[(ConvertFrom-Utf8Base64 "0JjQvNGP")] = [string]$profile.name
        $testClientRecord[(ConvertFrom-Utf8Base64 "0KHQuNC90L7QvdC40Lw=")] = [string]$profile.synonym
        $testClientRecord[(ConvertFrom-Utf8Base64 "0J/Rg9GC0YzQmtCY0L3RhNC+0LHQsNC30LU=")] = New-VanessaTestClientInfoBaseArg -InfoBaseKind $infoBaseKind -InfoBasePath $infoBasePath
        $testClientRecord[(ConvertFrom-Utf8Base64 "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA=")] = [int]$assignedPorts[$profileIndex]
        $testClientRecord[(ConvertFrom-Utf8Base64 "0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL")] = New-VanessaTestClientAdditionalParams -User ([string]$profile.user) -Password ([string]$profile.password)
        $testClientRecord[(ConvertFrom-Utf8Base64 "0KLQuNC/0JrQu9C40LXQvdGC0LA=")] = $(if ([string]$profile.clientType -eq "Thick") { ConvertFrom-Utf8Base64 "0KLQvtC70YHRgtGL0Lk=" } else { ConvertFrom-Utf8Base64 "0KLQvtC90LrQuNC5" })
        $testClientRecord[(ConvertFrom-Utf8Base64 "0JjQvNGP0JrQvtC80L/RjNGO0YLQtdGA0LA=")] = "localhost"
        $testClientRecord[(ConvertFrom-Utf8Base64 "UElE0JrQu9C40LXQvdGC0LDQotC10YHRgtC40YDQvtCy0LDQvdC40Y8=")] = 0
        $testClientRecords.Add($testClientRecord)
    }

    $testClientSettings = [ordered]@{}
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JfQsNC/0YPRgdC60LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0KHQnNCw0LrRgdC40LzQuNC30LjRgNC+0LLQsNC90L3Ri9C80J7QutC90L7QvA==")] = $true
    $testClientSettings[(ConvertFrom-Utf8Base64 "0KLQsNC50LzQsNGD0YLQl9Cw0L/Rg9GB0LrQsDHQoQ==")] = $clientStartupTimeout
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JfQsNC60YDRi9Cy0LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0J/RgNC40L3Rg9C00LjRgtC10LvRjNC90L4=")] = $true
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JrQsNGC0LDQu9C+0LPQpNCw0LnQu9C+0LLQktGL0LLQvtC00LDQodC70YPQttC10LHQvdGL0YXQodC+0L7QsdGJ0LXQvdC40Lk=")] = $RunDirectory
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JzQvtC00LDQu9GM0L3QvtC10J7QutC90L7Qn9GA0LjQl9Cw0L/Rg9GB0LrQtdCa0LvQuNC10L3RgtCw0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0K3RgtC+0J7RiNC40LHQutCw")] = $true
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JfQsNC60YDRi9GC0YxUZXN0Q2xpZW500J/QvtGB0LvQtdCX0LDQv9GD0YHQutCw0KHRhtC10L3QsNGA0LjQtdCy")] = $configuredTestClientRun
    $testClientSettings[(ConvertFrom-Utf8Base64 "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw==")] = @($testClientRecords.ToArray())

    $params = [ordered]@{}
    $params["Version"] = $VanessaVersion
    $params["Lang"] = "ru"
    $params["featurepath"] = $resolvedFeaturePath
    $applicationFeatureFiles = if (Test-Path -LiteralPath $resolvedFeaturePath -PathType Container) {
        @(Get-VanessaApplicationFeatureFiles -FeaturePath $resolvedFeaturePath)
    } else {
        @($resolvedFeaturePath)
    }
    $params["FeaturesToRun"] = @($applicationFeatureFiles)
    $params["projectpath"] = $script:ProjectRoot
    $params["gherkinlanguage"] = "ru"
    $params["createlogs"] = $true
    $params["logpath"] = $StatusPath
    $params["junitcreatereport"] = $true
    $params["junitpath"] = $RunDirectory
    $params["allurecreatereport"] = $false
    $params["logtotext"] = $true
    $params["logstepstotext"] = $true
    $params["logerrorstotext"] = $true
    $params["getactiveformdataonerror"] = $true
    $params["fulllog"] = $true
    $params["textlogname"] = $vanessaTextLogPath
    $params["texterrorslogname"] = $vanessaErrorsDirectory
    $params["maskpwdinlog"] = $true
    $params["outputloginconsole"] = $false
    $params["pendingequalfailed"] = $true
    $params["stoponerror"] = $configuredTestClientRun
    $params["NumberOfAttemptsToExecuteTheScript"] = 1
    $params["updatetreewhenscenariostarts"] = $false
    $params[(ConvertFrom-Utf8Base64 "0KDQsNC30YDQtdGI0LXQvdC+0JfQsNC/0YPRgdC60LDRgtGM0KLQvtC70YzQutC+0J7QtNC40L3QmtC70LjQtdC90YLQotC10YHRgtC40YDQvtCy0LDQvdC40Y8=")] = ([int]$TestClientTopology.requiredTestClientSlots -le 1)
    $portRangeValues = @($assignedPorts)
    if ($portRangeValues.Count -eq 0 -and $TestPort -gt 0) { $portRangeValues = @($TestPort) }
    $portRangeStart = [int]($portRangeValues | Measure-Object -Minimum).Minimum
    $portRangeEnd = [int]($portRangeValues | Measure-Object -Maximum).Maximum
    $params[(ConvertFrom-Utf8Base64 "0JTQuNCw0L/QsNC30L7QvdCf0L7RgNGC0L7QslRlc3RjbGllbnQ=")] = "$portRangeStart-$portRangeEnd"
    $params[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90LXQvdC40LXQodGG0LXQvdCw0YDQuNC10LI=")] = $scenarioSettings
    $params[(ConvertFrom-Utf8Base64 "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP")] = $testClientSettings
    $params[(ConvertFrom-Utf8Base64 "0JLRi9Cz0YDRg9C20LDRgtGM0KHRgtCw0YLRg9GB0JLRi9C/0L7Qu9C90LXQvdC40Y/QodGG0LXQvdCw0YDQuNC10LLQktCk0LDQudC7")] = $true
    $params[(ConvertFrom-Utf8Base64 "0J/Rg9GC0YzQmtCk0LDQudC70YPQlNC70Y/QktGL0LPRgNGD0LfQutC40KHRgtCw0YLRg9GB0LDQktGL0L/QvtC70L3QtdC90LjRj9Ch0YbQtdC90LDRgNC40LXQsg==")] = $StatusPath
    $params[(ConvertFrom-Utf8Base64 "0JfQsNCy0LXRgNGI0LjRgtGM0KDQsNCx0L7RgtGD0KHQuNGB0YLQtdC80Ys=")] = $true
    $params[(ConvertFrom-Utf8Base64 "0JLRi9C/0L7Qu9C90LjRgtGM0KHRhtC10L3QsNGA0LjQuA==")] = $true

    $normalizedFilterTags = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    if ($normalizedFilterTags.Count -gt 0) {
        # VA 1.2.043.28 JsonParams declares filtertags as the launch-setting array.
        # Gherkin stores tag names without the feature-file @ prefix; tags is metadata, not a launch alias.
        $params["filtertags"] = @($normalizedFilterTags)
    }

    $path = Join-Path $RunDirectory "VAParams.json"
    Write-Utf8Text -Path $path -Value (($params | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $path
}

function Protect-VanessaVerificationDiagnosticText {
    param(
        [string]$Text,
        [ValidateRange(80, 4000)][int]$MaxLength = 1500
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $safe = $Text -replace '\s+', ' '
    $safe = $safe -replace '(?i)\b(password|passwd|pwd|token|secret|authorization)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|\S+)', '$1=<redacted>'
    $safe = $safe -replace '(?i)\bBearer\s+\S+', 'Bearer <redacted>'
    $safe = $safe -replace '(?i)(://)[^/\s:@]+:[^@\s/]+@', '$1<redacted>@'
    $safe = $safe -replace '(?i)([?&](?:token|access_token|password|secret)=)[^&\s]+', '$1<redacted>'
    $safe = $safe -replace '(?i)(/(?:P|Password)\s+)(?:"[^"]*"|\S+)', '$1<redacted>'
    $safe = $safe -replace '(?i)\b(configuration|connectionString|infobase)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|\S+)', '$1=<redacted>'
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaxLength) {
        return ($safe.Substring(0, $MaxLength - 3) + "...")
    }
    return $safe
}

function Test-VanessaTestClientConnectionFailure {
    param([string]$Diagnostic)

    if ([string]::IsNullOrWhiteSpace($Diagnostic)) {
        return $false
    }
    $connectionFailure = $Diagnostic -match '(?i)(Не получилось подключить TestClient|Не удалось подключить клиент тестирования|(?:could not|failed to) connect (?:the )?TestClient)'
    $startupEvidence = $Diagnostic -match '(?i)(Прерывание по таймауту|connection timeout|PID(?:КлиентаТестирования)?\s*[:=]\s*0)'
    return ($connectionFailure -and $startupEvidence)
}

function New-VanessaTestClientStartupMonitor {
    param(
        [string]$RunDirectory,
        [string[]]$ProfileNames = @(),
        [ValidateRange(1, 120)][int]$ExitDetectionSeconds = 5
    )

    return [pscustomobject][ordered]@{
        runDirectory = Resolve-Agent1cFullPath -Path $RunDirectory
        profileNames = @($ProfileNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        exitDetectionSeconds = $ExitDetectionSeconds
        lastProbeAt = [DateTime]::MinValue
        candidates = @{}
        failure = $null
    }
}

function Test-VanessaTestClientStartupMonitor {
    param(
        [Parameter(Mandatory = $true)][object]$Monitor,
        [Parameter(Mandatory = $true)][object]$State,
        [int[]]$TestPorts = @(),
        [Parameter(Mandatory = $true)][string]$RunParamsPath
    )

    if ($null -ne $Monitor.failure -or @($Monitor.profileNames).Count -eq 0) {
        return ($null -ne $Monitor.failure)
    }
    $now = Get-Date
    if ($Monitor.lastProbeAt -ne [DateTime]::MinValue -and ($now - $Monitor.lastProbeAt).TotalMilliseconds -lt 750) {
        return $false
    }
    $Monitor.lastProbeAt = $now

    foreach ($file in @(Get-ChildItem -LiteralPath $Monitor.runDirectory -File -Filter "*.txt" -ErrorAction SilentlyContinue)) {
        $profileName = @($Monitor.profileNames | Where-Object {
            $file.BaseName -match ('^' + [regex]::Escape([string]$_) + '_\d{14}$')
        } | Select-Object -First 1)
        if ($profileName.Count -ne 1 -or $Monitor.candidates.ContainsKey($file.FullName)) { continue }
        $Monitor.candidates[$file.FullName] = [pscustomobject][ordered]@{
            profileName = [string]$profileName[0]
            outputPath = $file.FullName
            createdAt = $file.CreationTime
            processObserved = $false
            processId = 0
        }
    }
    if ($Monitor.candidates.Count -eq 0) { return $false }

    try {
        $processes = @(Get-OneCProcessInfo -RequireSuccess | Where-Object {
            Test-OneCVanessaTestProcessBelongsToRun -ProcessInfo $_ -State $State -TestPorts $TestPorts -RunParamsPath $RunParamsPath
        })
    } catch {
        return $false
    }
    foreach ($processInfo in $processes) {
        $commandLine = [string](Get-StateValue -State $processInfo -Name "commandLine" -Default "")
        $outputPath = Get-OneCCommandLineSwitchPath -CommandLine $commandLine -SwitchNames @("Out")
        if ([string]::IsNullOrWhiteSpace($outputPath)) { continue }
        try { $outputPath = Resolve-Agent1cFullPath -Path $outputPath } catch { continue }
        foreach ($candidatePath in @($Monitor.candidates.Keys)) {
            if ([string]::Equals([string]$candidatePath, $outputPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidate = $Monitor.candidates[$candidatePath]
                $candidate.processObserved = $true
                $candidate.processId = ConvertTo-IntOrDefault -Value (Get-StateValue -State $processInfo -Name "processId" -Default 0)
            }
        }
    }

    foreach ($candidate in @($Monitor.candidates.Values)) {
        if ($candidate.processObserved) { continue }
        if (($now - [DateTime]$candidate.createdAt).TotalSeconds -lt [int]$Monitor.exitDetectionSeconds) { continue }
        $identity = Get-OneCInfoBaseIdentity `
            -InfoBaseKind ([string](Get-StateValue -State $State -Name "infoBaseKind" -Default "file")) `
            -InfoBasePath ([string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default ""))
        $Monitor.failure = [pscustomobject][ordered]@{
            code = "ITL_VANESSA_TESTCLIENT_STARTUP_EXITED"
            profileName = [string]$candidate.profileName
            infoBaseKey = [string]$identity.key
            ports = @($TestPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
            outputPath = [string]$candidate.outputPath
            processObserved = $false
            processId = 0
            detectedAt = $now
            waitedSeconds = [Math]::Round(($now - [DateTime]$candidate.createdAt).TotalSeconds, 3)
        }
        return $true
    }
    return $false
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
                $caseSkippedNodes = @($case.SelectNodes('./*[local-name()="skipped"]'))
                $caseFailureNodes = @($case.SelectNodes('./*[local-name()="failure"]'))
                $caseErrorNodes = @($case.SelectNodes('./*[local-name()="error"]'))
                $caseSkipped = $caseSkippedNodes.Count -gt 0
                $caseFailure = $caseFailureNodes.Count -gt 0
                $caseError = $caseErrorNodes.Count -gt 0
                if ($caseSkipped) { $summary.skipped++ }
                $diagnosticParts = @()
                foreach ($failureNode in @($caseFailureNodes + $caseErrorNodes)) {
                    if ($failureNode.Attributes["message"]) {
                        $diagnosticParts += [string]$failureNode.Attributes["message"].Value
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$failureNode.InnerText)) {
                        $diagnosticParts += [string]$failureNode.InnerText
                    }
                }
                $summary.testCases += [pscustomobject][ordered]@{
                    name = $(if ($case.Attributes["name"]) { [string]$case.Attributes["name"].Value } else { "" })
                    className = $(if ($case.Attributes["classname"]) { [string]$case.Attributes["classname"].Value } else { "" })
                    skipped = $caseSkipped
                    failure = $caseFailure
                    error = $caseError
                    diagnostic = Protect-VanessaVerificationDiagnosticText -Text ($diagnosticParts -join " ")
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

function Assert-VanessaTagFilterJunitEvidence {
    param(
        [string]$RunDirectory,
        [int]$ExpectedScenarioCount,
        [string]$FilterTags
    )

    $normalizedTags = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    if ($normalizedTags.Count -eq 0) { return $null }
    $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
    if (-not $junit.found) {
        throw "ITL_VANESSA_TAG_FILTER_EVIDENCE_MISSING: filter=$($normalizedTags -join ',') expected=$ExpectedScenarioCount JUnit was not found."
    }
    if ([int]$junit.tests -ne $ExpectedScenarioCount) {
        throw "ITL_VANESSA_TAG_FILTER_COUNT_MISMATCH: filter=$($normalizedTags -join ',') expected=$ExpectedScenarioCount actual=$($junit.tests)."
    }
    return [pscustomobject][ordered]@{
        filterTags = @($normalizedTags)
        expectedScenarioCount = $ExpectedScenarioCount
        junitScenarioCount = [int]$junit.tests
        files = @($junit.files)
    }
}

function Assert-VanessaScenarioCountJunitEvidence {
    param(
        [string]$RunDirectory,
        [int]$ExpectedScenarioCount,
        [string]$FilterTags = ""
    )

    $normalizedTags = @(ConvertTo-VanessaTagFilterList -Value $FilterTags)
    $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
    if (-not $junit.found) {
        throw "ITL_VANESSA_SCENARIO_COUNT_EVIDENCE_MISSING: filter=$($normalizedTags -join ',') expected=$ExpectedScenarioCount JUnit was not found."
    }
    if ([int]$junit.tests -ne $ExpectedScenarioCount) {
        throw "ITL_VANESSA_SCENARIO_COUNT_MISMATCH: filter=$($normalizedTags -join ',') expected=$ExpectedScenarioCount actual=$($junit.tests). Library/export scenarios must not execute as application tests."
    }
    return [pscustomobject][ordered]@{
        filterTags = @($normalizedTags)
        expectedScenarioCount = $ExpectedScenarioCount
        junitScenarioCount = [int]$junit.tests
        files = @($junit.files)
    }
}

function Merge-VanessaScenarioCountDiagnostic {
    param(
        [Parameter(Mandatory = $true)][object]$Verification,
        [Parameter(Mandatory = $true)][string]$ScenarioCountReason
    )

    if ([string](Get-StateValue -State $Verification -Name "status" -Default "") -eq "failed") {
        $primaryReason = [string](Get-StateValue -State $Verification -Name "reason" -Default "")
        $Verification.reason = "$primaryReason Secondary scenario-count diagnostic: $ScenarioCountReason"
        return $Verification
    }

    return [pscustomobject]@{
        status = "failed"
        reason = $ScenarioCountReason
    }
}

function Get-VanessaVerificationStatus {
    param(
        [string]$RunDirectory,
        [string]$StatusPath
    )

    $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
    if ($junit.found) {
        if (($junit.failures + $junit.errors) -gt 0) {
            $failedCases = @($junit.testCases | Where-Object { $_.failure -or $_.error })
            $diagnostic = if ($failedCases.Count -gt 0) { [string]$failedCases[0].diagnostic } else { "" }
            $failureCategory = if (Test-VanessaTestClientConnectionFailure -Diagnostic $diagnostic) { "runner" } else { "" }
            $reason = "Vanessa JUnit report contains failures/errors: failures=$($junit.failures), errors=$($junit.errors)."
            if ($diagnostic) {
                $reason += " First failure: $diagnostic"
            }
            return [pscustomobject]@{
                status = "failed"
                reason = $reason
                failureCategory = $failureCategory
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

function Get-GitObjectIdForTreePath {
    param(
        [string]$Treeish,
        [string]$RepoPath
    )

    $normalized = ($RepoPath -replace "\\", "/").Trim("/")
    if (-not $normalized) {
        return ""
    }

    $treePath = "{0}:{1}" -f $Treeish, $normalized
    & git -C $script:ProjectRoot rev-parse --verify --quiet $treePath *> $null
    if ($LASTEXITCODE -ne 0) {
        return "<missing>"
    }

    $output = Get-GitOutput @("rev-parse", $treePath)
    if ($output) {
        return ([string]$output).Trim()
    }
    return "<missing>"
}

function Get-VerificationFingerprintScopePaths {
    return @(
        (Get-ExportPath),
        (Get-ExtensionsPath),
        (Get-VanessaFeaturesPath)
    )
}

function Get-VerificationWorkingTreeChangePaths {
    param([string[]]$PathSpec)

    if (Test-GitHasAnyCommit) {
        $tracked = @(Get-GitPathList -Arguments (@(
            "diff",
            "--name-only",
            "-z",
            "--no-renames",
            "--diff-filter=ACDMRTUXB",
            "HEAD",
            "--"
        ) + @($PathSpec)))
    } else {
        $tracked = @(Get-GitPathList -Arguments (@(
            "ls-files",
            "-z",
            "--cached",
            "--"
        ) + @($PathSpec)))
    }
    $untracked = @(Get-GitPathList -Arguments (@(
        "ls-files",
        "-z",
        "--others",
        "--exclude-standard",
        "--"
    ) + @($PathSpec)))

    $pathSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
    foreach ($repoPath in @($tracked) + @($untracked)) {
        if ([string]::IsNullOrWhiteSpace([string]$repoPath)) {
            continue
        }
        $normalized = ([string]$repoPath -replace "\\", "/").TrimStart("/")
        [void]$pathSet.Add($normalized)
    }

    [string[]]$sorted = @($pathSet)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function New-VerificationEffectiveTree {
    param([string[]]$ChangedPaths)

    $paths = @($ChangedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $hasHead = Test-GitHasAnyCommit
    if ($hasHead -and $paths.Count -eq 0) {
        return "HEAD"
    }

    $tempDirectory = [System.IO.Path]::GetTempPath()
    $indexPath = New-TimestampedFilePath -Directory $tempDirectory -Prefix "agent-1c-verification-index-" -Extension ".idx"
    $pathspecPath = New-TimestampedFilePath -Directory $tempDirectory -Prefix "agent-1c-verification-paths-" -Extension ".bin"
    $hadGitIndexFile = Test-Path Env:GIT_INDEX_FILE
    $previousGitIndexFile = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexPath
        if ($hasHead) {
            Invoke-Git @("read-tree", "HEAD")
        } else {
            Invoke-Git @("read-tree", "--empty")
        }
        if ($paths.Count -gt 0) {
            $pathspecText = (@($paths) -join ([string][char]0)) + [char]0
            [System.IO.File]::WriteAllText($pathspecPath, $pathspecText, (Get-Utf8Encoding))
            Invoke-Git @(
                "--literal-pathspecs",
                "add",
                "-A",
                "--force",
                "--pathspec-from-file=$pathspecPath",
                "--pathspec-file-nul"
            )
        }
        $tree = [string](Get-GitOutput @("write-tree"))
        if ([string]::IsNullOrWhiteSpace($tree)) {
            throw "Git did not return an effective verification tree."
        }
        return $tree.Trim()
    } finally {
        if ($hadGitIndexFile) {
            $env:GIT_INDEX_FILE = $previousGitIndexFile
        } else {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        }
        foreach ($temporaryPath in @($indexPath, "$indexPath.lock", $pathspecPath)) {
            if (Test-Path -LiteralPath $temporaryPath -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-VerificationFingerprint {
    $paths = @(Get-VerificationFingerprintScopePaths)
    $changedPaths = @(Get-VerificationWorkingTreeChangePaths -PathSpec $paths)
    $treeish = New-VerificationEffectiveTree -ChangedPaths $changedPaths
    $parts = @("v3")
    foreach ($path in $paths) {
        $normalized = ($path -replace "\\", "/").Trim("/")
        if ($normalized) {
            $parts += "$normalized=$(Get-GitObjectIdForTreePath -Treeish $treeish -RepoPath $normalized)"
        }
    }
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
        [object]$VerificationState = $null,
        [switch]$Allow,
        [switch]$ProceedOnWarn
    )

    $verification = if ($null -ne $VerificationState) { $VerificationState } else { Get-VerificationState -State $State }
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

    if ($ProceedOnWarn) {
        Write-Host "verificationPolicy=warn permits $Operation without an explicit override."
        return $false
    }

    throw "$Operation stopped because fresh passed Vanessa verification is missing. Run verify-dev-branch or rerun with explicit unverified override."
}

function Add-VanessaVerificationEvidenceUpdates {
    param(
        [hashtable]$Updates,
        [string]$Status,
        [string]$Reason,
        [string]$Commit,
        [string]$Fingerprint,
        [string]$ReportPath,
        [string]$LogPath,
        [switch]$RecordFullVerificationEvidence
    )

    if ($RecordFullVerificationEvidence) {
        $Updates["lastVerificationStatus"] = $Status
        $Updates["lastVerifiedCommit"] = $Commit
        $Updates["lastVerifiedFingerprint"] = $Fingerprint
        $Updates["lastVerifiedAt"] = (Get-Date).ToString("o")
        $Updates["lastVerifiedReportPath"] = $ReportPath
        $Updates["lastVerificationLogPath"] = $LogPath
        $Updates["lastVerificationReason"] = $Reason
        return
    }

    $Updates["lastVerificationStatus"] = "partial"
    $Updates["lastVerificationEvidenceKind"] = "diagnostic"
    $Updates["lastVerificationTrigger"] = "diagnostic"
    $Updates["lastVerificationSkippedComponents"] = @("full-suite")
    $Updates["lastVerificationReason"] = "Diagnostic Vanessa run status=$Status; it does not create full verification proof. $Reason"
    $Updates["lastVerifiedCommit"] = ""
    $Updates["lastVerifiedFingerprint"] = ""
    $Updates["lastVerifiedAt"] = (Get-Date).ToString("o")
    $Updates["lastVerifiedReportPath"] = ""
    $Updates["lastVerificationLogPath"] = ""
}

function Run-DevBranchTests {
    param(
        [switch]$RecordFullVerificationEvidence,
        [string]$EventLogCursorPath = "",
        [Nullable[datetime]]$EventLogBoundaryAt = $null,
        [string]$EventLogCursorScope = "vanessa-only"
    )

    if ($VerificationTrigger -eq "repair") {
        Get-ItlMatchingVerificationRepairSession | Out-Null
    }
    if ($VanessaFeaturePath -or $VanessaFilterTags) {
        $RecordFullVerificationEvidence = $false
    }
    Set-RunStage -Stage "vanessa.prepare" -Detail "Preparing Vanessa Automation verification."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "check-dev-branch"
    Assert-DevBranchExtensionInitialized -State $state -Operation "check-dev-branch"
    $state = Assert-DevBranchApplicationReady -State $state -Operation "Vanessa verification"
    Sync-DevBranchContextToDotEnv -State $state
    $serviceInfoBase = Ensure-VanessaServiceInfoBase -State $state
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    $state = Ensure-VanessaMcpInstalled -State $state

    Assert-VanessaSourceBuildArchiveMatchesActivePin
    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        throw "Vanessa Automation is not installed. Run install-vanessa-automation first."
    }

    $featuresPath = Get-VanessaFeaturesPath
    $featureFiles = @(Get-VanessaFeatureFiles -FeaturePath $featuresPath)
    if ($featureFiles.Count -eq 0) {
        throw "No Vanessa .feature files found under '$featuresPath'. Create tests in tests/features before running dev branch tests."
    }
    $applicationFeatureFiles = @(Get-VanessaApplicationFeatureFiles -FeaturePath $featuresPath)

    try {
        $testClientTopology = Get-VanessaTestClientTopology -FeatureFiles $applicationFeatureFiles -FilterTags $VanessaFilterTags
        $expectedScenarioCount = Get-VanessaSelectedScenarioCount -FeatureFiles $applicationFeatureFiles -FilterTags $VanessaFilterTags
        if ($expectedScenarioCount -le 0) {
            if (@(ConvertTo-VanessaTagFilterList -Value $VanessaFilterTags).Count -gt 0) {
                throw "ITL_VANESSA_TAG_FILTER_NO_SCENARIOS: filter='$VanessaFilterTags' selected no scenarios."
            }
            throw "ITL_VANESSA_APPLICATION_SCENARIOS_MISSING: no application scenarios were found outside the Libraries directory."
        }
    } catch {
        if ($_.Exception.Message -match '^ITL_VANESSA_TEST_FIXTURE_') {
            Set-RunFailureContext -Category "test-fixture" -RequiredAction "/itl-verify-fix"
        } else {
            Set-RunFailureContext -Category "runner"
        }
        throw
    }

    $testPortLeaseToken = [string](Get-StateValue -State $state -Name "vanessaTestPortLeaseToken" -Default "")
    if ([string]::IsNullOrWhiteSpace($testPortLeaseToken)) {
        $testPortLeaseToken = New-ItlManagedPortLeaseToken
        Update-DevBranchState -State $state -Updates @{ vanessaTestPortLeaseToken = $testPortLeaseToken }
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    }
    try {
        $testPortCount = [Math]::Max(1, @($testClientTopology.profiles).Count)
        $testPorts = @(Resolve-VanessaTestPorts -State $state -Count $testPortCount -LeaseToken $testPortLeaseToken)
        $testPort = [int]$testPorts[0]
    } catch {
        Set-RunFailureContext -Category "runner"
        throw
    }
    Update-DevBranchState -State $state -Updates @{
        vanessaTestPort = $testPort
        vanessaTestPorts = @($testPorts)
        vanessaTestPortLeaseToken = $testPortLeaseToken
        vanessaTestPortUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    Save-VanessaTestSettingsToDotEnv -Port $testPort
    Invoke-ForeignVanessaTestProcessPolicy -State $state -TestPort $testPort
    $state = Ensure-DevBranchEventLogBaseline -State $state
    Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "Vanessa verification preflight" | Out-Null

    $runDirectory = New-VanessaRunDirectory
    $statusPath = Join-Path $runDirectory "status.json"
    $runEventLogCursorPath = Join-Path $runDirectory "event-log-cursor.json"
    if ($EventLogCursorPath) {
        [System.IO.File]::Copy($EventLogCursorPath, $runEventLogCursorPath, $true)
        $externalCursorInfo = Read-DevBranchEventLogCursorInfo -Path $runEventLogCursorPath
        if ($null -eq $EventLogBoundaryAt) { $EventLogBoundaryAt = $externalCursorInfo.capturedAt }
    } else {
        New-DevBranchEventLogCursor -State $state -Path $runEventLogCursorPath | Out-Null
        $localCursorInfo = Read-DevBranchEventLogCursorInfo -Path $runEventLogCursorPath
        $EventLogBoundaryAt = $localCursorInfo.capturedAt
        $EventLogCursorScope = "vanessa-only"
    }
    $runCursorEvidence = Read-Utf8Text -Path $runEventLogCursorPath | ConvertFrom-Json
    $runCursorEvidence | Add-Member -NotePropertyName scope -NotePropertyValue $EventLogCursorScope -Force
    $runCursorEvidence | Add-Member -NotePropertyName boundaryAt -NotePropertyValue ([datetime]$EventLogBoundaryAt).ToString("o") -Force
    Write-Utf8TextAtomic -Path $runEventLogCursorPath -Value (($runCursorEvidence | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    $paramsPath = New-VanessaParamsFile `
        -FeaturePath $featuresPath `
        -RunDirectory $runDirectory `
        -StatusPath $statusPath `
        -State $state `
        -TestPort $testPort `
        -VanessaVersion $vanessa.version `
        -TestClientTopology $testClientTopology `
        -TestPorts $testPorts `
        -FilterTags $VanessaFilterTags
    Publish-Agent1cVanessaRunEvidence `
        -State $state `
        -TestPorts $testPorts `
        -RunParamsPath $paramsPath

    Write-Host "Vanessa Automation EPF: $($vanessa.epfPath)"
    Write-Host "Vanessa features: $(Resolve-ProjectPath $featuresPath)"
    Write-Host "Vanessa report directory: $runDirectory"
    Write-Host "Vanessa params: $paramsPath"
    Write-Host "Vanessa TestManager service infobase: $($serviceInfoBase.path)"
    Write-Host "Vanessa TestClient target infobase: $($state.devBranchInfoBasePath)"
    Write-Host "Vanessa TestClient profiles: $(@($testClientTopology.profiles).Count); manifest ceiling: $($testClientTopology.declaredTestClientCeiling); required by selected scenarios: $($testClientTopology.requiredTestClientSlots); ports: $($testPorts -join ',')"
    if ($VanessaFilterTags) {
        Write-Host "Vanessa tag filter: $VanessaFilterTags"
    }
    if (-not $RecordFullVerificationEvidence) {
        Write-Host "[WARN] Diagnostic-only Vanessa run: it does not create fresh full verification proof and cannot authorize result export or complete a repair session."
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
    $eventLogDebtUpdates = @{}
    $eventLogBoundaryUpdates = @{}
    $runnerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDurationMs = [int64]0
    $eventLogDurationMs = [int64]0
    $postProcessStopwatch = $null
    $testClientStartupMonitor = New-VanessaTestClientStartupMonitor `
        -RunDirectory $runDirectory `
        -ProfileNames @($testClientTopology.profiles | ForEach-Object { [string]$_.name })
    Write-Host "Vanessa test timeout: $timeoutSeconds seconds"
    try {
        Set-RunStage -Stage "vanessa.run" -Detail "Running TESTMANAGER and TESTCLIENT."
        $logPath = Invoke-Enterprise `
            -InfoBasePath $serviceInfoBase.path `
            -InfoBaseKind $serviceInfoBase.kind `
            -User $serviceInfoBase.user `
            -Password $serviceInfoBase.password `
            -EnterpriseArgs $enterpriseArgs `
            -TestClientPort $testPort `
            -ExpectedSessionCount 1 `
            -AdditionalSessionAdmissions @([pscustomobject]@{
                infoBaseKind = [string]$state.infoBaseKind
                infoBasePath = [string]$state.devBranchInfoBasePath
                requiredSessions = [int]$testClientTopology.requiredTestClientSlots
                expectedChildRole = "test-client"
                purpose = "vanessa-test-clients"
            }) `
            -SessionLimitRecovery {
                Stop-OneCInfoBaseSessionProcesses `
                    -InfoBaseKind $state.infoBaseKind `
                    -InfoBasePath $state.devBranchInfoBasePath `
                    -Reason "managed Vanessa verification admission" | Out-Null
            } `
            -TimeoutSeconds $timeoutSeconds `
            -CompletionProbe {
                $probeStatus = Get-VanessaVerificationStatus -RunDirectory $runDirectory -StatusPath $statusPath
                if ($probeStatus.status -in @("passed", "failed")) { return $true }
                return (Test-VanessaTestClientStartupMonitor -Monitor $testClientStartupMonitor -State $state -TestPorts $testPorts -RunParamsPath $paramsPath)
            } `
            -CompletionGraceSeconds 10 `
            -OnTimeout {
                Write-Host "[WARN] Vanessa verify exceeded timeout; stopping own TESTMANAGER/TESTCLIENT processes."
                Stop-OwnHungVanessaTestClients -State $state -TestPorts $testPorts -RunParamsPath $paramsPath
            }
        if ($null -ne $testClientStartupMonitor.failure) {
            $startupFailure = $testClientStartupMonitor.failure
            throw "$($startupFailure.code): profile='$($startupFailure.profileName)' infoBaseKey='$($startupFailure.infoBaseKey)' ports='$(@($startupFailure.ports) -join ',')' processObserved=$($startupFailure.processObserved) pid=$($startupFailure.processId) out='$($startupFailure.outputPath)' waitedSeconds=$($startupFailure.waitedSeconds). The TestClient /Out file was created, but no matching owned /TESTCLIENT process remained; the 300-second Vanessa connection timeout was not awaited."
        }
        $runnerStopwatch.Stop()
    } catch {
        if ($runnerStopwatch.IsRunning) { $runnerStopwatch.Stop() }
        Set-RunStage -Stage "vanessa.postprocess" -Detail "Cleaning up and reading verification evidence after a failed runner."
        $postProcessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $runFinishedAt = Get-Date
        $logPath = $script:LastLogPath
        Write-OneCVanessaProcessDiagnostics -State $state -TestPorts $testPorts -RunParamsPath $paramsPath -Context "Vanessa verify failed; active 1C process diagnostics"
        $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-OwnHungVanessaTestClients -State $state -TestPorts $testPorts -RunParamsPath $paramsPath
        $cleanupStopwatch.Stop(); $cleanupDurationMs = $cleanupStopwatch.ElapsedMilliseconds
        $eventLogReason = ""
        try {
            $eventLogStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $eventLogVerification = if ($script:ItlSkipEventLogForVerification) {
                [pscustomobject]@{ status = "skipped"; reason = "ITL_CHECK_EVENT_LOG=off skipped event-log verification."; reader = ""; baselinePath = ""; reportPath = ""; newErrorCount = 0; legacyErrorCount = 0; checkedUntil = $runFinishedAt; scannedBytes = 0; scanMode = "skipped" }
            } else {
                Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory -CursorPath $runEventLogCursorPath -BoundaryStartedAt $EventLogBoundaryAt -CursorScope $EventLogCursorScope
            }
            $eventLogStopwatch.Stop(); $eventLogDurationMs = $eventLogStopwatch.ElapsedMilliseconds
            if ($EventLogCursorScope -eq "lifecycle-pending" -and $eventLogVerification.status -ne "skipped") {
                $debtResult = Resolve-DevBranchEventLogDebt -State $state -Verification $eventLogVerification -Fingerprint $currentFingerprint -Trigger $(if ($VerificationTrigger) { $VerificationTrigger } else { "command" })
                $eventLogVerification = $debtResult.verification
                $eventLogDebtUpdates = $debtResult.updates
            }
            if ($EventLogCursorScope -eq "lifecycle-pending" -and $eventLogVerification.scanMode -notin @("failed", "skipped")) {
                $eventLogBoundaryUpdates = Complete-DevBranchEventLogObservation -State $state -Status $eventLogVerification.status -Fingerprint $currentFingerprint -ReportPath $eventLogVerification.reportPath
            }
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
        }
        Add-VanessaVerificationEvidenceUpdates -Updates $updates -Status "failed" -Reason $failureReason -Commit $currentCommit -Fingerprint $currentFingerprint -ReportPath $runDirectory -LogPath $logPath -RecordFullVerificationEvidence:$RecordFullVerificationEvidence
        if ($null -ne $eventLogVerification) {
            $updates["lastVanessaEventLogReader"] = $eventLogVerification.reader
            $updates["lastVanessaEventLogBaselinePath"] = $eventLogVerification.baselinePath
            $updates["lastVanessaEventLogNewErrorsPath"] = $eventLogVerification.reportPath
            $updates["lastVanessaEventLogNewErrorCount"] = $eventLogVerification.newErrorCount
            $updates["lastVanessaEventLogLegacyErrorCount"] = $eventLogVerification.legacyErrorCount
            $updates["lastVanessaEventLogCheckedUntil"] = $eventLogVerification.checkedUntil.ToString("o")
            $updates["lastVanessaEventLogScannedBytes"] = $eventLogVerification.scannedBytes
            $updates["lastVanessaEventLogScanMode"] = $eventLogVerification.scanMode
            $updates["lastVanessaEventLogCursorScope"] = [string](Get-StateValue -State $eventLogVerification -Name "cursorScope" -Default $EventLogCursorScope)
            $updates["lastVanessaEventLogCursorSourceKey"] = [string](Get-StateValue -State $eventLogVerification -Name "cursorSourceKey" -Default "")
            $updates["lastVanessaEventLogCursorCapturedAt"] = [string](Get-StateValue -State $eventLogVerification -Name "cursorCapturedAt" -Default $EventLogBoundaryAt)
        }
        foreach ($key in $eventLogDebtUpdates.Keys) { $updates[$key] = $eventLogDebtUpdates[$key] }
        foreach ($key in $eventLogBoundaryUpdates.Keys) { $updates[$key] = $eventLogBoundaryUpdates[$key] }
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
    $tagFilterEvidence = $null
    try {
        $scenarioCountEvidence = Assert-VanessaScenarioCountJunitEvidence `
            -RunDirectory $runDirectory `
            -ExpectedScenarioCount $expectedScenarioCount `
            -FilterTags $VanessaFilterTags
        if (@(ConvertTo-VanessaTagFilterList -Value $VanessaFilterTags).Count -gt 0) {
            $tagFilterEvidence = $scenarioCountEvidence
        }
    } catch {
        $verification = Merge-VanessaScenarioCountDiagnostic `
            -Verification $verification `
            -ScenarioCountReason $_.Exception.Message
    }
    try {
        $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-OwnVanessaTestProcessesAndAssert -State $state -TestPorts $testPorts -RunParamsPath $paramsPath
        Clear-Agent1cVanessaRunEvidence
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
            Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory -CursorPath $runEventLogCursorPath -BoundaryStartedAt $EventLogBoundaryAt -CursorScope $EventLogCursorScope
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
    if ($EventLogCursorScope -eq "lifecycle-pending" -and $eventLogVerification.status -ne "skipped" -and $eventLogVerification.scanMode -ne "failed") {
        $debtResult = Resolve-DevBranchEventLogDebt -State $state -Verification $eventLogVerification -Fingerprint $currentFingerprint -Trigger $(if ($VerificationTrigger) { $VerificationTrigger } else { "command" })
        $eventLogVerification = $debtResult.verification
        $eventLogDebtUpdates = $debtResult.updates
        $eventLogBoundaryUpdates = Complete-DevBranchEventLogObservation -State $state -Status $eventLogVerification.status -Fingerprint $currentFingerprint -ReportPath $eventLogVerification.reportPath
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
        lastVanessaTestPorts = @($testPorts)
        lastVanessaTestClientManifestPath = $testClientTopology.path
        lastVanessaTestClientProfileCount = @($testClientTopology.profiles).Count
        lastVanessaTestClientDeclaredCeiling = $testClientTopology.declaredTestClientCeiling
        lastVanessaTestClientRequiredSlots = $testClientTopology.requiredTestClientSlots
        lastVanessaTagFilterExpectedScenarioCount = $(if (@(ConvertTo-VanessaTagFilterList -Value $VanessaFilterTags).Count -gt 0) { $expectedScenarioCount } else { 0 })
        lastVanessaTagFilterActualScenarioCount = $(if ($null -ne $tagFilterEvidence) { $tagFilterEvidence.junitScenarioCount } else { 0 })
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
        lastVanessaEventLogCursorScope = [string](Get-StateValue -State $eventLogVerification -Name "cursorScope" -Default $EventLogCursorScope)
        lastVanessaEventLogCursorSourceKey = [string](Get-StateValue -State $eventLogVerification -Name "cursorSourceKey" -Default "")
        lastVanessaEventLogCursorCapturedAt = [string](Get-StateValue -State $eventLogVerification -Name "cursorCapturedAt" -Default $EventLogBoundaryAt)
        lastVanessaRunnerDurationMs = [int64]$runnerStopwatch.ElapsedMilliseconds
        lastVanessaCleanupDurationMs = $cleanupDurationMs
        lastVanessaEventLogDurationMs = $eventLogDurationMs
        lastVanessaPostProcessDurationMs = [int64]$postProcessStopwatch.ElapsedMilliseconds
    }
    foreach ($key in $eventLogDebtUpdates.Keys) { $updates[$key] = $eventLogDebtUpdates[$key] }
    foreach ($key in $eventLogBoundaryUpdates.Keys) { $updates[$key] = $eventLogBoundaryUpdates[$key] }
    Add-VanessaVerificationEvidenceUpdates -Updates $updates -Status $verification.status -Reason $verification.reason -Commit $currentCommit -Fingerprint $currentFingerprint -ReportPath $runDirectory -LogPath $logPath -RecordFullVerificationEvidence:$RecordFullVerificationEvidence
    Update-DevBranchState -State $state -Updates $updates

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
        if ($verification.status -eq "unknown") {
            Set-RunFailureContext -Category "runner"
            Write-OneCVanessaProcessDiagnostics -State $state -TestPorts $testPorts -RunParamsPath $paramsPath -Context "Vanessa verify produced no reliable JUnit/status; active 1C process diagnostics"
            Stop-OwnHungVanessaTestClients -State $state -TestPorts $testPorts -RunParamsPath $paramsPath
        } elseif ($eventLogVerification.status -eq "failed") {
            Set-RunFailureContext -Category "event-log" -RequiredAction "/itl-verify-fix"
        } elseif ([string](Get-StateValue -State $verification -Name "failureCategory" -Default "") -eq "runner") {
            Set-RunFailureContext -Category "runner" -RequiredAction "inspect-testclient-startup-diagnostics-and-repeat-original-command"
        } elseif ([string]$verification.reason -match '(?i)(undefined step|step.+not found|unsupported-step)') {
            Set-RunFailureContext -Category "unsupported-step" -RequiredAction "/itl-verify-fix"
        } elseif ([string]$verification.reason -match '(?i)(scenario context|scenario-context)') {
            Set-RunFailureContext -Category "scenario-context" -RequiredAction "/itl-verify-fix"
        } elseif ([string]$verification.reason -match '^ITL_VANESSA_TAG_FILTER_') {
            Set-RunFailureContext -Category "runner"
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

function Test-OneCCommandLineOutputBelongsToRun {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$RunParamsPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($RunParamsPath)) { return $false }
    $outputPath = Get-OneCCommandLineSwitchPath -CommandLine $CommandLine -SwitchNames @("Out")
    if ([string]::IsNullOrWhiteSpace($outputPath)) { return $false }
    try {
        $runDirectory = (Split-Path -Parent (Resolve-Agent1cFullPath -Path $RunParamsPath)).TrimEnd('\', '/')
        $resolvedOutputPath = Resolve-Agent1cFullPath -Path $outputPath
    } catch {
        return $false
    }
    $runPrefix = $runDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $resolvedOutputPath.StartsWith($runPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-OneCCommandLineTestPort {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return 0
    }

    $matches = [regex]::Matches(
        [string]$CommandLine,
        '(?i)(?:^|\s)-TPort(?=\s)\s+(?:"(?<quoted>\d+)"|(?<plain>\d+))(?=\s|$)'
    )
    if ($matches.Count -ne 1) {
        return 0
    }
    $match = $matches[0]
    $value = $(if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value } else { $match.Groups["plain"].Value })
    return (ConvertTo-IntOrDefault -Value $value -Default 0)
}

function Test-CommandLineContainsPort {
    param(
        [AllowNull()][string]$CommandLine,
        [int]$Port
    )

    if ($Port -le 0 -or [string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    return (Get-OneCCommandLineTestPort -CommandLine $CommandLine) -eq $Port
}

function Get-OneCCommandLineMcpPort {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return 0
    }

    $matches = [regex]::Matches(
        [string]$CommandLine,
        '(?i)(?:^|[;\s])mcpPort\s*=\s*(?<port>\d+)(?=;|\s|"|$)'
    )
    if ($matches.Count -ne 1) {
        return 0
    }
    $match = $matches[0]
    return (ConvertTo-IntOrDefault -Value $match.Groups["port"].Value -Default 0)
}

function Test-CommandLineContainsMcpPort {
    param(
        [AllowNull()][string]$CommandLine,
        [int]$Port
    )

    if ($Port -le 0) {
        return $false
    }
    return (Get-OneCCommandLineMcpPort -CommandLine $CommandLine) -eq $Port
}

function Test-CommandLineContainsVaParamsPath {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$ParamsPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ParamsPath)) {
        return $false
    }

    try {
        $expected = (Resolve-Agent1cFullPath -Path $ParamsPath).Replace('/', '\').ToLowerInvariant()
    } catch {
        return $false
    }
    $normalized = ([string]$CommandLine).Replace('/', '\').ToLowerInvariant()
    $marker = 'vaparams='
    $offset = 0
    while ($offset -lt $normalized.Length) {
        $index = $normalized.IndexOf($marker, $offset, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        $valueStart = $index + $marker.Length
        if (($normalized.Length - $valueStart) -ge $expected.Length -and
            $normalized.Substring($valueStart, $expected.Length) -ceq $expected) {
            $valueEnd = $valueStart + $expected.Length
            if ($valueEnd -eq $normalized.Length -or @(';', '"', ' ', "`t") -contains [string]$normalized[$valueEnd]) {
                return $true
            }
        }
        $offset = $valueStart
    }
    return $false
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

    $targetInfoBasePath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    $serviceInfoBasePath = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default $targetInfoBasePath)
    $infoBasePath = $(if ($commandLine -match '(?i)(?:^|\s)/TESTMANAGER(?=\s|$)') { $serviceInfoBasePath } else { $targetInfoBasePath })
    if (-not (Test-OneCCommandLineInfoBasePath -CommandLine $commandLine -InfoBasePath $infoBasePath)) {
        return $false
    }

    if ($RequireTestPort) {
        if ($TestPort -le 0 -or -not (Test-CommandLineContainsPort -CommandLine $commandLine -Port $TestPort)) {
            return $false
        }
    }

    return $true
}

function Test-OneCVanessaTestProcessBelongsToRun {
    param(
        [object]$ProcessInfo,
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @(),
        [string]$RunParamsPath
    )

    if ([string]::IsNullOrWhiteSpace($RunParamsPath) -or -not (Test-OneCVanessaTestProcess -ProcessInfo $ProcessInfo)) {
        return $false
    }
    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    if (-not (Test-OneCProcessBelongsToState -ProcessInfo $ProcessInfo -State $State)) {
        return $false
    }
    if ($commandLine -match '(?i)(?:^|\s)/TESTCLIENT(?=\s|$)') {
        $effectivePorts = @($TestPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        if ($effectivePorts.Count -eq 0) {
            return $false
        }
        $processPort = Get-OneCCommandLineTestPort -CommandLine $commandLine
        return ($processPort -gt 0 -and $effectivePorts -contains $processPort -and
            (Test-OneCCommandLineOutputBelongsToRun -CommandLine $commandLine -RunParamsPath $RunParamsPath))
    }
    if ($commandLine -match '(?i)(?:^|\s)/TESTMANAGER(?=\s|$)') {
        return (Test-CommandLineContainsVaParamsPath -CommandLine $commandLine -ParamsPath $RunParamsPath)
    }
    return $false
}

function Test-OneCVanessaTestProcessBelongsToState {
    param(
        [object]$ProcessInfo,
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @()
    )

    if (-not (Test-OneCVanessaTestProcess -ProcessInfo $ProcessInfo)) {
        return $false
    }

    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    if ($commandLine -match '(?i)(?:^|\s)/TESTCLIENT(?=\s|$)') {
        $effectivePorts = @($TestPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        if ($effectivePorts.Count -eq 0) {
            $effectivePorts = @(
                @(
                    @(Get-StateValue -State $State -Name "vanessaTestPorts" -Default @())
                    (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
                ) | ForEach-Object { ConvertTo-IntOrDefault -Value $_ -Default 0 } | Where-Object { $_ -gt 0 } | Select-Object -Unique
            )
        }
        if ($effectivePorts.Count -eq 0 -or -not (Test-OneCProcessBelongsToState -ProcessInfo $ProcessInfo -State $State)) {
            return $false
        }
        $processPort = Get-OneCCommandLineTestPort -CommandLine $commandLine
        return ($processPort -gt 0 -and $effectivePorts -contains $processPort)
    }

    return (Test-OneCProcessBelongsToState -ProcessInfo $ProcessInfo -State $State)
}

function Test-VanessaStateIdentityMatch {
    param(
        [object]$First,
        [object]$Second
    )

    foreach ($propertyName in @("stateProjectRoot", "worktreePath", "devBranchInfoBasePath")) {
        $firstPath = [string](Get-StateValue -State $First -Name $propertyName -Default "")
        $secondPath = [string](Get-StateValue -State $Second -Name $propertyName -Default "")
        if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
            return $false
        }
        try {
            if (-not [string]::Equals(
                (Resolve-Agent1cFullPath -Path $firstPath),
                (Resolve-Agent1cFullPath -Path $secondPath),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

function Format-OneCProcessInfo {
    param([object]$ProcessInfo)

    $pidValue = Get-StateValue -State $ProcessInfo -Name "processId" -Default ""
    $name = Get-StateValue -State $ProcessInfo -Name "name" -Default ""
    $workingSetMb = Get-StateValue -State $ProcessInfo -Name "workingSetMb" -Default ""
    $commandLine = Get-StateValue -State $ProcessInfo -Name "commandLine" -Default ""
    $commandLine = [regex]::Replace(
        [string]$commandLine,
        '(?i)(/(?:P|ConfigurationRepositoryP)\s+)(?:"(?:[^"]|"")*"|\S+)',
        '$1<hidden>'
    )
    return "PID=$pidValue NAME=$name WS=${workingSetMb}MB CMD=$commandLine"
}

function Get-ForeignVanessaTestProcesses {
    param(
        [object]$State,
        [int]$TestPort = 0,
        [switch]$RequireInspection
    )

    return @(Get-OneCProcessInfo -RequireSuccess:$RequireInspection | Where-Object {
        (Test-OneCVanessaTestProcess -ProcessInfo $_) -and
        -not (Test-OneCVanessaTestProcessBelongsToState -ProcessInfo $_ -State $State -TestPort $TestPort)
    })
}

function Test-VanessaTestPortOwnedByState {
    param(
        [object]$State,
        [int]$Port,
        [int]$ExcludeProcessId = 0
    )

    if ($Port -le 0) {
        return $false
    }

    foreach ($processInfo in Get-OneCProcessInfo -RequireSuccess) {
        if ($ExcludeProcessId -gt 0 -and
            (ConvertTo-IntOrDefault -Value (Get-StateValue -State $processInfo -Name "processId" -Default 0) -Default 0) -eq $ExcludeProcessId) {
            continue
        }
        if ((Test-OneCProcessBelongsToState -ProcessInfo $processInfo -State $State -TestPort $Port -RequireTestPort)) {
            return $true
        }
    }

    return $false
}

function Test-VanessaTestPortUsedByForeignProcess {
    param(
        [object]$State,
        [int]$Port,
        [int]$ExcludeProcessId = 0
    )

    if ($Port -le 0) {
        return $false
    }

    foreach ($processInfo in Get-OneCProcessInfo -RequireSuccess) {
        if ($ExcludeProcessId -gt 0 -and
            (ConvertTo-IntOrDefault -Value (Get-StateValue -State $processInfo -Name "processId" -Default 0) -Default 0) -eq $ExcludeProcessId) {
            continue
        }
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

    $ports = @{}
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            if (Test-VanessaStateIdentityMatch -First $state -Second $CurrentState) {
                continue
            }
            if (Get-StateValue -State $state -Name "closedAt" -Default "") {
                continue
            }

            $statePorts = @(
                @(Get-StateValue -State $state -Name "vanessaTestPorts" -Default @())
                (Get-StateValue -State $state -Name "vanessaTestPort" -Default 0)
            ) | ForEach-Object { ConvertTo-IntOrDefault -Value $_ -Default 0 } | Where-Object { $_ -gt 0 } | Select-Object -Unique
            foreach ($port in $statePorts) {
                $ports[[int]$port] = $true
            }
        } catch {
        }
    }

    return $ports
}

function Resolve-VanessaTestPorts {
    param(
        [object]$State,
        [int]$Count = 1,
        [string]$LeaseToken = ""
    )

    if ($Count -lt 1) { throw "Vanessa TestClient port count must be positive." }
    if ([string]::IsNullOrWhiteSpace($LeaseToken)) {
        $LeaseToken = [string](Get-StateValue -State $State -Name "vanessaTestPortLeaseToken" -Default "")
    }
    if ([string]::IsNullOrWhiteSpace($LeaseToken)) {
        $LeaseToken = New-ItlManagedPortLeaseToken
    }
    $reserved = Get-VanessaTestReservedPorts -CurrentState $State
    $savedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
    $range = Get-VanessaTestPortRange
    if (($range.end - $range.start + 1) -lt $Count) {
        throw "ITL_VANESSA_TESTCLIENT_PORT_RANGE_INSUFFICIENT: range=$($range.start)..$($range.end) required=$Count."
    }
    $ports = New-Object System.Collections.Generic.List[int]

    for ($index = 0; $index -lt $Count; $index++) {
        $suffix = $(if ($index -eq 0) { "" } else { "profile-$index" })
        $key = Get-ItlBranchManagedPortKey -Family "vanessa-testclient" -State $State -Suffix $suffix
        $preferred = if ($index -eq 0) { $savedPort } else { [int]$ports[0] + $index }
        if ($preferred -gt $range.end) { $preferred = 0 }
        $explicit = $(if ($index -eq 0) { $VanessaTestPort } else { 0 })
        $allocated = 0

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $lease = Resolve-ItlManagedPortLease `
                -Family "vanessa-testclient" `
                -Key $key `
                -Start $range.start `
                -End $range.end `
                -PreferredPort $preferred `
                -ExplicitPort $explicit `
                -ReservedPorts $reserved `
                -State $State `
                -Subject "Vanessa TestClient port" `
                -LeaseToken $LeaseToken
            $allocated = [int]$lease.port

            if (-not (Test-VanessaTestPortUsedByForeignProcess -State $State -Port $allocated)) {
                break
            }

            Release-ItlManagedPortAllocation -Family "vanessa-testclient" -Key $key -LeaseToken $LeaseToken
            if ($explicit -gt 0) {
                throw "Requested Vanessa TestClient port $explicit is already used by another branch 1C test process."
            }
            $reserved[$allocated] = $true
            $allocated = 0
        }
        if ($allocated -le 0) {
            throw "No free Vanessa TestClient port found in range $($range.start)..$($range.end). Stop another branch Vanessa run or override VANESSA_TEST_PORT_RANGE."
        }
        $ports.Add($allocated)
        $reserved[$allocated] = $true
    }

    return @($ports.ToArray())
}

function Resolve-VanessaTestPort {
    param([object]$State)

    $leaseToken = [string](Get-StateValue -State $State -Name "vanessaTestPortLeaseToken" -Default "")
    $ports = @(Resolve-VanessaTestPorts -State $State -Count 1 -LeaseToken $leaseToken)
    return [int]$ports[0]
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
        $foreign = @(Get-ForeignVanessaTestProcesses -State $State -TestPort $TestPort -RequireInspection)
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

    $remaining = @(Get-ForeignVanessaTestProcesses -State $State -TestPort $TestPort -RequireInspection)
    $details = ($remaining | ForEach-Object { Format-OneCProcessInfo -ProcessInfo $_ }) -join [Environment]::NewLine
    throw "Foreign Vanessa 1C processes did not stay quiet within $timeoutSeconds seconds. Active processes:$([Environment]::NewLine)$details"
}

function Stop-OwnHungVanessaTestClients {
    param(
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @(),
        [Parameter(Mandatory = $true)][string]$RunParamsPath
    )

    $ownClients = @(Get-OneCProcessInfo -RequireSuccess | Where-Object {
        Test-OneCVanessaTestProcessBelongsToRun -ProcessInfo $_ -State $State -TestPorts $TestPorts -RunParamsPath $RunParamsPath
    })

    foreach ($processInfo in $ownClients) {
        Write-Host "Stopping own hung Vanessa TESTMANAGER/TESTCLIENT process: $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
        Stop-Process -Id $processInfo.processId -Force -ErrorAction SilentlyContinue
    }
}

function Write-OneCVanessaProcessDiagnostics {
    param(
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @(),
        [string]$RunParamsPath = "",
        [string]$Context = "Vanessa process diagnostics"
    )

    Write-Host "${Context}:"
    $processes = @(Get-OneCProcessInfo | Where-Object { Test-OneCVanessaTestProcess -ProcessInfo $_ })
    if ($processes.Count -eq 0) {
        Write-Host "  No active 1C TESTMANAGER/TESTCLIENT/StartFeaturePlayer processes found."
        return
    }

    foreach ($processInfo in $processes) {
        $scope = if ($RunParamsPath -and (Test-OneCVanessaTestProcessBelongsToRun -ProcessInfo $processInfo -State $State -TestPorts $TestPorts -RunParamsPath $RunParamsPath)) {
            "current-run"
        } elseif (Test-OneCVanessaTestProcessBelongsToState -ProcessInfo $processInfo -State $State) {
            "own-branch"
        } else {
            "foreign"
        }
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
    $pendingCursor = Get-StateValue -State $State -Name "eventLogPendingCursorPath" -Default ""
    if ($pendingCursor) {
        Write-Host "${Indent}Event log pending cursor: $pendingCursor"
        Write-Host "${Indent}Event log pending boundary/reason: $(Get-StateValue -State $State -Name 'eventLogPendingCursorCreatedAt' -Default '<unknown>') / $(Get-StateValue -State $State -Name 'eventLogPendingCursorReason' -Default '<unknown>')"
    }
    if ([string](Get-StateValue -State $State -Name "eventLogDebtStatus" -Default "") -eq "failed") {
        Write-Host "${Indent}Event log debt: failed; fingerprint=$(Get-StateValue -State $State -Name 'eventLogDebtFingerprint' -Default '<unknown>'); evidence=$(Get-StateValue -State $State -Name 'eventLogDebtReportPath' -Default '<none>')"
    }
    $postProcessMs = Get-StateValue -State $State -Name "lastVanessaPostProcessDurationMs" -Default ""
    if ($postProcessMs -ne "") {
        Write-Host "${Indent}Last Vanessa runner/cleanup/event-log/post-process ms: $(Get-StateValue -State $State -Name 'lastVanessaRunnerDurationMs' -Default 0) / $(Get-StateValue -State $State -Name 'lastVanessaCleanupDurationMs' -Default 0) / $(Get-StateValue -State $State -Name 'lastVanessaEventLogDurationMs' -Default 0) / $postProcessMs"
        Write-Host "${Indent}Last event log scan mode/bytes: $(Get-StateValue -State $State -Name 'lastVanessaEventLogScanMode' -Default '<unknown>') / $(Get-StateValue -State $State -Name 'lastVanessaEventLogScannedBytes' -Default 0)"
        Write-Host "${Indent}Last event log cursor scope/source: $(Get-StateValue -State $State -Name 'lastVanessaEventLogCursorScope' -Default '<unknown>') / $(Get-StateValue -State $State -Name 'lastVanessaEventLogCursorSourceKey' -Default '<unknown>')"
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

function Test-VanessaMcpProcessBelongsToState {
    param(
        [object]$ProcessInfo,
        [object]$State
    )

    $expectedPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPid" -Default 0) -Default 0
    $expectedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPort" -Default 0) -Default 0
    $expectedStartText = [string](Get-StateValue -State $State -Name "vanessaMcpProcessStartTime" -Default "")
    $expectedExecutable = [string](Get-StateValue -State $State -Name "vanessaMcpExecutablePath" -Default "")
    $expectedCommand = [string](Get-StateValue -State $State -Name "vanessaMcpCommandLineIdentity" -Default "")
    $expectedInfoBase = [string](Get-StateValue -State $State -Name "vanessaMcpInfoBasePath" -Default "")
    $stateInfoBase = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default (Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default ""))
    if ($expectedPid -le 0 -or $expectedPort -le 0 -or
        [string]::IsNullOrWhiteSpace($expectedStartText) -or
        [string]::IsNullOrWhiteSpace($expectedExecutable) -or
        [string]::IsNullOrWhiteSpace($expectedCommand) -or
        [string]::IsNullOrWhiteSpace($expectedInfoBase) -or
        [string]::IsNullOrWhiteSpace($stateInfoBase)) {
        return $false
    }

    $actualPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $ProcessInfo -Name "processId" -Default 0) -Default 0
    $actualStartText = [string](Get-StateValue -State $ProcessInfo -Name "processStartTime" -Default "")
    $actualExecutable = [string](Get-StateValue -State $ProcessInfo -Name "executablePath" -Default "")
    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    if ($actualPid -ne $expectedPid -or [string]::IsNullOrWhiteSpace($actualStartText) -or
        -not [string]::Equals($actualExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    try {
        $expectedStart = [DateTimeOffset]::Parse($expectedStartText).UtcDateTime
        $actualStart = [DateTimeOffset]::Parse($actualStartText).UtcDateTime
        if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -ge 2) {
            return $false
        }
        if (-not [string]::Equals(
            (Resolve-Agent1cFullPath -Path $expectedInfoBase),
            (Resolve-Agent1cFullPath -Path $stateInfoBase),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }
    } catch {
        return $false
    }

    $canonicalCommand = "runMcp;mcpPort=$expectedPort"
    return (
        [string]::Equals($expectedCommand, $canonicalCommand, [System.StringComparison]::Ordinal) -and
        (Test-OneCCommandLineInfoBasePath -CommandLine $commandLine -InfoBasePath $expectedInfoBase) -and
        $commandLine -match '(?i)(?:^|/C|;)runMcp(?=;|\s|"|$)' -and
        (Test-CommandLineContainsMcpPort -CommandLine $commandLine -Port $expectedPort)
    )
}

function Get-OwnVanessaTestProcesses {
    param(
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @(),
        [string]$RunParamsPath = "",
        [switch]$RequireInspection
    )

    $processes = @(Get-OneCProcessInfo -RequireSuccess:$RequireInspection)
    if (-not [string]::IsNullOrWhiteSpace($RunParamsPath)) {
        return @($processes | Where-Object {
            Test-OneCVanessaTestProcessBelongsToRun -ProcessInfo $_ -State $State -TestPorts $TestPorts -RunParamsPath $RunParamsPath
        })
    }
    return @($processes | Where-Object {
        (Test-OneCVanessaTestProcess -ProcessInfo $_) -and
        (Test-OneCVanessaTestProcessBelongsToState -ProcessInfo $_ -State $State)
    })
}

function Get-VanessaTestProcessCategory {
    param([object]$ProcessInfo)

    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name "commandLine" -Default "")
    return $(if ($commandLine -match '(?i)/TESTCLIENT(?:\s|$)') { "TestClient" } else { "TestManager" })
}

function Stop-OwnVanessaTestProcesses {
    param(
        [object]$State,
        [Alias("TestPort")][int[]]$TestPorts = @(),
        [string]$RunParamsPath = "",
        [switch]$BranchWide
    )

    $targetInfoBasePath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    $serviceInfoBasePath = [string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default $targetInfoBasePath)
    $effectivePorts = @($TestPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($effectivePorts.Count -eq 0) {
        $effectivePorts = @(
            @(
                @(Get-StateValue -State $State -Name "vanessaTestPorts" -Default @())
                (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
            ) | ForEach-Object { ConvertTo-IntOrDefault -Value $_ -Default 0 } | Where-Object { $_ -gt 0 } | Select-Object -Unique
        )
    }
    if ([string]::IsNullOrWhiteSpace($targetInfoBasePath) -or [string]::IsNullOrWhiteSpace($serviceInfoBasePath)) {
        return [pscustomobject]@{
            stoppedTestManager = 0
            stoppedTestClient = 0
            remaining = @()
            errors = @("ownership-unverified: Vanessa TestManager service or TestClient target infobase path is missing")
        }
    }

    if (-not $BranchWide -and [string]::IsNullOrWhiteSpace($RunParamsPath)) {
        return [pscustomobject]@{
            stoppedTestManager = 0
            stoppedTestClient = 0
            remaining = @()
            errors = @("ownership-unverified: ordinary cleanup requires the current run VAParams path")
        }
    }
    if (-not $BranchWide -and $effectivePorts.Count -eq 0) {
        return [pscustomobject]@{
            stoppedTestManager = 0
            stoppedTestClient = 0
            remaining = @()
            errors = @("ownership-unverified: ordinary cleanup requires a positive Vanessa TestClient port")
        }
    }

    $before = @(if ($BranchWide) {
        Get-OwnVanessaTestProcesses -State $State -RequireInspection
    } else {
        Get-OwnVanessaTestProcesses -State $State -TestPorts $effectivePorts -RunParamsPath $RunParamsPath -RequireInspection
    })
    $errors = @()
    foreach ($processInfo in $before) {
        $category = Get-VanessaTestProcessCategory -ProcessInfo $processInfo
        Write-Host "Stopping own Vanessa $category process: $(Format-OneCProcessInfo -ProcessInfo $processInfo)"
        try {
            Stop-Process -Id ([int]$processInfo.processId) -Force -ErrorAction Stop
        } catch {
            $errors += "$category PID=$($processInfo.processId): $($_.Exception.Message)"
        }
    }

    if ($before.Count -gt 0) {
        Start-Sleep -Milliseconds 300
    }
    $remaining = @(if ($BranchWide) {
        Get-OwnVanessaTestProcesses -State $State -RequireInspection
    } else {
        Get-OwnVanessaTestProcesses -State $State -TestPorts $effectivePorts -RunParamsPath $RunParamsPath -RequireInspection
    })
    $remainingIds = @($remaining | ForEach-Object { [int]$_.processId })
    $stopped = @($before | Where-Object { $remainingIds -notcontains [int]$_.processId })
    return [pscustomobject]@{
        stoppedTestManager = @($stopped | Where-Object { (Get-VanessaTestProcessCategory -ProcessInfo $_) -eq "TestManager" }).Count
        stoppedTestClient = @($stopped | Where-Object { (Get-VanessaTestProcessCategory -ProcessInfo $_) -eq "TestClient" }).Count
        remaining = @($remaining)
        errors = @($errors)
    }
}

function Stop-OwnVanessaTestProcessesAndAssert {
    param(
        [object]$State,
        [Parameter(Mandatory = $true)][Alias("TestPort")][int[]]$TestPorts,
        [Parameter(Mandatory = $true)][string]$RunParamsPath
    )

    $result = Stop-OwnVanessaTestProcesses -State $State -TestPorts $TestPorts -RunParamsPath $RunParamsPath
    if ($result.remaining.Count -gt 0 -or $result.errors.Count -gt 0) {
        $details = @($result.remaining | ForEach-Object { Format-OneCProcessInfo -ProcessInfo $_ })
        $details += @($result.errors)
        throw "Branch-local Vanessa TESTMANAGER/TESTCLIENT cleanup failed:$([Environment]::NewLine)$($details -join [Environment]::NewLine)"
    }

    Write-Host "Branch-local Vanessa test process cleanup passed. Stopped TestManager: $($result.stoppedTestManager); TestClient: $($result.stoppedTestClient)"
}

function Invoke-InterruptedDevBranchVanessaRunCleanup {
    if (-not $InterruptedVanessaInfoBasePath -or -not $InterruptedVanessaRunParamsPath -or
        -not $InterruptedVanessaTestPorts) {
        throw "ITL_INTERRUPTED_VANESSA_EVIDENCE_INVALID: exact infobase, VAParams path, and TestClient ports are required."
    }
    $ports = @($InterruptedVanessaTestPorts -split ',' | ForEach-Object {
        $port = ConvertTo-IntOrDefault -Value $_ -Default 0
        if ($port -le 0 -or $port -gt 65535) {
            throw "ITL_INTERRUPTED_VANESSA_EVIDENCE_INVALID: invalid TestClient port '$($_)'."
        }
        $port
    } | Select-Object -Unique)
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "cleanup-interrupted-vanessa-run"
    $expectedInfoBase = Resolve-Agent1cFullPath -Path ([string](Get-StateValue -State $state -Name "vanessaServiceInfoBasePath" -Default (Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default "")))
    $evidenceInfoBase = Resolve-Agent1cFullPath -Path $InterruptedVanessaInfoBasePath
    if (-not [string]::Equals($expectedInfoBase, $evidenceInfoBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ITL_INTERRUPTED_VANESSA_EVIDENCE_INVALID: TestManager service infobase does not match current branch state."
    }
    $paramsPath = Resolve-Agent1cFullPath -Path $InterruptedVanessaRunParamsPath
    $projectPrefix = $script:ProjectRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $paramsPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $paramsPath -PathType Leaf)) {
        throw "ITL_INTERRUPTED_VANESSA_EVIDENCE_INVALID: VAParams path is missing or outside the current project."
    }
    Stop-OwnVanessaTestProcessesAndAssert -State $state -TestPorts $ports -RunParamsPath $paramsPath
}

function Get-VanessaInteractiveProfileStatePath {
    return (Join-Path $script:ProjectRoot ".agent-1c\vanessa-interactive-profile.json")
}

function Read-VanessaInteractiveProfileState {
    param([switch]$Strict)

    $path = Get-VanessaInteractiveProfileStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return (Read-Utf8Text -Path $path | ConvertFrom-Json)
    } catch {
        if ($Strict) {
            throw "ITL_VANESSA_PROFILE_STATE_INVALID path='$path' error='$($_.Exception.Message)'"
        }
        return $null
    }
}

function Write-VanessaInteractiveProfileState {
    param([Parameter(Mandatory = $true)][object]$ProfileState)

    $path = Get-VanessaInteractiveProfileStatePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $temporary = "$path.tmp-$PID"
    Write-Utf8Text -Path $temporary -Value (($ProfileState | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return $path
}

function Get-VanessaInteractiveProfileRuntimeInstances {
    param([Parameter(Mandatory = $true)][object]$State)

    $infoBasePath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    return @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
        [string]$_.family -eq "vanessa-ui" -and
        (Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $infoBasePath)
    })
}

function New-VanessaInteractiveProfileUserReport {
    param(
        [string]$Action,
        [string]$Status,
        [object]$State,
        [AllowNull()][object]$RuntimeState,
        [AllowNull()][object]$ProfileState,
        [AllowNull()][object]$ReleaseResult
    )

    $managerPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $RuntimeState -Name "pid" -Default 0) -Default 0
    $managerPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $RuntimeState -Name "port" -Default 0) -Default 0
    $testClientPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $RuntimeState -Name "testClientPid" -Default 0) -Default 0
    $testClientPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $RuntimeState -Name "testClientPort" -Default 0) -Default 0
    $connectionState = [string](Get-StateValue -State $ProfileState -Name "testClientState" -Default (Get-StateValue -State $RuntimeState -Name "testClientState" -Default "stopped"))
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        action = $Action
        status = $Status
        managerPid = $managerPid
        managerPort = $managerPort
        testClientPid = $testClientPid
        testClientPort = $testClientPort
        infoBase = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
        feature = [string](Get-StateValue -State $ProfileState -Name "featurePath" -Default "")
        connectionState = $connectionState
        persistentUntilExplicitStop = ($Status -eq "running")
        scenarioStarted = $false
        verificationVerdictProduced = $false
        stoppedTestManager = ConvertTo-IntOrDefault -Value (Get-StateValue -State $ReleaseResult -Name "stoppedTestManager" -Default 0) -Default 0
        stoppedTestClient = ConvertTo-IntOrDefault -Value (Get-StateValue -State $ReleaseResult -Name "stoppedTestClient" -Default 0) -Default 0
        stoppedVanessaUiBackend = ConvertTo-IntOrDefault -Value (Get-StateValue -State $ReleaseResult -Name "stoppedVanessaUiBackend" -Default 0) -Default 0
    }
}

function Publish-VanessaInteractiveProfileUserReport {
    param([Parameter(Mandatory = $true)][object]$Report)

    $json = $Report | ConvertTo-Json -Compress -Depth 10
    $script:RunUserReport = $json
    Write-Host "ITL_VANESSA_PROFILE_REPORT=$json"
    return $Report
}

function Invoke-ItlNativeProcessCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-NativeCommandLineArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Native process did not start: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = [string]$stdoutTask.Result
            stderr = [string]$stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Protect-ItlVanessaProfileDiagnosticText {
    param(
        [string]$Text,
        [ValidateRange(80, 4000)][int]$MaxLength = 3000
    )

    return Protect-VanessaVerificationDiagnosticText -Text $Text -MaxLength $MaxLength
}

function Get-ItlVanessaProfileBrokerLogPath {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $jsonMatch = [regex]::Match($Text, '(?i)"logPath"\s*:\s*"(?<path>(?:\\.|[^"])*)"')
    if ($jsonMatch.Success) {
        try {
            return ('"' + $jsonMatch.Groups["path"].Value + '"' | ConvertFrom-Json)
        } catch {
            return $jsonMatch.Groups["path"].Value
        }
    }
    $plainMatch = [regex]::Match($Text, '(?i)(?:brokerLog|logPath|log)\s*=\s*(?<path>.+?)\s*$')
    if ($plainMatch.Success) {
        return $plainMatch.Groups["path"].Value.Trim().Trim('"', "'")
    }
    return ""
}

function Get-ItlVanessaProfileFailureRequiredAction {
    param(
        [string]$Diagnostic,
        [string]$BrokerLogPath
    )

    if ($Diagnostic -match '(?i)(ITL_THIN_CLIENT_EXECUTABLE_MISSING|1cv8c\.exe.+not found)') {
        return "install-thin-client-and-retry-start-vanessa-profile"
    }
    if ($Diagnostic -match '(?i)license') {
        return "release-1c-license-and-retry-start-vanessa-profile"
    }
    if ($Diagnostic -match '(?i)(address already in use|port.+(?:busy|used))') {
        return "free-vanessa-port-and-retry-start-vanessa-profile"
    }
    if ($BrokerLogPath) {
        return "inspect-broker-log-and-retry-start-vanessa-profile"
    }
    return "retry-start-vanessa-profile"
}

function Read-ItlVanessaProfileSafeLogTail {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }
    try {
        return Protect-ItlVanessaProfileDiagnosticText -Text ((Get-Content -LiteralPath $Path -Tail 30 -ErrorAction Stop) -join " ")
    } catch {
        return ""
    }
}

function Invoke-ItlOnDemandVanessaProfileStart {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$FeaturePath
    )

    $executable = Get-ItlOnDemandMcpExecutablePath
    $definition = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
    $arguments = @(
        "vanessa-profile-start",
        "--project-root", $script:ProjectRoot,
        "--catalog", $definition.catalogPath,
        "--helper", $script:Agent1cScriptPath,
        "--instance-id", $InstanceId,
        "--feature", $FeaturePath
    )
    $processResult = Invoke-ItlNativeProcessCapture -FilePath $executable -Arguments $arguments
    if ($processResult.exitCode -ne 0) {
        $combined = @($processResult.stderr, $processResult.stdout) -join " "
        $brokerLogPath = Get-ItlVanessaProfileBrokerLogPath -Text $combined
        $diagnostic = Protect-ItlVanessaProfileDiagnosticText -Text $combined
        $logTail = Read-ItlVanessaProfileSafeLogTail -Path $brokerLogPath
        if ($logTail) {
            $diagnostic = Protect-ItlVanessaProfileDiagnosticText -Text "$diagnostic brokerLogTail=$logTail"
        }
        $requiredAction = Get-ItlVanessaProfileFailureRequiredAction -Diagnostic $diagnostic -BrokerLogPath $brokerLogPath
        Set-RunFailureContext -Category "runner" -RequiredAction $requiredAction
        $safeLogPath = Protect-ItlVanessaProfileDiagnosticText -Text $brokerLogPath -MaxLength 600
        throw "ITL_VANESSA_PROFILE_START_FAILED: exitCode=$($processResult.exitCode); requiredAction=$requiredAction; retryAction=start-vanessa-profile; brokerLog=$safeLogPath; cause=$diagnostic"
    }
    $marker = "ITL_VANESSA_PROFILE_RESULT="
    $line = @(([string]$processResult.stdout -split "`r?`n") | Where-Object {
        $_.StartsWith($marker, [System.StringComparison]::Ordinal)
    } | Select-Object -Last 1)
    if ($line.Count -ne 1) {
        $diagnostic = Protect-ItlVanessaProfileDiagnosticText -Text $processResult.stderr
        throw "ITL_VANESSA_PROFILE_START_FAILED: facade did not return a structured result on stdout; stderr=$diagnostic"
    }
    try {
        return ($line[0].Substring($marker.Length) | ConvertFrom-Json)
    } catch {
        throw "ITL_VANESSA_PROFILE_START_FAILED: facade returned invalid JSON. $($_.Exception.Message)"
    }
}

function Resolve-VanessaInteractiveFeaturePath {
    if ([string]::IsNullOrWhiteSpace([string]$VanessaFeaturePath)) {
        throw "ITL_VANESSA_PROFILE_FEATURE_REQUIRED: pass -VanessaFeaturePath with one .feature file."
    }
    $path = Resolve-ProjectPath $VanessaFeaturePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [System.IO.Path]::GetExtension($path) -cne ".feature") {
        throw "ITL_VANESSA_PROFILE_FEATURE_INVALID: expected one existing .feature file: $path"
    }
    return $path
}

function Start-DevBranchVanessaInteractiveProfile {
    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "start-vanessa-profile"
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "start-vanessa-profile"
    $featurePath = Resolve-VanessaInteractiveFeaturePath
    $profileState = Read-VanessaInteractiveProfileState -Strict
    $runtimes = @(Get-VanessaInteractiveProfileRuntimeInstances -State $state)
    if ($runtimes.Count -gt 1) {
        throw "ITL_VANESSA_PROFILE_RUNTIME_CONFLICT: expected at most one current-branch Vanessa manager, found $($runtimes.Count). Run stop-vanessa-profile."
    }

    $instanceId = [string](Get-StateValue -State $profileState -Name "instanceId" -Default "")
    if ($runtimes.Count -eq 1) {
        $runtime = $runtimes[0]
        if (-not $instanceId) {
            throw "ITL_VANESSA_PROFILE_RUNTIME_CONFLICT: the owned manager runtime has no interactive-profile marker and may still have an independent idle owner; it was not reused or stopped."
        }
        $health = Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $runtime
        if (-not $health.owned -or $health.status -ne "healthy") {
            throw "ITL_VANESSA_PROFILE_OWNERSHIP_UNVERIFIED: current-branch manager status=$($health.status); it was not reused or stopped."
        }
        if ($instanceId -and $instanceId -cne [string]$runtime.instanceId) {
            throw "ITL_VANESSA_PROFILE_RUNTIME_CONFLICT: profile marker and owned runtime instance do not match."
        }
        $instanceId = [string]$runtime.instanceId
    }
    if (-not $instanceId) {
        $instanceId = [guid]::NewGuid().ToString("N")
    }
    if ($instanceId -notmatch '^[a-f0-9]{32}$') {
        throw "ITL_VANESSA_PROFILE_STATE_INVALID: invalid instance id '$instanceId'."
    }

    $registeredPids = @($runtimes | ForEach-Object {
        ConvertTo-IntOrDefault -Value $_.pid -Default 0
        ConvertTo-IntOrDefault -Value $_.testClientPid -Default 0
    } | Where-Object { $_ -gt 0 })
    $unregistered = @(Get-OwnVanessaTestProcesses -State $state -RequireInspection | Where-Object {
        $registeredPids -notcontains (ConvertTo-IntOrDefault -Value $_.processId -Default 0)
    })
    if ($unregistered.Count -gt 0) {
        throw "ITL_VANESSA_PROFILE_OWNERSHIP_UNVERIFIED: $($unregistered.Count) current-branch test process(es) have no active ownership marker; they were not reused or stopped."
    }

    $transport = Invoke-ItlOnDemandVanessaProfileStart -InstanceId $instanceId -FeaturePath $featurePath
    if ([string]$transport.status -ne "running" -or
        [string]$transport.testClientState -ne "manager-connected" -or
        [bool]$transport.scenarioWasStarted) {
        throw "ITL_VANESSA_PROFILE_CONNECTION_STATE_UNAVAILABLE: facade did not positively prove a connected non-running interactive pair."
    }

    $runtime = Read-ItlOnDemandRuntimeState -Family "vanessa-ui" -InstanceId $instanceId
    if ($null -eq $runtime -or -not (Test-ItlOnDemandOwnedProcess -RuntimeState $runtime)) {
        throw "ITL_VANESSA_PROFILE_OWNERSHIP_UNVERIFIED: manager ownership marker was not proven after start."
    }
    $ownedTestClients = @(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $runtime)
    if ($ownedTestClients.Count -ne 1 -or [int]$ownedTestClients[0].process.Id -ne [int]$transport.testClientPid) {
        throw "ITL_VANESSA_PROFILE_OWNERSHIP_UNVERIFIED: exactly one owned TestClient was not proven after start."
    }
    $matchingRuntimes = @(Get-VanessaInteractiveProfileRuntimeInstances -State $state)
    if ($matchingRuntimes.Count -ne 1 -or [string]$matchingRuntimes[0].instanceId -cne $instanceId) {
        throw "ITL_VANESSA_PROFILE_RUNTIME_CONFLICT: exactly one owned manager runtime was not proven after start."
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $saved = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = "running"
        instanceId = $instanceId
        infoBasePath = [string]$state.devBranchInfoBasePath
        featurePath = $featurePath
        managerPid = [int]$transport.managerPid
        managerPort = [int]$transport.managerPort
        testClientPid = [int]$transport.testClientPid
        testClientPort = [int]$transport.testClientPort
        testClientState = [string]$transport.testClientState
        startedAt = $(if ($profileState -and $profileState.startedAt) { [string]$profileState.startedAt } else { $now })
        updatedAt = $now
    }
    Write-VanessaInteractiveProfileState -ProfileState $saved | Out-Null
    $action = $(if ($runtimes.Count -eq 1 -or [bool]$transport.testClientReused) { "reused" } else { "started" })
    $report = New-VanessaInteractiveProfileUserReport -Action $action -Status "running" -State $state -RuntimeState $runtime -ProfileState $saved
    Publish-VanessaInteractiveProfileUserReport -Report $report
}

function Show-DevBranchVanessaInteractiveProfile {
    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "status-vanessa-profile"
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "status-vanessa-profile"
    $profileState = Read-VanessaInteractiveProfileState -Strict
    $runtimes = @(Get-VanessaInteractiveProfileRuntimeInstances -State $state)
    if ($runtimes.Count -gt 1) {
        $report = New-VanessaInteractiveProfileUserReport -Action "status" -Status "runtime-conflict" -State $state -ProfileState $profileState
        return (Publish-VanessaInteractiveProfileUserReport -Report $report)
    }
    if ($runtimes.Count -eq 0) {
        $status = $(if ($null -eq $profileState) { "stopped" } else { "stopped-stale-marker" })
        $report = New-VanessaInteractiveProfileUserReport -Action "status" -Status $status -State $state -ProfileState $profileState
        return (Publish-VanessaInteractiveProfileUserReport -Report $report)
    }
    $runtime = $runtimes[0]
    $health = Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $runtime
    $ownedClients = @(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $runtime)
    $status = $(if ($health.status -eq "healthy" -and $ownedClients.Count -eq 1 -and
        [string](Get-StateValue -State $profileState -Name "testClientState" -Default "") -eq "manager-connected") {
        "running"
    } elseif (-not $health.owned) {
        "ownership-unverified"
    } else {
        "connection-unverified"
    })
    $report = New-VanessaInteractiveProfileUserReport -Action "status" -Status $status -State $state -RuntimeState $runtime -ProfileState $profileState
    Publish-VanessaInteractiveProfileUserReport -Report $report
}

function Stop-DevBranchVanessaInteractiveProfile {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "stop-vanessa-profile"
    $path = Get-VanessaInteractiveProfileStatePath
    $claimedPath = ""
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Read-VanessaInteractiveProfileState -Strict | Out-Null
        $claimedPath = "$path.stopping-$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $path -Destination $claimedPath
    }
    try {
        $release = Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "stop-vanessa-profile"
        if ($claimedPath) {
            Remove-Item -LiteralPath $claimedPath -Force
        }
    } catch {
        if ($claimedPath -and (Test-Path -LiteralPath $claimedPath -PathType Leaf) -and -not (Test-Path -LiteralPath $path)) {
            Move-Item -LiteralPath $claimedPath -Destination $path
        }
        throw
    }
    $stoppedCount = [int]$release.stoppedTestManager + [int]$release.stoppedTestClient + [int]$release.stoppedVanessaUiBackend
    $action = $(if ($stoppedCount -gt 0 -or $claimedPath) { "stopped" } else { "already-stopped" })
    $report = New-VanessaInteractiveProfileUserReport -Action $action -Status "stopped" -State $state -ReleaseResult $release
    Publish-VanessaInteractiveProfileUserReport -Report $report
}

function Invoke-DevBranchVanessaRuntimeRelease {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Reason = "branch runtime cleanup"
    )

    $infoBasePath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    if ([string]::IsNullOrWhiteSpace($infoBasePath)) {
        throw "ITL_VANESSA_RUNTIME_RELEASE_FAILED reason='$Reason' detail='development branch infobase path is missing'"
    }

    $errors = @()
    $testResult = Stop-OwnVanessaTestProcesses -State $State -BranchWide
    $errors += @($testResult.errors)

    $onDemandBefore = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
        [string]$_.family -eq "vanessa-ui" -and
        (Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $infoBasePath)
    })
    foreach ($instance in $onDemandBefore) {
        try {
            Stop-ItlOnDemandBackendInstance `
                -Family "vanessa-ui" `
                -InstanceId ([string]$instance.instanceId) `
                -StrictOwnership | Out-Null
        } catch {
            $errors += "vanessa-ui/$([string]$instance.instanceId): $($_.Exception.Message)"
        }
    }

    $legacyStopped = 0
    $legacyBefore = Get-VanessaMcpRuntimeInfo -State $State
    if ($legacyBefore.processAlive) {
        try {
            if (Stop-VanessaMcpForState -State $State -Quiet -SkipClientConfig) {
                $legacyStopped = 1
            }
        } catch {
            $errors += "legacy-vanessa-ui/PID=$($legacyBefore.pid): $($_.Exception.Message)"
        }
    }

    $remainingTests = @(Get-OwnVanessaTestProcesses -State $State -RequireInspection)
    $remainingOnDemand = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
        [string]$_.family -eq "vanessa-ui" -and
        (Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $infoBasePath)
    })
    $legacyAfter = Get-VanessaMcpRuntimeInfo -State $State
    $remaining = @()
    $remaining += @($remainingTests | ForEach-Object {
        "$(Get-VanessaTestProcessCategory -ProcessInfo $_)/PID=$([int]$_.processId)"
    })
    $remaining += @($remainingOnDemand | ForEach-Object {
        "vanessa-ui/$([string]$_.instanceId)/PID=$(ConvertTo-IntOrDefault -Value $_.pid -Default 0)"
    })
    if ($legacyAfter.processAlive) {
        $remaining += "legacy-vanessa-ui/PID=$($legacyAfter.pid)"
    }

    $remainingInstanceIds = @($remainingOnDemand | ForEach-Object { [string]$_.instanceId })
    $stoppedOnDemand = @($onDemandBefore | Where-Object {
        $remainingInstanceIds -notcontains [string]$_.instanceId
    }).Count
    $result = [pscustomobject]@{
        schemaVersion = 1
        status = $(if ($remaining.Count -eq 0 -and $errors.Count -eq 0) { "released" } else { "failed" })
        reason = $Reason
        infoBasePath = $infoBasePath
        stoppedTestManager = [int]$testResult.stoppedTestManager
        stoppedTestClient = [int]$testResult.stoppedTestClient
        stoppedVanessaUiBackend = [int]($stoppedOnDemand + $legacyStopped)
        remainingOwnedRuntime = @($remaining)
        errors = @($errors)
    }

    Write-Host "Vanessa runtime cleanup stopped: TestManager=$($result.stoppedTestManager); TestClient=$($result.stoppedTestClient); Vanessa UI backend=$($result.stoppedVanessaUiBackend)."
    Write-Host "Vanessa runtime cleanup remaining owned runtime: $($result.remainingOwnedRuntime.Count)."
    foreach ($identity in $result.remainingOwnedRuntime) {
        Write-Host "  $identity"
    }
    if ($result.status -ne "released") {
        $detail = @($result.errors + $result.remainingOwnedRuntime) -join " | "
        throw "ITL_VANESSA_RUNTIME_RELEASE_FAILED reason='$Reason' stoppedTestManager=$($result.stoppedTestManager) stoppedTestClient=$($result.stoppedTestClient) stoppedVanessaUiBackend=$($result.stoppedVanessaUiBackend) remaining=$($result.remainingOwnedRuntime.Count) detail='$detail'"
    }
    return $result
}

function Stop-DevBranchTestClients {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "stop-dev-branch-test-clients"
    Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "stop-dev-branch-test-clients" | Out-Null
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

    $pathEnvName = [string]$Definition.pathEnvName
    $configuredValue = Get-EnvValue -Name $pathEnvName -Default ""
    $configured = ""
    try {
        $configured = Resolve-VanessaMcpArtifactPath -Value $configuredValue
    } catch {
        Write-Warning "ITL_VANESSA_MCP_ARTIFACT_PATH_INVALID: ignoring the invalid cached artifact path from $pathEnvName; artifact resolution will continue from the managed install root."
    }
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
    $source = [string]$AssetInfo.url
    $expected = ([string](Get-ConfigValueFromObject -Object $AssetInfo -Path "expectedSha256" -Default "")).ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$') {
        throw "Vanessa UI MCP artifact has an invalid expected SHA256 for $($Definition.lockKey): '$expected'."
    }

    Write-Host "Vanessa UI MCP artifact source: $source"
    [void](Invoke-ItlImmutableFileAcquire -Source (ConvertFrom-FileUri -Value $source) -DestinationPath $targetPath -ExpectedSha256 $expected -Label "Vanessa UI MCP artifact $($Definition.lockKey)")

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
    Write-Host "Vanessa UI MCP artifact SHA256: $hash"
    if ($hash -cne $expected) {
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

function Install-VanessaMcpExtensionCfe {
    param(
        [object]$State,
        [string]$CfePath,
        [string]$ExtensionName,
        [ValidateSet("file", "server")][string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$User = "",
        [string]$Password = ""
    )

    if (-not (Test-Path -LiteralPath $CfePath -PathType Leaf)) {
        throw "Vanessa UI MCP CFE was not found: $CfePath"
    }

    Write-Host "Installing 1C extension '$ExtensionName' from: $CfePath"
    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -User $User `
        -Password $Password `
        -DesignerArgs @("/LoadCfg", $CfePath, "-Extension", $ExtensionName, "/UpdateDBCfg") | Out-Null

    return $script:LastLogPath
}

function Get-VanessaDesignerAgentPortRange {
    $range = [string](Get-EnvValue -Name "VANESSA_DESIGNER_AGENT_PORT_RANGE" -Default "")
    if ($range -match '^\s*(\d+)\s*(?:\.\.|-|:)\s*(\d+)\s*$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
    } else {
        $start = 48251
        $end = 48350
    }
    if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
        throw "Invalid Vanessa Designer Agent port range: $start..$end"
    }
    return [pscustomobject]@{ start = $start; end = $end }
}

function Get-VanessaDesignerAgentRuntimeRoot {
    param([object]$State)

    $safeName = [string](Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch")
    return (Resolve-ProjectPath (Join-Path ".agent-1c\runtime\designer-agent" (ConvertTo-SafeName $safeName)))
}

function Get-VanessaDesignerAgentHostKeyRoot {
    param([object]$State)

    $hostKeyHome = [string](Get-EnvValue -Name "VANESSA_DESIGNER_AGENT_HOST_KEY_ROOT" -Default "")
    if ([string]::IsNullOrWhiteSpace($hostKeyHome)) {
        $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw "ITL_DESIGNER_AGENT_HOST_KEY_HOME_MISSING: LocalApplicationData could not be resolved. Set VANESSA_DESIGNER_AGENT_HOST_KEY_ROOT to an ASCII-only writable directory."
        }
        $hostKeyHome = Join-Path (Join-Path (Join-Path $localAppData "ITL") "1c-agent-workflow") "designer-agent-host-keys"
    } else {
        $hostKeyHome = [Environment]::ExpandEnvironmentVariables($hostKeyHome)
    }

    $stateProjectRoot = [string](Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $worktreePath = [string](Get-StateValue -State $State -Name "worktreePath" -Default $script:ProjectRoot)
    $safeName = ConvertTo-SafeName ([string](Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch"))
    $scopeHash = Get-ItlPortHashSegment "$stateProjectRoot|$worktreePath|$safeName|designer-agent-host-key"
    return [System.IO.Path]::GetFullPath((Join-Path $hostKeyHome "$safeName-$scopeHash"))
}

function Ensure-VanessaDesignerAgentHostKey {
    param([object]$State)

    $root = Get-VanessaDesignerAgentHostKeyRoot -State $State
    $privateKeyPath = Join-Path $root "host_id"
    $publicKeyPath = "$privateKeyPath.pub"
    if ($privateKeyPath -match '[^\x00-\x7F]') {
        throw "ITL_DESIGNER_AGENT_HOST_KEY_PATH_NON_ASCII: 1C Designer Agent cannot install a host key from '$privateKeyPath'. Set VANESSA_DESIGNER_AGENT_HOST_KEY_ROOT to an ASCII-only writable directory."
    }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if ((Test-Path -LiteralPath $privateKeyPath -PathType Leaf) -and (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        return [pscustomobject]@{ privateKeyPath = $privateKeyPath; publicKeyPath = $publicKeyPath }
    }

    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw "ITL_DESIGNER_AGENT_SSH_KEYGEN_MISSING: Windows OpenSSH ssh-keygen.exe is required to create the project-owned Designer Agent host key."
    }
    $arguments = @("-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", (ConvertTo-NativeEmptyStringArgument ""), "-f", $privateKeyPath)
    $result = Invoke-NativeProcessAndWaitResult -FilePath $sshKeygen.Source -Arguments $arguments -TimeoutSeconds 30
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) -or -not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        throw "ITL_DESIGNER_AGENT_SSH_KEYGEN_FAILED: ssh-keygen exited with code $($result.ExitCode)."
    }
    return [pscustomobject]@{ privateKeyPath = $privateKeyPath; publicKeyPath = $publicKeyPath }
}

function Invoke-VanessaDesignerAgentClient {
    param(
        [string]$ExecutablePath,
        [hashtable]$Request,
        [int]$TimeoutSeconds = 180
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw "ITL_DESIGNER_AGENT_CLIENT_MISSING: $ExecutablePath"
    }
    $json = $Request | ConvertTo-Json -Compress -Depth 20
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExecutablePath
    $startInfo.Arguments = "designer-agent-safe-mode"
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = Get-Utf8Encoding
    $startInfo.StandardErrorEncoding = Get-Utf8Encoding
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "ITL_DESIGNER_AGENT_CLIENT_START_FAILED"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdinBytes = (Get-Utf8Encoding).GetBytes($json)
        $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $cleanup = Stop-NativeProcessForSafety -Process $process
            throw "ITL_DESIGNER_AGENT_CLIENT_TIMEOUT: stopped=$($cleanup.confirmed) error='$($cleanup.error)'"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "ITL_DESIGNER_AGENT_CLIENT_FAILED: exitCode=$($process.ExitCode) error='$($stderr.Trim())'"
        }
        try {
            return ($stdout | ConvertFrom-Json)
        } catch {
            throw "ITL_DESIGNER_AGENT_CLIENT_RESULT_INVALID: $($_.Exception.Message)"
        }
    } finally {
        $process.Dispose()
    }
}

function Test-VanessaDesignerAgentSafeModeResult {
    param(
        [object]$Result,
        [string]$ExtensionName
    )

    if ($null -eq $Result -or -not [bool](Get-StateValue -State $Result -Name "success" -Default $false)) {
        return $false
    }
    $command = "config extensions properties get --extension $ExtensionName"
    $matches = @($Result.commands | Where-Object { [string]$_.command -ceq $command })
    if ($matches.Count -ne 1) {
        return $false
    }
    $serialized = $matches[0].messages | ConvertTo-Json -Compress -Depth 20
    return ($serialized -match '(?i)"safe(?:-)?mode"\s*:\s*(?:false|"no")')
}

function Stop-VanessaDesignerAgentOwnedProcess {
    param(
        [object]$Process,
        [DateTime]$ExpectedStartTime
    )

    $current = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if ($null -eq $current) {
        return [pscustomobject]@{ confirmed = $true; error = "" }
    }
    try {
        if ([Math]::Abs(($current.StartTime.ToUniversalTime() - $ExpectedStartTime.ToUniversalTime()).TotalSeconds) -ge 2) {
            return [pscustomobject]@{ confirmed = $false; error = "PID $($Process.Id) start time changed; refusing to stop a foreign process." }
        }
    } catch {
        return [pscustomobject]@{ confirmed = $false; error = "PID $($Process.Id) identity could not be verified: $($_.Exception.Message)" }
    }
    return (Stop-NativeProcessForSafety -Process $current)
}

function Read-VanessaDesignerAgentSafeLogTail {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }
    try {
        return Protect-VanessaVerificationDiagnosticText -Text ((Get-Content -LiteralPath $Path -Tail 30 -ErrorAction Stop) -join " ") -MaxLength 2000
    } catch {
        return ""
    }
}

function Wait-VanessaDesignerAgentReady {
    param(
        [Parameter(Mandatory = $true)][object]$Process,
        [Parameter(Mandatory = $true)][DateTime]$ExpectedStartTime,
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(0, 300)][int]$TimeoutSeconds = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $current = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if ($null -eq $current) {
            $exitCode = $null
            try {
                if ($Process.HasExited) { $exitCode = [int]$Process.ExitCode }
            } catch {}
            $stopwatch.Stop()
            return [pscustomobject][ordered]@{
                ready = $false
                status = "exited"
                processAlive = $false
                exitCode = $exitCode
                ownerPids = @()
                elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                detail = "Designer Agent process exited before readiness."
            }
        }

        try {
            if ([Math]::Abs(($current.StartTime.ToUniversalTime() - $ExpectedStartTime.ToUniversalTime()).TotalSeconds) -ge 2) {
                $stopwatch.Stop()
                return [pscustomobject][ordered]@{
                    ready = $false
                    status = "identity-changed"
                    processAlive = $false
                    exitCode = $null
                    ownerPids = @()
                    elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    detail = "Designer Agent PID identity changed before readiness."
                }
            }
        } catch {
            $stopwatch.Stop()
            return [pscustomobject][ordered]@{
                ready = $false
                status = "identity-inspection-failed"
                processAlive = $true
                exitCode = $null
                ownerPids = @()
                elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                detail = "Designer Agent PID identity could not be verified: $($_.Exception.Message)"
            }
        }

        if (Test-TcpPortOpen -Port $Port -TimeoutMilliseconds 500) {
            try {
                $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
                $ownerPids = @($listeners | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
                if ($ownerPids.Count -eq 1 -and $ownerPids[0] -eq [int]$Process.Id) {
                    $stopwatch.Stop()
                    return [pscustomobject][ordered]@{
                        ready = $true
                        status = "ready"
                        processAlive = $true
                        exitCode = $null
                        ownerPids = @($ownerPids)
                        elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                        detail = "Designer Agent owns the expected listener."
                    }
                }
                $stopwatch.Stop()
                return [pscustomobject][ordered]@{
                    ready = $false
                    status = "owner-mismatch"
                    processAlive = $true
                    exitCode = $null
                    ownerPids = @($ownerPids)
                    elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    detail = "Expected TCP port is not owned exclusively by the Designer Agent PID."
                }
            } catch {
                $stopwatch.Stop()
                return [pscustomobject][ordered]@{
                    ready = $false
                    status = "listener-inspection-failed"
                    processAlive = $true
                    exitCode = $null
                    ownerPids = @()
                    elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    detail = "TCP listener ownership could not be verified: $($_.Exception.Message)"
                }
            }
        }

        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ($true)

    $stopwatch.Stop()
    return [pscustomobject][ordered]@{
        ready = $false
        status = "timeout"
        processAlive = $true
        exitCode = $null
        ownerPids = @()
        elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        detail = "Designer Agent stayed alive but did not open the expected TCP listener."
    }
}

function Set-VanessaMcpExtensionUnsafeMode {
    param(
        [object]$State,
        [ValidateSet("file", "server")][string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$ExtensionName,
        [object]$Artifact,
        [string]$User = "",
        [string]$Password = "",
        [string]$Scope = "extension"
    )

    $platformPath = Get-PlatformPath
    $key = Ensure-VanessaDesignerAgentHostKey -State $State
    $range = Get-VanessaDesignerAgentPortRange
    $leaseToken = New-ItlManagedPortLeaseToken
    $portFamily = "vanessa-designer-agent"
    $portKey = "$(Get-ItlBranchManagedPortKey -Family $portFamily -State $State)|scope=$Scope"
    $lease = Resolve-ItlManagedPortLease -Family $portFamily -Key $portKey -Start $range.start -End $range.end -State $State -Subject "Vanessa Designer Agent port" -LeaseToken $leaseToken
    $agentRoot = Get-VanessaDesignerAgentRuntimeRoot -State $State
    $logPath = New-TimestampedFilePath -Directory $agentRoot -Prefix "designer-agent-$Scope-" -Extension ".log"
    $infoBaseIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind $InfoBaseKind -InfoBasePath $InfoBasePath
    $platformVersion = ""
    try { $platformVersion = [string](Get-Item -LiteralPath $platformPath).VersionInfo.FileVersion } catch {}
    $process = $null
    $processStartTime = [DateTime]::MinValue
    $releaseLease = $true
    try {
        $infoBaseArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User "" -Password ""
        $arguments = @("DESIGNER") + $infoBaseArgs + @(
            "/DisableStartupMessages",
            "/DisableStartupDialogs",
            "/Out", $logPath,
            "/AgentMode",
            "/AgentPort", [string]$lease.port,
            "/AgentListenAddress", "127.0.0.1",
            "/AgentSSHHostKey", $key.privateKeyPath,
            "/AgentBaseDir", $agentRoot
        )
        Write-Host "Starting Designer Agent for Vanessa extension property reconciliation on 127.0.0.1:$($lease.port)."
        $process = Start-OneCProcessBackground -FilePath $platformPath -Arguments $arguments -InfoBaseKind $InfoBaseKind -InfoBasePath $InfoBasePath -Purpose "vanessa-designer-agent-safe-mode-$Scope"
        $processStartTime = $process.StartTime
        Set-ItlManagedPortAllocationStatus -Family $portFamily -Key $portKey -Status "running" -ProcessId $process.Id -LeaseToken $leaseToken
        $readiness = Wait-VanessaDesignerAgentReady -Process $process -ExpectedStartTime $processStartTime -Port ([int]$lease.port) -TimeoutSeconds 30
        if (-not $readiness.ready) {
            $code = switch ([string]$readiness.status) {
                "exited" { "ITL_DESIGNER_AGENT_EXITED" }
                "identity-changed" { "ITL_DESIGNER_AGENT_IDENTITY_CHANGED" }
                "identity-inspection-failed" { "ITL_DESIGNER_AGENT_IDENTITY_INSPECTION_FAILED" }
                "owner-mismatch" { "ITL_DESIGNER_AGENT_PORT_OWNER_MISMATCH" }
                "listener-inspection-failed" { "ITL_DESIGNER_AGENT_LISTENER_INSPECTION_FAILED" }
                default { "ITL_DESIGNER_AGENT_NOT_READY" }
            }
            $exitCode = if ($null -eq $readiness.exitCode) { "unknown" } else { [string]$readiness.exitCode }
            $ownerPids = if (@($readiness.ownerPids).Count -gt 0) { @($readiness.ownerPids) -join "," } else { "none" }
            $logTail = Read-VanessaDesignerAgentSafeLogTail -Path $logPath
            throw "${code}: extension='$ExtensionName' scope='$Scope' infoBaseKind='$InfoBaseKind' infoBaseKey='$($infoBaseIdentity.key)' platformVersion='$platformVersion' pid=$($process.Id) processAlive=$($readiness.processAlive) exitCode=$exitCode port=$($lease.port) ownerPids=$ownerPids elapsedSeconds=$($readiness.elapsedSeconds) log='$logPath' detail='$($readiness.detail)' logTail='$logTail'"
        }

        $clientPath = Get-ItlOnDemandMcpExecutablePath
        $commands = @(
            "common connect-ib",
            "config extensions properties set --extension $ExtensionName --safe-mode no",
            "config extensions properties get --extension $ExtensionName",
            "common disconnect-ib",
            "common shutdown"
        )
        $request = @{
            host = "127.0.0.1"
            port = [int]$lease.port
            username = $User
            password = $Password
            hostPublicKey = [string](Read-Utf8Text -Path $key.publicKeyPath)
            commands = $commands
            connectTimeoutSeconds = 30
            commandTimeoutSeconds = 120
        }
        $result = Invoke-VanessaDesignerAgentClient -ExecutablePath $clientPath -Request $request
        if (-not (Test-VanessaDesignerAgentSafeModeResult -Result $result -ExtensionName $ExtensionName)) {
            throw "ITL_DESIGNER_AGENT_SAFE_MODE_VERIFY_FAILED: extension '$ExtensionName' was not proven with safe mode disabled in '$InfoBasePath'."
        }
        if (-not (Wait-ItlOnDemandProcessExit -ProcessId $process.Id -TimeoutSeconds 30)) {
            throw "ITL_DESIGNER_AGENT_SHUTDOWN_FAILED: Designer Agent PID $($process.Id) did not exit after common shutdown."
        }
        return [pscustomobject][ordered]@{
            verifiedAt = (Get-Date).ToString("o")
            extensionName = $ExtensionName
            infoBaseKind = $InfoBaseKind
            infoBasePath = $InfoBasePath
            infoBaseKey = [string]$infoBaseIdentity.key
            platformVersion = $platformVersion
            artifactSha256 = [string]$Artifact.sha256
            safeMode = $false
        }
    } finally {
        if ($null -ne $process -and $null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            $cleanup = Stop-VanessaDesignerAgentOwnedProcess -Process $process -ExpectedStartTime $processStartTime
            if (-not $cleanup.confirmed) {
                $releaseLease = $false
            }
        }
        if ($releaseLease) {
            Release-ItlManagedPortAllocation -Family $portFamily -Key $portKey -LeaseToken $leaseToken
        } else {
            throw "ITL_DESIGNER_AGENT_CLEANUP_UNCONFIRMED: $($cleanup.error) The managed port lease was retained."
        }
    }
}

function Test-VanessaMcpSafeModeProofMatchesState {
    param([object]$State)

    $proof = Get-StateValue -State $State -Name "vanessaMcpSafeModeProof" -Default $null
    $clientProof = Get-StateValue -State $proof -Name "clientMcp" -Default $null
    $vaProof = Get-StateValue -State $proof -Name "vaExtension" -Default $null
    if ($null -eq $proof -or $null -eq $clientProof -or $null -eq $vaProof -or
        [bool](Get-StateValue -State $clientProof -Name "safeMode" -Default $true) -or
        [bool](Get-StateValue -State $vaProof -Name "safeMode" -Default $true)) {
        return $false
    }
    try {
        $serviceIdentity = Get-OneCInfoBaseIdentity `
            -InfoBaseKind ([string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseKind" -Default "file")) `
            -InfoBasePath ([string](Get-StateValue -State $State -Name "vanessaServiceInfoBasePath" -Default ""))
        $targetIdentity = Get-OneCInfoBaseIdentity `
            -InfoBaseKind ([string](Get-StateValue -State $State -Name "infoBaseKind" -Default "")) `
            -InfoBasePath ([string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default ""))
    } catch {
        return $false
    }
    return (
        [string](Get-StateValue -State $proof -Name "serviceInfoBaseGeneration" -Default "") -ceq [string](Get-StateValue -State $State -Name "vanessaServiceInfoBaseGeneration" -Default "") -and
        [string](Get-StateValue -State $clientProof -Name "extensionName" -Default "") -ceq "client_mcp" -and
        [string](Get-StateValue -State $clientProof -Name "infoBaseKey" -Default "") -ceq [string]$serviceIdentity.key -and
        [string](Get-StateValue -State $clientProof -Name "artifactSha256" -Default "") -ceq [string](Get-StateValue -State $State -Name "vanessaMcpClientMcpSha256" -Default "") -and
        [string](Get-StateValue -State $vaProof -Name "extensionName" -Default "") -ceq "VAExtension" -and
        [string](Get-StateValue -State $vaProof -Name "infoBaseKey" -Default "") -ceq [string]$targetIdentity.key -and
        [string](Get-StateValue -State $vaProof -Name "artifactSha256" -Default "") -ceq [string](Get-StateValue -State $State -Name "vanessaMcpVaExtensionSha256" -Default "")
    )
}

function Install-VanessaMcp {
    Write-Section "Install Vanessa UI MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "install-vanessa-mcp"
    $runtime = Get-VanessaMcpRuntimeInfo -State $state
    if ($runtime.processAlive) {
        throw "Stop Vanessa UI MCP for this branch before reinstalling MCP extensions. PID: $($runtime.pid)"
    }
    $serviceInfoBase = Ensure-VanessaServiceInfoBase -State $state
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

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

    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "Vanessa UI MCP extension installation"
    $clientLog = Install-VanessaMcpExtensionCfe `
        -State $state `
        -CfePath $clientArtifact.path `
        -ExtensionName "client_mcp" `
        -InfoBaseKind $serviceInfoBase.kind `
        -InfoBasePath $serviceInfoBase.path `
        -User $serviceInfoBase.user `
        -Password $serviceInfoBase.password
    $vaExtensionLog = Install-VanessaMcpExtensionCfe `
        -State $state `
        -CfePath $vaExtensionArtifact.path `
        -ExtensionName "VAExtension" `
        -InfoBaseKind ([string]$state.infoBaseKind) `
        -InfoBasePath ([string]$state.devBranchInfoBasePath) `
        -User ([string](Get-EnvValue -Name "IB_USER")) `
        -Password ([string](Get-EnvValue -Name "IB_PASSWORD"))

    $clientSafeModeProof = Set-VanessaMcpExtensionUnsafeMode `
        -State $state `
        -InfoBaseKind $serviceInfoBase.kind `
        -InfoBasePath $serviceInfoBase.path `
        -ExtensionName "client_mcp" `
        -Artifact $clientArtifact `
        -User $serviceInfoBase.user `
        -Password $serviceInfoBase.password `
        -Scope "service-client-mcp"
    $vaSafeModeProof = Set-VanessaMcpExtensionUnsafeMode `
        -State $state `
        -InfoBaseKind ([string]$state.infoBaseKind) `
        -InfoBasePath ([string]$state.devBranchInfoBasePath) `
        -ExtensionName "VAExtension" `
        -Artifact $vaExtensionArtifact `
        -User ([string](Get-EnvValue -Name "IB_USER")) `
        -Password ([string](Get-EnvValue -Name "IB_PASSWORD")) `
        -Scope "target-va-extension"
    $safeModeProof = [pscustomobject][ordered]@{
        schemaVersion = 2
        serviceInfoBaseGeneration = [string](Get-StateValue -State $state -Name "vanessaServiceInfoBaseGeneration" -Default "")
        clientMcpSafeMode = $false
        vaExtensionSafeMode = $false
        clientMcp = $clientSafeModeProof
        vaExtension = $vaSafeModeProof
    }

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
        vanessaMcpSafeModeProof = $safeModeProof
    }

    Write-Host "client_mcp installed in Vanessa TestManager service infobase: $($serviceInfoBase.path)"
    Write-Host "VAExtension installed in TestClient target infobase: $($state.devBranchInfoBasePath)"
    Write-Host "client_mcp CFE: $($clientArtifact.path)"
    Write-Host "VAExtension CFE: $($vaExtensionArtifact.path)"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Ensure-VanessaMcpInstalled {
    param([object]$State)

    $serviceInfoBase = Ensure-VanessaServiceInfoBase -State $State
    $State = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")

    $clientPath = Get-StateValue -State $State -Name "vanessaMcpClientMcpCfePath" -Default ""
    $vaExtensionPath = Get-StateValue -State $State -Name "vanessaMcpVaExtensionCfePath" -Default ""
    if ($clientPath -and $vaExtensionPath -and
        (Test-Path -LiteralPath $clientPath -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath $vaExtensionPath -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-VanessaMcpSafeModeProofMatchesState -State $State)) {
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
        [switch]$Quiet,
        [switch]$SkipClientConfig
    )

    $runtime = Get-VanessaMcpRuntimeInfo -State $State
    $oneCProcesses = @(Get-OneCProcessInfo -RequireSuccess)
    $updates = @{
        vanessaMcpPid = ""
        vanessaMcpProcessStartTime = ""
        vanessaMcpExecutablePath = ""
        vanessaMcpCommandLineIdentity = ""
        vanessaMcpInfoBasePath = ""
        vanessaMcpStatus = "stopped"
        vanessaMcpStoppedAt = (Get-Date).ToString("o")
        vanessaMcpUpdatedAt = (Get-Date).ToString("o")
    }

    if ($runtime.processAlive) {
        $processInfo = @($oneCProcesses | Where-Object { [int]$_.processId -eq [int]$runtime.pid } | Select-Object -First 1)
        if ($processInfo.Count -ne 1 -or -not (Test-VanessaMcpProcessBelongsToState -ProcessInfo $processInfo[0] -State $State)) {
            throw "ITL_LEGACY_MCP_OWNERSHIP_MISMATCH: refusing to stop unverified Vanessa UI PID $($runtime.pid); PID, start time, executable, command line, infobase, and port must all match durable state."
        }
        if (-not $Quiet) {
            Write-Host "Stopping Vanessa UI MCP process: PID $($runtime.pid)"
        }
        Stop-Process -Id $runtime.pid -Force -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 200
            $processStillAlive = $null -ne (Get-Process -Id $runtime.pid -ErrorAction SilentlyContinue)
            $portStillOpen = Test-TcpPortOpen -Port ([int]$runtime.port)
        } while (($processStillAlive -or $portStillOpen) -and (Get-Date) -lt $deadline)
        $postStopProcesses = @(Get-OneCProcessInfo -RequireSuccess)
        if (@($postStopProcesses | Where-Object { [int]$_.processId -eq [int]$runtime.pid }).Count -gt 0) {
            $processStillAlive = $true
        }
        if ($processStillAlive -or $portStillOpen) {
            throw "ITL_LEGACY_MCP_STOP_FAILED: Vanessa UI PID $($runtime.pid) or port $($runtime.port) is still active; state and port lease were preserved."
        }
        Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $State) -Status "stopped" -LeaseToken ([string](Get-StateValue -State $State -Name "vanessaMcpPortLeaseToken" -Default ""))
        Update-DevBranchState -State $State -Updates $updates
        $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
        if (-not $SkipClientConfig) {
            Write-VanessaMcpClientConfig -State $state
        }
        return $true
    }

    if ($runtime.portOpen) {
        throw "ITL_LEGACY_MCP_OWNERSHIP_MISMATCH: Vanessa UI state PID $($runtime.pid) is not alive, but port $($runtime.port) is open; state and port lease were preserved."
    }

    Set-ItlManagedPortAllocationStatus -Family "vanessa-mcp" -Key (Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $State) -Status "stopped" -LeaseToken ([string](Get-StateValue -State $State -Name "vanessaMcpPortLeaseToken" -Default ""))
    Update-DevBranchState -State $State -Updates $updates
    $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    if (-not $SkipClientConfig) {
        Write-VanessaMcpClientConfig -State $state
    }
    if (-not $Quiet) {
        Write-Host "Vanessa UI MCP is not running for this branch."
    }
    return $false
}
