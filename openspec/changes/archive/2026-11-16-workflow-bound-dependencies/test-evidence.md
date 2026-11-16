# Проверка реализации

## Локальные проверки до live-приёмки

Ветка `codex/workflow-dependencies`, Windows PowerShell 5.1, Pester 5.8.0.
Прямые owned suites запускаются через `invoke-pester-shards.ps1`; Targeted
отдельно не запускался. Регистрацией и публикацией эти результаты не являются.

- `build/dependency-bundle-proof`: 266 passed / 0 failed: DependencyLocks 33,
  OnDemandMcp 56, AiRulesMigration 29, OpenSpecCliRuntime 5,
  SourceUpgradeHandoff 58, UiTools 11, VanessaPatchedArtifact 60,
  GitHubDependencyFallback 14. Последующие изменения API формы записей
  перепроверены непосредственно владельцами ниже.
- `build/dependency-selection-final-2`: 105 passed / 0 failed:
  DependencyLocks 33, YAxUnitVerification 65, VanessaArtifactIntegration 7.
  Сохраняются исходные archive/EPF SHA mismatch reproductions; fixture package
  теперь объявляет собственные pins, вместо неявного изменения project lock.
- `build/dependency-transaction.xml`: 6 passed: rollback при post-copy failure
  и после commit, сохранение решения при изменении внешнего JSON после arm,
  CAS при изменении/появлении lock и повтор после перепланирования,
  выбранный workflow-переход и явный qualified fork exception.
- Ранее полный WorkflowUpdateRollback: 52 passed. После расширения suite её
  новые cases выполнены отдельно; актуальную полную селекцию выполнит RegisterChange.
- Strict OpenSpec validation прошла. Проверка parser helper modules прошла.

Это fixture/unit evidence. Реальные файловые update/rollback описаны ниже отдельно;
успешные 1C init/CFE/MCP-вызовы ими не подтверждаются.

## Стоимость и применимость

Один workload — разрешение точного ROCTUP и двух Vanessa MCP артефактов,
20 повторов после прогрева, одинаковый PowerShell и packaged inputs.
Pristine HEAD: 36 мс/workload. Первый вариант resolver: 1083,8 мс.
После передачи одного plan между consumers и memoization: 55,2 мс.
Дополнительные 19,2 мс относятся к проверке полных входных bytes и копированию
JSON-решения; native tools/list и runtime/proof не кешируются. Замер находится
в `build/measure-dependency-resolution.ps1`; никакого постоянного сборщика нет.

Memoization действует только в процессе. Ключ включает root, пути и SHA всех
входных lock/template/selection/compatibility файлов. Транзакция потребляет свой
сохранённый plan; изменённый selection JSON и другой root не переиспользуют старое
решение. Копия JSON сохраняет контракт PSObject для diagnostic baseline callers.

Всегда загружаемые instructions не расширены. В AGENT-INSTALL заменён один
абзац; нормализованный UTF-8 текст уменьшился с 58838 до 58727 bytes.
Подробности доступны по одному reference; dependency status включается явно.
Новый module добавлен в существующий quality owner `dependency-lock`; бюджет
300 секунд сохранён (последний непосредственный suite — около 33 секунд).
Повторное использование gate proof возможно только по общим правилам inputs,
inventory и runtime identity; более ранние shard results не объявлены exact-tree.

## Live-приёмка

Пользователь выбрал штатный E2E-стенд при условии доступности. Приёмка должна
использовать его изолированные qualification fixtures. Основной test bundle
содержит `itl-main-5700f54-r42`, commit `827e5ccaa7e319dc5871555f7e997093478359c4`.
Для retain/retire нужны отдельные immutable test generations с известными
qualified r36/r42; изменение версий в этих fixtures не меняет shipped template.

## Доставка

Итоговый local commit регистрируется через RegisterChange, который владеет одним
Targeted на общем кандидате. Фактический head/queue/gate подтверждаются отдельным
source-delivery Status, без изменения этого документа после регистрации.
Публикация не запрошена.
### Первый live-переход и transport continuation

