# G3: согласованная приёмка и остаток до выпуска

Решение пользователя от 2026-10-25: **G3 принят и закрыт в проверенном PM5-контуре**. Эта граница едина для add-product-project-registry и add-scoped-cognee-memory. Она заменяет прежнее требование держать весь G3 открытым до полной платформенной/client/lifecycle матрицы. Исторические отчёты, failures и незакрытые агрегатные checkbox ниже в документах сохраняют факт на дату записи, но не определяют текущий статус G3. Непроверенные клетки не становятся PASS, заявленная поддержка не сокращается.

## Принятый контур

PM5, локальный Windows 11, Kilo и Cursor; Codex принят только в доказанной core/API области. Приёмка опирается на существующие результаты разных зафиксированных срезов; это не утверждение, что все клиенты и сценарии повторены на одном последнем commit. Последний G3-LD1 повтор и регистрация выделены отдельно.

| Область | Итог и доказательство |
|---|---|
| Каталог, выбор/ассоциация, обновление контекста | Принят проверенный installed PM5 subset: rename, typical/custom, замена/удаление СППР/Mantis links, functionality/home; [metadata proof](evidence/g3-project-metadata-functional-2026-10-24.md) |
| Различия проекта и MCP-источника | Registry model и custom → typical / ПРОФ → КОРП приняты; название/версия/индексация из registry, обязательных патчей Code/Graph нет; [source model](evidence/g3-registry-source-model-2026-10-21.md) |
| Нативные Code/Graph | Kilo/Cursor IDE reads/reload приняты в [current PM5 proof](evidence/g3-pm5-native-clients-2026-10-24.md); Codex useful reads/deny/reload/new thread — только [core/API](evidence/g3-remaining-qualification-2026-10-24.md), без Desktop/model UI |
| BookStack, СППР, Mantis | Серверные scopes/negative controls, exact links и routing/writer operation-ID fixtures приняты в [матрице](evidence/g3-final-qualification-2026-10-20.md). Реальное создание Mantis не выполнялось и не объявляется PASS; оно не является новым требованием закрытия G3 |
| Конфликты, custom/disabled MCP, offline | Приняты проверенные PM5 пути с сохранением пользовательских настроек; [owner repair](evidence/g3-owned-mcp-defer-repair-2026-10-22.md) и последующая [итоговая квалификация](evidence/g3-completion-2026-10-23.md) |
| Транзакции и восстановление | Приняты выполненные cancel/partial/pinned resume/owned restore, damaged receipt, same-user concurrency и foreign-edit/byte-preservation пути; [итоговый PM5 proof](evidence/g3-completion-2026-10-23.md). Это не покрытие всех возможных fault combinations |
| Legacy PM5 | Первый unattended update, поздняя ассоциация и compatibility restore приняты на отдельной capsule-копии; [lifecycle proof](evidence/g3-pm5-lifecycle-2026-10-24.md). Capsule не заменяет fresh init или currentness отсутствующего original live seed |
| Managed downgrade / G3-LD1 | Исходный direct downgrade main+sibling принят: exit0, clean/pending0, exact old helpers/pins, CF/DB/history сохранены; [integrated native proof](evidence/g3-legacy-executor-integrated-2026-10-25.md). Прежние downgrade blockers закрыты |
| Startup/cost | Существующие warm и dynamic результаты сохранены; [cost repair](evidence/g3-publisher-cost-repair-2026-10-24.md). Допустимое пользователем превышение warm median 49.731 мс — ACCEPTED DEVIATION, не PASS порога и не повод продолжать оптимизацию ради закрытия G3 |
| Регистрация реализации | Source head bf5a46e6ff84a355f603578ea98e3f77631ec32d принят в product-project-registry-g2; Targeted 1833 passed / 0 failed / 0 skipped. Native implementation 7ba9f0a3 и регистрация разделены; текущая документационная регистрация — отдельная запись штатного delivery ledger |

На этой границе незакрытых воспроизведённых функциональных блокеров G3 нет. Новые сценарии автоматически не добавляются. Конкретный новый дефект или расширение квалификации требуют отдельной постановки; регистрация документации по обычному source-delivery с Targeted не является новым G3 canary.

## Отдельный остаток до выпуска

Это конечный открытый список для выпускной квалификации, а не продолжение закрытого G3. Отсутствие стенда означает UNVERIFIED, а не PASS. Подготовка стендов и исполнение требуют отдельного поручения; запрет Gate 6 не обходится.

| ID | Открытая работа | Условие готовности |
|---|---|---|
| R1 | Реальная изолированная установленная PM4 | Installed proof; существующие PM4 source/file fixtures не заменяют стенд |
| R2 | Windows 10 / Server 2019+, терминальные и независимые пользовательские сессии | Platform/session evidence при сохранении заявленной поддержки; same-user Win11 proof не переносится автоматически |
| R3 | Full fresh init, положительные new branch/fork/refresh, оставшиеся foreground choose/create/later пути | Исходные lifecycle задачи завершены штатными владельцами, включая отдельный допуск к затрагиваемому Gate 6; недоступный live seed не подменён capsule currentness |
| R4 | Codex Desktop/model UI, остальные native clients и полная platform/lifecycle матрица | Реальные activation/read/reload доказательства для соответствующего выпускного охвата. OpenCode SKIPPED по решению пользователя и не блокирует принятый G3; пропуск не является PASS или удалением поддержки |
| R5 | Остальные cold/remote/platform/client cost области | Отдельная выпускная оценка с честной областью измерений; без нового runtime SLA и без повторов ради уже принятого небольшого warm превышения |
| R6 | Обязательное наполнение реестра: AC-36–38 / memory AC-44 | Owner-confirmed выпускной перечень продуктов/проектов, MCP/СППР/Mantis настройки, различия проекта/источника, карта функциональности/ограничений/home и точный опубликованный SHA согласованных catalog/relations/endpoint файлов; pilot/synthetic записи недостаточны |

R6 — обязательный блокер первого выпуска каталога и первого выпуска памяти. R1–R5 остаются явными выпускными qualification obligations; их нельзя молча зачеркнуть или использовать эту приёмку как полную платформенную сертификацию. При недоступности доказательства решение принимается отдельно перед выпуском, поддержка автоматически не сокращается.

Реальная внешняя запись Mantis и standalone unavailable-executor/fault combinations не доказаны; это ограничения доказательств, а не новые автоматически назначенные сценарии. Выпускные действия выполняются только по обычному отдельно разрешённому delivery процессу.

## Связь с памятью и границы разрешения

Зависимость «принятый installed registry G3» закрыта только в описанном контуре. Это не завершение memory consumer 4.2, G4, G5 или memory AC-43 целиком. G1/Q1–Q7, G2, D9, шесть областей, единый resolver/applied snapshot, canonical knowledge home, optional OpenViking и ownership ai_rules_1c не изменены. Для иных платформ/клиентов наследуется R1–R5; память не создаёт второй updater или вторую матрицу реестра. Наполнение AC-44 использует единый R6.

G4, рабочая миграция, Gate 6, публикация/push/PR этим решением не разрешены. OpenSpec changes не архивируются: в registry остаётся выпускной остаток, в memory — ещё не реализованные потребитель и native acceptance. Исторические доказательства и sealed artifacts не изменяются.
