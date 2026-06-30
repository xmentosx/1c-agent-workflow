[CmdletBinding()]
param(
    [ValidateSet("help", "validate", "check-tools", "list-platforms", "detect-apache", "install-apache", "init-project", "sync-master", "new-dev-branch", "update-dev-branch-base", "refresh-dev-branch", "export-dev-branch-cf", "close-dev-branch", "switch-master", "switch-dev-branch", "list-dev-branches")]
    [string]$Action = "help",

    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$DevBranchName,
    [string]$DevBranch,
    [string]$DevBranchInfoBasePath,
    [ValidateSet("", "codex", "kilocode", "both")]
    [string]$AgentTarget = "",
    [switch]$PublishToApache,
    [switch]$SkipAiRules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ProjectRoot ".agent-1c\project.json"
}

$script:LastLogPath = $null
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
    [System.IO.File]::WriteAllText($Path, $Value, (Get-Utf8Encoding))
}

function Add-Utf8Text {
    param(
        [string]$Path,
        [string]$Value
    )
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

function Get-GitOutput {
    param([string[]]$Arguments)
    $output = & git -C $script:ProjectRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$script:ProjectRoot`" $($Arguments -join ' ')"
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

function Test-GitHasChanges {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status"
    }
    return [bool]($status | Select-Object -First 1)
}

function Assert-CleanGit {
    if (Test-GitHasChanges) {
        throw "Git worktree is not clean. Commit, stash, or discard changes before this action."
    }
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
        "build/cf/",
        "*.cf",
        "*.dt",
        "*.log",
        "logs/",
        ".agent-1c/infobases/"
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

function Invoke-NativeProcessAndWait {
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
        -Wait `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    return $process.ExitCode
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
        Write-Host "Source infobase is configured without repository connection. Skipping repository update; dump will use the current source infobase state."
        return $false
    }

    $repositoryArgs = (New-RepositoryConnectionArgs) + @(
        "/ConfigurationRepositoryUpdateCfg", "-force",
        "/UpdateDBCfg", "-WarningsAsErrors"
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

function Get-DevBranchLoadBaseCommit {
    param([object]$State)

    foreach ($candidate in @(
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
    param([object]$State)

    $exportPath = Get-ExportPath
    $absoluteExportPath = Assert-ExportPathInsideProject $exportPath
    $baseCommit = Get-DevBranchLoadBaseCommit -State $State

    $tracked = & git -C $script:ProjectRoot diff --name-only --diff-filter=ACMRTUXBD $baseCommit -- $exportPath
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot calculate changed config files from commit: $baseCommit"
    }

    $untracked = & git -C $script:ProjectRoot ls-files --others --exclude-standard -- $exportPath
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot calculate untracked config files under $exportPath"
    }

    $files = @()
    foreach ($path in @($tracked) + @($untracked)) {
        $relative = ConvertTo-ConfigLoadRelativePath -RepoPath $path -ExportPath $exportPath
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
    param([object]$LoadResult)

    $updates = @{
        lastLoadedCommit = $LoadResult.currentCommit
        lastLoadAt = (Get-Date).ToString("o")
        lastLoadListFile = $LoadResult.listFile
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

function Load-ConfigFromFiles {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [object]$State
    )

    $changeSet = Get-ConfigLoadChangeSet -State $State
    if ($changeSet.files.Count -eq 0) {
        Write-Host "No changed config files under $(Get-ExportPath) since $($changeSet.baseCommit)."
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

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs @("/LoadConfigFromFiles", $changeSet.absoluteExportPath, "-listFile", $listFilePath, "-Format", "Hierarchical", "/UpdateDBCfg", "-WarningsAsErrors") | Out-Null

    return [pscustomobject]@{
        loaded = $true
        fileCount = $changeSet.files.Count
        listFile = $listFilePath
        currentCommit = $changeSet.currentCommit
        lastLogPath = $script:LastLogPath
    }
}

function Dump-CF {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string]$SafeDevBranchName
    )

    $artifactDir = Resolve-ProjectPath (Get-ConfigValue -Path "artifactsPath" -Default "build/cf")
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $cfPath = Join-Path $artifactDir ($SafeDevBranchName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".cf")

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs @("/DumpCfg", $cfPath) | Out-Null

    return $cfPath
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

Use `.agents/skills/1c-workflow/SKILL.md` for project initialization, development branch creation, development branch refresh/load, master sync, branch switching, development branch close, and CF export.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.
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
        [hashtable]$State
    )

    $devBranchesDir = Join-Path $script:ProjectRoot ".agent-1c\dev-branches"
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
    Save-DevBranchState -SafeDevBranchName $safeName -State $stateHash | Out-Null
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
        throw "Development branch state not found: $path"
    }
    return Read-Utf8Text -Path $path | ConvertFrom-Json
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
    Update-UserRules
    Commit-IfChanged "chore: install 1C agent workflow"
}

function Sync-Master {
    Write-Section "Sync master"
    Assert-CleanGit
    Checkout-Master
    $sourceUsesRepository = Get-SourceUsesRepository
    Update-BaseFromRepository
    $dumpResult = Dump-ConfigToFiles
    $dumpMessage = if ($sourceUsesRepository) { "sync: refresh 1C configuration from repository" } else { "sync: refresh 1C configuration from source infobase" }
    Commit-IfChanged -Message $dumpMessage -PathSpec @($dumpResult.exportPath) -ForceAdd | Out-Null
}

function New-DevBranch {
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
    Invoke-Git @("checkout", "-b", $DevBranch)

    $kind = Get-InfoBaseKind
    $sourceUsesRepository = Get-SourceUsesRepository
    $source = Get-SourceInfoBasePath
    if (-not $DevBranchInfoBasePath) {
        $rootPath = Resolve-ProjectPath (Get-DevBranchInfoBaseRoot)
        $DevBranchInfoBasePath = Join-Path $rootPath $safe
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
        $publicationUrl = Publish-DevBranchToApache -DevBranchPath $DevBranchInfoBasePath -SafeDevBranchName $safe
    }

    $statePath = Save-DevBranchState -SafeDevBranchName $safe -State @{
        devBranchName = $DevBranchName
        safeDevBranchName = $safe
        devBranch = $DevBranch
        createdFromCommit = Get-CurrentCommit
        lastLoadedCommit = Get-CurrentCommit
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

    Write-Host "Development branch: $DevBranch"
    Write-Host "Development branch infobase: $DevBranchInfoBasePath"
    Write-Host "Development branch state: $statePath"
    Write-Host "1C launcher infobase: $($launcherRegistration.name)"
    Write-Host "1C launcher folder: $($launcherRegistration.folder)"
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
}

function Update-DevBranchBase {
    $state = Read-DevBranchState -Name $DevBranchName
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    Update-DevBranchState -State $state -Updates (New-LoadStateUpdates -LoadResult $loadResult)
    if ($loadResult.loaded) {
        Write-Host "Development branch infobase updated: $($state.devBranchInfoBasePath)"
        Write-Host "Last 1C log: $($loadResult.lastLogPath)"
    } else {
        Write-Host "Development branch infobase unchanged: $($state.devBranchInfoBasePath)"
    }
}

function Refresh-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CleanGit
    Sync-Master
    Invoke-Git @("checkout", $state.devBranch)
    Invoke-Git @("merge", (Get-MasterBranch))
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["lastRefreshAt"] = (Get-Date).ToString("o")
    Update-DevBranchState -State $state -Updates $updates
    Write-Host "Development branch refreshed from master: $($state.devBranch)"
    if ($loadResult.loaded) {
        Write-Host "Development branch infobase updated: $($state.devBranchInfoBasePath)"
        Write-Host "Last 1C log: $($loadResult.lastLogPath)"
    } else {
        Write-Host "Development branch infobase unchanged: $($state.devBranchInfoBasePath)"
    }
}

function Export-DevBranchCF {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CleanGit
    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $state.devBranch) {
        Invoke-Git @("checkout", $state.devBranch)
    }
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $cfPath = Dump-CF -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -SafeDevBranchName $state.safeDevBranchName
    $devBranchCommit = Get-CurrentCommit
    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["lastCfPath"] = $cfPath
    $updates["lastCfAt"] = (Get-Date).ToString("o")
    $updates["lastLogPath"] = $script:LastLogPath
    Update-DevBranchState -State $state -Updates $updates
    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "CF saved: $cfPath"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Close-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CleanGit

    Sync-Master
    Invoke-Git @("checkout", $state.devBranch)
    Invoke-Git @("merge", (Get-MasterBranch))

    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $cfPath = Dump-CF -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -SafeDevBranchName $state.safeDevBranchName

    $masterBranch = Get-MasterBranch
    $masterCommit = (Get-GitOutput @("rev-parse", $masterBranch)).Trim()
    $devBranchCommit = Get-CurrentCommit

    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["closedAt"] = (Get-Date).ToString("o")
    $updates["finalCfPath"] = $cfPath
    $updates["lastLogPath"] = $script:LastLogPath
    Update-DevBranchState -State $state -Updates $updates

    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Master commit: $masterCommit"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "CF saved: $cfPath"
    Write-Host "Last 1C log: $script:LastLogPath"
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
    }

    Invoke-Git @("checkout", $masterBranch)
    $currentCommit = Get-CurrentCommit
    Write-Host "Switched to master branch: $masterBranch"
    Write-Host "Current commit: $currentCommit"
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

    $devBranchesDir = Join-Path $script:ProjectRoot ".agent-1c\dev-branches"
    if (-not (Test-Path -LiteralPath $devBranchesDir)) {
        Write-Host "No active development branches."
        return
    }

    $states = @()
    foreach ($file in Get-ChildItem -LiteralPath $devBranchesDir -Filter "*.json" -File) {
        try {
            $state = Read-Utf8Text -Path $file.FullName | ConvertFrom-Json
            $state | Add-Member -NotePropertyName statePath -NotePropertyValue $file.FullName -Force
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
        $createdAt = Get-StateValue -State $state -Name "createdAt" -Default ""
        $lastLoadAt = Get-StateValue -State $state -Name "lastLoadAt" -Default ""
        $lastRefreshAt = Get-StateValue -State $state -Name "lastRefreshAt" -Default ""
        Write-Host "$marker $name"
        Write-Host "  Branch: $branch"
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
        Write-Host "  Created: $createdAt"
        Write-Host "  Last load: $lastLoadAt"
        Write-Host "  Last refresh: $lastRefreshAt"
    }
}

