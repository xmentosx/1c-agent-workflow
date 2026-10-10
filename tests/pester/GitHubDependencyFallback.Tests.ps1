Describe "GitHub dependency rate-limit fallback" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:RepoRoot = $context.RepoRoot
        $script:ProjectRoot = Join-Path $TestDrive "project"
        New-Item -ItemType Directory -Force -Path (Join-Path $script:ProjectRoot ".agent-1c") | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json")
        $script:ConfigPath = Join-Path $script:ProjectRoot ".agent-1c\project.json"
        $script:DependencyLockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
        $script:Config = [pscustomobject]@{ dependencyMode = "fresh" }
        $global:DependencyMode = "fresh"

        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1")
        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1")
        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1")
        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1")

        $script:SavedGitHubToken = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
        $script:SavedGhToken = [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process")
        $script:SavedVanessaSourceBuild = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", $script:SavedGitHubToken, "Process")
        [Environment]::SetEnvironmentVariable("GH_TOKEN", $script:SavedGhToken, "Process")
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $script:SavedVanessaSourceBuild, "Process")
    }

    AfterAll {
        Remove-Variable -Name DependencyMode -Scope Global -ErrorAction SilentlyContinue
    }

    It "keeps the programmatic default lock identical to the packaged baseline" {
        $template = Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $actual = [pscustomobject](New-DefaultDependencyLockManifest)

        ($actual | ConvertTo-Json -Depth 10) | Should -Be ($template | ConvertTo-Json -Depth 10)
    }

    It "prefers GITHUB_TOKEN over GH_TOKEN without exposing either token" {
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "primary-secret", "Process")
        [Environment]::SetEnvironmentVariable("GH_TOKEN", "secondary-secret", "Process")

        $headers = Get-GitHubApiHeaders
        $headers.Authorization | Should -Be "Bearer primary-secret"
        (Get-GitHubRateLimitRecoveryMessage -Operation "test operation" -FailureInfo ([pscustomobject]@{ reset = "" })) | Should -Not -Match "primary-secret|secondary-secret"
    }

    It "uses complete dependency-lock entries after a confirmed GitHub API rate limit" {
        Mock Invoke-RestMethod {
            $exception = [System.Exception]::new("API rate limit exceeded")
            $exception.Data["StatusCode"] = 403
            throw $exception
        }

        $lockPath = $script:DependencyLockPath
        $savedLock = [IO.File]::ReadAllBytes($lockPath)
        $manifest = Read-DependencyLockManifest
        # Published f5466e6ff98e95bae989a80d65809d1bff2bc31e retained this legacy API asset.
        # Only this entry belongs to the legacy request; the other two pins stay current.
        $manifest.dependencies.vanessaMcp.clientMcp = [pscustomobject]@{
            version = 'v0.6.5'
            assetName = 'client_mcp.cfe'
            url = 'https://github.com/1c-neurofish/onec-client-mcp-devkit/releases/download/v0.6.5/client_mcp.cfe'
            sha256 = 'd1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f'
            source = 'template baseline'
            updatedAt = '2026-05-26T19:34:34Z'
        }
        try {
            [IO.File]::WriteAllText($lockPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $roctup = Get-GitHubReleaseAssetInfo -Repository "ROCTUP/1c-mcp-toolkit" -AssetNameLike "MCP_Toolkit.epf" -OverrideEnvName "" -DefaultFileName "MCP_Toolkit.epf" -RetryCount 1
            $client = Get-GitHubReleaseAssetInfo -Repository "1c-neurofish/onec-client-mcp-devkit" -AssetNameLike "client_mcp.cfe" -OverrideEnvName "" -DefaultFileName "client_mcp.cfe" -RetryCount 1
            $extension = Get-GitHubReleaseAssetInfo -Repository "Pr-Mex/vanessa-automation" -AssetNameLike "VAExtension*.cfe" -OverrideEnvName "" -DefaultFileName "VAExtension.cfe" -RetryCount 1
            @($roctup, $client, $extension) | ForEach-Object {
                $_.source | Should -Be "dependency-lock rate-limit fallback"
                $_.expectedSha256 | Should -Match '^[a-f0-9]{64}$'
            }
            $roctup.name | Should -Be "MCP_Toolkit.epf"
            $client.name | Should -Be "client_mcp.cfe"
            $extension.name | Should -Be "VAExtension.1.32-itl-r4.cfe"
            $extension.expectedSha256 | Should -Be "24190cb07ad82ac49aacdd86c1fb6412cd2f6713758cde123b1bb4103b7b4c0c"
            $client.version | Should -BeExactly 'v0.6.5'
            $client.url | Should -BeExactly 'https://github.com/1c-neurofish/onec-client-mcp-devkit/releases/download/v0.6.5/client_mcp.cfe'
            $client.expectedSha256 | Should -BeExactly 'd1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f'
        } finally {
            [IO.File]::WriteAllBytes($lockPath, $savedLock)
        }
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) | Should -BeExactly ([Convert]::ToBase64String($savedLock))
    }

    It "does not borrow the current owned client asset for a rate-limited legacy asset request" {
        $lockPath = $script:DependencyLockPath
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))
        $current = (Read-DependencyLockManifest).dependencies.vanessaMcp.clientMcp
        $current.assetName | Should -BeExactly 'client_mcp.v0.6.5-itl-r1.cfe'
        $current.sha256 | Should -Match '^[a-f0-9]{64}$'
        Mock Invoke-RestMethod {
            $exception = [System.Exception]::new("API rate limit exceeded")
            $exception.Data["StatusCode"] = 403
            throw $exception
        }

        {
            Get-GitHubReleaseAssetInfo -Repository "1c-neurofish/onec-client-mcp-devkit" -AssetNameLike "client_mcp.cfe" -OverrideEnvName "" -DefaultFileName "client_mcp.cfe" -RetryCount 1
        } | Should -Throw '*GitHub API rate limit reached while resolving GitHub release asset 1c-neurofish/onec-client-mcp-devkit/client_mcp.cfe*complete compatible dependency lock*'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) | Should -BeExactly $before
    }

    It "uses the immutable workflow-pinned Vanessa asset without a mutable publication flag or releases-latest query" {
        Mock Invoke-RestMethod { throw "must not query GitHub" }
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $null, "Process")

        $lockPath = Join-Path $RepoRoot "templates\dependency-lock.json"
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.dependencies.vanessaAutomation.PSObject.Properties.Name | Should -Not -Contain "publicationStatus"
        $download = Get-VanessaAutomationDownloadInfo
        $download.source | Should -Be "workflow-pinned"
        $download.url | Should -Be "https://github.com/xmentosx/1c-agent-workflow/releases/download/vanessa-automation-v1.2.043.42-itl-r4/vanessa-automation-single.1.2.043.42-itl-r4.zip"
        $download.expectedSha256 | Should -Be "84aabfbf77511abd432c235625afb543aa3c182654e08a24bda3c4312c7d5f4c"
        Assert-MockCalled Invoke-RestMethod -Times 0
    }

    It "fails closed before a Vanessa run when the source-build archive differs from the active project pin" {
        $archivePath = Join-Path $TestDrive "wrong-vanessa-candidate.zip"
        [System.IO.File]::WriteAllBytes($archivePath, [System.Text.Encoding]::UTF8.GetBytes("wrong candidate"))
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $archivePath, "Process")
        Mock Get-VanessaAutomationDownloadInfo {
            return [pscustomobject]@{ expectedSha256 = ("0" * 64) }
        }

        { Assert-VanessaSourceBuildArchiveMatchesActivePin } |
            Should -Throw "*ITL_VANESSA_SOURCE_BUILD_SHA_MISMATCH*"
    }

    It "accepts the exact source-build archive selected by the active project pin" {
        $archivePath = Join-Path $TestDrive "exact-vanessa-candidate.zip"
        [System.IO.File]::WriteAllBytes($archivePath, [System.Text.Encoding]::UTF8.GetBytes("exact candidate"))
        $archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [Environment]::SetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", $archivePath, "Process")
        Mock Get-VanessaAutomationDownloadInfo {
            return [pscustomobject]@{ expectedSha256 = $archiveSha256 }
        }

        { Assert-VanessaSourceBuildArchiveMatchesActivePin } | Should -Not -Throw
    }

    It "does not use the lock for a non-rate-limit API failure" {
        Mock Invoke-RestMethod {
            $exception = [System.Exception]::new("Not Found")
            $exception.Data["StatusCode"] = 404
            throw $exception
        }

        {
            Get-GitHubReleaseAssetInfo -Repository "ROCTUP/1c-mcp-toolkit" -AssetNameLike "MCP_Toolkit.epf" -OverrideEnvName "" -DefaultFileName "MCP_Toolkit.epf" -RetryCount 1
        } | Should -Throw "*Could not resolve GitHub release asset*"
    }

    It "keeps the baseline lock unchanged after a fallback artifact download" {
        $lockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
        $before = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
        $sourcePath = Join-Path $TestDrive "roctup-source.epf"
        [System.IO.File]::WriteAllBytes($sourcePath, [System.Text.Encoding]::UTF8.GetBytes("fallback artifact"))
        $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $asset = [pscustomobject]@{
            url = $sourcePath
            name = "MCP_Toolkit.epf"
            version = "test"
            expectedSha256 = $hash
            source = "dependency-lock rate-limit fallback"
        }

        Save-RoctupMcpArtifact -AssetInfo $asset | Out-Null

        (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
    }

    It "rejects a SHA256 mismatch for a fallback artifact" {
        $sourcePath = Join-Path $TestDrive "bad-roctup-source.epf"
        [System.IO.File]::WriteAllBytes($sourcePath, [System.Text.Encoding]::UTF8.GetBytes("wrong artifact"))
        $asset = [pscustomobject]@{
            url = $sourcePath
            name = "MCP_Toolkit.epf"
            version = "test"
            expectedSha256 = ("0" * 64)
            source = "dependency-lock rate-limit fallback"
        }

        { Save-RoctupMcpArtifact -AssetInfo $asset } | Should -Throw "*SHA256 mismatch*"
    }

    It "keeps the tracked lock byte-identical when acquiring the same verified ROCTUP pin from <priorSource>" -TestCases @(
        @{ priorSource = 'template baseline' }
        @{ priorSource = 'compatibility-manifest' }
    ) {
        param($priorSource)
        $lockPath = Join-Path $script:ProjectRoot '.agent-1c\dependency-lock.json'
        $savedLock = [IO.File]::ReadAllBytes($lockPath)
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $artifactRoot = Join-Path $TestDrive ('ROCTUP source ' + $nonAsciiWord + ' ' + [guid]::NewGuid().ToString('N'))
        $installRoot = Join-Path $artifactRoot ('Artifact cache ' + $nonAsciiWord)
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $sourcePath = Join-Path $artifactRoot 'MCP_Toolkit.epf'
        [IO.File]::WriteAllBytes($sourcePath, [Text.Encoding]::UTF8.GetBytes('exact pinned ROCTUP payload'))
        $sha256 = (Get-FileHash -LiteralPath $sourcePath).Hash.ToLowerInvariant()
        $manifest = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.dependencies.roctupMcpToolkit = [pscustomobject]@{
            version='v1.7.1'; assetName='MCP_Toolkit.epf'; url=$sourcePath; sha256=$sha256
            source=$priorSource; updatedAt='original qualification time'
        }
        [IO.File]::WriteAllText($lockPath, (($manifest | ConvertTo-Json -Depth 20) + "`r`n"), [Text.UTF8Encoding]::new($true))
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))
        Mock Get-RoctupMcpInstallRoot { $installRoot }
        try {
            $asset = [pscustomobject]@{url=$sourcePath; name='MCP_Toolkit.epf'; version='v1.7.1'; expectedSha256=$sha256; source='compatibility-manifest'}
            $result = Save-RoctupMcpArtifact -AssetInfo $asset
            $result.sha256 | Should -BeExactly $sha256
            (Get-FileHash -LiteralPath $result.path).Hash.ToLowerInvariant() | Should -BeExactly $sha256
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) | Should -BeExactly $before
        } finally {
            [IO.File]::WriteAllBytes($lockPath, $savedLock)
        }
    }

    It "records a materially changed verified ROCTUP artifact pin" {
        $lockPath = Join-Path $script:ProjectRoot '.agent-1c\dependency-lock.json'
        $savedLock = [IO.File]::ReadAllBytes($lockPath)
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $artifactRoot = Join-Path $TestDrive ('ROCTUP new source ' + $nonAsciiWord + ' ' + [guid]::NewGuid().ToString('N'))
        $installRoot = Join-Path $artifactRoot ('Artifact cache ' + $nonAsciiWord)
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $sourcePath = Join-Path $artifactRoot 'MCP_Toolkit.epf'
        [IO.File]::WriteAllBytes($sourcePath, [Text.Encoding]::UTF8.GetBytes('new verified ROCTUP payload'))
        $sha256 = (Get-FileHash -LiteralPath $sourcePath).Hash.ToLowerInvariant()
        Mock Get-RoctupMcpInstallRoot { $installRoot }
        try {
            $asset = [pscustomobject]@{url=$sourcePath; name='MCP_Toolkit.epf'; version='test-new-pin'; expectedSha256=$sha256; source='explicit new pin'}
            $result = Save-RoctupMcpArtifact -AssetInfo $asset
            $actual = (Read-DependencyLockManifest).dependencies.roctupMcpToolkit
            $actual.version | Should -BeExactly 'test-new-pin'
            $actual.url | Should -BeExactly $sourcePath
            $actual.sha256 | Should -BeExactly $sha256
            $actual.source | Should -BeExactly 'explicit new pin'
            $actual.updatedAt | Should -Not -BeNullOrEmpty
            (Get-FileHash -LiteralPath $result.path).Hash.ToLowerInvariant() | Should -BeExactly $sha256
        } finally {
            [IO.File]::WriteAllBytes($lockPath, $savedLock)
        }
    }

    It "routes ROCTUP skills through the shared authenticated GitHub API helper" {
        $roctupText = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1") -Raw -Encoding UTF8
        $roctupText | Should -Match 'Invoke-GitHubApiRestMethod -Uri \$uri'
        $roctupText | Should -Match "provide a platform-specific roctupMcpToolkit lock entry"
    }
}
