BeforeAll {
    $helperPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
}

Describe 'Producer feature title identities in native JUnit coverage' {
    BeforeAll {
        function Get-NativeFeatureTitleFixtureCoverage {
            param([string]$Root, [object[]]$Features, [string[]]$SelectedSuiteIds, [string]$JUnitText)

            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'), (Join-Path $Root 'run') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'), '{}', [Text.UTF8Encoding]::new($false))
            $assignments = @()
            foreach ($feature in $Features) {
                $fullPath = Join-Path $Root $feature.path
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullPath) | Out-Null
                [IO.File]::WriteAllText($fullPath, $feature.text, [Text.UTF8Encoding]::new($false))
                $assignments += [pscustomobject]@{path=$feature.path;fullPath=$fullPath;suiteId=$feature.suiteId}
            }
            $reportPath = Join-Path $Root 'run/junit.xml'
            [IO.File]::WriteAllText($reportPath, $JUnitText, [Text.UTF8Encoding]::new($false))
            & {
                . $helperPath -ProjectRoot $Root -Action help *> $null
                $catalog = [pscustomobject]@{assignments=$assignments}
                $junit = Get-VanessaJunitSummary -ReportPaths @($reportPath)
                [pscustomobject]@{
                    junit=$junit
                    definitions=@(Get-VanessaFeatureScenarioDefinitions -FeatureFiles @($assignments.fullPath))
                    coverage=@(Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds $SelectedSuiteIds -JUnit $junit)
                }
            }
        }
        $liveFeature = @'
#language: ru

@itl_migration_acceptance
Функционал: Прикладная база PM5 после продолжения прерванного refresh

Контекст:
    Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий

Сценарий: Клиент подключён к исходной конфигурации PM5 и выполняет серверный запрос
    И я выполняю код встроенного языка на сервере (Расширение)
        """bsl
            Если Метаданные.Имя <> "УправлениеПроектамиКОРП" Тогда
                ВызватьИсключение "Продолжение refresh открыло другую конфигурацию";
            КонецЕсли;
            Если Метаданные.Версия <> "5.0.2.119" Тогда
                ВызватьИсключение "Продолжение refresh изменило исходную версию PM5";
            КонецЕсли;
            Запрос = Новый Запрос("ВЫБРАТЬ 42 КАК Ответ");
            Выборка = Запрос.Выполнить().Выбрать();
            Если Не Выборка.Следующий() Или Выборка.Ответ <> 42 Тогда
                ВызватьИсключение "Сервер прикладной базы не выполнил контрольный запрос";
            КонецЕсли;
        """
