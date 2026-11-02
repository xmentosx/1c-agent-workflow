# The host owns scheduling/Windows capacity. Native owners retain index authority.
function Get-McpStorageSettings {
    param($Config)
    $raw=Get-ObjectValue $Config 'storageRetention' @{}
    $values=@{enabled=$false;lowSpaceGiB=50;reserveGiB=20;cacheTargetGiB=10;cacheUnusedDays=7;minimumAgeDays=14;keepAccepted=2;cleanupIntervalHours=24;vhdPath='';compactEnabled=$false;compactDay='Sunday';compactAt='03:30';compactWindowMinutes=30;compactMinimumGiB=10}
    foreach($key in @($values.Keys)){$values[$key]=Get-ObjectValue $raw $key $values[$key]}
    foreach($key in @('lowSpaceGiB','reserveGiB','cacheTargetGiB','cacheUnusedDays','minimumAgeDays','keepAccepted','cleanupIntervalHours','compactWindowMinutes','compactMinimumGiB')){
        if([double]$values[$key] -le 0){throw "Invalid storageRetention.$key"}
    }
    if([int]$values.keepAccepted -lt 2 -or [int]$values.minimumAgeDays -lt 14){throw 'Retention must preserve at least two accepted transitions and fourteen days'}
    if([string]$values.compactAt -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' -or [string]$values.compactDay -notin [Enum]::GetNames([DayOfWeek])){throw 'Invalid storage maintenance window'}
    if([double]$values.lowSpaceGiB -lt [double]$values.reserveGiB){throw 'Low-space threshold must include the reserve'}
    return $values
}

function Get-McpStorageFreeBytes {
    param($Config)
    # This is the Windows volume containing state, never Linux df inside a VHD.
    return [IO.DriveInfo]::new([IO.Path]::GetPathRoot((Get-StateRoot $Config))).AvailableFreeSpace
}

function Get-McpStorageRecord {
    param($Config)
    return (Convert-ToHash (Get-ObjectValue (Read-HostState $Config) 'storageRetention' @{}))
}

function Save-McpStorageRecord {
    param($Config,$Record)
    $state=Convert-ToHash (Read-HostState $Config)
    $state.storageRetention=$Record
    Write-HostState -Config $Config -State $state
}

function Invoke-McpStorageDocker {
    param([string[]]$Arguments,[int]$TimeoutSec=60)
    $r=Invoke-ProcessWithTimeout -FilePath docker -Arguments $Arguments -TimeoutSec $TimeoutSec -Description 'MCP storage owner operation'
    if($r.exitCode){throw ('Docker storage operation failed: '+($r.lines -join '; '))}
    return @($r.lines)
}

function Get-McpStorageContainers {
    $ids=@(Invoke-McpStorageDocker @('ps','-aq','--no-trunc'))
    if(-not $ids.Count){return @()}
    # Inspect only identities and mounts. Environment variables may contain secrets.
    $rows=@()
    for($offset=0;$offset -lt $ids.Count;$offset+=128){
        $batch=@($ids|Select-Object -Skip $offset -First 128)
        $rows+=Invoke-McpStorageDocker (@('inspect','--format','{{json .Id}}|{{json .Name}}|{{json .Image}}|{{json .State.Running}}|{{json .Mounts}}')+$batch)
    }
    return @(foreach($row in $rows){
        $parts=$row -split '\|',5
        if($parts.Count -ne 5){throw 'Unrecognized container inventory'}
        [pscustomobject]@{id=($parts[0]|ConvertFrom-Json);name=($parts[1]|ConvertFrom-Json).TrimStart('/');image=($parts[2]|ConvertFrom-Json);running=($parts[3]|ConvertFrom-Json);mounts=@($parts[4]|ConvertFrom-Json)}
    })
}

function Test-McpStorageOwnersIdle {
    param($Config,[switch]$ForOffline)
    if(Test-McpHostNightlyPriorityLockActive $Config){return $false}
    $trackedServers=@(As-Array (Get-ObjectValue (Read-HostState $Config) 'servers' @()))
    if($ForOffline){
        $allowed=@(foreach($server in $trackedServers){
            [string](Get-ObjectValue $server 'containerName' '')
            [string](Get-ObjectValue $server 'proxyContainerName' '')
            if((Get-ObjectValue $server 'id' '') -eq 'graph'){[string]$server.containerName+'-neo4j'}
        })
        if(@(Get-McpStorageContainers|Where-Object {$_.running -and $_.name -notin $allowed}).Count){return $false}
    }
    foreach($server in $trackedServers){
        $id=[string](Get-ObjectValue $server 'id' '')
        if($id -in @('mantis','bookstack','sppr')){
            $connection=Open-HostMcpConnection -Url ([string]$server.url) -ExactEndpoint
            try{
                $tool=switch($id){mantis {'index_control'} bookstack {'index_status'} sppr {'sppr_index_status'}}
                $response=Invoke-HostMcpTool -Connection $connection -Name $tool -Arguments $(if($id -eq 'mantis'){@{action='status';actor='itl-host-storage'}}else{@{}}) -TimeoutSec 15
                $payload=Get-ObjectValue $response 'structuredContent' $null
                if($null -eq $payload){return $false}
                if($id -eq 'mantis' -and (Get-ObjectValue $payload 'work_in_progress' $true)){return $false}
                if($id -eq 'bookstack' -and (Get-ObjectValue $payload 'index_in_progress' $true)){return $false}
                if($id -eq 'sppr'){
                    if((Get-ObjectValue $payload 'state' '') -ne 'available'){return $false}
                    if((Get-ObjectValue (Get-ObjectValue $payload 'last_attempt' $null) 'state' '') -eq 'running' -or
                       (Get-ObjectValue (Get-ObjectValue $payload 'last_embedding_attempt' $null) 'state' '') -eq 'running'){return $false}
                }
            }finally{Close-HostMcpConnection $connection}
            continue
        }
        if($id -notin @('code','graph')){continue}
        $activity=Get-BetaConfigurationIndexActivity -ServerId $id -Url ([string]$server.url) -ExactEndpoint -TimeoutSec 15
        if($null -eq $activity -or $activity.running){return $false}
    }
    # Engine jobs not owned by this host must not be interrupted either.
    return (Test-McpStorageBuildsIdle)
}

function Test-McpStorageBuildsIdle {
    $builds=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -match '^(docker|docker-buildx)\.exe$' -and $_.CommandLine -match '(?i)\b(build|bake)\b'})
    return ($builds.Count -eq 0)
}

