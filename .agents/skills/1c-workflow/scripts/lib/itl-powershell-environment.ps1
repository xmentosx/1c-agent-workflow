function Get-ItlWindowsPowerShellModulePath {
    param(
        [AllowNull()][string]$ModulePath = $env:PSModulePath,
        [string]$ParentEdition = [string]$PSVersionTable.PSEdition,
        [string]$ParentHome = $PSHOME
    )
    if ($ParentEdition -ne 'Core' -or $null -eq $ModulePath) { return $ModulePath }
    $coreRoot = [IO.Path]::GetFullPath((Join-Path $ParentHome 'Modules')).TrimEnd('\','/')
    $compatible = @($ModulePath -split ';' | Where-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return $false }
        try { return -not [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\','/'),$coreRoot,[StringComparison]::OrdinalIgnoreCase) }
        catch { return $true }
    })
    return ($compatible -join ';')
}
