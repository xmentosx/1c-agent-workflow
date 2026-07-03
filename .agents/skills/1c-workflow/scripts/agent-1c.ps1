[CmdletBinding()]
param(
    [ValidateSet("help", "validate", "check-tools", "list-platforms", "detect-apache", "install-apache", "install-vanessa-automation", "install-vanessa-mcp", "start-vanessa-mcp", "stop-vanessa-mcp", "vanessa-mcp-status", "mcp-setup", "mcp-update", "mcp-status", "mcp-start", "mcp-stop", "mcp-rotate-keys", "mcp-ensure-model", "mcp-write-client-config", "run-dev-branch-tests", "init-project", "sync-master", "new-dev-branch", "new-extension-dev-branch", "set-dev-branch-extension", "dump-dev-branch-extension", "activate-dev-branch-context", "update-dev-branch-base", "verify-dev-branch", "status", "refresh-dev-branch", "export-dev-branch-result", "close-dev-branch", "switch-master", "switch-dev-branch", "list-dev-branches")]
    [string]$Action = "help",

    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$DevBranchName,
    [string]$DevBranch,
    [string]$DevBranchInfoBasePath,
    [string]$DevBranchWorktreePath,
    [string]$ExtensionName,
    [string]$VanessaFeaturePath,
    [string]$VanessaFilterTags,
    [int]$VanessaTestPort = 0,
    [int]$VanessaMcpPort = 0,
    [string]$McpDistributionPath = "",
    [ValidateSet("", "global", "project", "branch", "current", "all")]
    [string]$McpScope = "",
    [string]$McpServerId = "",
    [ValidateSet("configured", "wizard", "json")]
    [string]$InitMode = "configured",
    [string]$InitAnswersPath,
    [ValidateSet("", "codex", "kilocode", "both")]
    [string]$AgentTarget = "",
    [switch]$PublishToApache,
    [switch]$Force,
    [switch]$SkipAiRules,
    [switch]$AllowUnverifiedResult,
    [switch]$AllowUnverifiedClose,
    [switch]$UseCurrentWorktree,
    [switch]$OfferOpenAgent,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [switch]$PauseOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ConsoleOutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $script:ConsoleOutputEncoding
$OutputEncoding = $script:ConsoleOutputEncoding

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ProjectRoot ".agent-1c\project.json"
}

$script:LastLogPath = $null
$script:LastProcessId = 0
$script:LastProcessTimedOut = $false
$script:RunStartedAt = Get-Date
$script:ResolvedRunStatusPath = ""
$script:ResolvedRunLogPath = ""
$script:ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$script:Config = $null
$script:ToolsManifest = $null
$script:ToolsManifestLoaded = $false

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
    $previousConfig = $script:Config
    try {
        Set-ProjectContext -Root $Root
        & $ScriptBlock
    } finally {
        $script:ProjectRoot = $previousRoot
        $script:ConfigPath = $previousConfigPath
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

function Invoke-Git {
    param([string[]]$Arguments)
    & git -C $script:ProjectRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$script:ProjectRoot`" $($Arguments -join ' ')"
    }
}

function Invoke-GitAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$Root`" $($Arguments -join ' ')"
    }
}

