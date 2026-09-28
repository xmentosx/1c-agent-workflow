# Retained-store support for the existing cutover transaction. No separate state
# machine: its context owns these records and rollback runs under the same lease.
function Get-RetainedIndexMounts {
    param([object]$Config, [object]$Context)
    $bindings = @(Get-BetaProjectVolumes -Config $Config -Server $Context.betaServer -ConfigState $Context.configState)
    if ($Context.serverId -in @("code", "graph")) {
        if ($bindings.Count -eq 0) { throw "Stable Code/Graph requires an explicit retained indexProfile. Bind the accepted volumes before retrying stable-preflight." }
        Initialize-BetaProjectVolumes -Config $Config -Context $Context -InspectOnly -RequireExisting
    } else {
        $path = switch ($Context.serverId) { docs { "/app/index" }; templates { "/app/chroma_db" }; ssl { "/app/zvec_db" } }
        if (-not $path) { return @() }
        $bindings = @([pscustomobject]@{ name = (Get-BetaVolumePath -Config $Config -Context $Context -ContainerPath $path); container = $path; role = "index" })
    }
    $result = @()
    foreach ($binding in $bindings) {
        $container = if ($binding.role -eq "neo4j") { "$($Context.old.containerName)-neo4j" } else { [string]$Context.old.containerName }
        $json = @(Invoke-DockerCommandCapture -Arguments @("inspect", "-f", "{{json .Mounts}}", $container) -TimeoutSec 60 -Description "inspect accepted index binding") -join ""
        $decoded = ConvertFrom-Json -InputObject $json
        $mounts = @($decoded | Where-Object { $_.Destination -eq $binding.container })
        if ($mounts.Count -ne 1 -or -not $mounts[0].RW) { throw "Accepted '$container' index mount is missing, ambiguous or read-only. Reconcile it before stable-preflight." }
        $mount = $mounts[0]
        if ($Context.serverId -in @("code", "graph")) {
            if ($mount.Type -ne "volume" -or $mount.Name -cne $binding.name) { throw "Retained volume differs from the running accepted index. Restore the exact profile binding before retrying." }
        } else {
            $source = ([string]$mount.Source).Replace('/', '\').TrimEnd('\')
            if ($mount.Type -ne "bind" -or $source -ine ([string]$binding.name).Replace('/', '\').TrimEnd('\')) { throw "Retained Windows index path differs from the running accepted index. Reconcile the versioned manifest before retrying." }
            [void](Assert-BetaPathUnderStateRoot -Config $Config -Path $source)
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Accepted retained index path is missing: $source" }
        }
        $result += [pscustomobject]@{ role = $binding.role; type = [string]$mount.Type; source = [string]$binding.name; destination = $binding.container; oldContainer = $container }
    }
    return $result
}

function Assert-RetainedIndexStopped {
    param([object]$Context)
    $names = @([string]$Context.old.containerName, [string]$Context.runtime.containerName)
    if ($Context.serverId -eq "graph") { $names += @("$($Context.old.containerName)-neo4j", "$($Context.runtime.containerName)-neo4j") }
    foreach ($name in $names) {
        if ((Get-HostContainerPublishState -ContainerName $name) -notin @("missing", "exited", "created")) {
            # Unknown, paused and restarting are not proof of quiescence.
            throw "Index snapshot requires stopped containers: '$name'. Complete the existing cutover/rollback before retrying."
        }
    }
}

function Invoke-RetainedIndexSnapshot {
    param([object]$Config, [object]$Context, [object]$Record, [ValidateSet("save", "restore")][string]$Operation)
    Assert-RetainedIndexStopped -Context $Context
    $folder = Assert-BetaPathUnderStateRoot -Config $Config -Path $Record.folder
    $scriptPath = Join-Path $PSScriptRoot "index-snapshot.py"
    $indexMount = "type=$($Record.type),source=$($Record.source),target=/index"
    if ($Operation -eq "save") { $indexMount += ",readonly" }
    $helperName = "itl-index-snapshot-" + [guid]::NewGuid().ToString("N")
    $args = @("run", "--rm", "--name", $helperName, "--network", "none", "--read-only", "--user", "0:0", "--entrypoint", "python",
        "--mount", $indexMount, "--mount", "type=bind,source=$folder,target=/snapshot",
        "--mount", "type=bind,source=$scriptPath,target=/snapshot-tool.py,readonly",
        [string]$Context.runtime.image, "/snapshot-tool.py", $Operation)
    if ($Operation -eq "restore") { $args += @("--sha256", [string]$Record.sha256) }
    try {
        $lines = @(Invoke-DockerCommandCapture -Arguments $args -TimeoutSec 14400 -Description "$Operation retained MCP index snapshot")
    } finally {
        # A timed-out Docker client does not stop its container. Complete this
        # owned copy before the coordinator can restore or start either main.
        if ((Get-HostContainerPublishState -ContainerName $helperName) -ne "missing") {
            Invoke-DockerCommandChecked -Arguments @("rm", "-f", $helperName) -TimeoutSec 180 -Description "stop owned index snapshot helper"
        }
    }
    $proof = ConvertFrom-Json -InputObject ($lines -join "`n")
    if ([string]$proof.sha256 -notmatch '^[a-f0-9]{64}$') { throw "Index snapshot did not return an SHA256 proof. Keep the snapshot and inspect the operation before retrying." }
    return $proof
}

function Save-RetainedIndexSnapshot {
    param([object]$Config, [object]$Context)
    $mounts = @(Get-RetainedIndexMounts -Config $Config -Context $Context)
    $Context | Add-Member -NotePropertyName snapshots -NotePropertyValue @() -Force
    $Context | Add-Member -NotePropertyName snapshotReady -NotePropertyValue $false -Force
    if ($mounts.Count -eq 0) { $Context.snapshotReady = $true; return }
    Assert-RetainedIndexStopped -Context $Context
    $root = Assert-BetaPathUnderStateRoot -Config $Config -Path (Join-Path (Join-Path (Get-StateRoot -Config $Config) "snapshots") ("cutover-" + [guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $root | Out-Null
    # Protect before any source content is written. No elevation or inherited access.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new("S-1-5-18"))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow"))
    }
    $directory = [IO.DirectoryInfo]::new($root)
    if ($PSVersionTable.PSEdition -eq "Core") { [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl) } else { $directory.SetAccessControl($acl) }
    $Context | Add-Member -NotePropertyName snapshotRoot -NotePropertyValue $root -Force
    foreach ($mount in $mounts) {
        $record = Convert-ToHash -Object $mount
        $record.folder = Join-Path $root $mount.role
        New-Item -ItemType Directory -Path $record.folder | Out-Null
        $proof = Invoke-RetainedIndexSnapshot -Config $Config -Context $Context -Record $record -Operation save
        $record.sha256 = [string]$proof.sha256
        $record.bytes = [long]$proof.bytes
        $Context.snapshots += [pscustomobject]$record
        Write-JsonFile -Path (Join-Path $root "snapshot.json") -Value @{ oldContainer = $Context.old.containerName; candidate = $Context.runtime.containerName; image = $Context.runtime.image; manifestPath = $Context.runtime.manifestPath; complete = $false; records = $Context.snapshots }
    }
    $Context.snapshotReady = $true
    Write-JsonFile -Path (Join-Path $root "snapshot.json") -Value @{ oldContainer = $Context.old.containerName; candidate = $Context.runtime.containerName; image = $Context.runtime.image; manifestPath = $Context.runtime.manifestPath; complete = $true; records = $Context.snapshots }
}

function Restore-RetainedIndexSnapshot {
    param([object]$Config, [object]$Context)
    if (-not [bool](Get-ObjectValue -Object $Context -Name "candidateStarted" -Default $false)) { return }
    if (-not [bool](Get-ObjectValue -Object $Context -Name "snapshotReady" -Default $false)) { throw "Candidate started without a complete snapshot. Keep both runtimes stopped and inspect the retained snapshot proof." }
    Assert-RetainedIndexStopped -Context $Context
    $actual = @(Get-RetainedIndexMounts -Config $Config -Context $Context)
    foreach ($record in $Context.snapshots) {
        $match = @($actual | Where-Object { $_.role -eq $record.role -and $_.source -eq $record.source -and $_.type -eq $record.type -and $_.oldContainer -eq $record.oldContainer })
        if ($match.Count -ne 1) { throw "Snapshot restore binding changed; restore the recorded mount identity before retrying rollback." }
        [void](Invoke-RetainedIndexSnapshot -Config $Config -Context $Context -Record $record -Operation restore)
    }
}
