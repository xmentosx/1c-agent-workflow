# CATALOG_PROJECT_REQUIRED в квалификации develop

## Причина и граница

`Status` от 2026-10-30 подтвердил: опубликованный develop уже
`0e89efa008930cb2b1fca08cae96951a30c6b0ec`; наша запись
`product-project-registry-g2@d3c278e23e1c3cbe6acb06d204e523ff6e62a9cc`
отложена на `develop-e2e-upgrade-prerun`. Сохранённая причина — отказ
post-copy с `CATALOG_PROJECT_REQUIRED` на непривязанном минимальном стенде.
Активной публикации нет. Прежнее утверждение о готовности всей очереди к
обновлению проектов не является успешной квалификацией этой записи.

Обязательный выбор из f9 действует по согласованному контракту. Оснастка
`source-e2e-fixture` / `invoke-develop-e2e` не предоставляла проект для
unattended update; `fresh` и создание нового gate stand также не передавали
выбор при init. Назначать техническому стенду PM5 КОРП из рабочего реестра
нельзя: это создало бы неверную бизнес-привязку.

Дополнительно подтверждён product defect: явные `CatalogProjectId`,
`CatalogProfileId`, `CatalogDecision` отсутствовали в
`Get-Agent1cReexecArguments`. После исходного отказа старого caller source-side
resume тоже терял решение при fresh post-copy. Теперь все три значения
сериализуются существующим quoting owner. Диагностика отказа post-copy
содержит точный Original candidate и продолжение через тот же source updater;
prefix `CATALOG_PROJECT_REQUIRED` и snapshot/hash admission остаются прежними.

## Исправление владельца оснастки

В существующем `source-e2e-workflow-update.ps1` подготовлены только тестовые
данные: локальный Git publisher с schema-valid registry/catalog/relations,
одним техническим продуктом и проектом `itl-gate-qualification`, без MCP,
СППР/Mantis endpoints и memory homes. Выбор передаётся штатными
`-CatalogProjectId` / `-CatalogDecision keep-local` первоначальному updater
и его существующему source continuation. Init получает тот же явный выбор.
Исходный post-copy отказ старого caller сохраняется. Continuation допускает
этот известный guard только при уже подготовленном явном выборе технической
фикстуры и прежних проверках fresh status, exact root/candidate, terminal
stage, единственности evidence и общего remaining budget. Без такого выбора
отказ не превращается в автоматическое продолжение.

Подготовка ограничена UUID Configuration.xml из repository fixture
`tests/fixtures/gate-stand/cf/Configuration.xml`. Другие конфигурации и уже
привязанные проекты не получают подстановки. Factory меняет только новые
disposable copies; sealed seed/capsules и прежние snapshots не редактируются.
Перед updater проект остаётся непривязанным: это не подмена исходного
upgrade сценария предварительной привязкой. Операции init/update, topology,
guards, assertions и watchdog прежние. Рабочий Git-реестр не изменяется.

Новый XML reader включён в native input inventory и owner reuse dependencies.
Audited Go-reader hashes дополнены точными новыми bytes с сохранением старых:
читатели не потребляют Go tests/README. Неизвестное изменение по-прежнему
отменяет эту узкую возможность reuse.

## Проверка и доставка

Использованы существующие файлы `SourceE2EWorkflowUpdate.Tests.ps1`,
`GateStand.Tests.ps1`, `DeliveryGoInputScope.Tests.ps1`. Существующая пара
Develop/Release повторяет native PowerShell handoff с Unicode/spaces root,
явным выбором, исходным отказом старого helper и одной bounded continuation.
Отрицательные admission/budget проверки сохранены. Это проверка кода и
оснастки, а не полный 1C upgrade/fresh и не публикация workflow.
Focused итог: 32 passed / 0 failed / 0 skipped. В существующей паре также
реальный CLI preview прочитал и проверил опубликованный локальный каталог,
actual reexec builder сохранил три typed значения, а вызов на уже привязанном
проекте сохранил env побайтно. Первая попытка выявила неверный BOM-sensitive
audited hash; последующая native preview — ошибочный override path вместо
готового checkout. Обе ошибки исправлены; failed evidence сохранён.

Raw evidence и failed attempts сохраняются в ignored task
`build/agent-artifacts/catalog-required-delivery-repair-20261030`.

Первая регистрация остановилась в уже существующем
`CompactRunnerWatchdog.Tests.ps1`: 17 passed / 2 failed, wall time двух случаев
7.0958 и 7.0782 секунды при прежнем `<7`. Код runner/timeout policy и сам файл
теста совпадали с опубликованным develop. Изолированный повтор сохранил все
пороги: timing отказ исчез, но delayed-read hook упал на чужом JSON без `stage`.
Диагностический повтор того же случая сохранил stdout/stderr и вход hook:
это существующий `clean-artifacts` lifecycle record с `phase=complete`, не
helper status. Исправлено только чтение optional `stage` в test hook через
существующий `Get-ObjectValue`; original delayed-read marker, timeout stage,
single extension и неизменность deadline по-прежнему обязательны.
Исправленный исходный watchdog-файл: 19 passed / 0 failed / 0 skipped;
два исходных deadline случая — 6.09 и 6.11 секунды, предел `<7` сохранён.

Этот native timing file перенесён в существующую serial cohort shard owner:
тот же workload и assertions запускаются без параллельных cold package tests.
Прежний параллельный файл занял 181185 мс, изолированный до исправления hook —
около 166 с. Это перенос уже существующей стоимости в serial tail, возможная
добавка к стеновому времени общего gate; пользовательский runtime watchdog,
порог теста и always-on context не увеличены. Нового случая или gate нет.
XML dependency дополнительно закреплена в `source-qualification-fixture`,
который реально входит в обе native route projections; существующая пара
Develop/Release проверяет включение XML в оба inventory.
Проверки точного serial inventory в `SourceQualityCatalog.Tests.ps1`
согласованы с этим явным изменением scheduling: watchdog обязан быть serial,
остальные четыре extracted compact fixture files остаются parallel; полный
список всё ещё сравнивается точно. До согласования эти две старые проверки
остановили повторную регистрацию; они не были удалены. Итог существующих
SourceQualityCatalog + SourceE2EWorkflowUpdate файлов — 60 passed / 0 failed.
Следующая регистрация обнаружила ещё один закрытый reader inventory:
`Test-DevelopColdCutoverConsumers` не знал новый SHA E2E runner и правильно
отменял reuse прежнего retained-record proof. После аудита добавлен только
точный runner SHA; для него дополнительно закреплён SHA нового catalog helper.
До bootstrap helper читает config/XML и готовит Git-данные, не читает retained
on-demand runtime. Прежние SHA и helper projection checks сохранены;
неизвестные изменения по-прежнему закрывают исключение. Исходные шесть
DevelopBrokerInputScope проверок прошли, включая original/current cold cutover
на Unicode root и malformed-state rejection; assertions не менялись.

Фактическая регистрация исправленного head проверяется через
`source-delivery Status` с прежним QueueId; только успешный RegisterChange
снимает deferred в своей транзакции. После этого ещё требуется штатный
PublishDevelop с исходными owner gates. Master, рабочая миграция и новые
функциональные сценарии этим ремонтом не запускаются.
