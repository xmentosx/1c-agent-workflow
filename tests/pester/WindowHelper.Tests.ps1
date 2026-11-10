BeforeAll {
    $script:WhRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:WhLib = Join-Path $script:WhRepo '.agents/skills/1c-workflow/scripts/lib'
    $script:WhAssets = Join-Path $script:WhRepo '.agents/skills/1c-workflow/assets/window-helper'
    $script:WhRevision = Join-Path $script:WhRepo 'third-party/vanessa-automation/1.2.043.42-itl-r13'
    foreach ($module in 'agent-1c.core.ps1', 'agent-1c.sessions.ps1', 'agent-1c.vanessa.ps1', 'agent-1c.window-helper.ps1') {
        . (Join-Path $script:WhLib $module)
    }
    $script:ProjectRoot = Join-Path $TestDrive 'Проект окон с пробелом'
    [void][IO.Directory]::CreateDirectory($script:ProjectRoot)
    $env:ITL_WINDOW_HELPER_CACHE_ROOT = Join-Path $TestDrive 'Кеш помощника с пробелом'
    # Launch tests resolve logsPath through the project config; strict mode requires it to exist.
    $script:Config = [pscustomobject]@{ logsPath = (Join-Path $script:ProjectRoot 'логи 1С') }
    $script:WhGroups = [Collections.Generic.List[object]]::new()

    function New-WhGroup([string]$Name, [int]$Countdown = 0, [int[]]$Roots = @()) {
        $dir = Join-Path $TestDrive ('Группа окон ' + $Name)
        [void][IO.Directory]::CreateDirectory($dir)
        $exe = Get-ItlWindowHelperExecutable
        $config = [ordered]@{ protocol = 1; mode = 'hidden'; countdownSeconds = $Countdown; pauseLimitSeconds = 30; roots = @($Roots); executable = $exe }
        Write-Utf8Text -Path (Join-Path $dir 'group.json') -Value ($config | ConvertTo-Json)
        $group = [pscustomobject]@{ directory = $dir; executable = $exe; ready = $true; mode = 'hidden'; warning = '' }
        $script:WhGroups.Add($group)
        return $group
    }

    # Pester removes a Describe block's TestDrive files when that block ends, so each block
    # that starts helpers stops them in its own AfterAll, through the executable it started
    # them with (the cache record is a TestDrive file, too). A helper that keeps its
    # helper.lock is a leak, not a cleanup detail.
    function Stop-WhGroups {
        foreach ($group in @($script:WhGroups)) {
            & $group.executable stop $group.directory | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because "the helper of $($group.directory) must stop"
            $lock = Join-Path $group.directory 'helper.lock'
            if (Test-Path -LiteralPath $lock) { Test-ItlWindowHelperLockHeld -Directory $group.directory | Should -BeFalse -Because $lock }
        }
        $script:WhGroups.Clear()
    }

    # The helper counts an adopted process with its live descendants (a child starts after its
    # parent). The test host may own children of its own, such as its console host or a
    # process left by an earlier file in the same Pester worker, so the expected count is the
    # same tree read from the system process table.
    function Get-WhTreeCount([int]$Root) {
        $processes = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate)
        $byId = @{}
        foreach ($process in $processes) { $byId[[int]$process.ProcessId] = $process }
        if (-not $byId.ContainsKey($Root)) { return 0 }
        $tree = [Collections.Generic.HashSet[int]]::new(); [void]$tree.Add($Root)
        do {
            $grew = $false
            foreach ($process in $processes) {
                $id = [int]$process.ProcessId; $parentId = [int]$process.ParentProcessId
                if ($tree.Contains($id) -or -not $tree.Contains($parentId) -or $id -eq $parentId) { continue }
                if ($process.CreationDate -lt $byId[$parentId].CreationDate) { continue }
                [void]$tree.Add($id); $grew = $true
            }
        } while ($grew)
        return $tree.Count
    }

    function Get-WhHelperPid([string]$Directory) {
        return [int]((Get-Content -LiteralPath (Join-Path $Directory 'helper.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pid)
    }
}

AfterAll {
    Remove-Item Env:\ITL_WINDOW_HELPER_CACHE_ROOT -ErrorAction SilentlyContinue
}

Describe 'Agent 1C window mode and settings' {
    AfterEach { Remove-Item Env:\ONEC_WINDOW_MODE, Env:\ONEC_UI_LEASE_COUNTDOWN_SECONDS, Env:\ONEC_UI_LEASE_PAUSE_LIMIT_SECONDS -ErrorAction SilentlyContinue }

    It 'defaults to hidden with a 10-second countdown and a 600-second pause limit' {
        Mock Get-EnvValue { param($Name, $Default) $Default }
        Get-OneCWindowMode | Should -Be 'hidden'
        Get-OneCUiLeaseCountdownSeconds | Should -Be 10
        Get-OneCUiLeasePauseLimitSeconds | Should -Be 600
    }

    It 'accepts visible and 0 and rejects other values with guidance' {
        Mock Get-EnvValue { param($Name, $Default) switch ($Name) { 'ONEC_WINDOW_MODE' { ' Visible ' } 'ONEC_UI_LEASE_COUNTDOWN_SECONDS' { '0' } default { $Default } } }
        Get-OneCWindowMode | Should -Be 'visible'
        Get-OneCUiLeaseCountdownSeconds | Should -Be 0
        Mock Get-EnvValue { param($Name, $Default) switch ($Name) { 'ONEC_WINDOW_MODE' { 'minimized' } 'ONEC_UI_LEASE_COUNTDOWN_SECONDS' { '-1' } 'ONEC_UI_LEASE_PAUSE_LIMIT_SECONDS' { '0' } default { $Default } } }
        { Get-OneCWindowMode } | Should -Throw "*ONEC_WINDOW_MODE must be 'hidden' or 'visible'*Use visible*"
        { Get-OneCUiLeaseCountdownSeconds } | Should -Throw '*ONEC_UI_LEASE_COUNTDOWN_SECONDS must be an integer between 0 and 600*'
        { Get-OneCUiLeasePauseLimitSeconds } | Should -Throw '*ONEC_UI_LEASE_PAUSE_LIMIT_SECONDS must be an integer between 1 and 86400*'
    }
}

Describe 'Agent 1C launch path' {
    BeforeEach {
        $script:Launched = $null
        Mock Resolve-EnterpriseClientExecutablePath { 'C:\Program Files\1cv8\bin\1cv8c.exe' }
        Mock Assert-InfoBaseAvailable { }
        Mock Get-OneCLaunchUserWindow { [int64]4242 }
        Mock Start-OneCProcessBackground { $script:Launched = [pscustomobject]@{ arguments = @($Arguments); visible = [bool]$Visible }; [pscustomobject]@{ Id = 777 } }
    }

    It 'starts TestManager, ROCTUP and a helper-served TestClient hidden with /DisableSplash in hidden mode' {
        Mock Get-OneCWindowMode { 'hidden' }
        $manager = Start-EnterpriseBackground -InfoBasePath 'C:\База с пробелом' -InfoBaseKind file -UseTestManager -TestClientPort 48100 -EnterpriseArgs @('/Execute', 'x.epf') -User '' -Password ''
        $script:Launched.arguments | Should -Contain '/DisableSplash'
        $script:Launched.visible | Should -BeFalse
        $manager.focusGuard.userWindow | Should -Be 4242
        $manager.focusGuard.processId | Should -Be 777
        Start-EnterpriseBackground -InfoBasePath 'C:\База с пробелом' -InfoBaseKind file -UseTestClient -HiddenTestClient -TestClientPort 48101 -User '' -Password '' | Out-Null
        $script:Launched.arguments | Should -Contain '/DisableSplash'
        $script:Launched.visible | Should -BeFalse
        # Without a ready helper group the client keeps the visible start.
        Start-EnterpriseBackground -InfoBasePath 'C:\База с пробелом' -InfoBaseKind file -UseTestClient -TestClientPort 48101 -User '' -Password '' | Out-Null
        $script:Launched.visible | Should -BeTrue
    }

    It 'keeps the prior launch in visible mode' {
        Mock Get-OneCWindowMode { 'visible' }
        $client = Start-EnterpriseBackground -InfoBasePath 'C:\База' -InfoBaseKind file -UseTestClient -HiddenTestClient -TestClientPort 48101 -User '' -Password ''
        $script:Launched.arguments | Should -Not -Contain '/DisableSplash'
        $script:Launched.visible | Should -BeTrue
        $client.focusGuard | Should -BeNullOrEmpty
        Should -Invoke Get-OneCLaunchUserWindow -Times 0
    }

    It 'adds /DisableSplash and the focus return to the runner TestManager monitor' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WhLib 'agent-1c.core.ps1'), [ref]$null, [ref]$null)
        $invoke = [string]($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Enterprise' }, $true)[0].Extent.Text)
        $invoke | Should -Match '(?s)\$args \+= "/TESTMANAGER"\s*if \(\(Get-OneCWindowMode\) -eq ''hidden''\) \{\s*\$args \+= "/DisableSplash"\s*\$launchFocusGuard = New-OneCLaunchFocusGuard -UserWindow \(Get-OneCLaunchUserWindow\)'
        $invoke | Should -Match '(?s)Invoke-OneCLaunchFocusReturn -Guard \$launchFocusGuard -ProcessId \(\[int\]\$probeContext\.processId\).*?& \$focusedCompletionProbe \$probeContext'
    }

    It 'returns the focus only for the launched process and only during the first 60 seconds' {
        Invoke-OneCLaunchFocusReturn -Guard $null | Should -Be 'no-user-window'
        $guard = New-OneCLaunchFocusGuard -UserWindow 1 -ProcessId 4
        Invoke-OneCLaunchFocusReturn -Guard $guard | Should -Be 'user'
        $guard.untilUtc = [DateTime]::UtcNow.AddSeconds(-1)
        Invoke-OneCLaunchFocusReturn -Guard $guard | Should -Be 'expired'
    }
}

