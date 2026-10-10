# Stateless contract shared by the Pester scheduler and its actual worker.
function Get-PesterShardFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    $sha256 = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Initialize-PesterShardModulePath {
    if ($env:OS -eq 'Windows_NT' -and [string]$PSVersionTable.PSEdition -eq 'Desktop') {
        $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        $userModuleRoot = [IO.Path]::GetFullPath((Join-Path $documents 'WindowsPowerShell\Modules'))
        $moduleRoots = @($env:PSModulePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (-not @($moduleRoots | Where-Object {
            try { [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\'), $userModuleRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        }).Count) {
            $env:PSModulePath = (@($userModuleRoot) + $moduleRoots) -join ';'
        }
    }
}

function Get-PesterShardRuntimeReceipt {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $module = Get-Module Pester | Select-Object -First 1
        if (-not $module -or $module.Version -lt [version]'5.0.0') { throw 'Pester 5 is not loaded in the actual worker.' }
        $manifest = Join-Path $module.ModuleBase 'Pester.psd1'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Loaded Pester has no verifiable manifest.' }
        $executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $engine = [Management.Automation.PSObject].Assembly.Location
        # Hash all module files once per observation, including assemblies and
        # dot-sourced scripts. Reparse points do not qualify an incomplete tree.
        $pending = New-Object 'Collections.Generic.Queue[string]'
        $pending.Enqueue([IO.Path]::GetFullPath($module.ModuleBase))
        $files = New-Object 'Collections.Generic.List[string]'
        while ($pending.Count -gt 0) {
            $directory = $pending.Dequeue()
            if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pester module contains a reparse directory.' }
            foreach ($entry in [IO.Directory]::GetFileSystemEntries($directory)) {
                $attributes = [IO.File]::GetAttributes($entry)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pester module contains a reparse entry.' }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Enqueue($entry) }
                else { $files.Add($entry) }
            }
        }
        $root = [IO.Path]::GetFullPath($module.ModuleBase).TrimEnd('\') + '\'
        $inputs = New-Object 'Collections.Generic.List[string]'
        foreach ($file in @($files | Sort-Object)) {
            $inputs.Add($file.Substring($root.Length).Replace('\', '/'))
            $inputs.Add((Get-PesterShardFileSha256 -Path $file))
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $moduleSha = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($inputs -join "`0"))))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $identity = [ordered]@{
            schemaVersion = 1
            powerShellVersion = [string]$PSVersionTable.PSVersion
            powerShellEdition = [string]$PSVersionTable.PSEdition
            processBits = [IntPtr]::Size * 8
            executablePath = $executable
            executableSha256 = Get-PesterShardFileSha256 -Path $executable
            enginePath = $engine
            engineSha256 = Get-PesterShardFileSha256 -Path $engine
            pesterVersion = [string]$module.Version
            pesterManifestPath = $manifest
            pesterModuleInputCount = $files.Count
            pesterModuleInputsSha256 = $moduleSha
        }
        $parts = @($identity.GetEnumerator() | ForEach-Object { [string]$_.Key; [string]$_.Value })
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $identity.identitySha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`0"))))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        return [pscustomobject]@{status='known'; identity=[pscustomobject]$identity; reason=''; durationMs=[int64]$watch.ElapsedMilliseconds}
    } catch {
        return [pscustomobject]@{status='unknown'; identity=$null; reason=$_.Exception.Message; durationMs=[int64]$watch.ElapsedMilliseconds}
    } finally { $watch.Stop() }
}
