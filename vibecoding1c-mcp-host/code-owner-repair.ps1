# Stateless validation and mounts; cutover owns admission, replacement and rollback.
function Get-QualifiedCodeOwnerRepairMounts {
    param([object]$Config, [object]$Server)
    $spec = Get-ObjectValue -Object $Server -Name 'codeOwnerRepair' -Default $null
    if ($null -eq $spec) { return @() }
    $continuation = 'Re-run the declared original crash/resume and selective-repair fixture without network or live indices under the existing host maintenance lease; stage its exact proof and files, then repeat stable-preflight.'
    $image = [string](Get-ObjectValue -Object $Server -Name 'image' -Default '')
    if ([string]$Server.id -ne 'code' -or $image -notmatch '^comol/1c_code_metadata_mcp@sha256:([a-f0-9]{64})$' -or [string]$spec.image -cne $image) { throw "Code owner repair belongs to another image. $continuation" }
    $digest = $Matches[1]
    $root = Join-Path (Join-Path (Join-Path (Get-StateRoot -Config $Config) 'repairs') 'code-owner') $digest
    $proofPath = Join-Path $root 'qualification.json'
    if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$spec.proofSha256) { throw "Code owner qualification is missing or changed. $continuation" }
    $proof = Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($proof.schemaVersion -ne 1 -or $proof.accepted -ne $true -or $proof.image -cne $image -or $proof.host -cne (Get-HostId -Config $Config) -or $proof.isolated -ne $true -or $proof.network -cne 'none' -or $proof.liveIndexMounted -ne $false -or $proof.negativeControlReproduced -ne $true -or $proof.fixtureSha256 -cne [string]$spec.fixtureSha256) { throw "Code owner qualification has the wrong native invariant or scope. $continuation" }
    $resume = @($proof.regression | Where-Object test -eq 'interrupted_incremental_resume')
    $selection = @($proof.regression | Where-Object test -eq 'selective_repair')
    if ($resume.Count -ne 1 -or $selection.Count -ne 1 -or $resume[0].modules -ne 2 -or $resume[0].new_function_found -ne $true -or $resume[0].ancestor_unchanged -ne $true -or $selection[0].preserves_vectors -ne $true -or $selection[0].honors_omissions -ne $true) { throw "Code owner original native regression did not pass. $continuation" }
    $expected = Convert-ToHash -Object $spec.files
    $observed = Convert-ToHash -Object $proof.files
    if ((($expected.Keys | Sort-Object) -join ',') -cne 'driver,main' -or (($observed.Keys | Sort-Object) -join ',') -cne 'driver,main') { throw "Code owner repair must contain both exact files. $continuation" }
    foreach ($name in @('driver','main')) {
        $path = Join-Path $root ($name + '.py')
        if ([string]$expected[$name] -cnotmatch '^[a-f0-9]{64}$' -or $observed[$name] -cne $expected[$name] -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) { throw "Qualified Code owner file changed: $name. $continuation" }
        [pscustomobject]@{host=$path;container=$(if($name -eq 'driver'){'/app/src/index_generation/driver.py'}else{'/app/src/main.py'});readOnly=$true}
    }
}

function Assert-QualifiedCodeOwnerRepairMounts {
    param([object]$Config, [object]$Server, [object]$Runtime)
    $expected = @(Get-QualifiedCodeOwnerRepairMounts -Config $Config -Server $Server)
    if ($expected.Count -eq 0) { return }
    $raw = @(Invoke-DockerCommandCapture -Arguments @('inspect','-f','{{json .Mounts}}',[string]$Runtime.containerName) -TimeoutSec 60 -Description 'verify qualified native Code owner mounts') -join ''
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
