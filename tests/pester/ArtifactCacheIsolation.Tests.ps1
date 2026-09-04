Describe "Immutable workflow artifact cache isolation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:RepoRoot = $context.RepoRoot
        $script:HelperPath = $context.HelperPath
        $script:SavedArtifactCacheEnvironment = @{}
        foreach ($name in @("ITL_ARTIFACT_CACHE_ROOT", "DEPENDENCY_MODE", "ROCTUP_MCP_TOOLKIT_EPF", "ROCTUP_MCP_VERSION", "ROCTUP_MCP_SHA256")) {
            $script:SavedArtifactCacheEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }
    }

    AfterEach {
        foreach ($name in @($script:SavedArtifactCacheEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedArtifactCacheEnvironment[$name], "Process")
        }
    }

    It "derives Vanessa and ROCTUP locations from branch-local lock identity outside the project" {
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $projectRoot = Join-Path $TestDrive "Branch project $nonAsciiWord with space"
        $cacheRoot = Join-Path $TestDrive "Shared cache $nonAsciiWord with space"
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c") | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\project.json") -Destination (Join-Path $projectRoot ".agent-1c\project.json")
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $projectRoot ".agent-1c\dependency-lock.json")
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", $cacheRoot, "Process")

        $paths = & {
            . $script:HelperPath -ProjectRoot $projectRoot -Action help *> $null
            $definitions = @(Get-VanessaMcpArtifactDefinitions)
            [pscustomobject]@{
                vanessa = Get-VanessaInstallRoot
                roctup = Get-RoctupMcpInstallRoot
                clientMcp = Get-VanessaMcpManagedArtifactPath -Definition @($definitions | Where-Object { $_.lockKey -eq "clientMcp" })[0]
                vaExtension = Get-VanessaMcpManagedArtifactPath -Definition @($definitions | Where-Object { $_.lockKey -eq "vaExtension" })[0]
                siblingLegacyIsManaged = Test-ItlPathUnderManagedProjectTools -Path (Join-Path $TestDrive "Sibling branch $nonAsciiWord with space\.agent-1c\tools\va\vanessa.epf")
            }
        }

        $resolvedCacheRoot = [System.IO.Path]::GetFullPath($cacheRoot).TrimEnd("\") + "\"
        foreach ($path in @($paths.vanessa, $paths.roctup, $paths.clientMcp, $paths.vaExtension)) {
            $path.StartsWith($resolvedCacheRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            $path | Should -Not -Match ([regex]::Escape((Join-Path $projectRoot ".agent-1c\tools")))
        }
        $paths.roctup | Should -Match "roctup-mcp-toolkit"
        $paths.clientMcp | Should -Match "vanessa-mcp-clientMcp"
        $paths.vaExtension | Should -Match "vanessa-mcp-vaExtension"
        $paths.siblingLegacyIsManaged | Should -BeTrue
    }

    It "imports an exact legacy ROCTUP EPF and rewrites the branch binding" {
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $projectRoot = Join-Path $TestDrive "Migration branch $nonAsciiWord with space"
        $cacheRoot = Join-Path $TestDrive "Migration cache $nonAsciiWord with space"
        $legacyRoot = Join-Path $projectRoot ".agent-1c\tools\roctup-mcp-toolkit"
        New-Item -ItemType Directory -Force -Path $legacyRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\project.json") -Destination (Join-Path $projectRoot ".agent-1c\project.json")
        $lock = Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $legacyEpf = Join-Path $legacyRoot ([string]$lock.dependencies.roctupMcpToolkit.assetName)
        [System.IO.File]::WriteAllText($legacyEpf, "legacy ROCTUP fixture", [System.Text.UTF8Encoding]::new($false))
        $expectedSha256 = (Get-FileHash -LiteralPath $legacyEpf -Algorithm SHA256).Hash.ToLowerInvariant()
        $lock.dependencies.roctupMcpToolkit.sha256 = $expectedSha256
        $lock.dependencies.roctupMcpToolkit.url = ([System.Uri]$legacyEpf).AbsoluteUri
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".agent-1c\dependency-lock.json"), (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".dev.env"), "DEPENDENCY_MODE=locked`r`nROCTUP_MCP_TOOLKIT_EPF=$legacyEpf`r`n", [System.Text.UTF8Encoding]::new($false))
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", $cacheRoot, "Process")

        $result = & {
            . $script:HelperPath -ProjectRoot $projectRoot -Action help *> $null
            function Install-RoctupMcpSkillsBestEffort {}
            $artifact = Install-RoctupMcpArtifact
            [pscustomobject]@{
                artifact = $artifact
                dotEnv = Get-Content -LiteralPath (Join-Path $projectRoot ".dev.env") -Raw -Encoding UTF8
            }
        }

        $result.artifact.path | Should -Not -Be $legacyEpf
        $result.artifact.path | Should -Match ("^" + [regex]::Escape([System.IO.Path]::GetFullPath($cacheRoot)))
        (Get-FileHash -LiteralPath $result.artifact.path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $expectedSha256
        $result.dotEnv | Should -Match ("(?m)^ROCTUP_MCP_TOOLKIT_EPF=" + [regex]::Escape($result.artifact.path) + "\r?$")
        (Test-Path -LiteralPath $legacyEpf -PathType Leaf) | Should -BeTrue
    }

    It "replaces a corrupt shared ROCTUP artifact from the pinned source" {
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $projectRoot = Join-Path $TestDrive "Repair project $nonAsciiWord with space"
        $cacheRoot = Join-Path $TestDrive "Repair cache $nonAsciiWord with space"
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), $cacheRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\project.json") -Destination (Join-Path $projectRoot ".agent-1c\project.json")
        $lock = Get-Content -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceEpf = Join-Path $TestDrive "Pinned source $nonAsciiWord.epf"
        [System.IO.File]::WriteAllText($sourceEpf, "exact pinned ROCTUP artifact", [System.Text.UTF8Encoding]::new($false))
        $expectedSha256 = (Get-FileHash -LiteralPath $sourceEpf -Algorithm SHA256).Hash.ToLowerInvariant()
        $lock.dependencies.roctupMcpToolkit.sha256 = $expectedSha256
        $lock.dependencies.roctupMcpToolkit.url = ([System.Uri]$sourceEpf).AbsoluteUri
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".agent-1c\dependency-lock.json"), (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", $cacheRoot, "Process")

        $result = & {
            . $script:HelperPath -ProjectRoot $projectRoot -Action help *> $null
            function Install-RoctupMcpSkillsBestEffort {}
            $corruptPath = Join-Path (Get-RoctupMcpInstallRoot) (Get-RoctupMcpAssetName)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $corruptPath) | Out-Null
            [System.IO.File]::WriteAllText($corruptPath, "corrupt cached bytes", [System.Text.UTF8Encoding]::new($false))
            $artifact = Install-RoctupMcpArtifact
            [pscustomobject]@{ artifact = $artifact; corruptPath = $corruptPath }
        }

        $result.artifact.path | Should -Be $result.corruptPath
        (Get-FileHash -LiteralPath $result.artifact.path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $expectedSha256
        [System.IO.File]::ReadAllText($result.artifact.path, [System.Text.Encoding]::UTF8) | Should -Be "exact pinned ROCTUP artifact"
    }

    It "does not reuse stale bindings from another version in the shared cache" {
        $nonAsciiWord = "$([char]0x0422)$([char]0x0435)$([char]0x0441)$([char]0x0442)"
        $projectRoot = Join-Path $TestDrive "Updated branch $nonAsciiWord with space"
        $cacheRoot = Join-Path $TestDrive "Versioned cache $nonAsciiWord with space"
        $oldRoot = Join-Path $cacheRoot ("old-family\0.0.1\" + ("a" * 64))
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), $oldRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\project.json") -Destination (Join-Path $projectRoot ".agent-1c\project.json")
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $projectRoot ".agent-1c\dependency-lock.json")
        $oldVanessa = Join-Path $oldRoot "vanessa.epf"
        $oldRoctup = Join-Path $oldRoot "MCP_Toolkit.epf"
        $oldClient = Join-Path $oldRoot "client_mcp.cfe"
        foreach ($path in @($oldVanessa, $oldRoctup, $oldClient)) {
            [System.IO.File]::WriteAllText($path, "old version", [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".dev.env"), @"
VANESSA_AUTOMATION_EPF=$oldVanessa
ROCTUP_MCP_TOOLKIT_EPF=$oldRoctup
VANESSA_MCP_CLIENT_CFE_PATH=$oldClient
"@, [System.Text.UTF8Encoding]::new($false))
        [Environment]::SetEnvironmentVariable("ITL_ARTIFACT_CACHE_ROOT", $cacheRoot, "Process")

        $resolved = & {
            . $script:HelperPath -ProjectRoot $projectRoot -Action help *> $null
            $clientDefinition = @(Get-VanessaMcpArtifactDefinitions | Where-Object { $_.lockKey -eq "clientMcp" })[0]
            [pscustomobject]@{
                vanessa = Get-VanessaAutomationEpfPath
                roctup = Find-RoctupMcpEpf
                clientMcp = Find-VanessaMcpCachedArtifactPath -Definition $clientDefinition
            }
        }

        $resolved.vanessa | Should -BeNullOrEmpty
        $resolved.roctup | Should -BeNullOrEmpty
        $resolved.clientMcp | Should -BeNullOrEmpty
    }
}
