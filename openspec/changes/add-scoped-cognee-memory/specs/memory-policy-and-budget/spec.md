# Spec Delta

## Purpose

Сохранить поведение памяти ai_rules_1c в упрощённом Cognee-only варианте и доказать полезность областей без необоснованного роста запросов, токенов и сложности.

## ADDED Requirements

### Requirement: Совместимость политики принадлежит controlled fork

Managed интеграция SHALL сохранять recall-first, correction-capture в том же ходе, полезные подтверждённые решения, `rule-friction:`, приоритет актуальных инструкций/источников, TOOL `off/auto/required`, отчёт `Memory:` и строгую роль `memory.md`. Общая политика SHALL изменяться только у владельца controlled fork; установленная копия и общая upstream policy SHALL NOT патчиться ITL helper. Само обнаружение Cognee SHALL NOT активировать неготовый managed binding.

#### Scenario: Исправление пользователя
- **WHEN** пользователь исправил неочевидный факт или постоянное условие работы
- **THEN** оно сохраняется в том же ходе в наиболее узкую достаточную область либо честно остаётся локальным pending; не запускается unsolicited изменение LLM-RULES

### Requirement: Cognee достаточно, OpenViking optional

Поддерживаемый первый вариант SHALL полностью работать без OpenViking. Он SHALL NOT устанавливать/включать его, зеркалировать записи или требовать второго backend для готовности. Для явно подключённых квалифицированных readers SHALL сохраняться triage scope upstream: full-cycle/spec — все eligible readers, quick-fix/standing — первый eligible reader. Write priority SHALL оставаться Cognee → допустимый OpenViking → допустимый templates; один durable save достаточен. Optional provider SHALL NOT расширять разрешённый scope.

#### Scenario: Только Cognee
- **WHEN** Cognee подключён и qualified, OpenViking отсутствует или off
- **THEN** шесть областей работают без предупреждения о необходимости второго провайдера и без дополнительных probes его установки

#### Scenario: Выбран required provider
- **WHEN** пользователь явно выбрал required provider, который недоступен или не имеет scoped binding
- **THEN** незавершённой остаётся зависимая memory operation с продолжением; политика не обходится alias или прямым HTTP, независимая работа сохраняется

### Requirement: Локальный fallback сохраняет область

При отсутствии успешного eligible writer SHALL сохраняться датированная локальная запись с областью, intended provider, причиной и состоянием вне reset tree. Она SHALL обнаруживаться новым сеансом прямым ограниченным чтением по scope, без зависимости от Cognee. Общий templates SHALL NOT получать project/customer/runtime facts; его eligibility ограничена действующей ITL-политикой. Локальная private pending запись SHALL NOT автоматически попадать в tracked/global memory.md; managed отличия — qualified binding/явное назначение, private fallback/read route и shared templates wording — SHALL быть описаны у владельца fork. Source host overlay SHALL явно различать новый qualified route и прежний legacy root fallback, без противоречащей fork инструкции. Остальная generic policy и строгая роль memory.md сохраняются.

#### Scenario: Нельзя сохранить проектное решение
- **WHEN** Cognee недоступен, а scoped OpenViking не выбран
- **THEN** решение остаётся в локальной области и доступно новому сеансу; запись в общий templates и ложное сообщение об успешной remote memory исключены

### Requirement: Выдача ограничена общим бюджетом

Selected context SHALL вычисляться программно без LLM и загрузки всего каталога. Один тематический recall SHALL передавать объединённый разрешённый набор datasets вместо отдельного агентского запроса на каждую область. Ограниченный backend candidate set SHALL отличаться от меньшего final agent budget. Scope SHALL применяться до retrieval; native applicability filter до cap используется только при поддержке, иначе чистая проверка original/current status и применимости выполняется над ограниченными кандидатами до выдачи агенту. Выдача SHALL сохранять проверяемые ссылки, ограничения и статусы с общим provenance без ненужных повторов. Обязательные инструкции SHALL NOT теряться из-за retrieval budget. Служебные schemas и always-on инструкции SHALL оставаться минимальными и измеряемыми.

