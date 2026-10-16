BeforeAll {
    $RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')
    function New-StorageCopy {
        param([string]$Root,[string]$Status='passed',[string]$Candidate=('a'*40))
        $candidate=$Candidate;$capsule='f'*64
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