'@
        $liveCaseName = 'Клиент подключён к исходной конфигурации PM5 и выполняет серверный запрос'
        $liveFeatureTitle = 'Прикладная база PM5 после продолжения прерванного refresh'
        $liveDefinitions = @([pscustomobject]@{path='tests/features/PausedRefreshPM5Identity.feature';suiteId='paused-refresh-pm5-identity';text=$liveFeature})
    }

    It 'observes the unchanged live PM5 title and scenario under a Unicode path with spaces' -Tag 'native-feature-title' {
        $actual = Get-NativeFeatureTitleFixtureCoverage -Root (Join-Path $TestDrive 'Исходная ветка PM5 с пробелами') -Features $liveDefinitions -SelectedSuiteIds @('paused-refresh-pm5-identity') -JUnitText @"
<?xml version="1.0" encoding="UTF-8"?>
<testsuites><testsuite name="$liveFeatureTitle" errors="0" skipped="0" tests="1" failures="0" time="25.21"><testcase name="$liveCaseName" classname="$liveFeatureTitle" time="25.21" StartDate="20261001180900" timestamp="2026-10-01T18:09:00" EndDate="20261001180925"/></testsuite></testsuites>
"@
        $actual.junit.tests | Should -Be 1
        $actual.junit.failures | Should -Be 0
        $actual.junit.errors | Should -Be 0
        $actual.junit.skipped | Should -Be 0
        $actual.coverage[0].status | Should -Be 'passed'
        $actual.coverage[0].expectedCount | Should -Be 1
        $actual.coverage[0].observedCount | Should -Be 1
        $actual.definitions[0].sourceLine | Should -Be 9
        $actual.definitions[0].featureName | Should -BeExactly $liveFeatureTitle
    }

    It 'rejects a fabricated basename classname when the source has a valid distinct title' -Tag 'native-feature-title' {
        $actual = Get-NativeFeatureTitleFixtureCoverage -Root (Join-Path $TestDrive 'Подмена имени PM5 с пробелами') -Features $liveDefinitions -SelectedSuiteIds @('paused-refresh-pm5-identity') -JUnitText "<testsuite tests=`"1`" failures=`"0`" errors=`"0`" skipped=`"0`"><testcase classname=`"PausedRefreshPM5Identity`" name=`"$liveCaseName`"/></testsuite>"
        $actual.coverage[0].status | Should -Be 'partial'
        $actual.coverage[0].observedCount | Should -Be 0
        $actual.coverage[0].issue | Should -Match 'missing|unmapped'
    }

    It 'keeps duplicate titles and scenario names ambiguous across selected and unselected suites' -Tag 'native-feature-title' -TestCases @(@{Selected=@('orders','integration')}, @{Selected=@('orders')}) {
        param($Selected)
        $features = @(
            [pscustomobject]@{path='tests/features/Orders/orders-file.feature';suiteId='orders';text="Функционал: Общее сохранение данных`nСценарий: Результат сохранён`nКогда Данные сохранены`n"},
            [pscustomobject]@{path='tests/features/Integration/integration-file.feature';suiteId='integration';text="Функционал: Общее сохранение данных`nСценарий: Результат сохранён`nКогда Данные сохранены`n"}
        )
        $actual = Get-NativeFeatureTitleFixtureCoverage -Root (Join-Path $TestDrive ("Одинаковые заголовки 1С " + $Selected.Count)) -Features $features -SelectedSuiteIds $Selected -JUnitText '<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase classname="Общее сохранение данных" name="Результат сохранён"/></testsuite>'
        foreach ($coverage in $actual.coverage) {
            $coverage.status | Should -Be 'partial'
            $coverage.issue | Should -Match 'ambiguous'
            $coverage.observedCount | Should -Be 0
        }
    }

    It 'resolves the producer first directory prefix with the real duplicate feature titles' -Tag 'native-feature-title' {
        $features = @(
            [pscustomobject]@{path='tests/features/Заказы с пробелами/deep/orders-file.feature';suiteId='orders';text="Функционал: Общее сохранение данных`nСценарий: Результат сохранён`nКогда Данные сохранены`n"},
            [pscustomobject]@{path='tests/features/Обмен с пробелами/deep/integration-file.feature';suiteId='integration';text="Функционал: Общее сохранение данных`nСценарий: Результат сохранён`nКогда Данные сохранены`n"}
        )
        $actual = Get-NativeFeatureTitleFixtureCoverage -Root (Join-Path $TestDrive 'Каталоги с пробелами и кириллицей') -Features $features -SelectedSuiteIds @('orders','integration') -JUnitText '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase classname="Заказы с пробелами.Общее сохранение данных" name="Результат сохранён"/><testcase classname="Обмен с пробелами.Общее сохранение данных" name="Результат сохранён"/></testsuite>'
        foreach ($coverage in $actual.coverage) {
            $coverage.status | Should -Be 'passed'
            $coverage.expectedCount | Should -Be 1
            $coverage.observedCount | Should -Be 1
        }
    }

    It 'does not credit duplicated native cases to a missing selected title' -Tag 'native-feature-title' {
        $features = @(
            [pscustomobject]@{path='tests/features/orders-file.feature';suiteId='orders';text="Функционал: Заказы PM5`nСценарий: Результат сохранён`nКогда Данные сохранены`n"},
            [pscustomobject]@{path='tests/features/integration-file.feature';suiteId='integration';text="Функционал: Обмен PM5`nСценарий: Результат сохранён`nКогда Данные сохранены`n"}
        )
        $actual = Get-NativeFeatureTitleFixtureCoverage -Root (Join-Path $TestDrive 'Дублированные native результаты 1С') -Features $features -SelectedSuiteIds @('orders','integration') -JUnitText '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase classname="Заказы PM5" name="Результат сохранён"/><testcase classname="Заказы PM5" name="Результат сохранён"/></testsuite>'
        $actual.junit.tests | Should -Be 2
        foreach ($coverage in $actual.coverage) { $coverage.status | Should -Be 'partial'; $coverage.issue | Should -Match 'missing or duplicate' }
        @($actual.coverage | Where-Object id -eq 'orders')[0].observedCount | Should -Be 2
        @($actual.coverage | Where-Object id -eq 'integration')[0].observedCount | Should -Be 0
    }
}

