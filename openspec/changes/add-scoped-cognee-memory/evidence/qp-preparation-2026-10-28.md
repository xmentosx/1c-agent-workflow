# QP0–QP4: подготовка Qwen, 2026-10-28

Пользователь разрешил только QP0–QP4. QP5/QP6, переключение, Gate6/G6,
рабочая миграция, публикация workflow/fork, push и PR не выполняются.
**QP0–QP4 выполнены в согласованной границе подготовки.**
[Машиночитаемые результаты](qp-preparation-2026-10-28.json) и
[сертификат native profile/index](qp-qwen-profile-2026-10-28.json) сохраняют
точные идентичности, mappings, hashes и границы proof. Release admission отсутствует.

## Source и сохранение данных

Обнаружено одно настроенное общее подключение: изолированная квалификация G5,
а не рабочий production. Сохранены25datasets/84originals:50JSON-записей имеют
точное synthetic/fixture происхождение, остальные34 входят в пять известных
G1/Q5/Q7 qualification datasets. Native pending0; два локальных unsent intents
сохранены без отправки. Новое рабочее хранилище начинается пустым, учебные
записи не переименованы в production. Для пустого старта создан новый ordinary
account; исходный G5 principal сохранён в своём комплекте.

Полный согласованный snapshot BGE:3196entries /2,622,497,612bytes; остановка
исходного контейнера22.554s, затем он возвращён к работе. Manifest SHA256:
`6fb3248ee957f7e59f7253dbb4925d8237c0528e9ecb42afa3f27a24bec42525`.
Отдельная BGE restore-копия проверена нативно:84/84 exact dataset/data IDs,
raw hashes и ordinary principal совпали, native pending0. Копия остановлена,
сохранена; старые provider/binding/credential и2pending скопированы приватно.

## Пустой кандидат и связь с реестром

Host `dev-karimov-mcp`; operator root `/home/mcp/itl-cognee-qp-20261028`.
Production candidate `itl-cognee-qwen-prod-v1`, logical instance
`cognee-qwen-prod-20261028-v1`, native ordinary principal
`4b5e843d-9d33-4e84-9970-4c81c4bdff1d`. Native API привязан только к loopback
`127.0.0.1:18220`; сетевой маршрут обычных клиентов не опубликован.
Все runtime ключи/config остаются в existing private MCP/host home, вне Git.

Созданы17пустых shared datasets:8active типовых продуктов,8проектов и
organization `itland`. Два базовых component products не создаются без home;
частные taskCycle/workspace/workplace scopes остаются on-demand у existing owner.
Шесть областей являются типами, а не шестью общими datasets для всей сети.
Pinned business SHA `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73` сохранён.
На текущем registry main `fc2f9f92daa05be117c7fc26e2621d8acb97e7be` business
catalog/product-relations byte-identical: publisher-only advancement.
Homes/applicability, Code/Graph/productDocs, СППР/Mantis не менялись.

Candidate остановлен и имеет полный empty snapshot; в нём0working originals.
Учебные50/12datasets загружены только в отдельную qualification-копию этого
снимка. Production principal/auth повторно не создаются ради проверки.
Рабочий новый пустой индекс не наполняется учебным корпусом после квалификации.

## Новый индекс и фактическая стоимость

Новый native image не менялся; настройки Qwen cache6/rate-off/pool256MiB,
2CPU/5GiB с общим RAM+swap cap5GiB, frontend query20s/write60s сохранены.
Используется native uvicorn app без diagnostic wrapper и без форка Cognee.
На26-й записи исходный remember180s завершился TimeoutError, а native pipeline
через316s подтвердил EmbeddingException/failed. Оригинал сохранён один раз.
После проверки terminal failed штатный cognify для того же dataset продолжил
индексацию; тот же dataId получил completed. Повторного remember, изменения
payload, удаления failed proof или увеличения runtime budgets не было.