function Get-GitOutput {
    param([string[]]$Arguments)
    $output = & git -C $script:ProjectRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$script:ProjectRoot`" $($Arguments -join ' ')"
    }
    return $output
}

function Get-GitOutputAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    $output = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$Root`" $($Arguments -join ' ')"
    }
    return $output
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
    $output = & git -C $script:ProjectRoot @arguments
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
        ".agent-1c/tools/vanessa-automation/",
        ".agent-1c/tools/vanessa-mcp/",
        ".agent-1c/mcp/",
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

    $message = "Apache httpd.conf was not found. Run install-apache after explicit developer confirmation, install Apache 2.4 manually, or set APACHE_HTTPD_CONF_PATH, then rerun detect-apache or check-tools."
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
        devBranchInfoBaseRoot = ".agent-1c/infobases/dev-branches"
        devBranchWorktreeRoot = ""
        serverBaseCopyScript = ""
        aiRules = [ordered]@{
            repo = "https://github.com/comol/ai_rules_1c.git"
            tools = ""
        }
        web = [ordered]@{
            publishByDefault = $false
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
    }
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
                name = "Apache/webinst"
                requiredWhenWebPublication = $true
                install = [ordered]@{
                    policy = "confirm-then-run"
                    commands = @(
                        "After explicit developer confirmation, run: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-apache",
                        "If automatic install is declined, install/configure Apache 2.4 manually so httpd.conf can be detected, then run detect-apache."
                    )
                }
            },
            [ordered]@{
                id = "vanessa-automation"
                name = "Vanessa Automation"
                required = $true
                install = [ordered]@{
                    policy = "confirm-then-run"
                    commands = @(
                        "After explicit developer confirmation, run: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation"
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

function Get-ApacheServiceName {
    return [string](Get-Setting -EnvName "APACHE_SERVICE_NAME" -ConfigName "web.apacheServiceName" -Default "Apache24")
}

function Get-ApachePreferredPort {
    $value = Get-Setting -EnvName "APACHE_LISTEN_PORT" -ConfigName "web.apacheListenPort"
    if (-not $value) {
        return $null
    }

    $port = 0
    if (-not [int]::TryParse(([string]$value).Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Invalid APACHE_LISTEN_PORT value: $value"
    }

    return $port
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ApacheSkipServiceInstall {
    return ConvertTo-BoolSetting -Value (Get-EnvValue -Name "APACHE_SKIP_SERVICE") -Default $false
}

function Test-ApacheSkipVcRedistInstall {
    return ConvertTo-BoolSetting -Value (Get-EnvValue -Name "APACHE_SKIP_VCREDIST") -Default $false
}

function Test-ApacheAllowNonAdminInstall {
    return ConvertTo-BoolSetting -Value (Get-EnvValue -Name "APACHE_ALLOW_NONADMIN") -Default $false
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

function Get-ApacheInstallPort {
    $preferred = Get-ApachePreferredPort
    if ($preferred) {
        if (-not (Test-TcpPortAvailable -Port $preferred)) {
            throw "Configured Apache listen port is busy: $preferred"
        }
        return $preferred
    }

    foreach ($port in @(80) + (8080..8090)) {
        if (Test-TcpPortAvailable -Port $port) {
            return $port
        }
    }

    throw "No free Apache listen port found. Checked 80 and 8080..8090."
}

function Get-ApacheLoungeDownloadFromWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        return $null
    }

    try {
        $output = & $winget.Source show --id ApacheLounge.httpd -e --accept-source-agreements 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $text = (@($output) -join "`n")
        $urlMatch = [regex]::Match($text, 'https?://\S*apachelounge\.com/\S*httpd-[^\s]+?Win64[^\s]+?\.zip', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $urlMatch.Success) {
            $urlMatch = [regex]::Match($text, 'https?://\S+?httpd-[^\s]+?\.zip', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        if (-not $urlMatch.Success) {
            return $null
        }

        $shaMatch = [regex]::Match($text, '\b[A-Fa-f0-9]{64}\b')
        return [pscustomobject]@{
            url = $urlMatch.Value.Trim()
            expectedSha256 = $(if ($shaMatch.Success) { $shaMatch.Value.ToLowerInvariant() } else { "" })
            source = "winget show ApacheLounge.httpd"
        }
    } catch {
        return $null
    }
}

function Get-ApacheDownloadInfo {
    $override = Get-EnvValue -Name "APACHE_ARCHIVE_URL"
    if ($override) {
        return [pscustomobject]@{
            url = [string]$override
            expectedSha256 = ""
            source = "APACHE_ARCHIVE_URL"
        }
    }

    $wingetInfo = Get-ApacheLoungeDownloadFromWinget
    if ($wingetInfo) {
        return $wingetInfo
    }

    return [pscustomobject]@{
        url = "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.68-260610-Win64-VS18.zip"
        expectedSha256 = ""
        source = "Apache Lounge fallback URL"
    }
}

function Get-ApacheCacheDirectory {
    return (Join-Path $env:TEMP "1c-agent-workflow\apache")
}

function ConvertFrom-FileUri {
    param([string]$Value)

    if ($Value -match '^file:') {
        return ([System.Uri]$Value).LocalPath
    }

    return $Value
}

function Save-ApacheArchive {
    param([object]$DownloadInfo)

    $cacheDir = Get-ApacheCacheDirectory
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $archivePath = Join-Path $cacheDir "apache-httpd.zip"
    $source = [string]$DownloadInfo.url

    Write-Host "Apache archive source: $source"
    if (Test-Path -LiteralPath (ConvertFrom-FileUri -Value $source) -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath (ConvertFrom-FileUri -Value $source) -Destination $archivePath -Force
    } else {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {
            # Best effort for older Windows PowerShell hosts.
        }
        Invoke-WebRequest -Uri $source -UseBasicParsing -OutFile $archivePath
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    Write-Host "Apache archive SHA256: $hash"

    $expected = [string]$DownloadInfo.expectedSha256
    if ($expected) {
        $expected = $expected.ToLowerInvariant()
        if ($hash -eq $expected) {
            Write-Host "Apache archive hash matches metadata from $($DownloadInfo.source)."
        } else {
            Write-Host "[WARN] Apache archive hash differs from metadata from $($DownloadInfo.source). Continuing because winget metadata can be stale; actual SHA256 is logged above."
        }
    }

    return $archivePath
}

function Find-ApacheFolderInExtractedArchive {
    param([string]$ExtractRoot)

    $direct = Join-Path $ExtractRoot "Apache24"
    if ((Test-Path -LiteralPath (Join-Path $direct "bin\httpd.exe") -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath (Join-Path $direct "conf\httpd.conf") -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $direct
    }

    foreach ($dir in Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue) {
        if ((Test-Path -LiteralPath (Join-Path $dir.FullName "bin\httpd.exe") -PathType Leaf -ErrorAction SilentlyContinue) -and
            (Test-Path -LiteralPath (Join-Path $dir.FullName "conf\httpd.conf") -PathType Leaf -ErrorAction SilentlyContinue)) {
            return $dir.FullName
        }
    }

    throw "Downloaded Apache archive does not contain an Apache24 folder with bin\httpd.exe and conf\httpd.conf."
}

function Expand-ApacheArchiveToInstallRoot {
    param(
        [string]$ArchivePath,
        [string]$InstallRoot
    )

    $httpdExe = Join-Path $InstallRoot "bin\httpd.exe"
    $httpdConf = Join-Path $InstallRoot "conf\httpd.conf"
    if ((Test-Path -LiteralPath $httpdExe -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath $httpdConf -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-Host "Apache files already exist: $InstallRoot"
        return
    }

    if (Test-Path -LiteralPath $InstallRoot -ErrorAction SilentlyContinue) {
        $children = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Apache install root already exists but does not look like Apache: $InstallRoot"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    $extractRoot = Join-Path (Get-ApacheCacheDirectory) ("extract-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force
        $apacheFolder = Find-ApacheFolderInExtractedArchive -ExtractRoot $extractRoot
        Copy-Item -Path (Join-Path $apacheFolder "*") -Destination $InstallRoot -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $httpdExe -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Apache httpd.exe was not installed to expected path: $httpdExe"
    }
    if (-not (Test-Path -LiteralPath $httpdConf -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Apache httpd.conf was not installed to expected path: $httpdConf"
    }
}

function Set-ApacheHttpdConfig {
    param(
        [string]$InstallRoot,
        [int]$Port
    )

    $confPath = Join-Path $InstallRoot "conf\httpd.conf"
    if (-not (Test-Path -LiteralPath $confPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Apache httpd.conf was not found: $confPath"
    }

    $serverRoot = ($InstallRoot -replace "\\", "/")
    $lines = @(Read-Utf8Lines -Path $confPath)
    $result = New-Object System.Collections.ArrayList
    $definedSrvRoot = $false
    $serverRootSet = $false
    $listenSet = $false
    $serverNameSet = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*Define\s+SRVROOT\b') {
            [void]$result.Add("Define SRVROOT `"$serverRoot`"")
            $definedSrvRoot = $true
            continue
        }
        if ($line -match '^\s*ServerRoot\b') {
            [void]$result.Add('ServerRoot "${SRVROOT}"')
            $serverRootSet = $true
            continue
        }
        if (-not $listenSet -and $line -match '^\s*Listen\s+') {
            [void]$result.Add("Listen $Port")
            $listenSet = $true
            continue
        }
        if (-not $serverNameSet -and $line -match '^\s*#?\s*ServerName\s+') {
            [void]$result.Add("ServerName localhost:$Port")
            $serverNameSet = $true
            continue
        }

        [void]$result.Add($line)
    }

    if (-not $definedSrvRoot) {
        [void]$result.Insert(0, "Define SRVROOT `"$serverRoot`"")
    }
    if (-not $serverRootSet) {
        [void]$result.Add('ServerRoot "${SRVROOT}"')
    }
    if (-not $listenSet) {
        [void]$result.Add("Listen $Port")
    }
    if (-not $serverNameSet) {
        [void]$result.Add("ServerName localhost:$Port")
    }

    Write-Utf8Text -Path $confPath -Value ((@($result) -join [Environment]::NewLine) + [Environment]::NewLine)
    Write-Host "Apache httpd.conf configured: $confPath"
    Write-Host "Apache Listen port: $Port"
}

function Install-VcRedistForApache {
    if (Test-ApacheSkipVcRedistInstall) {
        Write-Host "Skipping VC++ Redistributable install because APACHE_SKIP_VCREDIST is true."
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget was not found. Install Microsoft Visual C++ Redistributable 2015-2022 x64 manually, then rerun install-apache."
    }

    Write-Host "Ensuring Microsoft Visual C++ Redistributable 2015-2022 x64 is installed..."
    & $winget.Source install --id Microsoft.VCRedist.2015+.x64 -e --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "VC++ Redistributable install failed with exit code $LASTEXITCODE"
    }
}

function Install-ApacheService {
    param([string]$InstallRoot)

    if (Test-ApacheSkipServiceInstall) {
        Write-Host "Skipping Apache service install/start because APACHE_SKIP_SERVICE is true."
        return
    }

    $serviceName = Get-ApacheServiceName
    $httpdExe = Join-Path $InstallRoot "bin\httpd.exe"
    if (-not (Test-Path -LiteralPath $httpdExe -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Apache httpd.exe was not found: $httpdExe"
    }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "Installing Apache service: $serviceName"
        & $httpdExe -k install -n $serviceName
        if ($LASTEXITCODE -ne 0) {
            throw "Apache service install failed with exit code $LASTEXITCODE"
        }
    } else {
        Write-Host "Apache service already exists: $serviceName"
    }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        Write-Host "Starting Apache service: $serviceName"
        & $httpdExe -k start -n $serviceName
        if ($LASTEXITCODE -ne 0) {
            throw "Apache service start failed with exit code $LASTEXITCODE"
        }
    } elseif ($service) {
        Write-Host "Apache service is already running: $serviceName"
    } else {
        throw "Apache service was not found after install: $serviceName"
    }
}

function Save-ApacheDetectedSettingsToDotEnv {
    $settings = Get-EffectiveApacheSettings
    $values = @{
        WEB_PUBLISH_BY_DEFAULT = "true"
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
    Write-Host "Apache settings saved to .dev.env"
    return $settings
}

function Invoke-ElevatedInstallApache {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        throw "Cannot determine helper script path for elevated Apache install."
    }

    $powershell = (Get-Command powershell -ErrorAction SilentlyContinue).Source
    if (-not $powershell) {
        throw "powershell.exe was not found for elevated Apache install."
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-Action", "install-apache",
        "-ProjectRoot", $script:ProjectRoot,
        "-ConfigPath", $script:ConfigPath
    )
    $argumentLine = Join-NativeCommandLineArguments -Arguments $arguments
    $commandPreview = "$(ConvertTo-NativeCommandLineArgument $powershell) $argumentLine"

    Write-Host "Apache install needs administrator privileges."
    Write-Host "Elevated command: $commandPreview"
    try {
        $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    } catch {
        throw "Failed to start elevated PowerShell. Run this command as Administrator: $commandPreview"
    }

    if ($null -eq $process) {
        throw "Failed to start elevated PowerShell. Run this command as Administrator: $commandPreview"
    }
    if ($process.ExitCode -ne 0) {
        throw "Elevated Apache install failed with exit code $($process.ExitCode)."
    }
}

function Install-Apache {
    Write-Section "Install Apache"

    $existing = Find-ApacheConfig
    if ($existing.found) {
        Write-Host "Apache is already detected: $($existing.httpdConfPath)"
        Save-ApacheDetectedSettingsToDotEnv | Out-Null
        Detect-Apache
        return
    }

    if (-not (Test-IsAdministrator) -and -not (Test-ApacheSkipServiceInstall) -and -not (Test-ApacheAllowNonAdminInstall)) {
        Invoke-ElevatedInstallApache
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        Detect-Apache
        return
    }

    $installRoot = Get-ApacheInstallRoot
    Write-Host "Apache install root: $installRoot"

    $httpdExe = Join-Path $installRoot "bin\httpd.exe"
    $httpdConf = Join-Path $installRoot "conf\httpd.conf"
    $apacheFilesExist = ((Test-Path -LiteralPath $httpdExe -PathType Leaf -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath $httpdConf -PathType Leaf -ErrorAction SilentlyContinue))
    if (-not $apacheFilesExist -and (Test-Path -LiteralPath $installRoot -ErrorAction SilentlyContinue)) {
        $children = @(Get-ChildItem -LiteralPath $installRoot -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Apache install root already exists but does not look like Apache: $installRoot"
        }
    }

    Install-VcRedistForApache

    if (-not $apacheFilesExist) {
        $downloadInfo = Get-ApacheDownloadInfo
        Write-Host "Apache download metadata source: $($downloadInfo.source)"
        $archivePath = Save-ApacheArchive -DownloadInfo $downloadInfo
        Expand-ApacheArchiveToInstallRoot -ArchivePath $archivePath -InstallRoot $installRoot
    } else {
        Write-Host "Apache files already exist: $installRoot"
    }

    $port = Get-ApacheInstallPort
    Set-ApacheHttpdConfig -InstallRoot $installRoot -Port $port
    Install-ApacheService -InstallRoot $installRoot

    Save-ApacheDetectedSettingsToDotEnv | Out-Null
    Detect-Apache
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

    $answers.webPublishByDefault = Read-InitYesNo -Prompt "Publish development branch infobases to Apache for web-client testing?" -Default $false

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
    Write-Host "Apache publication by default: $($answers.webPublishByDefault)"
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
        installApacheIfMissing = (ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("installApacheIfMissing", "INSTALL_APACHE_IF_MISSING") -Default $false) -Default $false)
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
    }

    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Ensure-ApacheForInit {
    param([object]$Answers)

    if (-not $Answers.webPublishByDefault) {
        return
    }

    $settings = Get-EffectiveApacheSettings
    if ($settings.ready) {
        Save-ApacheDetectedSettingsToDotEnv | Out-Null
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        return
    }

    Write-Host "Apache publication is enabled, but Apache is not ready: $($settings.message)"
    if ($InitMode -eq "wizard") {
        if (Read-InitYesNo -Prompt "Install Apache automatically now?" -Default $false) {
            Install-Apache
            Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
            return
        }
        if (Read-InitYesNo -Prompt "Disable Apache publication and continue init?" -Default $true) {
            Set-DotEnvValues -Values @{ WEB_PUBLISH_BY_DEFAULT = "false" }
            Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
            return
        }
        throw "Init stopped until Apache is installed or publication is disabled."
    }

    if ($Answers.installApacheIfMissing) {
        Install-Apache
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        return
    }

    throw "Apache publication is enabled but Apache is not ready. Run install-apache after explicit confirmation or set WEB_PUBLISH_BY_DEFAULT=false."
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
    Ensure-ApacheForInit -Answers $answers
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
        -Offer (Get-ToolOffer -Id "vanessa-automation" -Fallback "Run helper action install-vanessa-automation after explicit developer confirmation.")

    $publishDefault = Get-WebPublishByDefault
    if ($PublishToApache -or $publishDefault) {
        $apacheSettings = Get-EffectiveApacheSettings
        $webInstDetail = if ($apacheSettings.webInstPath) { $apacheSettings.webInstPath } else { "webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set" }
        $results += New-ToolResult `
            -Id "apache-webinst" `
            -Name "Apache/webinst" `
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
            -Name "Apache/httpd config" `
            -Required $true `
            -Ok ([bool]($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) `
            -Detail $apacheDetail `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Run helper action install-apache after explicit developer confirmation, or install/configure Apache 2.4 manually and rerun detect-apache.")

        $publicationDetail = if ($apacheSettings.publicationRoot) {
            "$($apacheSettings.publicationRoot) -> $($apacheSettings.publicationUrlBase)"
        } else {
            "Publication root could not be derived because Apache was not detected."
        }
        $results += New-ToolResult `
            -Id "web-publication" `
            -Name "Web publication target" `
            -Required $true `
            -Ok (-not [string]::IsNullOrWhiteSpace([string]$apacheSettings.publicationRoot)) `
            -Detail $publicationDetail `
            -Offer "After Apache is detected, the default publication root is DocumentRoot\1c and the URL base is derived from Listen."
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

function Start-EnterpriseBackground {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$EnterpriseArgs,
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
    $args = @("ENTERPRISE", "/TESTMANAGER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $EnterpriseArgs

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
    $override = Get-EnvValue -Name "VANESSA_AUTOMATION_ARCHIVE_URL"
    if ($override) {
        return [pscustomobject]@{
            url = [string]$override
            version = ""
            source = "VANESSA_AUTOMATION_ARCHIVE_URL"
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # Best effort for older Windows PowerShell hosts.
    }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Pr-Mex/vanessa-automation/releases/latest" -Headers @{ "User-Agent" = "1c-agent-workflow" }
        $asset = @($release.assets | Where-Object { $_.name -like "vanessa-automation-single*.zip" } | Select-Object -First 1)
        if ($asset.Count -gt 0) {
            return [pscustomobject]@{
                url = [string]$asset[0].browser_download_url
                version = [string]$release.tag_name
                source = "GitHub releases Pr-Mex/vanessa-automation"
            }
        }
    } catch {
        Write-Host "[WARN] Could not read Vanessa Automation latest release from GitHub API: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        url = "https://github.com/Pr-Mex/vanessa-automation/releases/download/1.2.043.28/vanessa-automation-single.1.2.043.28.zip"
        version = "1.2.043.28"
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

    Write-Host "Vanessa Automation is required for development branch tests and is not installed."
    if ($InitMode -eq "wizard") {
        if (Read-InitYesNo -Prompt "Install Vanessa Automation automatically now?" -Default $true) {
            Install-VanessaAutomation
            return
        }
        throw "Init stopped until Vanessa Automation is installed. Run install-vanessa-automation, then rerun init."
    }

    $install = $false
    if ($Answers -and $Answers.PSObject.Properties["installVanessaIfMissing"]) {
        $install = [bool]$Answers.installVanessaIfMissing
    }
    if ($install) {
        Install-VanessaAutomation
        return
    }

    throw "Vanessa Automation is required but missing. Run install-vanessa-automation after explicit confirmation or pass installVanessaIfMissing=true in init JSON."
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
    Write-Host "Vanessa TESTMANAGER/TestClient port: $testPort"
    if ($VanessaFilterTags) {
        Write-Host "Vanessa tag filter: $VanessaFilterTags"
    }
    Write-Host "Dev branch tests use TESTMANAGER -> TESTCLIENT and do not load configuration files. Run update-dev-branch-base before tests when files changed."

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
            -TestManagerPort $testPort `
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
        throw "Invalid Vanessa test port range: $start..$end"
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

    if ($VanessaTestPort -gt 0) {
        if ($reserved.ContainsKey($VanessaTestPort)) {
            throw "Requested Vanessa test port $VanessaTestPort is already reserved by another development branch."
        }
        if (Test-VanessaTestPortUsedByForeignProcess -State $State -Port $VanessaTestPort) {
            throw "Requested Vanessa test port $VanessaTestPort is already used by another branch 1C test process."
        }
        if ((Test-TcpPortAvailable -Port $VanessaTestPort) -or (Test-VanessaTestPortOwnedByState -State $State -Port $VanessaTestPort)) {
            return $VanessaTestPort
        }
        throw "Requested Vanessa test port $VanessaTestPort is already occupied by another process."
    }

    $savedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaTestPort" -Default 0)
    if ($savedPort -gt 0 -and -not $reserved.ContainsKey($savedPort)) {
        if (-not (Test-VanessaTestPortUsedByForeignProcess -State $State -Port $savedPort) -and
            ((Test-TcpPortAvailable -Port $savedPort) -or (Test-VanessaTestPortOwnedByState -State $State -Port $savedPort))) {
            return $savedPort
        }
    }

    $range = Get-VanessaTestPortRange
    for ($port = $range.start; $port -le $range.end; $port++) {
        if ($reserved.ContainsKey($port)) {
            continue
        }
        if (Test-VanessaTestPortUsedByForeignProcess -State $State -Port $port) {
            continue
        }
        if ((Test-TcpPortAvailable -Port $port) -or (Test-VanessaTestPortOwnedByState -State $State -Port $port)) {
            return $port
        }
    }

    throw "No free Vanessa test port found in range $($range.start)..$($range.end). Stop another branch Vanessa run or override VANESSA_TEST_PORT_RANGE."
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
        (Test-OneCProcessBelongsToState -ProcessInfo $_ -State $State -TestPort $TestPort -RequireTestPort)
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
        Write-Host "${Indent}Vanessa verify test port: $port"
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
        throw "Invalid Vanessa MCP port range: $start..$end"
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
    $savedPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "vanessaMcpPid" -Default 0)
    $savedProcess = Get-ProcessByIdOrNull -ProcessId $savedPid

    if ($VanessaMcpPort -gt 0) {
        if ($reserved.ContainsKey($VanessaMcpPort)) {
            throw "Requested Vanessa MCP port $VanessaMcpPort is already reserved by another development branch."
        }
        if (-not (Test-TcpPortAvailable -Port $VanessaMcpPort)) {
            throw "Requested Vanessa MCP port $VanessaMcpPort is already occupied."
        }
        return $VanessaMcpPort
    }

    if ($savedPort -gt 0 -and -not $reserved.ContainsKey($savedPort)) {
        if ((Test-TcpPortAvailable -Port $savedPort) -or ($null -ne $savedProcess)) {
            return $savedPort
        }
    }

    $range = Get-VanessaMcpPortRange
    for ($port = $range.start; $port -le $range.end; $port++) {
        if ($reserved.ContainsKey($port)) {
            continue
        }
        if (Test-TcpPortAvailable -Port $port) {
            return $port
        }
    }

    throw "No free Vanessa MCP port found in range $($range.start)..$($range.end). Stop another branch MCP server or override VANESSA_MCP_PORT_RANGE."
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
        [string]$DefaultFileName
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

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers @{ "User-Agent" = "1c-agent-workflow" }
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
}

function Save-VanessaMcpArtifact {
    param([object]$AssetInfo)

    $installRoot = Get-VanessaMcpInstallRoot
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $targetPath = Join-Path $installRoot ([string]$AssetInfo.name)
    $source = [string]$AssetInfo.url

    Write-Host "Vanessa MCP artifact source: $source"
    $localSource = ConvertFrom-FileUri -Value $source
    if (Test-Path -LiteralPath $localSource -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $localSource -Destination $targetPath -Force
    } else {
        Invoke-WebRequest -Uri $source -UseBasicParsing -OutFile $targetPath
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
    Write-Host "Vanessa MCP artifact SHA256: $hash"
    return [pscustomobject]@{
        path = $targetPath
        version = [string]$AssetInfo.version
        sha256 = $hash
        source = [string]$AssetInfo.source
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
        throw "Vanessa MCP CFE was not found: $CfePath"
    }

    Write-Host "Installing 1C extension '$ExtensionName' from: $CfePath"
    Invoke-Designer `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -DesignerArgs @("/LoadCfg", $CfePath, "-Extension", $ExtensionName, "/UpdateDBCfg") | Out-Null

    return $script:LastLogPath
}

function Install-VanessaMcp {
    Write-Section "Install Vanessa MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "install-vanessa-mcp"
    $runtime = Get-VanessaMcpRuntimeInfo -State $state
    if ($runtime.processAlive) {
        throw "Stop Vanessa MCP for this branch before reinstalling MCP extensions. PID: $($runtime.pid)"
    }

    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        Write-Host "Vanessa Automation EPF is missing; installing it first."
        Install-VanessaAutomation
    }

    $clientAsset = Get-GitHubReleaseAssetInfo `
        -Repository "1c-neurofish/onec-client-mcp-devkit" `
        -AssetNameLike "client_mcp.cfe" `
        -OverrideEnvName "VANESSA_MCP_CLIENT_CFE_URL" `
        -DefaultFileName "client_mcp.cfe"
    $vaExtensionAsset = Get-GitHubReleaseAssetInfo `
        -Repository "Pr-Mex/vanessa-automation" `
        -AssetNameLike "VAExtension*.cfe" `
        -OverrideEnvName "VANESSA_MCP_VA_EXTENSION_CFE_URL" `
        -DefaultFileName "VAExtension.cfe"

    $clientArtifact = Save-VanessaMcpArtifact -AssetInfo $clientAsset
    $vaExtensionArtifact = Save-VanessaMcpArtifact -AssetInfo $vaExtensionAsset

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

    Write-Host "Vanessa MCP extensions installed in development branch infobase."
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

    Write-Host "Vanessa MCP dependencies are not installed for this branch; installing them now."
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

    $serverName = "VanessaAutomation-$safeName"
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

function Write-VanessaMcpStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $runtime = Get-VanessaMcpRuntimeInfo -State $State
    $installedAt = Get-StateValue -State $State -Name "vanessaMcpInstalledAt" -Default ""
    if (-not $installedAt -and $runtime.port -le 0) {
        Write-Host "${Indent}Vanessa MCP: not configured"
        return
    }

    Write-Host "${Indent}Vanessa MCP: $($runtime.status)"
    if ($runtime.port -gt 0) {
        Write-Host "${Indent}Vanessa MCP port: $($runtime.port)"
        Write-Host "${Indent}Vanessa MCP URL: $($runtime.url)"
    }
    if ($runtime.pid -gt 0) {
        Write-Host "${Indent}Vanessa MCP PID: $($runtime.pid)"
    }
    $logPath = Get-StateValue -State $State -Name "vanessaMcpLogPath" -Default ""
    if ($logPath) {
        Write-Host "${Indent}Vanessa MCP log: $logPath"
    }
    if ($installedAt) {
        Write-Host "${Indent}Vanessa MCP installed: $installedAt"
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
        vanessaMcpStoppedAt = (Get-Date).ToString("o")
    }

    if ($runtime.processAlive) {
        if (-not $Quiet) {
            Write-Host "Stopping Vanessa MCP process: PID $($runtime.pid)"
        }
        Stop-Process -Id $runtime.pid -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        Update-DevBranchState -State $State -Updates $updates
        return $true
    }

    Update-DevBranchState -State $State -Updates $updates
    if (-not $Quiet) {
        Write-Host "Vanessa MCP is not running for this branch."
    }
    return $false
}

function Start-VanessaMcp {
    Write-Section "Start Vanessa MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "start-vanessa-mcp"
    $runtime = Get-VanessaMcpRuntimeInfo -State $state
    if ($runtime.processAlive) {
        Save-VanessaMcpSettingsToDotEnv -Port $runtime.port -Url $runtime.url
        Write-Host "Vanessa MCP process is already running for this branch."
        Write-VanessaMcpStatusLines -State $state
        Write-VanessaMcpClientSnippets -State $state
        return
    }

    $state = Ensure-VanessaMcpInstalled -State $state
    $vanessa = Get-VanessaAutomationState
    if (-not $vanessa.ready) {
        throw "Vanessa Automation is not installed. Run install-vanessa-automation first."
    }

    $port = Resolve-VanessaMcpPort -State $state
    $url = Get-VanessaMcpUrl -Port $port
    Save-VanessaMcpSettingsToDotEnv -Port $port -Url $url
    Update-DevBranchState -State $state -Updates @{
        vanessaMcpPort = $port
        vanessaMcpUrl = $url
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    $command = "runMcp;mcpPort=$port"
    $result = Start-EnterpriseBackground `
        -InfoBasePath $state.devBranchInfoBasePath `
        -InfoBaseKind $state.infoBaseKind `
        -EnterpriseArgs @("/Execute", $vanessa.epfPath, "/C$command")

    Update-DevBranchState -State $state -Updates @{
        vanessaMcpPort = $port
        vanessaMcpUrl = $url
        vanessaMcpPid = $result.process.Id
        vanessaMcpStartedAt = (Get-Date).ToString("o")
        vanessaMcpLogPath = $result.logPath
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    if (-not (Wait-VanessaMcpPort -Port $port -TimeoutSeconds 30)) {
        throw "Vanessa MCP process was started, but port $port did not become reachable within 30 seconds. PID: $($result.process.Id). Log: $($result.logPath)"
    }

    Write-Host "Vanessa MCP started."
    Write-VanessaMcpStatusLines -State $state
    Write-VanessaMcpClientSnippets -State $state
}

function Stop-VanessaMcp {
    Write-Section "Stop Vanessa MCP"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "stop-vanessa-mcp"
    Stop-VanessaMcpForState -State $state | Out-Null
}

function Show-VanessaMcpStatus {
    Write-Section "Vanessa MCP status"

    $state = Read-CurrentDevBranchStateForVanessaMcp -Operation "vanessa-mcp-status"
    Write-VanessaMcpStatusLines -State $state
    Write-VanessaMcpClientSnippets -State $state
}

function Get-ItlMcpObjectValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $value = $Object[$Name]
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return $prop.Value
    }

    return $Default
}

function ConvertTo-ItlMcpArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [array]) {
        return @($Value)
    }
    return @($Value)
}

function ConvertTo-ItlMcpHashtable {
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

    foreach ($prop in $Object.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }
    return $hash
}

function Get-ItlMcpLocalHome {
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path ([System.IO.Path]::GetTempPath()) "ITL"
    } else {
        $localAppData = Join-Path $localAppData "ITL"
    }

    return (Join-Path (Join-Path $localAppData "MCP") "vibecoding1c")
}

function Get-ItlMcpLocalPath {
    param([string]$Leaf)
    return (Join-Path (Get-ItlMcpLocalHome) $Leaf)
}

function Read-ItlMcpJsonFile {
    param(
        [string]$Path,
        [object]$Default
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        return (Read-Utf8Text -Path $Path | ConvertFrom-Json)
    }
    return $Default
}

function Write-ItlMcpJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    Write-Utf8Text -Path $Path -Value (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Read-ItlMcpState {
    $path = Get-ItlMcpLocalPath -Leaf "state.json"
    $default = [pscustomobject]@{
        schemaVersion = 1
        version = ""
        model = $null
        servers = @()
        staleIndexes = @()
        keyHash = ""
        updatedAt = ""
    }
    return (Read-ItlMcpJsonFile -Path $path -Default $default)
}

function Write-ItlMcpState {
    param([object]$State)

    $stateHash = ConvertTo-ItlMcpHashtable -Object $State
    $stateHash["schemaVersion"] = 1
    $stateHash["updatedAt"] = (Get-Date).ToString("o")
    New-Item -ItemType Directory -Force -Path (Get-ItlMcpLocalHome) | Out-Null
    Write-ItlMcpJsonFile -Path (Get-ItlMcpLocalPath -Leaf "state.json") -Value $stateHash
    Write-ItlMcpProjectState -State $stateHash
}

function Write-ItlMcpProjectState {
    param([object]$State)

    $projectStatePath = Join-Path $script:ProjectRoot ".agent-1c\mcp\state.json"
    $context = Get-ItlMcpScopeContext
    $servers = @()
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $State -Name "servers" -Default @())) {
        $scope = [string](Get-ItlMcpObjectValue -Object $server -Name "scope" -Default "")
        if ($scope -eq "global") {
            continue
        }
        if (([string](Get-ItlMcpObjectValue -Object $server -Name "projectSlug" -Default "")) -ne $context.projectSlug) {
            continue
        }
        $servers += $server
    }

    $payload = [ordered]@{
        schemaVersion = 1
        projectSlug = $context.projectSlug
        branchSlug = $context.branchSlug
        updatedAt = (Get-Date).ToString("o")
        model = (Get-ItlMcpObjectValue -Object $State -Name "model" -Default $null)
        servers = $servers
        staleIndexes = (Get-ItlMcpObjectValue -Object $State -Name "staleIndexes" -Default @())
    }

    Write-ItlMcpJsonFile -Path $projectStatePath -Value $payload
}

function Read-ItlMcpPortRegistry {
    $path = Get-ItlMcpLocalPath -Leaf "ports.json"
    $default = [pscustomobject]@{
        schemaVersion = 1
        allocations = @()
        updatedAt = ""
    }
    return (Read-ItlMcpJsonFile -Path $path -Default $default)
}

function Write-ItlMcpPortRegistry {
    param([object]$Registry)

    $hash = ConvertTo-ItlMcpHashtable -Object $Registry
    $hash["schemaVersion"] = 1
    $hash["updatedAt"] = (Get-Date).ToString("o")
    New-Item -ItemType Directory -Force -Path (Get-ItlMcpLocalHome) | Out-Null
    Write-ItlMcpJsonFile -Path (Get-ItlMcpLocalPath -Leaf "ports.json") -Value $hash
}

function Invoke-ItlMcpPortRegistryLock {
    param([scriptblock]$ScriptBlock)

    $home = Get-ItlMcpLocalHome
    New-Item -ItemType Directory -Force -Path $home | Out-Null
    $lockPath = Join-Path $home "ports.lock"
    $stream = $null
    for ($attempt = 1; $attempt -le 50; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $stream) {
        throw "Cannot acquire ITL MCP port registry lock: $lockPath"
    }

    try {
        return (& $ScriptBlock)
    } finally {
        $stream.Close()
    }
}

function Get-ItlMcpDistributionRoot {
    if (-not [string]::IsNullOrWhiteSpace($McpDistributionPath)) {
        return [System.IO.Path]::GetFullPath($McpDistributionPath)
    }

    $fromEnv = [string](Get-EnvValue -Name "ITL_MCP_DISTRIBUTION_PATH" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($fromEnv))
    }

    $defaultPath = "D:\Git\MCP vibecoding1c"
    if (Test-Path -LiteralPath $defaultPath -PathType Container -ErrorAction SilentlyContinue) {
        return $defaultPath
    }

    return (Join-Path (Get-ItlMcpLocalHome) "distribution")
}

function Read-ItlMcpDotEnvFile {
    param([string]$Path)

    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $values
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
        $values[$name] = $value
    }

    return $values
}

function Write-ItlMcpDotEnvFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        $lines = @(Read-Utf8Lines -Path $Path)
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

    Write-Utf8Text -Path $Path -Value ((@($updated) -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Get-ItlMcpConfigContext {
    $distributionRoot = Get-ItlMcpDistributionRoot
    $distributionConfigPath = Join-Path $distributionRoot "config.env"
    $localConfigPath = Get-ItlMcpLocalPath -Leaf "config.env"
    $values = [ordered]@{}

    foreach ($source in @(
        (Read-ItlMcpDotEnvFile -Path $distributionConfigPath),
        (Read-ItlMcpDotEnvFile -Path $localConfigPath),
        (Read-ItlMcpDotEnvFile -Path (Join-Path $script:ProjectRoot ".dev.env"))
    )) {
        foreach ($key in $source.Keys) {
            $values[$key] = $source[$key]
        }
    }

    return [pscustomobject]@{
        distributionRoot = $distributionRoot
        distributionConfigPath = $distributionConfigPath
        localConfigPath = $localConfigPath
        values = $values
    }
}

function Get-ItlMcpConfigValue {
    param(
        [object]$Context,
        [string]$Name,
        [object]$Default = ""
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $processValue
    }

    $values = Get-ItlMcpObjectValue -Object $Context -Name "values" -Default $null
    if ($null -ne $values -and $values.Contains($Name)) {
        $value = $values[$Name]
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }

    return $Default
}

function Get-ItlMcpDefaultManifest {
    return [pscustomobject]@{
        schemaVersion = 1
        package = "vibecoding1c"
        servers = @(
            [ordered]@{
                id = "docs"
                title = "1C help search"
                scope = "global"
                mcpNameTemplate = "itl-1c-docs"
                containerNameTemplate = "itl-1c-docs"
                image = "comol/1c_help_mcp:{imageTag}"
                internalPort = 8003
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_HELP"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @(
                    [ordered]@{ from = "PATH_1C_BIN"; to = "/app/1c_bin"; required = $false }
                )
            },
            [ordered]@{
                id = "templates"
                title = "1C templates search"
                scope = "global"
                mcpNameTemplate = "itl-1c-templates"
                containerNameTemplate = "itl-1c-templates"
                image = "comol/template-search-mcp:{imageTag}"
                internalPort = 8004
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_TEMPLATES"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "syntax"
                title = "1C syntax check"
                scope = "global"
                mcpNameTemplate = "itl-1c-syntax"
                containerNameTemplate = "itl-1c-syntax"
                image = "comol/1c_syntaxcheck_mcp:latest"
                internalPort = 8002
                healthPath = "/mcp"
                embedding = $false
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_SYNTAX"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "codechecker"
                title = "1C code checker"
                scope = "global"
                mcpNameTemplate = "itl-1c-codechecker"
                containerNameTemplate = "itl-1c-codechecker"
                image = "comol/1c-code-checker:latest"
                internalPort = 8007
                healthPath = "/mcp"
                embedding = $false
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_CODECHECKER"; required = $true },
                    [ordered]@{ name = "ONEC_AI_TOKEN"; from = "ONEC_AI_TOKEN"; required = $false },
                    [ordered]@{ name = "USESSE"; value = "false" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "ssl"
                title = "1C SSL search"
                scope = "global"
                mcpNameTemplate = "itl-1c-ssl"
                containerNameTemplate = "itl-1c-ssl"
                image = "comol/mcp_ssl_server:{imageTag}"
                internalPort = 8008
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_SSL"; required = $true },
                    [ordered]@{ name = "SSL_VERSION"; from = "SSL_VERSION"; required = $false },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "code"
                title = "Project code metadata search"
                scope = "project"
                mcpNameTemplate = "itl-{projectSlug}-code"
                containerNameTemplate = "itl-{projectSlug}-code"
                image = "comol/1c_code_metadata_mcp:{imageTag}"
                internalPort = 8000
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_CODEMETADATA"; required = $true },
                    [ordered]@{ name = "METADATA_PATH"; value = "/app/metadata" },
                    [ordered]@{ name = "CODE_PATH"; value = "/app/code" },
                    [ordered]@{ name = "RESET_CACHE"; from = "RESET_CACHE"; default = "false" },
                    [ordered]@{ name = "RESET_DATABASE"; from = "RESET_DATABASE"; default = "false" },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @(
                    [ordered]@{ from = "PATH_METADATA"; to = "/app/metadata"; required = $true },
                    [ordered]@{ from = "PATH_CODE"; to = "/app/code"; required = $true; fallback = "exportPath" },
                    [ordered]@{ from = "PATH_BASES"; to = "/app/chroma_db"; required = $false; subdir = "mcp_codemetadata"; fallback = "mcpBases" }
                )
            },
            [ordered]@{
                id = "graph"
                title = "Project graph metadata search"
                scope = "project"
                mcpNameTemplate = "itl-{projectSlug}-graph"
                containerNameTemplate = "itl-{projectSlug}-graph"
                compose = $true
                composePath = "Graph_metadata_search\docker-compose.yml"
                composeProjectTemplate = "itl-{projectSlug}-graph"
                internalPort = 8006
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_GRAPH"; required = $true },
                    [ordered]@{ name = "METADATA_HOST_PATH"; from = "PATH_METADATA"; required = $true },
                    [ordered]@{ name = "METADATA_FILES_HOST_PATH"; from = "PATH_CODE"; required = $true; fallback = "exportPath" },
                    [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                    [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                    [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false },
                    [ordered]@{ name = "OPENAI_EMBEDDING_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_EMBEDDING_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_EMBEDDING_MODEL"; embedding = "model" },
                    [ordered]@{ name = "MCP_PORT"; value = "8006" },
                    [ordered]@{ name = "MCP_USE_SSE"; value = "false" },
                    [ordered]@{ name = "RESET_DATABASE"; from = "RESET_DATABASE"; default = "false" },
                    [ordered]@{ name = "PROJECT_NAME"; value = "{projectSlug}" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "vanessa"
                title = "Branch Vanessa Automation MCP"
                scope = "branch"
                mcpNameTemplate = "itl-{projectSlug}-{branchSlug}-vanessa"
                containerNameTemplate = "itl-{projectSlug}-{branchSlug}-vanessa"
                localVanessa = $true
                internalPort = 0
                healthPath = "/mcp"
                embedding = $false
                env = @()
                volumes = @()
            }
        )
    }
}

function Read-ItlMcpManifest {
    $distributionRoot = Get-ItlMcpDistributionRoot
    $manifestPath = Join-Path $distributionRoot "itl-mcp.manifest.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return (Read-Utf8Text -Path $manifestPath | ConvertFrom-Json)
    }
    return (Get-ItlMcpDefaultManifest)
}

function Get-ItlMcpScopeContext {
    $projectSlug = ConvertTo-SafeName (Split-Path -Leaf $script:ProjectRoot)
    $gitBranch = ""
    try {
        if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git")) {
            $gitBranch = Get-CurrentBranch
        }
    } catch {
        $gitBranch = ""
    }

    $branchSlug = ""
    if ($gitBranch -like "itldev/*") {
        $branchSlug = ConvertTo-SafeName ($gitBranch.Substring("itldev/".Length))
    } elseif ($gitBranch) {
        $branchSlug = ConvertTo-SafeName $gitBranch
    } else {
        $branchSlug = "no-branch"
    }

    return [pscustomobject]@{
        projectRoot = $script:ProjectRoot
        projectSlug = $projectSlug
        gitBranch = $gitBranch
        branchSlug = $branchSlug
        isDevelopmentBranch = ($gitBranch -like "itldev/*")
    }
}

function Expand-ItlMcpTemplate {
    param(
        [string]$Template,
        [object]$Context,
        [string]$ServerId = ""
    )

    $value = $Template
    $value = $value.Replace("{projectSlug}", [string](Get-ItlMcpObjectValue -Object $Context -Name "projectSlug" -Default "project"))
    $value = $value.Replace("{branchSlug}", [string](Get-ItlMcpObjectValue -Object $Context -Name "branchSlug" -Default "branch"))
    $value = $value.Replace("{serverId}", $ServerId)
    return $value
}

function Get-ItlMcpImageName {
    param(
        [object]$Server,
        [object]$ConfigContext
    )

    $image = [string](Get-ItlMcpObjectValue -Object $Server -Name "image" -Default "")
    $imageTag = [string](Get-ItlMcpConfigValue -Context $ConfigContext -Name "IMAGE_TAG" -Default "latest")
    if ($imageTag -eq "light" -and $image -match ':latest$') {
        return $image
    }
    return $image.Replace("{imageTag}", $imageTag)
}

function Get-ItlMcpPortRange {
    param([string]$Scope)

    switch ($Scope) {
        "global" { return [pscustomobject]@{ start = 18000; end = 18099 } }
        "project" { return [pscustomobject]@{ start = 18100; end = 18499 } }
        "branch" { return [pscustomobject]@{ start = 18500; end = 18999 } }
        "model" { return [pscustomobject]@{ start = 19000; end = 19049 } }
        default { throw "Unknown ITL MCP port scope: $Scope" }
    }
}

function Test-ItlMcpDockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-ItlMcpDockerContainerStatus {
    param([string]$ContainerName)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return ""
    }
    $output = & docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}|{{.Status}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }
    foreach ($line in @($output)) {
        if ($line -like "$ContainerName|*") {
            return ($line.Substring($ContainerName.Length + 1))
        }
    }
    return ""
}

function Test-ItlMcpDockerContainerExists {
    param([string]$ContainerName)
    return -not [string]::IsNullOrWhiteSpace((Get-ItlMcpDockerContainerStatus -ContainerName $ContainerName))
}

function Remove-ItlMcpStalePortAllocations {
    param([object]$Registry)

    $kept = @()
    foreach ($allocation in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $Registry -Name "allocations" -Default @())) {
        $port = ConvertTo-IntOrDefault -Value (Get-ItlMcpObjectValue -Object $allocation -Name "port" -Default 0)
        $containerName = [string](Get-ItlMcpObjectValue -Object $allocation -Name "containerName" -Default "")
        if ($containerName -and (Test-ItlMcpDockerContainerExists -ContainerName $containerName)) {
            $kept += $allocation
            continue
        }
        if ($port -gt 0 -and -not (Test-TcpPortAvailable -Port $port)) {
            $kept += $allocation
            continue
        }
    }

    $hash = ConvertTo-ItlMcpHashtable -Object $Registry
    $hash["allocations"] = $kept
    return [pscustomobject]$hash
}

function Resolve-ItlMcpPort {
    param(
        [string]$Scope,
        [string]$Key,
        [string]$ServerId,
        [string]$ContainerName
    )

    $result = Invoke-ItlMcpPortRegistryLock -ScriptBlock {
        $registry = Remove-ItlMcpStalePortAllocations -Registry (Read-ItlMcpPortRegistry)
        $allocations = @(ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $registry -Name "allocations" -Default @()))
        foreach ($allocation in $allocations) {
            if ([string](Get-ItlMcpObjectValue -Object $allocation -Name "key" -Default "") -eq $Key) {
                $savedPort = ConvertTo-IntOrDefault -Value (Get-ItlMcpObjectValue -Object $allocation -Name "port" -Default 0)
                if ($savedPort -gt 0) {
                    Write-ItlMcpPortRegistry -Registry $registry
                    return [pscustomobject]@{ port = $savedPort }
                }
            }
        }

        $used = @{}
        foreach ($allocation in $allocations) {
            $usedPort = ConvertTo-IntOrDefault -Value (Get-ItlMcpObjectValue -Object $allocation -Name "port" -Default 0)
            if ($usedPort -gt 0) {
                $used[$usedPort] = $true
            }
        }

        $range = Get-ItlMcpPortRange -Scope $Scope
        for ($port = $range.start; $port -le $range.end; $port++) {
            if ($used.ContainsKey($port)) {
                continue
            }
            if (-not (Test-TcpPortAvailable -Port $port)) {
                continue
            }

            $newAllocation = [ordered]@{
                key = $Key
                scope = $Scope
                serverId = $ServerId
                port = $port
                containerName = $ContainerName
                projectRoot = $script:ProjectRoot
                updatedAt = (Get-Date).ToString("o")
            }
            $hash = ConvertTo-ItlMcpHashtable -Object $registry
            $hash["allocations"] = @($allocations + $newAllocation)
            Write-ItlMcpPortRegistry -Registry $hash
            return [pscustomobject]@{ port = $port }
        }

        throw "No free ITL MCP host port found in range $($range.start)..$($range.end) for $Scope server '$ServerId'."
    }

    return [int]$result.port
}

function Resolve-ItlMcpModelPort {
    if ((Test-ItlMcpEmbeddingEndpoint -Port 1234) -or (Test-TcpPortAvailable -Port 1234)) {
        return 1234
    }
    return (Resolve-ItlMcpPort -Scope "model" -Key "model:lm-studio" -ServerId "lm-studio" -ContainerName "")
}

function Get-ItlMcpHardwareProfile {
    $gpuMemoryMb = 0
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $values = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
            foreach ($value in @($values)) {
                $parsed = ConvertTo-IntOrDefault -Value $value -Default 0
                if ($parsed -gt $gpuMemoryMb) {
                    $gpuMemoryMb = $parsed
                }
            }
        } catch {
            $gpuMemoryMb = 0
        }
    }

    $ramGb = 0
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ramGb = [int][Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 0)
    } catch {
        $ramGb = 0
    }

    return [pscustomobject]@{
        gpuMemoryMb = $gpuMemoryMb
        ramGb = $ramGb
    }
}

