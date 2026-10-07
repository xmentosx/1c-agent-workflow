BeforeAll {
    $script:recoverySourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:recoverySourceRoot 'scripts/source-delivery-process.ps1')
    . (Join-Path $script:recoverySourceRoot 'scripts/source-delivery-release-recovery.ps1')

    function Get-RecoverySourceAst {
        param([string]$RelativePath)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:recoverySourceRoot $RelativePath), [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw "Fixture owner must parse: $RelativePath" }
        return $ast
    }
    $componentAst = Get-RecoverySourceAst 'scripts/source-delivery-component.ps1'
    $quoteOwner = @($componentAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ConvertTo-DeliveryNativeArgument'
    }, $false))
    if ($quoteOwner.Count -ne 1) { throw 'Expected one native quoting owner.' }
    Invoke-Expression $quoteOwner[0].Extent.Text

    # Execute the actual publication decision blocks; stub only subsequent gates
    # and evidence writers. Recovery and readiness each launch their real child.
    $candidateAst = Get-RecoverySourceAst 'scripts/source-delivery-candidate.ps1'
    $script:recoveryPublicationBlocks = @{}
    foreach ($name in @('Publish-AccumulatedDevelop', 'Release-DevelopToMaster')) {
        $owner = @($candidateAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $false))[0]
        $calls = @($owner.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-DeliveryReleaseStandRecovery'
        }, $true))
        if ($calls.Count -ne 1) { throw "Expected one recovery call in $name." }
        $decision = $calls[0].Parent
        while ($decision -and $decision -isnot [Management.Automation.Language.IfStatementAst]) { $decision = $decision.Parent }
        if (-not $decision) { throw "Recovery must remain conditional in $name." }
        $script:recoveryPublicationBlocks[$name] = [scriptblock]::Create($decision.Extent.Text)
    }
    function Get-DevelopPublicationPhaseRank { param([string]$Phase) if ($Phase -eq 'release-qualified') { return 2 }; return 0 }
    function Test-ExactPassedDeliveryRun { return $true }
    function Get-DeliveryPlanGateBudgetSeconds { return 1 }
    function Invoke-SourceGate { param([string]$Mode) Add-Content -LiteralPath $script:recoveryOrderPath -Encoding UTF8 -Value $Mode }
    function Save-DeliveryQualification {}
    function Save-DeliveryPlanGateEvidence {}
    function Register-DeliveryGateResources {}
}

Describe 'Mutating source publication Release recovery' {
    BeforeEach {
        $script:DeliveryCustomGateBoundary = $false
        $script:recoveryCandidate = Join-Path $TestDrive ('candidate путь ' + [guid]::NewGuid().ToString('N'))
        $script:E2EProjectRoot = Join-Path $TestDrive ('stand путь ' + [guid]::NewGuid().ToString('N'))
        $script:AiRulesSource = Join-Path $TestDrive 'rules путь'
        $script:ReleaseResumeMode = 'Auto'
        $script:AgentTarget = 'codex'
        $script:recoveryOrderPath = Join-Path $script:E2EProjectRoot 'order.log'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:recoveryCandidate 'scripts'))
        [void][IO.Directory]::CreateDirectory($script:E2EProjectRoot)
        [void][IO.Directory]::CreateDirectory($script:AiRulesSource)
        [IO.File]::WriteAllText((Join-Path $script:E2EProjectRoot 'residue.txt'), 'owned interrupted extension', [Text.UTF8Encoding]::new($false))
        $runner = @'
