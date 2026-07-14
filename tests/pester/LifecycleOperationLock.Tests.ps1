Describe "1C workflow lifecycle operation lock" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
        $HelperText = $context.HelperText

        function Initialize-LifecycleLockTestRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Force -Path $Path | Out-Null
            Set-Content -LiteralPath (Join-Path $Path ".gitignore") -Encoding ASCII -Value "*.local`n"
            Set-Content -LiteralPath (Join-Path $Path "sentinel.txt") -Encoding ASCII -Value "fixture"
            & git -C $Path init *> $null
            & git -C $Path config user.email "test@example.com"
            & git -C $Path config user.name "Test User"
            & git -C $Path add .gitignore sentinel.txt
            & git -C $Path commit -m init *> $null
            & git -C $Path branch -M master
        }
    }

    It "publishes meaningful phases for the long lifecycle slices" {
        foreach ($phase in @(
            "config-load.fingerprint",
            "config-load.designer",
            "enterprise.normalize",
            "vanessa.run",
            "vanessa.postprocess",
            "extension-init.snapshot",
            "extension-init.rollback",
            "refresh.merge",
            "close.merge",
            "workflow-update.copy",
            "release.extension-smoke"
        )) {
            $HelperText | Should -Match ([regex]::Escape($phase))
        }
    }

    It "blocks a second mutating action but keeps read-only help and status available" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-conflict-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Enter-Agent1cLifecycleOperation -RequestedAction "run-dev-branch-tests"
                try {
                    $conflict = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $tempRoot,
                        "-Action", "start-vanessa-mcp"
                    )
                    $conflict.exitCode | Should -Be 1
                    $conflict.combinedText | Should -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $conflict.combinedText | Should -Match "requestedAction='start-vanessa-mcp'"
                    $conflict.combinedText | Should -Match "activeAction='run-dev-branch-tests'"
                    $conflict.combinedText | Should -Match ([regex]::Escape($tempRoot))

                    $help = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "help")
                    $help.exitCode | Should -Be 0
                    $status = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "status")
                    $status.exitCode | Should -Be 0
                    $status.combinedText | Should -Match "Lifecycle operation: running"
                    $status.combinedText | Should -Match "action=run-dev-branch-tests"
                } finally {
                    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
                    Exit-Agent1cLifecycleOperation
                }
            }
            @(& git -C $tempRoot status --porcelain) | Should -BeNullOrEmpty
            $commonGitDirectory = ((& git -C $tempRoot rev-parse --git-common-dir) -join "").Trim()
            if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) {
                $commonGitDirectory = Join-Path $tempRoot $commonGitDirectory
            }
            (Get-Content -LiteralPath (Join-Path $commonGitDirectory "info\exclude") -Raw -Encoding UTF8) | Should -Match ([regex]::Escape(".agent-1c/locks/"))
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses independent locks for ordinary actions in separate branch worktrees" {
        $mainRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-main-" + [guid]::NewGuid().ToString("N"))
        $branchOne = $mainRoot + "-branch-one"
        $branchTwo = $mainRoot + "-branch-two"
        try {
            Initialize-LifecycleLockTestRepository -Path $mainRoot
            & git -C $mainRoot worktree add --quiet -b itldev/one $branchOne *> $null
            & git -C $mainRoot worktree add --quiet -b itldev/two $branchTwo master *> $null

            & {
                . $HelperPath -ProjectRoot $branchOne -Action help *> $null
                Enter-Agent1cLifecycleOperation -RequestedAction "run-dev-branch-tests"
                try {
                    $otherBranch = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $branchTwo,
                        "-Action", "start-vanessa-mcp"
                    )
                    $otherBranch.exitCode | Should -Be 1
                    $otherBranch.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $otherState = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $branchTwo ".agent-1c\locks\lifecycle-operation.json") | ConvertFrom-Json
                    $otherState.action | Should -Be "start-vanessa-mcp"
                    $otherState.status | Should -Be "failed"
                } finally {
                    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
                    Exit-Agent1cLifecycleOperation
                }
            }
        } finally {
            Remove-Item -LiteralPath $branchOne -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $branchTwo -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "locks branch and master in canonical order for refresh and exposes the same owner from master" {
        $mainRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-refresh-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = $mainRoot + "-branch"
        try {
            Initialize-LifecycleLockTestRepository -Path $mainRoot
            & git -C $mainRoot worktree add --quiet -b itldev/refresh $branchRoot *> $null

            & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $expected = @(@($branchRoot, $mainRoot) | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Sort-Object { $_.ToLowerInvariant() })
                $scopes = @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "refresh-dev-branch")
                $scopes | Should -Be $expected

                Enter-Agent1cLifecycleOperation -RequestedAction "refresh-dev-branch"
                try {
                    $masterConflict = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $mainRoot,
                        "-Action", "sync-master"
                    )
                    $masterConflict.exitCode | Should -Be 1
                    $masterConflict.combinedText | Should -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $masterConflict.combinedText | Should -Match "activeAction='refresh-dev-branch'"
                    $masterConflict.combinedText | Should -Match ([regex]::Escape((Join-Path $branchRoot ".agent-1c\locks\lifecycle-operation.json")))
                } finally {
                    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
                    Exit-Agent1cLifecycleOperation
                }

                Enter-Agent1cLifecycleOperation -RequestedAction "run-dev-branch-tests"
                try {
                    $masterStatus = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $mainRoot,
                        "-Action", "status"
                    )
                    $masterStatus.exitCode | Should -Be 0
                    $masterStatus.combinedText | Should -Match "action=refresh-dev-branch"
                    $masterStatus.combinedText | Should -Not -Match "action=run-dev-branch-tests"
                } finally {
                    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
                    Exit-Agent1cLifecycleOperation
                }
            }
        } finally {
            Remove-Item -LiteralPath $branchRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "continues an exact parent-owned operation without reacquiring its locks" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-continuation-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Enter-Agent1cLifecycleOperation -RequestedAction "start-vanessa-mcp"
                $operationId = $script:LifecycleOperationId
                try {
                    $continued = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $tempRoot,
                        "-Action", "start-vanessa-mcp",
                        "-OperationId", $operationId,
                        "-OperationOwnerPid", ([string]$PID),
                        "-OperationContinuation"
                    )
                    $continued.exitCode | Should -Be 1
                    $continued.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $continued.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONTINUATION_INVALID"
                    $record = Get-Content -Encoding UTF8 -Raw -LiteralPath $script:LifecycleOperationStatePath | ConvertFrom-Json
                    $record.operationId | Should -Be $operationId
                    $record.status | Should -Be "failed"
                    [int]$record.continuationPid | Should -BeGreaterThan 0
                } finally {
                    Exit-Agent1cLifecycleOperation
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects forged continuation arguments and treats unlocked running JSON as orphaned" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-orphan-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            $statePath = Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
            [ordered]@{
                schemaVersion = 1
                status = "running"
                operationId = "stale-operation"
                action = "run-dev-branch-tests"
                projectRoot = $tempRoot
                worktreePath = $tempRoot
                branch = "master"
                lockScopes = @($tempRoot)
                pid = 999999
                startedAt = (Get-Date).AddHours(-1).ToString("o")
                updatedAt = (Get-Date).AddHours(-1).ToString("o")
                phase = "vanessa.run"
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

            $status = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "status")
            $status.exitCode | Should -Be 0
            $status.combinedText | Should -Match "Lifecycle operation: orphaned"

            $forged = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                "-ProjectRoot", $tempRoot,
                "-Action", "start-vanessa-mcp",
                "-OperationId", "wrong-operation",
                "-OperationOwnerPid", "999999",
                "-OperationContinuation"
            )
            $forged.exitCode | Should -Be 1
            $forged.combinedText | Should -Match "LIFECYCLE_OPERATION_CONTINUATION_INVALID"

            $normal = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "start-vanessa-mcp")
            $normal.exitCode | Should -Be 1
            $normal.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONFLICT"
            $record = Get-Content -Encoding UTF8 -Raw -LiteralPath $statePath | ConvertFrom-Json
            $record.operationId | Should -Not -Be "stale-operation"
            $record.status | Should -Be "failed"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
