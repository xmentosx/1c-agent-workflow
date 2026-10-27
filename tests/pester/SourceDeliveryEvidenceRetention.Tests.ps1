BeforeAll {
    Set-StrictMode -Version Latest
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-process.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-ref-cleanup.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-candidate.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-evidence.ps1')
    function Get-DeliveryCommonGitDirectory { Join-Path $script:Root '.git' }
    function New-RecoveryFixture {
        param([string]$Phase='develop', [int]$Age=10, [switch]$Nested)
        $id = [guid]::NewGuid().ToString('N').Substring(0,12)
        $name = "$Phase-aaaaaaaaaaaa-$id"
        $path = Join-Path (Get-DeliveryCommonGitDirectory) "itl/evidence/fixture-cleanup/$name"
        $copy = Join-Path $script:Root "copies/$name"
        $payloadRoot = if ($Nested) { Join-Path $path 'archived-inactive' } else { $path }
        [void][IO.Directory]::CreateDirectory($payloadRoot)
        $proof = @{kind='itl-fixture-copy-cleanup-proof'; reason='archive-inactive-qualification'; candidateCommit=($id + ('b'*28)); copyRoot=$copy; workflowCommonGit=(Get-DeliveryCommonGitDirectory)}
        $proofPath = Join-Path $payloadRoot 'cleanup-proof.json'
        [IO.File]::WriteAllText($proofPath, ($proof | ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $payloadRoot 'recovery.zip'), 'unique recovery bytes')
        [IO.File]::WriteAllText((Join-Path $payloadRoot 'source.bundle'), 'git history')
        [IO.File]::WriteAllText((Join-Path $payloadRoot 'recovery-index.json'), '[]')
        foreach ($file in Get-ChildItem -LiteralPath $payloadRoot -File) { $file.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$Age) }
        [pscustomobject]@{path=$path; copy=$copy; payload=(Join-Path $payloadRoot 'recovery.zip'); bundle=(Join-Path $payloadRoot 'source.bundle'); proof=$proofPath}
    }
    function Write-RecoveryGuardJson {
        param([string]$RelativePath, [object]$Value)
        $path = Join-Path (Get-DeliveryCommonGitDirectory) $RelativePath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 12))
        return $path
    }
    $savedDays = $env:ITL_SOURCE_RECOVERY_RETENTION_DAYS
    $savedKeep = $env:ITL_SOURCE_RECOVERY_KEEP_COUNT
    $script:RecoveryInventoryBody = (Get-Command Get-DeliveryRecoveryInventory).ScriptBlock
}