Describe 'Window helper build, group and channel' {
    AfterAll { Stop-WhGroups }

    It 'builds once into the user cache with a recorded hash and rebuilds a replaced executable' {
        $exe = Get-ItlWindowHelperExecutable
        $exe | Should -BeLike ((Join-Path $env:ITL_WINDOW_HELPER_CACHE_ROOT '*') + '\itl-window-helper.exe')
        (Get-Content -LiteralPath "$exe.sha256" -Raw).Trim() | Should -Be (Get-ItlFileSha256 -Path $exe)
        Split-Path -Leaf (Split-Path -Parent $exe) | Should -Be (Get-ItlFileSha256 -Path (Join-Path $script:WhAssets 'ItlWindowHelper.cs'))
        [IO.File]::AppendAllText($exe, 'tampered')
        $rebuilt = Get-ItlWindowHelperExecutable
        $rebuilt | Should -Be $exe
        (Get-Content -LiteralPath "$rebuilt.sha256" -Raw).Trim() | Should -Be (Get-ItlFileSha256 -Path $rebuilt)
    }

    It 'lets two concurrent first builds end with one usable directory' {
        $cache = Join-Path $TestDrive 'Параллельный кеш'
        $jobs = 1..2 | ForEach-Object {
            Start-Job -ArgumentList $script:WhLib, $cache -ScriptBlock {
                param($lib, $cache)
                foreach ($module in 'agent-1c.core.ps1', 'agent-1c.sessions.ps1', 'agent-1c.vanessa.ps1', 'agent-1c.window-helper.ps1') { . (Join-Path $lib $module) }
                $env:ITL_WINDOW_HELPER_CACHE_ROOT = $cache
                Get-ItlWindowHelperExecutable
            }
        }
        $paths = @($jobs | Wait-Job -Timeout 300 | Receive-Job)
        $jobs | Remove-Job -Force
        @($paths | Select-Object -Unique) | Should -HaveCount 1
        @(Get-ChildItem -LiteralPath $cache -Directory) | Should -HaveCount 1
        (Get-Content -LiteralPath "$($paths[0]).sha256" -Raw).Trim() | Should -Be (Get-ItlFileSha256 -Path $paths[0])
    }

    It 'keeps the TestClient visible with a warning when the helper is unavailable' {
        Mock Get-OneCWindowMode { 'hidden' }
        Mock Test-ItlVanessaWindowChannelCapability { $true }
        Mock Get-ItlWindowHelperCompilerPath { Join-Path $TestDrive 'нет компилятора\csc.exe' }
        $env:ITL_WINDOW_HELPER_CACHE_ROOT = Join-Path $TestDrive 'Пустой кеш'
        try {
            $output = Start-ItlWindowHelperGroup -Directory (Join-Path $TestDrive 'Группа без помощника') 6>&1
        } finally { $env:ITL_WINDOW_HELPER_CACHE_ROOT = Join-Path $TestDrive 'Кеш помощника с пробелом' }
        $group = @($output | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })[0]
        $group.ready | Should -BeFalse
        $group.warning | Should -Match '^ITL_WINDOW_HELPER_UNAVAILABLE: .*compiler was not found'
        ($output | Where-Object { $_ -is [Management.Automation.InformationRecord] }) -join "`n" | Should -Match '\[WARN\] ITL_WINDOW_HELPER_UNAVAILABLE: .*starts visible and the run continues'
        $params = [ordered]@{}
        Add-VanessaAgentLaunchParams -Params $params -ClientCodeChannelRoot (Join-Path $TestDrive 'cc') -WindowGroup $group | Out-Null
        $params.dopparams.Contains('ITLWindowChannelRoot') | Should -BeFalse
    }

    It 'warns for an old Vanessa revision and a group root beyond MAX_PATH, and stays silent in visible mode' {
        Mock Get-OneCWindowMode { 'hidden' }
        Mock Test-ItlVanessaWindowChannelCapability { $false }
        (Start-ItlWindowHelperGroup -Directory (Join-Path $TestDrive 'старая') 6>$null).reason | Should -Be 'vanessa-revision-without-window-channel'
        Mock Test-ItlVanessaWindowChannelCapability { $true }
        (Start-ItlWindowHelperGroup -Directory (Join-Path $TestDrive ('x' * 220)) 6>$null).reason | Should -Match '^max-path'
        Mock Get-OneCWindowMode { 'visible' }
        $visible = Start-ItlWindowHelperGroup -Directory (Join-Path $TestDrive 'видимая') 6>&1
        @($visible | Where-Object { $_ -is [Management.Automation.InformationRecord] }) | Should -HaveCount 0
        @($visible)[0].reason | Should -Be 'mode-visible'
    }

    It 'declares the window channel in the r13 recipe and reads it from the dependency entry' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:WhRevision 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($manifest.capabilities) | Should -Contain 'itl-window-channel-1'
        Test-ItlVanessaWindowChannelCapability -VanessaEntry ([pscustomobject]@{ capabilities = @('itl-window-channel-1') }) | Should -BeTrue
        Test-ItlVanessaWindowChannelCapability -VanessaEntry ([pscustomobject]@{ downstreamRevision = 'itl-r12' }) | Should -BeFalse
    }

    It 'passes the channel root and countdown only for a ready group' {
        Mock Get-OneCUiLeaseCountdownSeconds { 0 }
        $group = [pscustomobject]@{ ready = $true; directory = Join-Path $TestDrive 'Группа wh' }
        $params = [ordered]@{}
        Add-VanessaAgentLaunchParams -Params $params -ClientCodeChannelRoot (Join-Path $TestDrive 'cc') -WindowGroup $group | Out-Null
        $params.dopparams.ITLAgentLaunch | Should -BeTrue
        $params.dopparams.ITLWindowChannelRoot | Should -Be $group.directory
        $params.dopparams.ITLUiLeaseCountdownSeconds | Should -Be 0
        $manual = [ordered]@{}
        Add-VanessaAgentLaunchParams -Params $manual -ClientCodeChannelRoot (Join-Path $TestDrive 'cc') | Out-Null
        $manual.dopparams.Contains('ITLWindowChannelRoot') | Should -BeFalse
    }

    It 'answers status, adopt, lease and lease-end through the file channel and rejects a foreign protocol' {
        $group = New-WhGroup 'протокол'
        # A request written before the helper starts is picked up by its first scan.
        $early = [guid]::NewGuid().ToString()
        [void][IO.Directory]::CreateDirectory((Join-Path $group.directory 'requests'))
        [IO.File]::WriteAllText((Join-Path $group.directory "requests\$early.json"), (@{ protocol = 1; op = 'status'; id = $early } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($true))
        Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments @('ensure', $group.directory) | Should -Be 0
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath (Join-Path $group.directory "responses\$early.json")) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        (Get-Content -LiteralPath (Join-Path $group.directory "responses\$early.json") -Raw | ConvertFrom-Json).status | Should -Be 'ok'

        $status = Send-ItlWindowHelperRequest -Directory $group.directory -Operation status -Executable $group.executable
        $status.status | Should -Be 'ok'
        $status.mode | Should -Be 'hidden'
        $status.protocol | Should -Be 1
        $before = Get-WhTreeCount $PID
        $adopted = Send-ItlWindowHelperRequest -Directory $group.directory -Operation adopt -Fields @{ pid = $PID } -Executable $group.executable
        $adopted.members | Should -BeIn @($before, (Get-WhTreeCount $PID))
        $lease = Send-ItlWindowHelperRequest -Directory $group.directory -Operation lease -Fields @{ scope = 'сценарий 1' } -Executable $group.executable -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
        $lease.status | Should -Be 'declined'
        $lease.code | Should -Be 'ITL_UI_CONTROL_DECLINED'
        $lease.reason | Should -Be 'no-client'
        $end = Send-ItlWindowHelperRequest -Directory $group.directory -Operation lease-end -Fields @{ scope = 'сценарий 1'; endScope = $true } -Executable $group.executable
        $end.leases | Should -Be 0

        $foreign = [guid]::NewGuid().ToString()
        [IO.File]::WriteAllText((Join-Path $group.directory "requests\$foreign.json"), (@{ protocol = 99; op = 'status'; id = $foreign } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath (Join-Path $group.directory "responses\$foreign.json")) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        (Get-Content -LiteralPath (Join-Path $group.directory "responses\$foreign.json") -Raw | ConvertFrom-Json).status | Should -Be 'protocol-mismatch'
    }

    It 'is disposable: a killed helper restarts on the next request and keeps its adopted roots, a hung one is replaced' {
        $group = New-WhGroup 'перезапуск'
        Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments @('ensure', $group.directory) | Should -Be 0
        (Send-ItlWindowHelperRequest -Directory $group.directory -Operation adopt -Fields @{ pid = $PID } -Executable $group.executable).status | Should -Be 'ok'
        $first = Get-WhHelperPid $group.directory
        Stop-Process -Id $first -Force
        $before = Get-WhTreeCount $PID
        $status = Send-ItlWindowHelperRequest -Directory $group.directory -Operation status -Executable $group.executable
        $status.status | Should -Be 'ok'
        $status.helperPid | Should -Not -Be $first
        $status.members | Should -BeIn @($before, (Get-WhTreeCount $PID))
        # ensure --hung replaces the recorded helper after checking its image and start time.
        Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments @('ensure', $group.directory, '--hung') | Should -Be 0
        Get-WhHelperPid $group.directory | Should -Not -Be $status.helperPid
        Get-Process -Id $status.helperPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        # A second daemon of the same group exits at once: helper.lock admits one.
        $second = Start-Process -FilePath $group.executable -ArgumentList ('run "' + $group.directory + '"') -PassThru
        $second.WaitForExit(5000) | Should -BeTrue
        $second.ExitCode | Should -Be 5
    }

    It 'reports status and stops the helpers of this project only' {
        $group = New-WhGroup 'команды'
        Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments @('ensure', $group.directory) | Should -Be 0
        $helper = Get-WhHelperPid $group.directory
        $saved = $script:ProjectRoot
        $script:ProjectRoot = $TestDrive
        try {
            Mock Get-OneCWindowMode { 'hidden' }
            (Show-ItlWindowHelperStatus 6>&1) -join "`n" | Should -Match ("Window helper PID $helper" + ': group=.*mode=hidden state=idle')
            $script:ProjectRoot = Join-Path $TestDrive 'другой проект'
            (Stop-ItlWindowHelper 6>&1) -join "`n" | Should -Match 'No running window helper to stop'
            Get-Process -Id $helper -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            $script:ProjectRoot = $TestDrive
            (Stop-ItlWindowHelper 6>&1) -join "`n" | Should -Match "Window helper PID $helper stopped: exit=0"
            Get-Process -Id $helper -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally { $script:ProjectRoot = $saved }
    }

    It 'sums the lease journal into the run summary and lists hidden windows for a failure' {
        $dir = Join-Path $TestDrive 'Журнал аренд'
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'journal'))
        @(
            '{"scope":"scenario:1","durationMs":1500,"consentWaitMs":10000,"queueWaitMs":200,"outcome":"idle-end"}',
            '{"scope":"scenario:1","durationMs":700,"consentWaitMs":0,"queueWaitMs":0,"outcome":"lease-end"}',
            '{"scope":"scenario:2","durationMs":0,"consentWaitMs":4000,"queueWaitMs":0,"outcome":"declined:user-cancel"}'
        ) | Set-Content -LiteralPath (Join-Path $dir 'journal\leases.jsonl') -Encoding UTF8
        '{"t":"2026-11-10T10:00:00Z","event":"hidden","title":"Предупреждение","class":"V8TopLevelFrameSDIsec","image":"C:\\img.png"}' | Set-Content -LiteralPath (Join-Path $dir 'journal\hidden.jsonl') -Encoding UTF8
        $group = [pscustomobject]@{ ready = $true; directory = $dir; mode = 'hidden'; warning = '' }
        $summary = Get-ItlWindowHelperLeaseSummary -Group $group
        $summary.leases | Should -Be 2
        $summary.leaseMs | Should -Be 2200
        $summary.consentWaitMs | Should -Be 14000
        $summary.queueWaitMs | Should -Be 200
        $summary.declined | Should -Be 1
        Format-ItlWindowHelperLeaseSummary -Summary $summary | Should -Be 'Agent UI control: mode=hidden leases=2 leaseSeconds=2.2 consentWaitSeconds=14.0 queueWaitSeconds=0.2 declined=1'
        (Write-ItlWindowHelperFailureDiagnostics -Group $group 6>&1) -join "`n" | Should -Match "Hidden TestClient window: .*title='Предупреждение'.*image='C:\\img.png'"
        (Get-ItlWindowHelperLeaseSummary -Group ([pscustomobject]@{ ready = $false; mode = 'hidden'; warning = 'ITL_WINDOW_HELPER_UNAVAILABLE: x' })).warning | Should -Be 'ITL_WINDOW_HELPER_UNAVAILABLE: x'
    }
}

