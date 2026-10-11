. (Join-Path $PSScriptRoot 'SourceDeliveryFrozen.TestSupport.ps1')
    function Add-IntegrityFixtureCallback([object]$Fixture,[string]$Stage) {
        $path=if($Stage -eq 'gate'){$Fixture.gate}else{$Fixture.finalizer}
        $body=[IO.File]::ReadAllText($path)
        ([regex]::Matches($body,'(?m)^exit 0\r?$')).Count | Should -Be 1
        $mutation=if($Stage -eq 'gate'){
@'
if ($Mode -eq 'Develop' -and $env:ITL_TEST_MUTATE_PUBLICATION_STAGE -eq 'gate') {
    & git -C (Get-Location).Path commit --quiet --allow-empty -m 'unqualified callback commit'
    if ($LASTEXITCODE) { exit 21 }
}
'@
        }else{
@'
if ($env:ITL_TEST_MUTATE_PUBLICATION_STAGE -eq 'finalizer') {
    [IO.File]::WriteAllText((Join-Path $RepositoryRoot 'unqualified.txt'), 'unqualified tree', [Text.UTF8Encoding]::new($false))
}
'@
        }
        $body=[regex]::Replace($body,'(?m)^exit 0\r?$',($mutation+"`r`nexit 0"))
        [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($true))
    }
