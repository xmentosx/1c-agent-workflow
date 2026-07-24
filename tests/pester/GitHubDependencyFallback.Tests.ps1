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

        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1")
        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1")
        . (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1")

        $script:SavedGitHubToken = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
        $script:SavedGhToken = [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process")
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", $script:SavedGitHubToken, "Process")
        [Environment]::SetEnvironmentVariable("GH_TOKEN", $script:SavedGhToken, "Process")
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

        $roctup = Get-GitHubReleaseAssetInfo -Repository "ROCTUP/1c-mcp-toolkit" -AssetNameLike "MCP_Toolkit.epf" -OverrideEnvName "" -DefaultFileName "MCP_Toolkit.epf" -RetryCount 1
        $client = Get-GitHubReleaseAssetInfo -Repository "1c-neurofish/onec-client-mcp-devkit" -AssetNameLike "client_mcp.cfe" -OverrideEnvName "" -DefaultFileName "client_mcp.cfe" -RetryCount 1
        $extension = Get-GitHubReleaseAssetInfo -Repository "Pr-Mex/vanessa-automation" -AssetNameLike "VAExtension*.cfe" -OverrideEnvName "" -DefaultFileName "VAExtension.cfe" -RetryCount 1
        @($roctup, $client, $extension) | ForEach-Object {
            $_.source | Should -Be "dependency-lock rate-limit fallback"
            $_.expectedSha256 | Should -Match '^[a-f0-9]{64}$'
        }
        $roctup.name | Should -Be "MCP_Toolkit.epf"
        $client.name | Should -Be "client_mcp.cfe"
        $extension.name | Should -Be "VAExtension.1.29.cfe"
    }

    It "never resolves Vanessa Automation through releases latest even in fresh mode" {
        Mock Invoke-RestMethod { throw "must not query GitHub" }

        { Get-VanessaAutomationDownloadInfo } | Should -Throw "*ITL_VANESSA_ARTIFACT_NOT_PUBLISHED*"
        Assert-MockCalled Invoke-RestMethod -Times 0
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

    It "routes ROCTUP skills through the shared authenticated GitHub API helper" {
        $roctupText = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1") -Raw -Encoding UTF8
        $roctupText | Should -Match 'Invoke-GitHubApiRestMethod -Uri \$uri'
        $roctupText | Should -Match "provide a platform-specific roctupMcpToolkit lock entry"
    }
}
