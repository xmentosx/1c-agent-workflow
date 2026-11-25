# Причина MEMORY_APPLIED_CONTEXT_REQUIRED и исходный повтор

Последующим отдельным разрешением исправление выполнено у registry owner;
прежние native keep-local/default вызовы на том же пилоте прошли. Полный hash
guard не менялся. Итог этого прогона описан в разделе «Согласованное исправление»
ниже и имеет приоритет над историческим остатком analysis/replay.

## Граница исходного разбора

Разбор двух сохранённых отказов и повтор того же disable → enable на исходном
PM5/Windows11 пилоте. Source HEAD `6ac297e9`, установленный workflow `ac482fef`;
runtime-код, Cognee, корпус и правила ai_rules_1c не менялись. Новые сценарии,
тестовые случаи, самостоятельные gates, рабочая миграция и публикация не запускались.
Результаты регистрируются отдельно как documentation change.

## Подтверждённая причина в существующем владельце

Источник — `agent-1c.product-project-context.ps1`, ветка
`Test-ItlProductProjectPreviewAlreadyApplied` в `Initialize-ItlProductProjectContext`.
Это сохранение контекста после решения «уже применено», до обращения к Cognee.

1. После package update применённый контекст содержал
   `catalogIncludesClientSurfaces=true`: он подтверждает также клиентские surfaces.
   Обычный memory enable вызывает Startup без `-IncludeClientSurfaces`; его
   preview получает `catalogIncludesClientSurfaces=false`.
2. Existing AlreadyApplied допускает такой более узкий запрос: новый `false`
   не требует заменять прежде применённый `true`. Resolved hash не включает этот
   флаг, настройки/проект остаются теми же, клиентских изменений нет.
3. Однако shortcut оставляет `applied.context` прежним, обновляет `noOpInputs`,
   а в operation cache помещает **`chosen.context`** с `false`.
4. `Invoke-ItlMemorySetup` сравнивает полный hash operation context с сохранённым
   applied hash. Полные hashes различаются. `MEMORY_APPLIED_CONTEXT_REQUIRED`
   корректно останавливает enable; ослаблять этот guard оснований нет.

Сохранённый `before-operation.json.beforeApplied` содержит именно исходный
applied hash `9ddd45c252a7116ba774203e86f7f64b602290b42384d1b60c3ef03f39772fef`,
`catalogIncludesClientSurfaces=true` и `noOpInputs.includeClientSurfaces=false`.
Поздний фактический operation context в том же receipt отличается **только**
`catalogIncludesClientSurfaces=false`, его hash —
`7aa4461fcb1d139f984faff968bf958514653677803afb29c73bf607f7e07d1f`.
Read-only расчёт штатными canonical/hash-функциями над сохранёнными данными
даёт те же full hashes и одинаковый resolved hash `cad0d775…`.
Он не пишет в пилот и не является новым qualification case.

Механизм объясняет последовательность обоих исходных отказов:

- Первый обычный enable проходит через AlreadyApplied с новым узким preview и
  сохраняет `noOpInputs=false`, но оставляет applied context/hash с `true`.
- Повтор с явным `CatalogDecision=keep-local` отключает ранний no-op cache reuse,
  снова строит узкий preview и попадает в тот же shortcut/guard.
- Последующий обычный вызов уже может переиспользовать applied context через
  совпавший no-op cache. Поэтому диагностический запуск прошёл без исправления
  кода. Затем managed MCP writer сохранил согласованный контекст с `false`,
  и исходная команда без instrumentation также прошла.

У первых двух вызовов не были записаны переменные непосредственно в точке
исключения. Выше отдельно приведены сохранённые фактические контексты и вывод
из кода; вычисленный hash не объявляется native capture тех двух исключений.
Read-only диагностический breakpoint не был исправлением или обходом guard.
Отказ не доказывает сбой Cognee, модели, ключа или нехватку памяти сервера:
эта точка предшествует principal verification и записи memory binding.

## Повтор на том же пилоте

Root: `D:/Git/itl-workflow-e2e-pm5-workflow-release-e2e-preflight`.
Штатные public helper disable и исходный enable выполнены exit0 без breakpoint,
правки installed files, `CatalogDecision`, удаления receipt или reset базы.
Использованы прежние shared Qwen provider и установленный Kilo policy.

Новый stdio-сеанс по фактическому installed descriptor завершил тот же
`memory_status`: **current, pending[], 1.901s, process exit0**. Это существующий
setup/status сценарий; UI/model/frontend qualification им не подменяется.
Новые remember/retire/reindex и paired measurements не выполнялись.