function Get-McpStorageMountedPeak {
    param([string]$ContainerName,[double]$Copies=1,[string]$HelperImage='')
    $json=@(Invoke-McpStorageDocker @('inspect','--format','{"image":{{json .Image}},"mounts":{{json .Mounts}}}',$ContainerName)) -join ''
    $container=$json|ConvertFrom-Json
    if(-not $HelperImage){$HelperImage=[string]$container.image}
    $bytes=0L
    foreach($mount in $container.mounts){
        if(-not $mount.RW -or $mount.Destination -match '(?i)(model|cache)' -or $mount.Type -notin @('bind','volume')){continue}
        $source=if($mount.Type -eq 'volume'){$mount.Name}else{$mount.Source}
        $binding='type='+$mount.Type+',source='+$source+',target=/index,readonly'
        $code='import os; total=0; count=0
for root,dirs,files in os.walk("/index",followlinks=False):
 for name in files:
  total+=os.lstat(os.path.join(root,name)).st_size; count+=1
print(total+count*8192+1048576)'
        $helper='itl-storage-estimate-'+[guid]::NewGuid().ToString('N')
        try{
            $value=@(Invoke-McpStorageDocker @('run','--rm','--name',$helper,'--network','none','--entrypoint','python','--mount',$binding,$HelperImage,'-c',$code) -TimeoutSec 90)
            if($value.Count -ne 1 -or $value[0] -notmatch '^\d+$'){throw 'Cannot estimate the existing data peak; inspect this owner before repeating the operation'}
            $bytes+=[long]$value[0]
        }finally{
            if((Get-HostContainerPublishState $helper) -ne 'missing'){[void](Invoke-McpStorageDocker @('rm','-f',$helper))}
        }
    }
    return [long][math]::Ceiling($bytes*$Copies*1.1)
}

