# Процесс разработки внутри ветки разработки

Этот документ — router для работы внутри уже созданной `itldev/*` ветки. Он объясняет lifecycle-поверхность и помогает выбрать один конечный reference. После выбора режима откройте только соответствующий файл:

- `dev-branch-quick-fix.md`: `executionPath=quick-fix`, `planningMode=direct`;
- `dev-branch-direct.md`: `executionPath=full-cycle`, `planningMode=direct`;
- `dev-branch-openspec.md`: `planningMode=OpenSpec`, а `executionPath=quick-fix|full-cycle` выбирается независимо.

Допустимы все четыре сочетания двух осей. `direct` — planning mode по умолчанию. Promotion trigger меняет только `executionPath` на `full-cycle` и сам по себе не выбирает OpenSpec.

Роли `ai_rules_1c` разработчик вручную не выбирает. Агент сам выбирает внутреннюю специализацию по задаче.

## Как запускать действия

Жизненный цикл ветки запускается через ITL-поверхность активного клиента; точные команды, skills или prompts показывает `/itl`:

```text
vibecoding1c-mcp helper action            Настроить, запустить, обновить или проверить vibecoding1c MCP текущего scope.
/itl-status                       Показать текущую ветку, базу и статус проверки.
/itl-check                        Обновить базу ветки и запустить Vanessa Automation.
update-base helper action                  Обновить базу ветки без тестов.
verify helper action                       Совместимый alias для /itl-check.
/itl-refresh                      Обновить ветку разработки свежим master.
/itl-sync-master                  Обновить master и принудительно пересоздать latest-only seed.
/itl-refresh-lite                 Обновить ветку из текущего master без обращения к source и seed.
/itl-result                       Выгрузить CF/CFE по текущей ветке.
```

Например, в Kilo Code upstream-native OpenSpec-процесс запускается отдельными slash-командами:

```text
/opsx-propose                     Обычный первый шаг: подготовить proposal, design/tasks/test-plan/spec deltas; код не менять.
/opsx-apply                       Реализовать согласованный OpenSpec change по tasks.md.
/opsx-archive                     После приемки заархивировать OpenSpec change.
/opsx-explore                     Опционально (optional): исследовать задачу или код до proposal, если контекста недостаточно.
```

Это только пример `native`-режима. `/itl` определяет режим по managed manifest и показывает синтаксис активного клиента. В `natural`-режиме используйте обычные запросы:

```text
Исследуй задачу в режиме OpenSpec, не создавая proposal и не меняя код
Подготовь OpenSpec proposal для <изменение>; создай proposal, design, tasks, test-plan и spec deltas; код не меняй
Реализуй согласованный OpenSpec change <change-id> по tasks.md и test-plan.md
Заархивируй принятый OpenSpec change <change-id> и синхронизируй specs
```

Оба режима используют один `openspec/` workspace, общий preflight и fresh `/itl-check`. Отсутствие внешнего `openspec` executable не блокирует natural flow. Не устанавливайте пакет автоматически и не запускайте `openspec update`.

В Codex рутинные действия доступны как явные skills:

```text
$itl-check
$itl-refresh
$itl-result
```

`$itl` показывает только действия текущего контекста. Обычный текст остается для разработки, объяснений, инициализации и нестандартного восстановления.

Команды жизненного цикла ветки выполняются через `/itl-*` или естественные текстовые команды. Роли остаются внутренней логикой агента.

`/itl` в ветке разработки показывает не просто список команд, а процессную панель: состояние ветки, рекомендуемый следующий шаг, путь разработки, реальные native OpenSpec entrypoints либо точные natural-запросы и дополнительные helper-действия. В свежей чистой ветке с `verification missing` независимо выбирают upstream execution path `quick-fix|full-cycle` и planning mode `direct|OpenSpec`; `direct` остаётся default. `/itl-check` выполняется после появления проверяемых изменений или когда предыдущая проверка stale/failed/unknown.

`vibecoding1c-mcp helper action` в worktree текущей `itldev/*` ветки подключает выбранные vibecoding1c MCP endpoints. Если для `code` или `graph` выбран local branch scope, helper поднимает отдельный vibecoding1c MCP для текущей ветки. vibecoding1c MCP соседних веток в client config не добавляются; Vanessa UI MCP доступен отдельно как предзарегистрированный stdio-сервер `itl-vanessa-ui` и запускает приватный backend по первому вызову без helper action или raw HTTP.

Обычно агент собирает параметры в master и helper выполняет отдельную транзакционную инициализацию внутри общего сценария создания extension-ветки. Если параметры при создании были неизвестны, состояние ветки остаётся `pending`: при первом обращении агент должен спросить, создать пустое расширение или загрузить CFE, получить имя и при необходимости путь к CFE, затем сам вызвать внутреннее действие:

```text
init-dev-branch-extension -ExtensionInitMode Empty -ExtensionName <имя-расширения>
```

Для готового CFE:

```text
init-dev-branch-extension -ExtensionInitMode Cfe -ExtensionName <имя-расширения> -ExtensionSourcePath <файл.cfe>
```

Эти строки описывают внутренний helper-контракт, а не команды для разработчика. Helper создаёт snapshot базы, загружает расширение через Designer с `-Extension`, выгружает нормализованные исходники строго в `src/cfe/<имя-расширения>` и откатывает базу при ошибке. CFE не распаковывается; Designer Agent и `AgentMode` не используются. `set-dev-branch-extension` только записывает recovery-контекст для расширения, созданного вручную, а `dump-dev-branch-extension` остаётся recovery-выгрузкой. До статуса `ready` все действия разработки блокируются. Дальше `/update1cbase` — обычный цикл разработки, `/itl-check` — обязательная проверка, `/itl-result` — выгрузка `CFE`.

