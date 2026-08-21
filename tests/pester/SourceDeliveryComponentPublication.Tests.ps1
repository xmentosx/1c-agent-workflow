BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It "finalizes every owned release surface and excludes external pinned dependencies" {
        foreach ($name in @(
            'Invoke-AiRulesComponentPublicationFinalize',
            'Invoke-VanessaComponentPublicationFinalize',
            'Invoke-OnDemandMcpComponentPublicationFinalize'
        )) { $DeliverySourceText | Should -Match ([regex]::Escape($name)) }
        $aggregate = (Get-DeliveryFunctionDefinitions -Names @('Invoke-ComponentPublicationFinalizer')).Extent.Text
        @([regex]::Matches($aggregate, 'Invoke-(AiRules|Vanessa|OnDemandMcp)ComponentPublicationFinalize')).Count | Should -Be 3
        foreach ($external in @('roctupMcpToolkit', 'vanessaMcp', 'agentBrowser', 'windowsMcp', 'piMcpExtension', 'opencodePlugin')) {
            $aggregate | Should -Not -Match ([regex]::Escape($external))
        }
        $DeliverySourceText | Should -Match 'Owned component publication requires exact-candidate Release qualification'
        $DeliverySourceText | Should -Match 'Get-DeliveryComponentFinalizerIdentity'
    }

    It "classifies exact, partial, and missing immutable ai_rules remote refs" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Get-DeliveryAiRulesRemoteState')) { Invoke-Expression $definition.Extent.Text }
            function Invoke-WorktreeGit {
                param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
                $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
                return [pscustomobject]@{ exitCode = $LASTEXITCODE; stdout = ($output -join "`n") }
            }
            $root = Join-Path $TestDrive "rules remote путь"
            $remote = Join-Path $TestDrive "rules-remote.git"
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            & git init --quiet --bare $remote
            & git -C $root init --quiet
            & git -C $root config user.email tests@example.com
            & git -C $root config user.name Tests
            [IO.File]::WriteAllText((Join-Path $root 'README.md'), "fixture`n", [Text.UTF8Encoding]::new($false))
            & git -C $root add README.md
            & git -C $root commit --quiet -m fixture
            $commit = (& git -C $root rev-parse HEAD).Trim()
            $tag = 'itl-main-deadbeef-r1'
            & git -C $root branch "release/$tag" $commit
            & git -C $root tag -a $tag $commit -m fixture
            & git -C $root remote add origin $remote
            & git -C $root push --quiet --atomic origin "refs/heads/release/${tag}:refs/heads/release/${tag}" "refs/tags/${tag}:refs/tags/${tag}"
            $lock = [pscustomobject]@{ ref = $tag; commit = $commit }
            (Get-DeliveryAiRulesRemoteState -SourceRoot $root -Lock $lock).status | Should -Be 'matched'
            & git --git-dir=$remote update-ref -d "refs/heads/release/$tag"
            (Get-DeliveryAiRulesRemoteState -SourceRoot $root -Lock $lock).status | Should -Be 'partial'
            & git --git-dir=$remote update-ref -d "refs/tags/$tag"
            (Get-DeliveryAiRulesRemoteState -SourceRoot $root -Lock $lock).status | Should -Be 'missing'
        }
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

            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = "false"
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
            ($published.stdout | ConvertFrom-Json).status | Should -Be "published"
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Targeted", "Develop")
            @((Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8)).Count | Should -Be 2
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
        } finally {
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = $oldFailure
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
}
