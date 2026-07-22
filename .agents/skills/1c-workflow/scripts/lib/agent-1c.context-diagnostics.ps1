$script:KiloBrowserAutomationSettingName = "kilo-code.new.browserAutomation.enabled"
$script:KiloContextBenchmarkPrompt = "ITL_CONTEXT_BENCHMARK_V1: Reply with only OK. Do not call tools."
$script:KiloContextBenchmarkTimeoutSeconds = 180

function ConvertFrom-ItlJsoncText {
    param([string]$Text)

    if ($null -eq $Text) { throw "JSONC text is null." }
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        if ($lineComment) {
            if ($character -eq "`r" -or $character -eq "`n") {
                $lineComment = $false
                [void]$builder.Append($character)
            }
            continue
        }
        if ($blockComment) {
            if ($character -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $index++
            } elseif ($character -eq "`r" -or $character -eq "`n") {
                [void]$builder.Append($character)
            }
            continue
        }
        if ($inString) {
            [void]$builder.Append($character)
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
            continue
        }
        if ($character -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $index++
            continue
        }
        if ($character -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $index++
            continue
        }
        [void]$builder.Append($character)
    }

    if ($inString -or $blockComment) { throw "JSONC text is incomplete." }
    $json = [regex]::Replace($builder.ToString(), ',(?=\s*[}\]])', '')
    return ($json | ConvertFrom-Json)
}

function Read-ItlJsoncFile {
    param([string]$Path)
    return (ConvertFrom-ItlJsoncText -Text (Read-Utf8Text -Path $Path))
}

function Get-ItlObjectPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-KiloBooleanSettingFromFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ present = $false; valid = $true; value = $null; path = $Path; error = "" }
    }
    try {
        $settings = Read-ItlJsoncFile -Path $Path
        $property = $settings.PSObject.Properties[$script:KiloBrowserAutomationSettingName]
        if ($null -eq $property) {
            return [pscustomobject]@{ present = $false; valid = $true; value = $null; path = $Path; error = "" }
        }
        if ($property.Value -isnot [bool]) {
            throw "Setting '$($script:KiloBrowserAutomationSettingName)' must be boolean."
        }
        return [pscustomobject]@{ present = $true; valid = $true; value = [bool]$property.Value; path = $Path; error = "" }
    } catch {
        return [pscustomobject]@{ present = $false; valid = $false; value = $null; path = $Path; error = $_.Exception.Message }
    }
}

function Get-KiloUserSettingsCandidates {
    $appData = [string]$env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) { return @() }
    $roots = @("Code", "Cursor", "VSCodium", "Kilo Code")
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        $userRoot = Join-Path $appData "$root\User"
        $paths.Add((Join-Path $userRoot "settings.json"))
        $profilesRoot = Join-Path $userRoot "profiles"
        if (Test-Path -LiteralPath $profilesRoot -PathType Container -ErrorAction SilentlyContinue) {
            foreach ($file in @(Get-ChildItem -LiteralPath $profilesRoot -Filter "settings.json" -File -Recurse -ErrorAction SilentlyContinue)) {
                $paths.Add($file.FullName)
            }
        }
    }
    return @($paths | Select-Object -Unique)
}

function Get-KiloExtensionPackageCandidates {
    $profile = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profile)) { return @() }
    $roots = @(".vscode\extensions", ".cursor\extensions", ".vscode-shared\extensions")
    $packages = [System.Collections.Generic.List[object]]::new()
    foreach ($relativeRoot in $roots) {
        $root = Join-Path $profile $relativeRoot
        if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Filter "kilocode.kilo-code-*" -ErrorAction SilentlyContinue)) {
            $packagePath = Join-Path $directory.FullName "package.json"
            if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { continue }
            $version = [version]"0.0"
            if ($directory.Name -match '^kilocode\.kilo-code-(?<version>\d+(?:\.\d+){1,3})') {
                try { $version = [version]$Matches["version"] } catch { $version = [version]"0.0" }
            }
            $packages.Add([pscustomobject]@{ path = $packagePath; directory = $directory.FullName; version = $version })
        }
    }
    return @($packages | Sort-Object version -Descending)
}

