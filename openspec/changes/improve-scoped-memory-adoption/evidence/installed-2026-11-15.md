# Canary установленной копии PM5, 2026-11-15

Задача 12.1. Копия `PM5 КОРП - Codex - 2`, раскатка `update-workflow` с
`develop@4749f8cf` (`ai_rules_1c` r59 `d6a65870`) поверх `develop@3097468d`.
Сервер `itl-scoped-cognee` запускался командой и аргументами из
`.codex/config.toml` ветки и вызывался по stdio JSON-RPC (`initialize`,
`tools/call`), как это делает клиент Codex. Тексты рабочих заметок сюда не
переносятся.

## Итог по пунктам задачи

| Пункт | Результат |
|---|---|
| Сессия, открытая до обновления, получает `MEMORY_STALE_CONTEXT` один раз | не воспроизводится на живых копиях — см. ниже |
| `memory_status` с постоянными заметками и оглавлением, включая кандидата | подтверждено |
| Нет `MEMORY_STALE_CONTEXT` при параллельном `update-workflow` | подтверждено для раскатки без изменения привязки — см. ниже |
| `contextChanged` и отказ первой записи после reset | не проверено: нужен `/itl-reset-branch` живой ветки пилота |
| Заметка workspace из одной ветки видна в другой ветке того же локального проекта | подтверждено |
| Удаление pending от 2026-11-08 через `retire_note` | подтверждено ранее: [pm5-notes-review](../../improve-memory-content-quality/evidence/pm5-notes-review-2026-11-15.md) |

## Workspace, постоянная заметка и кандидат

Все три ветки `2-branch1`, `2-branch3`, `2-branch4` имеют один
`localProjectId` (`59ba083b…`); у `1-branch1` другой (`ccaabf49…`).

| Шаг | Результат |
|---|---|
| `2-branch1`: `remember` в `itl_workspace_59ba083b…`, `status=standing`, evidence `user` | `state=durable`, `scopeKind=workspace`, 16,0 с |
| `2-branch1`: `remember` туда же, `status=candidate` | `state=durable`, `scopeKind=workspace`, 13,8 с |
| `2-branch3`: `memory_status` | `serverCoverage=bounded`; в `standing` — постоянная заметка целиком (`level=workspace`, `noteId`, `dataId`, факт); в `index` — уровень `workspace` с одной строкой `… [candidate]` |
| `1-branch1` (другая основная копия): `memory_status` | уровня `workspace` нет ни в `standing`, ни в `index` |
| `2-branch1`: `retire_note` обеих заметок, затем `memory_status` | обе `retired`; `standing` пуст, уровня `workspace` в `index` нет |

В `destinations` строки workspace нет: по справочнику она читается, но к записи
не предлагается, явный label принимается. Запись выше шла по явному label.

## Вызовы памяти во время `update-workflow`

Сервер запущен в `2-branch3` в 15:53, до раскатки: `memory_status(local_only)`
и `recall` (3 карточки). Затем, не закрывая процесс, выполнен `update-workflow`
мастера: мастер закоммичен на `develop@4749f8c`, его скрипты, включая
`cognee-memory-mcp.ps1`, заменены; `itldev/branch3` раскатан за 05:24. После
этого в 16:02 тот же процесс выполнил `recall`, `memory_status` (сервер,
`serverCoverage=bounded`) и `recall`: все без ошибки, без `MEMORY_STALE_CONTEXT`
и `contextChanged`, по 3 карточки, `bindingState=current`, цикл прежний.

`bindingId`, `cycleId`, `settingsHash` и `registryContextHash` привязки
`2-branch3` до и после раскатки совпадают; файл привязки раскаткой не
переписан (время изменения 15:52, до запуска сервера). Значит, проверен случай
раскатки, которая не меняет привязку. Обновление привязки на месте (например,
новое подтверждение политики) этой раскаткой не вызывалось и здесь не
проверено; его покрывает Pester `ScopedCogneeMemory`.

Раскатка всех шести веток копии (`branch1`–`branch4`, `md-migration-proof`,
`md-performance-proof`) завершилась `completed` за 04:43–05:24 с первого
прогона, без `RUNNER_STATUS_STALE` и сверки.

## Однократный `MEMORY_STALE_CONTEXT`

Пункт относится к разовому дополнению привязки (2.3). Оно уже прошло на всех
19 привязках PM5: у каждой есть `localProjectId` и `hostId`. Повторить его на
живой копии нельзя. В логах Codex копий PM5 за 2026-11-01 — 2026-11-15
`MEMORY_STALE_CONTEXT` не встречается ни разу, а `MEMORY_CONTEXT_CHANGED` —
только в выводе справочника, не в ответе сервера. Однократность отказа
подтверждается только Pester (замороженный читатель предыдущей версии
`tests/fixtures/scoped-memory/previous-reader.ps1`), не вызовами клиента.

## Reset

`contextChanged` и отказ первой записи после смены цикла требуют
`/itl-reset-branch`. Все ветки PM5 — живые копии пилота с работой пользователя,
и в логах Codex реального ответа с `contextChanged` нет. Проверка оставлена до
решения пользователя о ветке, которую можно сбросить.
