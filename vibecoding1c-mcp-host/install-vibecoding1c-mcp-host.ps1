[CmdletBinding()]
param(
    [ValidateSet("setup", "start", "stop", "status", "refresh-config", "publish", "dump-config")]
    [string]$Action = "status",

    [string]$ConfigPath = ".\host.config.json",
    [string]$ConfigId = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$script:PythonExecutable = ""

function Read-Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Text {
    param(
        [string]$Path,
        [string]$Value
    )
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Value, $script:Utf8NoBom)
}

function Read-JsonFile {
    param([string]$Path)
    return (Read-Text -Path $Path | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )
    Write-Text -Path $Path -Value (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Get-ObjectValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
            $value = $Object[$Name]
            if ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) -or $value -is [System.Collections.IDictionary]) {
                return $value
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        if ($prop.Value -is [array] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string]) -or $prop.Value -is [System.Collections.IDictionary]) {
            return $prop.Value
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return $prop.Value
        }
    }
    return $Default
}

function As-Array {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [array]) { return @($Value) }
    return @($Value)
}

function Convert-ToHash {
    param([AllowNull()][object]$Object)
    $hash = [ordered]@{}
    if ($null -eq $Object) {
        return $hash
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { $hash[$key] = $Object[$key] }
        return $hash
    }
    foreach ($prop in $Object.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }
    return $hash
}

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Join-PathIfRelative {
    param(
        [string]$Root,
        [string]$Path
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Invoke-Git {
    param(
        [string]$Root,
        [string[]]$Arguments
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git -C $Root @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in @($output)) {
        if ($null -ne $line) {
            Write-Host ([string]$line)
        }
    }
    if ($exitCode -ne 0) {
        throw "git failed in $Root with arguments: $($Arguments -join ' ')"
    }
}

function Get-GitOutput {
    param(
        [string]$Root,
        [string[]]$Arguments
    )
    $output = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $Root with arguments: $($Arguments -join ' ')"
    }
    return @($output)
}

function Ensure-GitCheckout {
    param(
        [string]$Repo,
        [string]$Path,
        [string]$Branch = ""
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Host "Cloning $Repo -> $Path"
        if ($DryRun) { return }
        Invoke-Git -Root $parent -Arguments @("clone", $Repo, $Path)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path ".git") -PathType Container)) {
        throw "Path exists but is not a Git checkout: $Path"
    }
    if ($Branch) {
        Invoke-Git -Root $Path -Arguments @("fetch", "--prune")
        Invoke-Git -Root $Path -Arguments @("checkout", $Branch)
        Invoke-Git -Root $Path -Arguments @("pull", "--ff-only")
    } else {
        Invoke-Git -Root $Path -Arguments @("fetch", "--prune")
        try {
            $upstream = ((Get-GitOutput -Root $Path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")) -join "").Trim()
        } catch {
            $upstream = ""
        }
        if ($upstream) {
            Invoke-Git -Root $Path -Arguments @("merge", "--ff-only", $upstream)
        } else {
            Invoke-Git -Root $Path -Arguments @("pull", "--ff-only")
        }
    }
}

function Read-DotEnv {
    param([string]$Path)
    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }
    return $values
}

function Write-DotEnv {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )
    $lines = @()
    foreach ($key in @($Values.Keys | Sort-Object)) {
        $lines += "$key=$($Values[$key])"
    }
    Write-Text -Path $Path -Value (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Get-Sha256Text {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $script:Utf8NoBom.GetBytes($Value)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
}

function Get-FileSha256OrEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DirectoryFingerprint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return "<missing>"
    }
    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $lines = @()
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart("\", "/") -replace "\\", "/"
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$relative=$hash"
    }
    return (Get-Sha256Text -Value ($lines -join "`n"))
}

function Read-HostConfig {
    $resolved = Get-FullPath $ConfigPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Host config was not found: $resolved. Copy host.config.example.json to host.config.json first."
    }
    return (Read-JsonFile -Path $resolved)
}

function Get-StateRoot {
    param([object]$Config)
    return (Get-FullPath ([string](Get-ObjectValue -Object $Config -Name "stateRoot" -Default "D:/ITL/MCP")))
}

function Get-DistributionRoot {
    param([object]$Config)
    return (Join-Path (Get-StateRoot -Config $Config) "distribution")
}

function Get-RegistryRoot {
    param([object]$Config)
    return (Join-Path (Get-StateRoot -Config $Config) "registry")
}

function Get-HostStatePath {
    param([object]$Config)
    return (Join-Path (Get-StateRoot -Config $Config) "host-state.json")
}

function Read-HostState {
    param([object]$Config)
    $default = [pscustomobject]@{
        schemaVersion = 1
        updatedAt = ""
        configurations = @()
        servers = @()
    }
    $path = Get-HostStatePath -Config $Config
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Read-JsonFile -Path $path)
    }
    return $default
}

function Write-HostState {
    param(
        [object]$Config,
        [object]$State
    )
    $hash = Convert-ToHash -Object $State
    $hash["schemaVersion"] = 1
    $hash["updatedAt"] = (Get-Date).ToString("o")
    Write-JsonFile -Path (Get-HostStatePath -Config $Config) -Value $hash
}

function Invoke-DockerCommand {
    param(
        [string[]]$Arguments,
        [switch]$Quiet,
        [int]$TimeoutSec = 300
    )
    $result = Invoke-ProcessWithTimeout -FilePath "docker" -Arguments $Arguments -TimeoutSec $TimeoutSec -Description "Docker command did not finish"
    if (-not $Quiet) {
        foreach ($line in @($result.lines)) {
            if ($null -ne $line) {
                Write-Host ([string]$line)
            }
        }
    }
    return [int]$result.exitCode
}

function Invoke-DockerCommandChecked {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSec = 300,
        [string]$Description = "docker command"
    )
    $result = Invoke-ProcessWithTimeout -FilePath "docker" -Arguments $Arguments -TimeoutSec $TimeoutSec -Description $Description
    foreach ($line in @($result.lines)) {
        if ($null -ne $line) {
            Write-Host ([string]$line)
        }
    }
    if ($result.exitCode -ne 0) {
        $output = (($result.lines | Where-Object { $_ }) -join [Environment]::NewLine).Trim()
        if ($output) {
            throw "$Description failed with exit code $($result.exitCode). Command: docker $($Arguments -join ' '). Output: $output"
        }
        throw "$Description failed with exit code $($result.exitCode). Command: docker $($Arguments -join ' ')."
    }
}

function Invoke-DockerCommandCapture {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSec = 300,
        [string]$Description = "docker command"
    )
    $result = Invoke-ProcessWithTimeout -FilePath "docker" -Arguments $Arguments -TimeoutSec $TimeoutSec -Description $Description
    if ($result.exitCode -ne 0) {
        $output = (($result.lines | Where-Object { $_ }) -join [Environment]::NewLine).Trim()
        if ($output) {
            throw "$Description failed with exit code $($result.exitCode). Command: docker $($Arguments -join ' '). Output: $output"
        }
        throw "$Description failed with exit code $($result.exitCode). Command: docker $($Arguments -join ' ')."
    }
    return @($result.lines)
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        exitCode = [int]$exitCode
        lines = @($output | ForEach-Object { [string]$_ })
    }
}

