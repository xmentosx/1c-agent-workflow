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
$temporaryOutputPath = "{0}.{1}.tmp" -f $OutputPath, [guid]::NewGuid().ToString("N")

Push-Location $sourceRoot
try {
    if (-not $SkipTests) {
        $testOutput = @(& go test ./... 2>&1)
        $testExitCode = $LASTEXITCODE
        foreach ($line in $testOutput) { Write-Host ([string]$line) }
        if ($testExitCode -ne 0) { throw "itl-ondemand-mcp Go tests failed." }
    }
    $oldGoOs = $env:GOOS
    $oldGoArch = $env:GOARCH
    $oldGoAmd64 = $env:GOAMD64
    $oldCgoEnabled = $env:CGO_ENABLED
    try {
        $env:GOOS = "windows"
        $env:GOARCH = "amd64"
        $env:GOAMD64 = "v1"
        $env:CGO_ENABLED = "0"
        & go build -trimpath -buildvcs=false -ldflags "-s -w -buildid=" -o $temporaryOutputPath .
        if ($LASTEXITCODE -ne 0) { throw "itl-ondemand-mcp build failed." }
        Move-Item -LiteralPath $temporaryOutputPath -Destination $OutputPath -Force
    } finally {
        $env:GOOS = $oldGoOs
        $env:GOARCH = $oldGoArch
        $env:GOAMD64 = $oldGoAmd64
        $env:CGO_ENABLED = $oldCgoEnabled
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $temporaryOutputPath -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    path = $OutputPath
    sha256 = $hash
    assetName = [System.IO.Path]::GetFileName($OutputPath)
    os = "windows"
    arch = "amd64"
}
