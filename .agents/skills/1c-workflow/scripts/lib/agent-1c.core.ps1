function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "== $Text =="
}

function Get-Utf8Encoding {
    return New-Object System.Text.UTF8Encoding $false
}

function Get-Utf8BomEncoding {
    return New-Object System.Text.UTF8Encoding $true
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, (Get-Utf8Encoding))
}

function Read-Utf8Lines {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines($Path, (Get-Utf8Encoding))
}

function Write-Utf8Text {
    param(
        [string]$Path,
        [string]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Value, (Get-Utf8Encoding))
}

function Add-Utf8Text {
    param(
        [string]$Path,
        [string]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [System.IO.File]::AppendAllText($Path, $Value, (Get-Utf8Encoding))
}

function New-TimestampedFilePath {
    param(
        [string]$Directory,
        [string]$Prefix,
        [string]$Extension
    )

    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $name = "{0}{1}-{2}-{3}{4}" -f $Prefix, (Get-Date -Format "yyyyMMdd-HHmmss-fff"), $PID, $suffix, $Extension
    return Join-Path $Directory $name
}

function Resolve-RunFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Write-RunStatus {
    param(
        [ValidateSet("running", "succeeded", "failed")]
        [string]$Status,
        [object]$ExitCode = $null,
        [string]$ErrorMessage = ""
    )

    if ([string]::IsNullOrWhiteSpace($RunStatusPath)) {
        return
    }

    $script:ResolvedRunStatusPath = Resolve-RunFilePath -Path $RunStatusPath
    if ($RunLogPath) {
        $script:ResolvedRunLogPath = Resolve-RunFilePath -Path $RunLogPath
    }

    $now = Get-Date
    $finishedAt = $null
    if ($Status -ne "running") {
        $finishedAt = $now.ToString("o")
    }

    $payload = [ordered]@{
        schemaVersion = 1
        status = $Status
        action = $Action
        projectRoot = $script:ProjectRoot
        pid = $PID
        startedAt = $script:RunStartedAt.ToString("o")
        updatedAt = $now.ToString("o")
        finishedAt = $finishedAt
        exitCode = $ExitCode
        lastLogPath = $(if ($script:LastLogPath) { [string]$script:LastLogPath } else { "" })
        runLogPath = $script:ResolvedRunLogPath
        errorMessage = $ErrorMessage
    }

    Write-Utf8Text -Path $script:ResolvedRunStatusPath -Value (($payload | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

function Import-DotEnv {
    param(
        [string]$Path,
        [switch]$Overwrite
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Read-Utf8Lines -Path $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) {
            continue
        }

        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($Overwrite -or -not [Environment]::GetEnvironmentVariable($name, "Process")) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Read-ProjectConfig {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $script:Config = Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json
    } else {
        $script:Config = [pscustomobject]@{}
    }
}

function Get-ConfigValue {
    param(
        [string]$Path,
        [object]$Default = $null
    )

    $node = $script:Config
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node) {
            return $Default
        }

        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) {
            return $Default
        }

        $node = $prop.Value
    }

    if ($null -eq $node) {
        return $Default
    }
    if ($node -is [string] -and $node -eq "") {
        return $Default
    }

    return $node
}

function Get-EnvValue {
    param(
        [string]$Name,
        [object]$Default = $null
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($value) {
        return $value
    }

    $prefixedName = "AGENT_1C_$Name"
    $value = [Environment]::GetEnvironmentVariable($prefixedName, "Process")
    if ($value) {
        return $value
    }

    return $Default
}

function Get-Setting {
    param(
        [string]$EnvName,
        [string]$ConfigName,
        [object]$Default = $null
    )

    $value = Get-EnvValue -Name $EnvName
    if ($value) {
        return $value
    }

    return Get-ConfigValue -Path $ConfigName -Default $Default
}

function ConvertTo-BoolSetting {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    $yesMarker = -join ([char[]](0x0434, 0x0430))
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if (@("1", "true", "yes", "y", "on", $yesMarker) -contains $text) {
        return $true
    }
    if (@("0", "false", "no", "n", "off", $noMarker) -contains $text) {
        return $false
    }

    throw "Invalid boolean setting value: $Value"
}

function ConvertTo-DependencyMode {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "fresh"
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq "fresh" -or $text -eq "latest") {
        return "fresh"
    }
    if ($text -eq "locked" -or $text -eq "pinned") {
        return "locked"
    }

    throw "Invalid dependency mode: $Value. Use fresh or locked."
}

function ConvertTo-Agent1cHashtable {
    param([AllowNull()][object]$Object)

    $hash = [ordered]@{}
    if ($null -eq $Object) {
        return $hash
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $hash[$key] = $Object[$key]
        }
        return $hash
    }
    foreach ($property in $Object.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }
    return $hash
}

function Require-Value {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Required value is missing: $Name"
    }

    return $Value
}

function Resolve-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Set-ProjectContext {
    param([string]$Root)

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $script:ProjectRoot = $resolvedRoot
    $script:ConfigPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot ".agent-1c\project.json"))
    $script:DependencyLockPath = Join-Path $resolvedRoot ".agent-1c\dependency-lock.json"
    Import-DotEnv -Path (Join-Path $resolvedRoot ".dev.env") -Overwrite
    Read-ProjectConfig
}

function Invoke-InProjectContext {
    param(
        [string]$Root,
        [scriptblock]$ScriptBlock
    )

    $previousRoot = $script:ProjectRoot
    $previousConfigPath = $script:ConfigPath
    $previousDependencyLockPath = $script:DependencyLockPath
    $previousConfig = $script:Config
    try {
        Set-ProjectContext -Root $Root
        & $ScriptBlock
    } finally {
        $script:ProjectRoot = $previousRoot
        $script:ConfigPath = $previousConfigPath
        $script:DependencyLockPath = $previousDependencyLockPath
        $script:Config = $previousConfig
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    }
}

function Test-DirectoryExists {
    param([string]$Path)
    if (-not $Path) {
        return $false
    }

    try {
        return [System.IO.Directory]::Exists($Path)
    } catch {
        return $false
    }
}