function Join-HostProcessArguments {
    param([string[]]$Arguments)
    $escaped = @()
    foreach ($argument in @($Arguments)) {
        $text = [string]$argument
        if ($text -notmatch '[\s"]') {
            $escaped += $text
            continue
        }
        $escaped += '"' + ($text.Replace('"', '\"')) + '"'
    }
    return ($escaped -join " ")
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSec = 300,
        [string]$Description = ""
    )
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList (Join-HostProcessArguments -Arguments $Arguments) `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try {
                $process.Kill()
            } catch {
            }
            $commandText = "$FilePath $($Arguments -join ' ')"
            $descriptionText = $(if ($Description) { "$Description. " } else { "" })
            throw "${descriptionText}Command timed out after $TimeoutSec seconds: $commandText"
        }
        $stdout = @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
        $stderr = @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            exitCode = [int]$process.ExitCode
            lines = @($stdout + $stderr)
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PythonExecutable {
    param([object]$Config)
    $candidate = [string](Get-ObjectValue -Object $Config -Name "pythonPath" -Default "")
    if (-not $candidate) {
        $candidate = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_PYTHON_PATH", "Process")
    }
    if (-not $candidate) {
        $candidate = "python"
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($candidate.Trim())
    $looksLikePath = [System.IO.Path]::IsPathRooted($expanded) -or $expanded.Contains("\") -or $expanded.Contains("/")
    if ($looksLikePath) {
        $fullPath = Get-FullPath $expanded
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Python executable was not found: $fullPath. Set host.config.json pythonPath to a real python.exe."
        }
        return $fullPath
    }
    $command = Get-Command $expanded -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Python executable was not found in PATH: $expanded. Install Python 3 or set host.config.json pythonPath."
    }
    return $command.Source
}

function Ensure-PythonRuntime {
    param([object]$Config)
    if ($script:PythonExecutable) {
        return $script:PythonExecutable
    }
    $pythonPath = Resolve-PythonExecutable -Config $Config
    $versionResult = Invoke-ProcessCapture -FilePath $pythonPath -Arguments @("--version")
    $versionText = (($versionResult.lines | Where-Object { $_ }) -join " ").Trim()
    if ($versionResult.exitCode -ne 0 -or $versionText -notmatch '^Python\s+3\.') {
        throw "Python 3 runtime check failed for '$pythonPath' with exit code $($versionResult.exitCode). Output: $versionText. Install Python 3, disable the Windows Store python app execution alias, or set host.config.json pythonPath to a real python.exe."
    }
    $script:PythonExecutable = $pythonPath
    Write-Host "Python runtime: $versionText ($pythonPath)"
    return $script:PythonExecutable
}

function Ensure-HostPrerequisites {
    param([object]$Config)
    foreach ($command in @("git", "docker")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command was not found: $command"
        }
    }
    Ensure-PythonRuntime -Config $Config | Out-Null
    if ((Invoke-DockerCommand -Arguments @("info") -Quiet -TimeoutSec 60) -ne 0) {
        throw "Docker is installed but not available to the current user/session."
    }
}

function Test-DockerImageAvailable {
    param([string]$Image)
    return ((Invoke-DockerCommand -Arguments @("image", "inspect", $Image) -Quiet -TimeoutSec 60) -eq 0)
}

function Ensure-DockerImageAvailable {
    param([string]$Image)
    if ([string]::IsNullOrWhiteSpace($Image)) {
        throw "Docker image is not configured for a vibecoding1c MCP server."
    }
    if (Test-DockerImageAvailable -Image $Image) {
        return
    }

    Write-Host "Docker image is not available locally: $Image"
    Write-Host "Pulling Docker image: $Image"
    if ((Invoke-DockerCommand -Arguments @("pull", $Image) -TimeoutSec 900) -ne 0) {
        throw "Docker image '$Image' is not available locally and docker pull failed. Check Docker daemon health and registry access. If Docker reports 'read-only file system', restart Docker Desktop or run 'wsl --shutdown' before retrying, then pull or load the image manually if needed."
    }
}

function Ensure-Distribution {
    param([object]$Config)
    $repo = [string](Get-ObjectValue -Object $Config -Name "distributionRepo" -Default "http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git")
    Ensure-GitCheckout -Repo $repo -Path (Get-DistributionRoot -Config $Config)
}

function Read-DistributionManifest {
    param([object]$Config)
    $path = Join-Path (Get-DistributionRoot -Config $Config) "vibecoding1c-mcp.manifest.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Distribution manifest was not found: $path"
    }
    return (Read-JsonFile -Path $path)
}

function Test-ConfigSpecificServerId {
    param([string]$Id)
    return ($Id -eq "code" -or $Id -eq "graph")
}

function Get-ServerScope {
    param([object]$Server)
    $id = [string](Get-ObjectValue -Object $Server -Name "id" -Default "")
    $scope = [string](Get-ObjectValue -Object $Server -Name "scope" -Default "")
    if ((Test-ConfigSpecificServerId -Id $id) -and ((-not $scope) -or $scope -eq "global")) {
        return "project"
    }
    if ($scope) {
        return $scope
    }
    return "global"
}

function Get-EnabledServerIds {
    param(
        [object]$Config,
        [string]$Scope
    )
    $enabledServers = Get-ObjectValue -Object $Config -Name "enabledServers" -Default $null
    $enabled = @(As-Array (Get-ObjectValue -Object $enabledServers -Name $Scope -Default @()) | ForEach-Object { [string]$_ })
    if ($Scope -eq "global") {
        return @($enabled | Where-Object { -not (Test-ConfigSpecificServerId -Id $_) })
    }
    if ($Scope -eq "project") {
        $globalEnabled = @(As-Array (Get-ObjectValue -Object $enabledServers -Name "global" -Default @()) | ForEach-Object { [string]$_ })
        $configSpecificEnabled = @($globalEnabled | Where-Object { Test-ConfigSpecificServerId -Id $_ })
        return @($enabled + $configSpecificEnabled | Where-Object { $_ } | Select-Object -Unique)
    }
    return $enabled
}

function ConvertTo-HostBoolSetting {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )
    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $text = ([string]$Value).Trim()
    if ($text -match '^(1|true|yes|on)$') {
        return $true
    }
    if ($text -match '^(0|false|no|off)$') {
        return $false
    }
    return $Default
}

function ConvertTo-HostEnvBool {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )
    if (ConvertTo-HostBoolSetting -Value $Value -Default $Default) {
        return "true"
    }
    return "false"
}

function Test-HostEnabledServersNeedEmbedding {
    param(
        [object]$Manifest,
        [string[]]$GlobalServerIds,
        [string[]]$ProjectServerIds
    )
    foreach ($server in As-Array (Get-ObjectValue -Object $Manifest -Name "servers" -Default @())) {
        if (-not (ConvertTo-HostBoolSetting -Value (Get-ObjectValue -Object $server -Name "embedding" -Default $false) -Default $false)) {
            continue
        }
        $id = [string](Get-ObjectValue -Object $server -Name "id" -Default "")
        $scope = Get-ServerScope -Server $server
        if ($scope -eq "global" -and $GlobalServerIds -contains $id) {
            return $true
        }
        if ($scope -eq "project" -and $ProjectServerIds -contains $id) {
            return $true
        }
    }
    return $false
}

function Test-HostServerNeedsEmbedding {
    param([object]$Server)
    return (ConvertTo-HostBoolSetting -Value (Get-ObjectValue -Object $Server -Name "embedding" -Default $false) -Default $false)
}

function Get-HostEmbeddingSettings {
    param([object]$Config)
    $embedding = Get-ObjectValue -Object $Config -Name "embedding" -Default $null
    $apiBase = [string](Get-ObjectValue -Object $embedding -Name "apiBase" -Default "")
    $apiKey = [string](Get-ObjectValue -Object $embedding -Name "apiKey" -Default "")
    $mode = $(if ([string]::IsNullOrWhiteSpace($apiKey)) { "cpu" } else { "openai" })
    $model = [string](Get-ObjectValue -Object $embedding -Name "model" -Default $(if ($mode -eq "cpu") { "intfloat/multilingual-e5-base" } else { "" }))
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "Standalone vibecoding1c MCP host embedding.model is required because an enabled server needs embeddings. Set it to 'intfloat/multilingual-e5-base' unless you explicitly need another model."
    }
    if ($mode -eq "openai" -and [string]::IsNullOrWhiteSpace($apiBase)) {
        throw "Standalone vibecoding1c MCP host embedding.apiBase is required when embedding.apiKey is set."
    }
    return [pscustomobject]@{
        mode = $mode
        apiBase = $apiBase.TrimEnd("/")
        apiKey = $apiKey
        model = $model
    }
}

function Get-HostEmbeddingProbeBase {
    param([string]$ApiBase)
    try {
        $uri = [System.Uri]$ApiBase
    } catch {
        throw "Standalone vibecoding1c MCP host embedding.apiBase is not a valid absolute URL: $ApiBase"
    }
    if (-not $uri.IsAbsoluteUri) {
        throw "Standalone vibecoding1c MCP host embedding.apiBase must be an absolute URL: $ApiBase"
    }
    $builder = [System.UriBuilder]::new($uri)
    $apiHost = $uri.Host.ToLowerInvariant()
    if ($apiHost -eq "host.docker.internal" -or $apiHost -eq "localhost" -or $apiHost -eq "127.0.0.1") {
        $builder.Host = "127.0.0.1"
    }
    return $builder.Uri.AbsoluteUri.TrimEnd("/")
}

function Get-HostEmbeddingModelsUri {
    param([string]$ApiBase)
    return "$(Get-HostEmbeddingProbeBase -ApiBase $ApiBase)/models"
}

function Get-HostEmbeddingModelIds {
    param([AllowNull()][object]$Response)
    $ids = @()
    $items = Get-ObjectValue -Object $Response -Name "data" -Default $Response
    foreach ($item in As-Array $items) {
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $ids += $item
            }
            continue
        }
        $id = [string](Get-ObjectValue -Object $item -Name "id" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $ids += $id
        }
    }
    return @($ids)
}

function Test-HostEmbeddingModelPresent {
    param(
        [AllowNull()][object]$Response,
        [string]$Model
    )
    $matches = @((Get-HostEmbeddingModelIds -Response $Response) | Where-Object { $_ -eq $Model })
    return ($matches.Count -gt 0)
}

function Test-HostEmbeddingEndpointReady {
    param(
        [string]$ApiBase,
        [string]$Model
    )
    try {
        $response = Invoke-RestMethod -Uri (Get-HostEmbeddingModelsUri -ApiBase $ApiBase) -TimeoutSec 5
        return (Test-HostEmbeddingModelPresent -Response $response -Model $Model)
    } catch {
        return $false
    }
}

function Test-HostEmbeddingApiBaseIsLocal {
    param([string]$ApiBase)
    try {
        $uri = [System.Uri]$ApiBase
    } catch {
        return $false
    }
    $apiHost = $uri.Host.ToLowerInvariant()
    return ($apiHost -eq "host.docker.internal" -or $apiHost -eq "localhost" -or $apiHost -eq "127.0.0.1")
}

function Invoke-HostLmsCommand {
    param([string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & lms @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        exitCode = [int]$exitCode
        output = (@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    }
}

function Get-HostLmsCommand {
    return (Get-Command lms -ErrorAction SilentlyContinue)
}

function Invoke-HostLmsRequiredCommand {
    param(
        [string[]]$Arguments,
        [string]$Description
    )
    $result = Invoke-HostLmsCommand -Arguments $Arguments
    if ($result.exitCode -ne 0) {
        $output = ([string]$result.output).Trim()
        if ($output) {
            throw "Standalone vibecoding1c MCP host failed to $Description. Command: lms $($Arguments -join ' '). Exit code: $($result.exitCode). Output: $output"
        }
        throw "Standalone vibecoding1c MCP host failed to $Description. Command: lms $($Arguments -join ' '). Exit code: $($result.exitCode)."
    }
}

function Ensure-HostEmbeddingModel {
    param(
        [object]$Config,
        [object]$Manifest,
        [string[]]$GlobalServerIds,
        [string[]]$ProjectServerIds
    )
    if (-not (Test-HostEnabledServersNeedEmbedding -Manifest $Manifest -GlobalServerIds $GlobalServerIds -ProjectServerIds $ProjectServerIds)) {
        return
    }

    $settings = Get-HostEmbeddingSettings -Config $Config
    Write-Host "Standalone embedding mode: $($settings.mode)"
    Write-Host "Standalone embedding model: $($settings.model)"
    if ($settings.mode -eq "cpu") {
        Write-Host "Standalone embedding uses built-in CPU model; LM Studio bootstrap is skipped."
        return
    }

    $probeBase = Get-HostEmbeddingProbeBase -ApiBase $settings.apiBase
    $modelsUri = Get-HostEmbeddingModelsUri -ApiBase $settings.apiBase
    Write-Host "Standalone embedding probe: $modelsUri"

    if (Test-HostEmbeddingEndpointReady -ApiBase $settings.apiBase -Model $settings.model) {
        Write-Host "Standalone embedding endpoint is ready for model: $($settings.model)"
        return
    }

    if (-not (Test-HostEmbeddingApiBaseIsLocal -ApiBase $settings.apiBase)) {
        throw "Standalone vibecoding1c MCP host embedding endpoint '$($settings.apiBase)' is reachable only when /v1/models includes configured model '$($settings.model)'. Fix host.config.json embedding.model or start the model before starting containers."
    }

    $lms = Get-HostLmsCommand
    if ($null -eq $lms) {
        throw "Standalone vibecoding1c MCP host needs LM Studio CLI 'lms' to load embedding model '$($settings.model)' for '$probeBase', but 'lms' was not found. Install LM Studio CLI, or start an OpenAI-compatible embedding endpoint manually before starting containers."
    }

    $uri = [System.Uri]$probeBase
    $port = $uri.Port
    if ($port -le 0) {
        $port = if ($uri.Scheme -eq "https") { 443 } else { 80 }
    }

    Invoke-HostLmsRequiredCommand -Arguments @("get", $settings.model) -Description "download embedding model '$($settings.model)'"
    Invoke-HostLmsRequiredCommand -Arguments @("load", $settings.model) -Description "load embedding model '$($settings.model)'"
    $serverStart = Invoke-HostLmsCommand -Arguments @("server", "start", "--port", ([string]$port))

    if (Test-HostEmbeddingEndpointReady -ApiBase $settings.apiBase -Model $settings.model) {
        Write-Host "Standalone embedding endpoint is ready for model: $($settings.model)"
        return
    }

    $serverOutput = ([string]$serverStart.output).Trim()
    if ($serverStart.exitCode -ne 0 -and $serverOutput) {
        throw "Standalone vibecoding1c MCP host could not start LM Studio server on port $port. Command: lms server start --port $port. Exit code: $($serverStart.exitCode). Output: $serverOutput"
    }
    if ($serverStart.exitCode -ne 0) {
        throw "Standalone vibecoding1c MCP host could not start LM Studio server on port $port. Command: lms server start --port $port. Exit code: $($serverStart.exitCode)."
    }
    throw "Standalone vibecoding1c MCP host loaded '$($settings.model)', but '$modelsUri' still does not list that model. Check LM Studio server state before starting containers."
}

function Get-ConfigWorkRoot {
    param(
        [object]$Config,
        [string]$ConfigId
    )
    return (Join-Path (Join-Path (Get-StateRoot -Config $Config) "configs") $ConfigId)
}

function Get-SourceRoot {
    param(
        [object]$Config,
        [string]$ConfigId
    )
    return (Join-Path (Join-Path (Get-StateRoot -Config $Config) "sources") $ConfigId)
}

function Resolve-ConfigSourcePath {
    param(
        [object]$Config,
        [object]$Configuration,
        [string]$ConfigId
    )
    $sourcePath = [string](Get-ObjectValue -Object $Configuration -Name "sourcePath" -Default "")
    if (-not $sourcePath) {
        return Get-SourceRoot -Config $Config -ConfigId $ConfigId
    }
    return Get-FullPath $sourcePath
}

function Assert-ConfigurationSourceSettings {
    param(
        [object]$Configuration,
        [string]$ConfigId
    )
    $sourceRepo = [string](Get-ObjectValue -Object $Configuration -Name "sourceRepo" -Default "")
    $sourcePath = [string](Get-ObjectValue -Object $Configuration -Name "sourcePath" -Default "")
    if ($sourceRepo -and $sourcePath) {
        throw "Configuration '$configId' must use either sourceRepo or sourcePath, not both."
    }
    if (-not $sourceRepo -and -not $sourcePath) {
        throw "Configuration '$configId' must set sourceRepo for Git dumps or sourcePath for local XML dumps."
    }
}

function Get-ConfigSubPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )
    $path = if ($RelativePath) { $RelativePath } else { "." }
    if ($path -eq ".") {
        return ([System.IO.Path]::GetFullPath($Root))
    }
    return (Join-PathIfRelative -Root $Root -Path $path)
}

function New-TimestampedFilePath {
    param(
        [string]$Directory,
        [string]$Prefix,
        [string]$Extension
    )
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    return (Join-Path $Directory "$Prefix$timestamp$Extension")
}

function Ensure-MetadataTool {
    param([object]$Config)
    $toolRoot = Join-Path (Join-Path (Get-StateRoot -Config $Config) "tools") "norkins-metadata"
    Ensure-GitCheckout -Repo "https://github.com/norkins/metadata.git" -Path $toolRoot
    return $toolRoot
}

function Invoke-PythonMetadataGenerator {
    param(
        [string]$PythonPath,
        [string]$ScriptPath,
        [string]$ConfigPath,
        [string]$LogPath
    )
    $result = Invoke-ProcessCapture -FilePath $PythonPath -Arguments @("-B", $ScriptPath, "--config", $ConfigPath)
    $lines = @($result.lines)
    Write-Text -Path $LogPath -Value (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    foreach ($line in $lines) {
        if ($line) {
            Write-Host $line
        }
    }
    return [int]$result.exitCode
}

function Write-MetadataDiagnosticsSummary {
    param([string]$DiagnosticsRoot)
    $diagnosticsPath = Join-Path $DiagnosticsRoot "report-diagnostics.json"
    $statsPath = Join-Path $DiagnosticsRoot "report-stats.json"
    if (Test-Path -LiteralPath $statsPath -PathType Leaf) {
        try {
            $stats = Read-JsonFile -Path $statsPath
            Write-Host "norkins/metadata stats: objects=$((Get-ObjectValue -Object $stats -Name 'mainConfigurationObjects' -Default 0)) warnings=$((Get-ObjectValue -Object $stats -Name 'warnings' -Default 0)) errors=$((Get-ObjectValue -Object $stats -Name 'errors' -Default 0))"
        } catch {
            Write-Host "WARNING: failed to read norkins/metadata stats: $statsPath"
        }
    }
    if (-not (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)) {
        return
    }
    Write-Host "norkins/metadata diagnostics: $diagnosticsPath"
    try {
        $diagnostics = Read-JsonFile -Path $diagnosticsPath
        foreach ($event in @(As-Array (Get-ObjectValue -Object $diagnostics -Name "errors" -Default @())) | Select-Object -First 10) {
            $code = Get-ObjectValue -Object $event -Name "code" -Default "<unknown>"
            $message = Get-ObjectValue -Object $event -Name "message" -Default ""
            $path = Get-ObjectValue -Object $event -Name "path" -Default ""
            Write-Host "  ERROR ${code}: $message $path"
        }
        foreach ($event in @(As-Array (Get-ObjectValue -Object $diagnostics -Name "warnings" -Default @())) | Select-Object -First 10) {
            $code = Get-ObjectValue -Object $event -Name "code" -Default "<unknown>"
            $message = Get-ObjectValue -Object $event -Name "message" -Default ""
            $count = Get-ObjectValue -Object $event -Name "count" -Default ""
            $countText = $(if ($count) { " count=$count" } else { "" })
            Write-Host "  WARNING ${code}${countText}: $message"
        }
    } catch {
        Write-Host "WARNING: failed to read norkins/metadata diagnostics: $diagnosticsPath"
    }
}

function Get-XmlDirectChildText {
    param(
        [AllowNull()][object]$Node,
        [string]$LocalName
    )
    if ($null -eq $Node) {
        return ""
    }
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq $LocalName) {
            return ([string]$child.InnerText).Trim()
        }
    }
    return ""
}

function Read-ConfigurationXmlInfo {
    param(
        [string]$MainConfigRoot,
        [string]$FallbackName,
        [string]$FallbackVersion = ""
    )
    $result = [ordered]@{
        configurationName = $FallbackName
        configurationVersion = $FallbackVersion
    }
    $configurationXmlPath = Join-Path $MainConfigRoot "Configuration.xml"
    if (-not (Test-Path -LiteralPath $configurationXmlPath -PathType Leaf)) {
        return [pscustomobject]$result
    }
    try {
        [xml]$xml = Read-Text -Path $configurationXmlPath
        $propertiesNodes = $xml.SelectNodes("//*[local-name()='Configuration']/*[local-name()='Properties']")
        if ($propertiesNodes.Count -eq 0) {
            $propertiesNodes = $xml.SelectNodes("//*[local-name()='Properties']")
        }
        if ($propertiesNodes.Count -gt 0) {
            $name = Get-XmlDirectChildText -Node $propertiesNodes[0] -LocalName "Name"
            $version = Get-XmlDirectChildText -Node $propertiesNodes[0] -LocalName "Version"
            if ($name) {
                $result["configurationName"] = $name
            }
            if ($version) {
                $result["configurationVersion"] = $version
            }
        }
    } catch {
        Write-Host "WARNING: failed to read configuration metadata from $configurationXmlPath`: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

