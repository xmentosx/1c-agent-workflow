BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:repoRoot 'scripts/git-path-list.ps1')
    . (Join-Path $script:repoRoot 'scripts/release-e2e/extension-recovery.ps1')

    function Write-RecoveryFixtureFile {
        param([string]$Path, [string]$Text)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    }
    function Write-RecoveryFixtureJson {
        param([string]$Path, [object]$Value)
        Write-RecoveryFixtureFile $Path ($Value | ConvertTo-Json -Depth 30)
    }
    function New-RecoveryFixture {
        param([string]$Root)
        $main = Join-Path $Root 'Основной проект'
        $branch = Join-Path $Root 'Ветка восстановления'
        [IO.Directory]::CreateDirectory($main) | Out-Null
        Invoke-RepositoryGit $main @('init', '-b', 'master') | Out-Null
        Invoke-RepositoryGit $main @('config', 'user.name', 'Recovery fixture') | Out-Null
        Invoke-RepositoryGit $main @('config', 'user.email', 'recovery@example.invalid') | Out-Null
        Write-RecoveryFixtureFile (Join-Path $main '.gitignore') ".agent-1c/`n.dev.env`n"
        Write-RecoveryFixtureFile (Join-Path $main 'business.txt') 'unrelated committed business bytes'
        Invoke-RepositoryGit $main @('add', '--', '.gitignore', 'business.txt') | Out-Null
        Invoke-RepositoryGit $main @('commit', '-m', 'Fixture baseline') | Out-Null
        Invoke-RepositoryGit $main @('worktree', 'add', '-b', 'itldev/recovery', $branch) | Out-Null
        $runRoot = Join-Path $branch '.agent-1c/runs/release-e2e/recovery'
        $statePath = Join-Path $branch '.agent-1c/dev-branches/recovery.json'
        $envPath = Join-Path $branch '.dev.env'
        $target = Join-Path $branch '.agent-1c/infobases/База проверки'
        $savedState = Join-Path $runRoot 'state/post-config.json'
        $savedEnv = Join-Path $runRoot 'state/post-config.env'
        $snapshot = Join-Path $runRoot 'snapshots/post-config.dt'
        Write-RecoveryFixtureJson $savedState @{ devBranchKind = 'configuration'; devBranchInfoBasePath = $target; business = 'must retain saved state' }
        Write-RecoveryFixtureFile $savedEnv "FOREIGN_VARIABLE=Кириллица и пробел`r`n"
        Write-RecoveryFixtureFile $snapshot 'Synthetic DT unit boundary; never used as native evidence'
        Write-RecoveryFixtureJson $statePath @{ devBranchKind = 'extension'; devBranchInfoBasePath = $target; extensionInitializationStatus = 'running' }
        Write-RecoveryFixtureFile $envPath "FOREIGN_VARIABLE=Кириллица и пробел`r`nITL_ACTIVE_CONTEXT_UPDATED_AT=owned original`r`n"
        $context = [ordered]@{ projectRoot = $main; worktreePath = $branch; commonGitPath = (Get-RepositoryCommonGitDirectory $main);
            branch = 'itldev/recovery'; expectedHead = (Invoke-RepositoryGit $branch @('rev-parse', 'HEAD')).stdout.Trim();
            checkpointPath = (Join-Path $runRoot 'checkpoint.json'); runId = 'original-failed-run'; infoBaseKind = 'file'; infoBasePath = $target }
        $identity = [ordered]@{ projectRoot = $main; worktreePath = $branch; branch = $context.branch; workflowCommit = ('a' * 40); workflowTree = ('b' * 40);
            runnerSha256 = ('c' * 64); aiRulesCommit = ('d' * 40); aiRulesTree = ('e' * 40); helperSha256 = ('f' * 64); projectConfigSha256 = ('1' * 64); clientSelection = 'explicit fixture client' }
        $checkpoint = [ordered]@{ schemaVersion = 3; runId = $context.runId; identity = $identity; expectedHead = $context.expectedHead;
            stages = @{ 'extension-smoke' = @{ status = 'failed'; error = 'original child timeout' } };
            snapshots = @{ postConfig = @{ path = $snapshot; sha256 = (Get-ReleaseExtensionRecoveryFile $snapshot).sha256 } };
            stateFiles = @{ postConfig = @{ actualStatePath = $statePath; actualEnvPath = $envPath; stateCopyPath = $savedState;
                stateSha256 = (Get-ReleaseExtensionRecoveryFile $savedState).sha256; envCopyPath = $savedEnv; envSha256 = (Get-ReleaseExtensionRecoveryFile $savedEnv).sha256 } } }
        Write-RecoveryFixtureJson $context.checkpointPath $checkpoint
        # Closed process metadata is a fixture of the owner-observation boundary;
        # no native process, DT restore, or Release qualification is claimed here.
        $invocation = @{ childProcessId = 12345; childStartedAtUtc = '2026-10-07T00:00:00.0000000Z' }
        $observationPath = Join-Path $runRoot 'closed-process-observation.json'
        $observation = [ordered]@{ runId = $context.runId; projectRoot = $main; worktreePath = $branch; branch = $context.branch;
            infoBaseKind = 'file'; infoBasePath = $target; action = 'release-e2e-extension-smoke'; childProcessId = $invocation.childProcessId;
            childStartedAtUtc = $invocation.childStartedAtUtc; launcherExited = $true; nativeQuiescent = $true }
        Write-RecoveryFixtureJson $observationPath $observation
        $stop = [ordered]@{}
        foreach ($name in $observation.Keys) { $stop[$name] = $observation[$name] }
        $stop.evidencePath = $observationPath
        $stop.evidenceSha256 = (Get-ReleaseExtensionRecoveryFile $observationPath).sha256
        return @{ context = $context; checkpoint = $checkpoint; invocation = $invocation; stop = $stop; observationPath = $observationPath;
            restoreCalls = 0; restoredSnapshots = @(); archive = (Join-Path $branch '.agent-1c/recovery-archives/original-failed-run');
            extensionName = 'ITLReleaseSmokeПроверка'; paths = @('src/cfe/ITLReleaseSmokeПроверка/Configuration.xml', 'src/cfe/ITLReleaseSmokeПроверка/CommonModules/Модуль/Ext/Module.bsl') }
    }
    function Get-RecoveryFixtureCompatibility {
        return {
            param($Context, $Checkpoint, $Ownership)
            if ($Checkpoint.identity.workflowCommit -cne ('a' * 40)) { throw 'existing source continuation rejected' }
        }
    }
    function Get-RecoveryFixtureStop {
        return { param($Context, $Ownership) $script:fixture.stop }
    }
    function Get-RecoveryFixtureRestore {
        return {
            param($Snapshot, $StateFiles)
            $script:fixture.restoreCalls++
            $script:fixture.restoredSnapshots += $Snapshot.sha256
            Copy-Item -LiteralPath $StateFiles.stateCopyPath -Destination $StateFiles.actualStatePath -Force
            Copy-Item -LiteralPath $StateFiles.envCopyPath -Destination $StateFiles.actualEnvPath -Force
            # Existing owner records only its own stopped restoration writes.
            $script:fixture.ownership.runtimeFiles = Get-ReleaseExtensionRecoveryRuntimeFiles $script:fixture.checkpoint $script:fixture.context
        }
    }
    function Set-RecoveryFixtureSealed {
        param([int]$CreatedFiles = 2)
        $script:fixture.ownership = New-ReleaseExtensionRecoveryOwnership -Checkpoint $script:fixture.checkpoint -Context $script:fixture.context -ExtensionName $script:fixture.extensionName -WriteSet $script:fixture.paths -AssertCompatibility (Get-RecoveryFixtureCompatibility)
        $script:fixture.ownership.invocation = $script:fixture.invocation
        for ($index = 0; $index -lt $CreatedFiles; $index++) { Write-RecoveryFixtureFile (Join-Path $script:fixture.context.worktreePath $script:fixture.paths[$index]) "original generated bytes $index Кириллица`r`n" }
        $script:fixture.ownership = Complete-ReleaseExtensionRecoveryOwnership -Ownership $script:fixture.ownership -Checkpoint $script:fixture.checkpoint -Context $script:fixture.context -GetStopEvidence (Get-RecoveryFixtureStop) -AssertCompatibility (Get-RecoveryFixtureCompatibility)
    }
    function Invoke-RecoveryFixture {
        Invoke-ReleaseExtensionRecovery -Checkpoint $script:fixture.checkpoint -Context $script:fixture.context -Ownership $script:fixture.ownership -ArchiveRoot $script:fixture.archive -GetStopEvidence (Get-RecoveryFixtureStop) -AssertCompatibility (Get-RecoveryFixtureCompatibility) -RestoreSnapshot (Get-RecoveryFixtureRestore)
    }
    function Set-RecoveryFixtureApprovedLegacy {
        $manifestPath = Join-Path $TestDrive 'Согласованный legacy manifest.json'
        $manifest = @{ stand = $script:fixture.context.worktreePath; expectedBranch = $script:fixture.context.branch; expectedHead = $script:fixture.context.expectedHead;
            residue = $script:fixture.ownership.residuePath; checkpoint = $script:fixture.context.checkpointPath;
            postConfigSnapshotSha256 = $script:fixture.ownership.support.snapshot.sha256; postConfigStateSha256 = $script:fixture.ownership.support.state.sha256;
            postConfigEnvSha256 = $script:fixture.ownership.support.env.sha256; files = $script:fixture.ownership.files }
        Write-RecoveryFixtureJson $manifestPath $manifest
        $script:fixture.ownership = Resolve-ReleaseExtensionRecoveryOwnership -Checkpoint $script:fixture.checkpoint -Context $script:fixture.context -Invocation $script:fixture.invocation `
            -ApprovedLegacyManifestPath $manifestPath -ApprovedLegacyManifestSha256 (Get-ReleaseExtensionRecoveryFile $manifestPath).sha256 -AssertCompatibility (Get-RecoveryFixtureCompatibility)
    }
    function Set-RecoveryFixtureLegacyStop {
        $operationPath = Join-Path $script:fixture.context.worktreePath '.agent-1c/locks/lifecycle-operation-orphaned.json'
        $operation = @{ status = 'failed'; action = 'release-e2e-extension-smoke'; projectRoot = $script:fixture.context.worktreePath; branch = $script:fixture.context.branch;
            pid = 12345; startedAt = '2026-10-07T03:00:00.0000000+03:00'; finishedAt = '2026-10-07T03:15:00.0000000+03:00' }
        Write-RecoveryFixtureJson $operationPath $operation
        $script:fixture.ownership.invocation = @{ childProcessId = $operation.pid; processCreationUnavailable = $true;
            legacyOperationRecordPath = $operationPath; legacyOperationRecordSha256 = (Get-ReleaseExtensionRecoveryFile $operationPath).sha256;
            operationStartedAt = $operation.startedAt; operationFinishedAt = $operation.finishedAt }
        $script:fixture.stop.Remove('childStartedAtUtc')
        foreach ($name in $script:fixture.ownership.invocation.Keys) { $script:fixture.stop[$name] = $script:fixture.ownership.invocation[$name] }
        $raw = [ordered]@{}
        foreach ($name in $script:fixture.stop.Keys) { if ($name -notin @('evidencePath', 'evidenceSha256')) { $raw[$name] = $script:fixture.stop[$name] } }
        Write-RecoveryFixtureJson $script:fixture.observationPath $raw
        $script:fixture.stop.evidenceSha256 = (Get-ReleaseExtensionRecoveryFile $script:fixture.observationPath).sha256
    }
}

Describe 'Release extension interrupted ownership recovery' {
    BeforeEach {
        $script:fixture = New-RecoveryFixture (Join-Path $TestDrive ('Проект с пробелом ' + [guid]::NewGuid().ToString('N')))
    }

    It 'predeclares absent exact paths before child invocation is known and seals only stopped generated bytes' {
        $owned = New-ReleaseExtensionRecoveryOwnership -Checkpoint $fixture.checkpoint -Context $fixture.context -ExtensionName $fixture.extensionName -WriteSet $fixture.paths -AssertCompatibility (Get-RecoveryFixtureCompatibility)
        $owned.status | Should -Be 'declared'
        $owned.invocation | Should -BeNullOrEmpty
        $owned.writeSet.Count | Should -Be 2
        $owned.invocation = $fixture.invocation
        Write-RecoveryFixtureFile (Join-Path $fixture.context.worktreePath $fixture.paths[0]) 'one created file'
        $sealed = Complete-ReleaseExtensionRecoveryOwnership $owned $fixture.checkpoint $fixture.context (Get-RecoveryFixtureStop) (Get-RecoveryFixtureCompatibility)
        $sealed.files.Count | Should -Be 1
        $sealed.files[0].sha256 | Should -Be (Get-ReleaseExtensionRecoveryFile (Join-Path $fixture.context.worktreePath $fixture.paths[0])).sha256
    }

    It 'restores the same DT and quarantines exact dirty bytes outside the evicted Release root' {
        Set-RecoveryFixtureSealed
        $result = Invoke-RecoveryFixture
        $fixture.restoreCalls | Should -Be 1
        $fixture.restoredSnapshots[0] | Should -Be $fixture.checkpoint.snapshots.postConfig.sha256
        $result.status | Should -Be 'recovered'
        $result.stageStatus | Should -Be 'failed'
        $result.Keys | Should -Not -Contain 'passed'
        @(Get-RepositoryGitPathList $fixture.context.worktreePath @('status', '--porcelain=v1', '--untracked-files=all', '-z')).Count | Should -Be 0
        foreach ($file in $fixture.ownership.files) {
            Test-Path -LiteralPath (Join-Path $fixture.context.worktreePath $file.path) | Should -BeFalse
            (Get-ReleaseExtensionRecoveryFile (Join-Path $fixture.archive $file.path)).sha256 | Should -Be $file.sha256
        }
        Test-Path -LiteralPath (Split-Path $fixture.context.checkpointPath -Parent) | Should -BeTrue
    }

    It 'restores when only <CreatedFiles> declared files were created without inventing additional ownership' -ForEach @(@{ CreatedFiles = 0 }, @{ CreatedFiles = 1 }) {
        Set-RecoveryFixtureSealed -CreatedFiles $CreatedFiles
        $result = Invoke-RecoveryFixture
        $fixture.restoreCalls | Should -Be 1
        @($result.archivedFiles).Count | Should -Be $CreatedFiles
        $result.stageStatus | Should -Be 'failed'
    }

    It 'refuses foreign file or changed owned bytes before restoring and preserves them: <Mutation>' -ForEach @(@{ Mutation = 'foreign' }, @{ Mutation = 'edit' }, @{ Mutation = 'foreign-business' }) {
        Set-RecoveryFixtureSealed
        $path = switch ($Mutation) {
            'foreign' { Join-Path $fixture.context.worktreePath ('src/cfe/' + $fixture.extensionName + '/Чужой файл.txt') }
            'edit' { Join-Path $fixture.context.worktreePath $fixture.paths[0] }
            'foreign-business' { Join-Path $fixture.context.worktreePath 'business.txt' }
        }
        Write-RecoveryFixtureFile $path 'foreign bytes must survive'
        $sha = (Get-ReleaseExtensionRecoveryFile $path).sha256
        { Invoke-RecoveryFixture } | Should -Throw '*RELEASE_EXTENSION_RECOVERY_REJECTED*'
        $fixture.restoreCalls | Should -Be 0
        (Get-ReleaseExtensionRecoveryFile $path).sha256 | Should -Be $sha
        Test-Path -LiteralPath $fixture.archive | Should -BeFalse
    }

    It 'refuses <Mutation> binding drift before any restoration' -ForEach @(
        @{ Mutation = 'snapshot' }, @{ Mutation = 'saved-state' }, @{ Mutation = 'saved-env' }, @{ Mutation = 'current-state' }, @{ Mutation = 'current-env' },
        @{ Mutation = 'target' }, @{ Mutation = 'head' }, @{ Mutation = 'common-git' }, @{ Mutation = 'helper' }, @{ Mutation = 'child' }, @{ Mutation = 'native-active' }, @{ Mutation = 'raw-stop' }, @{ Mutation = 'archive-in-run' }
    ) {
        Set-RecoveryFixtureSealed
        switch ($Mutation) {
            'snapshot' { Write-RecoveryFixtureFile $fixture.checkpoint.snapshots.postConfig.path 'changed DT' }
            'saved-state' { Write-RecoveryFixtureFile $fixture.checkpoint.stateFiles.postConfig.stateCopyPath '{}' }
            'saved-env' { Write-RecoveryFixtureFile $fixture.checkpoint.stateFiles.postConfig.envCopyPath 'changed support env' }
            'current-state' { Add-Content -LiteralPath $fixture.checkpoint.stateFiles.postConfig.actualStatePath -Value ' ' }
            'current-env' { Write-RecoveryFixtureFile $fixture.checkpoint.stateFiles.postConfig.actualEnvPath 'foreign env edit' }
            'target' { $fixture.context.infoBasePath = Join-Path $TestDrive 'Другая база' }
            'head' { Invoke-RepositoryGit $fixture.context.worktreePath @('commit', '--allow-empty', '-m', 'foreign new head') | Out-Null }
            'common-git' { $fixture.context.commonGitPath = Join-Path $TestDrive 'foreign-git' }
            'helper' { $fixture.checkpoint.identity.helperSha256 = '2' * 64 }
            'child' { $fixture.stop.childProcessId = 54321 }
            'native-active' { $fixture.stop.nativeQuiescent = $false }
            'raw-stop' { Write-RecoveryFixtureFile $fixture.observationPath '{}' }
            'archive-in-run' { $fixture.archive = Join-Path (Split-Path $fixture.context.checkpointPath -Parent) 'archive' }
        }
        { Invoke-RecoveryFixture } | Should -Throw '*RELEASE_EXTENSION_RECOVERY_REJECTED*'
        $fixture.restoreCalls | Should -Be 0
        foreach ($file in $fixture.ownership.files) { (Get-ReleaseExtensionRecoveryFile (Join-Path $fixture.context.worktreePath $file.path)).sha256 | Should -Be $file.sha256 }
    }

    It 'rejects legacy residue without both explicit approved arguments' {
        Set-RecoveryFixtureSealed
        { Resolve-ReleaseExtensionRecoveryOwnership -Checkpoint $fixture.checkpoint -Context $fixture.context -Invocation $fixture.invocation -AssertCompatibility (Get-RecoveryFixtureCompatibility) } | Should -Throw '*no explicit approved manifest and SHA*'
        $fixture.restoreCalls | Should -Be 0
    }

    It 'uses an exact approved legacy manifest while preserving the original failed verdict' {
        Set-RecoveryFixtureSealed
        $manifestPath = Join-Path $TestDrive 'Согласованный старый остаток.json'
        $manifest = @{ stand = $fixture.context.worktreePath; expectedBranch = $fixture.context.branch; expectedHead = $fixture.context.expectedHead;
            residue = $fixture.ownership.residuePath; checkpoint = $fixture.context.checkpointPath; postConfigSnapshotSha256 = $fixture.ownership.support.snapshot.sha256;
            postConfigStateSha256 = $fixture.ownership.support.state.sha256; postConfigEnvSha256 = $fixture.ownership.support.env.sha256; files = $fixture.ownership.files }
        Write-RecoveryFixtureJson $manifestPath $manifest
        $sha = (Get-ReleaseExtensionRecoveryFile $manifestPath).sha256
        $fixture.ownership = Resolve-ReleaseExtensionRecoveryOwnership -Checkpoint $fixture.checkpoint -Context $fixture.context -Invocation $fixture.invocation -ApprovedLegacyManifestPath $manifestPath -ApprovedLegacyManifestSha256 $sha -AssertCompatibility (Get-RecoveryFixtureCompatibility)
        $result = Invoke-RecoveryFixture
        $result.stageStatus | Should -Be 'failed'
        $fixture.ownership.approvedLegacyManifest.sha256 | Should -Be $sha
        $fixture.restoreCalls | Should -Be 1
    }

    It 'preserves residue after interrupted restore and permits only the same verified DT replay with owner-captured writes' {
        Set-RecoveryFixtureSealed
        $sha = $fixture.checkpoint.snapshots.postConfig.sha256
        $lostAck = {
            param($Snapshot, $StateFiles)
            & (Get-RecoveryFixtureRestore) $Snapshot $StateFiles
            throw 'existing restored helper lost acknowledgement after confirmed stop'
        }
        { Invoke-ReleaseExtensionRecovery -Checkpoint $fixture.checkpoint -Context $fixture.context -Ownership $fixture.ownership -ArchiveRoot $fixture.archive -GetStopEvidence (Get-RecoveryFixtureStop) -AssertCompatibility (Get-RecoveryFixtureCompatibility) -RestoreSnapshot $lostAck } | Should -Throw '*lost acknowledgement*'
        Test-Path -LiteralPath $fixture.archive | Should -BeFalse
        foreach ($file in $fixture.ownership.files) { Test-Path -LiteralPath (Join-Path $fixture.context.worktreePath $file.path) | Should -BeTrue }
        $result = Invoke-RecoveryFixture
        $fixture.restoreCalls | Should -Be 2
        @($fixture.restoredSnapshots | Where-Object { $_ -cne $sha }).Count | Should -Be 0
        $result.stageStatus | Should -Be 'failed'
    }

    It 'rejects a foreign edit after an interrupted restore despite owner-captured retry hashes' {
        Set-RecoveryFixtureSealed
        & (Get-RecoveryFixtureRestore) $fixture.checkpoint.snapshots.postConfig $fixture.checkpoint.stateFiles.postConfig
        Write-RecoveryFixtureFile $fixture.checkpoint.stateFiles.postConfig.actualEnvPath 'foreign after restore'
        { Invoke-RecoveryFixture } | Should -Throw '*current state/env changed after sealing*'
        $fixture.restoreCalls | Should -Be 1
        Test-Path -LiteralPath $fixture.archive | Should -BeFalse
    }

    It 'rejects unknown generated files at sealing even if the closed observation succeeds' {
        $fixture.ownership = New-ReleaseExtensionRecoveryOwnership -Checkpoint $fixture.checkpoint -Context $fixture.context -ExtensionName $fixture.extensionName -WriteSet $fixture.paths -AssertCompatibility (Get-RecoveryFixtureCompatibility)
        $fixture.ownership.invocation = $fixture.invocation
        Write-RecoveryFixtureFile (Join-Path $fixture.context.worktreePath ('src/cfe/' + $fixture.extensionName + '/foreign.txt')) 'undeclared bytes'
        { Complete-ReleaseExtensionRecoveryOwnership $fixture.ownership $fixture.checkpoint $fixture.context (Get-RecoveryFixtureStop) (Get-RecoveryFixtureCompatibility) } | Should -Throw '*RELEASE_EXTENSION_RECOVERY_REJECTED*'
        $fixture.ownership.status | Should -Be 'declared'
    }

    It 'restores exact postConfig support imported from the existing owned capability cache' {
        $cacheRoot = Join-Path $fixture.context.worktreePath '.agent-1c/runs/release-e2e-capabilities/qualified-config'
        $records = @(@{ record = $fixture.checkpoint.snapshots.postConfig; key = 'path' },
            @{ record = $fixture.checkpoint.stateFiles.postConfig; key = 'stateCopyPath' }, @{ record = $fixture.checkpoint.stateFiles.postConfig; key = 'envCopyPath' })
        foreach ($item in $records) {
            $source = [string]$item.record[$item.key]
            $destination = Join-Path $cacheRoot ([IO.Path]::GetFileName($source))
            [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination
            $item.record[$item.key] = $destination
        }
        Set-RecoveryFixtureSealed
        $result = Invoke-RecoveryFixture
        $result.snapshotSha256 | Should -Be $fixture.checkpoint.snapshots.postConfig.sha256
        $fixture.restoreCalls | Should -Be 1
        $fixture.ownership.support.snapshot.path | Should -Be $fixture.checkpoint.snapshots.postConfig.path
        $result.stageStatus | Should -Be 'failed'
    }

    It 'admits missing old process creation only with approved legacy files and the exact failed lifecycle record' {
        Set-RecoveryFixtureSealed
        Set-RecoveryFixtureApprovedLegacy
        Set-RecoveryFixtureLegacyStop
        $result = Invoke-RecoveryFixture
        $fixture.restoreCalls | Should -Be 1
        $result.stageStatus | Should -Be 'failed'
        $result.stopEvidence.processCreationUnavailable | Should -BeTrue
        $result.stopEvidence.Keys | Should -Not -Contain 'childStartedAtUtc'
    }

    It 'refuses unsafe legacy stop context before restoration: <Mutation>' -ForEach @(
        @{ Mutation = 'no-approval' }, @{ Mutation = 'changed-record' }, @{ Mutation = 'wrong-action' }, @{ Mutation = 'wrong-pid' }, @{ Mutation = 'native-active' }
    ) {
        Set-RecoveryFixtureSealed
        Set-RecoveryFixtureApprovedLegacy
        Set-RecoveryFixtureLegacyStop
        switch ($Mutation) {
            'no-approval' { $fixture.ownership.Remove('approvedLegacyManifest') }
            'changed-record' { Write-RecoveryFixtureFile $fixture.ownership.invocation.legacyOperationRecordPath '{}' }
            'wrong-action' {
                $record = Read-ReleaseExtensionRecoveryJson $fixture.ownership.invocation.legacyOperationRecordPath
                $record.action = 'unrelated-action'
                Write-RecoveryFixtureJson $fixture.ownership.invocation.legacyOperationRecordPath $record
                $fixture.ownership.invocation.legacyOperationRecordSha256 = (Get-ReleaseExtensionRecoveryFile $fixture.ownership.invocation.legacyOperationRecordPath).sha256
            }
            'wrong-pid' { $fixture.ownership.invocation.childProcessId = 54321 }
            'native-active' { $fixture.stop.nativeQuiescent = $false }
        }
        { Invoke-RecoveryFixture } | Should -Throw '*RELEASE_EXTENSION_RECOVERY_REJECTED*'
        $fixture.restoreCalls | Should -Be 0
        foreach ($file in $fixture.ownership.files) { (Get-ReleaseExtensionRecoveryFile (Join-Path $fixture.context.worktreePath $file.path)).sha256 | Should -Be $file.sha256 }
        Test-Path -LiteralPath $fixture.archive | Should -BeFalse
    }

    It 'refuses an unignored archive before restoring or moving any owned bytes' {
        Write-RecoveryFixtureFile (Join-Path $fixture.context.worktreePath '.gitignore') ".agent-1c/*`n!.agent-1c/unignored-archive/`n.dev.env`n"
        Invoke-RepositoryGit $fixture.context.worktreePath @('add', '--', '.gitignore') | Out-Null
        Invoke-RepositoryGit $fixture.context.worktreePath @('commit', '-m', 'Fixture explicitly unignored archive') | Out-Null
        $fixture.context.expectedHead = (Invoke-RepositoryGit $fixture.context.worktreePath @('rev-parse', 'HEAD')).stdout.Trim()
        $fixture.checkpoint.expectedHead = $fixture.context.expectedHead
        Write-RecoveryFixtureJson $fixture.context.checkpointPath $fixture.checkpoint
        $fixture.archive = Join-Path $fixture.context.worktreePath '.agent-1c/unignored-archive/original-failed-run'
        Set-RecoveryFixtureSealed
        { Invoke-RecoveryFixture } | Should -Throw '*RELEASE_EXTENSION_RECOVERY_REJECTED*'
        $fixture.restoreCalls | Should -Be 0
        foreach ($file in $fixture.ownership.files) { (Get-ReleaseExtensionRecoveryFile (Join-Path $fixture.context.worktreePath $file.path)).sha256 | Should -Be $file.sha256 }
        Test-Path -LiteralPath $fixture.archive | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $fixture.context.worktreePath 'business.txt')) | Should -Be 'unrelated committed business bytes'
    }
}