Native completed подтверждён для50/50 originals. Полный CHUNKS-контроль вернул
ровно50текстов с тем же множеством frozen payload hashes. На stopped snapshot
штатный Lance SDK прочитал72vector tables/895rows: все vector schemas4096,
384-векторов нет. Чтение snapshot только read-only; Cognee/БД не патчились.
Прежний RU21 на шести exact scopes:13.312248s при whole-request лимите20s.
Gold не передавался серверу; unscoped calls0.

Полное операторское окно ingestion —3449.520215s, включая паузы и продолжение
неуспешной26-й попытки. Для49исходных записей с полным successful timing:
median26.403305s, max271.259213s,13дольше60s. Failed/recovered ru-n26 исключена
из этой статистики и описана отдельно; она не превращена в успешный180s write.
Это отдельный rebuild, не увеличение frontend write deadline60s.
Наблюдавшийся peak5,092,737,024bytes при cap5,368,709,120bytes; sampled OOM/max
событий0. Старые read peaks1.5GiB не подставлены вместо ingestion. Денежная
стоимость embeddings unknown, не нулевая.

## Existing frontend и controlled restore

Все positive стадии выполнены настоящим source MCP stdio frontend в новых
процессах и отдельном private fixture home, не прямой подстановкой результата:

| Стадия | Фактический результат |
|---|---|
| N1/N2 initial | Два native remember:25.004s и19.207s; оба durable, exact raw и per-item completed подтверждены |
| Fresh reader / исходный RU01 | Оба оригинала прочитаны новым процессом; точный прежний CHUNKS_LEXICAL вызов вернул ru-n01 и8cards за3.873038s |
| Late correction / precise retirement | Native update43.391s, затем exact forget и404; целый dataset не удалялся |
| Controlled old restore | Создана отдельная копия initial snapshot; principal/native IDs сохранены, старая версия и восстановленная retired note наблюдались явно; currentAdmission=false |
| Repair после restore | Известная confirmed correction повторно применена32.267s; retirement восстановлен точно, без replay unknown write |
| Final fresh reader | Подтверждена текущая SILVER-версия; retired original отсутствует; все50frozen originals по тем же data IDs равны исходным |
| Explicit off | Child-only TOOL_COGNEE=off: local status доступен, recall отклонён за0.047s; общая настройка не менялась |

Карточки RU01:1476cl100k/1262o200k tokens; действующие8cards/1600response tokens,
24raw candidates, максимум2original reads in flight сохранены. Новых always-on
инструкций/tool schemas/backend calls на обычную операцию нет. Model-agnostic
policy controlled ai_rules_1c r50/a2cbdcef52316db426acedc852f495564189f1ca и
clause hash неизменны. Existing default-on setup tests/MO/N5 evidence сохраняются;
native fixture AUTO и off проверены на новом профиле. Установка/реальный reload
нового provider в обычных клиентах относится к QP5 и здесь не выполнялся.

### Неуспешные попытки сохранены

Дополнительный semantic probe текстом общего RU01 question, без исходного
lexical route, завершился MEMORY_TRANSPORT_UNCONFIRMED за20.121869s. Это реальное
наблюдение availability на новом deployment; утверждения «любой поиск <20s» нет.
Лимит не увеличивали. Для agreed original RU01 восстановлены точные query и
CHUNKS_LEXICAL из прежней sealed tool trace, без run_key оснастки; assertion
ru-n01/свежие originals сохранён. Отказ semantic probe не удалён и не объявлен
прошедшим. Старые72/72 и6/6 — отдельное reused semantic/full-answer evidence;
на новом deployment заново подтверждены только названные affected сценарии.

Первый запуск оснастки перед записью не находил Get-FileHash: Python на Windows
передавал PSMODULEPATH PowerShell7 в Windows PowerShell5.1. Точное readonly
сопоставление показало pass после удаления этой переменной только в child env.
Глобальные настройки не менялись. Дополнительно readonly provider check обнаружил
в новом source admission nested-array ошибку сохранённого Get-ItlCatalogField
array; исправлено локальное перечисление. Исходные stdout/events сохранены,
native N6 originals до действительной записи0, pending не отправлялся повторно.

