Describe "Controlled Vanessa Automation patched artifact <revision>" -ForEach @(@{ revision = 'itl-r8' }, @{ revision = 'itl-r9' }, @{ revision = 'itl-r10' }, @{ revision = 'itl-r11' }, @{ revision = 'itl-r12' }, @{ revision = 'itl-r13' }) {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-$revision"
        $manifestPath = Join-Path $assetRoot "manifest.json"
        $patchPath = Join-Path $assetRoot "file-operations.patch"
        $licensePath = Join-Path $assetRoot "LICENSE.upstream"
        $buildScriptPath = Join-Path $repoRoot "scripts\build-vanessa-automation-patched.ps1"
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
        $buildScriptText = Get-Content -LiteralPath $buildScriptPath -Raw -Encoding UTF8
    }

    It "pins the exact upstream source, minimal patch, revision, and toolchain" {
        $manifest.upstream.repository | Should -Be "https://github.com/Pr-Mex/vanessa-automation.git"
        $manifest.upstream.ref | Should -Be "refs/tags/1.2.043.28"
        $manifest.upstream.commit | Should -Be "f3a01778a14d29b38204685deea0131274d438ff"
        $manifest.upstream.sourceArchive.sha256 | Should -Be "3581a8d6bb675426b6555fd0b0f2e612c7c9ea0b704123129256a89f1f8f2f81"
        $manifest.compatibilityVersion | Should -Be "1.2.043.28"
        $manifest.downstreamRevision | Should -Be $revision
        $manifest.build.platform.version | Should -Be "8.3.27.2130"
        $manifest.build.oneScript.version | Should -Be "1.9.4.16"
        $manifest.build.oneScript.packages.v8runner | Should -Be "1.8.2"
        $manifest.build.oneScript.packages.logos | Should -Be "1.4.0"

        $patchSha = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $patchSha | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount $(if ($revision -in @('itl-r11', 'itl-r12', 'itl-r13')) { 4 } else { 2 })
        $manifest.patch.expectedChangedPaths[0] | Should -Be "VanessaAutomation/Forms/MCPVA/Ext/Form/Module.bsl"
        $managedFormPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("VmFuZXNzYUF1dG9tYXRpb24vRm9ybXMv0KPQv9GA0LDQstC70Y/QtdC80LDRj9Ck0L7RgNC80LAvRXh0L0Zvcm0vTW9kdWxlLmJzbA=="))
        $manifest.patch.expectedChangedPaths[1] | Should -Be $managedFormPath
        @($manifest.patch.upstreamBackports) | Should -HaveCount 2
        @($manifest.patch.retainedDownstreamFixes) | Should -HaveCount $(if ($revision -eq 'itl-r13') { 10 } elseif ($revision -eq 'itl-r12') { 9 } elseif ($revision -eq 'itl-r11') { 7 } elseif ($revision -eq 'itl-r10') { 6 } elseif ($revision -eq 'itl-r9') { 5 } else { 4 })
        if ($revision -in @('itl-r11', 'itl-r12', 'itl-r13')) {
            $manifest.pairedExtension.required | Should -BeTrue
            $manifest.pairedExtension.protocol | Should -Be 'itl-file-code-v1'
            $manifest.pairedExtension.fileName | Should -Be "VAExtension.1.29-$revision.cfe"
            $manifest.patch.expectedChangedPaths[2] | Should -Match '^features/Libraries/VAExtension/VAExtension/Forms/'
            $manifest.patch.expectedChangedPaths[3] | Should -Be 'lib/VAExtension/Ext/ManagedApplicationModule.bsl'
        }
        @($manifest.patch.removedDownstreamWorkarounds) | Should -HaveCount 2
    }

    It "retains the two verified metadata backports" {
        $patchText | Should -Match '(?m)^-.*"search_string".*"number".*$'
        $patchText | Should -Match '(?m)^\+.*"search_string".*"string".*$'
        $patchText | Should -Match '(?m)^-.*get_window_screenshot_os\.$'
        $patchText | Should -Match '(?m)^\+.*get_window_list_os\.$'
        $manifest.patch.upstreamBackports[0].commit | Should -Be "b02d884e2636cc4ba6d351861368df14e4bf293b"
        $manifest.patch.upstreamBackports[1].commit | Should -Be "91b1d07584ef2df5858e44c98ff33638bef7b6cf"
    }

    It "retains run_scenario callback continuity and facade TestClient ownership" {
        $callParameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL0JLRi9C30L7QstCwTUNQKTs="))
        $returnStatement = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JLQvtC30LLRgNCw0YI7"))
        $mcpActiveGuard = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lgg0JfQvdCw0YfQtdC90LjQtdCX0LDQv9C+0LvQvdC10L3QvijQmNC00LXQvdGC0LjRhNC40LrQsNGC0L7RgNCX0LDQtNCw0YfQuE1DUCgpKSDQotC+0LPQtNCw"))
        $returnFalse = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JLQvtC30LLRgNCw0YIg0JvQvtC20Yw7"))
        $patchText | Should -Match ("(?s)MCPOpenFeatureFile.*?" + [regex]::Escape($callParameters) + ".*?\+\s*" + [regex]::Escape($returnStatement))
        $patchText | Should -Match 'TestClient.*MCP.*facade'
        $patchText | Should -Match ("(?s)" + [regex]::Escape($mcpActiveGuard) + ".*?\+\s*" + [regex]::Escape($returnFalse))
    }

    It "completes cold reloadAndRun without replacing callback context or weakening hot reload" {
        $localLoadedFlag = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KTQuNGH0LDQl9Cw0LPRgNGD0LbQtdC90LDQrdGC0LjQvNCS0YvQt9C+0LLQvtC8"))
        $continuation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/RgNC+0LTQvtC70LbQuNGC0YzQktGL0L/QvtC70L3QuNGC0YzQodGG0LXQvdCw0YDQuNC5Mg=="))
        $callParameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL0JLRi9C30L7QstCwTUNQKTs="))
        $reloadCallback = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JfQsNCz0YDRg9C30LjRgtGM0KTQuNGH0LDQpNCw0LnQu9CY0JLRi9C/0L7Qu9C90LjRgtGM0KHRhtC10L3QsNGA0LjQuA=="))
        $syntaxCheck = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/QvtC70YPRh9C40YLRjNCf0YDQvtCx0LvQtdC80YvQn9C+0KLQtdC60YPRidC10LnQpNC40YfQtQ=="))
        $runAll = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JrQvtC80LDQvdC00LDQktGL0L/QvtC70L3QuNGC0YzQodGG0LXQvdCw0YDQuNC4"))
        $deferredRunner = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("TUNQ0JLRi9C/0L7Qu9C90LjRgtGM0KHRhtC10L3QsNGA0LjQuNCf0L7RgdC70LXQl9Cw0LPRgNGD0LfQutC4"))
        $attachWaitHandler = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/QvtC00LrQu9GO0YfQuNGC0YzQntCx0YDQsNCx0L7RgtGH0LjQutCe0LbQuNC00LDQvdC40Y8="))
        $scenarioWaitFlag = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("TUNQ0J7QttC40LTQsNC90LjQtdCS0YvQv9C+0LvQvdC10L3QuNGP0KHRhtC10L3QsNGA0LjRjw=="))
        $falseValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JvQvtC20Yw="))
        $trueValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JjRgdGC0LjQvdCw"))
        $ifKeyword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lg="))
        $elseKeyword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JjQvdCw0YfQtQ=="))
        $newStructure = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3QvtCy0YvQuSDQodGC0YDRg9C60YLRg9GA0LA="))
        $globalFlag = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3Rg9C20L3QvtCe0L/QvtCy0LXRgdGC0LjRgtGMTUNQ0KHQtdGA0LLQtdGA0J/QvtGB0LvQtdCX0LDQs9GA0YPQt9C60LjQpNC40YfQuA=="))
        $undefinedValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3QtdC+0L/RgNC10LTQtdC70LXQvdC+"))

        $patchText | Should -Match ("(?m)^\+.*" + [regex]::Escape($continuation) + ".*" + [regex]::Escape($localLoadedFlag) + " = " + [regex]::Escape($falseValue) + ".*$")
        $patchText | Should -Match ("(?m)^\+.*" + [regex]::Escape($continuation) + ".*" + [regex]::Escape($trueValue) + ".*$")
        $patchText | Should -Match ("(?s)\+\s*" + [regex]::Escape($ifKeyword + " " + $localLoadedFlag) + ".*?" + [regex]::Escape($attachWaitHandler) + ".*?" + [regex]::Escape($deferredRunner) + ".*?\+\s*" + [regex]::Escape($elseKeyword) + ".*?" + [regex]::Escape($reloadCallback))
        $patchText | Should -Match ("(?s)\+.*?" + [regex]::Escape($deferredRunner) + ".*?" + [regex]::Escape($syntaxCheck) + ".*?" + [regex]::Escape($scenarioWaitFlag) + "\s*=\s*" + [regex]::Escape($falseValue) + ".*?" + [regex]::Escape($runAll))
        $patchText | Should -Not -Match ("(?m)^\+\s*" + [regex]::Escape($callParameters.TrimEnd(';')) + "\s*=\s*" + [regex]::Escape($newStructure))
        $patchText | Should -Not -Match ("(?m)^[+-].*" + [regex]::Escape($globalFlag) + "\s*=\s*" + [regex]::Escape($undefinedValue))
    }

    It "keeps safe-mode substitutions removed and routes cold reloadAndRunFromLine through the first load callback" {
        foreach ($removedMarker in @(
            "PATH_INVALID",
            "PATH_NOT_FOUND",
            "PATH_ACCESS_DENIED",
            "getContent()",
            "VanessaTabs.current.filename"
        )) {
            $patchText | Should -Not -Match ([regex]::Escape($removedMarker))
        }
        $callParameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL0JLRi9C30L7QstCwTUNQ'))
        $modeName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0KDQtdC20LjQvA=='))
        $postLoadMode = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0KDQtdC20LjQvNCf0L7RgdC70LXQl9Cw0LPRgNGD0LfQutC4'))
        $openFeature = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('TUNQT3BlbkZlYXR1cmVGaWxl0JLQoNC10LTQsNC60YLQvtGA0LU='))
        $completionCallback = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0KPRgdGC0LDQvdC+0LLQuNGC0YzQpNC70LDQs9Ce0L/QvtCy0LXRgdGC0LjRgtGMTUNQ0KHQtdGA0LLQtdGA0J/QvtGB0LvQtdCS0YvQv9C+0LvQvdC10L3QuNGP0KHRhtC10L3QsNGA0LjQtdCy'))
        $patchText | Should -Match ([regex]::Escape($callParameters) + '\.' + [regex]::Escape($modeName) + ' = "reloadAndRunFromLine"')
        $patchText | Should -Match ([regex]::Escape($postLoadMode) + '.*reloadAndRunFromLine')
        $patchText | Should -Match ('(?s)' + [regex]::Escape($postLoadMode) + '.*reloadAndRunFromLine.*' + [regex]::Escape($completionCallback) + '.*' + [regex]::Escape($openFeature))
        $patchText | Should -Not -Match 'step_definitions'
    }

    It "builds fail closed through the official upstream flow" {
        $buildScriptText | Should -Match ([regex]::Escape('"apply", "--check", "--whitespace=error-all"'))
        $buildScriptText | Should -Match ([regex]::Escape('"archive", "--format=tar"'))
        $runtimeText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/run-vanessa-build-runtime.ps1') -Raw -Encoding UTF8
        $runtimeText | Should -Match ([regex]::Escape("'tools/onescript/Compile.os'"))
        $runtimeText | Should -Match ([regex]::Escape("'tools/onescript/MakeVASingle.os'"))
        $buildScriptText | Should -Match 'ValidateSet\("itl-r1", "itl-r2", "itl-r3", "itl-r4"'
        $buildScriptText | Should -Match ([regex]::Escape('$DownstreamRevision = "itl-r8"'))
        $buildScriptText | Should -Match 'run-vanessa-build-runtime.ps1'
        $runtimeText | Should -Match 'Get-VanessaServiceInfoBaseTemplate'
        $runtimeText | Should -Match '/RestoreIB'
        ($buildScriptText + $runtimeText) | Should -Not -Match 'conf\.cfg|ScopedUnsafeActionProtectionBypass|DisableUnsafeActionProtection'
        $buildScriptText | Should -Match ([regex]::Escape("New-DeterministicZip"))
        $manifest.artifact.fileName | Should -Be "vanessa-automation-single.1.2.043.28-$revision.zip"
    }

    It "retains the complete BSD 3-Clause binary redistribution notice" {
        $licenseText = Get-Content -LiteralPath $licensePath -Raw -Encoding UTF8
        $licenseText | Should -Match "Copyright \(c\) 2018, Pautov Leonid"
        $licenseText | Should -Match "Redistributions in binary form must reproduce"
        $licenseText | Should -Match "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS"
        $manifest.license.spdx | Should -Be "BSD-3-Clause"
        $manifest.license.artifactNoticePath | Should -Be "ITL-NOTICE.txt"
    }
}

