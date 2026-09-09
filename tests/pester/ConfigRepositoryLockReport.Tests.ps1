BeforeAll {
    $script:LockReportHelper = Join-Path $PSScriptRoot '../../.agents/skills/1c-workflow/scripts/agent-1c.ps1'
}

Describe 'Repository lock partial outcome report' {
    It 'retains 24 captures, one owner conflict and four absent objects after the native failure' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl-захват с пробелом-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $result = & {
                . $script:LockReportHelper -ProjectRoot $root -Action help *> $null
                $script:CapturedNames = @(1..24 | ForEach-Object { "ОбщийМодуль.Захваченный$_" })
                $script:AbsentNames = @(1..4 | ForEach-Object { "Константа.Новая$_" })
                $script:ConflictName = 'Справочник.Планы.Форма.ФормаЭлемента'
                $script:LockCalls = 0
                function Read-DevBranchState {
                    [pscustomobject]@{ devBranch = 'itldev/report'; devBranchKind = 'configuration'; initializationStatus = 'ready' }
                }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Repair-OneCSourceLineEndings {}
                function Get-SourceUsesRepository { $true }
                function Get-SourceInfoBasePath { 'server\source' }
                function Get-InfoBaseKind { 'server' }
                function Get-ExportPath { 'src/cf' }
                function Get-ConfigRepositoryTransferPlan {
                    [pscustomobject]@{
                        baseCommit = 'captured-base'; unresolvedPaths = @()
                        items = @(@($script:CapturedNames) + @($script:AbsentNames) + @($script:ConflictName) | ForEach-Object {
                            [pscustomobject]@{ name = $_; scope = 'partial' }
                        })
                    }
                }
                function New-RepositoryConnectionArgs { @('/ConfigurationRepositoryF', 'repository', '-N', 'TestOwner') }
                function Get-EnvValue { param([string]$Name) if ($Name -eq 'REPOSITORY_USER') { 'TestOwner' } else { '' } }
                function Set-RunStage {}
                function Invoke-Designer {
                    $script:LockCalls++
                    $script:LastLogPath = Join-Path $root 'designer.log'
                    $lines = @('Объекты, отсутствующие в обеих конфигурациях:') + @($script:AbsentNames) + @(
                        '', '---- Начало операции с хранилищем конфигурации ----'
                    ) + @($script:CapturedNames | ForEach-Object { "Объект захвачен для редактирования: $_" }) + @(
                        "Объект захвачен для редактирования другим пользователем: $script:ConflictName (ДругойПользователь)",
                        '---- Операция с хранилищем конфигурации завершена ----',
                        'Ошибка захвата объектов в хранилище'
                    )
                    [IO.File]::WriteAllLines($script:LastLogPath, $lines, [Text.UTF8Encoding]::new($false))
                    throw '1C Designer failed with exit code 1'
                }
                $failure = ''
                try { Lock-ConfigRepositoryObjects 6>$null } catch { $failure = $_.Exception.Message }
                $outcomeFile = @(Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/runs') -Recurse -File -Filter 'repository-lock-result.json')
                [pscustomobject]@{
                    failure = $failure; report = $script:RunUserReport; calls = $script:LockCalls
                    captured = $script:CapturedNames; absent = $script:AbsentNames; conflict = $script:ConflictName
                    outcome = if ($outcomeFile.Count -eq 1) { Get-Content -LiteralPath $outcomeFile[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
                }
            }
            $result.failure | Should -Match 'LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT'
            $result.calls | Should -Be 1 -Because 'partial failure must not replay the lock request'
            $result.report | Should -Not -BeNullOrEmpty
            foreach ($name in @($result.captured) + @($result.absent) + @($result.conflict)) {
                $result.report | Should -Match ([regex]::Escape($name))
            }
            $result.report | Should -Match 'ДругойПользователь'
            $result.report | Should -Match '24'
            $result.report | Should -Match 'отсутств'
            $result.outcome.operationStatus | Should -Be 'failed'
            @($result.outcome.items).Count | Should -Be 29
            @($result.outcome.items | Where-Object status -eq 'captured').Count | Should -Be 24
            @($result.outcome.items | Where-Object status -eq 'absent').Count | Should -Be 4
            @($result.outcome.items | Where-Object status -eq 'conflict').Count | Should -Be 1
        } finally {
            $resolvedRoot = [IO.Path]::GetFullPath($root)
            $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $resolvedRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }

    It 'does not reuse an earlier capture log when the current launcher fails before writing a log' {
        $root = Join-Path $TestDrive 'Старый лог с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $result = & {
            . $script:LockReportHelper -ProjectRoot $root -Action help *> $null
            function Read-DevBranchState { [pscustomobject]@{ devBranch = 'itldev/report'; devBranchKind = 'configuration'; initializationStatus = 'ready' } }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Repair-OneCSourceLineEndings {}
            function Get-SourceUsesRepository { $true }
            function Get-SourceInfoBasePath { 'server\source' }
            function Get-InfoBaseKind { 'server' }
            function Get-ExportPath { 'src/cf' }
            function Get-ConfigRepositoryTransferPlan { [pscustomobject]@{ baseCommit = 'base'; unresolvedPaths = @(); items = @([pscustomobject]@{ name = 'ОбщийМодуль.Первый'; scope = 'partial' }) } }
            function New-RepositoryConnectionArgs { @('/ConfigurationRepositoryF', 'repository') }
            function Get-EnvValue { '' }
            function Set-RunStage {}
            function Invoke-Designer { throw 'Current launch failed before opening its log' }
            $script:LastLogPath = Join-Path $root 'previous.log'
            [IO.File]::WriteAllLines($script:LastLogPath, @(
                '---- Начало операции с хранилищем конфигурации ----',
                'Объект захвачен для редактирования: ОбщийМодуль.Первый',
                '---- Операция с хранилищем конфигурации завершена ----'
            ), [Text.UTF8Encoding]::new($false))
            $failure = ''
            try { Lock-ConfigRepositoryObjects 6>$null } catch { $failure = $_.Exception.Message }
            $file = Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/runs') -Recurse -File -Filter 'repository-lock-result.json'
            [pscustomobject]@{ failure = $failure; outcome = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) }
        }
        $result.failure | Should -Match 'Current launch failed'
        $result.outcome.items[0].status | Should -Be 'unconfirmed'
        $result.outcome.logPath | Should -BeNullOrEmpty
    }

    It 'keeps unobserved objects unknown and preserves captures before an interrupted operation ends' {
        $root = Join-Path $TestDrive 'Прерванный захват с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $outcome = & {
            . $script:LockReportHelper -ProjectRoot $root -Action help *> $null
            $plan = [pscustomobject]@{ baseCommit = 'base'; items = @(
                [pscustomobject]@{ name = 'ОбщийМодуль.Первый'; scope = 'partial' },
                [pscustomobject]@{ name = 'ОбщийМодуль.Второй'; scope = 'partial' }
            ) }
            $log = Join-Path $root 'partial.log'
            [IO.File]::WriteAllLines($log, @(
                '---- Начало операции с хранилищем конфигурации ----',
                'Объект захвачен для редактирования: ОбщийМодуль.Первый',
                'Объект захвачен для редактирования: ОбщийМодуль.НеЗапрашивался'
            ), [Text.UTF8Encoding]::new($false))
            Get-ConfigRepositoryLockOutcome -Plan $plan -LogPath $log -Succeeded $false
        }
        $outcome.operationStatus | Should -Be 'failed'
        $outcome.operationEndObserved | Should -BeFalse
        @($outcome.items).Count | Should -Be 2
        $outcome.items[0].status | Should -Be 'captured'
        $outcome.items[1].status | Should -Be 'unconfirmed'
    }

    It 'keeps every conflicting owner and does not count duplicate capture lines twice' {
        $root = Join-Path $TestDrive 'Несколько владельцев с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $outcome = & {
            . $script:LockReportHelper -ProjectRoot $root -Action help *> $null
            $plan = [pscustomobject]@{ baseCommit = 'base'; items = @(1..3 | ForEach-Object { [pscustomobject]@{ name = "ОбщийМодуль.Модуль$_"; scope = 'partial' } }) }
            $log = Join-Path $root 'owners.log'
            [IO.File]::WriteAllLines($log, @(
                '---- Начало операции с хранилищем конфигурации ----',
                'Объект захвачен для редактирования: ОбщийМодуль.Модуль1',
                'Объект захвачен для редактирования: ОбщийМодуль.Модуль1',
                'Объект захвачен для редактирования другим пользователем: ОбщийМодуль.Модуль2 (ПервыйВладелец)',
                'Объект захвачен для редактирования другим пользователем: ОбщийМодуль.Модуль3 (ВторойВладелец)',
                '---- Операция с хранилищем конфигурации завершена ----'
            ), [Text.UTF8Encoding]::new($false))
            Get-ConfigRepositoryLockOutcome -Plan $plan -LogPath $log -Succeeded $false
        }
        @($outcome.items | Where-Object status -eq 'captured').Count | Should -Be 1
        @($outcome.items | Where-Object status -eq 'conflict').Count | Should -Be 2
        $outcome.items[1].owner | Should -Be 'ПервыйВладелец'
        $outcome.items[2].owner | Should -Be 'ВторойВладелец'
    }

    It 'does not treat a contradictory log or an unrecognized successful log as per-object capture proof' {
        $root = Join-Path $TestDrive 'Неоднозначный захват с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $outcomes = & {
            . $script:LockReportHelper -ProjectRoot $root -Action help *> $null
            $plan = [pscustomobject]@{ baseCommit = 'base'; items = @([pscustomobject]@{ name = 'ОбщийМодуль.Первый'; scope = 'partial' }) }
            $log = Join-Path $root 'uncertain.log'
            [IO.File]::WriteAllLines($log, @(
                '---- Начало операции с хранилищем конфигурации ----',
                'Объект захвачен для редактирования: ОбщийМодуль.Первый',
                'Объект захвачен для редактирования другим пользователем: ОбщийМодуль.Первый (Владелец)',
                '---- Операция с хранилищем конфигурации завершена ----'
            ), [Text.UTF8Encoding]::new($false))
            Get-ConfigRepositoryLockOutcome -Plan $plan -LogPath $log -Succeeded $false
            [IO.File]::WriteAllText($log, 'Command exited zero without known object evidence', [Text.UTF8Encoding]::new($false))
            Get-ConfigRepositoryLockOutcome -Plan $plan -LogPath $log -Succeeded $true
        }
        $outcomes[0].items[0].status | Should -Be 'unconfirmed'
        $outcomes[0].items[0].owner | Should -Be 'Владелец'
        @($outcomes[0].items[0].observations).Count | Should -Be 2
        $outcomes[1].operationStatus | Should -Be 'succeeded'
        $outcomes[1].items[0].status | Should -Be 'unconfirmed'
    }
}
