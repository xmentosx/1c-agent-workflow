[CmdletBinding()]
param(
    [switch]$Provision,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$OpenSpecArguments
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageRoot = Join-Path $repoRoot '.agents/skills/1c-workflow/resources/openspec-cli'
$pin = (Get-Content -LiteralPath (Join-Path $repoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.openSpecCli
$version = [string]$pin.version
if ($version -notmatch '^\d+\.\d+\.\d+$' -or [string]$pin.packageLockSha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'SOURCE_OPENSPEC_PIN_INVALID: repair the source dependency-lock template.'
}
$lockPath = Join-Path $packageRoot 'package-lock.json'
$packagePath = Join-Path $packageRoot 'package.json'
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf) -or -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw 'SOURCE_OPENSPEC_PACKAGE_MISSING: restore the versioned OpenSpec package inputs.'
}
if ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -ine [string]$pin.packageLockSha256) {
    throw 'SOURCE_OPENSPEC_LOCK_DRIFT: package-lock bytes differ from the source pin.'
}
$package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
# Windows PowerShell 5.1 cannot parse npm lock v3's empty root key.
$lock = ((Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) -replace '"":\s*\{', '"__packageRoot__": {') | ConvertFrom-Json
$lockedPackage = $lock.packages.PSObject.Properties['node_modules/@fission-ai/openspec'].Value
if ([string]$package.dependencies.'@fission-ai/openspec' -ne $version -or
    [string]$lockedPackage.version -ne $version -or
    [string]$lockedPackage.integrity -cne [string]$pin.integrity) {
    throw 'SOURCE_OPENSPEC_PIN_CONFLICT: package, lock and source template disagree.'
}

$runtimeRoot = Join-Path $repoRoot ".agent-1c/tools/openspec-cli/$version"
$receiptPath = Join-Path $runtimeRoot 'itl-runtime.json'
$entryPath = Join-Path $runtimeRoot 'node_modules/@fission-ai/openspec/bin/openspec.js'

function Assert-SourceOpenSpecRuntime {
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        throw "SOURCE_OPENSPEC_NOT_PROVISIONED: run scripts/source-openspec.ps1 -Provision for $version."
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $nodePath = [string]$receipt.nodePath
    if (-not [IO.Path]::IsPathRooted($nodePath) -or -not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or
        [string]$receipt.version -ne $version -or
        [string]$receipt.packageLockSha256 -ne [string]$pin.packageLockSha256 -or
        (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash -ine [string]$receipt.nodeSha256 -or
        (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash -ine [string]$receipt.entrySha256) {
        throw "SOURCE_OPENSPEC_RUNTIME_DRIFT: preserve '$runtimeRoot' for diagnosis and provision a repaired generation."
    }
    return $nodePath
}

if ($Provision) {
    if ($OpenSpecArguments.Count -gt 0) { throw 'SOURCE_OPENSPEC_PROVISION_ARGUMENTS: -Provision takes no CLI arguments.' }
    if (Test-Path -LiteralPath $runtimeRoot) {
        [void](Assert-SourceOpenSpecRuntime)
        Write-Output "OpenSpec $version is already provisioned for this source checkout."
        return
    }
    $nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nodeCommand) { throw 'SOURCE_OPENSPEC_NODE_MISSING: install Node 20.19.0 or newer.' }
    $nodePath = [IO.Path]::GetFullPath([string]$nodeCommand.Source)
    $nodeVersion = (& $nodePath --version).TrimStart('v')
    if ($LASTEXITCODE -ne 0 -or [version]$nodeVersion -lt [version]'20.19.0') {
        throw "SOURCE_OPENSPEC_NODE_UNSUPPORTED: '$nodePath' reports $nodeVersion."
    }
    $npmCli = Join-Path (Split-Path -Parent $nodePath) 'node_modules/npm/bin/npm-cli.js'
    if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) { throw "SOURCE_OPENSPEC_NPM_MISSING: paired npm-cli.js is absent for '$nodePath'." }
    $runtimeParent = Split-Path -Parent $runtimeRoot
    New-Item -ItemType Directory -Force -Path $runtimeParent | Out-Null
    $staging = Join-Path $runtimeParent ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath $packagePath -Destination $staging
        Copy-Item -LiteralPath $lockPath -Destination $staging
        & $nodePath $npmCli ci --prefix $staging --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'SOURCE_OPENSPEC_NPM_CI_FAILED: pinned npm ci failed.' }
        $stagedEntry = Join-Path $staging 'node_modules/@fission-ai/openspec/bin/openspec.js'
        if (-not (Test-Path -LiteralPath $stagedEntry -PathType Leaf)) { throw 'SOURCE_OPENSPEC_ENTRY_MISSING: npm ci did not install the CLI.' }
        $actualVersion = (& $nodePath $stagedEntry --version).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $version) { throw "SOURCE_OPENSPEC_VERSION_MISMATCH: expected $version, found $actualVersion." }
        $receipt = [ordered]@{
            schemaVersion = 1
            version = $version
            packageLockSha256 = [string]$pin.packageLockSha256
            nodePath = $nodePath
            nodeSha256 = (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash.ToLowerInvariant()
            entrySha256 = (Get-FileHash -LiteralPath $stagedEntry -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText((Join-Path $staging 'itl-runtime.json'), (($receipt | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $runtimeRoot) { throw 'SOURCE_OPENSPEC_RUNTIME_CONFLICT: another process created this runtime.' }
        Move-Item -LiteralPath $staging -Destination $runtimeRoot
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    [void](Assert-SourceOpenSpecRuntime)
    Write-Output "Provisioned OpenSpec $version for this source checkout."
    return
}

$nodePath = Assert-SourceOpenSpecRuntime
if ($OpenSpecArguments.Count -eq 0) { $OpenSpecArguments = @('--version') }
Push-Location -LiteralPath $repoRoot
try {
    & $nodePath $entryPath @OpenSpecArguments
    if ($LASTEXITCODE -ne 0) { throw "SOURCE_OPENSPEC_COMMAND_FAILED: CLI exited $LASTEXITCODE." }
} finally {
    Pop-Location
}
