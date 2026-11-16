# Итоговая live-приёмка — 2026-10-13

Принятый объём redesign-source-delivery выполнен. Публикация и две настоящие
параллельные регистрации прошли. Индивидуальный аудит ограничен согласованными
800 из 2814 исходных определений; остальные 2014 не объявляются разобранными.

## Выпуск и повтор доставки

Опубликован `origin/develop`:
`fc43a953fbc9601934834010bc8b249ecaff0154`, tree
`c07d73aaf4fca78e6e92004c071456e8148bc239`. Publisher вернул `published`,
`developPublished=true`, `dependenciesInstallable=true`, `masterReleased=false`.
После выпуска Status: очередь пуста, publicationAttempt и activeOperation
отсутствуют, опубликованный develop-supervisor — `fc43a953`.

Начатый plan `60aee6425edb2df77f73975a114c3470d38a033602258f4b64ec667d6ee4ec1a`
сохранил authority `fa0e3c91`. Его первая успешная квалификация Develop заняла
3487065 ms: Full2910/0/1, 17 executed / 159 reused workers, реальная fresh journey
3036715 ms и переиспользованная upgrade journey `46b8c309` с совпавшими входами.
Full отдельно после Develop не запускался. Исходный positive capsule остался
`66ca0a9597f5965c9dd5b21f58286d8e0bbccb68ea40a5cb8cf7ac0425f73815`.

Один process-local pre-push hook отверг именно `fc43a953 -> refs/heads/develop`;
remote остался на `fa0e3c91`, настройка hook восстановлена. Обычный повтор
`PublishDevelop -ResumePlan ...` восстановил `component-finalized` и доставил тот
же кандидат. Нового Develop и запуска 1С не было: в ledger остался один passed
Develop этого commit; SHA256 develop.json до и после повтора одинаков:
`94c97b1cae22856deadd998885d99969eb026a9bfa2fe08e17c9a690c7ac09c8`.
Повтор занял примерно 9 минут 6 секунд вместе с pre/post cleanup; это не обещание
такой длительности каждого выпуска. Старая сводка timing имела `historyStatus=corrupt`
и не использована для сравнения времени. Опубликованный reader `fc43a953` читает
историю: `indexStatus=ready`, 1726 записей, `invalidCount=0`.

`origin/master` остался `69c0863bfe3bd837543267f122e81a28dcfa5488`.
Все 76 строк remote tags до/после совпали; SHA256 списка:
`fbb07368d3752818ca40215d87eae5e75b8f1d5eccadfef741ccd6dd8036421f`.
Master/Release/server-reset этим выпуском не квалифицировались.

## Две регистрации через опубликованный supervisor

В отдельном QA Git common directory две независимые документальные доработки
запущены одновременно настоящим `RegisterChange`, без fake gate и публикации QA.

| Задача | Commit | Полный процесс | Первый Targeted |
|---|---|---:|---:|
| Альфа | `aaaa672d1d140ed928228ea2ce5828be7a14a147` | 54.347 s | 48.151 s |
| Бета | `1d226351d9725a025cce059c0a253e6ee2b08a03` | 91.116 s | 47.912 s |

Первые passed Targeted пересеклись на **47.9119502 s**. После изменения общего
кандидата ещё один Targeted прошёл за34.031 s. Оба процесса exit0; worktrees чистые,
очередь содержит обе регистрации, active operation отсутствует. Общий кандидат
`dbc66bec1e685aa6e4aa2851812765050dab2dab`, tree
`c626effcc8b2eeb76c56bdbc79625775da35921f`, status `ready`; оба task head — его
предки, оба файла присутствуют. QA-изменения остаются в отдельном репозитории.

## Стоимость и защита результата

Сохранены все305 lifecycle cases; измеренный интервал четырёх групп304.646 s
вместо793.036 s прежнего shard. Удалены три доказанно дублирующих Python
definitions, эквивалентные требования сохранены. Малые docs-only регистрации
ранее занимали27–31 s; изолированная SPPR —53.207 s, проверка Ctrl+C —36.850 s.
Warm Develop `c2f18147` прошёл273193 ms с17 executed /159 reused workers и двумя
reused journeys. Это время gate, не полного publisher. Исходный Develop108.17 min
исполнял обе native journeys; сравнение с новым запуском58.12 min учитывает
переиспользование upgrade и не означает двукратного ускорения самой 1С.

Контракты selection/cost/reuse закреплены в AGENTS.md, local-quality-gate.md,
каталоге владельцев и проверках selector/fingerprint. Unknown inputs отключают
reuse; executable change без нового теста требует существующий CoverageContract.
Проверка новой доработки и публикация общего кандидата разделены; проверки
регистрации выполняются вне общей CAS-блокировки. Подробности аудита и отдельных
изменений: [cost-priority-audit.md](cost-priority-audit.md).

Planning исправлен в46b8c309: цель30 s, hard limit120 s. 32 s и120 s сохраняют
валидный план,120.001 s дают отказ с сохранением очереди/checkpoint. Реальное
наблюдение32 s cold /16.4 s warm объясняет прежний ложный отказ. Регрессия на
границы пройдена; лимит активен в опубликованном supervisor. Во время приёмки
также исправлены ложный native cache miss из-за LF/CRLF собственного PowerShell
и зависимость CAS deadline regression от скорости машины; исходные runtime
проверки и воспроизводители сохранены.

## Остаточный долг и границы

Publisher завершился `completed-with-cleanup-warnings`: старые ресурсы без
достаточной ownership-доказательности не удалялись. Стоимость повторной cleanup
остаётся. Найден ещё один реальный дефект эксплуатации: после удаления баз
qualification copy сохраняет около2.2GB исходников/tools. Накопление копий заполнило
C:, fresh остановился на модальном disk112. Закрытые принадлежащие задаче копии
сохранены на локальных D:/E: с проверкой counts/bytes/claim SHA; исходные capsules
сохранены, затем исходный fresh сценарий прошёл без изменения пути и нагрузки.
Автоматическая retention и немедленная диагностика disk112 ещё не реализованы;
освобождение места не объявляется их постоянным исправлением. Этот долг не скрыт
за закрытием согласованных пунктов приёмки.

Основной checkout на local develop `c900620e` с чужими untracked OpenSpecs сохранён;
публикация не означала его принудительного обновления. Реализация находится в
origin/develop и чистом рабочем worktree. Итоговые evidence регистрируются обычной
документальной доработкой после выпуска; повторная публикация ради них не требуется.

Локальные первичные receipts: `build/redesign-source-delivery/candidate-protocol/`
(`accepted-fc43a953`, `live-push-fault-fc43a953/receipt.json`, success log,
`status-fc43a953-published.json`) и qualification worktree
`build/redesign-source-delivery/runtime-proof/live-parallel-result.json`.
