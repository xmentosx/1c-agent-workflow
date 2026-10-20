Describe 'Product/project registry G2 contract' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1')
        function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
        function New-CatalogFixture {
            $catalog = @{
                schemaVersion = 1
                products = @(
                    @{ productId = 'corp'; name = 'КОРП'; roles = @{ code = @{ mode = 'own'; sourceId = 'corp-code' } } },
                    @{ productId = 'prof'; name = 'ПРОФ' }, @{ productId = 'erp'; name = 'ERP' },
                    @{ productId = 'erp-pm'; name = 'ERP+PM' }, @{ productId = 'fourth'; name = 'Четвёртый' })
                projects = @(@{ projectId = 'typical'; productId = 'corp'; name = 'Типовой' },
                    @{ projectId = 'prof-dev'; productId = 'prof'; name = 'ПРОФ' },
                    @{ projectId = 'erp-dev'; productId = 'erp-pm'; name = 'ERP+PM' },
                    @{ projectId = 'customer'; productId = 'erp-pm'; name = 'Заказчик'; customized = $true })
                profiles = @(@{ profileId = 'corp-lts'; productId = 'corp'; name = 'LTS'; roles = @{ graph = @{ mode = 'own'; sourceId = 'corp-graph' } } })
                sources = @(
                    @{ sourceId = 'corp-code'; role = 'code'; endpoint = @{ hostId = 'a'; serverId = 'code'; configId = 'corp' }; namespace = 'code-same-id' },
                    @{ sourceId = 'corp-graph'; role = 'graph'; endpoint = @{ hostId = 'b'; serverId = 'graph'; configId = 'other' }; namespace = 'graph-corp' },
                    @{ sourceId = 'docs'; role = 'productDocs'; endpoint = @{ hostId = 'a'; serverId = 'docs' }; binding = @{ mode = 'view'; viewId = 'corp' } })
                instances = @(@{ instanceId = 'mantis'; type = 'mantis'; url = 'https://example.test/mantis' },
                    @{ instanceId = 'sppr'; type = 'sppr'; url = 'http://example.test/sppr' })
            }
            $relations = @{ schemaVersion = 1; relations = @(
                @{ type = 'derivedFrom'; productId = 'prof'; fromProductId = 'corp' },
                @{ type = 'contains'; productId = 'erp-pm'; componentProductId = 'corp' },
                @{ type = 'contains'; productId = 'erp-pm'; componentProductId = 'erp' }); knowledgeAreas = @{
                    planning = @{ title = 'Планирование'; availableIn = @('corp', 'prof', 'erp-pm'); memoryHomeProductId = 'corp' }
                    portfolio = @{ title = 'Портфели'; availableIn = @('corp', 'erp-pm') }
                    erp = @{ title = 'ERP'; availableIn = @('corp', 'erp-pm'); requiresProducts = @('erp'); memoryHomeProductId = 'erp-pm' }
                } }
            $registry = @{ schemaVersion = 2; publishedAt = 'one'; hosts = @(
                @{ hostId = 'a'; servers = @(@{ id = 'code' }, @{ id = 'docs' }); configurations = @(@{ id = 'corp' }) },
                @{ hostId = 'b'; servers = @(@{ id = 'graph' }); configurations = @(@{ id = 'other' }) }) }
            return @{ catalogRevision = ('a' * 40); inputGitObjectIds = @{}; catalog = $catalog; relations = $relations; registry = $registry }
        }
        function New-KnowledgeFixture {
            return @{ origin = @{ projectId = 'erp-dev'; source = 'Object.Module'; revision = 'r1' };
                applicability = @{ knowledgeAreas = @('planning'); verificationState = 'verified' };
                evidence = @(@{ source = 'Object.Module'; revision = 'r1'; result = 'checked' }) }
        }
        function Write-CatalogFixture {
            param([string]$Root, [object]$Snapshot)
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'catalog'))
            foreach ($pair in @(@('registry.json', $Snapshot.registry), @('catalog/catalog.json', $Snapshot.catalog), @('catalog/product-relations.json', $Snapshot.relations))) {
                [IO.File]::WriteAllText((Join-Path $Root $pair[0]), (ConvertTo-Json -InputObject $pair[1] -Depth 100), [Text.UTF8Encoding]::new($false))
            }
        }
        function New-CatalogGitFixture {
            param([string]$Root)
            [void][IO.Directory]::CreateDirectory($Root)
            $null = Invoke-RepositoryGit $Root @('init', '-b', 'main')
            $null = Invoke-RepositoryGit $Root @('config', 'user.email', 'fixture@example.test')
            $null = Invoke-RepositoryGit $Root @('config', 'user.name', 'Fixture')
            Write-CatalogFixture $Root (New-CatalogFixture)
            $null = Invoke-RepositoryGit $Root @('add', '.')
            $null = Invoke-RepositoryGit $Root @('commit', '-m', 'fixture')
            return (Invoke-RepositoryGit $Root @('rev-parse', 'HEAD')).stdout.Trim()
        }
    }

    It 'validates the schema, optional profiles, missing home and unknown optional fields' {
        $s = New-CatalogFixture
        $s.catalog.products[0].future = @{ description = 'Сохранить' }
        $null = Assert-ItlProductCatalog $s.catalog $s.relations $s.registry
        $s.catalog.products[0].future.description | Should -Be 'Сохранить'
        (Resolve-ItlProductContext $s typical).profileId | Should -BeNullOrEmpty
    }

    It 'distinguishes repeated logical server IDs by the full host/configuration binding' {
        $s=New-CatalogFixture
        $s.registry.hosts[0].servers[0].configId='corp'
        $s.registry.hosts[0].configurations+=@{id='second'}
        $s.registry.hosts[0].servers+=@{id='code';configId='second'}
        $null=Assert-ItlProductCatalog $s.catalog $s.relations $s.registry
        (Resolve-ItlProductContext $s typical).roles.code.source.endpoint.configId | Should -Be 'corp'
        $s.catalog.sources[0].endpoint.Remove('configId')
        {Assert-ItlProductCatalog $s.catalog $s.relations $s.registry} | Should -Throw '*unknown/ambiguous*'
    }

    It 'rejects invalid catalog input: <Case>' -TestCases @(
        @{ Case = 'schema' }, @{ Case = 'duplicate' }, @{ Case = 'reference' }, @{ Case = 'cycle' },
        @{ Case = 'home-null' }, @{ Case = 'home-array' }, @{ Case = 'home-unknown' }, @{ Case = 'home-outside' },
        @{ Case = 'wrong-role' }, @{ Case = 'fourth-role' }, @{ Case = 'own-missing' }, @{ Case = 'disabled-source' },
        @{ Case = 'unknown-host' }, @{ Case = 'unknown-server' }, @{ Case = 'unknown-config' },
        @{ Case = 'mantis-search' }, @{ Case = 'mantis-route' }, @{ Case = 'native-id' }, @{ Case = 'null-products' },
        @{ Case = 'nested-secret' }, @{ Case = 'profile-reference' }, @{ Case = 'wrong-target' },
        @{ Case = 'version-range' }, @{ Case = 'published-config-mismatch' }
    ) {
        param($Case)
        $s = New-CatalogFixture
        switch ($Case) {
            'schema' { $s.catalog.schemaVersion = 99 }
            'duplicate' { $s.catalog.products += $s.catalog.products[0] }
            'reference' { $s.catalog.projects[0].productId = 'missing' }
            'cycle' { $s.relations.relations += @{ type = 'derivedFrom'; productId = 'corp'; fromProductId = 'prof' } }
            'home-null' { $s.relations.knowledgeAreas.planning.memoryHomeProductId = $null }
            'home-array' { $s.relations.knowledgeAreas.planning.memoryHomeProductId = @('corp') }
            'home-unknown' { $s.relations.knowledgeAreas.planning.memoryHomeProductId = 'missing' }
            'home-outside' { $s.relations.knowledgeAreas.planning.memoryHomeProductId = 'erp' }
            'wrong-role' { $s.catalog.products[0].roles.code.sourceId = 'corp-graph' }
            'fourth-role' { $s.catalog.products[0].roles.cognee = @{ mode = 'inherit' } }
            'own-missing' { $s.catalog.products[0].roles.code.Remove('sourceId') }
            'disabled-source' { $s.catalog.products[0].roles.code.mode = 'disabled' }
            'unknown-host' { $s.catalog.sources[0].endpoint.hostId = 'missing' }
            'unknown-server' { $s.catalog.sources[0].endpoint.serverId = 'missing' }
            'unknown-config' { $s.catalog.sources[0].endpoint.configId = 'missing' }
            'mantis-search' { $s.catalog.projects[0].links = @{ mantis = @{ instanceId = 'mantis'; projectIds = @(1); searchProjectIds = @(2) } } }
            'mantis-route' { $s.catalog.projects[0].links = @{ mantis = @{ instanceId = 'mantis'; projectIds = @(1); createRoutes = @{ bug = 2 } } } }
            'native-id' { $s.relations.knowledgeAreas.planning.datasetId = 'private-id' }
            'null-products' { $s.catalog.products = $null }
            'nested-secret' { $s.catalog.future = @{ nested = @(@{ password = 'harmless-placeholder' }) } }
            'profile-reference' { $s.catalog.projects[1].profileId = 'corp-lts' }
            'wrong-target' { $s.relations.relations[0].requiredProductId = 'erp' }
            'version-range' { $s.relations.knowledgeAreas.planning.versionRange = @{ minVersion = '5.1'; maxVersion = '4.0' } }
            'published-config-mismatch' { $s.registry.hosts[0].servers[0].configId = 'other' }
        }
        { Assert-ItlProductCatalog $s.catalog $s.relations $s.registry } | Should -Throw '*CATALOG_INVALID*'
    }

    It 'resolves independent roles with provenance and no automatic LTS substitution' {
        $s = New-CatalogFixture
        $s.catalog.projects[0].roles = @{ code = @{ mode = 'inherit' }; productDocs = @{ mode = 'own'; sourceId = 'docs' } }
        $ctx = Resolve-ItlProductContext $s typical -ProfileId corp-lts -Overrides @{ roles = @{ productDocs = @{ mode = 'disabled' } } }
        $ctx.roles.code.provenance | Should -Be 'product'
        $ctx.roles.code.source.endpoint.hostId | Should -Be 'a'
        $ctx.roles.graph.provenance | Should -Be 'profile'
        $ctx.roles.graph.source.endpoint.hostId | Should -Be 'b'
        $ctx.roles.productDocs.resolution | Should -Be 'disabled'
        (Resolve-ItlProductContext $s typical).roles.graph.resolution | Should -Be 'deferred'
        $s.catalog.projects[0].roles.graph = @{ mode = 'own'; sourceId = 'corp-graph' }
        (Resolve-ItlProductContext $s typical -ProfileId corp-lts).roles.graph.provenance | Should -Be 'project'
        { Resolve-ItlProductContext $s prof-dev -ProfileId corp-lts } | Should -Throw '*profileId*'
    }

    It 'replaces links as a whole, keeping search and creation targets separate' {
        $s = New-CatalogFixture
        $s.catalog.products[0].links = @{ mantis = @{ instanceId = 'mantis'; projectIds = @(1, 2); searchProjectIds = @(1); createRoutes = @{ feature = 2 } } }
        $ctx = Resolve-ItlProductContext $s typical -Overrides @{ links = @{ mantis = @{ instanceId = 'mantis'; projectIds = @(3) } } }
        @($ctx.links.mantis.value.projectIds) | Should -Be @(3)
        $ctx.links.mantis.provenance | Should -Be 'local'
    }

    It 'returns only applicable canonical homes without ancestors/descendants or whole catalog' {
        $s = New-CatalogFixture
        $ctx = Resolve-ItlProductContext $s prof-dev
        @($ctx.knowledgeContext.productReadCandidates) | Should -Be @('corp', 'prof')
        @($ctx.knowledgeContext.knowledgeAreas).Count | Should -Be 1
        $ctx.knowledgeContext.knowledgeAreas[0].areaId | Should -Be 'planning'
        $s.relations.knowledgeAreas.planning.availableIn += 'fourth'
        (Resolve-ItlProductContext $s prof-dev).knowledgeHash | Should -Be $ctx.knowledgeHash
        $s.relations.knowledgeAreas.portfolio.availableIn += 'fourth'
        (Resolve-ItlProductContext $s typical).knowledgeContext.productReadCandidates | Should -Not -Contain 'erp'
    }

    It 'keeps origin and evidence while excluding ERP/CORP/customer-specific knowledge' {
        $s = New-CatalogFixture; $note = New-KnowledgeFixture
        $result = Resolve-ItlProductKnowledge $s prof $note
        $result.status | Should -Be 'applicable'
        $result.memoryHomeProductId | Should -Be 'corp'
        $result.origin.projectId | Should -Be 'erp-dev'
        $note.applicability.knowledgeAreas = @('portfolio')
        (Resolve-ItlProductKnowledge $s prof $note).status | Should -Be 'not-applicable'
        $note.applicability.knowledgeAreas = @('planning'); $note.applicability.requiresProducts = @('erp')
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'not-applicable'
        $note = New-KnowledgeFixture; $note.origin.projectId = 'customer'
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
        $note.applicability.independentOfCustomization = $true
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'applicable'
        $note.applicability.Remove('verificationState')
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
    }

    It 'handles missing/ambiguous homes, unknown conditions/versions and data-only new variants' {
        $s = New-CatalogFixture; $note = New-KnowledgeFixture
        $note.applicability.knowledgeAreas = @('portfolio')
        (Resolve-ItlProductKnowledge $s corp $note).homeStatus | Should -Be 'needs-review'
        $s.relations.knowledgeAreas.portfolio.memoryHomeProductId = 'erp-pm'
        $note.applicability.knowledgeAreas = @('planning', 'portfolio')
        (Resolve-ItlProductKnowledge $s corp $note).homeStatus | Should -Be 'needs-review'
        $note.applicability.knowledgeAreas = @('planning'); $note.applicability.versionRange = @{ minVersion = '5.0' }
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
        (Resolve-ItlProductKnowledge $s corp $note -ProductVersion '4.0').status | Should -Be 'not-applicable'
        (Resolve-ItlProductKnowledge $s corp $note -ProductVersion '5.1').status | Should -Be 'applicable'
        $note.applicability.Remove('versionRange'); $note.applicability.conditions = @('feature-present')
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
        (Resolve-ItlProductKnowledge $s corp $note -Conditions @{ 'feature-present' = $false }).status | Should -Be 'not-applicable'
        $s.relations.knowledgeAreas.planning.availableIn += 'fourth'
        $note.applicability.Remove('conditions')
        (Resolve-ItlProductKnowledge $s fourth $note).status | Should -Be 'applicable'
    }

    It 'separates revision/settings/knowledge hashes and bounds projection growth without I/O' {
        $s = New-CatalogFixture; $before = Resolve-ItlProductContext $s typical
        $s.registry.publishedAt = 'two'; $s.catalogRevision = 'b' * 40
        1..100 | ForEach-Object { $s.catalog.projects += @{ projectId = "unrelated-$_"; productId = 'fourth'; name = 'Чужой проект' } }
        $after = Resolve-ItlProductContext $s typical
        $after.settingsHash | Should -Be $before.settingsHash
        $after.knowledgeHash | Should -Be $before.knowledgeHash
        $after.catalogRevision | Should -Not -Be $before.catalogRevision
        [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $after -Depth 30 -Compress)) | Should -Be ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $before -Depth 30 -Compress)))
        $s.relations.knowledgeAreas.planning.memoryHomeProductId = 'prof'
        $changed = Resolve-ItlProductContext $s typical
        $changed.settingsHash | Should -Be $before.settingsHash
        $changed.knowledgeHash | Should -Not -Be $before.knowledgeHash
        (Get-ItlCatalogHash ([ordered]@{ a = 1; b = @('x') })) | Should -Be (Get-ItlCatalogHash ([ordered]@{ b = @('x'); a = 1 }))
    }

    It 'reads immutable Git blobs and Unicode while latest/worktree changes and bad inputs stay separate' {
        $root = Join-Path $TestDrive 'Каталог с пробелом'
        $first = New-CatalogGitFixture $root
        $snapshot = Read-ItlProductCatalogSnapshot $root $first
        $snapshot.catalog.products[0].name | Should -Be 'КОРП'
        $changed = New-CatalogFixture; $changed.relations.knowledgeAreas.planning.memoryHomeProductId = 'prof'
        Write-CatalogFixture $root $changed
        $null = Invoke-RepositoryGit $root @('add', '.'); $null = Invoke-RepositoryGit $root @('commit', '-m', 'two')
        $second = (Invoke-RepositoryGit $root @('rev-parse', 'HEAD')).stdout.Trim()
        $old = Read-Vibecoding1cProductContext $root $first typical
        $new = Read-Vibecoding1cProductContext $root $second typical
        $old.knowledgeHash | Should -Not -Be $new.knowledgeHash
        $old.catalogRevision | Should -Be $first
        @($snapshot.inputGitObjectIds.Keys).Count | Should -Be 3
        [IO.File]::WriteAllText((Join-Path $root 'catalog/catalog.json'), 'broken uncommitted data')
        (Read-ItlProductCatalogSnapshot $root $second).catalogRevision | Should -Be $second
        (Get-RepositoryGitPathList $root @('diff', '--name-only', '-z')) | Should -Be @('catalog/catalog.json')
        $null = Invoke-RepositoryGit $root @('rm', '-f', 'catalog/product-relations.json')
        $null = Invoke-RepositoryGit $root @('commit', '-m', 'missing file')
        { Read-ItlProductCatalogSnapshot $root HEAD } | Should -Throw '*cannot read catalog/product-relations.json at*'
        $old.catalogRevision | Should -Be $first
    }

    It 'reads the pinned catalog with at most five Git queries while retaining exact object identities' -Tag StartupReadBudget {
        $catalogRoot=Join-Path $TestDrive 'Реестр с пробелами'
        $commit=New-CatalogGitFixture $catalogRoot
        $script:ReadBudgetGit=(Get-Command Get-GitOutputAt).ScriptBlock
        $script:ReadBudgetCalls=@()
        Mock Get-GitOutputAt {
            param($Root,$Arguments)
            $script:ReadBudgetCalls+=,@($Arguments)
            & $script:ReadBudgetGit -Root $Root -Arguments $Arguments
        }
        $snapshot=Read-ItlProductCatalogSnapshot $catalogRoot HEAD
        $snapshot.catalogRevision|Should -BeExactly $commit
        foreach($path in @('registry.json','catalog/catalog.json','catalog/product-relations.json')){
            $expected=(Invoke-RepositoryGit $catalogRoot @('rev-parse',($commit+':'+$path))).stdout.Trim()
            $snapshot.inputGitObjectIds[$path]|Should -BeExactly $expected
        }
        $script:ReadBudgetCalls.Count|Should -BeLessOrEqual 5
    }
    It 'pins all files even when HEAD advances during the first blob read' {
        $script:ChangingRoot = Join-Path $TestDrive 'tip changed'
        $first = New-CatalogGitFixture $script:ChangingRoot
        $expected = Read-ItlProductCatalogSnapshot $script:ChangingRoot $first
        $script:TipMoved = $false
        $script:ActualGitOutput = (Get-Command Get-GitOutputAt).ScriptBlock
        Mock Get-GitOutputAt {
            param($Root, $Arguments)
            $result = & $script:ActualGitOutput -Root $Root -Arguments $Arguments
            if ($Arguments[0] -eq 'show' -and -not $script:TipMoved) {
                $script:TipMoved = $true
                $s = New-CatalogFixture
                $s.relations.knowledgeAreas.planning.memoryHomeProductId = 'prof'
                Write-CatalogFixture $Root $s
                $null = Invoke-RepositoryGit $Root @('add', '.')
                $null = Invoke-RepositoryGit $Root @('commit', '-m', 'tip changed mid-read')
            }
            return $result
        }
        $actual = Read-ItlProductCatalogSnapshot $script:ChangingRoot HEAD
        $script:TipMoved | Should -BeTrue
        $actual.catalogRevision | Should -Be $first
        (Get-ItlCatalogHash $actual.inputGitObjectIds) | Should -Be (Get-ItlCatalogHash $expected.inputGitObjectIds)
        $actual.relations.knowledgeAreas.planning.memoryHomeProductId | Should -Be 'corp'
    }

    It 'keeps note origin/evidence through a home change and refuses incomplete or unknown applicability' {
        $s = New-CatalogFixture; $note = New-KnowledgeFixture
        $before = Get-ItlCatalogHash $note
        $s.relations.knowledgeAreas.planning.memoryHomeProductId = 'prof'
        $moved = Resolve-ItlProductKnowledge $s corp $note
        $moved.memoryHomeProductId | Should -Be 'prof'
        (Get-ItlCatalogHash $note) | Should -Be $before
        $s.relations.knowledgeAreas.planning.Remove('memoryHomeProductId')
        (Resolve-ItlProductKnowledge $s corp $note).homeStatus | Should -Be 'needs-review'
        (Get-ItlCatalogHash $note) | Should -Be $before
        $note.applicability.productIds = @('erp-pm')
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'not-applicable'
        $note.applicability.Remove('productIds'); $note.evidence = @(@{ source = 'no-revision' })
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
        $note = New-KnowledgeFixture; $note.applicability.futureConstraint = 'unknown'
        (Resolve-ItlProductKnowledge $s corp $note).status | Should -Be 'needs-review'
    }

    It 'does not write state or call network/provider/lifecycle while resolving' {
        Mock Invoke-WebRequest { throw 'network forbidden' }
        Mock Invoke-RestMethod { throw 'provider forbidden' }
        Mock Set-Content { throw 'state write forbidden' }
        Mock Write-Vibecoding1cMcpSelection { throw 'selection write forbidden' }
        Mock Write-Vibecoding1cMcpClientConfig { throw 'client write forbidden' }
        $s = New-CatalogFixture
        $before = Get-ItlCatalogHash $s
        $null = Resolve-ItlProductContext $s typical
        $null = Resolve-ItlProductKnowledge $s corp (New-KnowledgeFixture)
        (Get-ItlCatalogHash $s) | Should -Be $before
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Set-Content -Times 0
        Should -Invoke Write-Vibecoding1cMcpSelection -Times 0
        Should -Invoke Write-Vibecoding1cMcpClientConfig -Times 0
    }

    It 'keeps IDs through renaming and includes observed version/conditions in knowledge hashes' {
        $s = New-CatalogFixture
        $old = Resolve-ItlProductContext $s typical
        $s.catalog.products[0].name = 'Renamed product'; $s.catalog.projects[0].name = 'Renamed project'
        $new = Resolve-ItlProductContext $s typical
        $new.projectId | Should -Be $old.projectId
        $new.productId | Should -Be $old.productId
        $new.settingsHash | Should -Be $old.settingsHash
        (Resolve-ItlProductContext $s typical -ProductVersion '5.0').knowledgeHash | Should -Not -Be $old.knowledgeHash
        (Resolve-ItlProductContext $s typical -Conditions @{ present = $true }).knowledgeHash | Should -Not -Be $old.knowledgeHash
        { Resolve-ItlProductContext $s typical -Conditions @{ present = 'true' } } | Should -Throw '*boolean*'
    }

    It 'produces the same context hashes under different developer cultures' {
        $s = New-CatalogFixture
        $s.relations.knowledgeAreas['I'] = @{ title = 'One'; availableIn = @('corp') }
        $s.relations.knowledgeAreas['i-key'] = @{ title = 'Two'; availableIn = @('corp') }
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
            $first = Resolve-ItlProductContext $s typical
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $second = Resolve-ItlProductContext $s typical
            $first.settingsHash | Should -Be $second.settingsHash
            $first.knowledgeHash | Should -Be $second.knowledgeHash
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
    }

    It 'validates the confirmed minimal pilot with deferred integrations and no invented home' {
        $seed = Join-Path $RepoRoot 'templates/product-project-registry/pilot'
        $c = Get-Content -LiteralPath (Join-Path $seed 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $r = Get-Content -LiteralPath (Join-Path $seed 'product-relations.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $null = Assert-ItlProductCatalog $c $r @{ schemaVersion = 2 }
        $ctx = Resolve-ItlProductContext @{ catalog = $c; relations = $r; registry = @{ schemaVersion = 2 }; catalogRevision = 'prepared-not-published'; inputGitObjectIds = @{} } pm5-core-development
        $ctx.productId | Should -Be 'pm5-corp'
        @($ctx.knowledgeContext.knowledgeAreas).Count | Should -Be 0
        $ctx.roles.code.resolution | Should -Be 'deferred'
    }
}
