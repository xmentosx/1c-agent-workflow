BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1') }

Describe 'Frozen source publication membership' {
    It 'publishes a saved plan legacy without absorbing a later task before the first attempt' { Invoke-FrozenSavedPlan -Record legacy -Legacy:$true }
}
