# R6: предвыпускное наполнение — подготовленный кандидат

**Текущий итог:** [2cde7b6f — итоговая таблица для согласования](r6-final-catalog-review-2026-10-25.md).
PM4 карта подтверждена владельцем как соответствующая различиям PM5, УНФ+PM4
Mantis327 записан, СППР URL подтверждён deployed config, reader 8/8 passed.
Регистрационный deadline blocker устранён и source0ec93c18 зарегистрирован.
Ниже — история; старые незаполненные связи и прежний blocker не являются текущими.
R6 остаётся открыт только для итогового согласования/явных исключений и публикации
точного SHA; R1–R5 отдельно. Публикация/G4/Gate6/рабочая миграция не выполнялись.

**Обновление регистрации 2026-10-25:** [Git deadline repair](r6-git-deadline-repair-2026-10-25.md) закрыл подтверждённую причину превышения `<10 s` у existing cleanup owner, без изменения original GitSave test. Final focused proof 5/0/0; итог RegisterChange определяется source-delivery Status. Старые сообщения о неснятом blocker ниже относятся к предыдущим data revisions, не описывают актуальную реализацию. Полное наполнение/публикация R6 этим не закрываются.

## Актуально: завершены Mantis bug/search настройки ERP+PM5 и УНФ+PM5

По явному указанию пользователя 2026-10-25 в неопубликованном data commit **`fae719cac93c820add276ff7201d84473b621543`**:

| Проект реестра | Ошибки | Развитие | Область поиска Mantis |
|---|---|---|---|
| ERP+PM5 | 699 «10. Поддержка PM5, EPR+PM5, Модуль PM5» | 609 «Разработка «1С:PM5»» | Только 609 и 699: разработка и соответствующая поддержка |
| УНФ+PM5 | 814 «11. Поддержка УНФ+PM5» | 609 «Разработка «1С:PM5»» | Только 609 и 814: разработка и соответствующая поддержка |

`projectIds`, `searchProjectIds` и `createRoutes` согласованы; прежние пустые scopes и pending/defer пометки этих трёх настроек сняты. Развитие feature/improvement остаётся 609. 815 не добавлялся в ERP/УНФ search, остальные ранее согласованные маршруты не менялись. ERP+PM5 сохраняет собственные Code/Graph `dev-karimov-new/erppm5-lts`, оба PM5 проекта — общую СППР связь. PM4 не получил проект СППР, отдельные расширения остаются исключены.

Действующий reader/schema/reference проверил immutable commit и восемь selected contexts. Integration-intent owner подтвердил bug targets 699/814 и ровно scopes `[609,699]` / `[609,814]`; marker о pending отсутствует. Это проверка изменённых данных, не новый native G3 сценарий. Proof `build/registry-population-20261025/search-scopes-confirmed-validation.json`, bundle `registry-search-confirmed.bundle`; publisher registry.json unchanged. Ни внешних записей Mantis/СППР, ни client apply, ни публикации не было.

R6/AC-36–38/memory AC-44 пока не закрыты: остались карта PM4, Mantis link УНФ+PM4/конечный review optional exceptions, подтверждение URL СППР instance и отдельно разрешённая публикация точного data SHA. Прежний source registration blocker не снят, третий повтор Targeted без диагноза не выполнялся. Следующие разделы — история предыдущих data revisions; старые записи «bug/search не заданы» не являются актуальным остатком.

## Предыдущая редакция: собственный ERP+PM5 MCP и первые подтверждённые Mantis routes

Пользователь 2026-10-25 явно запретил подстановку PM КОРП для ERP+PM5 и затем подтвердил существующую собственную пару **dev-karimov-new / erppm5-lts**, Code `:22200/mcp`, Graph `:22201/mcp/`. Повторный read-only fetch endpoint registry подтвердил прежний publisher tip abb04af6; другой ERP пары в нём нет. Типовой продукт ERP+PM5 теперь ссылается непосредственно на `erppm5-lts-code`/`erppm5-lts-graph` с usage=project и явным названием LTS-источника. Это подтверждённое назначение, а не автоматическая подмена источника или доказательство версии/доработок локального проекта. Ссылки на pm5corp у Code/Graph ERP+PM5 удалены. Подтверждённые PM5 СППР links и исключение отдельных расширений сохранены.