Сохранены исходные cycle `e4e9f2a727144ddab36e3204c1f51aa6`, workspace
`d6ea5e665b4947beb334fa53c3ccd3bf`, workplace, профиль и Git HEAD пилота.
Raw SHA базы прежний:
`067ee2ac06b68459a75697e76cfca8785fa256c6444ebd8c56835120f854a534`.
Hashes source/installed memory-context и product-project-context совпадают.
Endpoint registry за время работы обновлял публикационные metadata;
проект/продукт пилота не менялись. Отдельная optional degradation `itl-1c-docs`
в disable log сохранена и не объявлена проверенной или исправленной.

## Остаток после исходного разбора

Успешный повтор на уже согласованном контексте не исправляет дефект shortcut.
Точечное предлагаемое исправление принадлежит registry owner: при подтверждённом
AlreadyApplied вернуть в operation cache **`applied.context`**, соответствующий
сохранённому receipt, вместо нового `chosen.context`. Нового apply/поля/кэша,
fetch, Cognee patch, исключения флага из memory hash или дополнительного guard
не требуется. Существующий полный hash guard должен сохраниться.

В этом analysis/replay прогоне runtime-исправление не выполнялось. Приёмка G3/G5,
пилотный QP5 и публикация ac482 не переоткрываются; устранение этого известного
дефекта остаётся отдельным конкретным действием до стабильного распространения.

## Согласованное исправление и тот же native сценарий

В `Initialize-ItlProductProjectContext`, только в AlreadyApplied shortcut,
`Set-ItlProductProjectOperationContext $chosen.context` заменён на
`Set-ItlProductProjectOperationContext $applied.context`. Прежде подтверждённый
receipt и context теперь остаются единым основанием вложенной memory операции.
`noOpInputs` по-прежнему обновляет существующий владелец. Новых schema/полей,
состояний, cache manager, fetch, guards и исключений из hash не добавлено.
**Весь `agent-1c.memory-context.ps1` побайтно совпадает с версией до исправления.**
Тестовые файлы, assertions, watchdog и исходные budgets не менялись.

Для чистого payload штатного updater был сохранён локальный runtime commit
`b088fa0e329634e237a1d3443cd1b94736d3835b`; его thin source bundle сохранён
как recovery input. Updater получил явный roots manifest только test master
и исходного Develop-пилота. Release-root, базы, ветки и прежние капсулы не
сбрасывались; installed memory первоначально отключена тем же владельцем.

После updater подтверждён **широкий applied context с true**, как при исходном
отказе. Повторён прежний вызов enable с `CatalogDecision=keep-local`:

- Read-only breakpoint в существующей ветке зафиксировал applied true / preview
  false; hashes различались (`e46dcb47…` и `c7656cae…`). Значит, затронутая ветка
  реально достигнута, а не пропущена ранним no-op кэшем.
- Read-only witness перед неизменным полным memory guard показал operation true,
  applied true и **operationHash = storedHash = appliedHash `e46dcb47…`**.
  Диагностика не изменяла runtime-код, контексты или результат сравнения.
- Existing helper завершил keep-local enable exit0. Затем исходный default
  enable повторён **без instrumentation**, также exit0.
- Новый stdio-сеанс по тому же installed descriptor: memory_status completed
  **2.022s**, current/pending[], process exit0. Это прежний setup/status сценарий;
  remember/reindex, UI/model qualification и новая матрица не добавлялись.

Cycle/workspace/workplace, shared Qwen profile и raw DB SHA `067ee2ac…` сохранены.
Installed context module совпадает по SHA с исправленным clean source payload;
memory guard file совпадает по SHA с before. Короткий default повтор не заменяет
отдельно записанное доказательство прохождения broad/narrow AlreadyApplied.

Итоговые документы добавлены amend только собственного незарегистрированного
runtime commit; executable bytes относительно native payload не изменялись.
Final head и единственный Targeted/результат регистрации читаются из штатного
source-delivery ledger. Source/installed proof и регистрация учитываются отдельно.
Ни публикация develop/master, ни рабочая миграция этим прогоном не выполняются.
В опубликованном ac482 этого позднего исправления ещё нет. Для стабильного
выпуска остаётся доставка зарегистрированного кандидата обычным release owner;
G3/G5/R6/QP5 и непройденные платформы/frontend не переоцениваются.

Ignored evidence исправления:
`build/agent-artifacts/memory-applied-context-fix-20261029/`.
Все прежние analysis/failed/пилотные sealed материалы сохранены.

Ignored evidence: `build/agent-artifacts/memory-enable-context-20261029/`.
Два исходных failed logs и прежний успешный diagnostic сохранены в sealed
`build/agent-artifacts/pilot-final-delivery-20261029/`, без перезаписи.