function Get-ConfigurationState {
    param(
        [object]$Config,
        [object]$Configuration
    )
    $configId = [string](Get-ObjectValue -Object $Configuration -Name "configId" -Default "")
    if (-not $configId) {
        throw "Configuration entry has no configId."
    }
    Assert-ConfigurationSourceSettings -Configuration $Configuration -ConfigId $configId
    $sourceRoot = Resolve-ConfigSourcePath -Config $Config -Configuration $Configuration -ConfigId $configId
    $sourceRepo = [string](Get-ObjectValue -Object $Configuration -Name "sourceRepo" -Default "")
    $sourcePath = [string](Get-ObjectValue -Object $Configuration -Name "sourcePath" -Default "")
    $sourceLabel = [string](Get-ObjectValue -Object $Configuration -Name "sourceLabel" -Default "")
    $sourceBranch = [string](Get-ObjectValue -Object $Configuration -Name "sourceBranch" -Default "")
    $title = [string](Get-ObjectValue -Object $Configuration -Name "title" -Default $configId)
    if ($sourceRepo) {
        Ensure-GitCheckout -Repo $sourceRepo -Path $sourceRoot -Branch $sourceBranch
    } elseif (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Configuration '$configId' sourcePath was not found: $sourceRoot"
    }

    $sourceCommit = ""
    $sourceStatus = ""
    $mainPath = [string](Get-ObjectValue -Object $Configuration -Name "mainConfigPath" -Default "src/cf")
    $treeHash = ""
    $source = $sourceRepo
    if ($sourceRepo) {
        try {
            $sourceCommit = ((Get-GitOutput -Root $sourceRoot -Arguments @("rev-parse", "HEAD")) -join "").Trim()
            $sourceStatus = ((& git -C $sourceRoot status --porcelain) -join "`n")
        } catch {
            $sourceCommit = ""
            $sourceStatus = "<not-git>"
        }
        try {
            $normalized = ($mainPath -replace "\\", "/").Trim("/")
            $treeRef = if ($normalized) { "HEAD:$normalized" } else { "HEAD^{tree}" }
            $treeHash = ((Get-GitOutput -Root $sourceRoot -Arguments @("rev-parse", $treeRef)) -join "").Trim()
        } catch {
            $treeHash = "<missing>"
        }
    } else {
        $source = $(if ($sourceLabel) { $sourceLabel } else { "local:$configId" })
        $sourceCommit = ""
        $sourceStatus = "local-source"
        $treeHash = Get-DirectoryFingerprint -Path (Get-ConfigSubPath -Root $sourceRoot -RelativePath $mainPath)
    }

    $workRoot = Get-ConfigWorkRoot -Config $Config -ConfigId $configId
    $configurationInfo = Read-ConfigurationXmlInfo -MainConfigRoot (Get-ConfigSubPath -Root $sourceRoot -RelativePath $mainPath) -FallbackName $title
    $metadataRoot = Join-Path $workRoot "metadata"
    $diagnosticsRoot = Join-Path $workRoot "diagnostics"
    $logsRoot = Join-Path $workRoot "logs"
    $reportFileName = [string](Get-ObjectValue -Object $Configuration -Name "reportFileName" -Default "Report.txt")
    $reportPath = Join-Path $metadataRoot $reportFileName
    return [pscustomobject]@{
        configId = $configId
        title = $title
        configurationName = [string]$configurationInfo.configurationName
        configurationVersion = [string]$configurationInfo.configurationVersion
        source = $source
        sourceRoot = $sourceRoot
        sourceCommit = $sourceCommit
        sourceFingerprint = "commit=$sourceCommit|$mainPath=$treeHash|worktree=$(if ($sourceStatus) { $sourceStatus } else { '<clean>' })"
        mainConfigPath = $mainPath
        extensionPath = [string](Get-ObjectValue -Object $Configuration -Name "extensionPath" -Default "")
        metadataRoot = $metadataRoot
        diagnosticsRoot = $diagnosticsRoot
        logsRoot = $logsRoot
        reportPath = $reportPath
        reportHash = (Get-FileSha256OrEmpty -Path $reportPath)
        indexedAt = ""
    }
}

