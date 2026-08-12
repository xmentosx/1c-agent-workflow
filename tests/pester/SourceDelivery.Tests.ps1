BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $DeliveryScript = Join-Path $RepoRoot "scripts\source-delivery.ps1"

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
if ($Mode -eq 'Targeted') { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-target-bases.log') -Encoding UTF8 -Value $BaseRef }
if ($Mode -eq 'Release') { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build\gate-release-resume.log') -Encoding UTF8 -Value $ReleaseResumeMode }
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
        & git -C $root add fake-gate.ps1 fake-component-finalizer.ps1
        & git -C $root commit --quiet -m "test: add gate" *> $null
        & git -C $root push --quiet origin develop *> $null
        return [pscustomobject]@{ root = $root; remote = $remote; gate = $fakeGate; finalizer = $fakeFinalizer; finalizerLog = (Join-Path $root 'build\component-finalizer.log'); modeLog = (Join-Path $root 'build\gate-modes.log'); targetBaseLog = (Join-Path $root 'build\gate-target-bases.log'); developBaseLog = (Join-Path $root 'build\gate-develop-bases.log'); developRouteInputLog = (Join-Path $root 'build\gate-develop-route-input.log'); releaseResumeLog = (Join-Path $root 'build\gate-release-resume.log'); base = (& git -C $root rev-parse HEAD).Trim() }
    }
    function Remove-DeliveryFixture {
        param([object]$Fixture)
        if ($Fixture) {
            & git -C $Fixture.root worktree prune *> $null; Remove-Item -LiteralPath $Fixture.root -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $Fixture.remote -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
Describe "Source develop queue and delivery" {
    It "parses the orchestrator and exposes only the four delivery actions" {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($DeliveryScript, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $action = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Action" } | Select-Object -First 1
        @($action.Attributes | Where-Object TypeName -match ValidateSet | Select-Object -ExpandProperty PositionalArguments | ForEach-Object SafeGetValue) | Should -Be @("RegisterChange", "Status", "PublishDevelop", "ReleaseMaster")
        $text = Get-Content -LiteralPath $DeliveryScript -Raw -Encoding UTF8
        $text | Should -Not -Match 'Restore-DeliveryContinuationQualification'
        $text | Should -Match 'Always enter Develop, even when exact proof was restored'
        $text | Should -Match 'Invoke-SourceGate -Mode "Develop" -WorkingRoot \$worktree\.path -TargetBaseRef \$remoteDevelop'
    }
    It "registers base and head atomically for a path with Cyrillic and spaces" {
        $fixture = $null; $parallelRoot = ""; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'ok'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: fixture" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", '"codex/parallel branch"', "-CoverageContract", "contract-one,contract-two")
            $result.exitCode | Should -Be 0
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/head).Trim() | Should -Be $head
            $parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl parallel worktree " + [guid]::NewGuid().ToString("N"))
            & git -C $fixture.root worktree add -b topic-two $parallelRoot $fixture.base *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $parallelRoot "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $parallelRoot "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'conflicting second'"
            Set-Content -LiteralPath (Join-Path $parallelRoot "tests\pester\Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $parallelRoot add --all; & git -C $parallelRoot commit -m "feat: parallel fixture" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $parallelRoot + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "parallel-two") | Out-Null
            $status = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))
            $statusPayload = $status.stdout | ConvertFrom-Json; @($statusPayload.queue.id | Sort-Object) | Should -Be @("codex/parallel-branch", "parallel-two"); [int]$statusPayload.runHistory.count | Should -BeGreaterOrEqual 2; [int]($statusPayload.runHistory.byMode | Where-Object mode -eq Targeted | Select-Object -ExpandProperty count) | Should -BeGreaterOrEqual 2
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure).exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -HaveCount 4
        } finally {
            if ($fixture -and $parallelRoot) { & git -C $fixture.root worktree remove --force $parallelRoot *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
    It "targets only commits after the existing head of the same queue" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "first.ps1") -Encoding UTF8 -Value "'first'"
            Set-Content -LiteralPath (Join-Path $tests "First.Tests.ps1") -Encoding UTF8 -Value "Describe 'first' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: first queued change" *> $null
            $firstHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue") | Out-Null

            $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $remoteHead = (& git -C $fixture.root commit-tree $baseTree -p $fixture.base -m "unrelated remote develop movement").Trim()
            & git -C $fixture.root push --quiet origin "$remoteHead`:refs/heads/develop" *> $null
            & git -C $fixture.root fetch --quiet origin develop *> $null
            (& git -C $fixture.root rev-parse origin/develop).Trim() | Should -Be $remoteHead

            Set-Content -LiteralPath (Join-Path $fixture.root "second.ps1") -Encoding UTF8 -Value "'second'"
            Set-Content -LiteralPath (Join-Path $tests "Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: second queued change" *> $null
            $secondHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue")
            $payload = $result.stdout | ConvertFrom-Json

            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base, $firstHead)
            @($payload.paths | Sort-Object) | Should -Be @("second.ps1", "tests/pester/Second.Tests.ps1")
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/head).Trim() | Should -Be $secondHead
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "refuses executable changes without tests or an explicit reused contract" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'changed'"
            & git -C $fixture.root add behavior.ps1
            & git -C $fixture.root commit -m "feat: uncovered" *> $null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match "must declare an existing -CoverageContract"
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "publishes the qualified candidate and clears only reachable queue entries" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'published'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: publish" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "publish") | Out-Null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($result.stdout | ConvertFrom-Json).status | Should -Be "published"
            $finalizerRecord = Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
            $finalizerRecord.candidateCommit | Should -Be $head
            $finalizerRecord.remoteHead | Should -Be $fixture.base
            $finalizerRecord.releaseQualified | Should -BeFalse
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $head
            $tree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\qualifications\$tree\develop.json") | Should -BeTrue
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "passes origin develop as the Develop base and restores its route reports before the gate" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $baselineCache = Join-Path $fixture.root ".git\itl\qualifications\$baseTree"
            New-Item -ItemType Directory -Force -Path $baselineCache | Out-Null
            foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
                Set-Content -LiteralPath (Join-Path $baselineCache $name) -Encoding UTF8 -Value '{}'
            }
            Set-Content -LiteralPath (Join-Path $baselineCache "develop-e2e-upgrade.json") -Encoding UTF8 -Value '{"source":"baseline-upgrade"}'
            Set-Content -LiteralPath (Join-Path $baselineCache "develop-e2e-fresh.json") -Encoding UTF8 -Value '{"source":"baseline-fresh"}'

            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Routing.Tests.ps1") -Encoding UTF8 -Value "Describe 'routing' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "test: route from develop baseline" *> $null
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "develop-route") | Out-Null

            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) | Out-Null

            @((Get-Content -LiteralPath $fixture.developBaseLog -Encoding UTF8)) | Should -Be @($fixture.base)
            $routeInput = Get-Content -LiteralPath $fixture.developRouteInputLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
            $routeInput.'develop-e2e-upgrade.json'.source | Should -Be "baseline-upgrade"
            $routeInput.'develop-e2e-fresh.json'.source | Should -Be "baseline-fresh"
            $candidateCache = Join-Path $fixture.root ".git\itl\qualifications\$candidateTree"
            (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-upgrade.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-upgrade"
            (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-fresh.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-fresh"
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "enriches a legacy exact-tree qualification cache with optional Develop route reports" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\LegacyCache.Tests.ps1") -Encoding UTF8 -Value "Describe 'legacy cache' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "test: legacy candidate cache" *> $null
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $candidateCache = Join-Path $fixture.root ".git\itl\qualifications\$candidateTree"
            New-Item -ItemType Directory -Force -Path $candidateCache | Out-Null
            foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
                Set-Content -LiteralPath (Join-Path $candidateCache $name) -Encoding UTF8 -Value '{}'
            }
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "legacy-cache") | Out-Null

            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) | Out-Null

            @((Get-Content -LiteralPath $fixture.developBaseLog -Encoding UTF8)) | Should -Be @($fixture.base)
            (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-upgrade.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-upgrade"
            (Get-Content -LiteralPath (Join-Path $candidateCache "develop-e2e-fresh.json") -Raw -Encoding UTF8 | ConvertFrom-Json).source | Should -Be "candidate-fresh"
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "preserves the queue and develop branch when component finalization fails" {
        $fixture = $null; $oldFailure = $env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ComponentFinalize.Tests.ps1") -Encoding UTF8 -Value "Describe 'component finalize' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "test: component finalizer failure" *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "component-finalize") | Out-Null

            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = "true"
            $failed = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure

            $failed.exitCode | Should -Not -Be 0
            $failed.stderr | Should -Match "Component publication finalizer failed"
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Targeted", "Develop")
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/component-finalize/head).Trim() | Should -Be $candidate
            $finalizerRecord = Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
            $finalizerRecord.remoteHead | Should -Be $fixture.base
        } finally {
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = $oldFailure
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
    It "publishes develop only after the exact candidate passes Develop and required Release" {
        $fixture = $null; $oldFailure = $env:ITL_TEST_FAIL_DELIVERY_RELEASE
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ReleaseQualified.Tests.ps1") -Encoding UTF8 -Value "Describe 'release-qualified publish' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: release-qualified publish" *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "true"
            $failed = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $failed.exitCode | Should -Not -Be 0
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Not -Be $candidate
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Auto")

            Remove-Item -LiteralPath $fixture.modeLog -Force
            Remove-Item -LiteralPath $fixture.releaseResumeLog -Force
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = "false"
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-ReleaseResumeMode", "Restart", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            $payload = $published.stdout | ConvertFrom-Json
            $payload.releaseQualified | Should -BeTrue
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            @((Get-Content -LiteralPath $fixture.releaseResumeLog -Encoding UTF8)) | Should -Be @("Restart")
        } finally {
            $env:ITL_TEST_FAIL_DELIVERY_RELEASE = $oldFailure
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
    It "imports an exact-tree qualification and revalidates Develop before Release" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Continuation.Tests.ps1") -Encoding UTF8 -Value "Describe 'continuation' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: continuation candidate" *> $null
            $tree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $qualification = Join-Path $fixture.root "build\test-results\qualification"
            New-Item -ItemType Directory -Force -Path $qualification | Out-Null
            [IO.File]::WriteAllText((Join-Path $qualification "full.json"), (([ordered]@{status="passed";repository=[ordered]@{tree=$tree}} | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $qualification "develop.json"), (([ordered]@{status="passed";repository=[ordered]@{tree=$tree}} | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $qualification "develop-e2e-summary.json") -Encoding UTF8 -Value '{}'

            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($published.stdout | ConvertFrom-Json).releaseQualified | Should -BeTrue
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
            Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\qualifications\$tree\develop.json") | Should -BeTrue
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "imports an ancestor qualification and revalidates Develop before Release" {
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            $catalog = [ordered]@{ continuationScopes = [ordered]@{ static = @("tests/pester/*"); gate = @(); develop = @(); release = @() } }
            [IO.File]::WriteAllText((Join-Path $fixture.root "tests\quality-contracts.json"), (($catalog | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: add continuation catalog" *> $null
            & git -C $fixture.root push --quiet origin develop *> $null
            $qualifiedCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $qualifiedTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $cache = Join-Path $fixture.root ".git\itl\qualifications\$qualifiedTree"
            New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $qualification = [ordered]@{ status = "passed"; repository = [ordered]@{ commit = $qualifiedCommit; tree = $qualifiedTree } }
            foreach ($name in @("full.json", "develop.json")) {
                [IO.File]::WriteAllText((Join-Path $cache $name), (($qualification | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            }
            Set-Content -LiteralPath (Join-Path $cache "develop-e2e-summary.json") -Encoding UTF8 -Value '{}'

            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\Harness.Tests.ps1") -Encoding UTF8 -Value "Describe 'harness repair' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "test: repair harness" *> $null
            $candidateCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $runRoot = Join-Path $fixture.root ".git\itl\runs"
            New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
            $targeted = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$candidateCommit; tree=$candidateTree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@([ordered]@{name="pester";status="passed"},[ordered]@{name="tracked-state";status="passed"},[ordered]@{name="git-diff-check";status="passed"}) }
            [IO.File]::WriteAllText((Join-Path $runRoot "fixture-targeted-continuation.json"), (($targeted | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($published.stdout | ConvertFrom-Json).releaseQualified | Should -BeTrue
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "preserves the queue when origin develop moves during qualification" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content (Join-Path $fixture.root "tests\pester\Drift.Tests.ps1") "Describe 'drift' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: queued" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $failGate = Join-Path $fixture.root 'build\fail-gate.ps1'; New-Item -ItemType Directory -Force -Path (Split-Path $failGate) | Out-Null
            Set-Content -LiteralPath $failGate -Value 'param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot); exit 8'
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $failGate + '"')) -AllowFailure).exitCode | Should -Not -Be 0
            $tree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $drift = (& git -C $fixture.root commit-tree $tree -p $fixture.base -m "remote drift").Trim()
            $driftGate = Join-Path $fixture.root 'build\drift-gate.ps1'
            $driftBody = 'param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot); $q=Join-Path (Get-Location) ''build\test-results\qualification''; New-Item -ItemType Directory -Force -Path $q|Out-Null; foreach($n in @(''full.json'',''develop.json'',''develop-e2e-summary.json'')){Set-Content (Join-Path $q $n) ''{}''}; & git push origin ''__SHA__:refs/heads/develop'' *> $null; if($LASTEXITCODE -ne 0){exit 9}; exit 0'.Replace('__SHA__', $drift)
            Set-Content -LiteralPath $driftGate -Value $driftBody
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $driftGate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "blocks a duplicate while an orphan gate is alive and journals stale recovery" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture; New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null; Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\DeliveryRecovery.Tests.ps1") -Encoding UTF8 -Value "Describe 'delivery recovery' { It 'works' { `$true | Should -BeTrue } }"; & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: recovery fixture" *> $null; Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $lockRoot = Join-Path $fixture.root ".git\itl\delivery-operation"; New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null; $acquiring = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $acquiring.exitCode | Should -Not -Be 0; $acquiring.stderr | Should -Match "acquiring the shared lock"; $pesterProcess = Get-Process -Id $PID
            $operation = [ordered]@{ schemaVersion=1; id=[guid]::NewGuid().ToString("N"); action="PublishDevelop"; startedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString("o"); ownerPid=999999; ownerProcessStartedAt=[DateTime]::UtcNow.AddDays(-1).ToString("o"); mode="Develop"; workingRoot=""; gatePid=$PID; gateProcessStartedAt=$pesterProcess.StartTime.ToUniversalTime().ToString("o"); gateStatus="running"; runRecordPath="" }; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $status = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json; $status.activeOperation.status | Should -Be "running"; $status.activeOperation.gateAlive | Should -BeTrue; $duplicate = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $duplicate.exitCode | Should -Not -Be 0; $duplicate.stderr | Should -Match "already active"
            $summaryRoot = Join-Path $fixture.root "build\test-results\local"; New-Item -ItemType Directory -Force -Path $summaryRoot | Out-Null; $summaryStarted = [DateTime]::UtcNow.AddSeconds(-2); $summaryFinished = [DateTime]::UtcNow.AddSeconds(-1); $summary = [ordered]@{ mode="Targeted"; status="failed"; startedAt=$summaryStarted.ToString("o"); finishedAt=$summaryFinished.ToString("o"); error="fixture interrupted"; tests=[ordered]@{passed=0;failed=1;skipped=0}; stages=@() }; [IO.File]::WriteAllText((Join-Path $summaryRoot "check-summary.json"), (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $operation.gatePid = 999998; $operation.gateProcessStartedAt = [DateTime]::UtcNow.AddDays(-1).ToString("o"); $operation.workingRoot = $fixture.root; $operation.mode = "Targeted"; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')); ($published.stdout | ConvertFrom-Json).status | Should -Be "published"; Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\operations\$($operation.id).json") | Should -BeTrue; $history = ((Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json).runHistory; @($history.lastRuns | Where-Object { [string]$_.error -match "Recovered after the delivery wrapper" }).Count | Should -Be 1
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "never uses force push for develop or master" {
        $text = Get-Content -LiteralPath $DeliveryScript -Raw -Encoding UTF8; $text | Should -Not -Match 'push[^\r\n]*(--force|-f\b|--force-with-lease)'
        foreach ($marker in @('HEAD:refs/heads/develop', 'push", "--atomic"', 'HEAD:refs/heads/master')) { $text | Should -Match ([regex]::Escape($marker)) }
    }
}
