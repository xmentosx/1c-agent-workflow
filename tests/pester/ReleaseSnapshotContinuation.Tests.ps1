BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Release on-demand application snapshot continuation' -Tag 'OnDemandSnapshotContinuation' {
    BeforeAll {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'),[ref]$tokens,[ref]$errors)
        if($errors){throw 'Release owner must parse'}
        foreach($name in @('Get-E2EFileSha256','Assert-E2ECheckpointFile','Restore-E2EStateFiles','Restore-E2EInfobaseSnapshot')){
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        $body=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('Invoke-E2EHelper -Action "release-e2e-prepare-ondemand"')},$true)|Sort-Object {$_.Extent.Text.Length})[0].Body
        $statements=@()
        foreach($statement in $body.Statements){
            $statements+=$statement.Extent.Text
            if($statement.Extent.Text -match '^Invoke-E2EHelper -Action "release-e2e-prepare-ondemand"'){break}
        }
        $onDemandPreparation=[scriptblock]::Create(($statements -join "`n"))
    }
    It 'preserves the native application boundary for <Case>' -ForEach @(
        @{Case='cross-source passed config';Cross=$true;Passed=$true;Corrupt=$false;Ready=$false;ExpectedRestore=1;ExpectedError=''},
        @{Case='same-source recovered live base';Cross=$false;Passed=$true;Corrupt=$false;Ready=$true;ExpectedRestore=0;ExpectedError=''},
        @{Case='unqualified config';Cross=$true;Passed=$false;Corrupt=$false;Ready=$false;ExpectedRestore=0;ExpectedError='ITL_INFOBASE_APPLICATION_NOT_READY'},
        @{Case='corrupt post-config snapshot';Cross=$true;Passed=$true;Corrupt=$true;Ready=$false;ExpectedRestore=0;ExpectedError='SHA256'}
    ) {
        & {
            param($Case,$Cross,$Passed,$Corrupt,$Ready,$ExpectedRestore,$ExpectedError)
            $worktreePath=Join-Path $TestDrive $Case
            New-Item -ItemType Directory -Force $worktreePath|Out-Null
            # Exact fingerprints from the native R8 baseline/postConfig failure.
            $expectedFingerprint='v2|git-tree-sha256|8442b3b14156383cda1f93f0661d2265d2c0da411b5a8ccb95dd06b156526317'
            $baselineFingerprint='v2|git-tree-sha256|2aa9360b7324b3000b0f53bae7bdfe63bdec49cbccf92bd3f8679f53def96eef'
            $currentStatePath=Join-Path $worktreePath 'current.json'
            $savedStatePath=Join-Path $worktreePath 'post-config.json'
            $snapshotPath=Join-Path $worktreePath 'post-config.dt'
            [IO.File]::WriteAllText($currentStatePath,(@{sourceFingerprint=$(if($Ready){$expectedFingerprint}else{$baselineFingerprint})}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($savedStatePath,(@{sourceFingerprint=$expectedFingerprint}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($snapshotPath,$expectedFingerprint,[Text.UTF8Encoding]::new($false))
            $checkpoint=@{stages=@{'config-cadence'=@{status=$(if($Passed){'passed'}else{'failed'})}};
                snapshots=@{postConfig=@{path=$snapshotPath;sha256=Get-E2EFileSha256 $snapshotPath}};
                stateFiles=@{postConfig=@{stateCopyPath=$savedStatePath;stateSha256=Get-E2EFileSha256 $savedStatePath;envCopyPath=''}}}
            if($Corrupt){[IO.File]::AppendAllText($snapshotPath,'corrupt')}
            $crossReleaseReuse=$Cross
            $script:e2eUnsafeActionProtectionConfirmation=$null
            $observed=@{databaseFingerprint=$(if($Ready){$expectedFingerprint}else{$baselineFingerprint});restoreCalls=0;prepareCalls=0}
            function Get-E2EState {@{path=$currentStatePath}}
            function Invoke-E2EHelper {
                param($Action,$TimeoutSeconds,$AdditionalArguments)
                if($Action -eq 'release-e2e-restore'){
                    $AdditionalArguments|Should -Contain '-PreserveReleaseSnapshotApplicationProof'
                    $observed.restoreCalls++
                    $observed.databaseFingerprint=[IO.File]::ReadAllText($snapshotPath)
                } elseif($Action -eq 'release-e2e-prepare-ondemand'){
                    $observed.prepareCalls++
                    $state=Get-Content -LiteralPath $currentStatePath -Raw -Encoding UTF8|ConvertFrom-Json
                    if($observed.databaseFingerprint -cne $expectedFingerprint -or $state.sourceFingerprint -cne $expectedFingerprint){throw 'ITL_INFOBASE_APPLICATION_NOT_READY: configuration-fingerprint-mismatch'}
                } else {throw "Unexpected helper action $Action"}
            }
            if($ExpectedError){ {& $onDemandPreparation}|Should -Throw "*$ExpectedError*" }
            else {& $onDemandPreparation}
            $observed.restoreCalls|Should -Be $ExpectedRestore
            $observed.prepareCalls|Should -Be $(if($Corrupt){0}else{1})
        } $Case $Cross $Passed $Corrupt $Ready $ExpectedRestore $ExpectedError
    }
}
