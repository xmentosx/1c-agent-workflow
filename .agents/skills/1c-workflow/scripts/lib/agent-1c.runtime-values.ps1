function Get-ItlOnDemandRuntimeRecordFiles {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
        # These are native facade/launch receipts, not backend process records.
        # Unknown JSON remains subject to the caller's strict runtime checks.
        if ($file.Name -like '*.VAParams.json' -or
            $relative -match '^[^/]+/connections/[^/]+/owner\.json$' -or
            $relative -match '^[^/]+/connection-recovery/recovery-[a-f0-9]{32}\.json$') { continue }
        $file
    }
}
function Get-StateValue {
    param(
        [object]$State,
        [string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $State) { return $Default }
    $prop = $State.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return $Default
    }
    return $prop.Value
}

function Test-ItlOnDemandInfoBaseMatch {
    param(
        [AllowNull()][string]$First,
        [AllowNull()][string]$Second
    )
    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }
    $firstText = $First.Trim().TrimEnd('\', '/')
    $secondText = $Second.Trim().TrimEnd('\', '/')
    if ([string]::Equals($firstText, $secondText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    try {
        if ([System.IO.Path]::IsPathRooted($firstText) -and [System.IO.Path]::IsPathRooted($secondText)) {
            return [string]::Equals(
                (Resolve-Agent1cFullPath -Path $firstText),
                (Resolve-Agent1cFullPath -Path $secondText),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    } catch {
        # Server connection strings can contain quotes and other characters
        # rejected by Windows path APIs. Unequal opaque connections do not match.
        return $false
    }
    return $false
}
