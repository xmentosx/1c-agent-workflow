BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
    function New-OnDemandLockFixture {
        $root = Join-Path $TestDrive 'Замок с пробелом'
        foreach ($relative in @('scripts/ondemand-mcp-lock.ps1', 'scripts/Build-ItlOnDemandMcp.ps1', 'scripts/git-path-list.ps1', 'templates/dependency-lock.json', '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json')) {
            $target = Join-Path $root $relative; [void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
        }
        foreach ($relative in @(Get-RepositoryGitPathList -RepositoryRoot $RepoRoot -Arguments @('ls-files', '-z', '--', 'tools/itl-ondemand-mcp'))) {
            $target = Join-Path $root $relative; [void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
        }
        & git -C $root init -q
        [IO.File]::WriteAllText((Join-Path $root '.git/info/exclude'), "/tools/itl-ondemand-mcp/build/`n")
        & git -C $root add --all; & git -C $root -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base
        return $root
    }
    function Save-OnDemandLockFixture([string]$Root, [string]$Message) {
        $null = & git -C $Root add --all 2>&1; $null = & git -C $Root -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm $Message 2>&1
        return [string](& git -C $Root rev-parse HEAD).Trim()
    }
    function Invoke-OnDemandLockFixture([string]$Root, [hashtable]$Arguments) {
        $savedProxy = $env:GOPROXY; $savedToolchain = $env:GOTOOLCHAIN
        try {
            $env:GOPROXY = 'off'; $env:GOTOOLCHAIN = 'local'
            return & (Join-Path $Root 'scripts/ondemand-mcp-lock.ps1') -RepositoryRoot $Root @Arguments
        } finally { $env:GOPROXY = $savedProxy; $env:GOTOOLCHAIN = $savedToolchain }
    }
}

Describe 'Locked on-demand MCP build identity' {
    It 'stops a stale lock before Pester, passes test or documentation edits, and repins every copy from one build' {
        $root = New-OnDemandLockFixture
        $base = (& git -C $root rev-parse HEAD).Trim()
        $main = Join-Path $root 'tools/itl-ondemand-mcp/main.go'
        $mainText = [IO.File]::ReadAllText($main)
        # 60fd9956: production Go changed while the lock kept the previous SHA-256.
        [IO.File]::WriteAllText($main, ($mainText -replace '(?m)^const version = "[^"]*"', 'const version = "9.9.9"'))
        $null = Save-OnDemandLockFixture $root 'production Go change without repin'
        $report = Join-Path $TestDrive 'lock report.json'
        { Invoke-OnDemandLockFixture $root @{ Action = 'Verify'; BaseRef = $base; OutputPath = $report } } | Should -Throw '*ONDEMAND_LOCK_STALE*-Action Repin*'
        $failed = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        $failed.status | Should -Be 'failed'
        @($failed.changedInputs) | Should -Contain 'tools/itl-ondemand-mcp/main.go'

        # Go tests and documentation are not build inputs: no build, no repin.
        $docsBase = Save-OnDemandLockFixture $root 'baseline for non-build edits'
        [IO.File]::AppendAllText((Join-Path $root 'tools/itl-ondemand-mcp/README.md'), "`nnote`n")
        [IO.File]::WriteAllText((Join-Path $root 'tools/itl-ondemand-mcp/added_test.go'), "package main`n")
        $null = Save-OnDemandLockFixture $root 'tests and docs only'
        (Invoke-OnDemandLockFixture $root @{ Action = 'Verify'; BaseRef = $docsBase }).status | Should -Be 'skipped'

        $repinned = Invoke-OnDemandLockFixture $root @{ Action = 'Repin'; Version = '9.9.9' }
        $repinned.releaseTag | Should -Be 'itl-ondemand-mcp-v9.9.9'
        $null = Save-OnDemandLockFixture $root 'repin'
        $verified = Invoke-OnDemandLockFixture $root @{ Action = 'Verify'; BaseRef = $base }
        $verified.status | Should -Be 'passed'
        $verified.builtSha256 | Should -Be $repinned.sha256
        $lock = (Get-Content -LiteralPath (Join-Path $root 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.itlOndemandMcp
        $manifest = Get-Content -LiteralPath (Join-Path $root '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.sha256 | Should -Be $repinned.sha256
        @(Get-QualityOnDemandVersionMismatches -Compatibility $manifest -LockEntry $lock -MainSource ([IO.File]::ReadAllText($main))) | Should -BeNullOrEmpty
        # Every other lock entry and byte layout stays as it was.
        $before = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates/dependency-lock.json'))
        $after = [IO.File]::ReadAllText((Join-Path $root 'templates/dependency-lock.json'))
        ($after -split "`r?`n").Count | Should -Be (($before -split "`r?`n").Count)
        $after.Contains("`r`n") | Should -Be $before.Contains("`r`n")
    }
}
