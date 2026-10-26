# G5: конечный план квалификации общего подключения

## Продолжение тех же B03/B09/B10, 2026-10-26

Оснастка сохраняет bounded request intents/results между перезапусками reader;
UTF8 BOM и exact benchmark-root/focused-composer/полный paragraph roundtrip
обязательны. Это repair транспорта прежних случаев, без новых сценариев.
Нативный server config в этом workload изменён только cache4→6; число logical
scopes само по себе не задаёт число всех dataset IDs для других проектов.
[Backend82 HTTP200 и оставшаяся граница](evidence/g5-common-continuation-2026-10-26.md):
полные ответы агента и подтверждение repair B03 остаются до свободного ПК.
Нативный ввод во время работы пользователя не продолжается. Критерии N1–N7,
лимиты, исходные prompts/эталоны и N5 остаток прежние; это не новый gate.


## Уточнение B11 и follow-up, 2026-10-26

Пользователь сохранил смысл B11 «применение в клиентском проекте»: исправляется
только ошибочный `context.project` на `qual-project-customer`, эталон
customer-only прежний. Оригинальный противоречивый прогон хранится неизменно.
Повтор двух B11 arms не добавляет тринадцатую задачу. Нативный follow-up остальных
задач не подменяет первоначальные paired затраты и не является повтором ради цены.
См. [единый итог](evidence/g5-common-continuation-2026-10-26.md):9/12 PASS,
два native backend lock failures, один unverified harness restart. Финитные N1–N7,
лимиты и критерии ниже сохраняются; новых случаев и ACL gate нет.


Статус 2026-10-26: **разрешён пользователем, выполняется; не принят**.
[Текущий follow-up N1–N7](evidence/g5-common-continuation-2026-10-26.md)
отделяет storage/current-original/native/client proof, source repairs и регистрацию.
Исходный [sealed first-run report](evidence/g5-common-qualification-2026-10-26.md)
сохранён; прежние update/reset blockers сняты. N7 завершён с недоказанной
пользой retrieval; N5 policy continuation выполнен в указанной границе.
Shared ordinary API key заменяет часовой Bearer без расширения конечных N1–N7.
Одно ordinary technical подключение, шесть областей, без прав людей/ACL.
Три homes подтверждены для локального qualification SHA `d705dfb78c749dd54c20f4ee99cc6bbb8b97776b`;
published R6 остаётся прежним. Конечные случаи/пороги ниже не расширяются.
Gate 6, рабочая миграция и публикация workflow остаются запрещены.
## Исходная граница и зависимости

G4 implementation `17061155f12c1c39df37eb3564f919edd994b811` зарегистрирован в
старой модели; предыдущий план — `02925f66bec63c06776445062caafee524ca8597`.
[Сверка с actual G4 и совместимость existing G4](g4-common-connection-alignment.md)
подтверждает совместимость текущего runtime с common account при одинаковом read/write.
Нового source gate нет; документы не дают новой native/client готовности.
G3 принят в прежнем конечном контуре; R6 опубликован SHA
`0274a8ffb5a03ba7b856736c2b4a637ccbe98b73` без назначенных product homes.

Контур остаётся PM5/Windows 11/PS5.1, Kilo VS Code и Cursor с actual tool
calls/reload; Codex — core/API. OpenCode SKIPPED. PM4, Windows 10/Server и
реальные terminal sessions остаются UNVERIFIED в выпускном остатке, поддержка
сохраняется. Это организация прежних 6.2–6.4/6.6b, AC/D8/D10, без нового gate,
перебора clients × products × lifecycle × OS или переоткрытия G3/R6.

## 1. Подготовка после отдельного разрешения G5

