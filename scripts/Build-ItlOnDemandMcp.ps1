[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$sourceRoot = Join-Path $repoRoot "tools\itl-ondemand-mcp"
if (-not $OutputPath) {
    $OutputPath = Join-Path $sourceRoot "build\itl-ondemand-mcp-windows-amd64.exe"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $repoRoot $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

Push-Location $sourceRoot
try {
    if (-not $SkipTests) {
        & go test ./...
        if ($LASTEXITCODE -ne 0) { throw "itl-ondemand-mcp Go tests failed." }
    }
    $oldGoOs = $env:GOOS
    $oldGoArch = $env:GOARCH
    try {
        $env:GOOS = "windows"
        $env:GOARCH = "amd64"
        & go build -trimpath -ldflags "-s -w" -o $OutputPath .
        if ($LASTEXITCODE -ne 0) { throw "itl-ondemand-mcp build failed." }
    } finally {
        $env:GOOS = $oldGoOs
        $env:GOARCH = $oldGoArch
    }
} finally {
    Pop-Location
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    path = $OutputPath
    sha256 = $hash
    assetName = [System.IO.Path]::GetFileName($OutputPath)
    os = "windows"
    arch = "amd64"
}
