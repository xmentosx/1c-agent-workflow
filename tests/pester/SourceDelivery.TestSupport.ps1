. (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $DeliveryScript = Join-Path $RepoRoot "scripts\source-delivery.ps1"
    $DeliverySourcePaths = @($DeliveryScript)
    foreach ($name in @("source-delivery-queue.ps1", "source-delivery-process.ps1", "source-delivery-component.ps1", "source-delivery-candidate.ps1", "source-delivery-cleanup.ps1")) {
        $path = Join-Path $RepoRoot ("scripts\" + $name)
        if (Test-Path -LiteralPath $path -PathType Leaf) { $DeliverySourcePaths += $path }
    }
    $DeliverySourceText = @($DeliverySourcePaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join [Environment]::NewLine

    function Get-DeliveryFunctionDefinitions {
        param([string[]]$Names)
        $definitions = @()
        foreach ($path in $DeliverySourcePaths) {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors) | Should -BeNullOrEmpty
            $definitions += @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object Name -in $Names)
        }
        return @($definitions)
    }

    function Invoke-DeliveryTestPowerShell {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $stdout = Join-Path ([IO.Path]::GetTempPath()) ("itl-delivery-stdout-" + [guid]::NewGuid().ToString("N") + ".log")
        $stderr = Join-Path ([IO.Path]::GetTempPath()) ("itl-delivery-stderr-" + [guid]::NewGuid().ToString("N") + ".log")
        try {
            $process = Start-Process -FilePath "powershell.exe" -ArgumentList (@("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $DeliveryScript + '"')) + $Arguments) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $result = [pscustomobject]@{
                exitCode = [int]$process.ExitCode
                stdout = $(if (Test-Path $stdout) { Get-Content -LiteralPath $stdout -Raw -Encoding UTF8 } else { "" })
                stderr = $(if (Test-Path $stderr) { Get-Content -LiteralPath $stderr -Raw -Encoding UTF8 } else { "" })
            }
            if (-not $AllowFailure -and $result.exitCode -ne 0) { throw "Delivery command failed: $($result.stderr)" }
            return $result
        } finally {
            Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        }
    }
    function New-DeliveryFixture {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl delivery путь " + [guid]::NewGuid().ToString("N"))
        $remote = Join-Path ([IO.Path]::GetTempPath()) ("itl-delivery-remote-" + [guid]::NewGuid().ToString("N") + ".git")
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git init --quiet --bare $remote *> $null
        & git -C $root init --quiet *> $null
        & git -C $root config user.name "ITL Test"
        & git -C $root config user.email "itl-test@example.invalid"
        & git -C $root switch --quiet -c develop *> $null
        Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding UTF8 -Value "build/"
        Set-Content -LiteralPath (Join-Path $root "README.md") -Encoding UTF8 -Value "base"
        & git -C $root add .gitignore README.md
        & git -C $root commit --quiet -m base *> $null
        & git -C $root remote add origin $remote
        & git -C $root push --quiet -u origin develop *> $null
        $fakeGate = Join-Path $root "fake-gate.ps1"
        Set-Content -LiteralPath $fakeGate -Encoding UTF8 -Value @'
param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot, [string]$ReleaseResumeMode); $CoverageContract = @($CoverageContract -split ','); if ($CoverageContract -and @($CoverageContract).Count -ne 2) { exit 12 }
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-modes.log') -Encoding UTF8 -Value $Mode
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-candidates.log') -Encoding UTF8 -Value ("$Mode " + (& git rev-parse HEAD).Trim())
if ($Mode -eq 'Targeted') { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-target-bases.log') -Encoding UTF8 -Value $BaseRef }
if ($Mode -eq 'Release') { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-release-resume.log') -Encoding UTF8 -Value $ReleaseResumeMode }
if ($Mode -eq 'Full') {
    $qualification = Join-Path (Get-Location) 'build\test-results\qualification'
    New-Item -ItemType Directory -Force -Path $qualification | Out-Null
    $head = (& git rev-parse HEAD).Trim()
    $tree = (& git rev-parse 'HEAD^{tree}').Trim()
    $full = [ordered]@{
        kind = 'itl-workflow-full-qualification'; status = 'passed'; reusable = $true
        repository = [ordered]@{ commit = $head; tree = $tree; worktreeClean = $true }
        result = [ordered]@{ passed = 1; failed = 0; skipped = 0 }
    }
    Set-Content -LiteralPath (Join-Path $qualification 'full.json') -Encoding UTF8 -Value ($full | ConvertTo-Json -Depth 6)
}
if ($Mode -eq 'Develop') {
    $qualification = Join-Path (Get-Location) 'build\test-results\qualification'
    New-Item -ItemType Directory -Force -Path $qualification | Out-Null
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-develop-bases.log') -Encoding UTF8 -Value $BaseRef
    $routeInput = [ordered]@{}
    foreach ($name in @('develop-e2e-upgrade.json', 'develop-e2e-fresh.json')) {
        $path = Join-Path $qualification $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $routeInput[$name] = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    }
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-develop-route-input.log') -Encoding UTF8 -Value ($routeInput | ConvertTo-Json -Compress -Depth 6)
    Set-Content -LiteralPath (Join-Path $qualification 'full.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop-e2e-summary.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop-e2e-upgrade.json') -Encoding UTF8 -Value '{"source":"candidate-upgrade"}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop-e2e-fresh.json') -Encoding UTF8 -Value '{"source":"candidate-fresh"}'
}
if ($Mode -eq 'Release' -and $env:ITL_TEST_FAIL_DELIVERY_RELEASE -eq 'true') { exit 14 }
exit 0
'@
        $fakePromoter = Join-Path $root "fake-compatibility-promoter.ps1"
        Set-Content -LiteralPath $fakePromoter -Encoding UTF8 -Value @'
param([string]$RepositoryRoot, [string]$QualificationPath)
$lockPath = Join-Path $RepositoryRoot 'templates\dependency-lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$lock.dependencies.aiRules1c.compatibilityStatus = 'passed'
$lock.dependencies.aiRules1c.compatibilityCheckedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
[IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\compatibility-promoter.log') -Encoding UTF8 -Value $QualificationPath
'@
        $fakeFinalizer = Join-Path $root "fake-component-finalizer.ps1"
        Set-Content -LiteralPath $fakeFinalizer -Encoding UTF8 -Value @'
param([string]$RepositoryRoot, [string]$SourceRepositoryRoot, [string]$CandidateCommit, [string]$Remote, [switch]$ReleaseQualified)
$remoteHead = ((& git -C $RepositoryRoot ls-remote $Remote refs/heads/develop) -split "`t")[0]
$record = [ordered]@{ candidateCommit = $CandidateCommit; remoteHead = $remoteHead; releaseQualified = [bool]$ReleaseQualified }
New-Item -ItemType Directory -Force -Path (Join-Path $SourceRepositoryRoot 'build') | Out-Null
Add-Content -LiteralPath (Join-Path $SourceRepositoryRoot 'build\component-finalizer.log') -Encoding UTF8 -Value ($record | ConvertTo-Json -Compress)
if ($env:ITL_TEST_FAIL_COMPONENT_FINALIZER -eq 'true') { [Console]::Error.WriteLine('fixture component finalizer failed'); exit 17 }
exit 0
'@
        & git -C $root add fake-gate.ps1 fake-compatibility-promoter.ps1 fake-component-finalizer.ps1
        & git -C $root commit --quiet -m "test: add gate" *> $null
        & git -C $root push --quiet origin develop *> $null
        return [pscustomobject]@{ root = $root; remote = $remote; gate = $fakeGate; promoter = $fakePromoter; promoterLog = (Join-Path $root 'build\compatibility-promoter.log'); finalizer = $fakeFinalizer; finalizerLog = (Join-Path $root 'build\component-finalizer.log'); modeLog = (Join-Path $root 'build\gate-modes.log'); candidateLog = (Join-Path $root 'build\gate-candidates.log'); targetBaseLog = (Join-Path $root 'build\gate-target-bases.log'); developBaseLog = (Join-Path $root 'build\gate-develop-bases.log'); developRouteInputLog = (Join-Path $root 'build\gate-develop-route-input.log'); releaseResumeLog = (Join-Path $root 'build\gate-release-resume.log'); base = (& git -C $root rev-parse HEAD).Trim() }
    }
    function Set-DeliveryAiRulesLock {
        param([Parameter(Mandatory = $true)][object]$Fixture, [string]$CompatibilityStatus = "pending")
        $templateRoot = Join-Path $Fixture.root "templates"
        New-Item -ItemType Directory -Force -Path $templateRoot | Out-Null
        $lock = [ordered]@{
            schemaVersion = 1
            dependencies = [ordered]@{
                aiRules1c = [ordered]@{
                    repo = "https://example.invalid/ai_rules_1c.git"
                    ref = "itl-v1.0.0-r99"
                    commit = ("a" * 40)
                    upstreamRef = "v1.0.0"
                    upstreamCommit = ("b" * 40)
                    downstreamRevision = 99
                    compatibilityStatus = $CompatibilityStatus
                    compatibilityCheckedAt = $(if ($CompatibilityStatus -eq "passed") { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "" })
                }
            }
        }
        [IO.File]::WriteAllText((Join-Path $templateRoot "dependency-lock.json"), (($lock | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    function Remove-DeliveryFixture {
        param([object]$Fixture)
        if ($Fixture) {
            & git -C $Fixture.root worktree prune *> $null; Remove-Item -LiteralPath $Fixture.root -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $Fixture.remote -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
