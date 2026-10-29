# Direct full-cycle в ветке разработки

Используйте этот reference после того, как upstream `AGENTS.md` и `verification-policy.md` определили `executionPath=full-cycle`, а границы, решение и критерии приёмки достаточно ясны для `planningMode=direct`. Promotion trigger или высокий verification risk усиливает проверки, но сам по себе не требует OpenSpec.

## Общее правило готовности

Здесь `itldev/*` означает текущее имя Git-ветки (`git branch --show-current`), а не каталог или файловый glob. В такой ветке доработка под `exportPath`/`extensionsPath` проходит оценку применимых обязательств и fresh passed `/itl-check`; `testsPath` хранит сохраняемые тесты, а достаточное one-off proof не требует фиктивного файла теста. Запущенный runner с zero tests, invalid JUnit или failure остаётся ошибкой. На `master` правка исходников остаётся branch-safety blocker.

Перед тестами алгоритма агент читает `references/yaxunit-tests.md`; перед Vanessa-тестами — `references/vanessa-tests.md`. Режим `off` запрещает автоматический запуск, но не создание теста и не повторное использование уже свежего достаточного proof. При отсутствии такого proof пропуск остаётся partial: `verificationPolicy=block` блокирует result/close, `warn` допускает экспорт с предупреждением; закрытие ветки требует отдельного подтверждения.

## Процесс

Direct full-cycle использует полный upstream процесс анализа, точечного изменения и применимых проверок, но не создает OpenSpec-артефакты.

Перед изменением агент записывает:

```text
executionPath=full-cycle
planningMode=direct
Reason: <promotion trigger или причина выхода за quick-fix>; scope and solution are clear.
```

После реализации получите достаточные доказательства по `verification-change.md`: применимые существующие или новые проверки, включая допустимое разовое наблюдение. Итоговую готовность оценивает финальный fresh passed `/itl-check`. Высокий verification risk усиливает необходимые проверки, а не создает proposal или дублирующий набор автоматически.

Финальный `/itl-check` выполняется после последней релевантной правки и принадлежит helper: он определяет необходимые обновление копии базы, запуски выбранных YAxUnit и Vanessa Automation через `TESTMANAGER -> TESTCLIENT`, проверку JUnit и event-log baseline, учитывая применимые сохранённые доказательства. Интерактивное MCP-подтверждение не требует дублирующего файла-теста, но не заменяет итоговую helper-оценку. Не заменяйте её headless EPF или `/deploy-and-test`.

Если проверка упала, проанализируйте отчёт выбранного runner, лог 1С, event-log evidence и изменённый код; исправьте причину и повторите полный helper-owned цикл. Повторные запуски и применимость доказательств определяет helper; не повторяйте вручную незатронутые наблюдения. Лимит recovery — три полных неуспешных запуска одной repair session, после чего нужно вернуть blocker diagnostics и не заявлять completion.

Заявлять проверенную готовность можно только после fresh passed `/itl-check`. Для `/itl-result` при partial/skipped evidence применяйте `verificationPolicy`; такой результат никогда не становится normal fresh pass.