Штатный owner создал отдельный Develop fixture из immutable capsule
`c2c570fe1ec57619f1a516b9752c48159da7b703eb8c8bb275977abde19cd8b6`.
Исходный стенд и его worktree не изменялись. Test generation r36:
`e06bce901f2bffc788f485fb81cb7b7ed191792a`; pin взят из исторического
qualified template (`1e01117b^`, passed, checkedAt 2026-09-23T01:33:44Z).

Обновление дошло до post-copy и точных YAxUnit/ROCTUP/Vanessa/facade артефактов,
но r36 installer потерял Get-FileHash в Windows PowerShell после native fresh
launch из PowerShell Core. Snapshot `be13cd08fdcd4133aac7753dc9be38f0` и точный
кандидат сохранены; успешной приёмкой этот запуск не является.

Исправлен owning native capture boundary: Windows PowerShell получает совместимые
module roots без изменения окружения родителя. Compact runner использует тот же
stateless helper. Fork и installed copy не патчились, recorded package не менялся.
`build/dependency-transport-proof`: 11 passed / 0 failed, включая настоящий Core →
Desktop переход, Get-FileHash и точный Unicode/whitespace round trip.
Продолжение live-перехода — через существующего recovery executor.

### Исправленный кандидат и файловая live-приёмка

Recovery выявил вторую ошибку нового resolver: captured plan перезаписывал
workflowPackage записью до копирования. Sync теперь сохраняет актуальную запись
package owner; transaction regression проверяет точный новый commit.
Первый незавершённый fixture и snapshot сохранены для диагностики; их статус
не объявлен успешным и receipts вручную не исправлялись.

После исправления `SourceUpgradeHandoff` 58 + `UiTools` 13 = 71 passed / 0 failed
(`build/dependency-owner-recovery-proof-2`). Транзакционные 6 cases повторно прошли.
UI cases проверяют перенос только идентичного legacy agent-browser cache,
сохранение исходных bytes и fresh install/doctor gates при другом integrity.

Код tested candidate: `517ecc0e4e04a71e931b66caf77138a1f4326588`.
Файловая live-приёмка относится к этому candidate, не ко всем последующим bytes.
Первый регистрационный Targeted выявил старый flat cache path общего
DevBranchLifecycleSupport facade fixture и пропущенных refresh consumers schema 2.
Failed candidate `itl-source-register-8fe383dd9b2546f2b04895ebff82e785` сохранён;
accepted queue refs им не заменены.

Fixture путь исправлен на version/SHA; настоящая сборка, точная проверка её SHA и
исходное facade-ready assertion сохранены. Semantic refresh merge и проверка
допустимого lock diff теперь используют общий resolver и stateless sync manifest,
включая прежний template из branch commit. Master hotfix не переносится в чужой
worktree. В legacy неполном checkout отчёт решения игнорируется через существующий
info/exclude owner, поэтому повтор исходной операции после выбора проходит clean
guard; чужие файлы и tracked guards не ослаблены.

`build/dependency-live/refresh-proof-3.log`: 8 passed / 0 failed — настоящий Git
semantic conflict, исходный старый client_mcp pin с отказом до выбора и повтором
через тот же Sync/postcondition, retain/retire, master-only exception, schema 1/2,
реальные facade binaries в worktree/init fixtures. `transaction-final.log`:
6 passed / 0 failed после выделения sync manifest. Полный Targeted нового head
выполняет повторный RegisterChange; предыдущая незавершённая селекция не считается
успешной квалификацией.

Во втором Targeted прежние owners прошли; дальнейшие bootstrap/doctor tests
выявили ожидания прежней fresh/locked политики и observer, принимавший выбранный
facade за запись об установленном в sparse legacy lock. Doctor снова читает
фактическую запись; getters при отказе выбора больше не пишут отчёт, его создаёт
mutating update owner. Обновлены init references с удалением противоречащего
locked-контракта; StrictMode fixture объявляет выбранный immutable checkout, а
phase-only fixture — валидный selected plan с реальным validator/receipt.
Исходные StrictMode, SHA, sequencing и clean assertions сохранены.