Текущий неопубликованный data commit **`2ee75f83df5fb9abae0b40d31749ea6d4151a653`** продолжает ba084c6. Schema/reference и 8/8 immutable selected contexts прошли через действующий reader и integration-intent owner. Никаких create_issue/update calls, клиентского apply или новых native G3 canary не было. Publisher registry.json unchanged; snapshot proof и bundle находятся в `build/registry-population-20261025/mantis-erp-confirmed-validation.json` / `registry-confirmed-routing.bundle`.

| Контур | Ошибки | Развитие: feature / improvement | Поиск |
|---|---|---|---|
| PM5 КОРП/ПРОФ | 699 «10. Поддержка PM5, EPR+PM5, Модуль PM5» | **609 «Разработка «1С:PM5»»**, не 815 | 609/699/815 сохранены как согласованный scope |
| УНФ+PM5 | 814 «11. Поддержка УНФ+PM5» | **609 «Разработка «1С:PM5»»** | Не согласован; явный пустой scope без global fallback |
| ERP+PM5 | Не согласована цель: needs-input при создании | **609 «Разработка «1С:PM5»»** | Не согласован; явный пустой scope без global fallback |
| PM4 КОРП/ПРОФ, ERP+PM4 | 327 «04. PM и ERP+PM (поддержка)» | 305 «Развитие «1С:PM»» | 305/327, остальное предложение принято пользователем |
| УНФ+PM4 | Связь не выбрана | Связь не выбрана | Связь отсутствует; это не новый запрет прежнего global search |

815 «Развитие «1С:PM5»» оставлен только в подтверждённом поиске КОРП/ПРОФ, а не в createRoutes. Purpose routes не определяют автоматически search scope. Неподтверждённые bug/search маршруты не выводились из названий проектов и не подменялись существующими целями. Ниже сохранена история исходных proposals; актуальные ERP/Mantis значения определяются этим разделом. R6 остаётся открытым для PM4 карты, конечного review и оставшихся optional exceptions/связей/публикации. Прежний source registration blocker не исправлялся, новый повтор Targeted не запускался.

## Уточнение владельца: СППР и расширения

Пользователь подтвердил 2026-10-25: отдельные расширения пока исключены. UUID `76bcfc1f-e8c2-4cd6-80ef-997b99bca476` — общий проект СППР «PM5», в котором есть доработки PM5 КОРП/ПРОФ, чисто ERP+PM5 и чисто УНФ+PM5. Один `links.sppr` записан всем четырём PM5 проектам; ограничение о продуктовой принадлежности каждой доработки сохранено. Для PM4 проекта СППР нет, links.sppr отсутствует по подтверждённому правилу. Это не вывод применимости одной доработки ко всем продуктам и не расширение collector.

Актуальный неопубликованный data commit **`ba084c6f505583acf79249d4f7193649c61396aa`** продолжает первоначальный `8f3033f`: восемь типовых проектов, десять продуктов с компонентами, девять MCP sources; текущая карта содержит **22 основные PM5 области**, пять областей отдельных расширений убраны из выпускного кандидата и сохранены в истории draft. Работающая публикация `registry.json` не изменена.

Commit-bound reader подтвердил 8/8 contexts, ровно четыре PM5 UUID-связи и отсутствие PM4/Mantis links. Первичный диагностический exporter ошибочно проверял PSObject.Properties у OrderedDictionary и дал false-флаги; corrected observer использует существующий Get-ItlCatalogField, данные каталога не исправлялись ради его результата. Оба diagnostic artifacts сохранены отдельно. Это data validation, не повтор native G3.

Mantis routes не согласованы: пользователь попросил показать названия вместо номеров. До ответа links.mantis не назначаются. Внешние проекты, полнота PM4 карты, URL СППР instance и окончательный выпускной охват также не объявлены подтверждёнными. Следующие разделы описывают исходный draft/первоначальные вопросы; фактически закрытая часть СППР и исключение расширений уточнены здесь. R6/AC-36–38/AC-44 остаются открытыми, source registration блокер ниже не снят.

**Наполнение начато по поручению пользователя, но R6 / registry AC-36–38 / memory AC-44 ещё не приняты.** Согласованный G3 остаётся закрытым. Это data preparation, а не новая квалификация G3, публикация или реализация G4.

## Реальный репозиторий данных

