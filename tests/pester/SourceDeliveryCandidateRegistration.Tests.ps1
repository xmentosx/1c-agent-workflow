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
    BeforeAll {
        $script:SourceGateSlotFunctions = @('Get-SourceGateSlotCount','Get-SourceGateSlotWaitSeconds','Get-SourceGateSlotRoot','Get-SourceGateSlotStatus',
            'Format-SourceGateSlotHolders','Enter-SourceGateSlot','Exit-SourceGateSlot','Test-DeliveryProcessIdentity','ConvertTo-DeliveryUtcDateTime')
        # A separate process holds slot 0 like a supervising gate, then dies
        # abruptly without releasing it.
        function Start-GateSlotHolder {
            param([string]$CommonGit, [string]$Mode, [int]$LifeMilliseconds)
            $slotRoot = Join-Path $CommonGit 'itl\gate-slots'
            New-Item -ItemType Directory -Force -Path $slotRoot | Out-Null
            $ready = Join-Path $CommonGit ("holder-" + [guid]::NewGuid().ToString('N') + '.ready')
            $code = @"
`$s=[IO.File]::Open('$((Join-Path $slotRoot 'slot-0.lock').Replace("'","''"))',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
`$me=Get-Process -Id `$PID
`$r=[ordered]@{schemaVersion=1;slot=0;mode='$Mode';pid=`$PID;processStartedAt=`$me.StartTime.ToUniversalTime().ToString('o');acquiredAt=[DateTime]::UtcNow.ToString('o');waitedSeconds=0;workingRoot='C:\holder'}
`$b=[Text.UTF8Encoding]::new(`$false).GetBytes((`$r|ConvertTo-Json -Compress))
`$s.SetLength(0);`$s.Write(`$b,0,`$b.Length);`$s.Flush()
[IO.File]::WriteAllText('$($ready.Replace("'","''"))','ready')
Start-Sleep -Milliseconds $LifeMilliseconds
[Diagnostics.Process]::GetCurrentProcess().Kill()
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $process = Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            if (-not (Test-Path -LiteralPath $ready)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; throw 'Gate slot holder did not start' }
            return $process
        }
        # Every composed check loses CAS; each gate call advances the injected
        # clock by its next duration (the last one repeats).
        function Invoke-RegistrationDeadlineFixture {
            param([int[]]$GateMilliseconds, [int]$SlotWaitMilliseconds = 0)
            foreach ($definition in @(Get-DeliveryFunctionDefinitions -Names @('Register-SourceChange','Assert-SourceRegistrationTransitionReady'))) {
                Invoke-Expression $definition.Extent.Text
            }
            $script:Root=$TestDrive; $script:Remote='origin'; $script:GateScript='injected-gate.ps1'
            $script:budgetReads=0; $script:gateDeadlines=@(); $script:casAttempts=0; $script:gateDurations=@($GateMilliseconds)
            $script:registrationNow=[DateTime]::SpecifyKind([DateTime]'2026-01-01', [DateTimeKind]::Utc)
            $startedAt=$script:registrationNow
            function Get-SourceRegistrationUtcNow { return $script:registrationNow }
            $BaseRef=''; $QueueId='bounded-race'; $CoverageContract=@()
            function Assert-CleanDeliveryWorktree { }
            function Get-DevelopPublicationAttemptPath { Join-Path $TestDrive 'no-publication-attempt.json' }
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
            function Invoke-SourceGate {
                param($Mode,$WorkingRoot,$TargetBaseRef,$DeadlineUtc)
                $script:gateDeadlines+=$DeadlineUtc
                $index=[Math]::Min($script:gateDeadlines.Count, $script:gateDurations.Count)-1
                $script:registrationNow=$script:registrationNow.AddMilliseconds($script:gateDurations[$index])
                $script:DeliveryLastGateSlotWaitSeconds=$SlotWaitMilliseconds/1000.0
            }
            function Save-SourceRegistrationEvidence { param($CandidateRoot,$Candidate,$RunRecordPath); return [pscustomobject]@{ path='fixture-evidence' } }
            function Try-AcceptSourceRegistration { param($Snapshot,$Id,$Base,$Head,$Candidate,$Tree,$Entries); $script:casAttempts++; return $false }
            function Remove-DeliveryWorktree { param($Worktree); throw 'A rejected candidate must survive' }
            $failure=$null
            try { Register-SourceChange -WarningAction SilentlyContinue | Out-Null } catch { $failure=$_.Exception.Message }
            return [pscustomobject]@{
                failure=$failure; elapsedMs=($script:registrationNow-$startedAt).TotalMilliseconds; budgetReads=$script:budgetReads
                gateDeadlines=@($script:gateDeadlines); casAttempts=$script:casAttempts
            }
        }
    }

    It 'bounds repeated CAS losses by one original deadline and leaves an agent-readable continuation' {
        $result=Invoke-RegistrationDeadlineFixture -GateMilliseconds @(100)
        # Five 100 ms checks lose CAS. The sixth would be cut by the 550 ms
        # original deadline, so it is not started; the continuation is exact.
        $result.failure | Should -BeLike "SOURCE_REGISTRATION_RACE_BUDGET:*repeat RegisterChange with the same QueueId 'bounded-race'*new budget*"
        $result.elapsedMs | Should -Be 500
        $result.budgetReads | Should -Be 1
        $result.gateDeadlines.Count | Should -Be 5
        @($result.gateDeadlines | Select-Object -Unique) | Should -HaveCount 1
        $result.casAttempts | Should -Be 5
        $checkpoint=Get-Content -LiteralPath (Join-Path $TestDrive 'build\source-registration\checkpoint.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $checkpoint.id | Should -Be 'bounded-race'
        $checkpoint.taskHead | Should -Be ('b'*40)
        $checkpoint.sourceRoot | Should -Be $TestDrive
        $checkpoint.attempt | Should -Be 5
    }

    It 'does not start a recheck after a lost CAS when the measured check no longer fits the original deadline' {
        # The observed incident: a slow passed check lost CAS and the recheck
        # inherited only the remainder, then was cut as a gate timeout.
        $result=Invoke-RegistrationDeadlineFixture -GateMilliseconds @(400)
        $result.failure | Should -BeLike "SOURCE_REGISTRATION_RACE_BUDGET: the develop queue moved during Targeted attempt 1*no recheck was started*repeat RegisterChange with the same QueueId 'bounded-race'*"
        $result.gateDeadlines.Count | Should -Be 1
        $result.casAttempts | Should -Be 1
        $result.elapsedMs | Should -Be 400
    }

    It 'never accepts a check that ends after the original deadline and keeps the exhausted continuation' {
        $result=Invoke-RegistrationDeadlineFixture -GateMilliseconds @(600)
        $result.failure | Should -BeLike "Registration exhausted its original * second budget.*repeat RegisterChange with the same QueueId 'bounded-race'*"
        $result.failure | Should -Not -BeLike '*SOURCE_REGISTRATION_RACE_BUDGET*'
        $result.gateDeadlines.Count | Should -Be 1
        $result.casAttempts | Should -Be 0
    }

    It 'reports a gate cut by the caller deadline separately from its own hard budget' {
        & {
            foreach ($definition in @(Get-DeliveryFunctionDefinitions -Names (@('Invoke-SourceGate','Get-DeliveryFailureClass') + $script:SourceGateSlotFunctions))) {
                Invoke-Expression $definition.Extent.Text
            }
            function Get-DeliveryCommonGitDirectory { return (Join-Path $TestDrive 'common git') }
            $script:Root=$TestDrive; $script:GateScript=Join-Path $TestDrive 'гейт с пробелами.ps1'
            [IO.File]::WriteAllText($script:GateScript, 'exit 0', [Text.UTF8Encoding]::new($false))
            $CoverageContract=@(); $AiRulesSource=''; $E2EProjectRoot=''
            $script:records=@(); $script:stops=0; $script:gateBudget=3600
            function Start-DeliveryProcess {
                param($ArgumentList,$WorkingDirectory,$StandardOutputPath,$StandardErrorPath)
                $fake=[pscustomobject]@{ Id=4242; StartTime=[DateTime]::Now; HasExited=$false; ExitCode=0 }
                $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) Start-Sleep -Milliseconds 20; return $false }
                return [pscustomobject]@{ process=$fake; jobHandle=[IntPtr]::Zero }
            }
            function Update-DeliveryOperation { param($Values) }
            function Get-SourceGateSupervisionBudgetSeconds { param($Mode,$WorkingRoot,$PlanBudgetSeconds,[switch]$InjectedGate); return $script:gateBudget }
            function Stop-DeliveryProcessTree { param($Process); $script:stops++ }
            function Close-DeliveryProcessJob { param($JobHandle,$Process,$PriorErrorMessage) }
            function Write-DeliveryRunRecord { param($Mode,$Status,$ErrorMessage,$WorkingRoot,$StartedAt,$FinishedAt,$ExitCode,$ReleaseCapability); $script:records+=[pscustomobject]@{ status=$Status; error=$ErrorMessage }; return 'fixture-record' }

            { Invoke-SourceGate -Mode Targeted -WorkingRoot $TestDrive -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(300)) } |
                Should -Throw '*SOURCE_GATE_OPERATION_DEADLINE: Targeted source gate was stopped after * seconds at its caller''s remaining operation budget; its own 3600 second budget was not exhausted*'
            $script:records[-1].status | Should -Be 'failed'
            $script:records[-1].error | Should -BeLike 'SOURCE_GATE_OPERATION_DEADLINE:*'
            Get-DeliveryFailureClass -Message $script:records[-1].error | Should -Be 'environment'
            $script:stops | Should -BeGreaterThan 0

            # Without a binding caller deadline the gate's own budget keeps
            # the original timeout contract.
            $script:gateBudget=0.3
            { Invoke-SourceGate -Mode Targeted -WorkingRoot $TestDrive -DeadlineUtc ([DateTime]::UtcNow.AddHours(1)) } |
                Should -Throw 'Targeted source gate exceeded its hard/no-progress budget.*'
            $script:records[-1].error | Should -Not -BeLike '*SOURCE_GATE_OPERATION_DEADLINE*'
            Get-DeliveryFailureClass -Message $script:records[-1].error | Should -Be 'environment'
        }
    }

    It 'extends the registration deadline by gate-slot admission and excludes the wait from the measured check' {
        # Each 400 ms gate call spent 300 ms waiting for a slot: the original
        # 550 ms budget alone would stop after the first call.
        $result=Invoke-RegistrationDeadlineFixture -GateMilliseconds @(400) -SlotWaitMilliseconds 300
        $result.failure | Should -BeLike "SOURCE_REGISTRATION_RACE_BUDGET: the develop queue moved during Targeted attempt 5*The previous check took 1 seconds*"
        $result.gateDeadlines.Count | Should -Be 5
        @($result.gateDeadlines | Select-Object -Unique) | Should -HaveCount 5
        $result.elapsedMs | Should -Be 2000
    }

    It 'admits a gate only after a killed slot holder exits and moves the caller deadline by the wait' {
        $previousSlots=$env:ITL_SOURCE_GATE_SLOTS; $state=@{ holder=$null }
        try {
            $env:ITL_SOURCE_GATE_SLOTS='1'
            & {
                foreach ($definition in @(Get-DeliveryFunctionDefinitions -Names (@('Invoke-SourceGate','Get-DeliveryFailureClass') + $script:SourceGateSlotFunctions))) {
                    Invoke-Expression $definition.Extent.Text
                }
                $commonGit=Join-Path $TestDrive 'общий git admit'
                function Get-DeliveryCommonGitDirectory { return $commonGit }
                $script:SourceGateSlotPollMilliseconds=100
                $script:Root=$TestDrive; $script:GateScript=Join-Path $TestDrive 'гейт с пробелами.ps1'
                [IO.File]::WriteAllText($script:GateScript, 'exit 0', [Text.UTF8Encoding]::new($false))
                $CoverageContract=@(); $AiRulesSource=''; $E2EProjectRoot=''
                $script:records=@(); $script:holderExitedAtStart=$null; $script:waitCalls=0
                function Start-DeliveryProcess {
                    param($ArgumentList,$WorkingDirectory,$StandardOutputPath,$StandardErrorPath)
                    $script:holderExitedAtStart=$state.holder.HasExited
                    $fake=[pscustomobject]@{ Id=4243; StartTime=[DateTime]::Now; HasExited=$false; ExitCode=0 }
                    # The gate itself runs for about 200 ms of its own budget.
                    $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) Start-Sleep -Milliseconds 20; $script:waitCalls++; return ($script:waitCalls -ge 10) }
                    $fake | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
                    return [pscustomobject]@{ process=$fake; jobHandle=[IntPtr]::Zero }
                }
                function Update-DeliveryOperation { param($Values) }
                function Get-SourceGateSupervisionBudgetSeconds { param($Mode,$WorkingRoot,$PlanBudgetSeconds,[switch]$InjectedGate); return 3600 }
                function Stop-DeliveryProcessTree { param($Process) }
                function Close-DeliveryProcessJob { param($JobHandle,$Process,$PriorErrorMessage) }
                function Write-DeliveryRunRecord { param($Mode,$Status,$ErrorMessage,$WorkingRoot,$StartedAt,$FinishedAt,$ExitCode,$ReleaseCapability); $script:records+=[pscustomobject]@{ status=$Status; error=$ErrorMessage }; return 'fixture-record' }

                $holder=Start-GateSlotHolder -CommonGit $commonGit -Mode 'Develop' -LifeMilliseconds 2500; $state.holder=$holder
                $status=Get-SourceGateSlotStatus
                $status.capacity | Should -Be 1
                @($status.holders).Count | Should -Be 1
                $status.holders[0].pid | Should -Be $holder.Id
                # Unshifted, this 1500 ms caller deadline would cut the gate.
                Invoke-SourceGate -Mode Targeted -WorkingRoot $TestDrive -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(1500))
                $script:holderExitedAtStart | Should -BeTrue
                $script:DeliveryLastGateSlotWaitSeconds | Should -BeGreaterOrEqual 1
                $script:records.Count | Should -Be 1
                $script:records[-1].status | Should -Be 'passed'
                # Released by the finished gate; nothing is reported as held.
                @((Get-SourceGateSlotStatus).holders).Count | Should -Be 0
            }
        } finally {
            if ($state.holder -and -not $state.holder.HasExited) { Stop-Process -Id $state.holder.Id -Force -ErrorAction SilentlyContinue }
            $env:ITL_SOURCE_GATE_SLOTS=$previousSlots
        }
    }

    It 'stops waiting at the slot limit with the live holders and an unspent continuation' {
        $previousSlots=$env:ITL_SOURCE_GATE_SLOTS; $previousWait=$env:ITL_SOURCE_GATE_SLOT_WAIT_SECONDS; $state=@{ holder=$null }
        try {
            $env:ITL_SOURCE_GATE_SLOTS='1'; $env:ITL_SOURCE_GATE_SLOT_WAIT_SECONDS='1'
            & {
                foreach ($definition in @(Get-DeliveryFunctionDefinitions -Names (@('Invoke-SourceGate') + $script:SourceGateSlotFunctions))) {
                    Invoke-Expression $definition.Extent.Text
                }
                $commonGit=Join-Path $TestDrive 'общий git limit'
                function Get-DeliveryCommonGitDirectory { return $commonGit }
                $script:SourceGateSlotPollMilliseconds=100
                $script:Root=$TestDrive; $script:GateScript=Join-Path $TestDrive 'гейт с пробелами.ps1'
                [IO.File]::WriteAllText($script:GateScript, 'exit 0', [Text.UTF8Encoding]::new($false))
                $CoverageContract=@(); $AiRulesSource=''; $E2EProjectRoot=''
                $script:started=0; $script:records=0
                function Start-DeliveryProcess { param($ArgumentList,$WorkingDirectory,$StandardOutputPath,$StandardErrorPath); $script:started++; throw 'must not start' }
                function Write-DeliveryRunRecord { param($Mode,$Status,$ErrorMessage,$WorkingRoot,$StartedAt,$FinishedAt,$ExitCode,$ReleaseCapability); $script:records++ }

                $holder=Start-GateSlotHolder -CommonGit $commonGit -Mode 'Develop' -LifeMilliseconds 60000; $state.holder=$holder
                { Invoke-SourceGate -Mode Targeted -WorkingRoot $TestDrive -DeadlineUtc ([DateTime]::UtcNow.AddHours(1)) } |
                    Should -Throw "SOURCE_GATE_SLOT_WAIT_TIMEOUT: Targeted waited *for one of 1 source gate slots*held by: Develop PID $($holder.Id) since *gate was not started*Repeat the same command*"
                $script:started | Should -Be 0
                $script:records | Should -Be 0

                # A holder killed without release frees the slot; its stale
                # record stays in the file but is not reported as live.
                Stop-Process -Id $holder.Id -Force; [void]$holder.WaitForExit(10000)
                (Get-Content -LiteralPath (Join-Path $commonGit 'itl\gate-slots\slot-0.lock') -Raw -Encoding UTF8) | Should -Match ('"pid":' + $holder.Id + ',')
                @((Get-SourceGateSlotStatus).holders).Count | Should -Be 0
                $slot=Enter-SourceGateSlot -Mode Targeted -WorkingRoot $TestDrive
                $slot.waitedSeconds | Should -BeLessThan 1
                @((Get-SourceGateSlotStatus).holders).Count | Should -Be 1
                Exit-SourceGateSlot -Slot $slot
            }
        } finally {
            if ($state.holder -and -not $state.holder.HasExited) { Stop-Process -Id $state.holder.Id -Force -ErrorAction SilentlyContinue }
            $env:ITL_SOURCE_GATE_SLOTS=$previousSlots; $env:ITL_SOURCE_GATE_SLOT_WAIT_SECONDS=$previousWait
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
Describe 'Source delivery fixture removal' {
    It 'removes the registration, supervisor and candidate worktrees a delivery fixture created in the system temp' {
        $fixture = New-DeliveryFixture
        $temp = [IO.Path]::GetTempPath()
        $ids = @{}; foreach ($name in @('register', 'publish-develop', 'supervisor')) { $ids[$name] = [guid]::NewGuid().ToString('N') }
        $paths = @{}; foreach ($name in $ids.Keys) { $paths[$name] = Join-Path $temp "itl-source-$name-$($ids[$name])" }
        try {
            & git -C $fixture.root worktree add --quiet -b "itl/register-$($ids.register)" $paths.register *> $null
            & git -C $fixture.root worktree add --quiet -b "itl/publish-develop-$($ids['publish-develop'])" $paths['publish-develop'] *> $null
            & git -C $fixture.root worktree add --quiet --detach $paths.supervisor *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $paths['publish-develop'] 'build\test-results') | Out-Null
            foreach ($path in $paths.Values) { Test-Path -LiteralPath $path | Should -BeTrue -Because $path }
        } finally {
            Remove-DeliveryFixture -Fixture $fixture
        }
        foreach ($path in @($paths.Values) + @($fixture.root, $fixture.remote)) { Test-Path -LiteralPath $path | Should -BeFalse -Because $path }
    }
}
