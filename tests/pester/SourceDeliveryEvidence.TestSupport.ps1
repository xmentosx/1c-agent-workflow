. (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1')
function New-DeliveryProofFixture {
    $fixture=New-FrozenFixture
    try {
        # The ordinary fake gate has no stage report. This fixture adds a
        # real hashed report so corruption reaches the production reader.
        $gateBody=[IO.File]::ReadAllText($fixture.gate)
        $at=$gateBody.LastIndexOf('exit 0',[StringComparison]::Ordinal)
        if($at -lt 0){throw 'Fixture gate exit changed'}
        $reportHook=@'
if ($Mode -in @('Develop','Release')) {
    $local=Join-Path (Get-Location) 'build/test-results/local'
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    $summary=[ordered]@{status='passed';mode=$Mode;e2eReportPath=''}
    [IO.File]::WriteAllText((Join-Path $local 'check-summary.json'),($summary|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
'@
        [IO.File]::WriteAllText($fixture.gate,($gateBody.Substring(0,$at)+$reportHook+"`n"+$gateBody.Substring($at)),[Text.UTF8Encoding]::new($true))
        & git -C $fixture.root add --all
        & git -C $fixture.root commit --quiet -m 'test: publish fake gate with a real stage proof'
        $LASTEXITCODE | Should -Be 0
        & git -C $fixture.root push --quiet origin HEAD:develop
        $LASTEXITCODE | Should -Be 0
        $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
        return $fixture
    } catch { Remove-DeliveryFixture $fixture; throw }
}
