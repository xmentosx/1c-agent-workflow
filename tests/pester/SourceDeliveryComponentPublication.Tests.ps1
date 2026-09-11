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
        $DeliverySourceText | Should -Match 'Resolve-DeliveryAiRulesSource'
        $DeliverySourceText | Should -Match 'worktree", "list", "--porcelain", "-z"'
        $DeliverySourceText | Should -Match 'Remove-DeliveryPreparedAiRulesWorktree'
        $DeliverySourceText | Should -Match 'Get-DeliveryComponentFinalizerIdentity'
        $DeliverySourceText | Should -Match 'compatibilityStatus = \[string\]\$lock\.compatibilityStatus; installable = \$true'
        $DeliverySourceText | Should -Match 'Copy-DeliveryVanessaPairedExtensionFromArchive'
        $DeliverySourceText | Should -Match '\$lock\.vanessaMcp\.vaExtension\.url'
    }

    It "extracts the exact paired VAExtension from the qualified Vanessa archive" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Copy-DeliveryVanessaPairedExtensionFromArchive')) { Invoke-Expression $definition.Extent.Text }
            $stage = Join-Path $TestDrive "paired archive содержимое"
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            $assetName = 'VAExtension.1.29-itl-r13.cfe'
            $source = Join-Path $stage $assetName
            [IO.File]::WriteAllBytes($source, [byte[]](1, 3, 5, 7, 9))
            $sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            $archive = Join-Path $TestDrive 'vanessa paired.zip'
            Compress-Archive -LiteralPath $source -DestinationPath $archive
            $destination = Join-Path $TestDrive "upload путь\$assetName"
            $lock = [pscustomobject]@{ assetName = $assetName; sha256 = $sha }

            Copy-DeliveryVanessaPairedExtensionFromArchive -ArchivePath $archive -Lock $lock -DestinationPath $destination | Should -Be $destination
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $sha

            Remove-Item -LiteralPath $destination -Force
            $lock.sha256 = ('0' * 64)
            { Copy-DeliveryVanessaPairedExtensionFromArchive -ArchivePath $archive -Lock $lock -DestinationPath $destination } |
                Should -Throw '*paired extension SHA256 mismatch*'
            Test-Path -LiteralPath $destination | Should -BeFalse
        }
    }

    It "requires Release when only the paired Vanessa extension is unpublished" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Get-OwnedComponentPublicationPlan')) { Invoke-Expression $definition.Extent.Text }
            $candidateRoot = Join-Path $TestDrive 'paired plan candidate'
            New-Item -ItemType Directory -Force -Path (Join-Path $candidateRoot 'templates') | Out-Null
            $lock = [ordered]@{ dependencies = [ordered]@{
                vanessaAutomation = [ordered]@{ url = 'https://example.invalid/vanessa.zip'; sha256 = ('1' * 64); assetName = 'vanessa.zip' }
                vanessaMcp = [ordered]@{ vaExtension = [ordered]@{ url = 'https://example.invalid/paired.cfe'; sha256 = ('2' * 64); assetName = 'paired.cfe' } }
                itlOndemandMcp = [ordered]@{ url = 'https://example.invalid/facade.exe'; sha256 = ('3' * 64) }
                aiRules1c = [ordered]@{ compatibilityStatus = 'passed' }
            } }
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'templates\dependency-lock.json'), (($lock | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            function Get-DeliveryRemoteAssetState {
                param([string]$Url, [string]$ExpectedSha256)
                return [pscustomobject]@{ status = $(if ($Url -like '*paired.cfe') { 'missing' } else { 'matched' }); sha256 = $ExpectedSha256 }
            }
            function Get-DeliveryLocalAiRulesSource { return [pscustomobject]@{ root = $candidateRoot } }
            function Get-DeliveryAiRulesRemoteState { return [pscustomobject]@{ status = 'matched' } }
            $script:ComponentFinalizerScript = ''

            $plan = Get-OwnedComponentPublicationPlan -CandidateRoot $candidateRoot -CandidateCommit ('a' * 40)
            $plan.requiresRelease | Should -BeTrue
            $component = @($plan.components | Where-Object { $_.name -eq 'vanessaAutomation' })[0]
            $component.status | Should -Be 'missing'
            $component.releaseRequired | Should -BeTrue
            @($component.assets | Where-Object { $_.name -eq 'paired.cfe' })[0].status | Should -Be 'missing'
        }
    }

    It "uploads and verifies the Vanessa archive and its paired extension together" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Copy-DeliveryVanessaPairedExtensionFromArchive','Invoke-VanessaComponentPublicationFinalize')) { Invoke-Expression $definition.Extent.Text }
            $candidateRoot = Join-Path $TestDrive 'paired finalize candidate'
            New-Item -ItemType Directory -Force -Path (Join-Path $candidateRoot 'templates') | Out-Null
            $assetName = 'VAExtension.1.29-itl-r13.cfe'
            $stage = Join-Path $TestDrive 'paired finalize archive'
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            $pairedSource = Join-Path $stage $assetName
            [IO.File]::WriteAllBytes($pairedSource, [byte[]](2, 4, 6, 8))
            $pairedSha = (Get-FileHash -LiteralPath $pairedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $archivePath = Join-Path $TestDrive 'qualified-vanessa.zip'
            Compress-Archive -LiteralPath $pairedSource -DestinationPath $archivePath
            $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $tag = 'vanessa-automation-v1.2.043.28-itl-r13'
            $lock = [ordered]@{ dependencies = [ordered]@{
                vanessaAutomation = [ordered]@{
                    compatibilityVersion = '1.2.043.28'; downstreamRevision = 'itl-r13'; assetName = 'vanessa-itl-r13.zip'
                    releaseTag = $tag; url = "https://github.com/xmentosx/1c-agent-workflow/releases/download/$tag/vanessa-itl-r13.zip"; sha256 = $archiveSha
                }
                vanessaMcp = [ordered]@{ vaExtension = [ordered]@{
                    assetName = $assetName; releaseTag = $tag
                    url = "https://github.com/xmentosx/1c-agent-workflow/releases/download/$tag/$assetName"
                    sha256 = $pairedSha; protocol = 'itl-file-code-v1'
                } }
            } }
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'templates\dependency-lock.json'), (($lock | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $script:remoteChecks = @{}
            $script:uploads = [Collections.Generic.List[string]]::new()
            function Get-DeliveryGitHubRepository { return [pscustomobject]@{ owner = 'xmentosx'; repo = '1c-agent-workflow'; slug = 'xmentosx/1c-agent-workflow' } }
            function Get-DeliveryRemoteAssetState {
                param([string]$Url, [string]$ExpectedSha256)
                $count = 1 + [int]$script:remoteChecks[$Url]
                $script:remoteChecks[$Url] = $count
                return [pscustomobject]@{ status = $(if ($count -eq 1) { 'missing' } else { 'matched' }); sha256 = $(if ($count -eq 1) { '' } else { $ExpectedSha256 }) }
            }
            function Get-DeliveryExactVanessaCandidate { return $archivePath }
            function Get-DeliveryRemoteAnnotatedTagCommit { return ('a' * 40) }
            function Invoke-DeliveryGitHubCli {
                param([string[]]$Arguments, [switch]$AllowFailure)
                if (@($Arguments)[0] -eq 'release' -and @($Arguments)[1] -eq 'upload') { [void]$script:uploads.Add([IO.Path]::GetFileName([string]@($Arguments)[3])) }
                return [pscustomobject]@{ exitCode = 0; text = '{"assets":[]}' }
            }
            function Save-DeliveryComponentPublicationEvidence {}
            $RequireRelease = $true

            $evidence = Invoke-VanessaComponentPublicationFinalize -CandidateRoot $candidateRoot -CandidateCommit ('a' * 40)
            @($script:uploads) | Should -Contain 'vanessa-itl-r13.zip'
            @($script:uploads) | Should -Contain $assetName
            $evidence.pairedExtension.sha256 | Should -Be $pairedSha
            @($script:remoteChecks.Values | Where-Object { $_ -eq 2 }).Count | Should -Be 2
        }
    }

    It "refuses to finalize a remotely present ai rules tag while compatibility is pending" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Invoke-AiRulesComponentPublicationFinalize')) { Invoke-Expression $definition.Extent.Text }
            $candidateRoot = Join-Path $TestDrive "pending rules candidate"
            New-Item -ItemType Directory -Force -Path (Join-Path $candidateRoot "templates") | Out-Null
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{
                repo = "https://example.invalid/ai_rules_1c.git"; ref = "itl-v1-r99"; commit = ("a" * 40)
                upstreamCommit = ("b" * 40); downstreamRevision = 99; compatibilityStatus = "pending"
            } } }
            [IO.File]::WriteAllText((Join-Path $candidateRoot "templates\dependency-lock.json"), (($lock | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            { Invoke-AiRulesComponentPublicationFinalize -CandidateRoot $candidateRoot -CandidateCommit ("c" * 40) } |
                Should -Throw "*is published remotely but is not installable: compatibilityStatus=pending*"
        }
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

    It "selects a clean registered ai_rules worktree at the locked commit" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('ConvertTo-DeliveryRepositoryIdentity', 'Remove-DeliveryPreparedAiRulesWorktree', 'Get-DeliveryAiRulesWorktreeRecords', 'Test-DeliveryAiRulesQualificationFile', 'Resolve-DeliveryAiRulesSource')) { Invoke-Expression $definition.Extent.Text }
            . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
            function Invoke-WorktreeGit {
                param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
                $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
                return [pscustomobject]@{ exitCode = $LASTEXITCODE; stdout = ($output -join "`n") }
            }
            $root = Join-Path $TestDrive "rules stale путь"; $exactRoot = Join-Path $TestDrive "rules exact путь"
            New-Item -ItemType Directory -Force -Path $root | Out-Null; & git -C $root init --quiet; & git -C $root config user.email tests@example.com; & git -C $root config user.name Tests
            [IO.File]::WriteAllText((Join-Path $root 'README.md'), "exact`n", [Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "build/`n", [Text.UTF8Encoding]::new($false)); & git -C $root add README.md .gitignore; & git -C $root commit --quiet -m exact; $expected = (& git -C $root rev-parse HEAD).Trim()
            $tag = 'itl-main-deadbeef-r1'; & git -C $root branch "release/$tag" $expected; & git -C $root tag -a $tag $expected -m exact; & git -C $root worktree add --quiet --detach $exactRoot $expected
            $expectedTree = (& git -C $exactRoot rev-parse 'HEAD^{tree}').Trim(); $qualificationPath = Join-Path $exactRoot 'build\test-results\qualification\full.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $qualificationPath) | Out-Null
            $qualification = [ordered]@{ kind='itl-ai-rules-full-qualification'; status='passed'; reusable=$true; repository=[ordered]@{commit=$expected;tree=$expectedTree;worktreeClean=$true} }; [IO.File]::WriteAllText($qualificationPath, ($qualification | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'README.md'), "stale`n", [Text.UTF8Encoding]::new($false)); & git -C $root add README.md; & git -C $root commit --quiet -m stale; & git -C $root remote add origin 'https://example.invalid/ai_rules_1c.git'
            $script:DeliveryRequestedAiRulesSource = $root; $script:AiRulesSource = $root; $lock = [pscustomobject]@{ repo='https://example.invalid/ai_rules_1c.git'; commit=$expected; ref=$tag }
            (Resolve-DeliveryAiRulesSource -Lock $lock) | Should -Be ([IO.Path]::GetFullPath($exactRoot))
            $script:AiRulesSource | Should -Be ([IO.Path]::GetFullPath($exactRoot))
        }
    }

    It "returns an expected GitHub CLI probe failure under Windows PowerShell error-stop semantics" {
        & {
            foreach ($definition in Get-DeliveryFunctionDefinitions -Names @('Invoke-DeliveryGitHubCli')) { Invoke-Expression $definition.Extent.Text }
            $oldPath = $env:PATH
            try {
                $fakeBin = Join-Path $TestDrive "fake gh путь"
                New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
                $fakeGh = Join-Path $fakeBin "gh.cmd"
                [IO.File]::WriteAllText($fakeGh, "@echo off`r`n1>&2 echo release not found`r`nexit /b 1`r`n", [Text.Encoding]::ASCII)
                $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
                $ErrorActionPreference = "Stop"

                $result = Invoke-DeliveryGitHubCli -Arguments @("release", "view", "missing") -AllowFailure

                $result.exitCode | Should -Be 1
                $result.text | Should -Match "release not found"
            } finally { $env:PATH = $oldPath }
        }
    }

