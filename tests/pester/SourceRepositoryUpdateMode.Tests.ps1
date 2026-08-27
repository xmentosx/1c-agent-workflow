$ErrorActionPreference = "Stop"

BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $script:RepoRoot = $context.RepoRoot
    $script:HelperPath = $context.HelperPath
}

Describe "Source repository update mode" {
    It "changes the local mode only from master and reports it" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-repository-mode-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            [IO.File]::WriteAllText(
                (Join-Path $tempRoot ".agent-1c\project.json"),
                '{"masterBranch":"master","sourceUsesRepository":true,"sourceRepositoryUpdateMode":"workflow"}',
                [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot ".dev.env"), "SOURCE_USES_REPOSITORY=true`n", [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master

            $changed = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action itl-repository-mode -Mode external 2>&1
            $LASTEXITCODE | Should -Be 0
            ($changed -join "`n") | Should -Match "Source repository update mode changed: external"
            Get-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Raw | Should -Match '(?m)^SOURCE_REPOSITORY_UPDATE_MODE=external\r?$'

            $status = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action itl-repository-mode -Mode status 2>&1
            $LASTEXITCODE | Should -Be 0
            ($status -join "`n") | Should -Match "SOURCE_REPOSITORY_UPDATE_MODE=external"

            & git -C $tempRoot branch -M itldev/mode-test
            $blocked = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action itl-repository-mode -Mode workflow 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($blocked -join "`n") | Should -Match "must be run from the 'master' worktree"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "skips every source repository mutation in external mode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-SourceUsesRepository { return $true }
            function Get-SourceRepositoryUpdateMode { return "external" }
            function Invoke-Designer { $script:designerCalls++ }
            $script:designerCalls = 0
            $updated = Update-BaseFromRepository
            [pscustomobject]@{ updated = $updated; designerCalls = $script:designerCalls }
        }

        $result.updated | Should -BeFalse
        $result.designerCalls | Should -Be 0
    }

    It "keeps the existing repository update contract in workflow mode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-SourceUsesRepository { return $true }
            function Get-SourceRepositoryUpdateMode { return "workflow" }
            function New-RepositoryConnectionArgs { return @("/ConfigurationRepositoryF", "repo") }
            function Get-SourceInfoBasePath { return "C:\source base" }
            function Get-InfoBaseKind { return "file" }
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:designerCall = [pscustomobject]@{ path = $InfoBasePath; kind = $InfoBaseKind; args = @($DesignerArgs) }
            }
            $script:designerCall = $null
            $updated = Update-BaseFromRepository
            [pscustomobject]@{ updated = $updated; call = $script:designerCall }
        }

        $result.updated | Should -BeTrue
        $result.call.path | Should -Be "C:\source base"
        @($result.call.args) | Should -Contain "/ConfigurationRepositoryUpdateCfg"
        @($result.call.args) | Should -Contain "/UpdateDBCfg"
    }

    It "fails closed on an unknown configured mode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-Setting { return "surprise" }
            try {
                Get-SourceRepositoryUpdateMode
            } catch {
                $_.Exception.Message
            }
        }
        $result | Should -Match "SOURCE_REPOSITORY_UPDATE_MODE_INVALID"
    }

    It "keeps repository topology independent from update ownership" {
        $seedText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.seed.ps1") -Raw
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw
        $seedText | Should -Match '(?s)function Disconnect-BranchSeedFileFromRepository.*?Get-SourceUsesRepository.*?/ConfigurationRepositoryUnbindCfg'
        $lifecycleText | Should -Match '\$branchCopyMayUseRepository = \$sourceUsesRepository -or \$configuredSourceUsesRepository'
        $lifecycleText | Should -Not -Match '\$branchCopyMayUseRepository\s*=.*SourceRepositoryUpdateMode'
    }
}