function Get-ChildDirectoriesSafe {
    param([string]$Path)
    if (-not (Test-DirectoryExists -Path $Path)) {
        return @()
    }

    try {
        return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Resolve-InfoBasePath {
    param([string]$Path)
    if (-not $Path) {
        return $Path
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return Resolve-ProjectPath $Path
}

function ConvertTo-SafeName {
    param([string]$Name)
    $safe = ($Name.Trim() -replace "[^a-zA-Z0-9_.-]+", "-").Trim("-").ToLowerInvariant()
    if (-not $safe) {
        $safe = "dev-branch-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    }
    return $safe
}

function Invoke-GitCommand {
    param(
        [string]$Root,
        [string[]]$Arguments,
        [switch]$PassThru
    )

    $gitArgs = @("-C", $Root) + @($Arguments)
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & git @gitArgs 2>&1
        if ($LASTEXITCODE -is [int]) {
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $standardOutput = @()
    $errorOutput = @()
    $displayOutput = @()
    foreach ($item in @($rawOutput)) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        $displayOutput += $text
        if (-not ($item -is [System.Management.Automation.ErrorRecord])) {
            $standardOutput += $text
        } else {
            $errorOutput += $text
        }
    }

    $outputToLog = if ($exitCode -ne 0 -or (-not $PassThru)) { $displayOutput } else { $errorOutput }
    foreach ($line in $outputToLog) {
        if ($line) {
            Write-Host $line
        }
    }

    if ($exitCode -ne 0) {
        throw "Git failed: git -C `"$Root`" $($Arguments -join ' ')"
    }

    if ($PassThru) {
        return $standardOutput
    }
}

function Invoke-Git {
    param([string[]]$Arguments)
    Invoke-GitCommand -Root $script:ProjectRoot -Arguments $Arguments
}

function Invoke-GitAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    Invoke-GitCommand -Root $Root -Arguments $Arguments
}

function Get-GitOutput {
    param([string[]]$Arguments)
    return (Invoke-GitCommand -Root $script:ProjectRoot -Arguments $Arguments -PassThru)
}

function Get-GitOutputAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    return (Invoke-GitCommand -Root $Root -Arguments $Arguments -PassThru)
}

function Get-CurrentBranch {
    return (Get-GitOutput @("branch", "--show-current")).Trim()
}

function Get-CurrentCommit {
    return (Get-GitOutput @("rev-parse", "HEAD")).Trim()
}

function Test-GitCommitExists {
    param([string]$Commit)
    if (-not $Commit) {
        return $false
    }

    & git -C $script:ProjectRoot cat-file -e "$Commit^{commit}" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitHasAnyCommit {
    & git -C $script:ProjectRoot rev-parse --verify --quiet HEAD *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitBranchExists {
    param([string]$Branch)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot show-ref --verify --quiet "refs/heads/$Branch"
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-GitHeadBranch {
    $branch = & git -C $script:ProjectRoot symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        return ([string]$branch).Trim()
    }
    return ""
}

function Set-GitHeadBranch {
    param([string]$Branch)
    & git -C $script:ProjectRoot symbolic-ref HEAD "refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$script:ProjectRoot`" symbolic-ref HEAD refs/heads/$Branch"
    }
}

function Test-GitHasRemote {
    $remote = & git -C $script:ProjectRoot remote
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return [bool]($remote | Select-Object -First 1)
}

function Test-GitHasUpstream {
    & git -C $script:ProjectRoot rev-parse --abbrev-ref --symbolic-full-name "@{u}" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-IgnorableLocalGitStatusLine {
    param([string]$Line)

    if (-not $Line -or -not $Line.StartsWith("?? ")) {
        return $false
    }

    $path = $Line.Substring(3).Trim()
    $normalizedPath = $path -replace "\\", "/"
    if ($normalizedPath -eq ".kilo/kilo.json" -or $normalizedPath -eq ".kilo/kilo.jsonc" -or $normalizedPath -eq ".codex/config.toml") {
        return $true
    }

    if ($normalizedPath -eq ".agent-1c/mcp/") {
        return $true
    }

    if ($normalizedPath -eq ".kilo/" -or $normalizedPath -eq ".codex/") {
        $localDirName = $(if ($normalizedPath -eq ".kilo/") { ".kilo" } else { ".codex" })
        $allowedFiles = $(if ($normalizedPath -eq ".kilo/") { @(".kilo/kilo.json", ".kilo/kilo.jsonc") } else { @(".codex/config.toml") })
        $localDir = Join-Path $script:ProjectRoot $localDirName
        if (-not (Test-Path -LiteralPath $localDir -PathType Container -ErrorAction SilentlyContinue)) {
            return $false
        }

        $files = @(Get-ChildItem -LiteralPath $localDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -lt 1) {
            return $false
        }

        $rootPath = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\", "/") + "\"
        foreach ($file in $files) {
            $filePath = [System.IO.Path]::GetFullPath($file.FullName)
            if (-not $filePath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }

            $relativePath = $filePath.Substring($rootPath.Length) -replace "\\", "/"
            if ($allowedFiles -notcontains $relativePath) {
                return $false
            }
        }

        return $true
    }

    return $false
}

function Test-GitHasChanges {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status"
    }
    $effectiveStatus = @($status | Where-Object { -not (Test-IgnorableLocalGitStatusLine -Line ([string]$_)) })
    return [bool]($effectiveStatus | Select-Object -First 1)
}

function Assert-CleanGit {
    if (Test-GitHasChanges) {
        throw "Git worktree is not clean. Commit, stash, or discard changes before this action."
    }
}

function Get-FullPathNormalized {
    param([string]$Path)

    if (-not $Path) {
        return ""
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Get-GitWorktrees {
    $output = & git -C $script:ProjectRoot worktree list --porcelain
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $items = @()
    $current = $null
    foreach ($line in @($output)) {
        if (-not $line) {
            if ($null -ne $current) {
                $items += [pscustomobject]$current
                $current = $null
            }
            continue
        }

        if ($line -like "worktree *") {
            if ($null -ne $current) {
                $items += [pscustomobject]$current
            }
            $current = [ordered]@{
                path = $line.Substring("worktree ".Length)
                head = ""
                branch = ""
                bare = $false
                detached = $false
            }
            continue
        }

        if ($null -eq $current) {
            continue
        }

        if ($line -like "HEAD *") {
            $current.head = $line.Substring("HEAD ".Length)
        } elseif ($line -like "branch *") {
            $branch = $line.Substring("branch ".Length)
            $current.branch = ($branch -replace "^refs/heads/", "")
        } elseif ($line -eq "bare") {
            $current.bare = $true
        } elseif ($line -eq "detached") {
            $current.detached = $true
        }
    }

    if ($null -ne $current) {
        $items += [pscustomobject]$current
    }
    return @($items)
}

function Find-GitWorktreeByBranch {
    param([string]$Branch)

    foreach ($worktree in Get-GitWorktrees) {
        if ($worktree.branch -eq $Branch) {
            return $worktree
        }
    }
    return $null
}

function Get-MainWorktreePath {
    $worktrees = @(Get-GitWorktrees)
    if ($worktrees.Count -gt 0) {
        return [System.IO.Path]::GetFullPath($worktrees[0].path)
    }
    return $script:ProjectRoot
}

function Ensure-GitRepository {
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git"))) {
        Invoke-Git @("init")
    }
}

function Get-MasterBranch {
    return "master"
}

function Get-ExportPath {
    return "src/cf"
}

function Get-ExtensionsPath {
    return (Get-ConfigValue -Path "extensionsPath" -Default "src/cfe")
}

function Checkout-Master {
    $masterBranch = Get-MasterBranch
    Ensure-GitRepository

    if (-not (Test-GitHasAnyCommit)) {
        $currentBranch = Get-GitHeadBranch
        if ($currentBranch -ne $masterBranch) {
            Set-GitHeadBranch -Branch $masterBranch
        }
        Write-Host "Using empty Git repository on branch: $masterBranch"
        return
    }

    & git -C $script:ProjectRoot rev-parse --verify --quiet $masterBranch *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git @("checkout", $masterBranch)
    } else {
        Invoke-Git @("checkout", "-b", $masterBranch)
    }

    if ((Test-GitHasRemote) -and (Test-GitHasUpstream)) {
        Invoke-Git @("pull", "--ff-only")
    }
}

function Test-GitHasStagedChanges {
    param([string[]]$PathSpec = @("."))

    $arguments = @("diff", "--cached", "--quiet", "--") + @($PathSpec)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot @arguments
        if ($LASTEXITCODE -eq 0) {
            return $false
        }
        if ($LASTEXITCODE -eq 1) {
            return $true
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    throw "Cannot read staged Git changes for: $($PathSpec -join ', ')"
}

function Test-GitHeadContainsPath {
    param([string]$RepoPath)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot cat-file -e "HEAD:$RepoPath" *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-GitStatusForPathSpec {
    param([string[]]$PathSpec = @("."))

    $arguments = @("status", "--short", "--") + @($PathSpec)
    $output = & git -C $script:ProjectRoot @arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return "<cannot read git status>"
    }
    if (-not $output) {
        return "<empty>"
    }
    return ($output -join [Environment]::NewLine)
}

function Commit-IfChanged {
    param(
        [string]$Message,
        [string[]]$PathSpec = @("."),
        [switch]$RequireChanges,
        [switch]$ForceAdd
    )

    $addArgs = @("add", "--all")
    if ($ForceAdd) {
        $addArgs += "--force"
    }
    $addArgs += "--"
    $addArgs += @($PathSpec)
    Invoke-Git $addArgs
    if (Test-GitHasStagedChanges -PathSpec $PathSpec) {
        $commitArgs = @("commit", "-m", $Message, "--") + @($PathSpec)
        Invoke-Git $commitArgs
        return $true
    } elseif ($RequireChanges) {
        $status = Get-GitStatusForPathSpec -PathSpec $PathSpec
        throw "No Git changes to commit for: $($PathSpec -join ', '). Expected files from the 1C configuration dump. Git status for this path: $status"
    } else {
        Write-Host "No Git changes to commit for: $($PathSpec -join ', ')"
        return $false
    }
}

function Assert-BaselineDumpCommitted {
    param([string]$ExportPath)

    $normalizedExportPath = (($ExportPath -replace "\\", "/").TrimEnd("/"))
    $dumpInfoRepoPath = "$normalizedExportPath/ConfigDumpInfo.xml"
    if (Test-GitHeadContainsPath -RepoPath $dumpInfoRepoPath) {
        return
    }

    $status = Get-GitStatusForPathSpec -PathSpec @($ExportPath)
    throw "Baseline configuration dump was not committed to HEAD: $dumpInfoRepoPath. Git status for $($ExportPath): $status. Check .gitignore and make sure '$normalizedExportPath' is tracked."
}

function Ensure-GitIgnore {
    $gitignorePath = Join-Path $script:ProjectRoot ".gitignore"
    $required = @(
        ".dev.env",
        "build/result/",
        "build/event-log/",
        "testResults.xml",
        "*.cf",
        "*.cfe",
        "*.dt",
        "*.log",
        "logs/",
        ".agent-1c/dev-branches/",
        ".agent-1c/event-log-baselines/",
        ".agent-1c/runs/",
        ".agent-1c/infobases/",
        ".agent-1c/tools/event-log-exporter/",
        ".agent-1c/tools/auto-update/",
        ".agent-1c/tools/data-mcp/",
        ".agent-1c/tools/vanessa-automation/",
        ".agent-1c/tools/vanessa-mcp/",
        ".agent-1c/tools/roctup-mcp-toolkit/",
        ".agent-1c/mcp/",
        "build/data-mcp-tools-loader/",
        "build/test-results/",
        ".codex/config.toml",
        ".kilo/kilo.json",
        ".kilo/kilo.jsonc"
    )

    if (Test-Path -LiteralPath $gitignorePath) {
        $current = Read-Utf8Lines -Path $gitignorePath
    } else {
        $current = @()
    }

    $linesToAdd = @()
    foreach ($line in $required) {
        if ($current -notcontains $line) {
            $linesToAdd += $line
        }
    }

    if ($linesToAdd.Count -gt 0) {
        Add-Utf8Text -Path $gitignorePath -Value (($linesToAdd -join [Environment]::NewLine) + [Environment]::NewLine)
    }
}

function Resolve-PlatformExecutablePath {
    param([string]$Path)

    if (-not $Path) {
        return $Path
    }

    $resolvedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (Test-DirectoryExists -Path $resolvedPath) {
        return (Join-Path $resolvedPath "1cv8.exe")
    }

    return $resolvedPath
}

function Get-PlatformPath {
    $value = Require-Value "PLATFORM_PATH or project.platformPath" (Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath")
    return Resolve-PlatformExecutablePath -Path $value
}

function Get-SourceUsesRepository {
    $value = Get-Setting -EnvName "SOURCE_USES_REPOSITORY" -ConfigName "sourceUsesRepository" -Default $true
    return ConvertTo-BoolSetting -Value $value -Default $true
}

function Get-WebPublishByDefault {
    $envValue = Get-EnvValue -Name "WEB_PUBLISH_BY_DEFAULT"
    if ($null -ne $envValue -and -not [string]::IsNullOrWhiteSpace([string]$envValue)) {
        return ConvertTo-BoolSetting -Value $envValue -Default $false
    }

    return ConvertTo-BoolSetting -Value (Get-ConfigValue -Path "web.publishByDefault" -Default $false) -Default $false
}

function Get-WebPublishAuto {
    $envValue = Get-EnvValue -Name "WEB_PUBLISH_AUTO"
    if ($null -ne $envValue -and -not [string]::IsNullOrWhiteSpace([string]$envValue)) {
        return ConvertTo-BoolSetting -Value $envValue -Default $false
    }

    return ConvertTo-BoolSetting -Value (Get-ConfigValue -Path "web.publishAuto" -Default $false) -Default $false
}

function Get-DefaultWebInstPath {
    $rawPlatformPath = Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath"
    if (-not $rawPlatformPath) {
        return ""
    }

    $platformPath = Resolve-PlatformExecutablePath -Path $rawPlatformPath
    if (-not $platformPath) {
        return ""
    }

    $platformDirectory = Split-Path -Parent $platformPath
    if (-not $platformDirectory) {
        return ""
    }

    $candidate = Join-Path $platformDirectory "webinst.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
        return $candidate
    }

    return ""
}

function Get-WebInstPath {
    $configured = Get-Setting -EnvName "WEBINST_PATH" -ConfigName "web.webInstPath"
    if ($configured) {
        return [Environment]::ExpandEnvironmentVariables(([string]$configured).Trim())
    }

    return Get-DefaultWebInstPath
}

function Remove-ApacheInlineComment {
    param([string]$Line)

    $inQuote = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
        } elseif ($ch -eq '#' -and -not $inQuote) {
            return $Line.Substring(0, $i)
        }
    }

    return $Line
}

function ConvertFrom-ApacheConfigToken {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = $Value.Trim()
    if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function Resolve-ApacheConfigPathValue {
    param(
        [AllowNull()][string]$Value,
        [hashtable]$Variables,
        [string]$BasePath
    )

    $text = ConvertFrom-ApacheConfigToken -Value $Value
    if (-not $text) {
        return ""
    }

    foreach ($key in @($Variables.Keys)) {
        $text = $text.Replace(('${' + $key + '}'), [string]$Variables[$key])
    }
    $text = [Environment]::ExpandEnvironmentVariables($text)

    if (-not [System.IO.Path]::IsPathRooted($text) -and $BasePath) {
        $text = Join-Path $BasePath $text
    }

    try {
        return [System.IO.Path]::GetFullPath($text)
    } catch {
        return $text
    }
}

function Get-ApacheListenPort {
    param([string]$Value)

    $token = ConvertFrom-ApacheConfigToken -Value (($Value.Trim() -split "\s+")[0])
    if ($token -match '^\d+$') {
        return [int]$token
    }
    if ($token -match ':(\d+)$') {
        return [int]$matches[1]
    }
    if ($token -match '\]:(\d+)$') {
        return [int]$matches[1]
    }
    return 80
}

function Read-ApacheHttpdConfig {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $confDirectory = Split-Path -Parent $fullPath
    $defaultServerRoot = Split-Path -Parent $confDirectory
    $variables = @{}
    $serverRoot = $defaultServerRoot
    $documentRoot = ""
    $listenPort = 80

    foreach ($rawLine in Read-Utf8Lines -Path $fullPath) {
        $line = (Remove-ApacheInlineComment -Line $rawLine).Trim()
        if (-not $line) {
            continue
        }

        if ($line -match '^\s*Define\s+([^\s]+)\s+(.+)$') {
            $name = $matches[1]
            $value = Resolve-ApacheConfigPathValue -Value $matches[2] -Variables $variables -BasePath $serverRoot
            $variables[$name] = $value
            continue
        }

        if ($line -match '^\s*ServerRoot\s+(.+)$') {
            $serverRoot = Resolve-ApacheConfigPathValue -Value $matches[1] -Variables $variables -BasePath $serverRoot
            continue
        }

        if (-not $documentRoot -and $line -match '^\s*DocumentRoot\s+(.+)$') {
            $documentRoot = Resolve-ApacheConfigPathValue -Value $matches[1] -Variables $variables -BasePath $serverRoot
            continue
        }

        if ($line -match '^\s*Listen\s+(.+)$') {
            $listenPort = Get-ApacheListenPort -Value $matches[1]
            continue
        }
    }

    if (-not $documentRoot) {
        throw "DocumentRoot was not found in Apache config: $fullPath"
    }

    $urlBase = if ($listenPort -eq 80) { "http://localhost" } else { "http://localhost:$listenPort" }
    return [pscustomobject]@{
        found = $true
        httpdConfPath = $fullPath
        documentRoot = $documentRoot
        listenPort = $listenPort
        publicationRoot = (Join-Path $documentRoot "1c")
        publicationUrlBase = $urlBase
    }
}

function Get-ExecutablePathFromCommandLine {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }

    $text = $CommandLine.Trim()
    if ($text.StartsWith('"')) {
        $endQuote = $text.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            return $text.Substring(1, $endQuote - 1)
        }
    }

    if ($text -match '^(.*?\.exe)(\s|$)') {
        return $matches[1]
    }

    return ""
}

function Get-CommandLineSwitchValue {
    param(
        [AllowNull()][string]$CommandLine,
        [string]$Switch
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }

    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Switch) + '\s+(?:"([^"]+)"|(\S+))'
    if ($CommandLine -match $pattern) {
        if ($matches[1]) {
            return $matches[1]
        }
        return $matches[2]
    }

    return ""
}

function New-ApacheConfigCandidate {
    param(
        [string]$Path,
        [string]$Source
    )

    if (-not $Path) {
        return $null
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    return [pscustomobject]@{
        path = [System.IO.Path]::GetFullPath($resolved)
        source = $Source
    }
}

function Get-ApacheConfigCandidates {
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}

    $addCandidate = {
        param([string]$Path, [string]$Source)
        $candidate = New-ApacheConfigCandidate -Path $Path -Source $Source
        if ($candidate -and -not $seen.ContainsKey($candidate.path.ToLowerInvariant())) {
            $seen[$candidate.path.ToLowerInvariant()] = $true
            [void]$candidates.Add($candidate)
        }
    }

    $configuredConf = Get-Setting -EnvName "APACHE_HTTPD_CONF_PATH" -ConfigName "web.apacheHttpdConfPath"
    if ($configuredConf) {
        & $addCandidate $configuredConf "APACHE_HTTPD_CONF_PATH"
    }

    & $addCandidate (Join-Path (Get-ApacheInstallRoot) "conf\httpd.conf") "APACHE_INSTALL_ROOT"

    try {
        $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            ($_.PathName -match 'httpd\.exe') -or ($_.Name -match 'apache|httpd') -or ($_.DisplayName -match 'apache|httpd')
        })
        foreach ($service in $services) {
            $serviceRoot = Get-CommandLineSwitchValue -CommandLine $service.PathName -Switch "-d"
            $serviceConf = Get-CommandLineSwitchValue -CommandLine $service.PathName -Switch "-f"
            if ($serviceConf) {
                if (-not [System.IO.Path]::IsPathRooted($serviceConf) -and $serviceRoot) {
                    $serviceConf = Join-Path $serviceRoot $serviceConf
                }
                & $addCandidate $serviceConf "Windows service $($service.Name)"
            }

            $serviceExe = Get-ExecutablePathFromCommandLine -CommandLine $service.PathName
            if ($serviceExe) {
                $exeRoot = Split-Path -Parent (Split-Path -Parent $serviceExe)
                & $addCandidate (Join-Path $exeRoot "conf\httpd.conf") "Windows service $($service.Name)"
            }
        }
    } catch {
        # Service discovery is best-effort; continue with PATH and standard folders.
    }

    $httpdCommand = Get-Command httpd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($httpdCommand -and $httpdCommand.Source) {
        $httpdRoot = Split-Path -Parent (Split-Path -Parent $httpdCommand.Source)
        & $addCandidate (Join-Path $httpdRoot "conf\httpd.conf") "PATH httpd.exe"
    }

    $standardRoots = @(
        "C:\Apache24",
        "C:\Apache2.4",
        "C:\Apache",
        (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "Apache24"),
        (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "Apache Software Foundation\Apache2.4")
    )
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    if ($programFilesX86) {
        $standardRoots += (Join-Path $programFilesX86 "Apache Software Foundation\Apache2.4")
    }

    foreach ($root in @($standardRoots | Where-Object { $_ } | Select-Object -Unique)) {
        & $addCandidate (Join-Path $root "conf\httpd.conf") "standard path"
    }

    return @($candidates)
}

