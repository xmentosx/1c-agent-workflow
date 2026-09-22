BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.branch-deletion.ps1')
}

Describe 'ITL artifact retention' {
    It 'uses the configured defaults and rejects an invalid count' {
        Mock Get-EnvValue { param($Name, $Default) return $Default }
        $policy = Get-ItlArtifactRetentionPolicy
        $policy.enabled | Should -BeTrue
        $policy.resultKeepCount | Should -Be 3
        $policy.archiveKeepCount | Should -Be 2
        $policy.runKeepCount | Should -Be 3
        $policy.runtimeDays | Should -Be 7
        Mock Get-EnvValue { param($Name, $Default) if ($Name -eq 'ITL_RESULT_ARTIFACT_KEEP_COUNT') { return '0' }; return $Default }
        { Get-ItlArtifactRetentionPolicy } | Should -Throw '*ITL_RESULT_ARTIFACT_KEEP_COUNT*'
    }

    It 'discovers only manifest-backed CF pairs in a Cyrillic path with spaces' {
        $root = Join-Path $TestDrive 'Проект с пробелами'
        $resultRoot = Join-Path $root 'build/result'
        New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
        $artifact = Join-Path $resultRoot 'test-20260923.cf'
        $unknown = Join-Path $resultRoot 'manual.cf'
        [IO.File]::WriteAllText($artifact, 'verified')
        [IO.File]::WriteAllText($unknown, 'unknown')
        $manifest = [ordered]@{ schemaVersion = 3; artifact = [ordered]@{ path = $artifact; sha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash }; branch = [ordered]@{ safeName = 'test' } }
        [IO.File]::WriteAllText("$artifact.manifest.json", ($manifest | ConvertTo-Json -Depth 5))
        $script:ProjectRoot = $root
        Mock Get-ConfigValue { param($Path, $Default) return $Default }
        $found = @(Get-ItlResultArtifactCandidates -ProjectRoot $root)
        $found.Count | Should -Be 1
        $found[0].path | Should -Be $artifact
        $found[0].group | Should -Be 'test'
    }

    It 'retains three newest results and every referenced result' {
        $root = Join-Path $TestDrive 'Проект с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $candidates = @()
        foreach ($index in 1..5) {
            $path = Join-Path $root "result-$index.cf"
            [IO.File]::WriteAllText($path, "result-$index")
            $candidates += New-ItlArtifactRetentionCandidate -Category result -Root $root -Path $path -Group one -ModifiedAt ([datetime]'2026-01-01').AddDays($index)
        }
        $script:retentionCandidates = $candidates
        $script:referencedResult = $candidates[0].path
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @($script:referencedResult) }
        Mock Get-ItlResultArtifactCandidates { return $script:retentionCandidates }
        Mock Get-ItlRunArtifactCandidates { return @() }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        $plan = Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root
        @($plan.entries | Where-Object delete).Count | Should -Be 1
        @($plan.entries | Where-Object delete)[0].path | Should -Be $candidates[1].path
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 5
    }

    It 'refuses to walk outside the exact managed root' {
        $root = Join-Path $TestDrive 'Корень с пробелами'
        $other = Join-Path $TestDrive 'Корень с пробелами-другой'
        New-Item -ItemType Directory -Path $root, $other -Force | Out-Null
        (Test-ItlArtifactPathInside -Root $root -Path $other) | Should -BeFalse
        (Test-ItlArtifactPathWithoutReparse -Root $root -Path $other -Recursive) | Should -BeFalse
    }

    It 'deletes only a hash-matched eligible result pair and leaves unknown files' {
        $root = Join-Path $TestDrive 'Результаты с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $artifact = Join-Path $root 'old.cf'
        $manifest = "$artifact.manifest.json"
        $unknown = Join-Path $root 'manual.cf'
        [IO.File]::WriteAllText($artifact, 'old-result')
        [IO.File]::WriteAllText($manifest, '{}')
        [IO.File]::WriteAllText($unknown, 'manual-result')
        $entry = [pscustomobject]@{ category = 'result'; group = 'test'; root = $root; path = $artifact; companion = $manifest; expectedSha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash; sizeBytes = 10; delete = $true }
        Mock Get-ItlArtifactCleanupPlan { [pscustomobject]@{ policy = [pscustomobject]@{ enabled = $true }; entries = @($entry) } }
        Invoke-ItlArtifactCleanup -DryRun | Out-Null
        (Test-Path -LiteralPath $artifact) | Should -BeTrue
        Invoke-ItlArtifactCleanup | Out-Null
        (Test-Path -LiteralPath $artifact) | Should -BeFalse
        (Test-Path -LiteralPath $manifest) | Should -BeFalse
        (Test-Path -LiteralPath $unknown) | Should -BeTrue
    }

    It 'keeps automatic cleanup silent so it cannot replace action output' {
        Mock Get-ItlArtifactCleanupPlan { [pscustomobject]@{ policy = [pscustomobject]@{ enabled = $true }; entries = @() } }
        Mock Write-Host { throw 'automatic cleanup wrote to host' }
        Invoke-ItlArtifactCleanup -Automatic | Out-Null
        Should -Invoke Write-Host -Times 0
    }

    It 'requires both surplus count and seven-day age for completed runs' {
        $root = Join-Path $TestDrive 'Прогоны с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $now = (Get-Date).ToUniversalTime()
        $daysAgo = @(0, 1, 2, 3, 10)
        $runs = @()
        foreach ($index in 0..4) {
            $path = Join-Path $root "run-$index"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            $runs += New-ItlArtifactRetentionCandidate -Category 'itl-run' -Root $root -Path $path -Group 'itl-run' -ModifiedAt $now.AddDays(-$daysAgo[$index])
        }
        $script:runCandidates = $runs
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @() }
        Mock Get-ItlResultArtifactCandidates { return @() }
        Mock Get-ItlRunArtifactCandidates { return $script:runCandidates }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        $plan = Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root
        @($plan.entries | Where-Object delete).Count | Should -Be 1
        @($plan.entries | Where-Object delete)[0].path | Should -Be $runs[4].path
    }
}

