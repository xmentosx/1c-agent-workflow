BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot

    function Get-DeliveryTextSha256 {
        param([string]$Text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function Get-DeliveryCanonicalJsonSha256 {
        param([object]$Value)
        Get-DeliveryTextSha256 -Text ($Value | ConvertTo-Json -Depth 24 -Compress)
    }
    function Get-DevelopPublicationAttemptPath { Join-Path (Get-DeliveryCommonGitDirectory) 'itl\publication-attempts\develop.json' }
    function Test-SourceDeliveryPathInUse { param([string]$Path); return $false }
    function Invoke-SourceDeliveryPostSuccessCleanup {
        param([string]$FreshProjectsRoot,[string]$E2EProjectRoot,[string[]]$PreservePaths)
        [pscustomobject]@{ status='completed'; warnings=@() }
    }

    . (Join-Path $RepoRoot 'scripts\git-path-list.ps1')
    function Invoke-DeliveryGit {
        param([string[]]$Arguments,[switch]$AllowFailure,[AllowNull()][string]$StandardInput=$null)
        Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
    }
    function Get-DeliveryCommonGitDirectory {
        $value = (Invoke-DeliveryGit -Arguments @('rev-parse','--path-format=absolute','--git-common-dir')).stdout.Trim()
        if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
        return [IO.Path]::GetFullPath((Join-Path $script:Root $value))
    }
    function ConvertTo-QueueRefName {
        param([string]$Value)
        $name = $Value.Trim().Replace('\', '/').ToLowerInvariant()
        $name = [regex]::Replace($name, '[^a-z0-9._/-]+', '-')
        $name = [regex]::Replace($name, '/+', '/')
        $name = $name.Trim('/', '.', '-')
        if (-not $name) { throw 'Queue id cannot be converted to a safe Git ref name.' }
        return $name
    }

    . (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1')
    . (Join-Path $RepoRoot 'scripts\source-delivery-resources.ps1')
    . (Join-Path $RepoRoot 'scripts\source-delivery-ref-cleanup.ps1')
    . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')

    function New-RefCleanupFixture {
        $root = Join-Path $TestDrive ('ref cleanup репо ' + [guid]::NewGuid().ToString('N'))
        $remote = Join-Path $TestDrive ('ref cleanup удаленный ' + [guid]::NewGuid().ToString('N') + '.git')
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet -b develop
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'base', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m base
        $base = (& git -C $root rev-parse HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'published', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m published
        $head = (& git -C $root rev-parse HEAD).Trim()
        & git init --quiet --bare $remote
        & git -C $root remote add origin $remote
        & git -C $root push --quiet origin HEAD:develop HEAD:master
        $script:Root = $root
        $script:Remote = 'origin'
        $script:QueueRoot = 'refs/itl/develop-queue'
        $script:ActiveOperation = $null
        return [pscustomobject]@{ root=$root; remote=$remote; base=$base; head=$head; promotion=('a' * 64) }
    }

    function Add-RefCleanupCandidates {
        param([Parameter(Mandatory=$true)][object]$Fixture,[switch]$Queue,[switch]$Promotion)
        if ($Queue) {
            & git -C $Fixture.root update-ref 'refs/itl/develop-queue/fixture/base' $Fixture.base
            & git -C $Fixture.root update-ref 'refs/itl/develop-queue/fixture/head' $Fixture.head
        }
        if ($Promotion) { & git -C $Fixture.root update-ref "refs/itl/develop-promotions/$($Fixture.promotion)" $Fixture.head }
    }

    function Remove-RefCleanupFixture {
        param([AllowNull()][object]$Fixture)
        try { Exit-DeliveryOperation } catch {}
        $script:ActiveOperation = $null
        if ($Fixture) { Remove-Item -LiteralPath $Fixture.root, $Fixture.remote -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Source delivery ref-only cleanup' {
    It 'routes mutation only through manual Cleanup and keeps Status and publication sweeps free of it' {
        $supervisor = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-supervisor.ps1') -Raw -Encoding UTF8
        ([regex]::Matches($supervisor, 'Invoke-DeliveryRefDispositionCleanup')).Count | Should -Be 1
        $statusStart = $supervisor.IndexOf('"Status" {', [StringComparison]::Ordinal)
        $cleanupStart = $supervisor.IndexOf('"Cleanup" {', [StringComparison]::Ordinal)
        $diagnoseStart = $supervisor.IndexOf('"DiagnoseFull" {', [StringComparison]::Ordinal)
        $statusStart | Should -BeGreaterOrEqual 0
        $cleanupStart | Should -BeGreaterThan $statusStart
        $diagnoseStart | Should -BeGreaterThan $cleanupStart
        $supervisor.Substring($statusStart, $cleanupStart - $statusStart) | Should -Not -Match 'Invoke-DeliveryRefDispositionCleanup'
        $manualCleanup = $supervisor.Substring($cleanupStart, $diagnoseStart - $cleanupStart)
        $manualCleanup | Should -Match 'Invoke-DeliveryCleanupSweep[\s\S]+Invoke-DeliveryRefDispositionCleanup'
        $refCleanupOffset = $manualCleanup.IndexOf('Invoke-DeliveryRefDispositionCleanup', [StringComparison]::Ordinal)
        foreach ($compaction in @('Repair-DeliveryRunHotIndex', 'Compact-DeliveryResourceLedger')) {
            $compactionOffset = $manualCleanup.IndexOf($compaction, [StringComparison]::Ordinal)
            if ($compactionOffset -ge 0) { $compactionOffset | Should -BeLessThan $refCleanupOffset }
        }
        $supervisor.Substring($diagnoseStart) | Should -Not -Match 'Invoke-DeliveryRefDispositionCleanup'

        $module = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-ref-cleanup.ps1') -Raw -Encoding UTF8
        $module | Should -Match ([regex]::Escape("@('update-ref', '--no-deref', '--stdin')"))
        $module | Should -Not -Match '(?i)worktree\s+remove|branch\s+-D|\bprune\b|Remove-DeliveryPendingLedgerResource'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts\source-delivery-ref-cleanup.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $cas = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeliveryRefCasTransaction' }, $false)
        $casParameterCount = if ($cas.Body.ParamBlock) { @($cas.Body.ParamBlock.Parameters).Count } else { 0 }
        $casParameterCount | Should -Be 0 -Because 'the mutating boundary must always recompute its own authoritative plan'
    }

    It 'fails before mutation without the exact live manual Cleanup lease' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue
            { Invoke-DeliveryRefDispositionCleanup } | Should -Throw '*active manual Cleanup*'
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/base').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/head').Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'rejects an in-memory operation that no longer matches the persisted Cleanup lease' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue
            [void](Enter-DeliveryOperation -Action Cleanup)
            $script:ActiveOperation.id = [guid]::NewGuid().ToString('N')

            { Invoke-DeliveryRefDispositionCleanup } | Should -Throw '*missing, changed, or owned by another process*'
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/base').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/head').Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'atomically deletes exact eligible queue and promotion refs and is idempotent' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue -Promotion
            [void](Enter-DeliveryOperation -Action Cleanup)
            $first = Invoke-DeliveryRefDispositionCleanup
            $first.status | Should -Be completed
            @($first.removed).Count | Should -Be 3
            (& git -C $fixture.root rev-parse --verify 'refs/itl/develop-queue/fixture/base' 2>$null) | Should -BeNullOrEmpty
            (& git -C $fixture.root rev-parse --verify 'refs/itl/develop-queue/fixture/head' 2>$null) | Should -BeNullOrEmpty
            (& git -C $fixture.root rev-parse --verify "refs/itl/develop-promotions/$($fixture.promotion)" 2>$null) | Should -BeNullOrEmpty

            $second = Invoke-DeliveryRefDispositionCleanup
            $second.status | Should -Be unchanged
            @($second.removed).Count | Should -Be 0
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'leaves the whole transaction unchanged when one old SHA no longer matches' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue -Promotion
            [void](Enter-DeliveryOperation -Action Cleanup)
            $script:injectedCasMove = $false
            Mock Invoke-DeliveryGit {
                param([string[]]$Arguments,[switch]$AllowFailure,[AllowNull()][string]$StandardInput=$null)
                if (-not $script:injectedCasMove -and $Arguments[0] -eq 'update-ref' -and $Arguments -contains '--stdin') {
                    $script:injectedCasMove = $true
                    [void](Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments @('update-ref','refs/itl/develop-queue/fixture/head',$fixture.base,$fixture.head))
                }
                return Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
            }

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            $result.reason | Should -Be 'expected-sha-cas-failed'
            $script:injectedCasMove | Should -BeTrue
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/base').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/head').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse "refs/itl/develop-promotions/$($fixture.promotion)").Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'rejects non-canonical case variants in queue ownership' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            & git -C $fixture.root update-ref 'refs/itl/develop-queue/fixture/BASE' $fixture.base
            & git -C $fixture.root update-ref 'refs/itl/develop-queue/fixture/HEAD' $fixture.head
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/BASE').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/HEAD').Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'rejects an uppercase promotion identity even when its commit is published' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            $upperPromotion = 'B' * 64
            & git -C $fixture.root update-ref "refs/itl/develop-promotions/$upperPromotion" $fixture.head
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            $result.reason | Should -Be 'eligible-promotion-ref-changed-or-indirect'
            (& git -C $fixture.root rev-parse "refs/itl/develop-promotions/$upperPromotion").Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'blocks active-attempt ABA around the exact disposition snapshot' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Promotion
            [void](Enter-DeliveryOperation -Action Cleanup)
            $script:attemptProbeCalls = 0
            Mock Get-DeliveryDispositionPublicationAttempt {
                $script:attemptProbeCalls++
                if ($script:attemptProbeCalls -eq 1) {
                    return [pscustomobject]@{ status='valid'; path='attempt.json'; fingerprint='attempt-A'; attempt=[pscustomobject]@{ schemaVersion=1; promotionRef="refs/itl/develop-promotions/$($fixture.promotion)"; promotionCommit=$fixture.head } }
                }
                if ($script:attemptProbeCalls -eq 2) {
                    return [pscustomobject]@{ status='absent'; path='attempt.json'; fingerprint='attempt-B'; attempt=$null }
                }
                return [pscustomobject]@{ status='valid'; path='attempt.json'; fingerprint='attempt-A'; attempt=[pscustomobject]@{ schemaVersion=1; promotionRef="refs/itl/develop-promotions/$($fixture.promotion)"; promotionCommit=$fixture.head } }
            }

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            $result.reason | Should -Be 'disposition-snapshot-unstable'
            (Get-DeliveryDispositionPublicationAttempt).fingerprint | Should -Be 'attempt-A'
            $script:attemptProbeCalls | Should -Be 3
            (& git -C $fixture.root rev-parse "refs/itl/develop-promotions/$($fixture.promotion)").Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'does not dereference a symbolic ref in an owned namespace' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            $symbolic = "refs/itl/develop-promotions/$($fixture.promotion)"
            & git -C $fixture.root symbolic-ref $symbolic refs/heads/develop
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            $result.reason | Should -Be 'eligible-promotion-ref-changed-or-indirect'
            (& git -C $fixture.root symbolic-ref $symbolic).Trim() | Should -Be 'refs/heads/develop'
            (& git -C $fixture.root rev-parse refs/heads/develop).Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'keeps an active promotion while deleting no unrelated namespace' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Promotion
            & git -C $fixture.root update-ref refs/heads/codex/user-keep $fixture.head
            $attemptPath = Get-DevelopPublicationAttemptPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attemptPath) | Out-Null
            $attempt = [ordered]@{ schemaVersion=1; promotionRef="refs/itl/develop-promotions/$($fixture.promotion)"; promotionCommit=$fixture.head }
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be unchanged
            (& git -C $fixture.root rev-parse "refs/itl/develop-promotions/$($fixture.promotion)").Trim() | Should -Be $fixture.head
            (& git -C $fixture.root rev-parse refs/heads/codex/user-keep).Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'aborts a prepared transaction without a commit and then converges through Cleanup' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue
            $payload = "start`ndelete refs/itl/develop-queue/fixture/base $($fixture.base)`ndelete refs/itl/develop-queue/fixture/head $($fixture.head)`nprepare`n"
            $prepared = Invoke-DeliveryGit -Arguments @('update-ref','--no-deref','--stdin') -StandardInput $payload -AllowFailure
            $prepared.exitCode | Should -Be 0
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/base').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/head').Trim() | Should -Be $fixture.head

            [void](Enter-DeliveryOperation -Action Cleanup)
            (Invoke-DeliveryRefDispositionCleanup).status | Should -Be completed
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'fails closed when authoritative remote evidence is unavailable' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            Add-RefCleanupCandidates -Fixture $fixture -Queue
            & git -C $fixture.root remote set-url origin (Join-Path $TestDrive 'missing remote.git')
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be needs-attention
            $result.reason | Should -Be 'authoritative-publication-evidence-unavailable'
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/base').Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse 'refs/itl/develop-queue/fixture/head').Trim() | Should -Be $fixture.head
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }

    It 'returns unchanged without remote proof when no mutable owned refs exist' {
        $fixture = $null
        try {
            $fixture = New-RefCleanupFixture
            & git -C $fixture.root remote set-url origin (Join-Path $TestDrive 'missing remote.git')
            [void](Enter-DeliveryOperation -Action Cleanup)

            $result = Invoke-DeliveryRefDispositionCleanup
            $result.status | Should -Be unchanged
            $result.reason | Should -Be 'no-eligible-refs'
        } finally { Remove-RefCleanupFixture -Fixture $fixture }
    }
}
