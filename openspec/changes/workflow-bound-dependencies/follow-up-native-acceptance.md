# Отдельный нативный прогон

Пользователь явно перенёс нативную приёмку на отдельный прогон после отказа
лицензии 1С, 2026-10-14. Это не успешная runtime-приёмка и не Release qualification.

Остались fresh init, подготовка CFE, реальные ROCTUP/Vanessa calls с проверкой
tools/list и новый клиентский контекст после обновления contributions. Полный
live-сценарий с одновременно свободной и занятой рабочими ветками также требует
завершения штатного fork, остановленного проверкой готовности ИБ.

## Сохранённые препятствия

1. Платформа `C:\Program Files\1cv8\8.3.27.2130\bin\1cv8.exe` при Gate 6 snapshot
   для `update-dev-branch-base` вернула «Не найдена лицензия. Не обнаружен ключ
   защиты программы или полученная программная лицензия!». Editable load не
   выполнялся. Лог: `branch/logs/1c/1c-20261013-235221-421-63944-8567e6ca.log`.
2. Fresh bootstrap дошёл до `seed.copy-artifact`, затем отказал с
   `BRANCH_SEED_SOURCE_ARTIFACT_MISSING`: фабрика перенесла SOURCE_INFOBASE_PATH
   в owned project, но не материализовала там исходный `1Cv8.1CD`. Это дефект
   владельца `scripts/source-e2e-fixture.ps1`, а не подтверждение init.
   Root: `C:\itlj\p Проект\d-deps-f37a26a8`; run
   `20261013-235250-687-4780-abba6b1d`, status failed / exitCode 1.

Fixture receipt: `build/dependency-live/fixture-fixed.json` в checkout
`C:\Users\xment\.codex\worktrees\workflow-dependencies\1c-agent-workflow`.
Project и branch находятся под
`C:\itlj\q Проект\develop-c2c570fe1ec5-517ecc0e4e04-44bd936f`.
После проверенного rollback master содержит test candidate `517ecc0e`,
ветка — `18f2dffb` с явным rules42 hotfix; оба tracked trees чистые.
Все native attempt logs и файловые acceptance records — в `build/dependency-live`.

## Продолжение

Восстановить доступ к лицензии, исправить owning fixture preparation с регрессией
на исходный fresh-init путь и пройти прежний workload через штатные helpers.
Не редактировать installed fork, status/transaction receipts и не обходить
готовность ИБ. Результат source/unit tests не заменяет отсутствующие runtime calls.
Не переносить сюда производственные ИБ и не менять platform/workload, чтобы
скрыть исходный отказ. При повторе bootstrap сохраняется его штатный monitored
маршрут и четырёхчасовой бюджет.
