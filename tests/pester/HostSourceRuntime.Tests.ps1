BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    function New-SourceRuntimeFixture {
        $root=Join-Path $TestDrive ('Среда с пробелом '+[guid]::NewGuid().ToString('N'))
        $hostRoot=Join-Path $root 'vibecoding1c-mcp-host'
        New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
        foreach($file in @('install-vibecoding1c-mcp-host.ps1','beta-cutover.ps1','index-snapshot.ps1','sppr-host.ps1','owner-repair.ps1')){
            Copy-Item -LiteralPath (Join-Path $RepoRoot ('vibecoding1c-mcp-host/'+$file)) -Destination $hostRoot
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $hostRoot 'sppr-mcp') | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'vibecoding1c-mcp-host/sppr-mcp/requirements.txt') -Destination (Join-Path $hostRoot 'sppr-mcp')
        return $root
    }
}
Describe 'Source host Python environment ownership' {
    It 'prepares only the selected isolated component and reuses it with an explicit bootstrap and poisoned PATH' {
        $root=New-SourceRuntimeFixture
        $oldBootstrap=$env:ITL_SOURCE_TEST_PYTHON; $oldPath=$env:PATH
        try {
            $env:ITL_SOURCE_TEST_PYTHON=(Get-Command python -CommandType Application | Where-Object Source -NotMatch 'WindowsApps' | Select-Object -First 1).Source
            $first=Get-SourceHostTestPython -RepositoryRoot $root -Component Mantis
            $first | Should -Match ([regex]::Escape($root))
            $receipt=@(Get-ChildItem (Join-Path $root 'build/host-test-runtime') -Filter prepared.json -Recurse)
            $receipt.Count | Should -Be 1
            (Get-Content $receipt[0].FullName -Raw | ConvertFrom-Json).requirementsSha256 | Should -BeExactly 'stdlib-only'
            @((Get-ChildItem (Join-Path $root 'build/host-test-runtime') -Directory | Where-Object Name -Like 'sppr-*')).Count | Should -Be 0
            $env:PATH=$TestDrive
            $again=Get-SourceHostTestPython -RepositoryRoot $root -Component Mantis
            $again | Should -BeExactly $first
            $probe=& $again -I -X utf8 -c 'import sys; print(sys.argv[1]); print(sys.prefix != sys.base_prefix)' 'Путь с пробелом / имя.txt'
            $LASTEXITCODE | Should -Be 0
            $probe | Should -Be @('Путь с пробелом / имя.txt','True')
            @(Get-ChildItem (Join-Path $root 'build/host-test-runtime') -Filter prepared.json -Recurse).Count | Should -Be 1
        } finally { $env:ITL_SOURCE_TEST_PYTHON=$oldBootstrap; $env:PATH=$oldPath }
    }
    It 'continues the original component test after its missing bootstrap is repaired' {
        $root=New-SourceRuntimeFixture
        $oldBootstrap=$env:ITL_SOURCE_TEST_PYTHON
        $real=(Get-Command python -CommandType Application | Where-Object Source -NotMatch 'WindowsApps' | Select-Object -First 1).Source
        try {
            $env:ITL_SOURCE_TEST_PYTHON=Join-Path $root 'missing Python/python.exe'
            {Get-SourceHostTestPython -RepositoryRoot $root -Component Mantis} | Should -Throw '*Python executable was not found*'
            $env:ITL_SOURCE_TEST_PYTHON=$real
            $python=Get-SourceHostTestPython -RepositoryRoot $root -Component Mantis
            $previousError=$ErrorActionPreference
            try { $ErrorActionPreference='Continue'; $result=& $python -X utf8 -B (Join-Path $RepoRoot 'vibecoding1c-mcp-host/mantis-ticket-mcp/test_server.py') 2>&1; $code=$LASTEXITCODE }
            finally { $ErrorActionPreference=$previousError }
            $code | Should -Be 0 -Because ($result -join "`n")
            ($result -join "`n") | Should -Match 'Ran 12 tests'
        } finally { $env:ITL_SOURCE_TEST_PYTHON=$oldBootstrap }
    }
    It 'rejects a global SPPR override before changing its packages or preparing another component' {
        $root=New-SourceRuntimeFixture
        $oldBootstrap=$env:ITL_SOURCE_TEST_PYTHON; $oldSppr=$env:SPPR_TEST_PYTHON
        try {
            $env:ITL_SOURCE_TEST_PYTHON=(Get-Command python -CommandType Application | Where-Object Source -NotMatch 'WindowsApps' | Select-Object -First 1).Source
            $env:SPPR_TEST_PYTHON=$env:ITL_SOURCE_TEST_PYTHON
            $before=(Get-FileHash -LiteralPath $env:SPPR_TEST_PYTHON).Hash
            {Get-SourceHostTestPython -RepositoryRoot $root -Component Sppr} | Should -Throw '*not isolated*'
            (Get-FileHash -LiteralPath $env:SPPR_TEST_PYTHON).Hash | Should -BeExactly $before
            @(Get-ChildItem (Join-Path $root 'build/host-test-runtime') -Filter prepared.json -Recurse).Count | Should -Be 0
        } finally { $env:ITL_SOURCE_TEST_PYTHON=$oldBootstrap; $env:SPPR_TEST_PYTHON=$oldSppr }
    }
    It 'repairs missing owned SPPR dependencies and completes its original corpus test in the same environment' {
        $root=New-SourceRuntimeFixture
        $oldBootstrap=$env:ITL_SOURCE_TEST_PYTHON; $oldSppr=$env:SPPR_TEST_PYTHON
        try {
            $env:ITL_SOURCE_TEST_PYTHON=(Get-Command python -CommandType Application | Where-Object Source -NotMatch 'WindowsApps' | Select-Object -First 1).Source
            $env:SPPR_TEST_PYTHON=$null
            $python=Get-SourceHostTestPython -RepositoryRoot $root -Component Sppr
            $output=& $python -I -m pip uninstall --yes tzdata
            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
            $again=Get-SourceHostTestPython -RepositoryRoot $root -Component Sppr
            $again | Should -BeExactly $python
            $previousError=$ErrorActionPreference
            try { $ErrorActionPreference='Continue'; $output=& $again -X utf8 -B (Join-Path $RepoRoot 'vibecoding1c-mcp-host/sppr-mcp/test_sppr.py') 2>&1; $code=$LASTEXITCODE }
            finally { $ErrorActionPreference=$previousError }
            $code | Should -Be 0 -Because ($output -join "`n")
            ($output -join "`n") | Should -Match 'OK'
            @(Get-ChildItem (Join-Path $root 'build/host-test-runtime') -Filter prepared.json -Recurse).Count | Should -Be 1
        } finally { $env:ITL_SOURCE_TEST_PYTHON=$oldBootstrap; $env:SPPR_TEST_PYTHON=$oldSppr }
    }
}