function Find-ApacheConfig {
    $errors = @()
    foreach ($candidate in Get-ApacheConfigCandidates) {
        try {
            $parsed = Read-ApacheHttpdConfig -Path $candidate.path
            $parsed | Add-Member -NotePropertyName source -NotePropertyValue $candidate.source -Force
            return $parsed
        } catch {
            $errors += "$($candidate.path): $($_.Exception.Message)"
        }
    }

    $message = "Apache/httpd config was not found. Prepare the web server outside ITL workflow, or set APACHE_HTTPD_CONF_PATH/WEB_PUBLICATION_ROOT/WEB_PUBLICATION_URL_BASE, then rerun detect-web-publication or check-tools."
    if ($errors.Count -gt 0) {
        $message += " Checked candidates: $($errors -join '; ')"
    }

    return [pscustomobject]@{
        found = $false
        httpdConfPath = ""
        documentRoot = ""
        listenPort = $null
        publicationRoot = ""
        publicationUrlBase = ""
        source = ""
        message = $message
    }
}

function Get-ConfigUrlBaseOverride {
    $envValue = Get-EnvValue -Name "WEB_PUBLICATION_URL_BASE"
    if ($envValue) {
        return $envValue
    }

    $configValue = Get-ConfigValue -Path "web.publicationUrlBase"
    if ($configValue -and $configValue -ne "http://localhost") {
        return $configValue
    }

    return ""
}