Describe "Controlled Vanessa Automation patched artifact 1.2.043.42-itl-r1" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\.." )).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.42-itl-r1"
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchPath = Join-Path $assetRoot 'file-operations.patch'
        $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
    }

    It "pins the new tag, source archive, downstream patch, and paired extension" {
        $manifest.upstream.ref | Should -Be 'refs/tags/1.2.043.42'
        $manifest.upstream.commit | Should -Be 'a0ce2ee9803dd69be52f682e5cf49e0938fd33f1'
        $manifest.upstream.sourceArchive.sha256 | Should -Be 'dbd601ab7b9868103541a4bc4216009e209a9b378127efdbc5b2bdd604681d0c'
        (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount 10
        $manifest.pairedExtension.required | Should -BeTrue
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r1.cfe'
    }

    It "replaces every ping wait fallback with local sleep and checks MCP progress tokens" {
        $patchText | Should -Match 'Start-Sleep -Milliseconds'
        $patchText | Should -Match '/bin/sleep '
        $patchText | Should -Match 'ПрогрессТокенИзЗапроса'
        $patchText | Should -Match 'УсловиеИначе'
        $patchText | Should -Not -Match '(?m)^\+.*ping 127\.0\.0\.1'
    }

    It "resumes only after native release and exact source verification" {
        $buildText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/build-vanessa-automation-patched.ps1') -Raw -Encoding UTF8
        $buildText | Should -Match 'ResumeWorkDirectory'
        $buildText | Should -Match 'VANESSA_BUILD_RESUME_NATIVE_OWNERSHIP_UNCONFIRMED'
        $buildText | Should -Match 'Resumed downstream patch'
        $buildText | Should -Match 'Resumed upstream source archive SHA-256'
    }
}

