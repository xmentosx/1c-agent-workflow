BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
    function Add-CandidateTask {
        param([string]$Root, [string]$Name)
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'tests\pester') | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root "$Name.ps1"), "'$Name'", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root "tests\pester\$Name.Tests.ps1"), "Describe '$Name' { It 'exists' { `$true | Should -BeTrue } }", [Text.UTF8Encoding]::new($false))
        & git -C $Root add --all
        & git -C $Root commit --quiet -m "test: $Name"
        if ($LASTEXITCODE) { throw 'Could not commit candidate task' }
        return (& git -C $Root rev-parse HEAD).Trim()
    }
    function Set-CandidateGateHook {
        param([string]$Path, [string]$Code)
        $text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
        $exit=$text.LastIndexOf('exit 0',[StringComparison]::Ordinal)
        if ($exit -lt 0 -or $text.Substring($exit).Trim() -ne 'exit 0') { throw 'Fixture gate final exit changed; inspect before inserting hook' }
        [IO.File]::WriteAllText($Path,($text.Substring(0,$exit)+$Code+"`r`n"+$text.Substring($exit)),[Text.UTF8Encoding]::new($true))
    }
    function Start-CandidateRegistration {
        param([object]$Fixture, [string]$Root, [string]$Id, [string]$LogRoot)
        $stdout = Join-Path $LogRoot "$Id.out"
        $stderr = Join-Path $LogRoot "$Id.err"
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$DeliveryScript+'"'),'-Action','RegisterChange','-RepositoryRoot',('"'+$Root+'"'),'-GateScript',('"'+$Fixture.gate+'"'),'-QueueId',$Id)
        $process = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        return [pscustomobject]@{ process=$process; stdout=$stdout; stderr=$stderr }
    }
    function Complete-CandidateRegistration {
        param([object]$Job)
        if (-not $Job.process.WaitForExit(180000)) { throw "Registration fixture timed out; PID $($Job.process.Id)" }
        $Job.process.Refresh()
        if ($Job.process.ExitCode) { throw (Get-Content -LiteralPath $Job.stderr -Raw -Encoding UTF8) }
        return Get-Content -LiteralPath $Job.stdout -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

Describe 'Shared source candidate registration' {
    It 'bounds repeated CAS losses by one original deadline and leaves an agent-readable continuation' {
        & {
            $definition=(Get-DeliveryFunctionDefinitions -Names Register-SourceChange | Select-Object -First 1).Extent.Text
            Invoke-Expression $definition
            $script:Root=$TestDrive; $script:Remote='origin'; $script:GateScript='injected-gate.ps1'
            $script:budgetReads=0; $script:gateDeadlines=@(); $script:casAttempts=0
            $BaseRef=''; $QueueId='bounded-race'; $CoverageContract=@()
            function Assert-CleanDeliveryWorktree { }
            function Get-GitValue { param($Arguments); if ($Arguments[-1] -eq 'HEAD') { return ('b'*40) }; return ('a'*40) }
            function ConvertTo-QueueRefName { param($Value) return $Value }
            function Get-SourceGateHardBudgetSeconds { param($Mode,$WorkingRoot,[switch]$AllowMissingCatalog); $script:budgetReads++; return 0.55 }
            function Get-SourceRegistrationSnapshot { return [pscustomobject]@{ entries=@(); remoteBefore=('a'*40) } }
            function Invoke-DeliveryGit { param($Arguments,[switch]$AllowFailure); return [pscustomobject]@{ exitCode=0; stdout='' } }
            function Get-RepositoryGitPathList { param($RepositoryRoot,$Arguments); return 'tests/pester/Bounded.Tests.ps1' }
            function Get-SourceRegistrationStartPoint { param($Snapshot); return ('a'*40) }
            function New-DeliveryWorktree { param($StartPoint,$Purpose); return [pscustomobject]@{ path=$TestDrive; branch='fixture-only' } }
            function Add-QueuedRangesToCandidate { param($CandidateRoot,$Entries) }
            function Invoke-WorktreeGit {
                param($Root,$Arguments)
                $out=if ($Arguments[0] -eq 'rev-parse') { 'b'*40 } else { '' }
                return [pscustomobject]@{ stdout=$out; exitCode=0 }
            }
            function Invoke-SourceGate { param($Mode,$WorkingRoot,$TargetBaseRef,$DeadlineUtc); $script:gateDeadlines+=$DeadlineUtc; Start-Sleep -Milliseconds 100 }
            function Save-SourceRegistrationEvidence { param($CandidateRoot,$Candidate,$RunRecordPath); return [pscustomobject]@{ path='fixture-evidence' } }
            function Try-AcceptSourceRegistration { param($Snapshot,$Id,$Base,$Head,$Candidate,$Tree,$Entries); $script:casAttempts++; return $false }
            function Remove-DeliveryWorktree { param($Worktree); throw 'A rejected candidate must survive' }
            $clock=[Diagnostics.Stopwatch]::StartNew()
            { Register-SourceChange -WarningAction SilentlyContinue } | Should -Throw '*repeat RegisterChange with the same QueueId*'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            $script:budgetReads | Should -Be 1
            $script:gateDeadlines.Count | Should -BeGreaterThan 1
            @($script:gateDeadlines | Select-Object -Unique) | Should -HaveCount 1
            $script:casAttempts | Should -BeGreaterThan 0
            $checkpoint=Get-Content -LiteralPath (Join-Path $TestDrive 'build\source-registration\checkpoint.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $checkpoint.id | Should -Be 'bounded-race'
            $checkpoint.taskHead | Should -Be ('b'*40)
            $checkpoint.sourceRoot | Should -Be $TestDrive
        }
    }

    It 'rejects a mergeable semantic conflict against accepted work and preserves both task heads' {
        $fixture=$null; $parallel=''
        try {
            $fixture=New-DeliveryFixture
            # Each branch passes alone; only the actual integrated tree fails.
            Set-CandidateGateHook -Path $fixture.gate -Code "if ((Test-Path -LiteralPath './alpha.ps1') -and (Test-Path -LiteralPath './beta.ps1')) { exit 29 }"
            & git -C $fixture.root add fake-gate.ps1
            & git -C $fixture.root commit --quiet -m 'test: incompatible combined contract'
            & git -C $fixture.root push --quiet origin HEAD:develop
            $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
            $alpha=Add-CandidateTask -Root $fixture.root -Name alpha
            $missingGate=Join-Path $fixture.root 'отсутствующий gate с пробелами.ps1'
            $unicodeFailure=Invoke-DeliveryTestPowerShell -Arguments @('-Action','RegisterChange','-RepositoryRoot',('"'+$fixture.root+'"'),'-GateScript',('"'+$missingGate+'"'),'-QueueId','alpha') -AllowFailure
            $unicodeFailure.exitCode | Should -Not -Be 0
            # PS5 formats an error across physical lines, including inside a
            # Cyrillic word. Remove only those CR/LF record wraps: every space
            # and Unicode character of the original path must remain exact.
            $unwrappedError=$unicodeFailure.stderr.Replace("`r",'').Replace("`n",'')
            $unwrappedError.IndexOf($missingGate,[StringComparison]::Ordinal) | Should -BeGreaterOrEqual 0 -Because ("the complete Unicode path and its spaces must survive the native error boundary. Actual stderr: " + $unicodeFailure.stderr)
            (& git -C $fixture.root rev-parse HEAD).Trim() | Should -Be $alpha
            @(& git -C $fixture.root status --porcelain) | Should -HaveCount 0
            & git -C $fixture.root show-ref --verify --quiet refs/itl/develop-queue/alpha/head
            $LASTEXITCODE | Should -Not -Be 0
            # Correct the missing gate and finish the same task/QueueId through
            # the normal owner; do not bypass registration after the rejection.
            $a=(Invoke-DeliveryTestPowerShell -Arguments @('-Action','RegisterChange','-RepositoryRoot',('"'+$fixture.root+'"'),'-GateScript',('"'+$fixture.gate+'"'),'-QueueId','alpha')).stdout | ConvertFrom-Json
            $parallel=Join-Path $TestDrive 'вторая задача с пробелами'
            & git -C $fixture.root worktree add --quiet -b candidate-beta $parallel $fixture.base
            $beta=Add-CandidateTask -Root $parallel -Name beta
            $failed=Invoke-DeliveryTestPowerShell -Arguments @('-Action','RegisterChange','-RepositoryRoot',('"'+$parallel+'"'),'-GateScript',('"'+$fixture.gate+'"'),'-QueueId','beta') -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            $failed.stderr | Should -Match 'Targeted source gate failed with exit code 29'
            (& git -C $fixture.root rev-parse refs/itl/develop-candidate/head).Trim() | Should -Be $a.candidate
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -Be $alpha
            & git -C $fixture.root show-ref --verify --quiet refs/itl/develop-queue/beta/head
            $LASTEXITCODE | Should -Not -Be 0
            (& git -C $parallel rev-parse HEAD).Trim() | Should -Be $beta
            @(& git -C $parallel status --porcelain) | Should -HaveCount 0
            # Original independent task passes when run outside the combination.
            Push-Location $parallel
            try { & powershell.exe -NoProfile -File $fixture.gate -Mode Targeted; $LASTEXITCODE | Should -Be 0 } finally { Pop-Location }
        } finally {
            if ($fixture -and $parallel) { & git -C $fixture.root worktree remove --force $parallel *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }

    It 'runs independent native gates concurrently and retries the losing CAS against the accepted candidate' {
        $fixture=$null; $parallel=''; $jobs=@(); $oldBarrier=$env:ITL_TEST_CANDIDATE_BARRIER
        try {
            $fixture=New-DeliveryFixture
            $barrier=Join-Path $TestDrive 'общий барьер с пробелами'
            New-Item -ItemType Directory -Force -Path $barrier | Out-Null
            $env:ITL_TEST_CANDIDATE_BARRIER=$barrier
            Set-CandidateGateHook -Path $fixture.gate -Code @'
if ($Mode -eq 'Targeted') {
    $barrier=$env:ITL_TEST_CANDIDATE_BARRIER
    $record=[ordered]@{ base=$BaseRef; candidate=(& git rev-parse HEAD).Trim(); started=[DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Join-Path $barrier "$PID.json"), ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $limit=[DateTime]::UtcNow.AddSeconds(90)
    while (@([IO.Directory]::GetFiles($barrier,'*.json')).Count -lt 2) {
        if ([DateTime]::UtcNow -ge $limit) { exit 37 }
        Start-Sleep -Milliseconds 25
    }
}
'@
            & git -C $fixture.root add fake-gate.ps1
            & git -C $fixture.root commit --quiet -m 'test: native candidate race barrier'
            & git -C $fixture.root push --quiet origin HEAD:develop
            $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
            $alpha=Add-CandidateTask -Root $fixture.root -Name alpha
            $parallel=Join-Path $TestDrive 'параллельная задача'
            & git -C $fixture.root worktree add --quiet -b candidate-beta $parallel $fixture.base
            $beta=Add-CandidateTask -Root $parallel -Name beta
            $jobs+=Start-CandidateRegistration -Fixture $fixture -Root $fixture.root -Id alpha -LogRoot $TestDrive
            $jobs+=Start-CandidateRegistration -Fixture $fixture -Root $parallel -Id beta -LogRoot $TestDrive
            $a=Complete-CandidateRegistration $jobs[0]
            $b=Complete-CandidateRegistration $jobs[1]
            ([int]$a.attempts+[int]$b.attempts) | Should -Be 3
            $winner=if ($a.attempts -eq 1) { $a } else { $b }
            $last=if ($a.attempts -eq 2) { $a } else { $b }
            $records=@(Get-ChildItem -LiteralPath $barrier -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
            $records | Should -HaveCount 3
            @($records | Where-Object base -eq $fixture.base) | Should -HaveCount 2
            @($records | Where-Object base -eq $winner.candidate) | Should -HaveCount 1
            (& git -C $fixture.root rev-parse refs/itl/develop-candidate/head).Trim() | Should -Be $last.candidate
            foreach ($head in @($alpha,$beta)) { & git -C $fixture.root merge-base --is-ancestor $head $last.candidate; $LASTEXITCODE | Should -Be 0 }
            $state=& git -C $fixture.root cat-file blob refs/itl/develop-candidate/state | ConvertFrom-Json
            @($state.queue.id | Sort-Object) | Should -Be @('alpha','beta')
            @(& git -C $fixture.root status --porcelain) | Should -HaveCount 0
            @(& git -C $parallel status --porcelain) | Should -HaveCount 0
        } finally {
            $env:ITL_TEST_CANDIDATE_BARRIER=$oldBarrier
            foreach ($job in $jobs) { if (-not $job.process.HasExited) { Stop-Process -Id $job.process.Id -Force } }
            if ($fixture -and $parallel) { & git -C $fixture.root worktree remove --force $parallel *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }

    It 'qualifies legacy queue entries on migration and preserves additions made through the legacy ref contract' {
        $fixture=$null; $parallel=''
        try {
            $fixture=New-DeliveryFixture
            $alpha=Add-CandidateTask -Root $fixture.root -Name alpha
            # Exact legacy public base/head interface; no new candidate ref yet.
            & git -C $fixture.root update-ref refs/itl/develop-queue/alpha/base $fixture.base
            & git -C $fixture.root update-ref refs/itl/develop-queue/alpha/head $alpha
            $parallel=Join-Path $TestDrive 'старый владелец очереди'
            & git -C $fixture.root worktree add --quiet -b candidate-beta $parallel $fixture.base
            $beta=Add-CandidateTask -Root $parallel -Name beta
            $b=(Invoke-DeliveryTestPowerShell -Arguments @('-Action','RegisterChange','-RepositoryRoot',('"'+$parallel+'"'),'-GateScript',('"'+$fixture.gate+'"'),'-QueueId','beta')).stdout | ConvertFrom-Json
            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base)
            foreach ($head in @($alpha,$beta)) { & git -C $fixture.root merge-base --is-ancestor $head $b.candidate; $LASTEXITCODE | Should -Be 0 }
            $gamma=Add-CandidateTask -Root $fixture.root -Name gamma
            # A rollback owner can append its record without deleting new refs.
            & git -C $fixture.root update-ref refs/itl/develop-queue/alpha/head $gamma $alpha
            $delta=Add-CandidateTask -Root $parallel -Name delta
            $d=(Invoke-DeliveryTestPowerShell -Arguments @('-Action','RegisterChange','-RepositoryRoot',('"'+$parallel+'"'),'-GateScript',('"'+$fixture.gate+'"'),'-QueueId','beta')).stdout | ConvertFrom-Json
            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base,$b.candidate)
            foreach ($head in @($gamma,$delta)) { & git -C $fixture.root merge-base --is-ancestor $head $d.candidate; $LASTEXITCODE | Should -Be 0 }
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -Be $gamma
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/beta/head).Trim() | Should -Be $delta
            $state=& git -C $fixture.root cat-file blob refs/itl/develop-candidate/state | ConvertFrom-Json
            $archive=Join-Path (Join-Path $fixture.root '.git') $state.evidence.path
            $manifestPath=Join-Path $archive 'manifest.json'
            (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $state.evidence.manifestSha256
            $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.candidate | Should -Be $d.candidate
            @($manifest.files | Where-Object path -eq 'source-registration/checkpoint.json') | Should -HaveCount 1
            foreach ($file in $manifest.files) {
                (Get-FileHash -LiteralPath (Join-Path $archive $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $file.sha256
            }
            Test-Path -LiteralPath (Join-Path (Join-Path $fixture.root '.git\itl\runs') $manifest.runRecord) | Should -BeTrue
            # Once the publisher includes the candidate, its qualified develop
            # tip becomes the baseline; released promotion must not be retested.
            $published=(& git -C $fixture.root commit-tree $state.tree -p $d.candidate -m 'test: published descendant').Trim()
            . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
            Invoke-Expression (Get-DeliveryFunctionDefinitions -Names Get-SourceRegistrationStartPoint | Select-Object -First 1).Extent.Text
            function Invoke-DeliveryGit { param($Arguments,[switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $fixture.root -Arguments $Arguments -AllowFailure:$AllowFailure }
            $snapshot=[pscustomobject]@{ state=$state; candidate=$d.candidate; remoteBefore=$published; entries=@() }
            Get-SourceRegistrationStartPoint -Snapshot $snapshot | Should -Be $published
        } finally {
            if ($fixture -and $parallel) { & git -C $fixture.root worktree remove --force $parallel *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
}
