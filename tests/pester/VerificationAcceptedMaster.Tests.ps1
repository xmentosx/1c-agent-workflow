BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $script:AcceptedMasterHelper = $context.HelperPath

    function Invoke-AcceptedMasterFixture {
        param([string]$Case = 'configuration')
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/Импорт master с пробелом')
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        & {
            param($FixtureRoot, $Case)
            function Invoke-FixtureGit {
                param([string[]]$Arguments)
                $ErrorActionPreference = 'Continue'
                [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
                $output = & git -C $FixtureRoot @Arguments 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($Arguments -join ' '): $output" }
                return ($output -join "`n")
            }
            function Set-FixtureFile {
                param([string]$Path, [string]$Text)
                $absolute = Join-Path $FixtureRoot $Path
                New-Item -ItemType Directory -Path (Split-Path $absolute) -Force | Out-Null
                [IO.File]::WriteAllText($absolute, $Text, [Text.UTF8Encoding]::new($false))
            }
            $extensionRoot = if ($Case -eq 'custom-extension-root') { 'Исходники расширений/Расширение Тест' } else { 'src/cfe' }
            $sourceRoot = if ($Case -in @('extension', 'custom-extension-root')) { $extensionRoot } else { 'src/cf' }
            $importedPath = "$sourceRoot/Мастер [1]/Модуль.bsl"
            [string[]]$importedPaths = if ($Case -eq 'pm5-imported-paths') { @(
                'src/cf/Catalogs/упо_Задания/Ext/ObjectModule.bsl',
                'src/cf/Catalogs/упо_Планы/Ext/ManagerModule.bsl',
                'src/cf/Catalogs/упо_Планы/Forms/ФормаСписка/Ext/Form.xml',
                'src/cf/Catalogs/упо_Планы/Forms/ФормаСписка/Ext/Form/Module.bsl',
                'src/cf/Catalogs/упо_Проекты/Ext/ManagerModule.bsl',
                'src/cf/Catalogs/упо_Проекты/Forms/ФормаСписка/Ext/Form.xml',
                'src/cf/Catalogs/упо_Проекты/Forms/ФормаЭлемента/Ext/Form.xml',
                'src/cf/Catalogs/упо_РискиПроектов/Ext/ManagerModule.bsl',
                'src/cf/CommonModules/упо_ПоказателиКлиент/Ext/Module.bsl',
                'src/cf/CommonModules/упо_СтатусОтчетыКлиент/Ext/Module.bsl',
                'src/cf/Documents/упо_СводныйСтатусОтчет/Ext/ManagerModule.bsl',
                'src/cf/Documents/упо_СогласованиеТрудозатрат/Ext/ManagerModule.bsl',
                'src/cf/Documents/упо_СтатусОтчет/Ext/ManagerModule.bsl'
            ) } else { @($importedPath) }
            $importedPath = $importedPaths[0]
            $ownPath = if ($Case -eq 'own-before-import') { 'src/cf/А свое.xml' } else { 'src/cf/Я свое.xml' }
            Set-FixtureFile '.agent-1c/project.json' (@{ schemaVersion = 1; baseConfigurationVersion = 'fixture'; testsPath = 'tests/features'; extensionsPath = $extensionRoot } | ConvertTo-Json)
            Set-FixtureFile '.gitignore' ".agent-1c/verification-selection/`n"
            Set-FixtureFile '.gitattributes' "src/cf/** -text`nsrc/cfe/** -text`n"
            foreach ($name in @('Orders', 'Reports', 'Profiling')) { Set-FixtureFile "tests/features/$name.feature" "Функционал: $name" }
            Set-FixtureFile 'tests/verification-suites.branch.json' '{"schemaVersion":1,"suites":[{"id":"orders","purpose":"acceptance","featurePaths":["tests/features/Orders.feature"],"ownerPaths":["src/cf/Orders/**"]},{"id":"reports","purpose":"acceptance","featurePaths":["tests/features/Reports.feature"],"ownerPaths":["src/cf/Reports/**"]},{"id":"profiling","purpose":"explicit","featurePaths":["tests/features/Profiling.feature"],"ownerPaths":["tools/profiling/**"]}]}'
            if ($Case -ne 'addition') { foreach ($sourcePath in $importedPaths) { Set-FixtureFile $sourcePath 'old master' } }
            Set-FixtureFile 'src/cf/Orders/Order.xml' 'old order'
            Invoke-FixtureGit @('init', '-b', 'master') | Out-Null
            Invoke-FixtureGit @('config', 'user.name', 'ITL Test') | Out-Null
            Invoke-FixtureGit @('config', 'user.email', 'tests@example.invalid') | Out-Null
            Invoke-FixtureGit @('add', '--', '.') | Out-Null
            Invoke-FixtureGit @('commit', '-m', 'initial master') | Out-Null
            Invoke-FixtureGit @('switch', '-c', 'itldev/fixture') | Out-Null
            Invoke-FixtureGit @('commit', '--allow-empty', '-m', 'branch task') | Out-Null
            . $script:AcceptedMasterHelper -ProjectRoot $FixtureRoot -Action help *> $null
            $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath 'tests/features')
            # Synthetic proof belongs only to this isolated test repository.
            $initial = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
            Complete-VerificationSelectionProof -Plan $initial
            Invoke-FixtureGit @('switch', 'master') | Out-Null
            if ($Case -eq 'deletion') {
                Invoke-FixtureGit @('rm', '--', $importedPath) | Out-Null
            } elseif ($Case -eq 'rename') {
                Invoke-FixtureGit @('mv', '--', $importedPath, "$sourceRoot/Мастер [1]/Новое имя.bsl") | Out-Null
            } else { foreach ($sourcePath in $importedPaths) { Set-FixtureFile $sourcePath 'accepted master' } }
            Invoke-FixtureGit @('add', '--', '.') | Out-Null
            Invoke-FixtureGit @('commit', '-m', 'master input') | Out-Null
            $acceptedCommit = Invoke-FixtureGit @('rev-parse', 'HEAD')
            Invoke-FixtureGit @('switch', 'itldev/fixture') | Out-Null
            if ($Case -ne 'not-accepted') { Invoke-FixtureGit @('merge', '--no-edit', 'master') | Out-Null }
            switch ($Case) {
                'not-accepted' { Set-FixtureFile $importedPath 'accepted master' }
                'own-before-import' { Set-FixtureFile $ownPath 'own new source'; Invoke-FixtureGit @('add', '--', $ownPath) | Out-Null }
                'own-after-import' { Set-FixtureFile $ownPath 'own new source' }
                'imported-staged-edit' { Set-FixtureFile $importedPath 'own edit'; Invoke-FixtureGit @('add', '--', $importedPath) | Out-Null }
                'imported-unstaged-edit' { Set-FixtureFile $importedPath 'own edit' }
                'index-only-edit' { Set-FixtureFile $importedPath 'index edit'; Invoke-FixtureGit @('add', '--', $importedPath) | Out-Null; Set-FixtureFile $importedPath 'accepted master' }
                'owned-branch-edit' { Set-FixtureFile 'src/cf/Orders/Order.xml' 'own order' }
                'master-ahead' {
                    Invoke-FixtureGit @('switch', 'master') | Out-Null
                    Set-FixtureFile $importedPath 'future master'
                    Invoke-FixtureGit @('add', '--', $importedPath) | Out-Null
                    Invoke-FixtureGit @('commit', '-m', 'not accepted yet') | Out-Null
                    Invoke-FixtureGit @('switch', 'itldev/fixture') | Out-Null
                }
                'master-missing' { Invoke-FixtureGit @('branch', '-D', 'master') | Out-Null }
                'master-unrelated' {
                    Invoke-FixtureGit @('switch', '--orphan', 'unrelated') | Out-Null
                    Invoke-FixtureGit @('commit', '--allow-empty', '-m', 'unrelated root') | Out-Null
                    Invoke-FixtureGit @('branch', '-f', 'master', 'HEAD') | Out-Null
                    Invoke-FixtureGit @('switch', 'itldev/fixture') | Out-Null
                }
                'runtime-and-own' { Set-FixtureFile '.agent-1c/dependency-lock.json' '{}'; Set-FixtureFile $ownPath 'own source' }
                'support-and-own' { Set-FixtureFile 'tests/features/support.json' '{}'; Set-FixtureFile $ownPath 'own source' }
                'unclassified-catalog' { Set-FixtureFile 'tests/features/Unclassified.feature' 'Функционал: unclassified' }
                'git-error' {
                    $gitOutputImplementation = ${function:Get-GitOutput}
                    function Get-GitOutput {
                        param([string[]]$Arguments)
                        if ($Arguments[0] -eq 'merge-base') { throw 'Fixture Git ancestry failure' }
                        & $gitOutputImplementation -Arguments $Arguments
                    }
                }
                'ambiguous-ancestor' {
                    $gitOutputImplementation = ${function:Get-GitOutput}
                    function Get-GitOutput {
                        param([string[]]$Arguments)
                        if ($Arguments[0] -eq 'merge-base') { return "$acceptedCommit`n$acceptedCommit" }
                        & $gitOutputImplementation -Arguments $Arguments
                    }
                }
                'unmanaged-branch' { Invoke-FixtureGit @('branch', '-m', 'ordinary-branch') | Out-Null }
            }
            $indexPath = Join-Path $FixtureRoot '.git/index'
            $indexBefore = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
            $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath 'tests/features')
            $plan = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
            $indexAfter = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
            if ($plan.mode -eq 'full') { Complete-VerificationSelectionProof -Plan $plan }
            $proof = Read-VerificationSelectionProof
            [pscustomobject]@{
                plan = $plan; proof = $proof; importedPath = $importedPath; ownPath = $ownPath
                acceptedCommit = $acceptedCommit; indexBefore = $indexBefore; indexAfter = $indexAfter
            }
        } $fixtureRoot $Case
    }
}

