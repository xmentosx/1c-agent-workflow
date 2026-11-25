BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:SourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

    function Invoke-RepairGit {
        param([string]$Root, [string[]]$Arguments)
        $output = & git -C $Root -c core.quotepath=false @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
        return ($output -join "`n").Trim()
    }

    function Write-RepairFixtureFile {
        param([string]$Root, [string]$Relative, [string]$Content)
        $path = Join-Path $Root $Relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    }

    function New-RepairFixture {
        $base = Join-Path $TestDrive ('ремонт с пробелом ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $root = Join-Path $base 'source repo'
        [void][IO.Directory]::CreateDirectory($root)
        & git init --quiet $root
        Invoke-RepairGit $root @('config', 'user.email', 'repair@example.test') | Out-Null
        Invoke-RepairGit $root @('config', 'user.name', 'Repair Test') | Out-Null
        foreach ($name in @('source-repair.ps1', 'git-path-list.ps1', 'source-delivery-process.ps1', 'source-proof-json.ps1',
                'source-e2e-artifact-discovery.ps1', 'stand-env-identity.ps1', 'quality-contracts.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:SourceRoot "scripts\$name") -Destination (Join-Path ([IO.Directory]::CreateDirectory((Join-Path $root 'scripts')).FullName) $name)
        }
        # Owner stubs record their exact arguments; the repair loop must call
        # them from the repair worktree, never reimplement them.
        $record = @'
$stubArgs = [string[]]@($args)
$entry = [ordered]@{ script = [IO.Path]::GetFileName($PSCommandPath); root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)); args = $stubArgs }
[IO.File]::AppendAllText($env:ITL_TEST_REPAIR_LOG, (($entry | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
function Get-StubValue([string]$Name) { $index = [Array]::IndexOf($stubArgs, $Name); if ($index -ge 0) { return $stubArgs[$index + 1] } return '' }
'@
        Write-RepairFixtureFile $root 'scripts/invoke-pester-shards.ps1' ($record + @'
$output = Get-StubValue '-OutputRoot'
if ($stubArgs -contains '-PlanOnly') {
    '{"files":[{"path":"tests/pester/Example.Tests.ps1","execution":"reuse"},{"path":"tests/pester/Second.Tests.ps1","execution":"execute"}]}'
    exit 0
}
[void][IO.Directory]::CreateDirectory((Join-Path $output 'pester-shards'))
[IO.File]::WriteAllText((Join-Path $output 'pester-shards\summary.json'), '{"status":"passed"}')
'@)
        Write-RepairFixtureFile $root 'scripts/invoke-develop-e2e.ps1' ($record + @'
$raw = Get-StubValue '-OutputPath'; $journey = Get-StubValue '-Journey'
$all = @{ upgrade = @('update', 'configuration-rejection', 'verification-export'); fresh = @('install', 'branch') }
$coverage = if (Get-StubValue '-Scenario') { @((Get-StubValue '-Scenario').Split(',')) } else { $all[$journey] }
$failed = $env:ITL_TEST_REPAIR_JOURNEY_FAIL -eq $journey
$result = [ordered]@{ name = $journey; coverage = $coverage; status = $(if ($failed) { 'failed' } else { 'passed' }) }
if ($journey -eq 'upgrade' -and 'configuration-rejection' -in $coverage) { $result.configurationRejection = @{ status = 'passed' } }
$tree = (& git -C (Get-StubValue '-CandidateRoot') rev-parse 'HEAD^{tree}').Trim()
$report = [ordered]@{ status = $result.status; candidate = @{ tree = $tree }; journeys = @($result) }
[IO.File]::WriteAllText($raw, ($report | ConvertTo-Json -Depth 5))
if ($failed) { exit 1 }
[IO.File]::WriteAllText("$raw.$journey.qualification.json", '{}')
'@)
        Write-RepairFixtureFile $root 'scripts/source-e2e-fixture.ps1' $record
        Write-RepairFixtureFile $root 'scripts/source-delivery.ps1' ($record + @'
if ((Get-StubValue '-Action') -eq 'RegisterChange') {
    $repo = Get-StubValue '-RepositoryRoot'
    & git -C $repo update-ref ("refs/itl/develop-queue/" + (Get-StubValue '-QueueId') + '/head') (& git -C $repo rev-parse HEAD)
}
'@)
        Write-RepairFixtureFile $root '.gitignore' "build/`n"
        Write-RepairFixtureFile $root 'tests/pester/Example.Tests.ps1' 'Describe x {}'
        Write-RepairFixtureFile $root 'tests/pester/Second.Tests.ps1' 'Describe y {}'
        Write-RepairFixtureFile $root 'tests/quality-contracts.json' '{"developJourneys":{"routes":{"upgrade":{"hardSeconds":120},"fresh":{"hardSeconds":120}},"scenarios":{"upgrade":[{"id":"update"},{"id":"configuration-rejection"},{"id":"verification-export"}],"fresh":[{"id":"install"},{"id":"branch"}]}}}'
        $artifacts = [ordered]@{}
        foreach ($name in @('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'VANESSA_MCP_CLIENT_CFE_PATH', 'ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')) {
            $path = Join-Path $base "артефакт $name.bin"
            [IO.File]::WriteAllText($path, $name)
            $artifacts[$name] = @{ path = $path; sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $lock = [ordered]@{ dependencies = [ordered]@{
            vanessaAutomation = @{ sha256 = $artifacts.ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE.sha; compatibilityVersion = '1'; downstreamRevision = 'r1'; assetName = 'va.zip' }
            vanessaMcp = @{ clientMcp = @{ sha256 = $artifacts.VANESSA_MCP_CLIENT_CFE_PATH.sha; assetName = 'client.cfe'; version = '1' } }
            itlOndemandMcp = @{ sha256 = $artifacts.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE.sha; assetName = 'ondemand.exe'; version = '1' }
        } }
        Write-RepairFixtureFile $root 'templates/dependency-lock.json' ($lock | ConvertTo-Json -Depth 5)
        Invoke-RepairGit $root @('add', '-A') | Out-Null
        Invoke-RepairGit $root @('commit', '--quiet', '-m', 'candidate') | Out-Null
        $candidate = Invoke-RepairGit $root @('rev-parse', 'HEAD')
        $stand = Join-Path $base 'стенд e2e'
        Write-RepairFixtureFile $stand '.agent-1c/release-e2e.json' '{}'
        $fixture = [pscustomobject]@{ base = $base; root = $root; candidate = $candidate; stand = $stand; artifacts = $artifacts
            repair = (Join-Path $base 'ремонт worktree'); log = (Join-Path $base 'calls.jsonl'); planId = ('a' * 64) }
        Write-RepairAttempt $fixture ([ordered]@{ schemaVersion = 1; candidate = $candidate; planId = $fixture.planId; replanQueueScope = 'Frozen'; queue = @(); fullReleaseRequested = $false })
        return $fixture
    }

    function Write-RepairAttempt {
        param([object]$Fixture, [object]$Attempt)
        Write-RepairFixtureFile $Fixture.root '.git/itl/publication-attempts/develop.json' ($Attempt | ConvertTo-Json -Depth 5)
    }

    function Invoke-Repair {
        param([object]$Fixture, [string[]]$Arguments)
        $env:ITL_TEST_REPAIR_LOG = $Fixture.log
        if (Test-Path -LiteralPath $Fixture.log) { Remove-Item -LiteralPath $Fixture.log }
        foreach ($name in $Fixture.artifacts.Keys) { Set-Item -Path "Env:$name" -Value $Fixture.artifacts[$name].path }
        try { return Invoke-TestPowerShellFile -FilePath (Join-Path $Fixture.root 'scripts\source-repair.ps1') -Arguments $Arguments }
        finally { foreach ($name in $Fixture.artifacts.Keys) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue } }
    }

    function Get-RepairCalls {
        param([object]$Fixture)
        if (-not (Test-Path -LiteralPath $Fixture.log)) { return @() }
        return @([IO.File]::ReadAllLines($Fixture.log, [Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-RepairJson {
        param([object]$Result)
        $lines = @($Result.stdout)
        $start = [Array]::LastIndexOf([string[]]$lines, '{')
        return ($lines[$start..($lines.Count - 1)] -join [Environment]::NewLine) | ConvertFrom-Json
    }

    function Get-CallValue {
        param([object]$Call, [string]$Name)
        $values = @($Call.args)
        $index = [Array]::IndexOf([string[]]$values, $Name)
        if ($index -lt 0) { return $null }
        return [string]$values[$index + 1]
    }

    function Add-RepairCommit {
        param([object]$Fixture, [string]$Name)
        Write-RepairFixtureFile $Fixture.repair "repair/$Name.txt" $Name
        Invoke-RepairGit $Fixture.repair @('add', '-A') | Out-Null
        Invoke-RepairGit $Fixture.repair @('commit', '--quiet', '-m', $Name) | Out-Null
        return Invoke-RepairGit $Fixture.repair @('rev-parse', 'HEAD')
    }
}

Describe 'Source publication repair loop' {
    It 'refuses to touch stands while a delivery operation is live' {
        $fixture = New-RepairFixture
        $self = Get-Process -Id $PID
        Write-RepairFixtureFile $fixture.root '.git/itl/delivery-operation/operation.json' (([ordered]@{
            id = 'live'; action = 'PublishDevelop'; ownerPid = $PID; ownerProcessStartedAt = $self.StartTime.ToUniversalTime().ToString('o'); startedAt = [DateTime]::UtcNow.ToString('o'); mode = ''; workingRoot = ''; gatePid = 0; gateProcessStartedAt = '' }) | ConvertTo-Json)
        $result = Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)
        $result.exitCode | Should -Not -Be 0
        $result.combinedText | Should -Match 'REPAIR_DELIVERY_ACTIVE'
        Test-Path -LiteralPath $fixture.repair | Should -BeFalse
    }

    It 'creates, reuses and fast-forwards the repair worktree from the frozen candidate' {
        $fixture = New-RepairFixture
        $result = Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        Invoke-RepairGit $fixture.repair @('rev-parse', 'HEAD') | Should -BeExactly $fixture.candidate
        Invoke-RepairGit $fixture.repair @('branch', '--show-current') | Should -BeExactly ('itl/repair/' + $fixture.candidate.Substring(0, 8))
        $head = Add-RepairCommit $fixture 'first'
        (Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)).exitCode | Should -Be 0
        Invoke-RepairGit $fixture.repair @('rev-parse', 'HEAD') | Should -BeExactly $head
        # An accepted replacement merges the repair into a newer candidate.
        Invoke-RepairGit $fixture.root @('merge', '--quiet', '--no-ff', '-m', 'merge repair', $head) | Out-Null
        $merged = Invoke-RepairGit $fixture.root @('rev-parse', 'HEAD')
        Write-RepairAttempt $fixture ([ordered]@{ schemaVersion = 1; candidate = $merged; planId = ('b' * 64); replanQueueScope = 'Frozen'; queue = @() })
        (Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)).exitCode | Should -Be 0
        Invoke-RepairGit $fixture.repair @('rev-parse', 'HEAD') | Should -BeExactly $merged
    }

    It 'runs only the named tests and journey from a clean committed repair' {
        $fixture = New-RepairFixture
        (Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)).exitCode | Should -Be 0
        Write-RepairFixtureFile $fixture.repair 'repair/dirty.txt' 'dirty'
        $dirty = Invoke-Repair $fixture @('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Test', 'Example.Tests.ps1')
        $dirty.combinedText | Should -Match 'REPAIR_UNCOMMITTED'
        @(Get-RepairCalls $fixture).Count | Should -Be 0
        $head = Add-RepairCommit $fixture 'dirty'
        $result = Invoke-Repair $fixture @('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Test', 'Example.Tests.ps1, Second.Tests.ps1', '-Journey', 'upgrade',
            '-Scenario', 'update', '-E2EProjectRoot', $fixture.stand, '-AiRulesSource', $fixture.base, '-AgentTarget', 'codex')
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        $summary = Get-RepairJson $result
        $summary.status | Should -BeExactly 'passed'
        $summary.head | Should -BeExactly $head
        @($summary.results | Where-Object { $_.PSObject.Properties['journey'] })[0].reusableProof | Should -BeTrue
        $calls = @(Get-RepairCalls $fixture)
        @($calls.script) | Should -Be @('invoke-pester-shards.ps1', 'source-e2e-fixture.ps1', 'source-e2e-fixture.ps1', 'invoke-develop-e2e.ps1')
        foreach ($call in $calls) { $call.root | Should -BeExactly ([IO.Path]::GetFullPath($fixture.repair)) }
        $selection = Get-Content -LiteralPath (Get-CallValue $calls[0] '-SelectionPath') -Raw -Encoding UTF8 | ConvertFrom-Json
        $selection.schemaVersion | Should -Be 1
        # powershell.exe -File delivers the comma list as one argument.
        @($selection.tests) | Should -Be @('tests/pester/Example.Tests.ps1', 'tests/pester/Second.Tests.ps1')
        @($calls[1..2] | ForEach-Object { Get-CallValue $_ '-Phase' }) | Should -Be @('Release', 'Develop')
        $journey = $calls[3]
        Get-CallValue $journey '-CandidateRoot' | Should -BeExactly ([IO.Path]::GetFullPath($fixture.repair))
        Get-CallValue $journey '-ProjectRoot' | Should -BeExactly $fixture.stand
        Get-CallValue $journey '-Scenario' | Should -BeExactly 'update'
        Get-CallValue $journey '-AgentTarget' | Should -BeExactly 'codex'
        $binding = Get-Content -LiteralPath (Get-CallValue $journey '-ArtifactBindingPath') -Raw -Encoding UTF8 | ConvertFrom-Json
        $binding.paths.VANESSA_MCP_CLIENT_CFE_PATH | Should -BeExactly $fixture.artifacts.VANESSA_MCP_CLIENT_CFE_PATH.path
    }

    It 'narrows a repeated journey to its failed scenarios and proves the rest through -Unproven' {
        $fixture = New-RepairFixture
        $positive = Join-Path $fixture.base 'положительный стенд'
        Write-RepairFixtureFile $positive '.agent-1c/release-e2e.json' '{}'
        Write-RepairFixtureFile $fixture.stand '.agent-1c/release-e2e.json' (@{ developConfigurationRejection = @{ positiveProjectRoot = $positive } } | ConvertTo-Json)
        (Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)).exitCode | Should -Be 0
        Add-RepairCommit $fixture 'fix' | Out-Null
        $stand = @('-E2EProjectRoot', $fixture.stand, '-AiRulesSource', $fixture.base, '-AgentTarget', 'kilocode')
        $journeyCalls = { @(Get-RepairCalls $fixture | Where-Object script -eq 'invoke-develop-e2e.ps1') }
        # 2026-10-27: the negative scenario passed, then the positive check failed.
        $env:ITL_TEST_REPAIR_JOURNEY_FAIL = 'upgrade'
        try { (Invoke-Repair $fixture (@('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Journey', 'upgrade') + $stand)).exitCode | Should -Be 1 }
        finally { $env:ITL_TEST_REPAIR_JOURNEY_FAIL = $null }
        Get-CallValue (& $journeyCalls)[0] '-Scenario' | Should -BeNullOrEmpty
        $repeat = Invoke-Repair $fixture (@('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Journey', 'upgrade') + $stand)
        $repeat.exitCode | Should -Be 0 -Because $repeat.combinedText
        Get-CallValue (& $journeyCalls)[0] '-Scenario' | Should -BeExactly 'update,verification-export'
        $unproven = Invoke-Repair $fixture (@('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Unproven') + $stand)
        $unproven.exitCode | Should -Be 0 -Because $unproven.combinedText
        $calls = @(Get-RepairCalls $fixture)
        @($calls | Where-Object { $_.args -contains '-PlanOnly' }).Count | Should -Be 1
        $selectionCall = @($calls | Where-Object { $_.script -eq 'invoke-pester-shards.ps1' -and $_.args -notcontains '-PlanOnly' })[0]
        @((Get-Content -LiteralPath (Get-CallValue $selectionCall '-SelectionPath') -Raw -Encoding UTF8 | ConvertFrom-Json).tests) | Should -Be @('tests/pester/Second.Tests.ps1')
        $journeys = & $journeyCalls
        @($journeys | ForEach-Object { Get-CallValue $_ '-Journey' }) | Should -Be @('upgrade', 'fresh')
        Get-CallValue $journeys[0] '-Scenario' | Should -BeExactly 'configuration-rejection'
        Get-CallValue $journeys[1] '-Scenario' | Should -BeNullOrEmpty
        $again = Invoke-Repair $fixture (@('-Action', 'Run', '-RepairRoot', $fixture.repair, '-Unproven') + $stand)
        $again.exitCode | Should -Be 0 -Because $again.combinedText
        @(& $journeyCalls).Count | Should -Be 0
    }

    It 'registers once against the candidate and continues the same frozen pin after acceptance' {
        $fixture = New-RepairFixture
        (Invoke-Repair $fixture @('-Action', 'Start', '-RepairRoot', $fixture.repair)).exitCode | Should -Be 0
        $stand = @('-E2EProjectRoot', $fixture.stand, '-AiRulesSource', $fixture.base, '-AgentTarget', 'codex')
        (Invoke-Repair $fixture (@('-Action', 'Finish', '-RepairRoot', $fixture.repair) + $stand)).combinedText | Should -Match 'REPAIR_EMPTY'
        $head = Add-RepairCommit $fixture 'fix'
        $id = 'repair-' + $fixture.candidate.Substring(0, 8)
        $result = Invoke-Repair $fixture (@('-Action', 'Finish', '-RepairRoot', $fixture.repair) + $stand)
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        $calls = @(Get-RepairCalls $fixture)
        @($calls | ForEach-Object { Get-CallValue $_ '-Action' }) | Should -Be @('RegisterChange', 'PublishDevelop')
        Get-CallValue $calls[0] '-QueueId' | Should -BeExactly $id
        Get-CallValue $calls[0] '-BaseRef' | Should -BeExactly $fixture.candidate
        Get-CallValue $calls[1] '-Replan' | Should -BeExactly $fixture.planId
        Get-CallValue $calls[1] '-ReplanQueueScope' | Should -BeExactly 'Frozen'
        Get-CallValue $calls[1] '-FrozenRepair' | Should -BeExactly "$id@$head"
        Get-CallValue $calls[1] '-E2EProjectRoot' | Should -BeExactly $fixture.stand
        @($calls[1].args) | Should -Not -Contain '-RequireRelease'
        # The replacement was accepted, then its gate failed: repeat Finish.
        Invoke-RepairGit $fixture.root @('merge', '--quiet', '--no-ff', '-m', 'merge repair', $head) | Out-Null
        Write-RepairAttempt $fixture ([ordered]@{ schemaVersion = 1; candidate = (Invoke-RepairGit $fixture.root @('rev-parse', 'HEAD')); planId = ('c' * 64)
            replacesPlanId = $fixture.planId; replanQueueScope = 'Frozen'; queue = @(@{ id = $id; base = $fixture.candidate; head = $head }) })
        $again = Invoke-Repair $fixture (@('-Action', 'Finish', '-RepairRoot', $fixture.repair) + $stand)
        $again.exitCode | Should -Be 0 -Because $again.combinedText
        $calls = @(Get-RepairCalls $fixture)
        @($calls | ForEach-Object { Get-CallValue $_ '-Action' }) | Should -Be @('PublishDevelop')
        Get-CallValue $calls[0] '-Replan' | Should -BeExactly $fixture.planId
        Get-CallValue $calls[0] '-FrozenRepair' | Should -BeExactly "$id@$head"
    }
}
