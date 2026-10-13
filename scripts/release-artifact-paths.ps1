# Source-only Release artifact layout shared by the producer and its cleanup owner.
function Get-ReleaseCapabilityCacheRoot {
    param([string]$WorktreePath, [string]$RunName)
    if ($RunName -notmatch '^[A-Za-z0-9_.-]+$' -or $RunName -in @('.', '..')) { throw 'Invalid Release run name.' }
    return Join-Path ([IO.Path]::GetFullPath($WorktreePath)) ".agent-1c/runs/release-e2e-capabilities/$RunName"
}

function Resolve-ReleaseCapabilityArtifactPath {
    param([string]$Path, [string]$WorktreePath)
    $root = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $relative = $full.Substring($root.Length + 1).Replace('\', '/')
    if ($relative -match '^\.agent-1c/runs/release-e2e-capabilities/([A-Za-z0-9_.-]+)/([0-9a-f]{32})(?:/(.*))?$') {
        $run = $matches[1]; $generation = $matches[2]; $member = $matches[3]
        $cache = Get-ReleaseCapabilityCacheRoot -WorktreePath $root -RunName $run
    } elseif ($relative -match '^\.agent-1c/release-capability-cache/([0-9a-f]{32})(?:/(.*))?$') {
        # Retain the previously accepted layout; never reinterpret arbitrary directories.
        $run = ''; $generation = $matches[1]; $member = $matches[2]
        $cache = Join-Path $root '.agent-1c/release-capability-cache'
    } else { return $null }
    $directory = Join-Path $cache $generation
    return [pscustomobject]@{ root=$directory; manifestPath=(Join-Path $directory 'manifest.json'); runName=$run; generation=$generation; member=$member }
}
