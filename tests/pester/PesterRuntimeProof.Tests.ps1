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
        $second = Invoke-RuntimeProofFixture $other 'out-warm' -Core $core
        $second.executedWorkerCount | Should -Be 0
        $second.reusedWorkerCount | Should -Be 1
        $second.runtimeIdentity.identitySha256 | Should -BeExactly $identity.identitySha256
        @(& git -C $root status --porcelain -z).Count | Should -Be 0
        @(& git -C $other status --porcelain -z).Count | Should -Be 0
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