function Test-McpStoragePrivateCache {
    param($Row)
    return ($Row.ID -match '^[a-z0-9]{25}$' -and $Row.Reclaimable -is [bool] -and $Row.Reclaimable -and
        $Row.Shared -is [bool] -and -not $Row.Shared -and $Row.Mutable -is [bool] -and -not $Row.Mutable)
}

function ConvertFrom-McpStorageSize {
    param([string]$Value)
    # Older buildx JSON uses human SI sizes, newer versions emit byte strings.
    # Never parse relative/localized ages; until is enforced by BuildKit below.
    if($Value -notmatch '^(?<number>\d+(?:\.\d+)?)(?<unit>B|[KMGTPE]i?B)?$'){throw 'Unrecognized buildx size; retain cache and inspect storage-plan'}
    $number=[decimal]::Parse($Matches.number,[Globalization.CultureInfo]::InvariantCulture)
    $unit=([string]$Matches['unit']).ToLowerInvariant()
    $power=switch -Regex ($unit){'^k' {1} '^m' {2} '^g' {3} '^t' {4} '^p' {5} '^e' {6} default {0}}
    $base=if($unit.Contains('i')){1024}else{1000}
    return [long][math]::Ceiling($number*[math]::Pow($base,$power))
}

function Get-McpStorageCachePlan {
    param($Settings)
    $rows=@(Invoke-McpStorageDocker @('buildx','du','--builder','desktop-linux','--format','json') | ForEach-Object {$_|ConvertFrom-Json})
    $age='until='+([int]$Settings.cacheUnusedDays*24)+'h'
    $old=@(Invoke-McpStorageDocker @('buildx','du','--builder','desktop-linux','--format','json','--filter',$age) | ForEach-Object {$_|ConvertFrom-Json})
    $private=@($rows|Where-Object {Test-McpStoragePrivateCache $_})
    $remaining=0L
    foreach($row in $private){$remaining+=ConvertFrom-McpStorageSize ([string]$row.Size)}
    $eligible=@($old|Where-Object {Test-McpStoragePrivateCache $_}|ForEach-Object {
        $_|Add-Member -NotePropertyName SizeBytes -NotePropertyValue (ConvertFrom-McpStorageSize ([string]$_.Size)) -Force -PassThru
    }|Sort-Object SizeBytes -Descending)
    $selected=@()
    foreach($row in $eligible){
        if($remaining -le [double]$Settings.cacheTargetGiB*1GB -or $selected.Count -ge 128){break}
        $selected+=$row;$remaining-=[long]$row.SizeBytes
    }
    return @($selected|ForEach-Object {@{ID=$_.ID;SizeBytes=$_.SizeBytes;reason='native-until-private-reclaimable'}})
}

function Invoke-McpStorageCacheCollection {
    param($Settings,$Plan)
    if(-not @($Plan).Count){return @{candidates=0;removed=0}}
    $ids=@($Plan|ForEach-Object {$_.ID})
    $filter='id~=^('+($ids -join '|')+')$'
    $age='until='+([int]$Settings.cacheUnusedDays*24)+'h'
    $fresh=@(Invoke-McpStorageDocker @('buildx','du','--builder','desktop-linux','--format','json','--filter',$filter,'--filter',$age)|ForEach-Object {$_|ConvertFrom-Json})
    foreach($row in $fresh){
        if($row.ID -notin $ids -or -not (Test-McpStoragePrivateCache $row)){throw 'Cache eligibility changed; preserve the entire planned batch'}
    }
    if(-not $fresh.Count){return @{candidates=$ids.Count;removed=0}}
    # Do not use boolean CLI filters: their behavior differs between installed versions.
    $output=Invoke-McpStorageDocker @('buildx','prune','--builder','desktop-linux','--force','--filter',$filter,'--filter',$age) -TimeoutSec 300
    return @{candidates=$ids.Count;removed=$fresh.Count;summary=@($output|Select-Object -Last 1)}
}

