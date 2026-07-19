Describe "Vanessa authoring gate" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    }

    It "places authoring preflight before base update and exposes the exact MCP schema" {
        $lifecycle = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $match = [regex]::Match($lifecycle, '(?s)function Invoke-DevBranchCheck \{(?<body>.*?)\n\}')
        $match.Success | Should -BeTrue
        $match.Groups['body'].Value.IndexOf('Assert-VanessaAuthoringPreflight') | Should -BeLessThan $match.Groups['body'].Value.IndexOf('Update-DevBranchBase')
        $match.Groups['body'].Value | Should -Match 'Stop-ItlOnDemandBackends'
        $vanessa = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $prepare = [regex]::Match($vanessa, '(?s)function Prepare-VanessaAuthoring \{(?<body>.*?)\n\}')
        $prepare.Groups['body'].Value.IndexOf('Update-DevBranchBase') | Should -BeLessThan $prepare.Groups['body'].Value.IndexOf('Write-ItlOnDemandMcpClientConfig')
        $prepare.Groups['body'].Value | Should -Not -Match 'Start-VanessaMcp'
        $prepare.Groups['body'].Value | Should -Match 'Phase "ready"'
        $command = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-vanessa-author.md.template") -Raw -Encoding UTF8
        foreach ($name in @('search_name','search_description','search_type','exclude_name','exclude_description','exclude_type','limit')) { $command | Should -Match $name }
        $command | Should -Match 'never invent `keywords`'
        $command | Should -Match 'Never call.*raw HTTP'
    }

    It "does not classify runMcp as a final Vanessa test process" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                mcp = Test-OneCVanessaTestProcess -ProcessInfo ([pscustomobject]@{ commandLine = '1cv8.exe /TESTMANAGER /CrunMcp;mcpPort=48123' })
                runner = Test-OneCVanessaTestProcess -ProcessInfo ([pscustomobject]@{ commandLine = '1cv8.exe /TESTMANAGER /CStartFeaturePlayer;VAParams=x' })
            }
        }
        $result.mcp | Should -BeFalse
        $result.runner | Should -BeTrue
    }

    It "installs only Core and the selected edition while preserving Product" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-libraries-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot "tests\features\Libraries\Product") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM4","testsPath":"tests/features"}'
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\Product\keep.feature") -Encoding UTF8 -Value '#language: ru'
            & git -C $tempRoot init *> $null
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlVanessaLibraries }
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\ITL\Core\NavigationLinks.feature") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\ITL\PM4\README.md") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\ITL\PM5") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\Product\keep.feature") | Should -BeTrue
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}'
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlVanessaLibraries }
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\ITL\PM4") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\ITL\PM5\README.md") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $tempRoot "tests\features\Libraries\Product\keep.feature") | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps latest-master reference suites edition-safe and unpinned" {
        $registry = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\assets\vanessa-reference-suites.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.refreshPolicy | Should -Be "latest-master"
        $registry.suites.PM4.branch | Should -Be "master"
        $registry.suites.PM5.branch | Should -Be "master"
        ($registry | ConvertTo-Json -Depth 6) | Should -Not -Match '(?i)commit|[0-9a-f]{40}'
    }

    It "invalidates a pass when a changed feature hash changes in a Cyrillic worktree" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-$([char]0x0422)-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot "tests\features") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","masterBranch":"master","testsPath":"tests/features"}'
            $feature = Join-Path $tempRoot ("tests\features\$([char]0x0424).feature")
            Set-Content -LiteralPath $feature -Encoding UTF8 -Value "Feature: Check`n"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot config core.safecrlf false
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m baseline *> $null
            & git -C $tempRoot switch -q -c itldev/demo
            Add-Content -LiteralPath $feature -Encoding UTF8 -Value "Scenario: First"
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $records = @(Get-VanessaAuthoringFeatureRecords)
                $authoring = New-VanessaAuthoringState -Phase 'passed' -FeatureRecords $records -LibraryFingerprint ''
                $authoring.catalogSha256 = (Get-ItlOnDemandMcpFamilyDefinition -Family 'vanessa-ui').catalogSha256
                $authoring.passedAt = (Get-Date).ToString('o')
                Write-VanessaAuthoringState -State $authoring *> $null
                Assert-VanessaAuthoringPreflight -Trigger command
                Add-Content -LiteralPath $feature -Encoding UTF8 -Value "`tGiven changed"
                try { Assert-VanessaAuthoringPreflight -Trigger command; 'not-invalidated' } catch { $_.Exception.Message }
            }
            $result | Should -Match 'missing or stale'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "records final feature hashes after edits made during authoring" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-authoring-complete-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches"), (Join-Path $tempRoot "tests\features") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","masterBranch":"master","testsPath":"tests/features"}'
            $feature = Join-Path $tempRoot "tests\features\check.feature"
            Set-Content -LiteralPath $feature -Encoding UTF8 -Value "Feature: Check`n"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m baseline *> $null
            & git -C $tempRoot switch -q -c itldev/demo
            $state = [ordered]@{ devBranchName='demo'; safeDevBranchName='demo'; devBranch='itldev/demo'; devBranchKind='configuration'; worktreePath=$tempRoot; devBranchInfoBasePath=(Join-Path $tempRoot '.agent-1c\infobases\demo') }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\demo.json") -Encoding UTF8 -Value ($state | ConvertTo-Json)
            Add-Content -LiteralPath $feature -Encoding UTF8 -Value "Scenario: Draft"
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $catalogSha256 = (Get-ItlOnDemandMcpFamilyDefinition -Family 'vanessa-ui').catalogSha256
                $prepared = New-VanessaAuthoringState -Phase 'ready' -FeatureRecords @(Get-VanessaAuthoringFeatureRecords) -LibraryFingerprint ''
                $prepared.catalogSha256 = $catalogSha256
                $prepared.PSObject.Properties.Name | Should -Not -Contain 'mcpPid'
                $prepared.PSObject.Properties.Name | Should -Contain 'backendEvidence'
                Write-VanessaAuthoringState -State $prepared *> $null
                $evidenceRoot = Join-Path (Get-ItlOnDemandRuntimeRoot) 'vanessa-ui'
                New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
                [ordered]@{ schemaVersion=1; family='vanessa-ui'; instanceId='fixture'; backendVersion='fixture'; catalogSha256=$catalogSha256; tool='run_scenario'; succeededAt=(Get-Date).AddSeconds(1).ToUniversalTime().ToString('o') } |
                    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $evidenceRoot 'fixture.evidence.jsonl') -Encoding UTF8
                Add-Content -LiteralPath $feature -Encoding UTF8 -Value "`tGiven final edit"
                function Stop-ItlOnDemandBackends { }
                Complete-VanessaAuthoring -Result passed
                $final = Read-VanessaAuthoringState
                [pscustomobject]@{ phase=$final.phase; matches=(Test-VanessaAuthoringStateMatches -State $final -FeatureRecords @(Get-VanessaAuthoringFeatureRecords) -LibraryFingerprint '') }
            }
            $result.phase | Should -Be 'passed'
            $result.matches | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "enforces three helper-owned repair attempts" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-repair-budget-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot commit --allow-empty -m baseline *> $null
            & git -C $tempRoot switch -q -c itldev/demo *> $null
            $state = [ordered]@{ devBranchName='demo'; safeDevBranchName='demo'; devBranch='itldev/demo'; worktreePath=$tempRoot; devBranchInfoBasePath=(Join-Path $tempRoot '.agent-1c\infobases\demo') }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\demo.json") -Encoding UTF8 -Value ($state | ConvertTo-Json)
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $VerificationTrigger = 'repair'
                Start-ItlVerificationRepairSession *> $null
                Use-ItlVerificationRepairAttempt *> $null
                Use-ItlVerificationRepairAttempt *> $null
                Use-ItlVerificationRepairAttempt *> $null
                try { Use-ItlVerificationRepairAttempt *> $null; 'not-blocked' } catch { $_.Exception.Message }
            }
            $result | Should -Match 'exhausted its three full verification runs'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "bypasses missing suite when Vanessa mode is off" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-authoring-off-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"missing/features"}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot commit --allow-empty -m baseline *> $null
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_TESTING','off','Process')
            $result = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; try { Assert-VanessaAuthoringPreflight -Trigger command; 'passed' } catch { $_.Exception.Message } }
            $result | Should -Be 'passed'
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_TESTING',$null,'Process')
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports missing-suite before any infobase update through status JSON" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-authoring-status-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","masterBranch":"master","testsPath":"missing/features"}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot commit --allow-empty -m baseline *> $null
            & git -C $tempRoot switch -q -c itldev/demo
            $state = [ordered]@{ devBranchName='demo'; safeDevBranchName='demo'; devBranch='itldev/demo'; devBranchKind='configuration'; worktreePath=$tempRoot; devBranchInfoBasePath=(Join-Path $tempRoot '.agent-1c\infobases\demo') }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\demo.json") -Encoding UTF8 -Value ($state | ConvertTo-Json)
            $statusPath = Join-Path $tempRoot ".agent-1c\runs\status.json"
            $logPath = Join-Path $tempRoot ".agent-1c\runs\console.log"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = (Get-Command powershell).Source
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" -ProjectRoot `"$tempRoot`" -Action check-dev-branch -RunStatusPath `"$statusPath`" -RunLogPath `"$logPath`""
            $process = [System.Diagnostics.Process]::Start($processInfo)
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 1
            $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.stage | Should -Not -Match 'update|designer'
            $status.errorCategory | Should -Be 'missing-suite'
            $status.requiredAction | Should -Be '/itl-verify-fix'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
