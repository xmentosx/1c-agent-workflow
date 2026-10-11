BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Controlled fork qualification script inventory' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $checkAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw 'Cannot parse the actual workflow gate consumer.' }
        foreach ($name in @('Get-RelativeRepositoryPath', 'Get-CanonicalTextSha256', 'Test-HasExactInventory', 'Test-ForkQualification')) {
            $definition = $checkAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
            if ($null -eq $definition) { throw "Actual gate function is missing: $name" }
            Invoke-Expression $definition.Extent.Text
        }
        function New-ForkScriptInventoryFixture {
            param([string]$Root, [switch]$Legacy)
            $utf8 = [Text.UTF8Encoding]::new($false)
            foreach ($directory in @('tests', 'scripts', 'build')) { [void][IO.Directory]::CreateDirectory((Join-Path $Root $directory)) }
            $scripts = @('scripts/check.ps1', 'scripts/publish-fork-release.ps1')
            if (-not $Legacy) { $scripts += 'scripts/full-check-contract.ps1' }
            foreach ($relative in @('tests/Проверка.Tests.ps1', 'build/pester.xml') + $scripts) {
                [IO.File]::WriteAllText((Join-Path $Root $relative), "# Точный исходник: $relative`r`n", $utf8)
            }
            $identity = [ordered]@{ commit = ('a' * 40); tree = ('b' * 40); upstreamRef = 'refs/heads/main'; upstreamCommit = ('c' * 40) }
            $qualification = [ordered]@{
                schemaVersion = 2; kind = 'itl-ai-rules-full-qualification'; status = 'passed'; reusable = $true
                repository = [ordered]@{ commit = $identity.commit; tree = $identity.tree; worktreeClean = $true }
                provenance = [ordered]@{ upstreamRef = $identity.upstreamRef; upstreamCommit = $identity.upstreamCommit }
                inventory = [ordered]@{
                    tests = @([ordered]@{ path = 'tests/Проверка.Tests.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'tests/Проверка.Tests.ps1')).Hash.ToLowerInvariant() })
                    scripts = @(foreach ($relative in $scripts) { [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root $relative)).Hash.ToLowerInvariant() } })
                }
                junit = [ordered]@{ path = 'build/pester.xml'; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'build/pester.xml')).Hash.ToLowerInvariant() }
            }
            $path = Join-Path $Root 'build/full.json'
            [IO.File]::WriteAllText($path, ($qualification | ConvertTo-Json -Depth 8), $utf8)
            return [pscustomobject]@{ Root = $Root; Path = $path; Identity = $identity; Qualification = $qualification }
        }
        function Save-ForkScriptInventoryFixture {
            param([object]$Fixture)
            [IO.File]::WriteAllText($Fixture.Path, ($Fixture.Qualification | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach {
        $fixture = New-ForkScriptInventoryFixture -Root (Join-Path $TestDrive ('Форк с пробелом ' + [guid]::NewGuid().ToString('N')))
    }
    It 'accepts the exact three-script receipt when the Full contract helper exists' {
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeTrue
    }
    It 'accepts an exact legacy two-script receipt only when the Full contract helper is absent' {
        $legacy = New-ForkScriptInventoryFixture -Root (Join-Path $TestDrive 'Старый форк с пробелом') -Legacy
        Test-ForkQualification -SourceRoot $legacy.Root -Path $legacy.Path -Identity $legacy.Identity | Should -BeTrue
    }
    It 'refuses a receipt that omits the existing Full contract helper' {
        $fixture.Qualification.inventory.scripts = @($fixture.Qualification.inventory.scripts | Where-Object { $_.path -cne 'scripts/full-check-contract.ps1' })
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses an extra script entry rather than trusting an inventory subset' {
        $extra = Join-Path $fixture.Root 'scripts/extra.ps1'
        [IO.File]::WriteAllText($extra, '# foreign entry', [Text.UTF8Encoding]::new($false))
        $fixture.Qualification.inventory.scripts += [ordered]@{ path = 'scripts/extra.ps1'; sha256 = (Get-FileHash -LiteralPath $extra).Hash.ToLowerInvariant() }
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses a Full contract helper whose actual source bytes changed after qualification' {
        [IO.File]::AppendAllText((Join-Path $fixture.Root 'scripts/full-check-contract.ps1'), '# изменённый контракт', [Text.UTF8Encoding]::new($false))
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses an incorrect recorded hash for the Full contract helper' {
        ($fixture.Qualification.inventory.scripts | Where-Object { $_.path -ceq 'scripts/full-check-contract.ps1' }).sha256 = 'd' * 64
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses explicit provenance when the canonical release requires refs heads main' {
        $fixture.Qualification.provenance.upstreamRef = 'explicit'
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses a helper inventory entry when the helper file no longer exists' {
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'scripts/full-check-contract.ps1')
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
}
