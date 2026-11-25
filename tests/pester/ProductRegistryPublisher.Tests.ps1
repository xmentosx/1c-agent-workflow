Describe 'G2 endpoint publication preserves the catalog' {
    It 'publishes explicit view descriptors and declared source identity without inventing an observed generation' {
        $config=[pscustomobject]@{bookStackProductDocsServer=@{views=@{corp=@{book_ids=@(10)}}}}
        Mock Get-HostId {'fixture'}
        $state=@{servers=@(@{id='bookstack';url='http://example.test/mcp';scope='global';indexedAt='observed';sourceFingerprint='generation'})}
        $entry=New-CurrentHostRegistryEntry -Config $config -State $state -PublishedAt 'fixture'
        $entry.servers[0].viewBindings[0].url | Should -Be 'http://example.test/mcp?view=corp'
        $entry.servers[0].viewBindings[0].selectors.book_ids | Should -Be @(10)
        $entry.servers[0].viewBindings[0].readiness | Should -Be 'unverified'
        $entry.servers[0].sourceIdentity.observedGeneration | Should -BeNullOrEmpty
        $entry.servers[0].sourceIdentity.observedAt | Should -BeNullOrEmpty
        $entry.servers[0].sourceIdentity.declaredSourceFingerprint | Should -Be 'generation'
        $entry.servers[0].sourceFingerprint | Should -Be 'generation'
        $entry.servers[0].sourceIdentity.provenance | Should -Match '^host-working-source;'
        $entry.servers[0].sourceIdentity.hostId | Should -Be 'fixture'
    }
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        $hostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($hostPath, [ref]$null, [ref]$null)
        $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text })
        . ([scriptblock]::Create(($definitions -join "`n")))
        $script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
        $script:OriginalHostGit = (Get-Command Invoke-Git).ScriptBlock
        $DryRun = $false
        function New-PublicationFixture {
            param([string]$Root)
            [void][IO.Directory]::CreateDirectory($Root)
            $remote = Join-Path $Root 'remote.git'
            $null = Invoke-RepositoryGit $Root @('init', '--bare', $remote)
            $state = Join-Path $Root 'state'
            [void][IO.Directory]::CreateDirectory($state)
            $checkout = Join-Path $state 'registry'
            $null = Invoke-RepositoryGit $Root @('clone', $remote, $checkout)
            $null = Invoke-RepositoryGit $checkout @('config', 'user.email', 'fixture@example.test')
            $null = Invoke-RepositoryGit $checkout @('config', 'user.name', 'Fixture')
            [void][IO.Directory]::CreateDirectory((Join-Path $checkout 'catalog'))
            [IO.File]::WriteAllText((Join-Path $checkout 'registry.json'), '{"schemaVersion":2,"hosts":[{"hostId":"other","servers":[],"configurations":[]}]}', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $checkout 'catalog/catalog.json'), '{"schemaVersion":1,"future":"preserve"}', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $checkout 'catalog/product-relations.json'), '{"schemaVersion":1,"future":[]}', $script:Utf8NoBom)
            $null = Invoke-RepositoryGit $checkout @('add', '.')
            $null = Invoke-RepositoryGit $checkout @('commit', '-m', 'initial')
            $null = Invoke-RepositoryGit $checkout @('push', '-u', 'origin', 'HEAD')
            return @{ root = $checkout; remote = $remote; config = @{ hostId = 'fixture'; stateRoot = $state; registryRepo = $remote; baseUrl = 'http://fixture.test' } }
        }
    }
    BeforeEach {
        Mock Read-HostState { @{ configurations = @(); servers = @() } }
        Mock Update-HostStateForPublish { throw 'Runtime refresh is outside this fixture' }
    }
    It 'publishes only registry.json, preserving exact catalog bytes, untracked files and other hosts' {
        $f = New-PublicationFixture (Join-Path $TestDrive ('host space ' + [char]0x041F))
        $before = (Get-FileHash (Join-Path $f.root 'catalog/catalog.json')).Hash
        [IO.File]::WriteAllText((Join-Path $f.root 'untracked.txt'), 'unrelated')
        Publish-Registry -Config $f.config -SkipRuntimeRefresh *> $null
        (Get-FileHash (Join-Path $f.root 'catalog/catalog.json')).Hash | Should -Be $before
        @(Get-RepositoryGitPathList $f.root @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) | Should -Be @('registry.json')
        (Read-RegistryPayload (Join-Path $f.root 'registry.json')).hosts.hostId | Should -Contain 'other'
        (Read-RegistryPayload (Join-Path $f.root 'registry.json')).schemaVersion | Should -Be 2
        @(Get-RepositoryGitPathList $f.root @('ls-files', '-z', '--', 'untracked.txt')).Count | Should -Be 0
    }
    It 'preserves foreign tracked changes and offers a working continuation: staged=<Staged>' -TestCases @(@{Staged=$false}, @{Staged=$true}) {
        param($Staged)
        $f = New-PublicationFixture (Join-Path $TestDrive ("foreign-$Staged"))
        $path = Join-Path $f.root 'catalog/catalog.json'
        [IO.File]::WriteAllText($path, '{"schemaVersion":1,"future":"edited"}')
        if ($Staged) { $null = Invoke-RepositoryGit $f.root @('add', 'catalog/catalog.json') }
        $registryHash = (Get-FileHash (Join-Path $f.root 'registry.json')).Hash
        { Publish-Registry -Config $f.config -SkipRuntimeRefresh *> $null } | Should -Throw '*REGISTRY_FOREIGN_CHANGES*'
        (Get-FileHash (Join-Path $f.root 'registry.json')).Hash | Should -Be $registryHash
        [IO.File]::ReadAllText($path) | Should -Be '{"schemaVersion":1,"future":"edited"}'
        $null = Invoke-RepositoryGit $f.root @('add', 'catalog/catalog.json')
        $null = Invoke-RepositoryGit $f.root @('commit', '-m', 'owner catalog edit')
        Publish-Registry -Config $f.config -SkipRuntimeRefresh *> $null
        [IO.File]::ReadAllText($path) | Should -Be '{"schemaVersion":1,"future":"edited"}'
        @(Get-RepositoryGitPathList $f.root @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) | Should -Be @('registry.json')
    }
    It 'retains a concurrent catalog commit through the actual push/rebase/retry path' {
        $script:PublicationFixture = New-PublicationFixture (Join-Path $TestDrive 'retry')
        $f = $script:PublicationFixture
        $script:ConcurrentDone = $false
        Mock Invoke-Git {
            param($Root, $Arguments)
            if ($Arguments[0] -eq 'push' -and -not $script:ConcurrentDone) {
                $script:ConcurrentDone = $true
                $other = Join-Path (Split-Path $Root -Parent) 'other'
                $null = Invoke-RepositoryGit (Split-Path $Root -Parent) @('clone', $script:PublicationFixture.remote, $other)
                $null = Invoke-RepositoryGit $other @('config', 'user.email', 'other@example.test')
                $null = Invoke-RepositoryGit $other @('config', 'user.name', 'Other')
                [IO.File]::WriteAllText((Join-Path $other 'catalog/catalog.json'), '{"schemaVersion":1,"future":"concurrent"}')
                $null = Invoke-RepositoryGit $other @('add', 'catalog/catalog.json')
                $null = Invoke-RepositoryGit $other @('commit', '-m', 'concurrent')
                $null = Invoke-RepositoryGit $other @('push')
            }
            & $script:OriginalHostGit -Root $Root -Arguments $Arguments
        }
        Publish-Registry -Config $f.config -SkipRuntimeRefresh *> $null
        $script:ConcurrentDone | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $f.root 'catalog/catalog.json')) | Should -Be '{"schemaVersion":1,"future":"concurrent"}'
        @(Get-RepositoryGitPathList $f.root @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) | Should -Be @('registry.json')
        (Invoke-RepositoryGit $f.root @('rev-parse', 'HEAD')).stdout | Should -Be (Invoke-RepositoryGit $f.root @('rev-parse', '@{upstream}')).stdout
    }
}