function Refresh-Configuration {
    param(
        [object]$Config,
        [object]$Configuration
    )
    $state = Get-ConfigurationState -Config $Config -Configuration $Configuration
    $toolRoot = Ensure-MetadataTool -Config $Config
    New-Item -ItemType Directory -Force -Path $state.metadataRoot, $state.diagnosticsRoot, $state.logsRoot | Out-Null
    $mainConfigRoot = Get-ConfigSubPath -Root $state.sourceRoot -RelativePath $state.mainConfigPath
    if (-not (Test-Path -LiteralPath $mainConfigRoot -PathType Container)) {
        throw "Configuration '$($state.configId)' mainConfigPath was not found: $mainConfigRoot. Check sourceRepo/sourcePath and mainConfigPath. For local dumps stored directly under sourcePath, set mainConfigPath to '.'."
    }
    $generatorConfigPath = Join-Path (Get-ConfigWorkRoot -Config $Config -ConfigId $state.configId) "generate-config-report.json"
    $generatorConfig = [ordered]@{
        project = $state.configId
        repoPath = $state.sourceRoot
        mainConfigPath = $state.mainConfigPath
        mainConfigRequired = $true
        extensionPath = $state.extensionPath
        extensionRequired = $false
        outputPath = $state.metadataRoot
        reportFileName = [System.IO.Path]::GetFileName($state.reportPath)
        diagnosticsPath = $state.diagnosticsRoot
        logsPath = $state.logsRoot
        encoding = "utf-8"
        warningsAsErrors = $false
        buildXmlOverrides = $true
        generatorSettingsPath = (Join-Path (Get-ConfigWorkRoot -Config $Config -ConfigId $state.configId) "settings.generated.json")
    }
    Write-JsonFile -Path $generatorConfigPath -Value $generatorConfig
    $scriptPath = Join-Path $toolRoot "generate_config_report.py"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "norkins/metadata generator was not found: $scriptPath"
    }
    Write-Host "Generating Report.txt for $($state.configId)"
    if (-not $DryRun) {
        $pythonPath = Ensure-PythonRuntime -Config $Config
        $pythonLogPath = New-TimestampedFilePath -Directory $state.logsRoot -Prefix "norkins-metadata-" -Extension ".log"
        $exitCode = Invoke-PythonMetadataGenerator -PythonPath $pythonPath -ScriptPath $scriptPath -ConfigPath $generatorConfigPath -LogPath $pythonLogPath
        if ($exitCode -eq 1) {
            Write-Host "norkins/metadata completed for configId $($state.configId) with warnings."
            Write-MetadataDiagnosticsSummary -DiagnosticsRoot $state.diagnosticsRoot
        } elseif ($exitCode -ne 0) {
            Write-MetadataDiagnosticsSummary -DiagnosticsRoot $state.diagnosticsRoot
            throw "norkins/metadata failed for configId $($state.configId) with exit code $exitCode. Python: $pythonPath. Generator config: $generatorConfigPath. Python log: $pythonLogPath. Source root: $($state.sourceRoot). mainConfigPath: $($state.mainConfigPath). Resolved main config root: $mainConfigRoot."
        }
    }
    if (-not $DryRun -and -not (Test-Path -LiteralPath $state.reportPath -PathType Leaf)) {
        throw "norkins/metadata did not create Report.txt for configId $($state.configId): $($state.reportPath). Diagnostics root: $($state.diagnosticsRoot)."
    }
    $state.reportHash = Get-FileSha256OrEmpty -Path $state.reportPath
    $state.indexedAt = (Get-Date).ToString("o")
    return $state
}

function Update-HostStateConfigurations {
    param(
        [object]$Config,
        [object[]]$ConfigStates
    )
    $state = Read-HostState -Config $Config
    $hash = Convert-ToHash -Object $state
    $updatedById = @{}
    foreach ($configState in @($ConfigStates)) {
        $configId = [string](Get-ObjectValue -Object $configState -Name "configId" -Default "")
        if ($configId) {
            $updatedById[$configId] = $true
        }
    }
    $configurations = @()
    foreach ($existing in As-Array (Get-ObjectValue -Object $state -Name "configurations" -Default @())) {
        $existingId = [string](Get-ObjectValue -Object $existing -Name "configId" -Default "")
        if ($existingId -and $updatedById.ContainsKey($existingId)) {
            continue
        }
        $configurations += $existing
    }
    $configurations += @($ConfigStates)
    $hash["configurations"] = $configurations
    Write-HostState -Config $Config -State $hash
}

function Refresh-HostConfigurations {
    param(
        [object]$Config,
        [string]$TargetConfigId = ""
    )
    Ensure-Distribution -Config $Config
    $states = @()
    $matched = $false
    foreach ($configuration in As-Array (Get-ObjectValue -Object $Config -Name "configurations" -Default @())) {
        $configIdValue = [string](Get-ObjectValue -Object $configuration -Name "configId" -Default "")
        if ($TargetConfigId -and $configIdValue -ne $TargetConfigId) {
            continue
        }
        $matched = $true
        $states += Refresh-Configuration -Config $Config -Configuration $configuration
    }
    if ($TargetConfigId -and -not $matched) {
        throw "Configuration '$TargetConfigId' was not found in host config."
    }
    Update-HostStateConfigurations -Config $Config -ConfigStates $states
    return @($states)
}

