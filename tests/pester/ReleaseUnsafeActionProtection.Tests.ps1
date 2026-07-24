BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $RunnerPath = Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"
}

Describe "Release E2E unsafe action protection preflight" {
    It "fails before helper work when confirmation is false, missing, or from another context" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-unsafe-preflight-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreeRoot = Join-Path $tempRoot "worktree"
        $aiRulesRoot = Join-Path $tempRoot "ai-rules"
        $helperPath = Join-Path $tempRoot "fake-helper.ps1"
        $statePath = Join-Path $mainRoot ".agent-1c\dev-branches\workflow-release-e2e.json"
        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, $aiRulesRoot | Out-Null
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.invalid"
            & git -C $mainRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/`nbuild/`n"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding ASCII -Value "fixture"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m "fixture" *> $null
            & git -C $mainRoot branch -M master
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & git -C $mainRoot worktree add -b "itldev/workflow-release-e2e" $worktreeRoot *> $null
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $LASTEXITCODE | Should -Be 0

            $sourceSnapshot = Join-Path $mainRoot ".agent-1c\infobases\source-snapshot"
            New-Item -ItemType Directory -Force -Path $sourceSnapshot, (Split-Path -Parent $statePath) | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceSnapshot "1Cv8.1CD") -Encoding ASCII -Value "fixture infobase"
            Set-Content -LiteralPath (Join-Path $mainRoot ".dev.env") -Encoding UTF8 -Value "SOURCE_INFOBASE_PATH=$sourceSnapshot"
            $config = [ordered]@{ schemaVersion = 1; devBranchName = "workflow-release-e2e"; worktreePath = $worktreeRoot }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\release-e2e.json") -Encoding UTF8 -Value ($config | ConvertTo-Json)
            Set-Content -LiteralPath $helperPath -Encoding ASCII -Value 'throw "helper must not run before unsafe-action preflight"'

            foreach ($confirmation in @($false, $null)) {
                $state = [ordered]@{
                    devBranchName = "workflow-release-e2e"
                    devBranch = "itldev/workflow-release-e2e"
                    worktreePath = $worktreeRoot
                }
                if ($null -ne $confirmation) { $state["unsafeActionProtectionConfirmed"] = $confirmation }
                Set-Content -LiteralPath $statePath -Encoding UTF8 -Value ($state | ConvertTo-Json)
                $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash

                $result = Invoke-TestPowerShellFile -FilePath $RunnerPath -Arguments @(
                    "-ProjectRoot", $mainRoot,
                    "-AiRulesSource", $aiRulesRoot,
                    "-HelperPath", $helperPath,
                    "-OutputPath", (Join-Path $tempRoot "summary.json")
                )

                $result.exitCode | Should -Not -Be 0
                $result.combinedText | Should -Match "RELEASE_E2E_UNSAFE_ACTION_PROTECTION_UNCONFIRMED"
                $result.combinedText | Should -Match "configure-dev-branch-unsafe-action-protection"
                $result.combinedText | Should -Match "does not confirm automatically or edit state/conf\.cfg"
                (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should -Be $beforeHash
                Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\runs\release-e2e") | Should -BeFalse
            }

            $wrongContextState = [ordered]@{
                devBranchName = "workflow-release-e2e"
                devBranch = "itldev/workflow-release-e2e"
                worktreePath = Join-Path $tempRoot "another-worktree"
                unsafeActionProtectionConfirmed = $true
            }
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value ($wrongContextState | ConvertTo-Json)
            $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
            $result = Invoke-TestPowerShellFile -FilePath $RunnerPath -Arguments @(
                "-ProjectRoot", $mainRoot,
                "-AiRulesSource", $aiRulesRoot,
                "-HelperPath", $helperPath,
                "-OutputPath", (Join-Path $tempRoot "summary.json")
            )
            $result.exitCode | Should -Not -Be 0
            $result.combinedText | Should -Match "RELEASE_E2E_BRANCH_STATE_CONTEXT_MISMATCH"
            $result.combinedText | Should -Match "Refusing to use state from another context"
            (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should -Be $beforeHash
            Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\runs\release-e2e") | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $mainRoot -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $mainRoot worktree remove --force $worktreeRoot *> $null
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a confirmed state from another worktree context" {
        $text = Get-Content -LiteralPath $RunnerPath -Raw -Encoding UTF8
        $brokerText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1") -Raw -Encoding UTF8
        $text | Should -Match "RELEASE_E2E_BRANCH_STATE_CONTEXT_MISMATCH"
        $text | Should -Match '\$stateWorktree\.Equals\(\$expectedWorktree'
        $text.IndexOf("[void](Assert-E2EUnsafeActionProtectionConfirmed)") |
            Should -BeLessThan $text.IndexOf('[void](Sync-E2EWorktreeFromMaster)')
        $text.IndexOf("[void](Assert-E2EUnsafeActionProtectionConfirmed)") |
            Should -BeLessThan $text.IndexOf('Invoke-E2EInfobaseSnapshot -Path $baselineSnapshotPath')
        $brokerText | Should -Match "ITL_VANESSA_UNSAFE_ACTION_PROTECTION_UNCONFIRMED"
    }
}