function Get-EffectiveApacheSettings {
    $detected = Find-ApacheConfig
    $webInstPath = Get-WebInstPath
    $publicationRootOverride = Get-Setting -EnvName "WEB_PUBLICATION_ROOT" -ConfigName "web.publicationRoot"
    $publicationUrlOverride = Get-ConfigUrlBaseOverride
    $apacheKind = Get-Setting -EnvName "APACHE_KIND" -ConfigName "web.apacheKind" -Default "apache24"

    $publicationRoot = $publicationRootOverride
    if (-not $publicationRoot -and $detected.found) {
        $publicationRoot = $detected.publicationRoot
    }

    $publicationUrlBase = $publicationUrlOverride
    if (-not $publicationUrlBase -and $detected.found) {
        $publicationUrlBase = $detected.publicationUrlBase
    }
    if (-not $publicationUrlBase) {
        $publicationUrlBase = "http://localhost"
    }

    $httpdConfPath = ""
    if ($detected.found) {
        $httpdConfPath = $detected.httpdConfPath
    }

    $hasManualPublicationRoot = -not [string]::IsNullOrWhiteSpace([string]$publicationRootOverride)
    $webInstOk = ($webInstPath -and (Test-Path -LiteralPath $webInstPath -PathType Leaf -ErrorAction SilentlyContinue))
    $ready = ([bool]$webInstOk -and -not [string]::IsNullOrWhiteSpace([string]$publicationRoot) -and ($detected.found -or $hasManualPublicationRoot))

    return [pscustomobject]@{
        ready = $ready
        webInstPath = $webInstPath
        webInstOk = [bool]$webInstOk
        apacheKind = $apacheKind
        apacheFound = [bool]$detected.found
        apacheSource = $detected.source
        message = $(if ($detected.found) { "Apache detected from $($detected.source)" } else { $detected.message })
        httpdConfPath = $httpdConfPath
        documentRoot = $detected.documentRoot
        listenPort = $detected.listenPort
        publicationRoot = $publicationRoot
        publicationUrlBase = $publicationUrlBase
        manualPublicationRoot = $hasManualPublicationRoot
    }
}

function Set-DotEnvValues {
    param([hashtable]$Values)

    $path = Join-Path $script:ProjectRoot ".dev.env"
    $lines = @()
    if (Test-Path -LiteralPath $path) {
        $lines = @(Read-Utf8Lines -Path $path)
    }

    $seen = @{}
    $updated = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $replacement = $line
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') {
            $name = $matches[1]
            if ($Values.ContainsKey($name)) {
                $replacement = "$name=$($Values[$name])"
                $seen[$name] = $true
            }
        }
        [void]$updated.Add($replacement)
    }

    foreach ($name in @($Values.Keys | Sort-Object)) {
        if (-not $seen.ContainsKey($name)) {
            [void]$updated.Add("$name=$($Values[$name])")
        }
    }

    Write-Utf8Text -Path $path -Value ((@($updated) -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-DefaultProjectConfig {
    return [ordered]@{
        schemaVersion = 1
        masterBranch = "master"
        exportPath = "src/cf"
        extensionsPath = "src/cfe"
        artifactsPath = "build/result"
        testsPath = "tests/features"
        testResultsPath = "build/test-results/vanessa"
        logsPath = "logs/1c"
        platformPath = ""
        infoBaseKind = "file"
        sourceUsesRepository = $true
        sourceInfoBasePath = ""
        sourceServerName = ""
        sourceInfoBaseName = ""
        repositoryPath = ""
        dependencyMode = "fresh"
        verificationPolicy = "warn"
        devBranchInfoBaseRoot = ".agent-1c/infobases/dev-branches"
        devBranchWorktreeRoot = ""
        serverBaseCopyScript = ""
        aiRules = [ordered]@{
            repo = "https://github.com/comol/ai_rules_1c.git"
            tools = ""
        }
        vibecoding1cMcp = [ordered]@{
            registryRepo = "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"
            providerDefault = "remote"
            remoteConfigId = ""
            localScopeDefault = "project"
        }
        web = [ordered]@{
            publishByDefault = $false
            publishAuto = $false
            webInstPath = ""
            apacheKind = "apache24"
            apacheHttpdConfPath = ""
            publicationRoot = ""
            publicationUrlBase = "http://localhost"
        }
        vanessaAutomation = [ordered]@{
            installRoot = ".agent-1c/tools/vanessa-automation"
            epfPath = ""
            version = ""
            featuresPath = "tests/features"
            reportsPath = "build/test-results/vanessa"
        }
        roctupMcpToolkit = [ordered]@{
            installRoot = ".agent-1c/tools/roctup-mcp-toolkit"
            epfPath = ""
            version = ""
        }
    }
}

function Get-EffectiveWebPublicationSettings {
    return Get-EffectiveApacheSettings
}

function New-DefaultDependencyLockManifest {
    return [ordered]@{
        schemaVersion = 1
        mode = "fresh"
        dependencies = [ordered]@{
            workflowPackage = [ordered]@{
                repo = "https://github.com/xmentosx/1c-agent-workflow.git"
                ref = "master"
                commit = ""
                source = ""
                updatedAt = ""
            }
            aiRules1c = [ordered]@{
                repo = "https://github.com/comol/ai_rules_1c.git"
                ref = ""
                commit = ""
            }
            vanessaAutomation = [ordered]@{
                version = ""
                url = ""
                sha256 = ""
                source = ""
            }
            roctupMcpToolkit = [ordered]@{
                version = ""
                assetName = ""
                url = ""
                sha256 = ""
                source = ""
                updatedAt = ""
            }
        }
    }
}

function Get-DependencyLockPath {
    if (-not $script:DependencyLockPath) {
        $script:DependencyLockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
    }
    return $script:DependencyLockPath
}

function Read-DependencyLockManifest {
    $path = Get-DependencyLockPath
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        return Read-Utf8Text -Path $path | ConvertFrom-Json
    }
    return [pscustomobject](New-DefaultDependencyLockManifest)
}

function Write-DependencyLockManifest {
    param([object]$Manifest)

    Write-Utf8Text -Path (Get-DependencyLockPath) -Value (($Manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Ensure-DependencyLockManifest {
    $path = Get-DependencyLockPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-DependencyLockManifest -Manifest (New-DefaultDependencyLockManifest)
    }
}

function Get-DependencyMode {
    if ($DependencyMode) {
        return ConvertTo-DependencyMode -Value $DependencyMode
    }

    $value = Get-EnvValue -Name "DEPENDENCY_MODE"
    if (-not $value) {
        $value = Get-ConfigValue -Path "dependencyMode" -Default ""
    }
    if (-not $value) {
        $lock = Read-DependencyLockManifest
        $value = [string](Get-ConfigValueFromObject -Object $lock -Path "mode" -Default "fresh")
    }

    return ConvertTo-DependencyMode -Value $value
}

function Get-ConfigValueFromObject {
    param(
        [AllowNull()][object]$Object,
        [string]$Path,
        [object]$Default = $null
    )

    $node = $Object
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node) {
            return $Default
        }
        if ($node -is [System.Collections.IDictionary]) {
            if (-not $node.Contains($part)) {
                return $Default
            }
            $node = $node[$part]
            continue
        }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) {
            return $Default
        }
        $node = $prop.Value
    }
    if ($null -eq $node) {
        return $Default
    }
    if ($node -is [string] -and $node -eq "") {
        return $Default
    }
    return $node
}

function Set-DependencyLockMode {
    param([string]$Mode)

    $normalizedMode = ConvertTo-DependencyMode -Value $Mode
    Ensure-DependencyLockManifest
    $manifest = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $manifest["mode"] = $normalizedMode
    Write-DependencyLockManifest -Manifest $manifest

    $config = if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf -ErrorAction SilentlyContinue) {
        ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json)
    } else {
        New-DefaultProjectConfig
    }
    $config["dependencyMode"] = $normalizedMode
    Write-Utf8Text -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Read-ProjectConfig
}

function Get-DependencyLockEntry {
    param([string]$Name)

    $manifest = Read-DependencyLockManifest
    return Get-ConfigValueFromObject -Object $manifest -Path "dependencies.$Name" -Default $null
}

function Update-DependencyLockEntry {
    param(
        [string]$Name,
        [hashtable]$Values
    )

    if ((Get-DependencyMode) -ne "fresh") {
        return
    }

    Ensure-DependencyLockManifest
    $manifest = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $dependencies = ConvertTo-Agent1cHashtable -Object $manifest["dependencies"]
    $entry = ConvertTo-Agent1cHashtable -Object $dependencies[$Name]
    foreach ($key in @($Values.Keys)) {
        $entry[$key] = $Values[$key]
    }
    $entry["updatedAt"] = (Get-Date).ToString("o")
    $dependencies[$Name] = $entry
    $manifest["dependencies"] = $dependencies
    $manifest["mode"] = "fresh"
    Write-DependencyLockManifest -Manifest $manifest
}

function Get-VerificationPolicy {
    $value = Get-EnvValue -Name "VERIFICATION_POLICY"
    if (-not $value) {
        $value = Get-ConfigValue -Path "verificationPolicy" -Default "warn"
    }
    $policy = ([string]$value).Trim().ToLowerInvariant()
    if (-not $policy) {
        return "warn"
    }
    if ($policy -ne "warn" -and $policy -ne "block") {
        throw "Invalid verificationPolicy: $value. Use warn or block."
    }
    return $policy
}

function New-DefaultToolsManifest {
    return [ordered]@{
        schemaVersion = 1
        tools = @(
            [ordered]@{
                id = "git"
                name = "Git"
                required = $true
                install = [ordered]@{
                    policy = "offer"
                    commands = @("winget install --id Git.Git -e")
                }
            },
            [ordered]@{
                id = "1c-platform"
                name = "1C platform"
                required = $true
                install = [ordered]@{
                    policy = "manual"
                    commands = @("Choose an installed 1C version from C:\Program Files\1cv8\*\bin\1cv8.exe or C:\Program Files (x86)\1cv8\*\bin\1cv8.exe, then set PLATFORM_PATH in .dev.env. If no version is found, install 1C:Enterprise platform manually.")
                }
            },
            [ordered]@{
                id = "apache-webinst"
                name = "Web publication"
                requiredWhenWebPublication = $true
                install = [ordered]@{
                    policy = "manual"
                    commands = @(
                        "Prepare the web server and 1C web publication tooling outside ITL workflow.",
                        "Then run: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action configure-web-publication"
                    )
                }
            },
            [ordered]@{
                id = "vanessa-automation"
                name = "Vanessa Automation"
                required = $true
                install = [ordered]@{
                    policy = "auto"
                    commands = @(
                        "The ITL helper installs Vanessa Automation automatically during init. Manual recovery: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation"
                    )
                }
            }
        )
    }
}