function Invoke-HostConfigDumpHelper {
    param(
        [string]$ResolvedConfigPath,
        [string]$TargetConfigId = ""
    )
    $dumpScript = Join-Path $PSScriptRoot "export-1c-config-dump.ps1"
    if (-not (Test-Path -LiteralPath $dumpScript -PathType Leaf)) {
        throw "Config dump helper was not found: $dumpScript"
    }
    $args = @("-ExecutionPolicy", "Bypass", "-File", $dumpScript, "-ConfigPath", $ResolvedConfigPath)
    if ($TargetConfigId) {
        $args += @("-ConfigId", $TargetConfigId)
    }
    if ($DryRun) {
        $args += "-DryRun"
    }
    & powershell @args
    if ($LASTEXITCODE -ne 0) {
        throw "Config dump helper failed with exit code $LASTEXITCODE."
    }
}

function Get-HostPort {
    param(
        [object]$Config,
        [string]$Scope,
        [int]$Index,
        [int]$ConfigIndex = 0
    )
    $ranges = Get-ObjectValue -Object $Config -Name "portRanges" -Default $null
    if ($Scope -eq "global") {
        return ([int](Get-ObjectValue -Object $ranges -Name "globalStart" -Default 18000) + $Index)
    }
    return ([int](Get-ObjectValue -Object $ranges -Name "projectStart" -Default 18100) + ($ConfigIndex * 100) + $Index)
}

function Get-HostSecretValues {
    param([object]$Config)
    $distributionRoot = Get-DistributionRoot -Config $Config
    $values = Read-DotEnv -Path (Join-Path $distributionRoot "config.env")
    $configSecrets = Convert-ToHash -Object (Get-ObjectValue -Object $Config -Name "secrets" -Default $null)
    foreach ($key in @($configSecrets.Keys)) {
        $value = [string]$configSecrets[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values[$key] = $value
        }
    }
    return $values
}

function Get-HostLocalValues {
    param(
        [object]$Config,
        [object]$ConfigState = $null
    )
    $help = Get-ObjectValue -Object $Config -Name "helpSearchServer" -Default $null
    $ssl = Get-ObjectValue -Object $Config -Name "sslSearchServer" -Default $null
    $code = Get-ObjectValue -Object $Config -Name "codeMetadataSearchServer" -Default $null
    $graph = Get-ObjectValue -Object $Config -Name "graphMetadataSearchServer" -Default $null
    $platformBinPath = [string](Get-ObjectValue -Object $help -Name "platformBinPath" -Default "")
    $platformVersion = [string](Get-ObjectValue -Object $help -Name "platformVersion" -Default "")
    $bspVersion = [string](Get-ObjectValue -Object $ssl -Name "bspVersion" -Default "")
    return [ordered]@{
        PATH_METADATA = $(if ($ConfigState) { $ConfigState.metadataRoot } else { "" })
        PATH_CODE = $(if ($ConfigState) { Get-ConfigSubPath -Root $ConfigState.sourceRoot -RelativePath $ConfigState.mainConfigPath } else { "" })
        PATH_BASES = (Join-Path (Get-StateRoot -Config $Config) "bases")
        PATH_MODEL_CACHE = (Join-Path (Get-StateRoot -Config $Config) "model-cache")
        PATH_1C_BIN = $(if ($platformBinPath) { Get-FullPath $platformBinPath } else { "" })
        PLATFORM_VERSION = $platformVersion
        HELP_PLATFORM_VERSION = $platformVersion
        SSL_VERSION = $bspVersion
        BSP_VERSION = $bspVersion
        RESET_DATABASE = "false"
        CODE_RESET_DATABASE = (ConvertTo-HostEnvBool -Value (Get-ObjectValue -Object $code -Name "resetDatabase" -Default $false) -Default $false)
        CODE_REINDEX_INTERVAL_HOURS = [string](Get-ObjectValue -Object $code -Name "reindexIntervalHours" -Default "")
        GRAPH_RESET_DATABASE = (ConvertTo-HostEnvBool -Value (Get-ObjectValue -Object $graph -Name "resetDatabase" -Default $false) -Default $false)
        GRAPH_REINDEX_INTERVAL_HOURS = [string](Get-ObjectValue -Object $graph -Name "reindexIntervalHours" -Default "")
        GRAPH_AUTO_UPDATE_ON_STARTUP = (ConvertTo-HostEnvBool -Value (Get-ObjectValue -Object $graph -Name "autoUpdateOnStartup" -Default $true) -Default $true)
        PROJECT_NAME = $(if ($ConfigState) { $ConfigState.configId } else { [string](Get-ObjectValue -Object $Config -Name "hostId" -Default "vibecoding1c-mcp-host") })
    }
}

function Resolve-HostConfigValue {
    param(
        [string]$From,
        [System.Collections.IDictionary]$SecretValues,
        [System.Collections.IDictionary]$LocalValues,
        [object]$Default = ""
    )
    if (-not $From) {
        return [string]$Default
    }
    if ($From -like "PATH_*" -and $LocalValues.Contains($From)) {
        $localValue = [string]$LocalValues[$From]
        if (-not [string]::IsNullOrWhiteSpace($localValue)) {
            return $localValue
        }
    }
    if ($SecretValues.Contains($From)) {
        $secretValue = [string]$SecretValues[$From]
        if (-not [string]::IsNullOrWhiteSpace($secretValue)) {
            return $secretValue
        }
    }
    if ($LocalValues.Contains($From)) {
        $localValue = [string]$LocalValues[$From]
        if (-not [string]::IsNullOrWhiteSpace($localValue)) {
            return $localValue
        }
    }
    return [string]$Default
}

function Set-GraphOpenAiFallbackEnv {
    param(
        [object]$Config,
        [object]$Server,
        [System.Collections.IDictionary]$Values
    )
    $id = [string](Get-ObjectValue -Object $Server -Name "id" -Default "")
    if ($id -ne "graph") {
        return
    }
    if (-not (Test-HostServerNeedsEmbedding -Server $Server)) {
        return
    }
    $settings = Get-HostEmbeddingSettings -Config $Config
    if ($settings.mode -ne "openai") {
        return
    }
    $embedding = Get-ObjectValue -Object $Config -Name "embedding" -Default $null
    $fallbacks = @(
        [pscustomobject]@{ name = "OPENAI_API_KEY"; embeddingName = "apiKey"; default = "" },
        [pscustomobject]@{ name = "OPENAI_API_BASE"; embeddingName = "apiBase"; default = "" },
        [pscustomobject]@{ name = "OPENAI_MODEL"; embeddingName = "model"; default = "" }
    )
    foreach ($fallback in $fallbacks) {
        $current = ""
        if ($Values.Contains($fallback.name)) {
            $current = [string]$Values[$fallback.name]
        }
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            continue
        }
        $value = [string](Get-ObjectValue -Object $embedding -Name $fallback.embeddingName -Default $fallback.default)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $Values[$fallback.name] = $value
        }
    }
}

function Get-HostDefaultEnvEntries {
    param([object]$Server)
    $id = [string](Get-ObjectValue -Object $Server -Name "id" -Default "")
    switch ($id) {
        "codechecker" {
            return @([ordered]@{ name = "ONEC_AI_TOKEN"; from = "ONEC_AI_TOKEN"; required = $false })
        }
        "docs" {
            return @(
                [ordered]@{ name = "PLATFORM_VERSION"; from = "PLATFORM_VERSION"; required = $false },
                [ordered]@{ name = "HELP_PLATFORM_VERSION"; from = "HELP_PLATFORM_VERSION"; required = $false }
            )
        }
        "ssl" {
            return @(
                [ordered]@{ name = "SSL_VERSION"; from = "SSL_VERSION"; required = $false },
                [ordered]@{ name = "BSP_VERSION"; from = "BSP_VERSION"; required = $false }
            )
        }
        "code" {
            return @(
                [ordered]@{ name = "RESET_DATABASE"; from = "CODE_RESET_DATABASE"; default = "false"; required = $false },
                [ordered]@{ name = "REINDEX_INTERVAL_HOURS"; from = "CODE_REINDEX_INTERVAL_HOURS"; required = $false }
            )
        }
        "graph" {
            return @(
                [ordered]@{ name = "RESET_DATABASE"; from = "GRAPH_RESET_DATABASE"; default = "false"; required = $false },
                [ordered]@{ name = "REINDEX_INTERVAL_HOURS"; from = "GRAPH_REINDEX_INTERVAL_HOURS"; required = $false },
                [ordered]@{ name = "AUTO_UPDATE_ON_STARTUP"; from = "GRAPH_AUTO_UPDATE_ON_STARTUP"; default = "true"; required = $false }
            )
        }
        default {
            return @()
        }
    }
}

function Get-HostDefaultVolumeEntries {
    param([object]$Server)
    $id = [string](Get-ObjectValue -Object $Server -Name "id" -Default "")
    if ($id -eq "docs") {
        return @([ordered]@{ from = "PATH_1C_BIN"; to = "/app/1c_bin"; required = $false })
    }
    return @()
}