Describe 'Accepted master input in real verification trees' {
    It 'selects all existing acceptance suites for <Case>, preserving the user index' -TestCases @(
        @{ Case = 'configuration' }, @{ Case = 'extension' }, @{ Case = 'custom-extension-root' },
        @{ Case = 'addition' }, @{ Case = 'deletion' }, @{ Case = 'rename' },
        @{ Case = 'master-ahead' }, @{ Case = 'index-only-edit' }, @{ Case = 'owned-branch-edit' }, @{ Case = 'pm5-imported-paths' }
    ) {
        param($Case)
        $result = Invoke-AcceptedMasterFixture -Case $Case
        $result.plan.mode | Should -Be 'full'
        $result.plan.reason | Should -Match 'Accepted master input'
        @($result.plan.selectedSuiteIds | Sort-Object) | Should -Be @('orders', 'reports')
        $result.plan.acceptedMasterInput.available | Should -BeTrue
        $result.plan.acceptedMasterInput.acceptedCommit | Should -Be $result.acceptedCommit
        $result.plan.acceptedMasterInput.importedPaths | Should -Contain $result.importedPath
        $result.proof.acceptedMasterInput.acceptedCommit | Should -Be $result.acceptedCommit
        $result.indexAfter | Should -Be $result.indexBefore
        if ($Case -eq 'master-ahead') { $result.plan.acceptedMasterInput.masterTip | Should -Not -Be $result.acceptedCommit }
        if ($Case -eq 'rename') { $result.plan.acceptedMasterInput.importedPaths.Count | Should -Be 2 }
        if ($Case -eq 'pm5-imported-paths') { $result.plan.acceptedMasterInput.importedPaths.Count | Should -Be 13 }
        if ($Case -eq 'owned-branch-edit') { $result.plan.acceptedMasterInput.branchPaths | Should -Contain 'src/cf/Orders/Order.xml' }
    }

    It 'keeps <Case> unclassified rather than hiding it behind full acceptance' -TestCases @(
        @{ Case = 'own-before-import' }, @{ Case = 'own-after-import' },
        @{ Case = 'imported-staged-edit' }, @{ Case = 'imported-unstaged-edit' },
        @{ Case = 'not-accepted' }, @{ Case = 'master-missing' }, @{ Case = 'master-unrelated' },
        @{ Case = 'runtime-and-own' }, @{ Case = 'support-and-own' },
        @{ Case = 'unclassified-catalog' }, @{ Case = 'unmanaged-branch' }, @{ Case = 'ambiguous-ancestor' }
    ) {
        param($Case)
        $result = Invoke-AcceptedMasterFixture -Case $Case
        $result.plan.mode | Should -Be 'classification-required'
        $result.plan.selectedFeatureFiles.Count | Should -Be 0
        $result.indexAfter | Should -Be $result.indexBefore
    }

    It 'does not grant imported-input provenance when Git cannot prove ancestry' {
        $result = Invoke-AcceptedMasterFixture -Case git-error
        $result.plan.mode | Should -Be 'classification-required'
        $result.plan.acceptedMasterInput.available | Should -BeFalse
        $result.plan.acceptedMasterInput.importedPaths.Count | Should -Be 0
        $result.plan.acceptedMasterInput.reason | Should -Match 'Fixture Git ancestry failure'
    }

    It 'rejects malformed effective-tree evidence before attempting ancestry lookup' {
        . (Join-Path (Split-Path (Split-Path $PSScriptRoot)) '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-selection.ps1')
        $evidence = Get-VerificationAcceptedMasterInput -ChangedPaths @('src/cf/Модуль.bsl') -CurrentTree 'not-a-tree'
        $evidence.available | Should -BeFalse
        $evidence.importedPaths.Count | Should -Be 0
        $evidence.reason | Should -Be 'Invalid effective tree.'
    }
}
