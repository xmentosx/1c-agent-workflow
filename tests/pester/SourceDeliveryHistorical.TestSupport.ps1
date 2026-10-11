. (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1')
function Get-HistoricalDeliveryArchive {
    $root=Join-Path $RepoRoot 'tests/fixtures/source-delivery-history'
    $manifest=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive=Join-Path $root 'fa0-controller.zip'
    if ($manifest.sourceCommit -cne 'fa0e3c91694112c1da3ecda7209a8a81ea828264' -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.archiveSha256) { throw 'Historical controller fixture identity is invalid' }
    return $archive
}
function New-HistoricalDeliveryFixture {
    $fixture=New-DeliveryFixture
    try {
        Expand-Archive -LiteralPath (Get-HistoricalDeliveryArchive) -DestinationPath $fixture.root -Force
        & git -C $fixture.root add --all
        & git -C $fixture.root commit --quiet -m 'test: publish exact fa0 controller closure'
        if($LASTEXITCODE){throw 'Could not commit historical controller fixture'}
        & git -C $fixture.root push --quiet origin HEAD:develop HEAD:master
        if($LASTEXITCODE){throw 'Could not publish historical controller fixture'}
        $fixture.base=(& git -C $fixture.root rev-parse HEAD).Trim()
        return $fixture
    } catch { Remove-DeliveryFixture $fixture; throw }
}
