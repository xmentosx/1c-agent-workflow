Describe "Controlled Vanessa Automation patched artifact" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-itl-r8"
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
        $manifest.downstreamRevision | Should -Be "itl-r8"
        $manifest.build.platform.version | Should -Be "8.3.27.2130"
        $manifest.build.oneScript.version | Should -Be "1.9.4.16"
        $manifest.build.oneScript.packages.v8runner | Should -Be "1.8.2"
        $manifest.build.oneScript.packages.logos | Should -Be "1.4.0"

        $patchSha = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $patchSha | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount 2
        $manifest.patch.expectedChangedPaths[0] | Should -Be "VanessaAutomation/Forms/MCPVA/Ext/Form/Module.bsl"
        $managedFormPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("VmFuZXNzYUF1dG9tYXRpb24vRm9ybXMv0KPQv9GA0LDQstC70Y/QtdC80LDRj9Ck0L7RgNC80LAvRXh0L0Zvcm0vTW9kdWxlLmJzbA=="))
        $manifest.patch.expectedChangedPaths[1] | Should -Be $managedFormPath
        @($manifest.patch.upstreamBackports) | Should -HaveCount 2
        @($manifest.patch.retainedDownstreamFixes) | Should -HaveCount 4
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
        $buildScriptText | Should -Match ([regex]::Escape('"tools\onescript\Compile.os"'))
        $buildScriptText | Should -Match ([regex]::Escape('"tools\onescript\MakeVASingle.os"'))
        $buildScriptText | Should -Match ([regex]::Escape('[ValidateSet("itl-r4", "itl-r5", "itl-r6", "itl-r7", "itl-r8")]'))
        $buildScriptText | Should -Match ([regex]::Escape('$DownstreamRevision = "itl-r8"'))
        $buildScriptText | Should -Match ([regex]::Escape("Enter-ScopedUnsafeActionProtectionBypass"))
        $buildScriptText | Should -Match ([regex]::Escape("Exit-ScopedUnsafeActionProtectionBypass"))
        $buildScriptText | Should -Not -Match "DisableUnsafeActionProtection=\.\*;"
        $buildScriptText | Should -Match ([regex]::Escape("New-DeterministicZip"))
        $manifest.artifact.fileName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r8.zip"
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
