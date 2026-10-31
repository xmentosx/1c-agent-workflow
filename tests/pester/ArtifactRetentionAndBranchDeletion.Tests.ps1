BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.yaxunit.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1')
    . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.branch-deletion.ps1')

    function New-TestRetentionRepository {
        param([string]$Path)
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        & git -C $Path init --quiet
        & git -C $Path config user.name 'ITL Test'
        & git -C $Path config user.email 'itl@example.invalid'
        [IO.File]::WriteAllText((Join-Path $Path 'README.md'), 'fixture', [Text.UTF8Encoding]::new($false))
        & git -C $Path add README.md
        & git -C $Path commit --quiet -m 'fixture'
    }

    function Set-TestTreeAge {
        # Every directory below counts as a write, so age the whole tree.
        param([string]$Path, [double]$Days)
        $time = [datetime]::UtcNow.AddDays(-$Days)
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force) + @(Get-Item -LiteralPath $Path -Force)) {
            if ($item.FullName -notmatch '[\\/]\.git([\\/]|$)') { $item.LastWriteTimeUtc = $time }
        }
    }

    function New-TestAgedTree {
        param([string]$Path, [double]$Days, [string]$FileName = 'x.txt')
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        [IO.File]::WriteAllText((Join-Path $Path $FileName), 'leftover', [Text.UTF8Encoding]::new($false))
        Set-TestTreeAge -Path $Path -Days $Days
    }
}

