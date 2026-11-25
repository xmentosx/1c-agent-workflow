Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
        $TimeoutPolicySource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\itl-runner-timeout.ps1"
        function Copy-RunnerFixture {
            param([string]$Destination)
            $scriptRoot = Split-Path -Parent $Destination
            $libRoot = Join-Path $scriptRoot "lib"
            New-Item -ItemType Directory -Force -Path $libRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination $Destination
            Copy-Item -LiteralPath $TimeoutPolicySource -Destination (Join-Path $libRoot "itl-runner-timeout.ps1")
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $TimeoutPolicySource) 'itl-powershell-environment.ps1') -Destination $libRoot
        }
    }

    It "keeps Windows PowerShell built-in modules available when invoked from PowerShell Core" -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl pwsh boundary путь " + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            Copy-RunnerFixture -Destination $runnerPath
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$hash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$hash }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            Push-Location $tempRoot
            try {
                $output = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -- -Action check-dev-branch 2>&1)
                $exitCode = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            $summary = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine) | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.userReport | Should -Match '^[0-9a-f]{64}$'
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "routes update-workflow from a Cyrillic development worktree to master without switching the caller branch" {
        $cyrillicName = -join ([char[]](0x043C, 0x0430, 0x0440, 0x0448, 0x0440, 0x0443, 0x0442))
        $devBranch = "itldev/$cyrillicName"
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl update $cyrillicName " + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main project"
        $devRoot = Join-Path $tempRoot "dev branch"
        try {
            $scriptRoot = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$branch = (& git -C $ProjectRoot branch --show-current).Trim()
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; branch=$branch; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='master updated; refresh the dev branch' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m init *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b $devBranch $devRoot *> $null
            $LASTEXITCODE | Should -Be 0

            Push-Location $devRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $devRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1") -Arguments @("--", "-Action", "update-workflow")
            } finally {
                Pop-Location
            }

            $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.projectRoot | Should -Be ([IO.Path]::GetFullPath($mainRoot))
            $status.branch | Should -Be "master"
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $gitDirText = [IO.File]::ReadAllText((Join-Path $devRoot ".git"), $utf8).Trim()
            $gitDirValue = $gitDirText.Substring("gitdir: ".Length)
            $devGitDir = if ([IO.Path]::IsPathRooted($gitDirValue)) { $gitDirValue } else { Join-Path $devRoot $gitDirValue }
            [IO.File]::ReadAllText((Join-Path $devGitDir "HEAD"), $utf8).Trim() | Should -Be "ref: refs/heads/$devBranch"
            [IO.File]::ReadAllText((Join-Path $mainRoot ".git\HEAD"), $utf8).Trim() | Should -Be "ref: refs/heads/master"
            ($processResult.stderr -join "`n") | Should -Match "ITL update-workflow target: branch=itldev/"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "bootstraps only branch refresh actions through the clean master runner" {
        $cyrillicName = -join ([char[]](0x0432, 0x0435, 0x0442, 0x043A, 0x0430))
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl refresh $cyrillicName " + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main project"
        $devRoot = Join-Path $tempRoot "dev $cyrillicName"
        $devBranch = "itldev/$cyrillicName"
        try {
            $mainScripts = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $mainScripts | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $mainScripts "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $mainScripts "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="main-runtime:$Action" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m init *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b $devBranch $devRoot *> $null
            $LASTEXITCODE | Should -Be 0

            $branchHelper = Join-Path $devRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            Set-Content -LiteralPath $branchHelper -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="branch-runtime:$Action" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $branchRunner = Join-Path $devRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
            Push-Location $devRoot
            try {
                foreach ($refreshAction in @("refresh-dev-branch", "refresh-dev-branch-lite")) {
                    $processResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", $refreshAction)
                    $processResult.exitCode | Should -Be 0 -Because (($processResult.stderr + $processResult.stdout) -join [Environment]::NewLine)
                    $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
                    $summary.userReport | Should -Be "main-runtime:$refreshAction"
                    $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $status.projectRoot | Should -Be ([IO.Path]::GetFullPath($devRoot))
                    ($processResult.stderr -join "`n") | Should -Match "ITL refresh runtime: delegating action=$refreshAction"
                }

                $localResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", "check-dev-branch")
                $localResult.exitCode | Should -Be 0 -Because (($localResult.stderr + $localResult.stdout) -join [Environment]::NewLine)
                (($localResult.stdout -join "`n") | ConvertFrom-Json).userReport | Should -Be "branch-runtime:check-dev-branch"

                Add-Content -LiteralPath (Join-Path $mainScripts "agent-1c.ps1") -Encoding UTF8 -Value "# dirty runtime"
                $dirtyResult = Invoke-TestPowerShellFile -FilePath $branchRunner -Arguments @("--", "-Action", "refresh-dev-branch-lite")
                $dirtyResult.exitCode | Should -Not -Be 0
                (($dirtyResult.stderr + $dirtyResult.stdout) -join "`n") | Should -Match "REFRESH_MASTER_RUNTIME_DIRTY"
            } finally {
                Pop-Location
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "defaults Caveman to auto/full and ignores the retired persistent level" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-response-style-" + [guid]::NewGuid().ToString("N"))
        $previousMode = [Environment]::GetEnvironmentVariable("CAVEMAN", "Process")
        $previousLevel = [Environment]::GetEnvironmentVariable("CAVEMAN_LEVEL", "Process")
        try {
            [Environment]::SetEnvironmentVariable("CAVEMAN", $null, "Process")
            [Environment]::SetEnvironmentVariable("CAVEMAN_LEVEL", $null, "Process")
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='unchanged report' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $cases = @(
                [pscustomobject]@{ mode=$null; level=$null; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='invalid'; level='invalid'; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='on'; level='lite'; expectedMode='on'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='on'; level='ultra'; expectedMode='on'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='auto'; level='lite'; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='auto'; level='full'; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='auto'; level='ultra'; expectedMode='auto'; expectedLevel='full'; active=$true; profile='caveman-full' },
                [pscustomobject]@{ mode='off'; level='lite'; expectedMode='off'; expectedLevel='full'; active=$false; profile='normal' },
                [pscustomobject]@{ mode='off'; level='full'; expectedMode='off'; expectedLevel='full'; active=$false; profile='normal' },
                [pscustomobject]@{ mode='off'; level='ultra'; expectedMode='off'; expectedLevel='full'; active=$false; profile='normal' }
            )
            foreach ($case in $cases) {
                $envPath = Join-Path $tempRoot ".dev.env"
                if ($null -eq $case.mode -and $null -eq $case.level) {
                    Remove-Item -LiteralPath $envPath -Force -ErrorAction SilentlyContinue
                } else {
                    Set-Content -LiteralPath $envPath -Encoding UTF8 -Value "CAVEMAN=$($case.mode)`nCAVEMAN_LEVEL=$($case.level)`n"
                }
                Push-Location $tempRoot
                try {
                    $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
                } finally { Pop-Location }
                $processResult.exitCode | Should -Be 0 -Because $processResult.combinedText
                $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
                $summary.responseStyle.mode | Should -Be $case.expectedMode
                $summary.responseStyle.level | Should -Be $case.expectedLevel
                $summary.responseStyle.active | Should -Be $case.active
                $summary.responseStyle.profile | Should -Be $case.profile
                $summary.responseStyle.taskClass | Should -Be 'execution'
                $summary.userReport | Should -BeExactly 'unchanged report'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("CAVEMAN", $previousMode, "Process")
            [Environment]::SetEnvironmentVariable("CAVEMAN_LEVEL", $previousLevel, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "dispatches real classification and preserves its <Case> result without verification proof" -TestCases @(
        @{ Case='ready'; HelperExit=0; ErrorPattern='' },
        @{ Case='missing-suite'; HelperExit=1; ErrorPattern='Unclassified Vanessa feature' },
        @{ Case='unowned-path'; HelperExit=1; ErrorPattern='VERIFICATION_SUITE_OWNERS_MISSING' },
        @{ Case='source-without-git'; HelperExit=1; ErrorPattern='YAXUNIT_APPLICABILITY_BASELINE_MISSING' }
    ) {
        param($Case, $HelperExit, $ErrorPattern)
        $tempRoot = Join-Path $TestDrive ("Классификация команды " + $Case)
        $features = Join-Path $tempRoot 'tests/features'
        $stateRoot = Join-Path $tempRoot '.agent-1c/dev-branches'
        $proofPath = Join-Path $tempRoot '.agent-1c/verification-selection/proof.json'
        New-Item -ItemType Directory -Force -Path $features,$stateRoot,(Split-Path $proofPath) | Out-Null
        Set-Content -LiteralPath (Join-Path $stateRoot 'probe.json') -Value '{"devBranchName":"probe","safeDevBranchName":"probe"}' -Encoding UTF8
        $featurePath = Join-Path $features 'Example.feature'
        Set-Content -LiteralPath $featurePath -Encoding UTF8 -Value @'
# language: ru
Функционал: Проверка классификации
Сценарий: Сохранение поведения
    Дано исходное действие
'@
        if ($Case -ne 'missing-suite') {
            $owners = if ($Case -eq 'unowned-path') { @() } else { @('src/cf/**') }
            @{ schemaVersion=1; suites=@(@{id='example';purpose='acceptance';featurePaths=@('tests/features/Example.feature');ownerPaths=$owners}) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $tempRoot 'tests/verification-suites.branch.json') -Encoding UTF8
        }
        if ($Case -eq 'source-without-git') {
            $sourceRoot = Join-Path $tempRoot 'src/cf'
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot 'Module.bsl') -Value 'Процедура Проверка() КонецПроцедуры' -Encoding UTF8
        }
        Set-Content -LiteralPath $proofPath -Value '{"tree":"unchanged-existing-proof"}' -Encoding UTF8
        $proofHash = (Get-FileHash -LiteralPath $proofPath).Hash
        $featureHash = (Get-FileHash -LiteralPath $featurePath).Hash
        Push-Location $tempRoot
        try {
            $result = Invoke-TestPowerShellFile -FilePath $RunnerSource -Arguments @('--','-Action','validate-test-classification','-DevBranchName','probe')
        } finally { Pop-Location }
        $result.exitCode | Should -Be $HelperExit -Because $result.combinedText
        $summary = $result.stdout | ConvertFrom-Json
        $summary.action | Should -Be 'validate-test-classification'
        if ($HelperExit) {
            $summary.errorCategory | Should -Be 'missing-suite'
            $summary.error | Should -Match $ErrorPattern
            $summary.requiredAction | Should -Be 'classify-tests-and-repeat-original-itl-command'
        } else {
            $summary.status | Should -Be 'succeeded'
            $state = Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'probe.json') | ConvertFrom-Json
            $state.verificationClassificationStatus | Should -Be 'ready'
        }
        $inventory = Get-Content -Raw -LiteralPath (Join-Path $tempRoot '.agent-1c/verification-selection/inventory.json') | ConvertFrom-Json
        $inventory.classificationComplete | Should -Be ($HelperExit -eq 0)
        @($summary.ownedProcessIds).Count | Should -Be 0
        $summary.resultPath | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $proofPath).Hash | Should -Be $proofHash
        (Get-FileHash -LiteralPath $featurePath).Hash | Should -Be $featureHash
    }
}