Describe 'Canonical assessment of current component and obligation receipts' {
    It 'does not promote an unobserved selected suite when total JUnit count is satisfied by another suite' -Tag 'suite-observed-coverage' {
        $root = Join-Path $TestDrive 'Неполное покрытие двух групп 1С'
        foreach ($relative in @('.agent-1c','tests/features','src/cf/Orders','src/cf/Integration','run')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        $suites = @(); $obligations = @()
        foreach ($id in @('orders','integration')) {
            [IO.File]::WriteAllText((Join-Path $root "tests/features/$id.feature"),"Функционал: $id`nСценарий: Результат сохранён`nКогда Данные сохранены`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root "src/cf/$id/source.bsl"),'Procedure Current() EndProcedure',[Text.UTF8Encoding]::new($false))
            $suites += @{id=$id;purpose='acceptance';featurePaths=@("tests/features/$id.feature");ownerPaths=@("src/cf/$id/**")}
            $obligations += @{id="$id-result";expectedResult='The selected scenario passes';inputPaths=@("src/cf/$id/**");admissibleProof=@('vanessa-junit');retention='retained';retentionReason='Reusable coverage';cadence='affected';suiteId=$id}
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'),(@{schemaVersion=2;suites=$suites;obligations=$obligations}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $root init -b master *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        & git -C $root add -- .agent-1c/project.json src tests
        & git -C $root commit -qm 'selected suite coverage inputs'
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $state = [pscustomobject]@{stateProjectRoot=$root;infoBaseKind='file';devBranchInfoBasePath=(Join-Path $root 'База 1С');toolingInfoBaseGeneration='base-generation';vanessaServiceInfoBaseGeneration='runner-generation'}
            $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
            $plan = [pscustomobject]@{catalogAvailable=$true;currentTree=(Get-VerificationSelectionEffectiveTree);catalogFingerprint=$catalog.fingerprint;acceptanceSuiteIds=@($catalog.suiteFingerprints.id);acceptanceSuites=$catalog.suiteFingerprints;selectedSuiteIds=@('orders','integration');mode='full'}
            $report = Join-Path $root 'run/junit.xml'
            # Both pinned readers replace the feature node basename with its title.
            # Native JUnit uses that title and the first relative directory, if any.
            # Both tests succeed, but the second selected suite was never observed.
            Write-Utf8TextAtomic -Path $report -Value '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase classname="orders" name="Результат сохранён"/><testcase classname="orders" name="Результат сохранён"/></testsuite>'
            Assert-VanessaScenarioCountJunitEvidence -RunDirectory (Join-Path $root 'run') -ExpectedScenarioCount 2 | Out-Null
            Complete-VerificationSelectionProof -Plan $plan -State $state -RunDirectory (Join-Path $root 'run') -Status passed
            $missing = Read-VerificationSelectionProof
            $state | Add-Member -NotePropertyMembers @{lastVerificationStatus='passed';lastVerifiedFingerprint=(Get-VerificationFingerprint);lastVerifiedLoadedBaseIdentity=(Get-VerificationLoadedBaseIdentity -State $state)}
            $partial = Get-VerificationState -State $state
            Write-Utf8TextAtomic -Path $report -Value '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase classname="orders" name="Результат сохранён"/><testcase classname="integration" name="Результат сохранён"/></testsuite>'
            Complete-VerificationSelectionProof -Plan $plan -State $state -RunDirectory (Join-Path $root 'run') -Status passed
            [pscustomobject]@{missing=$missing;partial=$partial;complete=(Read-VerificationSelectionProof)}
        }
        @($actual.missing.suiteEvidence | Where-Object id -eq 'integration')[0].status | Should -Be 'partial'
        @($actual.missing.suiteEvidence | Where-Object id -eq 'integration')[0].coverageIssue | Should -Match 'unobserved|missing'
        $actual.partial.isFreshPassed | Should -BeFalse -Because 'new partial suite evidence must invalidate an older legacy global pass even without a component receipt'
        foreach ($receipt in $actual.complete.suiteEvidence) { $receipt.status | Should -Be 'passed' }
    }

    It 'keeps ambiguous native identities unverified and maps directory-qualified and outline cases' -Tag 'suite-observed-coverage' {
        $root = Join-Path $TestDrive 'Различение одинаковых имён 1С'
        foreach ($relative in @('.agent-1c','tests/features/Orders','tests/features/Integration')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        foreach ($id in @('Orders','Integration')) {
            [IO.File]::WriteAllText((Join-Path $root "tests/features/$id/shared.feature"),"Функционал: Сохранение`nСценарий: Результат сохранён`nКогда Данные сохранены`n",[Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/features/outline.feature'),"Функционал: Примеры`nСтруктура сценария: Значение <Value>`nКогда Проверено <Value>`nПримеры:`n| Value |`n| 1 |`n| 2 |`nПримеры:`n| Value |`n| 3 |`n",[Text.UTF8Encoding]::new($false))
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $catalog = [pscustomobject]@{assignments=@(
                [pscustomobject]@{path='tests/features/Orders/shared.feature';fullPath=(Join-Path $root 'tests/features/Orders/shared.feature');suiteId='orders'},
                [pscustomobject]@{path='tests/features/Integration/shared.feature';fullPath=(Join-Path $root 'tests/features/Integration/shared.feature');suiteId='integration'},
                [pscustomobject]@{path='tests/features/outline.feature';fullPath=(Join-Path $root 'tests/features/outline.feature');suiteId='outline'}
            )}
            $ambiguous = Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds @('orders','integration') -JUnit ([pscustomobject]@{testCases=@([pscustomobject]@{name='Результат сохранён';className='Сохранение'},[pscustomobject]@{name='Результат сохранён';className='Сохранение'})})
            $qualified = Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds @('orders','integration') -JUnit ([pscustomobject]@{testCases=@([pscustomobject]@{name='Результат сохранён';className='Orders.Сохранение'},[pscustomobject]@{name='Результат сохранён';className='Integration.Сохранение'})})
            $report = Join-Path $root 'qualified.xml'
            Write-Utf8TextAtomic -Path $report -Value '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase classname="Orders.Сохранение" name="Результат сохранён"/><testcase classname="Integration.Сохранение" name="Результат сохранён"/></testsuite>'
            $coverageFailures = @()
            foreach ($coverage in $qualified) {
                try { Assert-VerificationRetainedSuiteCoverage -Receipt ([pscustomobject]@{id=$coverage.id;coverage=$coverage;artifacts=@([pscustomobject]@{path='qualified.xml'})}) -Catalog $catalog }
                catch { $coverageFailures += $_.Exception.Message }
            }
            $outline = Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds @('outline') -JUnit ([pscustomobject]@{testCases=@([pscustomobject]@{name='Значение <Value> №0';className='Примеры'},[pscustomobject]@{name='Значение <Value> №1';className='Примеры'},[pscustomobject]@{name='Значение <Value> №0';className='Примеры'})})
            [pscustomobject]@{ambiguous=$ambiguous;qualified=$qualified;coverageFailures=$coverageFailures;outline=$outline}
        }
        foreach ($receipt in $actual.ambiguous) { $receipt.status | Should -Be 'partial'; $receipt.issue | Should -Match 'ambiguous' }
        foreach ($receipt in $actual.qualified) { $receipt.status | Should -Be 'passed' }
        @($actual.coverageFailures).Count | Should -Be 0 -Because 'a shared native report must remain applicable per suite without counting another qualified suite'
        $actual.outline.status | Should -Be 'passed'
        $actual.outline.observedCount | Should -Be 3
    }

    It 'rejects unknown target and runner generations without inventing a compatible auxiliary connection' -Tag 'retained-target-identity' {
        $root = Join-Path $TestDrive 'Неизвестный target с пробелами'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $state = [pscustomobject]@{stateProjectRoot=$root;infoBaseKind='file';devBranchInfoBasePath=(Join-Path $root 'База 1С');toolingInfoBaseGeneration='base-generation';vanessaServiceInfoBaseGeneration='runner-generation'}
            $primary = Get-VerificationRetainedTargetIdentity -State $state
            $missing = @()
            foreach($field in @('stateProjectRoot','infoBaseKind','devBranchInfoBasePath','toolingInfoBaseGeneration','vanessaServiceInfoBaseGeneration')) {
                $old = $state.$field
                $state.$field = ''
                try { Get-VerificationRetainedTargetIdentity -State $state | Out-Null; $missing += '' }
                catch { $missing += $_.Exception.Message }
                $state.$field = $old
            }
            $script:ActiveAuxiliaryVanessaContext = [pscustomobject]@{contour=[pscustomobject]@{name='Other';baseMode='attached-readonly'};suite='other'}
            $auxiliary = ''
            try { Get-VerificationRetainedTargetIdentity -State $state|Out-Null } catch { $auxiliary=$_.Exception.Message }
            $script:ActiveAuxiliaryVanessaContext = $null
            [pscustomobject]@{primary=$primary;missing=$missing;auxiliary=$auxiliary}
        }
        $result.primary | Should -Match '^[a-f0-9]{64}$'
        foreach($failure in $result.missing) { $failure | Should -Match 'VERIFICATION_RETAINED_TARGET_UNVERIFIED' }
        $result.auxiliary | Should -Match 'auxiliary connection identity is unknown'
    }

    It 'assesses <Kind> current proof with all runners off and rejects changed evidence without starting a runner' -ForEach @(
        @{ Kind='one-off-only'; Retained=$false },
        @{ Kind='one-off and retained affected/handoff'; Retained=$true }
    ) {
        $root = Join-Path $TestDrive ('Текущие доказательства 1С ' + [guid]::NewGuid().ToString('N'))
        foreach ($relative in @('.agent-1c','tests/features','src/cf/Orders','src/cf/Integration','evidence')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        & git -C $root init -b master *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/current.bsl'),'Procedure Current() EndProcedure',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/Orders/metadata.xml'),'<metadata />',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/Integration/metadata.xml'),'<metadata />',[Text.UTF8Encoding]::new($false))
        $obligations = @(@{
            id='current-result'; expectedResult='Observed value is 42'; inputPaths=@('src/cf/current.bsl')
            admissibleProof=@('runtime-observation'); retention='one-off'; retentionReason='A bounded current check is sufficient'; cadence='explicit'
        })
        $suites = @()
        if ($Retained) {
            foreach ($entry in @(@{id='orders';cadence='affected';owner='Orders'},@{id='integration';cadence='handoff';owner='Integration'})) {
                [IO.File]::WriteAllText((Join-Path $root "tests/features/$($entry.id).feature"),"Функционал: $($entry.id)`nСценарий: Результат сохранён`nКогда Данные сохранены`n",[Text.UTF8Encoding]::new($false))
                $suites += @{id=$entry.id;purpose='acceptance';featurePaths=@("tests/features/$($entry.id).feature");ownerPaths=@("src/cf/$($entry.owner)/**")}
                $obligations += @{id="$($entry.id)-result";expectedResult='The retained scenario passes';inputPaths=@("src/cf/$($entry.owner)/**");admissibleProof=@('vanessa-junit');retention='retained';retentionReason='Preserve reusable coverage';cadence=$entry.cadence;suiteId=$entry.id}
            }
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'),(@{schemaVersion=2;suites=$suites;obligations=$obligations}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $root add -- .agent-1c/project.json src tests
        & git -C $root commit -qm 'current proof inputs'
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:AggregateState = [pscustomobject]@{
                stateProjectRoot=$root;devBranchName='aggregate';safeDevBranchName='aggregate';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $root 'База 1С')
                lastConfigDesignerFingerprint=(Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint;configLoadStatus='passed'
                toolingInfoBaseGeneration='target-generation';vanessaServiceInfoBaseGeneration='runner-generation'
                enterpriseNormalizationStatus='passed';enterpriseNormalizationProofVersion=1
                lastVerificationStatus='partial';lastVerifiedFingerprint='';lastVerifiedLoadedBaseIdentity=''
                yaxunitApplicabilityBaseline=[pscustomobject]@{schemaVersion=1;commit=(Get-CurrentCommit);legacy=$false}
            }
            $script:UnexpectedRunnerCalls = 0
            function Read-DevBranchState { $script:AggregateState }
            function Update-DevBranchState { param($State,$Updates) foreach($name in $Updates.Keys){$script:AggregateState|Add-Member -NotePropertyName $name -NotePropertyValue $Updates[$name] -Force} }
            function Assert-DevelopmentBranchWorktreeContext { param($State,$Operation) }
            function Get-EnvValue { param($Name,$Default) if($Name -like 'ITL_*' -or $Name -eq 'TOOL_BROWSER'){return 'off'};return $Default }
            function Invoke-YAxUnitVerification { $script:UnexpectedRunnerCalls++;throw 'A forbidden YAxUnit runner started' }
            function Run-DevBranchTests { $script:UnexpectedRunnerCalls++;throw 'A forbidden Vanessa runner started' }
            function Test-ItlEventLogCurrent { $script:UnexpectedRunnerCalls++;throw 'A forbidden event-log rerun started' }
            $oneOff = @(Get-VerificationOneOffObligations)[0]
            $draft = Start-VerificationOneOffProof -ObligationId $oneOff.id
            $observedPath = Join-Path $root 'evidence/current-result.txt'
            [IO.File]::WriteAllText($observedPath,'Observed value: 42',[Text.UTF8Encoding]::new($false))
            $document = @{obligationId=$oneOff.id;runToken=$draft.runToken;expectedResult=$draft.expectedResult;status='passed';proofType='runtime-observation';actualResult='Observed value is 42';providerId='fixture-current-target';runnerVersion='1';steps=@(@{action='Observe the current fixture result';actual='42'});artifactPaths=@('evidence/current-result.txt');invocationProvenance=@{scope='named-one-off';expiresAt='2000-01-01T00:00:00Z';persistentMode='off'}}
            Write-Utf8TextAtomic -Path (Join-Path $root 'evidence/current-result.json') -Value ($document|ConvertTo-Json -Depth 8)
            Complete-VerificationOneOffProof -EvidencePath 'evidence/current-result.json' | Out-Null
            $fingerprint = Get-VerificationFingerprint
            $loaded = Get-VerificationLoadedBaseIdentity -State $script:AggregateState
            $eventPath = Join-Path $root 'evidence/event-log.json'
            [IO.File]::WriteAllText($eventPath,'{"status":"passed","newErrorCount":0,"scanMode":"cursor","cursorScope":"lifecycle-pending"}',[Text.UTF8Encoding]::new($false))
            $component = [pscustomobject]@{schemaVersion=1;component='event-log';status='passed';inputFingerprint=$fingerprint;loadedBaseIdentity=$loaded;checkerIdentity=(Get-VerificationOneOffCheckerIdentity -ProofType 'event-log');artifacts=@([pscustomobject]@{path='evidence/event-log.json';sha256=(Get-FileHash -LiteralPath $eventPath).Hash.ToLowerInvariant()});limitations='Fixture event-log result for this exact target'}
            $script:AggregateState|Add-Member -NotePropertyName lastVerificationComponentEvidence -NotePropertyValue ([pscustomobject]@{'event-log'=$component})
            if ($Retained) {
                $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
                $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $files
                $suiteEvidence = @()
                foreach($suite in $catalog.suiteFingerprints){
                    $obligation = @($catalog.obligations|Where-Object suiteId -eq $suite.id)[0]
                    $artifact = "evidence/$($suite.id).xml"
                    [IO.File]::WriteAllText((Join-Path $root $artifact),"<testsuite tests=`"1`" failures=`"0`" errors=`"0`" skipped=`"0`"><testcase classname=`"$($suite.id)`" name=`"Результат сохранён`"/></testsuite>",[Text.UTF8Encoding]::new($false))
                    $junit = Get-VanessaJunitSummary -ReportPaths @((Join-Path $root $artifact))
                    $coverage = @(Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds @($suite.id) -JUnit $junit)[0]
                    $suiteEvidence += [pscustomobject]@{schemaVersion=1;id=$suite.id;status='passed';coverage=$coverage;obligationHash=(Get-VerificationOneOffObligationHash -Obligation $obligation);inputIdentity=(Get-VerificationObligationInputIdentity -Obligation $obligation);runtimeIdentity=(Get-VerificationRelevantDependencyLockFingerprint -Treeish (Get-VerificationSelectionEffectiveTree));loadedBaseIdentity=$loaded;targetIdentity=(Get-VerificationRetainedTargetIdentity -State $script:AggregateState);checkerIdentity=(Get-VerificationRetainedCheckerIdentity);artifacts=@([pscustomobject]@{path=$artifact;sha256=(Get-FileHash -LiteralPath (Join-Path $root $artifact)).Hash.ToLowerInvariant()})}
                }
                New-Item -ItemType Directory -Force -Path (Get-VerificationSelectionStateRoot)|Out-Null
                Write-Utf8TextAtomic -Path (Join-Path (Get-VerificationSelectionStateRoot) 'proof.json') -Value (@{schemaVersion=1;tree=(Get-VerificationSelectionEffectiveTree);acceptanceSuites=$catalog.suiteFingerprints;acceptanceSuiteIds=@($catalog.suiteFingerprints.id);suiteEvidence=$suiteEvidence}|ConvertTo-Json -Depth 10)
            }
            Invoke-ItlVerificationCycle -Trigger command
            $ready = Get-VerificationState -State $script:AggregateState
            $stateFile = Join-Path $root '.agent-1c/current-proof-state.json'
            Write-Utf8TextAtomic -Path $stateFile -Value ($script:AggregateState | ConvertTo-Json -Depth 12)
            function Get-DevBranchStateFiles { @(Get-Item -LiteralPath $stateFile) }
            $protected = Get-ItlArtifactProtectedPaths -ProjectRoot $root
            $protection = @([pscustomobject]@{path=$eventPath;protected=$protected.Contains([IO.Path]::GetFullPath($eventPath))})
            if ($Retained) {
                foreach($suite in $suiteEvidence) {
                    $full = Resolve-ProjectPath $suite.artifacts[0].path
                    $protection += [pscustomobject]@{path=$full;protected=$protected.Contains([IO.Path]::GetFullPath($full))}
                }
            }
            function Get-VerificationPolicy { 'block' }
            $allowed = ''
            try { Confirm-UnverifiedProceed -State $script:AggregateState -Operation 'export-dev-branch-result' -VerificationState $ready|Out-Null } catch { $allowed=$_.Exception.Message }
            $negativeChecks = @()
            $eventReceipt = $script:AggregateState.lastVerificationComponentEvidence.'event-log'
            $script:AggregateState.lastVerificationComponentEvidence.'event-log' = $null
            $negativeChecks += [pscustomobject]@{ boundary='missing event-log'; assessment=(Get-VerificationState -State $script:AggregateState) }
            $script:AggregateState.lastVerificationComponentEvidence.'event-log' = $eventReceipt
            $eventText = Read-Utf8Text -Path $eventPath
            Write-Utf8TextAtomic -Path $eventPath -Value '{"status":"passed","newErrorCount":1}'
            $negativeChecks += [pscustomobject]@{ boundary='changed event-log artifact'; assessment=(Get-VerificationState -State $script:AggregateState) }
            Write-Utf8TextAtomic -Path $eventPath -Value $eventText
            $oldTarget = $script:AggregateState.devBranchInfoBasePath
            $script:AggregateState.devBranchInfoBasePath = Join-Path $root 'Другая база 1С'
            $negativeChecks += [pscustomobject]@{ boundary='changed loaded target'; assessment=(Get-VerificationState -State $script:AggregateState) }
            $script:AggregateState.devBranchInfoBasePath = $oldTarget
            $oldSource = $script:AggregateState.lastConfigDesignerFingerprint
            $script:AggregateState.lastConfigDesignerFingerprint = 'stale-source'
            $negativeChecks += [pscustomobject]@{ boundary='source not loaded'; assessment=(Get-VerificationState -State $script:AggregateState) }
            $script:AggregateState.lastConfigDesignerFingerprint = $oldSource
            $scopedReuse = $null
            if ($Retained) {
                $integrationPath = Join-Path $root 'src/cf/Integration/metadata.xml'
                $originalIntegration = Read-Utf8Text -Path $integrationPath
                Write-Utf8TextAtomic -Path $integrationPath -Value '<metadata changed="integration" />'
                $negativeChecks += [pscustomobject]@{boundary='changed source before reload';assessment=(Get-VerificationState -State $script:AggregateState)}
                $script:AggregateState.lastConfigDesignerFingerprint = (Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint
                $afterReload = New-VerificationSelectionPlan -ApplicationFeatureFiles $files -RequireObservedReceipts
                $negativeChecks += [pscustomobject]@{boundary='changed relevant suite after valid reload';assessment=(Get-VerificationState -State $script:AggregateState)}
                $scopedReuse = [pscustomobject]@{plan=$afterReload;provenance=$suiteEvidence[0].loadedBaseIdentity;originalLoaded=$loaded}
                Write-Utf8TextAtomic -Path $integrationPath -Value $originalIntegration
                $script:AggregateState.lastConfigDesignerFingerprint = $oldSource
                $featurePath = Join-Path $root 'tests/features/integration.feature'
                $originalFeature = Read-Utf8Text -Path $featurePath
                Write-Utf8TextAtomic -Path $featurePath -Value ($originalFeature.Replace('Результат сохранён','Изменённый результат сохранён'))
                $featurePlan = New-VerificationSelectionPlan -ApplicationFeatureFiles $files -RequireObservedReceipts
                $negativeChecks += [pscustomobject]@{boundary='changed relevant feature case';assessment=(Get-VerificationState -State $script:AggregateState)}
                Write-Utf8TextAtomic -Path $featurePath -Value $originalFeature
                $oldGeneration = $script:AggregateState.vanessaServiceInfoBaseGeneration
                $script:AggregateState.vanessaServiceInfoBaseGeneration = 'new-runner-generation'
                $negativeChecks += [pscustomobject]@{boundary='changed runner generation';assessment=(Get-VerificationState -State $script:AggregateState)}
                $runnerPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles $files -RequireObservedReceipts
                $script:AggregateState.vanessaServiceInfoBaseGeneration = $oldGeneration
                $script:ActiveAuxiliaryVanessaContext = [pscustomobject]@{contour=[pscustomobject]@{name='Other contour';baseMode='attached-readonly'};suite='other';featuresPath='tests/features'}
                $negativeChecks += [pscustomobject]@{boundary='different auxiliary scope';assessment=(Get-VerificationState -State $script:AggregateState)}
                $auxiliaryPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles $files -RequireObservedReceipts
                $script:ActiveAuxiliaryVanessaContext = $null
            }
            $writerUpdates = @{}
            $observation = $eventText | ConvertFrom-Json
            Add-VerificationComponentEvidenceUpdates -Updates $writerUpdates -State $script:AggregateState -Component event-log -Status passed -EventLogObservation $observation -RunDirectory (Join-Path $root 'evidence')
            Update-DevBranchState -State $script:AggregateState -Updates $writerUpdates
            $writerAssessment = Get-VerificationState -State $script:AggregateState
            if ($Retained) {
                $proofPath = Join-Path (Get-VerificationSelectionStateRoot) 'proof.json'
                $originalProof = Read-Utf8Text -Path $proofPath
                $unknown = $originalProof | ConvertFrom-Json
                $unknown.suiteEvidence = @()
                Write-Utf8TextAtomic -Path $proofPath -Value ($unknown | ConvertTo-Json -Depth 10)
                $legacyReceiptPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles $files -RequireObservedReceipts
                Write-Utf8TextAtomic -Path $proofPath -Value $originalProof
                $incomplete = $originalProof | ConvertFrom-Json
                $incomplete.suiteEvidence = @($incomplete.suiteEvidence | Where-Object id -ne 'integration')
                Write-Utf8TextAtomic -Path $proofPath -Value ($incomplete | ConvertTo-Json -Depth 10)
                $negativeChecks += [pscustomobject]@{ boundary='missing retained handoff'; assessment=(Get-VerificationState -State $script:AggregateState) }
                $invalid = $originalProof | ConvertFrom-Json
                $badArtifact = $invalid.suiteEvidence[0].artifacts[0]
                $badPath = Resolve-ProjectPath $badArtifact.path
                $originalJunit = Read-Utf8Text -Path $badPath
                Write-Utf8TextAtomic -Path $badPath -Value '<testsuite tests="0" failures="0" errors="0"/>'
                $badArtifact.sha256 = (Get-FileHash -LiteralPath $badPath).Hash.ToLowerInvariant()
                Write-Utf8TextAtomic -Path $proofPath -Value ($invalid | ConvertTo-Json -Depth 10)
                $negativeChecks += [pscustomobject]@{ boundary='zero-tests with matching artifact SHA'; assessment=(Get-VerificationState -State $script:AggregateState) }
                Write-Utf8TextAtomic -Path $badPath -Value $originalJunit
                Write-Utf8TextAtomic -Path $proofPath -Value $originalProof
                $failedPlan = [pscustomobject]@{ catalogAvailable=$true;currentTree=(Get-VerificationSelectionEffectiveTree);catalogFingerprint=$catalog.fingerprint;acceptanceSuiteIds=@($catalog.suiteFingerprints.id);acceptanceSuites=$catalog.suiteFingerprints;selectedSuiteIds=@('integration');mode='selected' }
                Complete-VerificationSelectionProof -Plan $failedPlan -State $script:AggregateState -RunDirectory (Join-Path $root 'evidence') -Status failed
                $negativeChecks += [pscustomobject]@{ boundary='failed retained rerun'; assessment=(Get-VerificationState -State $script:AggregateState) }
                $nativeRun = Join-Path $root 'evidence/integration-native-run'
                New-Item -ItemType Directory -Force -Path $nativeRun | Out-Null
                Write-Utf8TextAtomic -Path (Join-Path $nativeRun 'junit.xml') -Value '<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase classname="integration" name="Результат сохранён"/></testsuite>'
                Complete-VerificationSelectionProof -Plan $failedPlan -State $script:AggregateState -RunDirectory $nativeRun -Status passed
                $recoveredWriterAssessment = Get-VerificationState -State $script:AggregateState
                Write-Utf8TextAtomic -Path $proofPath -Value $originalProof
            }
            [IO.File]::WriteAllText($observedPath,'Observed value: changed',[Text.UTF8Encoding]::new($false))
            $tampered = Get-VerificationState -State $script:AggregateState
            $blocked = ''
            try { Confirm-UnverifiedProceed -State $script:AggregateState -Operation 'export-dev-branch-result' -VerificationState $tampered|Out-Null } catch { $blocked=$_.Exception.Message }
            [pscustomobject]@{ready=$ready;allowed=$allowed;tampered=$tampered;blocked=$blocked;negativeChecks=$negativeChecks;protection=$protection;writerAssessment=$writerAssessment;recoveredWriterAssessment=$(if($Retained){$recoveredWriterAssessment}else{$writerAssessment});legacyReceiptPlan=$(if($Retained){$legacyReceiptPlan}else{$null});scopedReuse=$scopedReuse;featurePlan=$(if($Retained){$featurePlan}else{$null});runnerPlan=$(if($Retained){$runnerPlan}else{$null});auxiliaryPlan=$(if($Retained){$auxiliaryPlan}else{$null});unexpectedRunnerCalls=$script:UnexpectedRunnerCalls;state=$script:AggregateState}
        }
        $actual.ready.isFreshPassed | Should -BeTrue
        $actual.allowed | Should -BeNullOrEmpty
        $actual.writerAssessment.isFreshPassed | Should -BeTrue
        $actual.recoveredWriterAssessment.isFreshPassed | Should -BeTrue
        if ($Retained) {
            $actual.legacyReceiptPlan.mode | Should -Be 'full'
            @($actual.legacyReceiptPlan.selectedSuiteIds).Count | Should -Be 2
            $actual.scopedReuse.plan.mode | Should -Be 'incremental'
            $actual.scopedReuse.plan.selectedSuiteIds | Should -Contain 'integration'
            $actual.scopedReuse.plan.selectedSuiteIds | Should -Not -Contain 'orders'
            $actual.scopedReuse.provenance | Should -BeExactly $actual.scopedReuse.originalLoaded
            $actual.featurePlan.mode | Should -Be 'incremental'
            $actual.featurePlan.selectedSuiteIds | Should -Contain 'integration'
            $actual.featurePlan.selectedSuiteIds | Should -Not -Contain 'orders'
            $actual.runnerPlan.mode | Should -Be 'full'
            $actual.auxiliaryPlan.mode | Should -Be 'full'
        }
        $actual.unexpectedRunnerCalls | Should -Be 0
        $actual.state.lastVerificationTrigger | Should -Not -Be 'explicit'
        $actual.tampered.isFreshPassed | Should -BeFalse
        $actual.blocked | Should -Match 'stopped|missing|proof'
        foreach ($negative in $actual.negativeChecks) {
            $negative.assessment.isFreshPassed | Should -BeFalse -Because $negative.boundary
        }
        foreach ($reference in $actual.protection) { $reference.protected | Should -BeTrue -Because $reference.path }
    }
}