function Ensure-WorkflowProjectFiles {
    $agentDir = Join-Path $script:ProjectRoot ".agent-1c"
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null

    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        Write-Utf8Text -Path $script:ConfigPath -Value (((New-DefaultProjectConfig) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }

    Ensure-DependencyLockManifest

    $toolsPath = Join-Path $agentDir "tools.json"
    if (-not (Test-Path -LiteralPath $toolsPath -PathType Leaf)) {
        Write-Utf8Text -Path $toolsPath -Value (((New-DefaultToolsManifest) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        $script:ToolsManifestLoaded = $false
        $script:ToolsManifest = $null
    }

    Ensure-GitIgnore
}

function Get-ApacheInstallRoot {
    $value = Get-Setting -EnvName "APACHE_INSTALL_ROOT" -ConfigName "web.apacheInstallRoot" -Default "C:\Apache24"
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$value).Trim()))
}

function Test-TcpPortAvailable {
    param([int]$Port)

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any), $Port
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) {
            $listener.Stop()
        }
    }
}

function ConvertFrom-FileUri {
    param([string]$Value)

    if ($Value -match '^file:') {
        return ([System.Uri]$Value).LocalPath
    }

    return $Value
}

function Save-WebPublicationDetectedSettingsToDotEnv {
    param(
        [bool]$PublishByDefault = $true,
        [bool]$Auto = $true
    )

    $settings = Get-EffectiveApacheSettings
    $values = @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
        APACHE_KIND = $settings.apacheKind
    }

    if ($settings.webInstPath) {
        $values["WEBINST_PATH"] = $settings.webInstPath
    }
    if ($settings.httpdConfPath) {
        $values["APACHE_HTTPD_CONF_PATH"] = $settings.httpdConfPath
    }
    if ($settings.publicationRoot) {
        $values["WEB_PUBLICATION_ROOT"] = $settings.publicationRoot
    }
    if ($settings.publicationUrlBase) {
        $values["WEB_PUBLICATION_URL_BASE"] = $settings.publicationUrlBase
    }

    Set-DotEnvValues -Values $values
    Write-Host "Web publication settings saved to .dev.env"
    return $settings
}

function Set-WebPublicationPolicy {
    param(
        [bool]$PublishByDefault,
        [bool]$Auto
    )

    Set-DotEnvValues -Values @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Read-WebPublicationValue {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        $value = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
        $value = [string]$value
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Host "Value is required."
    }
}

function Read-WebPublicationSettingsInteractively {
    param(
        [bool]$PublishByDefault = $true,
        [bool]$Auto = $true
    )

    $settings = Get-EffectiveWebPublicationSettings
    Write-Host "Automatic web publication uses an existing 1C webinst-compatible web server. ITL workflow does not install or configure the web server."

    $webInstPath = Read-WebPublicationValue -Prompt "Full path to webinst.exe" -Default $settings.webInstPath -Required
    $publicationRoot = Read-WebPublicationValue -Prompt "Publication root directory" -Default $settings.publicationRoot -Required
    $publicationUrlBase = Read-WebPublicationValue -Prompt "Publication URL base" -Default $settings.publicationUrlBase -Required
    $apacheKind = Read-WebPublicationValue -Prompt "webinst kind" -Default $settings.apacheKind -Required
    $httpdConfPath = Read-WebPublicationValue -Prompt "Optional Apache/httpd config path, empty if not needed" -Default $settings.httpdConfPath

    $values = @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
        WEBINST_PATH = $webInstPath
        WEB_PUBLICATION_ROOT = $publicationRoot
        WEB_PUBLICATION_URL_BASE = $publicationUrlBase
        APACHE_KIND = $apacheKind
        APACHE_HTTPD_CONF_PATH = $httpdConfPath
    }
    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    return Get-EffectiveWebPublicationSettings
}

function Ensure-WebPublicationForInit {
    param([object]$Answers)

    if (-not $Answers.webPublishByDefault) {
        Set-WebPublicationPolicy -PublishByDefault $false -Auto $false
        return
    }

    if (-not $Answers.webPublishAuto) {
        Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
        return
    }

    $settings = Get-EffectiveWebPublicationSettings
    if ($settings.ready) {
        Save-WebPublicationDetectedSettingsToDotEnv -PublishByDefault $true -Auto $true | Out-Null
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        return
    }

    Write-Host "Automatic web publication was requested, but the existing web publication tooling is not ready: $($settings.message)"
    if (Test-InteractiveInputAvailable) {
        try {
            $settings = Read-WebPublicationSettingsInteractively -PublishByDefault $true -Auto $true
            if ($settings.ready) {
                Write-Host "Automatic web publication is configured."
                return
            }
            Write-Warning "Web publication settings are incomplete. Automatic publication will be disabled; manual branch publication remains available."
        } catch {
            Write-Warning "Could not collect web publication settings. Automatic publication will be disabled; manual branch publication remains available. $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Interactive input is unavailable. Automatic publication will be disabled; manual branch publication remains available."
    }

    Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
}

function Configure-WebPublication {
    if (-not (Test-InteractiveInputAvailable)) {
        throw "configure-web-publication needs terminal input. Run it from an interactive terminal."
    }

    Write-Section "Configure web publication"
    $publishByDefault = Read-InitYesNo -Prompt "Publish development branch infobases to a web server by default?" -Default (Get-WebPublishByDefault)
    if (-not $publishByDefault) {
        Set-WebPublicationPolicy -PublishByDefault $false -Auto $false
        Write-Host "Web publication disabled for new development branches."
        return
    }

    $auto = Read-InitYesNo -Prompt "Attempt automatic web publication when a development branch is created?" -Default (Get-WebPublishAuto)
    if (-not $auto) {
        Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
        Write-Host "Web publication enabled; branch publication will be manual."
        return
    }

    $settings = Get-EffectiveWebPublicationSettings
    if ($settings.ready) {
        Write-Host "Detected usable web publication settings."
        if (Read-InitYesNo -Prompt "Use detected settings for automatic publication?" -Default $true) {
            Save-WebPublicationDetectedSettingsToDotEnv -PublishByDefault $true -Auto $true | Out-Null
            Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
            return
        }
    }

    $settings = Read-WebPublicationSettingsInteractively -PublishByDefault $true -Auto $true
    if ($settings.ready) {
        Write-Host "Automatic web publication is configured."
        return
    }

    Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
    Write-Warning "Web publication settings are incomplete. Publication remains enabled, but automatic publication is disabled."
}

function Find-Installed1CPlatforms {
    $roots = @()

    $programFiles = [Environment]::GetFolderPath("ProgramFiles")
    if ($programFiles) {
        $roots += (Join-Path $programFiles "1cv8")
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    if (-not $programFilesX86) {
        $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Machine")
    }
    if ($programFilesX86) {
        $roots += (Join-Path $programFilesX86 "1cv8")
    }

    $roots += @("C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8")
    $roots = @($roots | Where-Object { $_ } | Select-Object -Unique)

    $items = @()
    $seen = @{}
    foreach ($root in $roots) {
        foreach ($dir in Get-ChildDirectoriesSafe -Path $root) {
            $exePath = Join-Path $dir.FullName "bin\1cv8.exe"
            if (-not (Test-Path -LiteralPath $exePath -PathType Leaf -ErrorAction SilentlyContinue)) {
                continue
            }

            $key = $exePath.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true

            $parsedVersion = $null
            $versionOk = [System.Version]::TryParse($dir.Name, [ref]$parsedVersion)
            $items += [pscustomobject]@{
                version = $dir.Name
                parsedVersion = $(if ($versionOk) { $parsedVersion } else { [System.Version]"0.0" })
                binPath = (Split-Path -Parent $exePath)
                exePath = $exePath
                root = $root
            }
        }
    }

    return @($items | Sort-Object @{ Expression = { $_.parsedVersion }; Descending = $true }, @{ Expression = { $_.exePath }; Descending = $false })
}

function Format-Installed1CPlatformOptions {
    param([object[]]$Platforms)

    $items = @($Platforms)
    if ($items.Count -eq 0) {
        return "No installed 1C platform versions were found under C:\Program Files\1cv8 or C:\Program Files (x86)\1cv8."
    }

    $lines = @("Installed 1C platform versions detected:")
    $index = 1
    foreach ($item in $items) {
        $lines += "$index. $($item.version) - $($item.exePath)"
        $index++
    }
    $lines += "Choose one of these 1cv8.exe paths for PLATFORM_PATH, or enter a custom full path."
    return ($lines -join "`n")
}

function Test-InteractiveInputAvailable {
    try {
        return (-not [Console]::IsInputRedirected)
    } catch {
        return $false
    }
}

function ConvertTo-YesNoBool {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    $yesMarker = -join ([char[]](0x0434, 0x0430))
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if (@("1", "true", "yes", "y", "on", $yesMarker) -contains $text) {
        return $true
    }
    if (@("0", "false", "no", "n", "off", $noMarker, "-") -contains $text) {
        return $false
    }

    throw "Expected yes/no value, got: $Value"
}

function Read-InitRequired {
    param([string]$Prompt)

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Host "Value is required."
    }
}

function Read-InitOptional {
    param([string]$Prompt)
    return (Read-Host $Prompt)
}

function Read-InitYesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { " [Y/n]" } else { " [y/N]" }
    while ($true) {
        $answer = Read-Host ($Prompt + $suffix)
        try {
            return ConvertTo-YesNoBool -Value $answer -Default $Default
        } catch {
            Write-Host "Answer yes or no."
        }
    }
}

