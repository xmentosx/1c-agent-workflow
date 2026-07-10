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
    return (Join-Path $env:TEMP "1c-agent-workflow\vanessa-automation")
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
    param([string]$RecordText)

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
        [string[]]$Levels = (Get-VanessaEventLogLevels)
    )

    $logDirectory = Get-DevBranchEventLogDirectory -State $State
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container -ErrorAction SilentlyContinue)) {
        throw "1C event log directory was not found: $logDirectory"
    }

    $lgfPath = Join-Path $logDirectory "1Cv8.lgf"
    $lgpFiles = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.lgp" -ErrorAction SilentlyContinue | Sort-Object Name)
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
        $text = Read-SharedTextFile -Path $file.FullName
        foreach ($record in Get-OneCBracketRecords -Text $text) {
            $event = ConvertFrom-OneCEventLogRecord -RecordText $record
            if ($null -eq $event) {
                continue
            }
            if ($wantedLevels.Count -gt 0 -and -not $wantedLevels.ContainsKey($event.level)) {
                continue
            }
            if ($null -ne $StartTime -and $event.date -lt $StartTime) {
                continue
            }
            if ($null -ne $EndTime -and $event.date -gt $EndTime) {
                continue
            }
            [void]$events.Add($event)
        }
    }
    return @($events)
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
        [Nullable[datetime]]$EndTime = $null
    )

    $reader = Get-VanessaEventLogReader
    $levels = Get-VanessaEventLogLevels
    $lastError = $null

    if ($reader -eq "auto" -or $reader -eq "direct") {
        try {
            $events = @(Read-OneCEventLogDirect -State $State -StartTime $StartTime -EndTime $EndTime -Levels $levels)
            return [pscustomobject]@{
                reader = "direct"
                events = $events
                logDirectory = (Get-DevBranchEventLogDirectory -State $State)
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
            return [pscustomobject]@{
                reader = "fallback"
                events = $events
                logDirectory = (Get-DevBranchEventLogDirectory -State $State)
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

    $readResult = Read-DevBranchEventLogErrors -State $State
    $signatures = @($readResult.events | ForEach-Object { $_.signature } | Where-Object { $_ } | Sort-Object -Unique)
    $baselinePath = Get-DevBranchEventLogBaselinePath -State $State
    $createdAt = (Get-Date).ToString("o")
    $baseline = [ordered]@{
        schemaVersion = 1
        createdAt = $createdAt
        reason = $Reason
        reader = $readResult.reader
        logDirectory = $readResult.logDirectory
        errorCount = @($readResult.events).Count
        signatureCount = @($signatures).Count
        signatures = @($signatures)
    }
    Write-Utf8Text -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

    $hash = Get-StringSha256 -Value ((@($signatures) -join "`n"))
    $updates = @{
        eventLogBaselinePath = $baselinePath
        eventLogBaselineCreatedAt = $createdAt
        eventLogBaselineReader = $readResult.reader
        eventLogBaselineErrorCount = @($readResult.events).Count
        eventLogBaselineSignatureCount = @($signatures).Count
        eventLogBaselineHash = $hash
    }
    if ($Reason -eq "backfill") {
        $updates["eventLogBaselineBackfilledAt"] = $createdAt
    }
    Update-DevBranchState -State $State -Updates $updates

    Write-Host "Event log baseline saved: $baselinePath"
    Write-Host "Event log baseline signatures: $(@($signatures).Count)"

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
        [string]$RunDirectory
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
    $readResult = Read-DevBranchEventLogErrors -State $stateWithBaseline -StartTime $RunStartedAt -EndTime $endTime

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
    $scenarioSettings[(ConvertFrom-Utf8Base64 "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg=")] = $true
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
    $params["stoponerror"] = $true
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
    }

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container -ErrorAction SilentlyContinue)) {
        return [pscustomobject]$summary
    }

    $xmlFiles = @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue)
    foreach ($file in $xmlFiles) {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($file.FullName)
            $nodes = @($xml.SelectNodes('//*[local-name()="testsuite" or local-name()="testsuites"]'))
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
        } catch {
            Write-Host "[WARN] Could not parse Vanessa JUnit report: $($file.FullName)"
        }
    }

    return [pscustomobject]$summary
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

function Get-GitStatusForFingerprintPaths {
    param([string[]]$PathSpec)

    $arguments = @("status", "--porcelain", "--") + @($PathSpec)
    $output = & git -C $script:ProjectRoot @arguments
    if ($LASTEXITCODE -ne 0) {
        return "<cannot-read-status>"
    }
    return (@($output) -join "`n")
}

function Get-VerificationFingerprint {
    $paths = @(
        (Get-ExportPath),
        (Get-ExtensionsPath),
        (Get-VanessaFeaturesPath)
    )

    $parts = @()
    foreach ($path in $paths) {
        $normalized = ($path -replace "\\", "/").Trim("/")
        if ($normalized) {
            $parts += "$normalized=$(Get-GitObjectIdForHeadPath -RepoPath $normalized)"
        }
    }

    $relevantStatus = Get-GitStatusForFingerprintPaths -PathSpec $paths
    if ($relevantStatus) {
        $parts += "worktree=$relevantStatus"
    } else {
        $parts += "worktree=<clean>"
    }

    return ($parts -join "|")
}

