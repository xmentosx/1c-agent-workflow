# Spec Delta

## Purpose

Хранить полезные знания в штатном Cognee с явной принадлежностью одной из шести областей, сохраняя доступ, происхождение и возможность исправления без изменения провайдера.

## ADDED Requirements

### Requirement: Выбранный Qwen и отдельный квалифицированный индекс

Рабочий профиль SHALL использовать выбранный пользователем Qwen3-Embedding-8B/4096 с квалифицированными native settings. Сам выбор модели SHALL NOT означать допуск deployment. Индекс4096 SHALL строиться штатным Cognee в отдельных новых native datasets/namespaces, SHALL NOT смешиваться с BGE384 или объявляться готовым по старому completed/HTTP200. Должны быть подтверждены native status, current originals и scoped retrieval. Допуск нового профиля SHALL принадлежать существующему policy owner с фактическим qualification reference; старый BGE admission/комплект SHALL сохраняться для управляемого возврата. ITL SHALL NOT обходить existing qualification, автоматически переключать модели, менять Cognee или переносить provider IDs/секреты в бизнес-реестр.

#### Scenario: Выбран Qwen, развёртывание ещё не квалифицировано
- **WHEN** пользователь выбрал Qwen, но новый4096 deployment/admission ещё не подтверждены
- **THEN** выбор фиксируется в плане, прежнее рабочее подключение остаётся прежним; новые settings не считаются native success и не запускают переключение

#### Scenario: Native дедупликация не построила новый индекс
- **WHEN** импорт original вернул успех либо прежний completed, но нет подтверждённого4096 индекса в новом dataset
- **THEN** candidate остаётся недопущенным, source/export сохранены; используется supported status continuation/checkpoint без изменения текста, SQL или повторов неизвестной записи

### Requirement: Перестроение сохраняет знания и устойчивую идентичность

При разрешённом перестроении SHALL сохраняться логические шесть scope keys, noteId, current original payload/status/provenance/applicability и согласованный полный backup relational/auth/original/graph/vector/config/mapping. При переносе существующего реального рабочего source native principal SHALL сохраняться; при подтверждённом пустом старте ordinary account SHALL создаваться без fixture identity. Прежняя local taskCycle/workspace/workplace identity SHALL сохраняться. Новые instance/dataset/data IDs SHALL иметь подтверждённое exact mapping, SHALL NOT получаться по догадке из label или приниматься за прежние IDs. Неизвестные записи и исходные pending SHALL сохраняться; ранее отправленный unconfirmed write SHALL оставаться pinned к прежнему instance/principal/dataset без replay на candidate. Учебные данные SHALL NOT автоматически становиться рабочим набором. Прямое редактирование backend БД и пересоздание локального цикла ради reindex SHALL NOT допускаться.

#### Scenario: Dataset и data ID изменились при переносе
- **WHEN** тот же current noteId перенесён в новый4096 dataset с другим native dataId
- **THEN** точные old/new IDs и raw hashes проверены, scope/account/local identity сохранены; старые кэши и receipts не являются proof нового original

#### Scenario: Отсутствует настоящий рабочий source
- **WHEN** первый рабочий deployment создаётся с пустым подтверждённым набором, а имеются только G5/RU fixture stands
- **THEN** source absence фиксируется, тестовые записи/UUID не переносятся автоматически, новая рабочая identity создаётся штатно; прежнее unconfigured состояние сохраняется как граница возврата до записи

### Requirement: Переключение и возврат учитывают поздние изменения