function Read-InitInfoBaseKind {
    while ($true) {
        $answer = (Read-Host "Source infobase kind: file or server [file]").Trim().ToLowerInvariant()
        if (-not $answer) {
            return "file"
        }
        if ($answer -eq "file" -or $answer -eq "server") {
            return $answer
        }
        Write-Host "Enter 'file' or 'server'."
    }
}

function Read-InitDependencyMode {
    $useLatest = Read-InitYesNo -Prompt "Use latest dependency versions during initialization? Answer no to use .agent-1c/dependency-lock.json pins." -Default $true
    if ($useLatest) {
        return "fresh"
    }
    return "locked"
}

function Read-InitPlatformPath {
    $platforms = @(Find-Installed1CPlatforms)
    if ($platforms.Count -gt 0) {
        Write-Host "Installed 1C platform versions:"
        for ($i = 0; $i -lt $platforms.Count; $i++) {
            Write-Host ("{0}. {1} - {2}" -f ($i + 1), $platforms[$i].version, $platforms[$i].exePath)
        }

        while ($true) {
            $answer = Read-Host "Choose platform number or enter full path to 1cv8.exe"
            $index = 0
            if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $platforms.Count) {
                return $platforms[$index - 1].exePath
            }
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                return $answer
            }
        }
    }

    return Read-InitRequired "Full path to 1cv8.exe"
}

function Get-AnswerValue {
    param(
        [object]$Answers,
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        $prop = $Answers.PSObject.Properties[$name]
        if ($null -ne $prop) {
            return $prop.Value
        }
    }
    return $Default
}

function Read-InitAnswersFromJson {
    $path = Require-Value "InitAnswersPath" $InitAnswersPath
    $resolvedPath = Resolve-ProjectPath $path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Init answers JSON was not found: $resolvedPath"
    }
    return Read-Utf8Text -Path $resolvedPath | ConvertFrom-Json
}

function Read-InitAnswersFromWizard {
    if (-not (Test-InteractiveInputAvailable)) {
        throw "Interactive init wizard needs terminal input. Run this command from an interactive terminal or pass -InitMode json -InitAnswersPath <file>."
    }

    Write-Section "Init wizard"
    Write-Host "Project root: $script:ProjectRoot"
    if (-not (Read-InitYesNo -Prompt "Initialize the 1C project in this folder?" -Default $true)) {
        throw "Init canceled by developer."
    }

    $platformPath = Read-InitPlatformPath
    $infoBaseKind = Read-InitInfoBaseKind
    $sourceUsesRepository = Read-InitYesNo -Prompt "Is the source infobase connected to 1C configuration repository?" -Default $true

    $answers = [ordered]@{
        platformPath = $platformPath
        infoBaseKind = $infoBaseKind
        sourceUsesRepository = $sourceUsesRepository
        ibUser = ""
        ibPassword = ""
        repositoryPath = ""
        repositoryUser = ""
        repositoryPassword = ""
        webPublishByDefault = $false
        webPublishAuto = $false
    }

    if ($infoBaseKind -eq "server") {
        $answers.sourceServerName = Read-InitRequired "1C server name"
        $answers.sourceInfoBaseName = Read-InitRequired "Source infobase name"
    } else {
        $answers.sourceInfoBasePath = Read-InitRequired "Source file infobase directory"
    }

    $answers.ibUser = Read-InitOptional "Infobase user (empty if none)"
    $answers.ibPassword = ConvertFrom-OptionalPasswordAnswer (Read-InitOptional "Infobase password (empty or '-' if none)")

    if ($sourceUsesRepository) {
        $answers.repositoryPath = Read-InitRequired "Configuration repository path"
        $answers.repositoryUser = Read-InitRequired "Configuration repository user"
        $answers.repositoryPassword = ConvertFrom-OptionalPasswordAnswer (Read-InitOptional "Configuration repository password (empty or '-' if none)")
    }

    $answers.webPublishByDefault = Read-InitYesNo -Prompt "Publish development branch infobases to a web server for web-client testing?" -Default $false
    if ($answers.webPublishByDefault) {
        $answers.webPublishAuto = Read-InitYesNo -Prompt "Attempt automatic web publication when a development branch is created?" -Default $false
    }
    $answers.dependencyMode = Read-InitDependencyMode
    $answers.vibecoding1cMcpSetupDuringInit = Read-InitYesNo -Prompt "Configure vibecoding1c MCP now? Answer no to do it later through a normal agent request or helper action." -Default $false

    Write-Section "Init summary"
    Write-Host "Project root: $script:ProjectRoot"
    Write-Host "Platform: $($answers.platformPath)"
    Write-Host "Source kind: $($answers.infoBaseKind)"
    if ($infoBaseKind -eq "server") {
        Write-Host "Source server: $($answers.sourceServerName)"
        Write-Host "Source infobase: $($answers.sourceInfoBaseName)"
    } else {
        Write-Host "Source infobase: $($answers.sourceInfoBasePath)"
    }
    Write-Host "Infobase user: $($answers.ibUser)"
    Write-Host "Source uses repository: $($answers.sourceUsesRepository)"
    if ($sourceUsesRepository) {
        Write-Host "Repository path: $($answers.repositoryPath)"
        Write-Host "Repository user: $($answers.repositoryUser)"
    }
    Write-Host "Web publication by default: $($answers.webPublishByDefault)"
    Write-Host "Automatic web publication: $($answers.webPublishAuto)"
    Write-Host "Dependency mode: $($answers.dependencyMode)"
    Write-Host "Configure vibecoding1c MCP now: $($answers.vibecoding1cMcpSetupDuringInit)"
    Write-Host "Passwords: hidden"
    if (-not (Read-InitYesNo -Prompt "Continue with these values?" -Default $true)) {
        throw "Init canceled by developer."
    }

    return [pscustomobject]$answers
}

function Normalize-InitAnswers {
    param([object]$Answers)

    $sourceUsesRepository = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("sourceUsesRepository", "SOURCE_USES_REPOSITORY") -Default $true) -Default $true
    $webPublishByDefault = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("webPublishByDefault", "WEB_PUBLISH_BY_DEFAULT") -Default $false) -Default $false
    $webPublishAuto = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("webPublishAuto", "WEB_PUBLISH_AUTO") -Default $false) -Default $false
    if (-not $webPublishByDefault) {
        $webPublishAuto = $false
    }
    $vibecoding1cMcpSetupDuringInit = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("vibecoding1cMcpSetupDuringInit", "VIBECODING1C_MCP_SETUP_DURING_INIT") -Default $false) -Default $false
    $dependencyModeValue = Get-AnswerValue -Answers $Answers -Names @("dependencyMode", "DEPENDENCY_MODE") -Default ""
    if (-not $dependencyModeValue) {
        $useLatestDependencies = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("useLatestDependencies", "USE_LATEST_DEPENDENCIES") -Default $true) -Default $true
        $dependencyModeValue = $(if ($useLatestDependencies) { "fresh" } else { "locked" })
    }

    return [pscustomobject]@{
        platformPath = [string](Get-AnswerValue -Answers $Answers -Names @("platformPath", "PLATFORM_PATH"))
        infoBaseKind = ([string](Get-AnswerValue -Answers $Answers -Names @("infoBaseKind", "INFOBASE_KIND") -Default "file")).Trim().ToLowerInvariant()
        sourceUsesRepository = $sourceUsesRepository
        sourceInfoBasePath = [string](Get-AnswerValue -Answers $Answers -Names @("sourceInfoBasePath", "SOURCE_INFOBASE_PATH") -Default "")
        sourceServerName = [string](Get-AnswerValue -Answers $Answers -Names @("sourceServerName", "SOURCE_SERVER_NAME") -Default "")
        sourceInfoBaseName = [string](Get-AnswerValue -Answers $Answers -Names @("sourceInfoBaseName", "SOURCE_INFOBASE_NAME") -Default "")
        ibUser = [string](Get-AnswerValue -Answers $Answers -Names @("ibUser", "IB_USER") -Default "")
        ibPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-AnswerValue -Answers $Answers -Names @("ibPassword", "IB_PASSWORD") -Default ""))
        repositoryPath = [string](Get-AnswerValue -Answers $Answers -Names @("repositoryPath", "REPOSITORY_PATH") -Default "")
        repositoryUser = [string](Get-AnswerValue -Answers $Answers -Names @("repositoryUser", "REPOSITORY_USER") -Default "")
        repositoryPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-AnswerValue -Answers $Answers -Names @("repositoryPassword", "REPOSITORY_PASSWORD") -Default ""))
        webPublishByDefault = $webPublishByDefault
        webPublishAuto = $webPublishAuto
        dependencyMode = ConvertTo-DependencyMode -Value $dependencyModeValue
        vibecoding1cMcpSetupDuringInit = $vibecoding1cMcpSetupDuringInit
        installVanessaIfMissing = (ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("installVanessaIfMissing", "INSTALL_VANESSA_IF_MISSING") -Default $false) -Default $false)
    }
}

function Assert-InitAnswers {
    param([object]$Answers)

    $missing = @()
    if (-not $Answers.platformPath) { $missing += "platformPath" }
    if ($Answers.infoBaseKind -ne "file" -and $Answers.infoBaseKind -ne "server") { $missing += "infoBaseKind(file|server)" }
    if ($Answers.infoBaseKind -eq "server") {
        if (-not $Answers.sourceServerName) { $missing += "sourceServerName" }
        if (-not $Answers.sourceInfoBaseName) { $missing += "sourceInfoBaseName" }
    } else {
        if (-not $Answers.sourceInfoBasePath) { $missing += "sourceInfoBasePath" }
    }
    if ($Answers.sourceUsesRepository) {
        if (-not $Answers.repositoryPath) { $missing += "repositoryPath" }
        if (-not $Answers.repositoryUser) { $missing += "repositoryUser" }
    }

    if ($missing.Count -gt 0) {
        throw "Init answers are incomplete. Missing: $($missing -join ', ')"
    }
}

