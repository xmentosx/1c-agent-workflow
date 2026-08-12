[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "RELEASE_POWERSHELL_51_REQUIRED: actual=$($PSVersionTable.PSEdition)-$($PSVersionTable.PSVersion)"
}

$pathPayload = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$paths = foreach ($path in $pathPayload) { [string]$path }
$results = foreach ($path in $paths) {
    # Deliberately omit -Encoding. Windows PowerShell 5.1 applies its real
    # decoding rules; the readiness parent compares them with strict UTF-8.
    $decoded = Get-Content -LiteralPath ([string]$path) -Raw
    [ordered]@{
        path = [string]$path
        decodedBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($decoded))
    }
}
[IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -InputObject @($results) -Depth 3), [Text.UTF8Encoding]::new($false))
