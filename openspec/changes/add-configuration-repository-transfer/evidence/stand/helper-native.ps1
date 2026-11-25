# Runs the transfer module's native steps through the package Invoke-Designer
# against a stand prepared by 01-04 plus an update and form lock of the developer infobase.
param([Parameter(Mandatory = $true)][string]$StandRoot, [string]$Platform = 'C:\Program Files\1cv8\8.3.27.2130\bin\1cv8.exe')
$ErrorActionPreference = 'Stop'
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$project = Join-Path $StandRoot 'проект helper'
New-Item -ItemType Directory -Force -Path $project | Out-Null
. (Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1') -ProjectRoot $project -Action help *> $null
$script:StandDev = Join-Path $StandRoot 'ИБ разработчика'
$script:StandRepo = Join-Path $StandRoot 'Хранилище конфигурации'
$script:StandPlatform = $Platform
function Get-SourceInfoBasePath { $script:StandDev }
function Get-InfoBaseKind { 'file' }
function Get-PlatformPath { $script:StandPlatform }
function New-RepositoryConnectionArgs { @('/ConfigurationRepositoryF', $script:StandRepo, '/ConfigurationRepositoryN', 'Разработчик', '/ConfigurationRepositoryP', (ConvertTo-NativeEmptyStringArgument '')) }
function Get-EnvValue { param([string]$Name, [object]$Default = $null) switch ($Name) { 'REPOSITORY_USER' { 'Разработчик' } 'IB_USER' { '' } 'IB_PASSWORD' { '' } default { $Default } } }
$work = Join-Path $StandRoot 'работа helper'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$cf = Join-Path $StandRoot 'ветка-после-refresh.cf'
$src = Join-Path $StandRoot 'ветка после refresh'
$rel = 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext'
$results = [ordered]@{}
$latest = Get-RepositoryTransferLatestVersion -WorkRoot $work
$results.latestVersion = $latest
$results.probeEmpty = (Invoke-RepositoryTransferCompare -FirstVersion $latest -ReportPath (Join-Path $work 'probe.txt')).empty
$total = Invoke-RepositoryTransferCompare -FirstVersion $latest -SecondFile $cf -ReportPath (Join-Path $work 'total.txt')
$results.totalObjects = @($total.objects)
Assert-RepositoryTransferReportScope -Report $total -Scope ([ordered]@{ objects = @('Обработка.ITLОбработкаПроверкиОбработчиковФормы.Форма.ФормаПроверкиОбработчиковСДлиннымИменем'); rootRequired = $false })
$results.scopeAccepted = $true
try { Invoke-RepositoryTransferCompare -FirstVersion 99 -ReportPath (Join-Path $work 'missing.txt') | Out-Null; $results.missingVersion = 'not detected' } catch { $results.missingVersion = ($_.Exception.Message -split ':')[0] }
$listPath = Join-Path $work 'files.txt'
[IO.File]::WriteAllLines($listPath, [string[]]@((Join-Path $src "$rel\Form.xml"), (Join-Path $src "$rel\Form\Module.bsl")), [Text.UTF8Encoding]::new($true))
Invoke-RepositoryTransferDesigner -DesignerArgs @('/LoadConfigFromFiles', $src, '-listFile', $listPath, '-Format', 'Hierarchical') | Out-Null
$results.afterLoadEqualsCf = (Invoke-RepositoryTransferCompare -SecondFile $cf -ReportPath (Join-Path $work 'after.txt')).empty
Invoke-RepositoryTransferDesigner -DesignerArgs @('/UpdateDBCfg') | Out-Null
$record = [ordered]@{ baseVersion = $latest; objects = @('Обработка.ITLОбработкаПроверкиОбработчиковФормы.Форма.ФормаПроверкиОбработчиковСДлиннымИменем'); commitComment = '0001234: Проверка helper' }
$objects = Write-RepositoryTransferObjectList -Objects $record.objects -IncludeRoot $false -Path (Join-Path $work 'commit.xml')
Invoke-RepositoryTransferDesigner -Repository -DesignerArgs @('/ConfigurationRepositoryCommit', '-Objects', $objects, '-comment', $record.commitComment) | Out-Null
$found = @(Find-RepositoryTransferCommittedVersion -Record $record -WorkRoot $work)
$results.committedVersions = @($found | ForEach-Object { $_.version })
$results.committedEqualsMain = (Invoke-RepositoryTransferCompare -FirstVersion ([int]$found[0].version) -ReportPath (Join-Path $work 'committed.txt')).empty
$results.latestAfterCommit = Get-RepositoryTransferLatestVersion -Hint $latest -WorkRoot $work
$results | ConvertTo-Json -Depth 4