function Save-InitAnswers {
    param([object]$Answers)

    $values = @{
        PLATFORM_PATH = $Answers.platformPath
        INFOBASE_KIND = $Answers.infoBaseKind
        SOURCE_USES_REPOSITORY = $(if ($Answers.sourceUsesRepository) { "true" } else { "false" })
        SOURCE_INFOBASE_PATH = $(if ($Answers.infoBaseKind -eq "file") { $Answers.sourceInfoBasePath } else { "" })
        SOURCE_SERVER_NAME = $(if ($Answers.infoBaseKind -eq "server") { $Answers.sourceServerName } else { "" })
        SOURCE_INFOBASE_NAME = $(if ($Answers.infoBaseKind -eq "server") { $Answers.sourceInfoBaseName } else { "" })
        IB_USER = $Answers.ibUser
        IB_PASSWORD = $Answers.ibPassword
        REPOSITORY_PATH = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryPath } else { "" })
        REPOSITORY_USER = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryUser } else { "" })
        REPOSITORY_PASSWORD = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryPassword } else { "" })
        WEB_PUBLISH_BY_DEFAULT = $(if ($Answers.webPublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Answers.webPublishAuto) { "true" } else { "false" })
        DEPENDENCY_MODE = $Answers.dependencyMode
        VIBECODING1C_MCP_SETUP_DURING_INIT = $(if ($Answers.vibecoding1cMcpSetupDuringInit) { "true" } else { "false" })
    }

    Set-DotEnvValues -Values $values
    Set-DependencyLockMode -Mode $Answers.dependencyMode
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    $script:InitVibecoding1cMcpSetupRequested = [bool]$Answers.vibecoding1cMcpSetupDuringInit
}

function New-ConfiguredInitAnswers {
    return [pscustomobject]@{
        webPublishByDefault = (Get-WebPublishByDefault)
        webPublishAuto = (Get-WebPublishAuto)
        installVanessaIfMissing = [bool]$InstallVanessaIfMissing
    }
}

function Prepare-InitProjectSettings {
    Ensure-WorkflowProjectFiles
    Read-ProjectConfig

    $rawAnswers = if ($InitMode -eq "json") {
        Read-InitAnswersFromJson
    } elseif ($InitMode -eq "wizard") {
        Read-InitAnswersFromWizard
    } else {
        return
    }

    $answers = Normalize-InitAnswers -Answers $rawAnswers
    Assert-InitAnswers -Answers $answers
    Save-InitAnswers -Answers $answers
    Ensure-WebPublicationForInit -Answers $answers
    Ensure-VanessaAutomationForInit -Answers $answers
    Read-ProjectConfig
}

function Prepare-ConfiguredInitProjectSettings {
    Ensure-WorkflowProjectFiles
    Read-ProjectConfig

    $answers = New-ConfiguredInitAnswers
    Ensure-WebPublicationForInit -Answers $answers
    Ensure-VanessaAutomationForInit -Answers $answers
    Read-ProjectConfig
}

function Get-InfoBaseKind {
    return (Get-Setting -EnvName "INFOBASE_KIND" -ConfigName "infoBaseKind" -Default "file")
}

function Get-SourceInfoBasePath {
    $kind = Get-InfoBaseKind
    if ($kind -eq "server") {
        $legacyValue = Get-Setting -EnvName "SOURCE_INFOBASE_PATH" -ConfigName "sourceInfoBasePath"
        if ($legacyValue) {
            return $legacyValue
        }

        $serverName = Require-Value "SOURCE_SERVER_NAME or project.sourceServerName" (Get-Setting -EnvName "SOURCE_SERVER_NAME" -ConfigName "sourceServerName")
        $infoBaseName = Require-Value "SOURCE_INFOBASE_NAME or project.sourceInfoBaseName" (Get-Setting -EnvName "SOURCE_INFOBASE_NAME" -ConfigName "sourceInfoBaseName")
        return "Srvr=`"$serverName`";Ref=`"$infoBaseName`";"
    }

    $value = Get-Setting -EnvName "SOURCE_INFOBASE_PATH" -ConfigName "sourceInfoBasePath"
    if (-not $value) {
        $value = Get-EnvValue -Name "INFOBASE_PATH"
    }
    return Require-Value "SOURCE_INFOBASE_PATH or project.sourceInfoBasePath" $value
}

function Get-RepositoryPath {
    return Require-Value "REPOSITORY_PATH or project.repositoryPath" (Get-Setting -EnvName "REPOSITORY_PATH" -ConfigName "repositoryPath")
}

function Get-DevBranchInfoBaseRoot {
    return Get-Setting -EnvName "DEV_BRANCH_INFOBASE_ROOT" -ConfigName "devBranchInfoBaseRoot" -Default ".agent-1c/infobases/dev-branches"
}

function Get-DefaultDevBranchWorktreeRoot {
    $mainWorktreePath = Get-MainWorktreePath
    $parent = Split-Path -Parent $mainWorktreePath
    $leaf = Split-Path -Leaf $mainWorktreePath
    return [System.IO.Path]::GetFullPath((Join-Path $parent ($leaf + "-worktrees")))
}

function Get-DevBranchWorktreeRoot {
    $value = Get-Setting -EnvName "DEV_BRANCH_WORKTREE_ROOT" -ConfigName "devBranchWorktreeRoot" -Default ""
    if ($value) {
        if ([System.IO.Path]::IsPathRooted([string]$value)) {
            return [System.IO.Path]::GetFullPath([string]$value)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot ([string]$value)))
    }
    return Get-DefaultDevBranchWorktreeRoot
}

function Resolve-DevBranchWorktreePath {
    param([string]$SafeDevBranchName)

    if ($DevBranchWorktreePath) {
        if ([System.IO.Path]::IsPathRooted($DevBranchWorktreePath)) {
            return [System.IO.Path]::GetFullPath($DevBranchWorktreePath)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $DevBranchWorktreePath))
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-DevBranchWorktreeRoot) $SafeDevBranchName))
}

function Get-AgentTargets {
    $target = $AgentTarget
    if (-not $target) {
        $target = Get-Setting -EnvName "AGENT_TOOLS" -ConfigName "aiRules.tools" -Default "codex"
    }

    $items = @()
    foreach ($part in ([string]$target).Split(",")) {
        $normalized = $part.Trim().ToLowerInvariant()
        if (-not $normalized) {
            continue
        }
        if ($normalized -eq "both") {
            $items += @("codex", "kilocode")
        } elseif ($normalized -eq "kilo") {
            $items += "kilocode"
        } elseif ($normalized -eq "codex" -or $normalized -eq "kilocode") {
            $items += $normalized
        }
    }

    if ($items.Count -eq 0) {
        $items = @("codex")
    }

    return $items | Select-Object -Unique
}

function Read-ToolsManifest {
    if ($script:ToolsManifestLoaded) {
        return $script:ToolsManifest
    }

    $script:ToolsManifestLoaded = $true
    $path = Join-Path $script:ProjectRoot ".agent-1c\tools.json"
    if (Test-Path -LiteralPath $path) {
        $script:ToolsManifest = Read-Utf8Text -Path $path | ConvertFrom-Json
    }
    return $script:ToolsManifest
}

function Get-ToolOffer {
    param(
        [string]$Id,
        [string]$Fallback
    )

    $manifest = Read-ToolsManifest
    if ($manifest -and $manifest.PSObject.Properties["tools"]) {
        foreach ($tool in @($manifest.tools)) {
            if ($tool.id -eq $Id -and $tool.PSObject.Properties["install"] -and $tool.install.PSObject.Properties["commands"]) {
                return (@($tool.install.commands) -join "`n")
            }
        }
    }
    return $Fallback
}

function Invoke-ToolVersionCheck {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ok = ($exitCode -eq 0)
            detail = (($output | Out-String).Trim())
        }
    } catch {
        $detail = $_.Exception.Message
        $atIndex = $detail.IndexOf("At ")
        if ($atIndex -gt 0) {
            $detail = $detail.Substring(0, $atIndex).Trim()
        }
        return [pscustomobject]@{
            ok = $false
            detail = $detail
        }
    }
}

function New-ToolResult {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Required,
        [bool]$Ok,
        [string]$Detail,
        [string]$Offer
    )

    return [pscustomobject]@{
        id = $Id
        name = $Name
        required = $Required
        ok = $Ok
        detail = $Detail
        offer = $Offer
    }
}

