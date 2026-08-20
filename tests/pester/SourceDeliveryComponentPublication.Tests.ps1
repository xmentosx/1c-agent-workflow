BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
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
