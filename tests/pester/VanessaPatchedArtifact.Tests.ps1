Describe "Controlled Vanessa Automation patched artifact" {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-itl-r1"
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
        $manifest.downstreamRevision | Should -Be "itl-r1"
        $manifest.build.platform.version | Should -Be "8.3.27.2130"
        $manifest.build.oneScript.version | Should -Be "1.9.4.16"
        $manifest.build.oneScript.packages.v8runner | Should -Be "1.8.2"
        $manifest.build.oneScript.packages.logos | Should -Be "1.4.0"

        $patchSha = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $patchSha | Should -Be $manifest.patch.sha256
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount 1
        $manifest.patch.expectedChangedPaths[0] | Should -Be "VanessaAutomation/Forms/MCPVA/Ext/Form/Module.bsl"
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
        $manifest.artifact.fileName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r1.zip"
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
