# Stateless validation and mounts; cutover owns admission, replacement and rollback.
function Get-HostCodeRepairPackage {
    # A delivery copy of the distribution's authoritative package.
    return (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'code-package.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-QualifiedHostOwnerRepairMounts {
    param([object]$Config, [object]$Server)
    $spec = Get-ObjectValue -Object $Server -Name 'ownerRepair' -Default $null
    if ($null -eq $spec) { return @() }
    $continuation = 'Re-run the declared original native fixtures without network or live indices under the existing host maintenance lease; stage their exact proof and files, then repeat stable-preflight.'
    $id = [string]$Server.id
    $targets = @{
        code = @{driver='/app/src/index_generation/driver.py';main='/app/src/main.py'}
        graph = @{run='/app/run.py';score_floor='/app/score_floor.py';common_forms='/app/common_forms.py'}
    }
    $xsdFixture = [string](Get-ObjectValue -Object $spec -Name 'xsdFixtureSha256' -Default '')
    if ($id -eq 'code' -and [int](Get-ObjectValue -Object $spec -Name 'schemaVersion' -Default 1) -ge 2 -and -not $xsdFixture) {
        throw "Code package requires XSD qualification; restore the shared package and rerun its original fixtures before stable-preflight. $continuation"
    }
    if ($id -eq 'code' -and $xsdFixture) {
        $targets.code.xsd_schema_generator = '/app/src/xsd_schema_generator.py'
    }
    $repositories = @{code='comol/1c_code_metadata_mcp';graph='comol/1c_graph_metadata'}
    $image = [string](Get-ObjectValue -Object $Server -Name 'image' -Default '')
    if (-not $targets.ContainsKey($id) -or $image -cnotmatch ('^'+[regex]::Escape($repositories[$id])+'@sha256:([a-f0-9]{64})$') -or [string]$spec.image -cne $image) { throw "Host owner repair belongs to another image. $continuation" }
    $digest = $image.Split(':')[-1]
    $root = Join-Path (Join-Path (Join-Path (Join-Path (Get-StateRoot -Config $Config) 'repairs') 'owner') $id) $digest
    if ($id -eq 'code' -and $xsdFixture) { $root = Join-Path $root 'xsd-v2' }
    $proofPath = Join-Path $root 'qualification.json'
    if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$spec.proofSha256) { throw "Code owner qualification is missing or changed. $continuation" }
    $proof = Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($proof.schemaVersion -ne 1 -or $proof.accepted -ne $true -or $proof.image -cne $image -or $proof.host -cne (Get-HostId -Config $Config) -or $proof.isolated -ne $true -or $proof.network -cne 'none' -or $proof.liveIndexMounted -ne $false -or [string]$spec.fixtureSha256 -cnotmatch '^[a-f0-9]{64}$' -or $proof.fixtureSha256 -cne [string]$spec.fixtureSha256) { throw "Host owner qualification has the wrong native invariant or scope. $continuation" }
    if ($id -eq 'code') {
    $resumeFixedUpstream = $false
    if ($xsdFixture -and (Get-ObjectValue -Object $proof -Name 'resumeUpstreamPassed' -Default $false) -eq $true) {
        $rows = @([string]$proof.upstreamRegressionOutput -split "`n" | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
        $originalResume = @($rows | Where-Object test -eq 'interrupted_incremental_resume')
        $originalSelection = @($rows | Where-Object test -eq 'selective_repair')
        $resumeFixedUpstream = $originalResume.Count -eq 1 -and $originalSelection.Count -eq 1 -and
            $originalResume[0].modules -eq 2 -and $originalResume[0].new_function_found -eq $true -and
            $originalResume[0].ancestor_unchanged -eq $true -and $originalSelection[0].preserves_vectors -eq $true -and
            $originalSelection[0].honors_omissions -eq $true
    }
    if ($proof.negativeControlReproduced -ne $true -and -not $resumeFixedUpstream) { throw "Host owner qualification has the wrong native invariant or scope. $continuation" }
    $resume = @($proof.regression | Where-Object test -eq 'interrupted_incremental_resume')
    $selection = @($proof.regression | Where-Object test -eq 'selective_repair')
    if ($resume.Count -ne 1 -or $selection.Count -ne 1 -or $resume[0].modules -ne 2 -or $resume[0].new_function_found -ne $true -or $resume[0].ancestor_unchanged -ne $true -or $selection[0].preserves_vectors -ne $true -or $selection[0].honors_omissions -ne $true) { throw "Code owner original native regression did not pass. $continuation" }
    if ($xsdFixture) {
        $xsd = Get-ObjectValue -Object $proof -Name 'xsd' -Default @{}
        $controls = Convert-ToHash -Object (Get-ObjectValue -Object $xsd -Name 'negativeControls' -Default @{})
        $names = @('unknown-root','unknown-deep-child','wrong-title-child','wrong-nesting')
        if ($xsdFixture -cnotmatch '^[a-f0-9]{64}$' -or [string]$proof.xsdFixtureSha256 -cne $xsdFixture -or
            $xsd.positive -ne $true -or $xsd.parserLimitsPreserved -ne $true -or $xsd.xsdLaneOnlyInvalidated -ne $true -or
            (($controls.Keys | Sort-Object) -join ',') -cne (($names | Sort-Object) -join ',') -or
            @($names | Where-Object { $controls[$_] -cne 'invalid' }).Count -gt 0) {
            throw "Code owner original XSD regression did not pass. $continuation"
        }
    }
    } else {
        $suites = @{fulltext=13;commonForms=14;combined=3}
        if (@($proof.nativeSuites).Count -ne $suites.Count) { throw "Graph owner original native regression did not pass. $continuation" }
        foreach ($name in $suites.Keys) {
            $suite = @($proof.nativeSuites | Where-Object name -CEQ $name)
            if ($suite.Count -ne 1 -or $suite[0].tests -ne $suites[$name] -or $suite[0].failures -ne 0 -or $suite[0].errors -ne 0 -or $suite[0].skipped -ne 0 -or $suite[0].native -ne $true) { throw "Graph owner original native regression did not pass. $continuation" }
        }
    }
    $expected = Convert-ToHash -Object $spec.files
    $observed = Convert-ToHash -Object $proof.files
    if ($id -eq 'code' -and $xsdFixture) {
        $package = Get-HostCodeRepairPackage
        $shared = Convert-ToHash -Object $package.files
        if ([string]$package.image -cne $image -or [string]$package.xsdFixtureSha256 -cne $xsdFixture -or
            (($shared.Keys | Sort-Object) -join ',') -cne (($expected.Keys | Sort-Object) -join ',') -or
            @($shared.Keys | Where-Object { [string]$shared[$_] -cne [string]$expected[$_] }).Count -gt 0) {
            throw "Code image or files differ from the shared four-target package; intake and qualify one common package before retrying stable-preflight. $continuation"
        }
    }
    $names = ($targets[$id].Keys | Sort-Object) -join ','
    if ((($expected.Keys | Sort-Object) -join ',') -cne $names -or (($observed.Keys | Sort-Object) -join ',') -cne $names) { throw "Host owner repair must contain every exact file. $continuation" }
    foreach ($name in $targets[$id].Keys) {
        $path = Join-Path $root ($name + '.py')
        if ([string]$expected[$name] -cnotmatch '^[a-f0-9]{64}$' -or $observed[$name] -cne $expected[$name] -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) { throw "Qualified Code owner file changed: $name. $continuation" }
        [pscustomobject]@{host=$path;container=$targets[$id][$name];readOnly=$true}
    }
}

function Test-QualifiedHostCodeRepairChange {
    param([object]$Config, [object]$Server, [object]$OldRuntime)
    $spec = Get-ObjectValue -Object $Server -Name 'ownerRepair' -Default $null
    if ([string]$Server.id -cne 'code' -or -not [string](Get-ObjectValue -Object $spec -Name 'xsdFixtureSha256' -Default '')) { return $false }
    $expected = @(Get-QualifiedHostOwnerRepairMounts -Config $Config -Server $Server)
    $raw = @(Invoke-DockerCommandCapture -Arguments @('inspect','-f','{{json .Mounts}}',[string]$OldRuntime.containerName) -TimeoutSec 60 -Description 'compare qualified Code repair version') -join ''
    $mounts = $raw | ConvertFrom-Json
    foreach ($file in $expected) {
        $bindings = @($mounts | Where-Object Destination -eq $file.container)
        if ($bindings.Count -ne 1 -or $bindings[0].Type -cne 'bind' -or $bindings[0].RW -ne $false) { return $true }
        $actual = [string]$bindings[0].Source
        if ($actual -match '^/(?:run/desktop/mnt/host|host_mnt)/([a-z])/(.+)$') { $actual=$Matches[1]+':\'+$Matches[2].Replace('/','\') }
        if ((Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $file.host -Algorithm SHA256).Hash) { return $true }
    }
    return $false
}

function Assert-QualifiedHostOwnerRepairMounts {
    param([object]$Config, [object]$Server, [object]$Runtime)
    $expected = @(Get-QualifiedHostOwnerRepairMounts -Config $Config -Server $Server)
    if ($expected.Count -eq 0) { return }
    $raw = @(Invoke-DockerCommandCapture -Arguments @('inspect','-f','{{json .Mounts}}',[string]$Runtime.containerName) -TimeoutSec 60 -Description 'verify qualified native host owner mounts') -join ''
    $mounts = $raw | ConvertFrom-Json
    foreach ($file in $expected) {
        $bindings = @($mounts | Where-Object Destination -eq $file.container)
        if ($bindings.Count -ne 1 -or $bindings[0].Type -cne 'bind' -or $bindings[0].RW -ne $false) { throw "Qualified Code owner must be mounted once, read-only: $($file.container). Preserve the runtime and restore its qualified mount before retrying." }
        $actual = [string]$bindings[0].Source
        # Docker Desktop can expose the same Windows bind through its VM path.
        if ($actual -match '^/(?:run/desktop/mnt/host|host_mnt)/([a-z])/(.+)$') { $actual=$Matches[1]+':\'+$Matches[2].Replace('/','\') }
        if ([IO.Path]::GetFullPath($actual) -ine [IO.Path]::GetFullPath([string]$file.host)) { throw 'Qualified Code owner is mounted from another file; preserve the runtime and restore the exact qualified mount before retrying.' }
    }
}

function Set-QualifiedHostOwnerRepairComposeText {
    param([object]$Config, [object]$Server, [string]$ComposeText)
    $files = @(Get-QualifiedHostOwnerRepairMounts -Config $Config -Server $Server)
    if ($files.Count -eq 0) { return $ComposeText }
    $pattern = '(?ms)^  mcp-app:\r?\n.*?(?=^  [a-zA-Z0-9_-]+:|\z)'
    $services = [regex]::Matches($ComposeText, $pattern)
    if ($services.Count -ne 1 -or [regex]::Matches($services[0].Value, '(?m)^    volumes:\r?$').Count -ne 1) { throw 'Qualified Graph owner needs the declared mcp-app volumes; reconcile the versioned compose and repeat stable-preflight.' }
    $entries = ''
    foreach ($file in $files) {
        if ($services[0].Value.Contains([string]$file.container)) { throw 'Qualified owner target already exists in compose; reconcile its exact mount before retrying.' }
        # JSON strings are valid YAML scalars. Escape Compose interpolation too.
        $source = ConvertTo-Json -InputObject ([string]$file.host).Replace('$','$$') -Compress
        $entries += "      - type: bind`n        source: $source`n        target: $($file.container)`n        read_only: true`n        bind:`n          create_host_path: false`n"
    }
    $service = [regex]::Replace($services[0].Value, '(?m)^    volumes:\r?\n', [System.Text.RegularExpressions.MatchEvaluator]{param($match) $match.Value+$entries})
    return $ComposeText.Substring(0,$services[0].Index)+$service+$ComposeText.Substring($services[0].Index+$services[0].Length)
}
