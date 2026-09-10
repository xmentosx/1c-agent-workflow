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
