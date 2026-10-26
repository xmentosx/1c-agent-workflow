# G5: конечный план совместной квалификации

Статус 2026-10-26: **подготовлен для согласования; G5 не начат**. Разрешена
только подготовка плана. Подготовка/запуск стенда, homes/grants, импорт корпуса,
native/installed сценарии и измерения ниже — будущие действия после отдельного
разрешения. Gate 6, рабочая миграция и публикация workflow исключены.

## Основание и конечный объём

G4 зарегистрирован: workflow `17061155f12c1c39df37eb3564f919edd994b811`;
source candidate `3633f1eec31aa6aa8b1e98168be08bbbc815190b`, Targeted passed.
[Source-матрица G4](evidence/g4-source-implementation-2026-10-26.md) отделяет
fixtures от ещё не выполненного G5. G3 закрыт в согласованном контуре;
[R6](../add-product-project-registry/evidence/r6-publication-2026-10-25.md)
опубликован SHA `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`. Сейчас в нём
нет назначенных `memoryHomeProductId`; это допустимый registry-only результат.

Предлагаемый конечный контур G5: отдельная PM5-копия, Windows 11/PS5.1,
Kilo VS Code и Cursor с реальными tool calls/reload; Codex — core/API,
без заявления о native агенте. OpenCode — SKIPPED по решению пользователя.
PM4, Windows 10/Server и реальные terminal sessions остаются UNVERIFIED,
поддержка сохраняется. Они перечисляются в выпускном остатке, а не добавляются
по ходу этого прогона. Новый обязательный случай требует отдельного решения.

Это организация существующих задач **6.2–6.4/6.6b**, AC-01–44, D8/D10,
а не новый gate, расширение G3 или пересмотр Q1–Q7. Общая матрица имеет строки
ниже и статусы PASS / FAIL / BLOCKED / UNVERIFIED / SKIPPED, ссылки на actual
evidence, тип source/fixture/native/client и exact inputs. Конфигурация,
tools/list и успешная регистрация сами по себе native PASS не дают.

## 1. Зафиксировать входы и изолировать стенд