Read-only Lance helper сначала не мог прочитать свой non-secret0600 script,
затем SDK потребовал временную spill directory. Сохранены оба failed результата;
изменены только права этого скрипта и isolated64MiB/tmp tmpfs нового metadata
helper. Snapshot оставался ro, Cognee containers/config/images/DB не менялись.

## Закреплённый профиль и конечное состояние

Existing policy owner теперь явно принимает старую BGE пару и одну Qwen пару:
`cognee-qwen4096-v1` +
`0a5c01ecbcbddbf37f21b517618812d6e632ca6958982b0fca457608df7df8bc`.
Смешанный/неизвестный profile/hash отклоняется; нового runtime registry/fallback
нет. Existing test case расширен проверкой обеих пар и фактического SHA файла
native evidence; старые private path/identity/off/ambiguity проверки сохранены.

В private MCP home подготовлен только
`memory/prepared/cognee-qwen4096-v1/provider-prepared.json` с17точными mappings,
обычным account, native API key locator и AUTO. Это не активный provider.json.
Owner Assert-ItlMemoryProvider принял все17scopes без network calls. Native key
не требует регулярного login/refresh; секрет и account recovery сохранены приватно.
Сетевой адрес пока operator-only loopback; normal-client transport не активирован.

После квалификации main Qwen и qualification/restore копии остановлены и
сохранены. Main Qwen байт-в-байт равен empty snapshot, working originals0.
Исходный BGE работает с прежним Config/HostConfig/Mounts; финально повторены
25datasets/84exact originals и raw hashes, ordinary principal тот же, native
pending0. Все5исходных локальных файлов совпадают с backup по SHA,2unsent intents
остались прежними. Старые стенды, failed попытки и late-copy не удалялись.

Один финальный общий disk sample показал30,617,600free bytes. Две последующие
прямые проверки того же ext4 mount дали12,614,455,296free bytes без очистки.
Причина кратковременного значения не установлена; оно не приписано нашим
снимкам. Наши retained directories занимают5,484,285,952allocated bytes.
Ничего не удалялось и allocation файлов не менялась. Actual disk proof сохранён,
перед будущим Tf/cutover остаётся прежняя сверка свободного места, без нового gate.

## Граница source delivery и возврата

Selection/reuse: прежний owner scoped-cognee-memory и тот же test file/It;
новый реально читаемый certificate JSON включён одним exact path в owner inputs,
без wildcard на OpenSpec, нового owner или смешения независимых suites.
Путь выбирает прежнюю проверку и инвалидирует её reuse при изменении evidence.
Фактические executed/reused files, стоимость и медленные группы берутся из
обязательного RegisterChange run/check summaries; повтор ради времени не нужен.

Source implementation/native qualification выполнены; штатный RegisterChange
после связного локального коммита владеет единственным Targeted. Его факт и
base/head/комбинация хранятся в shared Git queue ledger, отдельно от этого native
proof. Gate6/G6 не запускался; source-регистрация не является публикацией.

BGE snapshot/restore84/84 сохранены как комплект прежнего qualification source,
а не как рабочая память компании. Для выбранного first-empty-production-start
до рабочих writes допустим возврат прежних настроек/unconfigured состояния.
После Qwen working writes QP6 потребует Tr и native переноса текущих additions,
corrections/deletions в квалифицированный BGE; такой перенос здесь не выполнялся.
Qwen controlled restore выше доказывает currentness/repair, не выполненный QP6.

Остаются отдельно разрешаемые QP5 и при необходимости QP6, существующие R1–R5/
release prerequisites и финальный owner setup/reload. G3/R6/G5 не переоткрываются;
рабочая миграция, Gate6, publication/push/PR не запускались.
