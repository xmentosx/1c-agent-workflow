# Direct full-cycle в ветке разработки

Используйте этот reference после того, как upstream `AGENTS.md` и `verification-policy.md` определили `executionPath=full-cycle`, а границы, решение и критерии приёмки достаточно ясны для `planningMode=direct`. Promotion trigger или высокий verification risk усиливает проверки, но сам по себе не требует OpenSpec.

## Общее правило готовности

Здесь `itldev/*` означает текущее имя Git-ветки (`git branch --show-current`), а не каталог или файловый glob. В такой ветке любая доработка агентом под настроенными `exportPath`/`extensionsPath` считается готовой только после релевантных сценариев под `testsPath` и fresh passed `/itl-check`; direct full-cycle исключений не даёт. Явно выбранный ITL lite допускает только partial evidence с формулировкой `implemented; executable verification skipped`. На `master` правка исходников остаётся branch-safety blocker.

Перед тестами алгоритма агент читает `references/yaxunit-tests.md`; перед Vanessa-тестами — `references/vanessa-tests.md`. Слой с режимом `off` автоматически не создаётся. Пропуск никогда не называется `готово/verified/done`; при `verificationPolicy=block` он блокирует result/close, при `warn` требует явного подтверждения partial result.

## Процесс

Direct full-cycle использует полный upstream процесс анализа, точечного изменения и применимых проверок, но не создает OpenSpec-артефакты.

Перед изменением агент записывает:

```text
executionPath=full-cycle
planningMode=direct
Reason: <promotion trigger или причина выхода за quick-fix>; scope and solution are clear.
```

После реализации действуют релевантные YAxUnit-тесты границ, Vanessa-сценарии интеграции/UI и один финальный fresh passed `/itl-check`. Высокий verification risk усиливает проверки, а не создает proposal автоматически.

Финальный `/itl-check` выполняется после последней правки и принадлежит helper: он обновляет копию базы текущей ветки, запускает YAxUnit, Vanessa Automation через `TESTMANAGER -> TESTCLIENT`, читает JUnit и проверяет event-log baseline. Не заменяйте его MCP, headless EPF или `/deploy-and-test`.

Если проверка упала, проанализируйте отчёт Vanessa, лог 1С, event-log evidence и изменённый код; исправьте причину и повторите полный helper-owned цикл. Лимит recovery — три полных неуспешных запуска одной repair session, после чего нужно вернуть blocker diagnostics и не заявлять completion.

Только после fresh passed `/itl-check` можно переходить к `/itl-result` или заявлять готовность. При partial/skipped evidence применяйте `verificationPolicy`; такой результат никогда не становится normal fresh pass.
