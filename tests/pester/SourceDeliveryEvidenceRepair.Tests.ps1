BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryEvidence.TestSupport.ps1') }
Describe 'Rejected develop proof recovery' {
    It 'names the corrupt proof and explicitly replaces it while completing the original publication' {
        $fixture=$null; $prior=$env:ITL_TEST_FAIL_COMPONENT_FINALIZER
        try {
            $fixture=New-DeliveryProofFixture
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER='true'
            (Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure).exitCode | Should -Not -Be 0
            $attempt=Read-FrozenAttempt $fixture
            $planId=[string]$attempt.planId
            $checkpointPath=Join-Path $fixture.root '.git/itl/publication-attempts/develop.json'
            $checkpoint=[IO.File]::ReadAllText($checkpointPath)
            $evidencePath=@(Get-ChildItem -LiteralPath (Join-Path $fixture.root '.git/itl/evidence/v1/develop.custom-gate') -Filter evidence.json -Recurse).FullName
            @($evidencePath).Count | Should -Be 1
            $evidence=Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $broken='corrupt proof: Путь с пробелом'
            [IO.File]::WriteAllText([string]$evidence.proof.path,$broken,[Text.UTF8Encoding]::new($false))
            $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$null
            $refused=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $refused.exitCode | Should -Not -Be 0
            $refused.stderr | Should -Match 'DELIVERY_STAGE_EVIDENCE_CORRUPT'
            $refused.stderr | Should -Match 'SHA256 changed; expected'
            $unwrapped=$refused.stderr.Replace("`r",'').Replace("`n",'')
            $unwrapped.IndexOf([string]$evidence.proof.path,[StringComparison]::Ordinal) | Should -BeGreaterOrEqual 0
            [IO.File]::ReadAllText($checkpointPath) | Should -BeExactly $checkpoint
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop @('-Replan',$planId)).stdout | ConvertFrom-Json
            $published.commit | Should -BeExactly $alpha
            $published.planId | Should -Not -Be $planId
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 2
            $archives=@(Get-ChildItem -LiteralPath (Join-Path $fixture.root '.git/itl/evidence-rejected/v1') -Directory)
            $archives.Count | Should -Be 1
            $archivedProof=Join-Path $archives[0].FullName (Split-Path -Leaf ([string]$evidence.proof.path))
            [IO.File]::ReadAllText($archivedProof) | Should -BeExactly $broken
            $repaired=Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            (Get-FileHash -LiteralPath ([string]$repaired.proof.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly ([string]$repaired.proof.sha256)
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { $env:ITL_TEST_FAIL_COMPONENT_FINALIZER=$prior; Remove-DeliveryFixture $fixture }
    }
}
