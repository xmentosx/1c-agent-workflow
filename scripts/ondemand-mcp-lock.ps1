[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Verify', 'Repin')][string]$Action,
    [string]$RepositoryRoot = '',
    # Verify: the registration base. Only build inputs changed since it are checked.
    [string]$BaseRef = '',
    [string]$OutputPath = '',
    # Repin: the facade version to publish; defaults to the version in the lock.
    [string]$Version = '',
    # Repin: the relay version; required when the pinned relay bytes change.
    [string]$RelayVersion = ''
)

# Owner of "the locked on-demand MCP executable is the build of the current source".
# The lock names the release asset that installed projects download, Develop E2E
# discovers the source build by that SHA-256 and the component finalizer treats an
# existing asset at the locked URL as published. A Go change without repinning would
# therefore ship the previous executable silently. Verify catches it before Pester;
# Repin rewrites every copy of the identity from one build.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RepositoryRoot) { $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path $PSScriptRoot 'git-path-list.ps1')

$lockRelative = 'templates/dependency-lock.json'
$compatibilityRelative = '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json'
$mainRelative = 'tools/itl-ondemand-mcp/main.go'
$relayMainRelative = 'tools/itl-ondemand-mcp/cmd/itl-ondemand-relay/main.go'
$repinCommand = '.\scripts\ondemand-mcp-lock.ps1 -Action Repin [-Version <next-version>] [-RelayVersion <next-relay-version>]'

function Get-OnDemandLockEntry {
    $lock = Get-Content -LiteralPath (Join-Path $RepositoryRoot $lockRelative) -Raw -Encoding UTF8 | ConvertFrom-Json
    return $lock.dependencies.itlOndemandMcp
}