function Check-Tools {
    param([switch]$StopOnMissing)

    Write-Section "Check tools"
    $results = @()

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    $gitCheck = if ($gitCommand) { Invoke-ToolVersionCheck -Command "git" -Arguments @("--version") } else { $null }
    $results += New-ToolResult `
        -Id "git" `
        -Name "Git" `
        -Required $true `
        -Ok ([bool]$gitCommand -and [bool]$gitCheck.ok) `
        -Detail $(if ($gitCommand) { $gitCheck.detail } else { "git command not found" }) `
        -Offer (Get-ToolOffer -Id "git" -Fallback "winget install --id Git.Git -e")

    $rawPlatformPath = Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath"
    $platformPath = Resolve-PlatformExecutablePath -Path $rawPlatformPath
    $platformOk = ($platformPath -and (Test-Path -LiteralPath $platformPath))
    $platformOffer = Get-ToolOffer -Id "1c-platform" -Fallback "Install 1C:Enterprise platform manually, then set PLATFORM_PATH in .dev.env."
    if (-not $platformOk) {
        $foundPlatforms = @(Find-Installed1CPlatforms)
        if ($foundPlatforms.Count -gt 0) {
            $platformOffer = Format-Installed1CPlatformOptions -Platforms $foundPlatforms
        }
    }
    $results += New-ToolResult `
        -Id "1c-platform" `
        -Name "1C platform" `
        -Required $true `
        -Ok ([bool]$platformOk) `
        -Detail $(if ($platformOk) { $platformPath } elseif ($rawPlatformPath) { "Configured path does not exist: $platformPath" } else { "PLATFORM_PATH/project.platformPath is missing" }) `
        -Offer $platformOffer

    $vanessa = Get-VanessaAutomationState
    $vanessaDetail = if ($vanessa.ready) {
        if ($vanessa.version) { "{0} ({1})" -f $vanessa.epfPath, $vanessa.version } else { $vanessa.epfPath }
    } else {
        $vanessa.message
    }
    $results += New-ToolResult `
        -Id "vanessa-automation" `
        -Name "Vanessa Automation" `
        -Required $true `
        -Ok ([bool]$vanessa.ready) `
        -Detail $vanessaDetail `
        -Offer (Get-ToolOffer -Id "vanessa-automation" -Fallback "ITL installs Vanessa Automation automatically during init. Manual recovery: run helper action install-vanessa-automation.")

    $publishDefault = Get-WebPublishByDefault
    $publishAuto = Get-WebPublishAuto
    if ($PublishToWeb -or ($publishDefault -and $publishAuto)) {
        $apacheSettings = Get-EffectiveApacheSettings
        $webInstDetail = if ($apacheSettings.webInstPath) { $apacheSettings.webInstPath } else { "webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set" }
        $results += New-ToolResult `
            -Id "apache-webinst" `
            -Name "Web publication webinst" `
            -Required $true `
            -Ok ([bool]$apacheSettings.webInstOk) `
            -Detail $webInstDetail `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Use the 1C webinst.exe located next to the selected 1cv8.exe, or set WEBINST_PATH only for a nonstandard 1C platform layout.")

        $apacheDetail = if ($apacheSettings.apacheFound) {
            "Config: $($apacheSettings.httpdConfPath); DocumentRoot: $($apacheSettings.documentRoot); URL base: $($apacheSettings.publicationUrlBase)"
        } elseif ($apacheSettings.manualPublicationRoot) {
            "Manual publication root: $($apacheSettings.publicationRoot); URL base: $($apacheSettings.publicationUrlBase)"
        } else {
            $apacheSettings.message
        }
        $results += New-ToolResult `
            -Id "apache-httpd" `
            -Name "Web server config" `
            -Required $true `
            -Ok ([bool]($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) `
            -Detail $apacheDetail `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Prepare the web server outside ITL workflow, then run configure-web-publication or detect-web-publication.")

        $publicationDetail = if ($apacheSettings.publicationRoot) {
            "$($apacheSettings.publicationRoot) -> $($apacheSettings.publicationUrlBase)"
        } else {
            "Publication root could not be derived from the current web server settings."
        }
        $results += New-ToolResult `
            -Id "web-publication" `
            -Name "Web publication target" `
            -Required $true `
            -Ok (-not [string]::IsNullOrWhiteSpace([string]$apacheSettings.publicationRoot)) `
            -Detail $publicationDetail `
            -Offer "Set WEB_PUBLICATION_ROOT and WEB_PUBLICATION_URL_BASE, or run configure-web-publication."
    }

    $missingRequired = @()
    foreach ($result in $results) {
        if ($result.ok) {
            Write-Host "[OK] $($result.name): $($result.detail)"
        } else {
            $level = if ($result.required) { "MISSING" } else { "OPTIONAL" }
            Write-Host "[$level] $($result.name): $($result.detail)"
            if ($result.offer) {
                Write-Host "Suggested install/setup:"
                Write-Host $result.offer
            }
            if ($result.required) {
                $missingRequired += $result
            }
        }
    }

    if ($StopOnMissing -and $missingRequired.Count -gt 0) {
        throw "Required tools are missing. Install or configure them, then rerun this action."
    }
}

function List-Platforms {
    Write-Section "Installed 1C platforms"
    $platforms = @(Find-Installed1CPlatforms)
    if ($platforms.Count -eq 0) {
        Write-Host "No installed 1C platform versions were found under C:\Program Files\1cv8 or C:\Program Files (x86)\1cv8."
        Write-Host "Install 1C:Enterprise platform manually or enter the full path to bin\1cv8.exe."
        return
    }

    $index = 1
    foreach ($platform in $platforms) {
        Write-Host "$index. Version: $($platform.version)"
        Write-Host "   bin: $($platform.binPath)"
        Write-Host "   1cv8.exe: $($platform.exePath)"
        $index++
    }
}

function Assert-InfoBaseAvailable {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$SettingName = "infobase path"
    )

    if ($Kind -eq "file") {
        $resolvedPath = Resolve-InfoBasePath $Path
        if (-not $resolvedPath) {
            throw "File infobase path is empty: $SettingName"
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "File infobase directory was not found: $resolvedPath. Check $SettingName before running 1C Designer."
        }

        $dbFile = Join-Path $resolvedPath "1Cv8.1CD"
        if (-not (Test-Path -LiteralPath $dbFile -PathType Leaf)) {
            throw "File infobase database file was not found: $dbFile. Check $SettingName; the helper will not let 1C create a new empty infobase during this workflow."
        }
    } elseif ($Kind -eq "server") {
        Require-Value $SettingName $Path | Out-Null
    } else {
        throw "Unknown infobase kind: $Kind"
    }
}

function New-InfobaseArgs {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    $args = @()
    if ($Kind -eq "file") {
        $args += @("/F", (Resolve-InfoBasePath $Path))
    } elseif ($Kind -eq "server") {
        $args += @("/S", $Path)
    } else {
        throw "Unknown infobase kind: $Kind"
    }

    $Password = ConvertFrom-OptionalPasswordAnswer $Password
    if ($User) {
        $args += @("/N", $User)
    }
    if (-not [string]::IsNullOrEmpty($Password)) {
        $args += @("/P", $Password)
    }

    return $args
}

function ConvertFrom-OptionalPasswordAnswer {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $trimmed = $Value.Trim()
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if ($trimmed -eq "-" -or [string]::Equals($trimmed, $noMarker, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    return $Value
}

function ConvertTo-NativeEmptyStringArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return $Value
}

function ConvertTo-NativeCommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-NativeCommandLineArguments {
    param([string[]]$Arguments)

    $quoted = @()
    foreach ($arg in $Arguments) {
        $quoted += ConvertTo-NativeCommandLineArgument $arg
    }

    return ($quoted -join " ")
}

function Format-SafeCommandLine {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $secretKeys = @("/P", "/ConfigurationRepositoryP")
    $parts = @((ConvertTo-NativeCommandLineArgument $Command))
    $maskNext = $false
    foreach ($arg in $Arguments) {
        if ($maskNext) {
            $parts += "<hidden>"
            $maskNext = $false
            continue
        }

        $parts += ConvertTo-NativeCommandLineArgument $arg
        if ($secretKeys -contains $arg) {
            $maskNext = $true
        }
    }

    return ($parts -join " ")
}

function Invoke-NativeProcessAndWaitResult {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0,
        [scriptblock]$OnTimeout = $null
    )

    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    $script:LastProcessId = $process.Id
    $script:LastProcessTimedOut = $false
    if ($TimeoutSeconds -gt 0) {
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            $script:LastProcessTimedOut = $true
            if ($null -ne $OnTimeout) {
                & $OnTimeout
            }
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {
            }
            try {
                $process.WaitForExit(10000) | Out-Null
            } catch {
            }
        }
    } else {
        $process.WaitForExit()
    }

    $process.Refresh()
    return [pscustomobject]@{
        processId = $process.Id
        exitCode = $(if ($script:LastProcessTimedOut) { -1 } else { $process.ExitCode })
        timedOut = $script:LastProcessTimedOut
    }
}

function Invoke-NativeProcessAndWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $result = Invoke-NativeProcessAndWaitResult -FilePath $FilePath -Arguments $Arguments
    return $result.exitCode
}

function Invoke-VisibleNativeProcessAndWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    $script:LastProcessId = $process.Id
    $process.WaitForExit()
    $process.Refresh()
    return $process.ExitCode
}

function Start-NativeProcessBackground {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    return $process
}

function Invoke-Designer {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$DesignerArgs,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $DesignerArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $exitCode = Invoke-NativeProcessAndWait -FilePath $platformPath -Arguments $args
    if ($exitCode -ne 0) {
        throw "1C Designer failed with exit code $exitCode. Log: $logPath"
    }

    return $logPath
}

function Invoke-DesignerInteractive {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-designer-interactive-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath)

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $exitCode = Invoke-VisibleNativeProcessAndWait -FilePath $platformPath -Arguments $args
    if ($exitCode -ne 0) {
        throw "1C Designer failed with exit code $exitCode. Log: $logPath"
    }

    return $logPath
}

function Start-EnterpriseBackground {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$EnterpriseArgs,
        [switch]$UseTestManager,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-enterprise-mcp-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("ENTERPRISE")
    if ($UseTestManager) {
        $args += "/TESTMANAGER"
    }
    $args += $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $EnterpriseArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $process = Start-NativeProcessBackground -FilePath $platformPath -Arguments $args
    return [pscustomobject]@{
        process = $process
        logPath = $logPath
    }
}

function Invoke-Enterprise {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$EnterpriseArgs,
        [int]$TestManagerPort = 0,
        [int]$TimeoutSeconds = 0,
        [scriptblock]$OnTimeout = $null,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-enterprise-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("ENTERPRISE") + $ibArgs + @("/DisableStartupMessages")
    if ($TestManagerPort -gt 0) {
        $args += @("/TESTMANAGER", "-TPort", ([string]$TestManagerPort))
    }
    $args += @("/Out", $logPath) + $EnterpriseArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $result = Invoke-NativeProcessAndWaitResult -FilePath $platformPath -Arguments $args -TimeoutSeconds $TimeoutSeconds -OnTimeout $OnTimeout
    if ($result.timedOut) {
        throw "1C Enterprise timed out after $TimeoutSeconds seconds. PID: $($result.processId). Log: $logPath"
    }
    if ($result.exitCode -ne 0) {
        throw "1C Enterprise failed with exit code $($result.exitCode). PID: $($result.processId). Log: $logPath"
    }

    return $logPath
}
