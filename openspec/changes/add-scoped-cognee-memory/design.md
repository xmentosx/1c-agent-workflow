# Design

## Регистрация QP: бюджет команды обновления, 2026-10-28

План QP и запрет выполнения сохраняются. Блокер общей регистрации относится
к добавленным в другой очереди обязательным инструкциям itl-update-workflow,
а не к memory profile. Existing renderer показал ровно+452байта на каждой из24
поверхностей, без новых файлов или роста root instructions. Требуемые rollout,
locks/preservation, frozen pending set, no-push/no-refresh и named continuation
сохранены. ParserDocsBudgets учитывает фиксированную дельту только при наличии
этого rollout contract и ограничивает сам template1930LF UTF-8 bytes.
Исходный запас220байт master/Codex сохраняется, произвольного увеличения нет.
Доказательства и граница — [test-plan](test-plan.md#блокер-регистрации-qp-клиентский-контекст-2026-10-28).

## QP: рабочий профиль Qwen и новый индекс, 2026-10-28

### Решение и разрешённая граница

Пользователь выбрал **Qwen3-Embedding-8B** для рабочего Cognee. Это заменяет
прежний статус «модель не выбрана/замена не принята»: BGE остаётся сохранённым
комплектом возврата. Выбор модели не означает, что рабочее подключение уже
переключено или новый профиль допущен. Сейчас разрешена только подготовка
этого плана и согласование двух OpenSpec. QP0–QP6 ниже не выполнялись.
Gate6/G6, рабочая миграция, публикация workflow/fork, push и PR не разрешены.

Основание: [RU21/72](evidence/qwen-lru6-recheck-2026-10-28.md) и
[6полных ответов](evidence/qwen-lru6-codex-answers-2026-10-28.md). Они подтверждают
чтение квалификационного корпуса, не production ingestion с cache6 и не перенос
рабочих данных. Прежние failures, G1/Q1–Q7, G3/R6/G4/G5/MO сохраняют свои границы.

### Архитектурный checkpoint QP

Инвариант: у знания сохраняются логическая область, noteId, текст, источник,
применимость и подтверждённый текущий статус; смена embedding не разрешает
потерю записей, восстановление отозванных фактов или смену task/workspace/workplace.
Cognee остаётся без форка, с одним общим техническим подключением и шестью
логическими областями; персональные ACL, OpenViking и второй memory pipeline
не добавляются. Два экземпляра существуют временно для подготовки/возврата,
нормальные клиенты в каждый момент используют только один принятый комплект.

Host/backup owner создаёт согласованные копии и выполняет операторское окно;
существующий memory/MCP owner ведёт профиль, exact mappings и setup/reload;
существующий policy owner допускает проверенный профиль. Registry owner
продолжает владеть business IDs/home/applicability и тремя проектными MCP-ролями.
Нового координатора, постоянной репликации, очереди миграции, shadow ledger,
автоматического fallback или runtime-барьера для независимого workflow нет.
Одноразовые inventory/delta/hash records — доказательства операторской операции,
не новый постоянно работающий сервис. Always-on rules/tool schemas не растут. Controlled ai_rules_1c r50 и его
model-agnostic remember/recall policy сохраняются; смена embedding не меняет
семантику tools, upstream/fork правила или route OpenViking.

Текущий `Assert-ItlMemoryProvider` допускает закреплённую пару profile/qualification
hash. Будущий QP4 меняет этот контракт у его существующего владельца: явно
допускаются проверенный Qwen и прежний BGE для управляемого возврата; нового
реестра профилей/динамического выбора нет. Запись выдуманного hash в settings
или снятие проверки не являются допуском. Нужные owner-local изменения,
совместимость и canary входят в будущую реализацию QP, не в этот planning commit.

### Целевой профиль

| Параметр | Планируемое значение / источник |
|---|---|
| Engine | `qwen/qwen3-embedding-8b`, `EMBEDDING_DIMENSIONS=4096` |
| Cognee |1.6.5, проверенный image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`; без одновременного upgrade |
| Клиент embedding | Тот же штатный async OpenAI-compatible SDK путь, endpoint/provider/model и wire settings из квалифицированного Qwen manifest; не возврат к прежнему LiteLLM пути |
| Native cache | `DATABASE_MAX_LRU_CACHE_SIZE=6` |
| Native pacing | `EMBEDDING_RATE_LIMIT_ENABLED=false`; queue/concurrency2, batch32 и input cap512 прежние |
| Graph buffer | `KUZU_BUFFER_POOL_SIZE=268435456` |
| Ресурсы |2CPU/5GiB RAM; Docker memory-swap field5GiB, то есть вместе RAM+swap5GiB; постоянное хранилище отдельно от контейнера |
| HTTP budgets | recall20s, remember60s у существующего frontend; объёмный rebuild — операторская подготовка с отдельным общим budget/status, не увеличение этих лимитов |
| Auth Cognee | Один обычный технический account, native `X-Api-Key` без регулярного login/refresh; секрет в existing user-local private credential file |
| Auth embedding | Серверный секрет прежнего разрешённого endpoint, отдельно от Cognee key; ни один секрет не входит в Git/бизнес-реестр/model context |
| Identity | Новый deployment `instanceId`, новый набор exact dataset IDs; сохранённый technical principal UUID и прежние local identities/cycle |
| Deployment | dev-karimov-mcp — подготовленный кандидат хоста; предлагаемые имена `itl-cognee-qwen-prod-v1` / `cognee-qwen4096-v1` ещё не созданы/не допущены. Реальные URL/port/paths/owner подтвердить в QP0 |
| Defaults | Память default-on при готовых prerequisites; существующие explicit off/disabled сохраняются. Без готового mapping — unavailable/pending, независимый workflow работает |

Полезная конфигурация SDK сохраняется отдельно от тестового DEBUG/logging wrapper.
Удаление инструментария не должно менять provider route; этот факт проверяет QP4.
Расход embeddings, диск и ingestion peak6 измеряются в подготовке; прежние
read peaks1.538–1.584GiB не объявляются доказательством памяти при загрузке.
Стоимость unknown не равна нулю и не требует нового бесконечного benchmark.

### QP0–QP5: конкретный порядок подготовки и будущего допуска

| Этап | Действия существующих владельцев после отдельного разрешения | Готовность / сохранённое продолжение |
|---|---|---|
| QP0. Инвентаризация | Подтвердить настоящий source, host/volumes, image/schema, principal, все6scope mappings, счётчики/bytes, current originals/status, pending/native jobs, private client settings и published registry SHA `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`. Назначить пути source/backup/candidate, свободный отдельный port, владельца и численные бюджеты rebuild/окна по существующему runner. Учебные G5/RU records исключаются из рабочего набора только по подтверждённому списку, не по догадке/имени. | Scope/source list и preview согласованы, место под full backup+clone+новый4096 index есть. Unknown originals сохраняются. Если настоящего рабочего хранилища ещё нет, QP0 фиксирует пустой рабочий старт; тестовый стенд не переименовывается в production. |
| QP1. Снимок T | Оператор приостанавливает общее memory подключение, сверяет pending/активные native jobs штатным status без replay, останавливает только свой Cognee и согласованно копирует relational/auth/original/graph/vector/config/mappings. Сохраняет hashes, source identity и закрытую credential recovery. Проверяет restore на отдельной копии тем же image и exact raw reads, затем возвращает прежний BGE source к работе. | Согласованный полный восстановимый комплект T и экспорт оригиналов. Live copy одной vector папки не считается backup. Неопределённый write не переносится и не объявляется отменённым; его продолжение остаётся на source. |
| QP2. Отдельный target | Из T создаётся изолированная копия полного хранилища: auth/native principal UUID сохраняется. В ней штатным Cognee API создаются новые пустые datasets для нового4096 индекса; они имеют новые native UUID и отдельные graph/vector namespaces. Старые BGE datasets в копии остаются архивными и никогда не выбираются Qwen binding. Выдаётся новый instanceId; обычные клиенты к candidate не подключаются. | Source T/BGE неизменён. Principal совпал, exact old→new dataset map известен; workspace/workplace/taskCycle не пересозданы. Копирование полного хранилища сохраняет account; ручной SQL/import таблиц auth не требуется. |
| QP3. Перестроение | Для каждого current original из экспорта T сохранить exact payload/noteId/status/provenance/applicability и выполнить штатный remember в подтверждённый новый dataset, затем native processing status и raw read. Подготовка по одному подтверждённому write с прежним concurrency cap; native dataId может измениться и фиксируется old→new. Не переносить384-векторы в4096 namespaces. | Текущие payload/hash множества по каждой логической области равны T; количество, current revision и precise retirement сохранены. Native status и actual CHUNKS доказывают построение нового индекса; HTTP200, старый completed или dedup reuse сами по себе не proof. При пропуске rebuild из-за native dedup — остановить эту подготовку с evidence, вернуться к поддерживаемому пути на checkpoint, без патча Cognee/изменения текста для обхода dedup. |
| QP4. Квалификация профиля | Переиспользовать неизменившиеся Q1–Q7/G5/MO и RU21/72/6 evidence с точным fingerprint. На candidate закрыть затронутые existing write/status/fresh-reader, exact/correction/retirement/restore и default-on/off continuation сценарии, включая new IDs и отсутствие diagnostic wrapper. Подтвердить4096 на новом индексе, per-scope hashes, native completed, ingestion resources/cost actual/unknown. Затем подготовить admission reference у существующего policy owner, сохраняющий управляемый возврат BGE. | Квалификационный результат и exact profile hash существуют; не ручная подстановка G1/RU hash. Existing budgets/assertions сохранены. Новые RU вопросы/72 до удачного числа не назначаются. Source registration/Targeted отдельно, Gate6 здесь не запускается и не считается пройденным. |
| QP5. Финальная сверка и переключение | Только после отдельного разрешения на cutover и требуемой выпускной квалификации exact candidate: снова приостановить общее подключение, завершить/разобрать source pending, получить согласованный Tf. Сравнить inventory T↔Tf по scope+noteId+raw hash; native API применить additions/corrections/precise deletions только к candidate. Сверить current original множества. Existing MCP owner готовит provider/settings/mappings комплект и через existing setup/reload последовательно переводит допущенные bindings; старый source останавливается до открытия normal writes в Qwen. | Ни один normal writer не пишет одновременно в BGE и Qwen; source/Tf сохранён. Все включённые клиенты подтвердили новый instance/dataset/data IDs и свежий context; старые endpoints/bindings недоступны для записи. Явный off сохранён. Не завершённый/неподтверждённый этап не даёт success; оператор возвращает прежний комплект или оставляет memory unavailable, основной workflow продолжается. |

Для подтверждённого пустого рабочего старта QP1 фиксирует отсутствие старых
рабочих записей/настроек; QP2 штатно создаёт ordinary account и пустые datasets,
не переносит fixture UUID/identity. Вариант полного клона применяется только
к существующему реальному source. Возврат до первых writes восстанавливает
прежнее unconfigured состояние; после writes Tr сохраняется и возврат к BGE
требует подготовленного квалифицированного BGE комплекта с сохранением данных.
Если его ещё нет, память остаётся unavailable, данные не удаляются ради отката.

QP1/T и QP5/Tf — два коротких операторских окна, а не остановка старой памяти на
всё время rebuild. Финальный diff получается повторным полным inventory, без
нового журнала событий/постоянного change-data-capture/dual write. Pending,
привязанный к прежнему instance/principal/exact dataset, не перепривязывается
к новому destination; сначала его штатное source reconciliation. Неиспользованные
локальные unsent intents остаются сохранёнными и не отправляются автоматически.
Если source только тестовый или отсутствует, old data/state всё равно сохраняются;
новый рабочий набор и начальные homes берутся из подтверждённых назначений QP0.

Сам rebuild не меняет registry SHA, canonical home или task generation.
Осознанно отсутствующие optional homes опубликованного R6 не заполняются
догадками ради индекса. Создаются только утверждённые shared scopes; частные
scopes — по существующему on-demand owner. Шесть областей — шесть типов,
а не шесть общих физических datasets на всю организацию.
Deployment mapping включает stable logical key, old/new native dataset/owner,
old/new dataId для каждого noteId и raw hash; это operator proof/native mapping,
не новая сущность бизнес-реестра. Общие scopes настраиваются один раз;
частные task/workspace/workplace mappings остаются у existing local owner.
Новые bindings не получают прежние кэши/receipts как доказательство новых IDs.

### QP6: возврат без скрытой потери текущих данных

До первого Qwen write достаточно остановить candidate и восстановить прежний
BGE provider/mappings/binding комплект через existing owner с новым context.
Секреты и native principal проверяются, а не меняются для обхода admission.

После хотя бы одного Qwen write возврат одним старым snapshot запрещён:

1. Приостановить только общее memory подключение и сохранить полный Qwen snapshot
   Tr, exact current inventory и pending; не удалять candidate/исходные записи.
2. На отдельной BGE restore-копии Tf штатным API384 применить разницу Tf→Tr:
   новые записи, текущие corrections и precise deletions. Для каждого confirmed
   original сравнить scope+noteId+payload hash и current status; native data IDs
   разрешено изменить только с точным новым mapping. Старые отозванные факты
   не должны снова стать current. Не переигрывать unconfirmed writes.
3. После native fresh original/status/recall подтверждения existing owner переводит
   настройки/допущенные bindings на согласованный BGE комплект и делает reload.
   Qwen normal writers остаются остановленными. Прежний admitted BGE profile
   и совместимый owner сохранены; automatic model fallback не используется.
4. Если текущие изменения/retirement подтвердить невозможно, не открывать старую
   память как будто она актуальна: сохранить обе стороны/экспорт/pending,
   оставить affected scopes unavailable и выполнить existing Q5 continuation.
   Любой ненулевой интервал потери данных требует отдельного решения пользователя.

Цель для подтверждённых current originals — нулевая потеря при согласованном
cutover/rollback inventory. Это не обещание native immutable истории всех
ревизий или несуществующей транзакции сразу на двух серверах. Вся сохранённая
история остаётся в полных снимках; поздние изменения учитываются явно по Q5.
Backups/BGE/Qwen/failed artifacts не удаляются автоматически по успеху/возрасту.
Срок и удаление старого комплекта — отдельное операторское решение после приёмки.

### Риски и выпускная граница

Native IDs могут меняться → exact mapping и current raw proof; principal/local
identity сохраняются. Вектор4096 больше384 → проверка диска/ingestion на candidate,
без пересчёта RAM из числа параметров удалённой8B модели. Внешний endpoint может
быть недоступен → штатное unavailable/pending, source preserved, без смены модели.
Недоступная native операция → retained evidence/checkpoint, без SQL/Cognee patch.

Предвыпускные R1–R5, fork r50 compatibility и Gate6 остаются отдельным существующим
контуром; QP их не заменяет и не добавляет новую бесконечную матрицу. Рабочая
миграция установленных проектов не входит в разрешение на подготовку candidate;
она и публикация потребуют своих отдельных поручений. Критерии QP-AC1–8 —
[test-plan.md](test-plan.md#qp-планируемая-приёмка-рабочего-профиля-2026-10-28).

## Qwen cache6: полные ответы Codex, 2026-10-28

[Native квалификация](evidence/qwen-lru6-codex-answers-2026-10-28.md) дополняет прежний RU21/72: те же шесть
полных заданий теперь выполнены6/6, включая получение факта RU20 и корректный
отказ RU24. Сохранены корпус/gold, точные prompts, бинарник/модель Codex,
controlled policy и native frontend. Общий Cognee, шесть областей, canonical
homes и различия проекта/MCP-источника прежние; ACL не добавляется.
Профиль cache6/rate off/pool256MiB действует только на тестовой копии.
20s бюджет frontend и исходные лимиты сохранены. Первый cold recall вернул
частичные карточки у границы бюджета; это не заявление о полном покрытии.
Median полного ответа44.552s — отдельная метрика от задержки embedding/search.
Рабочая модель/registry не переключены; ingestion, installed/Desktop acceptance
и выпуск этим не квалифицируются. Новый gate или runtime-слой не вводится.

## Qwen native profile6: итог согласованной настройки, 2026-10-28

[Единый actual result](evidence/qwen-lru6-recheck-2026-10-28.md): cache6/pacing off на изолированном Cognee без
изменения его кода; pool256MiB/5GiB/2CPU и прежний20s budget сохранены.
RU21 пройден, все72исходных requests получили ответ, p956.647s/max13.698s.
Согласованная пара native settings пригодна для измеренного чтения; отдельные
вклады не изолированы. Это не production model switch или новая роль registry.
Canonical homes, шесть областей/common connection, ai_rules_1c и принятые
G3/R6/G5/MO границы прежние; G6/рабочая миграция/публикация не запускались.



## Исторический итог профиля cache4/pacing1s

Итог28октября: полный identical index допущен;144/144 attempts и12/12 answers
завершены. BGE72/72 и6/6 выполненных задач; Qwen32/72 и5/6. Нужные знания
Qwen ранжирует лучше на успешных ответах, но20s availability недостаточна.
Рабочая модель прежняя; конечное исследование закрыто, новый release gate не вводится.

## RU-EMB: сопоставление подключения и восстановление подготовки, 2026-10-27

[Актуальное продолжение](evidence/ru-embedding-repair-2026-10-27.md) отделяет
вклад native buffer/cache в OOM, внешний403, подтверждённое совпадение
ключа/model/URL с Code/Graph и ошибку оснастки при HTTP timeout до native completion.
Исправления ограничены изолированным профилем и preparation harness; production
Cognee, frontend, каталог и ai_rules_1c не меняются. Для прежних144/12 обязателен
идентичный полный50-chunk index обеих моделей; partial raw originals не допуск.
Предел timed search20s прежний, новое ожидание native completion не засчитывается
как успешный timed call. Это исследование, без нового release gate.

## RU-EMB: технический допуск сравнения, 2026-10-27

[Единый результат](evidence/ru-embedding-preflight-2026-10-27.md): BGE получил
50/50 идентичных фрагментов; Qwen через LiteLLM остановлен OOM, через штатный
SDK — 403 security policy. Парные поиск/ответы не начаты, качество не принято.
Производственная модель, scoped frontend и ai_rules_1c не меняются. Это
исследовательский stop, без нового release gate и переоткрытия G3/R6/G5/MO.

## MO — разрешённая реализация, 2026-10-27

Пользователь согласовал checkpoint и разрешил MO0–MO4. MO0–MO3 реализованы
в source; прежние B01–B12 и установленный N5 на r50 завершены.
Доставка — отдельная штатная регистрация этого коммита, итог в общем queue ledger. [Единый отчёт MO](evidence/mo-implementation-2026-10-27.md)
отделяет source/fixture/native/стоимость/доставку. Controlled fork r50 —
a2cbdcef52316db426acedc852f495564189f1ca, template pin pending.
Прежние запреты реализации ниже относятся к уже завершённому планированию.
G3/R6 и конечный G5 не переоткрываются. Gate6/G6, рабочая миграция, публикация,
push/PR и native OpenCode по-прежнему не запускаются.

## План MO: default-on и оптимизация памяти, 2026-10-27

Актуальная постановка следующего ограниченного изменения: по решению пользователя
**память включена по умолчанию**. Прежние требования отдельного memory opt-in
ниже исторические и заменены нормативными требованиями memory-policy-and-budget,
memory-task-cycle и registry-memory-context. Project association с preview
остаётся отдельным явным действием.

G4 реализован, конечный G5 [завершён в согласованной границе](evidence/g5-codex-completion-2026-10-27.md).
Квалифицированный runtime source — 6828b622d8542748c4294bfd066a6c5af41a7bc2/r49:
explicit enable, CHUNKS и последовательное чтение. Это исторический baseline до MO. Новый default-on, параллельный reader и lexical
route реализованы в текущем MO; их доказательства приведены в едином отчёте выше.
G3/G5 не переоткрываются, преимущество перед файлами не заявляется. MO4 использует
только прежние N5/B01–B12. Targeted принадлежит RegisterChange; Gate6/G6,
рабочая миграция и публикация запрещены.

### Причина и ожидаемая полезность

Invoke-ItlMemoryRecall делает один CHUNKS запрос по allowed datasets, затем
round-robin отбирает до 24 кандидатов, dedupe по dataset/data ID и последовательно
читает raw originals с проверкой current status/applicability. Итог — до 8 cards,
весь recall payload до 1600 токенов по двум именованным счётчикам; общий deadline
20 секунд включает principal/recall/originals. Эти ограничения сохраняются.
Точный memory_status уже читает original по dataset/data ID.

В сохранённом Codex-продолжении B03/B09/B10 было 19/32/20 raw чтений,
11/24/11 уникальных пар за всю задачу: повторы между recall/exact, а не отсутствие
dedupe внутри recall. Они не доказаны лишними: currentness могла измениться.
Резерв — последовательные независимые GET внутри recall, выбор маршрута
и ненужное повторение контекста. Источники — текущий reader и wire/events
named run build/test-results/g5/common-20261026-112117, без новых замеров сейчас.
Текущий stdio MCP уже long-lived; N7 fixture запускает PowerShell на каждый call.
Его import/tokenizer overhead не является доказанной production задержкой.
Холодный recall B03 и три задачи не дают производственного p95/SLA.

Cognee даёт поиск по смыслу и durable originals/IDs между сеансами. Шесть областей,
cycle и продуктовую применимость обеспечивает ITL поверх datasets/реестра.
CHUNKS не использует graph traversal: graph строится native remember/cognify,
стоимость есть, выгода graph read пока не показана. Ingestion/index pipeline
не меняем. Исходные пары не доказали преимущества перед файлами; поздние Codex
PASS нельзя объединять с Grok/Cursor в новый paired score. Internal unknown
usage не нулевой. Половина bytes выдачи не доказывает экономию всей задачи.

### MO0 — default-on и checkpoint будущего apply

Policy владеет controlled ai_rules_1c; setup/binding/client writes/IDs/cycle
и recovery — прежние ITL owners. Fork меняется только в controlled source
на upgrade/release ветке; установленная копия не патчится. После готовой явной
association и настройки common connection setup автоматически готовит память,
без второго вопроса «включить/позже» и шести вопросов об областях.

| Состояние | Будущее поведение |
|---|---|
| Готовый новый/явно настраиваемый проект, настройка отсутствует | Default-on; прежний setup применяет binding, выполняет штатный reload и подтверждает native activation |
| Явные TOOL_COGNEE=off, disabled, сохранённый отказ/откладывание памяти | Off сохраняется при update/reload; не включать повторно автоматически |
| Нет association, connection, qualified version или mapping | Default-on preference, фактически unavailable/unconfigured; нет guessed IDs/unscoped запроса/ложного success |
| Required memory недоступна | Только зависимая операция incomplete с continuation; независимая работа продолжается |
| Unbound legacy, association later/no answer | Не назначать проект, package update не мигрирует память; продолжение через прежний setup |
| Установленный рабочий проект | Переход требует отдельно разрешённой миграции; сейчас не выполняется |
| Legacy memory.md/pending/история | Сохранить data/bytes/IDs, не импортировать и не публиковать массово |

Нет нового coordinator, background recall, readiness ledger, employee ACL или
remote provisioning. Общее подключение использует private native API key,
без часового login/auth-refresh service. R6 SHA
0274a8ffb5a03ba7b856736c2b4a637ccbe98b73 не меняется;
qualification homes не становятся production homes. Mapping подтверждает
memory owner; нет home — недопустима только зависимая shared-product запись.
Destination записи остаётся явным; включение не расширяет read/write scope.

Checkpoint: default-on policy запрошена пользователем; **реализация MO0–MO4 разрешена последующим решением пользователя**. Прежние owners и одна state machine; нет authority над чужими
процессами/служб/lock family/очереди. Сохраняются неадминистративные Windows
10/11/Server2019+ и терминальные сессии. Preference, binding readiness и native
activation различаются. Partial восстанавливается через прежние pinned
resume/owned restore без reset/init базы. Откат сохраняет data/IDs/pending/off;
несовместимая старая версия — только через compatibility/owned restore,
без удаления новых полей ради видимости совместимости. Расширение миграции,
платформ, блокировок или always-on контекста возвращается на checkpoint
package-architecture.md. Рабочая миграция отдельно, не часть текущего apply.

Совместимость с ai_rules_1c: intended semantic delta — отдельный enable prompt
заменяется default-on при тех же prerequisites; optional lexical route расширяет
только retrieval mode после proof. Recall-first, correction-capture в том же ходе,
rule-friction, один durable save, неопределённый write без blind retry/fallback,
TOOL off/auto/required, Memory line и строгая роль memory.md сохраняются.
Write priority Cognee → допустимый OpenViking → допустимый templates прежний;
project facts не уходят в shared templates. Standing query выполняется один раз
на неизменный session context, full-cycle/spec сохраняет всех eligible readers,
quick-fix/standing — первого. Код fork/host должен согласованно представить этот
semantic diff, без роста always-on policy за счёт дублирования плана.

Отсутствие старой настройки не является явным отказом пользователя. При будущем
переходе legacy нельзя выдавать технически записанный default за пользовательский
off; происхождение ambiguous значения выясняет прежний setup owner в отдельно
разрешённой миграции. Это не разрешение менять такие установки сейчас.

### Этапы после отдельного разрешения

| Этап | Владелец и конкретное действие | Зависимость и результат |
|---|---|---|
| MO0 | Fork policy + ITL setup: default-on, explicit off/unavailable, idempotent initial cycle/reload | Checkpoint выше; один policy contract, прежний recovery owner |
| MO1 | Existing HTTP/original reader: до двух одновременных read-only raw GET внутри recall | Сверить pinned raw API и пригодность двух чтений, без Cognee patch; если не поддерживается, оставить sequential с честным результатом, без скрытого retry |
| MO2 | Existing adapter + fork: confirmed ID → exact memory_status, точный термин/ошибка → qualified CHUNKS_LEXICAL, смысловой вопрос → CHUNKS | Lexical есть в pinned OpenAPI enum, это ещё не proof. До квалификации на существующем корпусе использовать CHUNKS; один маршрут |
| MO3 | Existing renderer + fork: компактные карточки/provenance, reuse релевантного результата в неизменном контексте | Без blind cache, потери source/status/applicability/coverage и обязательных правил |
| MO4 | Existing qualification owner: один ограниченный before/after проход затронутых существующих N5/B01–B12 | После MO0–3, real long-lived frontend, одинаковые corpus/model/profile/context; без новых кейсов/клиентов/платформ |

MO1: dedupe и round-robin до dispatch; completion order не меняет final порядок.
Максимум два GET in flight; общий 20s deadline, bounded cancel/cleanup только
своих запросов. По deadline/cancel прекратить новые GET; ошибка чтения даёт
partial, не отсутствие знаний. Сохранить caps, raw byte limits, UTF-8/пути
с пробелами и кириллицей, Windows PowerShell5.1/Core. Не распараллеливать semantic
queries/writers/lifecycle. Не добавлять общий scheduler или недоказанный batch API.
Допустимо максимум одно уже начатое speculative чтение сверх последовательного
раннего выхода; показать его calls/стоимость, а не скрывать как ускорение.

MO2: не добавлять LLM-классификатор. Exact ID должен иметь подтверждённые dataset
и scope, произвольный UUID не даёт доступа. Exact read не заменяет обязательный
standing/task recall, если нужны и другие знания. Dataset narrowing только
по подтверждённой области; иначе весь allowed set. Сохраняются standing query,
один task query на eligible reader, одна переформулировка после пустого relevant
answer, TOOL policy и optional OpenViking. Нет обхода шести областей, скрытого
lexical+semantic fallback, графового completion и добора карточек новым recall.
Ошибка lexical — честная ошибка/continuation в прежнем query budget.

MO3: сокращать доказанные повторы служебных полей/контекста, сохраняя полезный
факт, ограничения и evidence. 1600 токенов — на один recall payload, не всю задачу.
Exact originals могут быть длиннее: стоимость учитывать, доказательство
не обрезать ради метрики. Diagnostics остаются у existing logs/evidence owner,
без новой telemetry/token ledger. Межоперационный cache originals, graph/hybrid/
agentic completion, новые модели/embeddings/БД и изменения Cognee исключены.
[Официальные search modes](https://docs.cognee.ai/core-concepts/main-operations/legacy-operations/search)
— справка, не proof возможностей pinned1.6.5.

### Конечная приёмка MO

| ID | Критерий apply; фактический статус — в едином отчёте MO |
|---|---|
| MO-AC1 | Готовый проект default-on без memory prompt; explicit off/отказ сохранён; association later/no answer не даёт binding. Повтор/reload не меняет IDs/cycle, нет reset/автомиграции соседей |
| MO-AC2 | Исходные эталоны, current original/status/scope/applicability; stale/out-of-scope применения = 0. Reader сохраняет порядок/caps/partial/cancel/deadline, ошибка не превращается в пустоту |
| MO-AC3 | Known original не ищется semantic query только ради того же ID; lexical имеет pinned native proof; один маршрут, прежний standing/task/reformulation budget, без нового LLM |
| MO-AC4 | Прежние 20s/24 candidates/8 cards/1600 tokens всего recall payload; нет необоснованного роста always-on rules/tool schemas. Устранены доказанные повторы, свежие originals не заменены cache |
| MO-AC5 | Сопоставимые wall time, calls principal/recall/raw, tool duration, полный agent input/output/cached input, named tokens/UTF-8 bytes; ingestion/index/internal unknown не скрыты, parent/child не суммируются |
| MO-AC6 | Сохранены N5/B01–B12/failed/sealed evidence; code/native proof/RegisterChange разделены. Нет новых кейсов, Gate6/G6, рабочих установок или публикации |

Ожидается меньше ожидания на original-read пути без потери правильности;
из трёх задач не назначаются hard SLA/обещанный процент. MO1 учитывает максимум
один extra speculative GET; другие этапы не увеличивают поисковые запросы.
Экономия контекста доказывается полными сопоставимыми input/output, а не bytes
карточек. Cached input входит в input, reasoning — в output: не считать дважды.
Недоступная метрика unknown, не ноль; не вызывать модель ради подсчёта.
Стоимость graph ingestion не исчезает от ускорения raw reads.

В разрешённом MO4 фиксируется
конечная матрица: улучшение, явно принятый trade-off или конкретный остаток.
Малые отклонения времени не создают бесконечного цикла; после двух ремонтов
без acceptance/owner narrowing сравнить owner-local вариант и rollback по
package-architecture.md. Завершённый G5 остаётся историческим, новый proof
относится только к MO.

## G5: конечный результат, 2026-10-27

[Единый итог](evidence/g5-codex-completion-2026-10-27.md) закрывает N1–N7 в
согласованном контуре. По решению пользователя B03/B09/B10 и оставшийся N5
проверены native Codex CLI; прежний Cursor proof сохранён, новых Cursor действий
нет. Текущий source6828/r49 установлен штатно; matching memory policy bytes
не изменились, использован existing qualification-only dependency owner.
Active cancel/resume/owned restore и fresh current-original/recall подтверждены;
новых writer/state/recovery owners, runtime patches и случаев нет.

Исходные paired результаты сохранены, преимущество над файлами не доказано.
Смена модели не превращает три продолжения в новый парный score или экономию.
G5 completion не разрешает Gate6/G6, рабочую миграцию, выпускную qualification
вне описанного контура либо публикацию workflow/fork/homes. Расширение rollout
по-прежнему требует доказанной пользы или отдельного принятого trade-off.
R6/шесть областей/common connection/canonical home/ai_rules_1c прежние;
более ранние текущие статусы ниже исторические. Регистрация — отдельный ledger.

## G5 B03/B09–B10: ограниченное продолжение, 2026-10-26

[Единый memory report](evidence/g5-common-continuation-2026-10-26.md) фиксирует подготовленный repair оснастки B03 и
фактический повтор шести сохранённых backend-запросов B09/B10:82 HTTP200,
без Ladybug locks/recall errors. Native cache4→6, прежние image/data/account,
параллелизм2 и лимиты2CPU/5GiB; старый контейнер и stopped backup сохранены.
Это backend subset; полные ответы агента B03/B09/B10 не приняты. Пользователь
сейчас работает на ПК, поэтому UI-ввод остановлен до свободного окна; состояние
и восстановление тестовых настроек сохранены в continuation. G5/N5 остаток открыт,
исходные оценки не заменены. Новых случаев, Gate6, рабочей миграции и публикации нет.

## G5 N7 follow-up, 2026-10-26

[Единый memory report](evidence/g5-common-continuation-2026-10-26.md) фиксирует зарегистрированный watchdog/API-key
unit7b8 и bounded fair-selection repair с owner24/0. Пользователь исправил только
B11 context на customer при прежнем эталоне; обе arms PASS. Follow-up9/12 PASS,
B09/B10 native Ladybug lock failures, B03 unverified harness restart. G5 открыт;
исходный baseline, N5 остаток и разделение source/native/registration сохранены.
Registry SHA/home/business routing прежние. Gate6, рабочая миграция и публикация
не выполняются; новых обязательных случаев нет.

## G5: актуальный прогресс продолжения, 2026-10-26

[Единый follow-up memory owner](evidence/g5-common-continuation-2026-10-26.md) заменяет прежний текущий
статус остановки, сохраняя исходный sealed failure report. Source repairs
установлены штатным update на обоих isolated PM5 roots. Reset/resume/history,
шесть областей, canonical homes/applicability, actual Kilo/Cursor tools и
stopped backup/restore с repair до admission подтверждены в описанных границах.
N7: все 12 frozen pairs выполнены; на 11 однозначных задачах files11/11,
Cognee5/11; B11 противоречив и не принят. D8 byte/token repair проверен source
suite, но повтор B01 всё ещё пропускает целевой факт. Native N5 policy proof
получен в описанной границе; broader writer matrix не объявляется закрытой.
**G5 не принят**: польза retrieval не доказана; source/native/registration различаются.
Shared native API key того же ordinary account проверен на штатно обновлённой
PM5-копии: fresh stdio/exact read, одна запись/fresh read/точный retire.
Часовой Bearer не требуется, Cognee patch и auth-refresh service не добавлены.
Один common ordinary connection, без employee ACL; R6 SHA и бизнес-каталог
не менялись, три homes только в qualification snapshot. OpenCode пропущен.
Gate6, рабочая миграция и публикация workflow/fork/homes не выполняются.
Более ранние «не запускать G5» и прежние blocker summaries ниже исторические.

## Устойчивое общее подключение, 2026-10-26

Обычная эксплуатация использует native Cognee API key (`apiKey` в существующем
private credential file, заголовок `X-Api-Key`). В установленном 1.6.5 нет
expiry-поля/TTL или проверки времени ключа; ключ действителен до native revoke.
Account остаётся тем же ordinary technical principal, все mapping/IDs прежние.
Legacy `accessToken` поддерживается, но часовой login JWT не продлевается.
При обоих полях используется только API key; auth failure не вызывает login,
fallback или replay. Файл читается при каждом запросе: оператор меняет его
атомарно, затем отзывает старый ключ. Пароль, refresh worker, новый secret store
или backend patch не нужны. Секреты не передаются реестру, инструментам или LLM.
Квалификация проверяет прежние IDs/current originals и свежий stdio; отсутствие
TTL подтверждается кодом native server, а не ускоренным временем или ожиданием часа.
Отказ/отзыв сохраняет существующие pending/точный status continuation; обычный
workflow не зависит от доступности памяти. Подробности — в follow-up evidence.

## Актуальная модель первого выпуска, 2026-10-26

Один общий Cognee connection/account; шесть областей определяют принадлежность,
релевантность и актуальность, а не полномочия/конфиденциальность людей.
[Единая сверка с G4](g4-common-connection-alignment.md) задаёт семантическую
поправку D2/D3/D5/D9/D10, сохраняет owners/budgets/currentness и отдельно
фиксирует совместимость existing G4 с common account. Старый G1/source proof исторический, ACL/grants
больше не являются входом G5. [Пересмотренный G5](g5-qualification-plan.md)
заменяет предыдущий четырёхаккаунтный план; запуск G5/Gate6/миграции/публикации
не разрешён. Нижние датированные результаты не переписываются как новая proof.

## План G5, 2026-10-26

[Пересмотренный конечный план](g5-qualification-plan.md) конкретизирует
6.2–6.4/6.6b и D8/D10: isolated dev-karimov, один ordinary technical account,
общие exact IDs, owner-confirmed homes и matching fork/host pair; native PM5/
client сценарии и frozen paired B01–B12. Все mapping entries используют
одинаковый technical read/write существующего G4, без матрицы прав людей.
Qualification snapshot homes не равен published данным. Новый source gate,
server patch, runtime owner или always-on context не вводится. Подготовка/запуск
G5, Gate6, рабочая миграция и публикация workflow не разрешены.

## G4: исходная реализация, 2026-10-26

Пользователь согласовал план и разрешил G4. Реализован scoped Cognee consumer:
шесть областей, exact-ID REST/stdio, cycle/continuation/pending/source, existing
registry/client/lifecycle owners и отдельный qualified fork candidate.
[Общая source-матрица и границы](evidence/g4-source-implementation-2026-10-26.md)
отделяют fixtures, native proof и регистрацию. G5, Gate 6, рабочая миграция и
публикация workflow не запускались и не разрешены. R6/закрытый G3 прежние;
отсутствие homes не обходится. Исторические запреты G4 ниже относятся к прежним
поручениям. Source checkbox разделов 2–5 не закрывают native/installed часть:
она остаётся в 6.2–6.4/6.6b. Регистрация определяется только RegisterChange/Status.


## Конкретный план G4, 2026-10-25 — только подготовка

[План реализации G4](g4-implementation-plan.md) фиксирует G4.0–G4.7, шесть
областей, native REST frontend в existing MCP owner, cycle/continuation,
qualified fork/host route и конечную source границу перед G5. Он использует
опубликованный R6 SHA `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73` и actual r47 lock;
назначенных homes в R6 нет, shared-product write не включается по догадке.
D9 остаётся одобренным; план не является разрешением реализации, новой
квалификацией G3 или приёмкой памяти. Gate6/рабочая миграция/публикация workflow
не запускаются. Исторические readiness формулировки ниже читать через эту границу.

## R6 закрыт: данные опубликованы, 2026-10-25

Пользователь согласовал восьмипроектный кандидат и явно разрешил публикацию данных.
[Единая публикационная квитанция](../add-product-project-registry/evidence/r6-publication-2026-10-25.md): main существующего Git-реестра,
SHA **`0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`**; registry/catalog/relations прочитаны из одного commit,
schema/reference и 8/8 resolved contexts passed. Актуальный publisher registry
сохранён без ручных правок. Registry AC-36–38 и R6 выполнены; в memory AC-44
закрыта зависимость наполнения. Optional homes отложены осознанно для registry-only;
shared-product native приёмка, G4/G5 и R1–R5 от этого не становятся PASS.
Runtime, MCP, ai_rules_1c и ownership не меняются. Разрешение относилось только
к данным: G4/Gate6/рабочая миграция/публикация workflow не выполнялись.

## R6: владелец timeout cleanup

[Исправление подтверждённой причины Git deadline](../add-product-project-registry/evidence/r6-git-deadline-repair-2026-10-25.md) сохраняет existing cleanup owner и его authority. Неиспользуемые CIM-запросы к уже завершившимся Git parents исключены; live identity, pinned handle и ошибки lookup проверены. Original ProductProjectGitSave.Tests.ps1 и оба deadline assertions неизменны. Final focused5/0/0; source registration — отдельно через RegisterChange/Status. Memory не получает нового cleanup/updater, budget или installed state. Данные реестра/fae719c и принятая граница G3 не менялись; публикация и G4 не разрешены.

## Актуальная граница G3 — согласована 2026-10-25

**G3 закрыт в принятом PM5 / Windows 11 / Kilo и Cursor контуре; Codex — только core/API.** [Единая итоговая матрица и остаток до выпуска](../add-product-project-registry/g3-acceptance.md) определяет текущий статус, приоритетный перед историческими записями ниже. Непроверенные клетки не стали PASS; заявленная поддержка сохранена. Полная выпускная квалификация отделена от закрытого G3. G4, Gate 6, рабочая миграция и публикация workflow не разрешены; данные реестра опубликованы по отдельному разрешению R6.

[G3-LD1 / integrated native PASS, 2026-10-25](../add-product-project-registry/evidence/g3-legacy-executor-integrated-2026-10-25.md): после сохранения обеих сторон конфликта повторён исходный single PM5 downgrade source7ba9→oldfa0, exit0/381883мс; main+sibling clean, old helper/pins0.4.15/schema1/locked, pending0 и CF/DB/history unchanged. Два downgrade blocker закрыты. Новых cases нет; регистрация отдельно подтверждается source-delivery Status. Full G3/AC18/39 и memory AC43/G5 открыты; OpenCode SKIPPED, Gate6/G4/рабочая миграция/публикация вне допуска.

[Промежуточный mode repair до migration handoff, 2026-10-24](../add-product-project-registry/evidence/g3-managed-downgrade-mode-partial-2026-10-24.md): legacy wire/environment/argument исправлены, 97/0/0/0 owner tests. На той же PM5-копии direct downgrade прошёл прежнюю mode error, но exit1/87125мс на **G3-MANAGED-DOWNGRADE-AI-RULES-NOT-NEWER**; snapshot 400b27db91cc4fdb80a81e70a998ad29 сохранён. Named downgrade/G3/AC-39/memory AC-43/G5 ещё не приняты. Текущие процессы завершены; новые проверки/регистрация/lifecycle отложены на согласованное пользователем окно холодного A/B. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Исходный lifecycle PM5 до mode repair, 2026-10-24](../add-product-project-registry/evidence/g3-pm5-lifecycle-2026-10-24.md): новая отдельная capsule-копия прошла first unattended old-caller update (322555мс), поздний list/preview/select, отказ несовместимому пакету и restore-compatible. Actual downgrade FAIL: **G3-MANAGED-DOWNGRADE-DEPENDENCY-MODE**, старый post-copy не принимает mode=workflow. Snapshot/copy сохранены, recovery status работает только как диагностика. Fork остановлен до Gate6/создания worktree; full G3/AC-39 не принят. Исходный current PM5 сохранён. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Функциональные изменения каталога на current PM5, 2026-10-24](../add-product-project-registry/evidence/g3-project-metadata-functional-2026-10-24.md): 10/10 public commands в итоговом наборе; rename, typical/custom, СППР/Mantis links и functionality/home add/change/remove применены без client writes. Exact teardown 46/46, DB/старые roots/capsule сохранены. Новых workflow defects не найдено; полная G3/AC-39 и memory consumer/G5 не приняты. Warm excess принят пользователем; OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[G3 publisher-only/offline repair и повтор стоимости, 2026-10-24](../add-product-project-registry/evidence/g3-publisher-cost-repair-2026-10-24.md): две причины исправлены в existing context/journal owner, 101/0/0 tests и exact installed PM5 repeat; 20 пар/режим, paired delta median **1.170 / 4.002 / 1.494 с**. До/после не является чистой оценкой ускорения на общем занятом ПК. Дополнительные 20 full-window no-op дали **1049.731/1240.7921мс**: median goal1000мс превышена на 49.731мс, p95 goal2000мс выполнена; По решению пользователя от 2026-10-24 G3-PM5-WARM-STARTUP-MEDIAN закрыт как ACCEPTED DEVIATION: добавочные 49.731мс допустимы и не блокируют завершение G3; диагностика/оптимизация и повтор ради этого порога не требуются. Фактический результат относительно цели остаётся неизменным. Полная G3/AC-39 не принята. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Парная стоимость динамических режимов PM5, 2026-10-24](../add-product-project-registry/evidence/g3-paired-dynamic-cost-2026-10-24.md): 20 AB/BA пар на режим, 120 observer-off samples; paired delta median publisher-only / endpoint / offline **6.206 / 10.544 / 3.801 с**.80 online samples с дополнительной сменой origin URI сохранены отдельно и заменены полным fixed-URI повтором; offline 20 пар retained. Endpoint G3 обновляет два клиента против одного legacy; offline legacy сохраняет подключения без full sync. Измерительный пробел B5 этого subset закрыт, существенная задержка и полная cost/G3/AC-39 приёмка остаются открытыми. OpenCode SKIPPED; Gate6/G4/рабочая миграция/публикация не выполнялись.

[Остаток G3 на текущем PM5, 2026-10-24](../add-product-project-registry/evidence/g3-remaining-qualification-2026-10-24.md): Codex core/API прошёл 11 реальных вызовов Code/Graph, включая полезные чтения, отказ для чужого проекта, reload и новую сессию без запуска модели. Три режима Startup прошли функционально; диагностические окна 5,426 / 6,896 / 3,532 с не являются парным замером добавочной стоимости. Матрица 39 AC и 12 клиентов обновлена: Kilo/Cursor сохраняют прежний pass, OpenCode — SKIPPED. Полная registry G3/AC-39 остаётся непринятой; точный остаток B1–B5 указан в отчёте. Сохранность стенда и истории подтверждена. Gate 6, G4, рабочая миграция и публикация не выполнялись.

[Нативные клиенты на текущем PM5, 2026-10-24](../add-product-project-registry/evidence/g3-pm5-native-clients-2026-10-24.md): Kilo 7.8.15 / VS Code 1.142.0 и Cursor 3.27.12 выполнили по четыре реальных чтения Code/Graph до и после Reload Window. OpenCode 1.19.3 сохранил PM5-контекст и подключения после renderer reload, но квота модели заблокировала вызовы инструментов: **G3-OPENCODE-PROVIDER-QUOTA** [пропущен по решению пользователя](../add-product-project-registry/evidence/g3-opencode-skip-2026-10-24.md) в текущем прогоне; это не PASS и не устранение квоты. Смена версии первого Cursor и автоматические записи клиентов учтены отдельно; окончательная сохранность 46 путей, базы и истории подтверждена. Полная registry G3/AC-39 остаётся непринятой. Gate 6, G4, рабочая миграция и публикация не выполнялись.

[Стоимость G3 и baseline, 2026-10-24](../add-product-project-registry/evidence/g3-cost-baseline-2026-10-24.md): сопоставимый current-package legacy unbound baseline подготовлен; 20 AB/BA блоков, 100 retained samples + 4 warmups. Полный Startup median/p95 **0.995591 / 1.168819 с**, цель 1/2 с выполнена; paired whole CLI без профилировщика **0.548018 / 1.428991 с**. Запас median всего 4.408850 мс, устойчивый SLA <1 с не доказан. Прежнее превышение6.314 мс не округлено в pass, подробные phase probes отделены от benchmark. G3-B5 закрыт для сопоставимого warm no-op PM5 subset; полная G3/AC-39 остаётся BLOCKED по остальным клеткам. Ниже сохранены исторические результаты; новую стоимость определяет этот отчёт. Gate6/G4/рабочая миграция/публикация не выполнялись.

Актуальная зависимость G3.7 — [единая registry-матрица](../add-product-project-registry/evidence/g3-final-qualification-2026-10-20.md): G3/AC-39 и memory installed AC-43/G5 открыты, включая client/platform и cost ограничения. G1/Q1–Q7/D9/G2 сохраняют прежний допуск; текущая доступность provider перед будущим opt-in проверяется отдельно. Шесть областей, canonical home, ai_rules_1c и optional OpenViking не меняются; отдельного memory startup/recovery/ledger не добавляется. G4, рабочая миграция и публикация в этом срезе запрещены; AC-44 потребляет тот же будущий release population AC-36–38.

Разбор задержки Startup и лишних квитанций принадлежит registry owner: [контракт и повторные проверки](../add-product-project-registry/evidence/g3-startup-repair-2026-10-20.md). Memory consumer использует тот же pinned operation context; reuse checked applied projection после refresh/SHA/input проверки не добавляет memory cache, updater, refresh или provider probe. Unchanged single-client sync сохраняет project-wide proofs остальных клиентов. Полный G5/AC-43 не закрывается этим source/synthetic subset; engineering цели Startup, шесть областей, требования canonical home и выпускного наполнения прежние.

Registry-owned [re-enable/defer repair и original PM5 proof](../add-product-project-registry/evidence/g3-owned-mcp-defer-repair-2026-10-22.md) сохраняет прежние ownership/collision guards и пользовательский defer при ordinary reuse applied revision. Будущий memory consumer использует тот же контекст и решение, без собственной коррекции MCP, baseline store или updater. Это bounded dependency result; full G3/AC-39 и memory4.2/AC-43/G5/44, release population и остальные ограничения остаются открытыми.

## Context

Мотивация и границы — [proposal.md](proposal.md); проверенные исходники и точный снимок зависимой постановки — [context-sources.md](context-sources.md). Это новый потребитель change `add-product-project-registry`, а не его замена. В baseline уже есть MCP selection/client writer, reset с фазами и controlled fork; шесть scoped datasets и их привязка ещё не реализованы. Managed clause fork пока не квалифицирует новые providers и называет общий templates project-scoped вопреки ITL host policy.

## Goals / Non-Goals

**Goals:** один неизменённый Cognee достаточен; небольшой проверяемый слой параметров/идентичности; полезные знания связаны с шестью областями и основаниями реестра; task state восстанавливается точно; измеримая стоимость.

**Non-Goals:** свой memory engine, правка Cognee, двухсторонняя репликация, обязательный OpenViking, массовый импорт, вторая IAM/каталог/очередь/updater/lifecycle. Ни одна новая постоянная служба Windows или elevation не становится предпосылкой обычной работы.

## Decisions

### D1. Три места хранения, шесть типов принадлежности

| Место | Авторитетное содержимое |
|---|---|
| Общий Git-реестр | Продукты/проекты/источники/отношения из зависимой спеки. Никаких заметок, receipts или секретов. |
| Штатный общий экземпляр Cognee в сети | Исходные записи знаний в datasets, права и производные graph/vector данные; versioned backup/export штатными средствами. |
| Пользовательское хранилище ITL вне reset tree | Идентичность workspace/workplace/cycle, компактное продолжение, immutable привязка applied context, cache и pending receipts. |

Настройки базы и реальные verification/result status остаются у прежних владельцев. Заметка не дублирует их в качестве нового источника истины. Контекст продолжения содержит ссылки и следующий шаг, а не полный transcript. `memory.md` остаётся источником строгих устойчивых правил; это не седьмая область searchable knowledge.

### D2. Области отображаются на штатные datasets, по одному месту записи

| Область | Ключ | Условное имя dataset | Срок действия |
|---|---|---|---|
| Задача + ветка + база | workspaceId + cycleId | `itl_task_<cycleId>` | Текущий цикл до reset; затем явная история |
| Локальный проект | workspaceId | `itl_workspace_<workspaceId>` | Переживает reset, зависит от локальной установки |
| Рабочее место | developerId + machineId | `itl_workplace_<workplaceId>` | Пользователь и машина, не RDP session |
| Продукт/конфигурация | productId | `itl_product_<productId>` | По применимости, источникам и ревизиям |
| Проект | projectId | `itl_project_<projectId>` | По границам и правилам проекта |
| Организация | organizationId | `itl_org_<organizationId>` | Для допущенных пользователей внутри сети |

Имена — детерминированные labels, native IDs/owner и instance подтверждаются API общего технического подключения. Task/workspace/workplace datasets lazy; product/project/org один раз подготавливаются тем же account. Нет отдельного admin principal, выдачи grants людям, IAM/provisioning service или личных дублей shared dataset. Deployment map связывает business scope с exact native ID; label collision не подменяет его.

Переименование/смена endpoint не меняет business ID; независимая копия локального проекта получает новый workspaceId, перенос сохраняет его явно. Нет обязательной карты versions: rev evidence хранится и без profileId. Общая область без проверенных native IDs остаётся unverified; допустимая узкая локальная работа продолжается.

Подключение Cognee одно техническое для workflow; native principal не идентифицирует разработчика. User-local machine/workspace IDs сохраняют принадлежность рабочего места и независимой копии, новая терминальная сессия их не меняет. Области не гарантируют backend секретность между людьми. Credential остаётся у existing MCP owner вне Git/reset; pending/continuation не публикуются автоматически.

Знание получает наименее широкую достаточную область. Состояние эксперимента — task; особенность установки — workspace; особенность tooling — workplace; продуктовый механизм — product; клиентская доработка — project; проверенная универсальная практика — organization. Основной агент выбирает область по смыслу факта и подтверждённым правилам, без дополнительной LLM и вопроса пользователю на каждую запись. При неоднозначности сохраняется узкая область/candidate, без расширения readership. Один факт не копируется в шесть datasets.

У продуктового факта одно каноническое место записи — dataset продукта, указанного подтверждённой картой knowledgeArea (D4). Например, независимый от ERP механизм PM, обнаруженный в ERP+PM, сохраняется в PM КОРП; origin остаётся ERP+PM и его проектом. КОРП и ПРОФ читают этот dataset только для разрешённых им областей/условий. Факт с зависимостью от ERP остаётся в продукте ERP+PM, а клиентская особенность — в проекте. PM4/PM5 и расширения не объединяются по названию. Неизвестный home не заменяется обходом всех ancestors/descendants: до уточнения остаётся исходный project/task candidate.

### D3. Небольшой context-bound MCP adapter, без изменений Cognee

Чистый resolver получает applied context существующего registry owner и возвращает разрешённые dataset references. Один scoped MCP frontend, запускаемый существующим способом клиентской интеграции, передаёт операции штатному сетевому Cognee под пользователем. Он не открывает embedded graph файл на каждом ПК, не управляет reset и не владеет machine-wide state. Постоянный отдельный сервер-координатор для ITL не нужен.

Frontend сохраняет native-shaped `remember(data, dataset_name)`, `recall(query, datasets, search_type, top_k)` и точечные поддерживаемые status/retirement операции. Отсутствующий read scope заменяется разрешённым набором, explicit scope только сужает его. В qualified managed route основной агент обязан явно передать `dataset_name` из предложенных допустимых назначений; native optional parameter не изменяется в Cognee, но binding не принимает его пропуск как молчаливый task default. Пропуск/неоднозначность оставляет датированный local pending с intended scope; это не подтверждённое сохранение постоянного правила. Постоянное исправление проекта выбирает project/workspace по смыслу и переживает reset; результат эксперимента выбирает taskCycle. До backend call проверяются identity общего подключения, текущий binding, область и TOOL policy. Backend dataset permissions продолжают действовать. Клиентский dataset label не даёт права сам по себе. Идентичность/namespace/version объявляются при квалификации, не угадываются.

Для общего dataset другого владельца штатный MCP lookup имени может быть недостаточен, в том числе при записи. В этом конкретном пути adapter переводит подтверждённую привязку в поддерживаемый SDK/REST запрос с точным dataset ID того же provider и пользователя. Это не обход `off/required` и не новая primary store. Нет silent unscoped recall, custom SQL или внедрения своего policy внутрь Cognee. Неподдерживаемая операция оставляет binding unverified с конкретным продолжением. До зависимой реализации квалифицируются native exact-ID shared read/write, прочтение оригинала и актуального статуса D5. Если контракт требует нового общего брокера/очереди/версий/форка, apply возвращается на architecture checkpoint вместо расширения слоя.

Допустимые области ограничивают provider pipeline до извлечения/graph expansion/LLM. Проверка включает одноимённые узлы в двух datasets. Контекстуальный scope не подменяет права: одна только каталоговая связь не разрешает чтение. После confirmed revoke новые обращения и кеш недопустимы. Отзыв на реальном backend входит в canary; пока consistency не доказана, общий binding не считается квалифицированным.

### D4. Реестр потребляется, его политика не копируется

Зависимый change предоставляет стабильные IDs, effective settings, pinned SHA/hash и resolver `product-knowledge-applicability`. Он задаёт проектные роли только `code`, `graph`, `productDocs`; остальные MCP общие. Поэтому descriptor общего Cognee находится в существующих общих MCP settings/профиле организации и endpoint registry. Выбор business project/product определяет datasets и применимость, не собственный адрес Cognee и не четвёртую MCP-роль. Прежняя цепочка local override → project → profile → product относится к трём указанным ролям и не переносится на память. Личный выбор/disabled/TOOL off сохраняется у текущего MCP owner; qualified memory opt-in не включает выключенный provider.

**Согласованный interface dependency:** 2026-10-18 в `add-product-project-registry/product-knowledge-applicability` включено необязательное `knowledgeAreas.<area>.memoryHomeProductId` того же `catalog/product-relations.json` snapshot. Один непустой stable product ID должен существовать в каталоге и входить в `availableIn` области; массив/null/невалидная ссылка отклоняются registry validator. Назначение/изменение home подтверждается человеком как общее правило. Отсутствие поля валидно, но общее назначение не угадывается; при разных homes неоднозначных областей остаётся исходный project/task candidate. Поле не даёт доступа, не содержит provider URL/dataset ID и не создаёт новую область. Source schema/resolver квалифицированы G2; G3 принят в согласованном контуре, R6 опубликован. Реальных назначенных homes в R6 пока нет; memory consumer ещё не реализован, документальное согласование не заменяет его runtime proof. Memory consumer получает resolved контекст у прежнего владельца и не дублирует его policy.

Read set включает текущий product и канонические homes только тех известных knowledgeAreas, для которых resolver подтвердил `availableIn`, состав/зависимости/условия; затем сопоставляется с подтверждёнными native IDs общего подключения. Это не все связанные продукты. Широкий product dataset может содержать неприменимые текущему варианту функции: функциональный фильтр D8 обязателен, а private project scope не расширяется. Provider-local deployment mapping из D2 хранит IDs реально подготовленных общих datasets отдельно от business catalog; личные ключи/пути/receipts остаются ignored. Каталог не создаёт datasets/пользователей и не выдаёт grants.

Синхронизация выполняется одним startup шагом обычной команды существующего owner; nested calls используют его execution context. Memory adapter не fetch-ит реестр на каждом запросе. Status/read-only/recovery не включают новое автоприменение. Offline использует валидное локальное основание прежней ревизии, не remote tip. При откладывании конфликта applied/current/new сохраняется валидный **current local** с ручными изменениями на прежней ревизии каталога, а не откат к applied baseline. Новый отложенный план ничего не пишет. Изменения только publisher heartbeat не переписывают bindings. Смена productId остаётся явной; mixed old/new context исключён. До штатного перечитывания client tool catalog новый binding не объявляется активным.

Применимость остаётся у существующего чистого resolver: lineage отдельно от availability, origin отдельно от applicability/evidence, три результата. Он проверяет сырые карточки без нового LLM; unknown не выдаётся как applicable. Правила ограничения кандидатов и единственной допустимой переформулировки — D8. Смена карты не делает старое evidence проверкой нового продукта/версии.

Home участвует в hash выбранного контекста применимости; его изменение не вызывает записи неизменных client settings или native memory probe в startup реестра. Новое основание не переносит заметки: origin/evidence/исторический home сохраняются, полнота поиска старой истории явно не подтверждена до отдельной проверки потребителем. Автоматического копирования/удаления или добавления всех старых homes в read set нет. Реестр и его приёмка не зависят от реализации памяти; native перемещение, если потребуется, остаётся отдельной операцией memory owner.

### D5. Минимальная исходная заметка и точное исправление

Сохраняется один самостоятельный английский fact с неизменными 1C identifiers и компактным envelope: `noteId`, scope kind/ID, date/status, origin (project/workspace/cycle/source/revision), applicability (knowledgeArea/dependencies/conditions/versions при наличии), evidence references, supersedes ID. Envelope передаётся в штатном `data`, не требует расширения native schema Cognee. Dataset — техническая граница; текст envelope — provenance, не ACL. В receipt фиксируются provider data ID, dataset ID и durable/indexing state.

Предположение сохраняется только как candidate; причиной/проверенным исправлением оно становится после evidence. По известной карте классификация выполняется в основной задаче. Новая knowledgeArea/межпродуктовая связь и существенная неоднозначность клиента требуют подтверждения по реестру; приватные details перед общим распространением исключаются. Наличие права write не доказывает применимость.

Ссылка `supersedes` сама по себе не доказывает актуальность: correction может не попасть в semantic top_k. Перед выдачей фрагмента как действующего binding получает по стабильному native data/note ID оригинал/envelope и авторитетный текущий статус/ревизию штатным scoped API в текущем допущенном состоянии хранилища. Это не обнаружение скрытого rollback и не доказательство сохранения изменений после даты backup. Заголовок не обязан попадать в каждый chunk. Отсутствие original ID, envelope или доказуемого актуального статуса оставляет результат unverified и исключает его из действующих фактов; явно указанный пробел не равен отсутствию знания. Синтез другой моделью не восстанавливает provenance.

Допустимы штатное точное update/delete с последующим подтверждением либо поддерживаемая точная связь old ID → current correction/status, читаемая независимо от semantic recall. Один датированный текст или receipt на другом ПК не становится глобальным указателем актуальности. До зависимой реализации на выбранной версии надо доказать этот native путь и обработку старого fragment после correction/retirement. Не предполагается наличие удалённых MCP tools `get_document`/`list_data`; возможен поддерживаемый SDK/REST. При отсутствии подходящей native операции binding не qualified для действующих знаний: пересмотр checkpoint, без своего versioning service/БД.

Проверка оригинала/статуса ограничена cap кандидатов и общим read deadline D8, не является дополнительным semantic search. Точечное удаление не удаляет dataset/другие заметки. Backup/export выполняет оператор штатными средствами Cognee. Копия согласованно сохраняет originals и необходимое relational/graph/vector/mapping state на дату T; фиксируется возможный интервал потери последующих изменений. Полная неизменяемая история всех ревизий/отзывов и сохранение поздних изменений поверх старого snapshot не обещаются: native Q5 показал возврат старого состояния backup; прежняя ACL проверка историческая. Для коррекции shared original требуется поддерживаемая native операция через то же общее подключение, без отдельного writer/admin выбора.

**Контролируемый restore Q5:** оператор приостанавливает общее клиентское подключение → восстанавливает согласованную копию и фиксирует T/интервал потери → проверяет exact originals и известные поздние correction/delete → допускает только проверенные scopes → client owner выполняет fresh context/reload. Пока состояние не проверено, scope не current; независимая задача продолжается. Отдельные admin principal, grants/revoke/outsider checks и ACL rollback больше не требуются. Порядок native restore и client disable/reload используют прежних owners, без нового сервиса.

### D6. Циклом владеет существующий reset

Новый cycleId резервируется и сохраняется в existing reset state вместе с фазами до замены базы; успешное завершение активирует его. Resume читает тот же ID. До завершения новый цикл не утверждает готовность runtime. Fresh branch creation выделяет первый ID тем же owner. Никакой зависимости от изменения commit/названия нет.

Первое явное включение памяти в уже существующей ветке использует existing lifecycle/state owner: он сохраняет workspace identity, сохраняет user-local workplace отдельно от технической identity подключения и выделяет начальный current cycle в branch records **без reset/init/восстановления базы**. Если IDs уже существуют, повтор/прерванное включение использует их; конкурентные сеансы проверяются через прежний writer/hash ownership, не новый global lock. Стартовый cycle означает только область памяти: текущая установка исправлений/проверок по-прежнему неизвестна без доказательства прежнего владельца. Контекст/чат без нового подтверждённого binding не пишет в новую task область до перечитывания; выключение/повторное включение не создаёт новый cycle вместо reset.

Старый cycle исключается из обычного read set нового контекста без серверного удаления. Старый чат остаётся old-bound либо получает stale-context с продолжением; он не записывает в новый dataset. Явный historical read помечает старое состояние. Общий опыт уже в product/project переживает reset, но «исправление установлено в базе» требует новой проверки. Нельзя использовать память для разрешения запуска 1C, обхода clean-tree guards или текущей verification.

Task continuation и pending notes хранятся в user-local каталоге вне `src`, branch reset tree и tracked runtime; одновременные обновления используют scoped ownership/hash существующего state writer. Memory-only route нового сеанса сначала прямо читает компактное continuation и список scoped pending/receipts даже при отсутствии Cognee; выбирает относящиеся к текущему scope записи, old task показывает только как историю. Постоянная project/workspace correction доступна после reset и до восстановления backend. Это ограниченное чтение локального fallback, не загрузка всех журналов. Операции не коммитят fallback и не требуют связи с Cognee для reset. Проверки «reset pending/complete» берутся из существующего lifecycle state, не из ответа памяти.

### D7. Совместимость policy и optional OpenViking

| Контракт upstream | Managed решение |
|---|---|
| Memory-only route и загрузка policy по триггеру | Сохраняется; полный lifecycle/каталог/tooling corpus не загружается |
| Recall-first, correction-capture, rule-friction, Memory line | Сохраняются у владельца fork; schema/runtime не заменяют фактический save |
| Native remember/recall(CHUNKS), один durable write | Сохраняются; qualified binding требует явный `dataset_name` из допустимых назначений |
| Full-cycle/spec all eligible readers; quick-fix first reader | Сохраняется, optional не означает required и не означает unscoped |
| Cognee → OpenViking → templates | Порядок сохраняется среди допустимых writers; закрытая заметка не может уйти в общий templates |
| Generic dated fallback в root memory.md | Узкая managed адаптация: private pending/unconfirmed вне reset tree с прямым чтением в новом сеансе; root memory.md остаётся для строгих правил |
| Четыре критерия memory.md и отсутствие unsolicited evolve | Сохраняются |

Managed clause меняется у controlled fork в отдельной upgrade/release работе после explicit architecture checkpoint. Semantic delta ограничен: qualified opt-in и явный выбор write destination, private pending fallback/read route, корректная shared templates граница. Остальные triggers, query budget, ambiguous-write handling и приоритеты generic policy сохраняются. Host overlay несёт только binding/владение и условную ссылку на qualified route, не переписанную полную policy. Текущий `USER-RULES.append.md` направляет project-specific corrections в root memory.md: будущий source-template update должен явно оставить это legacy-поведением и выбрать D6 private fallback для qualified route. Иначе новая fork clause и host overlay противоречат друг другу. Строгие критические правила memory.md сохраняются в обоих режимах. Нет автоматического upgrade ruleset, patch установленной копии или ослабления policy ради совместимости.

OpenViking не устанавливается, не получает зеркала и не требует симметричной реализации шести областей этим change. Существующие External MCP entries сохраняются. Если пользователь явно включает его в managed memory, обычный вызов допускается только с уже квалифицированным scope; иначе это unverified/required gap и отдельная дальнейшая работа, не автоматическая пересылка туда private notes. Отсутствие optional provider не вызывает setup reminder о необходимости двух движков.

### D8. Бюджеты и отказ без новой блокировки workflow

Один task recall на выбранный eligible provider использует объединённый разрешённый dataset set. Начальный настраиваемый профиль Cognee: `CHUNKS`, до **24 backend-кандидатов**, после проверки original/current status и применимости — до **8 карточек / 1600 фактических токенов** агенту. Dataset/context scope применяется до retrieval/graph expansion. Нативный metadata filter до candidate cap применяется лишь при доказанной поддержке; выдуманных параметров нет. Иначе отбор делает чистый resolver над ограниченным набором внутри adapter до agent context. Это исходные измеряемые параметры, не доказательство полноты/оптимальности.

Native `top_k=24` может возвращать отдельные группы по dataset, поэтому первые
24 строки объединённого ответа не являются глобальным ranking. Adapter
чередует только разрешённые dataset groups, сохраняя native порядок внутри
каждой, и затем применяет прежний общий cap24 к кандидатам для current-original
lookup. Большая продуктовая группа не вытесняет остальные области. Нет шести
поисков, нового reranker, Cognee patch или увеличения read/token budget.
Флаг reformulation означает возможность одного уточнения при отсутствии
релевантного факта; присутствие посторонних cards само по себе её не отменяет.
Это не автоматический retry и не разрешение заполнять восемь карточек.

Не смешивать пустой relevant answer с недобором восьми карточек: одна переформулировка разрешена лишь после отсутствия применимых проверенных фактов, в прежнем dataset scope. Она не запускается ради заполнения бюджета. Standing query отдельный, один раз на unchanged session context, по первому eligible reader согласно fork. Успешная частичная выдача повторно не ищется без нового вопроса/изменения оснований. При исчерпании cap/deadline результат сообщает bounded/partial coverage, а не «знаний нет». Один batch или до 24 точных source/status lookups на поиск учитываются отдельно; тот же общий read deadline ограничивает их. Непроверенные остатки не поступают как действующие факты.

Budget не меняет обязательные правила и не запрещает явно открыть необходимый источник. В context идут selected scope/назначения, короткий readiness и компактные карточки. Общий response context/provenance передаётся один раз, карточки сохраняют короткую проверяемую ссылку и индивидуальные ограничения/status/evidence; полные GUID/envelope остаются в source/receipt, без бессмысленного повторения. Нет передачи всех backend-кандидатов агенту или автоматической дополнительной LLM-сводки. Schema/rule bytes измеряются до/после; токены — фактическим tokenizer, либо UTF-8 bytes как помеченная proxy, не «измеренные токены».

В первом профиле `remember` использует `self_improvement=false`, если это подтверждено live schema: штатные add/cognify сохраняются. Неподдерживаемый flag не отправляется; профиль отмечается несовместимым с этим минимальным режимом, его default costs измеряются и требуют явного решения до квалификации. Не инициируются отдельные improve/background jobs, импорт всей истории или обработка каждой реплики. Necessary ingestion/extraction/embedding всё равно расходуют ресурсы. Для Q7 фиксируются модели/параметры, ограничения calls/context/deadlines/resources и воспроизводимый контрольный прогон: клиентские операции, ошибки/повторы, длительность, объём контекста и доступный native/provider usage. Parent/child и started/completed одного run не складываются повторно. Для локальных моделей CPU time, максимум RAM и wall time измеряются за весь прогон; token/monetary детализация каждой внутренней операции не обязательна. Null usage остаётся unknown, оценки помечаются отдельно. При непроверяемых существенных расходах/ограничениях платного профиля требуется отдельное решение. Измерения квалификации/canary выполняются по запросу существующими средствами клиента/host, без нового tracing service и постоянного мониторинга каждого обращения.

В G5 сравнивается вся задача с files-only на одинаковых условиях: write/extraction/embedding/graph/index, optional improve, recall, bounded source/status calls, agent input/output/cached input при наличии данных, CPU/RAM/latency/rework. Coverage measured/estimated/unknown указан явно; недоступная внутренняя детализация сама не блокирует G4 при достаточном Q7 учёте всего прогона. Ingestion включён в итог, число reuse фиксируется. Повторные context inputs карточек учитываются: reuse убирает повторный search, но не делает контекст бесплатным. Заявления об экономии ограничены сопоставимыми измерениями; существенные unknown не превращаются в нулевую/полностью измеренную денежную стоимость. Без доказанной пользы расширение rollout требует явно принятого trade-off; требования безопасности при этом не меняются.

Deadline предлагаемого binding: read 20 s, durable write/status суммарно 60 s, настраиваемые значения с верхним пределом. При expiry возвращается доступный partial/status и конкретное продолжение; не бесконечное ожидание. Definite rejection, pending indexing и unconfirmed различаются. В последнем случае receipt сохраняется, штатный status/data lookup предшествует любому retry. Отсутствие Cognee не блокирует независимые команды; required gap останавливает только зависимую memory operation.

Private fallback остаётся в исходном scope и читается новым сеансом напрямую. Возврат backend не даёт массовой silent migration; сверяются receipts и выполняется scoped перенос. Общая очередь/служба синхронизации не создаётся. Выбор моделей/размещения Cognee фиксируется для отдельного разрешённого canary; место хранения не гарантирует локальность LLM-обработки.

### D9. Архитектурный checkpoint для будущего apply

**Статус 2026-10-19: пользователь отдельно одобрил D9. G2 реализован/квалифицирован в своей pure границе; G4 явно не разрешён и не начат.** Одобрение checkpoint не отменяет текущий запрет реализации памяти и installed migration. Native G1 уже passed для exact local profile этапа C, с сохранённым историческим failed proof; это не approval архитектуры, qualification русского/BSL retrieval или installed приёмка. До G4 нужны вместе: одобренная ниже граница, квалифицированный G2 interface и применимый G1 proof, затем явное разрешение реализации. При разрешении конкретного среза не требуется заново спрашивать согласие на каждую рутинную операцию внутри принятой границы.

#### Инвариант, воспроизводитель и выбор решения

Операция памяти использует один effective project/user/workspace/cycle context и только допущенные native datasets; повтор, reset или новый чат не расширяют scope и не объявляют неизвестную запись успешной. У каждого инварианта один владелец из таблицы ниже.

Минимальный воспроизводитель объединяет три случая: reset базы при неизменном HEAD; одинаковый объект в двух приватных datasets; общий product dataset под другим владельцем. HEAD/label не различают циклы, свободный native name lookup не доказывает shared ID, а prompt с названием проекта не изолирует graph retrieval. Files-only остаётся безопасной baseline/fallback, но не выполняет требуемый общий поиск знаний. Нужен один узкий context-bound adapter над штатным Cognee, а чистые business rules берутся из G2. Доработка Cognee, собственные graph/versioning/IAM/backup сервисы и общий runtime coordinator отвергнуты: native G1 подтвердил owner-local путь без них. Q5 остаётся административной процедурой допуска после контролируемого restore, без обнаружения скрытого rollback.

#### Владельцы и разрешённые изменения

| Владелец | Его единственная ответственность и затрагиваемое состояние | Граница |
|---|---|---|
| Registry owner | Один pinned business context G2: project/product, три роли, применимость/home и hashes | Память читает результат; не fetch/resolve/update каталога заново, не хранит там native IDs/mapping. G3 applied snapshot/recovery остаётся у прежнего owner |
| ITL MCP owner | Узкий native-backed remember/recall/status adapter, provider-local mapping instance/principal/dataset, memory receipts/cache/private pending и managed client binding | Existing client entrypoint `Write-Vibecoding1cMcpClientConfig` в `agent-1c.vibecoding1c-mcp.ps1` и прежний client writer; memory-specific leaf того же owner, без второй машины применения settings, global lock/queue или admin key |
| Lifecycle owner | Initial/current/reserved cycle ID в existing branch/reset records, identity workspace и её locator вне reset tree | `agent-1c.lifecycle.ps1`: existing branch state reader, `New-DevBranchCore`/`Reset-DevBranch` и их resume. Авторитет активации cycle только здесь; внешний locator/continuation не дублирует reset phases и verification state |
| ITL continuation owner в том же memory leaf | Компактные checkpoint/pending refs и идентичность workplace в user-local root вне reset tree | Один workspace/current cycle, без transcript и второй truth о базе/проверках; чтение нового чата по точной ссылке. Developer один на PC/RDP, machine различает workplace |
| Controlled `ai_rules_1c` fork | Correction capture, memory-only routing, TOOL/required, один durable save и provider/query policy D7 | Только отдельное owner-local изменение fork; host несёт qualified context/данные. Не патчить installed policy и не размножать правила по шести областям |
| Cognee и технический оператор | Original/current status, native graph/index/datasets и backup/restore | Шесть scopes в штатных datasets D2, локальные lazy и общие exact IDs под одним common account. Нет отдельного admin/grants setup; adapter не владеет backend provisioning/restore |

Новые данные ITL ограничены личным ignored state: identity/locator, компактное продолжение, mapping, receipts, cache и private pending; durable знания принадлежат Cognee. Точный каталог файлов остаётся детализацией owner-local реализации, а не поводом вводить manifest или shared coordinator. До записи проверяются user isolation и соответствие existing root; если имеющегося owner path недостаточно, срез возвращается к checkpoint. Конкурентное initial enable/resume использует прежний writer/guard и один ID, не отдельный межпроектный lock.

Не меняются admission/locks 1С, смысл lifecycle/verification/export и их критерии успеха, code/graph/productDocs selection, Mantis writer, delivery queue, server release, чужие settings/worktrees. Нет новой службы, автозапуска, elevation или расширения серверных разрешений. Windows 10/11/Server 2019+, PowerShell 5.1, local/terminal sessions и пути с пробелами/кириллицей сохраняются. Конкретные adapter/client runtime assets обязаны пройти действующую platform/client матрицу; native Linux stand этого не доказывает.

#### Состояние, завершение, отмена и восстановление

Readiness binding вычисляется из effective context, identity общего подключения, exact native mapping/currentness и реально перечитанного client catalog; отдельного lifecycle state нет. Config apply/pinned resume/restore у G3 owner. Отмена до записи сохраняет прежнюю установку, partial даёт прежний recovery path; отдельный shared-dataset/binding failure не разрешает молчаливую запись в task/global default.

Cycle резервируется в existing reset operation до замены базы и активируется только её успешным завершением. Resume повторно использует зарезервированный ID; незавершённый reset не разрешает новый task scope. Initial enable выделяет current cycle без reset/изменения базы. Disable/enable не порождает новый цикл. Checkpoint нового чата — refs/следующий шаг, не новая state machine reset.

Для native read действует суммарный deadline 20 s; durable write/status — 60 s по D8. До отправки отмена не пишет. После отправки отмена/обрыв не означают откат Cognee: сохраняется receipt с honest unconfirmed/indexing/durable/rejected status, перед любым повтором выполняется native exact status/data lookup. Durable receipt предшествует удалению private pending. Отсутствие доказательства не запускает слепой remember и не уничтожает исходный факт. Сетевой timeout не отменяет чужие операции и не приводит к бесконечному ожиданию; конкретное продолжение — status/reconcile либо исходный private pending route D7/D8. Никакого фона для replay нет.

После controlled restore оператор проверяет exact current originals и известные поздние correction/delete при приостановленном общем подключении. Только проверенные scopes допускаются к recall/remember, client owner сбрасывает cache/context. Старое backup state не обещает сохранить изменения после T; пользовательские права и их восстановление не квалифицируются.

#### Контекст, приёмка и откат

Сохраняются D7/ai_rules_1c memory-only route, correction capture и query budget; нет mandatory шести поисков, дополнительной LLM-классификации каждой записи или всегда загруженной карты продуктов. D8: один объединённый task recall, до 24 кандидатов и 8 карточек/1600 токенов после scope/currentness/applicability; standing query следует policy fork. GUID/context выдаётся один раз, reuse не делает повторный input бесплатным. До/после фиксируются schema/rule/context bytes/token proxies и весь ingestion/reuse workload. G1/Q7 подтверждает измеримость local profile; G5 отдельно проверяет качество, общий расход и заявления об экономии с measured/estimated/unknown, без нового tracing service.

Будущий harmless canary использует frozen B01–B12 baseline и фиксированные principals/models/settings: explicit association → отдельный memory opt-in → initial cycle без reset → durable write/status → fresh chat → исходная задача; затем unchanged-HEAD reset, две private области, ERP+PM → home КОРП → допустимый ПРОФ, conflict/defer/offline/partial recovery, revoke/restore и cache/reload. Windows/terminal варианты, отсутствующие фактически, остаются unverified. Native/fixture/config write/регистрация не заменяют этот proof. Матрица критериев — AC-39–43 и существующие scope/currentness AC.

Rollback выполняет существующий client/settings owner: disable только managed memory binding, сохранить IDs, old notes/checkpoint/private pending/receipts и Cognee datasets, проверить files-only продолжение исходной задачи и прежний reset. При необходимости downgrade используется совместимый helper/fork и owned restore. Remote catalog, shared Cognee и чужие client entries не откатываются этой операцией. Новые привилегии, обязательный сервис, backend/семантика native API вне qualified profile, иной state owner или расширение migration требуют пересмотра соответствующей границы; обновление native profile само не разрешает расширение полномочий.

**Рассматриваемое решение:** разрешить именно owner-local adapter/state и добавление cycle ID в прежний lifecycle, сохранив перечисленные владельцы, поддержку, бюджеты и recovery. Это короткий checkpoint внутри design по `docs/package-architecture.md`, не отдельный approval file. Его подготовка завершает документальную часть текущего запроса; D9 отдельно одобрен пользователем, запуск G4 по текущему запросу запрещён. Независимый G2 без installed writes/D9 runtime authority не блокируется этим решением.

### D10. Native допуск до разработки памяти

Перед разработкой зависимых adapter/runtime/lifecycle integrations этапа G4 нужно выполнить Q1–Q7 из [test-plan.md](test-plan.md#проверки-cognee-до-разработки-памяти) на отдельно разрешённом harmless экземпляре штатными MCP/SDK/REST. Это проверка возможностей провайдера, не предварительное написание ITL adapter и не разрешение на production данные/установку сейчас. Pure catalog fixtures и разработка реестра могут продолжаться независимо.

Доказательства содержат version/image digest/API mode/live schema, модели/embedding, connection identity/dataset IDs, test corpus, ожидаемое/фактическое поведение и bounded output. Каждый Q имеет passed/failed/unverified; configuration/tools-list или fixture не заменяет native proof. Read/write/status квалифицируются отдельно. Q4 требует original/envelope и авторитетного current status независимо от semantic hits: supersedes в тексте недостаточно.

До начала G4 должны быть passed Q1–Q7 по действующей редакции test-plan. Для Q5 достаточно native proof безопасной административной процедуры допуска после restore; обнаружение скрытого rollback/невозможная история поверх старой копии не требуются. Для Q7 нужны функциональный ограниченный ingestion profile и воспроизводимые достаточные измерения всего прогона D8; неизвестная внутренняя детализация сама не проваливает проверку. Отсутствующий flag не выдумывается; unknown usage не становится нулём. Редакция expected/actual фиксируется: исходный Q5 failed сохраняется, согласование нового контракта не делает его или обновлённый Q7 passed. Непроверенные новые сценарии и нарушения доступа/currentness по-прежнему запрещают допуск G4. Непройденный native путь возвращает design на checkpoint без своего IAM/versioning/graph service. Реестр независим; installed cache/disable/reload canary и paired cost с проверкой заявлений об экономии остаются G5.

## Risks / Trade-offs

- **Много мелких datasets** → lazy private creation и native provisioning только нужных общих областей; никакого декартова произведения. Latency/обслуживание измеряются, старые task datasets не читаются по умолчанию.
- **Native schema/permissions зависят от версии** → фиксировать instance/version/image digest и schema перед canary; менять узкую API-адаптацию, не Cognee. Unsupported остаётся unverified, не unscoped.
- **Граф сохраняет superseded/чужой факт** → scope до retrieval и native current-status/source proof независимо от semantic top_k; отсутствие native пути блокирует квалификацию до зависимой реализации.
- **Краткая выдача пропускает нужный опыт** → paired baseline оценивает успешное действие и повторную работу, не только размер ответа; параметры подстраиваются без ослабления scope.
- **Правила fork и host расходятся** → один semantic diff у fork owner, host несёт ссылки/данные; managed fallback изменение отдельно обозначено в D7.
- **Homes для shared-product пока не назначены** → использовать опубликованный R6 через существующий resolver, неизвестное общее назначение оставлять task/project candidate; свой каталог или automatic lineage sharing не строить.

## Migration Plan

### Общий порядок G0–G6

Согласован 2026-10-19 с [дизайном реестра](C:/Users/xment/OneDrive/Документы/1c-agent-workflow/openspec/changes/add-product-project-registry/design.md#общий-порядок-двух-changes). Таблица там владеет общим sequencing; здесь указаны обязательные memory зависимости и критерии, без нового coordinator.

| Этап | Зависимость и готовность со стороны памяти |
|---|---|
| G0. Границы и миграция | D9 отдельно одобрен; G4 по текущему запросу не начинать; проверить совместимые helper/fork и первый переход. Native stand и files-only baseline уже зафиксированы; pure G2 не ждёт D9 |
| G1. Native Cognee | До зависимого G4 пройти Q1–Q7 текущей редакции D10: Q5 administrative restore admission, Q7 ограниченный профиль и измерения всего прогона. Можно параллельно G2/G3, отсутствие proof не задерживает каталог; полное paired сравнение относится к G5 |
| G2. Основа реестра | G2.1–5 и интерфейс определены у registry owner: код one-SHA reader/resolver/publisher плюс consumer fixtures AC-01–03/05–07/27–29/35. Документы/mock не квалифицируют интерфейс. Synthetic contract допустим; реальные homes требуют подтверждённой карты. Pure G2 не равен G3 installed qualification и не ждёт D9/Cognee |
| G3. Установленный каталог | Отдельный registry checkpoint одобрен пользователем, source G3.0–7 разрешён: G2 → Git save / source scopes / один apply-recovery owner → bootstrap/startup → legacy compatibility → installed canary. Для memory G5 нужны применённый контекст и успешный association/update/recovery; memory development не ждёт всех неиспользуемых server работ. D9 не является approval G3; G4 и миграция действующих установок сейчас запрещены |
| G4. Память | После G1, готового G2 interface и отдельно одобренного D9/разрешения кода: native binding/scopes/receipts, lifecycle initial cycle/reset, continuation/pending и fork/host route. Выход — owner regressions и готовность к установленному canary |
| G5. Совместная приёмка | После нужного G3/G4: existing upgrade → association → separate memory opt-in → new chat/reset/update, client restore admission/cache reset/new context и paired сравнение всей задачи с measured/estimated/unknown. Claims ограничены подтверждёнными данными; native proof не заменяется fixtures |
| Наполнение к первому выпуску | Registry owner выполняет задачи 1.9–1.11/5.7 и AC-36–38: подтверждённый выпускной перечень PM4/PM5/расширений/компонентов и проектов, их resolved MCP/СППР/Mantis, карта основных областей/документации/ограничений и optional homes; опубликованный snapshot одного SHA. Обязательно перед первым registry-only выпуском и первым выпуском памяти; minimal seed G2 не заменяет данные. Подготовка после G2 не блокирует начало G3/G4 и не разрешает их автоматически |
| G6. Внедрение | Только после memory G5 и AC-44 по наполненному реестру: выделенные установки, disable/owned restore, затем расширение при доказанной пользе или явном принятом trade-off. Каталог выпускается независимо без памяти, выполнив registry AC-36–38 |

### Наполненный реестр как условие первого выпуска

Checkpoint G3, точные владельцы/срезы и budgets находятся в registry design; memory change их не дублирует. Registry AC-39 разделяет source/owner proof, отдельно разрешённый installed canary и первый выпуск. Native G1/D9 не закрывают G3, а G3 не включает память. Наполнение AC-36–38/здесь AC-44 может готовиться отдельно после G2, но обязательно до первого выпуска. До этого G3 canary subset не объявляется готовностью всего каталога. Startup 10 s относится к metadata Git, не к memory calls/Q5 restore или memory read/write budgets.

Source G3 client apply/recovery сохраняет один pinned registry context в существующем owner path; его local receipts и конфигурационные before-images не являются памятью и не уходят в Cognee/общий каталог. Пока bootstrap/startup и consumer admission не квалифицированы, наличие этого ядра не закрывает installed зависимость памяти и не разрешает G4. Канонические home IDs и оба projection hashes остаются прежним pure resolver contract; новый memory resolver/координатор не добавляется.

Authoritative процедура и состав — registry design «Наполнение к первому выпуску», задачи 1.9–1.11/5.7, AC-36–38. До первого выпуска памяти проверяется тот же опубликованный Git snapshot каталога/отношений/endpoint descriptors: подтверждённые продукты/проекты, resolved настройки и покрытие согласованного перечня основных областей кратким назначением, `availableIn`, зависимостями/ограничениями и первичными ссылками. Осознанное отсутствие необязательного binding/home допустимо; неподтверждённый пробел не считается готовностью. Полная документация остаётся в BookStack/источнике, не импортируется в Cognee автоматически.

Память использует прежнюю bounded selected projection и явно объявленный набор shared-product сценариев первого выпуска. Каждый такой сценарий имеет подтверждённый home по карте и отдельно проверенные native dataset IDs/mapping/currentness у memory owner. При отсутствии home общий факт остаётся узким кандидатом; registry-only выпуск не требует принудительного заполнения всех homes или запуска Cognee. Изменения выпускаемого snapshot после приёмки сверяются по затронутым настройкам/правилам, не переиспользуют несовместимый proof.

Это одна проверка зависимости AC-44 перед выпуском, без второго data registry/resolver/updater, bulk ingestion, новых provider функций, увеличения бюджетов запросов или постоянно загружаемого каталога. Native G1, готовность G2, G3/G4/G5 и source publication сохраняют свои прежние границы; текущий запрос уточняет только документы и не начинает наполнение, миграцию или реализацию.

### Переход существующей установки

1. Новый пакет не включает Cognee сам. Для локального проекта без `projectId` сценарий первого интерактивного update предлагает выбрать/создать проект или «позже»; deferred выбор живёт в existing ignored selection и не повторяется при каждой команде. Unattended/отсутствие ответа не назначают project ID. Association preview/overrides/receipts/resume/restore принадлежат registry owner; это не memory updater.
2. После validated association пользователь отдельно выбирает **включить память / позже**, в том же setup path при желании. Требуются Q1–Q7, поддерживаемые helper/fork, фактически перечитанный client context и current originals; registry project selection не означает memory opt-in. `TOOL off/required`, disabled и personal settings сохраняются. Нет вопросов на каждую область и установки OpenViking.
3. Первое включение существующей ветки создаёт local IDs/начальный cycle по D6 без сброса базы и без объявления прежнего runtime state проверенным. Повтор/resume и две сессии используют те же IDs. Новая lifecycle ветка наследует business binding и получает свой task cycle; workspace ID сохраняется или выделяется по прежним правилам переноса/независимой рабочей копии, а не по одному имени ветки. Соседние существующие worktrees не мигрируются.
4. Старые `memory.md`, локальные записи и receipts сохраняются. Нет автоматического импорта чатов/всего файла, очистки, переклассификации или пересылки в product/project/org datasets. Строгие whole-project правила остаются у memory.md; выбранный перенос отдельных фактов требует проверки scope/applicability/evidence и отдельного явного действия с durable подтверждением. Общие templates не считаются принадлежащей текущему проекту историей.
5. Если память недоступна/пока выключена, package update и каталог завершают независимый путь; требуемая memory operation сохраняет предусмотренный gap/fallback. При ошибке включения/partial client change прежний owner даёт pinned recovery, не объявляя memory ready. Disable сохраняет IDs/исходные заметки/pending и datasets, восстановление прав/удаление данных не выполняется. Downgrade проверяет совместимость helper/fork и использует owned restore; удаления одного ID недостаточно.

Реализация остаётся будущей работой. По последующему поручению «иди по плану» 2026-10-19 native этап C подтвердил новые Q5/Q7 на том же Cognee 1.6.5/dev-karimov profile; неизменные Q1–Q4/Q6 переиспользованы по совпавшим image/schema/auth/model identities. Исторический Q5 failed и старый Q7 unverified сохранены. G1 закрыт только для проверенного local profile, files-only baseline подготовлен; 1.4/1.6/1.7 имеют evidence. Это граница на момент этапа C. Позднее выполнен pure G2 handoff и пользователь одобрил D9; installed/paired G5 остаются открытыми, G4 явно отложен. Данные/границы proof — test-plan, этап C; свой versioning/IAM/backup/tracing service и provider patches не добавлены, production/fork/рабочие базы не менялись.

## Qualification status and remaining parameters

Архитектурные решения и критерии заданы; native реализуемость подтверждена G1 только на exact local profile этапа C. Общий exact-ID доступ, authoritative current status и original-by-ID больше не отмечаются как полностью непроверенные; языковое качество и installed путь этим не доказаны. D9 отдельно одобрен пользователем; G4 не разрешён. Registry home interface согласован, его код/consumer qualification G2 завершены. Реальные подтверждённые homes и full installed G3 остаются открытыми у registry owner; последующий native прогон G3 не прошёл все live критерии. Ни документы, ни fixtures не закрывают зависимости вне их фактической области.

Для разрешённого native прогона затем фиксируются адрес/version/image digest, модели/embeddings, harmless corpus, реальные dataset IDs/mapping и Windows/terminal stand. Эти параметры не дают разрешения на установку или рабочие данные. При отрицательном native proof пересматривается checkpoint и постановка; исходники Cognee и объём полномочий adapter молча не расширяются.

Текущий handoff G2: owner-local код и consumer proof на source base `181e1da00a08e56d2d0ac57d24a92e7187484e06`, worktree `product-project-registry-g2`, 42/42 focused tests на Windows PowerShell 5.1. Registry test-plan владеет evidence. Реальный pilot PM5 КОРП подтверждён, его integrations deferred, areas/homes не придуманы. Это qualification интерфейса для будущей памяти, без кода G4/миграции/новых native запросов.

Последующий разрешённый source G3.3–6 подключает registry binding, setup/startup/conflict/recovery и fixture-only compatibility path у прежних владельцев; evidence — соседний registry test-plan. Private selection сохраняет отдельный memory opt-in off, tracked schema/capability содержит только business IDs. No-op receipt включает local input hashes, без значений окружения; один bounded metadata check не запускает memory/provider/LLM запросы. Это не новый memory cache/updater, не допуск native datasets и не реализация G4. G1/D9, Q evidence, шесть областей и договорённости ai_rules_1c остаются прежними. Полные installed/platform/client критерии G3 и paired G5 ещё не приняты; обязательное наполнение AC-44 остаётся до первого выпуска.

После failed native квалификации 2026-10-19 отдельно разрешённое обновление трёх existing MCP завершено 2026-10-20. Текущий источник фактов — [registry test-plan](../add-product-project-registry/test-plan.md#обновление-трёх-mcp-и-повторная-квалификация-2026-10-20): attested BookStack/Mantis/СППР builds, passed live scope/compatibility controls и ограниченные resource/surface measurements. Отдельный экземпляр каждого MCP не требуется. Этот server proof не закрывает actual client/installed зависимость G5 и не создаёт business binding из qualification view. Память не получает второго capability ledger, fan-out или дополнительного updater/context. G1/D9/G2, шесть областей и ai_rules_1c не изменены; G4, миграция рабочих проектов и публикация workflow этим прогоном не разрешаются.

После [failed unattended PM5 offer](../add-product-project-registry/test-plan.md#продолжение-g3-codegraph-pm5-клиенты-и-startup-2026-10-20) общий registry input owner научился учитывать original compact log channel, включая old-runner fresh continuation. [Повтор на прежней capsule](../add-product-project-registry/test-plan.md#исправление-скрытой-консоли-и-повтор-pm5-2026-10-20) подтвердил whole-command success без association/consent/defer, с прежним `ai_rules_1c` r43 и сохранёнными seed/workload. Memory не получает своего prompt bridge, updater, marker/state или обхода registry admission. Это закрывает G3-PROMPT, но не полный registry AC-39 или installed G5/AC-43; обязательное наполнение AC-44 использует тот же registry 5.7 result. G4 и миграция рабочих проектов не начинаются.

[Продолжение PM5](../add-product-project-registry/test-plan.md#pm5-выбор-ассоциация-и-восстановление-2026-10-20) подтвердило явную association и owned partial/resume/restore, но обнаружило **G3-CATALOG-LEGACY-ENROLLMENT**: catalog-only private preferences попадают в legacy MCP reconcile при следующем update. Это registry selection/compatibility blocker, который исправляется у прежнего владельца до принятия installed G3; памяти не нужен обход, свой enrollment flag, updater или изменение ai_rules_1c. `memoryOptIn=false` в проверенных ассоциациях сохранён. AC-43/G5 остаётся открытым; Q1–Q7/G1/D9/G2, шесть областей и AC-44 не переопределяются, G4 не начинается.

Последующий owner fix `8ee68833…` сохраняет private property без legacy defaults и использует одну stateless классификацию в существующих automatic consumers. Ни memory flag, ни отдельный storage/updater/state owner для обхода legacy reconcile не добавляются; legacy native body и его обязательные guards сохраняются. [Квалификация](../add-product-project-registry/test-plan.md#owner-fix-enrollment-и-разбор-gate-6-2026-10-20) различает whole post-copy и same-version branch-resume. Gate 6 разобран по старым native artifacts и неизменному source, без исправления/загрузки PM5. Full installed G3/AC-43/G5 и AC-44 остаются открытыми; G4 не начинается.

Native переход новой версии отдельно выявил inaccessible input в captured post-copy child. Вопрос остаётся у существующего registry/update owner и переносится в foreground caller после exact terminal/snapshot/branch proof; lifecycle continuation не задаёт его. Прерванная попытка сохраняется как непринятая, memory не получает prompt bridge, собственный updater или consent. Подробный контракт и проверка настоящего перехода версий — в [registry design](../add-product-project-registry/design.md).

Enrollment owner fix квалифицирован в registry bounded PM5 journey; полный G3 не закрыт из-за Gate 6, G3-LEGACY-CALLER-OFFER и остальных source/client/stand controls. Manual select или установка нового caller не заменяют first-upgrade offer AC. Память сохраняет те же зависимости и не реализует собственный переход; [общие результаты](../add-product-project-registry/test-plan.md#итог-повтора-enrollment-2026-10-20) остаются у registry owner.

Контракт first-upgrade input уточнён у [registry owner](../add-product-project-registry/design.md#first-upgrade-input-у-того-же-lifecycle-owner): optional offer снова выполняет новый post-copy child, используя консоль проверенного caller той же signed lifecycle операции. On-demand stateless leaf сохраняет pipes/cleanup, обслуживает существующие вложенные catalog вопросы и не создаёт нового процесса, IPC, marker/state, updater или полномочий над другой операцией. Прежний перенос только в foreground caller — сохранённая промежуточная попытка, а не итоговый контракт. Compact/unattended не спрашивает; пустой ответ и ошибки не создают consent/defer; intermediate parent не спрашивает повторно. Actual first update неизменённой legacy PM5 capsule остаётся обязательным. Память не получает своего input adapter, provider calls или always-on context; ai_rules_1c и memoryOptIn=false сохраняются. Gate 6/G4/рабочая миграция/публикация не входят в исправление.

First-upgrade PM5 proof c264cbe5 закрыл G3-LEGACY-CALLER-OFFER у registry owner; сразу после первого update master/branch clean, later не включает память. Дополнительный select/restore выявил G3-CATALOG-RESTORE-FORMAT: descriptor значения восстановлены, но JSON keys переупорядочены и master dirty. Это незакрытая registry settings/recovery зависимость, а не разрешение на memory workaround, G4 или рабочую миграцию. [Native результаты](../add-product-project-registry/test-plan.md#первое-обновление-legacy-caller-2026-10-20); Gate 6/AC-43/G5/AC-44 остаются открытыми.

G3-CATALOG-RESTORE-FORMAT исправлен у existing registry settings/apply/recovery owner: исходные descriptor bytes и hash своей записи остаются в прежнем ignored receipt/compatibility baseline; exact restore разрешён только для неизменённого файла, иначе сохраняется owned-property merge и binding conflict. Нового memory состояния или updater нет, private later и memory opt-in не меняются. Source a2e6931e прошёл 89/89 focused tests. [Native replay](../add-product-project-registry/test-plan.md#точный-restore-descriptor-2026-10-20) пока не выполнен: factory отказал до новой copy из-за отсутствующей исходной 1Cv8.1CD sealed seed. Capsule/admission и прежняя dirty copy сохранены. Поэтому native G3-CATALOG-RESTORE-FORMAT, full G3 и зависимые G5/AC-43 остаются открытыми; шесть областей, ai_rules_1c, Q1–Q7/D9 и обязательное наполнение AC-44 не изменены. G4/рабочая миграция/публикация не начинались.

## Dependency согласованный capsule recovery, 2026-10-20

Пользователь согласовал у registry/source fixture owner отдельный Prepare Develop из path/SHA-bound исходной capsule и положительного capacity budget. Сохраняются прежние DT/source.bundle/state/context, published N-1 caller, existing native restore/guards/claim и исходная последовательность first update → later → select → restore; no automatic fallback, Recapture или Release/publication route. Новый owned target отделён от старого seed и failed copy; receipt явно помечает sealed-capsule admission, currentness пропавшего raw seed остаётся unavailable. Память не получает recovery state, updater или нового разрешения; native G3-CATALOG-RESTORE-FORMAT до результата открыт, как и full G3/AC-43/G5/AC-44. Шесть областей, ai_rules_1c, Q1–Q7/D9 неизменны. Gate 6, G4, рабочая миграция и публикация не начинаются. Подробный контракт и приёмка — registry design/test-plan, без второго каталога или механизма recovery.

## Dependency результат capsule recovery, 2026-10-20

Registry/source owner закрыл bounded native G3-CATALOG-RESTORE-FORMAT: [результаты](../add-product-project-registry/test-plan.md#результат-recovery-pm5-из-capsule-2026-10-20), [evidence](../add-product-project-registry/evidence/g3-capsule-recovery-2026-10-20.json). Exact capsule восстановлена в новый owned PM5 target; old caller fa0e3c начал первое обновление, два dependency failures сохранены, official pinned resume с local artifact exact locked SHA завершил upgrade. Фактический later → late select → restore вернул исходные bytes/clean roots, private later/legacy=false/memory off; descriptor Git blob и restored DB совпадают с original reproducer/failed copy. Это не uninterrupted first-command success или новая single-command legacy-caller qualification. Старый seed/failed copy, 13 protected files/4 roots, семь Gate 6 artifacts и все 11 capsule artifacts сохранены. Original raw seed currentness unavailable; automatic fallback/Recapture/Release route не добавлены.

Focused 101/0/0 за 292.577 s плюс перекрывающийся ownership 3/0/0 за 17.862 s. Storage 113.310 s при budget 60 — over-target; новый suite, serial restriction, always-on context, memory/provider/LLM calls не добавлены. Locked on-demand asset URL дал HEAD 404; source-build SHA совпал, публикация/Release компонента не доказана. Client context unverified и nonblocking uvx/UI warning сохранены. Final Targeted/registration — existing delivery ledger. Full G3, G5/AC-43/AC-44 и остальные release conditions остаются открытыми; native G1/Q1–Q7 не переоткрываются, текущая provider readiness перед будущим opt-in проверяется отдельно. Шесть областей/ai_rules_1c/Q1–Q7/D9 без изменений; Gate 6, G4, рабочая миграция и публикация не начинались.

## Dependency source/client qualification, 2026-10-20

Действующая зависимость — [checkpoint Code/Graph](#зависимость-checkpoint-codegraph-и-версии-источника) ниже: registry metadata и явные отличия проекта/source, без обязательного indexed revision proof. Обновление документов не закрывает remaining installed acceptance и не разрешает G4.

[Исторический registry-owned result](../add-product-project-registry/evidence/g3-source-client-qualification-2026-10-20.md) подтверждает native Codex core/API PM4/PM5 и reload без LLM turns в указанной области. Его прежний exact-version gap не является текущим prerequisite; remaining client/installed критерии открыты. Memory использует pinned context без нового probe/cache; шесть областей/canonical home/ai_rules_1c/optional OpenViking прежние, G5/AC-43/44 открыты, G4 не начинался.

## Зависимость: checkpoint Code/Graph и версии источника

**Действующая редакция 2026-10-21** использует [один registry contract](../add-product-project-registry/design.md#различия-проекта-и-подключённого-mcp-источника) и [AC-08-a–h](../add-product-project-registry/test-plan.md#план-проверки-привязки-codegraph-и-версии-источника). Название/версия конфигурации и сведения об индексации уже публикуются в registry; бизнес-происхождение source, его назначение и отличия проекта задаются явно в каталоге/карте. Обязательные Code/Graph patches, новый native sourceKey/manifest/stamp и доступ к исходникам Graph исключены из зависимости памяти и блокеров G3. Исторический [source result](../add-product-project-registry/evidence/g3-source-binding-implementation-2026-10-21.md) сохраняет свои факты, но прежний exact-version criterion больше не является обязательным.

Memory потребляет только selected applied projection: текущие project/product IDs, краткие доработки/ограничения, origin/назначение Code/Graph и опубликованные версии источников с registry provenance. При custom PM5 КОРП → типовой MCP сведения MCP относятся к базовому продукту; клиентский вывод подтверждается project/local evidence. При ПРОФ → КОРП найденная функция не считается доступной без подтверждённой карты ПРОФ. Отсутствие server revision само по себе не понижает все факты до candidates; достаточность evidence зависит от утверждения и применимости. Неоднозначная зависимость от custom кода остаётся project/task candidate по прежнему правилу, без автоматического общего home.

Source version/endpoint/назначение не заменяют productId/dataset/home/grants и не объявляют старые заметки автоматически перепроверенными. Remember/recall/startup не опрашивают Code/Graph, не создают второго resolver, manifest/cache или business classification. Собственные native Cognee currentness/grants и Q1–Q7 сохраняются без ослабления; строгий currentness записи Cognee не зависит от отменённого exact-source proof.

Шесть областей, canonical home/read set, controlled ai_rules_1c recall-first/correction-capture/query/card budgets/Memory line и optional OpenViking прежние. Новые always-on rules/tool schemas и Code/Graph probes этой модели — 0; выводится только выбранная проекция с релевантными ссылками. G1/G2/D9 и отдельное разрешение G4 сохраняются, full G3 — installed dependency G5. [Registry implementation result](../add-product-project-registry/evidence/g3-registry-source-model-2026-10-21.md) подтверждает source 2.1/2.1b и bounded selected projection; [native ПРОФ → КОРП/reload follow-up](../add-product-project-registry/evidence/g3-prof-native-reload-2026-10-21.md) закрыл connect/read/reload gap в Codex core/API subset без runtime/server patches. `httpOrigin` из status не заменяет native tool/scope evidence. Memory consumer ещё не реализован; origin/usage/limitations/project customizations не создают новый memory scope, не подменяют home/grants и не копируются во второй реестр. AC-43/G5/44, registry AC-36–38/39 и полный frontend/client/platform/installed остаток открыты. Gate 6, G4, рабочая миграция, deploy/reindex и публикация не начинаются.

## Dependency client/installed qualification, 2026-10-21

[Registry-owned report](../add-product-project-registry/evidence/g3-clients-installed-2026-10-21.md) — единственный результат нового среза. Kilo native connection/reconnect и legacy installed PM5 b4338057 selection/owned failure recovery подтверждены отдельно от tools/frontend/latest installed acceptance. Default CLI скрывает корректные DTO source differences; исправление presentation остаётся у прежнего registry context owner, consumer не дублирует resolver/renderer и не получает нового startup probe. Проверенное JSON pipeline продолжение диагностическое и не always-on load.

Project-local Kilo/OpenCode aliases (4 имени / 2 endpoints) и native `$schema` normalization относятся к client interoperability и ownership, не к business IDs/datasets/canonical home/grants. Local tool API 404 не доказывает дефект Code/Graph/Cognee и не требует backend patches или memory bridge. Client tool-schema/token overhead пока не измерен; memory lookup/card budgets не меняются. Новые actual timestamp guards исправляют прежний hash-only all-20 claim, не переоткрывая независимые Codex config/Startup receipt checks. G1/Q1–Q7/D9/G2, шесть областей/ai_rules_1c прежние; full G3/AC-39, G5/AC-43/44 и release population AC-36–38 открыты. Gate 6, G4, рабочая миграция и публикация не выполнялись.

### Registry context CLI repair

[G3-CONTEXT-CLI-OUTPUT закрыт у registry owner](../add-product-project-registry/evidence/g3-context-cli-output-2026-10-21.md): public status/select context выводит selected projection compact UTF-8 JSON, без дополнительного pipeline; внутренний DTO не меняется. Custom → typical и ПРОФ → КОРП прошли actual child stdout и owner regressions. Memory consumer не реализуется, не копирует serialization/resolver и не опрашивает Code/Graph/Cognee. Saved observations сохраняют прежнюю freshness; version/source origin не становятся project version/home/grants. Context guard уточнён до 19 уникальных paths/root, прежний summary 20 не был фактическим count. On-demand output 2332–3071 bytes, always-on/tool schema/probe delta 0, query/card budgets ai_rules_1c прежние. Kilo/прочие client/installed/platform gaps, registry AC-39/36–38 и memory AC-43/G5/44 открыты; Gate 6/G4/рабочая миграция/публикация не затронуты.

### Registry-owned Kilo repair

[Единственный registry report](../add-product-project-registry/evidence/g3-kilo-native-fix-2026-10-21.md) закрыл Kilo aliases/API findings в native 7.8.15 CLI/core области. Existing client writer добавляет disabled imported aliases в собственный Kilo config, сохраняет names/permissions/foreign overrides и прежние ownership/preview/undo; memory не дублирует этот механизм. Диагностический MCP Apps flag применяется только к частному native qualification процессу, не включается memory/installed defaults.

2 connected/2 disabled, Code/Graph reads/negative scope/reconnect/instance reload проверены на исходных CUSTOM/ПРОФ roots; frontend/latest installed/platform остаток не закрыт. Native `$schema`/format metadata exceptions сохранены, fresh discovery не изменил 38 protected paths. Alias names/flag/schema не становятся project/product/dataset IDs, canonical home или grants. Future consumer 4.2 использует прежний applied context; startup/remember/recall не получает Code/Graph probe, alias registry, readiness state или нового token budget. G1/Q1–Q7/D9/G2/ai_rules_1c/optional OpenViking прежние; G4/AC-43/G5/44 и release population открыты. Gate 6/рабочая миграция/публикация не выполнялись.

### Native desktop dependency: явная граница frontend/worker

[Registry-owned desktop result](../add-product-project-registry/evidence/g3-desktop-native-2026-10-21.md) — единственный proof этого среза. Kilo VS Code подтвердил actual Ask Code/Graph reads для ПРОФ → КОРП; исходный Graph status input со строкой generation="null" failed и не принимается по part completed. Native Graph list возвращает pm5corp/default с inherited state без active_generation: отсутствие stamp/producer не блокирует действующую registry-only модель.

Cursor worker/discovery/reload подтверждены за login overlay, visible signed-in frontend/agent calls не приняты. Первоначальные OpenCode Default Project/403 сохранены; picker repair подтвердил original PROF root, [provider follow-up](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) — два actual reads и scoped reload на отдельной official 1.19.3. Selected-context/provider-403 закрыты только в этой native scope, установленная 1.18.11 и full matrix не стали passed. Auth/private profile/desktop routes/provider IDs не становятся project/product/home/grants; memory не добавляет bridge/alias/readiness state или обход native UI. Future 4.2/G5 потребляет один applied context без повторных desktop/Code/Graph/LLM probes при startup/remember/recall.

Новые native canary counters (4 provider requests, существенный input/cache) описывают проверку existing Kilo toolset, не измеренную G3/memory добавку. Memory budgets/ai_rules_1c/шесть областей/canonical home/Q1–Q7/D9/G2/optional OpenViking прежние; AC-43/G5/44 и registry AC-39/36–38 открыты. Gate 6/G4/рабочая миграция/публикация не выполнялись.

### Уточнение provider dependency

Первый registry report сохраняет 403 и counters после отказа. [Новый единый proof](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) закрывает provider-403 native subset на vendor 1.19.3: 1 turn/3 streams/2 actual tools, input56619/cache56887/output458/reasoning507, reported cost0; это не billing или paired memory delta. Шесть областей/canonical home/registry-source различия/ai_rules_1c не меняются. Source-only процедура проверяет vendor frontend/backend version и native payloads; always-on инструкции, memory schemas и installed prerequisites не расширены. G4/AC-43/G5/44 и registry AC-39/36–38 открыты, Gate 6/рабочая миграция/публикация не выполнялись.

### Vendor/provider boundary

[Owner repair](../add-product-project-registry/evidence/g3-opencode-provider-repair-2026-10-21.md) относится к qualification client: сохранённые 1.18.11/failed profile, отдельная неизменённая 1.19.3 и original PROF workload. Нет memory-owned client updater, header override, credential storage или requirement использовать Big Pickle. Native project_id/Graph namespace/provider version не определяют business scope, canonical home или grants; config version остаётся registry/applied context. Code/Graph/backend patches и exact generation stamp не возвращаются в обязательный план. Actual memory consumer и его G5 proof по-прежнему впереди.

### Cursor account boundary остаётся у native client

[Registry-owned native proof 22.10](../add-product-project-registry/evidence/g3-cursor-native-reads-2026-10-22.md) закрывает G3-CURSOR-NATIVE-AGENT-AUTH в другом signed-in профиле/installed3.26.16 по явному разрешению пользователя на original PROF root: actual stats({})/list_graph_projects({}), completed scoped payloads и native signed-in reload. [Прежний signed-out private3.25.9](../add-product-project-registry/evidence/g3-cursor-auth-qualification-2026-10-21.md) сохранён; configuration/worker green не становится account permission. Project switches временно включались и восстановлены через normal UI, private auth/enablement APIs и credential copy не применялись. Registry/memory не приобретают account storage/mapper/probe, provider/profile identities не определяют scope/home/grants.

Fresh19 unchanged, 30 owned processes штатно закрыты. Canary1 user turn/2 tools/UI12 s; tokens/provider requests/billing/paired delta не измерены, automatic traffic не объявлен нулевым, budgets прежние. Consumer4.2/AC-43/G5/44, full registry G3/AC-39/remaining installed/CUSTOM/platform/cost и release population AC-36–38 открыты. Ai_rules_1c/шесть областей/canonical home/optional OpenViking прежние; Gate 6/G4/рабочая миграция/публикация не выполнялись.


### Registry dependency: fresh update Startup owner

[Registry-owned fix и original PM5 first-pass](../add-product-project-registry/evidence/g3-post-copy-startup-repair-2026-10-22.md) устраняют независимый catalog startup до проверки post-copy snapshot: существующие phase classifier и update file post-copy сохраняют единственного владельца client reconciliation. Memory не вводит свой update hook/state/probe или recovery. Один first update на исходном old-runtime Kilo+Cursor root прошёл без дополнительных recovery/retry, прежний failed результат сохранён. Это bounded dependency proof; full registry G3/AC-39, AC-36–38 и consumer4.2/G4/AC-43/G5/44 открыты. Шесть областей/canonical home/grants/Q1–Q7/D9/optional OpenViking/ai_rules_1c прежние; Gate 6, рабочая миграция и публикация не выполнялись.

### Registry dependency: completed plan и actual applied

[Registry-owned repair/proof](../add-product-project-registry/evidence/g3-completed-resume-repair-2026-10-23.md) подтверждает actual marker перед success completed resume и предоставляет tested existing restore continuation при invalid/missing/mismatch. Memory consumer не принимает completed plan как отдельный источник контекста и не создаёт свой repair/cache/probe. Canonical registry context/шесть областей/home/ai_rules_1c прежние; full registry G3/AC-39, consumer4.2/G4/AC-43/G5/44 и выпускное наполнение открыты. Scope не включает Gate6, рабочую миграцию или публикацию.

### Registry recovery dependency: partial cancel, 2026-10-23 (исторический subset)

[Один registry qualification report](../add-product-project-registry/evidence/g3-pm5-partial-cancel-2026-10-23.md) подтверждает cancel на faulted partial и original resume/restore continuation, сохраняя единственного context/apply owner. Отмена ещё работающего writer остаётся evidence gap; full registry G3/AC-39 и consumer4.2/G4/AC-43/G5/44 открыты. Restore не задаёт persisted defer, следующий startup может применить актуальный каталог. Memory не дублирует recovery/кеш/проверки; шесть областей/home/grants/ai_rules_1c прежние.

### Registry recovery update: active-writer cancellation, 2026-10-23

[Единый registry qualification report](../add-product-project-registry/evidence/g3-pm5-active-cancel-2026-10-23.md) закрывает прежний named active-writer gap в PM5 native-helper subset с original resume/restore continuation. Context/apply/recovery остаются у existing registry/client owner; timing instrumentation не поставляется в runtime. Full registry G3/AC-39 и consumer4.2/G4/AC-43/G5/44 открыты. Memory не вводит собственный cache/recovery/probe; шесть областей/home/grants/ai_rules_1c и optional OpenViking прежние.

### Registry cost/concurrency dependency update, 2026-10-23 (исторический срез)

[Один registry batch](../add-product-project-registry/evidence/g3-pm5-concurrency-startup-2026-10-23.md) подтверждает same-user serialization/read-only status, сохраняя единственный selected-context owner. Full Startup window2.045/2.570 s сохраняет открытый **G3-PM5-STARTUP-WINDOW-COST**, который memory consumer не обходит отдельным updater/cache/probe. Это не memory implementation/token benchmark и не основание закрыть G4/AC-43/G5/44; full registry G3/AC-39 и прочие prerequisites остаются открытыми.

### Qualification update: lazy import и observer calibration, 2026-10-23

[Единый owner result](../add-product-project-registry/evidence/g3-startup-window-repair-2026-10-23.md). Existing lazy importer проверяет видимые функции через Function provider, сохраняя UI separation/idempotence; PATH/module discovery удалён у прежнего owner. Finding закрыт в проверенном current PM5 subset; full window 0.932/1.238 s. Instrumentation остаётся qualification-only, presumed overhead не вычитается; новых always-on/state/locks/barriers нет. Registry feature baseline/full G3/AC-39 и memory consumer4.2/G4/AC-43/G5/44 открыты. Память не добавляет отдельный updater/cache/probe или второй cost ledger.

### Qualification update: external edit после согласия, 2026-10-23

[Последующий owner repair](../add-product-project-registry/evidence/g3-mcp-foreign-byte-repair-2026-10-23.md) закрывает G3-MCP-FOREIGN-BYTE-PRESERVATION в исходной PM5 Kilo+Cursor области. Сортировка semantic projection сохраняется для сравнения; physical JSON правится существующим agent-1c.jsonc editor только в owned properties, без переупорядочивания чужих ключей. Existing text/BOM сохраняются; semantic no-op не вызывает editor/initializer. Один projected text определяет PlanOnly afterFiles, atomic write и receipt; consent/ownership/partial guard/pinned resume/restore прежние. Нового writer/coordinator/cache/lock нет. Старый failed report сохранён. На этом историческом срезе G3-PM5-UPDATE-COPY-STATUS-STALE оставался открыт после normal continuation; [последующий repair/replay](../add-product-project-registry/evidence/g3-pm5-update-copy-status-repair-2026-10-23.md) закрывает исходный PM5 subset при прежнем watchdog120 s. Memory использует тот же registry owner; full registry G3/AC-39 и memory4.2/G4/AC-43/G5/44 открыты.


## PM5 copy-status owner repair, 2026-10-23

[PM5 update copy-status repair](../add-product-project-registry/evidence/g3-pm5-update-copy-status-repair-2026-10-23.md): **G3-PM5-UPDATE-COPY-STATUS-STALE закрыт в исходном PM5 subset**. Existing snapshot/receipt owner использует прежний PID-owned heartbeat; watchdog120 s и assertions неизменны. Source compact перенос449705 ms и original installed update443186 ms завершились без retry/recovery, оба roots clean, snapshots680/359. 84/0/0 complete owner tests; Kilo+Cursor/DB/старые доказательства сохранены. Full G3/AC-39, остальные journeys/cost/population и memory dependencies открыты; Gate6/G4/рабочая миграция/публикация не выполнялись.

Snapshot capture и SHA/receipt prepared/copying/copy-complete выполняются под существующим Invoke-WithRunStatusHeartbeat: один PID-owned worker, прежний nested reuse/cleanup/terminal handoff. Все path/reparse/write-set/SHA/receipt guards сохранены; нового state/lock/cache/recovery owner нет. Бутстрап исправленного executing helper и исходный installed replay различены в evidence; package-version checkpoint меняет только docs, runtime/tests идентичны. Routine Startup/always-on context/tool schemas не менялись; provider/LLM/memory calls0. Прежний whole CLI +1.756 s не атрибутирован этим update-only repair. Registry ownership/product-source differences/canonical home и memory consumer dependency неизменны; Code/Graph/ai_rules fork не дорабатывались.

## Квалификация cache/local-record на текущем PM5, 2026-10-23

[Квалификация cache/schema/applied на текущем PM5](../add-product-project-registry/evidence/g3-pm5-cache-integrity-2026-10-23.md): пакет `fac4bc51` установлен штатным update за 376,761 с. **Подтверждены 8 групп сценариев, 11 CLI-вызовов в итоговом наборе.** Проверены сохранение validated applied при offline/неподдерживаемой схеме, безопасный отказ без привязки, отказ для неизвестного проекта и повреждённого applied, доступность status и продолжение после удаления внесённого тестом повреждения. SHA и mtime защищённых путей, база, бизнес-исходники и прежние доказательства сохранены. Полная G3/AC-39, остальные платформы/клиенты/сценарии, стоимость и наполнение реестра остаются открытыми. Gate 6, G4, рабочая миграция и публикация не выполнялись.

Существующий владелец контекста различает ошибки refresh/validation и offline snapshot. Оба пути сохраняют только проверенный applied context с предупреждением, без записи клиента. Без такого контекста операция отказывает; неверный hash applied запрещает основное действие, оставляя status доступным. Возврат внесённых тестом байтов не заменяет проверку штатного recovery. Код пакета, его тесты, архитектура и интерфейс registry–memory не менялись. Данные каталога и нативная готовность MCP проверяются раздельно; требования к exact indexed revision и доработке Code/Graph не возвращаются.

## Завершающий прогон G3: исправления у существующих владельцев, 2026-10-23

[Единый результат квалификации](../add-product-project-registry/evidence/g3-completion-2026-10-23.md) сохраняет отдельные source, installed, platform и выпускные границы. Defer без MCP-записей может завершиться с `prepared=false`: его selection уже изменён самой операцией. Поэтому forward resume сохраняет исходные preview guards, а restore и resume начатого restore используют сохранённые setting/client proofs и свежий preflight того же writer. Проверки чужих изменений и перед записью сохраняются.

Для bounded Git тот же открытый Process передаётся существующему `Stop-ItlUiToolProcessTree`, уже используемому lifecycle: остановка ограничена его деревом и проверяет identity. Три секунды зарезервированы внутри исходного абсолютного deadline на cleanup; лимиты startup 10 с/save 60 с не увеличиваются. Новый coordinator, состояние, lock family, callback для независимых операций, elevation или обычный MCP probe не добавлены. UI leaf подгружается только при timeout; normal no-op и always-on surfaces не расширены. Это применение существующего владельца ресурсов в пределах одной Git-операции.

Непроверенные Windows/client/installed клетки остаются обязательными; Gate 6 и G4 не подменяются этими исправлениями. Наполнение реестра до первого выпуска сохраняет отдельный статус.

[Итоговый прогон G3](../add-product-project-registry/evidence/g3-completion-2026-10-23.md): доступный current PM5 subset завершён; **полная G3/AC-39 BLOCKED** по G3-B1–B5. Два owner-local repairs прошли 132+12 source tests и installed repeat `dfae2ff3`; 90 config calls + update. Настоящие conflict answers/Ctrl+C, pending stable ID, damaged-applied owned recovery и transport 7,933/7,836 с подтверждены. Warm full median/p95 1,006314/1,353585 с: median goal остаётся недостигнутым, без округления/повтора ради pass. Gate 6, G4, рабочая миграция и публикация не выполнялись.


## Owner-local устранение динамической стоимости G3, 2026-10-24

[Report/JSON](../add-product-project-registry/evidence/g3-publisher-cost-repair-2026-10-24.md): publisher-only reuse разрешён только после validation нового snapshot, checked inputs equality и immutable catalog/relation blob equality; из registry игнорируется только top-level publishedAt. Defer/explicit decision/любой business или source-version/endpoint/input change возвращает полный путь. Новый revision/context фиксирует существующий zero-client-request journal с прежними CAS/proof/cancel/resume/restore и marker-last; writer errors вне freshness fallback. Offline повторно использует только уже validated snapshot того же SHA и prior applied с WARN, без повторного resolve/декодирования; другой SHA читается обычным owner. Main UI/facade readiness preview сохранён, нового cache/manager/barrier/provider patch нет. Это не изменение schema реестра, canonical knowledge home, ai_rules policy или G4 consumer. Warm median1049.731мс принят пользователем как допустимое отклонение (49.731мс) и не блокирует G3; оптимизация/повтор ради порога не требуются. Прежние1000/2000мс остаются инженерными ориентирами; измерения не переписываются.

## G3: содержательные изменения каталога, 2026-10-24

[Native installed evidence](../add-product-project-registry/evidence/g3-project-metadata-functional-2026-10-24.md) подтверждает, что publisher-only reuse не поглощает изменения selected project metadata, links или relations. Переименование сохраняет IDs; custom/typical и explicit home меняют knowledge context/hash; links заменяются целиком и меняют settings hash. MCP endpoints и native client files не менялись. Синтетические homes/links остаются private fixtures, не release population, provisioning или памятью G4; схема/владельцы/ai_rules policy не изменялись.

## G3: lifecycle qualification и downgrade handoff, 2026-10-24

[Native evidence](../add-product-project-registry/evidence/g3-pm5-lifecycle-2026-10-24.md) разделяет capability binding и совместимость dependency handoff: успешный restore-compatible возвращает baseline/снимает binding, но не доказывает successful old-helper post-copy. Current producer сохраняет mode=workflow, старый fa0e3c9 понимает fresh/locked и останавливает фактический downgrade. Это blocker общего update-workflow/dependency owner, без нового сервиса/адаптера/режима/receipt edits. Исправление не начато; сохранить exact failed snapshot и повторить исходный сценарий после owner repair. Registry-only acceptance не подменяет G4/G5; новых зависимостей G3 → G4 не вводится, текущий запрет G4 сохраняется.

## G3: исторический partial mode repair до migration handoff

[Implementation/negative native repeat](../add-product-project-registry/evidence/g3-managed-downgrade-mode-partial-2026-10-24.md): существующий dependency owner сериализует целевой schema1 как locked с теми же pins/intent, current schema2 остаётся workflow. Snapshot coordinator согласует lock/project/dotenv, inherited environment и explicit child argument до старого child, восстанавливает parent environment в finally; старый helper не патчится. Следующий отказ ai_rules not-newer ещё не диагностирован и не обходится. Это registry compatibility subset, не memory consumer/G4; полная G3/G5 остаётся открытой.

## G3: final mode repair и согласованный G3-LD1

[Exact proof и варианты checkpoint](../add-product-project-registry/evidence/g3-managed-downgrade-repair-2026-10-24.md). Existing dependency owner сериализует legacy schema1/locked; snapshot coordinator согласует inherited environment/explicit argument, finally возвращает parent environment и вызывает existing exact-bundle ai_rules migration до старого child. Standalone guards, pins/intent, CAS, result/rollback/SkipAiRules прежние. Main proof положительный; old sibling coordinator не знает plan и сохраняет прежние pins, поэтому whole transition не принят.

**G3-LD1 — APPROVED, 2026-10-25.** Пользователь согласовал сохранить current verified executor внутри existing update/recovery owner для всего legacy master+branch перехода, отделив его identity от old payload; source/cache resolver, receipts, per-root leases/status/resume/restore прежние, новый manager/state machine не добавлять. До copy проверить доступность exact executor и дать existing-source continuation при его отсутствии. Не переставлять branches до master commit без отдельного обоснования. Альтернативы — snapshot restore (не исходный arbitrary-target update) и новый shared manager/support reduction (не согласованы). Реализация разрешена только в этой границе; исходные failed proof и стенд сохраняются. Исходный current→old PM5 single native workload, foreign preservation, прежние fault/resume/restore контракты и no Gate6 — обязательные критерии; recovery/no-op или preformatted branch недостаточны. G4/memory consumer и рабочая миграция не разрешены.

Legacy master-commit-ready/master-committed checkpoints продолжают только commit/rollout: не повторяют dependency/rules writers и не переписываются в post-copy-running. Existing migration handoff ограничен pre-commit фазами; две red regressions исправлены guard существующего owner, итог focused handoff/commit6/0 (58 unselected). Это сохранение прежней recovery границы, не G3-LD1 implementation. Native15b и exact final Targeted proof разделены.

## G3-LD1: разрешённый объём 2026-10-25

[Текущий отчёт LD1](../add-product-project-registry/evidence/g3-legacy-executor-2026-10-25.md). Путь и commit текущего исполнителя фиксируются до copy в существующих recoveryExecutorRoot/recoveryExecutorCommit; target source/pins остаются прежними. Main post-copy и branch rollout принадлежат одному текущему owner, порядок master commit → branches прежний. Используются уже имеющиеся source checkout, transaction, per-root lease и continuation, без нового cache manager/service/state machine. Если exact current checkout недоступен, до copy требуется запуск текущего source-side `scripts/update-installed-workflow.ps1 -ProjectRoot <root> -SourceRoot <old-source>`; записанная identity повторно проверяется перед child.

Пользователь ограничил этот прогон: новые проверки и тестовые случаи не добавлять. Повторяются исходный saved-PM5 сценарий и уже имеющиеся owner-проверки; прежние assertions, workload, watchdog и recovery контракты сохраняются. Непокрытые отдельным fault run свойства не отмечаются PASS. Регистрация — один штатный RegisterChange после снятия A/B-паузы; код/нативный результат/регистрация учитываются отдельно. OpenCode SKIPPED; Gate6/G4, рабочая миграция и публикация запрещены. Полная приёмка G3 не следует из закрытия только LD1.

## G3-LD1: результат исходного PM5 повтора

[Native PASS](../add-product-project-registry/evidence/g3-legacy-executor-2026-10-25.md), implementation `3645c8e46184284b50573a6164709252533a986c`, single update oldfa0 exit0/331540мс. Current executor довёл master и sibling через прежний owner; новый branch dependency plan и exact pins0.4.15/schema1/locked, clean roots и pending0 подтверждены. Original protected-state rejection, restore-compatible, CF/DB, capsule/history сохранены. Два исправления existing harness (глобальный single-EXE override и чтение optional полей исторических receipts) документированы с failed attempts; mandatory assertions и исходная topology не изменены. Новые проверки/тестовые случаи не добавлялись. Регистрация — штатный RegisterChange после снятой A/B-паузы, authoritative результат этого же head читается из source-delivery Status, без правки tracked приёмки после регистрации. Общая G3 матрица/AC18/39 и memory AC43/G5 не закрываются одним LD1; OpenCode/Gate6/G4/рабочая миграция/публикация остаются в прежних границах.

## G3-LD1: интеграция без потери соседних изменений

[Исходный PM5 повтор на объединённом коде — PASS](../add-product-project-registry/evidence/g3-legacy-executor-integrated-2026-10-25.md), `7ba9f0a3ce6ebd08b227b4b35b65e43fe5b2f99c` → oldfa0, exit0/381883мс. Три конфликта lifecycle.ps1 разрешены rebase на принятый candidate8f7aaee4: сохранены foreign legacy master-only recovery, temporary-patch retirement Bind и наши exact executor/branch dependency plan; старый760 остаётся ancestor, ручных merge/queue правок нет. Первый native proof и конфликт регистрации сохранены отдельно. Та же topology, workload и assertions повторены; новые проверки не добавлялись. Full G3 не закрыт. Факт регистрации финального doc-only head читается из source-delivery Status для product-project-registry-g2; это отдельное доказательство доставки.
## R6: подтверждённые ERP+PM5 / УНФ+PM5 Mantis настройки

[Единый актуальный data result](../add-product-project-registry/evidence/release-population-2026-10-25.md) фиксирует решение владельца 2026-10-25: ошибки ERP+PM5 → поддержка PM5 (699), поиск ERP+PM5 → разработка PM5 (609) и поддержка PM5 (699); поиск УНФ+PM5 → разработка PM5 (609) и поддержка УНФ+PM5 (814), ошибки УНФ остаются814. Развитие обоих →609. Это данные одного каталога, не второй routing owner или новая memory policy. Data revision fae719cac93c820add276ff7201d84473b621543; pending scopes/target сняты. Registry reader/intent8/8 подтверждены, native write/client apply/публикации нет. G3 остаётся принят в согласованном контуре; G4, Gate6 и рабочая миграция не разрешены, предшествующий registration blocker не снят.