Failed candidate `itl-source-register-94912e288dba4fc893685bc5d2a58d36` сохранён,
accepted queue не заменена. После диагностики выполнены полные owner suites:
BootstrapUpdate 77 и ClientAdaptersAndModes 41 passed; DependencyLocks после
добавления observational regression — 34 passed (`build/dependency-readonly-proof`).
После диагностики новый исправленный head проходит обычный RegisterChange.
Попытка передать `-RetryBlockedStage` отклонена до gate: этот флаг принадлежит
только PublishDevelop и неприменим к регистрации. Публикация не выполняется.

Следующий candidate `itl-source-register-550ba952aea84aaf83d5b4185e7a1e9e` прошёл
прежние owners и выявил MCP/AI client fixtures, объявлявшие тестовые сборки лишь
в project lock/config. Их package templates теперь фиксируют те же синтетические
pins. Исходные corrupted-cache, source-build SHA, Cursor idempotence, настоящий
Git index lock другого проекта, same-root reuse и tag/commit mismatch сохранены.
Отсутствующий legacy config ref использует immutable workflow tag; неполный
выбранный pin по-прежнему отвергается до обращения к main.
Полные `McpConfig` 57 и `AiRulesClients` 14 passed / 0 failed после исправления.
Это уточнение fixtures к согласованному source-of-truth контракту, не runtime proof.

Candidate `itl-source-register-a6f4ed75824347b1b746e55f2b7a4020` выявил ещё три
ROCTUP cache fixtures с pin только в project lock и две CFE fixtures, наследовавшие
внешний build archive. ROCTUP package теперь объявляет исходные fixture pins;
Vanessa fixture содержит собственный ZIP с той же парной CFE и scoped archive
восстанавливает окружение после проверки. Corrupt-cache, точные SHA, исходный
invalid configured path и неизменность tracked lock сохранены.
`build/dependency-cache-fixtures-proof`: McpConfig 57 + ArtifactCacheIsolation 5 =
62 passed / 0 failed. Неуспешный кандидат сохранён, accepted refs не заменены.

Candidate `itl-source-register-a93117f40dad462db5f2234b05e1afa1` прошёл эти cases,
затем выявил неполную сборку CompactRunner fixture: Core regression копировал
runner без нового stateless environment module. Все три runner fixture builders
теперь копируют этот required input. Исходный Core → Desktop запуск, путь с
кириллицей/пробелом и проверка Get-FileHash не изменены.
`build/dependency-runner-fixtures-proof`: Routing 8, Reports 15, Watchdog 12 =
35 passed / 0 failed / 0 skipped; Core scenario фактически выполнен.

Candidate `itl-source-register-09be9a9e7e0f450483365649cc03c4a6` прошёл runner,
затем три phase-only PendingMergeWorkflowTransition fixtures остановились до своих
исходных контрольных точек: source package не содержал dependency template.
Их source builders теперь включают реальный immutable template до фиксации source
commit. Production checks не изменены; recovery, Git worktree move, lost commit
acknowledgement, staged business, merge target и lifecycle record assertions
сохранены. Полный `build/dependency-pending-merge-proof`: 11 passed / 0 failed /
0 skipped, с настоящими merge-конфликтами и тем же исходным workload.

Candidate `itl-source-register-274e85686a7a4cefadf60616af8300d7`: 2305 passed,
один failed в YAxUnit static sequencing case. В принятой очереди PostCopy уже
делегирует registry operation в PostCopyCore; test искал установку в wrapper.
Проверка теперь требует делегирование и прежний строгий порядок Sync → Install
в фактическом implementation body. Исходный order regex сохранён.
`build/dependency-yax-wrapper-proof`: полный YAxUnit 65 passed / 0 failed /
0 skipped; тот же исправленный case отдельно выполнен на настоящем общем
кандидате с wrapper, без изменения сохранённого candidate tree, и прошёл.

Candidate `itl-source-register-e33464c365b1498c8572cc4f99012a0a` прошёл параллельную
часть и первый serial orchestration. CompactItlRunner static case ещё требовал
старую inline реализацию фильтра module path. Он теперь проверяет вызов общего
owner и его поведение: только Core module root исключается без учёта регистра и
завершающего slash; остальные Unicode/whitespace paths, Desktop и окружение
родителя сохраняются. Остальные job/console assertions сохранены.
`build/dependency-runner-contract-proof-2`: 3 passed / 0 failed / 0 skipped,
включая реальный Win32 Ctrl+C и остановку owned helper process tree.