function Select-ItlMcpEmbeddingModel {
    param(
        [int]$GpuMemoryMb = -1,
        [int]$RamGb = -1
    )

    if ($GpuMemoryMb -lt 0 -or $RamGb -lt 0) {
        $profile = Get-ItlMcpHardwareProfile
        if ($GpuMemoryMb -lt 0) {
            $GpuMemoryMb = [int]$profile.gpuMemoryMb
        }
        if ($RamGb -lt 0) {
            $RamGb = [int]$profile.ramGb
        }
    }

    if ($GpuMemoryMb -ge 6144) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q8_0"; modelId = "Qwen3-Embedding-4B-GGUF:Q8_0"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($GpuMemoryMb -ge 4096) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q6_K"; modelId = "Qwen3-Embedding-4B-GGUF:Q6_K"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($GpuMemoryMb -ge 3072) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q4_K_M"; modelId = "Qwen3-Embedding-4B-GGUF:Q4_K_M"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($RamGb -gt 0 -and $RamGb -lt 16) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "cpu"; model = "intfloat/multilingual-e5-small"; quantization = ""; modelId = "intfloat/multilingual-e5-small"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    return [pscustomobject]@{ provider = "lm-studio"; mode = "cpu"; model = "intfloat/multilingual-e5-base"; quantization = ""; modelId = "intfloat/multilingual-e5-base"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
}

function Test-ItlMcpEmbeddingEndpoint {
    param([int]$Port)

    try {
        $uri = "http://127.0.0.1:$Port/v1/models"
        Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-ItlMcpModel {
    Write-Section "ITL MCP embedding model"

    $state = Read-ItlMcpState
    $stateHash = ConvertTo-ItlMcpHashtable -Object $state
    $previousModel = Get-ItlMcpObjectValue -Object (Get-ItlMcpObjectValue -Object $state -Name "model" -Default $null) -Name "modelId" -Default ""
    $selection = Select-ItlMcpEmbeddingModel
    $port = Resolve-ItlMcpModelPort
    $apiBase = "http://host.docker.internal:$port/v1"
    $ready = Test-ItlMcpEmbeddingEndpoint -Port $port
    $lms = Get-Command lms -ErrorAction SilentlyContinue
    $notes = @()

    if (-not $ready -and $lms) {
        try {
            & lms get $selection.model *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms get returned exit code $LASTEXITCODE for $($selection.model)."
            }
        } catch {
            $notes += "lms get failed for $($selection.model): $($_.Exception.Message)"
        }
        try {
            & lms load $selection.model *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms load returned exit code $LASTEXITCODE for $($selection.model)."
            }
        } catch {
            $notes += "lms load failed for $($selection.model): $($_.Exception.Message)"
        }
        try {
            & lms server start --port $port *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms server start returned exit code $LASTEXITCODE on port $port."
            }
        } catch {
            $notes += "lms server start failed on port ${port}: $($_.Exception.Message)"
        }
        $ready = Test-ItlMcpEmbeddingEndpoint -Port $port
    } elseif (-not $ready) {
        $notes += "LM Studio CLI 'lms' was not found. Install LM Studio, open it once, then rerun mcp-ensure-model."
    }

    if ($previousModel -and $previousModel -ne $selection.modelId) {
        $stateHash["staleIndexes"] = @("docs", "templates", "ssl", "code", "graph")
        Write-Host "Embedding model changed from $previousModel to $($selection.modelId). Affected indexes are marked stale; set RESET_DATABASE=true explicitly before reindexing."
    } elseif (-not $stateHash.Contains("staleIndexes")) {
        $stateHash["staleIndexes"] = @()
    }

    $stateHash["model"] = [ordered]@{
        provider = $selection.provider
        mode = $selection.mode
        model = $selection.model
        quantization = $selection.quantization
        modelId = $selection.modelId
        port = $port
        apiBase = $apiBase
        apiKey = "lm-studio"
        ready = [bool]$ready
        gpuMemoryMb = $selection.gpuMemoryMb
        ramGb = $selection.ramGb
        updatedAt = (Get-Date).ToString("o")
        notes = $notes
    }

    Write-ItlMcpState -State $stateHash

    Write-Host "Selected embedding model: $($selection.modelId)"
    Write-Host "Embedding API base for containers: $apiBase"
    Write-Host "Embedding endpoint ready: $ready"
    foreach ($note in $notes) {
        Write-Host "NOTE: $note"
    }

    return [pscustomobject]$stateHash["model"]
}

function Get-ItlMcpEmbeddingEnv {
    $state = Read-ItlMcpState
    $model = Get-ItlMcpObjectValue -Object $state -Name "model" -Default $null
    if ($null -eq $model) {
        $model = Ensure-ItlMcpModel
    }

    return [pscustomobject]@{
        base = [string](Get-ItlMcpObjectValue -Object $model -Name "apiBase" -Default "")
        key = [string](Get-ItlMcpObjectValue -Object $model -Name "apiKey" -Default "lm-studio")
        model = [string](Get-ItlMcpObjectValue -Object $model -Name "model" -Default "")
    }
}

function Resolve-ItlMcpConfiguredPath {
    param(
        [object]$ConfigContext,
        [string]$Name,
        [string]$Fallback = "",
        [string]$Subdir = ""
    )

    $value = [string](Get-ItlMcpConfigValue -Context $ConfigContext -Name $Name -Default "")
    if (-not $value -and $Fallback -eq "exportPath") {
        $value = Resolve-ProjectPath (Get-ExportPath)
    }
    if (-not $value -and $Fallback -eq "mcpBases") {
        $value = Join-Path $script:ProjectRoot ".agent-1c\mcp\bases"
    }
    if (-not $value) {
        return ""
    }
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        $value = Resolve-ProjectPath $value
    }
    if ($Subdir) {
        $value = Join-Path $value $Subdir
    }
    return [System.IO.Path]::GetFullPath($value)
}

function New-ItlMcpServerRuntime {
    param(
        [object]$Server,
        [object]$Context,
        [object]$ConfigContext
    )

    $id = [string](Get-ItlMcpObjectValue -Object $Server -Name "id" -Default "")
    $scope = [string](Get-ItlMcpObjectValue -Object $Server -Name "scope" -Default "global")
    $nameTemplate = [string](Get-ItlMcpObjectValue -Object $Server -Name "mcpNameTemplate" -Default "itl-$id")
    $containerTemplate = [string](Get-ItlMcpObjectValue -Object $Server -Name "containerNameTemplate" -Default $nameTemplate)
    $mcpName = Expand-ItlMcpTemplate -Template $nameTemplate -Context $Context -ServerId $id
    $containerName = Expand-ItlMcpTemplate -Template $containerTemplate -Context $Context -ServerId $id
    $portKey = "${scope}:$mcpName"
    $internalPort = ConvertTo-IntOrDefault -Value (Get-ItlMcpObjectValue -Object $Server -Name "internalPort" -Default 0)
    $hostPort = 0
    if ($internalPort -gt 0) {
        $hostPort = Resolve-ItlMcpPort -Scope $scope -Key $portKey -ServerId $id -ContainerName $containerName
    }

    $url = ""
    if ($hostPort -gt 0) {
        $url = "http://127.0.0.1:$hostPort/mcp"
    }

    return [pscustomobject]@{
        id = $id
        scope = $scope
        name = $mcpName
        containerName = $containerName
        internalPort = $internalPort
        hostPort = $hostPort
        url = $url
        projectSlug = $Context.projectSlug
        branchSlug = $Context.branchSlug
        gitBranch = $Context.gitBranch
        projectRoot = $Context.projectRoot
        image = (Get-ItlMcpImageName -Server $Server -ConfigContext $ConfigContext)
    }
}