Describe "VAExtension HTML forms without orphan handlers" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $repoRoot 'scripts/git-path-list.ps1')
        $assetRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r2'
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $fixtureRoot = Join-Path $repoRoot 'tests/fixtures/vanessa-html-forms'
        $provenance = Get-Content -LiteralPath (Join-Path $fixtureRoot 'provenance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'retains the existing fixes under a new immutable paired component revision' {
        $previous = Get-Content -LiteralPath (Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r1/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.upstream.commit | Should -Be $previous.upstream.commit
        $manifest.upstream.sourceArchive.sha256 | Should -Be $previous.upstream.sourceArchive.sha256
        $manifest.downstreamRevision | Should -Be 'itl-r2'
        $manifest.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r2.zip'
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r2.cfe'
        $manifest.pairedExtension.protocol | Should -Be $previous.pairedExtension.protocol
        (Get-FileHash -LiteralPath (Join-Path $assetRoot 'file-operations.patch') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount 12
        foreach ($path in $previous.patch.expectedChangedPaths) { $manifest.patch.expectedChangedPaths | Should -Contain $path }
        foreach ($fix in $previous.patch.retainedDownstreamFixes) { $manifest.patch.retainedDownstreamFixes | Should -Contain $fix }
        $provenance.upstreamCommit | Should -Be $manifest.upstream.commit
        foreach ($input in $provenance.inputs) {
            (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $input.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $input.sha256
        }
    }

    It 'repairs the actual upstream missing handler while retaining every working control and module: <form>' -TestCases @(
        @{ form = 'VAExtension_НажатьГиперссылкуHTMLДокумента' },
        @{ form = 'VAExtension_НажатьКнопкуHTMLДокумента' }
    ) {
        param($form)
        $root = Join-Path $TestDrive ('Формы с пробелом '+$form)
        [void][IO.Directory]::CreateDirectory($root)
        $relative = 'lib/VAExtension/DataProcessors/'+$form+'/Forms/Форма/Ext/Form.xml'
        $moduleRelative = 'lib/VAExtension/DataProcessors/'+$form+'/Forms/Форма/Ext/Form/Module.bsl'
        foreach ($path in @($relative,$moduleRelative)) {
            $destination = Join-Path $root $path
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $fixtureRoot $path) -Destination $destination
        }
        $formPath = Join-Path $root $relative
        $modulePath = Join-Path $root $moduleRelative
        $moduleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
        $module = [IO.File]::ReadAllText($modulePath,[Text.Encoding]::UTF8)
        [xml]$before = [IO.File]::ReadAllText($formPath,[Text.Encoding]::UTF8)
        $orphanButton = $before.SelectSingleNode('//*[local-name()="Button" and @name="ФормаВыполнитьКодСервер"]')
        $orphanCommand = $before.SelectSingleNode('//*[local-name()="Command" and @name="ВыполнитьКодСервер"]')
        $orphanButton | Should -Not -BeNullOrEmpty
        $orphanCommand | Should -Not -BeNullOrEmpty
        $module | Should -Not -Match '(?im)^\s*(Процедура|Функция)\s+ВыполнитьКодСервер\s*\('
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('init','--quiet'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--check','--whitespace=error-all',('--include='+$relative),(Join-Path $assetRoot 'file-operations.patch')))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--whitespace=error-all',('--include='+$relative),(Join-Path $assetRoot 'file-operations.patch')))
        [xml]$after = [IO.File]::ReadAllText($formPath,[Text.Encoding]::UTF8)
        $after.SelectSingleNode('//*[local-name()="Button" and @name="ФормаВыполнитьКодСервер"]') | Should -BeNullOrEmpty
        $after.SelectSingleNode('//*[local-name()="Command" and @name="ВыполнитьКодСервер"]') | Should -BeNullOrEmpty
        [void]$orphanButton.ParentNode.RemoveChild($orphanButton)
        [void]$orphanCommand.ParentNode.RemoveChild($orphanCommand)
        $after.OuterXml | Should -BeExactly $before.OuterXml
        $after.SelectSingleNode('//*[local-name()="Button" and @name="ФормаВыполнитьКод"]/*[local-name()="DefaultButton"]').InnerText | Should -Be 'true'
        foreach ($action in $after.SelectNodes('//*[local-name()="Commands"]/*[local-name()="Command"]/*[local-name()="Action"]')) {
            $module | Should -Match ('(?im)^\s*(Процедура|Функция)\s+'+[regex]::Escape($action.InnerText)+'\s*\(')
        }
        (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash | Should -BeExactly $moduleHash
    }
}

Describe "Controlled Vanessa Automation patched artifact itl-r14" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-itl-r14"
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchPath = Join-Path $assetRoot "file-operations.patch"
        $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
        $buildScriptText = Get-Content -LiteralPath (Join-Path $repoRoot "scripts\build-vanessa-automation-patched.ps1") -Raw -Encoding UTF8
    }

    It "pins the exact source and the five-file r14 patch" {
        $manifest.upstream.repository | Should -Be "https://github.com/Pr-Mex/vanessa-automation.git"
        $manifest.upstream.ref | Should -Be "refs/tags/1.2.043.28"
        $manifest.upstream.commit | Should -Be "f3a01778a14d29b38204685deea0131274d438ff"
        $manifest.upstream.sourceArchive.sha256 | Should -Be "3581a8d6bb675426b6555fd0b0f2e612c7c9ea0b704123129256a89f1f8f2f81"
        $manifest.downstreamRevision | Should -Be "itl-r14"
        (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256

        $parserPath = "VanessaAutomation/Forms/ПарсерGherkin/Ext/Form/Module.bsl"
        $managedFormPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("VmFuZXNzYUF1dG9tYXRpb24vRm9ybXMv0KPQv9GA0LDQstC70Y/QtdC80LDRj9Ck0L7RgNC80LAvRXh0L0Zvcm0vTW9kdWxlLmJzbA=="))
        @($manifest.patch.expectedChangedPaths) | Should -Be @(
            "VanessaAutomation/Forms/MCPVA/Ext/Form/Module.bsl",
            $parserPath,
            $managedFormPath,
            "features/Libraries/VAExtension/VAExtension/Forms/Форма/Ext/Form/Module.bsl",
            "lib/VAExtension/Ext/ManagedApplicationModule.bsl"
        )
        @($manifest.patch.upstreamBackports) | Should -HaveCount 2
        @($manifest.patch.retainedDownstreamFixes) | Should -HaveCount 11
        @($manifest.patch.removedDownstreamWorkarounds) | Should -HaveCount 2
    }

    It "accepts only the legitimate omitted-empty-lines multiline shape" {
        $patchText | Should -Match ([regex]::Escape('ПараметрJson.Свойство("lines", СтрокиМногострочногоПараметра)'))
        $patchText | Should -Match ([regex]::Escape('ПараметрJson.Свойство("header") И ПараметрJson.Свойство("footer")'))
        $patchText | Should -Match ([regex]::Escape('ТипЗнч(СтрокиМногострочногоПараметра) <> Тип("Массив")'))
        ([regex]::Matches($patchText, 'ITL_VANESSA_GHERKIN_MULTILINE_INVALID')).Count | Should -Be 2
        $patchText | Should -Match 'VanessaExt.*lines'
    }

    It "keeps the paired extension and deterministic artifact contract" {
        $manifest.pairedExtension.required | Should -BeTrue
        $manifest.pairedExtension.protocol | Should -Be "itl-file-code-v1"
        $manifest.pairedExtension.fileName | Should -Be "VAExtension.1.29-itl-r14.cfe"
        $manifest.artifact.fileName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r14.zip"
        $manifest.artifact.downstreamRevision | Should -Be "itl-r14"
        $buildScriptText | Should -Match ([regex]::Escape('"itl-r13", "itl-r14"'))

        $noticeText = Get-Content -LiteralPath (Join-Path $assetRoot "ITL-NOTICE.txt") -Raw -Encoding UTF8
        $licenseText = Get-Content -LiteralPath (Join-Path $assetRoot "LICENSE.upstream") -Raw -Encoding UTF8
        $noticeText | Should -Match "itl-r14"
        $licenseText | Should -Match "BSD 3-Clause"
    }
}

