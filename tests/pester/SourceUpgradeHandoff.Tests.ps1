BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $launcher = Join-Path $context.RepoRoot 'scripts/update-installed-workflow.ps1'
    $helperPath = $context.HelperPath
}

Describe 'Durable update snapshot continuation' {
    It 'finishes normal update after the successful fresh child without replaying parent post-copy' {
        $project = Join-Path $TestDrive 'Завершённый fresh child в обычном update'
        $sourceRoot = Join-Path $TestDrive 'Источник обычного update'
        New-Item -ItemType Directory -Force -Path $project, $sourceRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $project 'managed.txt'), 'before', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'managed.txt'), 'candidate', [Text.UTF8Encoding]::new($false))
        $childPath = Join-Path $TestDrive 'successful post-copy child.ps1'
        [IO.File]::WriteAllText($childPath, @'
param([string]$ProjectRoot)
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'managed.txt'),'native child completed',[Text.UTF8Encoding]::new($false))
$report = [ordered]@{schemaVersion=1;sourceCommit=('3'*40);mainRoot=$ProjectRoot;roots=@()}
[IO.File]::WriteAllText((Join-Path $ProjectRoot '.agent-1c/snapshots/workflow-update-rollout.json'),($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
exit 0
'@, [Text.UTF8Encoding]::new($true))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            $script:NormalUpdateSource = [pscustomobject]@{root=$sourceRoot;commit=('3'*40)}
            $script:Agent1cScriptPath = $childPath
            function Resolve-WorkflowPackageSource { $script:NormalUpdateSource }
            function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
            function Assert-WorkflowTrackedGitClean {}
            function Assert-WorkflowUpdateCommitIdentity {}
            function Assert-WorkflowSourceAiRulesInstallable { param($SourceRoot) }
            function Invoke-WorkflowLocalPatchStep { param($Step,$Operation,$Source,$Plan) }
            function Get-WorkflowPackageCopyDirectoryPaths { @() }
            function Get-WorkflowPackageCopyFilePaths { @('managed.txt') }
            function Get-WorkflowUpdateSnapshotRelativePaths { param($SourceRoot,$AiRulesPathsAfter); @('managed.txt') }
            function Remove-LegacyWorkflowManagedFiles {}
            function Update-WorkflowPackageLockEntry { param($Source) }
            function Assert-MasterWorktreeContext { throw 'Parent incorrectly replayed post-copy after successful child' }
            Update-WorkflowPackage *> $null
            $completed = @(Get-ChildItem -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update') -Directory -Filter 'itl-workflow-update-completed-*')
            [pscustomobject]@{text=[IO.File]::ReadAllText((Join-Path $project 'managed.txt')); pending=($null -ne (Get-WorkflowUpdatePendingSnapshot)); completed=$completed.Count}
        }
        $result.text | Should -Be 'native child completed'
        $result.pending | Should -BeFalse
        $result.completed | Should -Be 1
    }

    It 'uses an exact newer source helper to finish pinned post-copy before requesting the new candidate' {
        $project=Join-Path $TestDrive 'Stopped update Кириллица'
        $newSource=Join-Path $TestDrive 'New qualified helper'
        New-Item -ItemType Directory -Force -Path $project,$newSource | Out-Null
        [IO.File]::WriteAllText((Join-Path $project 'managed.txt'),'before',[Text.UTF8Encoding]::new($false))
        $oldOverride=$env:ITL_WORKFLOW_SOURCE_PATH
        $hadOverride=Test-Path Env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH=$newSource
            $result=& {
                . $helperPath -ProjectRoot $project -Action help *> $null
                $script:RecoverySource=[pscustomobject]@{root=$newSource;commit=('2'*40)}
                function Resolve-WorkflowPackageSource { $script:RecoverySource }
                function Assert-WorkflowSourceOutsideProject { param($SourceRoot) }
                $recorded=[pscustomobject]@{root='C:\original-source';commit=('1'*40)}
                $refused=''
                try{Resolve-WorkflowUpdateRecoveryExecutor -RecordedSource $recorded|Out-Null}catch{$refused=$_.Exception.Message}
                $script:Agent1cScriptPath=Join-Path $newSource '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
                function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
                function Assert-WorkflowUpdateRecordedSource { param($Receipt) }
                function Assert-WorkflowDevelopmentBranchRolloutComplete { param($SourceCommit); if($SourceCommit -cne ('1'*40)){throw 'Pinned candidate identity changed'} }
                function Invoke-Agent1cFreshProcess {
                    param([string[]]$AdditionalArguments,[switch]$ReturnExitStatus)
                    if($env:ITL_WORKFLOW_SOURCE_PATH -cne 'C:\original-source'){throw 'Child payload selection was replaced by the new helper source'}
                    [pscustomobject]@{exitCode=0}
                }
                $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
                [IO.File]::WriteAllText((Join-Path $project 'managed.txt'),'original candidate bytes',[Text.UTF8Encoding]::new($false))
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $recorded -Phase post-copy-failed
                $next=''
                try{Update-WorkflowPackage|Out-Null}catch{$next=$_.Exception.Message}
                $id=(Split-Path -Leaf $snapshot.root).Substring('itl-workflow-update-rollback-'.Length)
                $completed=Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id
                [pscustomobject]@{refused=$refused;next=$next;payload=$completed.receipt.sourceCommit;executor=$completed.receipt.recoveryExecutorCommit;override=$env:ITL_WORKFLOW_SOURCE_PATH;text=[IO.File]::ReadAllText((Join-Path $project 'managed.txt'));pending=($null -ne (Get-WorkflowUpdatePendingSnapshot))}
            }
            $result.refused | Should -Match 'WORKFLOW_UPDATE_RECOVERY_SOURCE_HELPER_REQUIRED'
            $result.next | Should -Match 'WORKFLOW_UPDATE_NEW_CANDIDATE_PENDING'
            $result.payload | Should -Be ('1'*40)
            $result.executor | Should -Be ('2'*40)
            $result.override | Should -Be $newSource
            $result.text | Should -Be 'original candidate bytes'
            $result.pending | Should -BeFalse
        } finally {if($hadOverride){$env:ITL_WORKFLOW_SOURCE_PATH=$oldOverride}else{Remove-Item Env:ITL_WORKFLOW_SOURCE_PATH -ErrorAction SilentlyContinue}}
    }

    It 'records a real failed post-copy child before returning and resumes through the same owner' {
        $project=Join-Path $TestDrive 'Native child failure Кириллица'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        [IO.File]::WriteAllText((Join-Path $project 'managed.txt'),'before',[Text.UTF8Encoding]::new($false))
        $childPath=Join-Path $TestDrive 'post-copy child.ps1'
        $childText=@'
param([string]$ProjectRoot)
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'managed.txt'),'owned post-copy output',[Text.UTF8Encoding]::new($false))
Write-Output 'Native post-copy child failed after its owned write'
exit 7
'@
        [IO.File]::WriteAllText($childPath,$childText,[Text.UTF8Encoding]::new($true))
        $result=& {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $script:Agent1cScriptPath=$childPath
            $source=[pscustomobject]@{root='C:\source';commit=('1'*40)}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
            $failure=''
            try{Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source}catch{$failure=$_.Exception.Message}
            $pending=Get-WorkflowUpdatePendingSnapshot
            $phase=$pending.receipt.phase
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
            [IO.File]::WriteAllText($childPath,($childText.Replace('exit 7','exit 0')),[Text.UTF8Encoding]::new($true))
            Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source
            [pscustomobject]@{failure=$failure;phase=$phase;pending=($null -ne (Get-WorkflowUpdatePendingSnapshot));text=[IO.File]::ReadAllText((Join-Path $project 'managed.txt'));completed=@(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshot.root) -Directory -Filter 'itl-workflow-update-completed-*').Count}
        }
        $result.failure | Should -Match 'WORKFLOW_UPDATE_POST_COPY_INCOMPLETE.*exit code 7'
        $result.phase | Should -Be 'post-copy-failed'
        $result.pending | Should -BeFalse
        $result.text | Should -Be 'owned post-copy output'
        $result.completed | Should -Be 1
    }

    It 'returns one structured post-copy result when current rules emit native installer diagnostics' {
        $project = Join-Path $TestDrive 'Текущие rules повтор update'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            foreach ($name in @('Assert-UiTestingPolicyUpdateSnapshot','Ensure-OneCSessionLimitDotEnv','Ensure-Agent1cLifecycleLocksIgnored','Ensure-GitIgnore',
                'Ensure-ItlPinnedOpenSpecGitAttributes','Sync-ItlVanessaLibraries','Update-UserRules',
                'Sync-WorkflowManagedDependencyLockEntries','Install-YAxUnit','Update-RoctupMcp',
                'Sync-VanessaAutomationDependencyLock','Install-VanessaAutomation','Update-VanessaMcpArtifacts',
                'Sync-ItlOnDemandMcpDependencyLock','Install-ItlOnDemandMcp','Assert-AiRulesBaselineMigrationResult',
                'Update-AgentGuidanceBridge','Install-ItlUiTools','Sync-ItlClientSurfaces',
                'Sync-ItlClientUserEnvironment','Invoke-CavemanPolicyTransition','Invoke-UiTestingPolicyTransition')) {
                Set-Item -Path "Function:$name" -Value { }
            }
            function Get-AiRules1cManifestFileEntries { [pscustomobject]@{target='.codex/rules/current.md'} }
            function Get-WorkflowUpdateClientSurfacePaths { '.agents/skills/itl-check/SKILL.md' }
            function Get-AgentTargets { 'codex' }
            function Get-WorkflowUpdatePendingSnapshot { [pscustomobject]@{receipt=[pscustomobject]@{sourceRoot=''};snapshot=[pscustomobject]@{records=@()}} }
            function Get-CavemanPolicyPreviousWorkflowCommit { 'old-source' }
            function Invoke-AiRulesBaselineMigration { [pscustomobject]@{migrated=$false;suppressRegularUpdate=$false} }
            function Update-AiRules1c { 'Native installer: exact candidate'; 'Native installer: files unchanged' }
            @(Invoke-WorkflowPackageFilePostCopy)
        }
        @($result).Count | Should -Be 1
        @($result.aiRulesPathsBefore) | Should -Be @('.codex/rules/current.md')
        @($result.clientSurfacePathsBefore) | Should -Be @('.agents/skills/itl-check/SKILL.md')
    }

    It 'fingerprints the same Cyrillic managed directory in both PowerShell hosts' {
        $project = Join-Path $TestDrive 'каталог с пробелом'
        $managed = Join-Path $project 'managed'
        New-Item -ItemType Directory -Force -Path $managed | Out-Null
        [IO.File]::WriteAllText((Join-Path $managed 'A.md'), 'latin', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $managed 'а.md'), 'cyrillic', [Text.UTF8Encoding]::new($false))
        $probePath = Join-Path $TestDrive 'workflow-hash-probe.ps1'
        $probe = @'
