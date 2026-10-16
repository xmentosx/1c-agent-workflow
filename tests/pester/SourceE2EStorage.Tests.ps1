BeforeAll {
    $RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')
    function New-StorageCopy {
        param([string]$Root,[string]$Status='passed',[string]$Candidate=('a'*40),[string]$Capsule=('f'*64))
        $candidate=$Candidate;$capsule=$Capsule
        $parent=Join-Path $Root ('q Проект/develop-'+$capsule.Substring(0,12)+'-'+$candidate.Substring(0,12)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
        $project=Join-Path $parent 'project';$branch=Join-Path $parent 'branch'
        [void][IO.Directory]::CreateDirectory($project)
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('init','-b','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.name','Fixture')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.email','fixture@example.invalid')|Out-Null
        Write-Utf8Text -Path (Join-Path $project 'seed.txt') -Value 'immutable source'
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('commit','-m','fixture')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('worktree','add','--detach',$branch,'HEAD')|Out-Null
        $claim=@{schemaVersion=2;kind='itl-qualification-fixture-target';status='disposed';phase='Develop';projectRoot=$project;branchRoot=$branch;copyRoot=$parent;projectsRoot=$Root;candidateCommit=$candidate;capsuleSha256=$capsule;workflowCommonGit=(Get-RepositoryCommonGitDirectory -RepositoryRoot $RepoRoot)}
        Write-QualificationFixtureJson -Path (Join-Path $parent 'qualification-fixture.json') -Value $claim
        Write-Utf8Text -Path (Join-Path $parent 'preparation-logs/restore.log') -Value 'Ошибка: тестовый путь с пробелами; exact diagnostic'
        Write-Utf8Text -Path (Join-Path $branch '.agent-1c/dev-branches/negative.json') -Value '{"pendingMergeOperation":"refresh-dev-branch","cursor":17}'
        Write-Utf8Text -Path (Join-Path $branch '.agent-1c/snapshots/seed.dt') -Value 'reconstructible snapshot'
        Write-Utf8Text -Path (Join-Path $branch 'tools/large.zip') -Value ('x'*65536)
        $report=Join-Path $Root ('output/'+[guid]::NewGuid().ToString('N')+'/raw.json')
        Write-QualificationFixtureJson -Path $report -Value @{status=$Status;candidate=@{commit=$candidate};error=$(if($Status -eq 'failed'){'original failing scenario'}else{$null})}
        return @{root=$parent;fixture=@{projectRoot=$project;branchRoot=$branch;claim=[pscustomobject]$claim};report=$report;diagnostics=(Join-Path (Split-Path -Parent $report) 'diagnostics');claim=$claim}
    }
    function New-LegacyStorageCopy {
        param([string]$Root)
        $candidate=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $copy=New-StorageCopy -Root $Root -Candidate $candidate
        foreach($key in @('copyRoot','projectsRoot','workflowCommonGit')){$copy.claim.Remove($key)}
        $copy.claim.schemaVersion=1
        $copy.claim.disposal=@{status='disposed';candidateCommit=$candidate;finishedAt='2026-10-12T17:14:08.2443587Z';removedDatabases=@(@{path=(Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/dev-branches/golden/1Cv8.1CD');bytes=1024})}
        $origin=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('remote','get-url','origin')).stdout.Trim()
        Write-QualificationFixtureJson -Path (Join-Path $copy.fixture.projectRoot '.agent-1c/dependency-lock.json') -Value @{dependencies=@{workflowPackage=@{repo=$origin;commit=$candidate}}}
        Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        $copy.fixture.claim=[pscustomobject]$copy.claim
        return $copy
    }
    function New-RecoverableStorageCopy {
        param([string]$Root,[string]$State='materializing')
        $candidate=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        # The capsule producer is a source repository, not another disposable
        # qualification target. Keep the cleanup target's Unicode path unchanged.
        $seed=Join-Path $Root 'original';[void][IO.Directory]::CreateDirectory($seed)
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('init','-b','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('config','user.name','Fixture')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('config','user.email','fixture@example.invalid')|Out-Null
        Write-Utf8Text -Path (Join-Path $seed 'seed.txt') -Value 'immutable source'
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('commit','-m','fixture')|Out-Null
        $capsule=Join-Path $Root 'sealed';[void][IO.Directory]::CreateDirectory($capsule)
        Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('bundle','create',(Join-Path $capsule 'source.bundle'),'--all')|Out-Null
        foreach($name in @('infobase.dt','state.json','master.env','branch.env','release-e2e.json')){Write-Utf8Text -Path (Join-Path $capsule $name) -Value 'sealed source bytes'}
        $head=(Invoke-RepositoryGit -RepositoryRoot $seed -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $files=@(Get-ChildItem -LiteralPath $capsule -File|ForEach-Object {@{path=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
        $manifest=Join-Path $capsule 'capsule.json'
        Write-QualificationFixtureJson -Path $manifest -Value @{schemaVersion=1;kind='itl-qualification-fixture';status='sealed';phase='Develop';infoBaseKind='file';branchName='golden';masterCommit=$head;branchCommit=$head;workflowCommit=$candidate;files=$files}
        $sha=(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()
        $copy=New-StorageCopy -Root $Root -Candidate $candidate -Capsule $sha
        $copy.claim.status=$State;$copy.claim.capsulePath=$manifest
        Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        Invoke-RepositoryGit -RepositoryRoot $copy.fixture.projectRoot -Arguments @('remote','add','origin',(Join-Path $capsule 'source.bundle'))|Out-Null
        Write-Utf8Text -Path (Join-Path $copy.fixture.branchRoot '.agent-1c/snapshots/qualification-fixtures/seed.dt') -Value 'sealed source bytes'
        return $copy
    }
}

Describe 'Source E2E allocation capacity' {
    It 'combines simultaneous allocations on one volume and resumes unchanged after space becomes available' {
        $script:available=99L
        Mock Get-SourceE2EVolumeSpace {param($Path) [pscustomobject]@{volume='same-volume';availableBytes=$script:available}}
        $allocations=@(@{path='copy Проект';bytes=60L},@{path='temp папка';bytes=40L})
        {Assert-SourceE2ESpace -Allocations $allocations -Operation original-task}|Should -Throw '*requiredBytes=100 availableBytes=99*ResumePlan*'
        $script:available=100L
        {Assert-SourceE2ESpace -Allocations $allocations -Operation original-task}|Should -Not -Throw
    }
    It 'accounts for destination and TEMP separately when their volumes differ' {
        Mock Get-SourceE2EVolumeSpace {param($Path) [pscustomobject]@{volume=$Path;availableBytes=60L}}
        {Assert-SourceE2ESpace -Allocations @(@{path='copy';bytes=60L},@{path='temp';bytes=60L}) -Operation original-task}|Should -Not -Throw
    }
    It 'reads actual available space for a Unicode path without starting a native workflow' {
        $path=Join-Path $TestDrive 'папка с пробелами';[void][IO.Directory]::CreateDirectory($path)
        $v=Get-SourceE2EVolumeSpace -Path $path
        $v.availableBytes|Should -BeGreaterThan 0;$v.volume|Should -Not -BeNullOrEmpty
    }
}

Describe 'Terminal disposable Develop copy retention' {
    It 'removes two successive <status> copies, preserves exact diagnostics and proof, and does not accumulate heavy files' -ForEach @(@{status='passed'},@{status='failed'}) {
        $root=Join-Path $TestDrive ('циклы с пробелами '+[guid]::NewGuid().ToString('N'))
        $seed=Join-Path $root 'original/capsule.json';Write-Utf8Text -Path $seed -Value 'original sealed seed'
        $seedSha=(Get-FileHash -LiteralPath $seed).Hash
        foreach($iteration in 1..2){
            $copy=New-StorageCopy -Root $root -Status $status
            $pending=$null
            if($status -eq 'failed'){
                Invoke-RepositoryGit -RepositoryRoot $copy.fixture.branchRoot -Arguments @('commit','--allow-empty','-m','derived pending context')|Out-Null
                $pending=(Invoke-RepositoryGit -RepositoryRoot $copy.fixture.branchRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
                Invoke-RepositoryGit -RepositoryRoot $copy.fixture.branchRoot -Arguments @('reset','--hard','HEAD^')|Out-Null
                Write-Utf8Text -Path (Join-Path $copy.fixture.branchRoot 'seed.txt') -Value 'failed рабочая версия'
            }
            $proofSha=(Get-FileHash -LiteralPath $copy.report).Hash
            $log=Read-Utf8Text -Path (Join-Path $copy.root 'preparation-logs/restore.log')
            $result=Remove-SourceE2EFixtureCopy -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report -DiagnosticRoot $copy.diagnostics
            $result.status|Should -BeExactly 'removed';$result.removedBytes|Should -BeGreaterThan 65536
            Test-Path -LiteralPath $copy.root|Should -BeFalse
            (Read-Utf8Text -Path (Join-Path $copy.diagnostics 'preparation-logs/restore.log'))|Should -BeExactly $log
            (Get-FileHash -LiteralPath $copy.report).Hash|Should -BeExactly $proofSha
            (Get-FileHash -LiteralPath $seed).Hash|Should -BeExactly $seedSha
            if($pending){
                $restored=Join-Path (Split-Path -Parent $copy.report) 'restored'
                Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('clone',(Join-Path $copy.diagnostics 'source.bundle'),$restored)|Out-Null
                (Invoke-RepositoryGit -RepositoryRoot $restored -Arguments @('cat-file','-t',$pending)).stdout.Trim()|Should -BeExactly 'commit'
                Invoke-RepositoryGit -RepositoryRoot $restored -Arguments @('apply','--binary',(Join-Path $copy.diagnostics 'branch-working.patch'))|Out-Null
                (Read-Utf8Text -Path (Join-Path $restored 'seed.txt'))|Should -BeExactly 'failed рабочая версия'
            }
            @(Get-ChildItem -LiteralPath (Join-Path $root 'q Проект') -Directory).Count|Should -Be 0
            {Remove-SourceE2EFixtureCopy -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report -DiagnosticRoot $copy.diagnostics}|Should -Not -Throw
        }
    }
    It 'retains a leased terminal copy during a sweep and reclaims it automatically after the owner releases it' {
        $root=Join-Path $TestDrive ('deferred Пример '+[guid]::NewGuid().ToString('N'))
        $copy=New-StorageCopy -Root $root
        $lease=Open-SourceE2EFixtureUse -ProjectRoot $copy.fixture.projectRoot
        try {
            Write-SourceE2EFixtureTerminal -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report -UseLease $lease
            $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'retention')
            $result.retained|Should -Be 1;$result.removed|Should -Be 0
            Test-Path -LiteralPath $copy.root|Should -BeTrue
        } finally {$lease.Dispose()}
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'retention')
        $result.removed|Should -Be 1;$result.retained|Should -Be 0
        Test-Path -LiteralPath $copy.root|Should -BeFalse
    }
    It 'retains a <reason> copy before any recursive deletion' -ForEach @(
        @{reason='lease'},@{reason='legacy'},@{reason='Release'},@{reason='foreign-owner'},@{reason='external-worktree'},@{reason='reparse'},@{reason='database'}
    ) {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$copy=New-StorageCopy -Root $root
        $lease=$null;$junction=$null;$foreign=Join-Path $root 'foreign';[void][IO.Directory]::CreateDirectory($foreign)
        Write-Utf8Text -Path (Join-Path $foreign 'keep.txt') -Value 'foreign owner'
        switch($reason){
            lease {$lease=Open-SourceE2EFixtureUse -ProjectRoot $copy.fixture.projectRoot}
            legacy {$copy.claim.schemaVersion=1}
            Release {$copy.claim.phase='Release'}
            foreign-owner {$copy.claim.workflowCommonGit=Join-Path $root 'foreign/.git'}
            external-worktree {Invoke-RepositoryGit -RepositoryRoot $copy.fixture.projectRoot -Arguments @('worktree','add','--detach',(Join-Path $foreign 'external'),'HEAD')|Out-Null}
            reparse {$junction=Join-Path $copy.root 'link';New-Item -ItemType Junction -Path $junction -Target $foreign|Out-Null}
            database {Write-Utf8Text -Path (Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/1Cv8.1CD') -Value 'still owned database'}
        }
        Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        try {
            {Remove-SourceE2EFixtureCopy -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report -DiagnosticRoot $copy.diagnostics}|Should -Throw
            Test-Path -LiteralPath (Join-Path $copy.root 'preparation-logs/restore.log')|Should -BeTrue
            (Read-Utf8Text -Path (Join-Path $foreign 'keep.txt'))|Should -BeExactly 'foreign owner'
            if($reason -eq 'lease'){
                $other=New-StorageCopy -Root $root
                (Remove-SourceE2EFixtureCopy -Fixture $other.fixture -CandidateRoot $RepoRoot -ReportPath $other.report -DiagnosticRoot $other.diagnostics).status|Should -BeExactly 'removed'
                Test-Path -LiteralPath $copy.root|Should -BeTrue
                $lease.Dispose();$lease=$null
                (Remove-SourceE2EFixtureCopy -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report -DiagnosticRoot $copy.diagnostics).status|Should -BeExactly 'removed'
            }
        } finally {
            if($lease){$lease.Dispose()}
            if($junction){
                $link=Get-Item -LiteralPath $junction -Force
                if(-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TEST_JUNCTION_IDENTITY_CHANGED'}
                [IO.Directory]::Delete($junction)
            }
        }
    }
}

Describe 'Legacy disposed copy cleanup through the existing owner' {
    It 'uses the normal source-delivery cleanup adapter and its preserved owner paths' {
        $root=Join-Path $TestDrive 'штатная уборка с пробелами';$copy=New-LegacyStorageCopy -Root $root
        . (Join-Path $RepoRoot 'scripts/source-delivery-cleanup.ps1')
        $script:Root=$RepoRoot
        $result=Remove-SourceDeliveryCompletedFixtureCopies -FreshProjectsRoot $root -PreservePaths @($copy.fixture.branchRoot)
        $result.removed|Should -Be 0;$result.retained|Should -Be 1
        Test-Path -LiteralPath $copy.root|Should -BeTrue
        $result=Remove-SourceDeliveryCompletedFixtureCopies -FreshProjectsRoot $root
        $result.removed|Should -Be 1
        Test-Path -LiteralPath (Join-Path $result.entries[0].diagnostics 'source.bundle')|Should -BeTrue
        # Keep unit-test evidence in TestDrive, not in the source common Git store.
        Remove-Item -LiteralPath $result.entries[0].diagnostics -Recurse -Force
    }
    It 'reclaims a version 1 copy and preserves diagnostics, checkpoints, Git history and untracked Unicode data' {
        $root=Join-Path $TestDrive 'старые копии с пробелами';$copy=New-LegacyStorageCopy -Root $root
        Write-Utf8Text -Path (Join-Path $copy.fixture.branchRoot 'seed.txt') -Value 'изменённый исходник'
        Write-Utf8Text -Path (Join-Path $copy.fixture.branchRoot 'новый файл.txt') -Value 'нужные пользовательские данные'
        Write-QualificationFixtureJson -Path (Join-Path $copy.fixture.branchRoot '.agent-1c/execution-checkpoints/completed.json') -Value @{status='resumed'}
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy
        $result.removed|Should -Be 1;$result.removedBytes|Should -BeGreaterThan 65536
        Test-Path -LiteralPath $copy.root|Should -BeFalse
        $diagnostics=$result.entries[0].diagnostics
        (Read-Utf8Text -Path (Join-Path $diagnostics 'branch/untracked/новый файл.txt'))|Should -BeExactly 'нужные пользовательские данные'
        (Read-QualificationFixtureJson -Path (Join-Path $diagnostics 'branch/.agent-1c/execution-checkpoints/completed.json')).status|Should -BeExactly 'resumed'
        $restored=Join-Path $root 'restored'
        Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('clone',(Join-Path $diagnostics 'source.bundle'),$restored)|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $restored -Arguments @('apply','--binary',(Join-Path $diagnostics 'branch-working.patch'))|Out-Null
        (Read-Utf8Text -Path (Join-Path $restored 'seed.txt'))|Should -BeExactly 'изменённый исходник'
        (Read-QualificationFixtureJson -Path (Join-Path $diagnostics 'qualification-fixture.json')).schemaVersion|Should -Be 1
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
    }
    It 'retains legacy copies with <reason> and completes the original cleanup after the owner condition clears' -ForEach @(
        @{reason='lease'},@{reason='preserved'},@{reason='checkpoint'},@{reason='database'},@{reason='source'},@{reason='disposal'},@{reason='path'}
    ) {
        $root=Join-Path $TestDrive ('защита с пробелами '+[guid]::NewGuid().ToString('N'));$copy=New-LegacyStorageCopy -Root $root
        $lease=$null;$preserve=@();$checkpoint=Join-Path $copy.fixture.branchRoot '.agent-1c/execution-checkpoints/active.json';$database=Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/1Cv8.1CD'
        switch($reason){
            lease {$lease=Open-SourceE2EFixtureUse -ProjectRoot $copy.fixture.projectRoot}
            preserved {$preserve=@((Join-Path $copy.fixture.branchRoot '.agent-1c/snapshots/seed.dt'))}
            checkpoint {Write-QualificationFixtureJson -Path $checkpoint -Value @{status='suspended'}}
            database {Write-Utf8Text -Path $database -Value 'live database'}
            source {Write-QualificationFixtureJson -Path (Join-Path $copy.fixture.projectRoot '.agent-1c/dependency-lock.json') -Value @{dependencies=@{workflowPackage=@{repo='foreign';commit=$copy.claim.candidateCommit}}}}
            disposal {$copy.claim.disposal.candidateCommit='b'*40}
            path {$copy.claim.branchRoot=Join-Path $root 'foreign'}
        }
        Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        try {
            $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy -PreservePaths $preserve
            $result.removed|Should -Be 0;$result.retained|Should -Be 1
            Test-Path -LiteralPath $copy.root|Should -BeTrue
            if($reason -in @('lease','preserved','checkpoint','database')){
                if($lease){$lease.Dispose();$lease=$null}
                if(Test-Path -LiteralPath $checkpoint){Remove-Item -LiteralPath $checkpoint}
                if(Test-Path -LiteralPath $database){Remove-Item -LiteralPath $database}
                (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
            }
        } finally {if($lease){$lease.Dispose()}}
    }
}

Describe 'Failed factory and unclosed qualification copy recovery' {
    It 'retains the complete first recovery archive across an interrupted recursive removal' -Tag recovery_race {
        $root=Join-Path $TestDrive 'interrupted Пример';$copy=New-RecoverableStorageCopy -Root $root
        $script:interruptRemoval=$true
        Mock Remove-Item {
            param([string]$LiteralPath,[switch]$Recurse,[switch]$Force)
            if($script:interruptRemoval){throw 'injected recursive removal interruption'}
            if(-not [IO.Path]::GetFullPath($LiteralPath).StartsWith([IO.Path]::GetFullPath($TestDrive)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TEST_DELETE_OUTSIDE_TESTDRIVE'}
            [IO.Directory]::Delete($LiteralPath,$true)
        } -ParameterFilter {$LiteralPath -eq $copy.root}
        $first=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy
        $first.removed|Should -Be 0
        $diagnostics=Join-Path (Join-Path $root 'diagnostics') (Split-Path -Leaf $copy.root)
        $archive=Join-Path $diagnostics 'recovery.zip';$sha=(Get-FileHash -LiteralPath $archive).Hash
        foreach($path in @((Join-Path $copy.fixture.projectRoot '.git'),(Join-Path $copy.root 'qualification-fixture.json'),(Join-Path $copy.fixture.projectRoot 'seed.txt'))){
            if(-not [IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($TestDrive)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TEST_DELETE_OUTSIDE_TESTDRIVE'}
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $path -Recurse -Force
        }
        $script:interruptRemoval=$false
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
        (Get-FileHash -LiteralPath $archive).Hash|Should -BeExactly $sha
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try {$zip.GetEntry('project/seed.txt')|Should -Not -BeNullOrEmpty}finally{$zip.Dispose()}
    }
    It 'protects an older live factory in the same root even before its child names the exact copy' -Tag recovery_race {
        $root=Join-Path $TestDrive 'old producer Пример';$copy=New-RecoverableStorageCopy -Root $root
        $script:producerRunning=$true
        Mock Get-CimInstance {if($script:producerRunning){[pscustomobject]@{ProcessId=999991;CommandLine=('powershell.exe -File source-e2e-fixture.ps1 -Action Prepare -FreshProjectsRoot "'+$root+'"')}}}
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
        Test-Path -LiteralPath $copy.root|Should -BeTrue
        Test-SourceE2ECopyProducerCommand -CommandLine ('powershell.exe -File source-e2e-fixture.ps1 -Action Prepare -FreshProjectsRoot "'+(Join-Path $root 'independent')+'"') -ProjectsRoot $root|Should -BeFalse
        $script:producerRunning=$false
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
    }
    It 'rereads ownership under the lease when preparation finishes during cleanup discovery' -Tag recovery_race {
        $root=Join-Path $TestDrive 'race Пример';$copy=New-RecoverableStorageCopy -Root $root
        $script:leaseOpener=(Get-Command Open-SourceE2EFixtureUse).ScriptBlock;$script:finishDuringAdmission=$true
        Mock Open-SourceE2EFixtureUse {
            param($ProjectRoot)
            if($script:finishDuringAdmission){$path=Join-Path (Split-Path -Parent $ProjectRoot) 'qualification-fixture.json';$claim=Read-QualificationFixtureJson -Path $path;$claim.status='ready';Write-QualificationFixtureJson -Path $path -Value $claim}
            & $script:leaseOpener -ProjectRoot $ProjectRoot
        }
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
        Test-Path -LiteralPath $copy.root|Should -BeTrue
        $script:finishDuringAdmission=$false;$copy.claim.status='preparation-failed';Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
    }
    It 'accepts only the immutable qualification report for the exact completed target' {
        $root=Join-Path $TestDrive 'proof with spaces Пример';$control=Join-Path $root 'control.git';$parent=Join-Path $root 'copy'
        $commit=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $tree=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','HEAD^{tree}')).stdout.Trim()
        Mock Get-RepositoryCommonGitDirectory {return $control} -ParameterFilter {$RepositoryRoot -eq $RepoRoot}
        $cache=Join-Path $control ('itl/develop-e2e-qualifications/'+$tree+'/identity/upgrade')
        $reportPath=Join-Path $cache 'route-report.json';$manifestPath=Join-Path $cache 'manifest.json'
        $proof=@{schemaVersion=1;kind='itl-develop-e2e-route-report';status='passed';repository=@{commit=$commit;tree=$tree};result=@{configurationRejection=@{status='passed';proof=@{projectRoot=(Join-Path $parent 'branch');snapshotRestored=$true;cursorRestored=$true;nativeOperationsReleased=$true}}}}
        Write-QualificationFixtureJson -Path $reportPath -Value $proof
        Write-QualificationFixtureJson -Path $manifestPath -Value @{schemaVersion=1;kind='itl-develop-e2e-qualification-cache';identity=@{tree=$tree;reportSha256=(Get-FileHash -LiteralPath $reportPath).Hash.ToLowerInvariant()}}
        (Get-SourceE2ECopyReportBinding -CandidateRoot $RepoRoot -Commit $commit -Parent $parent).kind|Should -BeExactly 'passed-negative'
        [IO.File]::AppendAllText($reportPath,' ')
        Get-SourceE2ECopyReportBinding -CandidateRoot $RepoRoot -Commit $commit -Parent $parent|Should -BeNullOrEmpty
        $proof.result.configurationRejection.proof.projectRoot=Join-Path $root 'foreign/branch'
        Write-QualificationFixtureJson -Path $reportPath -Value $proof
        Write-QualificationFixtureJson -Path $manifestPath -Value @{schemaVersion=1;kind='itl-develop-e2e-qualification-cache';identity=@{tree=$tree;reportSha256=(Get-FileHash -LiteralPath $reportPath).Hash.ToLowerInvariant()}}
        Get-SourceE2ECopyReportBinding -CandidateRoot $RepoRoot -Commit $commit -Parent $parent|Should -BeNullOrEmpty
    }
    It 'delegates failed-factory database disposal to its original owner and repeats unchanged after the owner becomes available' {
        $root=Join-Path $TestDrive 'failed base Пример';$copy=New-RecoverableStorageCopy -Root $root -State preparation-failed
        $script:recoveryDatabase=Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/test/1Cv8.1CD'
        Write-Utf8Text -Path $script:recoveryDatabase -Value 'derived incomplete restore'
        $script:ownerAvailable=$false
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root,$Action,$Arguments)
            $Action|Should -BeExactly 'qualification-create-infobase';$Arguments[1]|Should -BeExactly 'Dispose';$Arguments[3]|Should -BeExactly $copy.claim.candidateCommit
            if(-not $script:ownerAvailable){throw 'original base owner held'}
            Remove-Item -LiteralPath $script:recoveryDatabase
            $path=Join-Path (Split-Path -Parent $Root) 'qualification-fixture.json';$claim=Read-QualificationFixtureJson -Path $path;$claim.status='disposed';Write-QualificationFixtureJson -Path $path -Value $claim
        }
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
        Test-Path -LiteralPath $script:recoveryDatabase|Should -BeTrue
        $script:ownerAvailable=$true
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -Exactly -ParameterFilter {$Root -eq $copy.fixture.branchRoot}
    }
    It 'reclaims <state> factory copies, retaining exact source data and the immutable seed' -ForEach @(@{state='materializing'},@{state='preparation-failed'},@{state='unclaimed'}) {
        $root=Join-Path $TestDrive ('неудачная подготовка '+[guid]::NewGuid().ToString('N'));$copy=New-RecoverableStorageCopy -Root $root -State $state
        if($state -eq 'unclaimed'){Remove-Item -LiteralPath (Join-Path $copy.root 'qualification-fixture.json')}
        $binary=Join-Path $copy.fixture.branchRoot 'src/cf/данные с пробелами.bin';$bytes=[byte[]](0,13,10,255,192,128,1);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $binary));[IO.File]::WriteAllBytes($binary,$bytes)
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy
        $result.removed|Should -Be 1;Test-Path -LiteralPath $copy.root|Should -BeFalse
        $diagnostics=$result.entries[0].diagnostics
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $diagnostics 'recovery.zip'))
        try {$stream=$zip.GetEntry('branch/src/cf/данные с пробелами.bin').Open();$output=[IO.MemoryStream]::new();try{$stream.CopyTo($output);[Convert]::ToBase64String($output.ToArray())|Should -BeExactly ([Convert]::ToBase64String($bytes))}finally{$stream.Dispose();$output.Dispose()}}finally{$zip.Dispose()}
        $index=Read-QualificationFixtureJson -Path (Join-Path $diagnostics 'recovery-index.json')
        $retained=@($index|Where-Object retainedSource)[0]
        (Get-FileHash -LiteralPath $retained.retainedSource).Hash.ToLowerInvariant()|Should -BeExactly $retained.sha256
        Test-Path -LiteralPath (Join-Path $diagnostics 'source.bundle')|Should -BeTrue
    }
    It 'requires hashed terminal owner proof for an old ready copy, then completes the same cleanup' {
        $root=Join-Path $TestDrive 'старая проверка';$copy=New-RecoverableStorageCopy -Root $root -State ready
        $copy.claim.schemaVersion=1;foreach($key in @('copyRoot','projectsRoot','workflowCommonGit')){$copy.claim.Remove($key)}
        Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
        Mock Get-SourceE2ECopyReportBinding {return @{kind='passed-negative';path='original frozen report';sha256=('a'*64);capsule=$null}}
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
    }
    It 'retains a recovery target with <reason> before any archive or base disposal' -ForEach @(@{reason='lease'},@{reason='checkpoint'},@{reason='foreign-source'},@{reason='changed-seed'},@{reason='Release'}) {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$copy=New-RecoverableStorageCopy -Root $root
        $lease=$null
        switch($reason){
            lease {$lease=Open-SourceE2EFixtureUse -ProjectRoot $copy.fixture.projectRoot}
            checkpoint {Write-QualificationFixtureJson -Path (Join-Path $copy.fixture.branchRoot '.agent-1c/runs/release/checkpoint.json') -Value @{status='failed';snapshot='needed for restart'}}
            foreign-source {Invoke-RepositoryGit -RepositoryRoot $copy.fixture.projectRoot -Arguments @('remote','set-url','origin','https://example.invalid/foreign.git')|Out-Null}
            changed-seed {Write-Utf8Text -Path (Join-Path (Split-Path -Parent $copy.claim.capsulePath) 'infobase.dt') -Value 'changed seed'}
            Release {$copy.claim.phase='Release';Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim}
        }
        Mock Invoke-SourceFixtureInstalledAction {throw 'must not dispose a protected base'}
        try {
            $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy
            $result.removed|Should -Be 0;Test-Path -LiteralPath $copy.root|Should -BeTrue
            Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0
        }finally{if($lease){$lease.Dispose()}}
    }
}

Describe 'UTF-8 tails during concurrent child output' {
    It 'waits for an incomplete character and rejects a truncated completed transport' {
        $path=Join-Path $TestDrive 'поток с пробелами.log'
        $utf8=[Text.UTF8Encoding]::new($false);$bytes=$utf8.GetBytes('prefix Я')
        [IO.File]::WriteAllBytes($path,$bytes[0..($bytes.Length-2)])
        (Read-SourceE2EOutputTail -Path $path)|Should -BeExactly 'prefix '
        {Read-SourceE2EOutputTail -Path $path -Complete}|Should -Throw
        [IO.File]::WriteAllBytes($path,$bytes)
        (Read-SourceE2EOutputTail -Path $path -Complete)|Should -BeExactly 'prefix Я'
    }
}