function Resolve-ServerEnv {
    param(
        [object]$Config,
        [object]$Server,
        [object]$ConfigState = $null
    )
    $secretValues = Get-HostSecretValues -Config $Config
    $serverNeedsEmbedding = Test-HostServerNeedsEmbedding -Server $Server
    $embeddingSettings = $null
    if ($serverNeedsEmbedding) {
        $embeddingSettings = Get-HostEmbeddingSettings -Config $Config
    }
    $values = [ordered]@{}
    $localValues = Get-HostLocalValues -Config $Config -ConfigState $ConfigState
    $envEntries = @(As-Array (Get-ObjectValue -Object $Server -Name "env" -Default @())) + @(Get-HostDefaultEnvEntries -Server $Server)
    foreach ($entry in $envEntries) {
        $name = [string](Get-ObjectValue -Object $entry -Name "name" -Default "")
        if (-not $name) { continue }
        $value = ""
        $skipMissingRequired = $false
        $embeddingKind = [string](Get-ObjectValue -Object $entry -Name "embedding" -Default "")
        if ($embeddingKind) {
            if ($null -eq $embeddingSettings) {
                $embeddingSettings = Get-HostEmbeddingSettings -Config $Config
            }
            if ($embeddingSettings.mode -eq "openai") {
                switch ($embeddingKind) {
                    "base" { $value = [string]$embeddingSettings.apiBase }
                    "key" { $value = [string]$embeddingSettings.apiKey }
                    "model" { $value = [string]$embeddingSettings.model }
                }
            } else {
                $skipMissingRequired = $true
            }
        } elseif (Get-ObjectValue -Object $entry -Name "value" -Default $null) {
            $value = [string](Get-ObjectValue -Object $entry -Name "value" -Default "")
            if ($ConfigState) { $value = $value.Replace("{projectSlug}", $ConfigState.configId) }
        } else {
            $from = [string](Get-ObjectValue -Object $entry -Name "from" -Default "")
            $value = Resolve-HostConfigValue -From $from -SecretValues $secretValues -LocalValues $localValues -Default (Get-ObjectValue -Object $entry -Name "default" -Default "")
        }
        if ([bool](Get-ObjectValue -Object $entry -Name "required" -Default $false) -and [string]::IsNullOrWhiteSpace($value)) {
            if ($skipMissingRequired) {
                continue
            }
            $serverId = [string](Get-ObjectValue -Object $Server -Name "id" -Default "<unknown>")
            $from = [string](Get-ObjectValue -Object $entry -Name "from" -Default "")
            $source = $(if ($from) { $from } else { $name })
            throw "Required environment value '$source' for vibecoding1c MCP server '$serverId' was not found."
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values[$name] = $value
        }
    }
    if ($serverNeedsEmbedding -and $null -ne $embeddingSettings -and $embeddingSettings.mode -eq "cpu") {
        $values["EMBEDDING_MODEL"] = [string]$embeddingSettings.model
    }
    Set-GraphOpenAiFallbackEnv -Config $Config -Server $Server -Values $values
    return $values
}

function Resolve-ServerVolumes {
    param(
        [object]$Config,
        [object]$Server,
        [object]$ConfigState = $null
    )
    $volumes = @()
    $localValues = Get-HostLocalValues -Config $Config -ConfigState $ConfigState
    $volumeEntries = @(As-Array (Get-ObjectValue -Object $Server -Name "volumes" -Default @())) + @(Get-HostDefaultVolumeEntries -Server $Server)
    if ((Test-HostServerNeedsEmbedding -Server $Server) -and (Get-HostEmbeddingSettings -Config $Config).mode -eq "cpu") {
        $volumeEntries += [ordered]@{ from = "PATH_MODEL_CACHE"; to = "/app/model_cache"; required = $false }
    }
    foreach ($entry in $volumeEntries) {
        $from = [string](Get-ObjectValue -Object $entry -Name "from" -Default "")
        $to = [string](Get-ObjectValue -Object $entry -Name "to" -Default "")
        if (-not $from -or -not $to) { continue }
        $hostPath = ""
        if ($localValues.Contains($from)) {
            $hostPath = [string]$localValues[$from]
        }
        $subdir = [string](Get-ObjectValue -Object $entry -Name "subdir" -Default "")
        if ($hostPath -and $subdir) {
            $hostPath = Join-Path $hostPath $subdir
        }
        if ([bool](Get-ObjectValue -Object $entry -Name "required" -Default $false) -and [string]::IsNullOrWhiteSpace($hostPath)) {
            $serverId = [string](Get-ObjectValue -Object $Server -Name "id" -Default "<unknown>")
            throw "Required volume source '$from' for vibecoding1c MCP server '$serverId' was not found."
        }
        if ($hostPath) {
            if (-not (Test-Path -LiteralPath $hostPath -PathType Container)) {
                if ([bool](Get-ObjectValue -Object $entry -Name "required" -Default $false)) {
                    $serverId = [string](Get-ObjectValue -Object $Server -Name "id" -Default "<unknown>")
                    throw "Required volume path for '$from' on vibecoding1c MCP server '$serverId' was not found: $hostPath"
                }
                if ($from -eq "PATH_BASES" -or $from -eq "PATH_METADATA" -or $from -eq "PATH_MODEL_CACHE") {
                    New-Item -ItemType Directory -Force -Path $hostPath | Out-Null
                } else {
                    continue
                }
            }
            $volumes += [pscustomobject]@{ host = $hostPath; container = $to }
        }
    }
    return $volumes
}

function Start-DockerServer {
    param(
        [object]$Config,
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigState = $null
    )
    $containerName = [string]$Runtime.containerName
    $existing = Invoke-DockerCommandCapture -Arguments @("ps", "-a", "--filter", "name=^/$containerName$", "--format", "{{.Names}}") -TimeoutSec 60 -Description "docker ps for $containerName"
    if ($existing -contains $containerName) {
        Write-Host "Starting existing container: $containerName"
        if (-not $DryRun) {
            Invoke-DockerCommandChecked -Arguments @("start", $containerName) -TimeoutSec 120 -Description "docker start $containerName"
        }
        return
    }
    $envValues = Resolve-ServerEnv -Config $Config -Server $Server -ConfigState $ConfigState
    $volumes = Resolve-ServerVolumes -Config $Config -Server $Server -ConfigState $ConfigState
    $args = @("run", "-d", "--name", $containerName, "-p", "$($Runtime.hostPort):$($Runtime.internalPort)")
    foreach ($key in @($envValues.Keys | Sort-Object)) {
        $args += @("-e", "$key=$($envValues[$key])")
    }
    foreach ($volume in $volumes) {
        $args += @("-v", "$($volume.host):$($volume.container)")
    }
    $args += $Runtime.image
    Write-Host "Starting container: $containerName -> $($Runtime.url)"
    if (-not $DryRun) {
        Ensure-DockerImageAvailable -Image ([string]$Runtime.image)
        Invoke-DockerCommandChecked -Arguments $args -TimeoutSec 180 -Description "docker run $containerName"
    }
}

function Start-ComposeServer {
    param(
        [object]$Config,
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigState
    )
    $distributionRoot = Get-DistributionRoot -Config $Config
    $sourceCompose = Join-Path $distributionRoot ([string](Get-ObjectValue -Object $Server -Name "composePath" -Default ""))
    if (-not (Test-Path -LiteralPath $sourceCompose -PathType Leaf)) {
        throw "Compose file was not found: $sourceCompose"
    }
    $runtimeDir = Join-Path (Join-Path (Get-ConfigWorkRoot -Config $Config -ConfigId $ConfigState.configId) "runtime") $Runtime.name
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $targetCompose = Join-Path $runtimeDir "docker-compose.yml"
    $composeText = Read-Text -Path $sourceCompose
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*neo4j\s*$', "    container_name: $($Runtime.containerName)-neo4j"
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*1c_graph_metadata\s*$', "    container_name: $($Runtime.containerName)"
    $composeText = [regex]::Replace($composeText, '(?ms)^    ports:\r?\n      - "7474:7474"\r?\n      - "7687:7687"\r?\n', '')
    $composeText = $composeText -replace '"8006:8006"', "`"$($Runtime.hostPort):$($Runtime.internalPort)`""
    Write-Text -Path $targetCompose -Value $composeText
    Write-DotEnv -Path (Join-Path $runtimeDir ".env") -Values (Resolve-ServerEnv -Config $Config -Server $Server -ConfigState $ConfigState)
    Write-Host "Starting compose project: $($Runtime.composeProject) -> $($Runtime.url)"
    if (-not $DryRun) {
        Invoke-DockerCommandChecked -Arguments @("compose", "-p", $Runtime.composeProject, "-f", $targetCompose, "--env-file", (Join-Path $runtimeDir ".env"), "up", "-d") -TimeoutSec 240 -Description "docker compose up $($Runtime.composeProject)"
    }
    $Runtime | Add-Member -NotePropertyName runtimePath -NotePropertyValue $runtimeDir -Force
}

function Expand-Template {
    param(
        [string]$Template,
        [string]$ConfigId,
        [string]$ServerId
    )
    return $Template.Replace("{projectSlug}", $ConfigId).Replace("{branchSlug}", "").Replace("{serverId}", $ServerId)
}

function New-ServerRuntime {
    param(
        [object]$Config,
        [object]$Server,
        [int]$Index,
        [object]$ConfigState = $null,
        [int]$ConfigIndex = 0
    )
    $scope = Get-ServerScope -Server $Server
    $id = [string](Get-ObjectValue -Object $Server -Name "id" -Default "")
    $configId = $(if ($ConfigState) { $ConfigState.configId } else { "" })
    $hostId = [string](Get-ObjectValue -Object $Config -Name "hostId" -Default "vibecoding1c-mcp-host")
    $nameTemplate = [string](Get-ObjectValue -Object $Server -Name "mcpNameTemplate" -Default "itl-$id")
    $containerTemplate = [string](Get-ObjectValue -Object $Server -Name "containerNameTemplate" -Default $nameTemplate)
    $name = if ($scope -eq "global") { Expand-Template -Template $nameTemplate -ConfigId $hostId -ServerId $id } else { Expand-Template -Template $nameTemplate -ConfigId $configId -ServerId $id }
    $containerName = if ($scope -eq "global") { Expand-Template -Template $containerTemplate -ConfigId $hostId -ServerId $id } else { Expand-Template -Template $containerTemplate -ConfigId $configId -ServerId $id }
    $internalPort = [int](Get-ObjectValue -Object $Server -Name "internalPort" -Default 0)
    $hostPort = Get-HostPort -Config $Config -Scope $scope -Index $Index -ConfigIndex $ConfigIndex
    $baseUrl = ([string](Get-ObjectValue -Object $Config -Name "baseUrl" -Default "http://localhost")).TrimEnd("/")
    $imageTag = [string](Get-ObjectValue -Object $Config -Name "imageTag" -Default "latest")
    $image = ([string](Get-ObjectValue -Object $Server -Name "image" -Default "")).Replace("{imageTag}", $imageTag)
    $composeProjectTemplate = [string](Get-ObjectValue -Object $Server -Name "composeProjectTemplate" -Default $name)
    $embeddingSettings = $null
    if (Test-HostServerNeedsEmbedding -Server $Server) {
        $embeddingSettings = Get-HostEmbeddingSettings -Config $Config
    }
    $localValues = Get-HostLocalValues -Config $Config -ConfigState $ConfigState
    return [pscustomobject]@{
        id = $id
        scope = $scope
        family = "vibecoding1c"
        provider = "remote"
        hostId = $hostId
        configId = $configId
        name = $name
        containerName = $containerName
        composeProject = (Expand-Template -Template $composeProjectTemplate -ConfigId $configId -ServerId $id)
        image = $image
        internalPort = $internalPort
        hostPort = $hostPort
        url = "$baseUrl`:$hostPort/mcp"
        health = "unknown"
        platformVersion = $(if ($id -eq "docs") { [string]$localValues["HELP_PLATFORM_VERSION"] } else { "" })
        bspVersion = $(if ($id -eq "ssl") { [string]$localValues["BSP_VERSION"] } else { "" })
        configurationName = $(if ($ConfigState) { [string](Get-ObjectValue -Object $ConfigState -Name "configurationName" -Default "") } else { "" })
        configurationVersion = $(if ($ConfigState) { [string](Get-ObjectValue -Object $ConfigState -Name "configurationVersion" -Default "") } else { "" })
        embeddingMode = $(if ($null -ne $embeddingSettings) { [string]$embeddingSettings.mode } else { "" })
        embeddingModel = $(if ($null -ne $embeddingSettings) { [string]$embeddingSettings.model } else { "" })
        sourceCommit = $(if ($ConfigState) { $ConfigState.sourceCommit } else { "" })
        sourceFingerprint = $(if ($ConfigState) { $ConfigState.sourceFingerprint } else { "" })
        reportHash = $(if ($ConfigState) { $ConfigState.reportHash } else { "" })
        indexedAt = $(if ($ConfigState) { $ConfigState.indexedAt } else { "" })
    }
}