function Get-KiloExtensionBrowserDefault {
    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @(Get-KiloExtensionPackageCandidates)) {
        try {
            $package = (Read-Utf8Text -Path $candidate.path) | ConvertFrom-Json
            foreach ($configuration in @($package.contributes.configuration)) {
                $properties = Get-ItlObjectPropertyValue -Object $configuration -Name "properties"
                $entry = Get-ItlObjectPropertyValue -Object $properties -Name $script:KiloBrowserAutomationSettingName
                $default = Get-ItlObjectPropertyValue -Object $entry -Name "default"
                if ($default -is [bool]) {
                    $values.Add([pscustomobject]@{ value = [bool]$default; version = [string]$package.version; path = $candidate.path })
                }
            }
        } catch {
        }
    }
    if ($values.Count -eq 0) {
        return [pscustomobject]@{ state = "unknown"; source = "extension-default-missing"; version = "" }
    }
    $distinct = @($values | Select-Object -ExpandProperty value -Unique)
    if ($distinct.Count -ne 1) {
        return [pscustomobject]@{ state = "unknown"; source = "extension-default-conflict"; version = "" }
    }
    $latest = @($values | Select-Object -First 1)[0]
    return [pscustomobject]@{
        state = $(if ([bool]$latest.value) { "enabled" } else { "disabled" })
        source = "extension-default"
        version = [string]$latest.version
    }
}

function Get-KiloBrowserAutomationStatus {
    param([string]$ProjectRoot = $script:ProjectRoot)

    try {
        $activeClient = Get-ItlActiveClient
        if ($activeClient -ne "kilocode") {
            return [pscustomobject]@{ applicable = $false; state = "not-applicable"; source = "active-client"; version = "" }
        }
    } catch {
        return [pscustomobject]@{ applicable = $false; state = "not-applicable"; source = "active-client-unknown"; version = "" }
    }

    try {
        $resolvedRoot = Resolve-Agent1cFullPath -Path $ProjectRoot
        $workspacePath = Join-Path $resolvedRoot ".vscode\settings.json"
        $workspace = Get-KiloBooleanSettingFromFile -Path $workspacePath
        if (-not $workspace.valid) {
            return [pscustomobject]@{ applicable = $true; state = "unknown"; source = "workspace-invalid"; version = "" }
        }
        if ($workspace.present) {
            return [pscustomobject]@{
                applicable = $true
                state = $(if ([bool]$workspace.value) { "enabled" } else { "disabled" })
                source = "workspace"
                version = ""
            }
        }

        $explicit = [System.Collections.Generic.List[object]]::new()
        $invalid = 0
        foreach ($candidatePath in @(Get-KiloUserSettingsCandidates)) {
            $candidate = Get-KiloBooleanSettingFromFile -Path $candidatePath
            if (-not $candidate.valid) { $invalid++; continue }
            if ($candidate.present) { $explicit.Add($candidate) }
        }
        if ($invalid -gt 0) {
            return [pscustomobject]@{ applicable = $true; state = "unknown"; source = "user-settings-invalid"; version = "" }
        }
        if ($explicit.Count -gt 1) {
            return [pscustomobject]@{ applicable = $true; state = "unknown"; source = "user-profile-ambiguous"; version = "" }
        }
        if ($explicit.Count -eq 1) {
            return [pscustomobject]@{
                applicable = $true
                state = $(if ([bool]$explicit[0].value) { "enabled" } else { "disabled" })
                source = "user"
                version = ""
            }
        }

        $default = Get-KiloExtensionBrowserDefault
        return [pscustomobject]@{ applicable = $true; state = $default.state; source = $default.source; version = $default.version }
    } catch {
        return [pscustomobject]@{ applicable = $true; state = "unknown"; source = "detection-error"; version = "" }
    }
}