Describe 'Window channel operation contract' {
    AfterAll { Stop-WhGroups }

    It 'names the same operations in protocol.json, the helper, the PowerShell client and the Vanessa patch' {
        $protocol = Get-Content -LiteralPath (Join-Path $script:WhAssets 'protocol.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $operations = @($protocol.operations.PSObject.Properties.Name)
        $operations | Should -HaveCount 6
        $source = [IO.File]::ReadAllText((Join-Path $script:WhAssets 'ItlWindowHelper.cs'))
        $declared = [regex]::Match($source, 'Operations = \{ (?<list>[^}]+) \}').Groups['list'].Value -split ',\s*' | ForEach-Object { $_.Trim().Trim('"') }
        @(Compare-Object $operations $declared) | Should -HaveCount 0
        @(Compare-Object $operations $script:ItlWindowHelperOperations) | Should -HaveCount 0
        $validate = (Get-Command Send-ItlWindowHelperRequest).Parameters['Operation'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }
        @(Compare-Object $operations @($validate.ValidValues)) | Should -HaveCount 0
        foreach ($field in $protocol.requestFields) { $source | Should -Match ('"' + [regex]::Escape($field) + '"') }
        $patch = [IO.File]::ReadAllText((Join-Path $script:WhRevision 'file-operations.patch'), [Text.Encoding]::UTF8)
        $used = @([regex]::Matches($patch, '(?m)^\+.*ITLЗапросПомощникуОкон\("(?<op>[a-z-]+)"') | ForEach-Object { $_.Groups['op'].Value } | Select-Object -Unique)
        $used | Should -Not -BeNullOrEmpty
        @($used | Where-Object { $operations -notcontains $_ }) | Should -HaveCount 0
        foreach ($field in $protocol.requestFields) { $patch | Should -Match ('Запрос\.Вставить\("' + [regex]::Escape($field) + '"') }
        $patch | Should -Match ([regex]::Escape('Запрос.Вставить("protocol", 1);'))
        $protocol.protocol | Should -Be 1
    }

    It 'runs the r13 Vanessa channel client against the real helper: status, decline, restart and a missing channel' {
        $patch = [IO.File]::ReadAllText((Join-Path $script:WhRevision 'file-operations.patch'), [Text.Encoding]::UTF8)
        $section = @($patch -split '(?m)(?=^diff --git )' | Where-Object { $_.StartsWith('diff --git a/VanessaAutomation/Forms/УправляемаяФорма/Ext/Form/Module.bsl') })[0]
        $builder = New-Object Text.StringBuilder
        $inHunk = $false
        foreach ($line in ($section -split "`n")) {
            if ($line.StartsWith('@@ ')) { $inHunk = $true; [void]$builder.Append("`n"); continue }
            if (-not $inHunk -or $line.Length -eq 0) { continue }
            if ($line[0] -eq '+' -or $line[0] -eq ' ') { [void]$builder.Append($line.Substring(1) + "`n") }
        }
        $form = $builder.ToString()
        $methods = 'ITLУдалитьФайлПомощникаОкон', 'ITLПрочитатьJSONПомощникаОкон', 'ITLПомощникОконЖив', 'ITLОтправитьЗапросПомощникуОкон', 'ITLПерезапуститьПомощникОкон', 'ITLЗапросПомощникуОкон', 'ITLПроверитьОтветПомощникаОкон' | ForEach-Object {
            $match = [regex]::Match($form, '(?ms)^(?:Функция|Процедура) ' + [regex]::Escape($_) + '\(.*?^Конец(?:Функции|Процедуры)[^\n]*')
            $match.Success | Should -BeTrue -Because $_
            $match.Value
        }
        $group = New-WhGroup 'OneScript клиент'
        Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments @('ensure', $group.directory) | Should -Be 0
        $stubs = @'
Перем Каталог;
Перем Ответ;
Функция ITLКаталогКаналаОкон() Возврат Каталог; КонецФункции
Функция ФайлСуществуетКомандаСистемы(Имя) Возврат (Новый Файл(Имя)).Существует(); КонецФункции
Процедура УдалитьФайлыКомандаСистемы(Имя) УдалитьФайлы(Имя); КонецПроцедуры
Процедура ЗаписатьЛогВЖРОшибка(Где, Текст) Сообщить("LOG " + Где + ": " + Текст); КонецПроцедуры
Процедура ITLПаузаМс(Мс) Приостановить(Мс); КонецПроцедуры
Функция ВыполнитьКомандуОСБезПоказаЧерногоОкна(Команда)
	Код = 0;
	ЗапуститьПриложение(Команда, , Истина, Код);
	Возврат Код;
КонецФункции
Функция Ошибка(Действие)
	Попытка
		Выполнить(Действие);
	Исключение
		Возврат ОписаниеОшибки();
	КонецПопытки;
	Возврат "";
КонецФункции
'@
        $body = @'
Каталог = АргументыКоманднойСтроки[0];
ПИД = Число(АргументыКоманднойСтроки[1]);
Ответ = ITLЗапросПомощникуОкон("status", Новый Структура("port", 1), 5);
Сообщить("STATUS " + Ответ.status + " clients=" + Ответ.clients.Количество());
Ответ = ITLЗапросПомощникуОкон("lease", Новый Структура("scope", "scenario:1"), 5);
Сообщить("LEASE " + Ответ.status + " " + Ответ.reason);
Сообщить("DECLINED " + Ошибка("ITLПроверитьОтветПомощникаОкон(Ответ, ""ввод ОС"")"));
// The helper dies: the next request restarts it through ensure --hung and repeats once.
ЗапуститьПриложение("taskkill /F /PID " + Формат(ПИД, "ЧГ="), , Истина);
Ответ = ITLЗапросПомощникуОкон("status", Новый Структура, 5);
Сообщить("RESTARTED " + Ответ.status + " pid=" + Формат(Ответ.helperPid, "ЧГ="));
Каталог = "";
Сообщить("UNAVAILABLE " + Ошибка("ITLПроверитьОтветПомощникаОкон(ITLЗапросПомощникуОкон(""lease"", Новый Структура, 5), ""ввод ОС"")"));
'@
        $probePath = Join-Path $TestDrive 'Проба канала окон.os'
        [IO.File]::WriteAllText($probePath, ($stubs + "`n" + ($methods -join "`n") + "`n" + $body), [Text.UTF8Encoding]::new($true))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Command oscript -ErrorAction Stop).Source
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8', $probePath, $group.directory, [string](Get-WhHelperPid $group.directory))
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit(90000) | Should -BeTrue
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $process.ExitCode | Should -Be 0 -Because $output
        $output | Should -Match 'STATUS ok clients=0'
        $output | Should -Match 'LEASE declined no-client'
        $output | Should -Match 'DECLINED .*ITL_UI_CONTROL_DECLINED: .*\(no-client\)'
        $output | Should -Match 'RESTARTED ok pid=\d+'
        $output | Should -Match 'UNAVAILABLE .*ITL_WINDOW_HELPER_UNAVAILABLE: .*ONEC_WINDOW_MODE=visible'
    }

    It 'starts the agent TestClient hidden and guards OS input in the r13 patch' {
        $patch = [IO.File]::ReadAllText((Join-Path $script:WhRevision 'file-operations.patch'), [Text.Encoding]::UTF8)
        $patch | Should -Match ([regex]::Escape('+		КомандаЗапуска = """" + СтрокаЗапуска1с + """ " + СтрокаЗапуска + " /DisableSplash";'))
        $patch | Should -Match ([regex]::Escape('+		ПолучитьWshShell().Run(КомандаЗапуска, 0, Ложь);'))
        $patch | Should -Match '(?s)\+Процедура ITLАрендоватьУправлениеДляВводаОС\(\) Экспорт.*?ITLПроверитьОтветПомощникаОкон\(Ответ, "ввод ОС"\);.*?Если НЕ ЗначениеЗаполнено\(PIDКлиента\) Или PIDАктивного <> PIDКлиента Тогда\n\+\t\tВызватьИсключение "ITL_WINDOW_ACTIVATION_FAILED'
        $patch | Should -Match '(?s)\+\t\tИначеЕсли ITLПоказатьКлиентДляСнимка\(\) Тогда\n\+\t\t\tСпособСнятияСкриншотовВнешнейКомпонентой = 1;'
        $patch | Should -Match ([regex]::Escape('+			Если ДвоичныеДанные = Неопределено И НЕ ЗначениеЗаполнено(ITLКаталогКаналаОкон()) Тогда'))
    }

    It 'declares every added ITL form-module variable on the client' {
        # A form-module variable without &НаКлиенте is server-side; the single build then failed
        # in GetStepsCache with "Переменная не определена (ITLИтогУправления)".
        $lines = [IO.File]::ReadAllText((Join-Path $script:WhRevision 'file-operations.patch'), [Text.Encoding]::UTF8) -split "\r?\n"
        $declarations = @()
        for ($index = 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\+Перем ITL') {
                $declarations += [pscustomobject]@{ Line = $lines[$index]; Directive = $lines[$index - 1].Substring(1) }
            }
        }
        $declarations.Count | Should -BeGreaterThan 0
        foreach ($declaration in $declarations) {
            $declaration.Directive | Should -Be '&НаКлиенте' -Because $declaration.Line
        }
    }

    It 'calls no server-only date function from the added thin-client channel code' {
        # The thin-client check of the single build failed with
        # "Процедура или функция с указанным именем не определена (ТекущаяУниверсальнаяДата)".
        $added = @([IO.File]::ReadAllText((Join-Path $script:WhRevision 'file-operations.patch'), [Text.Encoding]::UTF8) -split "\r?\n" |
            Where-Object { $_ -match '^\+' -and $_ -match 'ITL|deadlineUtc|ОжидатьСекунд' })
        $added.Count | Should -BeGreaterThan 0
        $added | Where-Object { $_ -match '(ТекущаяУниверсальнаяДата|ТекущаяДатаСеанса)\s*\(' } | Should -BeNullOrEmpty
        $added -join "`n" | Should -Match ([regex]::Escape('XMLСтрока(УниверсальноеВремя(ТекущаяДата()) + ОжидатьСекунд)'))
    }
}