Разрешённые cutover/rollback SHALL выполнять existing host/memory владельцы в согласованном операторском окне с одним normal writer target и свежими bindings. Перед cutover SHALL быть подтверждены профиль и требуемый выпускной admission; additions/corrections/precise deletions после начального T SHALL учитываться по финальному current inventory Tf. После новых Qwen writes возврат SHALL сохранять полный current snapshot/export Tr и переносить подтверждённые поздние current originals/corrections/deletions перед допуском BGE. Простой старый snapshot SHALL NOT считаться current состоянием. Неопределённый результат SHALL сохранять обе стороны/pending и оставлять affected scopes unavailable с Q5 continuation; независимый workflow SHALL продолжаться. Ненулевой интервал потери SHALL требовать отдельного решения, не скрываться успешным restore. Полная native immutable история всех ревизий SHALL NOT обещаться; предыдущие комплекты SHALL NOT удаляться автоматически.

#### Scenario: Возврат до первого нового write
- **WHEN** candidate подготовлен, но новые writes в Qwen ещё не разрешены и не выполнялись
- **THEN** оператор может вернуть сохранённое предыдущее подключение через existing owner/reload, сохраняя off и identity, без потери current записей

#### Scenario: После cutover знание исправили или отозвали
- **WHEN** после Tf в Qwen появились подтверждённые изменения, а оператор выполняет возврат
- **THEN** Tr и изменения сохранены; BGE допускается только после native проверки актуальных originals и precise retirement, старые отозванные сведения не возвращаются как действующие

#### Scenario: Не удалось подтвердить поздние изменения
- **WHEN** безопасная сверка при возврате не завершена или late write остался unconfirmed
- **THEN** обе стороны/источники/pending сохранены, affected scopes не объявляются актуальными, оператор продолжает Q5; автоматический fallback/допуск старого snapshot не выполняется


### Requirement: Одно общее подключение без пользовательских ACL

Первый выпуск SHALL использовать один Cognee instance и одно техническое подключение/account для workflow. Шесть областей SHALL обозначать принадлежность и применимость, SHALL NOT заявлять backend конфиденциальность между разработчиками. Аутентификация/secret storage SHALL сохраняться как транспорт подключения; ITL SHALL NOT требовать личные Cognee accounts, роли, membership, permissions matrix или outsider проверки. User-local IDs рабочего места SHALL оставаться независимыми от backend principal; смена сессии SHALL NOT менять workplace. При проверке pending/unknown native write SHALL сохраняться pin исходного instance/connection identity/exact dataset, без blind replay.

#### Scenario: Несколько разработчиков используют один account
- **WHEN** workflow использует один настроенный Cognee credential на разных рабочих местах
- **THEN** общие product/project/org IDs совпадают по назначению, локальные workspace/task/workplace IDs сохраняют свою принадлежность; права людям не назначаются и не проверяются, retrieval остаётся ограниченным текущим контекстом

### Requirement: Общее подключение без регулярного истечения login token

Штатное подключение SHALL использовать native API key обычного технического account через `X-Api-Key`, без автоматического срока истечения в квалифицированном Cognee 1.6.5. Секрет SHALL храниться только в существующем user-local private credential file как `apiKey`, вне Git, реестра, проекта и model context. Legacy `accessToken` SHALL сохраняться как Bearer compatibility, без обещания продления его lifetime. При наличии обоих полей SHALL выбираться только `apiKey`; отказ SHALL NOT запускать fallback, login, refresh или повтор записи. Адаптер SHALL перечитывать файл при каждом запросе; ротация оператором SHALL сохранять account/dataset identity и pending. Собственный auth service, хранение пароля для автоматического входа и изменение Cognee SHALL NOT требоваться.

#### Scenario: Истёк прежний Bearer, настроен API key
- **WHEN** private credential содержит валидный `apiKey` того же ordinary account и старый `accessToken`
- **THEN** адаптер отправляет только `X-Api-Key`, использует прежние dataset IDs и не зависит от срока Bearer; секрет не попадает в tool schema/ответ

#### Scenario: Оператор заменяет или отзывает ключ
- **WHEN** оператор атомарно заменяет private credential file либо сервер отклоняет отозванный ключ
- **THEN** следующий запрос читает актуальный файл без перезапуска; отказ не считается durable success и не приводит к login/replay, исходные IDs/pending сохраняются для существующего status continuation