function Get-KiloBrowserAutomationSourceDisplay {
    param(
        [string]$Source,
        [string]$Version = ""
    )

    switch ($Source) {
        "workspace" { return "настройки проекта" }
        "user" { return "настройки пользователя" }
        "extension-default" {
            if ($Version) { return "значение по умолчанию расширения Kilo Code $Version" }
            return "значение по умолчанию расширения Kilo Code"
        }
        "workspace-invalid" { return "некорректные настройки проекта" }
        "user-settings-invalid" { return "некорректные настройки пользователя" }
        "user-profile-ambiguous" { return "неоднозначные настройки профилей пользователя" }
        "extension-default-missing" { return "значение по умолчанию расширения Kilo Code не найдено" }
        "extension-default-conflict" { return "конфликт значений по умолчанию расширения Kilo Code" }
        "detection-error" { return "ошибка определения состояния" }
        "advisory-error" { return "ошибка подготовки рекомендации" }
        default {
            if ($Source) { return $Source }
            return "источник не определён"
        }
    }
}

function Get-KiloBrowserAutomationDisplay {
    param([string]$ProjectRoot = $script:ProjectRoot)

    try {
        $status = Get-KiloBrowserAutomationStatus -ProjectRoot $ProjectRoot
        if (-not $status.applicable) { return $null }
        $source = Get-KiloBrowserAutomationSourceDisplay `
            -Source ([string](Get-ItlObjectPropertyValue -Object $status -Name "source" -Default "")) `
            -Version ([string](Get-ItlObjectPropertyValue -Object $status -Name "version" -Default ""))
        if ($status.state -eq "enabled") {
            return [pscustomobject]@{
                statusLine = "Kilo Browser Automation: включена (источник: $source)."
                adviceLine = "Скрытый Playwright MCP добавляет тысячи токенов контекста, даже когда не используется. Включайте его только для задач в веб-браузере. ITL не изменяет эту настройку."
            }
        } elseif ($status.state -eq "disabled") {
            return [pscustomobject]@{
                statusLine = "Kilo Browser Automation: отключена (источник: $source)."
                adviceLine = ""
            }
        } else {
            return [pscustomobject]@{
                statusLine = "Kilo Browser Automation: состояние не определено (источник: $source)."
                adviceLine = "Проверьте Kilo Settings -> Browser. ITL не изменяет эту настройку."
            }
        }
    } catch {
        return [pscustomobject]@{
            statusLine = "Kilo Browser Automation: состояние не определено (источник: ошибка подготовки рекомендации)."
            adviceLine = "Проверьте Kilo Settings -> Browser. ITL не изменяет эту настройку."
        }
    }
}

function Write-KiloBrowserAutomationStatusLine {
    param([string]$ProjectRoot = $script:ProjectRoot)

    $display = Get-KiloBrowserAutomationDisplay -ProjectRoot $ProjectRoot
    if ($null -ne $display) {
        Write-Host $display.statusLine
    }
}

function Write-KiloBrowserAutomationAdvisory {
    param([string]$ProjectRoot = $script:ProjectRoot)

    $display = Get-KiloBrowserAutomationDisplay -ProjectRoot $ProjectRoot
    if ($null -ne $display -and $display.adviceLine) {
        Write-Host $display.adviceLine
    }
}

function Write-KiloBrowserAutomationSummary {
    param([string]$ProjectRoot = $script:ProjectRoot)

    Write-KiloBrowserAutomationStatusLine -ProjectRoot $ProjectRoot
    Write-KiloBrowserAutomationAdvisory -ProjectRoot $ProjectRoot
}

function Resolve-KiloExecutable {
    $commands = @("kilo.exe", "kilo")
    foreach ($name in $commands) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    }
    foreach ($candidate in @(Get-KiloExtensionPackageCandidates)) {
        $executable = Join-Path $candidate.directory "bin\kilo.exe"
        if (Test-Path -LiteralPath $executable -PathType Leaf) { return $executable }
    }
    throw "KILO_CONTEXT_BENCHMARK_CLI_MISSING: kilo.exe was not found in PATH or installed Kilo extensions."
}

function Get-KiloCliVersion {
    param([string]$Executable)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $text = ((& $Executable --version 2>$null) -join " ").Trim()
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) { return "unknown" }
    if ($text -match '(?<version>\d+\.\d+(?:\.\d+){0,2})') { return $Matches["version"] }
    return $(if ($text) { $text } else { "unknown" })
}