#### Scenario: Все шесть областей содержат знания
- **WHEN** выполняется один task recall в Cognee-only режиме
- **THEN** нет обязательных шести remember/recall инструментов или двенадцати вызовов; native datasets selection ограничивает область, CHUNKS выдаёт bounded факты без синтеза ответа другой моделью

#### Scenario: Применимый факт ниже первых восьми кандидатов
- **WHEN** первые восемь найденных фактов неприменимы к ПРОФ, а нужный находится далее в пределах настроенного backend cap
- **THEN** он может попасть в final budget после фильтрации кандидатов; до восьми карточек агенту не превращается в top_k=8 до проверки, исчерпание cap сообщает bounded coverage

### Requirement: Поиск и сохранение не превращаются в фоновую фабрику контекста

Реализация SHALL сохранять upstream budget: один task query на выбранный reader, отдельный standing query на первом reader и одну переформулировку после пустого relevant answer. Недобор final budget SHALL NOT вызывать добор поиском. Bounded native original/status lookups SHALL учитываться отдельно и SHALL NOT превращаться в дополнительные semantic queries. Частичная/неподтверждённая выдача SHALL NOT доказывать отсутствие знаний. Она SHALL NOT импортировать всю историю чатов/репозитория, строить отдельный ITL граф, запускать LLM-классификатор каждой реплики или автоматически реплицировать заметки.

#### Scenario: Повтор того же вопроса в неизменном контексте
- **WHEN** релевантная выдача уже получена и scope/source/цикл не изменились
- **THEN** используется прежний результат; новые обращения требуют нового вопроса, изменения данных или штатного разрешённого retry

### Requirement: Первый ingestion профиль минимален и измерим

Первый профиль SHALL отключать automatic self-improvement штатным `self_improvement=false` при подтверждённой live поддержке, сохраняя native ingestion/graph. Unsupported параметр SHALL NOT выдумываться; несовместимый профиль и default costs SHALL явно требовать решения до квалификации. Отдельные improve/background jobs SHALL NOT запускаться автоматически. Профиль SHALL фиксировать модели, параметры обработки, ограничения calls/context/deadlines/resources и воспроизводимый способ измерения всего контрольного прогона. Клиентские измерения SHALL включать операции, ошибки/повторы, длительность и объём контекста; доступный native/provider usage SHALL сохраняться с источником и без суммирования parent/child или started/completed одного run. Для локальных моделей SHALL измеряться CPU time, максимум RAM и длительность всего прогона; точный token/monetary расход каждой внутренней операции SHALL NOT быть обязательным условием Q7. Недоступная детализация SHALL оставаться unknown, оценки SHALL явно отличаться от измерений. Если платный профиль не позволяет подтвердить существенные расходы, бюджет и ограничения, SHALL требоваться отдельное решение по этому профилю, а не предположение о бесплатности.

Сравнение G5 SHALL охватывать write/extraction/embedding/index, optional improve, retrieval, source/status calls и agent input/output, cached input при доступной метрике, с явным покрытием измерений/оценок/unknown. Первоначальный ingestion и повторное присутствие карточек в поздних context inputs SHALL учитываться; reuse SHALL NOT объявляться нулевой стоимостью контекста. G1/Q7 SHALL доказывать профиль и достаточность способа измерения; полный paired эксперимент и проверка заявленной экономии SHALL выполняться в G5.

#### Scenario: Повторное использование карточки после записи
- **WHEN** факт записан минимальным профилем, найден и использован ещё в нескольких ходах без нового recall
- **THEN** измерение учитывает первоначальный ingestion и все входы контекста, отдельно от экономии повторных запросов; неподдерживаемые/неизвестные usage категории не считаются нулём

#### Scenario: У incremental update нет детального usage
- **WHEN** native API не возвращает usage части внутренних операций локального профиля, но функциональный профиль и ограничения подтверждены, а весь контрольный прогон измерен по calls/context/latency/CPU/RAM
- **THEN** отсутствующие поля отмечаются unknown; доступные counters не суммируются повторно, эта неполнота сама не проваливает Q7/G4 и не разрешает заявлять неподтверждённую экономию; provider code/новый tracing service не добавляются

