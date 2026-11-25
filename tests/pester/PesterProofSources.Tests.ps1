BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $PSScriptRoot 'PesterRuntimeSupport.ps1')
}

Describe 'Read-only proof reuse across support clones' {
    It 'reuses a local-origin proof and rejects corrupt or changed inputs without writing to the producer' {
        $producer = New-RuntimeProofFixture 'producer источник'
        $cold = Invoke-RuntimeProofFixture $producer out-cold
        $cold.executedWorkerCount | Should -Be 1
        $consumer = Join-Path $TestDrive 'support копия'
        & git clone -q -- $producer $consumer
        $LASTEXITCODE | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $producer 'README.md'),'unowned source progress after cloning')
        & git -C $producer add -- README.md
        & git -C $producer commit -qm 'source progressed independently'
        $cache = Join-Path $producer '.git/itl/pester-shards/v1'
        $before = @(Get-ChildItem $cache -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash })
        $warm = Invoke-RuntimeProofFixture $consumer out-warm
        $warm.executedWorkerCount | Should -Be 0
        $warm.reusedWorkerCount | Should -Be 1
        $warm.workers[0].proofSource | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $consumer 'counter.txt') | Should -BeFalse
        @(Get-ChildItem $cache -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) | Should -Be $before
        @(Get-ChildItem (Join-Path $consumer '.git/itl/pester-shards/v1') -Force).Count | Should -Be 0

        $manifest = Get-ChildItem $cache -Recurse -Filter manifest.json | Select-Object -First 1
        $result = Join-Path $manifest.DirectoryName 'result.json'
        [IO.File]::AppendAllText($result, 'corrupt')
        $invalid = Invoke-RuntimeProofFixture $consumer out-corrupt
        $invalid.executedWorkerCount | Should -Be 1
        $invalid.reusedWorkerCount | Should -Be 0
        # A changed owner input must miss the consumer's newly saved proof too.
        Add-Content (Join-Path $consumer 'scripts/run-pester-shard.ps1') '# changed owner'
        $changed = Invoke-RuntimeProofFixture $consumer out-changed
        $changed.executedWorkerCount | Should -Be 1
        $changed.reusedWorkerCount | Should -Be 0
        @(Get-Content (Join-Path $consumer 'counter.txt')).Count | Should -Be 2
    }

    It 'uses an explicit source for a sibling clone only after proving common ancestry' {
        $producer = New-RuntimeProofFixture 'explicit источник'
        [void](Invoke-RuntimeProofFixture $producer out-cold)
        $consumer = Join-Path $TestDrive 'explicit копия'
        & git clone -q -- $producer $consumer
        & git -C $consumer remote remove origin
        & git -C $consumer config --local --add itl.pesterProofSource $producer
        $warm = Invoke-RuntimeProofFixture $consumer out-warm
        $warm.reusedWorkerCount | Should -Be 1
        $unrelated = New-RuntimeProofFixture 'unrelated источник'
        & git -C $unrelated commit --amend -qm 'unrelated root identity'
        [void](Invoke-RuntimeProofFixture $unrelated out-cold)
        # Identical runtime input digests alone do not enroll an unrelated repo.
        & git -C $consumer config --local --unset-all itl.pesterProofSource
        & git -C $consumer config --local --add itl.pesterProofSource $unrelated
        $cold = Invoke-RuntimeProofFixture $consumer out-unrelated
        $cold.executedWorkerCount | Should -Be 1
    }
}
