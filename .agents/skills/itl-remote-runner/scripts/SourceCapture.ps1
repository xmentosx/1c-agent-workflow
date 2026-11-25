# Source-only Designer command construction. No arbitrary native arguments.
function Assert-ItlSourceCapturePath {
    param([string]$Path)
    # Never traverse an existing junction, including one replacing the run root.
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'SOURCE_CAPTURE_REPARSE_POINT'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Resolve-ItlSourceCaptureRoot {
    param([string]$RunRoot, [string]$SnapshotId)
    if ($SnapshotId -notmatch '^[a-f0-9]{32}$') { throw 'SOURCE_CAPTURE_ID_INVALID' }
    $run = [IO.Path]::GetFullPath($RunRoot)
    $root = [IO.Path]::GetFullPath((Join-Path $run ('source-snapshots\' + $SnapshotId)))
    Assert-ItlSourceCapturePath -Path $root
    return $root
}

function Get-ItlSourceCaptureStep {
    param([object]$Context, [string]$RunRoot, [object]$Spec)
    if ('measure' -notin @(Get-StateValue -State $Context -Name 'operations' -Default @())) { throw 'SOURCE_CAPTURE_MEASURE_AUTHORIZATION_REQUIRED' }
    $accessLease=Get-StateValue -State $Context -Name 'accessLease'
    if (-not (Get-StateValue -State $accessLease -Name 'ticket')) { throw 'SOURCE_CAPTURE_ACCESS_LEASE_REQUIRED' }
    $root = Resolve-ItlSourceCaptureRoot -RunRoot $RunRoot -SnapshotId ([string]$Spec.snapshotId)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'SOURCE_CAPTURE_ROOT_MISSING' }
    $base = $Context.target.infoBase
    if ($base.kind -notin @('file','server') -or -not $base.path) { throw 'SOURCE_CAPTURE_INFOBASE_REQUIRED' }
    if ($base.kind -eq 'file') {
        $basePath = [IO.Path]::GetFullPath([string]$base.path).TrimEnd('\','/')
        if ($root.Equals($basePath, [StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($basePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SOURCE_CAPTURE_OUTPUT_INSIDE_TARGET_BASE'
        }
    }
    $platform = [IO.Path]::GetFullPath([string]$Context.target.platform)
    if ([IO.Path]::GetFileName($platform) -notin @('1cv8.exe','1cv8c.exe')) { throw 'SOURCE_CAPTURE_PLATFORM_REQUIRED' }
    $executable = Join-Path ([IO.Path]::GetDirectoryName($platform)) '1cv8.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'SOURCE_CAPTURE_DESIGNER_UNAVAILABLE' }
    $scratch = Join-Path $root 'private\scratch'
    $marker = Join-Path $root 'private\scratch-owner.json'
    $extension = [string](Get-StateValue -State $Spec -Name 'extension' -Default '')
    $extensionKey = ''
    if ($extension) {
        if ($extension -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') { throw 'SOURCE_CAPTURE_EXTENSION_NAME_INVALID' }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $extensionKey = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($extension)))).Replace('-','').ToLowerInvariant() }
        finally { $hash.Dispose() }
    }
    $artifact = if ($extension) { Join-Path $root ('extensions\' + $extensionKey + '.cfe') } else { Join-Path $root 'database.cf' }
    foreach ($path in @($artifact, $scratch, $marker)) { Assert-ItlSourceCapturePath -Path $path }
    $output = $null
    $operation = [string]$Spec.operation
    $create = $false
    $native = @()
    switch ($operation) {
        'list-extensions' {
            if ($extension) { throw 'SOURCE_CAPTURE_UNEXPECTED_EXTENSION' }
            $native = @('/DumpDBCfgList', '-AllExtensions')
        }
        'dump-database' {
            if ($extension) { throw 'SOURCE_CAPTURE_UNEXPECTED_EXTENSION' }
            $output = $artifact
            $native = @('/DumpDBCfg', $output)
        }
        'dump-extension' {
            if (-not $extension) { throw 'SOURCE_CAPTURE_EXTENSION_REQUIRED' }
            $output = $artifact
            $native = @('/DumpDBCfg', $output, '-Extension', $extension)
        }
        'create-scratch' {
            if ($extension) { throw 'SOURCE_CAPTURE_UNEXPECTED_EXTENSION' }
            if (Test-Path -LiteralPath $scratch) { throw 'SOURCE_CAPTURE_SCRATCH_ALREADY_EXISTS' }
            $create = $true
        }
        'load-snapshot' {
            if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw 'SOURCE_CAPTURE_BINARY_MISSING' }
            $native = @('/LoadCfg', $artifact)
            if ($extension) { $native += @('-Extension', $extension) }
        }
        'dump-sources' {
            $output = if ($extension) { Join-Path $root ('extension-sources\' + $extensionKey) } else { Join-Path $root 'configuration' }
            $native = @('/DumpConfigToFiles', $output, '-Format', 'Hierarchical')
            if ($extension) { $native += @('-Extension', $extension) }
        }
        default { throw 'SOURCE_CAPTURE_OPERATION_INVALID' }
    }
    $isScratch = $operation -in @('create-scratch','load-snapshot','dump-sources')
    if ($isScratch) {
        if ($Context.target.infoBase.kind -eq 'file' -and ($scratch.Equals($basePath, [StringComparison]::OrdinalIgnoreCase) -or
            $scratch.StartsWith($basePath + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $basePath.StartsWith($scratch + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw 'SOURCE_CAPTURE_SCRATCH_OVERLAPS_TARGET'
        }
        if (-not $create) {
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'SOURCE_CAPTURE_SCRATCH_OWNER_MISSING' }
            $owner = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($owner.snapshotId -cne $Spec.snapshotId -or $owner.jobId -cne $Context.jobId -or $owner.path -cne $scratch) {
                throw 'SOURCE_CAPTURE_SCRATCH_OWNER_MISMATCH'
            }
        }
        $base = [pscustomobject]@{kind='file'; path=$scratch}
    }
    if ($output) {
        Assert-ItlSourceCapturePath -Path $output
        if (Test-Path -LiteralPath $output) { throw 'SOURCE_CAPTURE_ARTIFACT_ALREADY_EXISTS' }
    }
    $arguments = if ($create) { @('CREATEINFOBASE', ('File="' + $scratch + '";')) } else {
        @('DESIGNER', $(if ($base.kind -eq 'file') { '/F' } else { '/S' }), [string]$base.path)
    }
    if (-not $isScratch) {
        $sourceCapture=Get-StateValue -State $Context.target -Name 'sourceCapture'
        foreach ($credential in @(@('userEnv','/N'), @('passwordEnv','/P'))) {
            $reference = [string](Get-StateValue -State $sourceCapture -Name $credential[0] -Default '')
            if ($reference) {
                $secret = [Environment]::GetEnvironmentVariable($reference)
                if ([string]::IsNullOrEmpty($secret)) { throw 'SOURCE_CAPTURE_CREDENTIAL_REFERENCE_EMPTY' }
                $arguments += @($credential[1], $secret)
            }
        }
    }
    $arguments += @('/DisableStartupDialogs', '/DisableStartupMessages', '/L', 'en') + $native
    return [pscustomobject]@{ root=$root; operation=$operation; executable=$executable; arguments=$arguments;
        base=$base; create=$create; scratch=$scratch; marker=$marker; output=$output; extension=$extension }
}
