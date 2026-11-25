# Общее подключение Cognee: сверка с G4, 2026-10-26

Пользователь уточнил первый выпуск: **шесть областей сохраняются, разграничения
прав между пользователями сейчас нет, подключение Cognee общее**. Это актуальное
основание обеих OpenSpec. Изменены документы; source/runtime G4, сервер, datasets,
credentials и installed settings не меняются. G5, Gate6, рабочая миграция и
публикация не разрешены. Старые evidence остаются историей прежней ACL модели.

## Простая модель, совместимая с существующим G4

Один instance/endpoint и один обычный технический account/credential Cognee для
workflow. Это общая identity подключения, не identity разработчика. Она имеет
чтение/запись всех подготовленных для workflow datasets. Разным сотрудникам не
назначаются разные backend права, membership или publisher role; outsider/deny
qualification исключена. Аутентификация Cognee не отключается. Credential
настраивается existing MCP owner вне Git/reset; новый IAM/token service не нужен.

Шесть областей — принадлежность, релевантность, срок актуальности и место
записи, **не обещание секретности между разработчиками**. Task/workspace/workplace
различаются по стабильным local IDs; project/product/org совпадают по business
назначению. User-local machine ID создаётся отдельно в профиле Windows, поэтому
одно backend principal не сливает рабочие места разных локальных пользователей.
Continuation/pending/receipts остаются локальными и не пересылаются автоматически.

Resolver по-прежнему ограничивает datasets до retrieval/graph по текущему
workspace/cycle/project/product и применимым homes. Это маршрутизация качества,
а не проверка полномочий. Явный dataset_name, exact native IDs/owner, один original,
current cycle/status, applicability/evidence и bounded pending обязательны.
Нет full-account retrieval, silent task/global default или автоматического fan-out.

Общие datasets один раз подготавливаются штатным API **тем же** техническим
account, без отдельного admin principal или выдачи grants людям. Локальные
scopes создаются lazy. Labels не доказывают exact ID; deployment mapping вне
business registry, нового provisioning service нет.

## Сверка с actual source

Сверен workflow `02925f66bec63c06776445062caafee524ca8597`;
G4 implementation `17061155f12c1c39df37eb3564f919edd994b811` и fork candidate
`162f2ea7a5734b65bc1de80943d057e9b7c0a525`. Source не требует разных accounts,
OS-user/backend-user соответствия или отдельного admin provisioning. Поэтому
**новая обязательная source-адаптация G4 не нужна**: используем существующий
формат настройки общего account, не вводим новый gate перед G5.

| Существующий owner / contract | Общая настройка и смысл без пользовательского ACL |
|---|---|
| `agent-1c.memory-context.ps1` / `Assert-ItlMemoryProvider` | `principalId` — один technical account; `datasets[].permissions` сохраняется для совместимости формата и везде равно `["read", "write"]`. Это фиксированная техническая декларация capability, не редактируемая матрица прав людей. IDs/owner/admitted по-прежнему обязательны |
| `agent-1c.memory.ps1` / `Get-ItlMemoryScopes`, status/lookup | Existing permissions фильтр при одинаковом read/write не различает сотрудников. Context/cycle/home/subset проверки сохраняются: common credential не расширяет read set или destination |
| `Assert-ItlMemoryPrincipal` | Exact `/users/me` ID и `is_superuser=false` подходят обычному техническому account. Отдельные accounts разработчиков или admin credential не требуются. Аутентификация соединения, а не авторизация людей |
| `Get-ItlMemoryWorkspace` / local identity | Историческое поле `identity.developerId` содержит connection principal. Оно не используется как HR/user directory; workspace и user-local machine ID выделяются отдельно. Backend identity не объявляется личностью разработчика. Тот же account на новой terminal session не меняет local scope |
| Private dataset resolver / shared mappings | Existing lazy path создаёт локальный scope под account и сверяет owner. Shared mapping может ссылаться на datasets, подготовленные тем же account: код не требует другого owner, admin или grant issuance. Owner collision сохраняет exact ID, не проверяет membership |
| Unknown-write receipts | Instance/principal/dataset pin сохраняется как identity исходной попытки; смена credential того же principal не создаёт новое рабочее место. Замена backend account не разрешает blind replay |
| Controlled fork / host bridge | Existing qualified clause требует authenticated ordinary principal и usable scope, что выполняется общим обычным account. Wording о grants означает native возможность технического соединения, не обязательный per-user grants setup. Strict-root, TOOL/off/required, correction-capture, /evolve, standing query, Memory line и одна durable write прежние. Новый fork commit/installed patch не нужен |
| Source fixtures | Existing memory fixtures используют один `ordinary-user` с read/write; источники/native G1 с разными пользователями остаются историческими. Context collision, product exclusion, pending/body-loss, concurrency и Unicode assertions не ослабляются |

Нельзя просто удалить `permissions` из настроек существующего G4: текущий
validator требует поле. Упрощённый setup заполняет его фиксированно read/write,
без вопроса о правах каждого пользователя/области. Изменение/удаление поля из
API — необязательный будущий cleanup, **не prerequisite G5/первого выпуска**.
Нативная возможность обычного common account создавать/read/write/update/delete
проверяется в разрешённом G5; конфигурация/source proof не заменяет её.

## Restore и готовность

`admitted` — проверенность mapping/current backend state, а не право человека.
Во время native restore общий клиентский доступ приостанавливается. Оператор
проверяет exact originals и известные поздние correction/delete, фиксирует
backup T/интервал потери; только проверенные scopes возвращаются в работу после
fresh client context/reload. Проверка/replay grants/revoke и ACL rollback из
обязательного G5 исключены. Нет полного журнала и hidden rollback detection.

G4 сохраняет прежнюю source регистрацию; её не переоткрываем из-за уточнения
ролей. Нынешний результат — согласованная постановка и совместимый existing
configuration contract, **не новая native/client приёмка**. G5 ещё требует
отдельного разрешения, доступного instance/common credential/native IDs,
подтверждённых homes для product canary, isolated PM5 и matching local candidate
pair. Опубликованный R6 SHA не меняется; данные homes не назначались.
