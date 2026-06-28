[CmdletBinding()]
param(
    [ValidateSet("help", "validate", "check-tools", "init-project", "sync-master", "start-feature", "load-feature", "refresh-feature", "export-feature-cf", "finish-feature", "switch-master", "switch-feature", "list-features", "dump-cf")]
    [string]$Action = "help",

    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$FeatureName,
    [string]$FeatureBranch,
    [string]$FeatureInfoBasePath,
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

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
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

        if (-not [Environment]::GetEnvironmentVariable($name, "Process")) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Read-ProjectConfig {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
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

    if ($null -eq $node -or $node -eq "") {
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

function ConvertTo-SafeName {
    param([string]$Name)
    $safe = ($Name.Trim() -replace "[^a-zA-Z0-9_.-]+", "-").Trim("-").ToLowerInvariant()
    if (-not $safe) {
        $safe = "feature-" + (Get-Date -Format "yyyyMMdd-HHmmss")
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

    & git -C $script:ProjectRoot rev-parse --verify $masterBranch *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git @("checkout", $masterBranch)
    } else {
        Invoke-Git @("checkout", "-b", $masterBranch)
    }

    if ((Test-GitHasRemote) -and (Test-GitHasUpstream)) {
        Invoke-Git @("pull", "--ff-only")
    }
}

function Commit-IfChanged {
    param([string]$Message)
    Invoke-Git @("add", ".")
    if (Test-GitHasChanges) {
        Invoke-Git @("commit", "-m", $Message)
    } else {
        Write-Host "No Git changes to commit."
    }
}

function Ensure-GitIgnore {
    $gitignorePath = Join-Path $script:ProjectRoot ".gitignore"
    $required = @(
        ".dev.env",
        "build/cf/",
        "*.cf",
        "*.dt",
        "*.log",
        "logs/"
    )

    if (Test-Path -LiteralPath $gitignorePath) {
        $current = Get-Content -LiteralPath $gitignorePath
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
        Add-Content -LiteralPath $gitignorePath -Value $linesToAdd
    }
}

function Get-PlatformPath {
    return Require-Value "PLATFORM_PATH or project.platformPath" (Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath")
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

function Get-FeatureInfoBaseRoot {
    return Require-Value "FEATURE_INFOBASE_ROOT or project.featureInfoBaseRoot" (Get-Setting -EnvName "FEATURE_INFOBASE_ROOT" -ConfigName "featureInfoBaseRoot")
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
        $script:ToolsManifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
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

    $platformPath = Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath"
    $platformOk = ($platformPath -and (Test-Path -LiteralPath $platformPath))
    $results += New-ToolResult `
        -Id "1c-platform" `
        -Name "1C platform" `
        -Required $true `
        -Ok ([bool]$platformOk) `
        -Detail $(if ($platformPath) { $platformPath } else { "PLATFORM_PATH/project.platformPath is missing" }) `
        -Offer (Get-ToolOffer -Id "1c-platform" -Fallback "Install 1C:Enterprise platform manually, then set PLATFORM_PATH in .dev.env.")

    $publishDefault = [bool](Get-ConfigValue -Path "web.publishByDefault" -Default $false)
    if ($PublishToApache -or $publishDefault) {
        $webInstPath = Get-Setting -EnvName "WEBINST_PATH" -ConfigName "web.webInstPath"
        $webInstOk = ($webInstPath -and (Test-Path -LiteralPath $webInstPath))
        $results += New-ToolResult `
            -Id "apache-webinst" `
            -Name "Apache/webinst" `
            -Required $true `
            -Ok ([bool]$webInstOk) `
            -Detail $(if ($webInstPath) { $webInstPath } else { "WEBINST_PATH/project.web.webInstPath is missing" }) `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Install Apache and 1C web server extension manually, then set WEBINST_PATH and APACHE_KIND.")
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

function New-InfobaseArgs {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    $args = @()
    if ($Kind -eq "file") {
        $args += @("/F", $Path)
    } elseif ($Kind -eq "server") {
        $args += @("/S", $Path)
    } else {
        throw "Unknown infobase kind: $Kind"
    }

    if ($User) {
        $args += @("/N", $User)
    }
    if ($Password) {
        $args += @("/P", $Password)
    }
    return $args
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

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = Join-Path $logsPath ("1c-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $DesignerArgs

    & $platformPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "1C Designer failed with exit code $LASTEXITCODE. Log: $logPath"
    }

    return $logPath
}

function Update-BaseFromRepository {
    $repositoryUser = Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER")
    $repositoryPassword = Require-Value "REPOSITORY_PASSWORD" (Get-EnvValue -Name "REPOSITORY_PASSWORD")
    $repositoryPath = Get-RepositoryPath

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs @(
            "/ConfigurationRepositoryF", $repositoryPath,
            "/ConfigurationRepositoryN", $repositoryUser,
            "/ConfigurationRepositoryP", $repositoryPassword,
            "/ConfigurationRepositoryUpdateCfg", "-force",
            "/UpdateDBCfg", "-WarningsAsErrors"
        ) | Out-Null
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

function Get-FeatureLoadBaseCommit {
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
    $baseCommit = Get-FeatureLoadBaseCommit -State $State

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
    $safeFeatureName = Get-StateValue -State $State -Name "safeFeatureName" -Default "feature"
    $listFilePath = Join-Path $logsPath ("load-files-" + $safeFeatureName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($listFilePath, [string[]]$Files, $utf8NoBom)
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
    $designerArgs = @("/DumpConfigToFiles", $absoluteExportPath, "-Format", "Hierarchical")
    if (Test-Path -LiteralPath $dumpInfoPath) {
        $designerArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Export path '$absoluteExportPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping config files."
    }

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs $designerArgs | Out-Null
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
        Write-Host "Feature infobase already matches current branch config files."
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
        [string]$SafeFeatureName
    )

    $artifactDir = Resolve-ProjectPath (Get-ConfigValue -Path "artifactsPath" -Default "build/cf")
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $cfPath = Join-Path $artifactDir ($SafeFeatureName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".cf")

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
        $tools = (Get-AgentTargets) -join ","
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
        $installArgs = @("init", "-Source", $rulesDir, "-Tools", $tools)
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

Use `.agents/skills/1c-workflow/SKILL.md` for project initialization, feature start, feature refresh, feature load, master sync, branch switching, feature finish, and CF export.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.
"@

    if (Test-Path -LiteralPath $path) {
        $current = Get-Content -LiteralPath $path -Raw
        if ($current.Contains($marker)) {
            return
        }
        Add-Content -LiteralPath $path -Value $block
    } else {
        Set-Content -LiteralPath $path -Value $block.TrimStart()
    }
}

function Save-FeatureState {
    param(
        [string]$SafeFeatureName,
        [hashtable]$State
    )

    $featuresDir = Join-Path $script:ProjectRoot ".agent-1c\features"
    New-Item -ItemType Directory -Force -Path $featuresDir | Out-Null
    $path = Join-Path $featuresDir ($SafeFeatureName + ".json")
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
    return $path
}

function Update-FeatureState {
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

    $safeName = $stateHash["safeFeatureName"]
    if (-not $safeName) {
        $safeName = ConvertTo-SafeName $stateHash["featureName"]
        $stateHash["safeFeatureName"] = $safeName
    }
    Save-FeatureState -SafeFeatureName $safeName -State $stateHash | Out-Null
}

function Read-FeatureState {
    param([string]$Name)

    if (-not $Name) {
        $currentBranch = (Get-GitOutput @("branch", "--show-current")).Trim()
        if ($currentBranch -like "feature/*") {
            $Name = $currentBranch.Substring("feature/".Length)
        }
    }

    if (-not $Name) {
        throw "Run this from a feature branch or pass -FeatureName."
    }

    $safe = ConvertTo-SafeName $Name
    $path = Join-Path $script:ProjectRoot ".agent-1c\features\$safe.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Feature state not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Publish-FeatureToApache {
    param(
        [string]$FeaturePath,
        [string]$SafeFeatureName
    )

    $webInstPath = Get-Setting -EnvName "WEBINST_PATH" -ConfigName "web.webInstPath"
    $apacheKind = Get-Setting -EnvName "APACHE_KIND" -ConfigName "web.apacheKind" -Default "apache24"
    $publicationRoot = Get-Setting -EnvName "WEB_PUBLICATION_ROOT" -ConfigName "web.publicationRoot"
    $urlBase = Get-Setting -EnvName "WEB_PUBLICATION_URL_BASE" -ConfigName "web.publicationUrlBase" -Default "http://localhost"
    $confPath = Get-Setting -EnvName "APACHE_HTTPD_CONF_PATH" -ConfigName "web.apacheHttpdConfPath"

    Require-Value "WEBINST_PATH or project.web.webInstPath" $webInstPath | Out-Null
    Require-Value "WEB_PUBLICATION_ROOT or project.web.publicationRoot" $publicationRoot | Out-Null

    if (-not (Test-Path -LiteralPath $webInstPath)) {
        throw "webinst.exe was not found: $webInstPath"
    }

    $publicationName = $SafeFeatureName -replace "[^a-zA-Z0-9_]", "_"
    $publicationDir = Join-Path $publicationRoot $publicationName
    New-Item -ItemType Directory -Force -Path $publicationDir | Out-Null

    $kind = Get-InfoBaseKind
    if ($kind -eq "file") {
        $connStr = "File=`"$FeaturePath`";"
    } else {
        $connStr = $FeaturePath
    }

    $args = @("-publish", "-$apacheKind", "-wsdir", $publicationName, "-dir", $publicationDir, "-connstr", $connStr)
    if ($confPath) {
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
    Get-FeatureInfoBaseRoot | Out-Null
    Ensure-GitRepository
    Ensure-GitIgnore
    Checkout-Master

    Update-BaseFromRepository
    Dump-ConfigToFiles
    Commit-IfChanged "sync: export 1C configuration from repository"

    Install-AiRules1c
    Update-UserRules
    Commit-IfChanged "chore: install 1C agent workflow"
}

function Sync-Master {
    Write-Section "Sync master"
    Assert-CleanGit
    Checkout-Master
    Update-BaseFromRepository
    Dump-ConfigToFiles
    Commit-IfChanged "sync: refresh 1C configuration from repository"
}

function Start-Feature {
    Require-Value "FeatureName" $FeatureName | Out-Null
    $safe = ConvertTo-SafeName $FeatureName
    if (-not $FeatureBranch) {
        $FeatureBranch = "feature/$safe"
    }

    Assert-CleanGit
    Checkout-Master

    & git -C $script:ProjectRoot rev-parse --verify $FeatureBranch *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Feature branch already exists: $FeatureBranch"
    }
    Invoke-Git @("checkout", "-b", $FeatureBranch)

    $kind = Get-InfoBaseKind
    $source = Get-SourceInfoBasePath
    if (-not $FeatureInfoBasePath) {
        $rootPath = Resolve-ProjectPath (Get-FeatureInfoBaseRoot)
        $FeatureInfoBasePath = Join-Path $rootPath $safe
    }

    if ($kind -eq "file") {
        if (Test-Path -LiteralPath $FeatureInfoBasePath) {
            throw "Feature infobase path already exists: $FeatureInfoBasePath"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FeatureInfoBasePath) | Out-Null
        Copy-Item -LiteralPath $source -Destination $FeatureInfoBasePath -Recurse
    } else {
        $copyScript = Get-ConfigValue -Path "serverBaseCopyScript" -Default ""
        if (-not $copyScript) {
            throw "serverBaseCopyScript is required for server infobase copies."
        }
        $copyScriptPath = Resolve-ProjectPath $copyScript
        & powershell -ExecutionPolicy Bypass -File $copyScriptPath `
            -ProjectRoot $script:ProjectRoot `
            -FeatureName $FeatureName `
            -SourceInfoBasePath $source `
            -FeatureInfoBasePath $FeatureInfoBasePath
        if ($LASTEXITCODE -ne 0) {
            throw "Server infobase copy script failed with exit code $LASTEXITCODE"
        }
    }

    Invoke-Designer `
        -InfoBasePath $FeatureInfoBasePath `
        -InfoBaseKind $kind `
        -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null

    $publishDefault = [bool](Get-ConfigValue -Path "web.publishByDefault" -Default $false)
    $publicationUrl = ""
    if ($PublishToApache -or $publishDefault) {
        $publicationUrl = Publish-FeatureToApache -FeaturePath $FeatureInfoBasePath -SafeFeatureName $safe
    }

    $statePath = Save-FeatureState -SafeFeatureName $safe -State @{
        featureName = $FeatureName
        safeFeatureName = $safe
        branch = $FeatureBranch
        createdFromCommit = Get-CurrentCommit
        lastLoadedCommit = Get-CurrentCommit
        infoBaseKind = $kind
        featureInfoBasePath = $FeatureInfoBasePath
        publicationUrl = $publicationUrl
        createdAt = (Get-Date).ToString("o")
        lastLogPath = $script:LastLogPath
    }

    Write-Host "Feature branch: $FeatureBranch"
    Write-Host "Feature infobase: $FeatureInfoBasePath"
    Write-Host "Feature state: $statePath"
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
}

function Load-Feature {
    $state = Read-FeatureState -Name $FeatureName
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    Update-FeatureState -State $state -Updates (New-LoadStateUpdates -LoadResult $loadResult)
    if ($loadResult.loaded) {
        Write-Host "Feature infobase updated: $($state.featureInfoBasePath)"
        Write-Host "Last 1C log: $($loadResult.lastLogPath)"
    } else {
        Write-Host "Feature infobase unchanged: $($state.featureInfoBasePath)"
    }
}

function Refresh-Feature {
    $state = Read-FeatureState -Name $FeatureName
    Assert-CleanGit
    Sync-Master
    Invoke-Git @("checkout", $state.branch)
    Invoke-Git @("merge", (Get-MasterBranch))
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["lastRefreshAt"] = (Get-Date).ToString("o")
    Update-FeatureState -State $state -Updates $updates
    Write-Host "Feature refreshed from master: $($state.branch)"
    if ($loadResult.loaded) {
        Write-Host "Feature infobase updated: $($state.featureInfoBasePath)"
        Write-Host "Last 1C log: $($loadResult.lastLogPath)"
    } else {
        Write-Host "Feature infobase unchanged: $($state.featureInfoBasePath)"
    }
}

function Export-FeatureCF {
    $state = Read-FeatureState -Name $FeatureName
    Assert-CleanGit
    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $state.branch) {
        Invoke-Git @("checkout", $state.branch)
    }
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $cfPath = Dump-CF -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -SafeFeatureName $state.safeFeatureName
    $featureCommit = Get-CurrentCommit
    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["lastCfPath"] = $cfPath
    $updates["lastCfAt"] = (Get-Date).ToString("o")
    $updates["lastLogPath"] = $script:LastLogPath
    Update-FeatureState -State $state -Updates $updates
    Write-Host "Branch: $($state.branch)"
    Write-Host "Feature commit: $featureCommit"
    Write-Host "CF saved: $cfPath"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Finish-Feature {
    $state = Read-FeatureState -Name $FeatureName
    Assert-CleanGit

    Sync-Master
    Invoke-Git @("checkout", $state.branch)
    Invoke-Git @("merge", (Get-MasterBranch))

    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state
    $cfPath = Dump-CF -InfoBasePath $state.featureInfoBasePath -InfoBaseKind $state.infoBaseKind -SafeFeatureName $state.safeFeatureName

    $masterBranch = Get-MasterBranch
    $masterCommit = (Get-GitOutput @("rev-parse", $masterBranch)).Trim()
    $featureCommit = Get-CurrentCommit

    $updates = New-LoadStateUpdates -LoadResult $loadResult
    $updates["finishedAt"] = (Get-Date).ToString("o")
    $updates["finalCfPath"] = $cfPath
    $updates["lastLogPath"] = $script:LastLogPath
    Update-FeatureState -State $state -Updates $updates

    Write-Host "Branch: $($state.branch)"
    Write-Host "Master commit: $masterCommit"
    Write-Host "Feature commit: $featureCommit"
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

function List-Features {
    Write-Section "Features"

    $currentBranch = ""
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git")) {
        $currentBranch = Get-CurrentBranch
    }

    $currentFeature = "none"
    if ($currentBranch -like "feature/*") {
        $currentFeature = $currentBranch.Substring("feature/".Length)
    }

    Write-Host "Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Current feature: $currentFeature"

    $featuresDir = Join-Path $script:ProjectRoot ".agent-1c\features"
    if (-not (Test-Path -LiteralPath $featuresDir)) {
        Write-Host "No features in development."
        return
    }

    $states = @()
    foreach ($file in Get-ChildItem -LiteralPath $featuresDir -Filter "*.json" -File) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $state | Add-Member -NotePropertyName statePath -NotePropertyValue $file.FullName -Force
            if (-not (Get-StateValue -State $state -Name "finishedAt")) {
                $states += $state
            }
        } catch {
            Write-Host "Skipping unreadable feature state: $($file.FullName)"
        }
    }

    if ($states.Count -eq 0) {
        Write-Host "No features in development."
        return
    }

    foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "featureName" -Default "" } })) {
        $branch = Get-StateValue -State $state -Name "branch" -Default ""
        $marker = if ($branch -and $branch -eq $currentBranch) { "*" } else { " " }
        $name = Get-StateValue -State $state -Name "featureName" -Default (Get-StateValue -State $state -Name "safeFeatureName" -Default "<unknown>")
        $infoBasePath = Get-StateValue -State $state -Name "featureInfoBasePath" -Default ""
        $createdAt = Get-StateValue -State $state -Name "createdAt" -Default ""
        $lastLoadAt = Get-StateValue -State $state -Name "lastLoadAt" -Default ""
        $lastRefreshAt = Get-StateValue -State $state -Name "lastRefreshAt" -Default ""
        Write-Host "$marker $name"
        Write-Host "  Branch: $branch"
        Write-Host "  Infobase: $infoBasePath"
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

function Switch-Feature {
    $state = Read-FeatureState -Name $FeatureName
    Assert-CleanGit
    Invoke-Git @("checkout", $state.branch)
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to feature branch: $($state.branch)"
    Write-Host "Current commit: $currentCommit"
    Write-Host "Feature infobase: $($state.featureInfoBasePath)"
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
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

    Get-FeatureInfoBaseRoot | Out-Null

    $kind = Get-InfoBaseKind
    $source = Get-SourceInfoBasePath
    if ($kind -eq "file") {
        $dbFile = Join-Path $source "1Cv8.1CD"
        if (-not (Test-Path -LiteralPath $dbFile)) {
            throw "File infobase was not found: $dbFile"
        }
    }

    Get-RepositoryPath | Out-Null
    Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER") | Out-Null
    Require-Value "REPOSITORY_PASSWORD" (Get-EnvValue -Name "REPOSITORY_PASSWORD") | Out-Null
    Write-Host "Validation passed."
}

function Show-Help {
    Write-Host @"
1C workflow helper

Actions:
  help                Show this help.
  validate            Check required local settings.
  check-tools         Check Git, 1C platform, and optional web tools.
  init-project        Sync source infobase, dump config to master, install rules.
  sync-master         Refresh master from source infobase connected to storage.
  start-feature       Create feature branch and feature infobase copy.
  load-feature        Load changed config files into the feature infobase.
  refresh-feature     Refresh master from storage, merge it into the feature branch, update feature base.
  export-feature-cf   Export CF from the current feature branch without refreshing master.
  finish-feature      Refresh master, merge into feature branch, export final CF, switch to master.
  switch-master       Checkout the fixed master branch.
  switch-feature      Checkout a feature branch from saved feature state.
  list-features       Show features in development and the current feature.
  dump-cf             Alias for export-feature-cf.

Examples:
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-feature -FeatureName "order-discounts"
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-feature
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-feature
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-feature-cf
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action finish-feature
  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-features
"@
}

Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env")
Read-ProjectConfig

try {
    switch ($Action) {
        "help" { Show-Help }
        "validate" { Validate-Project }
        "check-tools" { Check-Tools }
        "init-project" { Initialize-Project }
        "sync-master" { Sync-Master }
        "start-feature" { Start-Feature }
        "load-feature" { Load-Feature }
        "refresh-feature" { Refresh-Feature }
        "export-feature-cf" { Export-FeatureCF }
        "finish-feature" { Finish-Feature }
        "switch-master" { Switch-Master }
        "switch-feature" { Switch-Feature }
        "list-features" { List-Features }
        "dump-cf" { Export-FeatureCF }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