Describe 'VAExtension configuration-independent report and system forms' {
    BeforeAll {
        $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $repoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        $assetRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r3'
        $fixtureRoot = Join-Path $repoRoot 'tests/fixtures/vanessa-extension-portability'
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $provenance = Get-Content -LiteralPath (Join-Path $fixtureRoot 'provenance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $originals = @{}; $patched = @{}
        $root = Join-Path $TestDrive 'Расширение с пробелом'
        [void][IO.Directory]::CreateDirectory($root)
        foreach ($input in $provenance.inputs) {
            $source = Join-Path $fixtureRoot $input.path
            $target = Join-Path $root $input.path
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy($source,$target)
            $originals[$input.path] = [IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)
        }
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('init','--quiet'))
        # This fixture models the canonical upstream blobs; do not inherit the
        # machine's autocrlf conversion while checking untouched source bytes.
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('config','core.autocrlf','false'))
        $includes = @($provenance.inputs | ForEach-Object { '--include='+$_.path })
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('apply','--check','--whitespace=error-all')+$includes+@((Join-Path $assetRoot 'file-operations.patch'))))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('apply','--whitespace=error-all')+$includes+@((Join-Path $assetRoot 'file-operations.patch'))))
        foreach ($input in $provenance.inputs) { $patched[$input.path] = [IO.File]::ReadAllText((Join-Path $root $input.path),[Text.Encoding]::UTF8) }
    }

    It 'retains every r2 patch section and fixes under an immutable paired revision' {
        $previousRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r2'
        $previous = Get-Content -LiteralPath (Join-Path $previousRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $previousPatch = [IO.File]::ReadAllText((Join-Path $previousRoot 'file-operations.patch'),[Text.Encoding]::UTF8)
        $patch = [IO.File]::ReadAllText((Join-Path $assetRoot 'file-operations.patch'),[Text.Encoding]::UTF8)
        $patch.StartsWith($previousPatch,[StringComparison]::Ordinal) | Should -BeTrue
        $manifest.upstream.commit | Should -Be $previous.upstream.commit
        $manifest.upstream.sourceArchive.sha256 | Should -Be $previous.upstream.sourceArchive.sha256
        $manifest.downstreamRevision | Should -Be 'itl-r3'
        $manifest.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r3.zip'
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r3.cfe'
        $manifest.pairedExtension.protocol | Should -Be $previous.pairedExtension.protocol
        (Get-FileHash -LiteralPath (Join-Path $assetRoot 'file-operations.patch') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount 16
        foreach ($path in $previous.patch.expectedChangedPaths) { $manifest.patch.expectedChangedPaths | Should -Contain $path }
        foreach ($fix in $previous.patch.retainedDownstreamFixes) { $manifest.patch.retainedDownstreamFixes | Should -Contain $fix }
        $provenance.upstreamCommit | Should -Be $manifest.upstream.commit
        foreach ($input in $provenance.inputs) {
            (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $input.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $input.sha256
            $manifest.patch.expectedChangedPaths | Should -Contain $input.path
        }
    }

    It 'retains all report branches and the four-to-three parameter fallback' {
        $path = 'lib/VAExtension/DataProcessors/VAExtension_МакетПоВариантуОтчета/Forms/Форма/Ext/Form/Module.bsl'
        $originals[$path] | Should -Match 'Отчеты\.УниверсальныйОтчет\.'
        $patched[$path] | Should -Not -Match 'Отчеты\.УниверсальныйОтчет\.'
        $restored = $patched[$path].Replace("`tМенеджерОтчета = Отчеты[ИмяОтчета];`n`tОтчет = МенеджерОтчета.Создать();", "`tОтчет = Отчеты[ИмяОтчета].Создать();")
        $restored = $restored.Replace('МенеджерОтчета.ФиксированныеПараметры(', 'Отчеты.УниверсальныйОтчет.ФиксированныеПараметры(').Replace('МенеджерОтчета.СхемаКомпоновкиДанных(', 'Отчеты.УниверсальныйОтчет.СхемаКомпоновкиДанных(')
        $restored | Should -BeExactly $originals[$path]
    }

    It 'preserves system wrapper blocking, close and SelectedForm callback: <name>' -TestCases @(
        @{name='AllFunctionsForm';form='VAExtension_ОткрытьВсеФункции'},
        @{name='DesktopCustomization';form='VAExtension_ОткрытьНастройкаНачальнойСтраницы'}
    ) {
        param($name,$form)
        $path = 'lib/VAExtension/DataProcessors/'+$form+'/Forms/Форма/Ext/Form/Module.bsl'
        $resolverCall = 'VAExtensionОбщегоНазначенияКлиент.ПолучитьСистемнуюФорму("'+$name+'")'
        $restored = $patched[$path].Replace($resolverCall, 'ПолучитьФорму("sysForm:'+$name+'")')
        $restored | Should -BeExactly $originals[$path]
    }

    It 'resolves only the two platform addresses and rejects metadata or unknown system names before dispatch' {
        $path = 'lib/VAExtension/CommonModules/VAExtensionОбщегоНазначенияКлиент/Ext/Module.bsl'
        $marker = '// Выполняет произвольный код на стороне клиента'
        $start = $patched[$path].IndexOf($marker,[StringComparison]::Ordinal)
        $start | Should -BeGreaterThan 0
        $patched[$path].Substring($start) | Should -BeExactly $originals[$path]
        $function = $patched[$path].Substring(0,$start)
        $probe = @'
Перем Вызовы;
Функция ПолучитьФорму(Адрес)
    Вызовы.Добавить(Адрес);
    Возврат Адрес;
КонецФункции
'@ + "`n" + $function + @'

Вызовы = Новый Массив;
Если ПолучитьСистемнуюФорму("AllFunctionsForm") <> "sysForm:AllFunctionsForm" Тогда ВызватьИсключение "ALL_FUNCTIONS_ADDRESS_CHANGED"; КонецЕсли;
Если ПолучитьСистемнуюФорму("DesktopCustomization") <> "sysForm:DesktopCustomization" Тогда ВызватьИсключение "DESKTOP_ADDRESS_CHANGED"; КонецЕсли;
Для Каждого Имя Из СтрРазделить("OtherSystemForm,Report.UniversalReport.Form", ",") Цикл
    Отклонено = Ложь;
    Попытка
        ПолучитьСистемнуюФорму(Имя);
    Исключение
        Отклонено = СтрНайти(ОписаниеОшибки(), "Неизвестная системная форма VAExtension:") > 0;
    КонецПопытки;
    Если НЕ Отклонено Тогда ВызватьИсключение "UNKNOWN_NAMESPACE_ACCEPTED"; КонецЕсли;
КонецЦикла;
Если Вызовы.Количество() <> 2 Тогда ВызватьИсключение "UNKNOWN_NAME_DISPATCHED"; КонецЕсли;
Сообщить("CLOSED_SYSTEM_NAMESPACE_PASSED");
'@
        $probePath = Join-Path $TestDrive 'Пространство системных форм.os'
        [IO.File]::WriteAllText($probePath,$probe,[Text.UTF8Encoding]::new($true))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command oscript -ErrorAction Stop).Source
        $startInfo.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8',$probePath)
        $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $outputTask = $process.StandardOutput.ReadToEndAsync(); $errorTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'System namespace probe timed out.' }
            $output = $outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult()
            $process.ExitCode | Should -Be 0 -Because $output
            $output | Should -Match 'CLOSED_SYSTEM_NAMESPACE_PASSED'
        } finally { $process.Dispose() }
    }
}