function Resolve-ItlMcpEnvironment {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $embedding = Get-ItlMcpEmbeddingEnv
    $env = [ordered]@{}
    $missing = @()
    foreach ($entry in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $Server -Name "env" -Default @())) {
        $name = [string](Get-ItlMcpObjectValue -Object $entry -Name "name" -Default "")
        if (-not $name) {
            continue
        }

        $value = ""
        $embeddingKind = [string](Get-ItlMcpObjectValue -Object $entry -Name "embedding" -Default "")
        if ($embeddingKind) {
            $value = [string](Get-ItlMcpObjectValue -Object $embedding -Name $embeddingKind -Default "")
        } elseif (Get-ItlMcpObjectValue -Object $entry -Name "value" -Default $null) {
            $value = [string](Get-ItlMcpObjectValue -Object $entry -Name "value" -Default "")
            $value = $value.Replace("{projectSlug}", [string](Get-ItlMcpObjectValue -Object $Runtime -Name "projectSlug" -Default ""))
            $value = $value.Replace("{branchSlug}", [string](Get-ItlMcpObjectValue -Object $Runtime -Name "branchSlug" -Default ""))
        } else {
            $from = [string](Get-ItlMcpObjectValue -Object $entry -Name "from" -Default "")
            $fallback = [string](Get-ItlMcpObjectValue -Object $entry -Name "fallback" -Default "")
            if ($from -like "PATH_*") {
                $value = Resolve-ItlMcpConfiguredPath -ConfigContext $ConfigContext -Name $from -Fallback $fallback
            } else {
                $value = [string](Get-ItlMcpConfigValue -Context $ConfigContext -Name $from -Default (Get-ItlMcpObjectValue -Object $entry -Name "default" -Default ""))
            }
        }

        $required = ConvertTo-BoolSetting -Value (Get-ItlMcpObjectValue -Object $entry -Name "required" -Default $false) -Default $false
        if ($required -and [string]::IsNullOrWhiteSpace($value)) {
            $missing += $name
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $env[$name] = $value
        }
    }

    return [pscustomobject]@{
        values = $env
        missing = $missing
    }
}

function Resolve-ItlMcpVolumes {
    param(
        [object]$Server,
        [object]$ConfigContext
    )

    $volumes = @()
    $missing = @()
    foreach ($entry in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $Server -Name "volumes" -Default @())) {
        $from = [string](Get-ItlMcpObjectValue -Object $entry -Name "from" -Default "")
        $to = [string](Get-ItlMcpObjectValue -Object $entry -Name "to" -Default "")
        if (-not $from -or -not $to) {
            continue
        }
        $hostPath = Resolve-ItlMcpConfiguredPath -ConfigContext $ConfigContext -Name $from -Fallback ([string](Get-ItlMcpObjectValue -Object $entry -Name "fallback" -Default "")) -Subdir ([string](Get-ItlMcpObjectValue -Object $entry -Name "subdir" -Default ""))
        $required = ConvertTo-BoolSetting -Value (Get-ItlMcpObjectValue -Object $entry -Name "required" -Default $false) -Default $false
        if (-not $hostPath) {
            if ($required) {
                $missing += $from
            }
            continue
        }
        if ($required -and -not (Test-Path -LiteralPath $hostPath -ErrorAction SilentlyContinue)) {
            $missing += $from
            continue
        }
        New-Item -ItemType Directory -Force -Path $hostPath | Out-Null
        $volumes += [pscustomobject]@{ host = $hostPath; container = $to }
    }

    return [pscustomobject]@{
        values = $volumes
        missing = $missing
    }
}

function Set-ItlMcpEndpointState {
    param(
        [object]$Runtime,
        [string]$Status,
        [string]$RuntimePath = "",
        [string]$ComposeProject = ""
    )

    $state = Read-ItlMcpState
    $stateHash = ConvertTo-ItlMcpHashtable -Object $state
    $servers = @()
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $state -Name "servers" -Default @())) {
        if ([string](Get-ItlMcpObjectValue -Object $server -Name "name" -Default "") -ne $Runtime.name) {
            $servers += $server
        }
    }

    $servers += [ordered]@{
        id = $Runtime.id
        scope = $Runtime.scope
        name = $Runtime.name
        containerName = $Runtime.containerName
        internalPort = $Runtime.internalPort
        hostPort = $Runtime.hostPort
        url = $Runtime.url
        status = $Status
        image = $Runtime.image
        projectSlug = $Runtime.projectSlug
        branchSlug = $Runtime.branchSlug
        gitBranch = $Runtime.gitBranch
        projectRoot = $Runtime.projectRoot
        runtimePath = $RuntimePath
        composeProject = $ComposeProject
        updatedAt = (Get-Date).ToString("o")
    }

    $stateHash["servers"] = $servers
    Write-ItlMcpState -State $stateHash
}

function Start-ItlMcpDockerRunServer {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $envResult = Resolve-ItlMcpEnvironment -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    $volumeResult = Resolve-ItlMcpVolumes -Server $Server -ConfigContext $ConfigContext
    $missing = @($envResult.missing + $volumeResult.missing)
    if ($missing.Count -gt 0) {
        Write-Host "Skipping $($Runtime.name): missing required settings $($missing -join ', ')."
        Set-ItlMcpEndpointState -Runtime $Runtime -Status "missing-settings"
        return
    }

    if (-not (Test-ItlMcpDockerAvailable)) {
        Write-Host "Skipping $($Runtime.name): Docker is not available."
        Set-ItlMcpEndpointState -Runtime $Runtime -Status "docker-unavailable"
        return
    }

    $existing = Get-ItlMcpDockerContainerStatus -ContainerName $Runtime.containerName
    if ($existing) {
        & docker start $Runtime.containerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Docker failed to start existing container $($Runtime.containerName)."
        }
        Write-Host "Started existing MCP container: $($Runtime.containerName) -> $($Runtime.url)"
        Set-ItlMcpEndpointState -Runtime $Runtime -Status "running"
        return
    }

    $args = @("run", "-d", "--name", $Runtime.containerName, "-p", "$($Runtime.hostPort):$($Runtime.internalPort)")
    $useGpu = ConvertTo-BoolSetting -Value (Get-ItlMcpConfigValue -Context $ConfigContext -Name "USE_GPU" -Default $false) -Default $false
    if ($useGpu) {
        $args += @("--gpus", "all")
    }
    foreach ($key in @($envResult.values.Keys | Sort-Object)) {
        $args += @("-e", "$key=$($envResult.values[$key])")
    }
    foreach ($volume in $volumeResult.values) {
        $args += @("-v", "$($volume.host):$($volume.container)")
    }
    $args += $Runtime.image

    & docker @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed to create MCP container $($Runtime.containerName)."
    }

    Write-Host "Started MCP container: $($Runtime.containerName) -> $($Runtime.url)"
    Set-ItlMcpEndpointState -Runtime $Runtime -Status "running"
}