param([string]$HelperPath, [string]$ProjectRoot)
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
Get-WorkflowUpdatePathState -RelativePath 'managed'
'@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
        $modern = @(& pwsh -NoProfile -File $probePath $helperPath $project)
        $modernExit = $LASTEXITCODE
        $legacy = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probePath $helperPath $project)
        $legacyExit = $LASTEXITCODE
        $modernExit | Should -Be 0
        $legacyExit | Should -Be 0
        $modern | Should -HaveCount 1
        $legacy | Should -Be $modern
        $legacy[0] | Should -Match '^directory:[a-f0-9]{64}$'
    }

    It 'accepts the r33 CRLF installed root after a real Git worktree checks out LF without changing the manifest' {
        $installed = Join-Path $TestDrive 'r33 установленный корень с пробелом'
        $project = Join-Path $TestDrive 'r33 worktree Кириллица с пробелом'
        New-Item -ItemType Directory -Force -Path $installed | Out-Null
        & git -C $installed init -b master *> $null
        $LASTEXITCODE | Should -Be 0
        & git -C $installed config user.name 'Root transport fixture'
        & git -C $installed config user.email 'root-transport@example.invalid'
        & git -C $installed config core.autocrlf true
        $text = "# 1C Development Rules`r`n`r`nReply in Russian. Проверяем исходный корень.`r`n"
        $installedAgents = Join-Path $installed 'AGENTS.md'
        [IO.File]::WriteAllText($installedAgents, $text, [Text.UTF8Encoding]::new($false))
        $installedHash = (Get-FileHash -LiteralPath $installedAgents -Algorithm SHA256).Hash.ToLowerInvariant()
        & git -C $installed add -- AGENTS.md
        $LASTEXITCODE | Should -Be 0
        & git -C $installed commit -qm 'r33 CRLF installed root'
        $LASTEXITCODE | Should -Be 0
        & git -C $installed config core.autocrlf false
        & git -C $installed worktree add -b itldev/check $project *> $null
        $LASTEXITCODE | Should -Be 0
        $agentsPath = Join-Path $project 'AGENTS.md'
        [IO.File]::ReadAllText($agentsPath) | Should -Be $text.Replace("`r`n", "`n")
        (Get-FileHash -LiteralPath $agentsPath).Hash | Should -Not -Be $installedHash
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath,
            ('{"version":"itl-main-410951e7-r33","files":{"AGENTS.md":{"installedHash":"' + $installedHash + '","userModified":false}}}'), [Text.UTF8Encoding]::new($false))
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $agentsHash = (Get-FileHash -LiteralPath $agentsPath).Hash
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $marked = @(Get-AiRulesManifestUserModifiedPaths)
            $errorText = ''
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; $ready = $true }
            catch { $ready = $false; $errorText = $_.Exception.Message }
            [pscustomobject]@{marked=$marked;ready=$ready;error=$errorText}
        }
        $result.marked | Should -BeNullOrEmpty
        $result.ready | Should -BeTrue -Because $result.error
        (Get-FileHash -LiteralPath $agentsPath).Hash | Should -Be $agentsHash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
    }

    It 'blocks invalid UTF8 in the managed root without changing its bytes or manifest' {
        $project = Join-Path $TestDrive 'invalid UTF8 корень с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        $agentsPath = Join-Path $project 'AGENTS.md'
        [IO.File]::WriteAllText($agentsPath, "# Rules`r`nКириллица`r`n", [Text.UTF8Encoding]::new($false))
        $installedHash = (Get-FileHash -LiteralPath $agentsPath).Hash.ToLowerInvariant()
        [IO.File]::WriteAllBytes($agentsPath, [byte[]]@(0x23,0x20,0xFF,0x0A))
        $invalidHash = (Get-FileHash -LiteralPath $agentsPath).Hash
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath,
            ('{"files":{"AGENTS.md":{"installedHash":"' + $installedHash + '","userModified":false}}}'), [Text.UTF8Encoding]::new($false))
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $marked = @(Get-AiRulesManifestUserModifiedPaths)
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; 'not-blocked' }
            catch { [pscustomobject]@{marked=$marked;error=$_.Exception.Message} }
        }
        $result.marked | Should -Contain 'AGENTS.md'
        $result.error | Should -Match 'WORKFLOW_UPDATE_RULES_USER_MODIFIED:.*AGENTS.md'
        (Get-FileHash -LiteralPath $agentsPath).Hash | Should -Be $invalidHash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
    }

    It 'blocks an edited rules root before workflow files or Caveman policy are changed' {
        $project = Join-Path $TestDrive 'modified rules root Кириллица'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        $agentsPath = Join-Path $project 'AGENTS.md'
        [IO.File]::WriteAllText($agentsPath, 'installed root', [Text.UTF8Encoding]::new($false))
        $installedHash = (Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($agentsPath, 'installed root with local policy', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.ai-rules.json'),
            ('{"files":{"AGENTS.md":{"installedHash":"' + $installedHash + '","userModified":false}}}'), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.dev.env'), "CAVEMAN=On`n", [Text.UTF8Encoding]::new($false))
        $errorText = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; 'not-blocked' }
            catch { $_.Exception.Message }
        }
        $errorText | Should -Match 'WORKFLOW_UPDATE_RULES_USER_MODIFIED:.*AGENTS.md'
        [IO.File]::ReadAllText($agentsPath) | Should -Be 'installed root with local policy'
        [IO.File]::ReadAllText((Join-Path $project '.dev.env')) | Should -Be "CAVEMAN=On`n"
        (Test-Path -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update')) | Should -BeFalse
    }

    It 'blocks unmarked changed rule files while accepting byte-equivalent legacy markers before copying' {
        $project = Join-Path $TestDrive 'modified rules files Кириллица'
        $rulesDir = Join-Path $project '.codex/rules'
        New-Item -ItemType Directory -Force -Path $rulesDir, (Join-Path $project '.agent-1c') | Out-Null
        $changedPath = Join-Path $rulesDir 'example.md'
        $equivalentPath = Join-Path $rulesDir 'eol.md'
        [IO.File]::WriteAllText($changedPath, 'installed rule', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($equivalentPath, "same line`n", [Text.UTF8Encoding]::new($false))
        $changedHash = (Get-FileHash -LiteralPath $changedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $equivalentHash = (Get-FileHash -LiteralPath $equivalentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($changedPath, 'user rule', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($equivalentPath, "same line`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $manifest = @{ files = @{
            '.codex/rules/example.md' = @{ installedHash = $changedHash; userModified = $false }
            '.codex/rules/eol.md' = @{ installedHash = $equivalentHash; userModified = $true }
        } }
        [IO.File]::WriteAllText((Join-Path $project '.ai-rules.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $errorText = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; 'not-blocked' }
            catch { $_.Exception.Message }
        }
        $errorText | Should -Match 'WORKFLOW_UPDATE_RULES_USER_MODIFIED:.*example.md'
        $errorText | Should -Not -Match 'eol.md'
        [IO.File]::ReadAllText($changedPath) | Should -Be 'user rule'
        [IO.File]::ReadAllText($equivalentPath) | Should -Be "same line`r`n"
    }

    It 'preserves legacy user-global prompt ownership through read-only update admission' -ForEach @(
        @{Marked=$false}, @{Marked=$true}
    ) {
        $project = Join-Path $TestDrive ('Legacy upstream manifest Кириллица ' + $Marked)
        $profile = Join-Path $TestDrive ('Isolated user profile с пробелами ' + $Marked)
        $prompt = Join-Path $profile '.codex/prompts/test-fix-loop.md'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c'), (Split-Path -Parent $prompt) | Out-Null
        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($prompt, "Historical prompt`r`nUser-owned additions Кириллица`r`n", $encoding)
        $promptHash = (Get-FileHash -LiteralPath $prompt).Hash
        $rule = Join-Path $project 'AGENTS.md'
        [IO.File]::WriteAllText($rule, "Installed project rules`r`n", $encoding)
        $manifest = [ordered]@{ protocol='1.0'; tools=@('codex'); files=[ordered]@{} }
        # Historical a421cf44 Resolve-CopyToPath/Invoke-PlaceArtifactFile
        # stores this absolute target and content/commands source verbatim.
        $manifest.files[$prompt] = @{source='content/commands/test-fix-loop.md'; installedHash=('a' * 64); userModified=$Marked}
        $manifest.files['AGENTS.md'] = @{source='AGENTS.md'; installedHash=(Get-FileHash -LiteralPath $rule).Hash.ToLowerInvariant()}
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), $encoding)
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"repo":"https://github.com/comol/ai_rules_1c.git","tools":["codex"]}}', $encoding)
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'), ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), $encoding)
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'legacy-global@example.invalid'
        & git -C $project config user.name 'Legacy Global Prompt Test'
        & git -C $project add --all
        & git -C $project commit -qm 'genuine historical manifest shape'
        $before = (& git -C $project rev-parse HEAD).Trim()
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $result = & {
            . $helperPath -ProjectRoot $project -Action help -AgentTarget codex *> $null
            # The predicate accepts an explicit home without granting any IO.
            # Map only this pure classification for the isolated fixture; the
            # production default is tested separately without touching globals.
            $script:legacyPromptPredicate = if (Test-Path Function:Test-AiRulesLegacyUserGlobalPrompt) { ${function:Test-AiRulesLegacyUserGlobalPrompt} } else { $null }
            $script:legacyPromptProfile = $profile
            if ($null -ne $script:legacyPromptPredicate) {
                function Test-AiRulesLegacyUserGlobalPrompt {
                    param($Path, $ManifestEntry)
                    & $script:legacyPromptPredicate -Path $Path -ManifestEntry $ManifestEntry -UserProfileRoot $script:legacyPromptProfile
                }
            }
            $markedPaths = @(Get-AiRulesManifestUserModifiedPaths)
            $entries = @(Get-AiRules1cManifestFileEntries)
            $conflicts = @()
            $inventory = @()
            $writeSetError = try { $conflicts = @(Get-WorkflowUpdateRootWriteSetConflicts -Root $project); '' } catch { $_.Exception.Message }
            $preflightError = try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; '' } catch { $_.Exception.Message }
            $snapshotError = try { $inventory = @(Get-WorkflowUpdateSnapshotRelativePaths); '' } catch { $_.Exception.Message }
            [IO.File]::WriteAllText($rule, "Actual user rule edit Кириллица`r`n", $encoding)
            $localEditError = try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; '' } catch { $_.Exception.Message }
            [IO.File]::WriteAllText($rule, "Installed project rules`r`n", $encoding)
            [pscustomobject]@{marked=$markedPaths;entries=$entries;conflicts=$conflicts;writeSetError=$writeSetError;preflightError=$preflightError;snapshotError=$snapshotError;inventory=$inventory;localEditError=$localEditError}
        }
        $result.writeSetError | Should -Be ''
        $result.marked | Should -Not -Contain $prompt
        @($result.entries.target) | Should -Be @('AGENTS.md')
        $result.conflicts | Should -HaveCount 0
        $result.preflightError | Should -Be ''
        $result.snapshotError | Should -Be ''
        $result.inventory | Should -Not -Contain $prompt
        $result.localEditError | Should -Match 'WORKFLOW_UPDATE_RULES_USER_MODIFIED:.*AGENTS\.md'
        (Get-FileHash -LiteralPath $prompt).Hash | Should -Be $promptHash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
        (& git -C $project rev-parse HEAD).Trim() | Should -Be $before
        @(& git -C $project -c core.quotepath=false status --porcelain=v1 -z) | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update')) | Should -BeFalse
    }

    It 'retains parent-proven legacy prompt metadata during pending manifest validation without global IO' {
        $project = Join-Path $TestDrive 'Pending legacy manifest Кириллица'
        $profile = Join-Path $TestDrive 'Pending legacy profile с пробелами'
        $prompt = Join-Path $profile '.codex/prompts/test-fix-loop.md'
        New-Item -ItemType Directory -Force -Path $project, (Split-Path -Parent $prompt) | Out-Null
        [IO.File]::WriteAllText($prompt, 'Independent user-global additions Кириллица', [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $prompt).Hash
        $manifest = @{protocol='1.0';tools=@('codex');files=@{};foreignFiles=@{codex=@()}}
        $manifest.files[$prompt] = @{source='content/commands/test-fix-loop.md';installedHash=('a' * 64);userModified=$true}
        $text = $manifest | ConvertTo-Json -Depth 12
        $result = & {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            $script:legacyPromptPredicate = ${function:Test-AiRulesLegacyUserGlobalPrompt}
            $script:legacyPromptProfile = $profile
            function Test-AiRulesLegacyUserGlobalPrompt {
                param($Path, $ManifestEntry)
                & $script:legacyPromptPredicate -Path $Path -ManifestEntry $ManifestEntry -UserProfileRoot $script:legacyPromptProfile
            }
            $branch = $text | ConvertFrom-Json
            $target = $text | ConvertFrom-Json
            $candidate = $text | ConvertFrom-Json
            $valid = Test-AiRulesPendingMergeManifestProvenance -Root $project -Candidate $candidate -Branch $branch -Target $target
            $candidate.files.PSObject.Properties[$prompt].Value.installedHash = ('b' * 64)
            $forged = Test-AiRulesPendingMergeManifestProvenance -Root $project -Candidate $candidate -Branch $branch -Target $target
            $unknown = $text | ConvertFrom-Json
            $unknown.files.PSObject.Properties[$prompt].Value.source = 'content/rules/test-fix-loop.md'
            $unknownCopy = $unknown | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $unknownSource = Test-AiRulesPendingMergeManifestProvenance -Root $project -Candidate $unknownCopy -Branch $unknown -Target $unknown
            [pscustomobject]@{valid=$valid;forged=$forged;unknownSource=$unknownSource;branchAfter=($branch|ConvertTo-Json -Depth 12);targetAfter=($target|ConvertTo-Json -Depth 12)}
        }
        $result.valid | Should -BeTrue
        $result.forged | Should -BeFalse
        $result.unknownSource | Should -BeFalse
        ($result.branchAfter | ConvertFrom-Json).files.PSObject.Properties[$prompt].Value.installedHash | Should -Be ('a' * 64)
        ($result.targetAfter | ConvertFrom-Json).files.PSObject.Properties[$prompt].Value.source | Should -Be 'content/commands/test-fix-loop.md'
        (Get-FileHash -LiteralPath $prompt).Hash | Should -Be $before
    }

    It 'does not turn arbitrary absolute or escaping manifest paths into legacy prompt ownership' -ForEach @(
        @{Case='arbitrary absolute';Tail='.codex/config.toml';Source='content/commands/test-fix-loop.md';Outside=$false},
        @{Case='other profile';Tail='.codex/prompts/test-fix-loop.md';Source='content/commands/test-fix-loop.md';Outside=$true},
        @{Case='escaping prompt path';Tail='.codex/prompts/../outside.md';Source='content/commands/test-fix-loop.md';Outside=$false},
        @{Case='unknown source';Tail='.codex/prompts/test-fix-loop.md';Source='content/rules/test-fix-loop.md';Outside=$false},
        @{Case='missing source';Tail='.codex/prompts/test-fix-loop.md';Source=$null;Outside=$false},
        @{Case='empty source';Tail='.codex/prompts/test-fix-loop.md';Source='';Outside=$false},
        @{Case='escaping command source';Tail='.codex/prompts/test-fix-loop.md';Source='content/commands/../rules.md';Outside=$false}
    ) {
        $project = Join-Path $TestDrive ('Invalid global ownership project ' + $Case)
        $profile = Join-Path $TestDrive ('Known home Кириллица ' + $Case)
        $pathRoot = if ($Outside) { Join-Path $TestDrive ('Foreign owned home ' + $Case) } else { $profile }
        $target = Join-Path $pathRoot $Tail
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c'), (Split-Path -Parent ([IO.Path]::GetFullPath($target))) | Out-Null
        [IO.File]::WriteAllText($target, 'Preserve external bytes Кириллица', [Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $target).Hash
        $manifest = @{files=@{};tools=@('codex')}
        $manifest.files[$target] = @{source=$Source;installedHash=$hash.ToLowerInvariant();userModified=$true}
        if ($Case -eq 'missing source') { $manifest.files[$target].Remove('source') }
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'), ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        & git -C $project init -b master *> $null
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $result = & {
            . $helperPath -ProjectRoot $project -Action help -AgentTarget codex *> $null
            $script:legacyPromptPredicate = if (Test-Path Function:Test-AiRulesLegacyUserGlobalPrompt) { ${function:Test-AiRulesLegacyUserGlobalPrompt} } else { $null }
            $script:legacyPromptProfile = $profile
            if ($null -ne $script:legacyPromptPredicate) {
                function Test-AiRulesLegacyUserGlobalPrompt {
                    param($Path, $ManifestEntry)
                    & $script:legacyPromptPredicate -Path $Path -ManifestEntry $ManifestEntry -UserProfileRoot $script:legacyPromptProfile
                }
            }
            [pscustomobject]@{
                marked=@(Get-AiRulesManifestUserModifiedPaths)
                writeSetError=$(try { Get-WorkflowUpdateRootWriteSetConflicts -Root $project | Out-Null; '' } catch { $_.Exception.Message })
                preflightError=$(try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; '' } catch { $_.Exception.Message })
                snapshotError=$(try { Get-WorkflowUpdateSnapshotRelativePaths | Out-Null; '' } catch { $_.Exception.Message })
            }
        }
        $result.marked | Should -Contain $target
        $result.writeSetError | Should -Match 'WORKFLOW_UPDATE_RULES_MANIFEST_INVALID:'
        $result.preflightError | Should -Match 'Invalid workflow update managed repository path'
        $result.snapshotError | Should -Match 'Invalid workflow update managed repository path'
        (Get-FileHash -LiteralPath $target).Hash | Should -Be $hash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
        (Test-Path -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update')) | Should -BeFalse
    }

    It 'classifies the actual profile legacy contract without opening or changing global files' {
        $result = & {
            . $helperPath -ProjectRoot $TestDrive -Action help -SkipAiRules *> $null
            $homeRoot = [Environment]::GetFolderPath('UserProfile')
            $path = Join-Path $homeRoot ('.codex/prompts/never-written-legacy-proof-' + [guid]::NewGuid().ToString('N') + '.md')
            Test-AiRulesLegacyUserGlobalPrompt -Path $path -ManifestEntry @{source='content/commands/test-fix-loop.md'}
        }
        $result | Should -BeTrue
    }

    It 'preserves declared placed-once project templates instead of blocking their user additions' -ForEach @(
        @{TemplateName='USER-RULES.md';Marked=$false},
        @{TemplateName='USER-RULES.md';Marked=$true},
        @{TemplateName='memory.md';Marked=$false},
        @{TemplateName='memory.md';Marked=$true},
        @{TemplateName='LLM-RULES.md';Marked=$false},
        @{TemplateName='LLM-RULES.md';Marked=$true}
    ) {
        $project = Join-Path $TestDrive ('placed-once project template Кириллица ' + $TemplateName + '-' + $Marked)
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        $templatePath = Join-Path $project $TemplateName
        [IO.File]::WriteAllText($templatePath, 'Original template', [Text.UTF8Encoding]::new($false))
        $installedHash = (Get-FileHash -LiteralPath $templatePath).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($templatePath, "Original template`r`nUser-owned notes Кириллица`r`n", [Text.UTF8Encoding]::new($false))
        $currentHash = (Get-FileHash -LiteralPath $templatePath).Hash
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $manifest = @{ files = @{} }
        $manifest.files[$TemplateName] = @{source=$TemplateName;template=$true;installedHash=$installedHash;userModified=$Marked;owners=@('core');scope='project'}
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $markedPaths = @(Get-AiRulesManifestUserModifiedPaths)
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; $failure = '' }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{markedPaths=$markedPaths;failure=$failure}
        }
        $result.markedPaths | Should -Not -Contain $TemplateName
        $result.failure | Should -Be ''
        (Get-FileHash -LiteralPath $templatePath).Hash | Should -Be $currentHash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
    }

    It 'keeps modified-rule protection when a template declaration is outside the placed-once contract' -ForEach @(
        @{RelativePath='.codex/rules/example.md';TemplateFlag=$true;DeclaredSource='.codex/rules/example.md';InvalidBytes=$false},
        @{RelativePath='USER-RULES.md';TemplateFlag=$true;DeclaredSource='other-policy.md';InvalidBytes=$false},
        @{RelativePath='memory.md';TemplateFlag='true';DeclaredSource='memory.md';InvalidBytes=$false},
        @{RelativePath='LLM-RULES.md';TemplateFlag=$true;DeclaredSource='LLM-RULES.md';InvalidBytes=$true}
    ) {
        $project = Join-Path $TestDrive ('template boundary Кириллица ' + $RelativePath.Replace('/', '_') + '-' + $InvalidBytes)
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        $targetPath = Join-Path $project $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        [IO.File]::WriteAllText($targetPath, 'Installed content', [Text.UTF8Encoding]::new($false))
        $installedHash = (Get-FileHash -LiteralPath $targetPath).Hash.ToLowerInvariant()
        if ($InvalidBytes) {
            [IO.File]::WriteAllBytes($targetPath, [byte[]]@(0x23,0x20,0xFF,0x0A))
        } else {
            [IO.File]::WriteAllText($targetPath, 'Changed content Кириллица', [Text.UTF8Encoding]::new($false))
        }
        $targetHash = (Get-FileHash -LiteralPath $targetPath).Hash
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/dependency-lock.json'),
            ('{"dependencies":{"aiRules1c":{"commit":"' + ('0' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $manifest = @{files=@{}}
        $manifest.files[$RelativePath] = @{source=$DeclaredSource;template=$TemplateFlag;installedHash=$installedHash;userModified=$false}
        $manifestPath = Join-Path $project '.ai-rules.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
        $errorText = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            try { Assert-WorkflowUpdateRulesRootReady -SourceRoot $context.RepoRoot; 'not-blocked' }
            catch { $_.Exception.Message }
        }
        $errorText | Should -Match ('WORKFLOW_UPDATE_RULES_USER_MODIFIED:.*' + [regex]::Escape($RelativePath))
        (Get-FileHash -LiteralPath $targetPath).Hash | Should -Be $targetHash
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $manifestHash
        (Test-Path -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update')) | Should -BeFalse
    }

    It 'rejects a changed cached source even when no source-path override was supplied' {
        $project = Join-Path $TestDrive 'project for source resume'
        $source = Join-Path $TestDrive 'источник с пробелом'
        New-Item -ItemType Directory -Force -Path $project, $source | Out-Null
        & git -C $source init -b main *> $null
        & git -C $source config user.email 'source-recovery@example.invalid'
        & git -C $source config user.name 'Source Recovery Test'
        [IO.File]::WriteAllText((Join-Path $source 'package.txt'), 'before', [Text.UTF8Encoding]::new($false))
        & git -C $source add -- package.txt
        & git -C $source commit -qm 'source baseline'
        $commit = (& git -C $source rev-parse HEAD).Trim()
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            function Assert-WorkflowPackageSourceRoot { param([string]$SourceRoot) }
            $receipt = [pscustomobject]@{ sourceRoot=$source; sourceCommit=$commit }
            Assert-WorkflowUpdateRecordedSource -Receipt $receipt
            [IO.File]::WriteAllText((Join-Path $source 'package.txt'), 'changed', [Text.UTF8Encoding]::new($false))
            try { Assert-WorkflowUpdateRecordedSource -Receipt $receipt; 'not-blocked' }
            catch { $_.Exception.Message }
        }
        $result | Should -Match 'WORKFLOW_UPDATE_SOURCE_CHANGED'
    }

    It 'verifies the full wide Unicode master write-set without losing <State> cleanliness' -TestCases @(
        @{ State='clean'; Dirty=$false }
        @{ State='dirty managed'; Dirty=$true }
    ) {
        param($State,$Dirty)
        $project=Join-Path $TestDrive ('Master large write-set Кириллица '+$State)
        New-Item -ItemType Directory -Force -Path $project|Out-Null
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'master-wide-status@example.invalid'
        & git -C $project config user.name 'Master Wide Status Test'
        & git -C $project config core.longpaths true
        $paths=@(1..645|ForEach-Object { 'managed/Каталог с пробелами/'+('подробное имя ' * 8)+('{0:D4}.md' -f $_) })
        $ownedPath=Join-Path $project $paths[0]
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ownedPath)|Out-Null
        [IO.File]::WriteAllText($ownedPath,'committed candidate',[Text.UTF8Encoding]::new($false))
        & git -C $project add --all
        $LASTEXITCODE|Should -Be 0
        & git -C $project commit -qm 'workflow candidate'
        $LASTEXITCODE|Should -Be 0
        $before=(& git -C $project rev-parse HEAD).Trim()
        ($paths -join ' ').Length|Should -BeGreaterThan 32767
        if($Dirty){[IO.File]::WriteAllText($ownedPath,'later managed edit',[Text.UTF8Encoding]::new($false))}
        $result=& {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            try{Refresh-WorkflowUpdateManagedIndexStat -ManagedPathSpecs $paths;$failure=''}catch{$failure=$_.Exception.Message}
            [pscustomobject]@{failure=$failure;head=Get-CurrentCommit;unstaged=@(Get-GitPathList -Arguments @('diff','--name-only','-z'));staged=@(Get-GitPathList -Arguments @('diff','--cached','--name-only','-z'));bytes=[IO.File]::ReadAllText($ownedPath)}
        }
        $result.head|Should -Be $before
        $result.staged.Count|Should -Be 0
        if($Dirty){
            $result.failure|Should -Match 'detected a real managed-file change after commit'
            $result.unstaged|Should -Be @($paths[0])
            $result.bytes|Should -Be 'later managed edit'
        }else{
            $result.failure|Should -Be ''
            $result.unstaged.Count|Should -Be 0
            $result.bytes|Should -Be 'committed candidate'
        }
    }

    It 'accepts the exact master workflow commit after a lost acknowledgement and rejects an unrelated commit path' {
        $project = Join-Path $TestDrive 'Master commit recovery Кириллица'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'master-recovery@example.invalid'
        & git -C $project config user.name 'Master Recovery Test'
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project 'AGENT-INSTALL.md'), 'before', [Text.UTF8Encoding]::new($false))
        & git -C $project add -- .agent-1c/project.json AGENT-INSTALL.md
        & git -C $project commit -qm 'installed baseline'
        $before = (& git -C $project rev-parse HEAD).Trim()
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $source = [pscustomobject]@{ root=(Join-Path $TestDrive 'exact source'); ref='master'; commit=('a' * 40); repo='fixture'; source='path' }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md') `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            [IO.File]::WriteAllText((Join-Path $project 'AGENT-INSTALL.md'), 'candidate', [Text.UTF8Encoding]::new($false))
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-commit-ready -Details @{
                preCommitHead=$before; plannedChangePaths=@('AGENT-INSTALL.md'); aiRulesPathsBefore=@(); clientSurfacePathsBefore=@()
            }
            $ready = Get-WorkflowUpdatePendingSnapshot
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $ready
            $pending = Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt $ready.receipt -Source $source
            $commit = Commit-WorkflowUpdate -Source $source
            $resumed = Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt $ready.receipt -Source $source
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-committed -Details @{
                preCommitHead=$before; plannedChangePaths=@('AGENT-INSTALL.md'); aiRulesPathsBefore=@(); clientSurfacePathsBefore=@()
            }
            $committed = Get-WorkflowUpdatePendingSnapshot
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $committed
            $wrong = [pscustomobject]@{ preCommitHead=$before; plannedChangePaths=@('USER-RULES.md') }
            $errorText = ''
            try { Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt $wrong -Source $source | Out-Null }
            catch { $errorText = $_.Exception.Message }
            [pscustomobject]@{ pending=$pending; commit=$commit; resumed=$resumed; phase=$committed.receipt.phase; errorText=$errorText }
        }
        $result.pending.committed | Should -BeFalse
        $result.commit.created | Should -BeTrue
        $result.resumed.committed | Should -BeTrue
        $result.resumed.commit | Should -Be $result.commit.commit
        $result.phase | Should -Be 'master-committed'
        $result.errorText | Should -Match 'WORKFLOW_UPDATE_MASTER_COMMIT_PATHS_CHANGED'
        [IO.File]::ReadAllText((Join-Path $project 'AGENT-INSTALL.md')) | Should -Be 'candidate'
    }

    It 'commits the original root snapshot write-set after rules advance: <Case>' -TestCases @(
        @{ Case='retired OpenSpec alias'; OwnedPath='.agents/skills/opsx-apply/SKILL.md'; Retired=$true }
        @{ Case='tracked client config with foreign prefix'; OwnedPath='.codex/config.toml'; Retired=$false }
    ) {
        param($Case,$OwnedPath,$Retired)
        $project=Join-Path $TestDrive ('Master interrupted rules Кириллица '+$Case)
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c'),(Split-Path -Parent (Join-Path $project $OwnedPath))|Out-Null
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'master-write-set@example.invalid'
        & git -C $project config user.name 'Master Write Set Test'
        $prefix="# Foreign configuration Кириллица`nuser_setting = 'keep'`n"
        [IO.File]::WriteAllText((Join-Path $project $OwnedPath),$prefix,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'),".agent-1c/`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.agent-1c/project.json'),'{"masterBranch":"master","aiRules":{"tools":["codex"]}}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.ai-rules.json'),'{"files":{}}',[Text.UTF8Encoding]::new($false))
        & git -C $project add -- .gitignore .ai-rules.json $OwnedPath
        & git -C $project commit -qm baseline
        $before=(& git -C $project rev-parse HEAD).Trim()
        $result=& {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            $source=[pscustomobject]@{root=(Join-Path $TestDrive 'exact payload');commit=('c'*40);repo='fixture';ref='master';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @($OwnedPath) -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            if($Retired){Remove-Item -LiteralPath (Join-Path $project $OwnedPath)}
            else{[IO.File]::WriteAllText((Join-Path $project $OwnedPath),($prefix+"# ITL managed block`nitl_endpoint = 'current'`n"),[Text.UTF8Encoding]::new($false))}
            # The advanced current manifest does not remember this original
            # owned path. The durable root snapshot still owns it literally.
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-commit-ready -Details @{
                preCommitHead=$before;plannedChangePaths=@($OwnedPath);aiRulesPathsBefore=@();clientSurfacePathsBefore=@()
            }
            $pending=Get-WorkflowUpdatePendingSnapshot
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
            $commit=Commit-WorkflowUpdate -Source $source -AiRulesPathsBefore @() -ClientSurfacePathsBefore @()
            [pscustomobject]@{commit=$commit;dirty=@(Get-GitPathList -Arguments @('status','--porcelain=v1','-z'));changed=@(Get-GitPathList -Arguments @('diff-tree','--no-commit-id','--name-only','-r','-z',$commit.commit))}
        }
        $result.commit.created|Should -BeTrue
        $result.changed|Should -Contain $OwnedPath
        $result.changed.Count|Should -Be 1
        $result.dirty|Should -BeNullOrEmpty
        if($Retired){Test-Path -LiteralPath (Join-Path $project $OwnedPath)|Should -BeFalse}
        else{[IO.File]::ReadAllText((Join-Path $project $OwnedPath))|Should -Be ($prefix+"# ITL managed block`nitl_endpoint = 'current'`n")}
    }

    It 'does not grant root commit ownership from arbitrary planned business paths' {
        $project=Join-Path $TestDrive 'Master unknown write-set Кириллица'
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c'),(Join-Path $project '.codex')|Out-Null
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'master-write-set@example.invalid'
        & git -C $project config user.name 'Master Write Set Test'
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'),".agent-1c/`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.codex/config.toml'),'before',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project 'business.txt'),'business before',[Text.UTF8Encoding]::new($false))
        & git -C $project add --all
        & git -C $project commit -qm baseline
        $before=(& git -C $project rev-parse HEAD).Trim()
        $result=& {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            $source=[pscustomobject]@{root=(Join-Path $TestDrive 'exact payload');commit=('c'*40);repo='fixture';ref='master';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.codex/config.toml') -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            [IO.File]::WriteAllText((Join-Path $project '.codex/config.toml'),'owned candidate',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $project 'business.txt'),'staged business',[Text.UTF8Encoding]::new($false))
            Invoke-Git @('add','--','business.txt')
            [IO.File]::WriteAllText((Join-Path $project 'business.txt'),'unstaged business',[Text.UTF8Encoding]::new($false))
            $indexBefore=(Get-GitOutput @('rev-parse',':business.txt')).Trim()
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-commit-ready -Details @{
                preCommitHead=$before;plannedChangePaths=@('.codex/config.toml','business.txt');aiRulesPathsBefore=@();clientSurfacePathsBefore=@()
            }
            try{Commit-WorkflowUpdate -Source $source|Out-Null;$failure=''}catch{$failure=$_.Exception.Message}
            [pscustomobject]@{failure=$failure;head=Get-CurrentCommit;indexBefore=$indexBefore;indexAfter=(Get-GitOutput @('rev-parse',':business.txt')).Trim();business=[IO.File]::ReadAllText((Join-Path $project 'business.txt'))}
        }
        $result.failure|Should -Match 'outside its managed allowlist.*business\.txt'
        $result.head|Should -Be $before
        $result.indexAfter|Should -Be $result.indexBefore
        $result.business|Should -Be 'unstaged business'
    }

    It 'preserves master when an original owned config backup is <BackupFault>' -TestCases @(
        @{BackupFault='missing'}
        @{BackupFault='corrupted'}
    ) {
        param($BackupFault)
        $project=Join-Path $TestDrive ('Master backup proof Кириллица '+$BackupFault)
        New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c'),(Join-Path $project '.codex')|Out-Null
        & git -C $project init -b master *> $null
        & git -C $project config user.email 'master-write-set@example.invalid'
        & git -C $project config user.name 'Master Write Set Test'
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'),".agent-1c/`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.codex/config.toml'),'foreign prefix before',[Text.UTF8Encoding]::new($false))
        & git -C $project add --all
        & git -C $project commit -qm baseline
        $before=(& git -C $project rev-parse HEAD).Trim()
        $result=& {
            . $helperPath -ProjectRoot $project -Action help -SkipAiRules *> $null
            $source=[pscustomobject]@{root=(Join-Path $TestDrive 'exact payload');commit=('c'*40);repo='fixture';ref='master';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.codex/config.toml') -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            [IO.File]::WriteAllText((Join-Path $project '.codex/config.toml'),'foreign prefix plus owned candidate',[Text.UTF8Encoding]::new($false))
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase master-commit-ready -Details @{
                preCommitHead=$before;plannedChangePaths=@('.codex/config.toml');aiRulesPathsBefore=@();clientSurfacePathsBefore=@()
            }
            $backup=$snapshot.records[0].backupPath
            if($BackupFault -eq 'missing'){Remove-Item -LiteralPath $backup}
            else{[IO.File]::WriteAllText($backup,'corrupted before bytes',[Text.UTF8Encoding]::new($false))}
            try{Commit-WorkflowUpdate -Source $source|Out-Null;$failure=''}catch{$failure=$_.Exception.Message}
            [pscustomobject]@{failure=$failure;head=Get-CurrentCommit;current=[IO.File]::ReadAllText((Join-Path $project '.codex/config.toml'));snapshotRetained=(Test-Path -LiteralPath $snapshot.root)}
        }
        $result.failure|Should -Match 'WORKFLOW_UPDATE_RECONCILIATION_BACKUP_INVALID'
        $result.head|Should -Be $before
        $result.current|Should -Be 'foreign prefix plus owned candidate'
        $result.snapshotRetained|Should -BeTrue
    }

    It 'restores an interrupted exact package copy, but preserves an edited candidate for reconciliation' {
        $project = Join-Path $TestDrive 'interrupted project'
        $source = Join-Path $TestDrive 'exact source'
        $projectManaged = Join-Path $project 'managed'
        $sourceManaged = Join-Path $source 'managed'
        New-Item -ItemType Directory -Force -Path $projectManaged, $sourceManaged | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectManaged 'file.txt'), 'before', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceManaged 'file.txt'), 'candidate', [Text.UTF8Encoding]::new($false))
        $lockPath = Join-Path $project '.agent-1c/dependency-lock.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
        $beforeLock = '{"schemaVersion":1,"dependencies":{"workflowPackage":{"repo":"old","ref":"old","commit":"old","source":"old","updatedAt":"before"},"custom":{"value":"keep"}}}'
        [IO.File]::WriteAllText($lockPath, $beforeLock, [Text.UTF8Encoding]::new($false))
        & git -C $source init --quiet
        & git -C $source config user.email 'copy-recovery@example.invalid'
        & git -C $source config user.name 'Copy Recovery Test'
        & git -C $source add --all
        & git -C $source commit --quiet -m candidate
        $sourceCommit = (& git -C $source rev-parse HEAD).Trim()
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
            function Resolve-WorkflowPackageSource { throw 'new-preflight-reached' }
            function Assert-WorkflowPackageSourceRoot { param([string]$SourceRoot) }
            function Get-WorkflowPackageCopyDirectoryPaths { @('managed') }
            function Get-WorkflowPackageCopyFilePaths { @() }
            $parent = Join-Path $project '.agent-1c/snapshots/workflow-update'
            $candidate = [pscustomobject]@{ root=$source; commit=$sourceCommit; repo='new repo'; ref='new ref'; source='path' }
            $first = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed', '.agent-1c/dependency-lock.json') -SnapshotParent $parent
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $first -Source $candidate -Phase prepared
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $first -Source $candidate -Phase copying
            [IO.File]::WriteAllText((Join-Path $projectManaged 'file.txt'), 'candidate', [Text.UTF8Encoding]::new($false))
            $afterLock = '{"schemaVersion":1,"dependencies":{"workflowPackage":{"repo":"new repo","ref":"new ref","commit":"' + $sourceCommit + '","source":"path","updatedAt":"after"},"custom":{"value":"keep"}}}'
            [IO.File]::WriteAllText($lockPath, $afterLock, [Text.UTF8Encoding]::new($false))
            $restarted = ''
            try { Update-WorkflowPackage *> $null } catch { $restarted = $_.Exception.Message }
            $firstRemoved = -not (Test-Path -LiteralPath $first.root)
            $afterRecovery = [IO.File]::ReadAllText((Join-Path $projectManaged 'file.txt'))
            $lockAfterRecovery = [IO.File]::ReadAllText($lockPath)

            $second = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed', '.agent-1c/dependency-lock.json') -SnapshotParent $parent
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $second -Source $candidate -Phase prepared
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $second -Source $candidate -Phase copying
            [IO.File]::WriteAllText((Join-Path $projectManaged 'file.txt'), 'user edit', [Text.UTF8Encoding]::new($false))
            $edited = ''
            try { Update-WorkflowPackage *> $null } catch { $edited = $_.Exception.Message }
            [pscustomobject]@{
                restarted = $restarted
                firstRemoved = $firstRemoved
                afterRecovery = $afterRecovery
                lockAfterRecovery = $lockAfterRecovery
                edited = $edited
                secondPreserved = Test-Path -LiteralPath $second.root
                finalText = [IO.File]::ReadAllText((Join-Path $projectManaged 'file.txt'))
            }
        }
        $result.restarted | Should -Match 'new-preflight-reached'
        $result.firstRemoved | Should -BeTrue
        $result.afterRecovery | Should -Be 'before'
        $result.lockAfterRecovery | Should -Be $beforeLock
        $result.edited | Should -Match 'WORKFLOW_UPDATE_COPY_RECONCILIATION_REQUIRED.*managed'
        $result.secondPreserved | Should -BeTrue
        $result.finalText | Should -Be 'user edit'
    }

    It 'does not treat an unrelated lock change as the interrupted workflow pin write' {
        $project = Join-Path $TestDrive 'lock edit project'
        $source = Join-Path $TestDrive 'lock edit source'
        $lockPath = Join-Path $project '.agent-1c/dependency-lock.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath), $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'source.txt'), 'candidate', [Text.UTF8Encoding]::new($false))
        & git -C $source init --quiet
        & git -C $source config user.email 'lock-recovery@example.invalid'
        & git -C $source config user.name 'Lock Recovery Test'
        & git -C $source add --all
        & git -C $source commit --quiet -m source
        $sourceCommit = (& git -C $source rev-parse HEAD).Trim()
        [IO.File]::WriteAllText($lockPath, '{"dependencies":{"workflowPackage":{"repo":"old","ref":"old","commit":"old","source":"old"},"custom":{"value":"keep"}}}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.agent-1c/dependency-lock.json') `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            $candidate = [pscustomobject]@{root=$source;commit=$sourceCommit;repo='new';ref='new';source='path'}
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $candidate -Phase prepared
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $candidate -Phase copying
            [IO.File]::WriteAllText($lockPath, ('{"dependencies":{"workflowPackage":{"repo":"new","ref":"new","commit":"' + $sourceCommit + '","source":"path"},"custom":{"value":"user edit"}}}'), [Text.UTF8Encoding]::new($false))
            $message = ''
            try { Restore-WorkflowUpdateInterruptedPackageCopy -Pending (Get-WorkflowUpdatePendingSnapshot) *> $null }
            catch { $message = $_.Exception.Message }
            [pscustomobject]@{message=$message;snapshotPreserved=(Test-Path -LiteralPath $snapshot.root);lockText=[IO.File]::ReadAllText($lockPath)}
        }
        $result.message | Should -Match 'WORKFLOW_UPDATE_COPY_RECONCILIATION_REQUIRED.*dependency-lock.json'
        $result.snapshotPreserved | Should -BeTrue
        $result.lockText | Should -Match 'user edit'
    }

    It 'discards only an interrupted backup-only snapshot, preserving an armed orphan' {
        $project = Join-Path $TestDrive 'backup-only project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $parent = Join-Path $project '.agent-1c/snapshots/workflow-update'
            $unapplied = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent $parent
            $pendingAfterBackup = Get-WorkflowUpdatePendingSnapshot
            $backupDiscarded = -not (Test-Path -LiteralPath $unapplied.root)
            $armed = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent $parent
            $markerPath = Join-Path $armed.root 'preparation.json'
            $marker = Read-Utf8Text -Path $markerPath | ConvertFrom-Json
            $marker.phase = 'armed'
            Write-Utf8TextAtomic -Path $markerPath -Value (($marker | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
            $armedError = ''
            try { Get-WorkflowUpdatePendingSnapshot *> $null } catch { $armedError = $_.Exception.Message }
            [pscustomobject]@{
                pendingAfterBackup = $pendingAfterBackup
                backupDiscarded = $backupDiscarded
                armedError = $armedError
                armedPreserved = Test-Path -LiteralPath $armed.root
                finalText = [IO.File]::ReadAllText($managed)
            }
        }
        $result.pendingAfterBackup | Should -BeNullOrEmpty
        $result.backupDiscarded | Should -BeTrue
        $result.armedError | Should -Match 'WORKFLOW_UPDATE_RECEIPT_MISSING'
        $result.armedPreserved | Should -BeTrue
        $result.finalText | Should -Be 'before'
    }

    It 'collects fork installer files and untracked OpenSpec scaffold before project writes' {
        $project = Join-Path $TestDrive 'old project'
        $fork = Join-Path $TestDrive 'fork candidate'
        $scaffoldFile = Join-Path $fork 'openspec/config.yaml'
        New-Item -ItemType Directory -Force -Path $project, (Split-Path -Parent $scaffoldFile) | Out-Null
        [IO.File]::WriteAllText($scaffoldFile, 'scaffold', [Text.UTF8Encoding]::new($false))
        $installer = @'
param([string]$Command,[string]$ProjectRoot,[string]$Source,[string]$Tools,[switch]$NonInteractive,[switch]$AssumeYes)
[IO.Directory]::CreateDirectory($ProjectRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $ProjectRoot '.ai-rules.json'), '{"files":{".codex/rules/mcp-policy.md":{"source":"content/rules/mcp-policy.md"},".codex/skills/openspec-update-change/SKILL.md":{"source":"content/openspec-bundle/codex"}}}', [Text.UTF8Encoding]::new($false))
'@
        [IO.File]::WriteAllText((Join-Path $fork 'install.ps1'), $installer, [Text.UTF8Encoding]::new($false))
        $paths = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            function Assert-AiRulesMigrationCandidateScope { param([string]$RulesRoot) }
            function Get-Agent1cTempRoot { $TestDrive }
            Get-AiRulesCandidateInstallInventory -Checkout ([pscustomobject]@{root=$fork}) -Tools @('codex')
        }
        $paths | Should -Contain '.codex/rules/mcp-policy.md'
        $paths | Should -Contain '.codex/skills/openspec-update-change/SKILL.md'
        $paths | Should -Contain 'openspec/config.yaml'
        @(Get-ChildItem -LiteralPath $TestDrive -Directory -Filter 'itl-ai-rules-preflight-*') | Should -HaveCount 0
        @(Get-ChildItem -LiteralPath $project -Force) | Should -HaveCount 0
    }

    It 'includes newly generated client files in the pre-copy write-set' {
        $project = Join-Path $TestDrive 'new client project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $paths = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            function Get-AgentTargets { @('codex', 'cursor') }
            function Get-WorkflowPackageCopyDirectoryPaths { @() }
            function Get-WorkflowPackageCopyFilePaths { @() }
            function Get-WorkflowUpdateManagedPathSpecs { @() }
            function Get-ItlClientAdapter {
                param([string]$Client)
                if ($Client -eq 'codex') { return [pscustomobject]@{mcpPath='.codex/config.toml'} }
                return [pscustomobject]@{mcpPath='.cursor/mcp.json'}
            }
            function Get-ItlExpectedSurfaceFiles {
                param([string]$Client, [string]$SourceRoot)
                if ($SourceRoot -ne 'C:\qualified source') { throw 'wrong source' }
                if ($Client -eq 'codex') { return @{ '.agents/skills/itl-update-workflow/SKILL.md' = 'new' } }
                return @{ '.cursor/commands/itl-update-workflow.md' = 'new' }
            }
            $writeSet = @(Get-WorkflowUpdateSnapshotRelativePaths -SourceRoot 'C:\qualified source' `
                -AiRulesPathsAfter @('.agents/skills/grill-me/SKILL.md'))
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths $writeSet `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            @($snapshot.records | Where-Object { -not $_.existed } | Select-Object -ExpandProperty relativePath)
        }
        $paths | Should -Contain '.agents/skills/itl-update-workflow/SKILL.md'
        $paths | Should -Contain '.cursor/commands/itl-update-workflow.md'
        $paths | Should -Contain '.agents/skills/grill-me/SKILL.md'
        $paths | Should -Contain '.codex/config.toml'
        $paths | Should -Contain '.cursor/mcp.json'
    }

    It 'restarts preflight after an unchanged prepared snapshot but preserves a changed one' {
        $project = Join-Path $TestDrive 'prepared project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
            function Resolve-WorkflowPackageSource { throw 'new-preflight-reached' }
            $source = [pscustomobject]@{root='C:\source';commit='1111111111111111111111111111111111111111'}
            $snapshotParent = Join-Path $project '.agent-1c/snapshots/workflow-update'
            $first = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent $snapshotParent
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $first -Source $source -Phase prepared
            $unchanged = ''
            try { Update-WorkflowPackage *> $null } catch { $unchanged = $_.Exception.Message }
            $firstRemoved = -not (Test-Path -LiteralPath $first.root)

            $second = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent $snapshotParent
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $second -Source $source -Phase prepared
            [IO.File]::WriteAllText($managed, 'later user edit', [Text.UTF8Encoding]::new($false))
            $changed = ''
            try { Update-WorkflowPackage *> $null } catch { $changed = $_.Exception.Message }
            [pscustomobject]@{
                unchanged = $unchanged
                firstRemoved = $firstRemoved
                changed = $changed
                secondPreserved = Test-Path -LiteralPath $second.root
                finalText = [IO.File]::ReadAllText($managed)
            }
        }
        $result.unchanged | Should -Match 'new-preflight-reached'
        $result.firstRemoved | Should -BeTrue
        $result.changed | Should -Match 'WORKFLOW_UPDATE_PRE_COPY_INTERRUPTED.*managed.txt'
        $result.secondPreserved | Should -BeTrue
        $result.finalText | Should -Be 'later user edit'
    }

    It 'rejects a managed file change between backup and prepared receipt' {
        $project = Join-Path $TestDrive 'drifting snapshot project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            [IO.File]::WriteAllText($managed, 'concurrent edit', [Text.UTF8Encoding]::new($false))
            $message = ''
            try {
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot `
                    -Source ([pscustomobject]@{root='C:\source';commit='1111111111111111111111111111111111111111'}) -Phase prepared
            } catch { $message = $_.Exception.Message }
            [pscustomobject]@{
                message = $message
                receiptExists = Test-Path -LiteralPath (Join-Path $snapshot.root 'transaction.json')
                finalText = [IO.File]::ReadAllText($managed)
            }
        }
        $result.message | Should -Match 'WORKFLOW_UPDATE_PREPARE_DRIFT.*managed.txt'
        $result.receiptExists | Should -BeFalse
        $result.finalText | Should -Be 'concurrent edit'
    }

    It 'removes an incomplete snapshot when reading the before state fails' {
        $project = Join-Path $TestDrive 'locked before project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $snapshotParent = Join-Path $project '.agent-1c/snapshots/workflow-update'
        $lock = [IO.File]::Open($managed, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $message = & {
                . $helperPath -ProjectRoot $project -Action help *> $null
                try { New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') -SnapshotParent $snapshotParent *> $null; '' }
                catch { $_.Exception.Message }
            }
            $message | Should -Not -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $snapshotParent -Directory -ErrorAction SilentlyContinue) | Should -HaveCount 0
        } finally {
            $lock.Dispose()
        }
        [IO.File]::ReadAllText($managed) | Should -Be 'before'
    }

    It 'rejects a junction in the write-set before creating a snapshot' {
        $project = Join-Path $TestDrive 'project root'
        $outside = Join-Path $TestDrive 'outside root'
        New-Item -ItemType Directory -Force -Path $project, $outside | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'foreign.txt'), 'keep', [Text.UTF8Encoding]::new($false))
        $junction = Join-Path $project 'managed'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $result = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            try {
                New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed/foreign.txt') `
                    -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update') *> $null
                ''
            } catch { $_.Exception.Message }
        }
        $result | Should -Match 'WORKFLOW_UPDATE_REPARSE_PATH'
        (Test-Path -LiteralPath (Join-Path $project '.agent-1c/snapshots/workflow-update')) | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $outside 'foreign.txt')) | Should -Be 'keep'
    }

    It 'blocks a later edit and resumes unchanged post-copy state without recopying the package' {
        $project = Join-Path $TestDrive 'Проект с пробелом'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $previousSource = $env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH = ''
            $result = & {
                . $helperPath -ProjectRoot $project -Action help *> $null
                function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
                function Assert-WorkflowUpdateRecordedSource { param([object]$Receipt) }
                function Invoke-Agent1cFreshProcess { param([string[]]$AdditionalArguments,[switch]$ReturnExitStatus); $script:resumeCalls++; [pscustomobject]@{exitCode=0} }
                function Assert-WorkflowDevelopmentBranchRolloutComplete { param([string]$SourceCommit) }
                $script:resumeCalls = 0
                $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') `
                    -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
                $source = [pscustomobject]@{ root = 'C:\source'; commit = '1111111111111111111111111111111111111111' }
                [IO.File]::WriteAllText($managed, 'candidate', [Text.UTF8Encoding]::new($false))
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-failed

                [IO.File]::WriteAllText($managed, 'user edit', [Text.UTF8Encoding]::new($false))
                $conflict = ''
                try { Update-WorkflowPackage *> $null } catch { $conflict = $_.Exception.Message }
                $receiptKept = Test-Path -LiteralPath (Join-Path $snapshot.root 'transaction.json') -PathType Leaf
                [IO.File]::WriteAllText($managed, 'candidate', [Text.UTF8Encoding]::new($false))
                Update-WorkflowPackage *> $null
                [pscustomobject]@{
                    conflict = $conflict
                    receiptKept = $receiptKept
                    resumeCalls = $script:resumeCalls
                    snapshotRemoved = -not (Test-Path -LiteralPath $snapshot.root)
                    finalText = [IO.File]::ReadAllText($managed)
                }
            }
            $result.conflict | Should -Match 'WORKFLOW_UPDATE_RECONCILIATION_REQUIRED.*managed.txt'
            $result.receiptKept | Should -BeTrue
            $result.resumeCalls | Should -Be 1
            $result.snapshotRemoved | Should -BeTrue
            $result.finalText | Should -Be 'candidate'
        } finally {
            $env:ITL_WORKFLOW_SOURCE_PATH = $previousSource
        }
    }

    It 'retains a completed receipt without repeating successful post-copy after a retention failure' {
        $project = Join-Path $TestDrive 'clean up project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $oldSource = $env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH = ''
            $result = & {
                . $helperPath -ProjectRoot $project -Action help *> $null
                function Assert-WorkflowPackageUpdateContext { param([switch]$DeferCleanCheck) }
                function Assert-WorkflowUpdateRecordedSource { param([object]$Receipt) }
                function Invoke-Agent1cFreshProcess { param([string[]]$AdditionalArguments,[switch]$ReturnExitStatus); $script:postCopyCalls++; [pscustomobject]@{exitCode=0} }
                function Assert-WorkflowDevelopmentBranchRolloutComplete { param([string]$SourceCommit) }
                $script:originalRetain = (Get-Command Retain-WorkflowUpdateRollbackSnapshot).ScriptBlock
                function Retain-WorkflowUpdateRollbackSnapshot {
                    param([object]$Snapshot)
                    if ($script:failCleanup) { $script:failCleanup = $false; throw 'cleanup stopped' }
                    & $script:originalRetain -Snapshot $Snapshot
                }
                $script:postCopyCalls = 0
                $script:failCleanup = $true
                $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') `
                    -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
                $source = [pscustomobject]@{ root = 'C:\source'; commit = '1111111111111111111111111111111111111111' }
                [IO.File]::WriteAllText($managed, 'candidate', [Text.UTF8Encoding]::new($false))
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
                $cleanupError = ''
                try { Update-WorkflowPackage *> $null } catch { $cleanupError = $_.Exception.Message }
                $phaseAfterFailure = (Read-Utf8Text -Path (Join-Path $snapshot.root 'transaction.json') | ConvertFrom-Json).phase
                Update-WorkflowPackage *> $null
                [pscustomobject]@{
                    cleanupError = $cleanupError
                    phaseAfterFailure = $phaseAfterFailure
                    postCopyCalls = $script:postCopyCalls
                    snapshotRemoved = -not (Test-Path -LiteralPath $snapshot.root)
                    completedSnapshots = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshot.root) -Directory -Filter 'itl-workflow-update-completed-*').Count
                }
            }
            $result.cleanupError | Should -Match 'WORKFLOW_UPDATE_SNAPSHOT_CLEANUP_REQUIRED'
            $result.phaseAfterFailure | Should -Be 'post-copy-complete'
            $result.postCopyCalls | Should -Be 1
            $result.snapshotRemoved | Should -BeTrue
            $result.completedSnapshots | Should -Be 1
        } finally {
            $env:ITL_WORKFLOW_SOURCE_PATH = $oldSource
        }
    }

    It 'preserves a completed master and rollback state when the fresh child reports deferred branches' {
        $project = Join-Path $TestDrive 'Частичное обновление после terminal checkpoint'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        $managed = Join-Path $project 'managed.txt'
        [IO.File]::WriteAllText($managed, 'before', [Text.UTF8Encoding]::new($false))
        $actual = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $script:testSource = [pscustomobject]@{ root='C:\source'; commit='1111111111111111111111111111111111111111' }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            [IO.File]::WriteAllText($managed, 'candidate', [Text.UTF8Encoding]::new($false))
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $script:testSource -Phase copy-complete
            function Invoke-Agent1cFreshProcess {
                param([string[]]$AdditionalArguments)
                $pending = Get-WorkflowUpdatePendingSnapshot
                $report = [ordered]@{ schemaVersion=1; sourceCommit=$script:testSource.commit
                    mainRoot=[string]$script:ProjectRoot; roots=@([ordered]@{
                        branch='itldev/paused'; status='deferred'; reason='active-lifecycle-lock'
                    }) }
                Write-Utf8TextAtomic -Path (Join-Path $script:ProjectRoot '.agent-1c/snapshots/workflow-update-rollout.json') `
                    -Value (($report | ConvertTo-Json -Depth 5) + "`n")
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $script:testSource -Phase post-copy-complete
                Retain-WorkflowUpdateRollbackSnapshot -Snapshot $pending.snapshot | Out-Null
                throw 'WORKFLOW_UPDATE_BRANCHES_INCOMPLETE: child reported deferred branch'
            }
            $failure = ''
            try { Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $script:testSource }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{ failure=$failure; managed=[IO.File]::ReadAllText($managed)
                snapshotExists=(Test-Path -LiteralPath $snapshot.root) }
        }
        $actual.failure | Should -Match '^WORKFLOW_UPDATE_BRANCHES_INCOMPLETE:.*itldev/paused=deferred'
        $actual.managed | Should -Be 'candidate'
        $actual.snapshotExists | Should -BeFalse
    }

    It 'keeps a child terminal receipt when its cleanup reports failure' {
        $project = Join-Path $TestDrive 'Terminal receipt cleanup failure'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        [IO.File]::WriteAllText((Join-Path $project 'managed.txt'), 'before', [Text.UTF8Encoding]::new($false))
        $actual = & {
            . $helperPath -ProjectRoot $project -Action help *> $null
            $script:testSource = [pscustomobject]@{ root='C:\source'; commit='1111111111111111111111111111111111111111' }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('managed.txt') `
                -SnapshotParent (Join-Path $project '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $script:testSource -Phase copy-complete
            function Invoke-Agent1cFreshProcess {
                param([string[]]$AdditionalArguments)
                $pending = Get-WorkflowUpdatePendingSnapshot
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $script:testSource -Phase post-copy-complete
                throw 'simulated cleanup failure'
            }
            $failure = ''
            try { Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $script:testSource }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{ failure=$failure; phase=(Read-Utf8Text -Path (Join-Path $snapshot.root 'transaction.json') | ConvertFrom-Json).phase }
        }
        $actual.failure | Should -Match '^WORKFLOW_UPDATE_SNAPSHOT_CLEANUP_REQUIRED:'
        $actual.phase | Should -Be 'post-copy-complete'
    }
}

Describe 'First installed workflow upgrade handoff' {
    It 'starts the source generation helper before touching an old installed helper' {
        $source = Join-Path $TestDrive 'Источник с пробелом'
        $project = Join-Path $TestDrive 'Старый проект с пробелом'
        $sourceHelper = Join-Path $source '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $oldHelper = Join-Path $project '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceHelper), (Split-Path -Parent $oldHelper) | Out-Null
        [IO.File]::WriteAllText($sourceHelper, @'
param([string]$ProjectRoot, [string]$Action)
if ($Action -ne 'update-workflow') { throw 'unexpected action' }
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'source-owner.txt'), [string]$env:ITL_WORKFLOW_SOURCE_PATH, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'clean-source-required.txt'), [string]$env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE, [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($oldHelper, "throw 'old helper started'", [Text.UTF8Encoding]::new($false))
        & git -C $source init --quiet
        & git -C $source config user.email 'handoff@example.invalid'
        & git -C $source config user.name 'ITL Handoff Test'
        & git -C $source add .
        & git -C $source commit --quiet -m 'source helper'
        $LASTEXITCODE | Should -Be 0
        $beforeSource = $env:ITL_WORKFLOW_SOURCE_PATH
        $beforeCleanSource = $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH = 'prior-value'
            $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = 'prior-value'
            & $launcher -ProjectRoot $project -SourceRoot $source
            (Get-Content -LiteralPath (Join-Path $project 'source-owner.txt') -Raw -Encoding UTF8) | Should -Be ([IO.Path]::GetFullPath($source))
            (Get-Content -LiteralPath (Join-Path $project 'clean-source-required.txt') -Raw -Encoding UTF8) | Should -Be 'true'
            $env:ITL_WORKFLOW_SOURCE_PATH | Should -Be 'prior-value'
            $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE | Should -Be 'prior-value'
        } finally {
            $env:ITL_WORKFLOW_SOURCE_PATH = $beforeSource
            $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = $beforeCleanSource
        }
    }

    It 'rejects a missing current helper before touching the installed project' {
        $source = Join-Path $TestDrive 'empty source'
        $project = Join-Path $TestDrive 'installed project'
        New-Item -ItemType Directory -Force -Path $source, $project | Out-Null
        { & $launcher -ProjectRoot $project -SourceRoot $source } | Should -Throw '*Current ITL workflow helper was not found*'
        @(Get-ChildItem -LiteralPath $project -Force) | Should -HaveCount 0
    }

    It 'rejects a project nested inside its package source' {
        $source = Join-Path $TestDrive 'source root'
        $project = Join-Path $source 'nested project'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        { & $launcher -ProjectRoot $project -SourceRoot $source } | Should -Throw '*must be separate directories*'
        @(Get-ChildItem -LiteralPath $project -Force) | Should -HaveCount 0
    }

    It 'refuses a dirty exact source before the first project copy' {
        $source = Join-Path $TestDrive 'Точный source с пробелом'
        $project = Join-Path $TestDrive 'Старый проект'
        $required = @(
            'install-agent-1c-workflow.ps1', 'AGENT-INSTALL.md',
            '.agents/skills/1c-workflow/scripts/agent-1c.ps1',
            '.agents/skills/1c-workflow-fast/SKILL.md',
            '.agents/skills/product-docs/SKILL.md',
            '.agents/skills/itl-roctup-1c-data/SKILL.md',
            '.agents/skills/itl-vanessa-ui-mcp/SKILL.md',
            '.agents/skills/itl-remote-runner/SKILL.md',
            '.agents/skills/itl-remote-agent/SKILL.md',
            '.agents/skills/itl-performance/SKILL.md',
            'templates/USER-RULES.append.md'
        )
        foreach ($relative in $required) {
            $path = Join-Path $source $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, 'source', [Text.UTF8Encoding]::new($false))
        }
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        & git -C $source init --quiet
        & git -C $source config user.email 'source@example.invalid'
        & git -C $source config user.name 'Source Test'
        & git -C $source add .
        & git -C $source commit --quiet -m source
        $LASTEXITCODE | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $source 'AGENT-INSTALL.md'), 'changed after commit', [Text.UTF8Encoding]::new($false))

        $oldSource = $env:ITL_WORKFLOW_SOURCE_PATH
        $oldRequired = $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH = $source
            $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = 'true'
            $message = & {
                . $helperPath -ProjectRoot $project -Action help *> $null
                try { Resolve-WorkflowPackageSource *> $null; '' }
                catch { $_.Exception.Message }
            }
            $message | Should -Match 'WORKFLOW_SOURCE_DIRTY'
        } finally {
            $env:ITL_WORKFLOW_SOURCE_PATH = $oldSource
            $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = $oldRequired
        }
    }

    It 'propagates a failed current helper exit without falling back to the installed helper' {
        $source = Join-Path $TestDrive 'failed source with spaces'
        $project = Join-Path $TestDrive 'old project with spaces'
        $sourceHelper = Join-Path $source '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceHelper), $project | Out-Null
        [IO.File]::WriteAllText($sourceHelper, 'exit 7', [Text.UTF8Encoding]::new($false))
        & git -C $source init --quiet
        & git -C $source config user.email 'handoff@example.invalid'
        & git -C $source config user.name 'ITL Handoff Test'
        & git -C $source add .
        & git -C $source commit --quiet -m source
        $LASTEXITCODE | Should -Be 0
        & pwsh -NoProfile -File $launcher -ProjectRoot $project -SourceRoot $source *> $null
        $LASTEXITCODE | Should -Be 7
    }
}