### Requirement: Квалификация доказывает исходную задачу и стоимость

Приёмка G5 SHALL включать native schema, действительную запись/status и чтение новым сеансом, а также paired сравнение Cognee и файлового baseline на одном корпусе/модели/условиях. SHALL измеряться правильность действий, чужие/устаревшие факты, полнота, доступные токены агента/backend, calls, latency, ресурсы локальных моделей и повторная работа; estimates/unknown SHALL перечисляться отдельно с границами покрытия. Количественное утверждение об экономии SHALL опираться только на сопоставимые подтверждённые измерения и SHALL NOT называться полной monetary экономией при существенных unknown. Конфигурация или fixture proof SHALL NOT заменять установленный canary. Нулевая утечка и отсутствие использования старого runtime state обязательны; неопределённость экономических показателей SHALL NOT ослаблять эти требования. Расширение rollout без доказанной пользы SHALL требовать явно принятого trade-off.

#### Scenario: Красивый короткий ответ, но задача не решена
- **WHEN** память уменьшила размер выдачи, но агент пропустил нужный вывод и повторил расследование
- **THEN** это учитывается как ухудшение результата/полной стоимости; экономия не объявляется, расширение rollout требует пересмотра или явного принятия trade-off

### Requirement: Память включена по умолчанию при готовой привязке

Init и первое обновление unbound проекта SHALL требовать существующую
опубликованную запись по registry setup contract; «позже», пустой ответ и local
draft SHALL NOT завершать переход. Создание/публикация записи SHALL выполняться
отдельно. Это SHALL NOT менять native prerequisites/default-on/explicit off,
создавать unscoped binding либо добавлять барьер независимым обычным командам.

Managed память SHALL иметь default-on policy после готовой явной project association и настройки общего Cognee. Existing setup owner SHALL автоматически подготовить binding при passed применимых native Q, совместимых helper/fork, applied registry context/native mapping и подтвердить client activation после штатного reload; отдельный memory opt-in/вопрос по каждой области SHALL NOT требоваться. Отсутствующая настройка SHALL означать default-on preference, SHALL NOT доказывать native readiness. Явные TOOL_COGNEE=off, disabled и сохранённый отказ/откладывание памяти SHALL иметь приоритет и сохраняться при update/reload; автоматическое повторное включение SHALL NOT выполняться. TOOL auto/required и eligible provider policy SHALL сохраняться у controlled fork.

Без prerequisites память SHALL сообщать unavailable/unconfigured с continuation, SHALL NOT угадывать project/dataset IDs или посылать unscoped запрос. Failure/partial binding SHALL иметь отдельный статус и прежний pinned resume/owned restore; независимые update/каталог SHALL продолжаться, required memory operation SHALL оставаться incomplete. Unbound legacy/no answer SHALL NOT автоматически ассоциироваться или мигрировать; переход рабочих установок SHALL требовать отдельного разрешения и прежнего setup owner. Disable SHALL сохранять data/IDs/pending; downgrade SHALL использовать compatibility/owned restore. Default-on SHALL NOT означать recall на каждую реплику, импорт старых заметок или автоматическую установку OpenViking/Cognee.

#### Scenario: Готовый проект без второго вопроса
- **WHEN** пользователь подтвердил ассоциацию/настройку, prerequisites готовы, memory setting отсутствует и явного отказа нет
- **THEN** setup включает qualified route по умолчанию, завершает штатный reload/native confirmation без второго вопроса; package success и readiness показаны раздельно

#### Scenario: Отключение переживает обновление
- **WHEN** TOOL_COGNEE=off, disabled или сохранён отказ от памяти и выполняется update/reload
- **THEN** off сохраняется, data/IDs/pending не удаляются, новые обращения к Cognee не выполняются

#### Scenario: Память по умолчанию пока недоступна
- **WHEN** действует default-on preference, но нет common connection, mapping или project association
- **THEN** unavailable/unconfigured с продолжением, без unscoped вызова/автоассоциации; независимая работа продолжается, required gap не скрыт

