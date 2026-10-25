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
    It 'prepares one component concurrently without rewriting another callers open config' {
        $root=New-SourceRuntimeFixture
        $runtime=Join-Path $root 'build/host-test-runtime'
        [void][IO.Directory]::CreateDirectory($runtime)
        $legacyConfig=Join-Path $runtime 'codechecker.config.json'
        [IO.File]::WriteAllText($legacyConfig,(@{schemaVersion=1;stateRoot=(Join-Path $runtime 'codechecker-state')}|ConvertTo-Json))
        $before=(Get-FileHash $legacyConfig).Hash
        $reader=[IO.File]::Open($legacyConfig,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $bootstrap=(Get-Command python -CommandType Application | Where-Object Source -NotMatch 'WindowsApps' | Select-Object -First 1).Source
        . (Join-Path $root 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1') -Action status -ConfigPath $legacyConfig *> $null
        $worker=Join-Path $root 'parallel-worker.ps1'
        [IO.File]::WriteAllText($worker,@'
param($source,$root,$id,$bootstrap)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$env:ITL_SOURCE_TEST_PYTHON=$bootstrap
. (Join-Path $source 'scripts/host-test-runtime.ps1')
[IO.File]::WriteAllText((Join-Path $root ('ready-'+$id)),'ready')
$deadline=[DateTime]::UtcNow.AddSeconds(30)
while(-not [IO.File]::Exists((Join-Path $root 'start'))){
    if([DateTime]::UtcNow -gt $deadline){throw 'Parallel runtime fixture did not start.'}
    Start-Sleep -Milliseconds 20
}
$python=Get-SourceHostTestPython -RepositoryRoot $root -Component CodeChecker
$probe=& $python -I -B -c 'import sys; print(sys.prefix != sys.base_prefix)'
if($LASTEXITCODE -ne 0 -or $probe -ne 'True'){throw 'Parallel component runtime is not isolated.'}
[IO.File]::WriteAllText((Join-Path $root ('result-'+$id)), $python)
'@,[Text.UTF8Encoding]::new($true))
        $jobs=@()
        try {
            foreach($i in 1..2){
                $arguments=Join-HostProcessArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,$RepoRoot,$root,[string]$i,$bootstrap)
                $process=Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root ('stdout-'+$i)) -RedirectStandardError (Join-Path $root ('stderr-'+$i))
                $null=$process.Handle
                $jobs+=$process
            }
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            while(-not ([IO.File]::Exists((Join-Path $root 'ready-1')) -and [IO.File]::Exists((Join-Path $root 'ready-2')))){
                if([DateTime]::UtcNow -gt $deadline){throw 'Parallel runtime workers did not become ready.'}
                Start-Sleep -Milliseconds 20
            }
            [IO.File]::WriteAllText((Join-Path $root 'start'),'start')
            foreach($job in $jobs){$job.WaitForExit(60000) | Should -BeTrue;$job.ExitCode | Should -Be 0 -Because ((Get-Content (Join-Path $root 'stderr-*') -Raw -Encoding UTF8) -join '')}
            $paths=@(1..2|ForEach-Object {[IO.File]::ReadAllText((Join-Path $root ('result-'+$_)))})
            $paths.Count | Should -Be 2
            $paths[0] | Should -BeExactly $paths[1]
            $paths[0] | Should -Match ([regex]::Escape($root))
            @(Get-ChildItem $runtime -Filter prepared.json -Recurse).Count | Should -Be 1
            (Get-FileHash $legacyConfig).Hash | Should -BeExactly $before
            @(Get-ChildItem $runtime -Filter '*.config.json').Count | Should -Be 1
            $lease=[IO.File]::Open((Join-Path $runtime 'codechecker-state/host-maintenance.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $lease.Dispose()
        } finally {
            $reader.Dispose()
            foreach($job in $jobs){if(-not $job.HasExited){Stop-HostProcessTree -Process $job};$job.Dispose()}
        }
    }
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
