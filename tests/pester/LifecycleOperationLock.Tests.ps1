Describe "1C workflow lifecycle operation lock" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
        $HelperText = $context.HelperText
        # Existing exclusion tests explicitly exercise non-waiting admission.
        $originalLockTimeout = $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS
        $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = '0'

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

    AfterAll { $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = $originalLockTimeout }

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

    It "publishes native process evidence without waiting for a phase transition" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-evidence-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Enter-Agent1cLifecycleOperation -RequestedAction "check-dev-branch"
                try {
                    Update-Agent1cLifecycleOperationStage -Stage "config-load.designer" -Detail "Loading configuration."
                    $script:LastProcessId = 43210
                    $script:LastLogPath = Join-Path $tempRoot "logs\1c\designer.log"
                    $script:LastProcessWorkingSetLimitMb = 6144
                    Publish-Agent1cLifecycleOperationProcessEvidence

                    $record = Get-Content -Encoding UTF8 -Raw -LiteralPath $script:LifecycleOperationStatePath | ConvertFrom-Json
                    $record.status | Should -Be "running"
                    $record.phase | Should -Be "config-load.designer"
                    $record.detail | Should -Be "Loading configuration."
                    [int]$record.lastProcessId | Should -Be 43210
                    $record.lastLogPath | Should -Be $script:LastLogPath
                    [int]$record.lastProcessWorkingSetLimitMb | Should -Be 6144
                } finally {
                    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
                    Exit-Agent1cLifecycleOperation
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a second mutating action but keeps help and status observable" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-conflict-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Enter-Agent1cLifecycleOperation -RequestedAction "check-dev-branch"
                try {
                    $conflict = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $tempRoot,
                        "-Action", "check-dev-branch"
                    )
                    $conflict.exitCode | Should -Be 1
                    $conflict.combinedText | Should -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $conflict.combinedText | Should -Match "requestedAction='check-dev-branch'"
                    $conflict.combinedText | Should -Match "activeAction='check-dev-branch'"
                    $conflict.combinedText | Should -Match ([regex]::Escape($tempRoot))

                    $help = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "help")
                    $help.exitCode | Should -Be 0
                    $status = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "status")
                    $status.exitCode | Should -Be 0
                    $status.combinedText | Should -Match "Lifecycle operation: running"
                    $status.combinedText | Should -Match "action=check-dev-branch"
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
            $excludeText = Get-Content -LiteralPath (Join-Path $commonGitDirectory "info\exclude") -Raw -Encoding UTF8
            $excludeText | Should -Match ([regex]::Escape(".agent-1c/locks/"))
            $excludeText | Should -Match ([regex]::Escape(".agent-1c/runtime/"))
            $excludeText | Should -Match ([regex]::Escape(".agent-1c/event-log-cursors/"))
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
                Enter-Agent1cLifecycleOperation -RequestedAction "check-dev-branch"
                try {
                    $otherBranch = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $branchTwo,
                        "-Action", "check-dev-branch"
                    )
                    $otherBranch.exitCode | Should -Be 1
                    $otherBranch.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $otherState = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $branchTwo ".agent-1c\locks\lifecycle-operation.json") | ConvertFrom-Json
                    $otherState.action | Should -Be "check-dev-branch"
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

    It "shares reset source reads across processes while excluding writers and the same branch" {
        $tempRoot = Join-Path $TestDrive "parallel reset общий"
        $mainRoot = Join-Path $tempRoot "main база"
        $branchOne = Join-Path $tempRoot "ветка one"
        $branchTwo = Join-Path $tempRoot "ветка two"
        Initialize-LifecycleLockTestRepository -Path $mainRoot
        & git -C $mainRoot worktree add --quiet -b itldev/one $branchOne *> $null
        & git -C $mainRoot worktree add --quiet -b itldev/two $branchTwo master *> $null
        $worker = Join-Path $tempRoot "read source.ps1"
        Set-Content -LiteralPath $worker -Encoding UTF8 -Value @'
param([string]$HelperPath, [string]$Root)
. $HelperPath -ProjectRoot $Root -Action help *> $null
Enter-Agent1cLifecycleOperation -RequestedAction "reset-dev-branch"
try {
    Invoke-Agent1cMainWorktreeReadScope -TimeoutSeconds 1 -ScriptBlock { "READ_OK" }
    Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
} finally { Exit-Agent1cLifecycleOperation }
'@
        & {
            . $HelperPath -ProjectRoot $branchOne -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction "reset-dev-branch"
            try {
                @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "reset-dev-branch") | Should -Be @($branchOne)
                Invoke-Agent1cMainWorktreeReadScope -ScriptBlock {
                    $other = Invoke-TestPowerShellFile -FilePath $worker -Arguments @("-HelperPath", $HelperPath, "-Root", $branchTwo)
                    $other.exitCode | Should -Be 0 -Because $other.combinedText
                    $other.combinedText | Should -Match "READ_OK"
                    $same = Invoke-TestPowerShellFile -FilePath $worker -Arguments @("-HelperPath", $HelperPath, "-Root", $branchOne)
                    $same.exitCode | Should -Be 1
                    $same.combinedText | Should -Match "LIFECYCLE_OPERATION_CONFLICT"
                    $writer = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $mainRoot, "-Action", "sync-master")
                    $writer.exitCode | Should -Be 1
                    $writer.combinedText | Should -Match "LIFECYCLE_OPERATION_CONFLICT.*activeAction='reset-dev-branch'"
                }
                (Test-Agent1cLifecycleLockHeld -WorktreePath $mainRoot) | Should -BeFalse
                (Test-Agent1cLifecycleLockHeld -WorktreePath $branchOne) | Should -BeTrue
                { Invoke-Agent1cMainWorktreeReadScope -ScriptBlock { throw "READ_FAILED" } } | Should -Throw "*READ_FAILED*"
                (Test-Agent1cLifecycleLockHeld -WorktreePath $mainRoot) | Should -BeFalse
                @(Get-ChildItem -LiteralPath (Join-Path $mainRoot ".agent-1c/locks/lifecycle-readers") -Filter "*.json").Count | Should -Be 0
                # A writer also excludes readers (the sharing contract is symmetric).
                $writerLock = [IO.File]::Open((Get-Agent1cLifecycleLockPath -WorktreePath $mainRoot), 'Open', 'ReadWrite', 'Read')
                try {
                    { Invoke-Agent1cMainWorktreeReadScope -TimeoutSeconds 0 -ScriptBlock { throw "MUST_NOT_ENTER" } } | Should -Throw "*LIFECYCLE_OPERATION_CONFLICT*"
                } finally { $writerLock.Dispose() }
            } finally {
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
            }
        }
    }

    It "runs reset through <Scenario> with real worktree archives and seed leases" -ForEach @(
        @{ Scenario = "parallel branches" }, @{ Scenario = "interruption and resume" }, @{ Scenario = "updated helper handoff" }
    ) {
        $tempRoot = Join-Path $TestDrive ("сброс " + $Scenario)
        $mainRoot = Join-Path $tempRoot "main база"
        $branchOne = Join-Path $tempRoot "ветка one"
        $branchTwo = Join-Path $tempRoot "ветка two"
        $sourceRoot = Join-Path $tempRoot "source база"
        Initialize-LifecycleLockTestRepository -Path $mainRoot
        Add-Content -LiteralPath (Join-Path $mainRoot '.gitignore') -Value '.agent-1c/'
        & git -C $mainRoot add .gitignore
        & git -C $mainRoot commit --quiet -m 'ignore runtime'
        if ($Scenario -eq 'updated helper handoff') {
            $helperDirectory = Join-Path $mainRoot '.agents/skills/1c-workflow/scripts'
            $templateDirectory = Join-Path $mainRoot '.agents/skills/1c-workflow/assets/vanessa-service'
            New-Item -ItemType Directory -Path $helperDirectory,$templateDirectory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $helperDirectory 'agent-1c.ps1') -Encoding UTF8 -Value '# pinned master helper fixture'
            Set-Content -LiteralPath (Join-Path $templateDirectory 'manifest.json') -Encoding UTF8 -Value '{"template":"new"}'
            & git -C $mainRoot add .agents
            & git -C $mainRoot commit --quiet -m 'master service generation'
        }
        $masterCommit = (& git -C $mainRoot rev-parse HEAD).Trim()
        foreach ($entry in @(@{ name = 'one'; root = $branchOne }, @{ name = 'two'; root = $branchTwo })) {
            & git -C $mainRoot worktree add --quiet -b ('itldev/' + $entry.name) $entry.root master *> $null
            Set-Content -LiteralPath (Join-Path $entry.root 'изменение ветки.txt') -Encoding UTF8 -Value $entry.name
            if ($Scenario -eq 'updated helper handoff') {
                Set-Content -LiteralPath (Join-Path $entry.root '.agents/skills/1c-workflow/assets/vanessa-service/manifest.json') -Encoding UTF8 -Value '{"template":"old"}'
            }
            & git -C $entry.root add .
            & git -C $entry.root commit --quiet -m 'branch work'
        }
        New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $sourceRoot '1Cv8.1CD'), [byte[]](1, 2, 3, 4))
        New-TestBranchSeedFixture -ProjectRoot $mainRoot -SourceInfoBasePath $sourceRoot
        $worker = Join-Path $tempRoot 'reset worker.ps1'
        Set-Content -LiteralPath $worker -Encoding UTF8 -Value @'