### Requirement: Старые заметки не становятся общими автоматически

Первое включение/обновление SHALL сохранять прежние memory.md, локальные заметки и receipts. Оно SHALL NOT импортировать весь файл/чаты, очищать, переклассифицировать или пересылать заметки в shared datasets автоматически. Strict whole-project rules SHALL сохранять роль memory.md. Перенос выбранных фактов SHALL требовать отдельного явного действия, проверки scope/applicability/evidence и durable подтверждения; общие templates SHALL NOT считаться историей текущего проекта.

#### Scenario: Legacy memory.md содержит проектные факты
- **WHEN** qualified память включается при существующих локальных заметках и прежнем memory.md
- **THEN** исходники сохранены без bulk remember/удаления; новый маршрут не объявляет их мигрированными или проверенными, выбранный перенос выполняется отдельно в допустимую область


### Requirement: Оптимизация сохраняет originals и один маршрут поиска

Existing reader SHALL ограничивать параллельное чтение originals двумя read-only raw GET внутри recall, сохраняя dedupe, round-robin порядок и deterministic выдачу независимо от завершения. SHALL сохраняться общий deadline 20 секунд, candidate cap 24, до 8 cards и до 1600 токенов всего сериализованного recall payload, current original/status/applicability и raw byte limits. Максимум одно уже начатое speculative чтение сверх sequential раннего выхода SHALL учитываться отдельно. Ошибка/отмена SHALL сохранять partial/continuation, SHALL NOT доказывать отсутствие знаний. Reader SHALL прекращать dispatch по deadline/cancel и очищать только свои ресурсы; SHALL NOT вводить общий scheduler, межоперационный original cache или parallel semantic/writer операции.

Routing SHALL выбирать один маршрут: подтверждённый dataset/data ID → exact memory_status; точный термин/ошибка → CHUNKS_LEXICAL только после native qualification pinned профиля; смысловой вопрос → CHUNKS. До lexical qualification SHALL использоваться прежний CHUNKS; OpenAPI enum SHALL NOT заменять proof. Exact read SHALL NOT заменять обязательные standing/task queries, если нужны другие знания. SHALL NOT требоваться новая LLM, обход scopes или скрытый lexical+semantic fallback; прежние TOOL/query budgets сохраняются. Narrowing SHALL опираться на подтверждённую область; иначе SHALL сохраняться весь allowed read set.

#### Scenario: Originals завершаются в другом порядке
- **WHEN** два GET завершаются в обратном порядке или один даёт ошибку
- **THEN** прежние порядок/currentness/budgets сохранены; ошибка partial, stale fragment не становится фактом

#### Scenario: Уже известен original
- **WHEN** нужен конкретный original по подтверждённым dataset/data ID
- **THEN** exact route не делает semantic query только ради того же original; scope/currentness обязательны

### Requirement: Экономия оценивается по всей задаче

Оптимизация SHALL сохранять обязательные инструкции, provenance/status/applicability/coverage и exact evidence. SHALL сокращаться только доказанная избыточность полей/повторов в неизменном контексте; blind cache SHALL NOT заменять свежие originals. Лимит одного recall SHALL NOT объявляться бюджетом всех ходов. Before/after SHALL использовать существующие затронутые N5/B01–B12, одинаковые модель/корпус/профиль/контекст и real long-lived frontend; per-call fixture overhead SHALL отделяться от production latency. Новые кейсы и полная переаттестация G5 SHALL NOT требоваться этим планом. Польза/стоимость SHALL фиксироваться по MO-AC1–6 design с фактическими wall/calls/agent context и unknown internal usage; отсутствующие counters SHALL NOT считаться нулём. Исторический G5 SHALL NOT считаться proof нового default-on/reader/lexical поведения.

#### Scenario: Payload короче, полный контекст неизвестен
- **WHEN** bytes карточек меньше, но сопоставимого полного usage нет
- **THEN** указывается только измеренное сокращение payload; общая token/monetary экономия не объявляется
