BeforeAll {
    $script:PythonRuntimeRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:PythonRuntimeModule = Join-Path $script:PythonRuntimeRepo '.agents/skills/itl-remote-runner/scripts/PythonRuntime.ps1'
    . $script:PythonRuntimeModule
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-PythonRuntimeFixture {
        param([string]$Root, [switch]$UnsafeEntry)
        [void][IO.Directory]::CreateDirectory($Root)
        $package = Join-Path $Root 'python.3.13.15.nupkg'
        $content = [ordered]@{ 'python.exe' = 'fake interpreter'; 'LICENSE.txt' = 'fixture license'; 'Lib/example.py' = 'value = 1' }
        $files = [ordered]@{}
        $archive = [IO.Compression.ZipFile]::Open($package, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $content.Keys) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($content[$name])
                $entry = $archive.CreateEntry('tools/' + $name)
                $stream = $entry.Open()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $sha = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
                $files[$name] = @{ sha256 = $sha; bytes = $bytes.Length }
            }
            if ($UnsafeEntry) { [void]$archive.CreateEntry('tools/../../outside.txt') }
        } finally { $archive.Dispose() }
        $payload = Join-Path $Root 'payload.json'
        [IO.File]::WriteAllText($payload, (@{ schemaVersion = 1; files = $files } | ConvertTo-Json -Depth 5))
        $manifest = @{ schemaVersion = 1; version = '3.13.15'; platform = 'windows-amd64'; package = 'python.3.13.15.nupkg';
            url = 'https://example.invalid/python.nupkg'; sha256 = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant();
            payload = 'payload.json'; payloadSha256 = (Get-FileHash $payload -Algorithm SHA256).Hash.ToLowerInvariant();
            executable = 'python.exe'; license = 'LICENSE.txt'; archivePrefix = 'tools/' }
        [IO.File]::WriteAllText((Join-Path $Root 'manifest.json'), ($manifest | ConvertTo-Json))
        [pscustomobject]@{ root = $Root; package = $package; manifest = $manifest }
    }
}