### Requirement: Шесть областей с устойчивой идентичностью

Система SHALL различать `taskCycle`, `workspace`, `workplace`, `product`, `project`, `organization`. Задача, ветка и база SHALL иметь одну область текущего цикла. Область SHALL иметь стабильный ID и основной dataset; локальные task/workspace/workplace datasets создаются по необходимости, общие — по подтверждённой native привязке того же технического подключения. Имя каталога, адрес сервера или имя ветки SHALL NOT подменять идентичность. Одно знание SHALL иметь одно основное место хранения, без обязательных копий по всем областям/провайдерам.

#### Scenario: Несколько локальных установок одного проекта
- **WHEN** два разработчика работают с одним `projectId` в разных локальных установках
- **THEN** project/product области могут совпадать, а workspace и taskCycle различаются; локальные особенности не становятся общими проектными фактами

#### Scenario: ПК и терминальная сессия
- **WHEN** тот же разработчик открывает новую терминальную сессию на прежней машине
- **THEN** новая сессия не создаёт нового разработчика или workplace; другая машина имеет отдельный workplace при той же developer identity

### Requirement: Штатный backend без форка Cognee

Система SHALL использовать поддерживаемые Cognee MCP/SDK/REST и штатные datasets под одним техническим подключением. Она SHALL NOT менять исходники Cognee, напрямую править его БД, добавлять свой граф/embedding pipeline или маскировать широкую выборку текстовой меткой проекта. Отсутствие нужной операции в конкретной версии SHALL давать неподтверждённый binding с понятным продолжением, без обхода scope.

#### Scenario: MCP не адресует общий dataset по имени
- **WHEN** общий dataset подготовлен под техническим подключением, но lookup имени через MCP не адресует его однозначно
- **THEN** ITL использует штатный поддерживаемый API с точным dataset ID под той же технической identity подключения либо оставляет этот binding неподтверждённым; поиск без dataset-ограничения не выполняется

### Requirement: Проверенный контекст ограничивает чтение и запись

ITL binding SHALL ограничивать datasets по выбранному workspace/cycle/project/product контексту до backend retrieval и graph expansion. Это фильтрация релевантности, SHALL NOT обещать разграничение прав людей. Отсутствующий read scope SHALL разрешаться в закреплённый набор, explicit scope SHALL только сужать его. Qualified write SHALL явно выбирать один dataset через `dataset_name`; отсутствие SHALL сохранять локальный pending, SHALL NOT использовать silent task/global default. Native ID/owner/currentness SHALL подтверждаться независимо от label; неизвестное или неоднозначное назначение SHALL NOT вызывать запись. Персональные accounts/grants, outsider и publisher roles SHALL NOT быть условиями первого выпуска. Для совместимости existing G4 поле mapping `permissions` SHALL заполняться фиксированным `["read", "write"]` для всех областей; оно SHALL NOT моделировать права сотрудников или требовать отдельного setup выбора. `principalId` SHALL обозначать обычный технический account общего подключения, не личность разработчика.

#### Scenario: Запрос чужой задачи
- **WHEN** клиент текущей задачи передаёт dataset другой задачи вне текущего контекста или опускает scope
- **THEN** чужой dataset не запрашивается; пропущенный scope ограничивается текущим разрешённым набором, а ошибка получает способ выбрать допустимый контекст

#### Scenario: Граф связывает одинаковые сущности
- **WHEN** в двух проектах есть одноимённые объекты и совпадающие графовые сущности
- **THEN** поиск одной области не извлекает факты другой вне выбранного контекста через связи; это доказывается backend-вызовом, а не только очисткой итогового текста