function Invoke-KiloJsonCapture {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $script:ProjectRoot
    )

    Push-Location $WorkingDirectory
    try {
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = @(& $Executable @Arguments 2>$null)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        if ($exitCode -ne 0) { throw "Kilo command failed with exit code $exitCode." }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    } finally {
        Pop-Location
    }
}

function Get-KiloSessionExport {
    param([string]$Executable, [string]$SessionId)
    if ($SessionId -notmatch '^ses_[A-Za-z0-9]+$') { throw "KILO_CONTEXT_BENCHMARK_SESSION_INVALID: invalid Kilo session id '$SessionId'." }
    return (Invoke-KiloJsonCapture -Executable $Executable -Arguments @("export", $SessionId))
}

function Get-KiloBenchmarkPromptProfile {
    param([string]$Text)
    $normalized = $Text.Trim()
    if ($normalized -eq $script:KiloContextBenchmarkPrompt) { return "itl-context-v1" }
    throw "KILO_CONTEXT_BENCHMARK_PROMPT_INVALID: the session must contain the fixed one-message no-tool OK prompt."
}

function ConvertFrom-KiloBenchmarkSessionExport {
    param(
        [object]$Export,
        [string]$SessionId,
        [ValidateSet("cli", "ide")][string]$Surface = "ide",
        [string]$Label = ""
    )

    $messages = @($Export.messages)
    $userMessages = @($messages | Where-Object { [string](Get-ItlObjectPropertyValue -Object $_.info -Name "role") -eq "user" })
    $assistantMessages = @($messages | Where-Object { [string](Get-ItlObjectPropertyValue -Object $_.info -Name "role") -eq "assistant" })
    if ($userMessages.Count -ne 1 -or $assistantMessages.Count -ne 1 -or $messages.Count -ne 2) {
        throw "KILO_CONTEXT_BENCHMARK_MULTI_STEP: expected exactly one user and one assistant message."
    }

    $userTextParts = @($userMessages[0].parts | Where-Object { [string]$_.type -eq "text" })
    if ($userTextParts.Count -ne 1) { throw "KILO_CONTEXT_BENCHMARK_PROMPT_INVALID: expected one user text part." }
    $promptProfile = Get-KiloBenchmarkPromptProfile -Text ([string]$userTextParts[0].text)

    $assistant = $assistantMessages[0]
    $toolParts = @($assistant.parts | Where-Object { [string]$_.type -match '^tool(?:$|[-_])' })
    if ($toolParts.Count -gt 0) { throw "KILO_CONTEXT_BENCHMARK_TOOL_CALL: benchmark sessions must not call tools." }
    $assistantText = (@($assistant.parts | Where-Object { [string]$_.type -eq "text" } | ForEach-Object { [string]$_.text }) -join "").Trim()
    if ($assistantText -notmatch '^(?i:OK)[.!]?$') { throw "KILO_CONTEXT_BENCHMARK_OUTPUT_INVALID: assistant response must be only OK." }

    $tokens = Get-ItlObjectPropertyValue -Object $assistant.info -Name "tokens"
    if ($null -eq $tokens) { throw "KILO_CONTEXT_BENCHMARK_TOKENS_MISSING: assistant token counters are absent." }
    $cache = Get-ItlObjectPropertyValue -Object $tokens -Name "cache"
    $inputTokens = [long](Get-ItlObjectPropertyValue -Object $tokens -Name "input" -Default 0)
    $cacheRead = [long](Get-ItlObjectPropertyValue -Object $cache -Name "read" -Default 0)
    $cacheWrite = [long](Get-ItlObjectPropertyValue -Object $cache -Name "write" -Default 0)
    $outputTokens = [long](Get-ItlObjectPropertyValue -Object $tokens -Name "output" -Default 0)
    $reasoningTokens = [long](Get-ItlObjectPropertyValue -Object $tokens -Name "reasoning" -Default 0)

    return [ordered]@{
        schemaVersion = 1
        kind = "kilo-context-benchmark"
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        surface = $Surface
        label = $Label
        sessionId = $SessionId
        session = [ordered]@{
            provider = [string](Get-ItlObjectPropertyValue -Object $assistant.info -Name "providerID")
            model = [string](Get-ItlObjectPropertyValue -Object $assistant.info -Name "modelID")
            variant = [string](Get-ItlObjectPropertyValue -Object $assistant.info -Name "variant")
            agent = [string](Get-ItlObjectPropertyValue -Object $assistant.info -Name "agent")
            promptProfile = $promptProfile
        }
        tokens = [ordered]@{
            input = $inputTokens
            cacheRead = $cacheRead
            cacheWrite = $cacheWrite
            context = ($inputTokens + $cacheRead + $cacheWrite)
            output = $outputTokens
            reasoning = $reasoningTokens
            cost = [double](Get-ItlObjectPropertyValue -Object $assistant.info -Name "cost" -Default 0)
        }
        validation = [ordered]@{ userMessages = 1; assistantMessages = 1; toolCalls = 0; output = "OK" }
    }
}

