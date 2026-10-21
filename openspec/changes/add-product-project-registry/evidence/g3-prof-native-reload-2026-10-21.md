# G3: native ПРОФ → КОРП и reload, 2026-10-21

**Fresh native ПРОФ → КОРП и reload passed для Codex app-server core/API. Full G3 / AC-39 открыт.** Проверен неизменённый runtime `f53b9247ae9ebefb42e6f0b39d34d6e9b8800a63`; все 11 input hashes предыдущего source proof совпали. [JSON evidence](g3-prof-native-reload-2026-10-21.json) содержит точный CLI SHA, raw references, сравнение owner-командой и сохранённые failures. Это продолжение [предыдущего source результата](g3-registry-source-model-2026-10-21.md), без runtime/server fixes и без публикации.

## Handshake: что установлено

В двух прежних неудачных ПРОФ попытках Codex записал `http/request send failed`, `error_is_connect=true`, `error_is_timeout=false`, затем отказ отправки MCP `initialize`. HTTP status/ответа сервера в этих ошибках нет. Это connect-level failure, до проверки native project/namespace и бизнес-происхождения источника. Неверный продукт или недостаточный source stamp этими логами не доказан. Client config с каноническими адресами PM5 совпадает с успешным custom-проектом.

Сейчас DNS разрешил host в `10.0.12.53`; TCP 22100/22101 и контрольные 22200/22201 доступны. HEAD на канонические `/mcp` и `/mcp/` вернул 405 без redirect: это подтверждает HTTP-доступность, не MCP readiness. Proxy environment variables отсутствуют; это текущий срез, не доказательство прежних настроек ОС/сети.

Затем настоящий native Codex прочитал Code `stats`/`get_module_structure` и Graph `get_graph_project_status`/fulltext `search_code`. Graph подтвердил `pm5corp/default`, статус доступности и полезный результат. Context проекта остаётся ПРОФ, origin обоих sources — КОРП, назначение `reference-product`, явное ограничение ПРОФ сохранено. Pair занял **9.526 s**, 4 calls, модель не запускалась. Синтетические названия/ограничения fixture не заменяют подтверждённую рабочую карту функций.

Нынешние повторы не воспроизвели прежние connect failures. Их точная историческая инфраструктурная первопричина **не установлена**: сохранённые client logs не различают DNS/TCP/host/proxy причины, server/network incident logs в этом прогоне не получены. Развёртывание, restart, reindex, смена URL или доработка Code/Graph не применялись. Неизвестная причина не объявлена исправленной программным patch.

## Исходный reload journey

Использован тот же private ПРОФ root с пробелами и кириллицей, тот же applied snapshot и канонические server names. Изменялся только его тестовый Codex config: PM5 ports → существующие PM4 ports. Это controlled wrong endpoint, не изменение binding продукта или рабочего проекта.

| Фаза | Фактическое native чтение | Проверка относительно выбранного PM5 source |
|---|---|---|
| Initial | Code + Graph PM5 | matched, native activation matched |
| Конфиг уже PM4, reload ещё не вызван | Tools продолжают PM5, та же thread | Старое соединение подтверждено; для нового target PM4 actual evidence = mismatch |
| Штатный `config/mcpServer/reload` | Code + Graph PM4, та же thread | endpoint mismatch; selected PM5 source не объявлен готовым |
| Negative + новая thread | Graph на PM4 отвергает `pm5corp`: `project_not_accessible`; новая thread читает PM4 | Чужой source не подменяет выбранный |
| Исходные bytes + reload + новая thread | Code + Graph PM5 | matched, native activation matched; исходное чтение восстановлено |

Каждый pair содержит 4 native tool calls и занял 8.666–10.412 s при прежнем 20 s deadline. Дополнительный Graph negative — один safe read. Code module read signatures дали A → A → B → B → A, Graph фактический `project_id` — PM5 → PM5 → PM4 → PM4 → PM5. Signature здесь вспомогательное наблюдение raw read, не новый server ID, index-version prerequisite или runtime barrier.

Первый reload harness остановился после initial pair: он ошибочно принял `mcpServerStatus.httpOrigin` за активное соединение. Поле уже показывало записанный PM4 origin, ещё до reload. Эта попытка/её script/raw RPC сохранены, config восстановлен. При повторе выполнялись исходные реальные reads, а config-oriented status считывался после них; raw доказал **httpOrigin=PM4 при фактическом Graph/Code чтении PM5**. Исправлено неподтверждённое ожидание harness, scope/read/negative/restore assertions, topology и workload не ослаблены. Сам по себе status/config не стал доказательством activation.

## Owner comparison и preservation

Существующий handler команды `context` с explicit observation file оценил standalone ПРОФ proof и пять reload observations. Initial/before/restored Code+Graph matched; foreign source в той же и новой thread — mismatch. Отдельное сравнение записанного нового target с фактическим old read до reload дало mismatch. Descriptor project/product/source IDs не менялись; current project ПРОФ и explicit source КОРП не считались ошибочным равенством продуктов. Квитанции не переписывались, header SHA/settingsHash соответствует одному applied context.

Все **20 protected local paths** сохранили bytes и mtime, включая descriptor/applied/operation/selection/managed/client конфиги. Исходный Codex config восстановлен byte-for-byte с исходным mtime и подтверждён повторным native чтением. Global Codex config сохранил SHA; использовались отдельные private homes и ephemeral threads, exact Unicode cwd проверен. Старые stands, failed copies/capsule и прежние raw artifacts сохранены.

В принятых runs **25 safe native calls**, в сохранённом failed harness ещё 4; `turn/start=0`. Compact owner diagnostic — 668–682 UTF-8 bytes. Внутренний backend usage и token count не измерены. Новых always-on rules/tools/startup probes/owners/кэшей нет; неизменённые Pester и Startup suites не повторялись. Обязательные strict OpenSpec validation/Targeted/регистрация documentation/evidence commit учитываются обычным source-delivery ledger, не вторым журналом.

## Что остаётся

В проверенной области сняты fresh native ПРОФ transport/read/reload gaps AC-08-a/c/d и AC-20/26. Не заявлены Codex desktop/IDE frontend, остальные 11 native adapters, полный installed 1C journey/AC-39, отдельный PM4 installed stand и Windows 10/Server terminal matrix. Real release population продуктов/проектов/настроек/source origin/карты функций AC-36–38 остаётся обязательным.

Память потребляет тот же registry result в будущем consumer. G1/Q1–Q7/D9/G2, шесть областей/canonical home/grants/ai_rules_1c/optional OpenViking не меняются; G4/G5/AC-43/44 не приняты. Gate 6 не исправлялся/не запускался; working migration, server deployment/reindex и публикация/push не выполнялись.

## Коррекция all-20 timestamp claim

[Последующая client/installed qualification](g3-clients-installed-2026-10-21.md#сохранность-стоимость-и-исправление-прежнего-evidence-claim) показала, что общий guard 20 protected paths использовал hash-only `Get-ItlMcpFileState`: bytes доказаны, все 20 mtime этим guard не доказаны. Historical JSON сохранён; отдельный explicit Python byte+mtime restore Codex config и независимые Startup receipt timestamp controls остаются действительными. Новый context invocation явно проверил actual mtime_ns/SHA всех 20 paths. Kilo позднее изменил два config metadata поля — это отдельный сохранённый client finding, не часть Codex reload run и не runtime repair.
