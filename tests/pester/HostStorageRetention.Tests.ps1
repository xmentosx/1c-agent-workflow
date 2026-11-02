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
        function Invoke-McpStorageVhdCompaction {throw 'must not stop independent owners'}
        Invoke-McpHostStorageMaintenance @{stateRoot=$TestDrive;storageRetention=@{enabled=$true;compactEnabled=$true}} -OnlineOnly
        $script:OnlineCollections|Should -Be 1
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