Рабочий реестр — http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git, не pilot шаблон в workflow. Из base `abb04af6dc987fb015b7c4542590d7222eb32ced` подготовлена локальная ветка `codex/pre-release-catalog-20261025`, commit **`8f3033ffd21512a32f836eb7148f9ab3b28a3bc4`**. Push не выполнялся. `registry.json` оставлен byte-exact исходному publisher; его текущие версии не переписаны вручную и не объявлены версиями проектов.

Локальная копия: `build/registry-population-20261025/registry`. Кандидат содержит `catalog/catalog.json`, `catalog/product-relations.json` и review README. Это единственная рабочая data-копия кандидата; source templates/pilot не превращены во второй production registry. Approval должен ссылаться на этот commit или его следующую явно просмотренную редакцию; локальный SHA не заменяет опубликованный SHA R6.

| Данные | Подготовлено | Остаток |
|---|---|---|
| Продукты | Восемь PM4/PM5 КОРП, ПРОФ, УНФ+PM, ERP+PM; ERP/УНФ отдельно как два компонента | Подтвердить выпускной перечень; перечислить внешние проекты и самостоятельные расширения |
| Типовые проекты | Восемь proposed development projects, customized=false; `pm5-core-development` сохранён | Owner confirmation охвата; внешние проекты не выведены автоматически из Mantis/СППР |
| MCP | Девять источников: четыре пары Code/Graph и общая PM5 BookStack; explicit graph namespace/nativeProjectId из live metadata | Подтвердить reference-source выбор для составных PM4/ERP+PM5; нет утверждения, что индекс содержит всю такую конфигурацию |
| ERP+PM5 LTS | Отдельный явный профиль `erppm5-lts` | Не назначен обычному ERP+PM5 автоматически |
| СППР/Mantis | Проверены доступные метаданные; instance records и review routing proposals подготовлены | Проектные links **не записаны** без подтверждения назначения и маршрутов |
| Функциональность | 27 PM5 областей, availableIn, ограничения, ссылки и exact BookStack updatedAt; 10 composition relations | Основная карта PM4 и owner review полноты PM5 остаются открытыми |
| Память | Ни одного memoryHomeProductId/native dataset/grant, memory off | Optional home отложены явно; общие записи не маршрутизируются по догадке |

## Проверенные источники и решения

