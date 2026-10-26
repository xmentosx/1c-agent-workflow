# G5: завершение согласованного контура, 2026-10-27

## Итог и граница

Конечные N1–N7 выполнены в согласованном тестовом контуре общего подключения.
Остаток B03/B09/B10 и N5 закрыт; новых случаев и обязательных gates нет.
Пользователь заменил Cursor на Codex для продолжения. Cursor не запускался,
его окна, ввод, reload и новые ответы не использовались. Прежние результаты,
ошибки и sealed evidence сохранены; текущий результат их не переписывает.

Это завершение квалификации, а не разрешение внедрения или доказательство
преимущества Cognee перед файлами. Gate6/G6, рабочая миграция и публикация
workflow/fork/homes не выполнялись. R6 по-прежнему опубликован на
`0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`; qualification homes не публиковались.

## Матрица конечного плана

| Пункт | Результат | Область доказательства |
|---|---|---|
| N1 — шесть областей | PASS | Прежние native write/fresh exact original, общий обычный principal и exact mapping; без employee ACL |
| N2 — актуальность | PASS | Прежние точные correction/retire/body-loss и отсутствие дубликата; fragment не подменяет current original |
| N3 — lifecycle | PASS | Прежние initial cycle/reset/resume/history; новый процесс не делает старую runtime-проверку текущей |
| N4 — продукт и home | PASS | Прежние ERP→КОРП→допустимый ПРОФ, исключения и pending missing-home; только qualification homes |
| N5 — клиент и восстановление | PASS в описанном контуре | Прежние Kilo/Cursor tool/policy/offline/off/reload proof плюс текущие Codex required-gap, active cancel → pinned resume → owned restore → explicit enable → fresh original/recall на установленной PM5 |
| N6 — backup/restore | PASS | Прежний согласованный snapshot, проверка originals/поздних изменений до повторного admission; потери после T не скрываются |
| N7 — задачи и стоимость | Выполнено; преимущество не доказано | Исходные пары и исправленный B11 сохранены. Три оставшихся задачи прошли в Codex; это отдельное продолжение, не новая парная оценка Cursor/Grok |

Подробности прежних строк остаются у [единого common report](g5-common-continuation-2026-10-26.md).
PM4, Windows 10/Server/терминальные сессии и расширенная клиентская/выпускная
матрица не объявляются проверенными. OpenCode пропущен по решению пользователя.

## B03/B09/B10: нативное продолжение в Codex

Использован установленный Codex CLI `0.163.0-alpha.11`, текущая настроенная
модель `gpt-6.1-sol`, high. Три ephemeral read-only запуска, без shell, web,
субагентов, копирования авторизации или изменения глобальной конфигурации.
Исходные задания/эталоны сохранены; изменён только run key. Два прежних
fixture MCP tools исполняют текущий adapter против настоящего Cognee.

| Задача | Результат | Фактические tools | Время, s | Input / cached input / output tokens |
|---|---|---|---:|---:|
| B03 | PASS: rationale `project-rationale`, current original; причина двух несогласованных lookup | 2 recall, 1 exact original | 50.996 | 66492 / 59776 / 410 |
| B09 | PASS: `candidate-09` / FIXTURE-R09 применим к ПРОФ, home КОРП не запрещает использование | 2 recall, 1 exact original | 49.206 | 66853 / 60160 / 552 |
| B10 | PASS: `candidate-09` и `product-shared`; происхождение ERP не создаёт зависимости ERP | 2 recall, 2 exact originals | 45.019 | 66689 / 59776 / 729 |

Неприменимые знания и старый runtime proof не объявлены текущими; partial
coverage названа. Записей нет. Прежние budgets не менялись. Usage получен из
native terminal events; cached input — часть input, reasoning — часть output,
их повторно не суммируют. Денежная стоимость не вычислялась.

## Текущий пакет и установленная PM5

Штатный source-side updater завершился exit0/862.272s на обоих прежних roots
с workflow `6828b622d8542748c4294bfd066a6c5af41a7bc2`. Stand/topology/база,
старые стенды и failed snapshots сохранены; рабочих проектов это не касается.

Текущий source уже содержит объединённый r49
`df91727cc584a9b499cad1d9daa6ac22320486f9`. Откат к старому pin не выполнялся.
Четыре memory-файла r49 побайтно совпадают с прежним G5 candidate `162f2ea`;
прочитан существующий exact-commit Full receipt r49, новых Full/gates не было.
Для тестового обновления сохранён прежний fork и подготовлен отдельный clone
с новым неизменяемым qualification-only local ref. Использован существующий
dependency-selection/hotfix owner. Публичные template pin/status остаются
pending; публикация, перенос существующих tags и ручная правка installed
manifest/policy/dependency locks не выполнялись.