function Assert-McpStorageSnapshotPath {
    param($Config,[string]$Path)
    $parent=[IO.Path]::GetFullPath((Join-Path (Get-StateRoot $Config) 'snapshots')).TrimEnd('\','/')
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full) -cne $parent -or [IO.Path]::GetFileName($full) -notmatch '^cutover-[a-f0-9]{32}$'){throw 'Snapshot is outside the exact owned cutover directory'}
    foreach($p in @((Get-StateRoot $Config),$parent,$full)){
        if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Snapshot path contains a reparse point'}
    }
    return $full
}

function Get-McpStorageRetirementPlan {
    param($Config,$Settings,$Record,[datetime]$Now=(Get-Date))
    $entries=@(As-Array (Get-ObjectValue $Record 'accepted' @()))
    $result=@()
    # PS 5.1 does not resolve named hashtable keys consistently in grouping/sorting.
    foreach($group in $entries|Group-Object {Get-ObjectValue $_ 'service' ''}){
        $ordered=@($group.Group|Sort-Object {[datetime](Get-ObjectValue $_ 'acceptedAt' '')} -Descending)
        $position=0
        foreach($entry in $ordered){
            $reason='eligible'
            $accepted=(Get-ObjectValue $entry 'status' '') -in @('accepted','snapshot-retired') -and (Get-ObjectValue $entry 'qualification' '') -eq 'native-cutover-and-control-restart'
            if(-not $accepted){$reason='protected'}
            elseif($position -lt [int]$Settings.keepAccepted){$reason='latest-accepted'}
            elseif(([datetime]$entry.acceptedAt) -gt $Now.AddDays(-[double]$Settings.minimumAgeDays)){$reason='minimum-age'}
            elseif(Get-ObjectValue $entry 'pinned' $false){$reason='protected'}
            $result+=@{entry=$entry;reason=$reason}
            if($accepted){$position++}
        }
    }
    return $result
}

function Get-McpStorageLegacySnapshots {
    param($Config,$Record)
    $root=Join-Path (Get-StateRoot $Config) 'snapshots'
    if(-not (Test-Path -LiteralPath $root)){return @()}
    $known=@(As-Array (Get-ObjectValue $Record 'accepted' @())|ForEach-Object {$_.snapshotPath})
    return @(Get-ChildItem -LiteralPath $root -Directory -Force|Where-Object {$_.FullName -notin $known}|ForEach-Object {@{path=$_.FullName;status='protected';reason='not-enrolled-by-full-acceptance-owner'}})
}

