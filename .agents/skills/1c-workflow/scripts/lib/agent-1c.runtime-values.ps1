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