function New-ItlMcpScopedCompose {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $distributionRoot = [string](Get-ItlMcpObjectValue -Object $ConfigContext -Name "distributionRoot" -Default (Get-ItlMcpDistributionRoot))
    $composePath = [string](Get-ItlMcpObjectValue -Object $Server -Name "composePath" -Default "")
    $sourceCompose = Join-Path $distributionRoot $composePath
    if (-not (Test-Path -LiteralPath $sourceCompose -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Compose file was not found for $($Runtime.name): $sourceCompose"
    }

    $runtimeDir = Join-Path $script:ProjectRoot ".agent-1c\mcp\$($Runtime.scope)-$($Runtime.name)"
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $targetCompose = Join-Path $runtimeDir "docker-compose.yml"
    $composeText = Read-Utf8Text -Path $sourceCompose
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*neo4j\s*$', "    container_name: $($Runtime.containerName)-neo4j"
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*1c_graph_metadata\s*$', "    container_name: $($Runtime.containerName)"
    $composeText = [regex]::Replace($composeText, '(?ms)^    ports:\r?\n      - "7474:7474"\r?\n      - "7687:7687"\r?\n', '')
    $composeText = $composeText -replace '"8006:8006"', "`"$($Runtime.hostPort):$($Runtime.internalPort)`""
    Write-Utf8Text -Path $targetCompose -Value $composeText

    $envResult = Resolve-ItlMcpEnvironment -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    if ($envResult.missing.Count -gt 0) {
        return [pscustomobject]@{
            ready = $false
            missing = $envResult.missing
            runtimeDir = $runtimeDir
            composePath = $targetCompose
            composeProject = ""
        }
    }

    $envPath = Join-Path $runtimeDir ".env"
    Write-ItlMcpDotEnvFile -Path $envPath -Values $envResult.values
    $composeProjectTemplate = [string](Get-ItlMcpObjectValue -Object $Server -Name "composeProjectTemplate" -Default $Runtime.name)
    $composeProject = Expand-ItlMcpTemplate -Template $composeProjectTemplate -Context (Get-ItlMcpScopeContext) -ServerId $Runtime.id
    return [pscustomobject]@{
        ready = $true
        missing = @()
        runtimeDir = $runtimeDir
        composePath = $targetCompose
        composeProject = $composeProject
    }
}

function Start-ItlMcpComposeServer {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $compose = New-ItlMcpScopedCompose -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    if (-not $compose.ready) {
        Write-Host "Skipping $($Runtime.name): missing required settings $($compose.missing -join ', ')."
        Set-ItlMcpEndpointState -Runtime $Runtime -Status "missing-settings" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
        return
    }

    if (-not (Test-ItlMcpDockerAvailable)) {
        Write-Host "Skipping $($Runtime.name): Docker is not available."
        Set-ItlMcpEndpointState -Runtime $Runtime -Status "docker-unavailable" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
        return
    }

    & docker compose -p $compose.composeProject -f $compose.composePath --env-file (Join-Path $compose.runtimeDir ".env") up -d | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker compose failed for MCP server $($Runtime.name)."
    }

    Write-Host "Started MCP compose project: $($compose.composeProject) -> $($Runtime.url)"
    Set-ItlMcpEndpointState -Runtime $Runtime -Status "running" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
}

function Start-ItlMcpVanessaServer {
    param([object]$Runtime)

    $context = Get-ItlMcpScopeContext
    if (-not $context.isDevelopmentBranch) {
        Write-Host "Skipping branch Vanessa MCP: current worktree is not itldev/*."
        return
    }

    Start-VanessaMcp
    $state = Read-DevBranchState -Name ""
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $state -Name "vanessaMcpPort" -Default 0)
    $url = Get-StateValue -State $state -Name "vanessaMcpUrl" -Default $(if ($port -gt 0) { Get-VanessaMcpUrl -Port $port } else { "" })
    $runtime.hostPort = $port
    $runtime.url = $url
    Set-ItlMcpEndpointState -Runtime $Runtime -Status "running"
}

function Get-ItlMcpTargetScopes {
    $context = Get-ItlMcpScopeContext
    switch ($McpScope) {
        "global" { return @("global") }
        "project" { return @("project") }
        "branch" { return @("branch") }
        "all" { return @("global", "project", "branch") }
        default {
            $scopes = @("global", "project")
            if ($context.isDevelopmentBranch) {
                $scopes += "branch"
            }
            return $scopes
        }
    }
}

function Select-ItlMcpManifestServers {
    $manifest = Read-ItlMcpManifest
    $targetScopes = Get-ItlMcpTargetScopes
    $servers = @()
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $manifest -Name "servers" -Default @())) {
        $id = [string](Get-ItlMcpObjectValue -Object $server -Name "id" -Default "")
        $scope = [string](Get-ItlMcpObjectValue -Object $server -Name "scope" -Default "global")
        if ($McpServerId -and $id -ne $McpServerId) {
            continue
        }
        if ($targetScopes -notcontains $scope) {
            continue
        }
        $servers += $server
    }
    return $servers
}

function Rotate-ItlMcpKeys {
    Write-Section "ITL MCP rotate keys"

    $context = Get-ItlMcpConfigContext
    $distributionConfigPath = [string]$context.distributionConfigPath
    if (-not (Test-Path -LiteralPath $distributionConfigPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "MCP distribution config.env was not found: $distributionConfigPath"
    }

    $sourceValues = Read-ItlMcpDotEnvFile -Path $distributionConfigPath
    $rotated = [ordered]@{}
    foreach ($key in @($sourceValues.Keys | Sort-Object)) {
        if ($key -like "LICENSE_KEY_*" -or $key -eq "ONEC_AI_TOKEN") {
            $rotated[$key] = $sourceValues[$key]
        }
    }

    if ($rotated.Keys.Count -eq 0) {
        Write-Host "No license keys found in distribution config.env."
        return
    }

    Write-ItlMcpDotEnvFile -Path $context.localConfigPath -Values $rotated
    $hashInput = (($rotated.Keys | Sort-Object | ForEach-Object { "$_=$($rotated[$_])" }) -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $keyHash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    $state = Read-ItlMcpState
    $stateHash = ConvertTo-ItlMcpHashtable -Object $state
    $stateHash["keyHash"] = $keyHash
    $stateHash["keyUpdatedAt"] = (Get-Date).ToString("o")
    Write-ItlMcpState -State $stateHash

    Write-Host "Rotated MCP license keys into local config: $($context.localConfigPath)"
    Write-Host "Key hash: $keyHash"
}

function Start-ItlMcp {
    Write-Section "Start ITL MCP"

    Ensure-GitIgnore
    Ensure-ItlMcpModel | Out-Null
    $context = Get-ItlMcpScopeContext
    $configContext = Get-ItlMcpConfigContext
    foreach ($server in Select-ItlMcpManifestServers) {
        $runtime = New-ItlMcpServerRuntime -Server $server -Context $context -ConfigContext $configContext
        if (ConvertTo-BoolSetting -Value (Get-ItlMcpObjectValue -Object $server -Name "localVanessa" -Default $false) -Default $false) {
            Start-ItlMcpVanessaServer -Runtime $runtime
        } elseif (ConvertTo-BoolSetting -Value (Get-ItlMcpObjectValue -Object $server -Name "compose" -Default $false) -Default $false) {
            Start-ItlMcpComposeServer -Server $server -Runtime $runtime -ConfigContext $configContext
        } else {
            Start-ItlMcpDockerRunServer -Server $server -Runtime $runtime -ConfigContext $configContext
        }
    }

    Write-ItlMcpClientConfig
}

function Stop-ItlMcp {
    Write-Section "Stop ITL MCP"

    $state = Read-ItlMcpState
    $stateHash = ConvertTo-ItlMcpHashtable -Object $state
    $context = Get-ItlMcpScopeContext
    $targetScopes = Get-ItlMcpTargetScopes
    $servers = @()
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $state -Name "servers" -Default @())) {
        $scope = [string](Get-ItlMcpObjectValue -Object $server -Name "scope" -Default "")
        $name = [string](Get-ItlMcpObjectValue -Object $server -Name "name" -Default "")
        if ($targetScopes -notcontains $scope) {
            $servers += $server
            continue
        }
        if ($scope -ne "global" -and ([string](Get-ItlMcpObjectValue -Object $server -Name "projectSlug" -Default "")) -ne $context.projectSlug) {
            $servers += $server
            continue
        }
        if ($McpServerId -and ([string](Get-ItlMcpObjectValue -Object $server -Name "id" -Default "")) -ne $McpServerId) {
            $servers += $server
            continue
        }

        if ([string](Get-ItlMcpObjectValue -Object $server -Name "id" -Default "") -eq "vanessa" -and $context.isDevelopmentBranch) {
            try {
                $devState = Read-DevBranchState -Name ""
                Stop-VanessaMcpForState -State $devState | Out-Null
            } catch {
                Write-Host "Vanessa MCP stop skipped: $($_.Exception.Message)"
            }
        } else {
            $composeProject = [string](Get-ItlMcpObjectValue -Object $server -Name "composeProject" -Default "")
            $runtimePath = [string](Get-ItlMcpObjectValue -Object $server -Name "runtimePath" -Default "")
            if ($composeProject -and $runtimePath -and (Test-ItlMcpDockerAvailable)) {
                $composePath = Join-Path $runtimePath "docker-compose.yml"
                if (Test-Path -LiteralPath $composePath -PathType Leaf -ErrorAction SilentlyContinue) {
                    & docker compose -p $composeProject -f $composePath --env-file (Join-Path $runtimePath ".env") down | Out-Null
                }
            } else {
                $containerName = [string](Get-ItlMcpObjectValue -Object $server -Name "containerName" -Default "")
                if ($containerName -and (Test-ItlMcpDockerAvailable) -and (Test-ItlMcpDockerContainerExists -ContainerName $containerName)) {
                    & docker stop $containerName | Out-Null
                }
            }
        }

        $serverHash = ConvertTo-ItlMcpHashtable -Object $server
        $serverHash["status"] = "stopped"
        $serverHash["updatedAt"] = (Get-Date).ToString("o")
        $servers += $serverHash
        Write-Host "Stopped MCP server: $name"
    }

    $stateHash["servers"] = $servers
    Write-ItlMcpState -State $stateHash
    Write-ItlMcpClientConfig
}

function Update-ItlMcp {
    Write-Section "Update ITL MCP"

    Rotate-ItlMcpKeys
    $configContext = Get-ItlMcpConfigContext
    if (-not (Test-ItlMcpDockerAvailable)) {
        Write-Host "Docker is not available; image pull skipped."
        return
    }

    $pulled = @{}
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object (Read-ItlMcpManifest) -Name "servers" -Default @())) {
        $image = Get-ItlMcpImageName -Server $server -ConfigContext $configContext
        if (-not $image -or $pulled.ContainsKey($image)) {
            continue
        }
        & docker pull $image | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: docker pull failed for $image"
        } else {
            Write-Host "Pulled image: $image"
        }
        $pulled[$image] = $true
    }
}

function Setup-ItlMcp {
    Write-Section "Setup ITL MCP"

    Ensure-GitIgnore
    if (Test-Path -LiteralPath (Join-Path (Get-ItlMcpDistributionRoot) "config.env") -PathType Leaf -ErrorAction SilentlyContinue) {
        Rotate-ItlMcpKeys
    } else {
        Write-Host "Distribution config.env not found; key rotation skipped."
    }
    Start-ItlMcp
    Show-ItlMcpStatus
}

function Get-ItlMcpCurrentEndpoints {
    param([switch]$IncludeGlobal)

    $state = Read-ItlMcpState
    $context = Get-ItlMcpScopeContext
    $endpoints = @()
    foreach ($server in ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $state -Name "servers" -Default @())) {
        $url = [string](Get-ItlMcpObjectValue -Object $server -Name "url" -Default "")
        if (-not $url) {
            continue
        }
        $scope = [string](Get-ItlMcpObjectValue -Object $server -Name "scope" -Default "")
        if ($scope -eq "global") {
            if ($IncludeGlobal) {
                $endpoints += $server
            }
            continue
        }
        if ([string](Get-ItlMcpObjectValue -Object $server -Name "projectSlug" -Default "") -ne $context.projectSlug) {
            continue
        }
        if ($scope -eq "branch" -and [string](Get-ItlMcpObjectValue -Object $server -Name "branchSlug" -Default "") -ne $context.branchSlug) {
            continue
        }
        $endpoints += $server
    }
    return $endpoints
}

function ConvertTo-ItlMcpTomlString {
    param([string]$Value)
    return '"' + ($Value.Replace("\", "\\").Replace('"', '\"')) + '"'
}

function Set-ItlMcpManagedTextBlock {
    param(
        [string]$Path,
        [string]$BlockId,
        [string]$Body
    )

    $start = "# >>> itl-mcp $BlockId"
    $end = "# <<< itl-mcp $BlockId"
    $text = ""
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        $text = Read-Utf8Text -Path $Path
    }
    $pattern = "(?ms)^" + [regex]::Escape($start) + ".*?^" + [regex]::Escape($end) + "\r?\n?"
    $text = [regex]::Replace($text, $pattern, "")
    $block = $start + [Environment]::NewLine + $Body.TrimEnd() + [Environment]::NewLine + $end + [Environment]::NewLine
    if ($text -and -not $text.EndsWith([Environment]::NewLine)) {
        $text += [Environment]::NewLine
    }
    Write-Utf8Text -Path $Path -Value ($text + $block)
}

function Write-ItlMcpCodexConfig {
    param(
        [string]$Path,
        [string]$BlockId,
        [object[]]$Endpoints
    )

    $lines = New-Object System.Collections.ArrayList
    foreach ($endpoint in @($Endpoints | Sort-Object @{ Expression = { Get-ItlMcpObjectValue -Object $_ -Name "name" -Default "" } })) {
        $name = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "name" -Default "")
        $url = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "url" -Default "")
        if (-not $name -or -not $url) {
            continue
        }
        [void]$lines.Add("[mcp_servers.$(ConvertTo-ItlMcpTomlString $name)]")
        [void]$lines.Add("url = $(ConvertTo-ItlMcpTomlString $url)")
        [void]$lines.Add("enabled = true")
        [void]$lines.Add("startup_timeout_sec = 20")
        [void]$lines.Add("tool_timeout_sec = 120")
        [void]$lines.Add("")
    }

    Set-ItlMcpManagedTextBlock -Path $Path -BlockId $BlockId -Body ((@($lines) -join [Environment]::NewLine).TrimEnd())
}

function Write-ItlMcpKiloConfig {
    param([object[]]$Endpoints)

    $path = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        $current = Read-Utf8Text -Path $path | ConvertFrom-Json
        $config = ConvertTo-ItlMcpHashtable -Object $current
    }

    $mcp = [ordered]@{}
    if ($config.Contains("mcp")) {
        $mcp = ConvertTo-ItlMcpHashtable -Object $config["mcp"]
    }

    foreach ($key in @($mcp.Keys)) {
        $entry = $mcp[$key]
        $managedBy = [string](Get-ItlMcpObjectValue -Object $entry -Name "managedBy" -Default "")
        if ($managedBy -eq "itl-mcp") {
            $mcp.Remove($key)
        }
    }

    foreach ($endpoint in @($Endpoints | Sort-Object @{ Expression = { Get-ItlMcpObjectValue -Object $_ -Name "name" -Default "" } })) {
        $name = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "name" -Default "")
        $url = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "url" -Default "")
        if (-not $name -or -not $url) {
            continue
        }
        $mcp[$name] = [ordered]@{
            type = "remote"
            url = $url
            enabled = $true
            timeout = 15000
            managedBy = "itl-mcp"
            scope = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "scope" -Default "")
        }
    }

    $config["mcp"] = $mcp
    Write-ItlMcpJsonFile -Path $path -Value $config
}

function Write-ItlMcpClientConfig {
    Write-Section "Write ITL MCP client config"

    Ensure-GitIgnore
    $globalEndpoints = @(Get-ItlMcpCurrentEndpoints -IncludeGlobal | Where-Object { [string](Get-ItlMcpObjectValue -Object $_ -Name "scope" -Default "") -eq "global" })
    $localEndpoints = @(Get-ItlMcpCurrentEndpoints | Where-Object { [string](Get-ItlMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })
    $allCurrentEndpoints = @($globalEndpoints + $localEndpoints)

    $home = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($home)) {
        $home = $HOME
    }
    $codexHomeConfig = Join-Path $home ".codex\config.toml"
    $codexProjectConfig = Join-Path $script:ProjectRoot ".codex\config.toml"

    Write-ItlMcpCodexConfig -Path $codexHomeConfig -BlockId "global" -Endpoints $globalEndpoints
    Write-ItlMcpCodexConfig -Path $codexProjectConfig -BlockId "project" -Endpoints $localEndpoints
    Write-ItlMcpKiloConfig -Endpoints $allCurrentEndpoints

    Write-Host "Codex global MCP config: $codexHomeConfig"
    Write-Host "Codex project MCP config: $codexProjectConfig"
    Write-Host "Kilo project MCP config: $(Join-Path $script:ProjectRoot '.kilo\kilo.json')"
}

function Show-ItlMcpStatus {
    Write-Section "ITL MCP status"

    $state = Read-ItlMcpState
    $context = Get-ItlMcpScopeContext
    Write-Host "MCP local home: $(Get-ItlMcpLocalHome)"
    Write-Host "MCP distribution: $(Get-ItlMcpDistributionRoot)"
    Write-Host "Project scope: $($context.projectSlug)"
    Write-Host "Branch scope: $($context.branchSlug)"

    $model = Get-ItlMcpObjectValue -Object $state -Name "model" -Default $null
    if ($model) {
        Write-Host "Embedding model: $(Get-ItlMcpObjectValue -Object $model -Name 'modelId' -Default '<unknown>')"
        Write-Host "Embedding API: $(Get-ItlMcpObjectValue -Object $model -Name 'apiBase' -Default '<not set>')"
        Write-Host "Embedding ready: $(Get-ItlMcpObjectValue -Object $model -Name 'ready' -Default $false)"
    } else {
        Write-Host "Embedding model: not configured"
    }

    $stale = @(ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $state -Name "staleIndexes" -Default @()))
    if ($stale.Count -gt 0) {
        Write-Host "Stale indexes: $($stale -join ', ')"
        Write-Host "Reindex only after explicit RESET_DATABASE=true."
    } else {
        Write-Host "Stale indexes: none"
    }

    $endpoints = @(Get-ItlMcpCurrentEndpoints -IncludeGlobal)
    if ($endpoints.Count -eq 0) {
        Write-Host "Active MCP names: none"
        Write-Host "Start with: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-start"
        return
    }

    Write-Host "Active MCP names:"
    foreach ($endpoint in ($endpoints | Sort-Object @{ Expression = { Get-ItlMcpObjectValue -Object $_ -Name "scope" -Default "" } }, @{ Expression = { Get-ItlMcpObjectValue -Object $_ -Name "name" -Default "" } })) {
        $name = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "name" -Default "")
        $url = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "url" -Default "")
        $port = ConvertTo-IntOrDefault -Value (Get-ItlMcpObjectValue -Object $endpoint -Name "hostPort" -Default 0)
        $live = $(if ($port -gt 0) { Test-TcpPortOpen -Port $port -TimeoutMilliseconds 200 } else { $false })
        $scope = [string](Get-ItlMcpObjectValue -Object $endpoint -Name "scope" -Default "")
        Write-Host "  $name [$scope] $url live=$live"
    }
    Write-Host "Restart: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-start"
}

function Write-ItlMcpStatusLines {
    param([string]$Indent = "")

    $state = Read-ItlMcpState
    $model = Get-ItlMcpObjectValue -Object $state -Name "model" -Default $null
    if ($model) {
        Write-Host "${Indent}ITL MCP embeddings: $(Get-ItlMcpObjectValue -Object $model -Name 'modelId' -Default '<unknown>') ready=$(Get-ItlMcpObjectValue -Object $model -Name 'ready' -Default $false)"
    } else {
        Write-Host "${Indent}ITL MCP embeddings: not configured"
    }

    $endpoints = @(Get-ItlMcpCurrentEndpoints -IncludeGlobal)
    if ($endpoints.Count -eq 0) {
        Write-Host "${Indent}ITL MCP active servers: none"
        return
    }

    $names = @($endpoints | ForEach-Object { [string](Get-ItlMcpObjectValue -Object $_ -Name "name" -Default "") } | Where-Object { $_ })
    Write-Host "${Indent}ITL MCP active servers: $($names -join ', ')"
    $stale = @(ConvertTo-ItlMcpArray (Get-ItlMcpObjectValue -Object $state -Name "staleIndexes" -Default @()))
    if ($stale.Count -gt 0) {
        Write-Host "${Indent}ITL MCP stale indexes: $($stale -join ', ')"
    }
}

function New-RepositoryConnectionArgs {
    $repositoryUser = Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER")
    $repositoryPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-EnvValue -Name "REPOSITORY_PASSWORD" -Default ""))
    $repositoryPath = Get-RepositoryPath

    return @(
        "/ConfigurationRepositoryF", $repositoryPath,
        "/ConfigurationRepositoryN", $repositoryUser,
        "/ConfigurationRepositoryP", (ConvertTo-NativeEmptyStringArgument $repositoryPassword)
    )
}

function Update-BaseFromRepository {
    if (-not (Get-SourceUsesRepository)) {
        Write-Host "WARNING: no repository update was performed; master dump uses current source infobase state."
        Write-Host "Source infobase is configured without repository connection. Update it manually before sync-master or refresh-dev-branch when fresh external changes are needed."
        return $false
    }

    $repositoryArgs = (New-RepositoryConnectionArgs) + @(
        "/ConfigurationRepositoryUpdateCfg", "-force",
        "/UpdateDBCfg"
    )

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs $repositoryArgs | Out-Null

    return $true
}

function Assert-ExportPathInsideProject {
    param([string]$ExportPath)
    $resolved = Resolve-ProjectPath $ExportPath
    $root = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\")
    if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Export path must be inside project root: $resolved"
    }
    return $resolved
}

function Get-StateValue {
    param(
        [object]$State,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $State) {
        return $Default
    }

    $prop = $State.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return $Default
    }

    return $prop.Value
}

function Get-DevBranchKind {
    param([object]$State)
    return (Get-StateValue -State $State -Name "devBranchKind" -Default "configuration")
}

function Assert-DevBranchKind {
    param(
        [object]$State,
        [ValidateSet("configuration", "extension")]
        [string]$Expected
    )

    $actual = Get-DevBranchKind -State $State
    if ($actual -ne $Expected) {
        throw "This action requires a '$Expected' development branch, but current branch state is '$actual'."
    }
}

function Get-ExtensionExportPath {
    param([string]$SafeExtensionName)

    $safe = Require-Value "safeExtensionName" $SafeExtensionName
    $basePath = (Get-ExtensionsPath).TrimEnd("\", "/")
    return (($basePath + "/" + $safe) -replace "\\", "/")
}

function Require-DevBranchExtensionName {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    $name = Get-StateValue -State $State -Name "extensionName" -Default ""
    if (-not $name) {
        throw "Extension name is not set for this development branch. Run set-dev-branch-extension first."
    }
    return $name
}

function Get-DevBranchExtensionExportPath {
    param([object]$State)

    $extensionName = Require-DevBranchExtensionName -State $State
    $safeExtensionName = Get-StateValue -State $State -Name "safeExtensionName" -Default (ConvertTo-SafeName $extensionName)
    $path = Get-StateValue -State $State -Name "extensionExportPath" -Default ""
    if (-not $path) {
        $path = Get-ExtensionExportPath -SafeExtensionName $safeExtensionName
    }
    return $path
}

function Assert-ExtensionFilesReady {
    param([object]$State)

    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absolutePath = Assert-ExportPathInsideProject $extensionExportPath
    $dumpInfoPath = Join-Path $absolutePath "ConfigDumpInfo.xml"
    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "Extension files are not ready in '$extensionExportPath'. Create the extension in the development branch infobase, then run dump-dev-branch-extension."
    }
    return $extensionExportPath
}

function Get-DevBranchLoadBaseCommit {
    param(
        [object]$State,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $specificCommitField = if ($ContentKind -eq "extension") { "lastExtensionBaseUpdatedCommit" } else { "lastConfigBaseUpdatedCommit" }

    foreach ($candidate in @(
        (Get-StateValue -State $State -Name $specificCommitField),
        (Get-StateValue -State $State -Name "lastLoadedCommit"),
        (Get-StateValue -State $State -Name "createdFromCommit")
    )) {
        if (Test-GitCommitExists $candidate) {
            return $candidate
        }
    }

    $masterBranch = Get-MasterBranch
    $mergeBase = & git -C $script:ProjectRoot merge-base HEAD $masterBranch 2>$null
    if ($LASTEXITCODE -eq 0 -and $mergeBase) {
        return ([string]$mergeBase).Trim()
    }

    return Get-CurrentCommit
}

function ConvertTo-ConfigLoadRelativePath {
    param(
        [string]$RepoPath,
        [string]$ExportPath
    )

    $normalizedExportPath = ($ExportPath -replace "\\", "/").Trim("/")
    $normalizedRepoPath = $RepoPath -replace "\\", "/"
    if ($normalizedRepoPath -eq $normalizedExportPath) {
        return $null
    }

    $prefix = $normalizedExportPath + "/"
    if (-not $normalizedRepoPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $normalizedRepoPath.Substring($prefix.Length)
    if (-not $relative -or $relative -ieq "ConfigDumpInfo.xml") {
        return $null
    }

    return ($relative -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Get-ConfigLoadChangeSet {
    param(
        [object]$State,
        [string]$ExportPath = (Get-ExportPath),
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
    $baseCommit = Get-DevBranchLoadBaseCommit -State $State -ContentKind $ContentKind

    $tracked = & git -C $script:ProjectRoot diff --name-only --diff-filter=ACMRTUXBD $baseCommit -- $ExportPath
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot calculate changed config files from commit: $baseCommit"
    }

    $untracked = & git -C $script:ProjectRoot ls-files --others --exclude-standard -- $ExportPath
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot calculate untracked config files under $ExportPath"
    }

    $files = @()
    foreach ($path in @($tracked) + @($untracked)) {
        $relative = ConvertTo-ConfigLoadRelativePath -RepoPath $path -ExportPath $ExportPath
        if ($relative) {
            $files += $relative
        }
    }

    $files = @($files | Sort-Object -Unique)
    return [pscustomobject]@{
        files = $files
        baseCommit = $baseCommit
        currentCommit = Get-CurrentCommit
        absoluteExportPath = $absoluteExportPath
    }
}

function New-ConfigLoadListFile {
    param(
        [object]$State,
        [string[]]$Files
    )

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $safeDevBranchName = Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch"
    $listFilePath = New-TimestampedFilePath -Directory $logsPath -Prefix ("load-files-" + $safeDevBranchName + "-") -Extension ".txt"
    [System.IO.File]::WriteAllLines($listFilePath, [string[]]$Files, (Get-Utf8Encoding))
    return $listFilePath
}

function New-LoadStateUpdates {
    param(
        [object]$LoadResult,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $now = (Get-Date).ToString("o")
    if ($ContentKind -eq "extension") {
        $updates = @{
            lastExtensionBaseUpdatedCommit = $LoadResult.currentCommit
            lastExtensionBaseUpdateAt = $now
            lastExtensionBaseUpdateListFile = $LoadResult.listFile
        }
    } else {
        $updates = @{
            lastConfigBaseUpdatedCommit = $LoadResult.currentCommit
            lastConfigBaseUpdateAt = $now
            lastConfigBaseUpdateListFile = $LoadResult.listFile
        }
    }

    if ($LoadResult.lastLogPath) {
        $updates["lastLogPath"] = $LoadResult.lastLogPath
    }

    return $updates
}

function Dump-ConfigToFiles {
    $exportPath = Get-ExportPath
    $absoluteExportPath = Assert-ExportPathInsideProject $exportPath
    New-Item -ItemType Directory -Force -Path $absoluteExportPath | Out-Null

    $dumpInfoPath = Join-Path $absoluteExportPath "ConfigDumpInfo.xml"
    $children = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    $isIncremental = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
    $designerArgs = @()
    if (Get-SourceUsesRepository) {
        $designerArgs += New-RepositoryConnectionArgs
    }
    $designerArgs += @("/DumpConfigToFiles", $absoluteExportPath, "-Format", "Hierarchical")
    if ($isIncremental) {
        $designerArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Export path '$absoluteExportPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping config files."
    }

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs $designerArgs | Out-Null

    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "1C configuration dump did not create ConfigDumpInfo.xml in '$absoluteExportPath'. Check the 1C log: $script:LastLogPath"
    }

    $dumpedFiles = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    if ($dumpedFiles.Count -eq 0) {
        throw "1C configuration dump produced no files in '$absoluteExportPath'. Check the 1C log: $script:LastLogPath"
    }

    return [pscustomobject]@{
        exportPath = $exportPath
        absoluteExportPath = $absoluteExportPath
        incremental = $isIncremental
        logPath = $script:LastLogPath
    }
}

function Dump-ExtensionToFiles {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    $extensionName = Require-DevBranchExtensionName -State $State
    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absoluteExportPath = Assert-ExportPathInsideProject $extensionExportPath
    New-Item -ItemType Directory -Force -Path $absoluteExportPath | Out-Null

    $dumpInfoPath = Join-Path $absoluteExportPath "ConfigDumpInfo.xml"
    $children = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    $isIncremental = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
    $designerArgs = @("/DumpConfigToFiles", $absoluteExportPath, "-Extension", $extensionName, "-Format", "Hierarchical")
    if ($isIncremental) {
        $designerArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Extension export path '$absoluteExportPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping extension files."
    }

    Invoke-Designer `
        -InfoBasePath $state.devBranchInfoBasePath `
        -InfoBaseKind $state.infoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "1C extension dump did not create ConfigDumpInfo.xml in '$absoluteExportPath'. Make sure extension '$extensionName' exists in the development branch infobase. Check the 1C log: $script:LastLogPath"
    }

    return [pscustomobject]@{
        extensionName = $extensionName
        exportPath = $extensionExportPath
        absoluteExportPath = $absoluteExportPath
        incremental = $isIncremental
        logPath = $script:LastLogPath
    }
}

function Load-ConfigFromFiles {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [object]$State,
        [string]$ExportPath = (Get-ExportPath),
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration",
        [string]$ExtensionName = ""
    )

    $changeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $ExportPath -ContentKind $ContentKind
    if ($changeSet.files.Count -eq 0) {
        Write-Host "No changed config files under $ExportPath since $($changeSet.baseCommit)."
        Write-Host "Development branch infobase already matches current branch config files."
        return [pscustomobject]@{
            loaded = $false
            fileCount = 0
            listFile = ""
            currentCommit = $changeSet.currentCommit
            lastLogPath = $script:LastLogPath
        }
    }

    $listFilePath = New-ConfigLoadListFile -State $State -Files $changeSet.files
    Write-Host "Partial config load file count: $($changeSet.files.Count)"
    Write-Host "Partial config load list: $listFilePath"

    $designerArgs = @("/LoadConfigFromFiles", $changeSet.absoluteExportPath)
    if ($ExtensionName) {
        $designerArgs += @("-Extension", $ExtensionName)
    }
    $designerArgs += @("-listFile", $listFilePath, "-Format", "Hierarchical", "/UpdateDBCfg")

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    return [pscustomobject]@{
        loaded = $true
        fileCount = $changeSet.files.Count
        listFile = $listFilePath
        currentCommit = $changeSet.currentCommit
        lastLogPath = $script:LastLogPath
    }
}

function Export-DevBranchResultFile {
    param(
        [object]$State,
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $artifactDir = Resolve-ProjectPath (Get-ConfigValue -Path "artifactsPath" -Default "build/result")
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

    $safeDevBranchName = Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch"
    $extensionName = ""
    $extension = ".cf"
    $designerArgs = @()
    if ($ContentKind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $State
        $extension = ".cfe"
    }

    $resultPath = Join-Path $artifactDir ($safeDevBranchName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + $extension)
    $designerArgs += @("/DumpCfg", $resultPath)
    if ($extensionName) {
        $designerArgs += @("-Extension", $extensionName)
    }

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    return $resultPath
}

function Get-GitCommitOrEmpty {
    param([string]$Revision)

    if (-not $Revision) {
        return ""
    }

    $output = & git -C $script:ProjectRoot rev-parse --verify $Revision 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }

    return ([string]$output).Trim()
}

function New-ResultManifest {
    param(
        [object]$State,
        [string]$ResultPath,
        [ValidateSet("cf", "cfe")]
        [string]$ResultKind,
        [string]$Operation,
        [string]$MasterCommit = "",
        [string]$DevBranchCommit = "",
        [bool]$UnverifiedOverride = $false
    )

    $artifactPath = [System.IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Result artifact was not found for manifest creation: $artifactPath"
    }

    $artifact = Get-Item -LiteralPath $artifactPath
    $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    $verification = Get-VerificationState -State $State
    $manifestPath = "$artifactPath.manifest.json"

    $manifest = [ordered]@{
        schemaVersion = 1
        operation = $Operation
        createdAt = (Get-Date).ToString("o")
        artifact = [ordered]@{
            path = $artifactPath
            name = $artifact.Name
            kind = $ResultKind
            sha256 = $artifactHash
        }
        branch = [ordered]@{
            name = (Get-StateValue -State $State -Name "devBranchName" -Default "")
            safeName = (Get-StateValue -State $State -Name "safeDevBranchName" -Default "")
            gitBranch = (Get-StateValue -State $State -Name "devBranch" -Default "")
            kind = (Get-DevBranchKind -State $State)
            publicationUrl = (Get-StateValue -State $State -Name "publicationUrl" -Default "")
        }
        commits = [ordered]@{
            master = $MasterCommit
            development = $DevBranchCommit
        }
        verification = [ordered]@{
            status = $verification.effectiveStatus
            storedStatus = $verification.status
            freshPassed = [bool]$verification.isFreshPassed
            verifiedAt = $verification.verifiedAt
            verifiedCommit = $verification.verifiedCommit
            currentCommit = $verification.currentCommit
            reportPath = $verification.reportPath
            logPath = $verification.logPath
            reason = $verification.reason
        }
        latest1cLogPath = [string]$script:LastLogPath
        unverifiedOverride = [bool]$UnverifiedOverride
        manualImportNote = "Import this CF/CFE into the source infobase manually after backup and normal acceptance checks. The ITL helper does not load development branch changes into the source infobase."
    }

    Write-Utf8Text -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $manifestPath
}

function Install-AiRules1c {
    if ($SkipAiRules) {
        Write-Host "Skipping ai_rules_1c installation."
        return
    }

    $repo = Get-ConfigValue -Path "aiRules.repo" -Default "https://github.com/comol/ai_rules_1c.git"
    $tools = Get-ConfigValue -Path "aiRules.tools" -Default ""
    if (-not $tools) {
        $tools = Get-AgentTargets
    } elseif ($tools -is [string]) {
        $tools = @($tools.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $rulesDir = Join-Path $env:TEMP "ai_rules_1c"

    if (Test-Path -LiteralPath $rulesDir) {
        & git -C $rulesDir pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update ai_rules_1c in $rulesDir"
        }
    } else {
        & git clone $repo $rulesDir
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone ai_rules_1c from $repo"
        }
    }

    $installScript = Join-Path $rulesDir "install.ps1"
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "ai_rules_1c install.ps1 was not found: $installScript"
    }

    Push-Location $script:ProjectRoot
    try {
        $installArgs = @(
            "-Command", "init",
            "-ProjectRoot", $script:ProjectRoot,
            "-Source", $rulesDir,
            "-Tools"
        ) + @($tools) + @("-AssumeYes")
        & $installScript @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "ai_rules_1c installer failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Update-UserRules {
    $path = Join-Path $script:ProjectRoot "USER-RULES.md"
    $marker = "## 1C Project Lifecycle"
    $block = @"

$marker

Use `.agents/skills/1c-workflow/SKILL.md` for detailed project initialization, development branch creation, development branch refresh, development branch base update, Vanessa Automation test runs, master sync, development branch listing, branch switching, development branch close, and CF/CFE result export.

For routine lifecycle operations in an already installed project, prefer the short Kilo `/itl-*` commands or `.agents/skills/1c-workflow-fast/SKILL.md`. The fast path runs `.agents/skills/1c-workflow/scripts/agent-1c.ps1` directly and should read detailed workflow references only after helper failure or when the developer asks for explanation.

Use `DEV-BRANCH-DEVELOPMENT.ru.md` for the development process inside a development branch: quick-fix for small local fixes, OpenSpec for business feature work or risky behavior changes.

When asking the developer for missing setup values, ask one value at a time and accept the raw value only. Do not ask for `KEY=value` blocks, one large free-form block with all missing variables, or variable names.

For optional passwords, ask whether the password is set before asking for the value. If the password is not set, store an empty value and do not treat placeholder text as the password.

Before asking for the 1C platform path, search existing standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders and offer installed versions as choices. Missing standard folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version.

Keep `AGENTS.md` as a short bridge to `USER-RULES.md` and workflow skills. Store detailed project workflow notes in `USER-RULES.md`. Store secrets only in local `.dev.env`.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8 so Cyrillic usernames and paths are preserved.

Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local runtime state. They are ignored by Git because they contain local paths, worktree paths, 1C launcher metadata, verification status, result paths, event-log baseline signatures, and unverified override history.

Create new development branches in sibling Git worktrees by default, under `<project-folder>-worktrees/<branch>`, and leave the main project folder on `master`. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Use `.agent-1c/infobases/dev-branches` inside the active branch worktree as the default development branch infobase copy root and keep `.agent-1c/infobases/` ignored by Git.

Development branch changes must be loaded only into the development branch infobase copy, never directly into the source infobase connected to 1C configuration repository storage.

Before running ai_rules_1c IB-bound commands such as `/update1cbase`, `/loadfrom1cbase`, or `/getconfigfiles` inside an `itldev/*` branch, ensure the current development branch context is active. The ITL helper does this automatically during branch lifecycle commands.

Do not use `/deploy-and-test` as the normal verification command in an ITL development branch because it reloads all files. The normal executable verification cycle is `/itl-verify`. Use `/itl-update-base` only when you need to update the branch infobase without tests.

Use Vanessa Automation scenarios from `tests/features` for OpenSpec and quick-fix verification. `/itl-verify` runs Vanessa through packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` flow with a branch-local `VANESSA_TEST_PORT`; do not replace the final gate with MCP or a headless EPF launch. The same gate also checks the branch-local file infobase event log against the branch baseline and fails on fresh non-baseline `Error` signatures. `VANESSA_TEST_TIMEOUT_SECONDS` limits the full test run; on timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes. Vanessa MCP is only for authoring, form inspection, step search, recording, and point debugging in the current branch. For behavior changes, create or update a small Vanessa Automation check set: at least 2 checks, usually 2-3, and no more than 4 unless explicitly justified. Include the main successful scenario and at least one meaningful boundary or negative scenario. Choose the check type by change kind: unit-like for local logic, integration for object/register/document/exchange interaction, and UI only for forms, commands, or visible user behavior. For large OpenSpec changes, test each meaningful implementation slice separately. If Vanessa finds an error, analyze the JUnit/report/status/log/event-log report and active 1C process diagnostics, fix the cause, update the branch base again, and rerun the relevant scenario. Never kill another worktree's `TESTMANAGER` or `TESTCLIENT`; stop only the current branch's own hung test manager/client.

For `/itl-result` and `/itl-close`, create `<artifact>.manifest.json` next to the exported CF/CFE. The manifest records artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

Record current industrial compromises without enforcing them: ideal result/close gating would require fresh passed Vanessa, review, and test report, but the current workflow only warns and requires explicit unverified confirmation; ideal dependency management would use a lock file for `ai_rules_1c`, Vanessa Automation, and SHA256 hashes, but the current workflow uses latest versions and logs archive SHA256 where downloads happen; parallel independent development lines should use separate `itldev/*` branches/worktrees, while one development branch may remain long-lived and contain several sequential tasks.

When Git is on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase. For worktree-created branches, `/itl-switch` shows the target worktree path instead of checking it out over the current folder. The ITL workflow clears active development branch infobase values when switching to `master` or closing a worktree branch.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`. Join and quote arguments into one native command-line string first, or use the `&` call operator for simple cases. Paths with spaces must remain one native argument; otherwise 1C Designer may exit with code 1 or hang behind `-WindowStyle Hidden`.
"@

    if (Test-Path -LiteralPath $path) {
        $current = Read-Utf8Text -Path $path
        if ($current.Contains($marker)) {
            return
        }
        Add-Utf8Text -Path $path -Value ($block + [Environment]::NewLine)
    } else {
        Write-Utf8Text -Path $path -Value $block.TrimStart()
    }
}

function Update-AgentGuidanceBridge {
    $path = Join-Path $script:ProjectRoot "AGENTS.md"
    $marker = "## 1C Agent Workflow Bridge"
    $block = @"

$marker

Read `USER-RULES.md` for project-specific workflow notes.

For routine ITL lifecycle operations, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or the short Kilo `/itl-*` wrappers.

Use `.agents/skills/1c-workflow/SKILL.md` for initialization, unusual recovery, or detailed workflow work.

Keep `.dev.env`, `.agent-1c/dev-branches/*.json`, `.agent-1c/event-log-baselines/*.json`, downloaded tools, logs, local infobases, and result artifacts out of Git.
"@

    if (Test-Path -LiteralPath $path) {
        $current = Read-Utf8Text -Path $path
        if ($current.Contains($marker)) {
            return
        }
        Add-Utf8Text -Path $path -Value ($block + [Environment]::NewLine)
    } else {
        Write-Utf8Text -Path $path -Value $block.TrimStart()
    }
}

function Save-DevBranchState {
    param(
        [string]$SafeDevBranchName,
        [hashtable]$State,
        [string]$ProjectRootOverride = $script:ProjectRoot
    )

    $devBranchesDir = Join-Path $ProjectRootOverride ".agent-1c\dev-branches"
    New-Item -ItemType Directory -Force -Path $devBranchesDir | Out-Null
    $path = Join-Path $devBranchesDir ($SafeDevBranchName + ".json")
    Write-Utf8Text -Path $path -Value (($State | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $path
}

function Update-DevBranchState {
    param(
        [object]$State,
        [hashtable]$Updates
    )

    $stateHash = @{}
    foreach ($prop in $State.PSObject.Properties) {
        if (@("statePath", "stateProjectRoot") -contains $prop.Name) {
            continue
        }
        $stateHash[$prop.Name] = $prop.Value
    }
    foreach ($key in $Updates.Keys) {
        $stateHash[$key] = $Updates[$key]
    }

    $safeName = $stateHash["safeDevBranchName"]
    if (-not $safeName) {
        $safeName = ConvertTo-SafeName $stateHash["devBranchName"]
        $stateHash["safeDevBranchName"] = $safeName
    }
    $stateProjectRoot = Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot
    Save-DevBranchState -SafeDevBranchName $safeName -State $stateHash -ProjectRootOverride $stateProjectRoot | Out-Null
}

function Get-DevBranchStateProjectRootFromPath {
    param([string]$Path)

    $devBranchesDir = Split-Path -Parent $Path
    $agentDir = Split-Path -Parent $devBranchesDir
    return [System.IO.Path]::GetFullPath((Split-Path -Parent $agentDir))
}

function Read-DevBranchStateFile {
    param([string]$Path)

    $state = Read-Utf8Text -Path $Path | ConvertFrom-Json
    $stateProjectRoot = Get-DevBranchStateProjectRootFromPath -Path $Path
    $state | Add-Member -NotePropertyName statePath -NotePropertyValue $Path -Force
    $state | Add-Member -NotePropertyName stateProjectRoot -NotePropertyValue $stateProjectRoot -Force
    return $state
}

function Get-DevBranchStateFiles {
    $files = @()
    $roots = @($script:ProjectRoot)
    foreach ($worktree in Get-GitWorktrees) {
        if ($worktree.path) {
            $roots += [System.IO.Path]::GetFullPath($worktree.path)
        }
    }

    foreach ($root in @($roots | Sort-Object -Unique)) {
        $devBranchesDir = Join-Path $root ".agent-1c\dev-branches"
        if (Test-Path -LiteralPath $devBranchesDir -PathType Container -ErrorAction SilentlyContinue) {
            $files += @(Get-ChildItem -LiteralPath $devBranchesDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        }
    }

    return @($files | Sort-Object FullName -Unique)
}

function Find-DevBranchStateFile {
    param([string]$SafeDevBranchName)

    $fileName = $SafeDevBranchName + ".json"
    foreach ($file in Get-DevBranchStateFiles) {
        if ($file.Name -eq $fileName) {
            return $file.FullName
        }
    }
    return ""
}

function Read-DevBranchState {
    param([string]$Name)

    if (-not $Name) {
        $currentBranch = (Get-GitOutput @("branch", "--show-current")).Trim()
        if ($currentBranch -like "itldev/*") {
            $Name = $currentBranch.Substring("itldev/".Length)
        }
    }

    if (-not $Name) {
        throw "Run this from a development branch or pass -DevBranchName."
    }

    $safe = ConvertTo-SafeName $Name
    $path = Join-Path $script:ProjectRoot ".agent-1c\dev-branches\$safe.json"
    if (-not (Test-Path -LiteralPath $path)) {
        $path = Find-DevBranchStateFile -SafeDevBranchName $safe
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Development branch state not found for '$Name'."
    }
    return Read-DevBranchStateFile -Path $path
}

function Test-DevBranchStateUsesWorktree {
    param([object]$State)

    return (ConvertTo-BoolSetting -Value (Get-StateValue -State $State -Name "createdWithWorktree" -Default $false) -Default $false)
}

function Assert-CurrentProjectRootMatchesDevBranchState {
    param(
        [object]$State,
        [string]$Operation
    )

    if (-not (Test-DevBranchStateUsesWorktree -State $State)) {
        return
    }

    $worktreePath = Get-StateValue -State $State -Name "worktreePath" -Default ""
    if (-not $worktreePath) {
        return
    }

    if ((Get-FullPathNormalized $script:ProjectRoot) -ne (Get-FullPathNormalized $worktreePath)) {
        throw "$Operation must be run from the development branch worktree: $worktreePath. Open a separate agent window in that folder."
    }
}

function Copy-DotEnvToWorktree {
    param([string]$WorktreePath)

    $sourceDotEnv = Join-Path $script:ProjectRoot ".dev.env"
    if (Test-Path -LiteralPath $sourceDotEnv -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $sourceDotEnv -Destination (Join-Path $WorktreePath ".dev.env") -Force
    }
}

function Open-AgentWorktreeBestEffort {
    param([string]$WorktreePath)

    if (-not $OfferOpenAgent) {
        return
    }

    $codeCommand = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codeCommand) {
        & $codeCommand.Source -n $WorktreePath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Открыто новое окно VS Code/Kilo для рабочей папки: $WorktreePath"
            return
        }
        Write-Host "Не удалось автоматически открыть VS Code/Kilo через команду code."
    } else {
        Write-Host "Команда code не найдена. Откройте рабочую папку вручную."
    }
}

function Write-DevBranchWorktreeOpenMessage {
    param(
        [string]$MainProjectPath,
        [string]$WorktreePath
    )

    Write-Host ""
    Write-Host "Ветка разработки создана."
    Write-Host ""
    Write-Host "Текущая папка осталась на master:"
    Write-Host $MainProjectPath
    Write-Host ""
    Write-Host "Рабочая папка новой ветки:"
    Write-Host $WorktreePath
    Write-Host ""
    Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно Codex/Kilo/IDE в этой папке."
    Write-Host "Могу попробовать открыть новое окно агента для этой папки автоматически."
}

function Clear-DevBranchContext {
    Set-DotEnvValues -Values @{
        INFOBASE_PATH = ""
        INFOBASE_PUBLISH_URL = ""
        EXTENSION_NAME = ""
        EXPORT_PATH = ""
        ITL_ACTIVE_DEV_BRANCH = ""
        ITL_ACTIVE_DEV_BRANCH_KIND = ""
        ITL_ACTIVE_CONTEXT_UPDATED_AT = (Get-Date).ToString("o")
        VANESSA_TEST_PORT = ""
        VANESSA_MCP_PORT = ""
        VANESSA_MCP_URL = ""
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Development branch context cleared in .dev.env."
}

function Sync-DevBranchContextToDotEnv {
    param(
        [object]$State,
        [switch]$AllowIncompleteExtension
    )

    $kind = Get-DevBranchKind -State $State
    $values = @{
        INFOBASE_KIND = (Get-StateValue -State $State -Name "infoBaseKind" -Default (Get-InfoBaseKind))
        INFOBASE_PATH = (Require-Value "devBranchInfoBasePath" (Get-StateValue -State $State -Name "devBranchInfoBasePath"))
        INFOBASE_PUBLISH_URL = (Get-StateValue -State $State -Name "publicationUrl" -Default "")
        EXPORT_PATH = (Get-ExportPath)
        EXTENSION_NAME = ""
        ITL_ACTIVE_DEV_BRANCH = (Get-StateValue -State $State -Name "devBranch" -Default "")
        ITL_ACTIVE_DEV_BRANCH_KIND = $kind
        ITL_ACTIVE_CONTEXT_UPDATED_AT = (Get-Date).ToString("o")
        VANESSA_TEST_PORT = (Get-StateValue -State $State -Name "vanessaTestPort" -Default "")
        VANESSA_MCP_PORT = (Get-StateValue -State $State -Name "vanessaMcpPort" -Default "")
        VANESSA_MCP_URL = (Get-StateValue -State $State -Name "vanessaMcpUrl" -Default "")
    }

    if ($kind -eq "extension") {
        $extensionName = Get-StateValue -State $State -Name "extensionName" -Default ""
        if (-not $extensionName) {
            if ($AllowIncompleteExtension) {
                $values["INFOBASE_PATH"] = ""
                $values["INFOBASE_PUBLISH_URL"] = ""
                $values["EXPORT_PATH"] = ""
                $values["EXTENSION_NAME"] = ""
                Set-DotEnvValues -Values $values
                Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
                Write-Host "Development branch context is incomplete: extension name is not set. Run set-dev-branch-extension before using /update1cbase."
                return
            }
            Require-DevBranchExtensionName -State $State | Out-Null
        }
        $values["EXTENSION_NAME"] = $extensionName
        $values["EXPORT_PATH"] = Get-DevBranchExtensionExportPath -State $State
    }

    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Development branch context activated in .dev.env."
    Write-Host "Branch: $($values["ITL_ACTIVE_DEV_BRANCH"])"
    Write-Host "Infobase: $($values["INFOBASE_PATH"])"
    Write-Host "Export path: $($values["EXPORT_PATH"])"
    if ($values["EXTENSION_NAME"]) {
        Write-Host "Extension: $($values["EXTENSION_NAME"])"
    }
}

function Activate-DevBranchContext {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "activate-dev-branch-context"
    Sync-DevBranchContextToDotEnv -State $state
}

function ConvertTo-LauncherLabel {
    param([AllowNull()][string]$Value)

    $text = [string]$Value
    $text = ($text -replace "[\r\n\[\]]", " ").Trim()
    $text = ($text -replace "\s+", " ")
    if (-not $text) {
        return "project"
    }
    return $text
}

function Get-LauncherListPath {
    $appData = [Environment]::GetFolderPath("ApplicationData")
    if (-not $appData) {
        $appData = $env:APPDATA
    }
    if (-not $appData) {
        throw "APPDATA path is not available; cannot update 1C infobase list."
    }

    return (Join-Path $appData "1C\1CEStart\ibases.v8i")
}

function Get-LauncherProjectFolder {
    $projectName = Split-Path -Leaf $script:ProjectRoot
    return "/ITL/" + (ConvertTo-LauncherLabel -Value $projectName)
}

function New-LauncherConnectString {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath
    )

    if ($InfoBaseKind -eq "file") {
        $resolved = Resolve-InfoBasePath $InfoBasePath
        return "File=`"$resolved`";"
    }
    if ($InfoBaseKind -eq "server") {
        return (Require-Value "development branch server infobase connection string" $InfoBasePath)
    }

    throw "Unknown infobase kind: $InfoBaseKind"
}

function Get-LauncherSections {
    param([string[]]$Lines)

    $sections = New-Object System.Collections.ArrayList
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\[(.*)\]\s*$') {
            if ($null -ne $current) {
                $current["end"] = $i - 1
                [void]$sections.Add([pscustomobject]$current)
            }
            $current = @{
                name = $matches[1]
                start = $i
                end = $i
                values = @{}
            }
            continue
        }

        if ($null -ne $current -and $line -match '^([^=]+)=(.*)$') {
            $current["values"][$matches[1]] = $matches[2]
        }
    }

    if ($null -ne $current) {
        $current["end"] = $Lines.Count - 1
        [void]$sections.Add([pscustomobject]$current)
    }

    return @($sections)
}

function Get-LauncherMaxIntValue {
    param(
        [object[]]$Sections,
        [string]$Key
    )

    $max = 0
    foreach ($section in $Sections) {
        if (-not $section.values.ContainsKey($Key)) {
            continue
        }
        $value = 0
        if ([int]::TryParse([string]$section.values[$Key], [ref]$value) -and $value -gt $max) {
            $max = $value
        }
    }
    return $max
}

function Register-DevBranchInLauncher {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$DevBranchName,
        [string]$ExistingLauncherId = ""
    )

    $listPath = Get-LauncherListPath
    $listDir = Split-Path -Parent $listPath
    New-Item -ItemType Directory -Force -Path $listDir | Out-Null

    $lines = @()
    if (Test-Path -LiteralPath $listPath -PathType Leaf) {
        $lines = @(Read-Utf8Lines -Path $listPath)
    }

    $sections = @(Get-LauncherSections -Lines $lines)
    $projectName = ConvertTo-LauncherLabel -Value (Split-Path -Leaf $script:ProjectRoot)
    $displayName = "ITL $projectName - $(ConvertTo-LauncherLabel -Value $DevBranchName)"
    $folder = Get-LauncherProjectFolder
    $connect = New-LauncherConnectString -InfoBaseKind $InfoBaseKind -InfoBasePath $InfoBasePath

    $target = $null
    foreach ($section in $sections) {
        if ($ExistingLauncherId -and $section.values.ContainsKey("ID") -and $section.values["ID"] -eq $ExistingLauncherId) {
            $target = $section
            break
        }
    }
    if ($null -eq $target) {
        foreach ($section in $sections) {
            if ($section.values.ContainsKey("Connect") -and $section.values["Connect"] -eq $connect) {
                $target = $section
                break
            }
        }
    }
    if ($null -eq $target) {
        foreach ($section in $sections) {
            if ($section.name -eq $displayName) {
                $target = $section
                break
            }
        }
    }

    $id = if ($target -and $target.values.ContainsKey("ID") -and $target.values["ID"]) { $target.values["ID"] } else { [guid]::NewGuid().ToString() }
    $orderInList = if ($target -and $target.values.ContainsKey("OrderInList")) { $target.values["OrderInList"] } else { [string]((Get-LauncherMaxIntValue -Sections $sections -Key "OrderInList") + 16384) }
    $orderInTree = if ($target -and $target.values.ContainsKey("OrderInTree")) { $target.values["OrderInTree"] } else { [string]((Get-LauncherMaxIntValue -Sections $sections -Key "OrderInTree") + 256) }

    $entry = @(
        "[$displayName]",
        "Connect=$connect",
        "ID=$id",
        "OrderInList=$orderInList",
        "Folder=$folder",
        "OrderInTree=$orderInTree",
        "External=0",
        "ClientConnectionSpeed=Normal",
        "App=Auto",
        "WA=1",
        "Version=8.3"
    )

    $result = New-Object System.Collections.ArrayList
    if ($target) {
        for ($i = 0; $i -lt $target.start; $i++) {
            [void]$result.Add($lines[$i])
        }
        foreach ($line in $entry) {
            [void]$result.Add($line)
        }
        for ($i = $target.end + 1; $i -lt $lines.Count; $i++) {
            [void]$result.Add($lines[$i])
        }
    } else {
        foreach ($line in $lines) {
            [void]$result.Add($line)
        }
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$result[$result.Count - 1])) {
            [void]$result.Add("")
        }
        foreach ($line in $entry) {
            [void]$result.Add($line)
        }
    }

    if (Test-Path -LiteralPath $listPath -PathType Leaf) {
        $backupPath = "$listPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $listPath -Destination $backupPath -Force
    }

    [System.IO.File]::WriteAllLines($listPath, [string[]]$result.ToArray([string]), (Get-Utf8BomEncoding))
    Write-Host "Registered development branch infobase in 1C launcher list: $displayName"
    Write-Host "Launcher folder: $folder"

    return [pscustomobject]@{
        registered = $true
        name = $displayName
        folder = $folder
        id = $id
        listPath = $listPath
        connect = $connect
    }
}

function Publish-DevBranchToApache {
    param(
        [string]$DevBranchPath,
        [string]$SafeDevBranchName
    )

    $apacheSettings = Get-EffectiveApacheSettings
    $webInstPath = $apacheSettings.webInstPath
    $apacheKind = $apacheSettings.apacheKind
    $publicationRoot = $apacheSettings.publicationRoot
    $urlBase = $apacheSettings.publicationUrlBase
    $confPath = $apacheSettings.httpdConfPath

    Require-Value "WEBINST_PATH, web.webInstPath, or webinst.exe next to PLATFORM_PATH" $webInstPath | Out-Null
    Require-Value "Apache publication root from autodetect or WEB_PUBLICATION_ROOT override" $publicationRoot | Out-Null

    if (-not (Test-Path -LiteralPath $webInstPath)) {
        throw "webinst.exe was not found: $webInstPath"
    }
    if (-not ($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) {
        throw "Apache was not detected. Run detect-apache, install/configure Apache, or set APACHE_HTTPD_CONF_PATH for a nonstandard installation."
    }

    $publicationName = $SafeDevBranchName -replace "[^a-zA-Z0-9_]", "_"
    $publicationDir = Join-Path $publicationRoot $publicationName
    New-Item -ItemType Directory -Force -Path $publicationDir | Out-Null

    $kind = Get-InfoBaseKind
    if ($kind -eq "file") {
        $connStr = "File=`"$DevBranchPath`";"
    } else {
        $connStr = $DevBranchPath
    }

    $args = @("-publish", "-$apacheKind", "-wsdir", $publicationName, "-dir", $publicationDir, "-connstr", $connStr)
    if ($confPath -and (Test-Path -LiteralPath $confPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $args += @("-confpath", $confPath)
    }

    & $webInstPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "webinst failed with exit code $LASTEXITCODE"
    }

    return ($urlBase.TrimEnd("/") + "/" + $publicationName)
}

function Initialize-Project {
    Write-Section "Initialize project"
    New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
    Write-Host "Project root: $script:ProjectRoot"
    if ($InitMode -eq "wizard" -and [string]::IsNullOrWhiteSpace($RunStatusPath)) {
        Write-Host "WARNING: direct init-project wizard is not monitored. Agent-run initialization must use scripts/run-agent-1c-window.ps1 so the agent waits for completion and reads status.json. Use the direct wizard only for manual debugging."
    }
    if ($InitMode -eq "wizard" -or $InitMode -eq "json") {
        Prepare-InitProjectSettings
    } else {
        Ensure-WorkflowProjectFiles
        Read-ProjectConfig
    }
    Check-Tools -StopOnMissing
    Get-DevBranchInfoBaseRoot | Out-Null
    Ensure-GitRepository
    Ensure-GitIgnore
    Checkout-Master

    $sourceUsesRepository = Get-SourceUsesRepository
    Update-BaseFromRepository
    $dumpResult = Dump-ConfigToFiles
    $dumpMessage = if ($sourceUsesRepository) { "sync: export 1C configuration from repository" } else { "sync: export 1C configuration from source infobase" }
    Commit-IfChanged -Message $dumpMessage -PathSpec @($dumpResult.exportPath) -RequireChanges -ForceAdd | Out-Null
    Assert-BaselineDumpCommitted -ExportPath $dumpResult.exportPath

    Install-AiRules1c
    Update-AgentGuidanceBridge
    Update-UserRules
    Commit-IfChanged "chore: install 1C agent workflow"
}

function Sync-Master {
    param([switch]$NoDelegate)

    Write-Section "Sync master"
    if (-not $NoDelegate) {
        $currentBranch = ""
        try {
            $currentBranch = Get-CurrentBranch
        } catch {
            $currentBranch = ""
        }
        if ($currentBranch -like "itldev/*") {
            $state = Read-DevBranchState -Name ""
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
            if ($mainWorktreePath -and ((Get-FullPathNormalized $mainWorktreePath) -ne (Get-FullPathNormalized $script:ProjectRoot))) {
                Write-Host "Syncing master in main worktree: $mainWorktreePath"
                Invoke-InProjectContext -Root $mainWorktreePath -ScriptBlock {
                    Sync-Master -NoDelegate
                }
                return
            }
        }
    }

    Assert-CleanGit
    Checkout-Master
    Clear-DevBranchContext
    $sourceUsesRepository = Get-SourceUsesRepository
    Update-BaseFromRepository
    $dumpResult = Dump-ConfigToFiles
    $dumpMessage = if ($sourceUsesRepository) { "sync: refresh 1C configuration from repository" } else { "sync: refresh 1C configuration from source infobase" }
    Commit-IfChanged -Message $dumpMessage -PathSpec @($dumpResult.exportPath) -ForceAdd | Out-Null
}

function Initialize-DevBranchRuntime {
    param(
        [ValidateSet("configuration", "extension")]
        [string]$DevBranchKind = "configuration",
        [string]$SafeDevBranchName,
        [string]$GitBranch,
        [string]$MainProjectRoot,
        [string]$WorktreePath,
        [bool]$CreatedWithWorktree = $false
    )

    $kind = Get-InfoBaseKind
    $sourceUsesRepository = Get-SourceUsesRepository
    $source = Get-SourceInfoBasePath
    if (-not $DevBranchInfoBasePath) {
        $rootPath = Resolve-ProjectPath (Get-DevBranchInfoBaseRoot)
        $DevBranchInfoBasePath = Join-Path $rootPath $SafeDevBranchName
    }

    if ($kind -eq "file") {
        if (Test-Path -LiteralPath $DevBranchInfoBasePath) {
            throw "Development branch infobase path already exists: $DevBranchInfoBasePath"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DevBranchInfoBasePath) | Out-Null
        Copy-Item -LiteralPath $source -Destination $DevBranchInfoBasePath -Recurse
    } else {
        $copyScript = Get-ConfigValue -Path "serverBaseCopyScript" -Default ""
        if (-not $copyScript) {
            throw "serverBaseCopyScript is required for server infobase copies."
        }
        $copyScriptPath = Resolve-ProjectPath $copyScript
        & powershell -ExecutionPolicy Bypass -File $copyScriptPath `
            -ProjectRoot $script:ProjectRoot `
            -DevBranchName $DevBranchName `
            -SourceInfoBasePath $source `
            -DevBranchInfoBasePath $DevBranchInfoBasePath
        if ($LASTEXITCODE -ne 0) {
            throw "Server infobase copy script failed with exit code $LASTEXITCODE"
        }
    }

    $repositoryUnbound = $false
    if ($sourceUsesRepository) {
        Invoke-Designer `
            -InfoBasePath $DevBranchInfoBasePath `
            -InfoBaseKind $kind `
            -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
        $repositoryUnbound = $true
    } else {
        Write-Host "Source infobase is configured without repository connection. Skipping repository unbind for development branch copy."
    }

    $launcherRegistration = Register-DevBranchInLauncher `
        -InfoBaseKind $kind `
        -InfoBasePath $DevBranchInfoBasePath `
        -DevBranchName $DevBranchName

    $publishDefault = Get-WebPublishByDefault
    $publicationUrl = ""
    if ($PublishToApache -or $publishDefault) {
        $publicationUrl = Publish-DevBranchToApache -DevBranchPath $DevBranchInfoBasePath -SafeDevBranchName $SafeDevBranchName
    }

    $statePath = Save-DevBranchState -SafeDevBranchName $SafeDevBranchName -State @{
        devBranchName = $DevBranchName
        safeDevBranchName = $SafeDevBranchName
        devBranchKind = $DevBranchKind
        devBranch = $GitBranch
        createdWithWorktree = $CreatedWithWorktree
        worktreePath = $WorktreePath
        mainWorktreePath = $MainProjectRoot
        createdFromCommit = Get-CurrentCommit
        lastConfigBaseUpdatedCommit = Get-CurrentCommit
        infoBaseKind = $kind
        devBranchInfoBasePath = $DevBranchInfoBasePath
        sourceUsesRepository = $sourceUsesRepository
        repositoryUnbound = $repositoryUnbound
        launcherRegistered = $launcherRegistration.registered
        launcherInfoBaseName = $launcherRegistration.name
        launcherFolder = $launcherRegistration.folder
        launcherInfoBaseId = $launcherRegistration.id
        launcherListPath = $launcherRegistration.listPath
        publicationUrl = $publicationUrl
        createdAt = (Get-Date).ToString("o")
        lastLogPath = $script:LastLogPath
    }

    Write-Host "Development branch: $GitBranch"
    if ($CreatedWithWorktree) {
        Write-Host "Development branch worktree: $WorktreePath"
        Write-Host "Main project worktree: $MainProjectRoot"
    }
    Write-Host "Development branch infobase: $DevBranchInfoBasePath"
    Write-Host "Development branch state: $statePath"
    Write-Host "1C launcher infobase: $($launcherRegistration.name)"
    Write-Host "1C launcher folder: $($launcherRegistration.folder)"
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
    $state = Read-Utf8Text -Path $statePath | ConvertFrom-Json
    $state | Add-Member -NotePropertyName statePath -NotePropertyValue $statePath -Force
    $state | Add-Member -NotePropertyName stateProjectRoot -NotePropertyValue $script:ProjectRoot -Force
    $state = Initialize-DevBranchEventLogBaseline -State $state
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
}

function New-DevBranchCore {
    param(
        [ValidateSet("configuration", "extension")]
        [string]$DevBranchKind = "configuration"
    )

    Require-Value "DevBranchName" $DevBranchName | Out-Null
    $safe = ConvertTo-SafeName $DevBranchName
    if (-not $DevBranch) {
        $DevBranch = "itldev/$safe"
    }

    Assert-CleanGit
    Checkout-Master

    if (Test-GitBranchExists -Branch $DevBranch) {
        throw "Development branch already exists: $DevBranch"
    }

    $mainProjectRoot = Get-MainWorktreePath
    if ($UseCurrentWorktree) {
        Invoke-Git @("checkout", "-b", $DevBranch)
        Initialize-DevBranchRuntime `
            -DevBranchKind $DevBranchKind `
            -SafeDevBranchName $safe `
            -GitBranch $DevBranch `
            -MainProjectRoot $script:ProjectRoot `
            -WorktreePath $script:ProjectRoot `
            -CreatedWithWorktree $false
        return
    }

    $worktreePath = Resolve-DevBranchWorktreePath -SafeDevBranchName $safe
    if (Test-Path -LiteralPath $worktreePath -ErrorAction SilentlyContinue) {
        throw "Development branch worktree path already exists: $worktreePath"
    }

    $worktreeParent = Split-Path -Parent $worktreePath
    if ($worktreeParent) {
        New-Item -ItemType Directory -Force -Path $worktreeParent | Out-Null
    }
    Invoke-Git @("worktree", "add", "-b", $DevBranch, $worktreePath, (Get-MasterBranch))
    Copy-DotEnvToWorktree -WorktreePath $worktreePath

    Invoke-InProjectContext -Root $worktreePath -ScriptBlock {
        Initialize-DevBranchRuntime `
            -DevBranchKind $DevBranchKind `
            -SafeDevBranchName $safe `
            -GitBranch $DevBranch `
            -MainProjectRoot $mainProjectRoot `
            -WorktreePath $worktreePath `
            -CreatedWithWorktree $true
    }

    Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainProjectRoot -WorktreePath $worktreePath
    Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
}

function New-DevBranch {
    New-DevBranchCore -DevBranchKind "configuration"
}

function New-ExtensionDevBranch {
    New-DevBranchCore -DevBranchKind "extension"
}

function Set-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "set-dev-branch-extension"
    Assert-DevBranchKind -State $state -Expected "extension"
    Require-Value "ExtensionName" $ExtensionName | Out-Null

    $existing = Get-StateValue -State $state -Name "extensionName" -Default ""
    if ($existing -and $existing -ne $ExtensionName -and -not $Force) {
        throw "Extension name is already set to '$existing'. Pass -Force to overwrite it."
    }

    $safeExtensionName = ConvertTo-SafeName $ExtensionName
    $extensionExportPath = Get-ExtensionExportPath -SafeExtensionName $safeExtensionName
    $updates = @{
        extensionName = $ExtensionName
        safeExtensionName = $safeExtensionName
        extensionExportPath = $extensionExportPath
    }
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension settings changed." -Force
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $updatedState

    Write-Host "Development branch extension: $ExtensionName"
    Write-Host "Extension files path: $extensionExportPath"
}

function Write-BaseUpdateResult {
    param(
        [object]$State,
        [object]$LoadResult,
        [string]$Label
    )

    if ($LoadResult.loaded) {
        Write-Host "$Label updated: $($State.devBranchInfoBasePath)"
        Write-Host "Last 1C log: $($LoadResult.lastLogPath)"
    } else {
        Write-Host "$Label unchanged: $($State.devBranchInfoBasePath)"
    }
}

function Update-DevBranchBase {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "update-dev-branch-base"
    Sync-DevBranchContextToDotEnv -State $state

    if ((Get-DevBranchKind -State $state) -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "extension"
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch extension base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        Write-BaseUpdateResult -State $state -LoadResult $loadResult -Label "Development branch extension"
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch configuration base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        Write-BaseUpdateResult -State $state -LoadResult $loadResult -Label "Development branch infobase"
    }
}

function Refresh-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "refresh-dev-branch"
    Assert-CleanGit
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    Sync-Master
    if ((Get-CurrentBranch) -ne $state.devBranch) {
        Invoke-Git @("checkout", $state.devBranch)
    }
    Invoke-Git @("merge", (Get-MasterBranch))
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
    $updates["lastRefreshAt"] = (Get-Date).ToString("o")
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed from master." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    Write-Host "Development branch refreshed from master: $($state.devBranch)"
    Write-BaseUpdateResult -State $state -LoadResult $loadResult -Label "Development branch configuration"
    if ((Get-DevBranchKind -State $state) -eq "extension") {
        Write-Host "Extension files were not loaded during refresh. Run update-dev-branch-base when you need to update the extension in the branch infobase."
    }
}

function Dump-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "dump-dev-branch-extension"
    $dumpResult = Dump-ExtensionToFiles -State $state
    $updates = @{
        lastExtensionDumpAt = (Get-Date).ToString("o")
        lastExtensionDumpPath = $dumpResult.exportPath
        lastLogPath = $dumpResult.logPath
    }
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension files were dumped from the branch infobase." -Force
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $updatedState
    Write-Host "Extension dumped: $($dumpResult.exportPath)"
    Write-Host "Last 1C log: $($dumpResult.logPath)"
}

function Show-WorkflowStatus {
    Write-Section "ITL status"

    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git"))) {
        Write-Host "Git repository: missing"
        return
    }

    $currentBranch = Get-CurrentBranch
    $currentCommit = ""
    try {
        $currentCommit = Get-CurrentCommit
    } catch {
        $currentCommit = "<none>"
    }
    $dirty = Test-GitHasChanges

    Write-Host "Git branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Git commit: $currentCommit"
    Write-Host "Git worktree: $(if ($dirty) { 'dirty' } else { 'clean' })"

    if ($currentBranch -notlike "itldev/*") {
        Write-ItlMcpStatusLines
        Write-Host "Current development branch: none"
        $worktreeStates = @()
        foreach ($file in Get-DevBranchStateFiles) {
            try {
                $state = Read-DevBranchStateFile -Path $file.FullName
                if (-not (Get-StateValue -State $state -Name "closedAt")) {
                    $worktreeStates += $state
                }
            } catch {
            }
        }
        if ($worktreeStates.Count -gt 0) {
            Write-Host "Active development worktrees: $($worktreeStates.Count)"
            foreach ($state in ($worktreeStates | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
                $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
                Write-Host "  $name"
                Write-VanessaTestStatusLines -State $state -Indent "    "
                Write-VanessaMcpStatusLines -State $state -Indent "    "
            }
            Write-Host "Run list-dev-branches to see full paths."
        }
        return
    }

    $state = Read-DevBranchState -Name ""
    $verification = Get-VerificationState -State $state
    $kind = Get-DevBranchKind -State $state

    Write-Host "Development branch: $($state.devBranch)"
    $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
    if ($worktreePath) {
        Write-Host "Worktree: $worktreePath"
    }
    $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
    if ($mainWorktreePath) {
        Write-Host "Main worktree: $mainWorktreePath"
    }
    $safeDevBranchName = Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>"
    Write-Host "Development branch name: $(Get-StateValue -State $state -Name 'devBranchName' -Default $safeDevBranchName)"
    Write-Host "Type: $kind"
    if ($kind -eq "extension") {
        Write-Host "Extension: $(Get-StateValue -State $state -Name 'extensionName' -Default '<not set>')"
        Write-Host "Extension files: $(Get-StateValue -State $state -Name 'extensionExportPath' -Default '<not set>')"
    }
    Write-Host "Infobase: $($state.devBranchInfoBasePath)"
    $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
        Write-VanessaTestStatusLines -State $state
        Write-VanessaMcpStatusLines -State $state
        Write-ItlMcpStatusLines
        Write-Host "Last config base update: $(Get-StateValue -State $state -Name 'lastConfigBaseUpdateAt' -Default '<never>')"
    if ($kind -eq "extension") {
        Write-Host "Last extension base update: $(Get-StateValue -State $state -Name 'lastExtensionBaseUpdateAt' -Default '<never>')"
    }
    Write-Host "Last refresh: $(Get-StateValue -State $state -Name 'lastRefreshAt' -Default '<never>')"
    Write-Host "Verification status: $($verification.effectiveStatus)"
    Write-Host "Verification fresh passed: $($verification.isFreshPassed)"
    if ($verification.verifiedAt) {
        Write-Host "Last verified at: $($verification.verifiedAt)"
    }
    if ($verification.verifiedCommit) {
        Write-Host "Last verified commit: $($verification.verifiedCommit)"
    }
    if ($verification.reportPath) {
        Write-Host "Last verification report: $($verification.reportPath)"
    }
    if ($verification.reason) {
        Write-Host "Last verification reason: $($verification.reason)"
    }
    Write-Host "Last result: $(Get-StateValue -State $state -Name 'lastResultPath' -Default '<none>')"
    Write-Host "Final result: $(Get-StateValue -State $state -Name 'finalResultPath' -Default '<none>')"
    $override = Get-StateValue -State $state -Name "lastUnverifiedOverrideAt" -Default ""
    if ($override) {
        Write-Host "Last unverified override: $override ($(Get-StateValue -State $state -Name 'lastUnverifiedOverrideOperation' -Default 'unknown'))"
    }
}

function Verify-DevBranch {
    Update-DevBranchBase
    Run-DevBranchTests
}

function Export-DevBranchResult {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "export-dev-branch-result"
    Assert-CleanGit
    Sync-DevBranchContextToDotEnv -State $state
    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $state.devBranch) {
        Invoke-Git @("checkout", $state.devBranch)
    }
    $kind = Get-DevBranchKind -State $state
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    }
    $devBranchCommit = Get-CurrentCommit
    $masterCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind $kind
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch base was updated before result export." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $state = Read-DevBranchState -Name $DevBranchName
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "export-dev-branch-result" -Allow:$AllowUnverifiedResult

    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind
    $resultKind = $(if ($kind -eq "extension") { "cfe" } else { "cf" })
    $manifestPath = New-ResultManifest `
        -State $state `
        -ResultPath $resultPath `
        -ResultKind $resultKind `
        -Operation "export-dev-branch-result" `
        -MasterCommit $masterCommit `
        -DevBranchCommit $devBranchCommit `
        -UnverifiedOverride ([bool]$unverifiedOverride)
    $updates = @{}
    $updates["lastResultPath"] = $resultPath
    $updates["lastResultKind"] = $resultKind
    $updates["lastResultManifestPath"] = $manifestPath
    $updates["lastResultAt"] = (Get-Date).ToString("o")
    $updates["lastLogPath"] = $script:LastLogPath
    if ($unverifiedOverride) {
        $updates["lastUnverifiedOverrideAt"] = (Get-Date).ToString("o")
        $updates["lastUnverifiedOverrideOperation"] = "export-dev-branch-result"
        $updates["lastUnverifiedResultPath"] = $resultPath
    }
    Update-DevBranchState -State $state -Updates $updates
    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "Result saved: $resultPath"
    Write-Host "Result manifest: $manifestPath"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Close-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "close-dev-branch"
    Stop-VanessaMcpForState -State $state -Quiet | Out-Null
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CleanGit
    Sync-DevBranchContextToDotEnv -State $state

    Sync-Master
    if ((Get-CurrentBranch) -ne $state.devBranch) {
        Invoke-Git @("checkout", $state.devBranch)
    }
    Invoke-Git @("merge", (Get-MasterBranch))
    Sync-DevBranchContextToDotEnv -State $state

    $kind = Get-DevBranchKind -State $state
    $configLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    $updates = New-LoadStateUpdates -LoadResult $configLoadResult -ContentKind "configuration"
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed and updated before close." -CurrentCommit $configLoadResult.currentCommit
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $extensionLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
        $extensionUpdates = New-LoadStateUpdates -LoadResult $extensionLoadResult -ContentKind "extension"
        foreach ($key in $extensionUpdates.Keys) {
            $updates[$key] = $extensionUpdates[$key]
        }
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch extension was updated before close." -CurrentCommit $extensionLoadResult.currentCommit
    }
    Update-DevBranchState -State $state -Updates $updates
    $state = Read-DevBranchState -Name $DevBranchName
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "close-dev-branch" -Allow:$AllowUnverifiedClose

    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind

    $masterBranch = Get-MasterBranch
    $masterCommit = (Get-GitOutput @("rev-parse", $masterBranch)).Trim()
    $devBranchCommit = Get-CurrentCommit
    $resultKind = $(if ($kind -eq "extension") { "cfe" } else { "cf" })
    $manifestPath = New-ResultManifest `
        -State $state `
        -ResultPath $resultPath `
        -ResultKind $resultKind `
        -Operation "close-dev-branch" `
        -MasterCommit $masterCommit `
        -DevBranchCommit $devBranchCommit `
        -UnverifiedOverride ([bool]$unverifiedOverride)

    $updates["closedAt"] = (Get-Date).ToString("o")
    $updates["finalResultPath"] = $resultPath
    $updates["finalResultKind"] = $resultKind
    $updates["finalResultManifestPath"] = $manifestPath
    $updates["lastLogPath"] = $script:LastLogPath
    if ($unverifiedOverride) {
        $updates["lastUnverifiedOverrideAt"] = (Get-Date).ToString("o")
        $updates["lastUnverifiedOverrideOperation"] = "close-dev-branch"
        $updates["lastUnverifiedResultPath"] = $resultPath
    }
    Update-DevBranchState -State $state -Updates $updates

    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Master commit: $masterCommit"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "Result saved: $resultPath"
    Write-Host "Result manifest: $manifestPath"
    Write-Host "Last 1C log: $script:LastLogPath"
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
    }

    if (Test-DevBranchStateUsesWorktree -State $state) {
        Clear-DevBranchContext
        $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
        Write-Host "Development branch worktree remains on closed branch: $($state.devBranch)"
        if ($mainWorktreePath) {
            Write-Host "Main project worktree stays on master: $mainWorktreePath"
        }
    } else {
        Invoke-Git @("checkout", $masterBranch)
        Clear-DevBranchContext
        $currentCommit = Get-CurrentCommit
        Write-Host "Switched to master branch: $masterBranch"
        Write-Host "Current commit: $currentCommit"
    }
}

function List-DevBranches {
    Write-Section "Development branches"

    $currentBranch = ""
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git")) {
        $currentBranch = Get-CurrentBranch
    }

    $currentDevBranch = "none"
    if ($currentBranch -like "itldev/*") {
        $currentDevBranch = $currentBranch.Substring("itldev/".Length)
    }

    Write-Host "Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Current development branch: $currentDevBranch"

    $states = @()
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            if (-not (Get-StateValue -State $state -Name "closedAt")) {
                $states += $state
            }
        } catch {
            Write-Host "Skipping unreadable development branch state: $($file.FullName)"
        }
    }

    if ($states.Count -eq 0) {
        Write-Host "No active development branches."
        return
    }

    foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
        $branch = Get-StateValue -State $state -Name "devBranch" -Default ""
        $marker = if ($branch -and $branch -eq $currentBranch) { "*" } else { " " }
        $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
        $infoBasePath = Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default ""
        $kind = Get-DevBranchKind -State $state
        $extensionName = Get-StateValue -State $state -Name "extensionName" -Default ""
        $createdAt = Get-StateValue -State $state -Name "createdAt" -Default ""
        $lastConfigBaseUpdateAt = Get-StateValue -State $state -Name "lastConfigBaseUpdateAt" -Default ""
        $lastExtensionBaseUpdateAt = Get-StateValue -State $state -Name "lastExtensionBaseUpdateAt" -Default ""
        $lastRefreshAt = Get-StateValue -State $state -Name "lastRefreshAt" -Default ""
        Write-Host "$marker $name"
        Write-Host "  Branch: $branch"
        Write-Host "  Type: $kind"
        $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
        if (-not $worktreePath) {
            $worktreePath = Get-StateValue -State $state -Name "stateProjectRoot" -Default ""
        }
        if ($worktreePath) {
            Write-Host "  Worktree: $worktreePath"
        }
        $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
        if ($mainWorktreePath) {
            Write-Host "  Main worktree: $mainWorktreePath"
        }
        if ($extensionName) {
            Write-Host "  Extension: $extensionName"
        }
        Write-Host "  Infobase: $infoBasePath"
        $launcherName = Get-StateValue -State $state -Name "launcherInfoBaseName" -Default ""
        $launcherFolder = Get-StateValue -State $state -Name "launcherFolder" -Default ""
        if ($launcherName) {
            Write-Host "  1C launcher: $launcherName"
        }
        if ($launcherFolder) {
            Write-Host "  1C launcher folder: $launcherFolder"
        }
        $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
        if ($publicationUrl) {
            Write-Host "  Publication URL: $publicationUrl"
        }
        Write-VanessaTestStatusLines -State $state -Indent "  "
        Write-VanessaMcpStatusLines -State $state -Indent "  "
        Write-ItlMcpStatusLines -Indent "  "
        Write-Host "  Created: $createdAt"
        Write-Host "  Last config base update: $lastConfigBaseUpdateAt"
        if ($kind -eq "extension") {
            Write-Host "  Last extension base update: $lastExtensionBaseUpdateAt"
        }
        Write-Host "  Last refresh: $lastRefreshAt"
    }
}

function Switch-Master {
    Assert-CleanGit
    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }
    if ($currentBranch -like "itldev/*") {
        $state = Read-DevBranchState -Name ""
        if (Test-DevBranchStateUsesWorktree -State $state) {
            Clear-DevBranchContext
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default (Get-MainWorktreePath)
            Write-Host "Текущая ветка разработки находится в отдельной рабочей папке."
            Write-Host "Чтобы работать с master, откройте основную папку проекта:"
            Write-Host $mainWorktreePath
            Open-AgentWorktreeBestEffort -WorktreePath $mainWorktreePath
            return
        }
    }

    $masterBranch = Get-MasterBranch
    Ensure-GitRepository
    & git -C $script:ProjectRoot rev-parse --verify $masterBranch *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Master branch does not exist: $masterBranch"
    }
    Invoke-Git @("checkout", $masterBranch)
    Clear-DevBranchContext
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to master branch: $masterBranch"
    Write-Host "Current commit: $currentCommit"
}

function Switch-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    if (Test-DevBranchStateUsesWorktree -State $state) {
        $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
        if (-not $worktreePath) {
            $worktree = Find-GitWorktreeByBranch -Branch $state.devBranch
            if ($worktree) {
                $worktreePath = $worktree.path
            }
        }

        if ($worktreePath -and ((Get-FullPathNormalized $worktreePath) -ne (Get-FullPathNormalized $script:ProjectRoot))) {
            Write-Host "Ветка разработки находится в отдельной рабочей папке:"
            Write-Host $worktreePath
            Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно Codex/Kilo/IDE в этой папке."
            Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
            return
        }
    }

    Assert-CleanGit
    Invoke-Git @("checkout", $state.devBranch)
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to development branch: $($state.devBranch)"
    Write-Host "Current commit: $currentCommit"
    Write-Host "Development branch infobase: $($state.devBranchInfoBasePath)"
    $launcherName = Get-StateValue -State $state -Name "launcherInfoBaseName" -Default ""
    $launcherFolder = Get-StateValue -State $state -Name "launcherFolder" -Default ""
    if ($launcherName) {
        Write-Host "1C launcher infobase: $launcherName"
    }
    if ($launcherFolder) {
        Write-Host "1C launcher folder: $launcherFolder"
    }
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
    }
}

function Detect-Apache {
    Write-Section "Detect Apache"
    $settings = Get-EffectiveApacheSettings

    if ($settings.webInstOk) {
        Write-Host "[OK] webinst.exe: $($settings.webInstPath)"
    } elseif ($settings.webInstPath) {
        Write-Host "[MISSING] webinst.exe was configured or derived but does not exist: $($settings.webInstPath)"
    } else {
        Write-Host "[MISSING] webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set."
    }

    if ($settings.apacheFound) {
        Write-Host "[OK] Apache config: $($settings.httpdConfPath)"
        Write-Host "Source: $($settings.apacheSource)"
        Write-Host "DocumentRoot: $($settings.documentRoot)"
        Write-Host "Listen port: $($settings.listenPort)"
    } elseif ($settings.manualPublicationRoot) {
        Write-Host "[OK] Apache publication root is set manually: $($settings.publicationRoot)"
    } else {
        Write-Host "[MISSING] $($settings.message)"
    }

    if ($settings.publicationRoot) {
        Write-Host "Publication root: $($settings.publicationRoot)"
        Write-Host "Publication URL base: $($settings.publicationUrlBase)"
    }

    Write-Host ""
    Write-Host "Values for .dev.env:"
    Write-Host "WEB_PUBLISH_BY_DEFAULT=true"
    if ($settings.webInstPath) {
        Write-Host "WEBINST_PATH=$($settings.webInstPath)"
    }
    Write-Host "APACHE_KIND=$($settings.apacheKind)"
    if ($settings.httpdConfPath) {
        Write-Host "APACHE_HTTPD_CONF_PATH=$($settings.httpdConfPath)"
    }
    if ($settings.publicationRoot) {
        Write-Host "WEB_PUBLICATION_ROOT=$($settings.publicationRoot)"
    }
    if ($settings.publicationUrlBase) {
        Write-Host "WEB_PUBLICATION_URL_BASE=$($settings.publicationUrlBase)"
    }

    if (-not $settings.ready) {
        throw "Apache publication is not ready. Run helper action install-apache after explicit developer confirmation, or install/configure Apache 2.4 manually and make sure webinst.exe exists next to 1cv8.exe, then rerun detect-apache."
    }
}

function Validate-Project {
    Write-Section "Validate project"
    Require-Value "project root" $script:ProjectRoot | Out-Null
    if (-not (Test-Path -LiteralPath $script:ProjectRoot)) {
        throw "Project root does not exist: $script:ProjectRoot"
    }

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Get-DevBranchInfoBaseRoot | Out-Null

    $kind = Get-InfoBaseKind
    $source = Get-SourceInfoBasePath
    Assert-InfoBaseAvailable -Kind $kind -Path $source -SettingName "source infobase"

    if (Get-SourceUsesRepository) {
        Get-RepositoryPath | Out-Null
        Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER") | Out-Null
    } else {
        Write-Host "Source repository connection: disabled"
    }
    Write-Host "Validation passed."
}

function Show-Help {
    Write-Host @"
1C workflow helper

Actions:
  help                Show this help.
  validate            Check required local settings.
  check-tools         Check Git, 1C platform, and optional web tools.
  list-platforms      Show installed 1C platform versions found in Program Files.
  detect-apache       Detect Apache/httpd settings for web publication.
  install-apache      Install Apache Lounge httpd from official archive after confirmation.
  install-vanessa-automation
                      Install Vanessa Automation single EPF from official GitHub release.
  install-vanessa-mcp
                      Install Vanessa MCP extensions into the current development branch infobase.
  start-vanessa-mcp  Start branch-local Vanessa MCP on an auto-assigned port.
  stop-vanessa-mcp   Stop Vanessa MCP for the current development branch.
  vanessa-mcp-status Show Vanessa MCP PID, port, URL, log, and client snippets.
  mcp-setup          Rotate local keys, ensure embedding model, start current-scope MCP, write client config.
  mcp-update         Rotate keys and pull configured MCP Docker images.
  mcp-status         Show active MCP names, URLs, embedding model, and stale indexes.
  mcp-start          Start global, project, and current branch MCP servers.
  mcp-stop           Stop MCP servers for the selected/current scope.
  mcp-rotate-keys    Copy license keys from the private distribution config.env to local storage.
  mcp-ensure-model   Select and bootstrap the local embedding model through LM Studio CLI when available.
  mcp-write-client-config
                      Write Codex and Kilo MCP config for the current worktree scope.
  status              Show current ITL branch, infobase, and verification status.
  run-dev-branch-tests
                      Run Vanessa Automation tests against the current development branch base.
  verify-dev-branch   Update the current development branch base, then run Vanessa tests.
  init-project        Dump source infobase config to master and install rules.
  sync-master         Refresh master from storage or from the current source infobase state.
  new-dev-branch             Create a configuration development branch, sibling worktree, and infobase copy.
                             Use -UseCurrentWorktree for the legacy checkout-based mode.
                             Use -OfferOpenAgent to try opening the worktree in VS Code/Kilo.
  new-extension-dev-branch   Create an extension development branch, sibling worktree, and infobase copy.
  set-dev-branch-extension   Set the extension name for the current extension branch.
  dump-dev-branch-extension  Dump the current branch extension files to src/cfe/<extension>.
  activate-dev-branch-context
                      Write current development branch infobase context to .dev.env for ai_rules_1c commands.
  update-dev-branch-base     Update the current development branch infobase from branch files.
  refresh-dev-branch         Refresh master, merge it into the development branch, update the branch base.
  export-dev-branch-result   Export CF or CFE from the current development branch.
                             Use -AllowUnverifiedResult for explicit unverified override.
  close-dev-branch           Refresh master, merge into the development branch, export final result, mark closed.
                             Use -AllowUnverifiedClose for explicit unverified override.
  switch-master       Checkout master in legacy mode, or show the main worktree path.
  switch-dev-branch      Checkout a legacy branch or show the development branch worktree path.
  list-dev-branches      Show active development branches, worktrees, and the current branch.

Examples:
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode json -InitAnswersPath .\init.answers.json
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-platforms
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action detect-apache
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-apache
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-mcp
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-vanessa-mcp
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vanessa-mcp-status
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-setup
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-status
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-start
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action status
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts"
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts" -OfferOpenAgent
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts" -UseCurrentWorktree
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "bonus-extension"
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action set-dev-branch-extension -ExtensionName "BonusExtension"
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action dump-dev-branch-extension
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action activate-dev-branch-context
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-dev-branch-base
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action verify-dev-branch
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action run-dev-branch-tests
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-dev-branches
"@
}

try {
    Write-RunStatus -Status "running"
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env")
    Read-ProjectConfig

    switch ($Action) {
        "help" { Show-Help }
        "validate" { Validate-Project }
        "check-tools" { Check-Tools -StopOnMissing }
        "list-platforms" { List-Platforms }
        "detect-apache" { Detect-Apache }
        "install-apache" { Install-Apache }
        "install-vanessa-automation" { Install-VanessaAutomation }
        "install-vanessa-mcp" { Install-VanessaMcp }
        "start-vanessa-mcp" { Start-VanessaMcp }
        "stop-vanessa-mcp" { Stop-VanessaMcp }
        "vanessa-mcp-status" { Show-VanessaMcpStatus }
        "mcp-setup" { Setup-ItlMcp }
        "mcp-update" { Update-ItlMcp }
        "mcp-status" { Show-ItlMcpStatus }
        "mcp-start" { Start-ItlMcp }
        "mcp-stop" { Stop-ItlMcp }
        "mcp-rotate-keys" { Rotate-ItlMcpKeys }
        "mcp-ensure-model" { Ensure-ItlMcpModel | Out-Null }
        "mcp-write-client-config" { Write-ItlMcpClientConfig }
        "status" { Show-WorkflowStatus }
        "run-dev-branch-tests" { Run-DevBranchTests }
        "verify-dev-branch" { Verify-DevBranch }
        "init-project" { Initialize-Project }
        "sync-master" { Sync-Master }
        "new-dev-branch" { New-DevBranch }
        "new-extension-dev-branch" { New-ExtensionDevBranch }
        "set-dev-branch-extension" { Set-DevBranchExtension }
        "dump-dev-branch-extension" { Dump-DevBranchExtension }
        "activate-dev-branch-context" { Activate-DevBranchContext }
        "update-dev-branch-base" { Update-DevBranchBase }
        "refresh-dev-branch" { Refresh-DevBranch }
        "export-dev-branch-result" { Export-DevBranchResult }
        "close-dev-branch" { Close-DevBranch }
        "switch-master" { Switch-Master }
        "switch-dev-branch" { Switch-DevBranch }
        "list-dev-branches" { List-DevBranches }
    }
    Write-RunStatus -Status "succeeded" -ExitCode 0
} catch {
    $errorMessage = $_.Exception.Message
    try {
        Write-RunStatus -Status "failed" -ExitCode 1 -ErrorMessage $errorMessage
    } catch {
        [Console]::Error.WriteLine("Failed to write run status: $($_.Exception.Message)")
    }
    [Console]::Error.WriteLine($errorMessage)
    if ($PauseOnFailure) {
        Write-Host ""
        try {
            [void](Read-Host "ITL helper failed. Press Enter to close this window")
        } catch {
            Write-Host "ITL helper failed; unable to pause for input."
        }
    }
    exit 1
}
