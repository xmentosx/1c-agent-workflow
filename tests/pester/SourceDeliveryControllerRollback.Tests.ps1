BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryHistorical.TestSupport.ps1') }
Describe 'Compatible functional controller rollback' {
    It 'rejects a literal legacy decoder and completes the rollback with new accepted work preserved' {
        $fixture=$null
        try {
            $fixture=New-FrozenFixture
            $alpha=Add-FrozenTask $fixture alpha
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            & git -C $fixture.root switch --quiet -c rollback $alpha
            $historical=Join-Path $TestDrive 'historical rollback'
            Expand-Archive -LiteralPath (Get-HistoricalDeliveryArchive) -DestinationPath $historical
            Copy-Item -LiteralPath (Join-Path $historical 'scripts/source-delivery-queue.ps1') -Destination (Join-Path $fixture.root 'scripts/source-delivery-queue.ps1')
            [IO.File]::WriteAllText((Join-Path $fixture.root 'functional-rollback.txt'),'original behavior',[Text.UTF8Encoding]::new($false))
            $bad=Add-FrozenTask $fixture rollback
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $refused=Invoke-FrozenDelivery $fixture PublishDevelop -AllowFailure
            $refused.exitCode | Should -Not -Be 0
            $refused.stderr | Should -Match 'DELIVERY_CONTROLLER_PROTOCOL_INCOMPATIBLE'
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/alpha/head).Trim() | Should -BeExactly $bad
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 0
            & git -C $fixture.root switch --quiet -c beta $fixture.base
            $beta=Add-FrozenTask $fixture beta
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','beta') | Out-Null
            & git -C $fixture.root switch --quiet rollback
            & git -C $fixture.root restore --source=$($fixture.base) -- scripts/source-delivery-queue.ps1
            $LASTEXITCODE | Should -Be 0
            $repair=Add-FrozenTask $fixture repair
            Invoke-FrozenDelivery $fixture RegisterChange @('-QueueId','alpha') | Out-Null
            $published=(Invoke-FrozenDelivery $fixture PublishDevelop).stdout | ConvertFrom-Json
            (& git -C $fixture.root show "$($published.commit):functional-rollback.txt").Trim() | Should -BeExactly 'original behavior'
            foreach($head in @($repair,$beta)){ & git -C $fixture.root merge-base --is-ancestor $head $published.commit; $LASTEXITCODE | Should -Be 0 }
            @((Get-Content -LiteralPath $fixture.modeLog)|Where-Object {$_ -eq 'Develop'}).Count | Should -Be 1
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue).Count | Should -Be 0
            @(& git -C $fixture.root status --porcelain).Count | Should -Be 0
        } finally { Remove-DeliveryFixture $fixture }
    }
}
