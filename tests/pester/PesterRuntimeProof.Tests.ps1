BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $RepoRoot 'scripts/invoke-pester-runtime.ps1')
    . (Join-Path $PSScriptRoot 'PesterRuntimeSupport.ps1')
    function New-RuntimeModuleCopy([string]$Name) {
        $module = Get-Module Pester | Select-Object -First 1
        $moduleVersion = Join-Path $TestDrive ("$Name Modules Проект/Pester/" + [string]$module.Version)
        New-Item -ItemType Directory -Force -Path $moduleVersion | Out-Null
        Copy-Item -Path (Join-Path $module.ModuleBase '*') -Destination $moduleVersion -Recurse
        return $moduleVersion
    }
}

Describe 'Actual Pester worker runtime qualification' {

    It 'previews cold, warm, changed and corrupt proof through the actual cache reader without running or promoting tests' {
        $root=New-RuntimeProofFixture 'read-only plan'
        $runner=Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        function Read-ActualPreview([string]$Name) {
            $out=Join-Path $root $Name
            $run=Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$out,'-JunitPath',(Join-Path $out 'never.xml'),'-WorkerCount','1','-PlanOnly')
            $run.exitCode | Should -Be 0 -Because $run.combinedText
            Test-Path (Join-Path $out 'never.xml') | Should -BeFalse
            return (($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json)
        }
        $cold=Read-ActualPreview 'out-plan-cold'
        $cold.executedCount | Should -Be 1
        Test-Path (Join-Path $root counter.txt) | Should -BeFalse
        $first=Invoke-RuntimeProofFixture $root out-first
        $first.executedWorkerCount | Should -Be 1
        $cache=Join-Path $root ('.git/itl/pester-shards/v1/'+$first.workers[0].inputDigest)
        $before=@(Get-ChildItem $cache -File | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ','
        $warm=Read-ActualPreview 'out-plan-warm'
        $warm.reusedCount | Should -Be 1
        $warm.files[0].estimatedSeconds | Should -Be 0
        (@(Get-ChildItem $cache -File | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ',') | Should -BeExactly $before
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 1
        Add-Content -LiteralPath (Join-Path $cache result.json) -Value 'altered proof'
        $bad=Read-ActualPreview 'out-plan-corrupt'
        $bad.executedCount | Should -Be 1
        $bad.files[0].reason | Should -Match 'no valid passed proof'
        $out=Join-Path $root out-corrupt
        $refused=Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$out,'-JunitPath',(Join-Path $out 'pester.xml'),'-WorkerCount','1')
        $refused.exitCode | Should -Not -Be 0
        $refused.combinedText | Should -Match 'Incomplete Pester shard cache'
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 2
        Add-Content -LiteralPath (Join-Path $root tests/pester/Runtime.Tests.ps1) -Value '# owner changed'
        $changed=Read-ActualPreview 'out-plan-changed'
        $changed.executedCount | Should -Be 1
        $actual=Invoke-RuntimeProofFixture $root out-changed
        $actual.executedWorkerCount | Should -Be $changed.executedCount
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 3
    }

    It 'qualifies the Desktop child of a Core parent and reuses exact proof across worktrees' -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $root = New-RuntimeProofFixture 'Core parent'
        $core = (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source
        $first = Invoke-RuntimeProofFixture $root 'out-first' -Core $core
        $first.executedWorkerCount | Should -Be 1
        $first.runtimeIdentityStatus | Should -Be 'known'
        $identity = $first.runtimeIdentity
        $identity.powerShellEdition | Should -Be 'Desktop'
        $identity.powerShellVersion | Should -BeLike '5.1.*'
        $identity.executablePath | Should -Be ((Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source)
        $identity.executableSha256 | Should -Be (Get-PesterShardFileSha256 $identity.executablePath)
        $identity.engineSha256 | Should -Be (Get-PesterShardFileSha256 $identity.enginePath)
        $first.workers[0].runtimeIdentity.identitySha256 | Should -BeExactly $identity.identitySha256
        $other = Join-Path $TestDrive 'Другая рабочая копия'
        & git -C $root worktree add -q -b other $other
        $LASTEXITCODE | Should -Be 0
        $second = Invoke-RuntimeProofFixture $other 'out-warm'
        $second.executedWorkerCount | Should -Be 0
        $second.reusedWorkerCount | Should -Be 1
        $second.runtimeIdentity.identitySha256 | Should -BeExactly $identity.identitySha256
        @(& git -C $root status --porcelain -z).Count | Should -Be 0
        @(& git -C $other status --porcelain -z).Count | Should -Be 0
    }


    It 'finds legacy Desktop scheduler proof from a Core parent without executing another test' -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $root=New-RuntimeProofFixture 'legacy parent shell'
        $text=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'))
        $text=$text.Replace('$lines.Add($runtimeIdentity)','$lines.Add("powershell=$($PSVersionTable.PSVersion)|pester=$($runtime.pesterVersion)|workers=$WorkerCount")')
        $text=$text.Replace('$PSScriptRoot',("'"+(Join-Path $RepoRoot scripts).Replace("'","''")+"'"))
        $legacy=Join-Path $TestDrive legacy-runner.ps1
        [IO.File]::WriteAllText($legacy,$text,[Text.UTF8Encoding]::new($true))
        $first=Invoke-RuntimeProofFixture $root out-legacy -Runner $legacy
        $first.executedWorkerCount | Should -Be 1
        $core=(Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source
        $second=Invoke-RuntimeProofFixture $root out-modern -Core $core
        $second.executedWorkerCount | Should -Be 0
        $second.reusedWorkerCount | Should -Be 1
        $second.workers[0].reuseReason | Should -Match 'legacy'
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 1
    }

    It 'executes and then reuses a cache miss at the raised worker ceiling' {
        # Targeted resolves the catalog default 8; the legacy lookup must not
        # reject a count that the former 1..4 ceiling never recorded.
        $root = New-RuntimeProofFixture 'Eight workers'
        $first = Invoke-RuntimeProofFixture $root 'out-first' -WorkerCount 8
        $warm = Invoke-RuntimeProofFixture $root 'out-warm' -WorkerCount 8
        @($first,$warm | ForEach-Object { $_.passed }) | Should -Be @(1,1)
        @($first,$warm | ForEach-Object { $_.executedWorkerCount }) | Should -Be @(1,0)
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 1
    }

    It 'invalidates proof when actual Pester module bytes change at the same path and version' {
        $root = New-RuntimeProofFixture 'Module replacement'
        $moduleVersion = New-RuntimeModuleCopy 'Replacement'
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $moduleVersion)
        $previous = $env:PSModulePath
        try {
            $userModuleRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) 'WindowsPowerShell/Modules'
            $env:PSModulePath = @($moduleRoot, $userModuleRoot, $previous) -join ';'
            $first = Invoke-RuntimeProofFixture $root 'out-first'
            $warm = Invoke-RuntimeProofFixture $root 'out-warm'
            Add-Content -LiteralPath (Join-Path $moduleVersion 'Pester.psm1') -Encoding UTF8 -Value "`n# Runtime qualification regression: same version, changed executable input."
            $changed = Invoke-RuntimeProofFixture $root 'out-changed'
            $rewarm = Invoke-RuntimeProofFixture $root 'out-rewarm'
        } finally { $env:PSModulePath = $previous }
        $first.runtimeIdentity.pesterManifestPath | Should -Be (Join-Path $moduleVersion 'Pester.psd1')
        $changed.runtimeIdentity.pesterVersion | Should -Be $first.runtimeIdentity.pesterVersion
        $changed.runtimeIdentity.pesterManifestPath | Should -Be $first.runtimeIdentity.pesterManifestPath
        $changed.runtimeIdentity.identitySha256 | Should -Not -Be $first.runtimeIdentity.identitySha256
        @($first,$warm,$changed,$rewarm | ForEach-Object { $_.executedWorkerCount }) | Should -Be @(1,0,1,0)
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
    }

    It 'retains a passed task but refuses reusable proof when its runtime changes during execution' {
        $root = New-RuntimeProofFixture 'In-flight replacement'
        $moduleVersion = New-RuntimeModuleCopy 'In-flight'
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $moduleVersion)
        $testPath = Join-Path $root 'tests/pester/Runtime.Tests.ps1'
        $body = [IO.File]::ReadAllText($testPath).Replace("`$true | Should -BeTrue", "Add-Content -LiteralPath (Join-Path (Get-Module Pester).ModuleBase 'Pester.psm1') -Value '# changed during execution'; `$true | Should -BeTrue")
        [IO.File]::WriteAllText($testPath, $body, [Text.UTF8Encoding]::new($true))
        $previous = $env:PSModulePath
        try {
            $userModuleRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) 'WindowsPowerShell/Modules'
            $env:PSModulePath = @($moduleRoot, $userModuleRoot, $previous) -join ';'
            $first = Invoke-RuntimeProofFixture $root 'out-first'
            $second = Invoke-RuntimeProofFixture $root 'out-second'
        } finally { $env:PSModulePath = $previous }
        foreach ($summary in @($first, $second)) {
            $summary.runtimeIdentityStatus | Should -Be 'known'
            $summary.runtimeIdentity.pesterManifestPath | Should -Be (Join-Path $moduleVersion 'Pester.psd1')
            $summary.executedWorkerCount | Should -Be 1
            $summary.reusedWorkerCount | Should -Be 0
            $summary.workers[0].passed | Should -Be 1
            $summary.workers[0].runtimeIdentity | Should -BeNullOrEmpty
            $summary.workers[0].inputDigest | Should -BeNullOrEmpty
            $summary.workers[0].runtimeIdentityReason | Should -Match 'changed during execution'
        }
        @(Get-ChildItem -LiteralPath (Join-Path $root '.git/itl/pester-shards/v1') -Force).Count | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
    }

    It 'preserves integrity-valid <Kind> proof without treating it as current runtime qualification' -ForEach @(
        @{Kind='missing runtime identity'}, @{Kind='different runtime identity'}
    ) {
        $root = New-RuntimeProofFixture $Kind
        $first = Invoke-RuntimeProofFixture $root 'out-first'
        $first.executedWorkerCount | Should -Be 1
        $entry = Join-Path $root ('.git/itl/pester-shards/v1/' + $first.workers[0].inputDigest)
        $resultPath = Join-Path $entry 'result.json'
        $proof = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Kind -eq 'missing runtime identity') { $proof.PSObject.Properties.Remove('runtimeIdentity') }
        else { $proof.runtimeIdentity.identitySha256 = 'f' * 64 }
        [IO.File]::WriteAllText($resultPath, ($proof | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $entry 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.resultSha256 = Get-PesterShardFileSha256 $resultPath
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $preservedSha = Get-PesterShardFileSha256 $resultPath
        $second = Invoke-RuntimeProofFixture $root 'out-second'
        $third = Invoke-RuntimeProofFixture $root 'out-third'
        $second.executedWorkerCount | Should -Be 1
        $third.reusedWorkerCount | Should -Be 1
        (Get-PesterShardFileSha256 $resultPath) | Should -Be $preservedSha
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
    }

    It 'executes the original task without reuse when runtime observation is unavailable' {
        $root = New-RuntimeProofFixture 'Unknown identity'
        $runner = New-UnknownRuntimeRunner
        $first = Invoke-RuntimeProofFixture $root 'out-first' $runner
        $second = Invoke-RuntimeProofFixture $root 'out-second' $runner
        foreach ($summary in @($first, $second)) {
            $summary.runtimeIdentityStatus | Should -Be 'unknown'
            $summary.runtimeIdentityReason | Should -Be 'fixture observation unavailable'
            $summary.executedWorkerCount | Should -Be 1
            $summary.reusedWorkerCount | Should -Be 0
            $summary.workers[0].passed | Should -Be 1
            $summary.workers[0].inputDigest | Should -BeNullOrEmpty
        }
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath (Join-Path $root '.git/itl/pester-shards/v1') -Force).Count | Should -Be 0
    }

}

