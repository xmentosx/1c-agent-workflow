BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Shared Release admission decisions' -Tag 'ReleaseAdmissionContract' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
        function Get-AdmissionRunnerDefinition {
            param($Name)
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'),[ref]$tokens,[ref]$errors)
            if($errors){throw 'Release owner must parse'}
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$false)
            if(-not $node){throw "Missing Release owner $Name"};$node.Extent.Text
        }
        function New-AdmissionMergeFixture {
            param($Root,$CursorKind='')
            $utf8=[Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force (Join-Path $Root 'src/cf'),(Join-Path $Root '.kilo'),(Join-Path $Root '.agent-1c') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"exportPath":"src/cf","aiRules":{"tools":["codex"]}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Configuration.xml'),'baseline',$utf8)
            & git -C $Root init -q -b master
            & git -C $Root config user.name 'Release merge admission'
            & git -C $Root config user.email 'merge@example.invalid'
            & git -C $Root add --all
            & git -C $Root commit -qm baseline
            & git -C $Root checkout -q -b itldev/admission
            [IO.File]::WriteAllText((Join-Path $Root 'branch.txt'),'branch workload',$utf8)
            & git -C $Root add -- branch.txt
            & git -C $Root commit -qm branch
            $anchor=(& git -C $Root rev-parse HEAD).Trim()
            & git -C $Root checkout -q master
            [IO.File]::WriteAllText((Join-Path $Root 'main.txt'),'main baseline',$utf8)
            & git -C $Root add -- main.txt
            & git -C $Root commit -qm main
            $main=(& git -C $Root rev-parse HEAD).Trim()
            & git -C $Root checkout -q itldev/admission
            & git -C $Root merge --no-ff -qm 'ordinary refresh' master
            if($LASTEXITCODE -ne 0){throw 'Original managed merge must exist'}
            if($CursorKind){
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/ConfigDumpInfo.xml'),'cursor',$utf8)
                & git -C $Root add -- src/cf/ConfigDumpInfo.xml
                if($CursorKind -eq 'state'){
                    [IO.File]::WriteAllText((Join-Path $Root '.kilo/kilo.json'),'{}',$utf8)
                    & git -C $Root add -- .kilo/kilo.json
                    & git -C $Root commit -qm 'chore: persist branch refresh state'
                }else{& git -C $Root commit -qm 'chore: persist branch configuration synchronization cursor'}
            }
            return @{root=$Root;head=(& git -C $Root rev-parse HEAD).Trim();anchor=$anchor;main=$main}
        }
    }

    It 'preserves the original managed <Kind> transition in early and runner predicates without changing Git' -ForEach @(@{Kind='merge'},@{Kind='cursor'},@{Kind='state'}) {
        $fixture=New-AdmissionMergeFixture (Join-Path $TestDrive ('Переход с пробелом '+$Kind)) $(if($Kind -eq 'merge'){''}else{$Kind})
        . ([scriptblock]::Create((Get-AdmissionRunnerDefinition 'Test-E2EManagedRefreshHead')))
        $context=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/admission';resumeMode='Auto';workflowRoot=$RepoRoot;
            currentHead=$fixture.head;masterHead=$fixture.main;exportPath='src/cf';worktreeClean=$true;
            workflowCommit='';workflowTree='';runnerSha256='';helperSha256='';aiRulesCommit='';projectConfigSha256='';clientSelection='current'}
        $checkpoint=@{schemaVersion=3;expectedHead=$fixture.anchor;identity=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/admission';clientSelection='previous'};stages=@{}}
        (Get-E2EReleaseCheckpointAdmission $context $checkpoint).allowed | Should -BeTrue
        Test-E2EManagedRefreshHead $fixture.root $fixture.head $fixture.anchor $fixture.main 'src/cf' $RepoRoot | Should -BeTrue
        (& git -C $fixture.root rev-parse HEAD).Trim() | Should -BeExactly $fixture.head
        @(& git -C $fixture.root status --porcelain) | Should -BeNullOrEmpty
    }

    It 'never reuses or rewrites a passed stage when cross-source continuation has no proof' {
        & {
            . ([scriptblock]::Create((Get-AdmissionRunnerDefinition 'Test-E2EStagePassed')))
            $checkpoint=@{stages=@{'ondemand-mcp'=@{status='passed';fingerprint='same';evidencePath=''}}}
            $crossReleaseReuse=$true;$releaseContinuationProof=$null;$releaseSourceContinuationRequired=$true;$previousRunnerSha256='previous';$continuationBoundaryStage=''
            $script:invalidatedStages=@();$script:invalidationDetails=@();$script:checkpointWrites=0
            function Get-E2EStageFingerprint {param($Name,$RunnerSha256)'same'}
            function Write-E2ECheckpoint {$script:checkpointWrites++}
            $before=$checkpoint|ConvertTo-Json -Depth 8
            Test-E2EStagePassed 'ondemand-mcp' | Should -BeFalse
            ($checkpoint|ConvertTo-Json -Depth 8) | Should -BeExactly $before
            $script:checkpointWrites | Should -Be 0
            $script:invalidationDetails[0].reason | Should -Match 'no exact Targeted proof'
        }
    }

    It 'distinguishes exact source identity from changed source without weakening stage input checks' {
        & {
            $sourceCommit='a'*40;$sourceTree='b'*40;$head='c'*40
            $context=@{workflowRoot=$RepoRoot;projectRoot='main';worktreePath='branch';branch='itldev/test';workflowCommit=$sourceCommit;workflowTree=$sourceTree;runnerSha256='runner';aiRulesCommit='fork';helperSha256='current-helper';clientSelection='client';projectConfigSha256='config';resumeMode='Auto';currentHead=$head;masterHead=$head;worktreeClean=$true;exportPath='src/cf'}
            $checkpoint=@{schemaVersion=3;expectedHead=$head;identity=@{projectRoot='main';worktreePath='branch';branch='itldev/test';workflowCommit=$sourceCommit;workflowTree=$sourceTree;runnerSha256='runner';aiRulesCommit='fork';helperSha256='old-helper';clientSelection='client';projectConfigSha256='config'}}
            $script:sourceProofCalls=0
            function Get-WorkflowContinuationProof {$script:sourceProofCalls++;$null}
            $sameSource=Get-E2EReleaseCheckpointAdmission -Context $context -Checkpoint $checkpoint
            $sameSource.allowed | Should -BeTrue
            $sameSource.crossReleaseReuse | Should -BeTrue
            $sameSource.sourceContinuationRequired | Should -BeFalse
            $script:sourceProofCalls | Should -Be 0
            $stage=@{status='passed';fingerprint='same'}
            (Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $stage -CurrentFingerprint 'same' -CrossReleaseReuse $true -SourceContinuationRequired $sameSource.sourceContinuationRequired).action | Should -BeExactly 'reuse'
            (Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $stage -CurrentFingerprint 'changed' -CrossReleaseReuse $true -SourceContinuationRequired $sameSource.sourceContinuationRequired).action | Should -BeExactly 'rerun'
            foreach($field in @('workflowCommit','workflowTree')) {
                $original=$checkpoint.identity[$field];$checkpoint.identity[$field]='d'*40
                $changedSource=Get-E2EReleaseCheckpointAdmission -Context $context -Checkpoint $checkpoint
                $changedSource.allowed | Should -BeTrue
                $changedSource.sourceContinuationRequired | Should -BeTrue
                (Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $stage -CurrentFingerprint 'same' -CrossReleaseReuse $true -SourceContinuationRequired $changedSource.sourceContinuationRequired).action | Should -BeExactly 'rerun'
                $checkpoint.identity[$field]=$original
            }
            $script:sourceProofCalls | Should -Be 2
        }
    }

    It 'keeps rebind eligibility pure and limits it to a proven earlier passed stage' {
        $record=@{status='passed';fingerprint='legacy'}
        $before=$record|ConvertTo-Json
        $beforeFailure=Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'ondemand-mcp'
        $beforeFailure.action | Should -BeExactly 'rebind'
        (Get-E2EAdmissionStageDecision -Name 'extension-smoke' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'config-cadence').action | Should -BeExactly 'rerun'
        $record.status='failed'
        (Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'ondemand-mcp').action | Should -BeExactly 'rerun'
        $record.status='passed'
        ($record|ConvertTo-Json) | Should -BeExactly $before
    }

    It 'loads only isolated stage definitions and leaves ambient script registry and functions untouched' {
        $script:ReleaseE2EStageDefinitions=@{sentinel='outer'}
        $before=@(Get-Command Register-ReleaseE2EStageDefinition -ErrorAction SilentlyContinue)
        $definitions=Get-E2EAdmissionStageDefinitions $RepoRoot
        $definitions.Count | Should -Be 8
        $script:ReleaseE2EStageDefinitions.Count | Should -Be 1
        $script:ReleaseE2EStageDefinitions.sentinel | Should -BeExactly 'outer'
        @(Get-Command Register-ReleaseE2EStageDefinition -ErrorAction SilentlyContinue).Count | Should -Be $before.Count
    }

    It 'invalidates the changed stage and its dependency consumers while keeping unrelated schema 2 proof stable' {
        $root=Join-Path $TestDrive 'Fingerprint путь CRLF';$modules=Join-Path $root 'scripts/release-e2e'
        New-Item -ItemType Directory -Force $modules,(Join-Path $root 'input') | Out-Null
        $utf8=[Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $root 'scripts/stand-env-identity.ps1'),'environment owner',$utf8)
        foreach($name in @('base','child','unrelated')){[IO.File]::WriteAllText((Join-Path $modules "$name.ps1"),"stage $name",$utf8)}
        $shared=Join-Path $root 'input/Общий модуль.bsl'
        [IO.File]::WriteAllText($shared,"Процедура Первая()`r`nКонецПроцедуры`r`n",$utf8)
        [IO.File]::WriteAllText((Join-Path $root 'input/Другой.bsl'),'other',$utf8)
        $definitions=@{
            base=@{version=1;paths=@('input/Общий модуль.bsl');dependsOn=@();moduleFile='base.ps1'}
            child=@{version=1;paths=@();dependsOn=@('base');moduleFile='child.ps1'}
            unrelated=@{version=1;paths=@('input/Другой.bsl');dependsOn=@();moduleFile='unrelated.ps1'}
        }
        $context=@{workflowRoot=$root;stageModuleRoot=$modules;stageDefinitions=$definitions;trackedInputFilesProvided=$true;trackedInputFiles=@();
            aiRulesCommit='fork';aiRulesTree='fork-tree';projectConfigSha256='project';clientSelection='codex';serverConfiguration=@{}}
        $before=@{};foreach($name in @('base','child','unrelated')){$before[$name]=Get-E2EAdmissionStageFingerprint $context $name}
        [IO.File]::AppendAllText($shared, "// проверка`r`n", $utf8)
        (Get-E2EAdmissionStageFingerprint $context 'base') | Should -Not -Be $before.base
        (Get-E2EAdmissionStageFingerprint $context 'child') | Should -Not -Be $before.child
        (Get-E2EAdmissionStageFingerprint $context 'unrelated') | Should -BeExactly $before.unrelated
        $context.clientSelection='kilocode'
        (Get-E2EAdmissionStageFingerprint $context 'unrelated') | Should -Not -Be $before.unrelated
    }

    It 'rejects corrupted passed stage evidence before any checkpoint or evidence write' {
        $evidence=Join-Path $TestDrive 'Исходный receipt с пробелом.json'
        [IO.File]::WriteAllText($evidence,'unit receipt',[Text.UTF8Encoding]::new($false))
        $record=@{status='passed';fingerprint='same';evidencePath=$evidence;evidenceSha256=Get-E2EAdmissionFileSha256 $evidence}
        [IO.File]::AppendAllText($evidence,' tampered')
        $badHash=Get-E2EAdmissionFileSha256 $evidence
        {Assert-E2EAdmissionFile -Path $record.evidencePath -Sha256 $record.evidenceSha256 -Label 'stage evidence'} | Should -Throw '*RELEASE_E2E_CACHE_CORRUPT*'
        (Get-E2EAdmissionFileSha256 $evidence) | Should -BeExactly $badHash
        $record.fingerprint | Should -BeExactly 'same'
    }

    It 'preserves case-compatible SHA identity while requiring the exact selected client identity' {
        $context=@{projectRoot=$TestDrive;worktreePath=$TestDrive;branch='itldev/admission';resumeMode='Auto';workflowRoot=$RepoRoot;currentHead='same';masterHead='same';exportPath='src/cf';worktreeClean=$true;
            workflowCommit=('a'*40);workflowTree=('b'*40);runnerSha256=('c'*64);helperSha256=('d'*64);aiRulesCommit=('e'*40);projectConfigSha256=('f'*64);clientSelection='codex'}
        $identity=@{};foreach($name in @('projectRoot','worktreePath','branch','workflowCommit','workflowTree','runnerSha256','helperSha256','aiRulesCommit','projectConfigSha256','clientSelection')){$identity[$name]=$context[$name]}
        foreach($name in @('workflowCommit','workflowTree','runnerSha256','helperSha256','aiRulesCommit','projectConfigSha256')){$identity[$name]=$identity[$name].ToUpperInvariant()}
        $checkpoint=@{schemaVersion=3;expectedHead='same';identity=$identity}
        (Get-E2EReleaseCheckpointAdmission $context $checkpoint).exactIdentity | Should -BeTrue
        $identity.clientSelection='CODEX'
        $decision=Get-E2EReleaseCheckpointAdmission $context $checkpoint
        $decision.allowed | Should -BeTrue
        $decision.exactIdentity | Should -BeFalse
        $decision.continuationProof | Should -BeNullOrEmpty
    }
}
