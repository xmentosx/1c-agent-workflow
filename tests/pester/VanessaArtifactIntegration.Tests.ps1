Describe "Workflow-pinned Vanessa Automation integration" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:RepoRoot = $context.RepoRoot
        $script:SourceHelperPath = $context.HelperPath
        $script:SavedSourceBuild = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
        $script:SavedArchiveOverride = [Environment]::GetEnvironmentVariable("VANESSA_AUTOMATION_ARCHIVE_URL", "Process")
        $script:SavedVanessaEnvironment = @{}
        foreach ($name in @("VANESSA_AUTOMATION_ROOT", "VANESSA_AUTOMATION_EPF", "VANESSA_AUTOMATION_VERSION", "VANESSA_AUTOMATION_DOWNSTREAM_REVISION", "VANESSA_FEATURES_PATH", "VANESSA_REPORTS_PATH")) {
            $script:SavedVanessaEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        $script:FixtureRoot = Join-Path $TestDrive "candidate"
        $script:FixtureContent = Join-Path $script:FixtureRoot "content"
        New-Item -ItemType Directory -Force -Path $script:FixtureContent | Out-Null
        $script:FixtureEpfPath = Join-Path $script:FixtureContent "vanessa-automation-single.epf"
        [System.IO.File]::WriteAllBytes($script:FixtureEpfPath, [System.Text.Encoding]::UTF8.GetBytes("qualified patched EPF fixture"))
        $script:FixtureNestedPath = Join-Path $script:FixtureContent "metadata\fixture.txt"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:FixtureNestedPath) | Out-Null
        [System.IO.File]::WriteAllText($script:FixtureNestedPath, "nested fixture", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $script:FixtureContent "LICENSE"), "license fixture", [System.Text.UTF8Encoding]::new($false))
        $script:FixtureArchivePath = Join-Path $script:FixtureRoot "vanessa-automation-single.1.2.043.28-itl-r7.zip"
        Compress-Archive -Path (Join-Path $script:FixtureContent "*") -DestinationPath $script:FixtureArchivePath
        $script:FixtureArchiveSha256 = (Get-FileHash -LiteralPath $script:FixtureArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:FixtureEpfSha256 = (Get-FileHash -LiteralPath $script:FixtureEpfPath -Algorithm SHA256).Hash.ToLowerInvariant()
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
            [System.IO.File]::WriteAllText((Join-Path $Root ".agent-1c\dependency-lock.json"), (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            return $HelperPath
        }
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:SavedSourceBuild, "Process")
        [Environment]::SetEnvironmentVariable("VANESSA_AUTOMATION_ARCHIVE_URL", $script:SavedArchiveOverride, "Process")
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
        $entry.version | Should -Be "1.2.043.28"
        $entry.compatibilityVersion | Should -Be "1.2.043.28"
        $entry.downstreamRevision | Should -Be "itl-r7"
        $entry.assetName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r7.zip"
        $entry.url | Should -Be "https://github.com/xmentosx/1c-agent-workflow/releases/download/vanessa-automation-v1.2.043.28-itl-r7/vanessa-automation-single.1.2.043.28-itl-r7.zip"
        $entry.sha256 | Should -Be "d96ac6e48578ac8b2dc65d645b1748bc5f6183c58bcd22987122dc8e45e19c1e"
        $entry.epfSha256 | Should -Be "d17b20bca54861b025256652a84dec18cdcc2d20b4a08932c5141054d7dc7f9f"
        $entry.manifestSha256 | Should -Be "f8dc93948bff574ecf51570227757ce0caa0c18f5c3b9c93174a8b381c79ad48"
        $entry.patchSha256 | Should -Be "b19fba2bccb0f997525cf92433a817e3d6d25a49ce16961319397bfba79bd25f"
        $entry.upstreamCommit | Should -Be "f3a01778a14d29b38204685deea0131274d438ff"
        $entry.publicationStatus | Should -Be "published"
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
        $result.version | Should -Be "1.2.043.28"
        $result.downstreamRevision | Should -Be "itl-r7"
        $result.epfSha256 | Should -Be $script:FixtureEpfSha256
        (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $testProjectPath ".dev.env") -Raw -Encoding UTF8) | Should -Match "VANESSA_AUTOMATION_DOWNSTREAM_REVISION=itl-r7"
        (Test-Path -LiteralPath (Join-Path $testProjectPath ".agent-1c\tools\va\metadata\fixture.txt")) | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $testProjectPath ".agent-1c\tools\va\LICENSE") -Raw -Encoding UTF8) | Should -Be "license fixture"
        (Get-Content -LiteralPath (Join-Path $testProjectPath ".agent-1c\tools\va\vanessa.epf") -Raw -Encoding UTF8) | Should -Be "qualified patched EPF fixture"
        (Test-Path -LiteralPath (Join-Path $testProjectPath ".tx")) | Should -BeFalse
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
        $result.downstreamRevision | Should -Be "itl-r7"
    }

    It "rejects archive and EPF mismatches without replacing an existing owned install" {
        $rollbackProjectPath = Join-Path $TestDrive "rollback-project"
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
        $archiveMismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helperPath -ProjectRoot $rollbackProjectPath -Action install-vanessa-automation 2>&1
        ($archiveMismatchOutput -join [Environment]::NewLine) | Should -Match "archive SHA256 mismatch"

        $lock.dependencies.vanessaAutomation.sha256 = $script:FixtureArchiveSha256
        $lock.dependencies.vanessaAutomation.epfSha256 = ("0" * 64)
        [System.IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

        $epfMismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helperPath -ProjectRoot $rollbackProjectPath -Action install-vanessa-automation 2>&1
        ($epfMismatchOutput -join [Environment]::NewLine) | Should -Match "EPF SHA256 mismatch"
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($existingEpf)) | Should -Be ([Convert]::ToBase64String($existingBytes))
        (Test-Path -LiteralPath (Join-Path $rollbackProjectPath ".tx")) | Should -BeFalse
    }
}
