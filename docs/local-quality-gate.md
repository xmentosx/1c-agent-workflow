# Проверки и доставка исходного workflow

Обычная доработка не запускает общий gate. Агент создаёт один связный локальный
коммит и регистрирует его:

```powershell
.\scripts\source-delivery.ps1 -Action RegisterChange `
  -CoverageContract <existing-contract-id>
```

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

`Targeted` и `Full` хранят успешные Pester-шарды в `.git/itl/pester-shards/v1`. Reuse возможен
только при совпадении тестов шарда, всех входов их контрактов, общих runner/locks,
версий PowerShell/Pester и identity controlled fork/Vanessa build. Неизвестный
владелец теста отключает кэш для шарда. Провальные результаты не кэшируются.

## Публикация develop

```powershell
.\scripts\source-delivery.ps1 -Action PublishDevelop `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r23-rebuild `
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
локального `develop` и только зарегистрированных диапазонов, запускает один
`Develop`, выполняет обычный fast-forward push без force и сверяет удалённый
SHA/tree. Конфликт, сдвиг remote или ошибка gate сохраняют очередь.

Develop journey используют публичные поверхности workflow:

- обновление установленного N-1 стенда через `update-workflow`;
- refresh активной ветки, реальный `/itl-check`/Vanessa и экспорт результата;
- свежий bootstrap и `init-project` в коротком disposable-пути;
- `new-dev-branch`, минимальная конфигурационная правка и application feature;
- check, stale-result boundary через изменение feature без повторной загрузки
  конфигурации в Designer, recovery check, result, `refresh-dev-branch-lite`,
  повторный check и close.

Qualification `develop.json` связывает точный tree с SHA статического Full и
live-отчёта. Повторное использование допускается только для exact/ancestor
same-tree доказательства с тем же inventory.

## Controlled fork и Full

Новый fork lock сначала имеет `compatibilityStatus=pending`. Его может
квалифицировать только `Full`/`Develop` с явным clean annotated-tag checkout:

```powershell
.\scripts\check.ps1 -Mode Full -AiRulesSource D:\Git\itl_ai_rules_1c-r23-rebuild
```

После успешного Full `scripts/promote-ai-rules-compatibility.ps1` сверяет exact
HEAD/tree, fork qualification и меняет только status/timestamp. Неявный Full и
Release требуют `compatibilityStatus=passed`.

## Release в master

```powershell
.\scripts\source-delivery.ps1 -Action ReleaseMaster `
  -AiRulesSource D:\Git\itl_ai_rules_1c-r23-rebuild `
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
isolation, snapshot rollback, config/extension roundtrip, fresh passed check,
CF/CFE SHA и cleanup. Он требует существующий Develop proof и не повторяет
standard journeys. `-ReleaseResumeMode Restart` остаётся единственным штатным
началом нового checkpoint; state/status вручную не редактируются.

Git hooks автоматически не устанавливаются. GitHub Actions не являются
каноническим источником локальной квалификации; доказательства создают команды
выше и их SHA-проверяемые JSON/JUnit artifacts.