- BookStack [сравнение ПРОФ/КОРП PM5](https://kb.itland.ru/link/458), updated_at `2026-01-30T08:05:35.000000Z`: явные различия функциональности; КОРП-функции не разрешаются ПРОФ через derivedFrom. [Модель планов](https://kb.itland.ru/link/231), updated_at `2026-09-10T19:22:30.000000Z`: отдельная модель PM5. Это не полная карта PM4.
- [Расширения PM5](https://kb.itland.ru/link/602), updated_at `2026-08-10T15:20:30.000000Z`: совместимость Analytics/Bitrix/KPI/Renga/Accounting отражена с условием установки, без автоматического включения расширений. Реквизиты доступа из исходной страницы не перенесены.
- [УНФ+PM5](https://kb.itland.ru/link/442), updated_at `2026-06-16T12:19:18.000000Z`, и [ERP+PM5](https://kb.itland.ru/link/545), updated_at `2026-06-02T12:25:18.000000Z`: первичные продуктовые ссылки; LTS источник не заменяет обычный ERP.
- MCP Code `stats` и Graph `list_graph_projects` прочитаны для четырёх опубликованных endpoint pairs. PM4/PM5 native graph IDs сейчас `pm4corp`/`pm5corp`, namespace `default`; составные IDs/namespaces `unfpm5`/`erppm5-lts`. Использованы фактические IDs, не исторические предположения `project_id=default`. В registry текущая PM5 версия `5.0.3.71`, PM4 `4.2.40.2`, УНФ+PM5 `3.1.14.146`, ERP+PM5 LTS `2.5.527.94`; эти значения не зафиксированы как версия локального проекта.
- Mantis metadata подтверждает IDs/names 609 «Разработка «1С:PM5»», 699 «10. Поддержка PM5, EPR+PM5, Модуль PM5», 815 «Развитие «1С:PM5»», 814 «11. Поддержка УНФ+PM5», 327 «04. PM и ERP+PM (поддержка)», 305 «Развитие «1С:PM»». Одни названия не являются разрешением на search/create routing. Вопросы по конкретным proposals переданы владельцу; create/update calls не выполнялись.
- СППР `list_sppr_projects`: один indexed UUID `76bcfc1f-e8c2-4cd6-80ef-997b99bca476`, name пустой, current collector policy. Принадлежность к PM5 КОРП не доказана; запись в links.sppr отложена, collector не расширялся. Instance URL пока взят из versioned server config example и также требует подтверждения фактической базы.

## Блокер опубликованной формы registry и owner-local исправление

При первом `Assert-ItlProductCatalog` на настоящем неизменённом publisher registry получено `CATALOG_INVALID: sources.pm4corp-code.endpoint.configId is unknown`. Причина: schema-v2 publisher и прежний endpoint reader используют `configurations[].configId`, а catalog validator проверял только fixture/legacy `id`.

Точечное исправление у существующего catalog owner читает canonical `configId` с fallback на legacy `id`; прежние host/server/config checks не сняты, publisher JSON не нормализуется и не перезаписывается. Regression в существующем `ProductProjectRegistry.Tests.ps1` доказывает canonical shape, отсутствие мутации registry и отказ legacy alias при наличии canonical configId. Это регрессия фактически обнаруженного формата данных, не новый native G3 canary или новая архитектура.

Schema/reference validation после исправления passed. Первоначальный разовый projection exporter имел неполный DTO (не передал catalogRevision/inputGitObjectIds); его optimistic footer не является proof. Повтор с полным DTO/Stop подтвердил восемь projections. Далее commit-bound snapshot проверяется существующим reader; результат и регистрация исходников фиксируются штатными артефактами вне sealed G3 evidence. Нативная активация новых association в клиентах не выполнялась.

## Что требуется для завершения R6

1. Ответ владельца по выпускному охвату, внешним проектам/расширениям и reference-source choices.
2. Подтверждённые СППР mapping/base и Mantis search/create routes; затем запись реальных links и reader validation того же immutable SHA.
3. Дополненная PM4 карта и подтверждение основных областей/ограничений; optional home может остаться явно отложенным.
4. Отдельно разрешённая публикация data-кандидата в существующий registry Git после актуализации publisher tip и штатных guards, затем exact published three-file SHA/live evidence по AC-36–38. Регистрация workflow source commit этого не заменяет.

## Фактическая регистрация и блокер

Две штатные попытки RegisterChange остановились на неизменённом существующем `ProductProjectGitSave.Tests.ps1` / `G3GitTreeDeadline`: возврат stalled Git HTTP команды занял **10.8678824** и **10.4910746 с** при прежнем `<10 s`. Assertions до этой проверки, включая закрытие соединения до абсолютного deadline, прошли; это не отказ маршрутизации или новая configId regression (она passed за 0.412 с в первом Targeted). Ошибка оставлена FAIL, допустимое Startup отклонение к ней не применялось.

Диагностирован owner path: `Invoke-ItlCatalogGit` передаёт transport deadline на три секунды раньше абсолютного caller deadline и через existing native capture вызывает process-tree cleanup; превышен итоговый return window. Одновременная чужая регистрация наблюдалась, но её причинная роль не доказана. Root cause cleanup/возврата пока не установлена; assertions, timeout/reserve, workload, scheduling и reproducer не изменены. Это не разрешение на новый широкий G3 или native lifecycle batch.

Failed candidates/proof сохранены: `itl-source-register-9a8196cb7f2f485691b745a2d2059259` и `itl-source-register-4d22e3162ecd4ef5ba976a6169614f71` в существующем temp owner. Accepted queue head остался `051c556ee07e8287de1d9126541b6255adbde54e`; исправление source **ещё не зарегистрировано**, следующий повтор без диагноза не назначен. Source-only запись этого результата не превращает failed gate в PASS.

Дополнительно найдены первичные PM4 страницы [КОРП](http://info.itland.local/doku.php?id=products:pmo), [ПРОФ](http://info.itland.local/doku.php?id=products:pmoprof), [УНФ+PM4](http://info.itland.local/doku.php?id=products:unfpm), [ERP+PM4](http://info.itland.local/doku.php?id=products:epm2). Их тексты преимущественно о поставках; исключения ПРОФ представлены четырьмя изображениями. Первое изображение просмотрено, оно не даёт полной карты основной функциональности. Эти источники не использованы для автоматического заполнения неизвестной доступности PM4; нужна содержательная карта/подтверждение владельца.

Новых G3 сценариев, Gate 6, G4, рабочей миграции и workflow publication нет. Endpoint/index metadata reads и проверка самих подготавливаемых данных относятся к R6. Source-delivery RegisterChange владеет Targeted существующих owner tests, не означает выпуска.