param([string]$HelperPath, [string]$SupportPath, [string]$Root, [string]$SourceRoot,
    [string]$OtherRoot = "", [string]$InterruptPhase = "")
Import-Module Microsoft.PowerShell.Utility
. $SupportPath
. $HelperPath -ProjectRoot $Root -Action help *> $null
$fixtureStatePath = Join-Path $Root ".agent-1c/reset-fixture.json"
if (-not (Test-Path -LiteralPath $fixtureStatePath)) {
    $name = (Get-CurrentBranch).Substring(7)
    Write-Utf8Text -Path $fixtureStatePath -Value (([ordered]@{
        devBranchName = $name; safeDevBranchName = $name; devBranch = "itldev/$name"
        devBranchKind = "configuration"; initializationStatus = "ready"; infoBaseKind = "file"
        devBranchInfoBasePath = Join-Path $Root ".agent-1c/тестовая база"
    }) | ConvertTo-Json)
}
function Read-DevBranchState { Read-Utf8Text -Path $fixtureStatePath | ConvertFrom-Json }
function Update-DevBranchState {
    param($State, [hashtable]$Updates)
    $record = ConvertTo-Agent1cHashtable -Object $State
    foreach ($key in $Updates.Keys) { $record[$key] = $Updates[$key] }
    Write-Utf8Text -Path $fixtureStatePath -Value ($record | ConvertTo-Json -Depth 10)
}
function Get-SourceInfoBasePath { $SourceRoot }
function Get-InfoBaseKind { "file" }
function Get-SourceUsesRepository { $false }
function Assert-DevelopmentBranchWorktreeContext {}
function Assert-MasterWorktreeContext {}
function Resume-DevBranchLifecycleMergeIfPresent { $false }
function Save-DevBranchCheckpoint { Assert-CleanGit }
function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "test-fixture"; treeObjectId = "config-tree" } }
function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
function Invoke-Designer {
    param($InfoBasePath, $InfoBaseKind, $DesignerArgs)
    if ($DesignerArgs[0] -ne "/DumpIB") { throw "UNEXPECTED_DESIGNER" }
    Write-Utf8Text -Path $DesignerArgs[1] -Value "archived original infobase"
    Add-Content -LiteralPath (Join-Path $Root ".agent-1c/dumps.txt") -Value "dump"
}
function Initialize-DevBranchEventLogBaseline {
    param($State, $SeedBaselinePath)
    try { $writer = Open-BranchSeedLease -Mode write -TimeoutSeconds 1; $writer.Dispose(); throw "SEED_NOT_PROTECTED" }
    catch { if ($_.Exception.Message -notmatch "BRANCH_SEED_LEASE_TIMEOUT") { throw } }
    Copy-Item -LiteralPath $SeedBaselinePath -Destination (Join-Path $Root ".agent-1c/installed-baseline.json")
    $State
}
function Ensure-DevBranchEventLogPendingCursor {}
function Ensure-DevBranchEnterpriseNormalized {}
function Sync-AiRules1cManagedIgnoredFilesFromMain {
    if (-not (Test-Agent1cLifecycleLockHeld -WorktreePath (Get-MainWorktreePath))) { throw "MAIN_READ_NOT_PROTECTED" }
    # Acquiring the writer here also detects a retained seed lease / lock-order cycle.
    if ((Read-DevBranchState).devBranchName -ne "two") {
        $writer = Open-BranchSeedLease -Mode write -TimeoutSeconds 1
        $writer.Dispose()
    }
    Remove-Item -LiteralPath (Get-BranchSeedPaths).rebuildMarkerPath -Force -ErrorAction SilentlyContinue
}
function Invoke-DevBranchDefaultMcpSetup { param($State) $State }
function Sync-KiloItlCommandSurface {}
function Invoke-AiRules1cManagedMcpConfigReconcile {}
function Sync-DevBranchContextToDotEnv {}
function Write-AndSetRunUserReport {}
function Invoke-Agent1cFreshProcess {
    param([string]$ScriptPath)
    $state = Read-DevBranchState
    if ($state.resetPhase -ne 'git-reset-complete') { throw 'RESET_HANDOFF_PHASE_NOT_PINNED' }
    $writer = Open-BranchSeedLease -Mode write -TimeoutSeconds 1
    $writer.Dispose()
    Write-Utf8Text -Path (Join-Path $Root '.agent-1c/reset-handoff.json') -Value (([ordered]@{
        helperPath=$ScriptPath;masterCommit=$state.resetMasterCommit;archivePath=$state.resetArchivePath
        seedReaderReleased=$true;databaseRestored=(Test-Path -LiteralPath (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD'))
    }) | ConvertTo-Json)
    # Stop at dispatch so the test can inspect the saved boundary and start an
    # independent helper process against the same phase, archive and seed.
    throw 'RESET_HANDOFF_DISPATCHED'
}
function Set-RunStage {
    param($Stage, $Detail)
    Update-Agent1cLifecycleOperationStage -Stage $Stage -Detail $Detail
    if ($Stage -eq "reset.archive-dt") {
        if (Test-Agent1cLifecycleLockHeld -WorktreePath (Get-MainWorktreePath)) { throw "MAIN_LOCK_RETAINED_DURING_ARCHIVE" }
        if ($OtherRoot) {
            $nested = Invoke-TestPowerShellFile -FilePath $PSCommandPath -Arguments @(
                "-HelperPath", $HelperPath, "-SupportPath", $SupportPath, "-Root", $OtherRoot, "-SourceRoot", $SourceRoot)
            if ($nested.exitCode -ne 0) { throw "PARALLEL_RESET_FAILED: $($nested.combinedText)" }
        }
    }
    if ($InterruptPhase -and $Stage -eq $InterruptPhase) { throw "RESET_INTERRUPTED" }
    if ($Stage -eq "reset.infobase") {
        # A real seed writer publishes intent before waiting for existing readers.
        Write-Utf8Text -Path (Get-BranchSeedPaths).rebuildMarkerPath -Value "{}"
    }
}
Enter-Agent1cLifecycleOperation -RequestedAction "reset-dev-branch"
try {
    Reset-DevBranch
    Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
} catch {
    Complete-Agent1cLifecycleOperation -Status failed -ExitCode 1 -ErrorMessage $_.Exception.Message
    throw
} finally { Exit-Agent1cLifecycleOperation }
'@
        $arguments = @('-HelperPath', $HelperPath, '-SupportPath', (Join-Path $PSScriptRoot 'TestSupport.ps1'),
            '-Root', $branchOne, '-SourceRoot', $sourceRoot)
        if ($Scenario -eq 'parallel branches') {
            $run = Invoke-TestPowerShellFile -FilePath $worker -Arguments ($arguments + @('-OtherRoot', $branchTwo))
            $run.exitCode | Should -Be 0 -Because $run.combinedText
            $other = Get-Content -LiteralPath (Join-Path $branchTwo '.agent-1c/reset-fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $other.resetStatus | Should -Be 'complete'
        } elseif ($Scenario -eq 'updated helper handoff') {
            $handoff = Invoke-TestPowerShellFile -FilePath $worker -Arguments $arguments
            $handoff.exitCode | Should -Be 1
            $handoff.combinedText | Should -Match 'RESET_HANDOFF_DISPATCHED'
            $boundary = Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/reset-handoff.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $boundary.helperPath | Should -Be (Join-Path $branchOne '.agents/skills/1c-workflow/scripts/agent-1c.ps1')
            $boundary.masterCommit | Should -Be $masterCommit
            $boundary.seedReaderReleased | Should -BeTrue
            $boundary.databaseRestored | Should -BeFalse
            $resumed = Invoke-TestPowerShellFile -FilePath $worker -Arguments $arguments
            $resumed.exitCode | Should -Be 0 -Because $resumed.combinedText
            (Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/reset-fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json).resetArchivePath | Should -Be $boundary.archivePath
        } else {
            $failed = Invoke-TestPowerShellFile -FilePath $worker -Arguments ($arguments + @('-InterruptPhase', 'reset.infobase'))
            $failed.exitCode | Should -Be 1
            $failed.combinedText | Should -Match 'RESET_INTERRUPTED'
            $saved = Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/reset-fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved.resetPhase | Should -Be 'git-reset-complete'
            # Resume must retain the recorded master and archive even after master moves.
            Set-Content -LiteralPath (Join-Path $mainRoot 'new-master.txt') -Value 'later master'
            & git -C $mainRoot add .
            & git -C $mainRoot commit --quiet -m 'later master'
            $manifestPath = (Get-ChildItem -LiteralPath (Join-Path $mainRoot '.agent-1c/branch-seed') -Recurse -Filter manifest.json).FullName
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.configurationFingerprint = 'incompatible'
            $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            $incompatible = Invoke-TestPowerShellFile -FilePath $worker -Arguments $arguments
            $incompatible.exitCode | Should -Be 1
            $incompatible.combinedText | Should -Match 'BRANCH_SEED_INCOMPATIBLE'
            $manifest.configurationFingerprint = 'test-fixture'
            $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            $saved.resetSeedIdentity.syncId | Should -Be $manifest.syncId
            $saved.resetSeedIdentity.artifactSha256 | Should -Be $manifest.artifactSha256
            # Same configuration is insufficient: an independently rebuilt
            # seed may contain different data or a different event-log baseline.
            foreach ($drift in @('generation', 'database', 'baseline', 'archive', 'dirty source', 'committed source', 'missing pin')) {
                $artifactBytes = [IO.File]::ReadAllBytes($manifest.artifactPath)
                $baselineBytes = [IO.File]::ReadAllBytes($manifest.baselinePath)
                $archiveBytes = [IO.File]::ReadAllBytes($saved.resetArchiveDtPath)
                $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
                $statePath = Join-Path $branchOne '.agent-1c/reset-fixture.json'
                $stateBytes = [IO.File]::ReadAllBytes($statePath)
                $sourcePath = Join-Path $branchOne 'sentinel.txt'
                $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
                $head = (& git -C $branchOne rev-parse HEAD).Trim()
                try {
                    $expectedError = 'RESET_DEV_BRANCH_SEED_CHANGED'
                    switch ($drift) {
                        'generation' {
                            $changedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $changedManifest.syncId = 'later-generation-with-identical-configuration'
                            $changedManifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
                        }
                        'database' {
                            [IO.File]::WriteAllBytes($manifest.artifactPath, [byte[]](5,6,7,8))
                            $changedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $changedManifest.artifactSha256 = (Get-FileHash -LiteralPath $manifest.artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
                            $changedManifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
                        }
                        'baseline' { [IO.File]::WriteAllText($manifest.baselinePath, '{"signatures":["later"]}') }
                        'archive' {
                            [IO.File]::WriteAllText($saved.resetArchiveDtPath, 'damaged original archive')
                            $expectedError = 'DEV_BRANCH_ARCHIVE_DT_VERIFY_FAILED'
                        }
                        'dirty source' {
                            [IO.File]::WriteAllText($sourcePath, 'user changes after interruption')
                            $expectedError = 'Git worktree is not clean'
                        }
                        'committed source' {
                            [IO.File]::WriteAllText($sourcePath, 'committed user changes after interruption')
                            & git -C $branchOne add sentinel.txt
                            & git -C $branchOne commit --quiet -m 'user change after interrupted reset'
                            $expectedError = 'RESET_DEV_BRANCH_HEAD_CHANGED'
                        }
                        'missing pin' {
                            $changedState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $changedState.PSObject.Properties.Remove('resetSeedIdentity')
                            $changedState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8
                            $expectedError = 'RESET_DEV_BRANCH_SEED_IDENTITY_REQUIRED'
                        }
                    }
                    $rejected = Invoke-TestPowerShellFile -FilePath $worker -Arguments $arguments
                    $rejected.exitCode | Should -Be 1 -Because $rejected.combinedText
                    $rejected.combinedText | Should -Match $expectedError -Because $drift
                    Test-Path -LiteralPath (Join-Path $saved.devBranchInfoBasePath '1Cv8.1CD') | Should -BeFalse
                    @(Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/dumps.txt')).Count | Should -Be 1
                } finally {
                    [IO.File]::WriteAllBytes($manifest.artifactPath, $artifactBytes)
                    [IO.File]::WriteAllBytes($manifest.baselinePath, $baselineBytes)
                    [IO.File]::WriteAllBytes($saved.resetArchiveDtPath, $archiveBytes)
                    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
                    [IO.File]::WriteAllBytes($statePath, $stateBytes)
                    & git -C $branchOne reset --quiet --hard $head
                    [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
                }
            }
            $resumed = Invoke-TestPowerShellFile -FilePath $worker -Arguments $arguments
            $resumed.exitCode | Should -Be 0 -Because $resumed.combinedText
        }
        $state = Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/reset-fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.resetStatus | Should -Be 'complete'
        $state.resetMasterCommit | Should -Be $masterCommit
        (& git -C $branchOne rev-parse 'HEAD^{tree}').Trim() | Should -Be (& git -C $mainRoot rev-parse "$masterCommit`^{tree}").Trim()
        @(Get-Content -LiteralPath (Join-Path $branchOne '.agent-1c/dumps.txt')).Count | Should -Be 1
        [IO.File]::ReadAllBytes((Join-Path $state.devBranchInfoBasePath '1Cv8.1CD')) | Should -Be @([byte]1, [byte]2, [byte]3, [byte]4)
        Test-Path -LiteralPath (Join-Path $state.resetArchivePath 'files/изменение ветки.txt') | Should -BeTrue
        if ($Scenario -eq 'interruption and resume') { $state.resetArchivePath | Should -Be $saved.resetArchivePath }
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

                Enter-Agent1cLifecycleOperation -RequestedAction "check-dev-branch"
                try {
                    $masterStatus = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $mainRoot,
                        "-Action", "status"
                    )
                    $masterStatus.exitCode | Should -Be 0
                    $masterStatus.combinedText | Should -Match "action=refresh-dev-branch"
                    $masterStatus.combinedText | Should -Not -Match "action=check-dev-branch"
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
                Enter-Agent1cLifecycleOperation -RequestedAction "check-dev-branch"
                $operationId = $script:LifecycleOperationId
                try {
                    $script:LastProcessId = 54321
                    $script:LastLogPath = Join-Path $tempRoot "logs\1c\designer.log"
                    $script:LastProcessPeakWorkingSetMb = 512
                    $script:LastProcessWorkingSetLimitMb = 6144
                    Publish-Agent1cLifecycleOperationProcessEvidence
                    $continued = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                        "-ProjectRoot", $tempRoot,
                        "-Action", "check-dev-branch",
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
                    [int]$record.lastProcessId | Should -Be 54321
                    $record.lastLogPath | Should -Be $script:LastLogPath
                    [int]$record.lastProcessPeakWorkingSetMb | Should -Be 512
                    [int]$record.lastProcessWorkingSetLimitMb | Should -Be 6144
                } finally {
                    Exit-Agent1cLifecycleOperation
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes terminal run status when a fresh child rejects <Case> before entering its body" -ForEach @(
        @{Case='argument binding'}, @{Case='database ownership protocol'}
    ) {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Передача старому helper " + [guid]::NewGuid().ToString("N"))
        $childPath = Join-Path $tempRoot "invalid-child.ps1"
        $wrapperPath = Join-Path $tempRoot "invoke-parent.ps1"
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "console.log"
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            Set-Content -LiteralPath $childPath -Encoding UTF8 -Value @'
[CmdletBinding()]
param(
    [string]$Action,
    [string]$ProjectRoot,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [ValidateSet("accepted")][string]$LifecyclePhase,
    [string]$OperationId,
    [int]$OperationOwnerPid,
    [switch]$OperationContinuation
)
Write-Output "CHILD_BODY_MUST_NOT_RUN"
exit 0
'@
            Set-Content -LiteralPath $wrapperPath -Encoding UTF8 -Value @'
param(
    [string]$HelperPath,
    [string]$ProjectRoot,
    [string]$ChildPath,
    [string]$StatusPath,
    [string]$LogPath,
    [string]$Case
)
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
$Action = "check-dev-branch"
$RunStatusPath = $StatusPath
$RunLogPath = $LogPath
$script:RunStartedAt = Get-Date
$script:Agent1cReexecArguments = @(
    "-Action", $Action,
    "-ProjectRoot", $ProjectRoot,
    "-RunStatusPath", $RunStatusPath,
    "-RunLogPath", $RunLogPath
)
if ($Case -eq 'database ownership protocol') {
    $base = [pscustomobject]@{kind='file';path=(Join-Path $ProjectRoot 'Общая база')}
    $preparation = [pscustomobject]@{operation=$Action;plan=[pscustomobject]@{target=$base;bases=@($base)}
        settings=[pscustomobject]@{coordinator=(Join-Path $ProjectRoot 'Очередь');python=(Get-Command python -CommandType Application | Select-Object -First 1).Source;waitTimeoutSeconds=0}}
    $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $Action -Preparation $preparation
}
Enter-Agent1cLifecycleOperation -RequestedAction $Action
try {
    $phase = if ($Case -eq 'database ownership protocol') { 'accepted' } else { 'rejected' }
    Invoke-Agent1cFreshProcess -ScriptPath $ChildPath -AdditionalArguments @("-LifecyclePhase", $phase)
} finally {
    try { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission }
    finally { Exit-Agent1cLifecycleOperation }
}
'@

            # Windows PowerShell reads script literals through the ANSI code
            # page without a BOM, even when the fixture writer is PowerShell 7.
            foreach ($fixtureScript in @($childPath, $wrapperPath)) {
                [IO.File]::WriteAllText($fixtureScript, [IO.File]::ReadAllText($fixtureScript), [Text.UTF8Encoding]::new($true))
            }
            $result = Invoke-TestPowerShellFile -FilePath $wrapperPath -Arguments @(
                "-HelperPath", $HelperPath,
                "-ProjectRoot", $tempRoot,
                "-ChildPath", $childPath,
                "-StatusPath", $statusPath,
                "-LogPath", $logPath,
                "-Case", $Case
            )

            $result.exitCode | Should -Be 1
            $result.combinedText | Should -Match "LIFECYCLE_OPERATION_CONTINUATION_INVALID"
            $result.combinedText | Should -Match "childExitCode='1'"
            $result.combinedText | Should -Match ([regex]::Escape($childPath))
            $result.combinedText | Should -Not -Match "CHILD_BODY_MUST_NOT_RUN"
            if ($Case -eq 'database ownership protocol') {
                $result.combinedText | Should -Match 'DatabaseContinuationProtocol'
                $ticket = Get-ChildItem -LiteralPath (Join-Path $tempRoot 'Очередь/tickets') -Filter '*.json' |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
                $ticket.status | Should -Be 'released'
                @($ticket.nativeJournal.producers.PSObject.Properties) | Should -HaveCount 1
            }

            $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.status | Should -Be "failed"
            [int]$status.exitCode | Should -Be 1
            $status.stage | Should -Be "reexec"
            $status.errorCategory | Should -Be "runner"
            $status.finishedAt | Should -Not -BeNullOrEmpty
            $status.errorMessage | Should -Match "fresh process did not write terminal operation state"

            $lifecyclePath = Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json"
            $lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lifecycle.status | Should -Be "failed"
            [int]$lifecycle.exitCode | Should -Be 1
            $lifecycle.errorMessage | Should -Match "fresh process did not write terminal operation state"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "preserves the exact child failure status across fresh-process stderr" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-child-failure-" + [guid]::NewGuid().ToString("N"))
        $childPath = Join-Path $tempRoot "failing-child.ps1"
        $wrapperPath = Join-Path $tempRoot "invoke-parent.ps1"
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "console.log"
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            Set-Content -LiteralPath $childPath -Encoding UTF8 -Value @'
param([string]$Action, [string]$ProjectRoot, [string]$RunStatusPath, [string]$RunLogPath, [string]$LifecyclePhase, [string]$OperationId, [int]$OperationOwnerPid, [switch]$OperationContinuation)
$message = "REFRESH_TRACKED_STATE_UNEXPECTED: refresh changed tracked files other than the branch synchronization cursor: .kilo/kilo.json"
$lifecyclePath = Join-Path $ProjectRoot ".agent-1c\locks\lifecycle-operation.json"
$record = Get-Content -LiteralPath $lifecyclePath -Raw -Encoding UTF8 | ConvertFrom-Json
$now = (Get-Date).ToString("o")
$record | Add-Member -NotePropertyName status -NotePropertyValue "failed" -Force; $record | Add-Member -NotePropertyName phase -NotePropertyValue "refresh.load" -Force
$record | Add-Member -NotePropertyName detail -NotePropertyValue $message -Force; $record | Add-Member -NotePropertyName errorMessage -NotePropertyValue $message -Force
$record | Add-Member -NotePropertyName exitCode -NotePropertyValue 1 -Force; $record | Add-Member -NotePropertyName updatedAt -NotePropertyValue $now -Force
$record | Add-Member -NotePropertyName finishedAt -NotePropertyValue $now -Force; $record | Add-Member -NotePropertyName continuationPid -NotePropertyValue $PID -Force
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $lifecyclePath -Encoding UTF8
[ordered]@{ schemaVersion=1; status="failed"; action=$Action; stage="refresh.load"; stageDetail="tracked state validation"; errorMessage=$message; errorCategory="runner"; requiredAction=""; exitCode=1; finishedAt=$now } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RunStatusPath -Encoding UTF8
[Console]::Error.WriteLine("ITL failure: status=failed; errorCategory=runner; requiredAction=none; completion=failed.")
[Console]::Error.WriteLine($message)
exit 1
'@
            Set-Content -LiteralPath $wrapperPath -Encoding UTF8 -Value @'
param([string]$HelperPath, [string]$ProjectRoot, [string]$ChildPath, [string]$StatusPath, [string]$LogPath)
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
$Action = "refresh-dev-branch"
$RunStatusPath = $StatusPath; $RunLogPath = $LogPath
$script:ResolvedRunStatusPath = $StatusPath; $script:ResolvedRunLogPath = $LogPath
$script:RunStartedAt = Get-Date
$script:Agent1cReexecArguments = @("-Action", $Action, "-ProjectRoot", $ProjectRoot, "-RunStatusPath", $RunStatusPath, "-RunLogPath", $RunLogPath)
Enter-Agent1cLifecycleOperation -RequestedAction $Action
try {
    Invoke-Agent1cFreshProcess -ScriptPath $ChildPath -AdditionalArguments @("-LifecyclePhase", "post-merge")
} catch {
    $errorMessage = $_.Exception.Message
    Set-RunFailureContextFromMessage -Message $errorMessage -RequestedAction $Action
    Complete-Agent1cLifecycleOperation -Status "failed" -ExitCode 1 -ErrorMessage $errorMessage
    Write-RunStatus -Status "failed" -ExitCode 1 -ErrorMessage $errorMessage
    exit 1
} finally {
    Exit-Agent1cLifecycleOperation
}
'@
            $result = Invoke-TestPowerShellFile -FilePath $wrapperPath -Arguments @("-HelperPath", $HelperPath, "-ProjectRoot", $tempRoot, "-ChildPath", $childPath, "-StatusPath", $statusPath, "-LogPath", $logPath)
            $result.exitCode | Should -Be 1
            $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.status | Should -Be "failed"; $status.stage | Should -Be "refresh.load"
            $status.errorCategory | Should -Be "runner"; $status.requiredAction | Should -BeNullOrEmpty
            $status.errorMessage | Should -Be "REFRESH_TRACKED_STATE_UNEXPECTED: refresh changed tracked files other than the branch synchronization cursor: .kilo/kilo.json"
            $lifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lifecycle.status | Should -Be "failed"; $lifecycle.phase | Should -Be "refresh.load"; $lifecycle.errorMessage | Should -Be $status.errorMessage
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects forged continuation arguments and treats unlocked running JSON as orphaned" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lifecycle-lock-orphan-" + [guid]::NewGuid().ToString("N"))
        try {
            Initialize-LifecycleLockTestRepository -Path $tempRoot
            $statePath = Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json"
            $staleOperationId = [guid]::NewGuid().ToString("N")
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
            [ordered]@{
                schemaVersion = 1
                status = "running"
                operationId = $staleOperationId
                action = "check-dev-branch"
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
                "-Action", "check-dev-branch",
                "-OperationId", "wrong-operation",
                "-OperationOwnerPid", "999999",
                "-OperationContinuation"
            )
            $forged.exitCode | Should -Be 1
            $forged.combinedText | Should -Match "LIFECYCLE_OPERATION_CONTINUATION_INVALID"

            $normal = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "check-dev-branch")
            $normal.exitCode | Should -Be 1
            $normal.combinedText | Should -Not -Match "LIFECYCLE_OPERATION_CONFLICT"
            $record = Get-Content -Encoding UTF8 -Raw -LiteralPath $statePath | ConvertFrom-Json
            $record.operationId | Should -Not -Be $staleOperationId
            $record.status | Should -Be "failed"
            $record.recoveredOperationId | Should -Be $staleOperationId
            $archivePath = [string]$record.recoveredOperationArchivePath
            Test-Path -LiteralPath $archivePath -PathType Leaf | Should -BeTrue
            $archive = Get-Content -Encoding UTF8 -Raw -LiteralPath $archivePath | ConvertFrom-Json
            $archive.operationId | Should -Be $staleOperationId
            $archive.status | Should -Be "failed"
            $archive.phase | Should -Be "orphaned"
            $archive.errorCode | Should -Be "LIFECYCLE_OPERATION_ORPHANED"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