Describe 'Current-window expression failure attribution in controlled Vanessa r6' {
    BeforeAll {
        $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $repoRoot 'scripts/git-path-list.ps1')
        $assetRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r6'
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patch = [IO.File]::ReadAllText((Join-Path $assetRoot 'file-operations.patch'),[Text.Encoding]::UTF8)
        $expressionPath = 'features/Libraries/VAExtension/VAExtension/Forms/Форма/Ext/Form/Module.bsl'
        $sections = @{}
        foreach ($section in @($patch -split '(?m)(?=^diff --git )' | Where-Object { $_ })) { $sections[($section -split "`n")[0]] = $section }
        $expressionSection = $sections['diff --git a/'+$expressionPath+' b/'+$expressionPath]
        $rethrowHunks = @($expressionSection -split '(?m)(?=^@@ )' | Where-Object { $_ -match 'ЗаписатьЛогВЖРИнформация\("ЯВыполняюВыражениеВТекущемОкнеРасширение"' -and $_ -match '(?m)^\+\s+ВызватьИсключение;' })
    }

    It 'applies only an outer rethrow while preserving success, waiting and optional helper cleanup' {
        $rethrowHunks | Should -HaveCount 1
        $hunk = $rethrowHunks[0]
        @($hunk -split "`n" | Where-Object { $_ -match '^\+' }) | Should -HaveCount 1
        @($hunk -split "`n" | Where-Object { $_ -match '^-' }) | Should -HaveCount 0
        $fixture = Join-Path $repoRoot 'tests/fixtures/vanessa-current-window-expression'
        $provenance = Get-Content -LiteralPath (Join-Path $fixture 'provenance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $upstream = [IO.File]::ReadAllText((Join-Path $fixture 'function.upstream.bsl'),[Text.Encoding]::UTF8)
        (Get-FileHash -LiteralPath (Join-Path $fixture 'function.upstream.bsl')).Hash.ToLowerInvariant() | Should -Be $provenance.sha256
        $manifest.upstream.commit | Should -Be $provenance.commit
        $provenance.path | Should -Be $expressionPath
        $root = Join-Path $TestDrive 'Выражение в окне'
        $target = Join-Path $root $expressionPath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::WriteAllText($target,$upstream,[Text.UTF8Encoding]::new($false))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('init','--quiet'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('config','core.autocrlf','false'))
        $hunkPath = Join-Path $TestDrive 'outer-rethrow.patch'
        $diff = 'diff --git a/'+$expressionPath+' b/'+$expressionPath+"`n--- a/"+$expressionPath+"`n+++ b/"+$expressionPath+"`n"+$hunk
        [IO.File]::WriteAllText($hunkPath,$diff,[Text.UTF8Encoding]::new($false))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--check','--whitespace=error-all',$hunkPath))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--whitespace=error-all',$hunkPath))
        $logger = "`t`tВанесса.ЗаписатьЛогВЖРИнформация(`"ЯВыполняюВыражениеВТекущемОкнеРасширение`", ОписаниеОшибки());"
        [IO.File]::ReadAllText($target,[Text.Encoding]::UTF8) | Should -BeExactly ($upstream.Replace($logger,$logger+"`n`t`tВызватьИсключение;"))
    }

    It 'retains all r4 fixes and the primary assertion attachment protection' {
        $previous = [IO.File]::ReadAllText((Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r4/file-operations.patch'),[Text.Encoding]::UTF8)
        foreach ($section in @($previous -split '(?m)(?=^diff --git )' | Where-Object { $_ })) {
            $key = ($section -split "`n")[0]
            $actual = $sections[$key]
            if ($key -ceq ('diff --git a/'+$expressionPath+' b/'+$expressionPath)) { $actual = $actual.Replace($rethrowHunks[0],'') }
            $actual -replace '(?m)^(index |@@ )[^\n]*\n','' | Should -BeExactly ($section -replace '(?m)^(index |@@ )[^\n]*\n','')
        }
        $interface = $sections['diff --git a/features/Libraries/UITestRunner/step_definitions/РаботаСИнтерфейсом/Forms/Форма/Ext/Form/Module.bsl b/features/Libraries/UITestRunner/step_definitions/РаботаСИнтерфейсом/Forms/Форма/Ext/Form/Module.bsl']
        $interface | Should -Match 'Дополнительная ошибка вложения'
        $interface | Should -Match 'ТекстСообщения = ТекстСообщения \+ Символы.ПС \+ ОшибкаВложения'
        (Get-FileHash -LiteralPath (Join-Path $assetRoot 'file-operations.patch')).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        $manifest.patch.gitDiffFormat | Should -Be 'full-index'
    }

    It 'pins the tested recipe and paired extension in the delivery lock' {
        $assetRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r7'
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock = Get-Content -LiteralPath (Join-Path $repoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.dependencies.vanessaAutomation.downstreamRevision | Should -Be 'itl-r7'
        $lock.dependencies.vanessaAutomation.patchSha256 | Should -Be $manifest.patch.sha256
        $lock.dependencies.vanessaAutomation.manifestSha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $assetRoot 'manifest.json')).Hash.ToLowerInvariant()
        $lock.dependencies.vanessaAutomation.assetName | Should -Be $manifest.artifact.fileName
        $lock.dependencies.vanessaMcp.vaExtension.assetName | Should -Be $manifest.pairedExtension.fileName
    }

    It 'keeps authenticated recipe and upstream excerpt bytes unchanged by Git filters' {
        foreach ($relative in @(
            'third-party/vanessa-automation/1.2.043.42-itl-r6/manifest.json',
            'third-party/vanessa-automation/1.2.043.42-itl-r6/ITL-NOTICE.txt',
            'third-party/vanessa-automation/1.2.043.42-itl-r6/LICENSE.upstream',
            'tests/fixtures/vanessa-current-window-expression/function.upstream.bsl',
            'tests/fixtures/vanessa-current-window-expression/provenance.json'
        )) {
            $path = Join-Path $repoRoot $relative
            $raw = (Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('hash-object','--no-filters',$path)).stdout.Trim()
            $filtered = (Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('hash-object',('--path='+$relative),$path)).stdout.Trim()
            $filtered | Should -BeExactly $raw
        }
    }
}

