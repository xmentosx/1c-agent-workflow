Describe "Controlled Vanessa Automation patched artifact" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-itl-r3"
        $manifestPath = Join-Path $assetRoot "manifest.json"
        $patchPath = Join-Path $assetRoot "file-operations.patch"
        $licensePath = Join-Path $assetRoot "LICENSE.upstream"
        $buildScriptPath = Join-Path $repoRoot "scripts\build-vanessa-automation-patched.ps1"
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
        $buildScriptText = Get-Content -LiteralPath $buildScriptPath -Raw -Encoding UTF8
    }

    It "pins the exact upstream source, patch, downstream revision, and toolchain" {
        $manifest.upstream.repository | Should -Be "https://github.com/Pr-Mex/vanessa-automation.git"
        $manifest.upstream.ref | Should -Be "refs/tags/1.2.043.28"
        $manifest.upstream.commit | Should -Be "f3a01778a14d29b38204685deea0131274d438ff"
        $manifest.upstream.sourceArchive.sha256 | Should -Be "3581a8d6bb675426b6555fd0b0f2e612c7c9ea0b704123129256a89f1f8f2f81"
        $manifest.compatibilityVersion | Should -Be "1.2.043.28"
        $manifest.downstreamRevision | Should -Be "itl-r3"
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
    }

    It "keeps run-scenario progress file operations outside the active MCP path" {
        $mcpActive = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lgg0JfQvdCw0YfQtdC90LjQtdCX0LDQv9C+0LvQvdC10L3QvijQmNC00LXQvdGC0LjRhNC40LrQsNGC0L7RgNCX0LDQtNCw0YfQuE1DUCgpKSDQotC+0LPQtNCw"))
        $guardedProbe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0Jgg0J3QlSDQpNCw0LnQu9Ch0YPRidC10YHRgtCy0YPQtdGC0JrQvtC80LDQvdC00LDQodC40YHRgtC10LzRiyhWYW5lc3NhVGFicy5jdXJyZW50LmZpbGVuYW1lKSDQotC+0LPQtNCw"))
        $originalProbe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lgg0J3QlSDQpNCw0LnQu9Ch0YPRidC10YHRgtCy0YPQtdGC0JrQvtC80LDQvdC00LDQodC40YHRgtC10LzRiyhWYW5lc3NhVGFicy5jdXJyZW50LmZpbGVuYW1lKSDQotC+0LPQtNCw"))
        $globalFunction = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KTRg9C90LrRhtC40Y8g0KTQsNC50LvQodGD0YnQtdGB0YLQstGD0LXRgtCa0L7QvNCw0L3QtNCw0KHQuNGB0YLQtdC80Yso"))
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($mcpActive) + "$")
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($guardedProbe) + "$")
        $patchText | Should -Match ("(?m)^-\s*" + [regex]::Escape($originalProbe) + "$")
        $patchText | Should -Not -Match ("(?m)^[+-]\s*" + [regex]::Escape($globalFunction))
        $testClientOwnershipComment = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("VGVzdENsaWVudCDQtNC70Y8gTUNQINGD0L/RgNCw0LLQu9GP0LXRgiBmYWNhZGU="))
        $mcpActiveGuard = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lgg0JfQvdCw0YfQtdC90LjQtdCX0LDQv9C+0LvQvdC10L3QvijQmNC00LXQvdGC0LjRhNC40LrQsNGC0L7RgNCX0LDQtNCw0YfQuE1DUCgpKSDQotC+0LPQtNCw"))
        $returnFalse = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JLQvtC30LLRgNCw0YIg0JvQvtC20Yw7"))
        $patchText | Should -Match ([regex]::Escape($testClientOwnershipComment))
        $patchText | Should -Match ("(?s)" +
            [regex]::Escape($testClientOwnershipComment) +
            ".*?\+\s*" + [regex]::Escape($mcpActiveGuard) +
            ".*?\+\s*" + [regex]::Escape($returnFalse))
        $mcpMarker = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGLLtCS0YHRgtCw0LLQuNGC0YwoItCt0YLQvtCS0YvQt9C+0LJNQ1AiLCDQl9C90LDRh9C10L3QuNC10JfQsNC/0L7Qu9C90LXQvdC+KNCY0LTQtdC90YLQuNGE0LjQutCw0YLQvtGA0JfQsNC00LDRh9C4TUNQKCkpKTs="))
        $serverMarker = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQsNC90L3Ri9C1LtCU0L7Qv9Cf0LDRgNCw0LzQtdGC0YDRiy7QodCy0L7QudGB0YLQstC+KCLQrdGC0L7QktGL0LfQvtCyTUNQIiwg0K3RgtC+0JLRi9C30L7Qsk1DUCk7"))
        $serverGuard = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JXRgdC70Lgg0K3RgtC+0JLRi9C30L7Qsk1DUCDQotC+0LPQtNCw"))
        $stepDefinitionPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KTQsNC50LtFUEYgPSDQmtCw0YLQsNC70L7Qs9Ck0LjRh9C4ICsgInN0ZXBfZGVmaW5pdGlvbnMi"))
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($mcpMarker) + "$")
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($serverMarker) + "$")
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($serverGuard) + "$")
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($stepDefinitionPath) + "$")
        $editorContent = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KLQtdC60YHRgtCk0LDQudC70LAgPSDQktCw0L3QtdGB0YHQsC7Qn9C+0LvRg9GH0LjRgtGMVmFuZXNzYUVkaXRvcigpLmdldENvbnRlbnQoKTs="))
        $directReloadCallback = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J7Qv9C+0LLQtdGB0YLQuNGC0YxNQ1Bf0J7Ql9Cw0LLQtdGA0YjQtdC90LjQuNCX0LDQs9GA0YPQt9C60LjQpNC40YfQuCg="))
        $reloadCallbackType = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JfQsNCz0YDRg9C30LjRgtGM0KTQuNGH0YPQlNC70Y/QktGL0L/QvtC70L3QtdC90LjRj9Ch0YbQtdC90LDRgNC40Y8="))
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($editorContent) + "$")
        $patchText | Should -Match ("(?s)\+\s*" +
            [regex]::Escape($directReloadCallback) +
            ".*?\+\s*" + [regex]::Escape('"' + $reloadCallbackType + '"'))
        $reloadType = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("ItCX0LDQs9GA0YPQt9C40YLRjNCk0LjRh9GD0JTQu9GP0JLRi9C/0L7Qu9C90LXQvdC40Y/QodGG0LXQvdCw0YDQuNGPIiw="))
        $callParameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL0JLRi9C30L7QstCwTUNQKTs="))
        $returnStatement = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JLQvtC30LLRgNCw0YI7"))
        $patchText | Should -Match ("(?s)" +
            [regex]::Escape($reloadType) +
            ".*?" + [regex]::Escape($callParameters) +
            "\s*\+\s*" + [regex]::Escape($returnStatement))
    }

    It "implements one shared path probe with distinct structured errors" {
        $patchText | Should -Match "(?m)^\+&"
        $patchText | Should -Match "(?m)^\+.*\("
        $patchText | Should -Match ([regex]::Escape('"PATH_INVALID"'))
        $patchText | Should -Match ([regex]::Escape('"PATH_NOT_FOUND"'))
        $patchText | Should -Match ([regex]::Escape('"PATH_ACCESS_DENIED"'))
        ([regex]::Matches($patchText, [regex]::Escape('"PATH_INVALID"'))).Count | Should -BeGreaterThan 1
        $compatibilityFunction = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KTRg9C90LrRhtC40Y8gTUNQ0J3QvtGA0LzQsNC70LjQt9C+0LLQsNGC0YzQn9GD0YLRjNCa0KTQuNGH0LDQpNCw0LnQu9GDKNCf0YPRgtGMKQ=="))
        $sharedProbeCall = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/RgNC+0LLQtdGA0LrQsNCf0YPRgtC4ID0gTUNQ0J/QvtC00LPQvtGC0L7QstC40YLRjNCf0YPRgtGM0JrQpNC40YfQsNC8KNCf0YPRgtGMKTs="))
        $fileConstructor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3QvtCy0YvQuSDQpNCw0LnQuw=="))
        $patchText | Should -Match ("(?m)^\+" + [regex]::Escape($compatibilityFunction) + "$")
        $patchText | Should -Match ("(?m)^\+\s*" + [regex]::Escape($sharedProbeCall) + "$")
        $patchText | Should -Not -Match ("(?m)^\+.*" + [regex]::Escape($fileConstructor))
        $asyncSearch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3QsNGH0LDRgtGM0J/QvtC40YHQutCk0LDQudC70L7Qsg=="))
        $asyncRead = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J3QsNGH0LDRgtGM0KfRgtC10L3QuNC1"))
        $patchText | Should -Match ([regex]::Escape($asyncSearch + "("))
        $patchText | Should -Match ([regex]::Escape("." + $asyncRead + "("))
        $taskRegistration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JLQsNC90LXRgdGB0LAu0KPRgdGC0LDQvdC+0LLQuNGC0YzQmNC00LXQvdGC0LjRhNC40LrQsNGC0L7RgNCX0LDQtNCw0YfQuE1DUCjQl9Cw0L/RgNC+0YEu0JjQtNC10L3RgtC40YTQuNC60LDRgtC+0YApOw=="))
        $patchText | Should -Match ([regex]::Escape($taskRegistration))
        $patchText | Should -Match ([regex]::Escape('"SEARCH"'))
        $patchText | Should -Match ([regex]::Escape('"READ"'))
        $patchText | Should -Not -Match "WshShell"
        $patchText | Should -Not -Match "(?i)TEMP|TMP|Copy-Item"
        $patchText | Should -Match "(?m)^-.*MCP.*\("
        $patchText | Should -Match "(?m)^-.*\..*\("
    }

    It "builds fail closed through the official upstream flow" {
        $buildScriptText | Should -Match ([regex]::Escape('"apply", "--check", "--whitespace=error-all"'))
        $buildScriptText | Should -Match ([regex]::Escape('"archive", "--format=tar"'))
        $buildScriptText | Should -Match ([regex]::Escape('"tools\onescript\Compile.os"'))
        $buildScriptText | Should -Match ([regex]::Escape('"tools\onescript\MakeVASingle.os"'))
        $buildScriptText | Should -Match ([regex]::Escape("expectedChangedPaths"))
        $buildScriptText | Should -Match ([regex]::Escape("manifest.license.upstreamSha256"))
        $buildScriptText | Should -Match ([regex]::Escape("Enter-ScopedUnsafeActionProtectionBypass"))
        $buildScriptText | Should -Match ([regex]::Escape('$settingPattern = "(?m)^(DisableUnsafeActionProtection=)([^\r\n]*)"'))
        $buildScriptText | Should -Match ([regex]::Escape('$existingPatterns + ";" + $ownedPattern + ";"'))
        $buildScriptText | Should -Match ([regex]::Escape('Join-Path $env:LOCALAPPDATA "1C\1cv8\conf\conf.cfg"'))
        $buildScriptText | Should -Match ([regex]::Escape("Exit-ScopedUnsafeActionProtectionBypass"))
        $buildScriptText | Should -Match ([regex]::Escape("[System.IO.File]::WriteAllBytes"))
        $buildScriptText | Should -Not -Match "DisableUnsafeActionProtection=\.\*;"
        $buildScriptText | Should -Match ([regex]::Escape("New-DeterministicZip"))
        $buildScriptText | Should -Match ([regex]::Escape("[Array]::Sort"))
        $buildScriptText | Should -Match ([regex]::Escape("2000, 1, 1, 0, 0, 0"))
        $buildScriptText | Should -Not -Match ([regex]::Escape("[System.IO.Compression.ZipFile]::CreateFromDirectory"))
        $manifest.artifact.fileName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r3.zip"
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
