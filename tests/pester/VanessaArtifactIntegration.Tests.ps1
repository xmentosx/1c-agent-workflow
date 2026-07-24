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
        $script:FixtureArchivePath = Join-Path $script:FixtureRoot "vanessa-automation-single.1.2.043.28-itl-r1.zip"
        Compress-Archive -LiteralPath $script:FixtureEpfPath -DestinationPath $script:FixtureArchivePath
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
    It "keeps compatibility, downstream revision, artifact provenance, and publication state separate" {
        $entry = (Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
        $entry.version | Should -Be "1.2.043.28"
        $entry.compatibilityVersion | Should -Be "1.2.043.28"
        $entry.downstreamRevision | Should -Be "itl-r1"
        $entry.assetName | Should -Be "vanessa-automation-single.1.2.043.28-itl-r1.zip"
        $entry.url | Should -Be "https://github.com/xmentosx/1c-agent-workflow/releases/download/vanessa-automation-v1.2.043.28-itl-r1/vanessa-automation-single.1.2.043.28-itl-r1.zip"
        $entry.sha256 | Should -Be "fae6ff06a66e5fa3fe315585ec5c5e678724edcd75fff97069f6dd224b86b9b6"
        $entry.epfSha256 | Should -Be "260605fd71adf1d2d354b8d1ce3ca7e2ce222db7c79d21f6cb44885aff1b5b80"
        $entry.manifestSha256 | Should -Be "6711c0373a60ec58d4adfb1d917a646f6a1ca8612c7492c5e97bcaf4b768aee3"
        $entry.patchSha256 | Should -Be "32455c8f917d098a1eb218c249790fadaf62bf2bda3470af2f71586ffd6168c3"
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
        $result.downstreamRevision | Should -Be "itl-r1"
        $result.epfSha256 | Should -Be $script:FixtureEpfSha256
        (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $testProjectPath ".dev.env") -Raw -Encoding UTF8) | Should -Match "VANESSA_AUTOMATION_DOWNSTREAM_REVISION=itl-r1"
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
        $result.downstreamRevision | Should -Be "itl-r1"
    }

    It "rejects archive and EPF mismatches without replacing an existing owned install" {
        $rollbackProjectPath = Join-Path $TestDrive "rollback-project"
        $helperPath = New-VanessaArtifactTestProject -Root $rollbackProjectPath
        $installRoot = Join-Path $rollbackProjectPath ".agent-1c\tools\vanessa-automation"
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        $existingEpf = Join-Path $installRoot "vanessa-automation-single.epf"
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
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $installRoot) -Directory -Filter "vanessa-automation.rollback-*").Count | Should -Be 0
    }
}
