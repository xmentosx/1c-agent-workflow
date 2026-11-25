BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }

Describe 'Frozen source publication membership' {
    It 'keeps the legacy plan identity and includes new frozen membership in new identities' {
        . ([scriptblock]::Create((Get-DeliveryFunctionDefinitions @('Get-DeliveryPlanIdentity','Get-DeliveryCanonicalJsonSha256','Get-DeliveryTextSha256','Set-DeliveryPlanQueue'))))
        $plan=[pscustomobject][ordered]@{supervisor=[pscustomobject]@{commit=('a'*40);channel='develop'};candidate=[pscustomobject]@{commit=('b'*40);tree=('c'*40);baseCommit=('d'*40)};requireRelease=$false;releaseCapabilities=@();paths=@('a.ps1');contracts=@('documentation');stages=@();planId=''}
        # Captured from the accepted7084 implementation before the optional field.
        (Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $plan)) | Should -Be 'aeb810f231a2ad33eb32200c4da60fec33c6b3d4b212dc5ad0777d29599dc0ca'
        Set-DeliveryPlanQueue $plan @([pscustomobject]@{id='alpha';base=('d'*40);head=('b'*40)})
        $first=$plan.planId
        Set-DeliveryPlanQueue $plan @([pscustomobject]@{id='alpha';base=('d'*40);head=('e'*40)})
        $plan.planId | Should -Not -Be $first
        $plan.supervisor.commit | Should -Be ('a'*40)
    }

    It 'runs the real custom-gate supervisor without native planner or qualifier modules' {
        $fixture=New-FrozenFixture
        try {
            foreach($name in @('delivery-native-plan.ps1','develop-e2e-qualification.ps1','develop-journey-inputs.ps1','develop-e2e-scenarios.ps1')) {
                Test-Path -LiteralPath (Join-Path $fixture.root ('scripts/'+$name)) | Should -BeFalse
            }
            Add-FrozenTask $fixture alpha | Out-Null
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $plan=(Invoke-FrozenDelivery $fixture Plan).stdout | ConvertFrom-Json
            $plan.status | Should -Be 'ready'
            @($plan.stages.id) | Should -Be @('develop.custom-gate')
        } finally {Remove-DeliveryFixture $fixture}
    }

    It 'publishes a saved plan current without absorbing a later task before the first attempt' { Invoke-FrozenSavedPlan -Record current -Legacy:$false }
}