#### Scenario: Не выбран dataset для постоянного условия
- **WHEN** remember вызван без назначения или область постоянного исправления неоднозначна
- **THEN** backend write не выполняется с task default; заметка сохраняется как локальный pending, основной агент выбирает допустимую область по смыслу и правилам без отдельного LLM-классификатора

### Requirement: Общие datasets имеют одного подтверждённого владельца

Product/project/organization datasets SHALL подготавливаться один раз штатным Cognee API под тем же общим техническим подключением; отдельный admin principal или grants разработчикам SHALL NOT требоваться. Binding SHALL использовать точные native IDs/owner для чтения и записи. Одинаковые labels SHALL NOT считаться доказательством одной области или основанием создать дубликат. ITL SHALL NOT вводить IAM/provisioning service. Отсутствие поддержанного native пути SHALL оставлять mapping unverified с continuation.

#### Scenario: Два процесса используют общее подключение
- **WHEN** два процесса разработчиков выполняют scoped remember/recall через один technical account для одного projectId
- **THEN** оба используют один подтверждённый dataset ID; workspace/task contexts сохраняют собственные IDs, label collision не создаёт дубликаты и не расширяет retrieval set

### Requirement: Происхождение и жизненный цикл заметки

Запись SHALL содержать самостоятельный факт, область, ID, дату, origin, applicability и evidence с ревизией при наличии. Гипотеза SHALL отличаться от подтверждённого вывода. English narrative и исходные 1C identifiers SHALL сохраняться по политике fork; секреты/PII не сохраняются. Индекс/граф SHALL быть производными от сохраняемых исходных записей. Исправление SHALL ссылаться на прежний ID; точечное обновление/удаление используется только при поддерживаемой операции через общее подключение. Перед выдачей как действующего факта SHALL подтверждаться original/envelope и авторитетный current revision/status через поддерживаемый scoped native путь по стабильному ID, независимо от semantic hits. Эта проверка SHALL относиться к текущему допущенному состоянию хранилища; SHALL NOT объявляться обнаружением скрытого rollback или доказательством сохранения изменений после даты backup. Unverified фрагмент SHALL NOT выдаваться как действующий. Собственный сервис версий SHALL NOT заменять отсутствие native возможности.

#### Scenario: Ошибочное прежнее решение
- **WHEN** новая проверка опровергает сохранённый подход
- **THEN** записывается исправление с источником и связью supersedes; старое не выдаётся как действующее, а удаление dataset ради одной заметки запрещено

#### Scenario: Старый chunk найден без correction и заголовка
- **WHEN** recall вернул старый фрагмент без envelope, а correction не попала в top_k
- **THEN** precise original/current-status lookup подтверждает исправление или retirement независимо от recall; при отсутствии ID/поддерживаемого proof результат остаётся unverified, а binding не получает квалификацию актуальности

### Requirement: Различать принятую запись и готовность поиска

Результат SHALL различать подтверждённую durable запись, pending indexing, definite rejection и unconfirmed исход. Timeout/interruption SHALL NOT вызывать слепую повторную запись или перенос в другой provider. Должен сохраняться локальный receipt с областью, provider/data ID и способом сверить исход через доступные штатные операции.

#### Scenario: Индексация ещё идёт
- **WHEN** запись подтверждена, но индексация не завершена
- **THEN** результат сообщает сохранение и отдельный статус поиска; экземпляр не получает дубликат, статус проверяется ограниченно через поддерживаемую операцию

#### Scenario: Прерван ответ на remember
- **WHEN** клиент не знает, сохранил ли backend заметку
- **THEN** результат остаётся unconfirmed, локальная запись/receipt переживает перезапуск, следующий шаг сначала сверяет исход и не обещает exactly-once без доказательства провайдера

### Requirement: Минимальные права и восстановление

