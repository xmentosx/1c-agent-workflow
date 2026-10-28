BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $PSScriptRoot 'PesterRuntimeSupport.ps1')
    function Set-PreflightFixtureBody([string]$Root, [switch]$Fail) {
        $body = if ($Fail) { "throw 'original preflight failure'" } else { "Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt') -Value 'short-passed'" }
        $text = "Describe 'short owner' { It 'qualifies original short task' { Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt') -Value 'short-start'; Start-Sleep -Milliseconds 300; $body } }"
        [IO.File]::WriteAllText((Join-Path $Root 'tests/pester/SourceDeliveryAdmission.Tests.ps1'), $text, [Text.UTF8Encoding]::new($true))
    }
    function New-PreflightFixture([string]$Name, [switch]$Fail) {
        $root = New-RuntimeProofFixture $Name
        Set-PreflightFixtureBody $root -Fail:$Fail
        New-Item -ItemType Directory -Path (Join-Path $root '.native-trace') | Out-Null
        Add-Content -LiteralPath (Join-Path $root '.gitignore') -Value '.native-trace/'
        foreach ($file in @('Runtime.Tests.ps1','Expensive.Tests.ps1')) {
            $body = "Describe 'native task $file' { It 'runs after short owner' { @(Get-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt')) | Should -Contain 'short-passed'; Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../.native-trace/$file') -Value 'executed' } }"
            [IO.File]::WriteAllText((Join-Path $root ('tests/pester/'+$file)), $body, [Text.UTF8Encoding]::new($true))
        }
        $catalog = @{schemaVersion=1;contracts=@(@{id='runtime-fixture';owner='fixture';gate='targeted';budgetSeconds=30;primaryTest='tests/pester/SourceDeliveryAdmission.Tests.ps1';paths=@('scripts/*');tests=@('tests/pester/SourceDeliveryAdmission.Tests.ps1','tests/pester/Runtime.Tests.ps1','tests/pester/Expensive.Tests.ps1')})}
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -qm 'fixture: independent tasks behind short admission'
        $LASTEXITCODE | Should -Be 0
        return $root
    }
    function Invoke-PreflightFixture([string]$Root,[string]$OutputName,[switch]$ExpectFailure) {
        $output = Join-Path $Root $OutputName
        $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$Root,'-OutputRoot',$output,'-JunitPath',(Join-Path $output 'pester.xml'),'-WorkerCount','2')
        if ($ExpectFailure) { $run.exitCode | Should -Not -Be 0 -Because $run.combinedText }
        else { $run.exitCode | Should -Be 0 -Because $run.combinedText }
        return (Get-Content -LiteralPath (Join-Path $output 'pester-shards/summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
}

Describe 'Native short owner admission before expensive Pester files' {
    It 'admits private manifest fixtures alongside another native worker and reuses both proofs' {
        $root=New-RuntimeProofFixture 'Parallel manifest копия'
        foreach($name in @('Runtime','DevelopManifestContinuation')) {
            $other=if($name -eq 'Runtime') {'DevelopManifestContinuation'}else{'Runtime'}
            $body=@"
Describe 'private $name fixture' { It 'overlaps its independent peer' {
    `$root=Join-Path `$PSScriptRoot '../..'
    [IO.File]::WriteAllText((Join-Path `$root '$name.ready'),'ready')
    `$deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not [IO.File]::Exists((Join-Path `$root '$other.ready'))) {
        if([DateTime]::UtcNow -gt `$deadline){throw 'Independent peer was blocked by serial admission.'}
        Start-Sleep -Milliseconds 20
    }
    `$true | Should -BeTrue
} }
"@
            [IO.File]::WriteAllText((Join-Path $root ('tests/pester/'+$name+'.Tests.ps1')),$body,[Text.UTF8Encoding]::new($true))
        }
        Add-Content (Join-Path $root '.gitignore') '*.ready'
        $catalog=@{schemaVersion=1;contracts=@(@{id='parallel';owner='private fixture';gate='targeted';budgetSeconds=30;primaryTest='tests/pester/Runtime.Tests.ps1';paths=@('scripts/*');tests=@('tests/pester/Runtime.Tests.ps1','tests/pester/DevelopManifestContinuation.Tests.ps1')})}
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'),($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $root add --all;& git -C $root commit -qm 'independent native fixtures'
        $first=Invoke-PreflightFixture $root out-cold
        $first.executedWorkerCount | Should -Be 2
        $first.passed | Should -Be 2
        $warm=Invoke-PreflightFixture $root out-warm
        $warm.executedWorkerCount | Should -Be 0
        $warm.reusedWorkerCount | Should -Be 2
    }
    It 'finishes the short task before two independent workers and reuses all three proofs' {
        $root = New-PreflightFixture 'Preflight passing'
        $first = Invoke-PreflightFixture $root 'out-first'
        $first.executedWorkerCount | Should -Be 3
        $first.passed | Should -Be 3
        $trace = @(Get-Content -LiteralPath (Join-Path $root 'counter.txt'))
        $trace[0..1] | Should -Be @('short-start','short-passed')
        $trace.Count | Should -Be 2
        @((Get-ChildItem -LiteralPath (Join-Path $root '.native-trace')).Name | Sort-Object) | Should -Be @('Expensive.Tests.ps1','Runtime.Tests.ps1')
        $second = Invoke-PreflightFixture $root 'out-warm'
        $second.executedWorkerCount | Should -Be 0
        $second.reusedWorkerCount | Should -Be 3
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
        foreach ($file in @('Expensive.Tests.ps1','Runtime.Tests.ps1')) { @(Get-Content -LiteralPath (Join-Path $root ('.native-trace/'+$file))) | Should -Be @('executed') }
        @(& git -C $root status --porcelain -z).Count | Should -Be 0
    }

    It 'preserves the original short failure without launching expensive tasks and continues after its fix' {
        $root = New-PreflightFixture 'Preflight correction' -Fail
        $failed = Invoke-PreflightFixture $root 'out-failed' -ExpectFailure
        $failed.status | Should -Be 'failed'
        $failed.failed | Should -Be 1
        (Get-Content -LiteralPath $failed.junitPath -Raw -Encoding UTF8) | Should -Match 'original preflight failure'
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')) | Should -Be @('short-start')
        @(Get-ChildItem -LiteralPath (Join-Path $root '.native-trace')).Count | Should -Be 0
        $failed.workers.Count | Should -Be 1
        Set-PreflightFixtureBody $root
        & git -C $root add -- tests/pester/SourceDeliveryAdmission.Tests.ps1
        & git -C $root commit -qm 'fix: original short owner'
        $LASTEXITCODE | Should -Be 0
        $continued = Invoke-PreflightFixture $root 'out-continued'
        $continued.passed | Should -Be 3
        $continued.failed | Should -Be 0
        $trace = @(Get-Content -LiteralPath (Join-Path $root 'counter.txt'))
        $trace[0..2] | Should -Be @('short-start','short-start','short-passed')
        $trace.Count | Should -Be 3
        @((Get-ChildItem -LiteralPath (Join-Path $root '.native-trace')).Name | Sort-Object) | Should -Be @('Expensive.Tests.ps1','Runtime.Tests.ps1')
        foreach ($file in @('Expensive.Tests.ps1','Runtime.Tests.ps1')) { @(Get-Content -LiteralPath (Join-Path $root ('.native-trace/'+$file))) | Should -Be @('executed') }
        @(& git -C $root status --porcelain -z).Count | Should -Be 0
    }
}

Describe 'Memory admission remains inside the Pester scheduler' {
    BeforeAll {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PesterMemoryWorkerLimit'},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $snapshotDefinition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PesterMemorySnapshot'},$true)
        . ([scriptblock]::Create($snapshotDefinition.Extent.Text))
    }
    It 'limits only owned admission until memory permits progress: <Free>' -ForEach @(
        @{Free=0L;Expected=0},@{Free=1300MB;Expected=1},@{Free=2500MB;Expected=2},@{Free=8GB;Expected=3},@{Free=-1L;Expected=0}
    ) {
        Get-PesterMemoryWorkerLimit -Requested 3 -AvailableBytes $Free | Should -Be $Expected
    }
    It 'defers new workers at critical commit pressure despite ample free physical RAM' {
        Get-PesterMemoryWorkerLimit -Requested 3 -AvailableBytes 8GB -CommitHeadroomBytes 0 | Should -Be 0
        Get-PesterMemoryWorkerLimit -Requested 3 -AvailableBytes 8GB -CommitHeadroomBytes 3GB | Should -Be 1
        Get-PesterMemoryWorkerLimit -Requested 3 -AvailableBytes 8GB -CommitHeadroomBytes 8GB | Should -Be 3
        # The raised ceiling is still admitted per worker by both measurements.
        Get-PesterMemoryWorkerLimit -Requested 8 -AvailableBytes 7.5GB -CommitHeadroomBytes 24GB | Should -Be 7
        Get-PesterMemoryWorkerLimit -Requested 8 -AvailableBytes 16GB -CommitHeadroomBytes 9GB | Should -Be 4
    }
    It 'reads commit headroom above Int32 without treating healthy metrics as unavailable' {
        Mock Get-CimInstance { [pscustomobject]@{AvailableBytes=8GB;CommitLimit=80GB;CommittedBytes=60GB} }
        Remove-Variable pesterMemoryObservedAt -Scope Script -ErrorAction SilentlyContinue
        $snapshot=Get-PesterMemorySnapshot
        $snapshot.availableBytes | Should -Be 8GB
        $snapshot.commitHeadroomBytes | Should -Be 12GB
        Get-PesterMemoryWorkerLimit -Requested 3 -AvailableBytes $snapshot.availableBytes -CommitHeadroomBytes $snapshot.commitHeadroomBytes | Should -Be 3
        Remove-Variable pesterMemoryObservedAt -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable pesterMemorySnapshot -Scope Script -ErrorAction SilentlyContinue
    }
    It 'rejects a cheap routing defect before native work and resumes the original task after correction' {
        $root=New-PreflightFixture 'Routing failure' -Fail
        $old=Join-Path $root 'tests/pester/SourceDeliveryAdmission.Tests.ps1'
        $new=Join-Path $root 'tests/pester/ReleaseRouting.Tests.ps1'
        Move-Item -LiteralPath $old -Destination $new
        $catalogPath=Join-Path $root 'tests/quality-contracts.json'
        [IO.File]::WriteAllText($catalogPath,([IO.File]::ReadAllText($catalogPath).Replace('SourceDeliveryAdmission.Tests.ps1','ReleaseRouting.Tests.ps1')))
        & git -C $root add --all
        & git -C $root commit -qm 'route the original short assertion'
        $failed=Invoke-PreflightFixture $root out-routing-red -ExpectFailure
        $failed.failed | Should -Be 1
        @(Get-ChildItem (Join-Path $root '.native-trace')).Count | Should -Be 0
        Set-PreflightFixtureBody $root
        Move-Item -LiteralPath $old -Destination $new -Force
        & git -C $root add --all
        & git -C $root commit -qm 'repair original routing assertion'
        $green=Invoke-PreflightFixture $root out-routing-green
        $green.passed | Should -Be 3
        $green.failed | Should -Be 0
    }
    It 'completes native tasks with memory recovery=<Recovery> and reuses their proof' -ForEach @(
        @{Recovery='physical';Expected=1;Initial=1},@{Recovery='physical-recovery';Expected=2;Initial=1},@{Recovery='commit-recovery';Expected=2;Initial=0},@{Recovery='commit-serial-recovery';Expected=1;Initial=0}
    ) {
        $root=New-RuntimeProofFixture "Memory admission $Recovery"
        Copy-Item (Join-Path $root 'tests/pester/Runtime.Tests.ps1') (Join-Path $root 'tests/pester/Second.Tests.ps1')
        $catalogPath=Join-Path $root 'tests/quality-contracts.json'
        $catalog=Get-Content $catalogPath -Raw | ConvertFrom-Json
        $catalog.contracts[0].tests+=@('tests/pester/Second.Tests.ps1')
        if($Recovery -eq 'commit-serial-recovery') {
            Move-Item (Join-Path $root 'tests/pester/Runtime.Tests.ps1') (Join-Path $root 'tests/pester/ReleaseAdmission.Tests.ps1')
            Move-Item (Join-Path $root 'tests/pester/Second.Tests.ps1') (Join-Path $root 'tests/pester/ReleaseOrchestration.Tests.ps1')
            $catalog.contracts[0].primaryTest='tests/pester/ReleaseAdmission.Tests.ps1'
            $catalog.contracts[0].tests=@('tests/pester/ReleaseAdmission.Tests.ps1','tests/pester/ReleaseOrchestration.Tests.ps1')
        }
        [IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8))
        & git -C $root add --all
        & git -C $root commit -qm 'two independent native tasks'
        $path=Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $text=[IO.File]::ReadAllText($path)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        $memory=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PesterMemorySnapshot'},$true)
        # Substitute only host observation, keeping both original child tests.
        $observation=switch($Recovery) {
            'physical' {'function Get-PesterMemorySnapshot { return [pscustomobject]@{availableBytes=1300MB;commitHeadroomBytes=8GB} }'}
            'physical-recovery' {'function Get-PesterMemorySnapshot { if(-not (Get-Variable fixtureMemoryReads -Scope Script -ErrorAction SilentlyContinue)){$script:fixtureMemoryReads=0};$script:fixtureMemoryReads++;return [pscustomobject]@{availableBytes=$(if($script:fixtureMemoryReads -eq 1){1300MB}else{8GB});commitHeadroomBytes=8GB} }'}
            {$_ -in @('commit-recovery','commit-serial-recovery')} {'function Get-PesterMemorySnapshot { if(-not (Get-Variable fixtureMemoryReads -Scope Script -ErrorAction SilentlyContinue)){$script:fixtureMemoryReads=0};$script:fixtureMemoryReads++;return [pscustomobject]@{availableBytes=8GB;commitHeadroomBytes=$(if($script:fixtureMemoryReads -le 2){0}else{8GB})} }'}
        }
        $text=$text.Remove($memory.Extent.StartOffset,$memory.Extent.EndOffset-$memory.Extent.StartOffset).Insert($memory.Extent.StartOffset,$observation)
        if($Initial -eq 0) {
            $launchAst=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            $launch=$launchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PesterFileEntry'},$true)
            $text=$text.Insert($launch.Body.ParamBlock.Extent.EndOffset,"`nif(`$script:fixtureMemoryReads -le 2){throw 'Native worker launched before commit headroom returned.'}`n")
        }
        $text=$text.Replace('$PSScriptRoot',("'"+(Join-Path $RepoRoot 'scripts').Replace("'","''")+"'"))
        $runner=Join-Path $TestDrive 'memory scheduler.ps1'
        [IO.File]::WriteAllText($runner,$text,[Text.UTF8Encoding]::new($true))
        $output=Join-Path $root 'out-memory'
        $run=Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$output,'-JunitPath',(Join-Path $output 'pester.xml'),'-WorkerCount','3','-WorkerCountDefaulted')
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $cold=Get-Content (Join-Path $output 'pester-shards/summary.json') -Raw | ConvertFrom-Json
        $cold.initialMemoryLimit | Should -Be $Initial
        if($Initial -eq 0){$cold.memoryAdmissionReductions | Should -BeGreaterThan 0}
        $cold.peakActiveWorkers | Should -Be $Expected
        $cold.pesterWorkers.effective | Should -Be $Expected
        $cold.passed | Should -Be 2
        $cold.executedWorkerCount | Should -Be 2
        $warm=Invoke-RuntimeProofFixture $root out-memory-reuse
        $warm.reusedWorkerCount | Should -Be 2
        $warm.executedWorkerCount | Should -Be 0
        @(Get-Content (Join-Path $root 'counter.txt')).Count | Should -Be 2
        $previewOutput=Join-Path $root 'out-memory-plan'
        $planRun=Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$previewOutput,'-JunitPath',(Join-Path $previewOutput 'never.xml'),'-WorkerCount','3','-WorkerCountDefaulted','-PlanOnly')
        $planRun.exitCode | Should -Be 0 -Because $planRun.combinedText
        $preview=($planRun.stdout -join [Environment]::NewLine)|ConvertFrom-Json
        $preview.executedCount | Should -Be 0
        $preview.reusedCount | Should -Be 2
        $preview.admission.state | Should -Be 'ready'
        $warmOutput=Join-Path $root 'out-memory-default-reuse'
        $warmRun=Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$warmOutput,'-JunitPath',(Join-Path $warmOutput 'pester.xml'),'-WorkerCount','3','-WorkerCountDefaulted')
        $warmRun.exitCode | Should -Be 0 -Because $warmRun.combinedText
        $defaultWarm=Get-Content (Join-Path $warmOutput 'pester-shards/summary.json') -Raw|ConvertFrom-Json
        $defaultWarm.executedWorkerCount | Should -Be 0
        $defaultWarm.reusedWorkerCount | Should -Be 2
        $defaultWarm.peakActiveWorkers | Should -Be 0
        $defaultWarm.pesterWorkers.effective | Should -BeGreaterThan 0
    }
}
