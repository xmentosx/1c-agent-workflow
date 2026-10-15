Describe "Workflow-pinned Vanessa Automation integration" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:RepoRoot = $context.RepoRoot
        $script:SourceHelperPath = $context.HelperPath
        $script:SavedSourceBuild = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
        $script:SavedArchiveOverride = [Environment]::GetEnvironmentVariable("VANESSA_AUTOMATION_ARCHIVE_URL", "Process")
        $script:SavedArtifactCacheRoot = [Environment]::GetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", "Process")
        $script:NonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $script:SavedVanessaEnvironment = @{}
        foreach ($name in @("VANESSA_AUTOMATION_ROOT", "VANESSA_AUTOMATION_EPF", "VANESSA_AUTOMATION_VERSION", "VANESSA_AUTOMATION_DOWNSTREAM_REVISION", "VANESSA_FEATURES_PATH", "VANESSA_REPORTS_PATH")) {
            $script:SavedVanessaEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        $script:FixtureRoot = Join-Path $TestDrive "$script:NonAsciiWord candidate with space"
        $script:FixtureContent = Join-Path $script:FixtureRoot "content"
        New-Item -ItemType Directory -Force -Path $script:FixtureContent | Out-Null
        $script:FixtureEpfPath = Join-Path $script:FixtureContent "vanessa-automation-single.epf"
        [System.IO.File]::WriteAllBytes($script:FixtureEpfPath, [System.Text.Encoding]::UTF8.GetBytes("qualified patched EPF fixture"))
        $script:FixtureVaExtensionPath = Join-Path $script:FixtureContent "VAExtension.1.32-itl-r6.cfe"
        [System.IO.File]::WriteAllBytes($script:FixtureVaExtensionPath, [System.Text.Encoding]::UTF8.GetBytes("qualified paired VAExtension fixture"))
        $script:FixtureNestedPath = Join-Path $script:FixtureContent "metadata\fixture.txt"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:FixtureNestedPath) | Out-Null
        [System.IO.File]::WriteAllText($script:FixtureNestedPath, "nested fixture", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $script:FixtureContent "LICENSE"), "license fixture", [System.Text.UTF8Encoding]::new($false))
        $script:FixtureArchivePath = Join-Path $script:FixtureRoot "vanessa-automation-single.1.2.043.42-itl-r6.zip"
        Compress-Archive -Path (Join-Path $script:FixtureContent "*") -DestinationPath $script:FixtureArchivePath
        $script:FixtureArchiveSha256 = (Get-FileHash -LiteralPath $script:FixtureArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:FixtureEpfSha256 = (Get-FileHash -LiteralPath $script:FixtureEpfPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:FixtureVaExtensionSha256 = (Get-FileHash -LiteralPath $script:FixtureVaExtensionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        function global:New-VanessaArtifactTestProject {
            param(
                [string]$Root,
                [string]$HelperPath = $script:SourceHelperPath
            )

            New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agent-1c") | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root ".agent-1c\project.json"), '{"dependencyMode":"fresh","vanessaAutomation":{"installRoot":".agent-1c/tools/vanessa-automation","featuresPath":"tests/features","reportsPath":"build/test-results/vanessa"}}', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $Root ".dev.env"), "", [System.Text.UTF8Encoding]::new($false))
            $lock = Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.vanessaAutomation.sha256 = $script:FixtureArchiveSha256
            $lock.dependencies.vanessaAutomation.epfSha256 = $script:FixtureEpfSha256
            $lock.dependencies.vanessaMcp.vaExtension.sha256 = $script:FixtureVaExtensionSha256
            [System.IO.File]::WriteAllText((Join-Path $Root ".agent-1c\dependency-lock.json"), (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'templates') -Destination (Join-Path $Root 'templates') -Recurse -Force
            [IO.File]::WriteAllText((Join-Path $Root 'templates/dependency-lock.json'), (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            return $HelperPath
        }
    }

    BeforeEach {
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", (Join-Path $TestDrive "Shared cache $script:NonAsciiWord with space"), "Process")
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:SavedSourceBuild, "Process")
        [Environment]::SetEnvironmentVariable("VANESSA_AUTOMATION_ARCHIVE_URL", $script:SavedArchiveOverride, "Process")
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", $script:SavedArtifactCacheRoot, "Process")
        foreach ($name in @($script:SavedVanessaEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedVanessaEnvironment[$name], "Process")
        }
    }

    AfterAll {
        Remove-Item Function:\New-VanessaArtifactTestProject -ErrorAction SilentlyContinue
    }

    It "opens the archive once and extracts only the pinned runtime files" {
        $implementation = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $implementation | Should -Match ([regex]::Escape("[System.IO.Compression.ZipFile]::OpenRead"))
        $implementation | Should -Match ([regex]::Escape('"vanessa-automation-single.epf" = "vanessa.epf"'))
        $implementation | Should -Not -Match "ExtractToDirectory"
        $implementation | Should -Not -Match "\bExpand-Archive\b"
    }

    It "uses the short project transaction slot instead of GUID-suffixed install paths" {
        $implementation = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $implementation | Should -Match ([regex]::Escape('Initialize-Agent1cProjectTransactionSlot -Kind "v"'))
        $implementation | Should -Not -Match ([regex]::Escape('$stageRoot = "$InstallRoot.install-$operationId"'))
        $implementation | Should -Not -Match ([regex]::Escape('$rollbackRoot = "$InstallRoot.rollback-$operationId"'))
    }

    It "keeps compatibility, downstream revision, artifact provenance, and publication state separate" {
        $entry = (Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
        $entry.version | Should -Be "1.2.043.42"
        $entry.compatibilityVersion | Should -Be "1.2.043.42"
        $entry.downstreamRevision | Should -Be "itl-r6"
        $entry.assetName | Should -Be "vanessa-automation-single.1.2.043.42-itl-r6.zip"
        $entry.url | Should -Be "https://github.com/xmentosx/1c-agent-workflow/releases/download/vanessa-automation-v1.2.043.42-itl-r6/vanessa-automation-single.1.2.043.42-itl-r6.zip"
        $entry.sha256 | Should -Be "9c1ad5c510dc4fc9207a6b576176158e022cbb1243a39c88ade8ddfbb60d46f9"
        $entry.epfSha256 | Should -Be "40ddf0f75d51fb05569e236deee9dcc43a2b53cf80c23c604bc630eab2d1481c"
        $entry.manifestSha256 | Should -Be "5e977f351241d880b9090e81b4d639f44f42ca41daa6b8b797e233d2f9c439d6"
        $entry.patchSha256 | Should -Be "828cfb5277a3aef49d3330f562b6ed971efc38ae185be04af484e0b42c964a3f"
        $entry.upstreamCommit | Should -Be "a0ce2ee9803dd69be52f682e5cf49e0938fd33f1"
        $entry.PSObject.Properties.Name | Should -Not -Contain "publicationStatus"
    }

    It "installs from the exact SHA-verified source-build override without mutating the fresh lock" {
        $testProjectPath = Join-Path $TestDrive "source-project"
        $helperPath = New-VanessaArtifactTestProject -Root $testProjectPath
        $lockPath = Join-Path $testProjectPath ".agent-1c\dependency-lock.json"
        $before = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:FixtureArchivePath, "Process")

        $result = & {
            . $helperPath -ProjectRoot $testProjectPath -Action help *> $null
            Install-VanessaAutomation *> $null
            Get-VanessaAutomationState
        }

        $result.ready | Should -BeTrue
        $result.version | Should -Be "1.2.043.42"
        $result.downstreamRevision | Should -Be "itl-r6"
        $result.epfSha256 | Should -Be $script:FixtureEpfSha256
        (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $testProjectPath ".dev.env") -Raw -Encoding UTF8) | Should -Match "VANESSA_AUTOMATION_DOWNSTREAM_REVISION=itl-r6"
        $installedRoot = Split-Path -Parent $result.epfPath
        $installedRoot | Should -Match ([regex]::Escape($script:NonAsciiWord))
        $installedRoot | Should -Not -Match ([regex]::Escape($testProjectPath))
        (Test-Path -LiteralPath (Join-Path $installedRoot "metadata\fixture.txt")) | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $installedRoot "LICENSE") -Raw -Encoding UTF8) | Should -Be "license fixture"
        (Get-Content -LiteralPath $result.epfPath -Raw -Encoding UTF8) | Should -Be "qualified patched EPF fixture"
        (Test-Path -LiteralPath (Join-Path $testProjectPath ".tx")) | Should -BeFalse
    }

    It "installs the paired VAExtension from the qualified source-build archive before its release exists" {
        $testProjectPath = Join-Path $TestDrive "$script:NonAsciiWord paired CFE with space"
        $helperPath = New-VanessaArtifactTestProject -Root $testProjectPath
        $lockPath = Join-Path $testProjectPath ".agent-1c\dependency-lock.json"
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:FixtureArchivePath, "Process")

        $result = & {
            . $helperPath -ProjectRoot $testProjectPath -Action help *> $null
            $definition = @(Get-VanessaMcpArtifactDefinitions | Where-Object { [string]$_.lockKey -eq "vaExtension" })[0]
            Install-VanessaMcpArtifact -Definition $definition -ForceDownload
        }

        $result.key | Should -Be "vaExtension"
        $result.sha256 | Should -Be $script:FixtureVaExtensionSha256
        $result.path | Should -Match ([regex]::Escape($script:NonAsciiWord))
        [IO.File]::ReadAllText($result.path, [Text.Encoding]::UTF8) | Should -Be "qualified paired VAExtension fixture"
        $lockEntry = (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaMcp.vaExtension
        $lockEntry.source | Should -Be "workflow-pinned"
        $lockEntry.releaseTag | Should -Be "vanessa-automation-v1.2.043.42-itl-r6"
        $lockEntry.protocol | Should -Be "itl-file-code-v1"
    }

    It "installs from a packaged no-Git workflow copy through the same exact override" {
        $packageRoot = Join-Path $TestDrive "packaged-no-git"
        New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot ".agents\skills") | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow") -Destination (Join-Path $packageRoot ".agents\skills\1c-workflow") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates") -Destination (Join-Path $packageRoot "templates") -Recurse -Force
        Test-Path -LiteralPath (Join-Path $packageRoot ".git") | Should -BeFalse
        $helperPath = New-VanessaArtifactTestProject -Root $packageRoot -HelperPath (Join-Path $packageRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1")
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:FixtureArchivePath, "Process")

        $result = & {
            . $helperPath -ProjectRoot $packageRoot -Action help *> $null
            Install-VanessaAutomation *> $null
            Get-VanessaAutomationState
        }

        $result.ready | Should -BeTrue
        $result.epfSha256 | Should -Be $script:FixtureEpfSha256
        $result.downstreamRevision | Should -Be "itl-r6"
    }

    It "rejects archive and EPF mismatches without replacing an existing owned install" {
        $rollbackProjectPath = Join-Path $TestDrive "rollback-project"
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", (Join-Path $TestDrive "Isolated error cache $script:NonAsciiWord"), "Process")
        $helperPath = New-VanessaArtifactTestProject -Root $rollbackProjectPath
        $installRoot = Join-Path $rollbackProjectPath ".agent-1c\tools\va"
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        $existingEpf = Join-Path $installRoot "vanessa.epf"
        [System.IO.File]::WriteAllBytes($existingEpf, [System.Text.Encoding]::UTF8.GetBytes("existing EPF"))
        $existingBytes = [System.IO.File]::ReadAllBytes($existingEpf)
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:FixtureArchivePath, "Process")

        $lockPath = Join-Path $rollbackProjectPath ".agent-1c\dependency-lock.json"
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.dependencies.vanessaAutomation.sha256 = ("0" * 64)
        [System.IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $lockPath -Destination (Join-Path $rollbackProjectPath 'templates/dependency-lock.json') -Force
        $archiveMismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helperPath -ProjectRoot $rollbackProjectPath -Action install-vanessa-automation 2>&1
        ($archiveMismatchOutput -join [Environment]::NewLine) | Should -Match "archive SHA256 mismatch"

        $lock.dependencies.vanessaAutomation.sha256 = $script:FixtureArchiveSha256
        $lock.dependencies.vanessaAutomation.epfSha256 = ("0" * 64)
        [System.IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $lockPath -Destination (Join-Path $rollbackProjectPath 'templates/dependency-lock.json') -Force

        $epfMismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helperPath -ProjectRoot $rollbackProjectPath -Action install-vanessa-automation 2>&1
        ($epfMismatchOutput -join [Environment]::NewLine) | Should -Match "EPF SHA256 mismatch"
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($existingEpf)) | Should -Be ([Convert]::ToBase64String($existingBytes))
        (Test-Path -LiteralPath (Join-Path $rollbackProjectPath ".tx")) | Should -BeFalse
    }
}