Describe 'External Pester runtime reuse through the original worker' {
    BeforeEach {
        $script:savedExternalRoot=$env:ITL_PESTER_RUNTIME_TEST_ROOT
        $env:ITL_PESTER_RUNTIME_TEST_ROOT=Join-Path $TestDrive ('Runtime внешний '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($env:ITL_PESTER_RUNTIME_TEST_ROOT)
        [IO.File]::WriteAllText((Join-Path $env:ITL_PESTER_RUNTIME_TEST_ROOT 'engine.dll'),'original engine bytes')
    }
    AfterEach {$env:ITL_PESTER_RUNTIME_TEST_ROOT=$script:savedExternalRoot}
    It 'reuses exact external bytes, rejects replacement at the same path and keeps preview read-only' {
        $root=New-RuntimeProofFixture 'External bytes'
        $catalogPath=Join-Path $root 'tests/quality-contracts.json'
        $c=Get-Content $catalogPath -Raw|ConvertFrom-Json
        $c|Add-Member pesterExternalRuntimeProfiles ([pscustomobject]@{fixture=[pscustomobject]@{kind='directory';environmentVariable='ITL_PESTER_RUNTIME_TEST_ROOT'}})
        $c|Add-Member pesterExternalRuntimeTests ([pscustomobject]@{'tests/pester/Runtime.Tests.ps1'=@('fixture')})
        [IO.File]::WriteAllText($catalogPath,($c|ConvertTo-Json -Depth 8))
        & git -C $root add --all; & git -C $root commit -qm 'external runtime contract'
        $first=Invoke-RuntimeProofFixture $root out-first
        $warm=Invoke-RuntimeProofFixture $root out-warm
        $first.executedWorkerCount | Should -Be 1
        $warm.reusedWorkerCount | Should -Be 1
        [IO.File]::WriteAllText((Join-Path $env:ITL_PESTER_RUNTIME_TEST_ROOT 'engine.dll'),'replacement at the same version and path')
        $changed=Invoke-RuntimeProofFixture $root out-changed
        $changed.executedWorkerCount | Should -Be 1
        $rewarm=Invoke-RuntimeProofFixture $root out-rewarm
        $rewarm.reusedWorkerCount | Should -Be 1
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 2
        $previewRoot=Join-Path $root out-preview
        $run=Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$previewRoot,'-JunitPath',(Join-Path $previewRoot 'pester.xml'),'-PlanOnly')
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $preview=($run.stdout -join [Environment]::NewLine)|ConvertFrom-Json
        $preview.reusedCount | Should -Be 1
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 2
        Test-Path (Join-Path $previewRoot 'pester.xml') | Should -BeFalse
        $other=Join-Path $TestDrive 'Reuse другой worktree'
        try {
            & git -C $root worktree add --quiet --detach $other HEAD
            $cross=Invoke-RuntimeProofFixture $other out-cross
            $cross.reusedWorkerCount | Should -Be 1
            Test-Path (Join-Path $other counter.txt) | Should -BeFalse
        } finally {& git -C $root worktree remove --force $other}
        $cache=Join-Path $root ('.git/itl/pester-shards/v1/'+$rewarm.workers[0].inputDigest)
        $recordPath=Join-Path $cache 'result.json';$manifestPath=Join-Path $cache 'manifest.json'
        $record=Get-Content $recordPath -Raw|ConvertFrom-Json
        $record.PSObject.Properties.Remove('externalRuntimeIdentity')
        [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json
        $manifest.resultSha256=(Get-FileHash $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $withoutWitness=Invoke-RuntimeProofFixture $root out-without-witness
        $withoutWitness.executedWorkerCount | Should -Be 1 -Because 'integrity-valid legacy proof without an external witness is insufficient'
        [IO.Directory]::Delete($env:ITL_PESTER_RUNTIME_TEST_ROOT,$true)
        foreach($name in @('out-unknown-a','out-unknown-b')){
            $unknown=Invoke-RuntimeProofFixture $root $name
            $unknown.executedWorkerCount | Should -Be 1
            $unknown.workers[0].inputDigest | Should -BeNullOrEmpty
            $unknown.workers[0].repeatReason | Should -Match 'fixture.*unavailable'
        }
        $c.PSObject.Properties.Remove('pesterExternalRuntimeProfiles')
        [IO.File]::WriteAllText($catalogPath,($c|ConvertTo-Json -Depth 8))
        $undefined=Invoke-RuntimeProofFixture $root out-undefined-profile
        $undefined.executedWorkerCount | Should -Be 1
        $undefined.workers[0].inputDigest | Should -BeNullOrEmpty
        $undefined.workers[0].repeatReason | Should -Match 'identity unavailable'
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 6
    }
    It 'does not qualify passed tests when the external input changes during execution' {
        $root=New-RuntimeProofFixture 'External drift'
        $catalogPath=Join-Path $root 'tests/quality-contracts.json'
        $c=Get-Content $catalogPath -Raw|ConvertFrom-Json
        $c|Add-Member pesterExternalRuntimeProfiles ([pscustomobject]@{fixture=[pscustomobject]@{kind='directory';environmentVariable='ITL_PESTER_RUNTIME_TEST_ROOT'}})
        $c|Add-Member pesterExternalRuntimeTests ([pscustomobject]@{'tests/pester/Runtime.Tests.ps1'=@('fixture')})
        [IO.File]::WriteAllText($catalogPath,($c|ConvertTo-Json -Depth 8))
        $test=Join-Path $root 'tests/pester/Runtime.Tests.ps1'
        [IO.File]::AppendAllText($test,"`nAfterAll { Add-Content -LiteralPath (Join-Path `$env:ITL_PESTER_RUNTIME_TEST_ROOT 'engine.dll') -Value 'changed during execution' }")
        & git -C $root add --all; & git -C $root commit -qm 'runtime drift reproducer'
        $a=Invoke-RuntimeProofFixture $root out-first
        $b=Invoke-RuntimeProofFixture $root out-second
        $a.executedWorkerCount | Should -Be 1
        $b.executedWorkerCount | Should -Be 1
        $a.workers[0].passed | Should -Be 1
        $a.workers[0].inputDigest | Should -BeNullOrEmpty
        @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 2
    }
}

Describe 'External Pester runtime bounded observation' {
    BeforeAll {. (Join-Path $RepoRoot 'scripts/pester-external-runtime.ps1')}
    It 'preserves completed profile reuse when another native observer exceeds its deadline' {
        $saved=$env:ITL_PESTER_RUNTIME_TEST_ROOT
        try {
            $root=New-RuntimeProofFixture 'Bounded external probe'
            $env:ITL_PESTER_RUNTIME_TEST_ROOT=Join-Path $root 'external runtime Внешний'
            [void][IO.Directory]::CreateDirectory($env:ITL_PESTER_RUNTIME_TEST_ROOT)
            [IO.File]::WriteAllText((Join-Path $env:ITL_PESTER_RUNTIME_TEST_ROOT 'engine.dll'),'engine bytes')
            Copy-Item (Join-Path $root 'tests/pester/Runtime.Tests.ps1') (Join-Path $root 'tests/pester/Slow.Tests.ps1')
            $catalogPath=Join-Path $root 'tests/quality-contracts.json'
            $c=Get-Content $catalogPath -Raw|ConvertFrom-Json
            $c.contracts[0].tests=@('tests/pester/Runtime.Tests.ps1','tests/pester/Slow.Tests.ps1')
            $definition=[pscustomobject]@{kind='directory';environmentVariable='ITL_PESTER_RUNTIME_TEST_ROOT'}
            $c|Add-Member pesterExternalRuntimeProfiles ([pscustomobject]@{'fixture-fast'=$definition;'fixture-slow'=$definition})
            $c|Add-Member pesterExternalRuntimeTests ([pscustomobject]@{'tests/pester/Runtime.Tests.ps1'=@('fixture-fast');'tests/pester/Slow.Tests.ps1'=@('fixture-slow')})
            [IO.File]::WriteAllText($catalogPath,($c|ConvertTo-Json -Depth 8))
            & git -C $root add --all; & git -C $root commit -qm 'two independent external profiles'
            $cold=Invoke-RuntimeProofFixture $root out-cold
            $cold.executedWorkerCount | Should -Be 2
            $scripts=(Join-Path $RepoRoot 'scripts').Replace("'","''")
            $probe=Join-Path $TestDrive 'partial native observer Проект.ps1'
            $body=@'
param([string]$ProfilePath,[string]$ResultPath,[switch]$RuntimeIdentityOnly)
. 'SCRIPTS/git-path-list.ps1'
. 'SCRIPTS/invoke-pester-runtime.ps1'
. 'SCRIPTS/pester-external-runtime.ps1'
$spec=Get-Content $ProfilePath -Raw|ConvertFrom-Json
$receipt=Get-PesterExternalRuntimeReceipt $spec.repositoryRoot ([pscustomobject]@{'fixture-fast'=$spec.profiles.'fixture-fast'})
$receipt|Add-Member 'fixture-slow' ([pscustomobject]@{status='unknown';sha256='';reason='Observation did not complete within the bounded runtime probe.'})
Write-PesterExternalRuntimeReceipt $ResultPath $receipt
Start-Sleep -Seconds 20
'@
            [IO.File]::WriteAllText($probe,$body.Replace('SCRIPTS',$scripts),[Text.UTF8Encoding]::new($true))
            $runner=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'))
            $runner=$runner.Replace('(Join-Path $PSScriptRoot ''run-pester-external-shard.ps1'')',("'"+$probe.Replace("'","''")+"'"))
            $runner=$runner.Replace('$PSScriptRoot',("'"+$scripts+"'"))
            $runner=$runner.Replace('if(-not $process.WaitForExit(60000))','if(-not $process.WaitForExit(5000))')
            $runnerPath=Join-Path $TestDrive partial-observer-runner.ps1
            [IO.File]::WriteAllText($runnerPath,$runner,[Text.UTF8Encoding]::new($true))
            $out=Join-Path $root out-preview
            $run=Invoke-TestPowerShellFile -FilePath $runnerPath -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$out,'-JunitPath',(Join-Path $out 'never.xml'),'-PlanOnly')
            $run.exitCode | Should -Be 0 -Because $run.combinedText
            $preview=($run.stdout -join [Environment]::NewLine)|ConvertFrom-Json
            $preview.reusedCount | Should -Be 1
            $preview.executedCount | Should -Be 1
            ($preview.files|Where-Object path -Like '*Slow.Tests.ps1').reason | Should -Match 'bounded runtime probe'
            @(Get-Content (Join-Path $root counter.txt)).Count | Should -Be 2
            Test-Path (Join-Path $out never.xml) | Should -BeFalse
        } finally {$env:ITL_PESTER_RUNTIME_TEST_ROOT=$saved}
    }
}

Describe 'External Pester runtime component environment closure' {
    BeforeAll {. (Join-Path $RepoRoot 'scripts/pester-external-runtime.ps1')}
    It 'rejects an absent venv and binds DLLs, configuration and site packages only for the selected component' {
        $root=Join-Path $TestDrive 'Component runtime Проект'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'build/host-test-runtime'))
        function Read-ComponentWitness {
            $lines=[Collections.Generic.List[string]]::new()
            Add-PesterExternalComponentEnvironment $root Native $lines
            Get-PesterExternalSha $lines.ToArray()
        }
        {Read-ComponentWitness} | Should -Throw '*not prepared*'
        $generation=Join-Path $root ('build/host-test-runtime/native-'+('a'*20))
        [void][IO.Directory]::CreateDirectory((Join-Path $generation 'Lib/site-packages'))
        [IO.File]::WriteAllText((Join-Path $generation 'python.dll'),'original DLL')
        [IO.File]::WriteAllText((Join-Path $generation 'pyvenv.cfg'),"include-system-site-packages = false`nversion = original")
        $initial=Read-ComponentWitness
        (Read-ComponentWitness) | Should -Be $initial
        $foreign=Join-Path $root ('build/host-test-runtime/mantis-'+('b'*20))
        [void][IO.Directory]::CreateDirectory($foreign)
        [IO.File]::WriteAllText((Join-Path $foreign 'python.dll'),'unrelated component')
        (Read-ComponentWitness) | Should -Be $initial
        [IO.File]::WriteAllText((Join-Path $generation 'python.dll'),'replacement at the same path and version')
        $changed=Read-ComponentWitness
        $changed | Should -Not -Be $initial
        [IO.File]::WriteAllText((Join-Path $generation 'pyvenv.cfg'),"include-system-site-packages = false`nversion = changed")
        $config=Read-ComponentWitness
        $config | Should -Not -Be $changed
        [IO.File]::WriteAllText((Join-Path $generation 'Lib/site-packages/injected.pth'),'external startup plugin')
        {Read-ComponentWitness} | Should -Throw '*custom startup/search paths*'
        [IO.File]::Delete((Join-Path $generation 'Lib/site-packages/injected.pth'))
        [IO.File]::WriteAllText((Join-Path $generation 'pyvenv.cfg'),'include-system-site-packages = true')
        {Read-ComponentWitness} | Should -Throw '*system-site isolation*'
    }
}

