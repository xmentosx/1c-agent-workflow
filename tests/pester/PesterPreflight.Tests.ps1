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
