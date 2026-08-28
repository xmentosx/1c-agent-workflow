BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
    It "promotes one exact qualified candidate through develop and master without repeating gates" {
            $fixture = $null
            try {
                $fixture = New-DeliveryFixture
                & git -C $fixture.root push --quiet origin "HEAD:refs/heads/master" *> $null
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ReleaseTrain.Tests.ps1") -Encoding UTF8 -Value "Describe 'release train' { It 'works' { `$true | Should -BeTrue } }"
                Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'release-train'"
                & git -C $fixture.root add --all
                & git -C $fixture.root commit -m "feat: release train" *> $null
                $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
                Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue

                $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PromoteRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))
                $payload = $result.stdout | ConvertFrom-Json

                $payload.status | Should -Be "released"
                $payload.releaseTrain | Should -BeTrue
                $payload.qualificationReused | Should -BeTrue
                $payload.developPublished | Should -BeTrue
                $payload.masterReleased | Should -BeTrue
                $payload.developQualificationCommit | Should -Be $candidate
                @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @("Develop", "Release")
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/develop).Trim() | Should -Be $candidate
                (& git --git-dir=$($fixture.remote) rev-parse refs/heads/master).Trim() | Should -Be $candidate
                @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
            } finally { Remove-DeliveryFixture -Fixture $fixture }
        }

    It "resumes a durable release train after develop was published by an earlier process" {
            $fixture = $null
            try {
                $fixture = New-DeliveryFixture
                & git -C $fixture.root push --quiet origin "HEAD:refs/heads/master" *> $null
                New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null
                Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\ResumeTrain.Tests.ps1") -Encoding UTF8 -Value "Describe 'resume train' { It 'works' { `$true | Should -BeTrue } }"
                Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'resume-train'"
                & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: resume release train" *> $null
                Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
                Remove-Item -LiteralPath $fixture.modeLog -Force -ErrorAction SilentlyContinue
                $published = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RequireRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"'))).stdout | ConvertFrom-Json
                $attemptPath = Join-Path $fixture.root ".git\itl\publication-attempts\develop.json"; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attemptPath) | Out-Null
                $attempt = [ordered]@{ schemaVersion=1; phase='remote-pushed'; candidate=$published.commit; tree=$published.tree; requireRelease=$true; startedAt=$published.qualificationStartedAt }
                [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

                $released = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PromoteRelease", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'))).stdout | ConvertFrom-Json
                $released.status | Should -Be 'released'; $released.resumedReleaseTrain | Should -BeTrue; $released.qualificationReused | Should -BeTrue
                @((Get-Content -LiteralPath $fixture.modeLog -Encoding UTF8)) | Should -Be @('Develop','Release')
                Test-Path -LiteralPath $attemptPath | Should -BeFalse
            } finally { Remove-DeliveryFixture -Fixture $fixture }
        }

    It "never uses force push for develop or master" {
            $text = $DeliverySourceText; $text | Should -Not -Match 'push[^\r\n]*(--force|-f\b|--force-with-lease)'
            foreach ($marker in @('HEAD:refs/heads/develop', 'push", "--atomic"', 'HEAD:refs/heads/master')) { $text | Should -Match ([regex]::Escape($marker)) }
        }

    It "uses a GitHub pull request for protected master and reconciles develop without force" {
            $fixture = $null
            $fakeBin = $null
            $oldPath = $env:PATH
            $oldGhScript = $env:ITL_TEST_GH_SCRIPT
            $oldGhRemote = $env:ITL_TEST_GH_REMOTE
            try {
                $fixture = New-DeliveryFixture
                & git --git-dir=$($fixture.remote) update-ref refs/heads/master $fixture.base
                Set-Content -LiteralPath (Join-Path $fixture.root "release.txt") -Encoding UTF8 -Value "qualified"
                & git -C $fixture.root add release.txt
                & git -C $fixture.root commit --quiet -m "feat: protected release" *> $null
                & git -C $fixture.root push --quiet origin develop *> $null
                $candidate = (& git -C $fixture.root rev-parse HEAD).Trim()
                $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()

                $fakeBin = Join-Path ([IO.Path]::GetTempPath()) ("fake gh путь " + [guid]::NewGuid().ToString("N"))
                New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
                $fakeGhScript = Join-Path $fakeBin "fake-gh.ps1"
                [IO.File]::WriteAllText($fakeGhScript, @'
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
    if ($CliArgs[0] -eq 'repo' -and $CliArgs[1] -eq 'view') { 'fixture/repository'; exit 0 }
    if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'list') { exit 0 }
    if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'create') { 'https://github.com/fixture/repository/pull/17'; exit 0 }
    if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'view') { '17'; exit 0 }
    if ($CliArgs[0] -eq 'pr' -and $CliArgs[1] -eq 'merge') {
        if ($CliArgs -contains '--rebase') { "GraphQL: This branch can't be rebased"; exit 33 }
        if (-not ($CliArgs -contains '--squash')) { exit 34 }
        $line = @(& git --git-dir=$env:ITL_TEST_GH_REMOTE for-each-ref '--format=%(objectname) %(refname)' 'refs/heads/itl/release-master-*' | Select-Object -First 1)
        if (-not $line) { exit 31 }
        $parts = $line[0] -split ' ', 2
        $candidate = $parts[0]
        $releaseRef = $parts[1]
        $tree = (& git --git-dir=$env:ITL_TEST_GH_REMOTE rev-parse "$candidate^{tree}").Trim()
        $master = (& git --git-dir=$env:ITL_TEST_GH_REMOTE rev-parse refs/heads/master).Trim()
        $env:GIT_AUTHOR_NAME = 'GitHub Fixture'; $env:GIT_AUTHOR_EMAIL = 'fixture@example.invalid'
        $env:GIT_COMMITTER_NAME = 'GitHub Fixture'; $env:GIT_COMMITTER_EMAIL = 'fixture@example.invalid'
        $rebased = (& git --git-dir=$env:ITL_TEST_GH_REMOTE commit-tree $tree -p $master -m 'rebase protected release').Trim()
        & git --git-dir=$env:ITL_TEST_GH_REMOTE update-ref refs/heads/master $rebased $master
        if ($LASTEXITCODE -ne 0) { exit 32 }
        & git --git-dir=$env:ITL_TEST_GH_REMOTE update-ref -d $releaseRef $candidate
        'merged'; exit 0
    }
    exit 30
