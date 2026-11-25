BeforeAll {
    $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $HostInstaller=Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    $root=Join-Path $TestDrive ('host '+[char]0x0415+' Unicode')
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $configPath=Join-Path $root 'host.json'
    @{stateRoot=$root}|ConvertTo-Json|Set-Content -LiteralPath $configPath -Encoding UTF8
    . $HostInstaller -Action status -ConfigPath $configPath *> $null
}

Describe 'MCP storage owner retention' {
    It 'preserves the minimum accepted rollback history' {
        {Get-McpStorageSettings @{storageRetention=@{keepAccepted=1}}}|Should -Throw '*two accepted*'
        {Get-McpStorageSettings @{storageRetention=@{minimumAgeDays=1}}}|Should -Throw '*fourteen days*'
    }

    It 'retains latest, recent, pinned and failed transitions, selecting only old accepted data' {
        $now=[datetime]'2026-11-02T12:00:00Z'
        $entries=@(0..6|ForEach-Object {@{service='pm5/code';acceptedAt=$now.AddDays(-30-$_).ToString('o');status='accepted';qualification='native-cutover-and-control-restart';pinned=($_ -eq 3)}})
        $entries[4].status='failed'
        $plan=@(Get-McpStorageRetirementPlan @{} (Get-McpStorageSettings @{}) @{accepted=$entries} $now)
        @($plan|Where-Object reason -eq eligible).Count|Should -Be 3
        @($plan|Where-Object reason -eq latest-accepted).Count|Should -Be 2
        @($plan|Where-Object reason -eq protected).Count|Should -Be 2
        @($plan|Where-Object reason -eq latest-accepted)[0].entry.acceptedAt|Should -Be $entries[0].acceptedAt
        $entries[0].status='failed'
        $plan=@(Get-McpStorageRetirementPlan @{} (Get-McpStorageSettings @{}) @{accepted=$entries} $now)
        @($plan|Where-Object reason -eq latest-accepted).Count|Should -Be 2
        @($plan|Where-Object reason -eq latest-accepted)[0].entry.acceptedAt|Should -Be $entries[1].acceptedAt
        @($plan|Where-Object reason -eq protected).Count|Should -Be 3
        @((Get-McpStorageRetirementPlan @{} (Get-McpStorageSettings @{}) @{} $now)).Count|Should -Be 0
    }

    It 'never derives snapshot eligibility from an old directory alone' {
        $cfg=@{stateRoot=(Join-Path $TestDrive 'legacy')}
        $snapshot=Join-Path $cfg.stateRoot ('snapshots/cutover-'+('a'*32))
        New-Item -ItemType Directory -Path $snapshot -Force|Out-Null
        @((Get-McpStorageRetirementPlan $cfg (Get-McpStorageSettings @{}) @{})).Count|Should -Be 0
        Test-Path -LiteralPath $snapshot|Should -BeTrue
    }

    It 'rejects escaping snapshot paths before touching any data' {
        $cfg=@{stateRoot=$TestDrive}
        {Assert-McpStorageSnapshotPath $cfg (Join-Path $TestDrive '../outside')}|Should -Throw '*exact owned*'
    }

    It 'preserves unrecorded evidence and changed archives, then removes a fully verified owned snapshot' {
        $cfg=@{stateRoot=(Join-Path $TestDrive ('snapshot '+[char]0x042F+' Unicode'))}
        $path=Join-Path $cfg.stateRoot ('snapshots/cutover-'+('b'*32))
        $folder=Join-Path $path 'index'
        New-Item -ItemType Directory -Path $folder -Force|Out-Null
        $archive=Join-Path $folder 'index.tar'
        Write-Text $archive ('payload '+[char]0x0415)
        $manifest=Join-Path $path 'snapshot.json'
        Write-JsonFile $manifest @{complete=$true;records=@(@{folder=$folder;sha256=(Get-FileHash $archive).Hash.ToLowerInvariant()})}
        $entry=@{snapshotPath=$path;manifestSha256=(Get-FileHash $manifest).Hash}
        $extra=Join-Path $path 'failed-proof.txt'
        Write-Text $extra 'preserve'
        {Remove-McpStorageSnapshot $cfg $entry}|Should -Throw '*unrecorded evidence*'
        Test-Path $archive|Should -BeTrue
        Remove-Item -LiteralPath $extra
        Write-Text $archive 'changed'
        {Remove-McpStorageSnapshot $cfg $entry}|Should -Throw '*integrity changed*'
        Write-Text $archive ('payload '+[char]0x0415)
        Remove-McpStorageSnapshot $cfg $entry
        Test-Path $path|Should -BeFalse
    }

    It 'aborts a cache batch if a selected record became shared' {
        $script:CachePrunes=0
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments[1] -eq 'prune'){$script:CachePrunes++;return}
            return (@{ID=('a'*25);Reclaimable=$true;Shared=$true;Mutable=$false}|ConvertTo-Json -Compress)
        }
        {Invoke-McpStorageCacheCollection (Get-McpStorageSettings @{}) @(@{ID=('a'*25)})}|Should -Throw '*eligibility changed*'
        $script:CachePrunes|Should -Be 0
    }

    It 'treats a native empty cache plan as successful collection without Docker mutation' {
        function Get-McpStorageCachePlan {param($Settings);return @()}
        function Invoke-McpStorageDocker {throw 'An empty plan must not invoke Docker'}
        $result=Invoke-McpStorageCacheCollection (Get-McpStorageSettings @{}) (Get-McpStorageCachePlan (Get-McpStorageSettings @{}))
        $result.candidates|Should -Be 0
        $result.removed|Should -Be 0
    }

    It 'uses native age filtering with old human JSON and modern byte JSON: <Size>' -ForEach @(@{Size='13GB'},@{Size='13000000000'}) {
        param($Size)
        $script:AgeFiltered=$false;$script:CacheFixtureSize=$Size
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments -contains 'until=168h'){$script:AgeFiltered=$true}
            return (@{ID=('c'*25);Size=$script:CacheFixtureSize;LastUsedAt='3 months ago';Reclaimable=$true;Shared=$false;Mutable=$false}|ConvertTo-Json -Compress)
        }
        $plan=@(Get-McpStorageCachePlan (Get-McpStorageSettings @{}))
        $plan.Count|Should -Be 1
        $plan[0].SizeBytes|Should -Be 13000000000
        $script:AgeFiltered|Should -BeTrue
    }

    It 'runs offline reclaim only in the configured weekly window and once per date' {
        $s=Get-McpStorageSettings @{storageRetention=@{compactEnabled=$true}}
        Test-McpStorageCompactionWindow $s @{} ([datetime]'2026-11-08T03:35:00')|Should -BeTrue
        Test-McpStorageCompactionWindow $s @{} ([datetime]'2026-11-08T04:00:00')|Should -BeFalse
        Test-McpStorageCompactionWindow $s @{} ([datetime]'2026-11-09T03:35:00')|Should -BeFalse
        Test-McpStorageCompactionWindow $s @{lastCompactionDate='2026-11-08'} ([datetime]'2026-11-08T03:35:00')|Should -BeFalse
    }

    It 'defers a new heavy operation with its original continuation and reserve' {
        $script:AdmissionCleanup=0
        function Get-McpStorageFreeBytes {param($Config);return 25GB}
        function Test-McpStorageOwnersIdle {param($Config);return $true}
        function Invoke-McpHostStorageMaintenance {param($Config,[switch]$OnlineOnly,[switch]$Force);$script:AdmissionCleanup++}
        {Assert-McpStorageAdmission @{storageRetention=@{enabled=$true}} -PeakBytes 10GB}|Should -Throw '*MCP_STORAGE_DEFERRED*repeat the original operation*'
        $script:AdmissionCleanup|Should -Be 1
        Assert-McpStorageAdmission @{storageRetention=@{enabled=$true}} -PeakBytes 4GB
        $script:AdmissionCleanup|Should -Be 1
    }

    It 'keeps serving reconciliation independent of an auxiliary cleanup failure' {
        $script:SavedRecord=$null
        function Get-McpStorageFreeBytes {param($Config);return 55GB}
        function Get-McpStorageRecord {param($Config);return [ordered]@{}}
        function Save-McpStorageRecord {param($Config,$Record);$script:SavedRecord=$Record}
        function Test-McpStorageOwnersIdle {param($Config);return $true}
        function Test-McpStorageBuildsIdle {return $true}
        function Get-McpStorageCachePlan {param($Settings);throw 'fixture owner failure'}
        {Invoke-McpHostStorageMaintenance @{stateRoot=$TestDrive;storageRetention=@{enabled=$true}} -OnlineOnly 3>$null}|Should -Not -Throw
        $script:SavedRecord.lastError|Should -Match 'fixture owner failure'
        $script:SavedRecord.freeBytes|Should -Be 55GB
    }

    It 'does not advance daily cleanup while its build owner is busy' {
        $script:BusyRecord=$null
        function Get-McpStorageFreeBytes {param($Config);return 55GB}
        function Get-McpStorageRecord {param($Config);return [ordered]@{}}
        function Save-McpStorageRecord {param($Config,$Record);$script:BusyRecord=$Record}
        function Test-McpStorageOwnersIdle {param($Config);return $false}
        function Test-McpStorageBuildsIdle {return $false}
        function Get-McpStorageCachePlan {throw 'must not inspect or prune while busy'}
        Invoke-McpHostStorageMaintenance @{stateRoot=$TestDrive;storageRetention=@{enabled=$true}} -OnlineOnly
        $script:BusyRecord.Contains('lastCleanupAt')|Should -BeFalse
    }

    It 'collects independent cold data while an index owner is busy and leaves offline work alone' {
        $script:OnlineCollections=0;$script:OnlineRecord=$null
        function Get-McpStorageFreeBytes {param($Config);return 55GB}
        function Get-McpStorageRecord {param($Config);return [ordered]@{}}
        function Save-McpStorageRecord {param($Config,$Record);$script:OnlineRecord=$Record}
        function Test-McpStorageBuildsIdle {return $true}
        function Test-McpStorageOwnersIdle {param($Config,[switch]$ForOffline);return $false}
        function Get-McpStorageCachePlan {param($Settings);return @()}
        function Invoke-McpStorageCacheCollection {param($Settings,$Plan);$script:OnlineCollections++;return @{removed=0}}
        function Invoke-McpStorageRetirement {param($Config,$Settings,$Record);return 0}
        function Add-McpStorageLegacyAdoptions {param($Config,$Record);return 0}
        function Invoke-McpStorageContainerRetirement {param($Config,$Settings,$Record);$script:OnlineCollections++;return @{removed=0}}
        function Invoke-McpStorageDockerDataRetirement {param($Config,$Settings,$Record);$script:OnlineCollections++;return @{}}
        function Invoke-McpStorageVhdCompaction {throw 'must not stop independent owners'}
        Invoke-McpHostStorageMaintenance @{stateRoot=$TestDrive;storageRetention=@{enabled=$true;compactEnabled=$true}} -OnlineOnly
        $script:OnlineCollections|Should -Be 3
        $script:OnlineRecord.Contains('lastCleanupAt')|Should -BeTrue
    }

    It 'defers offline work before recording an attempt if an owner is busy' {
        $vhd=Join-Path $TestDrive 'deferred-data.vhdx';Write-Text $vhd 'fixture'
        function Optimize-VHD {param($Path,$Mode,$ErrorAction);throw 'must not compact'}
        function Test-McpStorageOwnersIdle {param($Config,[switch]$ForOffline);return $false}
        function Invoke-McpStorageDocker {throw 'must not stop Docker'}
        function Save-McpStorageRecord {throw 'a skipped window must remain pending'}
        $record=[ordered]@{}
        $r=Invoke-McpStorageVhdCompaction @{} (Get-McpStorageSettings @{storageRetention=@{vhdPath=$vhd}}) $record
        $r.status|Should -Be deferred
        $record.Contains('lastCompactionDate')|Should -BeFalse
    }

    It 'restores Docker after attached-disk rejection without invoking compaction' {
        $script:DesktopCalls=@();$script:OptimizeCalls=0
        $vhd=Join-Path $TestDrive 'owned-data.vhdx'
        Write-Text $vhd 'fixture'
        function Optimize-VHD {param($Path,$Mode,$ErrorAction);$script:OptimizeCalls++}
        function Get-VHD {param($Path,$ErrorAction);return @{Attached=$true}}
        function Save-McpStorageRecord {param($Config,$Record)}
        function Get-McpStorageContainers {return @(@{id=('a'*64);running=$true})}
        function Test-McpStorageOwnersIdle {param($Config);return $true}
        function Invoke-ProcessWithTimeout {param($FilePath,$Arguments,$TimeoutSec,$Description);return @{exitCode=0;lines=@('trimmed')}}
        function Invoke-McpStorageDocker {param($Arguments,$TimeoutSec);$script:DesktopCalls+=$Arguments[1]}
        function Wait-DockerDaemonAvailable {param($TimeoutSec,$PollSeconds);return $true}
        $settings=Get-McpStorageSettings @{storageRetention=@{vhdPath=$vhd}}
        {Invoke-McpStorageVhdCompaction @{} $settings ([ordered]@{})}|Should -Throw '*still attached*'
        $script:DesktopCalls|Should -Be @('stop','start')
        $script:OptimizeCalls|Should -Be 0
    }

    It 'retires only the enrolled container and unreferenced native data volume, preserving a shared image and volume' {
        $cfg=@{stateRoot=(Join-Path $TestDrive 'retirement-integration')}
        $snap=Join-Path $cfg.stateRoot ('snapshots/cutover-'+('c'*32))
        $folder=Join-Path $snap 'index';New-Item -ItemType Directory -Path $folder -Force|Out-Null
        Write-Text (Join-Path $folder 'index.tar') 'accepted old payload'
        $manifest=Join-Path $snap 'snapshot.json'
        Write-JsonFile $manifest @{complete=$true;records=@(@{folder=$folder;sha256=(Get-FileHash (Join-Path $folder 'index.tar')).Hash.ToLowerInvariant()})}
        $old=@{id=('b'*64);name='owned-old';image='shared-image';running=$false;mounts=@()}
        $current=@{id=('d'*64);name='current';image='shared-image';running=$true;mounts=@(@{Type='volume';Name='shared-volume'})}
        $script:Inventory=@($old,$current);$script:RemovedVolumes=@();$script:RemovedImages=@()
        $entry=@{service='pm5/code';acceptedAt='2026-09-01T00:00:00Z';qualification='native-cutover-and-control-restart';status='accepted';pinned=$false;snapshotPath=$snap;manifestSha256=(Get-FileHash $manifest).Hash;retiredContainer=$old.id;retiredName=$old.name;retiredImage=$old.image;retiredContainers=@($old);retiredVolumes=@(@{name='shared-volume';driver='local';createdAt='fixture';role='index'},@{name='unused-index';driver='local';createdAt='fixture';role='index'})}
        $newer=@(@{service='pm5/code';acceptedAt='2026-10-30T00:00:00Z';status='accepted';qualification='native-cutover-and-control-restart'},@{service='pm5/code';acceptedAt='2026-10-31T00:00:00Z';status='accepted';qualification='native-cutover-and-control-restart'})
        $record=[ordered]@{accepted=(@($entry)+$newer)}
        function Read-HostState {param($Config);return @{servers=@(@{containerName='current'})}}
        function Save-McpStorageRecord {param($Config,$Record)}
        function Get-McpStorageContainers {return $script:Inventory}
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments[0] -eq 'rm'){$script:Inventory=@($script:Inventory|Where-Object id -ne $Arguments[1]);return}
            if($Arguments[0] -eq 'image'){$script:RemovedImages+=$Arguments[2];return}
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'ls'){return @('shared-volume','unused-index')}
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'inspect'){return ' [{"Name":"unused-index","Driver":"local","CreatedAt":"fixture","Options":null}] '}
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'rm'){$script:RemovedVolumes+=$Arguments[2];return}
            throw 'Unexpected Docker mutation'
        }
        Invoke-McpStorageRetirement $cfg (Get-McpStorageSettings @{}) $record|Should -Be 1
        Test-Path $snap|Should -BeFalse
        @($script:Inventory|Where-Object name -eq current).Count|Should -Be 1
        @($script:Inventory|Where-Object name -eq owned-old).Count|Should -Be 0
        $script:RemovedImages.Count|Should -Be 0
        $script:RemovedVolumes|Should -Be @('unused-index')
    }

    It 'adopts only snapshots whose cutover is proven by succession, then retires them by the normal policy' {
        $cfg=@{stateRoot=(Join-Path $TestDrive ('adoption '+[char]0x0416+' Unicode'))}
        $snapshots=Join-Path $cfg.stateRoot 'snapshots'
        function New-AdoptionSnapshot {
            param([string]$Id,[string]$Old,[string]$Candidate,[string]$Created,[bool]$Complete=$true,[string]$Volume='')
            $path=Join-Path $snapshots ('cutover-'+($Id*32))
            $folder=Join-Path $path 'index';New-Item -ItemType Directory -Path $folder -Force|Out-Null
            Write-Text (Join-Path $folder 'index.tar') ('payload '+$Id+[char]0x0415)
            $record=@{role='index';type=$(if($Volume){'volume'}else{'bind'});source=$(if($Volume){$Volume}else{'E:/bind'});oldContainer=$Old;folder=$folder;sha256=(Get-FileHash (Join-Path $folder 'index.tar')).Hash.ToLowerInvariant()}
            Write-JsonFile (Join-Path $path 'snapshot.json') @{oldContainer=$Old;candidate=$Candidate;image='img-new';complete=$Complete;records=@($record)}
            (Get-Item -LiteralPath $path).CreationTimeUtc=[datetime]::Parse($Created).ToUniversalTime()
            return $path
        }
        $chained=New-AdoptionSnapshot 'a' 'rt-alpha' 'rt-bravo' '2026-09-01T00:00:00Z'
        $direct=New-AdoptionSnapshot 'b' 'rt-bravo' 'rt-charlie' '2026-09-10T00:00:00Z' -Volume 'vol-bravo'
        $failed=New-AdoptionSnapshot 'c' 'rt-alpha' 'rt-delta' '2026-09-02T00:00:00Z'
        $rolledBack=New-AdoptionSnapshot 'd' 'rt-charlie' 'rt-echo' '2026-09-03T00:00:00Z'
        $changed=New-AdoptionSnapshot 'e' 'rt-fox' 'rt-charlie' '2026-09-04T00:00:00Z'
        Write-Text (Join-Path $changed 'failed-proof.txt') 'preserve'
        $incomplete=New-AdoptionSnapshot 'f' 'rt-golf' 'rt-charlie' '2026-09-05T00:00:00Z' -Complete $false
        $running=New-AdoptionSnapshot '1' 'rt-hotel' 'rt-charlie' '2026-09-06T00:00:00Z'
        $script:Inventory=@(@{id=('b'*64);name='rt-bravo';image='img-bravo';running=$false;mounts=@()},@{id=('c'*64);name='rt-charlie';image='img-new';running=$true;mounts=@()},@{id=('h'*64);name='rt-hotel';image='img-hotel';running=$true;mounts=@()})
        $script:DockerMutations=@();$script:Saves=0
        function Read-HostState {param($Config);return @{servers=@(@{containerName='rt-charlie';configId='pm5';id='code'})}}
        function Save-McpStorageRecord {param($Config,$Record);$script:Saves++}
        function Get-McpStorageContainers {return $script:Inventory}
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'ls'){return @('vol-bravo')}
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'inspect'){return '[{"Name":"vol-bravo","Driver":"local","CreatedAt":"fixture","Options":null}]'}
            $script:DockerMutations+=($Arguments -join ' ')
        }
        $record=[ordered]@{}
        Add-McpStorageLegacyAdoptions $cfg $record|Should -Be 2
        $adopted=@($record.accepted)
        @($adopted|ForEach-Object {$_.snapshotPath})|Should -Be @($chained,$direct)
        @($adopted|Where-Object {$_.service -ne 'pm5/code' -or $_.qualification -ne 'legacy-succession-adopted'}).Count|Should -Be 0
        $adopted[1].retiredContainer|Should -Be ('b'*64)
        $adopted[1].retiredVolumes[0].name|Should -Be 'vol-bravo'
        $adopted[0].retiredContainer|Should -Be ''
        ([datetime]$adopted[0].acceptedAt).ToUniversalTime()|Should -Be ([datetime]::Parse('2026-09-01T00:00:00Z').ToUniversalTime())
        $legacy=@(Get-McpStorageLegacySnapshots $cfg $record|ForEach-Object {$_.path})|Sort-Object
        $legacy|Should -Be (@($failed,$rolledBack,$changed,$incomplete,$running)|Sort-Object)
        Add-McpStorageLegacyAdoptions $cfg $record|Should -Be 0
        @($record.accepted).Count|Should -Be 2

        $record.accepted=@($record.accepted)+@(@{service='pm5/code';acceptedAt='2026-10-30T00:00:00Z';status='accepted';qualification='native-cutover-and-control-restart'},@{service='pm5/code';acceptedAt='2026-10-31T00:00:00Z';status='accepted';qualification='native-cutover-and-control-restart'})
        Invoke-McpStorageRetirement $cfg (Get-McpStorageSettings @{}) $record|Should -Be 2
        Test-Path $direct|Should -BeFalse
        Test-Path $chained|Should -BeFalse
        foreach($kept in $legacy){Test-Path $kept|Should -BeTrue}
        # rt-bravo stays referenced by the then-remaining chained snapshot; legacy data protects the rest.
        $script:DockerMutations.Count|Should -Be 0
    }

    It 'removes only old stopped itl containers that nothing current or retained needs' {
        $cfg=@{stateRoot=(Join-Path $TestDrive ('containers '+[char]0x0417+' Unicode'))}
        $snapshot=Join-Path $cfg.stateRoot ('snapshots/cutover-'+('9'*32))
        New-Item -ItemType Directory -Path $snapshot -Force|Out-Null
        Write-JsonFile (Join-Path $snapshot 'snapshot.json') @{oldContainer='itl-snap-old';candidate='itl-current-x';complete=$true;records=@()}
        function New-StoppedFixture {
            param([string]$Name,[string]$Finished,[string]$Status='exited',[string]$Project='',[bool]$Running=$false,[string]$Created='2026-08-01T00:00:00Z')
            return [pscustomobject]@{id=($Name+'-id');name=$Name;image='img';running=$Running;status=$Status;finishedAt=$Finished;createdAt=$Created;mounts=@();composeProject=$Project}
        }
        $script:Inventory=@(
            (New-StoppedFixture 'itl-old-exp' '2026-10-01T00:00:00Z'),
            (New-StoppedFixture 'itl-recent' '2026-11-15T00:00:00Z'),
            (New-StoppedFixture 'itl-current-x' '2026-10-01T00:00:00Z'),
            (New-StoppedFixture 'itl-snap-old' '2026-10-01T00:00:00Z'),
            (New-StoppedFixture 'itl-accepted-old' '2026-10-01T00:00:00Z'),
            (New-StoppedFixture 'itl-proj-init' '2026-10-01T00:00:00Z' -Project 'proj'),
            (New-StoppedFixture 'itl-proj-main' '' 'running' 'proj' $true),
            (New-StoppedFixture 'foreign-db' '2026-09-01T00:00:00Z'),
            (New-StoppedFixture 'itl-never-started' '0001-01-01T00:00:00Z' 'created' -Created '2026-09-01T00:00:00Z'),
            (New-StoppedFixture 'itl-nano' '2026-10-02T16:39:42.123456789Z'),
            (New-StoppedFixture 'itl-current' '2026-10-01T00:00:00Z'))
        $record=@{accepted=@(@{status='accepted';retiredName='itl-accepted-old';retiredContainers=@()},@{status='retired';retiredName='itl-old-exp'})}
        function Read-HostState {param($Config);return @{servers=@(@{containerName='itl-current-x'})}}
        function Get-McpStorageContainers {param([string[]]$Ids);if($PSBoundParameters.ContainsKey('Ids')){return @($script:Fresh|Where-Object {$_.id -in $Ids})};return $script:Inventory}
        $plan=@(Get-McpStorageContainerRetirementPlan $cfg (Get-McpStorageSettings @{}) $record ([datetime]'2026-11-21T12:00:00Z'))
        $reasons=@{};foreach($item in $plan){$reasons[$item.name]=$item.reason}
        $reasons.Count|Should -Be 9
        # A shorter old name inside a current name is not a reference to it.
        @($reasons.Keys|Where-Object {$reasons[$_] -eq 'eligible'}|Sort-Object)|Should -Be @('itl-current','itl-nano','itl-never-started','itl-old-exp')
        $reasons['itl-recent']|Should -Be 'minimum-age'
        $reasons['itl-current-x']|Should -Be 'current'
        $reasons['itl-snap-old']|Should -Be 'retained-snapshot'
        $reasons['itl-accepted-old']|Should -Be 'retained-snapshot'
        $reasons['itl-proj-init']|Should -Be 'running-project'

        # A concurrent start wins and a refused removal is counted, never forced.
        $script:Fresh=@($script:Inventory|Where-Object {$_.name -ne 'itl-nano'})+@(New-StoppedFixture 'itl-nano' '' 'running' -Running $true)
        $script:Removed=@()
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments[0] -ne 'rm'){throw 'Unexpected Docker operation'}
            if($Arguments -contains '-f' -or $Arguments -contains '--force'){throw 'Removal must never force'}
            if($Arguments[1] -eq 'itl-never-started-id'){throw 'conflict: container is in use'}
            $script:Removed+=$Arguments[1]
        }
        $result=Invoke-McpStorageContainerRetirement $cfg (Get-McpStorageSettings @{}) $record
        $script:Removed|Should -Be @('itl-old-exp-id','itl-current-id')
        $result.candidates|Should -Be 4
        $result.removed|Should -Be 2
        $result.failed|Should -Be 1

        New-Item -ItemType Directory -Path (Join-Path $cfg.stateRoot ('snapshots/cutover-'+('8'*32)))|Out-Null
        @(Get-McpStorageContainerRetirementPlan $cfg (Get-McpStorageSettings @{}) $record ([datetime]'2026-11-21T12:00:00Z')).Count|Should -Be 0
    }

    It 'parses real inspect rows into individual mounts and labels with separators in values' {
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments[0] -eq 'ps'){return @('c'*64)}
            return '"'+('c'*64)+'"|"/itl-run"|"sha256:used"|true|"running"|"0001-01-01T00:00:00Z"|"2026-10-01T00:00:00.123456789Z"|[{"Type":"volume","Name":"vol-one","Destination":"/a"},{"Type":"bind","Source":"E:\\data","Destination":"/b"}]|{"com.docker.compose.project":"proj","note":"a|b"}'
        }
        $container=@(Get-McpStorageContainers)
        $container.Count|Should -Be 1
        $container[0].name|Should -Be 'itl-run'
        @($container[0].mounts).Count|Should -Be 2
        @($container[0].mounts|Where-Object {$_.Type -eq 'volume'})[0].Name|Should -Be 'vol-one'
        $container[0].composeProject|Should -Be 'proj'
        (ConvertFrom-McpStorageDockerTime $container[0].createdAt).Ticks|Should -Be ([datetime]::Parse('2026-10-01T00:00:00.1234567Z').ToUniversalTime().Ticks)
    }

    It 'removes only unmounted volumes and itl images that no owner names, needs or builds on' {
        $cfg=@{stateRoot=(Join-Path $TestDrive ('docker data '+[char]0x0418+' Unicode'));toolsListProxy=@{image='itl/proxy:1'}}
        $snapshot=Join-Path $cfg.stateRoot ('snapshots/cutover-'+('7'*32))
        New-Item -ItemType Directory -Path $snapshot -Force|Out-Null
        Write-JsonFile (Join-Path $snapshot 'snapshot.json') @{oldContainer='itl-gone';image='itl/snap:1';complete=$true;records=@(@{type='volume';source='itl-snap-vol'})}
        $compose=Join-Path $cfg.stateRoot 'configs/pm5/runtime/itl-pm5-graph/docker-compose.yml'
        New-Item -ItemType Directory -Path (Split-Path $compose) -Force|Out-Null
        Write-Text $compose "services:`n  graph:`n    image: itl/compose:1`n    volumes:`n      - itl-compose-vol:/data`nvolumes:`n  itl-compose-vol: {}`n"
        $old='2026-10-01T00:00:00Z';$recent='2026-11-20T00:00:00Z'
        $anonymous=@('a','b','c'|ForEach-Object {$_*64})
        function Read-HostState {param($Config);return @{servers=@()}}
        function Get-McpStorageContainers {return @([pscustomobject]@{id='run-id';name='itl-run';image='sha256:used';running=$true;mounts=@(@{Type='volume';Name=$anonymous[2]})})}
        $script:Volumes=@(
            [pscustomobject]@{name=$anonymous[0];driver='local';createdAt=$old},
            [pscustomobject]@{name=$anonymous[1];driver='local';createdAt=$recent},
            [pscustomobject]@{name=$anonymous[2];driver='local';createdAt=$old},
            [pscustomobject]@{name='itl-exp-data';driver='local';createdAt='2026-10-21T10:00:00+03:00'},
            [pscustomobject]@{name='itl-new-data';driver='local';createdAt=$recent},
            [pscustomobject]@{name='itl-snap-vol';driver='local';createdAt=$old},
            [pscustomobject]@{name='itl-compose-vol';driver='local';createdAt=$old},
            [pscustomobject]@{name='itl-nfs';driver='nfs';createdAt=$old},
            [pscustomobject]@{name='other-vol';driver='local';createdAt=$old})
        function Get-McpStorageVolumes {return $script:Volumes}
        function New-ImageFixture {param([string]$Id,[string[]]$Tags=@(),[string[]]$Layers=@('x'),[string]$Created='2026-10-01T00:00:00Z',[string[]]$Digests=@());return [pscustomobject]@{id=$Id;createdAt=$Created;tags=@($Tags);digests=@($Digests);layers=@($Layers)}}
        $script:Images=@(
            (New-ImageFixture 'sha256:used' @('itl/run:1') @('l1','l2','l3')),
            (New-ImageFixture 'sha256:base' @('itl/g3-base:1') @('l1','l2')),
            (New-ImageFixture 'sha256:dangling'),
            (New-ImageFixture 'sha256:old' @('itl/old:1','itl/old:2')),
            (New-ImageFixture 'sha256:recent' @('itl/recent:1') -Created '2026-11-20T00:00:00Z'),
            (New-ImageFixture 'sha256:snap' @('itl/snap:1')),
            (New-ImageFixture 'sha256:proxy' @('itl/proxy:1')),
            (New-ImageFixture 'sha256:compose' @('itl/compose:1')),
            (New-ImageFixture 'sha256:node' @('node:22-alpine')),
            (New-ImageFixture 'sha256:pinned' -Digests @('comol/x@sha256:abc')))
        function Get-McpStorageImages {return $script:Images}
        $now=[datetime]'2026-11-21T12:00:00Z';$settings=Get-McpStorageSettings @{}
        $volumes=@{};foreach($item in Get-McpStorageVolumeRetirementPlan $cfg $settings @{} $now){$volumes[$item.name]=$item.reason}
        $volumes.Count|Should -Be 8
        $volumes[$anonymous[0]]|Should -Be 'eligible'
        $volumes[$anonymous[1]]|Should -Be 'eligible'
        $volumes[$anonymous[2]]|Should -Be 'mounted'
        $volumes['itl-exp-data']|Should -Be 'eligible'
        $volumes['itl-new-data']|Should -Be 'minimum-age'
        $volumes['itl-snap-vol']|Should -Be 'retained-snapshot'
        $volumes['itl-compose-vol']|Should -Be 'referenced'
        $volumes['itl-nfs']|Should -Be 'foreign-driver'
        $images=@{};foreach($item in Get-McpStorageImageRetirementPlan $cfg $settings @{} $now){$images[$item.id]=$item.reason}
        $images.Count|Should -Be 8
        $images['sha256:used']|Should -Be 'in-use'
        $images['sha256:base']|Should -Be 'base-of-current'
        $images['sha256:dangling']|Should -Be 'eligible'
        $images['sha256:old']|Should -Be 'eligible'
        $images['sha256:recent']|Should -Be 'minimum-age'
        $images['sha256:snap']|Should -Be 'retained-snapshot'
        $images['sha256:proxy']|Should -Be 'referenced'
        $images['sha256:compose']|Should -Be 'referenced'

        $script:DataMutations=@()
        function Invoke-McpStorageDocker {
            param($Arguments,$TimeoutSec)
            if($Arguments -contains '-f' -or $Arguments -contains '--force'){throw 'Removal must never force'}
            if($Arguments[1] -ne 'rm'){throw 'Unexpected Docker operation'}
            if($Arguments[2] -eq 'itl-exp-data'){throw 'volume is in use'}
            $script:DataMutations+=($Arguments -join ' ')
        }
        # Real collection uses the current clock; every fixture except the recent ones is old enough.
        $result=Invoke-McpStorageDockerDataRetirement $cfg $settings @{}
        $script:DataMutations|Should -Be @(('volume rm '+$anonymous[0]),('volume rm '+$anonymous[1]),'image rm sha256:dangling','image rm itl/old:1 itl/old:2')
        $result.volumes.candidates|Should -Be 3
        $result.volumes.removed|Should -Be 2
        $result.volumes.failed|Should -Be 1
        $result.images.removed|Should -Be 2

        New-Item -ItemType Directory -Path (Join-Path $cfg.stateRoot ('snapshots/cutover-'+('6'*32)))|Out-Null
        @(Get-McpStorageVolumeRetirementPlan $cfg $settings @{} $now).Count|Should -Be 0
        @(Get-McpStorageImageRetirementPlan $cfg $settings @{} $now).Count|Should -Be 0
    }

    It 'rejects unknown Mantis owner bytes without changing either file' {
        . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
        $python=Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component Mantis
        $fixture=Join-Path $TestDrive ('owner '+[char]0x0415+' Unicode');New-Item -ItemType Directory -Path $fixture|Out-Null
        $repair=Join-Path $RepoRoot 'vibecoding1c-mcp-host/mantis-ticket-mcp/storage-owner-repair.py'
        $code=@'
import hashlib,importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('repair',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
root=pathlib.Path(sys.argv[2])
for name in m.EXPECTED:(root/name).write_text('unqualified = True\n',encoding='utf-8')
before={p.name:p.read_bytes() for p in root.glob('*.py')}
try:m.repair(root)
except ValueError:pass
else:raise AssertionError('unknown source was accepted')
assert before=={p.name:p.read_bytes() for p in root.glob('*.py')}
print(json.dumps({'path':str(root),'preserved':True},ensure_ascii=False))
'@
        $r=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-B','-X','utf8','-c',$code,$repair,$fixture) -TimeoutSec 30
        $r.exitCode|Should -Be 0
        $value=($r.lines -join "`n")|ConvertFrom-Json
        $value.path|Should -BeExactly $fixture
        $value.preserved|Should -BeTrue
    }
}
