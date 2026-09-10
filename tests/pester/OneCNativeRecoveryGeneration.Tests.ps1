Describe 'Recovery helper generations survive installed source replacement' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:recoveryHelperSource = Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib'
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    }
    BeforeEach {
        $script:sourceCopy = Join-Path $TestDrive ('Исходники восстановления ' + [guid]::NewGuid().ToString('N'))
        $script:archiveAuthority = Join-Path $TestDrive ('Общий архив версий ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sourceCopy | Out-Null
        $script:helperNames = @('agent-1c.core.ps1','agent-1c.runtime-values.ps1','agent-1c.sessions.ps1','agent-1c.vanessa.ps1','agent-1c.ports.ps1')
        foreach ($name in $helperNames) { Copy-Item -LiteralPath (Join-Path $recoveryHelperSource $name) -Destination $sourceCopy }
        [IO.File]::WriteAllText((Join-Path $sourceCopy '.dev.env'), 'IB_PASSWORD=do-not-archive-project-secrets')
    }

    It 'retains only code and reuses one complete content generation across journals' {
        $first = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        $second = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        $first | Should -HaveCount 5
        @($second.path) | Should -Be @($first.path)
        foreach ($helper in $first) {
            $original = Join-Path $sourceCopy (Split-Path -Leaf $helper.path)
            $helper.sha256 | Should -Be (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant()
            $helper.sha256 | Should -Be (Get-FileHash -LiteralPath $helper.path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $files = @(Get-ChildItem -LiteralPath (Split-Path -Parent $first[0].path) -File)
        @($files.Name | Sort-Object) | Should -Be @($helperNames | Sort-Object)
        @(Get-ChildItem -LiteralPath (Join-Path $archiveAuthority 'native-helper-generations') -Directory) | Should -HaveCount 1
    }

    It 'retains package function dependencies needed for a native restore in a fresh process' {
        $index = @{}
        foreach ($file in Get-ChildItem -LiteralPath $recoveryHelperSource -Filter '*.ps1') {
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
                $index[$definition.Name]=@{owner=$file.Name;ast=$definition}
            }
        }
        $pending=[Collections.Generic.Queue[string]]::new()
        foreach ($name in @('Invoke-Designer','Initialize-OneCNativeRecoveryContext','Register-OneCDatabaseRestorationDuty','Complete-OneCDatabaseRestorationDuty','New-OneCNativeOperationJournal')) { $pending.Enqueue($name) }
        $visited=@{}; $missing=@()
        while ($pending.Count) {
            $name=$pending.Dequeue()
            if ($visited.ContainsKey($name) -or -not $index.ContainsKey($name)) { continue }
            $entry=$index[$name]; $visited[$name]=$true
            if ($entry.owner -notin $helperNames) { $missing += ($name+' in '+$entry.owner) }
            foreach ($command in $entry.ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
                $called=$command.GetCommandName(); if ($called) { $pending.Enqueue($called) }
            }
        }
        $missing.Count | Should -Be 0 -Because ($missing -join '; ')
    }

    It 'keeps the old generation intact when installed sources change' {
        $first = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        [IO.File]::AppendAllText((Join-Path $sourceCopy 'agent-1c.core.ps1'), "`r`n# next installed helper generation`r`n")
        $second = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        $second[0].path | Should -Not -Be $first[0].path
        foreach ($helper in $first) { (Get-FileHash -LiteralPath $helper.path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $helper.sha256 }
        @(Get-ChildItem -LiteralPath (Join-Path $archiveAuthority 'native-helper-generations') -Directory) | Should -HaveCount 2
    }

    It 'lets independent processes publish the same generation without partial or overwritten files' {
        $jobs = @(1..2 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($Library, $Authority)
                $ErrorActionPreference = 'Stop'
                foreach ($name in @('core','runtime-values','sessions')) { . (Join-Path $Library ("agent-1c.$name.ps1")) }
                @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $Authority -LibraryRoot $Library) | ConvertTo-Json -Compress
            } -ArgumentList $sourceCopy,$archiveAuthority
        })
        try {
            $jobs | Wait-Job -Timeout 30 | Out-Null
            foreach ($job in $jobs) { $job.State | Should -Be 'Completed' }
            $first = Receive-Job $jobs[0] -ErrorAction Stop | ConvertFrom-Json
            $second = Receive-Job $jobs[1] -ErrorAction Stop | ConvertFrom-Json
            @($first.path) | Should -Be @($second.path)
            foreach ($helper in $first) { (Get-FileHash -LiteralPath $helper.path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $helper.sha256 }
            @(Get-ChildItem -LiteralPath (Join-Path $archiveAuthority 'native-helper-generations') -Directory) | Should -HaveCount 1
        } finally { $jobs | Stop-Job; $jobs | Remove-Job -Force }
    }

    It 'rejects a changed archived helper instead of overwriting recovery evidence' {
        $first = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        [IO.File]::AppendAllText($first[0].path, "`r`n# changed archived evidence`r`n")
        $changedHash = (Get-FileHash -LiteralPath $first[0].path -Algorithm SHA256).Hash
        { Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy } | Should -Throw '*HELPER_ARCHIVE_CHANGED*'
        (Get-FileHash -LiteralPath $first[0].path -Algorithm SHA256).Hash | Should -Be $changedHash
    }

    It 'leaves no visible partial generation when its archive directory cannot be created' {
        $target = [IO.Path]::GetFullPath((Join-Path $archiveAuthority 'native-helper-generations'))
        New-Item -ItemType Directory -Force -Path $archiveAuthority | Out-Null
        [IO.File]::WriteAllText($target, 'not a directory')
        { Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy } | Should -Throw
        [IO.File]::ReadAllText($target) | Should -Be 'not a directory'
        @(Get-ChildItem -LiteralPath $archiveAuthority -Directory) | Should -HaveCount 0
    }

    It 'rejects a redirected archive root without writing into its foreign target' {
        $foreign = Join-Path $TestDrive ('Чужой каталог ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $archiveAuthority,$foreign | Out-Null
        $sentinel = Join-Path $foreign 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'unchanged foreign file')
        $junction = Join-Path $archiveAuthority 'native-helper-generations'
        New-Item -ItemType Junction -Path $junction -Target $foreign | Out-Null
        try {
            { Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy } | Should -Throw '*ARCHIVE_REDIRECTED*'
            [IO.File]::ReadAllText($sentinel) | Should -Be 'unchanged foreign file'
            @(Get-ChildItem -LiteralPath $foreign) | Should -HaveCount 1
        } finally { [IO.Directory]::Delete($junction) }
    }

    It 'runs the archived process-enumeration worker after original library files are gone' {
        $helpers = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $archiveAuthority -LibraryRoot $sourceCopy)
        foreach ($name in $helperNames) { [IO.File]::Delete((Join-Path $sourceCopy $name)) }
        $worker = Join-Path $archiveAuthority 'Проверка сохраненного кода.ps1'
        $workerText = @'
param([string]$Library)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
foreach ($name in @('core','runtime-values','sessions','vanessa','ports')) { . (Join-Path $Library ("agent-1c.$name.ps1")) }
Initialize-OneCNativeRecoveryContext -ProjectRoot $PSScriptRoot
if (-not (Test-ItlOnDemandInfoBaseMatch -First (Join-Path $PSScriptRoot '.') -Second $PSScriptRoot) -or
    (Test-ItlOnDemandInfoBaseMatch -First (Join-Path $PSScriptRoot 'foreign') -Second $PSScriptRoot)) {
    throw 'Archived native target comparison did not preserve database identity.'
}
$probe = New-DesignerInvocationProbeState -LauncherProcessId 0
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    do {
        $observation = Get-DesignerInvocationProcessState -ProbeState $probe -LogPath ''
        if ($observation.querySucceeded) { break }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    if (-not $observation.querySucceeded) { throw ('Archived native process enumeration did not complete: ' + $observation.detail) }
    [pscustomobject]@{querySucceeded=$true;helperRoot=$script:Agent1cCoreRoot;cleanupAvailable=[bool](Get-Command Stop-OwnVanessaRunScopeProcesses -ErrorAction Stop)} | ConvertTo-Json -Compress
} finally {
    if ($null -ne $probe.processScanProcess) { Stop-DesignerProcessEnumeration -ProbeState $probe | Out-Null }
}
'@
        [IO.File]::WriteAllText($worker, $workerText, [Text.UTF8Encoding]::new($true))
        $library = Split-Path -Parent $helpers[0].path
        $observed = Invoke-TestPowerShellFile -FilePath $worker -Arguments @('-Library', $library)
        $observed.exitCode | Should -Be 0 -Because $observed.combinedText
        $result = $observed.stdout | ConvertFrom-Json
        $result.querySucceeded | Should -BeTrue
        $result.helperRoot | Should -Be $library
        $result.cleanupAvailable | Should -BeTrue
    }
}
