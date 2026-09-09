# User-local, pinned Python. This module never edits PATH, registry, or 1C settings.
$itlPythonLib = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../1c-workflow/scripts/lib'))
if (-not (Get-Command Get-ItlSharedArtifactDirectory -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $itlPythonLib 'agent-1c.core.ps1')
    . (Join-Path $itlPythonLib 'agent-1c.runtime-values.ps1')
}
if (-not (Get-Command Invoke-ItlImmutableFileAcquire -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $itlPythonLib 'agent-1c.immutable-download.ps1')
}
function Read-ItlPythonRuntimeManifest {
    param([string]$AssetRoot = (Join-Path $PSScriptRoot '../assets/python-runtime'))
    $manifest = Get-Content -LiteralPath (Join-Path $AssetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -notmatch '^3\.\d+\.\d+$' -or
        $manifest.platform -cne 'windows-amd64' -or $manifest.sha256 -notmatch '^[a-f0-9]{64}$' -or
        $manifest.payload -cne 'payload.json' -or $manifest.executable -cne 'python.exe' -or
        $manifest.archivePrefix -cne 'tools/' -or $manifest.package -notmatch '^python\.[0-9.]+\.nupkg$') {
        throw 'ITL_PYTHON_RUNTIME_MANIFEST_INVALID'
    }
    $payloadPath = Join-Path $AssetRoot $manifest.payload
    if ((Get-ItlImmutableFileSha256 -Path $payloadPath) -cne $manifest.payloadSha256) {
        throw 'ITL_PYTHON_RUNTIME_PAYLOAD_MANIFEST_HASH_MISMATCH'
    }
    $payload = Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $files = @{}
    foreach ($property in $payload.files.PSObject.Properties) {
        if ($property.Name -match '(^/|\\|:|(^|/)\.\.(/|$))' -or
            $property.Value.sha256 -notmatch '^[a-f0-9]{64}$' -or $property.Value.bytes -lt 0 -or $files.ContainsKey($property.Name)) {
            throw 'ITL_PYTHON_RUNTIME_PAYLOAD_MANIFEST_INVALID'
        }
        $files[$property.Name] = $property.Value
    }
    if ($payload.schemaVersion -ne 1 -or -not $files.ContainsKey('python.exe') -or -not $files.ContainsKey('LICENSE.txt')) {
        throw 'ITL_PYTHON_RUNTIME_PAYLOAD_MANIFEST_INVALID'
    }
    [pscustomobject]@{ manifest = $manifest; files = $files; assetRoot = $AssetRoot }
}

function Test-ItlPythonRuntimePayload {
    param([string]$Root, [object]$Definition)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    if ((Get-Item -LiteralPath $Root).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    $files = [Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $files.Add($item) }
        }
    }
    if ($files.Count -ne $Definition.files.Count) { return $false }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        if (-not $Definition.files.ContainsKey($relative)) { return $false }
        $expected = $Definition.files[$relative]
        if ($file.Length -ne $expected.bytes -or
            (Get-ItlImmutableFileSha256 -Path $file.FullName) -cne $expected.sha256) { return $false }
    }
    return $true
}

function Get-ItlPythonRuntimeProbe {
    param([Parameter(Mandatory = $true)][string]$Executable)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-B', '-I', '-X', 'utf8', '-c',
        'import ctypes,hashlib,json,socket,ssl,sys,threading; print(json.dumps({"version":".".join(map(str,sys.version_info[:3])),"executable":sys.executable}))')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'ITL_PYTHON_RUNTIME_START_FAILED' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw 'ITL_PYTHON_RUNTIME_PROBE_TIMEOUT'
        }
        if ($process.ExitCode -ne 0) { throw 'ITL_PYTHON_RUNTIME_PROBE_FAILED' }
        $probe = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
        if ([version]$probe.version -lt [version]'3.11') { throw 'ITL_PYTHON_RUNTIME_VERSION_UNSUPPORTED: Python 3.11+ is required.' }
        return $probe
    } finally { $process.Dispose() }
}

function Expand-ItlPythonRuntimePackage {
    param([string]$ArchivePath, [string]$DestinationPath, [object]$Definition)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $seen = @{}
        foreach ($entry in $archive.Entries) {
            if (-not $entry.FullName.StartsWith('tools/', [StringComparison]::Ordinal) -or $entry.FullName.EndsWith('/')) { continue }
            $relative = $entry.FullName.Substring(6)
            if (-not $Definition.files.ContainsKey($relative) -or $seen.ContainsKey($relative)) { throw 'ITL_PYTHON_RUNTIME_ARCHIVE_ENTRY_INVALID' }
            $seen[$relative] = $true
            $path = Join-Path $DestinationPath $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    } finally { $archive.Dispose() }
    if (-not (Test-ItlPythonRuntimePayload -Root $DestinationPath -Definition $Definition)) { throw 'ITL_PYTHON_RUNTIME_EXTRACTION_INVALID' }
}

