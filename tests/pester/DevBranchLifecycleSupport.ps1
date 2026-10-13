. (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperModulePaths = $context.HelperModulePaths
        $LauncherPath = $context.LauncherPath
        $InstallerPath = $context.InstallerPath
        $McpHostPath = $context.McpHostPath
        $McpHostDumpPath = $context.McpHostDumpPath
        $HelperText = $context.HelperText
        $LauncherText = $context.LauncherText
        $McpHostText = $context.McpHostText

        function Initialize-LifecycleGate6NativeFixture {
            # ProjectRoot and the fictional infobase/source/list paths remain the
            # original test inputs. Only this mock's Out files use TestDrive;
            # DT/result/evidence paths are still selected by the real owner.
            $script:LifecycleGate6NativeCalls = [Collections.Generic.List[object]]::new()
            $script:LifecycleGate6Snapshots = @{}
            $script:LifecycleGate6OutRoot = Join-Path $TestDrive ('Designer fixture Кириллица '+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $script:LifecycleGate6OutRoot|Out-Null
            $script:LifecycleGate6LoadLog = ''
            $script:LifecycleGate6CheckWarning = $false
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
        }

        function Invoke-LifecycleGate6NativeFixture {
            param([string]$InfoBasePath,[string]$InfoBaseKind,[string[]]$DesignerArgs,$NativeEffectContract,$RestorationDuty)
            $sequence = Get-Variable -Name Sequence -Scope Script -ErrorAction SilentlyContinue
            $script:LifecycleGate6NativeCalls.Add([pscustomobject]@{
                arguments=@($DesignerArgs);infoBasePath=$InfoBasePath;infoBaseKind=$InfoBaseKind
                observedSequence=$(if($null -ne $sequence){@($sequence.Value)}else{@()})
            })
            switch($DesignerArgs[0]) {
                '/DumpIB' {
                    [IO.File]::WriteAllBytes($DesignerArgs[1],[byte[]](11,23,37,41))
                    $script:LifecycleGate6Snapshots[$DesignerArgs[1]]=(Get-FileHash -LiteralPath $DesignerArgs[1]).Hash
                    return $true
                }
                '/RestoreIB' {
                    if(-not $script:LifecycleGate6Snapshots.ContainsKey($DesignerArgs[1]) -or
                        (Get-FileHash -LiteralPath $DesignerArgs[1]).Hash -cne $script:LifecycleGate6Snapshots[$DesignerArgs[1]]){throw 'Fixture rollback DT is missing or changed'}
                    Assert-OneCDatabaseRestoreRequest -Duty $RestorationDuty -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind -DesignerArgs $DesignerArgs
                    # No real process was started. The fake native boundary
                    # records quiescence and the exact duty, as Invoke-Designer does.
                    Set-OneCDatabaseRestoreEvidence -Duty $RestorationDuty -NativeRecord ([pscustomobject]@{
                        id=('fixture-restore-'+[guid]::NewGuid().ToString('N'));quiescenceConfirmed=$true
                        purpose=('designer-restore-snapshot-'+$RestorationDuty.payload.id)
                    })
                    return $true
                }
                {$_ -in @('/CheckModules','/CheckCanApplyConfigurationExtensions','/CheckConfig')} {
                    if($_ -ceq '/CheckModules'){$script:LifecycleGate6LoadLog=[string]$script:LastLogPath}
                    $script:LastLogPath=Join-Path $script:LifecycleGate6OutRoot ('check-'+$script:LifecycleGate6NativeCalls.Count+'.log')
                    $diagnostic=if($script:LifecycleGate6CheckWarning -and $_ -ceq '/CheckModules'){'Предупреждение: метод не найден.'}else{'Ошибок: 0; предупреждений: 0'}
                    [IO.File]::WriteAllText($script:LastLogPath,$diagnostic,[Text.UTF8Encoding]::new($false))
                    $index=[Array]::IndexOf($DesignerArgs,'/DumpResult')
                    if($index -lt 0){throw 'Fixture check requires the original fresh DumpResult path'}
                    [IO.File]::WriteAllText($DesignerArgs[$index+1],'0',[Text.UTF8Encoding]::new($false))
                    return $true
                }
                '/UpdateDBCfg' {
                    if($null -eq $NativeEffectContract -or $NativeEffectContract.kind -cne 'update-db-cfg' -or
                        $null -eq $NativeEffectContract.gate6 -or $NativeEffectContract.gate6.sourceFingerprint -cne $NativeEffectContract.sourceFingerprint){throw 'Fixture apply lacks the real owner Gate6 contract'}
                    # Existing tests deliberately name their mock load/apply log
                    # C:\logs\full.log. Preserve that diagnostic assertion.
                    $script:LastLogPath=$script:LifecycleGate6LoadLog
                    return $true
                }
            }
            # Legacy counters below count editable load attempts. The complete
            # native sequence is returned and independently asserted by each It.
            return $false
        }

        function Initialize-LifecycleFullSourceFixture {
            param([string]$Root)

            function Invoke-LifecycleSourceFixtureGit {
                param([string[]]$Arguments)
                $capture = Invoke-ItlNativeProcessCapture -FilePath 'git' -WorkingDirectory $Root -Arguments (@('-C', $Root) + $Arguments)
                if ($capture.exitCode -ne 0) { throw "Lifecycle source fixture Git failed: $($capture.stderr)" }
            }
            Invoke-LifecycleSourceFixtureGit @('init', '--quiet')
            Invoke-LifecycleSourceFixtureGit @('config', 'user.name', 'fixture')
            Invoke-LifecycleSourceFixtureGit @('config', 'user.email', 'fixture@example.invalid')
            [IO.File]::WriteAllText((Join-Path $Root '.gitattributes'), "src/cf/** -text`r`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".agent-1c/`r`nlogs/`r`n", [Text.UTF8Encoding]::new($false))
            $sourceRoot = Join-Path $Root 'src/cf'
            $moduleRoot = Join-Path $sourceRoot 'CommonModules/Проверяемый/Ext'
            [IO.Directory]::CreateDirectory($moduleRoot) | Out-Null
            [IO.File]::WriteAllText((Join-Path $moduleRoot 'Module.bsl'), "Функция Значение() Экспорт`r`n    Возврат 1;`r`nКонецФункции`r`n", [Text.UTF8Encoding]::new($true))
            $cursorPath = Join-Path $sourceRoot 'ConfigDumpInfo.xml'
            if (-not (Test-Path -LiteralPath $cursorPath -PathType Leaf)) {
                [IO.File]::WriteAllText($cursorPath, '<ConfigDumpInfo/>', [Text.UTF8Encoding]::new($true))
            }
            Invoke-LifecycleSourceFixtureGit @('add', '--all')
            Invoke-LifecycleSourceFixtureGit @('commit', '--quiet', '-m', 'full load source')
            $source = Get-ConfigSourceFingerprint -ExportPath 'src/cf'
            $source.fingerprint | Should -Match '^v2\|git-tree-sha256\|[a-f0-9]{64}$'
            return $source
        }


        function New-ShortWorkflowProjectRoot {
            $parent = Join-Path ([Environment]::GetFolderPath("UserProfile")) "W"
            return (Join-Path $parent ("t" + [guid]::NewGuid().ToString("N").Substring(0, 6)))
        }

        function New-LifecycleMergeConflictFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-merge-resume-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "base"
            Set-Content -LiteralPath (Join-Path $tempRoot "unrelated.txt") -Encoding UTF8 -Value "base-unrelated"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Related.bsl") -Encoding UTF8 -Value "base-related"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "branch"
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch-only"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "master"
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master-only"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
            }
        }

        function New-LifecyclePostMergeCursorFixture {
            param(
                [string]$Subject = "chore: persist branch configuration synchronization cursor",
                [ValidateSet("cursor", "dependency-lock", "managed", "foreign")][string]$ChangedPath = "cursor",
                [ValidateSet("none", "extra", "merge")][string]$AdditionalHead = "none",
                [switch]$SkipCursor
            )

            $fixture = New-LifecycleMergeConflictFixture
            & git -C $fixture.root merge --no-ff --no-commit $fixture.targetCommit *> $null
            Set-Content -LiteralPath (Join-Path $fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
            Set-Content -LiteralPath (Join-Path $fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            & git -C $fixture.root add .
            & git -C $fixture.root commit --no-edit *> $null
            $mergeCommit = (& git -C $fixture.root rev-parse HEAD).Trim()

            $cursorCommit = $mergeCommit
            if (-not $SkipCursor) {
                if ($ChangedPath -eq "cursor") {
                    Set-Content -LiteralPath (Join-Path $fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "post-merge-cursor"
                } elseif ($ChangedPath -eq "dependency-lock") {
                    New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root ".agent-1c") | Out-Null
                    Set-Content -LiteralPath (Join-Path $fixture.root ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{}}'
                } elseif ($ChangedPath -eq "managed") {
                    New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root ".agents\skills\1c-workflow") | Out-Null
                    Set-Content -LiteralPath (Join-Path $fixture.root ".agents\skills\1c-workflow\helper.ps1") -Encoding UTF8 -Value 'managed cutover'
                } else {
                    Set-Content -LiteralPath (Join-Path $fixture.root "unrelated.txt") -Encoding UTF8 -Value "post-merge-foreign"
                }
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m $Subject *> $null
                $cursorCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            }

            if (-not $SkipCursor -and $AdditionalHead -eq "extra") {
                Set-Content -LiteralPath (Join-Path $fixture.root "branch.txt") -Encoding UTF8 -Value "extra"
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m "extra commit" *> $null
            } elseif (-not $SkipCursor -and $AdditionalHead -eq "merge") {
                & git -C $fixture.root checkout --quiet -b cursor-side
                Set-Content -LiteralPath (Join-Path $fixture.root "side.txt") -Encoding UTF8 -Value "side"
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m "side" *> $null
                & git -C $fixture.root checkout --quiet itldev/test
                & git -C $fixture.root merge --no-ff cursor-side -m "extra merge" *> $null
            }

            return [pscustomobject]@{
                root = $fixture.root
                branchCommit = $fixture.branchCommit
                targetCommit = $fixture.targetCommit
                mergeCommit = $mergeCommit
                cursorCommit = $cursorCommit
                head = (& git -C $fixture.root rev-parse HEAD).Trim()
            }
        }

        function New-LifecycleMergeSourceIntegrityFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl source Целостность " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $validatorRoot | Out-Null
            $configurationPath = Join-Path $configRoot "Configuration.xml"
            $baseConfiguration = @"
<Configuration>
  <ChildObjects>
    <Constant>Alpha</Constant>
    <Constant>Omega</Constant>
    <Catalog>Products</Catalog>
    <Document>Order</Document>
    <Report>Sales</Report>
    <CommonForm>Main</CommonForm>
  </ChildObjects>
</Configuration>
"@
            [System.IO.File]::WriteAllText($configurationPath, $baseConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            $branchConfiguration = $baseConfiguration.Replace("    <CommonForm>Main</CommonForm>", "    <Constant>Shared</Constant>`r`n    <CommonForm>Main</CommonForm>")
            [System.IO.File]::WriteAllText($configurationPath, $branchConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            $masterConfiguration = $baseConfiguration.Replace("    <Constant>Omega</Constant>", "    <Constant>Shared</Constant>`r`n    <Constant>Omega</Constant>")
            [System.IO.File]::WriteAllText($configurationPath, $masterConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $validatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            $validator = @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
$source = [System.IO.File]::ReadAllText((Join-Path $ConfigPath "Configuration.xml"), [System.Text.Encoding]::UTF8)
$count = [regex]::Matches($source, "<Constant>Shared</Constant>").Count
$message = if ($count -gt 1) { "[ERROR] 5. Duplicate: Constant.Shared" } else { "=== Validation OK ===" }
[System.IO.File]::WriteAllText($OutFile, $message, [System.Text.UTF8Encoding]::new($true))
if ($count -gt 1) { exit 1 }
exit 0
'@
            [System.IO.File]::WriteAllText($validatorPath, $validator, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                configurationPath = $configurationPath
                validatorPath = $validatorPath
            }
        }

        function New-LifecycleMergeBslDuplicateFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl BSL Дубликат " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $moduleRoot = Join-Path $configRoot "CommonModules\ОбщийМодуль\Ext"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $moduleRoot, $validatorRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $configRoot "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $modulePath = Join-Path $moduleRoot "Module.bsl"
            $baseModule = @"
Процедура Начало()
КонецПроцедуры

Процедура Середина()
КонецПроцедуры

Процедура Конец()
КонецПроцедуры
"@
            [System.IO.File]::WriteAllText($modulePath, $baseModule, [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            $method = "Процедура ОбщийМетод()`r`nКонецПроцедуры`r`n`r`n"
            & git -C $tempRoot checkout --quiet -b itldev/test
            [System.IO.File]::WriteAllText($modulePath, $baseModule.Replace("Процедура Середина()", $method + "Процедура Середина()"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch method" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            [System.IO.File]::WriteAllText($modulePath, $baseModule.Replace("Процедура Конец()", $method + "Процедура Конец()"), [System.Text.UTF8Encoding]::new($false))
            $targetOnlyFormRoot = Join-Path $configRoot "CommonForms\ТолькоMaster\Ext"
            New-Item -ItemType Directory -Force -Path $targetOnlyFormRoot | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $targetOnlyFormRoot "Form.xml"), "<Form />", [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master method" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $validatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            [System.IO.File]::WriteAllText($validatorPath, @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
[System.IO.File]::WriteAllText($OutFile, "=== Validation OK ===", [System.Text.UTF8Encoding]::new($true))
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                modulePath = $modulePath
                moduleRepoPath = "src/cf/CommonModules/ОбщийМодуль/Ext/Module.bsl"
                validatorPath = $validatorPath
            }
        }

        function New-LifecycleTemplateIntegrityFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl Макет с пробелом " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $reportRoot = Join-Path $configRoot "Reports\ОтчетСКД"
            $templateRoot = Join-Path $reportRoot "Templates\ОсновнаяСхемаКомпоновкиДанных"
            New-Item -ItemType Directory -Force -Path (Join-Path $templateRoot "Ext"), (Join-Path $configRoot "Catalogs") | Out-Null
            $configurationPath = Join-Path $configRoot "Configuration.xml"
            $ownerPath = Join-Path $configRoot "Reports\ОтчетСКД.xml"
            $descriptorPath = Join-Path $reportRoot "Templates\ОсновнаяСхемаКомпоновкиДанных.xml"
            $payloadPath = Join-Path $templateRoot "Ext\Template.xml"
            $unrelatedPath = Join-Path $configRoot "Catalogs\Неизмененный.xml"
            [IO.File]::WriteAllText($configurationPath, '<MetaDataObject><Configuration uuid="10ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($ownerPath, @'
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">
  <Report uuid="20ffa7c3-3d5d-4edd-9ebe-1acc0592d242">
    <Properties>
      <Name>ОтчетСКД</Name>
      <MainDataCompositionSchema>Report.ОтчетСКД.Template.ОсновнаяСхемаКомпоновкиДанных</MainDataCompositionSchema>
    </Properties>
    <ChildObjects><Template>ОсновнаяСхемаКомпоновкиДанных</Template></ChildObjects>
  </Report>
</MetaDataObject>
'@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($descriptorPath, @'
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">
  <Template uuid="30ffa7c3-3d5d-4edd-9ebe-1acc0592d242">
    <Properties>
      <Name>ОсновнаяСхемаКомпоновкиДанных</Name>
      <TemplateType>DataCompositionSchema</TemplateType>
    </Properties>
  </Template>
</MetaDataObject>
'@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($payloadPath, '<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema" />', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($unrelatedPath, '<MetaDataObject><Catalog uuid="40ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base template aggregate" *> $null

            return [pscustomobject]@{
                root = $tempRoot
                ownerPath = $ownerPath
                ownerRepoPath = "src/cf/Reports/ОтчетСКД.xml"
                descriptorPath = $descriptorPath
                descriptorRepoPath = "src/cf/Reports/ОтчетСКД/Templates/ОсновнаяСхемаКомпоновкиДанных.xml"
                payloadPath = $payloadPath
                payloadRepoPath = "src/cf/Reports/ОтчетСКД/Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml"
                unrelatedPath = $unrelatedPath
            }
        }

        function New-LifecycleMergeFormIntegrityFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl Форма с пробелом " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $formRoot = Join-Path $configRoot "CommonForms\ОбщаяФорма\Ext"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $formRoot, $validatorRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $configRoot "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $formPath = Join-Path $formRoot "Form.xml"
            $baseForm = @"
<Form>
  <Items>
    <Item name="One" />
    <Item name="Two" />
    <Item name="Three" />
    <Item name="Four" />
    <Item name="Five" />
    <Item name="Six" />
    <Item name="Seven" />
    <Item name="Eight" />
    <Item name="Nine" />
    <Item name="Ten" />
  </Items>
</Form>
"@
            [System.IO.File]::WriteAllText($formPath, $baseForm, [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            $sharedItem = '    <Item name="Shared" />'
            & git -C $tempRoot checkout --quiet -b itldev/test
            [System.IO.File]::WriteAllText($formPath, $baseForm.Replace('    <Item name="Two" />', "$sharedItem`r`n    <Item name=""Two"" />"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch form move" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            [System.IO.File]::WriteAllText($formPath, $baseForm.Replace('    <Item name="Nine" />', "$sharedItem`r`n    <Item name=""Nine"" />"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master form move" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $configurationValidatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            [System.IO.File]::WriteAllText($configurationValidatorPath, @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
[System.IO.File]::WriteAllText($OutFile, "=== Validation OK ===", [System.Text.UTF8Encoding]::new($true))
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            $formValidatorPath = Join-Path $validatorRoot "form-validate.ps1"
            [System.IO.File]::WriteAllText($formValidatorPath, @'
param([string]$FormPath, [int]$MaxErrors)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$source = [System.IO.File]::ReadAllText($FormPath, [System.Text.Encoding]::UTF8)
$count = [regex]::Matches($source, '<Item name="Shared"').Count
if ($count -gt 1) {
    Write-Output "[ERROR] Duplicate form item Shared"
    exit 1
}
Write-Output "=== Validation OK ==="
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                formPath = $formPath
                formRepoPath = "src/cf/CommonForms/ОбщаяФорма/Ext/Form.xml"
                configurationValidatorPath = $configurationValidatorPath
                formValidatorPath = $formValidatorPath
            }
        }

        function New-LifecycleResetFormIntegrityFixture {
            param([switch]$InvalidCommandIds)
            $fixture = New-LifecycleMergeFormIntegrityFixture
            & git -C $fixture.root checkout --quiet master
            $source = [IO.File]::ReadAllText($fixture.formPath, [Text.Encoding]::UTF8)
            $source = $source.Replace('</Form>', '<Commands><Command name="УстановитьУровеньЗаглушка"><Action /></Command><Command name="Пустышка" /></Commands></Form>')
            if ($InvalidCommandIds) { $source = $source.Replace('<Command name=', '<Command id="1" name=') }
            [IO.File]::WriteAllText($fixture.formPath, $source, [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- $fixture.formRepoPath
            & git -C $fixture.root commit -m "master placeholder commands" *> $null
            $fixture.targetCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root checkout --quiet itldev/test
            # Mirror the pinned validator contract: unassigned actions are advisory,
            # while duplicate command IDs remain genuine structural errors.
            [IO.File]::WriteAllText($fixture.formValidatorPath, @'
param([string]$FormPath, [int]$MaxErrors)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[xml]$form = [IO.File]::ReadAllText($FormPath, [Text.Encoding]::UTF8)
$ids = @{}
$errors = 0
foreach ($command in $form.SelectNodes('/Form/Commands/Command')) {
    $id = $command.GetAttribute('id')
    if ($id) {
        if ($ids.ContainsKey($id)) { Write-Output "[ERROR] Duplicate command id=$id"; $errors++ }
        $ids[$id] = $true
    }
    $action = $command.SelectSingleNode('Action')
    if ($null -eq $action -or -not $action.InnerText.Trim()) {
        Write-Output "[WARN] COMMAND_ACTION_UNASSIGNED: Command '$($command.GetAttribute('name'))': missing or empty Action. Advisory only; do not create dummy handlers."
    }
}
if ($errors -gt 0) { exit 1 }
exit 0
'@, [Text.UTF8Encoding]::new($true))
            return $fixture
        }

        function Copy-AutoUpdateToolFixture {
            param([string]$TargetRoot)
            $target = Join-Path $TargetRoot ".agents\skills\1c-workflow\tools\auto-update"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\auto-update") -Destination $target -Recurse

            $fakePlatform = Join-Path $TargetRoot "source-base\test-platform\1cv8.exe"
            $fakeThinPlatform = Join-Path $TargetRoot "source-base\test-platform\1cv8c.exe"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakePlatform) | Out-Null
            $writeProof = @'
$paramsPath = $env:ITL_PROOF_PARAMS
if (-not $paramsPath -or -not (Test-Path -LiteralPath $paramsPath -PathType Leaf)) { exit 0 }
try {
    $request = Get-Content -LiteralPath $paramsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($request.runId -and $request.outputPath) {
        @{ schemaVersion = 1; runId = $request.runId; status = 'passed'; updateResult = 'Успешно'; errorMessage = ''; errorDetails = '' } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $request.outputPath -Encoding UTF8
    }
} catch { exit 1 }
'@
            $encodedProof = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($writeProof))
            $fixtureTypeName = 'NativeAutoUpdateFixture' + [guid]::NewGuid().ToString('N')
            $fakeScript = @"
using System;
using System.Diagnostics;
using System.IO;
public static class $fixtureTypeName {
    public static int Main(string[] args) {
        foreach (string arg in args) {
            if (!arg.StartsWith("/C", StringComparison.OrdinalIgnoreCase)) { continue; }
            var start = new ProcessStartInfo();
            start.FileName = Path.Combine(Environment.GetEnvironmentVariable("SystemRoot"), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            start.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedProof";
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.EnvironmentVariables["ITL_PROOF_PARAMS"] = arg.Substring(2);
            using (var proof = Process.Start(start)) {
                proof.WaitForExit();
                return proof.ExitCode;
            }
        }
        return 0;
    }
}
"@
            Add-Type -TypeDefinition $fakeScript -OutputAssembly $fakePlatform -OutputType ConsoleApplication -ErrorAction Stop
            Copy-Item -LiteralPath $fakePlatform -Destination $fakeThinPlatform
            return $fakePlatform
        }

        function New-ItlOnDemandMcpInstallFixture {
            param([string]$TargetRoot)

            $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = $lock.dependencies.itlOndemandMcp
            $installRoot = Join-Path $TargetRoot "ondemand"
            $assetPath = Join-Path (Join-Path (Join-Path $installRoot ([string]$entry.version)) ([string]$entry.sha256)) ([string]$entry.assetName)
            $oldGoProxy = $env:GOPROXY
            $oldGoSumDb = $env:GOSUMDB
            $oldGoToolchain = $env:GOTOOLCHAIN
            try {
                $env:GOPROXY = "off"
                $env:GOSUMDB = "off"
                $env:GOTOOLCHAIN = "local"
                $build = @(& (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -OutputPath $assetPath -SkipTests)
            } finally {
                $env:GOPROXY = $oldGoProxy
                $env:GOSUMDB = $oldGoSumDb
                $env:GOTOOLCHAIN = $oldGoToolchain
            }
            if ($build.Count -ne 1 -or [string]$build[0].sha256 -cne [string]$entry.sha256) {
                throw "ITL_ONDEMAND_TEST_FIXTURE_HASH_MISMATCH expected='$($entry.sha256)' actual='$($build[0].sha256)'"
            }
            return $installRoot
        }