В configuration-ветке допустимы несколько фич. В extension-ветке тоже допустимы несколько фич/OpenSpec changes, но все они должны относиться к одному расширению. Для второго CFE создавайте отдельные ветку, worktree и копию базы: workflow намеренно не хранит `extensions[]`. Изменённый второй корень `src/cfe/<ДругоеИмя>` блокирует update/check/dump/result/close кодом `EXTENSION_BRANCH_SINGLE_ARTIFACT`; неизменённые baseline-каталоги не мешают.

Команды жизненного цикла автоматически активируют контекст базы ветки разработки для `ai_rules_1c`.

`/deploy-and-test` сохранён как bridge к тому же `check-dev-branch`; собственного пути загрузки у него нет. Обычное имя ITL-цикла — `/itl-check`. Если нужно только обновить базу без тестов, используйте `update-base helper action`.

After a real file load, `/itl-check`, `update-base helper action`, `verify helper action`, `/itl-refresh`, `/itl-result`, and advanced `close-dev-branch` automatically launch the branch infobase in Enterprise user mode through bundled `ДляАвтоматическогоОбновленияИБ.epf`. This applies update handlers and answers the legal-copy prompt non-interactively. No-op updates do not launch Enterprise.

## Общее правило готовности

Здесь `itldev/*` означает текущее имя Git-ветки (`git branch --show-current`), а не каталог или файловый glob. В такой ветке любая доработка агентом под настроенными `exportPath`/`extensionsPath` считается готовой только после релевантных сценариев под `testsPath` и fresh passed `/itl-check`; quick-fix, direct full-cycle и OpenSpec исключений не дают. Явно выбранный ITL lite допускает только partial evidence с формулировкой `implemented; executable verification skipped`. На `master` правка исходников остаётся branch-safety blocker.

Перед созданием или правкой Vanessa-тестов агент читает `references/vanessa-tests.md`. При `ITL_VANESSA_TESTING=off` новые тесты автоматически не создаются и в новый план не добавляются. Пропуск никогда не называется `готово/verified/done`; при `verificationPolicy=block` он блокирует result/close, при `warn` требует явного подтверждения partial result.

Для больших OpenSpec changes действует hybrid cadence: каждый срез с наблюдаемым поведением получает минимум один focused Vanessa scenario и дешёвые targeted/static checks, но промежуточный `/itl-check` нужен только на milestone, где runtime-результат решает, можно ли продолжать реализацию. Подготовительные tasks фиксируются как pending verification. После последней verification-relevant правки обязателен fresh unfiltered `/itl-check` по всему разрешённому набору сценариев.

## Как выбрать режим

Сначала примените upstream `AGENTS.md` и `verification-policy.md` без downstream-переопределений. Используйте **quick-fix**, если выполняются все условия:

- проблема понятна;
- изменение локальное;
- затрагивается один модуль либо новая полностью неподключенная добавка метаданных, прямо разрешенная upstream policy;
- не меняется бизнес-процесс;
- не меняется публичный интерфейс модулей;
- нет upstream promotion trigger;
- не требуется согласование архитектуры или подхода.

Примеры quick-fix:

- исправить синтаксическую ошибку;
- поправить условие;
- исправить имя переменной;
- убрать падение в конкретной процедуре;
- добавить простую проверку на `Неопределено`;
- исправить текст сообщения;
- поправить запрос без изменения бизнес-смысла.

Используйте **direct full-cycle**, если quick-fix неприменим, но границы, решение и критерии приемки ясны. Например:

- изменение существующей формы или wired metadata;
- транзакционный, write/posting или RLS-путь с уже определенным ожидаемым результатом;
- несколько связанных мест с однозначным способом реализации;
- публичный контракт, требования к которому уже согласованы.

Используйте **OpenSpec**, когда пользователь явно его запросил либо нужно формально исследовать и согласовать требования, архитектуру, критерии приемки или этапы реализации. Promotion trigger меняет только execution path, а риск регрессии усиливает проверки; ни то ни другое само по себе не требует OpenSpec. При сомнении между direct и OpenSpec оцените необходимость согласования, а не количество файлов.

После выбора откройте ровно один matching reference из списка в начале этого файла. Не читайте остальные пути «на всякий случай».

## Короткая памятка

```text
Маленькая локальная ошибка без promotion triggers и без OpenSpec -> direct quick-fix -> dev-branch-quick-fix.md.

Понятная правка существующей формы, связанных метаданных, нескольких модулей или risk-bearing пути -> direct full-cycle -> dev-branch-direct.md.

Нужно формально исследовать или согласовать требования, архитектуру либо критерии приемки -> planningMode OpenSpec; execution path выбирается независимо -> dev-branch-openspec.md.

Роли вручную не выбираем. Агент сам выбирает внутреннюю специализацию по задаче.

После изменений запускайте единый цикл проверки: /itl-check.

Если предыдущая доработка могла пропустить релевантный сценарий или полный цикл проверки, используйте `/itl-verify-fix`. Команда сначала ищет подходящее существующее покрытие и не создаёт новый тест без необходимости; затем исправляет тест или реализацию и повторяет полную проверку до pass либо лимита трёх попыток.

Если нужно только обновить базу без тестов: update-base helper action.

Стандартная проверка идет через `/itl-check`; `verify helper action` остается совместимым alias.

Если Vanessa нашла ошибку, агент сам исправляет ее и повторяет /itl-check. Лимит - 3 попытки.

CF/CFE текущей ветки: /itl-result.
```