Первые три области SHALL быть пользовательскими по умолчанию; общие области SHALL использовать существующие разрешения и явную допустимость записи. Полезность для другого продукта SHALL NOT предоставлять доступ. Backup/restore SHALL принадлежать штатному администрированию Cognee. Backup SHALL быть согласованной копией originals и необходимого relational/graph/vector/mapping state на момент T с зафиксированной датой и возможным интервалом потери изменений после T. Полная неизменяемая история всех ревизий/отзывов и сохранение поздних изменений поверх старого snapshot SHALL NOT обещаться при отсутствии такой native гарантии.

Retirement SHALL адресовать точную заметку, SHALL NOT удалять dataset или другие originals; correction/delete SHALL иметь точное native подтверждение, с source/receipt preservation при unconfirmed результате. Backup SHALL согласованно сохранять необходимые relational/graph/vector/original/mapping данные на дату T. Контролируемый restore SHALL приостанавливать общее клиентское подключение. Оператор SHALL проверить exact originals, повторить известные поздние correction/delete при необходимости и подтвердить current state до допуска scopes и fresh client context. Интервал потери после T SHALL быть явным. Непроверенные области SHALL оставаться недопущенными; независимый workflow продолжается. ACL/grant/revoke/outsider checks SHALL NOT быть обязательными. Собственный IAM/versioning/backup service и hidden rollback detection SHALL NOT вводиться.

#### Scenario: Техническое подключение не может прочитать область
- **WHEN** сервер отклоняет чтение dataset через общее подключение
- **THEN** она больше не запрашивается текущим binding и связанные кеши не используются; старый mapping не считается доказательством актуальных originals после restore

#### Scenario: Старая копия вернула удалённый факт
- **WHEN** контролируемый restore к T вернул записи, удалённые или исправленные после T
- **THEN** оператор проверяет current originals и известные поздние correction/delete; только проверенные области допускаются после restore, клиент продолжает с очищенным кешем в новом контексте

#### Scenario: Поздние изменения области нельзя подтвердить
- **WHEN** после restore невозможно подтвердить актуальность области или восстановить необходимые поздние исправления/отзывы
- **THEN** область остаётся недоступной до проверки или восстановления подходящего состояния; ни native original lookup внутри старой копии, ни дата заметки не снимают этот запрет, независимая работа продолжается

### Requirement: Native допуск предшествует зависимой разработке

До зависимого managed runtime SHALL быть подтверждены применимые native Q1–Q7: exact shared ID read/write через общее подключение в двух процессах, context scope до retrieval, durable/status/new-session, current original независимо от semantic hits, precise correction/retirement и проверка состояния после restore (Q5), bounded CHUNKS и ограниченный профиль с whole-run измерениями (Q7). Version/schema/models/connection identity, harmless corpus и expected/actual/status SHALL фиксироваться. Персональные ACL, разные accounts/grants, outsider deny и revoke SHALL NOT быть входами G5. Старое G1 evidence SHALL сохраняться исторически; изменённые документы SHALL NOT считаться новым native proof. Старый failed результат SHALL сохраняться; config/tools-list/fixtures SHALL NOT заменять functional proof. Неизвестный cost SHALL NOT считаться нулевым; неполная internal детализация SHALL NOT сама блокировать G4 при достаточном Q7 whole-run учёте. Не доказанная native возможность SHALL возвращаться на checkpoint без собственного IAM/versioning/graph service. Каталог SHALL оставаться независимым; installed canary, paired сравнение и заявления об экономии SHALL оставаться G5.

#### Scenario: Native статус актуальности не доказан
- **WHEN** оригинал/текущая correction доступны только как возможные semantic hits либо live proof отсутствует
- **THEN** зависимый memory код не получает допуск по Q4; описывается gap и пересмотр design, а registry-only работа не блокируется

#### Scenario: Предварительная квалификация успешна
- **WHEN** на разрешённом harmless stand сохранены passed native Q1–Q7 и допустимый измеримый profile
- **THEN** можно переходить к отдельно разрешённой зависимой реализации; это не доказательство установленной памяти, миграции или экономии всей задачи
