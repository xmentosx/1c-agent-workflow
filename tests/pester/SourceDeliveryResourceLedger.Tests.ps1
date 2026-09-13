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
    function Get-DeliveryFileSha256 { param([string]$Path); (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    function Get-DeliveryCommonGitDirectory { (& git -C $script:Root rev-parse --path-format=absolute --git-common-dir).Trim() }
    function Get-DevelopPublicationAttemptPath { Join-Path (Get-DeliveryCommonGitDirectory) 'itl\publication-attempts\develop.json' }
    function Test-SourceDeliveryPathInUse { param([string]$Path); return $false }
    function Invoke-RepositoryGit {
        param([string]$RepositoryRoot,[string[]]$Arguments,[switch]$AllowFailure)
        $output = @(& git -C $RepositoryRoot @Arguments 2>&1); [pscustomobject]@{ exitCode=$LASTEXITCODE; stdout=($output -join [Environment]::NewLine); stderr='' }
    }
    function Invoke-DeliveryGit {
        param([string[]]$Arguments,[switch]$AllowFailure)
        Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure
    }
    function Invoke-SourceDeliveryPostSuccessCleanup {
        param([string]$FreshProjectsRoot,[string]$E2EProjectRoot,[string[]]$PreservePaths)
        [pscustomobject]@{ status='completed'; warnings=@() }
    }
    . (Join-Path $RepoRoot 'scripts\git-path-list.ps1')
    . (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1')
    . (Join-Path $RepoRoot 'scripts\source-delivery-resources.ps1')
    . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')

    function New-LedgerRepository {
        $nonAscii = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))
        $root = Join-Path $TestDrive ("ledger repo $nonAscii " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet -b develop
        $script:Root = $root
        return $root
    }

    # Exercise the producer's actual path assignments without starting its E2E.
    $releaseAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'), [ref]$null, [ref]$null)
    $pathAssignments = @($releaseAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in @('$safeRunName', '$preferredReleaseRunRoot', '$legacyReleaseRunRoot')
    }, $false) | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.Extent.Text })
    $pathFunction = $releaseAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-E2ERunPaths' }, $false)
    $script:ReleaseProducerPathSetup = ($pathAssignments + @($pathFunction.Extent.Text)) -join "`n"

    function New-ReleaseSnapshotFixture {
        param([string]$Layout = 'preferred', [string]$Snapshot = 'baseline', [string]$RelativePath = '')
        $root = New-LedgerRepository
        & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'clean', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- tracked.txt; & git -C $root commit --quiet -m base
        $paths = & {
            param($worktreePath, $Layout)
            $devBranchName = 'workflow-release-e2e'
            . ([scriptblock]::Create($script:ReleaseProducerPathSetup))
            Set-E2ERunPaths -Root $(if ($Layout -eq 'legacy-run') { $legacyReleaseRunRoot } else { $preferredReleaseRunRoot })
            [pscustomobject]@{ baseline = $script:baselineSnapshotPath; postConfig = $script:postConfigSnapshotPath }
        } $root $Layout
        $path = if ($Snapshot -eq 'baseline') { $paths.baseline } else { $paths.postConfig }
        if ($Layout -eq 'legacy-flat') { $path = Join-Path $root '.agent-1c/snapshots/release-e2e-old.dt' }
        if ($RelativePath) { $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath)) }
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        $identity = [ordered]@{ path = $path; sha256 = (Get-DeliveryFileSha256 -Path $path); worktreePath = $root }
        $id = Register-DeliveryResource -PlanId 'old-plan' -Kind release-snapshot -Owner release-e2e -Identity $identity -State cleanup-pending
        [pscustomobject]@{ root = $root; path = $path; identity = $identity; resourceId = $id }
    }

    function New-DispositionRepository {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl disposition репо ' + [guid]::NewGuid().ToString('N'))
        $remote = Join-Path ([IO.Path]::GetTempPath()) ('itl-disposition-remote-' + [guid]::NewGuid().ToString('N') + '.git')
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet -b develop
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'published', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- tracked.txt
        & git -C $root commit --quiet -m published
        & git init --quiet --bare $remote
        & git -C $root remote add origin $remote
        & git -C $root push --quiet origin HEAD:develop HEAD:master
        & git -C $root fetch --quiet origin
        $script:Root = $root
        $script:Remote = 'origin'
        return [pscustomobject]@{ root=$root; remote=$remote; published=(& git -C $root rev-parse HEAD).Trim(); candidates=[Collections.Generic.List[string]]::new() }
    }

    function Add-DispositionCandidate {
        param(
            [Parameter(Mandatory = $true)][object]$Fixture,
            [string]$Commit = '',
            [ValidateSet('active','retained','cleanup-pending','removed')][string]$State = 'cleanup-pending',
            [switch]$RegisterLedger
        )
        $id = [guid]::NewGuid().ToString('N')
        $path = Join-Path ([IO.Path]::GetTempPath()) "itl-source-publish-develop-$id"
        $branch = "itl/publish-develop-$id"
        $start = if ($Commit) { $Commit } else { [string]$Fixture.published }
        & git -C $Fixture.root worktree add --quiet -b $branch $path $start
        $Fixture.candidates.Add($path) | Out-Null
        $resourceId = ''
        if ($RegisterLedger) {
            $resourceId = Register-DeliveryResource -PlanId "plan-$id" -Kind candidate-worktree -Owner source-delivery -Identity ([ordered]@{ path=$path; branch=$branch; candidate=$start }) -State $State
        }
        return [pscustomobject]@{ id=$id; path=$path; branch=$branch; fullBranch="refs/heads/$branch"; commit=$start; resourceId=$resourceId }
    }

    function Remove-DispositionRepository {
        param([AllowNull()][object]$Fixture)
        if (-not $Fixture) { return }
        foreach ($candidate in @($Fixture.candidates)) {
            if (Test-Path -LiteralPath $Fixture.root -PathType Container) { & git -C $Fixture.root worktree remove --force -- $candidate 2>$null }
            Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $Fixture.root, $Fixture.remote -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Delivery v3 resource ledger' {
    It 'keeps the disposition call graph read-only and documents the future CAS boundary' {
        $resourcePath = Join-Path $RepoRoot 'scripts\source-delivery-resources.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($resourcePath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $functionNames = @(
            'New-DeliveryDispositionEntry', 'Get-DeliveryDispositionGroups',
            'Invoke-DeliveryBoundedLsRemote', 'Get-DeliveryAuthoritativePublishedTips', 'Get-DeliveryPublishedCommitDisposition', 'Get-DeliveryPathUseAdvisory',
            'Test-DeliveryLedgerResourceOwnership', 'Get-DeliveryCandidateWorktreeDispositions',
            'Get-DeliveryDispositionPublicationAttempt', 'Get-DeliveryOwnedRefSnapshot', 'Get-DeliveryRefDispositions', 'Get-DeliveryResourceDispositions',
            'Get-DeliveryDispositionReport'
        )
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames
        }, $true))
        @($definitions.Name | Sort-Object) | Should -Be @($functionNames | Sort-Object)
        $dispositionText = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
        $dispositionText | Should -Not -Match '(?i)\bRemove-[A-Za-z]'
        $dispositionText | Should -Not -Match '(?i)\b(update-ref|worktree\s+remove|branch\s+-D|prune)\b'
        $dispositionText | Should -Not -Match 'Invoke-DeliveryCleanupSweep'
        $dispositionText | Should -Match ([regex]::Escape("@('--no-optional-locks', 'status', '--porcelain', '--untracked-files=all')"))
        $dispositionText | Should -Match ([regex]::Escape("'ls-remote', '--exit-code', '--refs', `$script:Remote, 'refs/heads/develop', 'refs/heads/master'"))
        $dispositionText | Should -Match ([regex]::Escape("EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'"))
        $dispositionText | Should -Match ([regex]::Escape("EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'"))
        $dispositionText | Should -Match ([regex]::Escape("'credential.interactive=never'"))
        $dispositionText | Should -Match ([regex]::Escape('StandardOutputEncoding = $utf8'))
        $dispositionText | Should -Match ([regex]::Escape('StandardErrorEncoding = $utf8'))
        $dispositionText | Should -Match ([regex]::Escape('Stop-DeliveryProcessTree -Process $process -TimeoutMilliseconds 5000 -CapturedDescendants @($capturedDescendants.Values)'))
        $dispositionText | Should -Match 'Get-DeliveryDescendantProcessIdentities -RootProcessId \$process\.Id -RootCreatedAt \$rootCreatedAt'
        $dispositionText | Should -Match ([regex]::Escape('foreach ($reader in @($stdoutTask, $stderrTask))'))
        $dispositionText | Should -Match ([regex]::Escape('$reader.Wait($remaining)'))
        $dispositionText | Should -Not -Match 'GetAwaiter\(\)\.GetResult\(\)'
        $dispositionText | Should -Match '\$process\.WaitForExit\(\[Math\]::Min\(100, \$remaining\)\)'

        $entryText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery.ps1') -Raw -Encoding UTF8
        $statusRouteOffset = $entryText.IndexOf('if ($Action -eq "Status")', [StringComparison]::Ordinal)
        $worktreeAddOffset = $entryText.IndexOf('& git -C $candidateRoot worktree add', [StringComparison]::Ordinal)
        $statusRouteOffset | Should -BeGreaterOrEqual 0
        $statusRouteOffset | Should -BeLessThan $worktreeAddOffset
        $entryText.Substring($statusRouteOffset, $worktreeAddOffset - $statusRouteOffset) | Should -Not -Match '(?i)worktree\s+(add|remove)'
        $supervisorText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-supervisor.ps1') -Raw -Encoding UTF8
        $supervisorText | Should -Match 'disposition = \(Get-DeliveryDispositionReport\)'
        $docsText = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\local-quality-gate.md') -Raw -Encoding UTF8
        foreach ($marker in @(
            'git update-ref --stdin', 'git update-ref -d <ref> <expectedSha>',
            'delivery-operation', 'name-only worktree match', 'age-based decision',
            'promotionCommit', 'Restore-DevelopCompatibilityPromotion',
            'git ls-remote', 'fixed timeout', 'credential prompts', 'Status.snapshot',
            'process-free-proof-required', 'resourceId'
        )) { $docsText | Should -Match ([regex]::Escape($marker)) }
    }

    It 'reports exact owned refs worktrees and resources without changing them' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            $owned = Add-DispositionCandidate -Fixture $fixture -RegisterLedger
            $lookalike = Add-DispositionCandidate -Fixture $fixture
            & git -C $fixture.root worktree add --quiet -b codex/user-keep (Join-Path ([IO.Path]::GetTempPath()) ('codex-user-keep-' + [guid]::NewGuid().ToString('N'))) $fixture.published
            $userRecord = @(& git -C $fixture.root worktree list --porcelain | Where-Object { $_ -like 'worktree *codex-user-keep-*' } | Select-Object -First 1)[0]
            $userPath = $userRecord.Substring(9)
            $fixture.candidates.Add($userPath) | Out-Null
            & git -C $fixture.root update-ref refs/itl/develop-queue/fixture/base $fixture.published
            & git -C $fixture.root update-ref refs/itl/develop-queue/fixture/head $fixture.published
            & git -C $fixture.root update-ref refs/itl/develop-queue/incomplete/base $fixture.published
            & git -C $fixture.root update-ref ("refs/itl/develop-promotions/" + ('a' * 64)) $fixture.published
            Register-DeliveryResource -PlanId unknown -Kind manual-cache -Owner user -Identity ([ordered]@{ path=$fixture.root }) -State retained | Out-Null
            Register-DeliveryResource -PlanId old -Kind release-snapshot -Owner release-e2e -Identity ([ordered]@{ path=(Join-Path $fixture.root 'missing.dt'); sha256=('b' * 64); worktreePath=$fixture.root }) -State removed | Out-Null
            $tamperedId = Register-DeliveryResource -PlanId tampered -Kind release-snapshot -Owner release-e2e -Identity ([ordered]@{ path=(Join-Path $fixture.root 'before.dt'); sha256=('c' * 64); worktreePath=$fixture.root }) -State retained
            $staleResourceId = Register-DeliveryResource -PlanId stale-id -Kind release-snapshot -Owner release-e2e -Identity ([ordered]@{ path=(Join-Path $fixture.root 'stale-before.dt'); sha256=('d' * 64); worktreePath=$fixture.root }) -State retained
            $tamperedLedger = Read-DeliveryResourceLedger
            @($tamperedLedger.resources | Where-Object resourceId -eq $tamperedId)[0].identity.path = Join-Path $fixture.root 'after.dt'
            $staleResource = @($tamperedLedger.resources | Where-Object resourceId -eq $staleResourceId)[0]
            $staleResource.identity.path = Join-Path $fixture.root 'stale-after.dt'
            $staleResource.identitySha256 = Get-DeliveryCanonicalJsonSha256 -Value $staleResource.identity
            Write-DeliveryResourceLedger -Ledger $tamperedLedger | Out-Null
            Mock Get-DeliveryPathUseAdvisory { [pscustomobject]@{status='advisory-clear';detail=''} }

            $refsBefore = (& git -C $fixture.root for-each-ref --format='%(refname) %(objectname)') -join "`n"
            $worktreesBefore = (& git -C $fixture.root worktree list --porcelain) -join "`n"
            $ledgerPath = Get-DeliveryResourceLedgerPath
            $ledgerBefore = [IO.File]::ReadAllText($ledgerPath)
            $indexPath = (Invoke-RepositoryGit -RepositoryRoot $owned.path -Arguments @('rev-parse','--path-format=absolute','--git-path','index')).stdout.Trim()
            $indexBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
            $indexShaBefore = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
            $report = Get-DeliveryDispositionReport

            $report.readOnly | Should -BeTrue
            $report.deleteSupported | Should -BeFalse
            @($report.futureDeleteContract) | Should -Be @('exact-ownership','expected-sha-cas','clean-worktree','complete-process-free-proof-required','authoritative-published-ancestry-or-exact-tree-equivalence')
            $report.publishedEvidence.status | Should -Be available
            $ownedEntry = @($report.worktrees.entries | Where-Object resourceId -eq $owned.resourceId)
            $ownedEntry.Count | Should -Be 1
            $ownedEntry[0].disposition | Should -Be keep
            $ownedEntry[0].reason | Should -Be process-free-proof-required
            $ownedEntry[0].expectedSha | Should -Be $fixture.published
            @($report.worktrees.entries | Where-Object identity -like "$($lookalike.path)|*")[0].disposition | Should -Be not-owned
            @($report.worktrees.entries | Where-Object identity -like '*codex-user-keep*').Count | Should -Be 0
            @($report.refs.entries | Where-Object identity -like 'refs/heads/codex/*').Count | Should -Be 0
            @($report.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/fixture/*').disposition | Should -Be @('eligible','eligible')
            @($report.refs.entries | Where-Object identity -eq 'refs/itl/develop-queue/incomplete/base')[0].disposition | Should -Be not-owned
            @($report.refs.entries | Where-Object identity -eq 'refs/itl/develop-queue/incomplete/base')[0].reason | Should -Be incomplete-queue-pair
            @($report.resources.entries | Where-Object identity -eq 'manual-cache|user')[0].disposition | Should -Be not-owned
            @($report.resources.entries | Where-Object resourceId -eq $tamperedId)[0].reason | Should -Be identity-proof-mismatch
            @($report.resources.entries | Where-Object resourceId -eq $staleResourceId)[0].reason | Should -Be resource-id-proof-mismatch
            @($report.resources.groups | Where-Object reason -eq raw-history-preserved).count | Should -Be 1

            ((& git -C $fixture.root for-each-ref --format='%(refname) %(objectname)') -join "`n") | Should -BeExactly $refsBefore
            ((& git -C $fixture.root worktree list --porcelain) -join "`n") | Should -BeExactly $worktreesBefore
            [IO.File]::ReadAllText($ledgerPath) | Should -BeExactly $ledgerBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) | Should -BeExactly $indexBytesBefore
            (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash | Should -BeExactly $indexShaBefore
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'keeps the public Status route byte-for-byte read-only' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            $fixture.root | Should -Match ' '
            $fixture.root | Should -Match '[^\u0000-\u007f]'
            $candidate = Add-DispositionCandidate -Fixture $fixture -RegisterLedger
            $refsBefore = (& git -C $fixture.root for-each-ref --format='%(refname) %(objectname)') -join "`n"
            $worktreesBefore = (& git -C $fixture.root worktree list --porcelain) -join "`n"
            $ledgerPath = Get-DeliveryResourceLedgerPath
            $ledgerBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerPath))
            $rootIndex = (Invoke-RepositoryGit -RepositoryRoot $fixture.root -Arguments @('rev-parse','--path-format=absolute','--git-path','index')).stdout.Trim()
            $candidateIndex = (Invoke-RepositoryGit -RepositoryRoot $candidate.path -Arguments @('rev-parse','--path-format=absolute','--git-path','index')).stdout.Trim()
            $rootIndexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($rootIndex))
            $candidateIndexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($candidateIndex))

            $statusJson = (& (Join-Path $RepoRoot 'scripts\source-delivery.ps1') -Action Status -RepositoryRoot $fixture.root | Out-String)
            $publicStatus = $statusJson | ConvertFrom-Json
            $publicStatus.status | Should -Be ok
            $publicStatus.disposition.publishedEvidence.status | Should -Be available

            ((& git -C $fixture.root for-each-ref --format='%(refname) %(objectname)') -join "`n") | Should -BeExactly $refsBefore
            ((& git -C $fixture.root worktree list --porcelain) -join "`n") | Should -BeExactly $worktreesBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerPath)) | Should -BeExactly $ledgerBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($rootIndex)) | Should -BeExactly $rootIndexBefore
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($candidateIndex)) | Should -BeExactly $candidateIndexBefore
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'keeps a candidate unless every future deletion guard is proven' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            [IO.File]::WriteAllText((Join-Path $fixture.root 'tracked.txt'), 'unpublished change', [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- tracked.txt
            & git -C $fixture.root commit --quiet -m unpublished
            $unpublished = (& git -C $fixture.root rev-parse HEAD).Trim()
            $candidate = Add-DispositionCandidate -Fixture $fixture -Commit $unpublished -RegisterLedger
            Mock Get-DeliveryPathUseAdvisory { [pscustomobject]@{status='advisory-clear';detail=''} }
            (Get-DeliveryDispositionReport).worktrees.entries | Where-Object resourceId -eq $candidate.resourceId | Select-Object -ExpandProperty reason | Should -Be process-free-proof-required

            [IO.File]::WriteAllText((Join-Path $candidate.path 'untracked.txt'), 'user data', [Text.UTF8Encoding]::new($false))
            (Get-DeliveryDispositionReport).worktrees.entries | Where-Object resourceId -eq $candidate.resourceId | Select-Object -ExpandProperty reason | Should -Be worktree-not-clean
            Remove-Item -LiteralPath (Join-Path $candidate.path 'untracked.txt') -Force

            Mock Get-DeliveryPathUseAdvisory { [pscustomobject]@{status='unknown';detail='CIM unavailable'} }
            (Get-DeliveryDispositionReport).worktrees.entries | Where-Object resourceId -eq $candidate.resourceId | Select-Object -ExpandProperty reason | Should -Be worktree-process-advisory-unknown

            Mock Get-DeliveryPathUseAdvisory { [pscustomobject]@{status='advisory-active';detail=''} }
            (Get-DeliveryDispositionReport).worktrees.entries | Where-Object resourceId -eq $candidate.resourceId | Select-Object -ExpandProperty reason | Should -Be worktree-process-advisory-active

            $ledger = Read-DeliveryResourceLedger
            $resource = @($ledger.resources | Where-Object resourceId -eq $candidate.resourceId)[0]
            $resource.identity.candidate = $fixture.published
            $resource.identitySha256 = Get-DeliveryCanonicalJsonSha256 -Value $resource.identity
            $resource.resourceId = Get-DeliveryTextSha256 -Text "$([string]$resource.planId)|$([string]$resource.kind)|$([string]$resource.owner)|$([string]$resource.identitySha256)"
            $candidate.resourceId = [string]$resource.resourceId
            Write-DeliveryResourceLedger -Ledger $ledger | Out-Null
            Mock Get-DeliveryPathUseAdvisory { [pscustomobject]@{status='advisory-clear';detail=''} }
            $mismatch = (Get-DeliveryDispositionReport).worktrees.entries | Where-Object resourceId -eq $candidate.resourceId
            $mismatch.reason | Should -Be expected-sha-mismatch
            $mismatch.expectedSha | Should -Be $fixture.published
            $mismatch.observedSha | Should -Be $unpublished
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'accepts exact published tree equivalence only from authoritative remote tips' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            $publishedTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $equivalentOutput = 'equivalent root' | & git -C $fixture.root commit-tree $publishedTree
            $equivalent = ($equivalentOutput -join '').Trim()
            $promotionRef = "refs/itl/develop-promotions/$('b' * 64)"
            & git -C $fixture.root update-ref $promotionRef $equivalent
            $entry = (Get-DeliveryDispositionReport).refs.entries | Where-Object identity -eq $promotionRef
            $entry.disposition | Should -Be eligible
            $entry.reason | Should -Be promotion-published-tree-equivalent
            $entry.expectedSha | Should -Be $equivalent
            $entry.observedSha | Should -Be $equivalent
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'ignores spoofed remote-tracking publication refs and fails closed when the remote is unavailable' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            [IO.File]::WriteAllText((Join-Path $fixture.root 'tracked.txt'), 'local only', [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- tracked.txt
            & git -C $fixture.root commit --quiet -m 'local only'
            $localOnly = (& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root update-ref refs/remotes/origin/develop $localOnly
            & git -C $fixture.root update-ref refs/remotes/origin/master $localOnly
            & git -C $fixture.root update-ref refs/itl/develop-queue/spoof/base $fixture.published
            & git -C $fixture.root update-ref refs/itl/develop-queue/spoof/head $localOnly

            $report = Get-DeliveryDispositionReport
            $report.publishedEvidence.status | Should -Be available
            @($report.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/spoof/*').disposition | Should -Be @('keep','keep')
            @($report.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/spoof/*').reason | Should -Be @('queue-open','queue-open')

            $script:Remote = 'missing-authoritative-remote'
            $unavailable = Get-DeliveryDispositionReport
            $unavailable.publishedEvidence.status | Should -Be unavailable
            @($unavailable.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/spoof/*').disposition | Should -Be @('keep','keep')
        } finally {
            $script:Remote = 'origin'
            Remove-DispositionRepository -Fixture $fixture
        }
    }

    It 'keeps refs when the attempt or owned ref snapshot changes across the remote probe' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            $promotionRef = "refs/itl/develop-promotions/$('c' * 64)"
            & git -C $fixture.root update-ref $promotionRef $fixture.published
            $attemptPath = Get-DevelopPublicationAttemptPath
            $script:raceAttemptPath = $attemptPath
            $script:racePromotionRef = $promotionRef
            $script:racePublished = $fixture.published
            Mock Invoke-DeliveryBoundedLsRemote {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:raceAttemptPath) | Out-Null
                $attempt = [ordered]@{ schemaVersion=1; promotionRef=$script:racePromotionRef; promotionCommit=$script:racePublished }
                [IO.File]::WriteAllText($script:raceAttemptPath, (($attempt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ status='completed'; exitCode=0; stdout="$($script:racePublished)`trefs/heads/develop`n$($script:racePublished)`trefs/heads/master`n"; stderr='' }
            }

            $attemptRace = Get-DeliveryDispositionReport
            $attemptRace.snapshot.attemptStable | Should -BeFalse
            $attemptRace.snapshot.stable | Should -BeFalse
            $attemptEntry = @($attemptRace.refs.entries | Where-Object identity -eq $promotionRef)[0]
            $attemptEntry.disposition | Should -Be keep
            $attemptEntry.reason | Should -Be publication-attempt-changed-during-status

            Remove-Item -LiteralPath $attemptPath -Force
            [IO.File]::WriteAllText((Join-Path $fixture.root 'tracked.txt'), 'ref changed during status', [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- tracked.txt
            & git -C $fixture.root commit --quiet -m 'ref race'
            $script:raceNewCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            Mock Invoke-DeliveryBoundedLsRemote {
                & git -C $script:Root update-ref $script:racePromotionRef $script:raceNewCommit
                [pscustomobject]@{ status='completed'; exitCode=0; stdout="$($script:racePublished)`trefs/heads/develop`n$($script:racePublished)`trefs/heads/master`n"; stderr='' }
            }

            $refRace = Get-DeliveryDispositionReport
            $refRace.snapshot.refsStable | Should -BeFalse
            $refEntry = @($refRace.refs.entries | Where-Object identity -eq $promotionRef)[0]
            $refEntry.disposition | Should -Be keep
            $refEntry.reason | Should -Be local-ref-snapshot-changed
        } finally {
            Remove-Variable raceAttemptPath, racePromotionRef, racePublished, raceNewCommit -Scope Script -ErrorAction SilentlyContinue
            Remove-DispositionRepository -Fixture $fixture
        }
    }

    It 'keeps published-dependent refs when the bounded no-prompt probe times out or cannot authenticate' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            & git -C $fixture.root update-ref refs/itl/develop-queue/bounded/base $fixture.published
            & git -C $fixture.root update-ref refs/itl/develop-queue/bounded/head $fixture.published

            Mock Invoke-DeliveryBoundedLsRemote { [pscustomobject]@{ status='timed-out'; exitCode=-1; stdout=''; stderr='timeout' } }
            $timedOut = Get-DeliveryDispositionReport
            $timedOut.publishedEvidence.status | Should -Be timeout
            @($timedOut.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/bounded/*').disposition | Should -Be @('keep','keep')

            Mock Invoke-DeliveryBoundedLsRemote { [pscustomobject]@{ status='completed'; exitCode=128; stdout=''; stderr='authentication disabled' } }
            $authUnavailable = Get-DeliveryDispositionReport
            $authUnavailable.publishedEvidence.status | Should -Be unavailable
            @($authUnavailable.refs.entries | Where-Object identity -like 'refs/itl/develop-queue/bounded/*').disposition | Should -Be @('keep','keep')
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'bounds a real hanging publication probe and removes its descendant process' -Skip:($env:OS -ne 'Windows_NT') {
        $fixture = $null
        $childPid = 0
        $priorAllowProtocol = $env:GIT_ALLOW_PROTOCOL
        $priorPidPath = $env:ITL_DISPOSITION_CHILD_PID_PATH
        try {
            $fixture = New-DispositionRepository
            $pidPath = Join-Path $TestDrive ('probe child ' + [guid]::NewGuid().ToString('N') + '.pid')
            $env:GIT_ALLOW_PROTOCOL = 'ext'
            $env:ITL_DISPOSITION_CHILD_PID_PATH = $pidPath
            $childPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('while ($true) { Start-Sleep -Seconds 1 }'))
            $probeBody = @'
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$env:ITL_DISPOSITION_CHILD_PAYLOAD) -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($env:ITL_DISPOSITION_CHILD_PID_PATH, [string]$child.Id, [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
'@
            $probePayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeBody))
            $env:ITL_DISPOSITION_CHILD_PAYLOAD = $childPayload
            $script:Remote = "ext::powershell.exe -NoLogo -NoProfile -EncodedCommand $probePayload"

            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-DeliveryBoundedLsRemote -TimeoutMilliseconds 750
            $watch.Stop()
            $result.status | Should -Be timed-out
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 7
            Test-Path -LiteralPath $pidPath | Should -BeTrue
            $childPid = [int](Get-Content -LiteralPath $pidPath -Raw -Encoding UTF8)
            $exitDeadline = [DateTime]::UtcNow.AddSeconds(3)
            while ([DateTime]::UtcNow -lt $exitDeadline -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 100 }
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally {
            if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
            $env:GIT_ALLOW_PROTOCOL = $priorAllowProtocol
            $env:ITL_DISPOSITION_CHILD_PID_PATH = $priorPidPath
            Remove-Item Env:\ITL_DISPOSITION_CHILD_PAYLOAD -ErrorAction SilentlyContinue
            $script:Remote = 'origin'
            Remove-DispositionRepository -Fixture $fixture
        }
    }

    It 'bounds reader drain when an exited git root leaves a pipe-holding descendant' -Skip:($env:OS -ne 'Windows_NT') {
        $fixture = $null
        $childPid = 0
        $priorPath = $env:PATH
        $priorPidPath = $env:ITL_DISPOSITION_PIPE_CHILD_PID_PATH
        $priorChildPayload = $env:ITL_DISPOSITION_PIPE_CHILD_PAYLOAD
        try {
            $fixture = New-DispositionRepository
            $fakeRoot = Join-Path $TestDrive ('fake git путь ' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $fakeRoot | Out-Null
            $fakeGit = Join-Path $fakeRoot 'git.exe'
            $typeName = 'PipeHoldingGit' + [guid]::NewGuid().ToString('N')
            $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public static class $typeName
{
    public static int Main()
    {
        ProcessStartInfo childInfo = new ProcessStartInfo();
        childInfo.FileName = "powershell.exe";
        childInfo.Arguments = "-NoLogo -NoProfile -EncodedCommand " + Environment.GetEnvironmentVariable("ITL_DISPOSITION_PIPE_CHILD_PAYLOAD");
        childInfo.UseShellExecute = false;
        childInfo.CreateNoWindow = true;
        Process child = Process.Start(childInfo);
        File.WriteAllText(Environment.GetEnvironmentVariable("ITL_DISPOSITION_PIPE_CHILD_PID_PATH"), child.Id.ToString(), new UTF8Encoding(false));
        Thread.Sleep(1500);
        return 0;
    }
}
"@
            $sourcePath = Join-Path $fakeRoot 'fake-git.cs'
            [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($true))
            $compiler = @(
                (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
                (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            $compiler | Should -Not -BeNullOrEmpty
            & $compiler /nologo /target:exe "/out:$fakeGit" $sourcePath
            $LASTEXITCODE | Should -Be 0
            $pidPath = Join-Path $TestDrive ('pipe child ' + [guid]::NewGuid().ToString('N') + '.pid')
            $childBody = 'while ($true) { Start-Sleep -Seconds 1 }'
            $env:ITL_DISPOSITION_PIPE_CHILD_PAYLOAD = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childBody))
            $env:ITL_DISPOSITION_PIPE_CHILD_PID_PATH = $pidPath
            $env:PATH = "$fakeRoot;$priorPath"
            $script:Remote = 'ignored-by-fake-git'

            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-DeliveryBoundedLsRemote -TimeoutMilliseconds 3000
            $watch.Stop()
            $result.status | Should -Be timed-out
            $result.stderr | Should -Match 'output drain'
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 7
            Test-Path -LiteralPath $pidPath | Should -BeTrue
            $childPid = [int](Get-Content -LiteralPath $pidPath -Raw -Encoding UTF8)
            $exitDeadline = [DateTime]::UtcNow.AddSeconds(3)
            while ([DateTime]::UtcNow -lt $exitDeadline -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 100 }
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally {
            if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
            $env:PATH = $priorPath
            $env:ITL_DISPOSITION_PIPE_CHILD_PID_PATH = $priorPidPath
            $env:ITL_DISPOSITION_PIPE_CHILD_PAYLOAD = $priorChildPayload
            $script:Remote = 'origin'
            Remove-DispositionRepository -Fixture $fixture
        }
    }

    It 'keeps an active promotion ref and fails closed on attempt mismatch or corruption' {
        $fixture = $null
        try {
            $fixture = New-DispositionRepository
            $promotionRef = "refs/itl/develop-promotions/$('d' * 64)"
            & git -C $fixture.root update-ref $promotionRef $fixture.published
            $attemptPath = Get-DevelopPublicationAttemptPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attemptPath) | Out-Null
            $attempt = [ordered]@{ schemaVersion=1; promotionRef=$promotionRef; promotionCommit=$fixture.published }
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))

            $active = @((Get-DeliveryDispositionReport).refs.entries | Where-Object identity -eq $promotionRef)[0]
            $active.disposition | Should -Be keep
            $active.reason | Should -Be active-promotion
            $active.expectedSha | Should -Be $fixture.published
            $active.observedSha | Should -Be $fixture.published

            $attempt.promotionCommit = ('e' * 40)
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
            $mismatch = @((Get-DeliveryDispositionReport).refs.entries | Where-Object identity -eq $promotionRef)[0]
            $mismatch.disposition | Should -Be keep
            $mismatch.reason | Should -Be active-promotion-sha-mismatch
            $mismatch.expectedSha | Should -Be ('e' * 40)
            $mismatch.observedSha | Should -Be $fixture.published

            $attempt.Remove('promotionCommit')
            [IO.File]::WriteAllText($attemptPath, (($attempt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
            $incomplete = @((Get-DeliveryDispositionReport).refs.entries | Where-Object identity -eq $promotionRef)[0]
            $incomplete.disposition | Should -Be keep
            $incomplete.reason | Should -Be active-promotion-attempt-malformed

            [IO.File]::WriteAllText($attemptPath, '{broken', [Text.UTF8Encoding]::new($false))
            $malformed = @((Get-DeliveryDispositionReport).refs.entries | Where-Object identity -eq $promotionRef)[0]
            $malformed.disposition | Should -Be keep
            $malformed.reason | Should -Be publication-attempt-unreadable
            (Get-DeliveryDispositionReport).publicationAttemptGuard.status | Should -Be malformed
        } finally { Remove-DispositionRepository -Fixture $fixture }
    }

    It 'journals known resources from a failed report before optional artifacts exist' {
        $root=New-LedgerRepository
        $output=Join-Path $root 'build/test-results/local'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $reportPath=Join-Path $output 'partial-release.json'
        $report=[ordered]@{status='failed';projectRoot=$root;artifactRetention=[ordered]@{}}
        [IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $output 'check-summary.json'),(@{e2eReportPath=$reportPath} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        foreach ($mode in @('Develop','Release')) {
            @(Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode $mode -Failed).Count | Should -Be 1
        }
        @((Read-DeliveryResourceLedger).resources | Where-Object kind -eq 'reusable-stand').Count | Should -Be 2
        $report.status='passed'
        [IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        { Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release } | Should -Throw '*retainedResultArtifact*'
    }

    It 'keeps failed-gate journaling best effort while successful-gate journaling remains mandatory' {
        $root=New-LedgerRepository
        Mock Register-DeliveryGateResourcesCore { throw 'ledger write unavailable' }
        Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release -Failed -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        { Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release } | Should -Throw '*ledger write unavailable*'
    }

    It 'retains only the two newest failed plans and never longer than seven days' {
        New-LedgerRepository | Out-Null
        foreach ($id in 1..3) { Register-DeliveryResource -PlanId "plan-$id" -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=(Join-Path $TestDrive "candidate-$id") }) -State retained | Out-Null }
        $ledger = Read-DeliveryResourceLedger
        for ($index=0; $index -lt 3; $index++) {
            $ledger.resources[$index].updatedAt = [DateTime]::UtcNow.AddHours(-3 + $index).ToString('o')
            $ledger.resources[$index].retainUntil = [DateTime]::UtcNow.AddDays(6).ToString('o')
        }
        $ledger.resources[2].retainUntil = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        Write-DeliveryResourceLedger -Ledger $ledger | Out-Null
        Update-DeliveryFailedPlanRetention
        $states = Read-DeliveryResourceLedger
        @($states.resources | Where-Object state -eq 'retained' | Select-Object -ExpandProperty planId) | Should -Be @('plan-2')
        @($states.resources | Where-Object state -eq 'cleanup-pending' | Select-Object -ExpandProperty planId | Sort-Object) | Should -Be @('plan-1','plan-3')
    }

    It 'reads JSON timestamps independently of the current culture' {
        New-LedgerRepository | Out-Null
        Register-DeliveryResource -PlanId 'culture-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=(Join-Path $TestDrive 'culture-candidate') }) -State retained | Out-Null
        $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
            { Update-DeliveryFailedPlanRetention } | Should -Not -Throw
            { Get-DeliveryResourceLedgerSummary } | Should -Not -Throw
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
        }
    }

    It 'turns a stale active candidate into retained state and preserves its path' {
        $root = New-LedgerRepository; $active = Join-Path $root 'active-resource'; New-Item -ItemType Directory -Force -Path $active | Out-Null
        Register-DeliveryResource -PlanId 'active-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=$active }) -State active | Out-Null
        $script:capturedPreserve = @()
        Mock Invoke-SourceDeliveryPostSuccessCleanup { param($FreshProjectsRoot,$E2EProjectRoot,$PreservePaths); $script:capturedPreserve=@($PreservePaths); [pscustomobject]@{status='completed';warnings=@()} }
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null
        @($script:capturedPreserve) | Should -Contain $active
        (Read-DeliveryResourceLedger).resources[0].state | Should -Be 'retained'
    }

    It 'turns housekeeping failure into retryable debt and clears it after a successful retry' {
        $root = New-LedgerRepository; $script:returnWarning = $true
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{ status=$(if($script:returnWarning){'completed-with-warnings'}else{'completed'}); warnings=$(if($script:returnWarning){@('fixture cleanup failure')}else{@()}) } }
        $first = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root -Phase post-operation
        $first.status | Should -Be 'completed-with-warnings'; $first.debt.pending | Should -Be 1; $first.debt.entries[0].lastError | Should -Match 'fixture cleanup failure'
        $script:returnWarning = $false
        $second = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root -Phase pre-operation
        $second.status | Should -Be 'completed'; $second.debt.pending | Should -Be 0
    }

    It 'removes missing cleanup resources idempotently and reports debt size and next attempt' {
        $root = New-LedgerRepository; $missing = Join-Path $root 'itl-source-publish-develop-00000000000000000000000000000000'
        Register-DeliveryResource -PlanId 'failed-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=$missing }) -State cleanup-pending | Out-Null
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{status='completed';warnings=@()} }
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null; Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null
        $ledger = Read-DeliveryResourceLedger; @($ledger.resources).Count | Should -Be 1; $ledger.resources[0].state | Should -Be 'removed'; [int]$ledger.resources[0].cleanupAttempts | Should -Be 1
        $summary = Get-DeliveryResourceLedgerSummary; $summary.pending | Should -Be 0; $summary.nextAttempt | Should -Match 'PublishDevelop'
    }

    It 'removes only a SHA-matched owned Release snapshot and leaves the reusable worktree' {
        $root = New-LedgerRepository
        & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'clean', [Text.UTF8Encoding]::new($false)); & git -C $root add tracked.txt; & git -C $root commit --quiet -m base
        $snapshotRoot = Join-Path $root '.agent-1c\snapshots'; New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
        $snapshot = Join-Path $snapshotRoot 'release-e2e-old.dt'; [IO.File]::WriteAllText($snapshot, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        $identity = [ordered]@{ path=$snapshot; sha256=(Get-DeliveryFileSha256 -Path $snapshot); worktreePath=$root }
        Register-DeliveryResource -PlanId 'expired-plan' -Kind 'release-snapshot' -Owner 'release-e2e' -Identity $identity -State cleanup-pending | Out-Null
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{status='completed';warnings=@()} }
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root
        $result.status | Should -Be 'completed'; Test-Path -LiteralPath $snapshot | Should -BeFalse; Test-Path -LiteralPath $root | Should -BeTrue
        (Read-DeliveryResourceLedger).resources[0].state | Should -Be 'removed'
    }
}

Describe 'Release snapshot cleanup ownership and retention' {
    It 'cleans the actual producer <Layout> <Snapshot> path and preserves the worktree' -TestCases @(
        @{ Layout = 'preferred'; Snapshot = 'baseline' }, @{ Layout = 'preferred'; Snapshot = 'post-config' },
        @{ Layout = 'legacy-run'; Snapshot = 'baseline' }, @{ Layout = 'legacy-run'; Snapshot = 'post-config' }
    ) {
        param($Layout, $Snapshot)
        $fixture = New-ReleaseSnapshotFixture -Layout $Layout -Snapshot $Snapshot
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.root 'tracked.txt') | Should -BeTrue
        $resource = (Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $fixture.resourceId
        $resource.state | Should -Be 'removed'
        $again = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $again.debt.pending | Should -Be 0
    }

    It 'preserves a pending snapshot while another record has <State> ownership, then cleans it after release' -TestCases @(
        @{ State = 'retained' }, @{ State = 'active' }
    ) {
        param($State)
        $fixture = New-ReleaseSnapshotFixture -Layout legacy-flat
        $newId = Register-DeliveryResource -PlanId 'new-plan' -Kind release-snapshot -Owner release-e2e -Identity $fixture.identity -State $State -RetainUntil ([DateTime]::UtcNow.AddDays(6))
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root | Out-Null
        Test-Path -LiteralPath $fixture.path | Should -BeTrue
        $ledger = Read-DeliveryResourceLedger
        ($ledger.resources | Where-Object resourceId -eq $newId).state | Should -Be $State
        ($ledger.resources | Where-Object resourceId -eq $fixture.resourceId).state | Should -Be 'cleanup-pending'
        Set-DeliveryResourceState -ResourceId $newId -State cleanup-pending | Out-Null
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root | Out-Null
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
    }

    It 'rejects unowned layout <RelativePath>' -TestCases @(
        @{ RelativePath = '../foreign-snapshot.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e-other/run/snapshots/baseline.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e/run/snapshots/manual-backup.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e/run/nested/snapshots/baseline.dt' },
        @{ RelativePath = '.agent-1c/snapshots/unowned.dt' }
    ) {
        param($RelativePath)
        $fixture = New-ReleaseSnapshotFixture -RelativePath $RelativePath
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed-with-warnings'
        ($result.warnings -join ' ') | Should -Match 'outside the owned Release snapshot root'
        [IO.File]::ReadAllText($fixture.path) | Should -Be 'owned snapshot'
        ((Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $fixture.resourceId).state | Should -Be 'cleanup-pending'
    }

    It 'preserves <Failure> evidence instead of deleting the snapshot' -TestCases @(
        @{ Failure = 'changed-sha'; Error = 'snapshot SHA differs' },
        @{ Failure = 'dirty-worktree'; Error = 'tracked drift' },
        @{ Failure = 'active-process'; Error = 'active process' }
    ) {
        param($Failure, $Error)
        $fixture = New-ReleaseSnapshotFixture
        if ($Failure -eq 'changed-sha') { [IO.File]::WriteAllText($fixture.path, 'changed snapshot', [Text.UTF8Encoding]::new($false)) }
        if ($Failure -eq 'dirty-worktree') { [IO.File]::WriteAllText((Join-Path $fixture.root 'tracked.txt'), 'dirty', [Text.UTF8Encoding]::new($false)) }
        if ($Failure -eq 'active-process') { Mock Test-SourceDeliveryPathInUse { $true } }
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed-with-warnings'
        ($result.warnings -join ' ') | Should -Match $Error
        Test-Path -LiteralPath $fixture.path | Should -BeTrue
    }

    It 'does not follow a snapshot-directory junction to a foreign file with the same SHA' {
        $fixture = New-ReleaseSnapshotFixture
        $directory = Split-Path $fixture.path
        $foreign = Join-Path $TestDrive ('foreign target ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $foreign | Out-Null
        $foreignSnapshot = Join-Path $foreign 'baseline.dt'
        [IO.File]::WriteAllText($foreignSnapshot, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $fixture.path -Force
        Remove-Item -LiteralPath $directory -Force
        New-Item -ItemType Junction -Path $directory -Target $foreign | Out-Null
        try {
            $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
            $result.status | Should -Be 'completed-with-warnings'
            ($result.warnings -join ' ') | Should -Match 'reparse point'
            [IO.File]::ReadAllText($foreignSnapshot) | Should -Be 'owned snapshot'
        } finally {
            $junction = Get-Item -LiteralPath $directory -Force
            if ($junction.LinkType -eq 'Junction') { $junction.Delete() }
        }
    }

    It 'cleans an expired retained snapshot without requiring a manual ledger rewrite' {
        $fixture = New-ReleaseSnapshotFixture
        $newId = Register-DeliveryResource -PlanId 'expired-retention' -Kind release-snapshot -Owner release-e2e -Identity $fixture.identity -State retained -RetainUntil ([DateTime]::UtcNow.AddMinutes(-1))
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        ((Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $newId).state | Should -Be 'removed'
    }

    It 'retires obsolete records for a reused filename in the same sweep after the matching owner removes it' {
        $fixture = New-ReleaseSnapshotFixture
        [IO.File]::WriteAllText($fixture.path, 'new snapshot generation', [Text.UTF8Encoding]::new($false))
        $newIdentity = [ordered]@{ path = $fixture.path; sha256 = (Get-DeliveryFileSha256 -Path $fixture.path); worktreePath = $fixture.root }
        Register-DeliveryResource -PlanId 'new-plan' -Kind release-snapshot -Owner release-e2e -Identity $newIdentity -State cleanup-pending | Out-Null
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        $result.debt.pending | Should -Be 0
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        @((Read-DeliveryResourceLedger).resources | Where-Object { $_.kind -eq 'release-snapshot' -and $_.state -eq 'removed' }).Count | Should -Be 2
    }
}
