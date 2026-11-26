BeforeAll {
    $script:TransferHelper = Join-Path $PSScriptRoot '../../.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    $script:FormObject = 'Обработка.Проверка.Форма.Основная'

    function New-TransferMxl {
        param([string[]]$Cells)
        $body = ($Cells | ForEach-Object { '{"#","' + $_.Replace('"', '""') + '"}' }) -join ",`r`n"
        return [Text.Encoding]::UTF8.GetBytes("MOXCEL`r`n{8,1,12,`r`n" + $body + "`r`n}")
    }

    # Runs a transfer step in a fresh helper scope with an in-memory branch state and
    # native boundaries replaced by $Native (versions, comparison results, calls).
    function Invoke-TransferStep {
        param([string]$Root, [hashtable]$Native, [hashtable]$Parameters)
        & {
            . $script:TransferHelper -ProjectRoot $Root -Action help *> $null
            foreach ($key in $Parameters.Keys) { Set-Variable -Name $key -Value $Parameters[$key] }
            function Read-DevBranchState { $Native.state }
            function Update-DevBranchState { param([object]$State, [hashtable]$Updates)
                $copy = [ordered]@{}
                foreach ($property in $Native.state.PSObject.Properties) { $copy[$property.Name] = $property.Value }
                foreach ($key in $Updates.Keys) { $copy[$key] = $Updates[$key] }
                $Native.state = ($copy | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
            }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Get-DevBranchKind { $Native.kind }
            function Get-DevBranchInitializationStatus { 'ready' }
            function Get-SourceUsesRepository { $Native.usesRepository }
            function Get-RepositoryTransferWorkRoot { $Root }
            function Get-RepositoryTransferCheckedResult { [pscustomobject]@{ cfPath = 'C:\result\ветка.cf'; sha256 = $Native.cfSha; manifestPath = 'C:\result\ветка.cf.manifest.json'; head = $Native.head } }
            function Get-RepositoryTransferScope { [ordered]@{ baseCommit = 'base'; exportPath = 'C:\src\cf'; objects = @($script:FormObject); fullObjects = @(); rootRequired = $false; loadPaths = @('C:\src\cf\Form.xml') } }
            function Assert-RepositoryTransferMasterCurrent { $Native.calls.Add('master-current') | Out-Null }
            function Get-RepositoryTransferLatestVersion { $Native.latest }
            function Get-RepositoryTransferVersions { @($Native.history) }
            function Invoke-RepositoryTransferCompare { param([int]$FirstVersion = 0, [string]$SecondFile = '', [string]$ReportPath)
                $key = "$FirstVersion|$([IO.Path]::GetFileNameWithoutExtension($ReportPath))"
                $Native.calls.Add("compare:$key") | Out-Null
                $objects = @(if ($Native.compare.ContainsKey($key)) { $Native.compare[$key] })
                [pscustomobject]@{ empty = ($objects.Count -eq 0); objects = $objects; rootProperties = @(); path = $ReportPath; sha256 = $Native.reportSha }
            }
            function Invoke-RepositoryTransferDesigner { param([string[]]$DesignerArgs, [switch]$Repository) $Native.calls.Add($DesignerArgs[0]) | Out-Null; '' }
            function Invoke-ConfigRepositoryObjectOperation { param($Operation, $ObjectListPath) $Native.calls.Add($Operation) | Out-Null }
            function Sync-Master { param([string]$SeedPolicy, [switch]$SkipRepositoryUpdate) $Native.calls.Add("sync-master:$SkipRepositoryUpdate") | Out-Null }
            function Get-EnvValue { param([string]$Name, [object]$Default = $null) if ($Name -eq 'REPOSITORY_USER') { 'Разработчик' } else { $Default } }
            function Copy-Item {}
            function Write-AndSetRunUserReport { param($Lines) $Native.report = ($Lines -join "`n") }
            try { Invoke-RepositoryTransfer; $Native.error = '' } catch { $Native.error = $_.Exception.Message }
        }
    }

    function New-TransferNative {
        param([string]$Name)
        $root = Join-Path $TestDrive "Перенос $Name с пробелом"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        return @{
            root = $root
            state = [pscustomobject]@{ devBranch = 'itldev/задача'; safeDevBranchName = 'задача' }
            kind = 'configuration'; usesRepository = $true; cfSha = 'sha-1'; head = 'head-1'; latest = 7
            reportSha = 'report-1'; compare = @{ '7|attempt-1-total' = @('Обработка.Проверка') }; history = @()
            calls = [System.Collections.Generic.List[string]]::new(); error = ''; report = ''
        }
    }

    function Get-TransferStage { param([hashtable]$Native) [string]$Native.state.repositoryTransfer.stage }
}

Describe 'Repository transfer report parsing' {
    It 'separates objects, root properties and an empty comparison' {
        $legend = "`t***- Объект изменен`r`n`t-->- Объект присутствует только в конфигурации хранилища`r`n`t<--- Объект присутствует только в файле`r`n`t^- Порядок объекта изменен`r`n"
        $empty = & { . $script:TransferHelper -ProjectRoot $TestDrive -Action help *> $null; ConvertFrom-RepositoryTransferCompareReport -Text $legend }
        $empty.empty | Should -BeTrue
        $text = $legend + "`t- ***Конфигурация.Тест`r`n`t`t- ***Обработка.Проверка`r`n`t`t`t- ***Обработка.Проверка.Форма.Основная`r`n`t`t`t`t- Модуль - Различаются значения`r`n`t`t- -->ОбщийМакет.Удалённый`r`n`t`t- <--ОбщийМодуль.Новый`r`n`t`t- Синоним - Различаются значения`r`n"
        $parsed = & { . $script:TransferHelper -ProjectRoot $TestDrive -Action help *> $null; ConvertFrom-RepositoryTransferCompareReport -Text $text }
        $parsed.empty | Should -BeFalse
        $parsed.objects | Should -Be @('Обработка.Проверка', 'ОбщийМакет.Удалённый', 'ОбщийМодуль.Новый')
        $parsed.rootProperties | Should -Be @('Синоним - Различаются значения')
    }

    It 'reads versions, users, comments and object lists from the MXL history' {
        $bytes = New-TransferMxl -Cells @('Отчет по версиям хранилища:', 'C:\Хранилище с пробелом', 'Версия:', '4', 'Пользователь:', 'Разработчик', 'Дата создания:', '25.11.2026', 'Время создания:', '23:18:53',
            'Комментарий:', '0001234: "Задача"', 'Добавлены:', 'ОбщийМодуль.Новый', 'Изменены:', 'Конфигурация.Тест', 'Справочник.Товары', 'Удалены:', 'ОбщийМакет.Старый',
            'Версия:', '5', 'Пользователь:', 'Коллега', 'Комментарий:', '', 'Изменены:', 'Обработка.Проверка.Форма.Основная')
        $versions = & { . $script:TransferHelper -ProjectRoot $TestDrive -Action help *> $null; ConvertFrom-RepositoryTransferHistoryReport -Bytes $bytes }
        $versions.Count | Should -Be 2
        $versions[0].version | Should -Be 4
        $versions[0].comment | Should -BeExactly '0001234: "Задача"'
        $versions[0].added | Should -Be @('ОбщийМодуль.Новый')
        $versions[0].changed | Should -Be @('Конфигурация.Тест', 'Справочник.Товары')
        $versions[0].deleted | Should -Be @('ОбщийМакет.Старый')
        $versions[1].user | Should -Be 'Коллега'
        $versions[1].comment | Should -Be ''
        $versions[1].changed | Should -Be @('Обработка.Проверка.Форма.Основная')
    }

    It 'finds the latest version with one-version probes when no hint exists' {
        $result = & {
            . $script:TransferHelper -ProjectRoot $TestDrive -Action help *> $null
            $script:Probes = [System.Collections.Generic.List[string]]::new()
            function Get-RepositoryTransferVersions { param([int]$From, [int]$To = 0, [string]$WorkRoot)
                $script:Probes.Add("$From-$To") | Out-Null
                $last = if ($To -gt 0) { [Math]::Min($To, 37) } else { 37 }
                @($From..$last | Where-Object { $_ -le 37 -and $_ -ge $From } | ForEach-Object { [pscustomobject]@{ version = $_ } })
            }
            [pscustomobject]@{ plain = (Get-RepositoryTransferLatestVersion -WorkRoot $TestDrive); hinted = (Get-RepositoryTransferLatestVersion -Hint 30 -WorkRoot $TestDrive); probes = $script:Probes.Count }
        }
        $result.plain | Should -Be 37
        $result.hinted | Should -Be 37
        $result.probes | Should -BeLessThan 16
    }
}

Describe 'Repository transfer stages' {
    It 'refuses extension branches and projects without a repository before any native call' {
        $native = New-TransferNative 'расширение'
        $native.kind = 'extension'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'review' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_EXTENSION_UNSUPPORTED'
        $native.kind = 'configuration'; $native.usesRepository = $false
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_NOT_CONFIGURED'
        $native.calls.Count | Should -Be 0
    }

    It 'runs a reviewed transfer to a confirmed version and a master capture without repository update' {
        $native = New-TransferNative 'ручной'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'review' }
        $native.error | Should -BeNullOrEmpty
        Get-TransferStage $native | Should -Be 'prepared'
        $native.state.repositoryTransfer.baseVersion | Should -Be 7
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'agent' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_HUMAN_REVIEW_REQUIRED'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'human' }
        Get-TransferStage $native | Should -Be 'approved'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'commit'; RepositoryTransferComment = '1: Задача' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_STAGE'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'apply' }
        $native.error | Should -BeNullOrEmpty
        Get-TransferStage $native | Should -Be 'applied'
        @($native.calls) | Should -Contain '/LoadConfigFromFiles'
        @($native.calls) | Should -Contain '/UpdateDBCfg'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'smoke'; RepositoryTransferSmoke = 'passed'; RepositoryTransferComment = 'движение по регистру есть' }
        Get-TransferStage $native | Should -Be 'smoke-passed'
        $native.history = @([pscustomobject]@{ version = 8; user = 'Разработчик'; comment = '1: Задача'; added = @(); changed = @($script:FormObject); deleted = @() })
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'commit'; RepositoryTransferComment = '1: Задача' }
        $native.error | Should -BeNullOrEmpty
        Get-TransferStage $native | Should -Be 'committed'
        $native.state.repositoryTransfer.committedVersion | Should -Be 8
        @($native.calls | Where-Object { $_ -eq '/ConfigurationRepositoryCommit' }).Count | Should -Be 1
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'cancel' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_ALREADY_COMMITTED'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'update-master' }
        $native.error | Should -BeNullOrEmpty
        @($native.calls) | Should -Contain 'sync-master:True'
        Get-TransferStage $native | Should -Be 'master-updated'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'complete'; RepositoryTransferMantis = 'skipped' }
        Get-TransferStage $native | Should -Be 'completed'
    }

    It 'stops a stale decision after the CF is rebuilt and before any write' {
        $native = New-TransferNative 'пересборка'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'agent' }
        Get-TransferStage $native | Should -Be 'approved'
        $native.cfSha = 'sha-2'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'apply' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_MATERIAL_CHANGED'
        @($native.calls) | Should -Not -Contain '/LoadConfigFromFiles'
        $native.cfSha = 'sha-1'; $native.reportSha = 'report-2'
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'apply' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_MATERIAL_CHANGED'
        @($native.calls) | Should -Not -Contain '/LoadConfigFromFiles'
    }

    It 'hands foreign infobase changes and out-of-task objects to a human' {
        $native = New-TransferNative 'посторонние'
        $native.compare['7|probe-repository'] = @('Справочник.Чужой')
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_FOREIGN_CHANGES'
        $native.compare.Remove('7|probe-repository')
        $native.compare['7|attempt-1-total'] = @('Обработка.Проверка', 'Справочник.Чужой')
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_SCOPE_MISMATCH'
        $native.state.PSObject.Properties['repositoryTransfer'] | Should -BeNullOrEmpty
    }

    It 'retries after a failed smoke against the applied CF and stops when the repository advanced' {
        $native = New-TransferNative 'повтор'
        foreach ($step in @(@{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }, @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'agent' }, @{ RepositoryTransferStep = 'apply' }, @{ RepositoryTransferStep = 'smoke'; RepositoryTransferSmoke = 'failed' })) {
            Invoke-TransferStep -Root $native.root -Native $native -Parameters $step
        }
        Get-TransferStage $native | Should -Be 'smoke-failed'
        $native.cfSha = 'sha-2'; $native.head = 'head-2'
        $native.compare['7|attempt-2-total'] = @('Обработка.Проверка')
        $native.calls.Clear()
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        $native.error | Should -BeNullOrEmpty
        $native.state.repositoryTransfer.attempt | Should -Be 2
        @($native.calls) | Should -Contain 'compare:0|probe-applied'
        @($native.calls) | Should -Not -Contain 'master-current'
        $native.state.repositoryTransfer.applied.baseVersion | Should -Be 7
        $native.latest = 8
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_REPOSITORY_ADVANCED'
    }

    It 'reconciles an interrupted commit from history without committing twice' {
        $native = New-TransferNative 'обрыв'
        foreach ($step in @(@{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }, @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'agent' }, @{ RepositoryTransferStep = 'apply' }, @{ RepositoryTransferStep = 'smoke'; RepositoryTransferSmoke = 'passed' })) {
            Invoke-TransferStep -Root $native.root -Native $native -Parameters $step
        }
        $native.state.repositoryTransfer.stage = 'committing'
        $native.state.repositoryTransfer | Add-Member -NotePropertyName commitComment -NotePropertyValue '1: Задача' -Force
        $native.calls.Clear()
        $native.history = @(
            [pscustomobject]@{ version = 8; user = 'Разработчик'; comment = '1: Задача'; added = @(); changed = @($script:FormObject); deleted = @() },
            [pscustomobject]@{ version = 9; user = 'Разработчик'; comment = '1: Задача'; added = @(); changed = @($script:FormObject); deleted = @() })
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'commit' }
        $native.error | Should -Match '^REPOSITORY_TRANSFER_COMMIT_AMBIGUOUS'
        $native.history = @($native.history[0])
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'commit' }
        $native.error | Should -BeNullOrEmpty
        $native.state.repositoryTransfer.committedVersion | Should -Be 8
        @($native.calls) | Should -Not -Contain '/ConfigurationRepositoryCommit'
    }

    It 'cancels without rollback and keeps the locks' {
        $native = New-TransferNative 'отмена'
        foreach ($step in @(@{ RepositoryTransferStep = 'prepare'; RepositoryTransferMode = 'auto' }, @{ RepositoryTransferStep = 'approve'; RepositoryTransferDecidedBy = 'agent' }, @{ RepositoryTransferStep = 'apply' })) {
            Invoke-TransferStep -Root $native.root -Native $native -Parameters $step
        }
        $native.calls.Clear()
        Invoke-TransferStep -Root $native.root -Native $native -Parameters @{ RepositoryTransferStep = 'cancel'; RepositoryTransferComment = 'передумали' }
        Get-TransferStage $native | Should -Be 'cancelled'
        $native.state.repositoryTransfer.cancelled | Should -Not -BeNullOrEmpty
        @($native.calls | Where-Object { $_ -match 'UnLock|LoadConfig|Rollback' }).Count | Should -Be 0
    }
}
