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
        & git init --bare $remote *> $null
        & git -C $root init *> $null
        & git -C $root config user.name "ITL Test"
        & git -C $root config user.email "itl-test@example.invalid"
        & git -C $root switch -c develop *> $null
        Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding UTF8 -Value "build/"
        Set-Content -LiteralPath (Join-Path $root "README.md") -Encoding UTF8 -Value "base"
        & git -C $root add .gitignore README.md
        & git -C $root commit -m base *> $null
        & git -C $root remote add origin $remote
        & git -C $root push -u origin develop *> $null
        $fakeGate = Join-Path $root "fake-gate.ps1"
        Set-Content -LiteralPath $fakeGate -Encoding UTF8 -Value @'
param([string]$Mode, [string]$BaseRef, [string[]]$CoverageContract, [string]$AiRulesSource, [string]$E2EProjectRoot); $CoverageContract = @($CoverageContract -split ','); if ($CoverageContract -and @($CoverageContract).Count -ne 2) { exit 12 }
if ($Mode -eq 'Develop') {
    $qualification = Join-Path (Get-Location) 'build\test-results\qualification'
    New-Item -ItemType Directory -Force -Path $qualification | Out-Null
    Set-Content -LiteralPath (Join-Path $qualification 'full.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $qualification 'develop-e2e-summary.json') -Encoding UTF8 -Value '{}'
}
exit 0
'@
        & git -C $root add fake-gate.ps1
        & git -C $root commit -m "test: add gate" *> $null
        & git -C $root push origin develop *> $null
        return [pscustomobject]@{ root = $root; remote = $remote; gate = $fakeGate; base = (& git -C $root rev-parse HEAD).Trim() }
    }
    function Remove-DeliveryFixture {
        param([object]$Fixture)
        if ($Fixture) {
            & git -C $Fixture.root worktree prune *> $null
            Remove-Item -LiteralPath $Fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $Fixture.remote -Recurse -Force -ErrorAction SilentlyContinue
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
    }
    It "registers base and head atomically for a path with Cyrillic and spaces" {
        $fixture = $null
        $parallelRoot = ""
        try {
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
    It "refuses executable changes without tests or an explicit reused contract" {
        $fixture = $null
        try {
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
        $fixture = $null
        try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'published'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: publish" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "publish") | Out-Null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'))
            ($result.stdout | ConvertFrom-Json).status | Should -Be "published"
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $head
            $tree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\qualifications\$tree\develop.json") | Should -BeTrue
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "preserves the queue when origin develop moves during qualification" {
        $fixture = $null
        try {
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
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $driftGate + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -Not -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
    It "never uses force push for develop or master" {
        $text = Get-Content -LiteralPath $DeliveryScript -Raw -Encoding UTF8
        $text | Should -Not -Match 'push[^\r\n]*(--force|-f\b|--force-with-lease)'
        $text | Should -Match 'HEAD:refs/heads/develop'
        $text | Should -Match 'push", "--atomic"'
        $text | Should -Match 'HEAD:refs/heads/master'
    }
}
