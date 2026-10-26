BeforeAll {
    $RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')
    function New-StorageCopy {
        param([string]$Root,[string]$Status='passed',[string]$Candidate=('a'*40),[string]$Capsule=('f'*64),[string]$Phase='Develop')
        $candidate=$Candidate;$capsule=$Capsule
        $parent=Join-Path $Root ('q Проект/'+$Phase.ToLowerInvariant()+'-'+$capsule.Substring(0,12)+'-'+$candidate.Substring(0,12)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
        $project=Join-Path $parent 'project';$branch=Join-Path $parent 'branch'
        [void][IO.Directory]::CreateDirectory($project)
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('init','-b','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.name','Fixture')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.email','fixture@example.invalid')|Out-Null
        Write-Utf8Text -Path (Join-Path $project 'seed.txt') -Value 'immutable source'
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('commit','-m','fixture')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('worktree','add','--detach',$branch,'HEAD')|Out-Null
        $claim=@{schemaVersion=2;kind='itl-qualification-fixture-target';status='disposed';phase=$Phase;projectRoot=$project;branchRoot=$branch;copyRoot=$parent;projectsRoot=$Root;candidateCommit=$candidate;capsuleSha256=$capsule;workflowCommonGit=(Get-RepositoryCommonGitDirectory -RepositoryRoot $RepoRoot)}
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
        param([string]$Root,[string]$State='materializing',[string]$Phase='Develop')
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
        Write-QualificationFixtureJson -Path $manifest -Value @{schemaVersion=1;kind='itl-qualification-fixture';status='sealed';phase=$Phase;infoBaseKind='file';branchName='golden';masterCommit=$head;branchCommit=$head;workflowCommit=$candidate;files=$files}
        $sha=(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()
        $copy=New-StorageCopy -Root $Root -Candidate $candidate -Capsule $sha -Phase $Phase
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
    It 'cleans terminal copies in nested Unicode canary roots and retries a leased copy without traversing foreign projects' {
        $root=Join-Path $TestDrive 'nested Пример'
        $direct=New-StorageCopy -Root $root
        $nested=New-StorageCopy -Root (Join-Path $root 'canary Один')
        $leased=New-StorageCopy -Root (Join-Path $root 'canary Два')
        foreach($copy in @($direct,$nested,$leased)){
            Write-SourceE2EFixtureTerminal -Fixture $copy.fixture -CandidateRoot $RepoRoot -ReportPath $copy.report
        }
        $foreign=Join-Path $root 'foreign/project/q Проект/keep.txt'
        Write-Utf8Text -Path $foreign -Value 'outside the one grouping level'
        $lease=Open-SourceE2EFixtureUse -ProjectRoot $leased.fixture.projectRoot
        $arguments=@{ProjectsRoot=$root;CandidateRoot=$RepoRoot;DiagnosticRoot=(Join-Path $root 'diagnostics');IncludeNestedRoots=$true}
        try {
            $result=Remove-CompletedSourceE2ECopies @arguments
            $result.removed|Should -Be 2;$result.retained|Should -Be 1
            Test-Path -LiteralPath $leased.root|Should -BeTrue
            Test-Path -LiteralPath $foreign|Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root ('diagnostics/nested/canary Один/'+(Split-Path -Leaf $nested.root)+'/qualification-fixture.json'))|Should -BeTrue
        } finally {$lease.Dispose()}
        (Remove-CompletedSourceE2ECopies @arguments).removed|Should -Be 1
        (Remove-CompletedSourceE2ECopies @arguments).removed|Should -Be 0
        Test-Path -LiteralPath $foreign|Should -BeTrue
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

Describe 'Inactive qualification copy retention during project operations' {
    It 'keeps one newest owned ready copy per phase across nested roots and respects the configured age' {
        $root=Join-Path $TestDrive 'age policy Пример';$now=[datetime]::UtcNow
        $expected=@()
        foreach($phase in @('Develop','Release')){
            foreach($age in @(20,10)){
                $copy=New-StorageCopy -Root (Join-Path $root ($phase+$age)) -Phase $phase
                $copy.claim.status='ready';Write-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json') -Value $copy.claim
                (Get-Item -LiteralPath (Join-Path $copy.root 'qualification-fixture.json')).LastWriteTimeUtc=$now.AddDays(-$age)
                if($age -eq 20){$expected+=$copy.root}
            }
        }
        $foreign=New-StorageCopy -Root (Join-Path $root 'foreign')
        $foreign.claim.status='ready';$foreign.claim.workflowCommonGit='foreign-owner'
        Write-QualificationFixtureJson -Path (Join-Path $foreign.root 'qualification-fixture.json') -Value $foreign.claim
        $roots=@(Get-SourceE2EProjectsRoots -ProjectsRoot $root -IncludeNestedRoots)
        $plan=Get-SourceE2ECopyRetentionPlan -ProjectsRoots $roots -CandidateRoot $RepoRoot -NowUtc $now
        $plan.archivePaths.Count|Should -Be 2
        foreach($path in $expected){$plan.archivePaths|Should -Contain $path}
        (Get-SourceE2ECopyRetentionPlan -ProjectsRoots $roots -CandidateRoot $RepoRoot -RetentionDays 30 -NowUtc $now).archivePaths.Count|Should -Be 0
        (Get-SourceE2ECopyRetentionPlan -ProjectsRoots $roots -CandidateRoot $RepoRoot -KeepCount 0 -NowUtc $now).archivePaths.Count|Should -Be 4
    }
    It 'reads source env limits without importing unrelated settings and rejects invalid values before deletion' {
        $root=Join-Path $TestDrive 'settings Пример';$primary=Join-Path $root 'primary';$candidate=Join-Path $root 'executor'
        Mock Get-RepositoryCommonGitDirectory {Join-Path $primary '.git'} -ParameterFilter {$RepositoryRoot -eq $candidate}
        $names=@('ITL_SOURCE_FIXTURE_CLEANUP_ENABLED','ITL_SOURCE_FIXTURE_RETENTION_DAYS','ITL_SOURCE_FIXTURE_KEEP_COUNT','ITL_SOURCE_FIXTURE_ARCHIVE_BATCH_SIZE')
        $saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        try {
            $defaults=Get-SourceE2ECopyRetentionSettings -CandidateRoot $candidate
            $defaults.enabled|Should -BeTrue;$defaults.days|Should -Be 7;$defaults.keep|Should -Be 1;$defaults.batch|Should -Be 1
            Write-Utf8Text -Path (Join-Path $primary '.dev.env') -Value "ITL_SOURCE_FIXTURE_CLEANUP_ENABLED=false`nITL_SOURCE_FIXTURE_RETENTION_DAYS='14'`nITL_SOURCE_FIXTURE_KEEP_COUNT=2`nITL_RETENTION_TEST_UNRELATED=do-not-import"
            Write-Utf8Text -Path (Join-Path $candidate '.dev.env') -Value 'ITL_SOURCE_FIXTURE_KEEP_COUNT="1"'
            $settings=Get-SourceE2ECopyRetentionSettings -CandidateRoot $candidate
            $settings.enabled|Should -BeFalse;$settings.days|Should -Be 14;$settings.keep|Should -Be 1
            [Environment]::GetEnvironmentVariable('ITL_RETENTION_TEST_UNRELATED','Process')|Should -BeNullOrEmpty
            $env:ITL_SOURCE_FIXTURE_KEEP_COUNT='0'
            (Get-SourceE2ECopyRetentionSettings -CandidateRoot $candidate).keep|Should -Be 0
            $env:ITL_SOURCE_FIXTURE_RETENTION_DAYS='-1'
            {Get-SourceE2ECopyRetentionSettings -CandidateRoot $candidate}|Should -Throw '*FIXTURE_RETENTION_SETTINGS_INVALID*repeat the same operation*'
        } finally {foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}
    }
    It 'archives an expired ready copy automatically and resumes interrupted removal from the same verified archive' {
        $root=Join-Path $TestDrive 'automatic archive Пример';$copy=New-RecoverableStorageCopy -Root (Join-Path $root 'old canary') -State ready
        $new=New-RecoverableStorageCopy -Root (Join-Path $root 'new canary') -State ready
        $script:retentionDatabase=Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/test/1Cv8.1CD'
        Write-Utf8Text -Path $script:retentionDatabase -Value 'database unique to original failed canary'
        Get-ChildItem -LiteralPath $copy.root -Recurse -Force -File | ForEach-Object {
            # Desktop .NET cannot stamp read-only Git objects. Restore their
            # original attributes so the old-copy fixture retains the real shape.
            $attributes=$_.Attributes
            try {$_.IsReadOnly=$false;$_.LastWriteTimeUtc=[datetime]::UtcNow.AddDays(-10)}finally{$_.Attributes=$attributes}
        }
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root,$Arguments)
            $Arguments|Should -Contain '-ArchivedInactive'
            Remove-Item -LiteralPath $script:retentionDatabase
            $path=Join-Path (Split-Path -Parent $Root) 'qualification-fixture.json';$claim=Read-QualificationFixtureJson -Path $path
            $claim.status='disposed';$claim|Add-Member -NotePropertyName disposal -NotePropertyValue @{status='disposed';candidateCommit=$claim.candidateCommit}
            Write-QualificationFixtureJson -Path $path -Value $claim
        }
        $script:interruptRetention=$true
        Mock Remove-Item {
            param($LiteralPath)
            if($script:interruptRetention){throw 'injected interruption after retention disposal'}
            if(-not [IO.Path]::GetFullPath($LiteralPath).StartsWith([IO.Path]::GetFullPath($TestDrive)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TEST_DELETE_OUTSIDE_TESTDRIVE'}
            foreach($file in [IO.Directory]::EnumerateFiles($LiteralPath,'*',[IO.SearchOption]::AllDirectories)){[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)}
            [IO.Directory]::Delete($LiteralPath,$true)
        } -ParameterFilter {$LiteralPath -eq $copy.root}
        $roots=@(Get-SourceE2EProjectsRoots -ProjectsRoot $root -IncludeNestedRoots)
        $plan=Get-SourceE2ECopyRetentionPlan -ProjectsRoots $roots -CandidateRoot $RepoRoot
        $plan.archivePaths.Count|Should -Be 1
        $arguments=@{ProjectsRoot=$root;CandidateRoot=$RepoRoot;DiagnosticRoot=(Join-Path $root 'diagnostics');IncludeNestedRoots=$true}
        $budget=@{remaining=0}
        $deferred=Remove-CompletedSourceE2ECopies @arguments -ArchiveReadyPaths $plan.archivePaths -InactiveBeforeUtc $plan.inactiveBeforeUtc -ArchiveBudget $budget
        ($deferred.entries|Where-Object root -eq $copy.root).reason|Should -BeLike '*FIXTURE_COPY_ARCHIVE_DEFERRED*'
        $budget.remaining=1
        $first=Remove-CompletedSourceE2ECopies @arguments -ArchiveReadyPaths $plan.archivePaths -InactiveBeforeUtc $plan.inactiveBeforeUtc -ArchiveBudget $budget
        $budget.remaining|Should -Be 0
        $first.removed|Should -Be 0
        $archive=Join-Path $root ('diagnostics/nested/old canary/'+(Split-Path -Leaf $copy.root)+'/recovery.zip')
        $sha=(Get-FileHash -LiteralPath $archive).Hash
        $script:interruptRetention=$false
        (Get-SourceE2ECopyRetentionPlan -ProjectsRoots $roots -CandidateRoot $RepoRoot).archivePaths.Count|Should -Be 0
        (Remove-CompletedSourceE2ECopies @arguments -ArchiveBudget $budget).removed|Should -Be 1
        (Get-FileHash -LiteralPath $archive).Hash|Should -BeExactly $sha
        Test-Path -LiteralPath $new.root|Should -BeTrue
        Test-Path -LiteralPath $copy.root|Should -BeFalse
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -Exactly
    }
    It 'rechecks all file activity under the copy lease before creating an automatic archive' {
        $root=Join-Path $TestDrive 'recent activity Пример';$copy=New-RecoverableStorageCopy -Root $root -State ready
        (Get-Item -LiteralPath (Join-Path $copy.root 'qualification-fixture.json')).LastWriteTimeUtc=[datetime]::UtcNow.AddDays(-10)
        $plan=Get-SourceE2ECopyRetentionPlan -ProjectsRoots @($root) -CandidateRoot $RepoRoot -KeepCount 0
        $plan.archivePaths.Count|Should -Be 1
        Mock Invoke-SourceFixtureInstalledAction {throw 'must not dispose a recently active copy'}
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -ArchiveReadyPaths $plan.archivePaths -InactiveBeforeUtc $plan.inactiveBeforeUtc
        $result.removed|Should -Be 0;$result.entries[0].reason|Should -BeLike '*FIXTURE_COPY_RECENT_ACTIVITY*'
        Test-Path -LiteralPath $copy.root|Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $root 'diagnostics') -Recurse -Filter '*.zip' -ErrorAction SilentlyContinue).Count|Should -Be 0
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0
    }
}

Describe 'Failed factory and unclosed qualification copy recovery' {
    It 'archives the exact inactive database and raw Git state before disposing <phase>, and keeps Release checkpoints' -ForEach @(@{phase='Develop'},@{phase='Release'}) -Tag archive_inactive {
        $root=Join-Path $TestDrive ('archive Пример '+$phase);$copy=New-RecoverableStorageCopy -Root $root -State ready -Phase $phase
        $script:archiveDatabase=Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/test/1Cv8.1CD'
        Write-Utf8Text -Path $script:archiveDatabase -Value 'unique database state after the original failure'
        $indexHash=(Get-FileHash -LiteralPath (Join-Path $copy.fixture.projectRoot '.git/index')).Hash
        $diagnostics=Join-Path $root 'diagnostics'
        $checkpoint=Join-Path $copy.fixture.branchRoot '.agent-1c/runs/release-e2e/test/checkpoint.json'
        Write-QualificationFixtureJson -Path $checkpoint -Value @{status='passed';lastPassedStage='extension-smoke'}
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root,$Arguments)
            $Arguments|Should -Contain '-ArchivedInactive'
            $i=[Array]::IndexOf($Arguments,'-RecoveryArchiveIndex');$folder=Split-Path -Parent $Arguments[$i+1]
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $folder 'recovery.zip'))
            try {$zip.GetEntry('branch/.agent-1c/infobases/test/1Cv8.1CD')|Should -Not -BeNullOrEmpty;$zip.GetEntry('project/.git/index')|Should -Not -BeNullOrEmpty}finally{$zip.Dispose()}
            Remove-Item -LiteralPath $script:archiveDatabase
            $path=Join-Path (Split-Path -Parent $Root) 'qualification-fixture.json';$claim=Read-QualificationFixtureJson -Path $path;$claim.status='disposed'
            $claim|Add-Member -NotePropertyName disposal -NotePropertyValue @{status='disposed';candidateCommit=$claim.candidateCommit}
            Write-QualificationFixtureJson -Path $path -Value $claim
        }
        $arguments=@{Fixture=$copy.fixture;CandidateRoot=$RepoRoot;ProjectsRoot=$root;DiagnosticRoot=$diagnostics;ReportPath=(Join-Path $diagnostics 'cleanup-proof.json');RecoveryCleanup=$true;ArchiveInactive=$true}
        $ledgerPath=Join-Path (Get-RepositoryCommonGitDirectory -RepositoryRoot $RepoRoot) 'itl/resources/v1/ledger.json'
        $script:archiveRetainedReference=$true
        Mock Test-Path {return $true} -ParameterFilter {$LiteralPath -eq $ledgerPath}
        Mock Read-QualificationFixtureJson {if($script:archiveRetainedReference){return @{resources=@(@{state='retained';identity=[pscustomobject]@{path=$copy.root}})}}else{return @{resources=@()}}} -ParameterFilter {$Path -eq $ledgerPath}
        {Remove-SourceE2EFixtureCopy @arguments}|Should -Throw '*FIXTURE_COPY_PRESERVED*'
        $script:archiveRetainedReference=$false
        {Remove-SourceE2EFixtureCopy @arguments}|Should -Throw '*FIXTURE_COPY_RESUMABLE*'
        Test-Path -LiteralPath $script:archiveDatabase|Should -BeTrue
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0
        Remove-Item -LiteralPath $checkpoint
        $script:archiveRemovalInterrupted=$true
        Mock Remove-Item {
            param([string]$LiteralPath)
            if($script:archiveRemovalInterrupted){throw 'injected interruption after archived database disposal'}
            if(-not [IO.Path]::GetFullPath($LiteralPath).StartsWith([IO.Path]::GetFullPath($TestDrive)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TEST_DELETE_OUTSIDE_TESTDRIVE'}
            foreach($file in [IO.Directory]::EnumerateFiles($LiteralPath,'*',[IO.SearchOption]::AllDirectories)){[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)}
            [IO.Directory]::Delete($LiteralPath,$true)
        } -ParameterFilter {$LiteralPath -eq $copy.root}
        {Remove-SourceE2EFixtureCopy @arguments}|Should -Throw '*injected interruption*'
        $archiveHash=(Get-FileHash -LiteralPath (Join-Path $diagnostics 'recovery.zip')).Hash
        $script:archiveRemovalInterrupted=$false
        (Remove-SourceE2EFixtureCopy @arguments).status|Should -BeExactly 'archived-inactive'
        (Get-FileHash -LiteralPath (Join-Path $diagnostics 'recovery.zip')).Hash|Should -BeExactly $archiveHash
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -Exactly
        $restore=Join-Path $root 'restored';[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $diagnostics 'recovery.zip'),$restore)
        (Read-Utf8Text -Path (Join-Path $restore 'branch/.agent-1c/infobases/test/1Cv8.1CD'))|Should -BeExactly 'unique database state after the original failure'
        (Get-FileHash -LiteralPath (Join-Path $restore 'project/.git/index')).Hash|Should -BeExactly $indexHash
        (Read-QualificationFixtureJson -Path (Join-Path $restore 'qualification-fixture.json')).status|Should -BeExactly 'ready'
        (Read-QualificationFixtureJson -Path (Join-Path $diagnostics 'cleanup-proof.json')).reason|Should -BeExactly 'archive-inactive-qualification'
    }
    It 'continues interrupted cleanup after the base owner already recorded disposal' -Tag recovery_resume {
        $root=Join-Path $TestDrive 'disposed retry Пример';$copy=New-RecoverableStorageCopy -Root $root -State preparation-failed
        $script:disposedRetryDatabase=Join-Path $copy.fixture.branchRoot '.agent-1c/infobases/test/1Cv8.1CD'
        Write-Utf8Text -Path $script:disposedRetryDatabase -Value 'incomplete derived base'
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root)
            Remove-Item -LiteralPath $script:disposedRetryDatabase
            $path=Join-Path (Split-Path -Parent $Root) 'qualification-fixture.json'
            $claim=Read-QualificationFixtureJson -Path $path;$claim.status='disposed'
            $claim|Add-Member -NotePropertyName disposal -NotePropertyValue @{status='disposed';candidateCommit=$claim.candidateCommit;removedDatabases=@(@{path=$script:disposedRetryDatabase})}
            Write-QualificationFixtureJson -Path $path -Value $claim
        }
        $script:interruptDisposedRetry=$true
        Mock Remove-Item {
            param([string]$LiteralPath)
            if($script:interruptDisposedRetry){throw 'injected interruption after owned disposal'}
            if(-not [IO.Path]::GetFullPath($LiteralPath).StartsWith([IO.Path]::GetFullPath($TestDrive)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TEST_DELETE_OUTSIDE_TESTDRIVE'}
            foreach($file in [IO.Directory]::EnumerateFiles($LiteralPath,'*',[IO.SearchOption]::AllDirectories)){[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)}
            [IO.Directory]::Delete($LiteralPath,$true)
        } -ParameterFilter {$LiteralPath -eq $copy.root}
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 0
        $diagnostics=Join-Path (Join-Path $root 'diagnostics') (Split-Path -Leaf $copy.root)
        $archive=Join-Path $diagnostics 'recovery.zip';$sha=(Get-FileHash -LiteralPath $archive).Hash
        (Read-QualificationFixtureJson -Path (Join-Path $copy.root 'qualification-fixture.json')).status|Should -BeExactly 'disposed'
        $script:interruptDisposedRetry=$false
        (Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy).removed|Should -Be 1
        (Get-FileHash -LiteralPath $archive).Hash|Should -BeExactly $sha
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -Exactly
    }
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
    It 'requires a complete fresh reader inventory after a transient query failure (<Mode>)' -ForEach @(
        @{Mode='empty';ExpectedRemoved=1},@{Mode='reader';ExpectedRemoved=0},@{Mode='unavailable';ExpectedRemoved=0}
    ) {
        $root=Join-Path $TestDrive ('CIM повтор Пример '+$Mode);$copy=New-RecoverableStorageCopy -Root $root -State preparation-failed
        $script:inventoryAttempts=0
        Mock Get-CimInstance {
            $script:inventoryAttempts++
            # A provider may emit rows before its terminal error. They must
            # never become a successful empty/partial snapshot.
            if($script:inventoryAttempts -eq 1 -or $Mode -eq 'unavailable') {
                [pscustomobject]@{ProcessId=999992;CommandLine='unrelated.exe'}
                throw [TimeoutException]::new('reader enumeration timed out')
            }
            if($Mode -eq 'reader') {[pscustomobject]@{ProcessId=999991;CommandLine=('editor.exe "'+$copy.fixture.branchRoot+'"')}}
        }
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $root -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $root 'diagnostics') -IncludeLegacy
        $result.removed | Should -Be $ExpectedRemoved
        (Test-Path -LiteralPath $copy.root) | Should -Be ($ExpectedRemoved -eq 0)
        Should -Invoke Get-CimInstance -Times 2 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_Process' -and $OperationTimeoutSec -eq 2 -and
            (@($Property | Sort-Object) -join ',') -eq 'CommandLine,ProcessId'
        }
        if($Mode -eq 'unavailable') {$result.entries[0].reason | Should -Match 'FIXTURE_COPY_PROCESS_INVENTORY_UNAVAILABLE'}
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
