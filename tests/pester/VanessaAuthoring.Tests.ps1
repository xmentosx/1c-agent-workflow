Describe "Vanessa test development and verification" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    }

    It "uses one verification preflight without a mandatory authoring action or state" {
        $lifecycle = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $check = [regex]::Match($lifecycle, '(?s)function Invoke-DevBranchCheck \{(?<body>.*?)\n\}')
        $check.Success | Should -BeTrue
        $check.Groups['body'].Value.IndexOf('Assert-VanessaVerificationPreflight') | Should -BeLessThan $check.Groups['body'].Value.IndexOf('Update-DevBranchBase')
        $check.Groups['body'].Value | Should -Match 'Invoke-DevBranchVanessaRuntimeRelease'
        $check.Groups['body'].Value | Should -Not -Match 'Authoring'

        $helper = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $vanessa = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $core = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1") -Raw -Encoding UTF8
        $compact = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1") -Raw -Encoding UTF8
        $helper | Should -Not -Match 'prepare-vanessa-authoring|complete-vanessa-authoring|release-e2e-approve-vanessa-fixture|AuthoringResult'
        $vanessa | Should -Not -Match 'AuthoringState|AuthoringVerificationFallback|runner-fallback-pending'
        $core | Should -Not -Match 'authoringStatus|authoringStatePath'
        $compact | Should -Not -Match 'authoringStatus|authoringStatePath'
        Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-vanessa-author.md.template") | Should -BeFalse

        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-authoring.md") -Raw -Encoding UTF8
        $reference | Should -Match 'There is no separate Vanessa authoring gate'
        $reference | Should -Match 'scenario run is optional diagnostic feedback'
        $reference | Should -Match '/itl-check` is the only executable verification gate'
        $reference | Should -Match 'Do not delete, skip, filter, or weaken'
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
            $navigationLibrary = Join-Path $tempRoot "tests\features\Libraries\ITL\Core\NavigationLinks.feature"
            Test-Path -LiteralPath $navigationLibrary | Should -BeTrue
            (Get-Content -LiteralPath $navigationLibrary -Raw -Encoding UTF8) | Should -Match 'TestClient'
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

    It "detects a feature committed on the development branch for cheap lint preflight" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-feature-preflight-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot "tests\features") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","masterBranch":"master","testsPath":"tests/features"}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot config core.safecrlf false
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m baseline *> $null
            & git -C $tempRoot switch -q -c itldev/demo
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\features\committed.feature") -Encoding UTF8 -Value "Feature: Committed`nScenario: Works`n"
            & git -C $tempRoot add tests/features/committed.feature
            & git -C $tempRoot commit -m feature *> $null
            $records = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                @(Get-VanessaChangedFeatureRecords)
            }
            @($records).Count | Should -Be 1
            $records[0].path | Should -Be 'tests/features/committed.feature'
            @($records[0].PSObject.Properties.Name) | Should -Be @('path')
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
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-verification-off-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"missing/features"}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot commit --allow-empty -m baseline *> $null
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_TESTING','off','Process')
            $result = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; try { Assert-VanessaVerificationPreflight -Trigger command; 'passed' } catch { $_.Exception.Message } }
            $result | Should -Be 'passed'
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_TESTING',$null,'Process')
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports missing-suite before any infobase update through status JSON" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-verification-status-" + [guid]::NewGuid().ToString("N"))
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
            @($status.PSObject.Properties.Name) | Should -Not -Contain 'authoringStatus'
            @($status.PSObject.Properties.Name) | Should -Not -Contain 'authoringStatePath'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "prints an explicit failed completion route for a legacy direct helper call" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-verification-direct-" + [guid]::NewGuid().ToString("N"))
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
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = (Get-Command powershell).Source
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" -ProjectRoot `"$tempRoot`" -Action check-dev-branch"
            $process = [System.Diagnostics.Process]::Start($processInfo)
            $null = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            $process.ExitCode | Should -Be 1
            $stderr | Should -Match "ITL failure: status=failed"
            $stderr | Should -Match "errorCategory=missing-suite"
            $stderr | Should -Match "requiredAction=/itl-verify-fix"
            $stderr | Should -Match "completion=pending-verification"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