function Start-HostServers {
    param([object]$Config)
    Ensure-HostPrerequisites -Config $Config
    Ensure-Distribution -Config $Config
    $manifest = Read-DistributionManifest -Config $Config
    $globalIds = Get-EnabledServerIds -Config $Config -Scope "global"
    $projectIds = Get-EnabledServerIds -Config $Config -Scope "project"
    Ensure-HostEmbeddingModel -Config $Config -Manifest $manifest -GlobalServerIds $globalIds -ProjectServerIds $projectIds
    $configStates = @()
    $serverStates = @()

    $globalIndex = 0
    foreach ($server in As-Array (Get-ObjectValue -Object $manifest -Name "servers" -Default @())) {
        $id = [string](Get-ObjectValue -Object $server -Name "id" -Default "")
        $scope = Get-ServerScope -Server $server
        if ($scope -ne "global" -or $globalIds -notcontains $id) { continue }
        $runtime = New-ServerRuntime -Config $Config -Server $server -Index $globalIndex
        Start-DockerServer -Config $Config -Server $server -Runtime $runtime
        $runtime.health = "running"
        $serverStates += $runtime
        $globalIndex++
    }

    $configIndex = 0
    foreach ($configuration in As-Array (Get-ObjectValue -Object $Config -Name "configurations" -Default @())) {
        if ($ConfigId -and [string](Get-ObjectValue -Object $configuration -Name "configId" -Default "") -ne $ConfigId) {
            continue
        }
        $configState = Refresh-Configuration -Config $Config -Configuration $configuration
        $configStates += $configState
        $projectIndex = 0
        foreach ($server in As-Array (Get-ObjectValue -Object $manifest -Name "servers" -Default @())) {
            $id = [string](Get-ObjectValue -Object $server -Name "id" -Default "")
            $scope = Get-ServerScope -Server $server
            if ($scope -ne "project" -or $projectIds -notcontains $id) { continue }
            $runtime = New-ServerRuntime -Config $Config -Server $server -Index $projectIndex -ConfigState $configState -ConfigIndex $configIndex
            if ([bool](Get-ObjectValue -Object $server -Name "compose" -Default $false)) {
                Start-ComposeServer -Config $Config -Server $server -Runtime $runtime -ConfigState $configState
            } else {
                Start-DockerServer -Config $Config -Server $server -Runtime $runtime -ConfigState $configState
            }
            $runtime.health = "running"
            $serverStates += $runtime
            $projectIndex++
        }
        $configIndex++
    }

    $state = [ordered]@{
        schemaVersion = 1
        updatedAt = (Get-Date).ToString("o")
        configurations = $configStates
        servers = $serverStates
    }
    Write-HostState -Config $Config -State $state
}

function Stop-HostServers {
    param([object]$Config)
    $state = Read-HostState -Config $Config
    foreach ($server in As-Array (Get-ObjectValue -Object $state -Name "servers" -Default @())) {
        $composeProject = [string](Get-ObjectValue -Object $server -Name "composeProject" -Default "")
        $runtimePath = [string](Get-ObjectValue -Object $server -Name "runtimePath" -Default "")
        $containerName = [string](Get-ObjectValue -Object $server -Name "containerName" -Default "")
        if ($composeProject -and $runtimePath -and (Test-Path -LiteralPath (Join-Path $runtimePath "docker-compose.yml") -PathType Leaf)) {
            Write-Host "Stopping compose project: $composeProject"
            if (-not $DryRun) {
                Invoke-DockerCommandChecked -Arguments @("compose", "-p", $composeProject, "-f", (Join-Path $runtimePath "docker-compose.yml"), "--env-file", (Join-Path $runtimePath ".env"), "down") -TimeoutSec 180 -Description "docker compose down $composeProject"
            }
        } elseif ($containerName) {
            Write-Host "Stopping container: $containerName"
            if (-not $DryRun) {
                Invoke-DockerCommandChecked -Arguments @("stop", $containerName) -TimeoutSec 120 -Description "docker stop $containerName"
            }
        }
    }
}

function Get-HostId {
    param([object]$Config)
    $hostId = [string](Get-ObjectValue -Object $Config -Name "hostId" -Default "")
    if ([string]::IsNullOrWhiteSpace($hostId)) {
        return "vibecoding1c-mcp-host"
    }
    return $hostId
}

function ConvertTo-RegistryConfigurations {
    param(
        [object]$State,
        [string]$HostId,
        [string]$PublishedAt
    )
    $configurations = @()
    foreach ($configuration in As-Array (Get-ObjectValue -Object $State -Name "configurations" -Default @())) {
        $configurations += [ordered]@{
            hostId = $HostId
            hostPublishedAt = $PublishedAt
            publishedAt = $PublishedAt
            configId = [string](Get-ObjectValue -Object $configuration -Name "configId" -Default "")
            title = [string](Get-ObjectValue -Object $configuration -Name "title" -Default "")
            configurationName = [string](Get-ObjectValue -Object $configuration -Name "configurationName" -Default "")
            configurationVersion = [string](Get-ObjectValue -Object $configuration -Name "configurationVersion" -Default "")
            source = [string](Get-ObjectValue -Object $configuration -Name "source" -Default "")
            sourceCommit = [string](Get-ObjectValue -Object $configuration -Name "sourceCommit" -Default "")
            sourceFingerprint = [string](Get-ObjectValue -Object $configuration -Name "sourceFingerprint" -Default "")
            reportHash = [string](Get-ObjectValue -Object $configuration -Name "reportHash" -Default "")
            indexedAt = [string](Get-ObjectValue -Object $configuration -Name "indexedAt" -Default "")
        }
    }
    return @($configurations)
}

function ConvertTo-RegistryServers {
    param(
        [object]$State,
        [string]$HostId,
        [string]$PublishedAt
    )
    $servers = @()
    foreach ($server in As-Array (Get-ObjectValue -Object $State -Name "servers" -Default @())) {
        $servers += [ordered]@{
            hostId = $HostId
            hostPublishedAt = $PublishedAt
            publishedAt = $PublishedAt
            id = [string](Get-ObjectValue -Object $server -Name "id" -Default "")
            scope = [string](Get-ObjectValue -Object $server -Name "scope" -Default "")
            family = "vibecoding1c"
            provider = "remote"
            configId = [string](Get-ObjectValue -Object $server -Name "configId" -Default "")
            name = [string](Get-ObjectValue -Object $server -Name "name" -Default "")
            url = [string](Get-ObjectValue -Object $server -Name "url" -Default "")
            health = [string](Get-ObjectValue -Object $server -Name "health" -Default "unknown")
            image = [string](Get-ObjectValue -Object $server -Name "image" -Default "")
            platformVersion = [string](Get-ObjectValue -Object $server -Name "platformVersion" -Default "")
            bspVersion = [string](Get-ObjectValue -Object $server -Name "bspVersion" -Default "")
            configurationName = [string](Get-ObjectValue -Object $server -Name "configurationName" -Default "")
            configurationVersion = [string](Get-ObjectValue -Object $server -Name "configurationVersion" -Default "")
            embeddingMode = [string](Get-ObjectValue -Object $server -Name "embeddingMode" -Default "")
            embeddingModel = [string](Get-ObjectValue -Object $server -Name "embeddingModel" -Default "")
            sourceCommit = [string](Get-ObjectValue -Object $server -Name "sourceCommit" -Default "")
            sourceFingerprint = [string](Get-ObjectValue -Object $server -Name "sourceFingerprint" -Default "")
            reportHash = [string](Get-ObjectValue -Object $server -Name "reportHash" -Default "")
            indexedAt = [string](Get-ObjectValue -Object $server -Name "indexedAt" -Default "")
        }
    }
    return @($servers)
}