function Get-KiloContextBenchmarkEnvironment {
    param([string]$Executable)

    $gitCommit = ""; $gitBranch = ""
    try { $gitCommit = Get-CurrentCommit } catch { }
    try { $gitBranch = Get-CurrentBranch } catch { }
    $workflow = $null; $aiRules = $null
    try { $workflow = Get-DependencyLockEntry -Name "workflowPackage" } catch { }
    try { $aiRules = Get-DependencyLockEntry -Name "aiRules1c" } catch { }
    $mcpServers = @(); $mcpSha = ""
    $kiloPath = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    if (Test-Path -LiteralPath $kiloPath -PathType Leaf) {
        try {
            $mcpSha = (Get-FileHash -LiteralPath $kiloPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $config = Read-ItlJsoncFile -Path $kiloPath
            $mcp = Get-ItlObjectPropertyValue -Object $config -Name "mcp"
            foreach ($property in @($mcp.PSObject.Properties | Sort-Object Name)) {
                $enabledRaw = Get-ItlObjectPropertyValue -Object $property.Value -Name "enabled" -Default $true
                $mcpServers += [ordered]@{ id = [string]$property.Name; enabled = [bool]$enabledRaw }
            }
        } catch {
            $mcpServers = @()
            $mcpSha = "unreadable"
        }
    }
    $browser = Get-KiloBrowserAutomationStatus -ProjectRoot $script:ProjectRoot
    return [ordered]@{
        kiloVersion = Get-KiloCliVersion -Executable $Executable
        git = [ordered]@{ branch = $gitBranch; commit = $gitCommit }
        workflow = [ordered]@{
            ref = [string](Get-ItlObjectPropertyValue -Object $workflow -Name "ref")
            commit = [string](Get-ItlObjectPropertyValue -Object $workflow -Name "commit")
        }
        aiRules = [ordered]@{
            ref = [string](Get-ItlObjectPropertyValue -Object $aiRules -Name "ref")
            commit = [string](Get-ItlObjectPropertyValue -Object $aiRules -Name "commit")
            upstreamCommit = [string](Get-ItlObjectPropertyValue -Object $aiRules -Name "upstreamCommit")
        }
        mcp = [ordered]@{ configSha256 = $mcpSha; servers = @($mcpServers) }
        browserAutomation = [ordered]@{ state = [string]$browser.state; source = [string]$browser.source; observedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
}

function Add-KiloContextBenchmarkEnvironment {
    param([System.Collections.IDictionary]$Summary, [string]$Executable)
    $environment = Get-KiloContextBenchmarkEnvironment -Executable $Executable
    foreach ($key in $environment.Keys) { $Summary[$key] = $environment[$key] }
    return $Summary
}

function Ensure-KiloContextBenchmarkIgnored {
    $relative = ".agent-1c/diagnostics/context-benchmark/"
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) { return }
    $probe = Join-Path $script:ProjectRoot ($relative + "probe.json")
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot check-ignore -q -- $probe
        if ($LASTEXITCODE -eq 0) { return }
        $common = ((& git -C $script:ProjectRoot rev-parse --git-common-dir 2>$null) -join "").Trim()
        if (-not $common) { return }
        if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $script:ProjectRoot $common }
        $exclude = Join-Path (Resolve-Agent1cFullPath -Path $common) "info\exclude"
        $existing = if (Test-Path -LiteralPath $exclude -PathType Leaf) { @(Read-Utf8Lines -Path $exclude) } else { @() }
        if (-not @($existing | Where-Object { ([string]$_).Trim() -eq $relative }).Count) {
            Add-Utf8Text -Path $exclude -Value ($relative + [Environment]::NewLine)
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Save-KiloContextBenchmarkSummary {
    param([System.Collections.IDictionary]$Summary, [string]$Prefix = "context")
    Ensure-KiloContextBenchmarkIgnored
    $directory = Join-Path $script:ProjectRoot ".agent-1c\diagnostics\context-benchmark"
    $safePrefix = ($Prefix -replace '[^A-Za-z0-9._-]', '-')
    if (-not $safePrefix) { $safePrefix = "context" }
    $path = New-TimestampedFilePath -Directory $directory -Prefix $safePrefix -Extension ".json"
    Write-Utf8Text -Path $path -Value (($Summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    return $path
}

function Show-KiloContextBenchmarkSummary {
    param([System.Collections.IDictionary]$Summary, [string]$Path = "")
    Write-Host "Kilo context benchmark: surface=$($Summary.surface) label=$(if ($Summary.label) { $Summary.label } else { '<none>' })"
    Write-Host "Model: $($Summary.session.provider)/$($Summary.session.model) variant=$(if ($Summary.session.variant) { $Summary.session.variant } else { '<default>' }) agent=$($Summary.session.agent)"
    Write-Host "Context tokens: $($Summary.tokens.context) (input=$($Summary.tokens.input), cacheRead=$($Summary.tokens.cacheRead), cacheWrite=$($Summary.tokens.cacheWrite))"
    Write-Host "Completion tokens: output=$($Summary.tokens.output), reasoning=$($Summary.tokens.reasoning)"
    if ($Path) { Write-Host "Summary: $Path" }
}

function Import-KiloContextBenchmarkReference {
    param([string]$Reference, [string]$Executable)
    if ($Reference -match '^ses_[A-Za-z0-9]+$') {
        $export = Get-KiloSessionExport -Executable $Executable -SessionId $Reference
        $summary = ConvertFrom-KiloBenchmarkSessionExport -Export $export -SessionId $Reference -Surface "ide"
        return (Add-KiloContextBenchmarkEnvironment -Summary $summary -Executable $Executable)
    }
    $path = if ([System.IO.Path]::IsPathRooted($Reference)) { $Reference } else { Join-Path $script:ProjectRoot $Reference }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "KILO_CONTEXT_BENCHMARK_REFERENCE_MISSING: $Reference" }
    $summary = (Read-Utf8Text -Path $path) | ConvertFrom-Json
    if ([string]$summary.kind -ne "kilo-context-benchmark" -or [int]$summary.schemaVersion -ne 1) {
        throw "KILO_CONTEXT_BENCHMARK_REFERENCE_INVALID: $Reference"
    }
    return (ConvertTo-Agent1cHashtable $summary)
}

function Compare-KiloContextBenchmarkSummaries {
    param([System.Collections.IDictionary]$Baseline, [System.Collections.IDictionary]$Candidate)
    foreach ($field in @("surface")) {
        $baselineValue = Get-ItlObjectPropertyValue -Object $Baseline -Name $field
        $candidateValue = Get-ItlObjectPropertyValue -Object $Candidate -Name $field
        if ([string]$baselineValue -ne [string]$candidateValue) {
            throw "KILO_CONTEXT_BENCHMARK_INCOMPATIBLE: $field differs ('$baselineValue' vs '$candidateValue')."
        }
    }
    $baselineSession = Get-ItlObjectPropertyValue -Object $Baseline -Name "session"
    $candidateSession = Get-ItlObjectPropertyValue -Object $Candidate -Name "session"
    foreach ($field in @("provider", "model", "variant", "agent", "promptProfile")) {
        $baselineValue = Get-ItlObjectPropertyValue -Object $baselineSession -Name $field
        $candidateValue = Get-ItlObjectPropertyValue -Object $candidateSession -Name $field
        if ([string]$baselineValue -ne [string]$candidateValue) {
            throw "KILO_CONTEXT_BENCHMARK_INCOMPATIBLE: session.$field differs ('$baselineValue' vs '$candidateValue')."
        }
    }
    $baselineTokenRecord = Get-ItlObjectPropertyValue -Object $Baseline -Name "tokens"
    $candidateTokenRecord = Get-ItlObjectPropertyValue -Object $Candidate -Name "tokens"
    $baselineTokens = [long](Get-ItlObjectPropertyValue -Object $baselineTokenRecord -Name "context" -Default 0)
    $candidateTokens = [long](Get-ItlObjectPropertyValue -Object $candidateTokenRecord -Name "context" -Default 0)
    $delta = $candidateTokens - $baselineTokens
    $percent = if ($baselineTokens -eq 0) { 0.0 } else { [Math]::Round(($delta * 100.0) / $baselineTokens, 2) }
    return [ordered]@{
        schemaVersion = 1
        kind = "kilo-context-benchmark-comparison"
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        surface = Get-ItlObjectPropertyValue -Object $Baseline -Name "surface"
        baseline = [ordered]@{ sessionId = Get-ItlObjectPropertyValue -Object $Baseline -Name "sessionId"; label = Get-ItlObjectPropertyValue -Object $Baseline -Name "label"; context = $baselineTokens }
        candidate = [ordered]@{ sessionId = Get-ItlObjectPropertyValue -Object $Candidate -Name "sessionId"; label = Get-ItlObjectPropertyValue -Object $Candidate -Name "label"; context = $candidateTokens }
        delta = [ordered]@{ context = $delta; percent = $percent }
        session = $baselineSession
    }
}

function Invoke-KiloContextBenchmarkRun {
    param([string]$Executable)
    if (-not $ConfirmTokenSpend) { throw "KILO_CONTEXT_BENCHMARK_CONFIRM_REQUIRED: run mode spends one model request; pass -ConfirmTokenSpend." }
    if ([string]::IsNullOrWhiteSpace($BenchmarkModel) -or $BenchmarkModel -notmatch '^[^/]+/.+$') {
        throw "KILO_CONTEXT_BENCHMARK_MODEL_REQUIRED: pass -BenchmarkModel provider/model."
    }

    $title = "ITL context benchmark v1 CLI $([guid]::NewGuid().ToString('N'))"
    $tempRoot = Get-Agent1cTempRoot
    $stdoutPath = Join-Path $tempRoot ("itl-context-benchmark-" + [guid]::NewGuid().ToString("N") + ".out")
    $stderrPath = Join-Path $tempRoot ("itl-context-benchmark-" + [guid]::NewGuid().ToString("N") + ".err")
    $arguments = @("run", "--format", "json", "--agent", "code", "--model", $BenchmarkModel, "--title", $title, "--dir", $script:ProjectRoot)
    if ($BenchmarkVariant) { $arguments += @("--variant", $BenchmarkVariant) }
    # Kilo declares message as a variadic positional. Passing one spaced native
    # argument through Windows PowerShell/Bun preserves the wrapper quotes in
    # the stored prompt, so pass words and let Kilo join the positional array.
    $arguments += @($script:KiloContextBenchmarkPrompt -split ' ')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $encodedExecutable = [Convert]::ToBase64String($utf8.GetBytes($Executable))
    $encodedArguments = [Convert]::ToBase64String($utf8.GetBytes(($arguments | ConvertTo-Json -Compress)))
    $runner = '$utf8=New-Object System.Text.UTF8Encoding $false;' +
        '$exe=$utf8.GetString([Convert]::FromBase64String("' + $encodedExecutable + '"));' +
        '$argsJson=$utf8.GetString([Convert]::FromBase64String("' + $encodedArguments + '"));' +
        '$nativeArgs=@($argsJson|ConvertFrom-Json);' +
        '& $exe @nativeArgs;exit $LASTEXITCODE'
    $encodedRunner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))
    $process = $null
    try {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + $encodedRunner) -WorkingDirectory $script:ProjectRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit($script:KiloContextBenchmarkTimeoutSeconds * 1000)) {
            if ($env:OS -eq "Windows_NT") { & taskkill.exe /PID $process.Id /T /F *> $null } else { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            throw "KILO_CONTEXT_BENCHMARK_TIMEOUT: kilo run exceeded $($script:KiloContextBenchmarkTimeoutSeconds) seconds."
        }
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = [int]$process.ExitCode
        if ($exitCode -ne 0) {
            $errorText = if (Test-Path -LiteralPath $stderrPath) { ((Get-Content -LiteralPath $stderrPath -Encoding UTF8 | Select-Object -Last 5) -join " ") } else { "" }
            throw "KILO_CONTEXT_BENCHMARK_RUN_FAILED: kilo run exited $exitCode. $errorText"
        }
        $sessions = Invoke-KiloJsonCapture -Executable $Executable -Arguments @("session", "list", "--format", "json", "--search", $title, "--max-count", "5")
        $match = @($sessions | Where-Object { [string]$_.title -eq $title } | Select-Object -First 1)
        if ($match.Count -ne 1) { throw "KILO_CONTEXT_BENCHMARK_SESSION_MISSING: completed CLI session '$title' was not found." }
        $export = Get-KiloSessionExport -Executable $Executable -SessionId ([string]$match[0].id)
        $summary = ConvertFrom-KiloBenchmarkSessionExport -Export $export -SessionId ([string]$match[0].id) -Surface "cli" -Label $BenchmarkLabel
        return (Add-KiloContextBenchmarkEnvironment -Summary $summary -Executable $Executable)
    } finally {
        foreach ($path in @($stdoutPath, $stderrPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-KiloContextBenchmark {
    if ((Get-ItlActiveClient) -ne "kilocode") { throw "KILO_CONTEXT_BENCHMARK_CLIENT_UNSUPPORTED: active client must be kilocode." }
    $executable = Resolve-KiloExecutable
    if ($BenchmarkMode -eq "run") {
        $summary = Invoke-KiloContextBenchmarkRun -Executable $executable
        $path = Save-KiloContextBenchmarkSummary -Summary $summary -Prefix "cli"
        Show-KiloContextBenchmarkSummary -Summary $summary -Path $path
        return
    }
    if ($BenchmarkMode -eq "analyze") {
        if (-not $BenchmarkSessionId) { throw "KILO_CONTEXT_BENCHMARK_SESSION_REQUIRED: analyze mode requires -BenchmarkSessionId." }
        $export = Get-KiloSessionExport -Executable $executable -SessionId $BenchmarkSessionId
        $summary = ConvertFrom-KiloBenchmarkSessionExport -Export $export -SessionId $BenchmarkSessionId -Surface "ide" -Label $BenchmarkLabel
        $summary = Add-KiloContextBenchmarkEnvironment -Summary $summary -Executable $executable
        $path = Save-KiloContextBenchmarkSummary -Summary $summary -Prefix "ide"
        Show-KiloContextBenchmarkSummary -Summary $summary -Path $path
        return
    }
    if (-not $BenchmarkBaseline -or -not $BenchmarkCandidate) {
        throw "KILO_CONTEXT_BENCHMARK_REFERENCES_REQUIRED: compare mode requires -BenchmarkBaseline and -BenchmarkCandidate."
    }
    $baseline = Import-KiloContextBenchmarkReference -Reference $BenchmarkBaseline -Executable $executable
    $candidate = Import-KiloContextBenchmarkReference -Reference $BenchmarkCandidate -Executable $executable
    $comparison = Compare-KiloContextBenchmarkSummaries -Baseline $baseline -Candidate $candidate
    $path = Save-KiloContextBenchmarkSummary -Summary $comparison -Prefix "compare"
    Write-Host "Kilo context comparison: baseline=$($comparison.baseline.context), candidate=$($comparison.candidate.context), delta=$($comparison.delta.context) ($($comparison.delta.percent)%)."
    Write-Host "Summary: $path"
}