Отрицательные подготовительные попытки сохранены: pending-source refusal,
неверная UTF-8 декодировка оснастки, поглощение совпадающего release ref
workflow baseline и неверный origin нового local clone. Продолжение использует
явный local qualification ref, корректный UTF-8 и origin identity; guards не
обходились. Это подготовка source pair, не дефекты поиска Cognee.

## N5: фактическое завершение

Обычный disable сохранил данные. Codex вызвал local status и при
`TOOL_COGNEE=required`/disabled binding остановил только зависимое чтение,
обозначил incomplete coverage и выполнил независимую часть. Пустой успешный
поиск, fallback, replay и запись не заявлялись; elapsed26.687s.

При следующем explicit enable использован прежний PowerShell breakpoint
перед существующей проверкой отмены в settings loop. Runtime-файлы не менялись;
90-second timing pause сохранена. Первая оснастка остановилась до запуска
helper из-за двух одинаковых строк; исправлен выбор существующей точки,
не добавлен новый тестовый случай.

Операция `5b69c91f500f491785c189f06d166fb9` уже имела две подтверждённые
client-write receipts (`vibecoding1c`, `scoped-memory`). Публичный cancel
exit0/4.791s остановил активный writer с CATALOG_CANCEL_REQUESTED/partial;
resume exit0/13.270s завершил тот же pinned plan; owned restore exit0/12.907s
вернул прежний applied context и client configuration. Ручных receipt edits,
убийства процессов, новых recovery owners и backend writes не было.

Первое post-update startup нормализовало owned Cursor memory script path из
source checkout в установленную ветку. Первоначальная проверка полного
pre-startup hash поэтому остановилась; её результат сохранён. Read-only
реконструкция только прежнего значения этого аргумента дала точный исходный
SHA256 файла. Остальные байты, другие MCP и настройки не изменены; в самом
cancel/resume/restore Cursor config byte-identical к disabled baseline.
Запуск/проверка Cursor и ручная правка его настроек не выполнялись.

После restore клиентских настроек штатно повторён explicit enable: это
продолжение opt-in, а не ручное восстановление private binding. Identity,
cycle и exact dataset IDs сохранены. Свежий Codex process вызвал local status,
точный original и один bounded recall; `g5-n1-workspace`, data ID
`e6cf67d5-db9f-4149-9cf5-a041579b1c2c`, durable/verified/applicable, получен
без замены ID. Recall вернул тот же факт, partial coverage названа, elapsed45.980s.

Для этих N5 model checks Codex CLI потребляет фактический установленный stdio
descriptor с существующим Kilo-owned policy proof; policy прочитана из
установки и проверена frontend. Это native Codex consumer, но не новая
квалификация автоматического Codex GUI attachment или client membership.
Прежняя Kilo/Cursor qualification остаётся отдельным доказательством.

## Что установлено о пользе

Исходное сопоставление остаётся отрицательным: на 11 непротиворечивых задачах
files11/11 против Cognee5/11; median63.079s против111.5265s. Exposed response
bytes114622 против60201 не доказывают экономии токенов/денег. После source
repair прежний follow-up дал9/12, а остальные три задачи теперь решены другим
клиентом/моделью. Складывать это в новый paired score12/12 или приписывать
новому варианту прежние timings нельзя. Нового сравнительного прогона нет.

Итог: функциональные дефекты исходного конечного набора закрыты. Пригодность
общей памяти, scope/currentness и recovery проверены в этом профиле;
ускорение, экономия и преимущество над файлами не доказаны. Internal LLM/
embedding usage и часть полной денежной стоимости остаются unknown.
Расширение rollout без доказанной пользы требует отдельного явного trade-off.

## Evidence и остаток до выпуска

Ignored root: `build/test-results/g5/common-20261026-112117/Codex-continuation/`:
native events/answers/usage, three-case review, fork pair, qualified dependency
selection, N5 cancellation receipts, before/disabled/restored/final states,
exact-byte normalization proof и recovery result. Сводка и hashes находятся
в `final-proof.json` / `evidence-manifest.json`. Исходный sealed `g5-result.json`
не заменён. Source registration проверяется через RegisterChange/Status,
отдельно от native proof; эта документальная фиксация не запускает новые gates.

До выпуска остаются отдельно разрешённые Gate6/G6, решение о rollout с
неподтверждённой сравнительной выгодой, выпускная qualification за пределами
этого контура, штатное назначение/допуск production homes и публикация
совместимого fork/workflow. Рабочая миграция не начата. Registry R6 и принятый
G3 не переоткрываются.