Describe 'ITL artifact retention' {
    It 'protects current impact inputs and immutable accepted history after retiring a task' {
        $root=Join-Path $TestDrive 'История приёмки с пробелом'
        $selection=Join-Path $root '.agent-1c/verification-selection'
        $run=Join-Path $root '.agent-1c/runs/current'
        New-Item -ItemType Directory -Force -Path $selection,$run | Out-Null
        $change=@{planArtifact=@{path='.agent-1c/runs/current/plan.json'};requirements=@(@{path='requirements.md'})}
        $path=Join-Path $selection 'current-change.json'
        [IO.File]::WriteAllText($path,($change|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        Mock Get-DevBranchStateFiles { @() }
        $protected=Get-ItlArtifactProtectedPaths -ProjectRoot $root
        (Test-ItlArtifactProtected -Path $run -ProtectedPaths $protected) | Should -BeTrue
        (Test-ItlArtifactProtected -Path (Join-Path $root 'requirements.md') -ProtectedPaths $protected) | Should -BeTrue
        $change.requirements[0].path='../foreign.md'
        [IO.File]::WriteAllText($path,($change|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        { Get-ItlArtifactProtectedPaths -ProjectRoot $root } | Should -Throw '*ITL_ARTIFACT_CHANGE_RECEIPT_UNREADABLE*'
        Remove-Item -LiteralPath $path -Force
        $protected=Get-ItlArtifactProtectedPaths -ProjectRoot $root
        (Test-ItlArtifactProtected -Path (Join-Path $selection 'changes/accepted.json') -ProtectedPaths $protected) | Should -BeTrue
    }

    It 'protects the observed run artifacts named by a passed one-off receipt' {
        $root = Join-Path $TestDrive 'One off проект'
        $run = Join-Path $root '.agent-1c/runs/run-001'
        $proofRoot = Join-Path $root '.agent-1c/verification-selection/one-off'
        New-Item -ItemType Directory -Force -Path $run, $proofRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $run 'observed.txt'), 'observed', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $run 'result.json'), '{}', [Text.UTF8Encoding]::new($false))
        $receipt = [ordered]@{ status = 'passed'; evidencePath = '.agent-1c/runs/run-001/result.json'; artifacts = @(@{ path = '.agent-1c/runs/run-001/observed.txt' }) }
        [IO.File]::WriteAllText((Join-Path $proofRoot 'observed.json'), ($receipt | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Mock Get-DevBranchStateFiles { @() }
        $protected = Get-ItlArtifactProtectedPaths -ProjectRoot $root
        (Test-ItlArtifactProtected -Path $run -ProtectedPaths $protected) | Should -BeTrue
        $receipt.artifacts[0].path = '../outside.txt'
        [IO.File]::WriteAllText((Join-Path $proofRoot 'observed.json'), ($receipt | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        { Get-ItlArtifactProtectedPaths -ProjectRoot $root } | Should -Throw '*ITL_ARTIFACT_ONE_OFF_RECEIPT_UNREADABLE*'
    }

    It 'protects active run paths when script run context is present' {
        $root = Join-Path $TestDrive 'Активный запуск с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $names = @('ResolvedRunStatusPath', 'ResolvedRunLogPath', 'RunResultPath', 'RunResultManifestPath')
        $saved = @{}
        foreach ($name in $names) {
            $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            $saved[$name] = [pscustomobject]@{ exists = ($null -ne $variable); value = $(if ($null -ne $variable) { $variable.Value } else { $null }) }
        }
        try {
            $activePaths = @($names | ForEach-Object { Join-Path $root ($_ + '.json') })
            for ($i = 0; $i -lt $names.Count; $i++) { Set-Variable -Name $names[$i] -Scope Script -Value $activePaths[$i] }
            Mock Get-DevBranchStateFiles { @() }
            $protected = Get-ItlArtifactProtectedPaths -ProjectRoot $root
            foreach ($path in $activePaths) { (Test-ItlArtifactProtected -Path $path -ProtectedPaths $protected) | Should -BeTrue }
        } finally {
            foreach ($name in $names) {
                if (-not $saved[$name].exists) { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
                else { Set-Variable -Name $name -Scope Script -Value $saved[$name].value }
            }
        }
    }

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
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7; diagnosticDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @($script:referencedResult) }
        Mock Get-ItlResultArtifactCandidates { return $script:retentionCandidates }
        Mock Get-ItlRunArtifactCandidates { return @() }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        Mock Get-ItlAgentTaskArtifactCandidates { return @() }
        Mock Get-ItlBranchDumpArtifactCandidates { return @() }
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

    It 'deletes only a hash-matched eligible <Extension> pair with <HashCase> hash and leaves unknown files' -TestCases @(
        @{ Extension = 'cf'; HashCase = 'lower' },
        @{ Extension = 'cf'; HashCase = 'upper' },
        @{ Extension = 'cf'; HashCase = 'mixed' },
        @{ Extension = 'cfe'; HashCase = 'lower' },
        @{ Extension = 'cfe'; HashCase = 'upper' },
        @{ Extension = 'cfe'; HashCase = 'mixed' }
    ) {
        param($Extension, $HashCase)
        $root = Join-Path $TestDrive 'Результаты с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $artifact = Join-Path $root "old.$Extension"
        $manifest = "$artifact.manifest.json"
        $unknown = Join-Path $root 'manual.cf'
        [IO.File]::WriteAllText($artifact, 'old-result')
        [IO.File]::WriteAllText($manifest, '{}')
        [IO.File]::WriteAllText($unknown, 'manual-result')
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
        if ($HashCase -eq 'lower') { $hash = $hash.ToLowerInvariant() }
        elseif ($HashCase -eq 'mixed') { $hash = $hash.Substring(0, 32).ToLowerInvariant() + $hash.Substring(32) }
        $entry = [pscustomobject]@{ category = 'result'; group = 'test'; root = $root; path = $artifact; companion = $manifest; expectedSha256 = $hash; sizeBytes = 10; delete = $true }
        Mock Get-ItlArtifactCleanupPlan { [pscustomobject]@{ policy = [pscustomobject]@{ enabled = $true }; entries = @($entry) } }
        Invoke-ItlArtifactCleanup -DryRun | Out-Null
        (Test-Path -LiteralPath $artifact) | Should -BeTrue
        Invoke-ItlArtifactCleanup | Out-Null
        (Test-Path -LiteralPath $artifact) | Should -BeFalse
        (Test-Path -LiteralPath $manifest) | Should -BeFalse
        (Test-Path -LiteralPath $unknown) | Should -BeTrue
    }

    It 'preserves an eligible result and its manifest when the artifact bytes changed' {
        $root = Join-Path $TestDrive 'Изменённый результат с пробелами'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $artifact = Join-Path $root 'changed.cf'
        $manifest = "$artifact.manifest.json"
        [IO.File]::WriteAllText($artifact, 'original-result')
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($manifest, '{}')
        [IO.File]::WriteAllText($artifact, 'changed-result')
        $entry = [pscustomobject]@{ category = 'result'; group = 'test'; root = $root; path = $artifact; companion = $manifest; expectedSha256 = $hash; sizeBytes = 14; delete = $true }
        Mock Get-ItlArtifactCleanupPlan { [pscustomobject]@{ policy = [pscustomobject]@{ enabled = $true }; entries = @($entry) } }
        { Invoke-ItlArtifactCleanup -WarningAction SilentlyContinue } | Should -Throw '*ITL_ARTIFACT_CLEANUP_INCOMPLETE*'
        [IO.File]::ReadAllText($artifact) | Should -Be 'changed-result'
        (Test-Path -LiteralPath $manifest) | Should -BeTrue
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
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7; diagnosticDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @() }
        Mock Get-ItlResultArtifactCandidates { return @() }
        Mock Get-ItlRunArtifactCandidates { return $script:runCandidates }
        Mock Get-ItlAuxiliaryArchiveArtifactCandidates { return @() }
        Mock Get-ItlArchiveArtifactCandidates { return @() }
        Mock Get-ItlAgentTaskArtifactCandidates { return @() }
        Mock Get-ItlBranchDumpArtifactCandidates { return @() }
        $plan = Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root
        @($plan.entries | Where-Object delete).Count | Should -Be 1
        @($plan.entries | Where-Object delete)[0].path | Should -Be $runs[4].path
    }

    It 'expires idle agent task folders beyond the newest three and keeps owned, tracked and referenced ones' {
        $root = Join-Path $TestDrive 'Папки задач агентов с пробелом'
        New-TestRetentionRepository -Path $root
        foreach ($name in @('новая 1', 'новая 2', 'новая 3')) { New-TestAgedTree -Path (Join-Path $root "build/$name") -Days 1 }
        New-TestAgedTree -Path (Join-Path $root 'build/старая a') -Days 10
        New-TestAgedTree -Path (Join-Path $root 'build/старая b') -Days 20
        New-TestAgedTree -Path (Join-Path $root 'build/result') -Days 30
        New-TestAgedTree -Path (Join-Path $root 'build/tracked') -Days 30
        & git -C $root add -- 'build/tracked' 2>$null
        & git -C $root commit --quiet -m 'tracked build folder'
        New-TestAgedTree -Path (Join-Path $root 'build/test-results/давний 1') -Days 15
        New-TestAgedTree -Path (Join-Path $root 'build/test-results/давний 2') -Days 25
        New-TestAgedTree -Path (Join-Path $root 'build/test-results/vanessa') -Days 30
        New-TestAgedTree -Path (Join-Path $root 'build/agent-artifacts/задача со ссылкой') -Days 30
        New-TestAgedTree -Path (Join-Path $root '.agent-1c/runs/ai-rules-migration-1') -Days 30
        New-TestAgedTree -Path (Join-Path $root '.agent-1c/runs/helper run') -Days 30
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/runs/helper run/status.json'), '{"status":"succeeded"}', [Text.UTF8Encoding]::new($false))
        $script:referenced = Join-Path $root 'build/agent-artifacts/задача со ссылкой/x.txt'
        Mock Get-ConfigValue { param($Path, $Default) $Default }
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7; diagnosticDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @() }
        Mock Get-ItlDiagnosticRetainedPaths { return @($script:referenced) }
        foreach ($name in @('Get-ItlResultArtifactCandidates', 'Get-ItlRunArtifactCandidates', 'Get-ItlAuxiliaryArchiveArtifactCandidates', 'Get-ItlArchiveArtifactCandidates')) { Mock $name { return @() } }
        $plan = Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root
        $agent = @($plan.entries | Where-Object category -eq 'agent-task')
        @($agent | Where-Object delete | ForEach-Object { Split-Path -Leaf $_.path } | Sort-Object) | Should -Be @('старая a', 'старая b')
        @($agent | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Not -Contain 'result'
        @($agent | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Not -Contain 'tracked'
        @($agent | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Not -Contain 'vanessa'
        @($agent | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Not -Contain 'helper run'
        @($agent | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Not -Contain 'ai-rules-migration-1'
        @($agent | Where-Object { $_.group -eq 'test-results' -and -not $_.delete }).Count | Should -Be 2
        ($agent | Where-Object { (Split-Path -Leaf $_.path) -eq 'задача со ссылкой' }).reason | Should -Be 'referenced'
        ($agent | Where-Object { (Split-Path -Leaf $_.path) -eq 'старая b' }).sizeBytes | Should -BeGreaterThan 0
        Mock Get-ItlDiagnosticRetainedPaths { throw 'unreadable receipt store' }
        $plan = Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root
        @($plan.entries | Where-Object { $_.category -eq 'agent-task' -and $_.delete }).Count | Should -Be 0
    }

    It 'treats only a running record with a passed deadline and a dead process as abandoned' {
        $exited = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'exit 0' -WindowStyle Hidden -PassThru
        $exited.WaitForExit()
        $past = [datetime]::UtcNow.AddMinutes(-5).ToString('o')
        $future = [datetime]::UtcNow.AddHours(1).ToString('o')
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'running'; pid = $exited.Id; operationDeadlineUtc = $past }) | Should -BeTrue
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'running'; pid = $exited.Id; operationDeadlineUtc = [datetime]::UtcNow.AddMinutes(-5) }) | Should -BeTrue
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'running'; pid = $PID; operationDeadlineUtc = $past }) | Should -BeFalse
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'running'; pid = $exited.Id; operationDeadlineUtc = $future }) | Should -BeFalse
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'running'; pid = 0; operationDeadlineUtc = $past }) | Should -BeFalse
        Test-ItlRunStatusAbandoned -Status ([pscustomobject]@{ status = 'succeeded'; pid = $exited.Id; operationDeadlineUtc = $past }) | Should -BeFalse
        $root = Join-Path $TestDrive 'Брошенные прогоны'
        foreach ($run in @(@{ name = 'abandoned'; id = $exited.Id }, @{ name = 'live'; id = $PID })) {
            $folder = Join-Path $root ".agent-1c/runs/$($run.name)"
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            [IO.File]::WriteAllText((Join-Path $folder 'status.json'), ([ordered]@{ status = 'running'; pid = $run.id; operationDeadlineUtc = $past } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        $script:runRoot = $root
        Mock Resolve-ProjectPath { param($Path) Join-Path $script:runRoot $Path }
        Mock Get-VanessaReportsPath { 'build/test-results/vanessa' }
        Mock Get-YAxUnitReportsPath { 'build/test-results/yaxunit' }
        @(Get-ItlRunArtifactCandidates -ProjectRoot $root | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @('abandoned')
    }

    It 'expires an interrupted dump transaction after an hour without writes' {
        $root = Join-Path $TestDrive 'Выгрузка ветки'
        $old = Join-Path $root '.agent-1c/branch-dumps/20260818-185355-626-c884e1b6931e43cb843c6127452a0562'
        $fresh = Join-Path $root '.agent-1c/branch-dumps/20261031-100000-000-d884e1b6931e43cb843c6127452a0562'
        New-TestAgedTree -Path $old -Days 0.1
        New-TestAgedTree -Path $fresh -Days 0
        New-TestAgedTree -Path (Join-Path $root '.agent-1c/branch-dumps/unknown') -Days 10
        Mock Get-ItlArtifactRetentionPolicy { [pscustomobject]@{ enabled = $true; resultKeepCount = 3; archiveKeepCount = 2; runKeepCount = 3; runtimeDays = 7; diagnosticDays = 7 } }
        Mock Get-ItlArtifactProtectedPaths { return @() }
        foreach ($name in @('Get-ItlResultArtifactCandidates', 'Get-ItlRunArtifactCandidates', 'Get-ItlAuxiliaryArchiveArtifactCandidates', 'Get-ItlArchiveArtifactCandidates', 'Get-ItlAgentTaskArtifactCandidates')) { Mock $name { return @() } }
        $dumps = @((Get-ItlArtifactCleanupPlan -ProjectRoot $root -MainRoot $root).entries | Where-Object category -eq 'branch-dump')
        @($dumps | Where-Object delete).path | Should -Be @($old)
        ($dumps | Where-Object { $_.path -eq $fresh }).reason | Should -Be 'within-age'
        @($dumps).Count | Should -Be 2
    }

    It 'removes only the previous task leftovers when reset recreates the branch' {
        $root = Join-Path $TestDrive 'Ветка сброса с пробелом'
        $main = Join-Path $TestDrive 'Основная база'
        New-TestRetentionRepository -Path $root
        $removed = @('build/agent-artifacts/задача/tmp/a.txt', 'build/test-results/прогон/r.txt', 'build/старая задача/x.txt',
            'build/event-log/export-20261030-101010-101/EventLogExport.json', '.agent-1c/runs/old run/status.json', '.agent-1c/tmp/old/x.txt',
            '.agent-1c/branch-dumps/t/x.txt', '.agent-1c/fork-history/f/x.txt', '.agent-1c/snapshots/gate6-1.dt', '.agent-1c/snapshots/gate6-1.dt.recovery.json', 'logs/1c/x.log')
        $kept = @('build/test-results/tooling-probe/keep.txt', 'build/test-results/release-e2e/keep.json', 'build/result/r.cf', 'build/tracked/x.txt',
            '.agent-1c/runs/auto-update/x.txt', '.agent-1c/runs/ai-rules-migration-1/x.txt', '.agent-1c/tmp/tooling-probe/x.txt',
            '.agent-1c/snapshots/workflow-update/x.txt', '.agent-1c/snapshots/workflow-update-rollout.json', 'handoffs/заметка.md',
            'build/test-results/доказательство/proof.json')
        foreach ($relative in $removed + $kept) { New-TestAgedTree -Path (Split-Path -Parent (Join-Path $root $relative)) -Days 1 -FileName (Split-Path -Leaf $relative) }
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/runs/old run/status.json'), '{"status":"succeeded"}', [Text.UTF8Encoding]::new($false))
        & git -C $root add -f -- 'build/tracked' 2>$null
        & git -C $root commit --quiet -m 'tracked build folder'
        $live = Join-Path $root '.agent-1c/runs/live run'
        New-Item -ItemType Directory -Force -Path $live | Out-Null
        [IO.File]::WriteAllText((Join-Path $live 'status.json'), ([ordered]@{ status = 'running'; pid = $PID; operationDeadlineUtc = [datetime]::UtcNow.AddHours(1).ToString('o') } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $legacyArchive = Join-Path $main '.agent-1c/branch-archives/ветка/20261009T141019349Z-3570c292'
        $otherArchive = Join-Path $main '.agent-1c/branch-archives/другая/20261009T141019349Z-3570c292'
        New-TestAgedTree -Path $legacyArchive -Days 20
        New-TestAgedTree -Path $otherArchive -Days 20
        $busy = Join-Path $root 'build/test-results/занят'
        New-TestAgedTree -Path $busy -Days 1
        # Only items untouched since reset started belong to the previous task.
        Set-TestTreeAge -Path $root -Days 1
        Set-TestTreeAge -Path $main -Days 20
        $start = [datetime]::UtcNow.AddMinutes(-1)
        New-TestAgedTree -Path (Join-Path $root 'build/agent-artifacts/during reset') -Days 0
        $script:proof = Join-Path $root 'build/test-results/доказательство'
        Mock Get-ConfigValue { param($Path, $Default) $Default }
        Mock Get-ItlArtifactProtectedPaths { return @($script:proof) }
        $handle = [IO.File]::Open((Join-Path $busy 'x.txt'), 'Open', 'Read', 'None')
        try {
            $report = Invoke-ItlBranchResetLeftoverCleanup -ProjectRoot $root -MainRoot $main -SafeBranchName 'ветка' -StartedAt $start
        } finally { $handle.Dispose() }
        foreach ($relative in $removed) { Test-Path -LiteralPath (Join-Path $root $relative) | Should -BeFalse -Because $relative }
        foreach ($relative in $kept) { Test-Path -LiteralPath (Join-Path $root $relative) | Should -BeTrue -Because $relative }
        Test-Path -LiteralPath (Join-Path $live 'status.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'build/agent-artifacts/during reset') | Should -BeTrue
        Test-Path -LiteralPath (Split-Path -Parent $legacyArchive) | Should -BeFalse
        Test-Path -LiteralPath $otherArchive | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $busy 'x.txt') | Should -BeTrue
        $report.removedCount | Should -BeGreaterOrEqual $removed.Count
        $report.removedBytes | Should -BeGreaterThan 0
        @($report.leftovers | Where-Object { $_ -like "$busy*" }).Count | Should -Be 1
        @($report.leftovers | Where-Object { $_ -like "$($script:proof)*referenced by workflow evidence*" }).Count | Should -Be 1
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

    It 'keeps Git path diagnostics usable with optional lifecycle phase (<Case>)' -TestCases @(
        @{ Case = 'undefined'; Phase = $null; Expected = '<none>' },
        @{ Case = 'caller-defined'; Phase = 'observed-caller-phase'; Expected = 'observed-caller-phase' }
    ) {
        param($Case, $Phase, $Expected)
        Mock Invoke-ItlNativeProcessCapture { [pscustomobject]@{ exitCode = 128; stdout = ''; stderr = 'original native failure' } }
        & {
            if ($null -ne $Phase) { $LifecyclePhase = $Phase }
            try { Get-GitPathListAt -Root $TestDrive -Arguments @('worktree', 'list', '--porcelain', '-z'); throw 'Expected original native failure' }
            catch {
                $_.Exception.Message | Should -Match ('LifecyclePhase: ' + [regex]::Escape($Expected))
                $_.Exception.Message | Should -Match 'ExitCode: 128'
                $_.Exception.Message | Should -Match 'original native failure'
            }
        }
        Should -Invoke Invoke-ItlNativeProcessCapture -Times 1
    }

    It 'refuses to delete a dirty worktree when managed branch state is missing' {
        $main = Join-Path $TestDrive 'Главный проект без состояния с пробелами'
        $worktree = Join-Path $TestDrive 'Ветка без состояния с пробелами'
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
        $headBefore = (& git -C $main rev-parse HEAD).Trim()
        $dirtyBefore = (Get-FileHash -LiteralPath $dirty -Algorithm SHA256).Hash
        $masterBefore = (Get-FileHash -LiteralPath (Join-Path $main 'README.md') -Algorithm SHA256).Hash
        $script:ProjectRoot = $main
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation { throw 'Missing managed state must not reach runtime cleanup' }
        Mock Release-ItlManagedPortAllocationsForState { throw 'Missing managed state must not reach port cleanup' }
        { Remove-ItlDevBranch -Name test -Confirmed } | Should -Throw "*Development branch state not found for 'test'.*"
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 0
        Should -Invoke Release-ItlManagedPortAllocationsForState -Times 0
        (Test-Path -LiteralPath $worktree) | Should -BeTrue
        (Get-FileHash -LiteralPath $dirty -Algorithm SHA256).Hash | Should -Be $dirtyBefore
        (Get-FileHash -LiteralPath (Join-Path $main 'README.md') -Algorithm SHA256).Hash | Should -Be $masterBefore
        (& git -C $main rev-parse HEAD).Trim() | Should -Be $headBefore
        (Find-GitWorktreeByBranch -Branch 'itldev/test').path | Should -Be ([IO.Path]::GetFullPath($worktree).Replace('\', '/'))
        (& git -C $main branch --list 'itldev/test') | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $main '.agent-1c/branch-deletions/test.json')) | Should -BeFalse
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
        $masterHeadBefore = (& git -C $main rev-parse HEAD).Trim()
        $masterBytesBefore = (Get-FileHash -LiteralPath (Join-Path $main 'README.md') -Algorithm SHA256).Hash
        Remove-ItlDevBranch -Name test -Confirmed
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 1
        Should -Invoke Release-ItlManagedPortAllocationsForState -Times 1
        (Test-Path -LiteralPath $worktree) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $main 'README.md')) | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $main 'README.md') -Algorithm SHA256).Hash | Should -Be $masterBytesBefore
        (& git -C $main rev-parse HEAD).Trim() | Should -Be $masterHeadBefore
        (& git -C $main branch --list 'itldev/test') | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $main '.agent-1c/branch-deletions/test.json')) | Should -BeFalse
    }
}
