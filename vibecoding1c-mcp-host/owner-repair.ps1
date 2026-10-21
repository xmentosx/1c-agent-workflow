# Stateless validation and mounts; cutover owns admission, replacement and rollback.
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
    $repositories = @{code='comol/1c_code_metadata_mcp';graph='comol/1c_graph_metadata'}
    $image = [string](Get-ObjectValue -Object $Server -Name 'image' -Default '')
    if (-not $targets.ContainsKey($id) -or $image -cnotmatch ('^'+[regex]::Escape($repositories[$id])+'@sha256:([a-f0-9]{64})$') -or [string]$spec.image -cne $image) { throw "Host owner repair belongs to another image. $continuation" }
    $digest = $image.Split(':')[-1]
    $root = Join-Path (Join-Path (Join-Path (Join-Path (Get-StateRoot -Config $Config) 'repairs') 'owner') $id) $digest
    $proofPath = Join-Path $root 'qualification.json'
    if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$spec.proofSha256) { throw "Code owner qualification is missing or changed. $continuation" }
    $proof = Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($proof.schemaVersion -ne 1 -or $proof.accepted -ne $true -or $proof.image -cne $image -or $proof.host -cne (Get-HostId -Config $Config) -or $proof.isolated -ne $true -or $proof.network -cne 'none' -or $proof.liveIndexMounted -ne $false -or [string]$spec.fixtureSha256 -cnotmatch '^[a-f0-9]{64}$' -or $proof.fixtureSha256 -cne [string]$spec.fixtureSha256) { throw "Host owner qualification has the wrong native invariant or scope. $continuation" }
    if ($id -eq 'code') {
    if ($proof.negativeControlReproduced -ne $true) { throw "Host owner qualification has the wrong native invariant or scope. $continuation" }
    $resume = @($proof.regression | Where-Object test -eq 'interrupted_incremental_resume')
    $selection = @($proof.regression | Where-Object test -eq 'selective_repair')
    if ($resume.Count -ne 1 -or $selection.Count -ne 1 -or $resume[0].modules -ne 2 -or $resume[0].new_function_found -ne $true -or $resume[0].ancestor_unchanged -ne $true -or $selection[0].preserves_vectors -ne $true -or $selection[0].honors_omissions -ne $true) { throw "Code owner original native regression did not pass. $continuation" }
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
    $names = ($targets[$id].Keys | Sort-Object) -join ','
    if ((($expected.Keys | Sort-Object) -join ',') -cne $names -or (($observed.Keys | Sort-Object) -join ',') -cne $names) { throw "Host owner repair must contain every exact file. $continuation" }
    foreach ($name in $targets[$id].Keys) {
        $path = Join-Path $root ($name + '.py')
        if ([string]$expected[$name] -cnotmatch '^[a-f0-9]{64}$' -or $observed[$name] -cne $expected[$name] -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) { throw "Qualified Code owner file changed: $name. $continuation" }
        [pscustomobject]@{host=$path;container=$targets[$id][$name];readOnly=$true}
    }
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