Describe 'Reproducible Vanessa cumulative patch and resume format' {
    BeforeAll {
        $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $repoRoot 'scripts/git-path-list.ps1')
        $previousRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r3'
        $assetRoot = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r4'
        $fixtureRoot = Join-Path $repoRoot 'tests/fixtures/vanessa-extension-portability'
        $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patch = [IO.File]::ReadAllText((Join-Path $assetRoot 'file-operations.patch'),[Text.Encoding]::UTF8)
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/build-vanessa-automation-patched.ps1'),[ref]$null,[ref]$null)
        $function = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-VanessaResumeDiffArguments' })
        if ($function.Count -ne 1) { throw 'The existing builder must own its patch comparison recipe.' }
        . ([scriptblock]::Create($function[0].Extent.Text))
    }

    It 'retains every previous source hunk with only canonical indexes and ordering changed' {
        $previous = Get-Content -LiteralPath (Join-Path $previousRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $previousPatch = [IO.File]::ReadAllText((Join-Path $previousRoot 'file-operations.patch'),[Text.Encoding]::UTF8)
        $before = @{}; $after = @{}
        foreach ($section in @($previousPatch -split '(?m)(?=^diff --git )' | Where-Object { $_ })) { $before[($section -split "`n")[0]] = $section -replace '(?m)^index [^\n]*\n','' }
        foreach ($section in @($patch -split '(?m)(?=^diff --git )' | Where-Object { $_ })) { $after[($section -split "`n")[0]] = $section -replace '(?m)^index [^\n]*\n','' }
        @($before.Keys) | Should -HaveCount 16
        @($after.Keys) | Should -HaveCount 16
        foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
        $manifest.upstream.commit | Should -Be $previous.upstream.commit
        $manifest.downstreamRevision | Should -Be 'itl-r4'
        $manifest.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r4.zip'
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r4.cfe'
        $manifest.pairedExtension.protocol | Should -Be $previous.pairedExtension.protocol
        ($manifest.patch.expectedChangedPaths -join "`n") | Should -BeExactly ($previous.patch.expectedChangedPaths -join "`n")
        ($manifest.patch.retainedDownstreamFixes -join "`n") | Should -BeExactly ($previous.patch.retainedDownstreamFixes -join "`n")
        (Get-FileHash -LiteralPath (Join-Path $assetRoot 'file-operations.patch') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
    }

    It 'preserves the original comparison arguments for older immutable recipes' {
        $legacy = Get-Content -LiteralPath (Join-Path $previousRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        (@(Get-VanessaResumeDiffArguments -Manifest $legacy) -join ' ') | Should -BeExactly '--binary'
    }

    It 'refuses an unknown source recipe instead of silently comparing another format' {
        { Get-VanessaResumeDiffArguments -Manifest ([pscustomobject]@{patch=[pscustomobject]@{gitDiffFormat='unknown'}}) } | Should -Throw '*VANESSA_BUILD_PATCH_DIFF_FORMAT_UNSUPPORTED*'
    }

    It 'reproduces shortened Git indexes and accepts the same source through full-index resume proof' {
        $root = Join-Path $TestDrive 'Возобновление сборки с пробелом'
        [void][IO.Directory]::CreateDirectory($root)
        $provenance = Get-Content -LiteralPath (Join-Path $fixtureRoot 'provenance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($input in $provenance.inputs) {
            $target = Join-Path $root $input.path
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy((Join-Path $fixtureRoot $input.path),$target)
        }
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('init','--quiet'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('config','core.autocrlf','false'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('add','--all'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('-c','user.name=ITL fixture','-c','user.email=fixture@itl.local','commit','--quiet','-m','Exact upstream inputs'))
        $includes = @($provenance.inputs | ForEach-Object { '--include='+$_.path })
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('apply','--check','--whitespace=error-all')+$includes+@((Join-Path $assetRoot 'file-operations.patch'))))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('apply','--whitespace=error-all')+$includes+@((Join-Path $assetRoot 'file-operations.patch'))))
        $selectedSections = @($patch -split '(?m)(?=^diff --git )' | Where-Object {
            $header = ($_ -split "`n")[0]
            @($provenance.inputs | Where-Object { $header -ceq ('diff --git a/'+$_.path+' b/'+$_.path) }).Count -eq 1
        }) -join ''
        $legacyDiff = Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('diff','--binary','--abbrev=7','HEAD')
        $legacyDiff.stdout | Should -Not -BeExactly $selectedSections
        $diffPath = Join-Path $TestDrive 'canonical-full-index.patch'
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments (@('diff')+@(Get-VanessaResumeDiffArguments -Manifest $manifest)+@('HEAD',('--output='+$diffPath))))
        $actual = [IO.File]::ReadAllText($diffPath,[Text.Encoding]::UTF8)
        $actual | Should -BeExactly $selectedSections
        foreach ($index in [regex]::Matches($actual,'(?m)^index ([0-9a-f]+)\.\.([0-9a-f]+) ')) {
            $index.Groups[1].Length | Should -Be 40
            $index.Groups[2].Length | Should -Be 40
        }
    }
}