Factory повторно подготовила из того же capsule отдельные roots:
`C:\itlj\q Проект\develop-c2c570fe1ec5-517ecc0e4e04-44bd936f\project` и `branch`.
Файловые операции выполнялись настоящими source/installed helpers без test mode,
без правок установленного fork и без изменений исходного стенда.

| Сценарий | Наблюдаемый результат |
|---|---|
| Existing fresh master + locked branch | Legacy locked подготовлен прежним Set-DependencyLockMode; source update доставил `b567f9ad1da3b5adc1b14f2ceb792ffbf28124cc` с qualified r36 в оба roots. mode=workflow, trees clean; refresh конфигурации не вызывался. |
| Scoped hotfix | Через DependencyHotfixOnly выбранный branch получил qualified r42 (`827e5ccaa7e319dc5871555f7e997093478359c4`) и rules42 exception; master сохранил r36 без исключения. |
| Preserve newer hotfix | Новый immutable workflow `18f2dffb7c198b8ee66e6ed285fd59ff9157dff5` с baseline r36 обновил оба roots, branch сохранил rules42. |
| Busy branch | Настоящий lifecycle lease ветки удерживался существующим Wait-Agent1cLockSet. Master получил candidate 517ecc0e/r42; branch получил deferred/active-lifecycle-lock. Все 348 managed path states, lock, rules и HEAD ветки остались прежними. |
| Repeat without refresh | После освобождения lease та же source update команда завершила только ветку; master HEAD сохранился. Workflow r42 автоматически снял rules42. |
| Rollback | Source-side Recovery restore snapshot `acb8f080b395466e82451048f04dbe47` вернул branch workflow 18f2dffb + rules42, сохранил поздний посторонний файл и master HEAD. Rollback commit `7f89b3fa6f689297365b9acd80fbad8aa92d27bb`. |

Полный SHA256 исходного и восстановленного lock одинаков:
`635c341f661e8156ae7923bb1c3f8bf778f260216bd8763b6a4a1d8fc761dc7a`.
После проверки собственный fixture-файл удалён; оба tracked trees чистые.
Records: `hotfix-applied.json`, `hotfix-retained.json`, `busy-before.json`,
`busy-deferred.json`, `hotfix-retired.json`, `rollback-proof.json`,
`rollback-restored.json` в `build/dependency-live` task checkout.

При всех переходах артефакты tools оставались exact workflow pins:
ROCTUP v1.7.1 `74bd1d228aa36fda688b34277ede6030ea3b54350c112a680cdce63adb8ac675`;
Vanessa 1.2.043.42-itl-r4 archive
`84aabfbf77511abd432c235625afb543aa3c182654e08a24bda3c4312c7d5f4c`;
client_mcp v0.6.5-itl-r1
`29f741db8a379384cd8270398761ec96e7e8e548071a0c180d4ffc6ddd8443b6`;
VAExtension 1.32-itl-r4
`24190cb07ad82ac49aacdd86c1fb6412cd2f6713758cde123b1bb4103b7b4c0c`;
facade 0.4.15
`95968cccdcc38e3327ce7dc2ebe521fc34d55b44459d0a9d301cdec0be114aff`.
Их acquisition и hashes прошли; фактические tools/list этим не подтверждены.

### Явно отложенная нативная приёмка

Fork второй ветки остановлен application-readiness guard; предписанный
update-dev-branch-base затем отказал на Gate 6 snapshot из-за отсутствия лицензии
1С. Fresh init отказал в seed.copy-artifact из-за отсутствующего исходного 1CD
в owned fixture project. Никакой из этих отказов не считается успешным init,
CFE preparation, client reload или MCP runtime proof.

Пользователь явно выбрал отдельный нативный прогон. Точные attempts, blockers и
оставшийся исходный workload сохранены в [follow-up-native-acceptance.md](follow-up-native-acceptance.md).
Windows-MCP не подготовлен на этом host из-за отсутствия uv/uvx; прежняя optional
non-blocking политика helper сохранена. Локальный vibecoding1c вынесен отдельно.