| Вход | Конкретный план | Достаточная готовность |
|---|---|---|
| Cognee | Прежний isolated Docker **dev-karimov**, ordinary loopback `18190` через настроенный защищённый канал. Проверить сохранность прежних volumes/evidence и actual profile перед запуском | Один instance/endpoint и один технический account/credential workflow; не личные accounts разработчиков. Текущая доступность не проверялась. Административный endpoint старого G1 не требуется клиентам или новому ACL прогону |
| Native профиль | Cognee **1.6.5**, image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`, OpenAPI SHA `b863f72d912c07ceb4bb914d790152659427c0ad33863d553d38b5fa64e24171`, G1 qualification SHA `be8219d1d090343f2d7deebace513b77d5aa7a322e353f10b9f3324d7048582d` | Сверить actual version/schema/models и аутентификацию общего подключения. Старый G1 переиспользуется только для применимых native возможностей; multi-user ACL proof исторический, не обязательный повтор |
| Ресурсы | Прежние **2 CPU / 5 GiB**, GLiNER demo / fastembed `BAAI/bge-small-en-v1.5` 384 dims, sequential ingestion/batch1; `self_improvement=false`, без improve/background jobs | Зафиксированы host budget и models. Прежний OOM/failed proof сохранён. Новые модели/платные API автоматически не подключаются; auth отключать не требуется |
| Source pair | Закрепить фактически исполняемый clean workflow/tree и совместимый fork candidate: сейчас `162f2ea7a5734b65bc1de80943d057e9b7c0a525`, `D:/Git/itl_ai_rules_1c-scoped-cognee-g4` | Existing fixture/dependency owner готовит local candidate pair. `ITL_AI_RULES_SOURCE_PATH` сам по себе не меняет r47 pin; нужен согласованный qualification-only immutable local tag/pin в изолированной копии, без публикации. Проверены manifest/ownership/approved clause; никаких ручных installed подмен |
| PM5 | Через existing `scripts/source-e2e-fixture.ps1`/capsule owner отдельная копия; exact root/topology/DB/CF/capsule hashes до изменения | Старые стенды, failed copies, sealed evidence сохранены; обычный Windows пользователь. Gate 6 не запускается/не обходится; требующий его шаг остаётся BLOCKED |
| Реестр | Один existing applied context/resolver, сначала published R6; ниже отдельный подтверждённый qualification snapshot homes | Native mapping/credential вне business registry. Три проектные MCP-роли; ERP+PM5 сохраняет собственный `erppm5-lts`. Нет второго updater, production СППР/Mantis writes или Code/Graph patches |
| Corpus | Frozen 37 harmless notes/6 scopes, B01–B12, 43 payload hashes, manifest `b0cc2bcf94e06e7f6c504c0243c41af6e5f8e280d88a4ec2dade523d1f66ec3b` | Тела/prompts/expected results не меняются ради результата. Поля synthetic identity/allowedScopes трактуются как принадлежность/контекст отбора, не отдельные backend credentials или ACL |

Исходный corpus: `C:/Users/xment/AppData/Local/Temp/cognee-q5-q7-r2-20261019T094637Z-b4127852/files-only-baseline/`;
remote копия и frozen protocol указаны в [test-plan](test-plan.md). Native UUID
назначаются отдельно. Evaluator-only ответы закрыты от оцениваемого агента;
один account не даёт ему бесплатный full corpus scan.

## 2. Минимальные homes на подтверждение

| Existing knowledge area | Предложенный home | Нативный сценарий |
|---|---|---|
| `pm5-plan-model` | `pm5-corp` | Один PM-факт из ERP+PM5 применим КОРП и ПРОФ при нужном evidence |
| `pm5-project-requests` | `pm5-corp` | CORP-only факт в том же dataset исключён для ПРОФ/УНФ |
| `pm5-payroll-allocation` | `erppm5` | ERP-dependent факт исключён из независимого КОРП/ПРОФ |

Пользователь подтвердил эти homes для qualification snapshot указанного SHA; они не опубликованы. Все ссылки существуют и входят в
`availableIn`; подтверждение относится только к этим трём областям,
без массового назначения 44 homes или объединения PM4/PM5. Registry owner подготовил отдельный pinned qualification snapshot через
existing validator/reader. Native proof на нём не выдаётся за публикацию.
Перед выпуском памяти отдельно фиксируется published SHA тех же правил и
сверяется затронутая proof. Без homes блокируется только shared-product строка.
Product home не задаёт права и не меняет MCP source. Customer fact остаётся
project, не становится общим продуктовым знанием автоматически.

## 3. Шесть областей под одним техническим подключением

| Область / label | Привязка и подготовка | Проверяемый смысл |
|---|---|---|
| Задача+ветка+база / `itl_task_<cycleId>` | Lazy, workspace+cycle | Reset меняет cycle; старое runtime proof остаётся историей |
| Локальный проект / `itl_workspace_<workspaceId>` | Lazy, конкретная рабочая копия | Переживает reset/new chat, независимая копия имеет другой workspace |
| Рабочее место / `itl_workplace_<id>` | Lazy, стабильный user-local machine identity | Новая сессия того же пользователя/ПК сохраняет scope; backend principal не считается сотрудником |
| Продукт / `itl_product_<productId>` | Один exact native ID подтверждённого home, подготовлен тем же common account | Общий факт записан один раз; availability/versions/dependencies проверяются отдельно |
| Проект / `itl_project_<projectId>` | Один exact ID business project | Особенности проекта выбираются по контексту, не по членству/правам |
| Организация / `itl_org_<organizationId>` | Один exact ID организации workflow | Общий подтверждённый опыт; не default destination, без publisher role |

Общие datasets один раз подготавливает оператор штатным API под тем же account;
отдельный admin/grant setup не нужен. Deployment mapping содержит instance,
scope, exact ID/owner и current-state admission; Existing `permissions` сохраняется как
фиксированное `["read", "write"]` у всех entries; настройка прав сотрудников
не предлагается. `principalId` — один обычный технический account. Один label не доказывает native identity.
Context set ограничивает backend **до retrieval/graph expansion**, независимо
от широких технических возможностей account. User-local pending/continuation
не пересылаются автоматически. Credential вне Git/reset, не попадает в журналы.

## 4. Конечные native сценарии

| Шаг / прежние задачи | Действия | Критерий результата |
|---|---|---|
| N1 — 6.2, AC-01–09/18–20/33 | Все6 scopes: write/status → fresh reader; два процесса одного подключения используют один shared ID; label/owner collision | Exact ID/owner и durable/index/searchable различимы; нет duplicate dataset, смешения contexts или silent write destination. Права людей/outsider не проверяются |
| N2 — 6.2, AC-06–09/34 | Accepted-request/body-loss → pending/receipt → restart → точный lookup до retry; correction/retire и сохранённый stale fragment без header | Нет blind replay/дубля. Current original важнее semantic fragment; удалена ровно нужная заметка, прочие целы |
| N3 — 6.3, AC-10–23/31/39–42 | Отдельная legacy PM5: update → позже → association → отдельный opt-in → initial cycle без reset → new chat → unchanged-HEAD reset/reserve/interruption/resume existing owner | DB/HEAD/старые notes при initial enable сохранены; один reserved cycle, стабильные IDs, stale process не пишет новый цикл; постоянное условие переживает reset, исходная задача завершена |
| N4 — 6.6b, AC-32/35/44 | ERP+PM5 → одна запись в home КОРП → fresh КОРП/допустимый ПРОФ; CORP-only/ERP-dependent/missing home | Подтверждённые mapping/applicability/current original; нет fan-out или переноса неприменимых функций. Own ERP MCP сохранён |
| N5 — 6.3, AC-15–17/21/28/35/39/41/43 | Kilo/Cursor actual tools и policy → remember/recall/status/retire → reload/new session; existing writer update/conflict/cancel/partial/offline/resume/owned restore/disable | Общий connection сохранён; TOOL/off/required, standing query, strict-root, correction-capture, /evolve, Memory line и одна durable write прежние. IDs/data/pending/foreign MCP/disabled preferences целы; core/API Codex отдельно |
| N6 — 6.2–6.3, AC-27/34/43 | Приостановить общее клиентское подключение, native backup/restore к T; проверить originals/известные поздние correction/delete → допустить проверенные scopes → fresh context/reload | Непроверенное состояние не current, указана потеря после T. Нет mandatory ACL/grant/revoke/outsider проверки, hidden rollback detector или собственного versioning. Независимая задача продолжается |
| N7 — 6.4, AC-24–26/29/36/37 | Frozen paired B01–B12 по разделу5 | Качество/rework и полная стоимость сопоставлены, measured/estimated/unknown различимы; deterministic B09 order не выдаётся за native semantic rank |

Backend/data и PM5 lifecycle — один раз; native policy/read/write/reload — в двух
клиентах, без полного произведения вариантов. Failed inputs/стенд сохраняются;
подтверждённый owner repair повторяет тот же affected scenario. Не ослаблять
маршрутизационные/currentness assertions, watchdog или guards. После двух repair
cycles без принятия/сужения причины — architecture checkpoint, не новые слои.

## 5. Парная польза и стоимость

B01 ошибка, B02 reformulation, B03 причина решения, B04 успешный подход,
B05 scope collision, B06 new chat, B07 unchanged-HEAD reset, B08 correction,
B09 CORP/PROF, B10 ERP dependency, B11 customer-only, B12 workplace.
**Одна пара на задачу, 24 whole-task выполнения**, порядок files-first/Cognee-first
чередуется. Один и тот же agent model/settings/prompt/context/revision/checkpoint;
чистые независимые сессии не видят ответов другой половины. Synthetic identities
сохраняются как corpus provenance; весь native run использует common connection.
Corpus/expected answers не переписываются под новый удобный ranking.

Один union CHUNKS recall cap24 → original/currentness/applicability → final8/1600
actual tokens. Read20s, write+status60s; standing query один раз на eligible
unchanged context, одна reformulation только после пустого relevant answer.
Не добирать8 дополнительными запросами; bounded/partial coverage честная.

Включить ingestion/extraction/embedding/graph/index, source/status, errors/retries,
tool/schema/rules, agent input/output/cached input и повторные карточки,
CPU/peakRAM/wall host/container/frontend, cold compile/tokenizer rank load и reuse.
Parent/child usage не считать дважды. Реальной модели нужен подтверждённый
encoding; bytes/proxy/unsupported/non-BMP не выдаются за actual tokens.
Null internal usage/money остаётся unknown; деньги только при valid usage/pricing.

Обязательны ноль out-of-context фактов, объявленных применимыми, и ноль stale
runtime фактов, объявленных текущими; это качество/актуальность, не confidentiality
между людьми. Для каждой пары — success/missed knowledge/неприменимые советы/
rework и затраты. Без доказанной пользы расширение rollout требует явного
trade-off. Нет tuning/повтора ради цены или нового performance barrier;
принятое G3 warm отклонение не переоткрывается.

## 6. Готовность и конечная остановка

**До запуска:** отдельное разрешение G5; существующий G4/common configuration и
зарегистрированная matching pair; сохранённый Cognee/profile/common credential;
exact dataset mapping и harmless corpus; isolated PM5; подтверждённые homes для
N4. Четырёх аккаунтов, матрицы grants и членства среди входов больше нет.
Это зависимости плана, а не обнаруженные live отказы; независимые строки можно
выполнить после разрешения G5, не выдавая BLOCKED N4 за PASS.

**Приёмка конечного контура:** N1–N7 доказаны actual native/client/paired evidence;
нет открытых context/destination/currentness/durability/cycle/recovery дефектов;
исходные задачи завершены, старые protected assets сохранны, стоимость/польза
рассмотрены. Непройденный обязательный шаг не становится PASS; subset принимается
только отдельным решением с точным остатком. Не добавлять новые случаи по ходу.

Один итоговый отчёт у memory owner: exact inputs, expected/actual, hashes/calls,
source/fixture/native/client proof, статус и continuation/владелец блокера.
Registry ссылается на него, не ведёт вторую матрицу. PM4/platform/terminal/client
пробелы, публикация homes, dependency release и общая выпускная квалификация
остаются до выпуска отдельно. G5 не выполняет Gate6, рабочую миграцию,
публикацию fork/workflow. Документальные/source изменения — один coherent commit
и обычный RegisterChange; только helper владеет Targeted, отдельные gates не нужны.