Describe 'ITL branch deletion identity' {
    It 'removes only the exact launcher record and preserves a foreign base' {
        $savedAppData = $env:APPDATA
        try {
            $env:APPDATA = Join-Path $TestDrive 'Профиль с пробелами'
            $listPath = Join-Path $env:APPDATA '1C/1CEStart/ibases.v8i'
            New-Item -ItemType Directory -Path (Split-Path -Parent $listPath) -Force | Out-Null
            [IO.File]::WriteAllLines($listPath, [string[]]@('[Branch]','Connect=File="C:\branch";','ID=owned','Folder=/ITL/Test','','[Foreign]','Connect=File="C:\foreign";','ID=foreign','Folder=/Other'))
            $journal = [pscustomobject]@{ launcherRegistered = $true; launcherId = 'owned'; launcherName = 'Branch'; launcherFolder = '/ITL/Test'; launcherConnect = 'File="C:\branch";' }
            Unregister-ItlBranchLauncherEntry -Journal $journal
            $content = Get-Content -LiteralPath $listPath -Raw
            $content | Should -Not -Match 'ID=owned'
            $content | Should -Match 'ID=foreign'
        } finally { $env:APPDATA = $savedAppData }
    }

    It 'refuses an infobase that is also the source base' {
        $main = Join-Path $TestDrive 'Проект с пробелами'
        $worktree = Join-Path $TestDrive 'Ветка с пробелами'
        New-Item -ItemType Directory -Path $main, $worktree -Force | Out-Null
        $script:ProjectRoot = $main
        $state = [pscustomobject]@{ devBranch = 'itldev/test'; safeDevBranchName = 'test'; mainWorktreePath = $main; worktreePath = $worktree; createdWithWorktree = $true; infoBaseKind = 'file'; devBranchInfoBasePath = (Join-Path $main 'source'); statePath = (Join-Path $worktree '.agent-1c/dev-branches/test.json'); stateProjectRoot = $worktree }
        Mock Assert-MasterWorktreeContext {}
        Mock Get-MainWorktreePath { return $main }
        Mock Read-DevBranchState { return $state }
        Mock Find-GitWorktreeByBranch { [pscustomobject]@{ path = $worktree; branch = 'itldev/test' } }
        Mock Test-Agent1cLifecycleLockHeld { return $false }
        Mock Get-SourceInfoBasePath { return (Join-Path $main 'source') }
        { New-ItlBranchDeletionJournal -Name test } | Should -Throw '*DELETE_BRANCH_SOURCE_INFOBASE_REFUSED*'
    }

    It 'removes an exact dirty Git worktree and local branch without touching master' {
        $main = Join-Path $TestDrive 'Главный проект с пробелами'
        $worktree = Join-Path $TestDrive 'Ветка с пробелами'
        New-Item -ItemType Directory -Path $main -Force | Out-Null
        & git init -b master -- $main | Out-Null
        $LASTEXITCODE | Should -Be 0
        & git -C $main config user.name 'ITL Test'
        & git -C $main config user.email 'itl@example.invalid'
        [IO.File]::WriteAllText((Join-Path $main 'README.md'), 'master')
        & git -C $main add README.md
        & git -C $main commit -m initial | Out-Null
        $LASTEXITCODE | Should -Be 0
        & git -C $main worktree add -b itldev/test $worktree | Out-Null
        $LASTEXITCODE | Should -Be 0
        $dirty = Join-Path $worktree 'грязный файл.txt'
        [IO.File]::WriteAllText($dirty, 'uncommitted')
        $base = Join-Path $worktree '.agent-1c/infobases/dev-branches/test'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $base 'database.bin'), 'branch-only')
        $statePath = Join-Path $worktree '.agent-1c/dev-branches/test.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        $state = [ordered]@{ devBranchName = 'test'; safeDevBranchName = 'test'; devBranch = 'itldev/test'; mainWorktreePath = $main; worktreePath = $worktree; createdWithWorktree = $true; infoBaseKind = 'file'; devBranchInfoBasePath = $base; publicationMode = 'none'; launcherInfoBaseId = '' }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5))
        $script:ProjectRoot = $main
        Mock Get-SourceInfoBasePath { return (Join-Path $main 'source') }
        Mock Get-ItlResultArtifactCandidates { return @() }
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Release-ItlManagedPortAllocationsForState {}
        Remove-ItlDevBranch -Name test -Confirmed
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 1
        Should -Invoke Release-ItlManagedPortAllocationsForState -Times 1
        (Test-Path -LiteralPath $worktree) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $main 'README.md')) | Should -BeTrue
        (& git -C $main branch --list 'itldev/test') | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $main '.agent-1c/branch-deletions/test.json')) | Should -BeFalse
    }
}