function New-CurrentHostRegistryEntry {
    param(
        [object]$Config,
        [object]$State,
        [string]$PublishedAt
    )
    $hostId = Get-HostId -Config $Config
    return [ordered]@{
        hostId = $hostId
        baseUrl = [string](Get-ObjectValue -Object $Config -Name "baseUrl" -Default "")
        publishedAt = $PublishedAt
        configurations = (ConvertTo-RegistryConfigurations -State $State -HostId $hostId -PublishedAt $PublishedAt)
        servers = (ConvertTo-RegistryServers -State $State -HostId $hostId -PublishedAt $PublishedAt)
    }
}

function Read-RegistryPayload {
    param([string]$RegistryPath)
    if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
        return (Read-JsonFile -Path $RegistryPath)
    }
    return [pscustomobject]@{
        schemaVersion = 2
        publishedAt = ""
        hosts = @()
        configurations = @()
        servers = @()
    }
}

function Get-RegistryHostEntries {
    param([object]$Payload)
    $hosts = @(As-Array (Get-ObjectValue -Object $Payload -Name "hosts" -Default @()))
    if ($hosts.Count -gt 0) {
        return @($hosts)
    }

    $hostInfo = Get-ObjectValue -Object $Payload -Name "host" -Default $null
    $publishedAt = [string](Get-ObjectValue -Object $Payload -Name "publishedAt" -Default "")
    $hostId = [string](Get-ObjectValue -Object $hostInfo -Name "hostId" -Default "legacy-host")
    $baseUrl = [string](Get-ObjectValue -Object $hostInfo -Name "baseUrl" -Default "")
    $configurations = @(As-Array (Get-ObjectValue -Object $Payload -Name "configurations" -Default @()))
    $servers = @(As-Array (Get-ObjectValue -Object $Payload -Name "servers" -Default @()))
    if ($configurations.Count -eq 0 -and $servers.Count -eq 0 -and -not $baseUrl) {
        return @()
    }
    return @([pscustomobject]@{
        hostId = $hostId
        baseUrl = $baseUrl
        publishedAt = $publishedAt
        configurations = $configurations
        servers = $servers
    })
}

function Copy-RegistryChildWithHostMetadata {
    param(
        [object]$Child,
        [object]$HostEntry
    )
    $hash = Convert-ToHash -Object $Child
    $hostId = [string](Get-ObjectValue -Object $HostEntry -Name "hostId" -Default "")
    $publishedAt = [string](Get-ObjectValue -Object $HostEntry -Name "publishedAt" -Default "")
    $baseUrl = [string](Get-ObjectValue -Object $HostEntry -Name "baseUrl" -Default "")
    if (-not $hash.Contains("hostId") -or -not $hash["hostId"]) { $hash["hostId"] = $hostId }
    if (-not $hash.Contains("hostPublishedAt") -or -not $hash["hostPublishedAt"]) { $hash["hostPublishedAt"] = $publishedAt }
    if (-not $hash.Contains("publishedAt") -or -not $hash["publishedAt"]) { $hash["publishedAt"] = $publishedAt }
    if (-not $hash.Contains("hostBaseUrl") -or -not $hash["hostBaseUrl"]) { $hash["hostBaseUrl"] = $baseUrl }
    return [pscustomobject]$hash
}

function New-RegistryPayload {
    param(
        [object[]]$Hosts,
        [string]$PublishedAt
    )
    $normalizedHosts = @()
    $configurations = @()
    $servers = @()
    foreach ($hostEntry in @($Hosts)) {
        $hostHash = Convert-ToHash -Object $hostEntry
        if (-not $hostHash.Contains("configurations")) { $hostHash["configurations"] = @() }
        if (-not $hostHash.Contains("servers")) { $hostHash["servers"] = @() }
        $normalizedHosts += [pscustomobject]$hostHash
        foreach ($configuration in As-Array $hostHash["configurations"]) {
            $configurations += Copy-RegistryChildWithHostMetadata -Child $configuration -HostEntry $hostHash
        }
        foreach ($server in As-Array $hostHash["servers"]) {
            $servers += Copy-RegistryChildWithHostMetadata -Child $server -HostEntry $hostHash
        }
    }
    return [ordered]@{
        schemaVersion = 2
        publishedAt = $PublishedAt
        hosts = $normalizedHosts
        configurations = $configurations
        servers = $servers
    }
}

function Write-MergedRegistryPayload {
    param(
        [object]$Config,
        [string]$RegistryPath,
        [string]$PublishedAt
    )
    $state = Read-HostState -Config $Config
    $hostId = Get-HostId -Config $Config
    $currentPayload = Read-RegistryPayload -RegistryPath $RegistryPath
    $hosts = @()
    foreach ($hostEntry in Get-RegistryHostEntries -Payload $currentPayload) {
        $entryHostId = [string](Get-ObjectValue -Object $hostEntry -Name "hostId" -Default "")
        if ($entryHostId -and $entryHostId -ne $hostId) {
            $hosts += $hostEntry
        }
    }
    $hosts += (New-CurrentHostRegistryEntry -Config $Config -State $state -PublishedAt $PublishedAt)
    Write-JsonFile -Path $RegistryPath -Value (New-RegistryPayload -Hosts $hosts -PublishedAt $PublishedAt)
}

function Publish-Registry {
    param([object]$Config)
    $registryRepo = [string](Get-ObjectValue -Object $Config -Name "registryRepo" -Default "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git")
    $registryRoot = Get-RegistryRoot -Config $Config
    Ensure-GitCheckout -Repo $registryRepo -Path $registryRoot
    $registryPath = Join-Path $registryRoot "registry.json"
    $publishedAt = (Get-Date).ToString("o")
    for ($attempt = 0; $attempt -le 1; $attempt++) {
        Write-MergedRegistryPayload -Config $Config -RegistryPath $registryPath -PublishedAt $publishedAt
        Write-Host "Registry written: $registryPath"
        if ($DryRun) {
            return
        }
        Invoke-Git -Root $registryRoot -Arguments @("add", "registry.json")
        $status = ((& git -C $registryRoot status --porcelain) -join "`n")
        if ($status) {
            Invoke-Git -Root $registryRoot -Arguments @("commit", "-m", "publish vibecoding1c MCP registry")
        } else {
            Write-Host "Registry unchanged."
        }
        try {
            Invoke-Git -Root $registryRoot -Arguments @("push")
            return
        } catch {
            if ($attempt -ge 1) {
                throw
            }
            Write-Host "Registry push failed; rebasing once and retrying publish."
            Invoke-Git -Root $registryRoot -Arguments @("pull", "--rebase")
        }
    }
}

function Show-HostStatus {
    param([object]$Config)
    $state = Read-HostState -Config $Config
    Write-Host "Host: $(Get-ObjectValue -Object $Config -Name 'hostId' -Default '<unknown>')"
    Write-Host "Base URL: $(Get-ObjectValue -Object $Config -Name 'baseUrl' -Default '<unknown>')"
    Write-Host "State root: $(Get-StateRoot -Config $Config)"
    Write-Host "Configurations: $(@(As-Array (Get-ObjectValue -Object $state -Name 'configurations' -Default @())).Count)"
    Write-Host "Servers:"
    foreach ($server in As-Array (Get-ObjectValue -Object $state -Name "servers" -Default @())) {
        Write-Host "  $(Get-ObjectValue -Object $server -Name 'name' -Default '<unknown>') [$(Get-ObjectValue -Object $server -Name 'scope' -Default '')] $(Get-ObjectValue -Object $server -Name 'url' -Default '') health=$(Get-ObjectValue -Object $server -Name 'health' -Default 'unknown') configId=$(Get-ObjectValue -Object $server -Name 'configId' -Default '') indexedAt=$(Get-ObjectValue -Object $server -Name 'indexedAt' -Default '')"
    }
}

$config = Read-HostConfig
switch ($Action) {
    "setup" {
        Start-HostServers -Config $config
        Publish-Registry -Config $config
        Show-HostStatus -Config $config
    }
    "start" {
        Start-HostServers -Config $config
        Show-HostStatus -Config $config
    }
    "stop" {
        Stop-HostServers -Config $config
    }
    "status" {
        Show-HostStatus -Config $config
    }
    "refresh-config" {
        Refresh-HostConfigurations -Config $config -TargetConfigId $ConfigId | Out-Null
    }
    "publish" {
        Publish-Registry -Config $config
    }
    "dump-config" {
        Invoke-HostConfigDumpHelper -ResolvedConfigPath $ConfigPath -TargetConfigId $ConfigId
        Refresh-HostConfigurations -Config $config -TargetConfigId $ConfigId | Out-Null
    }
}