Describe 'Diagnostic screenshot failure preserves the original report' {
    BeforeAll {
        $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $repoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        $recipe = Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r7'
        $fixture = Join-Path $repoRoot 'tests/fixtures/vanessa-diagnostic-screenshot'
        $manifest = Get-Content -LiteralPath (Join-Path $recipe 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $provenance = Get-Content -LiteralPath (Join-Path $fixture 'provenance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patch = [IO.File]::ReadAllText((Join-Path $recipe 'file-operations.patch'),[Text.Encoding]::UTF8)
        $section = @($patch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq ('diff --git a/'+$provenance.path+' b/'+$provenance.path) })
        if ($section.Count -ne 1) { throw 'Expected the existing main form owner.' }
        $hunks = @($section[0] -split '(?m)(?=^@@ )' | Where-Object { $_ -match '^@@ ' -and $_ -match 'ИмяПроцедурыПриОшибкеСохранения|ПродолжитьПослеОшибкиСохраненияСкриншота|ЗавершитьСнятиеСкриншотовОшибки|Объект\.КаталогВыгрузкиСкриншотов' })
        $root = Join-Path $TestDrive 'Сохранение снимка с пробелом'
        $target = Join-Path $root $provenance.path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy((Join-Path $fixture 'callbacks.r6.bsl'),$target)
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('init','--quiet'))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('config','core.autocrlf','false'))
        $diff = 'diff --git a/'+$provenance.path+' b/'+$provenance.path+"`n--- a/"+$provenance.path+"`n+++ b/"+$provenance.path+"`n"+($hunks -join '')
        $hunkPath = Join-Path $TestDrive 'diagnostic.patch'
        [IO.File]::WriteAllText($hunkPath,$diff,[Text.UTF8Encoding]::new($false))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--check','--whitespace=error-all',$hunkPath))
        [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('apply','--whitespace=error-all',$hunkPath))
        $patched = [IO.File]::ReadAllText($target,[Text.Encoding]::UTF8)
        function Get-Body([string]$Name) {
            $match = [regex]::Match($patched,'(?ms)^(?:Процедура|Функция) '+[regex]::Escape($Name)+'\(.*?^Конец(?:Процедуры|Функции)[^\n]*')
            if (-not $match.Success) { throw "Missing production body $Name" }
            $match.Value
        }
    }

    It 'applies the actual I/O patch to authenticated r6 owner excerpts' {
        (Get-FileHash -LiteralPath (Join-Path $fixture 'callbacks.r6.bsl')).Hash.ToLowerInvariant() | Should -Be $provenance.sha256
        $prior = Join-Path $repoRoot ('third-party/vanessa-automation/'+$provenance.baselineRecipe+'/file-operations.patch')
        (Get-FileHash -LiteralPath $prior).Hash.ToLowerInvariant() | Should -Be $provenance.baselinePatchSha256
        (Get-FileHash -LiteralPath (Join-Path $recipe 'file-operations.patch')).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        $manifest.upstream.commit | Should -Be $provenance.commit
        foreach ($name in @('ПолученСнимокЭкранаОбработчикОповещения','ПолученСнимокОкна')) {
            $body = Get-Body $name
            $body | Should -Match '(?s)ДвоичныеДанные\.Записать\(.*?Исключение\s+Если НЕ ПродолжитьПослеОшибкиСохраненияСкриншота.*?ВызватьИсключение;.*?Возврат;.*?КонецПопытки;'
            $body | Should -Match '(?s)КопироватьФайлКомандаСистемы\(.*?Исключение\s+Если НЕ ПродолжитьПослеОшибкиСохраненияСкриншота.*?ВызватьИсключение;.*?Возврат;.*?КонецПопытки;'
            $body.IndexOf('ДвоичныеДанные.Записать(') | Should -BeLessThan $body.IndexOf('ДобавитьИмяФайлаСкриншотаКСтрокеТекущегоСценария(')
        }
    }

    It 'passes explicit diagnostic continuation through all native capture adapters' {
        foreach ($name in @('СделатьСкриншотОшибкиТекущегоОкна','СделатьСкриншотыВсехОконКомпонента','ОпределитьСвойстваПроцессаИСделатьСкриншотЕслиНеобходимоОбработкаОповещения','СделатьСкриншотыВсехОконКомпонентаПродолжение')) {
            Get-Body $name | Should -Match 'Вставить\("ИмяПроцедурыПриОшибкеСохранения", "ЗавершитьСнятиеСкриншотовОшибки"\)'
        }
        Get-Body 'СделатьСкриншотКомпонента' | Should -Match 'Свойство\("ИмяПроцедурыПриОшибкеСохранения", ИмяПроцедурыПриОшибкеСохранения\)'
        Get-Body 'СкриншотКомпонентойВсегоЭкрана' | Should -Match 'Вставить\("ИмяПроцедурыПриОшибкеСохранения", ИмяПроцедурыПриОшибкеСохранения\)'
        # No other recipe owner grants optionality to ordinary screenshots/autodoc.
        @($patch -split "`n" | Where-Object { $_ -match '^\+.*Вставить\("ИмяПроцедурыПриОшибкеСохранения", "' }) | Should -HaveCount 4
    }

    It 'executes <probeName> against production BSL' -ForEach @(
        @{probeName='report continuation including logger failure'; probeFile='continuation.os'; expected='DIAGNOSTIC_CONTINUATION_PASSED'; bodies=@('ПродолжитьПослеОшибкиСохраненияСкриншота','ЗавершитьСнятиеСкриншотовОшибки')},
        @{probeName='real file I/O failures in both callbacks, mandatory and diagnostic'; probeFile='callback-io.os'; expected='DIAGNOSTIC_CALLBACK_IO_PASSED'; bodies=@('ПродолжитьПослеОшибкиСохраненияСкриншота','ПолученСнимокЭкранаОбработчикОповещения','ПолученСнимокОкна')}
    ) {
        $helper = Get-Body 'ПродолжитьПослеОшибкиСохраненияСкриншота'
        $terminal = Get-Body 'ЗавершитьСнятиеСкриншотовОшибки'
        $terminal | Should -Not -Match 'СделатьСкриншот|ЗакрытьМодальный|ПодключитьОбработчикОжидания'
        Get-Body 'СделатьСкриншотыОшибкиПродолжение' | Should -Match 'ЗавершитьСнятиеСкриншотовОшибки\(\);'
        $production = (@($bodies | ForEach-Object { Get-Body $_ }) -join "`n") -replace '(?m)^\s*#.*$',''
        $probe = [IO.File]::ReadAllText((Join-Path $fixture $probeFile),[Text.Encoding]::UTF8).Replace('// PRODUCTION_PROCEDURES',$production)
        $probePath = Join-Path $TestDrive 'Диагностика с пробелом.os'
        [IO.File]::WriteAllText($probePath,$probe,[Text.UTF8Encoding]::new($true))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command oscript -ErrorAction Stop).Source
        $ioRoot = Join-Path $TestDrive 'Файловая проверка с пробелом'
        [void][IO.Directory]::CreateDirectory($ioRoot)
        $startInfo.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8',$probePath,$ioRoot)
        $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $outputTask = $process.StandardOutput.ReadToEndAsync(); $errorTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Diagnostic continuation probe timed out.' }
            $output = $outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult()
            $process.ExitCode | Should -Be 0 -Because $output
            $output | Should -Match $expected
        } finally { $process.Dispose() }
    }

    It 'retains unrelated cumulative fixes and authenticates the new recipe bytes through Git filters' {
        $previous = [IO.File]::ReadAllText((Join-Path $repoRoot 'third-party/vanessa-automation/1.2.043.42-itl-r6/file-operations.patch'),[Text.Encoding]::UTF8)
        $normalize = '(?m)^(index |@@ )[^\n]*\n'
        $previousMain = @($previous -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq ('diff --git a/'+$provenance.path+' b/'+$provenance.path) })[0]
        $retainedMain = $section[0]
        foreach ($hunk in $hunks) { $retainedMain = $retainedMain.Replace($hunk,'') }
        ($retainedMain -replace $normalize,'') | Should -BeExactly ($previousMain -replace $normalize,'')
        foreach ($oldSection in @($previous -split '(?m)(?=^diff --git )' | Where-Object { $_ })) {
            $header = ($oldSection -split "`n")[0]
            if ($header -ceq ('diff --git a/'+$provenance.path+' b/'+$provenance.path)) { continue }
            $current = @($patch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq $header })
            $current.Count | Should -Be 1
            ($current[0] -replace $normalize,'') | Should -BeExactly ($oldSection -replace $normalize,'')
        }
        foreach ($relative in @('third-party/vanessa-automation/1.2.043.42-itl-r7/manifest.json','third-party/vanessa-automation/1.2.043.42-itl-r7/ITL-NOTICE.txt','third-party/vanessa-automation/1.2.043.42-itl-r7/LICENSE.upstream','tests/fixtures/vanessa-diagnostic-screenshot/callbacks.r6.bsl','tests/fixtures/vanessa-diagnostic-screenshot/provenance.json')) {
            $path = Join-Path $repoRoot $relative
            $raw = (Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('hash-object','--no-filters',$path)).stdout.Trim()
            (Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('hash-object',('--path='+$relative),$path)).stdout.Trim() | Should -BeExactly $raw
        }
    }
}