function Remove-McpStorageSnapshot {
    param($Config,$Entry)
    $path=Assert-McpStorageSnapshotPath $Config ([string]$Entry.snapshotPath)
    $manifestPath=Join-Path $path 'snapshot.json'
    if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $Entry.manifestSha256){throw 'Snapshot manifest changed; preserve its data'}
    $manifest=Read-JsonFile $manifestPath
    if(-not $manifest.complete){throw 'Incomplete snapshot remains protected'}
    $children=@(Get-ChildItem -LiteralPath $path -Force -Recurse)
    if(@($children|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Snapshot contains a reparse point'}
    $expected=@($manifestPath)
    foreach($part in $manifest.records){
        $archive=[IO.Path]::GetFullPath((Join-Path ([string]$part.folder) 'index.tar'))
        if(-not $archive.StartsWith($path+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Snapshot archive escaped its owner directory'}
        $expected+=$archive
        if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$part.sha256){throw 'Snapshot archive integrity changed'}
    }
    if(@($children|Where-Object {-not $_.PSIsContainer -and $_.FullName -notin $expected}).Count){throw 'Snapshot contains unrecorded evidence; retain it'}
    $retiredId=[string](Get-ObjectValue $Entry 'retiredContainer' '')
    if($retiredId){
        $fresh=@(Get-McpStorageContainers|Where-Object id -eq $retiredId)
        if($fresh.Count -and $fresh[0].running){throw 'Retired runtime restarted during verification; keep its snapshot'}
        $current=Get-ObjectValue (Read-HostState $Config) 'servers' @()
        if(($current|ConvertTo-Json -Depth 25 -Compress).Contains([string]$Entry.retiredName)){throw 'Retired runtime became current during verification; keep its snapshot'}
    }
    # The absolute path and every descendant have been validated in this shell.
    Remove-Item -LiteralPath $path -Recurse -Force
}

function Add-McpStorageAcceptance {
    param($Config,$Context)
    $settings=Get-McpStorageSettings $Config
    if(-not $settings.enabled -or -not (Get-ObjectValue $Context 'snapshotReady' $false) -or -not (Get-ObjectValue $Context 'storageRestartQualified' $false)){return}
    $path=[string](Get-ObjectValue $Context 'snapshotRoot' '')
    if(-not $path){return}
    $path=Assert-McpStorageSnapshotPath $Config $path
    $manifest=Join-Path $path 'snapshot.json'
    if(-not (Read-JsonFile $manifest).complete){throw 'Cannot enroll an incomplete snapshot'}
    $containers=Get-McpStorageContainers
    $old=@($containers|Where-Object name -eq ([string]$Context.old.containerName))
    if($old.Count -ne 1 -or $old[0].running){throw 'Retired deployment identity is not stable'}
    $record=Get-McpStorageRecord $Config
    $accepted=@(As-Array (Get-ObjectValue $record 'accepted' @()))
    if(@($accepted|Where-Object snapshotPath -eq $path).Count){return}
    $entry=@{service=([string]$Context.configId+'/'+[string]$Context.serverId);acceptedAt=(Get-Date).ToString('o');status='accepted';snapshotPath=$path;manifestSha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash;retiredContainer=$old[0].id;retiredName=$old[0].name;retiredImage=$old[0].image;qualification='native-cutover-and-control-restart';pinned=$false}
    $entry.retiredContainers=@($old)
    if($Context.serverId -eq 'graph'){
        $aux=@($containers|Where-Object name -eq ([string]$Context.old.containerName+'-neo4j'))
        if($aux.Count -ne 1 -or $aux[0].running){throw 'Retired Neo4j identity is not stable'}
        $entry.retiredContainers+=@($aux)
    }
    $entry.retiredVolumes=@()
    foreach($binding in @($Context.snapshots|Where-Object {$_.type -eq 'volume' -and $_.role -in @('index','neo4j')})){
        $volume=(@(Invoke-McpStorageDocker @('volume','inspect',[string]$binding.source)) -join '')|ConvertFrom-Json
        $volume=@($volume)[0]
        if($volume.Driver -eq 'local' -and (Convert-ToHash $volume.Options).Count -eq 0 -and (Get-ObjectValue $volume 'CreatedAt' '')){
            $entry.retiredVolumes+=@(@{name=$volume.Name;driver=$volume.Driver;createdAt=$volume.CreatedAt;role=$binding.role})
        }
    }
    $record.accepted=$accepted+@($entry)
    Save-McpStorageRecord $Config $record
}

function Invoke-McpStorageRetirement {
    param($Config,$Settings,$Record)
    $removed=0
    foreach($candidate in Get-McpStorageRetirementPlan $Config $Settings $Record){
        if($candidate.reason -ne 'eligible'){continue}
        $entry=$candidate.entry
        $stateText=(Read-HostState $Config).servers|ConvertTo-Json -Depth 25 -Compress
        if($stateText.Contains([string]$entry.retiredName) -or $stateText.Contains([string]$entry.retiredContainer)){continue}
        $containers=Get-McpStorageContainers
        $old=@($containers|Where-Object id -eq $entry.retiredContainer)
        if($old.Count -gt 1 -or ($old.Count -and ($old[0].running -or $old[0].name -cne $entry.retiredName -or $old[0].image -cne $entry.retiredImage))){continue}
        # A restart after interruption may already have removed the snapshot.
        if(Test-Path -LiteralPath $entry.snapshotPath){Remove-McpStorageSnapshot $Config $entry}
        # All remaining snapshots, including immutable legacy/failed ones, protect their runtimes.
        $referenced=$false
        foreach($directory in Get-ChildItem -LiteralPath (Join-Path (Get-StateRoot $Config) 'snapshots') -Directory){
            $manifest=Join-Path $directory.FullName 'snapshot.json'
            if(-not (Test-Path -LiteralPath $manifest)){$referenced=$true;break}
            $text=Read-Text $manifest
            if($text.Contains([string]$entry.retiredName) -or $text.Contains([string]$entry.retiredImage)){$referenced=$true;break}
        }
        if(-not $referenced){
            foreach($resource in As-Array (Get-ObjectValue $entry 'retiredContainers' @($old))){
                $fresh=@(Get-McpStorageContainers|Where-Object id -eq $resource.id)
                if(-not $fresh.Count){continue}
                if($fresh[0].running -or $fresh[0].name -cne $resource.name -or $fresh[0].image -cne $resource.image){$referenced=$true;continue}
                if($stateText.Contains([string]$resource.name)){$referenced=$true;continue}
                # No force: a concurrent start must fail removal rather than kill a process.
                [void](Invoke-McpStorageDocker @('rm',[string]$resource.id))
                $remaining=Get-McpStorageContainers
                if(-not @($remaining|Where-Object image -eq $resource.image).Count -and -not @(Get-McpStorageLegacySnapshots $Config $Record).Count){
                    $images=@(Invoke-McpStorageDocker @('image','ls','--no-trunc','--quiet'))
                    if([string]$resource.image -in $images){[void](Invoke-McpStorageDocker @('image','rm',[string]$resource.image))}
                }
            }
            foreach($binding in As-Array (Get-ObjectValue $entry 'retiredVolumes' @())){
                $remaining=Get-McpStorageContainers
                if(@($remaining|Where-Object {@($_.mounts|Where-Object {$_.Type -eq 'volume' -and $_.Name -ceq $binding.name}).Count}).Count){continue}
                $volumeReferenced=$false
                foreach($directory in Get-ChildItem -LiteralPath (Join-Path (Get-StateRoot $Config) 'snapshots') -Directory){
                    $manifest=Join-Path $directory.FullName 'snapshot.json'
                    if(-not (Test-Path -LiteralPath $manifest) -or (Read-Text $manifest).Contains([string]$binding.name)){$volumeReferenced=$true;break}
                }
                if($volumeReferenced -or $binding.role -notin @('index','neo4j')){continue}
                $volumeNames=@(Invoke-McpStorageDocker @('volume','ls','--quiet'))
                if([string]$binding.name -notin $volumeNames){continue}
                $fresh=(@(Invoke-McpStorageDocker @('volume','inspect',[string]$binding.name)) -join '')|ConvertFrom-Json
                $fresh=@($fresh)[0]
                if($fresh.Driver -ceq $binding.driver -and $fresh.CreatedAt -ceq $binding.createdAt -and (Convert-ToHash $fresh.Options).Count -eq 0){
                    [void](Invoke-McpStorageDocker @('volume','rm',[string]$binding.name))
                }
            }
        }
        $entry.status=if($referenced){'snapshot-retired'}else{'retired'};$removed++
        Save-McpStorageRecord $Config $Record
    }
    return $removed
}

function Test-McpStorageCompactionWindow {
    param($Settings,$Record,[datetime]$Now=(Get-Date))
    $start=[TimeSpan]::ParseExact([string]$Settings.compactAt,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture)
    return ($Settings.compactEnabled -and [string]$Now.DayOfWeek -eq [string]$Settings.compactDay -and $Now.TimeOfDay -ge $start -and $Now.TimeOfDay -lt $start.Add([TimeSpan]::FromMinutes([double]$Settings.compactWindowMinutes)) -and (Get-ObjectValue $Record 'lastCompactionDate' '') -ne $Now.ToString('yyyy-MM-dd'))
}

function Get-McpStorageVhdReclaimEstimate {
    param($Settings)
    $r=Invoke-ProcessWithTimeout -FilePath wsl.exe -Arguments @('-d','docker-desktop','--exec','/bin/sh','-c','df -B1 /mnt/docker-desktop-disk | tail -n 1') -TimeoutSec 20 -Description 'estimate detached Docker VHD reclaim benefit'
    if($r.exitCode -or $r.lines.Count -ne 1){throw 'Cannot estimate Docker data allocation; skip offline reclaim'}
    $fields=([string]$r.lines[0]).Trim() -split '\s+'
    if($fields.Count -lt 6 -or $fields[2] -notmatch '^\d+$'){throw 'Unrecognized Docker filesystem accounting'}
    return [math]::Max(0,((Get-Item -LiteralPath ([string]$Settings.vhdPath)).Length-[long]$fields[2]))
}

function Invoke-McpStorageVhdCompaction {
    param($Config,$Settings,$Record)
    $path=Get-FullPath ([string]$Settings.vhdPath)
    if(-not [string]$Settings.vhdPath -or [IO.Path]::GetExtension($path) -ne '.vhdx'){throw 'Set an exact storageRetention.vhdPath before compaction'}
    if(-not (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)){throw 'Optimize-VHD is unavailable; retain serving MCPs and provision the optional native capability separately'}
    if(-not (Test-McpStorageOwnersIdle $Config -ForOffline)){return @{status='deferred';reason='A native owner or unrelated Docker container is active'}}
    $running=@(Get-McpStorageContainers|Where-Object running|ForEach-Object {$_.id})
    $before=(Get-Item -LiteralPath $path).Length
    $stopAttempted=$false
    try{
        if(-not (Test-McpStorageOwnersIdle $Config -ForOffline)){throw 'Index work started before compaction; preserve serving MCPs'}
        $trim=Invoke-ProcessWithTimeout -FilePath wsl.exe -Arguments @('-d','docker-desktop','--exec','/bin/sh','-c','fstrim -v /mnt/docker-desktop-disk') -TimeoutSec 180 -Description 'trim only free Docker filesystem blocks'
        if($trim.exitCode){throw 'Docker guest trim failed; preserve serving MCPs'}
        if(-not (Test-McpStorageOwnersIdle $Config -ForOffline)){return @{status='deferred';reason='An owner became active during trim'}}
        $record.lastCompactionDate=(Get-Date).ToString('yyyy-MM-dd')
        Save-McpStorageRecord $Config $Record # One offline attempt, even after interruption.
        $stopAttempted=$true
        [void](Invoke-McpStorageDocker @('desktop','stop','--timeout','120') -TimeoutSec 150)
        if((Get-VHD -Path $path -ErrorAction Stop).Attached){throw 'Docker VHD is still attached; compaction skipped'}
        $exclusive=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
        Optimize-VHD -Path $path -Mode Pretrimmed -ErrorAction Stop
        return @{beforeBytes=$before;afterBytes=(Get-Item -LiteralPath $path).Length}
    }finally{
        if($stopAttempted){
            try{[void](Invoke-McpStorageDocker @('desktop','start','--timeout','180') -TimeoutSec 210)}catch{Write-Warning $_.Exception.Message}
            if(-not (Wait-DockerDaemonAvailable -TimeoutSec 180 -PollSeconds 5)){throw 'Restore Engine, then repeat watchdog-run; compaction attempt remains recorded'}
            $active=@(Get-McpStorageContainers|Where-Object running|ForEach-Object {$_.id})
            $missing=@($running|Where-Object {$_ -notin $active})
            if($missing.Count){[void](Invoke-McpStorageDocker (@('start')+$missing) -TimeoutSec 180)}
        }
    }
}

function Assert-McpStorageAdmission {
    param($Config,[long]$PeakBytes=0)
    $settings=Get-McpStorageSettings $Config
    if(-not $settings.enabled -or $DryRun){return}
    if($PeakBytes -gt 0 -and -not (Test-McpStorageOwnersIdle $Config)){throw 'MCP_STORAGE_DEFERRED: another native index owner is busy. Wait for its completion, then repeat the original operation; no serving runtime was stopped.'}
    $required=$PeakBytes+[double]$settings.reserveGiB*1GB
    if((Get-McpStorageFreeBytes $Config) -ge $required){return}
    Invoke-McpHostStorageMaintenance -Config $Config -OnlineOnly -Force
    if((Get-McpStorageFreeBytes $Config) -lt $required){throw "MCP_STORAGE_DEFERRED: need $required Windows-volume bytes including operation peak and reserve. Free eligible data or expand storage, then repeat the original operation; serving MCPs remain available."}
}

function Test-McpStorageLeaseHeld {
    param($Config)
    $held=Get-Variable -Scope Script -Name McpHostMaintenanceLease -ValueOnly -ErrorAction SilentlyContinue
    if($null -eq $held -or $null -eq $held.stream -or -not $held.stream.CanWrite){return $false}
    return ([IO.Path]::GetFullPath($held.path) -ieq [IO.Path]::GetFullPath((Join-Path (Get-StateRoot $Config) 'host-maintenance.lock')))
}

function Invoke-McpHostStorageMaintenance {
    param($Config,[switch]$OnlineOnly,[switch]$Force)
    if(-not (Get-ObjectValue (Get-ObjectValue $Config 'storageRetention' @{}) 'enabled' $false) -or $DryRun){return}
    if(Test-McpStorageLeaseHeld $Config){Invoke-McpHostStorageMaintenanceCore -Config $Config -OnlineOnly:$OnlineOnly -Force:$Force;return}
    $lease=Enter-McpHostMaintenanceLock -Config $Config -Operation 'storage-retention' -WaitSeconds 0
    if(-not $lease.acquired){Write-Host 'Storage collection deferred: host maintenance is active; retry storage-run after it completes.';return}
    try{Invoke-McpHostStorageMaintenanceCore -Config $Config -OnlineOnly:$OnlineOnly -Force:$Force}
    finally{Exit-McpHostMaintenanceLock $lease}
}

function Invoke-McpHostStorageMaintenanceCore {
    param($Config,[switch]$OnlineOnly,[switch]$Force)
    try{$settings=Get-McpStorageSettings $Config}catch{
        $record=Get-McpStorageRecord $Config
        $errorText=$_.Exception.Message
        if($errorText -ne (Get-ObjectValue $record 'lastError' '')){Write-Warning "Invalid storage policy: $errorText. Correct storageRetention, then repeat storage-run; serving reconciliation continues."}
        $record.lastError=$errorText
        if(-not $DryRun){Save-McpStorageRecord $Config $record}
        return
    }
    if(-not $settings.enabled -or $DryRun){return}
    $record=Get-McpStorageRecord $Config
    $free=Get-McpStorageFreeBytes $Config
    $level=if($free -lt [double]$settings.reserveGiB*1GB){'critical'}elseif($free -lt [double]$settings.lowSpaceGiB*1GB){'low'}else{'healthy'}
    $previousLevel=Get-ObjectValue $record 'level' 'healthy'
    if($level -ne $previousLevel){Write-Warning "MCP storage threshold changed: $level; Windows free bytes=$free"}
    $record.level=$level;$record.freeBytes=$free;$record.observedAt=(Get-Date).ToString('o')
    $last=Get-ObjectValue $record 'lastCleanupAt' ''
    $due=$Force -or -not $last -or ([datetime]$last).AddHours([double]$settings.cleanupIntervalHours) -lt (Get-Date) -or ($level -ne 'healthy' -and ($level -ne $previousLevel -or -not $record.Contains('pressureAttempted')))
    try{
        if($due -and (Test-McpStorageBuildsIdle)){
                $record.lastCleanupAt=(Get-Date).ToString('o');$record.pressureAttempted=$true
                Save-McpStorageRecord $Config $record
                $record.cache=Invoke-McpStorageCacheCollection $settings (Get-McpStorageCachePlan $settings)
                $record.retired=Invoke-McpStorageRetirement $Config $settings $record
            $record.lastError=''
        }
        if(-not $OnlineOnly -and $level -ne 'healthy' -and (Test-McpStorageCompactionWindow $settings $record) -and (Test-McpStorageOwnersIdle $Config -ForOffline)){
            if((Get-McpStorageVhdReclaimEstimate $settings) -ge [double]$settings.compactMinimumGiB*1GB){
                $record.compaction=Invoke-McpStorageVhdCompaction $Config $settings $record
            }
            $record.lastError=''
        }
    }catch{
        $errorText=$_.Exception.Message
        if($errorText.Length -gt 512){$errorText=$errorText.Substring(0,512)}
        if($errorText -ne (Get-ObjectValue $record 'lastError' '')){Write-Warning "MCP storage maintenance: $errorText. Serving reconciliation continues; inspect storage-status and repeat storage-run after resolving the owner error."}
        $record.lastError=$errorText
    }
    if($level -eq 'healthy' -and $record.Contains('pressureAttempted')){$record.Remove('pressureAttempted')}
    $record.freeBytes=Get-McpStorageFreeBytes $Config
    Save-McpStorageRecord $Config $record
}
