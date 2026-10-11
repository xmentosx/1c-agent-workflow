BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {
        It "completes and reruns an explicitly non-reusable passed file through the real shard runner" {
        $root = Join-Path $TestDrive 'Некэшируемая проверка с пробелом'
        $testRoot = Join-Path $root 'tests/pester'
        New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
        & git -C $root init *> $null
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value "out/`ncounter.txt"
        $testText = "Describe 'external runtime' { It 'actually executes' { Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt') -Value 'executed'; `$true | Should -BeTrue } }"
        Set-Content -LiteralPath (Join-Path $testRoot 'External.Tests.ps1') -Encoding UTF8 -Value $testText
        $catalog = [ordered]@{
            schemaVersion=1; pesterNonReusableTests=@('tests/pester/External.Tests.ps1')
            contracts=@([ordered]@{id='external';owner='fixture';primaryTest='tests/pester/External.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/External.Tests.ps1')})
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $selectionPath = Join-Path $root 'selection.json'
        [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/External.Tests.ps1"]}', [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -m fixture *> $null
        $invoke = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $output = Join-Path $root 'out'
        foreach ($attempt in 1..2) {
            $run = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @('-RepositoryRoot', $root, '-OutputRoot', $output, '-JunitPath', (Join-Path $output 'pester.xml'), '-WorkerCount', '1', '-SelectionPath', $selectionPath)
            $run.exitCode | Should -Be 0 -Because ($run.stderr -join [Environment]::NewLine)
            $summary = ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $summary.status | Should -Be 'passed'
            $summary.executedWorkerCount | Should -Be 1
            $summary.reusedWorkerCount | Should -Be 0
            $summary.workers[0].inputDigest | Should -BeNullOrEmpty
        }
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
    }

    It "owns shard archive and cache hashing without Get-FileHash" {
        $runnerPath = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"
        $hashOwnerPath = Join-Path $RepoRoot "scripts\invoke-pester-runtime.ps1"
        $runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
        $runner | Should -Not -Match '\bGet-FileHash\b'

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($hashOwnerPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-PesterShardFileSha256" }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $ownerOffset = $runner.IndexOf('. (Join-Path $PSScriptRoot "invoke-pester-runtime.ps1")', [StringComparison]::Ordinal)
        $ownerOffset | Should -BeGreaterThan -1
        $ownerOffset | Should -BeLessThan $runner.IndexOf('function Initialize-VanessaSourceBuildArchiveForPester', [StringComparison]::Ordinal)
        $ownerOffset | Should -BeLessThan $runner.IndexOf('function Get-ShardInputDigest', [StringComparison]::Ordinal)

        $payloadPath = Join-Path $TestDrive "hash probe data.bin"
        $payload = [byte[]](0, 1, 2, 3, 10, 13, 127, 128, 255)
        [IO.File]::WriteAllBytes($payloadPath, $payload)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($sha256.ComputeHash($payload))).Replace("-", "").ToLowerInvariant() } finally { $sha256.Dispose() }

        $probePath = Join-Path $TestDrive "local-shard-hash.ps1"
        [IO.File]::WriteAllText($probePath, @"
param([string]`$Path)
function Get-FileHash { throw "Get-FileHash must not be used" }
$($definition.Extent.Text)
Get-PesterShardFileSha256 -Path `$Path
"@, [Text.UTF8Encoding]::new($false))
        $probe = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @("-Path", $payloadPath)
        $probe.exitCode | Should -Be 0
        $probe.stdout[-1] | Should -Be $expected
    }

    It "reuses a focused dirty proof after the identical files are committed" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl focused путь " + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"; $fixtureRoot = Join-Path $root "fixture"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $fixtureRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $fixtureRoot "owner.ps1") -Encoding UTF8 -Value "owner-v1"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m baseline *> $null
            Set-Content -LiteralPath (Join-Path $fixtureRoot "owner.ps1") -Encoding UTF8 -Value "owner-v2"
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# focused proof"
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine); $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            & git -C $root add --all; & git -C $root commit -m proven *> $null
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0 -Because ((@($secondRun.stdout) + @($secondRun.stderr)) -join [Environment]::NewLine); $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1; [string]$second.workers[0].inputDigest | Should -Be ([string]$first.workers[0].inputDigest)
            $second.legacyDigestCount | Should -Be 0
            $second.fingerprintPlanMs | Should -BeGreaterOrEqual 0
            $second.cacheLookupMs | Should -BeGreaterOrEqual 0
            $second.workerSpanMs | Should -BeGreaterOrEqual 0
            $second.pesterWorkers.requested | Should -Be 1
            $second.pesterWorkers.explicit | Should -BeTrue
            $second.pesterWorkers.effective | Should -Be 1
            $out3 = Join-Path $root "out3"; $implicitRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out3, "-JunitPath", (Join-Path $out3 "pester.xml"), "-SelectionPath", $selectionPath); $implicitRun.exitCode | Should -Be 0 -Because ((@($implicitRun.stdout) + @($implicitRun.stderr)) -join [Environment]::NewLine); $implicit = ($implicitRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $implicit.pesterWorkers.requested | Should -Be 3
            $implicit.pesterWorkers.explicit | Should -BeFalse
            $implicit.pesterWorkers.effective | Should -Be 3
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reuses only a passed shard with the same owner inputs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-cache-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        $previousArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
        try { New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"; & git -C $root config core.autocrlf true
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $archiveOne = Join-Path $root "archive путь one.zip"; $archiveTwo = Join-Path $root "archive путь two.zip"; [IO.File]::WriteAllBytes($archiveOne, [byte[]](1,2,3,4)); [IO.File]::WriteAllBytes($archiveTwo, [byte[]](1,2,3,4))
            $catalog = [ordered]@{ schemaVersion=1; pesterExternalInputs=[ordered]@{'tests/pester/Cache.Tests.ps1'=@('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE')}; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveOne
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine); $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $digest = [string]$first.workers[0].inputDigest; $entryRoot = Join-Path $root ".git\itl\pester-shards\v1\$digest"; $nested = Join-Path $entryRoot ".$digest.fixture.tmp"; New-Item -ItemType Directory -Path $nested | Out-Null; Get-ChildItem -LiteralPath $entryRoot -File | Move-Item -Destination $nested
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveTwo
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
            $originalBytes = [IO.File]::ReadAllBytes($testPath); $originalHasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
            $lfText = (Get-Content -LiteralPath $testPath -Raw -Encoding UTF8).Replace("`r`n", "`n"); [IO.File]::WriteAllText($testPath, $lfText, [Text.UTF8Encoding]::new($originalHasBom)); (& git -C $root diff --quiet -- "tests/pester/Cache.Tests.ps1"); $LASTEXITCODE | Should -Be 0
            $out3 = Join-Path $root "out3"; $lineEndingRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out3, "-JunitPath", (Join-Path $out3 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $lineEndingRun.exitCode | Should -Be 0 -Because ((@($lineEndingRun.stdout) + @($lineEndingRun.stderr)) -join [Environment]::NewLine); $lineEnding = ($lineEndingRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $lineEnding.executedWorkerCount | Should -Be 0; $lineEnding.reusedWorkerCount | Should -Be 1; [string]$lineEnding.workers[0].inputDigest | Should -Be $digest
            [IO.File]::WriteAllBytes($archiveTwo, [byte[]](9,8,7,6)); $out4 = Join-Path $root "out4"; $externalRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out4, "-JunitPath", (Join-Path $out4 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $externalRun.exitCode | Should -Be 0; $external = ($externalRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $external.executedWorkerCount | Should -Be 1; [string]$external.workers[0].inputDigest | Should -Not -Be $digest
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# changed owner input"; $out5 = Join-Path $root "out5"; $fifthRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out5, "-JunitPath", (Join-Path $out5 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $fifthRun.exitCode | Should -Be 0; $fifth = ($fifthRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $fifth.executedWorkerCount | Should -Be 1
        } finally { [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $previousArchive, 'Process'); Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps undeclared external identities out of a shard digest" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-external-scope-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        $previousArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process'); $previousRules = [Environment]::GetEnvironmentVariable('ITL_AI_RULES_SOURCE_PATH', 'Process')
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "Cache.Tests.ps1") -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $archiveOne = Join-Path $root "archive один.zip"; $archiveTwo = Join-Path $root "archive два.zip"; [IO.File]::WriteAllBytes($archiveOne, [byte[]](1)); [IO.File]::WriteAllBytes($archiveTwo, [byte[]](2))
            $rulesOne = Join-Path $root "rules один"; $rulesTwo = Join-Path $root "rules два"; New-Item -ItemType Directory -Path $rulesOne, $rulesTwo | Out-Null
            $catalog = [ordered]@{ schemaVersion=1; pesterExternalInputs=[ordered]@{}; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveOne; $env:ITL_AI_RULES_SOURCE_PATH = $rulesOne; $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0; $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveTwo; $env:ITL_AI_RULES_SOURCE_PATH = $rulesTwo; $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 1; $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 1; [string]$second.workers[0].inputDigest | Should -Be ([string]$first.workers[0].inputDigest)
        } finally { [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $previousArchive, 'Process'); [Environment]::SetEnvironmentVariable('ITL_AI_RULES_SOURCE_PATH', $previousRules, 'Process'); Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reuses an unchanged passed test file across runner and neighboring test repairs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl runner путь " + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"; $scriptRoot = Join-Path $root "scripts"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $scriptRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v1"
            Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding ASCII -Value "out*/"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m v1 *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; (Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)).exitCode | Should -Be 0
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v2"; Set-Content -LiteralPath (Join-Path $testRoot "Other.Tests.ps1") -Encoding UTF8 -Value "Describe 'other' { It 'changed' { `$true | Should -BeTrue } }"; & git -C $root add --all; & git -C $root commit -m v2 *> $null
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 1; $second.workers[0].reuseReason | Should -Be "exact owner input fingerprint"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "restarts a failed Pester stage at the corrected test file and then runs only its downstream files" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-file-checkpoint-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "A.Tests.ps1") -Encoding UTF8 -Value "Describe 'A' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'fails' { `$false | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "C.Tests.ps1") -Encoding UTF8 -Value "Describe 'C' { It 'passes' { `$true | Should -BeTrue } }"
            $contracts = @('A','B','C') | ForEach-Object { [ordered]@{id=$_;owner='fixture';primaryTest="tests/pester/$_.Tests.ps1";gate='full';budgetSeconds=30;paths=@("fixture/$_/*");tests=@("tests/pester/$_.Tests.ps1")} }
            [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ([ordered]@{schemaVersion=1;contracts=$contracts} | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/A.Tests.ps1","tests/pester/B.Tests.ps1","tests/pester/C.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $first = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $first.exitCode | Should -Not -Be 0
            $failedSummary = Get-Content -LiteralPath (Join-Path $out1 "pester-shards\summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($failedSummary.workers.paths | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @("A.Tests.ps1", "B.Tests.ps1")

            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'is fixed' { `$true | Should -BeTrue } }"
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.reusedWorkerCount | Should -Be 1; $second.executedWorkerCount | Should -Be 2
            @($second.workers | Where-Object execution -eq 'reused' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("A.Tests.ps1")
            @($second.workers | Where-Object execution -eq 'executed' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("B.Tests.ps1", "C.Tests.ps1")
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
