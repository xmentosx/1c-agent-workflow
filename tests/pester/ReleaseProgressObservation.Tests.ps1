BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Release native progress observation' {
    It 'observes owned native progress while retaining idle and hard limits: <Scenario>' -TestCases @(
        @{ Scenario = 'release-worktree'; ExpectedFailure = ''; NativeRoot = 'release' }
        @{ Scenario = 'configured-relative-worktree'; ExpectedFailure = ''; NativeRoot = 'release'; LogLayout = 'relative' }
        @{ Scenario = 'configured-absolute-main'; ExpectedFailure = ''; NativeRoot = 'main'; LogLayout = 'absolute' }
        @{ Scenario = 'foreign-worktree'; ExpectedFailure = 'no progress for 10 seconds'; NativeRoot = 'foreign' }
        @{ Scenario = 'hard-timeout'; ExpectedFailure = 'remaining mode budget 12 seconds'; NativeRoot = 'release' }
    ) {
        param($Scenario, $ExpectedFailure, $NativeRoot, [string]$LogLayout = 'default')
        $fixtureRoot = Join-Path $TestDrive "Стенд с пробелом $Scenario"
        $projectRoot = Join-Path $fixtureRoot 'Основная ветка'
        $releaseRoot = Join-Path $fixtureRoot 'Рабочая ветка'
        $foreignRoot = Join-Path $fixtureRoot 'Посторонняя ветка'
        $outputRoot = Join-Path $fixtureRoot 'out'
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot '.agent-1c'), $releaseRoot, $foreignRoot, $outputRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectRoot '.agent-1c/release-e2e.json'), (@{
            worktreePath = $releaseRoot; devBranchName = 'release-fixture'
        } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definitions = foreach ($name in @('ConvertTo-NativeArgument', 'Start-PowerShellChildProcess', 'Stop-GateChildProcessTree', 'Wait-PowerShellChildProcess')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
            $definition | Should -Not -BeNullOrEmpty
            $definition.Extent.Text
        }
        $progressAssignment = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$releaseProgressPaths'
        }, $true))
        $progressAssignment.Count | Should -Be 1
        $nativeRootPath = if ($NativeRoot -eq 'release') { $releaseRoot } elseif ($NativeRoot -eq 'main') { $projectRoot } else { $foreignRoot }
        $nativeLogDirectory = Join-Path $nativeRootPath 'logs/1c'
        if ($LogLayout -ne 'default') {
            $nativeLogDirectory = Join-Path $nativeRootPath 'Настроенные журналы 1С'
            $configuredPath = if ($LogLayout -eq 'relative') { 'Настроенные журналы 1С' } else { $nativeLogDirectory }
            New-Item -ItemType Directory -Force -Path (Join-Path $nativeRootPath '.agent-1c') | Out-Null
            [IO.File]::WriteAllText((Join-Path $nativeRootPath '.agent-1c/project.json'), (@{
                logsPath = $configuredPath
            } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        $nativeLogPath = Join-Path $nativeLogDirectory 'Проверка модулей.log'
        $writerPath = Join-Path $fixtureRoot 'native-progress.ps1'
        [IO.File]::WriteAllText($writerPath, @'
param([string]$LogPath)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
for ($i = 0; $i -lt 10; $i++) {
    [IO.File]::AppendAllText($LogPath, "Проверка модулей: $i`n", [Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 2500
}
exit 0
'@, [Text.UTF8Encoding]::new($true))
        $probePath = Join-Path $fixtureRoot 'observe-progress.ps1'
        $probe = @'
param([string]$SourceRoot, [string]$FixtureRoot, [string]$NativeLogPath, [string]$Scenario)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
. (Join-Path $SourceRoot 'scripts/stand-env-identity.ps1')
'@ + [Environment]::NewLine + ($definitions -join [Environment]::NewLine) + [Environment]::NewLine + @'
$repoRoot = $FixtureRoot
$outputRoot = Join-Path $FixtureRoot 'out'
$E2EProjectRoot = Join-Path $FixtureRoot 'Основная ветка'
$releaseFixtureRoot = $E2EProjectRoot
$modeHardBudgetSeconds = 60
$childTimeoutSeconds = if ($Scenario -eq 'hard-timeout') { 12 } else { 60 }
$overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
'@ + [Environment]::NewLine + $progressAssignment[0].Extent.Text + [Environment]::NewLine + @'
$child = Start-PowerShellChildProcess -ScriptPath (Join-Path $FixtureRoot 'native-progress.ps1') -Arguments @('-LogPath', $NativeLogPath) -LogName 'release-e2e'
$failure = ''
try { Wait-PowerShellChildProcess -Child $child -TimeoutSeconds $childTimeoutSeconds -NoProgressSeconds 10 -ProgressPaths $releaseProgressPaths }
catch { $failure = $_.Exception.Message }
finally { Stop-GateChildProcessTree -Process $child.process }
$child.process.Refresh()
[IO.File]::WriteAllText((Join-Path $outputRoot 'observation.json'), (@{
    failure = $failure; exitCode = [int]$child.process.ExitCode; elapsedSeconds = $overallStopwatch.Elapsed.TotalSeconds
} | ConvertTo-Json), $utf8)
'@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $run = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @(
            '-SourceRoot', $RepoRoot, '-FixtureRoot', $fixtureRoot, '-NativeLogPath', $nativeLogPath, '-Scenario', $Scenario
        )
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $observation = Get-Content -LiteralPath (Join-Path $outputRoot 'observation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ExpectedFailure) {
            $observation.failure | Should -Match ([regex]::Escape($ExpectedFailure))
            $observation.elapsedSeconds | Should -BeLessThan 25
        } else {
            $observation.failure | Should -BeNullOrEmpty
            $observation.exitCode | Should -Be 0
            $observation.elapsedSeconds | Should -BeGreaterThan 24
        }
        $nativeText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($nativeLogPath))
        $nativeText | Should -Match 'Проверка модулей: 0'
    }
}