Describe 'Pinned user-local Python acquisition and recovery' {
    BeforeEach {
        $savedCache = $env:ITL_ARTIFACT_CACHE_ROOT
        $savedPython = $env:ITL_PYTHON_EXECUTABLE
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:ITL_ARTIFACT_CACHE_ROOT = Join-Path $caseRoot 'Кэш с пробелом'
        $env:ITL_PYTHON_EXECUTABLE = ''
        $fixture = New-PythonRuntimeFixture -Root (Join-Path $caseRoot 'Поставка с пробелом')
        Mock Get-ItlPythonRuntimeProbe { [pscustomobject]@{ version = '3.13.15' } }
    }
    AfterEach {
        $env:ITL_ARTIFACT_CACHE_ROOT = $savedCache
        $env:ITL_PYTHON_EXECUTABLE = $savedPython
    }
    It 'installs the full declared payload offline and reuses it without acquisition or rewriting' {
        $runtime = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
        $runtime.executable | Should -Match 'Кэш с пробелом'
        $runtime.version | Should -Be '3.13.15'
        $definition = Read-ItlPythonRuntimeManifest -AssetRoot $fixture.root
        Test-ItlPythonRuntimePayload -Root (Split-Path -Parent $runtime.executable) -Definition $definition | Should -BeTrue
        $originalWrite = (Get-Item $runtime.executable).LastWriteTimeUtc
        Mock Invoke-ItlImmutableFileAcquire { throw 'Must reuse the verified local runtime' }
        (Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root).executable | Should -BeExactly $runtime.executable
        (Get-Item $runtime.executable).LastWriteTimeUtc | Should -Be $originalWrite
        Should -Invoke Get-ItlPythonRuntimeProbe -Exactly -Times 1
        Should -Invoke Invoke-ItlImmutableFileAcquire -Exactly -Times 0
    }
    It 'repairs altered library bytes into a new generation while the previous executable is held open' {
        $first = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
        $oldRoot = Split-Path -Parent $first.executable
        $handle = [IO.File]::Open($first.executable, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            [IO.File]::AppendAllText((Join-Path $oldRoot 'Lib/example.py'), '# changed')
            Mock Invoke-ItlImmutableFileAcquire { throw 'Repair must use the retained package' }
            $second = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
            $second.executable | Should -Not -Be $first.executable
            Test-Path -LiteralPath $first.executable | Should -BeTrue
            [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $second.executable) 'Lib/example.py')) | Should -BeExactly 'value = 1'
        } finally { $handle.Dispose() }
    }
    It 'restores an offline export archive without replacing the verified runtime' {
        $first = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
        Remove-Item -LiteralPath $first.archivePath
        $again = Get-ItlManagedPythonRuntime -Offline -RequireArchive -AssetRoot $fixture.root
        $again.executable | Should -BeExactly $first.executable
        (Get-FileHash -LiteralPath $again.archivePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $fixture.manifest.sha256
        Should -Invoke Get-ItlPythonRuntimeProbe -Exactly -Times 1
    }
    It 'serializes two independent installers into one complete selected generation' {
        $childScript = Join-Path $caseRoot 'Два установщика.ps1'
        $childText = @'
param($Module, $Assets, $Cache, $Result, $Ready, $Probing, $Release)
$ErrorActionPreference = 'Stop'
. $Module
$env:ITL_ARTIFACT_CACHE_ROOT = $Cache
function Get-ItlPythonRuntimeProbe {
    param($Executable)
    [IO.File]::WriteAllText($Probing, 'owned')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Release)) {
        if ($watch.Elapsed.TotalSeconds -gt 20) { throw 'Fixture release missing' }
        Start-Sleep -Milliseconds 50
    }
    [pscustomobject]@{ version = '3.13.15' }
}
[IO.File]::WriteAllText($Ready, 'started')
$runtime = Get-ItlManagedPythonRuntime -Offline -AssetRoot $Assets
[IO.File]::WriteAllText($Result, ($runtime | ConvertTo-Json))
'@
        [IO.File]::WriteAllText($childScript, $childText, [Text.UTF8Encoding]::new($true))
        $release = Join-Path $caseRoot 'release'
        $probing = Join-Path $caseRoot 'probing'
        $children = @()
        try {
            foreach ($number in @(1, 2)) {
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = (Get-Command powershell.exe -CommandType Application).Source
                $start.UseShellExecute = $false
                $start.CreateNoWindow = $true
                $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-NoProfile', '-File', $childScript,
                    $script:PythonRuntimeModule, $fixture.root, $env:ITL_ARTIFACT_CACHE_ROOT,
                    (Join-Path $caseRoot "result-$number.json"), (Join-Path $caseRoot "ready-$number"), $probing, $release)
                $children += [Diagnostics.Process]::Start($start)
                $expected = if ($number -eq 1) { $probing } else { Join-Path $caseRoot 'ready-2' }
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath $expected)) {
                    if ($watch.Elapsed.TotalSeconds -gt 15 -or $children[-1].HasExited) { throw 'Fixture installer did not reach synchronization point' }
                    Start-Sleep -Milliseconds 50
                }
            }
            # The first process owns the real installer lock while the second
            # independently enters acquisition against the same exact cache.
            $lockPath = @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Filter '.install.lock')[0].FullName
            { $handle = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None'); $handle.Dispose() } | Should -Throw
            Test-Path -LiteralPath (Join-Path $caseRoot 'result-2.json') | Should -BeFalse
            [IO.File]::WriteAllText($release, 'continue')
            foreach ($child in $children) {
                $child.WaitForExit(20000) | Should -BeTrue
                $child.ExitCode | Should -Be 0
            }
            $first = Get-Content -LiteralPath (Join-Path $caseRoot 'result-1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $second = Get-Content -LiteralPath (Join-Path $caseRoot 'result-2.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $second.executable | Should -BeExactly $first.executable
            @(Get-ChildItem -LiteralPath (Join-Path $env:ITL_ARTIFACT_CACHE_ROOT 'py') -Directory -Filter 'runtime-*') | Should -HaveCount 1
            Test-ItlPythonRuntimePayload -Root (Split-Path -Parent $first.executable) -Definition (Read-ItlPythonRuntimeManifest -AssetRoot $fixture.root) | Should -BeTrue
        } finally {
            [IO.File]::WriteAllText($release, 'cleanup')
            foreach ($child in $children) {
                if (-not $child.HasExited -and -not $child.WaitForExit(5000)) { $child.Kill(); $child.WaitForExit() }
                $child.Dispose()
            }
        }
    }
    It 'rejects a changed payload manifest before extracting or executing files' {
        [IO.File]::AppendAllText((Join-Path $fixture.root 'payload.json'), ' ')
        { Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root } | Should -Throw '*PAYLOAD_MANIFEST_HASH_MISMATCH*'
        Should -Invoke Get-ItlPythonRuntimeProbe -Exactly -Times 0
    }
    It 'replaces a redirected generation without modifying the foreign directory' {
        $first = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
        $oldRoot = Split-Path -Parent $first.executable
        $library = Join-Path $oldRoot 'Lib'
        Remove-Item -LiteralPath (Join-Path $library 'example.py')
        [IO.Directory]::Delete($library, $false)
        $foreign = Join-Path $caseRoot 'Чужая библиотека'
        [void][IO.Directory]::CreateDirectory($foreign)
        [IO.File]::WriteAllText((Join-Path $foreign 'example.py'), 'value = 1')
        New-Item -ItemType Junction -Path $library -Target $foreign | Out-Null
        $second = Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root
        $second.executable | Should -Not -Be $first.executable
        [IO.File]::ReadAllText((Join-Path $foreign 'example.py')) | Should -BeExactly 'value = 1'
        ((Get-Item -LiteralPath $library).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
    }
    It 'reports unavailable offline input without publishing a runtime' {
        Remove-Item -LiteralPath $fixture.package
        { Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root } | Should -Throw '*OFFLINE_ASSET_MISSING*'
        @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Filter current.json) | Should -HaveCount 0
        Should -Invoke Get-ItlPythonRuntimeProbe -Exactly -Times 0
    }
    It 'retains a network acquisition error and never publishes partial success' {
        Remove-Item -LiteralPath $fixture.package
        Mock Invoke-ItlImmutableFileAcquire { throw 'fixture download unavailable' }
        { Get-ItlManagedPythonRuntime -AssetRoot $fixture.root } | Should -Throw '*fixture download unavailable*'
        @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Filter current.json) | Should -HaveCount 0
    }
    It 'rejects traversal entries and releases its installer lock after failed extraction' {
        $unsafe = New-PythonRuntimeFixture -Root (Join-Path $caseRoot 'Unsafe package') -UnsafeEntry
        { Get-ItlManagedPythonRuntime -Offline -AssetRoot $unsafe.root } | Should -Throw '*ARCHIVE_ENTRY_INVALID*'
        Test-Path -LiteralPath (Join-Path $env:ITL_ARTIFACT_CACHE_ROOT 'outside.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Directory -Filter '.install-*') | Should -HaveCount 0
        $locks = @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Filter '.install.lock')
        $locks | Should -HaveCount 1
        $handle = [IO.File]::Open($locks[0].FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $handle.Dispose()
    }
    It 'keeps an incompatible executable from becoming the selected runtime' {
        Mock Get-ItlPythonRuntimeProbe { [pscustomobject]@{ version = '3.11.0' } }
        { Get-ItlManagedPythonRuntime -Offline -AssetRoot $fixture.root } | Should -Throw '*VERSION_MISMATCH*'
        @(Get-ChildItem -LiteralPath $env:ITL_ARTIFACT_CACHE_ROOT -Recurse -Filter current.json) | Should -HaveCount 0
    }
    It 'chooses managed acquisition when no interpreter is explicitly configured' {
        Mock Get-ItlManagedPythonRuntime { [pscustomobject]@{ executable = 'managed-python.exe' } }
        Resolve-ItlPythonExecutable -Offline | Should -Be 'managed-python.exe'
        Should -Invoke Get-ItlManagedPythonRuntime -Exactly -Times 1 -ParameterFilter { $Offline }
    }
    It 'validates an explicit interpreter and preserves an unsupported-version failure' {
        $env:ITL_PYTHON_EXECUTABLE = (Get-Command powershell.exe -CommandType Application).Source
        Mock Get-ItlPythonRuntimeProbe { throw 'ITL_PYTHON_RUNTIME_VERSION_UNSUPPORTED' }
        Mock Get-ItlManagedPythonRuntime { throw 'Must not replace an explicit interpreter' }
        { Resolve-ItlPythonExecutable } | Should -Throw '*VERSION_UNSUPPORTED*'
        Should -Invoke Get-ItlManagedPythonRuntime -Exactly -Times 0
    }
    It 'forwards public CLI output and preserves native argument errors through Windows PowerShell' {
        $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $wrapper = Join-Path $script:PythonRuntimeRepo '.agents/skills/itl-remote-runner/scripts/Invoke-RemoteWork.ps1'
        $project = Join-Path $caseRoot 'Проект с пробелом'
        [void][IO.Directory]::CreateDirectory($project)
        $result = Invoke-TestPowerShellFile -FilePath $wrapper -Arguments @('-Python', $python, 'scaffold', '--project', $project, '--name', 'cli-proof')
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        $created = ($result.stdout -join "`n") | ConvertFrom-Json
        Test-Path -LiteralPath $created.scenario | Should -BeTrue
        $created.scenario | Should -Match 'Проект с пробелом'
        $invalid = Invoke-TestPowerShellFile -FilePath $wrapper -Arguments @('-Python', $python, 'no-such-command')
        $invalid.exitCode | Should -Be 2
        ($invalid.stderr -join "`n") | Should -Match 'invalid choice'
    }
}