Describe 'External Pester runtime custom configuration' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/pester-external-runtime.ps1')
    }
    BeforeEach {
        # Agent hosts often export GIT_* prompt/editor overrides. Each case
        # models its own overrides and must not inherit the caller's.
        $script:hostGitEnvironment=@(Get-ChildItem Env: | Where-Object {$_.Name -match '^GIT_'} | ForEach-Object {[pscustomobject]@{Name=$_.Name;Value=$_.Value}})
        foreach($entry in $script:hostGitEnvironment){[Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')}
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object {$_.Name -match '^GIT_'} | ForEach-Object {[Environment]::SetEnvironmentVariable($_.Name,$null,'Process')}
        foreach($entry in $script:hostGitEnvironment){[Environment]::SetEnvironmentVariable($entry.Name,$entry.Value,'Process')}
    }
    It 'reuses real Git proof across equal worktree configuration and rejects a changed setting' {
        $root=New-RuntimeProofFixture 'Real Git profile'
        $other=Join-Path $TestDrive 'Real Git другой worktree'
        $catalogPath=Join-Path $root 'tests/quality-contracts.json'
        $c=Get-Content $catalogPath -Raw|ConvertFrom-Json
        $c|Add-Member pesterExternalRuntimeProfiles ([pscustomobject]@{git=[pscustomobject]@{kind='git'}})
        $c|Add-Member pesterExternalRuntimeTests ([pscustomobject]@{'tests/pester/Runtime.Tests.ps1'=@('git')})
        [IO.File]::WriteAllText($catalogPath,($c|ConvertTo-Json -Depth 8))
        & git -C $root add --all; & git -C $root commit -qm 'real Git qualification'
        & git -C $root config extensions.worktreeConfig true
        & git -C $root config --worktree core.abbrev 12
        try {
            & git -C $root worktree add --quiet --detach $other HEAD
            & git -C $other config --worktree core.abbrev 12
            $cold=Invoke-RuntimeProofFixture $root out-first
            $cold.executedWorkerCount | Should -Be 1
            $cross=Invoke-RuntimeProofFixture $other out-equal
            $cross.reusedWorkerCount | Should -Be 1
            Test-Path (Join-Path $other counter.txt) | Should -BeFalse
            & git -C $other config --worktree core.abbrev 13
            $changed=Invoke-RuntimeProofFixture $other out-changed
            $changed.executedWorkerCount | Should -Be 1
            $rewarm=Invoke-RuntimeProofFixture $other out-rewarm
            $rewarm.reusedWorkerCount | Should -Be 1
            @(Get-Content (Join-Path $other counter.txt)).Count | Should -Be 1
        } finally {& git -C $root worktree remove --force $other}
    }
    It 'qualifies the noninteractive cat pager without splitting the default Git identity' {
        $saved=$env:GIT_PAGER
        try {
            $profiles=[pscustomobject]@{git=[pscustomobject]@{kind='git'}}
            $env:GIT_PAGER=$null
            $plain=Get-PesterExternalRuntimeReceipt $RepoRoot $profiles
            $env:GIT_PAGER='cat'
            $hostPager=Get-PesterExternalRuntimeReceipt $RepoRoot $profiles
            $plain.git.status | Should -BeExactly known
            $hostPager.git.status | Should -BeExactly known
            $hostPager.git.sha256 | Should -BeExactly $plain.git.sha256
        } finally {$env:GIT_PAGER=$saved}
    }
    It 'does not qualify external hooks referenced by Git configuration' {
        $root=New-RuntimeProofFixture 'External Git hooks'
        & git -C $root config core.hooksPath (Join-Path $TestDrive 'external hooks Внешний')
        $LASTEXITCODE | Should -Be 0
        $receipt=Get-PesterExternalRuntimeReceipt $root ([pscustomobject]@{git=[pscustomobject]@{kind='git'}})
        $receipt.git.status | Should -BeExactly unknown
        $receipt.git.reason | Should -Match 'external hooks/attribute/template'
    }
    It 'does not qualify an unobserved Git process override' {
        $saved=$env:GIT_TEMPLATE_DIR
        try {
            $env:GIT_TEMPLATE_DIR=Join-Path $TestDrive 'external template Внешний'
            $receipt=Get-PesterExternalRuntimeReceipt $RepoRoot ([pscustomobject]@{git=[pscustomobject]@{kind='git'}})
            $receipt.git.status | Should -BeExactly unknown
            $receipt.git.reason | Should -Match 'process overrides'
        } finally {$env:GIT_TEMPLATE_DIR=$saved}
    }
}

Describe 'External Pester runtime command resolution' {
    BeforeAll {. (Join-Path $RepoRoot 'scripts/pester-external-runtime.ps1')}
    It 'does not qualify a later exe when the original command selects an earlier <Extension> wrapper' -ForEach @(@{Extension='cmd'},@{Extension='ps1'}) {
        $oldPath=$env:PATH
        $root=Join-Path $TestDrive 'Command resolution Проект'
        $first=Join-Path $root wrapper;$later=Join-Path $root executable
        [void][IO.Directory]::CreateDirectory($first);[void][IO.Directory]::CreateDirectory($later)
        [IO.File]::WriteAllText((Join-Path $first ('itl-runtime-proof.'+$Extension)),'exit 0')
        [IO.File]::WriteAllText((Join-Path $later 'itl-runtime-proof.exe'),'later exe bytes')
        try {
            $env:PATH=$first+[IO.Path]::PathSeparator+$later
            {Get-PesterExternalExecutable itl-runtime-proof} | Should -Throw '*external wrapper*'
            $env:PATH=$later
            (Get-PesterExternalExecutable itl-runtime-proof) | Should -BeExactly (Join-Path $later 'itl-runtime-proof.exe')
        } finally {$env:PATH=$oldPath}
    }
    It 'binds PowerShell Core bytes and leaves a host without pwsh unqualified' {
        $oldPath=$env:PATH
        $core=Join-Path $TestDrive 'PowerShell Core Проект'
        [void][IO.Directory]::CreateDirectory($core)
        [IO.File]::WriteAllText((Join-Path $core 'pwsh.exe'),'core host bytes')
        [IO.File]::WriteAllText((Join-Path $core 'System.Management.Automation.dll'),'original engine')
        $profiles=[pscustomobject]@{'powershell-core'=[pscustomobject]@{kind='powershell-core'}}
        try {
            $env:PATH=$core
            $initial=Get-PesterExternalRuntimeReceipt $RepoRoot $profiles
            $initial.'powershell-core'.status | Should -BeExactly known
            (Get-PesterExternalRuntimeReceipt $RepoRoot $profiles).'powershell-core'.sha256 | Should -BeExactly $initial.'powershell-core'.sha256
            [IO.File]::WriteAllText((Join-Path $core 'System.Management.Automation.dll'),'replacement at the same path')
            $changed=Get-PesterExternalRuntimeReceipt $RepoRoot $profiles
            $changed.'powershell-core'.status | Should -BeExactly known
            $changed.'powershell-core'.sha256 | Should -Not -Be $initial.'powershell-core'.sha256
            $env:PATH=Join-Path $TestDrive 'no core host'
            $absent=Get-PesterExternalRuntimeReceipt $RepoRoot $profiles
            $absent.'powershell-core'.status | Should -BeExactly unknown
            $absent.'powershell-core'.sha256 | Should -BeNullOrEmpty
        } finally {$env:PATH=$oldPath}
    }
}