param([string]$ProjectRoot,[string]$AiRulesSource,[string]$ResumeMode,[string]$AgentTarget,[switch]$RecoverInterruptedExtensionOnly)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
if (-not $RecoverInterruptedExtensionOnly -or $AgentTarget -cne 'codex' -or $ResumeMode -cne 'Auto' -or -not (Test-Path -LiteralPath $AiRulesSource)) { throw 'Recovery invocation mismatch.' }
Add-Content -LiteralPath (Join-Path $ProjectRoot 'order.log') -Encoding UTF8 -Value 'recovery'
if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'fail.txt')) { throw 'Recovery fixture refused its own target.' }
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'recovered.txt'), $ProjectRoot, [Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath (Join-Path $ProjectRoot 'residue.txt') -Force -ErrorAction SilentlyContinue
[Console]::Out.WriteLine('Восстановлен путь: ' + $ProjectRoot)
[Console]::Error.WriteLine('Диагностика восстановления: ' + $ProjectRoot)
'@
        [IO.File]::WriteAllText((Join-Path $script:recoveryCandidate 'scripts/invoke-release-e2e.ps1'), $runner, [Text.UTF8Encoding]::new($true))
        $readiness = @'
param([string]$Mode,[string]$RepositoryRoot,[string]$E2EProjectRoot,[string]$AiRulesSource,[string]$ResumeMode,[string]$OutputPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Content -LiteralPath (Join-Path $E2EProjectRoot 'order.log') -Encoding UTF8 -Value 'readiness'
$dirty=Test-Path -LiteralPath (Join-Path $E2EProjectRoot 'residue.txt')
$result=@{status=$(if($dirty){'failed'}else{'passed'});issues=@(@{code='FIXTURE_RESIDUE';message='owned residue remains';recovery='run owning recovery'})}
[IO.File]::WriteAllText($OutputPath,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
if($dirty){exit 9}
'@
        [IO.File]::WriteAllText((Join-Path $script:recoveryCandidate 'scripts/test-release-readiness.ps1'), $readiness, [Text.UTF8Encoding]::new($true))
    }

    It 'recovers before readiness in <Caller> using native Unicode child transport' -ForEach @(
        @{ Caller = 'Publish-AccumulatedDevelop' }, @{ Caller = 'Release-DevelopToMaster' }
    ) {
        $RequireRelease = $true; $attempt = [pscustomobject]@{ phase = 'candidate-built' }
        $ReusePrequalifiedGates = $false; $worktree = [pscustomobject]@{ path = $script:recoveryCandidate }
        $remoteDevelop = 'fixture'; $deliveryPlan = @{}; $candidateTree = 'fixture'
        & $script:recoveryPublicationBlocks[$Caller]
        $order = @(Get-Content -LiteralPath $script:recoveryOrderPath -Encoding UTF8)
        $order[0] | Should -Be 'recovery'; $order[1] | Should -Be 'readiness'
        if ($Caller -eq 'Release-DevelopToMaster') { $order | Should -Be @('recovery','readiness','Develop','Release') }
        else { $order.Count | Should -Be 2 }
        Test-Path -LiteralPath (Join-Path $script:E2EProjectRoot 'residue.txt') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $script:E2EProjectRoot 'recovered.txt')) | Should -Be $script:E2EProjectRoot
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        foreach ($stream in @('stdout','stderr')) {
            $path = Join-Path $script:recoveryCandidate "build/test-results/delivery/release-stand-recovery.$stream.log"
            $actual = $strictUtf8.GetString([IO.File]::ReadAllBytes($path)).TrimEnd("`r", "`n")
            $marker = if ($stream -eq 'stdout') { 'Восстановлен путь: ' } else { 'Диагностика восстановления: ' }
            $actual | Should -Be ($marker + $script:E2EProjectRoot)
        }
    }

    It 'preserves residue and stops before readiness when recovery fails' {
        [IO.File]::WriteAllText((Join-Path $script:E2EProjectRoot 'fail.txt'), 'fail')
        $RequireRelease = $true; $attempt = [pscustomobject]@{ phase = 'candidate-built' }
        $worktree = [pscustomobject]@{ path = $script:recoveryCandidate }
        { & $script:recoveryPublicationBlocks['Publish-AccumulatedDevelop'] } | Should -Throw '*Release stand recovery failed*'
        @(Get-Content -LiteralPath $script:recoveryOrderPath -Encoding UTF8) | Should -Be @('recovery')
        Test-Path -LiteralPath (Join-Path $script:E2EProjectRoot 'residue.txt') | Should -BeTrue
    }

    It 'keeps an older candidate on its ordinary readiness path' {
        [IO.File]::WriteAllText((Join-Path $script:recoveryCandidate 'scripts/invoke-release-e2e.ps1'), "param([string]`$ProjectRoot)`nthrow 'Older runner must not launch.'", [Text.UTF8Encoding]::new($true))
        Remove-Item -LiteralPath (Join-Path $script:E2EProjectRoot 'residue.txt')
        $RequireRelease = $true; $attempt = [pscustomobject]@{ phase = 'candidate-built' }
        $worktree = [pscustomobject]@{ path = $script:recoveryCandidate }
        & $script:recoveryPublicationBlocks['Publish-AccumulatedDevelop']
        @(Get-Content -LiteralPath $script:recoveryOrderPath -Encoding UTF8) | Should -Be @('readiness')
        Test-Path -LiteralPath (Join-Path $script:E2EProjectRoot 'recovered.txt') | Should -BeFalse
    }

    It 'leaves direct readiness read-only and limits recovery dispatch to publication owners' {
        { Assert-DeliveryReleaseStandReady -CandidateRoot $script:recoveryCandidate } | Should -Throw '*Release stand is not ready*'
        @(Get-Content -LiteralPath $script:recoveryOrderPath -Encoding UTF8) | Should -Be @('readiness')
        Test-Path -LiteralPath (Join-Path $script:E2EProjectRoot 'residue.txt') | Should -BeTrue
        $callers = @(foreach ($path in @('scripts/source-delivery-candidate.ps1','scripts/source-delivery-plan.ps1','scripts/source-delivery-process.ps1','scripts/source-delivery-supervisor.ps1')) {
            $ast = Get-RecoverySourceAst $path
            foreach ($call in @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-DeliveryReleaseStandRecovery'
            }, $true))) {
                $owner = $call.Parent
                while ($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
                if (-not $owner) { throw "Recovery may not run at module import: $path" }
                $owner.Name
            }
        })
        @($callers | Sort-Object) | Should -Be @('Publish-AccumulatedDevelop','Release-DevelopToMaster')
    }

    It 'does not recover an already qualified publication or a publication without Release' {
        $RequireRelease = $false; $attempt = [pscustomobject]@{ phase = 'candidate-built' }
        $worktree = [pscustomobject]@{ path = $script:recoveryCandidate }
        & $script:recoveryPublicationBlocks['Publish-AccumulatedDevelop']
        $RequireRelease = $true; $attempt.phase = 'release-qualified'
        & $script:recoveryPublicationBlocks['Publish-AccumulatedDevelop']
        $ReusePrequalifiedGates = $true; $candidateBeforeGate = 'exact'; $PrequalifiedCommit = 'exact'
        $candidateTree = 'tree'; $PrequalifiedTree = 'tree'; $PrequalifiedNotBefore = [DateTime]::MinValue
        & $script:recoveryPublicationBlocks['Release-DevelopToMaster']
        Test-Path -LiteralPath $script:recoveryOrderPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:E2EProjectRoot 'residue.txt') | Should -BeTrue
    }
}
