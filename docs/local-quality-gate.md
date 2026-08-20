# Проверки и доставка исходного workflow

Обычная доработка не запускает общий gate. Агент создаёт один связный локальный
коммит и регистрирует его:

```powershell
.\scripts\source-delivery.ps1 -Action RegisterChange `
  -CoverageContract <existing-contract-id>
```

For the first registration of a queue, `Targeted` uses `origin/develop` (or the
explicit `-BaseRef`). A later registration under the same `QueueId` uses the
previous queue head, so it verifies only the newly appended commits while the
original queue base remains unchanged. A non-descendant replacement fails
closed instead of silently retesting or rewriting another range.

`-CoverageContract` не нужен, если диапазон уже содержит изменённый Pester-тест.
Регистрация сама выполняет `Targeted` и только после успеха атомарно записывает
`base/head` под `refs/itl/develop-queue/*`. Эти refs общие для worktree, но не
публикуются. `-Action Status` показывает очередь и накопительную историю
успешных/неуспешных gate из общего Git-каталога `.git/itl/runs` со временем по режимам.

## Уровни проверки

| Режим | Когда | Цель | Hard limit |
|---|---|---:|---:|
| `Targeted` | регистрация одной доработки | 5 мин | 15 мин |
| `Smoke` | короткая проверка runner/catalog/delivery | 1 мин | 2 мин |
| `Full` | все изолированные Pester и fork compatibility | 10 мин | 20 мин |
| `Develop` | один Full и реальные стандартные journey | 25 мин | 90 мин |
| `Release` | только доказательства стабильной поставки после Develop | 60 мин | 120 мин |

Без параметров `check.ps1` запускает `Smoke`. Старый `Fast` временно является
deprecated alias для `Smoke`; в штатном процессе он не используется.
`Targeted` получает изменённые пути через NUL-delimited Git output и
`tests/quality-contracts.json`. Неизвестный путь останавливает проверку и требует
назначить владельца — полного fallback-прогона нет.

Каждый дочерний этап имеет hard timeout, no-progress timeout, heartbeat и запись
длительности в `build/test-results/local/check-summary.json`. Там же сохраняются
целевой/hard бюджет и пять самых медленных стадий. Выход за цель виден как
`over-target`, а провал или выход за hard limit блокирует публикацию.

`Targeted` и `Full` хранят каждый успешный Pester test-файл отдельно в
`.git/itl/pester-shards/v1`. Если файл падает, новые файлы больше не запускаются;
после исправления уже прошедшие файлы берутся из cache, выполнение начинается с
исправленного файла и продолжается дальше. Reuse возможен только при совпадении
самого test-файла, всех входов его контрактов, общих runner/locks,
версий PowerShell/Pester и identity controlled fork/Vanessa build. Неизвестный
владелец теста отключает кэш для шарда. Провальные результаты не кэшируются.

Исправление самого теста или gate-harness не сбрасывает уже доказанные более
ранние возможности. `tests/quality-contracts.json` объявляет четыре continuation
scope: `static`, `gate`, `develop`, `release`. Между ancestor-кандидатом и новым
commit все изменённые пути должны целиком принадлежать этим scope, а новый
commit/tree должен иметь точный прошедший `Targeted` с неизменённым tracked state.
Тогда Full/Develop evidence накладывается на этот Targeted и выполнение
продолжается с первого затронутого этапа. Неизвестный или production-путь,
отсутствующий/повреждённый Targeted record и изменение Develop-harness для
Develop proof закрывают reuse. Это продолжение по fingerprint входов, а не
эвристика «любой файл из tests безопасен».

## Публикация develop

```powershell
.\scripts\source-delivery.ps1 -Action PublishDevelop `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r29-grilling `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Команду запускают в foreground с внешним `timeout_ms >= 6000000`: внутренний
hard budget Develop равен 90 минутам, а внешняя оболочка обязана оставить запас
на сборку кандидата, push и удалённую сверку. Для `ReleaseMaster` требуется
`timeout_ms >= 7800000`.

Оркестратор атомарно создаёт общий для worktree delivery-operation lock и
публикует его через `Status` вместе с owner/gate PID. Если внешняя оболочка
прервана, но gate жив, повторный Publish/Release блокируется. После завершения
осиротевшего gate следующий запуск архивирует operation, восстанавливает запись
run history и exact-tree qualification, а затем продолжает обычную безопасную
сборку кандидата. Lock и status вручную не удаляются и не редактируются.

Pester-тест, который разбирает stdout/JSON или локализованный текст дочернего
PowerShell, обязан использовать `Invoke-TestPowerShellFile` и его UTF-8
`stdout`/`stderr`. Нативный pipeline-захват такого вывода запрещён: кодировка
меняется, когда worker сам запущен с перенаправленным выводом.

Оркестратор получает свежий `origin/develop`, строит временного кандидата из
локального `develop` и только зарегистрированных диапазонов, передаёт исходный
remote HEAD как границу `Develop`, выполняет обычный fast-forward push без force
и сверяет удалённый SHA/tree. Конфликт, сдвиг remote или ошибка gate сохраняют
очередь.

Если `develop` должен получить только release-qualified кандидат, к той же
команде добавляется `-RequireRelease`. Оркестратор последовательно выполняет
`Develop` и `Release` на одном временном commit и делает единственный push лишь
после двух успехов. Ошибка любой стадии не двигает remote и не очищает очередь.
При повторе того же exact-tree кандидата прошедший `Develop` берётся из
qualification cache, поэтому после ошибки `Release` он не запускается заново.
Успешный `Develop` уже включает exact-tree Full/static proof: отдельный `Full`
для того же дерева не запускается.

`PublishDevelop` атомарно хранит цепочку `candidate-built -> develop-qualified ->
release-qualified -> component-finalized -> remote-pushed`. Retry начинает с
первой незавершённой фазы; сбой finalizer/push не повторяет gate. Новая identity
кандидата/gate создаёт новую цепочку. После 60 минут новый этап не стартует. Два
одинаковых сбоя блокируют третий; повтор после диагностики требует
`-RetryBlockedStage`. Scope `deliveryPostGate` сохраняет broad proof.

Develop состоит из двух независимо квалифицируемых journey через публичные
поверхности workflow:

- обновление установленного N-1 стенда через `update-workflow`;
- refresh активной ветки, реальный `/itl-check`/Vanessa и экспорт результата;
- свежий bootstrap и `init-project` в коротком disposable-пути;
- `new-dev-branch`, минимальная конфигурационная правка и application feature;
- check, stale-result boundary через изменение feature без повторной загрузки
  конфигурации в Designer, recovery check, result, `refresh-dev-branch-lite`,
  повторный check и close.

Qualification `develop.json` связывает точный tree с SHA статического Full и
live-отчётов. Каталог владельцев сопоставляет диапазон `origin/develop...HEAD`
с `upgrade` и `fresh`; изменение самой оркестрации, неизвестный путь или
повреждённое доказательство всегда включает обе journey. Изменения, не входящие
в установленный lifecycle (например standalone MCP host), могут продолжить
незатронутые доказательства базового `develop` только при совпадении полного
input identity. Отсутствующая или несовместимая baseline qualification также
закрыто переключает выполнение на обе journey.

В текущем каталоге все владельцы установленного package участвуют в обеих
journey: upgrade и fresh пересекают одни и те же bootstrap/lifecycle/runtime
границы. Поэтому owner selection сейчас прежде всего исключает live 1C E2E для
source-only и standalone-host изменений; независимые checkpoint уже не дают
повторять прошедшую journey после сбоя второй. Разделять эти owner-наборы можно
только вместе с фактическим устранением общей runtime-границы из одной journey.

## Controlled fork и Full

Новый fork lock сначала имеет `compatibilityStatus=pending`. Его может
квалифицировать только `Full`/`Develop` с явным clean annotated-tag checkout:

Targeted Pester shards that include bootstrap update coverage resolve the
locked Vanessa source-build archive automatically: first from any worktree in
the common Git directory, then from a shared SHA-addressed cache, and finally
from the immutable locked URL. Every source is accepted only after the lock
SHA-256 matches; an invalid explicit environment path fails closed.

```powershell
.\scripts\check.ps1 -Mode Full -AiRulesSource D:\Git\itl_ai_rules_1c-r29-grilling
```

После успешного Full `scripts/promote-ai-rules-compatibility.ps1` сверяет exact
HEAD/tree, fork qualification и меняет только status/timestamp. Неявный Full и
Release требуют `compatibilityStatus=passed`.

## Release в master

```powershell
.\scripts\source-delivery.ps1 -Action ReleaseMaster `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r29-grilling `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Очередь должна быть пустой, а локальный `develop` совпадать с
`origin/develop`. Оркестратор включает отсутствующие изменения текущего
`origin/master`, получает/reuses Develop proof точного дерева, запускает
release-only E2E, затем без squash/force продвигает тот же commit в `develop` и
`master` и повторно читает remote refs.

`-Version itl-workflow-vX.Y.Z` отдельно создаёт annotated tag и GitHub Release
после успешного продвижения веток. Без `-Version` происходит только перенос в
стабильный канал.

Release сохраняет provenance/immutable dependencies, live MCP и Vanessa
isolation, `maxConcurrentSessions <= 3`, измеренный `ownedProcessExitWaitMs`,
snapshot rollback, config/extension roundtrip, fresh passed check, CF/CFE SHA и
cleanup. Он требует существующий Develop proof и не повторяет standard journeys.
При новом workflow-кандидате `Auto` переносит совпавшие capability proofs в
неизменяемый cache, создаёт новый rollback baseline/HEAD и всегда повторяет
свежую проверку, export и cleanup. `-ReleaseResumeMode Restart` остаётся
штатным полным rollback; state/status вручную не редактируются.
Если предыдущий Release остановился на конкретном этапе, а исправление меняет
только объявленный harness scope и прошло точный Targeted, `Auto` дополнительно
проверяет старый fingerprint с прежним runner SHA и переиспользует только целые
этапы до точки отказа. Упавший этап и весь downstream выполняются снова; cleanup
всегда свежий.

Git hooks автоматически не устанавливаются. GitHub Actions не являются
каноническим источником локальной квалификации; доказательства создают команды
выше и их SHA-проверяемые JSON/JUnit artifacts.

## Develop retry cache

`Develop` persists an exact-tree static qualification immediately after
Full/Pester and tracked-state checks pass, before starting live journeys. Each
successful `upgrade` or `fresh` journey is then saved atomically as a separate
SHA-verified exact-tree checkpoint, including the clean post-journey HEAD of the
master and dedicated Develop stand worktrees. If a later journey fails, the retry restores
both the static proof and every completed journey, then resumes with the first
missing journey. A different tree, environment/fork/stand/package identity,
missing evidence, or corrupt cache disables reuse for that evidence.