function Get-VerificationState {
    param([object]$State)

    $status = [string](Get-StateValue -State $State -Name "lastVerificationStatus" -Default "missing")
    $commit = [string](Get-StateValue -State $State -Name "lastVerifiedCommit" -Default "")
    $fingerprint = [string](Get-StateValue -State $State -Name "lastVerifiedFingerprint" -Default "")
    $currentCommit = ""
    $currentFingerprint = ""
    $isFresh = $false
    try {
        $currentCommit = Get-CurrentCommit
        $currentFingerprint = Get-VerificationFingerprint
        if ($fingerprint) {
            $isFresh = ($status -eq "passed" -and $fingerprint -eq $currentFingerprint)
        } else {
            $isFresh = ($status -eq "passed" -and $commit -and $commit -eq $currentCommit)
        }
    } catch {
        $currentCommit = ""
        $currentFingerprint = ""
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
        currentCommit = $currentCommit
        verifiedFingerprint = $fingerprint
        currentFingerprint = $currentFingerprint
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
    $currentFingerprint = Get-VerificationFingerprint
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
        throw "$Operation stopped because verificationPolicy=block and fresh passed Vanessa verification is missing. Run verify-dev-branch before exporting or closing the branch."
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
        return $true
    }

    throw "$Operation stopped because fresh passed Vanessa verification is missing. Run verify-dev-branch or rerun with explicit unverified override."
}

function Run-DevBranchTests {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "run-dev-branch-tests"
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
    Write-Host "Vanessa test timeout: $timeoutSeconds seconds"
    try {
        $logPath = Invoke-Enterprise `
            -InfoBasePath $state.devBranchInfoBasePath `
            -InfoBaseKind $state.infoBaseKind `
            -EnterpriseArgs $enterpriseArgs `
            -TestClientPort $testPort `
            -TimeoutSeconds $timeoutSeconds `
            -OnTimeout {
                Write-Host "[WARN] Vanessa verify exceeded timeout; stopping own TESTMANAGER/TESTCLIENT processes."
                Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
            }
    } catch {
        $runFinishedAt = Get-Date
        $logPath = $script:LastLogPath
        Write-OneCVanessaProcessDiagnostics -State $state -TestPort $testPort -Context "Vanessa verify failed; active 1C process diagnostics"
        Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
        $eventLogReason = ""
        try {
            $eventLogVerification = Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory
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
        }
        Update-DevBranchState -State $state -Updates $updates
        throw
    }

    $runFinishedAt = Get-Date
    $verification = Get-VanessaVerificationStatus -RunDirectory $runDirectory -StatusPath $statusPath
    try {
        $eventLogVerification = Test-DevBranchEventLogAfterVanessa -State $state -RunStartedAt $runStartedAt -RunFinishedAt $runFinishedAt -RunDirectory $runDirectory
    } catch {
        $eventLogVerification = [pscustomobject]@{
            status = "failed"
            reason = "1C event log check failed: $($_.Exception.Message)"
            reader = ""
            baselinePath = Get-StateValue -State $state -Name "eventLogBaselinePath" -Default ""
            reportPath = ""
            newErrorCount = 0
            legacyErrorCount = 0
            checkedUntil = $runFinishedAt
        }
    }
    if ($eventLogVerification.status -ne "passed") {
        $verification = [pscustomobject]@{
            status = "failed"
            reason = "$($verification.reason) Event log: $($eventLogVerification.reason)"
        }
    } elseif ($verification.status -eq "passed") {
        $verification = [pscustomobject]@{
            status = "passed"
            reason = "$($verification.reason) Event log: $($eventLogVerification.reason)"
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
        if ($verification.status -eq "unknown") {
            Write-OneCVanessaProcessDiagnostics -State $state -TestPort $testPort -Context "Vanessa verify produced no reliable JUnit/status; active 1C process diagnostics"
            Stop-OwnHungVanessaTestClients -State $state -TestPort $testPort
        }
        throw "Vanessa verification did not pass: $($verification.status). $($verification.reason)"
    }
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
    if ($port -le 0 -and -not $lastAt) {
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
    $baselinePath = Get-StateValue -State $State -Name "eventLogBaselinePath" -Default ""
    if ($baselinePath) {
        Write-Host "${Indent}Event log baseline: $baselinePath"
    }
    $newErrorCount = Get-StateValue -State $State -Name "lastVanessaEventLogNewErrorCount" -Default ""
    if ($newErrorCount -ne "") {
        Write-Host "${Indent}Last event log new errors: $newErrorCount"
    }
    $eventLogReport = Get-StateValue -State $State -Name "lastVanessaEventLogNewErrorsPath" -Default ""
    if ($eventLogReport) {
        Write-Host "${Indent}Last event log new-error report: $eventLogReport"
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

    if ((Get-DependencyMode) -eq "locked") {
        $locked = Get-VanessaMcpArtifactLockEntry -Definition $Definition
        $version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
        $assetName = [string](Get-ConfigValueFromObject -Object $locked -Path "assetName" -Default "")
        $url = [string](Get-ConfigValueFromObject -Object $locked -Path "url" -Default "")
        $sha256 = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
        if (-not $version -or -not $assetName -or -not $url -or -not $sha256) {
            throw "Dependency mode is locked, but vanessaMcp.$($Definition.lockKey).version, assetName, url, and sha256 must all be set in .agent-1c/dependency-lock.json."
        }
        return [pscustomobject]@{
            url = $url
            name = $assetName
            version = $version
            expectedSha256 = $sha256
            source = "dependency-lock"
        }
    }

    $asset = Get-GitHubReleaseAssetInfo `
        -Repository ([string]$Definition.repository) `
        -AssetNameLike ([string]$Definition.assetNameLike) `
        -OverrideEnvName ([string]$Definition.overrideEnvName) `
        -DefaultFileName ([string]$Definition.defaultFileName)
    $asset | Add-Member -NotePropertyName expectedSha256 -NotePropertyValue "" -Force
    return $asset
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