'@, [Text.UTF8Encoding]::new($false))
                $fakeGhCommand = @'
    @echo off
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ITL_TEST_GH_SCRIPT%" %*
    exit /b %ERRORLEVEL%
'@
                [IO.File]::WriteAllText((Join-Path $fakeBin "gh.cmd"), $fakeGhCommand, [Text.Encoding]::ASCII)
                $env:ITL_TEST_GH_SCRIPT = $fakeGhScript
                $env:ITL_TEST_GH_REMOTE = $fixture.remote
                $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath

                $definitions = @(Get-DeliveryFunctionDefinitions -Names @(
                    'Invoke-DeliveryGitHubCli',
                    'Get-ReleaseRemoteCommit',
                    'Complete-ReleaseDevelopReconciliation',
                    'Publish-ReleaseThroughGitHubPullRequest'
                ) | ForEach-Object { $_.Extent.Text })
                $payload = & {
                    param([string[]]$FunctionDefinitions, [string]$Root, [string]$Repository, [string]$Commit, [string]$Tree, [string]$ExpectedMaster)
                    . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
                    function Invoke-WorktreeGit {
                        param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
                        return Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure
                    }
                    foreach ($definition in $FunctionDefinitions) { Invoke-Expression $definition }
                    $script:Remote = "origin"
                    Publish-ReleaseThroughGitHubPullRequest -CandidateRoot $Root -Repository $Repository -Candidate $Commit -CandidateTree $Tree -ExpectedDevelop $Commit -ExpectedMaster $ExpectedMaster
                } $definitions $fixture.root "fixture/repository" $candidate $candidateTree $fixture.base

                $payload.mode | Should -Be "github-pull-request"
                $payload.pullRequest | Should -Be "17"
                $payload.masterCommit | Should -Not -Be $candidate
                (& git --git-dir=$($fixture.remote) rev-parse "$($payload.masterCommit)^{tree}").Trim() | Should -Be $candidateTree
                (& git --git-dir=$($fixture.remote) rev-parse "$($payload.developCommit)^{tree}").Trim() | Should -Be $candidateTree
                & git --git-dir=$($fixture.remote) merge-base --is-ancestor $payload.masterCommit $payload.developCommit
                $LASTEXITCODE | Should -Be 0
                $releaseSource = (Get-DeliveryFunctionDefinitions -Names @('Release-DevelopToMaster')).Extent.Text
                $releaseSource | Should -Match ([regex]::Escape('Publish-ReleaseThroughGitHubPullRequest'))
            } finally {
                $env:PATH = $oldPath
                if ($null -eq $oldGhScript) { Remove-Item Env:ITL_TEST_GH_SCRIPT -ErrorAction SilentlyContinue } else { $env:ITL_TEST_GH_SCRIPT = $oldGhScript }
                if ($null -eq $oldGhRemote) { Remove-Item Env:ITL_TEST_GH_REMOTE -ErrorAction SilentlyContinue } else { $env:ITL_TEST_GH_REMOTE = $oldGhRemote }
                Remove-DeliveryFixture -Fixture $fixture
                if ($fakeBin) { Remove-Item -LiteralPath $fakeBin -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
}