function Get-OnDemandRelayLockEntry {
    # The relay is pinned only once the published supervisor can finalize it.
    $lock = Get-Content -LiteralPath (Join-Path $RepositoryRoot $lockRelative) -Raw -Encoding UTF8 | ConvertFrom-Json
    $property = $lock.dependencies.PSObject.Properties['itlOndemandRelay']
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-OnDemandBuildInput {
    param([string]$Path)
    # Go excludes *_test.go from the build and documentation is not compiled.
    return $Path -like 'tools/itl-ondemand-mcp/*' -and $Path -notlike 'tools/itl-ondemand-mcp/build/*' -and
        $Path -notmatch '_test\.go$' -and $Path -notmatch '\.md$'
}

function Invoke-OnDemandBuild {
    param([string]$Destination)
    $builder = Join-Path $RepositoryRoot 'scripts\Build-ItlOnDemandMcp.ps1'
    $result = @(& $builder -OutputPath $Destination -SkipTests)
    if ($result.Count -lt 1 -or -not ([string]$result[-1].sha256) -or -not ([string]$result[-1].relaySha256)) { throw 'ONDEMAND_LOCK_BUILD_FAILED: Build-ItlOnDemandMcp.ps1 returned no SHA-256.' }
    return [pscustomobject]@{ sha256 = ([string]$result[-1].sha256).ToLowerInvariant(); relaySha256 = ([string]$result[-1].relaySha256).ToLowerInvariant() }
}

function Write-OnDemandTextPreservingBytes {
    param([string]$Relative, [scriptblock]$Transform)
    $path = Join-Path $RepositoryRoot $Relative
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    $updated = & $Transform $text
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($bom))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Set-JsonStringField {
    param([string]$Text, [string]$Field, [string]$Value, [int]$StartIndex = 0)
    $pattern = [regex]('"' + [regex]::Escape($Field) + '"\s*:\s*"[^"]*"')
    $match = $pattern.Match($Text, $StartIndex)
    if (-not $match.Success) { throw "ONDEMAND_LOCK_FIELD_MISSING: '$Field'." }
    return $Text.Substring(0, $match.Index) + ('"' + $Field + '": "' + $Value + '"') + $Text.Substring($match.Index + $match.Length)
}

if ($Action -eq 'Verify') {
    $report = [ordered]@{ schemaVersion = 1; status = 'skipped'; reason = ''; changedInputs = @(); lockSha256 = ''; builtSha256 = ''; relayLockSha256 = ''; relayBuiltSha256 = '' }
    if (-not $BaseRef) {
        $report.reason = 'no registration base'
    } else {
        $changed = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('diff', '--name-only', '-z', $BaseRef, 'HEAD', '--', 'tools/itl-ondemand-mcp', $lockRelative))
        $inputs = @($changed | Where-Object { (Test-OnDemandBuildInput $_) -or $_ -eq $lockRelative })
        $report.changedInputs = $inputs
        if (-not $inputs.Count) {
            $report.reason = 'no on-demand MCP build input changed'
        } else {
            $entry = Get-OnDemandLockEntry
            $report.lockSha256 = ([string]$entry.sha256).ToLowerInvariant()
            $buildPath = Join-Path ([IO.Path]::GetTempPath()) ('itl-ondemand-lock-' + [guid]::NewGuid().ToString('N') + '\' + [string]$entry.assetName)
            try {
                $built = Invoke-OnDemandBuild -Destination $buildPath
            } finally {
                Remove-Item -LiteralPath (Split-Path -Parent $buildPath) -Recurse -Force -ErrorAction SilentlyContinue
            }
            $report.builtSha256 = $built.sha256
            $relayEntry = Get-OnDemandRelayLockEntry
            if ($null -ne $relayEntry) {
                $report.relayLockSha256 = ([string]$relayEntry.sha256).ToLowerInvariant()
                $report.relayBuiltSha256 = $built.relaySha256
            }
            if ($report.builtSha256 -cne $report.lockSha256) {
                $report.status = 'failed'
                $report.reason = "ONDEMAND_LOCK_STALE: the current source builds $($report.builtSha256), but $lockRelative itlOndemandMcp.sha256 is $($report.lockSha256). Run $repinCommand and commit the result."
            } elseif ($report.relayLockSha256 -and $report.relayBuiltSha256 -cne $report.relayLockSha256) {
                $report.status = 'failed'
                $report.reason = "ONDEMAND_LOCK_STALE: the current source builds the relay $($report.relayBuiltSha256), but $lockRelative itlOndemandRelay.sha256 is $($report.relayLockSha256). Run $repinCommand with a new -RelayVersion and commit the result."
            } else { $report.status = 'passed' }
        }
    }
    if ($OutputPath) { [IO.File]::WriteAllText($OutputPath, (($report | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)) }
    if ($report.status -eq 'failed') { throw $report.reason }
    return [pscustomobject]$report
}

# Repin: the Go constant is compiled into the executable, so it is written first.
$entry = Get-OnDemandLockEntry
if (-not $Version) { $Version = [string]$entry.version }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "ONDEMAND_LOCK_VERSION_INVALID: '$Version'." }
$tag = 'itl-ondemand-mcp-v' + $Version
$url = ([string]$entry.url) -replace '/releases/download/[^/]+/[^/]+$', ('/releases/download/' + $tag + '/' + [string]$entry.assetName)
Write-OnDemandTextPreservingBytes -Relative $mainRelative -Transform {
    param($Text)
    $pattern = [regex]'(?m)^const version = "[^"]*"'
    if (-not $pattern.IsMatch($Text)) { throw "ONDEMAND_LOCK_FIELD_MISSING: $mainRelative const version." }
    $pattern.Replace($Text, ('const version = "' + $Version + '"'), 1)
}
$relayEntry = Get-OnDemandRelayLockEntry
if ($RelayVersion) {
    if ($null -eq $relayEntry) { throw 'ONDEMAND_LOCK_FIELD_MISSING: itlOndemandRelay; pin the relay entry before setting -RelayVersion.' }
    if ($RelayVersion -notmatch '^\d+\.\d+\.\d+$') { throw "ONDEMAND_LOCK_VERSION_INVALID: relay '$RelayVersion'." }
    Write-OnDemandTextPreservingBytes -Relative $relayMainRelative -Transform {
        param($Text)
        $pattern = [regex]'(?m)^const version = "[^"]*"'
        if (-not $pattern.IsMatch($Text)) { throw "ONDEMAND_LOCK_FIELD_MISSING: $relayMainRelative const version." }
        $pattern.Replace($Text, ('const version = "' + $RelayVersion + '"'), 1)
    }
}
$built = Invoke-OnDemandBuild -Destination (Join-Path $RepositoryRoot ('tools\itl-ondemand-mcp\build\' + [string]$entry.assetName))
$sha256 = $built.sha256
if ($null -ne $relayEntry) {
    # A published relay release is immutable: changed bytes need a new version.
    if (-not $RelayVersion -and $built.relaySha256 -cne ([string]$relayEntry.sha256).ToLowerInvariant()) {
        throw "ONDEMAND_RELAY_VERSION_REQUIRED: the relay builds $($built.relaySha256), not the pinned $([string]$relayEntry.sha256); repeat with -RelayVersion <next-relay-version>."
    }
    $relayVersionValue = if ($RelayVersion) { $RelayVersion } else { [string]$relayEntry.version }
    $relayTag = 'itl-ondemand-relay-v' + $relayVersionValue
    $relayUrl = ([string]$relayEntry.url) -replace '/releases/download/[^/]+/[^/]+$', ('/releases/download/' + $relayTag + '/' + [string]$relayEntry.assetName)
    Write-OnDemandTextPreservingBytes -Relative $lockRelative -Transform {
        param($Text)
        $start = $Text.IndexOf('"itlOndemandRelay"', [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'ONDEMAND_LOCK_FIELD_MISSING: itlOndemandRelay.' }
        foreach ($field in @(@('version', $relayVersionValue), @('releaseTag', $relayTag), @('url', $relayUrl), @('sha256', $built.relaySha256))) {
            $Text = Set-JsonStringField -Text $Text -Field $field[0] -Value $field[1] -StartIndex $start
        }
        $Text
    }
}
Write-OnDemandTextPreservingBytes -Relative $lockRelative -Transform {
    param($Text)
    $start = $Text.IndexOf('"itlOndemandMcp"', [StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'ONDEMAND_LOCK_FIELD_MISSING: itlOndemandMcp.' }
    foreach ($field in @(@('version', $Version), @('releaseTag', $tag), @('url', $url), @('sha256', $sha256))) {
        $Text = Set-JsonStringField -Text $Text -Field $field[0] -Value $field[1] -StartIndex $start
    }
    $Text
}
Write-OnDemandTextPreservingBytes -Relative $compatibilityRelative -Transform {
    param($Text)
    Set-JsonStringField -Text $Text -Field 'facadeVersion' -Value $Version
}
return [pscustomobject][ordered]@{ status = 'repinned'; version = $Version; releaseTag = $tag; url = $url; sha256 = $sha256; relaySha256 = $(if ($null -ne $relayEntry) { $built.relaySha256 } else { '' }) }
