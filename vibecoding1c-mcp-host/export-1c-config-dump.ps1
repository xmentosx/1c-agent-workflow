[CmdletBinding()]
param(
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

function Read-Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Read-JsonFile {
    param([string]$Path)
    return (Read-Text -Path $Path | ConvertFrom-Json)
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

function Require-Value {
    param(
        [string]$Name,
        [AllowNull()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }
    return $Value
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

function Get-StateRoot {
    param([object]$Config)
    return (Get-FullPath ([string](Get-ObjectValue -Object $Config -Name "stateRoot" -Default "D:/ITL/MCP")))
}

function Get-ConfigWorkRoot {
    param(
        [object]$Config,
        [string]$ConfigId
    )
    return (Join-Path (Join-Path (Get-StateRoot -Config $Config) "configs") $ConfigId)
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
    return $trimmed
}

function ConvertTo-NativeEmptyStringArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return '""'
    }
    if ($Value.Length -eq 0) {
        return '""'
    }
    return $Value
}

function ConvertTo-NativeCommandLineArgument {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument.Length -eq 0) {
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

function Resolve-PlatformExecutablePath {
    param([string]$Path)
    if (-not $Path) {
        return $Path
    }
    $resolvedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (Test-Path -LiteralPath $resolvedPath -PathType Container -ErrorAction SilentlyContinue) {
        return (Join-Path $resolvedPath "1cv8.exe")
    }
    return $resolvedPath
}

function Resolve-InfoBasePath {
    param([string]$Path)
    return Get-FullPath $Path
}

function Assert-InfoBaseAvailable {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$SettingName = "infobase path"
    )
    if ($Kind -eq "file") {
        $resolvedPath = Resolve-InfoBasePath $Path
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "File infobase directory was not found: $resolvedPath. Check $SettingName."
        }
        $dbFile = Join-Path $resolvedPath "1Cv8.1CD"
        if (-not (Test-Path -LiteralPath $dbFile -PathType Leaf)) {
            throw "File infobase database file was not found: $dbFile. Check $SettingName."
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

function New-RepositoryConnectionArgs {
    param([object]$Dump)
    $repositoryPath = Require-Value "configuration.dump.repositoryPath" ([string](Get-ObjectValue -Object $Dump -Name "repositoryPath" -Default ""))
    $repositoryUser = Require-Value "configuration.dump.repositoryUser" ([string](Get-ObjectValue -Object $Dump -Name "repositoryUser" -Default ""))
    $repositoryPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-ObjectValue -Object $Dump -Name "repositoryPassword" -Default ""))
    return @(
        "/ConfigurationRepositoryF", $repositoryPath,
        "/ConfigurationRepositoryN", $repositoryUser,
        "/ConfigurationRepositoryP", (ConvertTo-NativeEmptyStringArgument $repositoryPassword)
    )
}

function Get-SourceInfoBasePath {
    param([object]$Dump)
    $kind = [string](Get-ObjectValue -Object $Dump -Name "infoBaseKind" -Default "file")
    if ($kind -eq "server") {
        $legacyValue = [string](Get-ObjectValue -Object $Dump -Name "sourceInfoBasePath" -Default "")
        if ($legacyValue) {
            return $legacyValue
        }
        $serverName = Require-Value "configuration.dump.sourceServerName" ([string](Get-ObjectValue -Object $Dump -Name "sourceServerName" -Default ""))
        $infoBaseName = Require-Value "configuration.dump.sourceInfoBaseName" ([string](Get-ObjectValue -Object $Dump -Name "sourceInfoBaseName" -Default ""))
        return "Srvr=`"$serverName`";Ref=`"$infoBaseName`";"
    }
    return Require-Value "configuration.dump.sourceInfoBasePath" ([string](Get-ObjectValue -Object $Dump -Name "sourceInfoBasePath" -Default ""))
}

function Get-DumpOutputPath {
    param(
        [object]$Config,
        [object]$Configuration,
        [object]$Dump,
        [string]$ConfigId
    )
    $outputPath = [string](Get-ObjectValue -Object $Dump -Name "outputPath" -Default "")
    if ($outputPath) {
        return Get-FullPath $outputPath
    }
    $sourcePath = [string](Get-ObjectValue -Object $Configuration -Name "sourcePath" -Default "")
    if (-not $sourcePath) {
        throw "Configuration '$ConfigId' dump-config requires configuration.sourcePath or configuration.dump.outputPath."
    }
    $mainConfigPath = [string](Get-ObjectValue -Object $Configuration -Name "mainConfigPath" -Default "src/cf")
    return Get-ConfigSubPath -Root (Get-FullPath $sourcePath) -RelativePath $mainConfigPath
}

function Invoke-NativeProcessAndWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )
    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -PassThru
    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }
    $process.WaitForExit()
    return $process.ExitCode
}