function Switch-Master {
    Assert-CleanGit
    $masterBranch = Get-MasterBranch
    Ensure-GitRepository
    & git -C $script:ProjectRoot rev-parse --verify $masterBranch *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Master branch does not exist: $masterBranch"
    }
    Invoke-Git @("checkout", $masterBranch)
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to master branch: $masterBranch"
    Write-Host "Current commit: $currentCommit"
}

function Switch-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CleanGit
    Invoke-Git @("checkout", $state.devBranch)
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
  init-project        Dump source infobase config to master and install rules.
  sync-master         Refresh master from storage or from the current source infobase state.
  new-dev-branch         Create an itldev/<name> development branch, infobase copy, and 1C launcher entry.
  update-dev-branch-base Update the current development branch infobase from branch files.
  refresh-dev-branch     Refresh master, merge it into the development branch, update the branch base.
  export-dev-branch-cf   Export CF from the current development branch without refreshing master.
  close-dev-branch       Refresh master, merge into the development branch, export final CF, switch to master.
  switch-master       Checkout the fixed master branch.
  switch-dev-branch      Checkout a development branch from saved state.
  list-dev-branches      Show active development branches and the current branch.

Examples:
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-platforms
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action detect-apache
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-apache
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts"
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-dev-branch-base
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-cf
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-dev-branches
"@
}

Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env")
Read-ProjectConfig

try {
    switch ($Action) {
        "help" { Show-Help }
        "validate" { Validate-Project }
        "check-tools" { Check-Tools -StopOnMissing }
        "list-platforms" { List-Platforms }
        "detect-apache" { Detect-Apache }
        "install-apache" { Install-Apache }
        "init-project" { Initialize-Project }
        "sync-master" { Sync-Master }
        "new-dev-branch" { New-DevBranch }
        "update-dev-branch-base" { Update-DevBranchBase }
        "refresh-dev-branch" { Refresh-DevBranch }
        "export-dev-branch-cf" { Export-DevBranchCF }
        "close-dev-branch" { Close-DevBranch }
        "switch-master" { Switch-Master }
        "switch-dev-branch" { Switch-DevBranch }
        "list-dev-branches" { List-DevBranches }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
