[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$manifestPath = Join-Path $PSScriptRoot 'onboard.json'
$statusPath = Join-Path $PSScriptRoot 'bootstrap-status.json'
function Write-BootstrapStatus([string]$Phase, [string]$Detail = '') {
    $value = [ordered]@{
        schemaVersion = 1
        phase = $Phase
        detail = $Detail
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = "$statusPath.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}
function Assert-Hash([string]$Name, [string]$Expected) {
    $path = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ONBOARD_FILE_MISSING: $Name" }
    $stream = [IO.File]::OpenRead($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        if ($actual -ne $Expected) { throw "ONBOARD_HASH_MISMATCH: $Name" }
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

try {
    Write-BootstrapStatus 'verifying'
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') {
        throw 'ONBOARD_MANIFEST_INVALID'
    }
    Assert-Hash 'bundle.zip' $manifest.bundleSha256
    Assert-Hash 'worker-connection.json' $manifest.connectionSha256
    Assert-Hash 'profile.json' $manifest.profileSha256
    if ($manifest.caSha256) { Assert-Hash 'controller-ca.pem' $manifest.caSha256 }
    $root = Join-Path $env:LOCALAPPDATA (Join-Path 'ITL\remote-work' $manifest.name)
    $spool = Join-Path $root 'spool'
    $statePath = Join-Path $root 'onboard-state.json'
    $installed = $false
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $old = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($old.bundleSha256 -ne $manifest.bundleSha256 -or
            $old.connectionSha256 -ne $manifest.connectionSha256 -or
            $old.profileSha256 -ne $manifest.profileSha256 -or
            $old.caSha256 -ne $manifest.caSha256) {
            throw 'ONBOARD_ALREADY_PAIRED_DIFFERENT_INPUT'
        }
        $installed = $true
    }
    if (-not $installed) {
        if (Test-Path -LiteralPath (Join-Path $spool 'profile.json')) {
            throw 'ONBOARD_EXISTING_PRIVATE_PROFILE'
        }
        Write-BootstrapStatus 'installing'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $runtime = Join-Path $root ('runtime-' + $manifest.bundleSha256)
        if (-not (Test-Path -LiteralPath $runtime -PathType Container)) {
            $stage = Join-Path $root ('runtime-stage-' + [guid]::NewGuid().ToString('N'))
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $PSScriptRoot 'bundle.zip'), $stage)
            Move-Item -LiteralPath $stage -Destination $runtime
        }
        $scripts = Join-Path $runtime '.agents\skills\itl-remote-runner\scripts'
        if (-not (Test-Path -LiteralPath (Join-Path $scripts 'Prepare-RemoteHost.ps1') -PathType Leaf)) {
            throw 'ONBOARD_RUNTIME_INCOMPLETE'
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'profile.json') -Destination (Join-Path $root 'profile.json')
        $privateProfilePath = Join-Path $root 'profile.json'
        $privateProfile = [IO.File]::ReadAllText($privateProfilePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $privateProfile | Add-Member -NotePropertyName bootstrapStatusPath -NotePropertyValue $statusPath -Force
        [IO.File]::WriteAllText($privateProfilePath, ($privateProfile | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'worker-connection.json') -Destination (Join-Path $root 'worker-connection.json')
        if ($manifest.caSha256) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'controller-ca.pem') -Destination (Join-Path $root 'controller-ca.pem')
        }
        & (Join-Path $scripts 'Prepare-RemoteHost.ps1') -Offline -Resume -Spool $spool -Profile (Join-Path $root 'profile.json') -WorkerConnection (Join-Path $root 'worker-connection.json')
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
    if ($manifest.caSha256) { $env:SSL_CERT_FILE = Join-Path $root 'controller-ca.pem' }
    Write-BootstrapStatus 'worker-starting'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $spool 'Start-Worker.ps1')
    $code = $LASTEXITCODE
    Write-BootstrapStatus 'worker-stopped' "exit=$code"
    exit $code
} catch {
    $errorText = $_.Exception.Message
    try { Write-BootstrapStatus 'failed' $errorText } catch { }
    Write-Error $errorText
    exit 1
}
