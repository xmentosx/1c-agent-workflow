BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $RepoRoot 'scripts/invoke-pester-runtime.ps1')
    . (Join-Path $PSScriptRoot 'PesterRuntimeSupport.ps1')
}

Describe 'Full aggregate input qualification' {
It 'continues Full qualification with <Kind> inputs through actual scheduler proof and cache transport' -ForEach @(
        @{Kind='known'; ExpectedReusable=$true; ExpectedExecutions=1},
        @{Kind='unknown external'; ExpectedReusable=$false; ExpectedExecutions=2},
        @{Kind='unknown runtime'; ExpectedReusable=$false; ExpectedExecutions=2}
    ) {
        $sourceRoot = $RepoRoot
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'scripts/check.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        foreach ($name in @('Get-RelativeRepositoryPath','Get-CanonicalTextSha256','New-InventoryEntry','Test-HasExactInventory','Get-WorkflowGateScriptPaths','Test-WorkflowQualification')) {
            $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        . (Join-Path $sourceRoot 'scripts/develop-static-qualification.ps1')
        $requiredScripts = @(Get-WorkflowGateScriptPaths)
        $root = New-RuntimeProofFixture $Kind
        foreach ($file in $requiredScripts) {
            $relative=$file.Substring($sourceRoot.Length).TrimStart('\','/')
            $destination=Join-Path $root $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $file -Destination $destination -Force
        }
        if ($Kind -eq 'unknown external') {
            $catalogPath=Join-Path $root 'tests/quality-contracts.json'
            $catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $catalog | Add-Member -NotePropertyName pesterNonReusableTests -NotePropertyValue @('tests/pester/Runtime.Tests.ps1')
            [IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        if ($Kind -eq 'known') {
            $catalogPath=Join-Path $root 'tests/quality-contracts.json'
            $catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $catalog | Add-Member -NotePropertyName pesterExternalInputs -NotePropertyValue @{'tests/pester/Runtime.Tests.ps1'=@('ITL_FULL_PROOF_EXTERNAL')}
            [IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        Add-Content -LiteralPath (Join-Path $root '.gitignore') -Value 'build/'
        & git -C $root add -- scripts tests/quality-contracts.json .gitignore
        & git -C $root commit -qm 'complete actual script inventory'
        $LASTEXITCODE | Should -Be 0
        $runner = if ($Kind -eq 'unknown runtime') { New-UnknownRuntimeRunner } else { Join-Path $sourceRoot 'scripts/invoke-pester-shards.ps1' }
        $previousExternal=[Environment]::GetEnvironmentVariable('ITL_FULL_PROOF_EXTERNAL','Process')
        try {
        if ($Kind -eq 'known') {
            $externalFile=Join-Path $TestDrive 'Внешний вход full.txt'
            [IO.File]::WriteAllText($externalFile,'исходные байты',[Text.UTF8Encoding]::new($false))
            [Environment]::SetEnvironmentVariable('ITL_FULL_PROOF_EXTERNAL',$externalFile,'Process')
        }
        $observed = Invoke-RuntimeProofFixture $root 'out-observation' $runner -InputIdentityOnly
        (Test-Path -LiteralPath (Join-Path $root 'counter.txt')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $root 'out-observation/pester.xml')) | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $root 'out-observation/pester-shards') -Filter 'worker-*.result.json').Count | Should -Be 0
        $first = Invoke-RuntimeProofFixture $root 'out-first' $runner
        $first.passed | Should -Be 1
        (Test-PesterInputIdentityMatch $first.inputIdentity $observed) | Should -Be $ExpectedReusable

        # Use the real checker producer/reader on an exact clean Git tree. The
        # observation value comes from the native scheduler, never a fabricated
        # module version or synthetic input digest.
        $repoRoot=$root
        $qualificationFullPath=Join-Path $root 'out-proof/full.json'
        $junitPath=Join-Path $root 'out-first/pester.xml'
        $forkQualificationPath=Join-Path $root 'out-proof/fork.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $forkQualificationPath) | Out-Null
        [IO.File]::WriteAllText($forkQualificationPath,'fixture fork evidence',[Text.UTF8Encoding]::new($false))
        $forkQualificationSha256=(Get-FileHash -LiteralPath $forkQualificationPath).Hash.ToLowerInvariant()
        $aiRulesRelease=[pscustomobject]@{repo='fixture';tag='fixture';commit=('a'*40);tree=('b'*40);upstreamRef='refs/heads/main';upstreamCommit=('c'*40)}
        $stages=New-Object 'Collections.Generic.List[object]'
        $startedAt=[DateTime]::UtcNow
        $overallStopwatch=[Diagnostics.Stopwatch]::StartNew()
        $pesterVersion=$first.pesterVersion
        $pesterShardSummary=$first
        $commit=(& git -C $root rev-parse HEAD).Trim()
        $tree=(& git -C $root rev-parse 'HEAD^{tree}').Trim()
        function Get-CurrentPesterInputIdentity { $observed }
        $record=Write-WorkflowQualification -Commit $commit -Tree $tree -EvidenceCommit $commit -ReuseKind executed -Result @{passed=1;failed=0;skipped=0}
        $record.schemaVersion | Should -Be 4
        $record.reusable | Should -Be $ExpectedReusable
        if ($Kind -eq 'known') {
            # Preserve the distinct-directory producer above, then reproduce the
            # real Develop layout where output and qualification share JUnit.
            $junitPath=Join-Path (Split-Path -Parent $qualificationFullPath) 'pester.xml'
            $sharedJunitSha=(Get-FileHash -LiteralPath $junitPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $record=Write-WorkflowQualification -Commit $commit -Tree $tree -EvidenceCommit $commit -ReuseKind executed -Result @{passed=1;failed=0;skipped=0}
            $record.junit.sha256 | Should -BeExactly $sharedJunitSha
            (Get-FileHash -LiteralPath $junitPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $sharedJunitSha
        }
        $match=Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease
        $match | Should -Not -BeNullOrEmpty
        $match.canReusePester | Should -Be $ExpectedReusable
        if ($Kind -eq 'known') {
            # Change only declared external bytes: the candidate, test inventory
            # and actual child remain unchanged. A real new observation must
            # reject the whole shortcut and rerun this file to completion.
            [IO.File]::WriteAllText($externalFile,'изменённые байты',[Text.UTF8Encoding]::new($false))
            $observed=Invoke-RuntimeProofFixture $root 'out-changed-observation' $runner -InputIdentityOnly
            $observed.reusable | Should -BeTrue
            (Test-PesterInputIdentityMatch $record.pesterInputs $observed) | Should -BeFalse
            $changedMatch=Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease
            $changedMatch | Should -Not -BeNullOrEmpty
            $changedMatch.canReusePester | Should -BeFalse
            $fresh=Invoke-RuntimeProofFixture $root 'out-changed' $runner
            $fresh.passed | Should -Be 1
            $fresh.executedWorkerCount | Should -Be 1
            $pesterShardSummary=$fresh
            $junitPath=Join-Path $root 'out-changed/pester.xml'
            $record=Write-WorkflowQualification -Commit $commit -Tree $tree -EvidenceCommit $commit -ReuseKind executed -Result @{passed=1;failed=0;skipped=0}
            (Test-WorkflowQualification -Path $qualificationFullPath -Commit $commit -Tree $tree -ForkIdentity $aiRulesRelease).canReusePester | Should -BeTrue
            $ExpectedExecutions++
        }
        $recordJson=[IO.File]::ReadAllText($qualificationFullPath)
        [void](Save-DevelopStaticQualification -RepositoryRoot $root -QualificationRoot (Split-Path -Parent $qualificationFullPath) -Tree $tree)
        Remove-Item -LiteralPath $qualificationFullPath
        Restore-DevelopStaticQualification -RepositoryRoot $root -QualificationRoot (Split-Path -Parent $qualificationFullPath) -Tree $tree | Should -BeTrue
        [IO.File]::ReadAllText($qualificationFullPath) | Should -BeExactly $recordJson
        if (-not $match.canReusePester) {
            $second=Invoke-RuntimeProofFixture $root 'out-second' $runner
            $second.passed | Should -Be 1
            $second.executedWorkerCount | Should -Be 1
            $pesterShardSummary=$second
            $junitPath=Join-Path $root 'out-second/pester.xml'
            $record=Write-WorkflowQualification -Commit $commit -Tree $tree -EvidenceCommit $commit -ReuseKind executed -Result @{passed=1;failed=0;skipped=0}
            $record.status | Should -Be passed
            $record.reusable | Should -BeFalse
        }
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be $ExpectedExecutions
        # Exercise the other workflow Full transport used by compatibility
        # continuation. Git responses are real; no delivery operation is run.
        . (Join-Path $sourceRoot 'scripts/git-path-list.ps1')
        $candidateTokens=$null; $candidateErrors=$null
        $candidateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'scripts/source-delivery-candidate.ps1'),[ref]$candidateTokens,[ref]$candidateErrors)
        @($candidateErrors) | Should -BeNullOrEmpty
        foreach ($name in @('Get-DevelopCompatibilityQualificationPath','Save-DevelopCompatibilityQualification','Restore-DevelopCompatibilityQualification')) {
            $definition=$candidateAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function Get-DeliveryCommonGitDirectory { Get-RepositoryCommonGitDirectory -RepositoryRoot $root }
        function Invoke-WorktreeGit {
            param([string]$Root,[string[]]$Arguments)
            $value=@(& git -C $Root @Arguments)
            if ($LASTEXITCODE) { throw 'Fixture native Git failed.' }
            [pscustomobject]@{stdout=($value -join "`n")}
        }
        $compatibilityProof=Join-Path $root 'build/test-results/qualification/full.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $compatibilityProof) | Out-Null
        Copy-Item -LiteralPath $qualificationFullPath -Destination $compatibilityProof
        $compatibilityJson=[IO.File]::ReadAllText($compatibilityProof)
        [void](Save-DevelopCompatibilityQualification -CandidateRoot $root -Tree $tree)
        Remove-Item -LiteralPath $compatibilityProof
        Restore-DevelopCompatibilityQualification -CandidateRoot $root -Tree $tree | Should -BeTrue
        [IO.File]::ReadAllText($compatibilityProof) | Should -BeExactly $compatibilityJson
        (Get-Content -LiteralPath $compatibilityProof -Raw -Encoding UTF8|ConvertFrom-Json).reusable | Should -Be $ExpectedReusable
        @(& git -C $root status --porcelain).Count | Should -Be 0
        foreach ($defect in @('duplicate-file','missing-file','invalid-digest','false-reuse-flag','missing-input-manifest')) {
            $invalid=$recordJson|ConvertFrom-Json
            switch ($defect) {
                'duplicate-file' { $invalid.pesterInputs.files=@($invalid.pesterInputs.files)+@($invalid.pesterInputs.files[0]) }
                'missing-file' { $invalid.pesterInputs.files=@() }
                'invalid-digest' { $invalid.pesterInputs.files[0].digest='not-a-sha' }
                'false-reuse-flag' { $invalid.reusable=-not $invalid.reusable }
                'missing-input-manifest' { $invalid.PSObject.Properties.Remove('pesterInputs') }
            }
            (Test-WorkflowFullQualificationRecord $invalid) | Should -BeFalse -Because $defect
        }
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_FULL_PROOF_EXTERNAL',$previousExternal,'Process')
        }
    }
}
