BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot "scripts\develop-static-qualification.ps1")
    . (Join-Path $RepoRoot "scripts\release-qualification.ps1")
}

Describe "Develop static qualification cache" {
    BeforeEach {
        $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl develop static cache путь " + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
        & git -C $fixtureRoot init *> $null
        & git -C $fixtureRoot config user.name "ITL Test"
        & git -C $fixtureRoot config user.email "itl-test@example.invalid"
        Set-Content -LiteralPath (Join-Path $fixtureRoot "tracked.txt") -Encoding UTF8 -Value "candidate"
        & git -C $fixtureRoot add tracked.txt
        & git -C $fixtureRoot commit -m candidate *> $null
        $tree = (& git -C $fixtureRoot rev-parse 'HEAD^{tree}').Trim()
        $qualificationRoot = Join-Path $fixtureRoot "build\test-results\qualification"
        New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
        $pesterPath = Join-Path $qualificationRoot "pester.xml"
        [IO.File]::WriteAllText($pesterPath, "<testsuites tests=`"731`" failures=`"0`" />", [Text.UTF8Encoding]::new($false))
        $qualification = [ordered]@{
            schemaVersion = 2
            kind = "itl-workflow-full-qualification"
            status = "passed"
            reusable = $true
            repository = [ordered]@{ commit = (& git -C $fixtureRoot rev-parse HEAD).Trim(); tree = $tree; worktreeClean = $true }
            junit = [ordered]@{ path = "build/test-results/qualification/pester.xml"; sha256 = (Get-FileHash -LiteralPath $pesterPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        [IO.File]::WriteAllText((Join-Path $qualificationRoot "full.json"), (($qualification | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }

    AfterEach {
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    }

    It "restores exact-tree Full and JUnit proof after a failed Develop worktree is gone" {
        $cachePath = Save-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $tree
        Test-Path -LiteralPath (Join-Path $cachePath "manifest.json") -PathType Leaf | Should -BeTrue

        Remove-Item -LiteralPath $qualificationRoot -Recurse -Force
        Restore-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $tree | Should -BeTrue
        $restored = Get-Content -LiteralPath (Join-Path $qualificationRoot "full.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $restored.repository.tree | Should -Be $tree
        (Get-FileHash -LiteralPath (Join-Path $qualificationRoot "pester.xml") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be ([string]$restored.junit.sha256).ToLowerInvariant()
    }

    It "resolves a linked common Git directory through the PS 5.1 UTF-8 boundary" {
        $linkedRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl linked worktree путь " + [guid]::NewGuid().ToString("N"))
        try {
            & git -C $fixtureRoot worktree add --quiet -b cache-path-test $linkedRoot
            $LASTEXITCODE | Should -Be 0
            $linkedTree = (& git -C $linkedRoot rev-parse 'HEAD^{tree}').Trim()
            $cachePath = Get-DevelopStaticQualificationCachePath -RepositoryRoot $linkedRoot -Tree $linkedTree
            $expectedRoot = [IO.Path]::GetFullPath((Join-Path $fixtureRoot ".git\itl\develop-static-qualifications"))
            $cachePath.StartsWith($expectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        } finally {
            & git -C $fixtureRoot worktree remove --force $linkedRoot *> $null
            if (Test-Path -LiteralPath $linkedRoot) { Remove-Item -LiteralPath $linkedRoot -Recurse -Force }
        }
    }

    It "fails closed for a different tree or modified cached evidence" {
        $otherTree = "0" * 40
        { Save-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $otherTree } | Should -Throw "*does not match candidate tree*"

        $cachePath = Save-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $tree
        Add-Content -LiteralPath (Join-Path $cachePath "pester.xml") -Encoding UTF8 -Value "corrupt"
        Remove-Item -LiteralPath $qualificationRoot -Recurse -Force
        Restore-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $tree | Should -BeFalse
    }

    It "reuses Pester proof on the second exact-tree Develop after the first Develop E2E fails" {
        $runs = @{ static = 0; e2e = 0 }
        $fullText = Get-Content -LiteralPath (Join-Path $qualificationRoot "full.json") -Raw -Encoding UTF8
        $pesterText = Get-Content -LiteralPath (Join-Path $qualificationRoot "pester.xml") -Raw -Encoding UTF8
        Remove-Item -LiteralPath $qualificationRoot -Recurse -Force
        $invokeDevelopGate = {
            $match = Get-DevelopStaticQualificationCacheMatch `
                -RepositoryRoot $fixtureRoot `
                -QualificationRoot $qualificationRoot `
                -Tree $tree `
                -Validate {
                    param([bool]$AllowIndependentExactTree)
                    $full = Get-Content -LiteralPath (Join-Path $qualificationRoot "full.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$full.repository.tree -ne $tree) { return $null }
                    return [pscustomobject]@{ qualification = $full }
                }
            $pesterExecution = if ($match) { "reused" } else {
                $runs.static++
                New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
                [IO.File]::WriteAllText((Join-Path $qualificationRoot "full.json"), $fullText, [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $qualificationRoot "pester.xml"), $pesterText, [Text.UTF8Encoding]::new($false))
                [void](Save-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $tree)
                "executed"
            }
            $runs.e2e++
            if ($runs.e2e -eq 1) { throw "simulated develop-e2e failure" }
            return [pscustomobject]@{ status = "passed"; stages = @([pscustomobject]@{ name = "pester"; execution = $pesterExecution }) }
        }

        { & $invokeDevelopGate } | Should -Throw "simulated develop-e2e failure"
        Remove-Item -LiteralPath $qualificationRoot -Recurse -Force
        $second = & $invokeDevelopGate

        $second.status | Should -Be "passed"
        ($second.stages | Where-Object name -eq "pester").execution | Should -Be "reused"
        $runs.static | Should -Be 1
        $runs.e2e | Should -Be 2
    }

    It "accepts a sibling commit with the same tree only through verified Develop cache reuse" {
        $baseCommit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        & git -C $fixtureRoot commit --allow-empty -m "qualified sibling" *> $null
        $qualifiedCommit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        $qualifiedTree = (& git -C $fixtureRoot rev-parse 'HEAD^{tree}').Trim()
        & git -C $fixtureRoot switch --quiet -c retry-sibling $baseCommit *> $null
        & git -C $fixtureRoot commit --allow-empty -m "retry sibling" *> $null
        $currentCommit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        $currentTree = (& git -C $fixtureRoot rev-parse 'HEAD^{tree}').Trim()

        $arguments = @{
            RepositoryRoot = $fixtureRoot
            SchemaVersion = 2
            QualifiedCommit = $qualifiedCommit
            EvidenceCommit = $qualifiedCommit
            QualifiedTree = $qualifiedTree
            CurrentCommit = $currentCommit
            CurrentTree = $currentTree
        }
        Get-WorkflowQualificationReuseKind @arguments | Should -BeNullOrEmpty
        Get-CachedWorkflowQualificationReuseKind @arguments | Should -Be "independent-exact-tree"

        $qualification = Get-Content -LiteralPath (Join-Path $qualificationRoot "full.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $qualification.repository.commit = $qualifiedCommit
        $qualification.repository.tree = $qualifiedTree
        [IO.File]::WriteAllText((Join-Path $qualificationRoot "full.json"), (($qualification | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [void](Save-DevelopStaticQualification -RepositoryRoot $fixtureRoot -QualificationRoot $qualificationRoot -Tree $qualifiedTree)
        Remove-Item -LiteralPath $qualificationRoot -Recurse -Force

        $observation = @{ cacheTrust = $false }
        $match = Get-DevelopStaticQualificationCacheMatch `
            -RepositoryRoot $fixtureRoot `
            -QualificationRoot $qualificationRoot `
            -Tree $currentTree `
            -Validate {
                param([bool]$AllowIndependentExactTree)
                $observation.cacheTrust = $AllowIndependentExactTree
                $restored = Get-Content -LiteralPath (Join-Path $qualificationRoot "full.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                $kind = if ($AllowIndependentExactTree) {
                    Get-CachedWorkflowQualificationReuseKind -RepositoryRoot $fixtureRoot -SchemaVersion 2 -QualifiedCommit ([string]$restored.repository.commit) -EvidenceCommit ([string]$restored.repository.commit) -QualifiedTree ([string]$restored.repository.tree) -CurrentCommit $currentCommit -CurrentTree $currentTree
                } else { "" }
                if (-not $kind) { return $null }
                return [pscustomobject]@{ reuseKind = $kind }
            }
        $observation.cacheTrust | Should -BeTrue
        $match.reuseKind | Should -Be "independent-exact-tree"
    }

    It "wires restore before Full validation and save before Develop E2E" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $restoreIndex = $check.IndexOf('Get-DevelopStaticQualificationCacheMatch', [StringComparison]::Ordinal)
        $validationIndex = $check.IndexOf('-AllowIndependentExactTree:$AllowIndependentExactTree', [StringComparison]::Ordinal)
        $saveIndex = $check.IndexOf('Save-DevelopStaticQualification', [StringComparison]::Ordinal)
        $e2eIndex = $check.IndexOf('Invoke-GateStage -Name "develop-e2e-$journey"', [StringComparison]::Ordinal)
        $restoreIndex | Should -BeGreaterThan -1
        $validationIndex | Should -BeGreaterThan $restoreIndex
        $saveIndex | Should -BeGreaterThan $validationIndex
        $e2eIndex | Should -BeGreaterThan $saveIndex
    }
}