function Get-ItlManagedPythonRuntime {
    param([switch]$Offline, [switch]$RequireArchive, [string]$ArchivePath = '', [string]$AssetRoot = (Join-Path $PSScriptRoot '../assets/python-runtime'))
    $definition = Read-ItlPythonRuntimeManifest -AssetRoot $AssetRoot
    $manifest = $definition.manifest
    $cache = Get-ItlSharedArtifactDirectory -Family 'py' -Version $manifest.version -Sha256 $manifest.sha256
    # Keep executable generations shallow: CreateProcess rejects long image
    # paths even when archive extraction itself supports extended paths.
    $generationRoot = Join-Path (Get-ItlSharedArtifactCacheRoot) 'py'
    foreach ($directoryPath in @($generationRoot, (Join-Path $generationRoot $manifest.version), $cache)) {
        if ((Test-Path -LiteralPath $directoryPath) -and ((Get-Item -LiteralPath $directoryPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'ITL_PYTHON_RUNTIME_CACHE_REDIRECTED'
        }
        [void][IO.Directory]::CreateDirectory($directoryPath)
    }
    $pointerPath = Join-Path $cache 'current.json'
    $packagePath = Join-Path $cache $manifest.package
    foreach ($filePath in @($pointerPath, $packagePath, (Join-Path $cache '.install.lock'))) {
        if ((Test-Path -LiteralPath $filePath) -and ((Get-Item -LiteralPath $filePath).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'ITL_PYTHON_RUNTIME_CACHE_REDIRECTED'
        }
    }
    $lock = $null
    $staging = ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($null -eq $lock) {
            try { $lock = [IO.File]::Open((Join-Path $cache '.install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] {
                if ($watch.Elapsed.TotalSeconds -ge 60) { throw 'ITL_PYTHON_RUNTIME_INSTALL_WAIT_TIMEOUT' }
                Start-Sleep -Milliseconds 100
            }
        }
        $runtime = ''
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            try {
                $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($pointer.directory -cmatch '^runtime-[a-f0-9]{32}$') {
                    $candidate = Join-Path $generationRoot $pointer.directory
                    if (Test-ItlPythonRuntimePayload -Root $candidate -Definition $definition) { $runtime = $candidate }
                }
            } catch { $runtime = '' }
        }
        if (-not $runtime -or $RequireArchive) {
            if ((Get-ItlImmutableFileSha256 -Path $packagePath) -cne $manifest.sha256) {
                $bundled = Join-Path $AssetRoot $manifest.package
                $source = if ($ArchivePath) { $ArchivePath } elseif (Test-Path -LiteralPath $bundled -PathType Leaf) { $bundled } elseif ($Offline) { throw 'ITL_PYTHON_RUNTIME_OFFLINE_ASSET_MISSING' } else { $manifest.url }
                Invoke-ItlImmutableFileAcquire -Source $source -DestinationPath $packagePath -ExpectedSha256 $manifest.sha256 -Label 'ITL Python runtime' | Out-Null
            }
        }
        if (-not $runtime) {
            $staging = Join-Path $generationRoot ('.install-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($staging)
            Expand-ItlPythonRuntimePackage -ArchivePath $packagePath -DestinationPath $staging -Definition $definition
            $probe = Get-ItlPythonRuntimeProbe -Executable (Join-Path $staging $manifest.executable)
            if ($probe.version -cne $manifest.version) { throw 'ITL_PYTHON_RUNTIME_VERSION_MISMATCH' }
            $directory = 'runtime-' + [guid]::NewGuid().ToString('N')
            $runtime = Join-Path $generationRoot $directory
            [IO.Directory]::Move($staging, $runtime)
            $staging = ''
            Write-Utf8TextAtomic -Path $pointerPath -Value (@{ schemaVersion = 1; directory = $directory } | ConvertTo-Json)
        }
        [pscustomobject]@{ executable = (Join-Path $runtime $manifest.executable); archivePath = $packagePath; version = $manifest.version; managed = $true }
    } finally {
        try {
            if ($staging -and (Test-Path -LiteralPath $staging)) {
                $fullStaging = [IO.Path]::GetFullPath($staging)
                $items = @((Get-Item -LiteralPath $fullStaging)) + @(Get-ChildItem -LiteralPath $fullStaging -Recurse -Force)
                if (-not $fullStaging.StartsWith([IO.Path]::GetFullPath($generationRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    [IO.Path]::GetFileName($fullStaging) -cnotmatch '^\.install-[a-f0-9]{32}$' -or
                    @($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
                    throw 'ITL_PYTHON_RUNTIME_STAGING_CLEANUP_UNSAFE'
                }
                Remove-Item -LiteralPath $fullStaging -Recurse -Force
            }
        } finally { if ($null -ne $lock) { $lock.Dispose() } }
    }
}

function Resolve-ItlPythonExecutable {
    param([string]$Python = '', [switch]$Offline)
    if (-not $Python) { $Python = [Environment]::GetEnvironmentVariable('ITL_PYTHON_EXECUTABLE', 'Process') }
    if (-not $Python) { return (Get-ItlManagedPythonRuntime -Offline:$Offline).executable }
    $command = Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1
    Get-ItlPythonRuntimeProbe -Executable $command.Source | Out-Null
    return $command.Source
}

function Invoke-ItlPythonCommand {
    param([string]$Python = '', [string[]]$Arguments = @(), [switch]$Offline)
    $executable = Resolve-ItlPythonExecutable -Python $Python -Offline:$Offline
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.Arguments = Join-NativeCommandLineArguments -Arguments (@('-B', '-X', 'utf8') + $Arguments)
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
    $start.EnvironmentVariables['PYTHONNOUSERSITE'] = '1'
    $start.EnvironmentVariables['PYTHONUTF8'] = '1'
    $start.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $start.EnvironmentVariables.Remove('PYTHONHOME')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'ITL_PYTHON_RUNTIME_START_FAILED' }
        # Explicit byte streams are necessary under Windows PowerShell: a
        # grandchild does not reliably inherit the caller's redirected handles.
        # Copy both concurrently so progress stays live and neither pipe fills.
        $stdoutTarget = [Console]::OpenStandardOutput()
        $stderrTarget = [Console]::OpenStandardError()
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutTarget)
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrTarget)
        $process.WaitForExit()
        [void]$stdoutCopy.GetAwaiter().GetResult()
        [void]$stderrCopy.GetAwaiter().GetResult()
        $stdoutTarget.Flush()
        $stderrTarget.Flush()
        return $process.ExitCode
    } finally { $process.Dispose() }
}
