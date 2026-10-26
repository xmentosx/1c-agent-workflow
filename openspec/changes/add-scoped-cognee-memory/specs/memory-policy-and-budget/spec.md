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

### Requirement: Миграция включает память отдельным выбором

Package update/registry association SHALL сохранять legacy/off до отдельного явного memory opt-in. Existing setup owner SHALL предлагать включить память/позже только при passed native Q, поддерживаемых helper/fork, registry context/native mapping и подтверждённом client reload; SHALL NOT обходить TOOL policy или спрашивать по каждой области. Unattended/отсутствие ответа SHALL NOT активировать память. Failure/partial memory binding SHALL иметь отдельный статус и прежний recovery owner; SHALL NOT превращать успешное независимое обновление/каталог в memory success либо блокировать их. Disable SHALL сохранять data/IDs/pending; downgrade SHALL проверять совместимость/owned restore.

#### Scenario: После обновления пользователь выбрал память позже
- **WHEN** каталог уже выбран, но memory opt-in отсутствует, отложен или provider не qualified
- **THEN** legacy/off сохраняется, независимая работа продолжается; required memory gap остаётся зависимой операцией, OpenViking автоматически не устанавливается

### Requirement: Старые заметки не становятся общими автоматически

Первое включение/обновление SHALL сохранять прежние memory.md, локальные заметки и receipts. Оно SHALL NOT импортировать весь файл/чаты, очищать, переклассифицировать или пересылать заметки в shared datasets автоматически. Strict whole-project rules SHALL сохранять роль memory.md. Перенос выбранных фактов SHALL требовать отдельного явного действия, проверки scope/applicability/evidence и durable подтверждения; общие templates SHALL NOT считаться историей текущего проекта.

#### Scenario: Legacy memory.md содержит проектные факты
- **WHEN** qualified память включается при существующих локальных заметках и прежнем memory.md
- **THEN** исходники сохранены без bulk remember/удаления; новый маршрут не объявляет их мигрированными или проверенными, выбранный перенос выполняется отдельно в допустимую область