function Invoke-Designer {
    param(
        [object]$Config,
        [object]$Configuration,
        [object]$Dump,
        [string[]]$DesignerArgs,
        [string]$LogPrefix
    )
    $help = Get-ObjectValue -Object $Config -Name "helpSearchServer" -Default $null
    $platformPath = [string](Get-ObjectValue -Object $Dump -Name "platformPath" -Default "")
    if (-not $platformPath) {
        $platformPath = [string](Get-ObjectValue -Object $Config -Name "platformPath" -Default "")
    }
    if (-not $platformPath) {
        $platformPath = [string](Get-ObjectValue -Object $help -Name "platformBinPath" -Default "")
    }
    $platformPath = Resolve-PlatformExecutablePath -Path (Require-Value "configuration.dump.platformPath or helpSearchServer.platformBinPath" $platformPath)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $platformPath -PathType Leaf)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    $kind = [string](Get-ObjectValue -Object $Dump -Name "infoBaseKind" -Default "file")
    $infoBasePath = Get-SourceInfoBasePath -Dump $Dump
    if (-not $DryRun) {
        Assert-InfoBaseAvailable -Kind $kind -Path $infoBasePath -SettingName "configuration.dump source infobase"
    }

    $configId = [string](Get-ObjectValue -Object $Configuration -Name "configId" -Default "")
    $logsPath = [string](Get-ObjectValue -Object $Dump -Name "logsPath" -Default "")
    if (-not $logsPath) {
        $logsPath = Join-Path (Get-ConfigWorkRoot -Config $Config -ConfigId $configId) "logs"
    }
    $logsPath = Get-FullPath $logsPath
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix $LogPrefix -Extension ".log"
    $user = [string](Get-ObjectValue -Object $Dump -Name "ibUser" -Default "")
    $password = [string](Get-ObjectValue -Object $Dump -Name "ibPassword" -Default "")
    $ibArgs = New-InfobaseArgs -Kind $kind -Path $infoBasePath -User $user -Password $password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $DesignerArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"
    if ($DryRun) {
        return $logPath
    }
    $exitCode = Invoke-NativeProcessAndWait -FilePath $platformPath -Arguments $args -WorkingDirectory $PSScriptRoot
    if ($exitCode -ne 0) {
        throw "1C Designer failed with exit code $exitCode. Log: $logPath"
    }
    return $logPath
}

function Invoke-ConfigurationDump {
    param(
        [object]$Config,
        [object]$Configuration
    )
    $configId = [string](Get-ObjectValue -Object $Configuration -Name "configId" -Default "")
    if (-not $configId) {
        throw "Configuration entry has no configId."
    }
    $dump = Get-ObjectValue -Object $Configuration -Name "dump" -Default $null
    if ($null -eq $dump) {
        if ($ConfigId) {
            throw "Configuration '$configId' has no dump settings."
        }
        Write-Host "Skipping configuration without dump settings: $configId"
        return $false
    }

    Write-Host "Dumping 1C configuration: $configId"
    $repositoryArgs = New-RepositoryConnectionArgs -Dump $dump
    $updateArgs = $repositoryArgs + @(
        "/ConfigurationRepositoryUpdateCfg", "-force",
        "/UpdateDBCfg"
    )
    Invoke-Designer -Config $Config -Configuration $Configuration -Dump $dump -DesignerArgs $updateArgs -LogPrefix "1c-repository-update-" | Out-Null

    $outputPath = Get-DumpOutputPath -Config $Config -Configuration $Configuration -Dump $dump -ConfigId $configId
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    $dumpInfoPath = Join-Path $outputPath "ConfigDumpInfo.xml"
    $children = @(Get-ChildItem -LiteralPath $outputPath -Force)
    $isIncremental = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
    $dumpArgs = $repositoryArgs + @("/DumpConfigToFiles", $outputPath, "-Format", "Hierarchical")
    if ($isIncremental) {
        $dumpArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Export path '$outputPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping config files."
    }

    Invoke-Designer -Config $Config -Configuration $Configuration -Dump $dump -DesignerArgs $dumpArgs -LogPrefix "1c-dump-config-" | Out-Null
    if (-not $DryRun -and -not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "1C configuration dump did not create ConfigDumpInfo.xml in '$outputPath'."
    }
    Write-Host "Configuration dump path: $outputPath"
    return $true
}

$resolvedConfigPath = Get-FullPath $ConfigPath
if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
    throw "Host config was not found: $resolvedConfigPath. Copy host.config.example.json to host.config.json first."
}
$config = Read-JsonFile -Path $resolvedConfigPath
$matched = 0
$dumped = 0
foreach ($configuration in As-Array (Get-ObjectValue -Object $config -Name "configurations" -Default @())) {
    $currentConfigId = [string](Get-ObjectValue -Object $configuration -Name "configId" -Default "")
    if ($ConfigId -and $currentConfigId -ne $ConfigId) {
        continue
    }
    $matched++
    if (Invoke-ConfigurationDump -Config $config -Configuration $configuration) {
        $dumped++
    }
}
if ($matched -eq 0) {
    throw "No configurations matched ConfigId '$ConfigId'."
}
if ($dumped -eq 0) {
    throw "No configuration dumps were executed. Add configuration.dump settings or pass a ConfigId with dump settings."
}
