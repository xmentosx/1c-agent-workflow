Describe "YAxUnit production applicability" {
    BeforeAll {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $SelectionModule = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-selection.ps1"
        $YAxUnitModule = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.yaxunit.ps1"
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    }

    It "keeps the pre-upgrade source without creating a unit-test obligation" {
        $result = & {
            $DevBranchName = "legacy"
            . $SelectionModule
            function Read-DevBranchState { param($Name) [pscustomobject]@{ yaxunitApplicabilityBaseline = [pscustomobject]@{ schemaVersion = 1; commit = ('1' * 40); legacy = $true } } }
            function Get-StateValue { param($State, $Name, $Default) if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) { return $Default }; return $State.$Name }
            function Get-GitOutput { '2' * 40 }
            function Get-VerificationSelectionEffectiveTree { '3' * 40 }
            function Get-VerificationSelectionChangedPaths { param($BaseTree, $CurrentTree) @() }
            function Get-VerificationAcceptedMasterInput { param($ChangedPaths, $CurrentTree) [pscustomobject]@{ importedPaths = @() } }
            function Get-VerificationConfigurationMetadataRoots { [pscustomobject]@{ configurationRoots = @('src/cf'); extensionRoots = @() } }
            Get-YAxUnitProductionApplicability -Catalog ([pscustomobject]@{ groups = @(); assignments = @(); registrationPaths = @(); notApplicable = @() })
        }
        $result.classificationComplete | Should -BeTrue
        $result.legacy | Should -BeTrue
        @($result.decisions).Count | Should -Be 0
    }

    It "accepts one exact notApplicable entry and rejects duplicate declarations" {
        $catalogPath = Join-Path $TestDrive 'yaxunit-suites.branch.json'
        $result = & {
            . $YAxUnitModule
            function Get-YAxUnitSuiteCatalogPaths { @($catalogPath) }
            function Get-YAxUnitTestsPath { 'tests/yaxunit' }
            function Get-VerificationRepoRelativePath { param($Path) 'tests/yaxunit-suites.branch.json' }
            function Read-Utf8Text { param($Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
            $entry = @{ path = 'src/cf/CommonModules/Новый Расчет/Ext/Module.bsl'; sourceOid = ('a' * 40); reason = 'Only interactive behavior changed' }
            @{ schemaVersion = 1; notApplicable = @($entry) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
            $valid = Read-YAxUnitSuiteCatalog -ModuleFiles @()
            @{ schemaVersion = 1; notApplicable = @($entry, $entry) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
            $duplicate = Read-YAxUnitSuiteCatalog -ModuleFiles @()
            [pscustomobject]@{ valid = $valid; duplicate = $duplicate }
        }
        $result.valid.classificationComplete | Should -BeTrue
        $result.valid.notApplicable[0].path | Should -Be 'src/cf/CommonModules/Новый Расчет/Ext/Module.bsl'
        $result.duplicate.classificationComplete | Should -BeFalse
        $result.duplicate.issues[0] | Should -Match 'YAXUNIT_APPLICABILITY_DUPLICATE'
    }

    It "requires a decision for new BSL but accepts a narrow matching notApplicable declaration" {
        $result = & {
            $DevBranchName = "current"
            $script:Changed = @('src/cf/CommonModules/Тест Выбора/Ext/Module.bsl')
            $script:SourceOid = '4' * 40
            . $SelectionModule
            function Read-DevBranchState { param($Name) [pscustomobject]@{ yaxunitApplicabilityBaseline = [pscustomobject]@{ schemaVersion = 1; commit = ('1' * 40); legacy = $false } } }
            function Get-StateValue { param($State, $Name, $Default) if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) { return $Default }; return $State.$Name }
            function Get-GitOutput { '2' * 40 }
            function Get-VerificationSelectionEffectiveTree { '3' * 40 }
            function Get-VerificationSelectionChangedPaths { param($BaseTree, $CurrentTree) @($script:Changed) }
            function Get-VerificationAcceptedMasterInput { param($ChangedPaths, $CurrentTree) [pscustomobject]@{ importedPaths = @() } }
            function Get-VerificationConfigurationMetadataRoots { [pscustomobject]@{ configurationRoots = @('src/cf'); extensionRoots = @() } }
            function Get-GitObjectIdForTreePath { param($Treeish, $RepoPath) $script:SourceOid }
            $baseCatalog = [pscustomobject]@{ groups = @(); assignments = @(); registrationPaths = @(); notApplicable = @() }
            $unclassified = Get-YAxUnitProductionApplicability -Catalog $baseCatalog
            $baseCatalog.notApplicable = @([pscustomobject]@{ path = $script:Changed[0]; sourceOid = $script:SourceOid; reason = 'UI-only route covered by Vanessa' })
            $classified = Get-YAxUnitProductionApplicability -Catalog $baseCatalog
            $script:SourceOid = '5' * 40
            $stale = Get-YAxUnitProductionApplicability -Catalog $baseCatalog
            [pscustomobject]@{ unclassified = $unclassified; classified = $classified; stale = $stale }
        }
        $result.unclassified.classificationComplete | Should -BeFalse
        $result.unclassified.issues[0] | Should -Match ('4' * 40)
        $result.classified.classificationComplete | Should -BeTrue
        $result.classified.decisions[0].decision | Should -Be 'not-applicable'
        $result.stale.classificationComplete | Should -BeFalse
        $result.stale.issues[0] | Should -Match ('5' * 40)
    }

    It "reuses an existing registered default-fast group without demanding a new test" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-yax-applicability-" + [guid]::NewGuid().ToString('N'))
        try {
            $registrationPath = Join-Path $tempRoot 'tests\yaxunit\CommonModules\ИсполняемыеСценарии\Ext\Module.bsl'
            $testModulePath = Join-Path $tempRoot 'tests\yaxunit\CommonModules\TestsSelection\Ext\Module.bsl'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $registrationPath) | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $testModulePath) | Out-Null
            [IO.File]::WriteAllText($registrationPath, 'TestsSelection.AddTests();', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($testModulePath, "Процедура ДобавитьТесты() Экспорт`nКонецПроцедуры", [Text.UTF8Encoding]::new($false))
            $result = & {
                $script:ProjectRoot = $tempRoot
                $DevBranchName = 'current'
                . $YAxUnitModule
                . $SelectionModule
                function Read-DevBranchState { param($Name) [pscustomobject]@{ yaxunitApplicabilityBaseline = [pscustomobject]@{ schemaVersion = 1; commit = ('1' * 40); legacy = $false } } }
                function Get-StateValue { param($State, $Name, $Default) if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) { return $Default }; return $State.$Name }
                function Get-GitOutput { '2' * 40 }
                function Get-VerificationSelectionEffectiveTree { '3' * 40 }
                function Get-VerificationSelectionChangedPaths { param($BaseTree, $CurrentTree) @('src/cf/CommonModules/Selection/Ext/Module.bsl') }
                function Get-VerificationAcceptedMasterInput { param($ChangedPaths, $CurrentTree) [pscustomobject]@{ importedPaths = @() } }
                function Get-VerificationConfigurationMetadataRoots { [pscustomobject]@{ configurationRoots = @('src/cf'); extensionRoots = @() } }
                function Get-GitObjectIdForTreePath { param($Treeish, $RepoPath) '4' * 40 }
                function Resolve-ProjectPath { param($Path) Join-Path $script:ProjectRoot $Path }
                function Read-Utf8Text { param($Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                function Test-YAxUnitSuitePresent { $true }
                function Get-YAxUnitModuleNameFromPath { param($Path) 'TestsSelection' }
                $registration = 'tests/yaxunit/CommonModules/ИсполняемыеСценарии/Ext/Module.bsl'
                $catalog = [pscustomobject]@{
                    groups = @([pscustomobject]@{ id = 'selection'; purpose = 'default-fast'; ownerPaths = @('src/cf/CommonModules/Selection/**') })
                    assignments = @([pscustomobject]@{ groupId = 'selection'; purpose = 'default-fast'; path = 'tests/yaxunit/CommonModules/TestsSelection/Ext/Module.bsl' })
                    registrationPaths = @($registration)
                    notApplicable = @()
                }
                $registered = Get-YAxUnitProductionApplicability -Catalog $catalog
                [IO.File]::WriteAllText($registrationPath, "// TestsSelection.AddTests();`nTestsSelectionOther.AddTests();", [Text.UTF8Encoding]::new($false))
                $missing = Get-YAxUnitProductionApplicability -Catalog $catalog
                [pscustomobject]@{ registered = $registered; missing = $missing }
            }
            $result.registered.classificationComplete | Should -BeTrue
            $result.registered.decisions[0].decision | Should -Be 'required'
            $result.missing.classificationComplete | Should -BeFalse
            $result.missing.issues[0] | Should -Match 'neither an ordinary registration reference nor a discoverable exported'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts a discoverable self-registered server module without registrationPaths" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl yaxunit self registration " + [guid]::NewGuid().ToString('N'))
        try {
            $moduleRepoPath = 'tests/yaxunit/CommonModules/ТестВыбора/Ext/Module.bsl'
            $modulePath = Join-Path $tempRoot ($moduleRepoPath -replace '/', '\')
            $metadataPath = Join-Path $tempRoot 'tests\yaxunit\CommonModules\ТестВыбора.xml'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $modulePath) | Out-Null
            [IO.File]::WriteAllText($modulePath, "Процедура ИсполняемыеСценарии() Экспорт`nКонецПроцедуры", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($metadataPath, '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"><CommonModule><Properties><Server>true</Server><ServerCall>false</ServerCall></Properties></CommonModule></MetaDataObject>', [Text.UTF8Encoding]::new($false))
            $result = & {
                $script:ProjectRoot = $tempRoot
                $DevBranchName = 'current'
                . $YAxUnitModule
                . $SelectionModule
                function Read-DevBranchState { param($Name) [pscustomobject]@{ yaxunitApplicabilityBaseline = [pscustomobject]@{ schemaVersion = 1; commit = ('1' * 40); legacy = $false } } }
                function Get-StateValue { param($State, $Name, $Default) if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) { return $Default }; return $State.$Name }
                function Get-GitOutput { '2' * 40 }
                function Get-VerificationSelectionEffectiveTree { '3' * 40 }
                function Get-VerificationSelectionChangedPaths { param($BaseTree, $CurrentTree) @('src/cf/CommonModules/Selection/Ext/Module.bsl') }
                function Get-VerificationAcceptedMasterInput { param($ChangedPaths, $CurrentTree) [pscustomobject]@{ importedPaths = @() } }
                function Get-VerificationConfigurationMetadataRoots { [pscustomobject]@{ configurationRoots = @('src/cf'); extensionRoots = @() } }
                function Get-GitObjectIdForTreePath { param($Treeish, $RepoPath) '4' * 40 }
                function Resolve-ProjectPath { param($Path) Join-Path $script:ProjectRoot $Path }
                function Read-Utf8Text { param($Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                function Test-YAxUnitSuitePresent { $true }
                $catalog = [pscustomobject]@{
                    groups = @([pscustomobject]@{ id = 'selection'; purpose = 'default-fast'; ownerPaths = @('src/cf/CommonModules/Selection/**') })
                    assignments = @([pscustomobject]@{ groupId = 'selection'; purpose = 'default-fast'; path = $moduleRepoPath })
                    registrationPaths = @()
                    notApplicable = @()
                }
                $selfRegistered = Get-YAxUnitProductionApplicability -Catalog $catalog
                [IO.File]::WriteAllText($metadataPath, '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"><CommonModule><Properties><Server>true</Server><ServerCall>true</ServerCall></Properties></CommonModule></MetaDataObject>', [Text.UTF8Encoding]::new($false))
                $undiscoverable = Get-YAxUnitProductionApplicability -Catalog $catalog
                [IO.File]::WriteAllText($modulePath, '// Процедура ИсполняемыеСценарии() Экспорт', [Text.UTF8Encoding]::new($false))
                $commentOnly = Get-YAxUnitProductionApplicability -Catalog $catalog
                [pscustomobject]@{ selfRegistered = $selfRegistered; undiscoverable = $undiscoverable; commentOnly = $commentOnly }
            }
            $result.selfRegistered.classificationComplete | Should -BeTrue
            $result.selfRegistered.decisions[0].decision | Should -Be 'required'
            $result.undiscoverable.classificationComplete | Should -BeFalse
            $result.commentOnly.classificationComplete | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "compares a legacy baseline with a new dirty BSL file in a Cyrillic path containing spaces" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl проверка тестов " + [guid]::NewGuid().ToString('N'))
        try {
            $sourcePath = 'src/cf/CommonModules/Новый Расчет/Ext/Module.bsl'
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.agent-1c') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'src\cf\CommonModules\Новый Расчет\Ext') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'src\cf\CommonModules\Старый Расчет\Ext') | Out-Null
            [IO.File]::WriteAllText((Join-Path $tempRoot '.agent-1c\project.json'), '{"schemaVersion":1,"baseConfigurationVersion":"PM5","exportPath":"src/cf","testsPath":"tests/features"}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot 'README.md'), 'baseline', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot 'src\cf\CommonModules\Старый Расчет\Ext\Module.bsl'), 'Процедура Старая() КонецПроцедуры', [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email 'tests@example.invalid'
            & git -C $tempRoot config user.name 'ITL Tests'
            & git -C $tempRoot add -- .
            & git -C $tempRoot commit -m baseline *> $null
            $baseline = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout -b itldev/applicability *> $null
            $legacyDirtyPath = 'src/cf/CommonModules/До Обновления/Ext/Module.bsl'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $tempRoot $legacyDirtyPath)) | Out-Null
            [IO.File]::WriteAllText((Join-Path $tempRoot $legacyDirtyPath), 'Процедура СтараяПравка() КонецПроцедуры', [Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:AdoptionState = [pscustomobject]@{ yaxunitApplicabilityBaseline = $null }
                function Read-DevBranchState { param($Name) $script:AdoptionState }
                function Update-DevBranchState { param($State, $Updates) $script:AdoptionState.yaxunitApplicabilityBaseline = $Updates.yaxunitApplicabilityBaseline }
                $catalog = [pscustomobject]@{ groups = @(); assignments = @(); registrationPaths = @(); notApplicable = @() }
                $legacy = Get-YAxUnitProductionApplicability -Catalog $catalog
                $adopted = $script:AdoptionState.yaxunitApplicabilityBaseline
                $inventoryLegacy = Update-VerificationSuiteInventory -Reason 'legacy applicability preflight' -EvaluateApplicability
                [IO.File]::WriteAllText((Join-Path $tempRoot 'src\cf\CommonModules\Новый Расчет\Ext\Module.bsl'), 'Процедура Рассчитать() КонецПроцедуры', [Text.UTF8Encoding]::new($false))
                $inventoryBefore = Update-VerificationSuiteInventory -Reason 'applicability preflight' -EvaluateApplicability
                $unclassified = Get-YAxUnitProductionApplicability -Catalog $catalog
                $catalog.notApplicable = @([pscustomobject]@{ path = $sourcePath; sourceOid = [string]$unclassified.issues[0].Split('=')[-1].Split('.')[0]; reason = 'No local decision point' })
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'tests') | Out-Null
                [IO.File]::WriteAllText((Join-Path $tempRoot 'tests\yaxunit-suites.branch.json'),
                    ((@{ schemaVersion = 1; notApplicable = @($catalog.notApplicable) } | ConvertTo-Json -Depth 5)), [Text.UTF8Encoding]::new($false))
                $inventoryAfter = Update-VerificationSuiteInventory -Reason 'applicability preflight' -EvaluateApplicability
                $classified = Get-YAxUnitProductionApplicability -Catalog $catalog
                $fingerprintBefore = Get-VerificationFingerprint
                $catalog.notApplicable[0].reason = 'Reconsidered interactive route'
                [IO.File]::WriteAllText((Join-Path $tempRoot 'tests\yaxunit-suites.branch.json'),
                    ((@{ schemaVersion = 1; notApplicable = @($catalog.notApplicable) } | ConvertTo-Json -Depth 5)), [Text.UTF8Encoding]::new($false))
                $fingerprintAfter = Get-VerificationFingerprint
                $proofState = [pscustomobject]@{ lastVerificationStatus = 'passed'; lastVerifiedCommit = $baseline; lastVerifiedFingerprint = $fingerprintBefore }
                $proofAfterDecisionChange = Get-VerificationState -State $proofState -CurrentCommit $baseline -CurrentFingerprint $fingerprintAfter
                [IO.File]::WriteAllText((Join-Path $tempRoot $legacyDirtyPath), 'Процедура НоваяПравка() КонецПроцедуры', [Text.UTF8Encoding]::new($false))
                $changedLegacy = Get-YAxUnitProductionApplicability -Catalog $catalog
                [pscustomobject]@{ legacy = $legacy; adopted = $adopted; unclassified = $unclassified; classified = $classified; changedLegacy = $changedLegacy; inventoryLegacy = $inventoryLegacy; inventoryBefore = $inventoryBefore; inventoryAfter = $inventoryAfter; fingerprintBefore = $fingerprintBefore; fingerprintAfter = $fingerprintAfter; proofAfterDecisionChange = $proofAfterDecisionChange }
            }
            $result.legacy.classificationComplete | Should -BeTrue -Because ($result.legacy.issues -join '; ')
            @($result.legacy.decisions).Count | Should -Be 0
            $result.adopted.commit | Should -Be $baseline
            $result.adopted.legacy | Should -BeTrue
            $result.adopted.legacySourceOids[0].path | Should -Be $legacyDirtyPath
            $result.inventoryLegacy.classificationComplete | Should -BeTrue
            $result.unclassified.classificationComplete | Should -BeFalse
            $result.unclassified.issues[0] | Should -Match 'Новый Расчет'
            $result.inventoryBefore.classificationComplete | Should -BeFalse
            $result.inventoryBefore.yaxunit.classificationComplete | Should -BeFalse
            $result.classified.classificationComplete | Should -BeTrue
            $result.classified.legacy | Should -BeTrue
            $result.classified.decisions[0].path | Should -Be $sourcePath
            $result.inventoryAfter.classificationComplete | Should -BeTrue
            $result.inventoryAfter.yaxunit.legacyBaseline | Should -BeTrue
            $result.fingerprintAfter | Should -Not -Be $result.fingerprintBefore
            $result.proofAfterDecisionChange.effectiveStatus | Should -Be 'stale'
            $result.changedLegacy.classificationComplete | Should -BeFalse
            @($result.changedLegacy.issues | Where-Object { $_ -match 'До Обновления' }).Count | Should -Be 1
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }
}