Describe 'Source recovery archive retention' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('репозиторий с пробелом ' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Get-DeliveryCommonGitDirectory))
        $script:ActiveOperation = $null
        $env:ITL_SOURCE_RECOVERY_RETENTION_DAYS = '7'
        $env:ITL_SOURCE_RECOVERY_KEEP_COUNT = '0'
    }
    AfterEach { Exit-DeliveryOperation }

    It 'previews exact bytes without creating receipts or altering files' {
        $fixture = New-RecoveryFixture -Nested
        $before = (Get-FileHash -LiteralPath $fixture.payload).Hash
        $report = Get-DeliveryRecoveryInventory -IncludeEntries
        $report.eligible | Should -Be 1
        $report.eligibleBytes | Should -Be ((Get-Item $fixture.payload).Length + (Get-Item $fixture.bundle).Length)
        (Get-FileHash -LiteralPath $fixture.payload).Hash | Should -Be $before
        Test-Path (Join-Path $fixture.path 'retention.json') | Should -BeFalse
    }

    It 'exposes preview through the ordinary public Status route in Windows PowerShell' {
        $fixture = New-RecoveryFixture
        & git -C $script:Root init --quiet -b develop
        [IO.File]::WriteAllText((Join-Path $script:Root 'tracked.txt'), 'source')
        & git -C $script:Root add -- tracked.txt
        & git -C $script:Root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
        $result = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/source-delivery.ps1') -Arguments @('-Action','Status','-RepositoryRoot',$script:Root,'-StatusDetail','Full')
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        $report = ($result.stdout -join "`n") | ConvertFrom-Json
        $report.recoveryArchives.eligible | Should -Be 1 -Because ($report.recoveryArchives | ConvertTo-Json -Depth 8)
        $report.recoveryArchives.entries[0].path | Should -Be $fixture.path
        Test-Path $fixture.payload | Should -BeTrue
        Test-Path (Join-Path $fixture.path 'retention.json') | Should -BeFalse
    }

    It 'keeps two newest archives independently for Develop and Release' {
        $env:ITL_SOURCE_RECOVERY_KEEP_COUNT = '2'
        foreach ($phase in @('develop','release')) { foreach ($age in @(8,9,10)) { $null = New-RecoveryFixture -Phase $phase -Age $age } }
        $report = Get-DeliveryRecoveryInventory -IncludeEntries
        $report.eligible | Should -Be 2
        @($report.entries | Where-Object reason -eq 'newest-recovery-quota').Count | Should -Be 4
    }

    It 'honors source .dev.env, process precedence and disabled retention' {
        $null = New-RecoveryFixture
        $env:ITL_SOURCE_RECOVERY_RETENTION_DAYS = ''
        $env:ITL_SOURCE_RECOVERY_KEEP_COUNT = ''
        [IO.File]::WriteAllText((Join-Path $script:Root '.dev.env'), "ITL_SOURCE_RECOVERY_RETENTION_DAYS=0`nITL_SOURCE_RECOVERY_KEEP_COUNT=0`n")
        (Get-DeliveryRecoveryInventory).eligible | Should -Be 0
        $env:ITL_SOURCE_RECOVERY_RETENTION_DAYS = '7'
        (Get-DeliveryRecoveryInventory).eligible | Should -Be 1
    }

    It 'preserves recent archives and invalid settings without blocking preview' {
        $null = New-RecoveryFixture -Age 1
        (Get-DeliveryRecoveryInventory -IncludeEntries).entries[0].reason | Should -Be 'within-retention'
        $env:ITL_SOURCE_RECOVERY_KEEP_COUNT = '-1'
        $report = Get-DeliveryRecoveryInventory
        $report.eligible | Should -Be 0
        $report.warnings | Should -Not -BeNullOrEmpty
    }

    It 'preserves the recovery archive while its original copy exists' {
        $fixture = New-RecoveryFixture
        [void][IO.Directory]::CreateDirectory($fixture.copy)
        (Get-DeliveryRecoveryInventory -IncludeEntries).entries[0].reason | Should -Be 'original-copy-present'
    }

    It 'preserves every archive during a resumable publication, including malformed attempts' {
        $fixture = New-RecoveryFixture
        $null = Write-RecoveryGuardJson 'itl/publication-attempts/develop.json' @{phase='failed'}
        $null = Enter-DeliveryOperation -Action Cleanup
        (Invoke-DeliveryRecoveryCleanup).removedFiles | Should -Be 0
        Test-Path $fixture.payload | Should -BeTrue
    }

    It 'requires the real manual operation lease and rejects publication leases' {
        $fixture = New-RecoveryFixture
        { Invoke-DeliveryRecoveryCleanup } | Should -Throw '*manual Cleanup*'
        $null = Enter-DeliveryOperation -Action PublishDevelop
        { Invoke-DeliveryRecoveryCleanup } | Should -Throw '*manual Cleanup*'
        (Get-DeliveryRecoveryInventory -IncludeEntries).entries[0].reason | Should -Be 'delivery-operation-present'
        Test-Path $fixture.payload | Should -BeTrue
    }

    It 'protects nested ledger references to the original copy' {
        $fixture = New-RecoveryFixture
        $null = Write-RecoveryGuardJson 'itl/resources/v1/ledger.json' @{schemaVersion=1;resources=@(@{state='retained';identity=@{nested=@{path=(Join-Path $fixture.copy 'branch')}}})}
        (Get-DeliveryRecoveryInventory -IncludeEntries).entries[0].reason | Should -Be 'owner-or-checkpoint-reference'
    }

    It 'protects archive checkpoint references and fails closed on unreadable state' {
        $fixture = New-RecoveryFixture
        $path = Write-RecoveryGuardJson 'itl/plans/v1/old/checkpoint.json' @{archive=$fixture.payload}
        (Get-DeliveryRecoveryInventory).eligible | Should -Be 0
        [IO.File]::WriteAllText($path, 'broken json')
        $report = Get-DeliveryRecoveryInventory
        $report.eligible | Should -Be 0
        $report.warnings | Should -Not -BeNullOrEmpty
    }

    It 'does not adopt foreign or unrecognized proof by age or name' {
        $fixture = New-RecoveryFixture
        $proof = Get-Content -LiteralPath $fixture.proof -Raw -Encoding UTF8 | ConvertFrom-Json
        $proof.workflowCommonGit = Join-Path $TestDrive 'foreign/.git'
        [IO.File]::WriteAllText($fixture.proof, ($proof | ConvertTo-Json))
        (Get-DeliveryRecoveryInventory).eligible | Should -Be 0
        Remove-Item -LiteralPath $fixture.proof
        (Get-DeliveryRecoveryInventory).eligible | Should -Be 0
    }

    It 'retains a reparse tree and never visits its target' -Skip:($env:OS -ne 'Windows_NT') {
        $fixture = New-RecoveryFixture
        $outside = Join-Path $TestDrive 'внешние данные'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'untouched')
        $link = Join-Path $fixture.path 'linked'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            (Get-DeliveryRecoveryInventory).eligible | Should -Be 0
            (Get-Content (Join-Path $outside 'keep.txt') -Encoding UTF8) | Should -Be 'untouched'
        } finally { [IO.Directory]::Delete($link) }
    }

    It 'retains the entire recovery set when <Name> has an open reader' -ForEach @(@{Name='recovery.zip'}, @{Name='source.bundle'}) {
        $fixture = New-RecoveryFixture
        $reader = [IO.File]::Open((Join-Path (Split-Path -Parent $fixture.payload) $Name), 'Open', 'Read', 'Read')
        try {
            $null = Enter-DeliveryOperation -Action Cleanup
            $report = Invoke-DeliveryRecoveryCleanup
            $report.status | Should -Be 'completed-with-warnings'
            $report.removedFiles | Should -Be 0
            Test-Path $fixture.payload | Should -BeTrue
            Test-Path $fixture.bundle | Should -BeTrue
        } finally { $reader.Dispose() }
    }

    It 'expires exact payloads, retains proof and indexes, and is idempotent' {
        $fixture = New-RecoveryFixture -Nested
        $expectedHash = (Get-FileHash -LiteralPath $fixture.payload).Hash
        $proofHash = (Get-FileHash -LiteralPath $fixture.proof).Hash
        $null = Enter-DeliveryOperation -Action Cleanup
        $report = Invoke-DeliveryRecoveryCleanup
        $report.warnings | Should -BeNullOrEmpty
        $report.removedFiles | Should -Be 2
        Test-Path $fixture.payload | Should -BeFalse
        Test-Path $fixture.bundle | Should -BeFalse
        (Get-FileHash -LiteralPath $fixture.proof).Hash | Should -Be $proofHash
        Test-Path (Join-Path (Split-Path $fixture.proof -Parent) 'recovery-index.json') | Should -BeTrue
        $receipt = Get-Content (Join-Path $fixture.path 'retention.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($receipt.files | Where-Object path -eq $fixture.payload)[0].sha256 | Should -Be $expectedHash
        @($receipt.files | Where-Object status -ne 'removed').Count | Should -Be 0
        (Invoke-DeliveryRecoveryCleanup).removedFiles | Should -Be 0
    }

    It 'retains bytes when the durable deletion receipt cannot be saved' {
        $fixture = New-RecoveryFixture
        Mock Write-DeliveryRecoveryReceipt { throw 'simulated disk failure' }
        $null = Enter-DeliveryOperation -Action Cleanup
        (Invoke-DeliveryRecoveryCleanup).removedFiles | Should -Be 0
        Test-Path $fixture.payload | Should -BeTrue
    }

    It 'rechecks the inventory under the lease instead of trusting preview bytes' {
        $fixture = New-RecoveryFixture
        $script:ChangingPayload = $fixture.payload
        $script:InventoryCalls = 0
        Mock Get-DeliveryRecoveryInventory {
            param([switch]$IncludeEntries)
            $script:InventoryCalls++
            if ($script:InventoryCalls -eq 2) { [IO.File]::WriteAllText($script:ChangingPayload, 'new unique bytes') }
            & $script:RecoveryInventoryBody -IncludeEntries:$IncludeEntries
        }
        $null = Enter-DeliveryOperation -Action Cleanup
        (Invoke-DeliveryRecoveryCleanup).removedFiles | Should -Be 0
        Get-Content -LiteralPath $fixture.payload -Encoding UTF8 | Should -Be 'new unique bytes'
    }

    It 'preserves a copy recreated while a payload is being admitted' {
        $fixture = New-RecoveryFixture
        $script:RecreatedCopy = $fixture.copy
        Mock Write-DeliveryRecoveryReceipt { [void][IO.Directory]::CreateDirectory($script:RecreatedCopy) }
        $null = Enter-DeliveryOperation -Action Cleanup
        (Invoke-DeliveryRecoveryCleanup).removedFiles | Should -Be 0
        Test-Path $fixture.payload | Should -BeTrue
    }
}

AfterAll {
    $env:ITL_SOURCE_RECOVERY_RETENTION_DAYS = $savedDays
    $env:ITL_SOURCE_RECOVERY_KEEP_COUNT = $savedKeep
}