It "preserves passed gates and recovers their phase when component finalization fails" {
        $fixture = $null; $standRoot = $null; $oldFailure = $env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture = New-DeliveryFixture
            $standRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl post release stand " + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $standRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $standRoot ".dev.env") -Encoding UTF8 -Value "IDENTITY=before"
            & git -C $standRoot init --quiet
            & git -C $standRoot config user.email "itl-tests@example.invalid"
            & git -C $standRoot config user.name "ITL Tests"
            & git -C $standRoot add -- .dev.env
            & git -C $standRoot commit --quiet -m "test: create publication stand"
            New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ComponentFinalize.Tests.ps1") -Encoding UTF8 -Value "Describe 'component finalize' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "test: component finalizer failure" *> $null
            $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "component-finalize") | Out-Null

            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = "true"
            $publishArguments = @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'), "-E2EProjectRoot", ('"' + $standRoot + '"'))
            $failed = Invoke-DeliveryTestPowerShell -Arguments $publishArguments -AllowFailure

            $failed.exitCode | Should -Not -Be 0
            $failed.stderr | Should -Match "Component publication finalizer failed"
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Targeted", "Develop", "Release")
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/component-finalize/head).Trim() | Should -Be $candidate
            $finalizerRecord = Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
            $finalizerRecord.remoteHead | Should -Be $fixture.base

            Set-Content -LiteralPath (Join-Path $standRoot ".dev.env") -Encoding UTF8 -Value "IDENTITY=after"
            & git -C $standRoot add -- .dev.env
            & git -C $standRoot commit --quiet -m "test: mutate post release stand"
            (Invoke-DeliveryTestPowerShell -Arguments $publishArguments -AllowFailure).exitCode | Should -Not -Be 0
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Targeted", "Develop", "Release")

            $attemptPath = Join-Path $fixture.root ".git\itl\publication-attempts\develop.json"
            $attempt = Get-Content -LiteralPath $attemptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $attempt.phase = "candidate-built"
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = "false"
            $published = Invoke-DeliveryTestPowerShell -Arguments ($publishArguments + @("-RetryBlockedStage"))
            ($published.stdout | ConvertFrom-Json).status | Should -Be "published"
            @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Targeted", "Develop", "Release")
            @((Get-Content -LiteralPath $fixture.finalizerLog -Encoding UTF8)).Count | Should -Be 3
            (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
        } finally {
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER = $oldFailure
            if ($standRoot) { Remove-Item -LiteralPath $standRoot -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }
}