| Вход | План подготовки после разрешения G5 | Критерий допуска зависимого шага |
|---|---|---|
| Cognee | Использовать прежний isolated Docker стенд **dev-karimov**, обычный loopback `18190`, отдельный admin `18191`; доступ только через настроенный защищённый канал. Перед запуском проверить actual deployment, занятость и сохранность прежних volumes/evidence. Текущая доступность не проверялась | Зафиксированы instance ID, endpoint, digest/schema/auth/models/resource limits; действующие сервисы/данные не заменены. Admin port закрыт обычным клиентам |
| G1 profile | Cognee **1.6.5**, image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`, OpenAPI SHA `b863f72d912c07ceb4bb914d790152659427c0ad33863d553d38b5fa64e24171`; qualification SHA `be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d` | Оператор сверил фактический профиль, не только settings label. Сохраняются GLiNER demo / fastembed `BAAI/bge-small-en-v1.5`, 384 dims, auth/ACL, `self_improvement=false`, без improve/background jobs. При отличии повторяется только затронутая capability Q, с решением о новом профиле, а не молчаливый reuse |
| Ресурсы | Начальный предел прежнего профиля **2 CPU / 5 GiB**, ingestion последовательно/batch 1: прежний параллельный indexing приводил к OOM. Сохранить его failed proof; не запускать соседний diagnostic model process | Host budget и исходное состояние записаны. OOM/нехватка места — результат/блокер среды; durable/status reconciliation до retry. Новые модели и платные API не подключаются автоматически |
| Workflow/fork | Закрепить фактически исполняемый clean workflow commit/tree и fork `162f2ea7a5734b65bc1de80943d057e9b7c0a525` из `D:/Git/itl_ai_rules_1c-scoped-cognee-g4`. Первая установка — через existing fixture/dependency owner | Release lock r47 остаётся прежним. `ITL_AI_RULES_SOURCE_PATH` выбирает чистый local checkout, **сам по себе не меняет r47 pin**. Нужен qualification-only immutable local tag/pin на candidate, подготовленный fork/fixture owner в отдельной локальной копии, без push/release. Совпадают tag/commit/manifest/owned hashes и approved clause. Нет поддержанного пути — pairing BLOCKED; ручная подмена installed rule/lock/receipt запрещена |
| PM5 | Через существующий `scripts/source-e2e-fixture.ps1`/capsule owner подготовить отдельную копию из сохранённой capsule, записать exact root, DB/CF/capsule hashes и topology до первого изменения | Старые G3-стенды, failed copies и sealed evidence не меняются. Все update/reset/recovery только на новой копии; обычный пользователь без elevation. Существующий guard применяется, Gate 6 не запускается и не обходится; если операция требует его, зависимый шаг BLOCKED |
| Реестр | Сначала тот же published R6 SHA и существующий applied context/resolver; настройки Code/Graph/СППР/Mantis берутся из него | Нет второго каталога, четвёртой MCP-роли, memory startup fetch, production-записей в СППР/Mantis или доработок Code/Graph. ERP+PM5 сохраняет собственный `erppm5-lts`; product home не меняет MCP source |
| Corpus | Сверить frozen baseline manifest `b0cc2bcf94e06e7f6c504c0243c41af6e5f8e280d88a4ec2dade523d1f66ec3b`, 37 безвредных заметок/6 scope types, 43 payload hashes, B01–B12 | Сохраняются prompts, bodies, scope boundaries, evaluator-only expected results и protocol; native UUID назначаются отдельно. Synthetic IDs не выдаются за реальные products/projects |

Путь frozen corpus: `C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/files-only-baseline/`;
резервная исходная копия — прежний run на dev-karimov, указанный в
[test-plan](test-plan.md). Утрата входов требует восстановления exact hashes,
а не создания более удобного нового корпуса. Stand setup, identities, grants,
backup и sanitized call logs сохраняются в ignored `build/test-results/g5/<run>/`.
В Git — краткая итоговая матрица/выводы и ссылки/hash evidence; credentials,
полные backups, runtime и пользовательские заметки туда не попадают.

## 2. Подтвердить homes отдельно от provider mapping

Минимальный **кандидат для подтверждения владельцем**, не внесённый в реестр:

| Существующая область | Предлагаемый `memoryHomeProductId` | Для чего нужна в G5 |
|---|---|---|
| `pm5-plan-model` | `pm5-corp` | Один PM-факт из `erppm5` читается КОРП, ПРОФ и УНФ+PM5 при доказанной применимости |
| `pm5-project-requests` | `pm5-corp` | CORP/ERP факт исключён из ПРОФ/УНФ, хотя хранится в том же product dataset |
| `pm5-payroll-allocation` | `erppm5` | ERP-only знание не переносится в независимый ПРОФ/КОРП по одному происхождению |

Все три ссылки существуют в опубликованной карте и входят в `availableIn`.
Предлагается подтвердить только эти назначения, не раздавать homes всем 44
областям и не объединять поколения PM4/PM5. Это решение об authoritative месте
знания, а не выданное право. Origin, versions, evidence и ограничения каждой
заметки сохраняются независимо от home. Локальные customer facts — project,
без добавления внешних проектов в выпускной реестр ради canary.

После подтверждения владелец registry подготавливает производный от R6
qualification snapshot через существующий validator/reader; фиксируются его
отдельный immutable commit/hash и applied context. Такой snapshot явно **не
опубликован**. Прогон на нём даёт native proof подтверждённого candidate mapping,
а не факт опубликованных homes. Публикация homes — отдельное разрешение;
перед выпуском памяти должен быть зафиксирован опубликованный SHA этих же
правил и сверена затронутая proof, без повторного прогона всего G5 по умолчанию.
Исходный R6/G3 не переоткрываются. Без owner confirmation shared-product строка
остаётся BLOCKED; нельзя подставить fixture home и назвать AC-32/44 принятыми.
Private/project/org сценарии от этого независимо выполнимы после допуска G5.

В paired B01–B12 сохраняются исходные synthetic IDs/context `fixture-r2`;
их отдельное test mapping не подменяет три реальных назначения выше.
Не переписывать frozen prompts/corpus под реальные IDs. Это две явно названные
линии доказательств: native поведение на синтетическом корпусе и consumer
подтверждённого registry mapping на изолированной PM5-копии.

## 3. Подготовить шесть областей и права

Один Cognee, native datasets; namespace не является ACL. Admin оператор готовит
shared datasets и grants штатным API, ordinary adapter их не создаёт и не
получает admin credential. Записать exact instance/principal/dataset/owner IDs
и назначение в provider-local settings вне Git. `permissions` в settings —
декларация, допуск доказывается реальным allow/deny. Сохранить отдельный список
только созданных test artifacts для точечной уборки, без удаления чужих datasets.

| Область / label | Создание и субъект | Доступ и проверяемая граница |
|---|---|---|
| Задача+ветка+база / `itl_task_<cycleId>` | Lazy обычным A; ключ workspace+cycle | A читает/пишет; B/outsider не видят. Reset меняет cycle, не возвращает старый runtime proof |
| Локальный проект / `itl_workspace_<workspaceId>` | Lazy обычным A | Та же рабочая копия переживает reset/new chat; другая независимая копия не получает её task/workspace данные |
| Рабочее место / `itl_workplace_<id>` | Lazy A; principal+стабильный machine ID | Новая сессия того же пользователя/ПК не создаёт новый scope; другой principal/ПК не наследует private факты |
| Продукт / `itl_product_<productId>` | Admin, только подтверждённые homes | A и B читают/пишут один exact ID. Outsider без grants не читает/пишет. У применимости и grants независимые проверки |
| Проект / `itl_project_<projectId>` | Admin, explicit project binding | A/B с членством читают/пишут; чужой проект не попадает в read set. Customer знание не публикуется в product/org |
| Организация / `itl_org_<organizationId>` | Admin, явная тестовая организация | A/B имеют read; A — назначенный publisher с write+delete, B без publisher права не исправляет/удаляет. Outsider вне неё не читает/пишет. Организация не означает default destination |

Нужны **A, B — два обычных пользователя, C — outsider, отдельный admin**;
это разные native principals, не имена клиентов одного токена. Для shared
product/project correction/retire A/B нужны native write+delete grants;
native semantics этих прав проверяется фактическими действиями. Для каждого
admitted ID выполняются remember/status → fresh reader/raw, allowed update/retire
и denied чтение/запись под C; для organization writer проверяются A allow/B deny.
Все CRUD canaries — только harmless записи своего run.
Отдельно воспроизводится уже предусмотренная collision: тот же label у другого
owner не подменяет exact shared ID. Нет персональных копий shared dataset.
Private Windows storage вне reset/Git доступен только нужному пользователю;
tokens не печатаются. Backend scope/grants действуют **до** retrieval/graph,
проверка отсутствия foreign текста в конечном ответе сама по себе недостаточна.

## 4. Один ограниченный native прогон

Строки группируют существующие AC; не образуют декартово произведение
clients × products × lifecycle × OS. Backend/data и PM5 lifecycle проходят
один раз; native policy/read/write/reload повторяются только в двух клиентах.

| Шаг / прежняя задача | Конкретная последовательность | Достаточное доказательство |
|---|---|---|
| N1 — 6.2, AC-01–09/18–20/33 | Подготовка IDs/grants по таблице; все 6 scopes: remember → status → новый ordinary процесс/reader; два пользователя одного shared ID, outsider deny и owner collision | Actual principal, exact dataset/data IDs, original hash и статус durable/index/searchable раздельно; ноль unauthorized/foreign фактов или незаявленных дублей |
| N2 — 6.2, AC-06–09/27/34 | На тестовом канале воспроизвести accepted-request/body-loss; сохранить pending/receipt, перезапустить frontend, выполнить точный lookup до retry. Исправить и retire запись, передать сохранённый старый fragment без header | Unconfirmed не назван success/rejection и не отправлен повторно вслепую. Authorized current original имеет приоритет над stale fragment; удалена одна запись, чужие целы. Нет собственного version store |
| N3 — 6.3, AC-10–23/31/39–42 | На отдельной legacy PM5-копии update → «позже» → association → отдельный memory opt-in → initial cycle без reset → new chat → reset при unchanged branch/HEAD, reserve/interruption/resume по существующему owner | First enable не меняет DB/HEAD/старые memory files; повтор/два сеанса/disable-enable стабильны. Один reserved cycle активируется после success; старый процесс не пишет новый task scope. Постоянное условие доступно после reset, старый runtime proof не current; независимая исходная задача завершена |
| N4 — 6.6b, AC-32/35/44 | На подтверждённом qualification snapshot ERP+PM5 → общий PM home `pm5-corp`: одна запись с origin ERP → fresh КОРП → допустимый ПРОФ; отдельные CORP-only/ERP-dependent canaries, missing/ambiguous home | Один authoritative native original, нет автоматического fan-out; исключённые функции/ERP-зависимости не становятся фактами ПРОФ. Реестр, deployment map и actual rights различимы; ERP MCP остаётся собственным, private project scope не расширен |
| N5 — 6.3, AC-15–17/21/28/35/39/41/43 | В Kilo/Cursor actual catalog и policy → remember/recall/status/retire → reload/new session. По existing writer: update/конфликт/cancel/partial recovery/offline → resume/owned restore → disable | Scope/principal/qualified fork проверены actual calls; TOOL off/required, standing query, strict-root, correction-capture, /evolve и Memory line сохраняются, одна durable write без root-дубля. IDs/source/pending/old notes/foreign MCP и disabled preferences сохранены; offline не блокирует независимый workflow. Core/API Codex отдельно, без ложного client PASS |
| N6 — 6.2–6.3, AC-27/34/43 | На isolated backend admin закрывает ordinary доступ, делает согласованный native restore к T, сверяет grants и известные поздние correction/delete/revoke, проверяет allow/deny; frontend disable → admission только проверенных IDs → fresh context/reload | Неавторизованные клиенты не получают старый snapshot, неподтверждённые scopes недоступны. Старые cached facts не current. Указан интервал потери после T; нет обещания hidden rollback detection/полной истории. Независимая задача продолжается; port reopen только после proof |
| N7 — 6.4, AC-24–26/29/36/37 | Парные files-only/Cognee B01–B12 по frozen protocol и разделу ниже, без изменения корпуса по результатам | Полезность/ошибки и полные расходы сопоставимы; измеренные, оценённые, unknown величины различимы; нет выдачи deterministic B09 order за semantic rank |

При дефекте сохраняются исходный стенд/входы/failed proof. Исправляется
подтверждённый owner в одобренной архитектуре и повторяется **тот же** affected
сценарий; assertions, watchdog и guards не ослабляются. После двух repair cycles
без принятия/сужения причины — checkpoint по package architecture, без наслоения
новых механизмов и бессрочного расширения матрицы.

## 5. Конечное парное сравнение и бюджет

B01 ошибка; B02 переформулировка; B03 причина решения; B04 успешный подход;
B05 collision; B06 новый чат; B07 unchanged-HEAD reset; B08 correction;
B09 CORP/PROF; B10 ERP dependency; B11 customer-only; B12 workplace.
Для каждого — **одна пара**, итого 24 whole-task выполнения, с чередованием
порядка files-first/Cognee-first. Cold preparation/ingestion показывается отдельно
и включается в итог; фактические warm reuse и повторные context inputs считаются.
Это matched-case оценка, не статистический SLA или доказательство всей продуктовой
базы. Повтор допустим только при документированном техническом сбое с сохранённым
исходным результатом, не до удобной стоимости/качества.

Одинаковы model/settings, prompt, разрешённый scope, catalog/evidence revision,
checkpoint/private pending и критерий результата. Чистые независимые сессии
не видят ответы другой половины пары; evaluator-only ожидаемые ответы закрыты
от агента. Files-only не получает бесплатного полного corpus scan, Cognee —
foreign scopes. Не импортировать реальные чаты/документы. Нативный B09 ranking
сохраняется как получен; deterministic candidateOrder — отдельная fixture proof.

Один union recall по admitted IDs, CHUNKS cap24 → проверка originals/currentness
и applicability → не более8 карточек/1600 actual tokens; общий read20s,
write+status60s. Standing query — один раз на неизменный eligible session context,
одна reformulation только после пустого relevant answer, без добора ради8.
Сохраняются bounded/partial coverage и конкретное continuation. Дедлайны не
продлеваются, cap не пополняется скрытыми запросами/LLM-классификатором.

Учитывать tool/schema/rule inputs, ingestion/extraction/embedding/graph/index,
source/status calls, ошибки/повторы, agent input/output/cached input, повторные
карточки, latency/wall, CPU time/peak RAM host/container и frontend, включая
первую компиляцию/tokenizer rank load. Parent/child usage не суммировать дважды.
Для реальной модели сверить encoding; named cl100k/o200k не автоматически её
tokenizer. UTF-8 bytes — proxy, unsupported/non-BMP — honest unknown с upper
bound, не «измеренные токены». Null internal cost не ноль. Деньги вычисляются
только при подтверждённых pricing/usage, иначе estimated/unknown.

Безопасность и актуальность обязательны: ноль unauthorized facts и ноль stale
runtime facts, объявленных текущими. Результат каждой пары — task success,
полезные/пропущенные знания, неприменимые советы, rework плюс цена получения
результата. Снижение числа токенов само по себе не PASS. Небольшое превышение
инженерной цели записывается для решения, без новых performance barriers или
повторов ради порога; принятый G3 warm excess не переоткрывается. Если Cognee
не доказывает пользу либо повышает качество ценой затрат, это честный вывод
и явный trade-off перед расширением rollout, а не бесконечный tuning.

## 6. Готовность, блокеры и остановка

**Готовность к запуску**: отдельно согласованы этот конечный контур и G5;
доступен сохранённый dev-karimov profile; определены A/B/C/admin и test IDs;
подтверждены три proposed homes и qualification snapshot; fixture owner выдаёт
чистую isolated PM5-копию и действительную candidate fork/host пару; сохранён
frozen corpus. Сейчас это план подготовки, **не подтверждение их наличия**.

**Конечная приёмка G5 в данном контуре**: N1–N7 имеют actual native/client/paired
evidence для заявленного объёма; нет открытых scope/ACL/currentness/durability,
cycle/continuation или recovery дефектов; исходная задача принятых сценариев
завершена, test artifacts/исходные protected roots сохранны. Ограничения и
результат пользы/стоимости рассмотрены, при необходимости принят явный trade-off.
Незапущенная/заблокированная обязательная строка не превращается в PASS:
завершённый subset можно принять только отдельным решением с точным остатком.

Сегодня **потенциальные зависимости, не обнаруженные native отказы**: доступность
Cognee, credentials/grants, homes и local candidate pairing. Отсутствие одного
блокирует соответствующий шаг, не независимый каталог/исходную задачу.
Непроверенные PM4/Windows/terminal/client области, публикация homes,
подготовка dependency release/общая выпускная проверка остаются отдельно до
выпуска; G5 не публикует fork/workflow, не выполняет Gate 6 или рабочую миграцию.

Один итоговый отчёт у memory owner связывает строки с AC, pinned identities,
actual/expected, calls и hashes, статусом и continuation/владельцем блокера;
registry OpenSpec ссылается на него, не ведёт вторую матрицу.
Документальные/исходные изменения завершаются одним coherent commit и штатным
`source-delivery.ps1 -Action RegisterChange -QueueId product-project-registry-g2`;
только этот helper выполняет Targeted. Регистрация и native приёмка — отдельные
факты. Дополнительные gates/публикация из завершения G5 не следуют.
