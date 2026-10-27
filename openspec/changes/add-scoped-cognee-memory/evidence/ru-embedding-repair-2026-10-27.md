# Разбор OOM / Cloudflare403 и продолжение исходного корпуса

Продолжение разрешено пользователем 2026-10-27. Рабочая модель и исходный
Cognee не меняются; Gate6/G6, рабочая миграция и публикация не запускаются.
[Предыдущий technical stop](ru-embedding-preflight-2026-10-27.md) сохранён.
G3/R6/G5/MO не переоткрываются, исследование не становится новым release gate.

## Граница результата

Подтверждены источники избыточной памяти, внешняя граница403 и ошибка учёта
HTTP timeout до native completion. Для изолированных экземпляров исправлены
штатные buffer/cache settings и preparation harness; server/client sources не
патчились. Подготовка **обоих** индексов завершена:50 originals /12datasets /
50 native chunks, оба text hash sets точно равны frozen corpus. Конечный эксперимент
завершён:144/144 attempts и12/12 полных Codex answers. Qwen лучше ранжирует
на успешных запросах, но40/72 timed requests недоступны в пределах20s.
Рабочая модель остаётся прежней; Qwen не принят как её замена.

## Память: факты, исправление и предел доказательства

Закреплённый Cognee 1.6.5 / image
`sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`
сохраняется. Предыдущий OOM относится ко всему процессному дереву контейнера
с лимитом5GiB, а не к локальной загрузке Qwen8B: embedding inference удалённый.

В native `graph/ladybug/adapter.py` значение
`DEFAULT_KUZU_BUFFER_POOL_SIZE=1<<35` (32GiB); в исходном профиле
`KUZU_BUFFER_POOL_SIZE` не задан. Это верхний размер пула, **не доказательство
фактического выделения32GiB RAM**. Отдельный native component probe на шести
одинаковых маленьких базах дал peak RSS471351296bytes с исходным пулом и
72368128bytes с пулом256MiB, оба без OOM. Измеренное снижение —398983168bytes.
Это доказательство вклада настройки, не приёмка исходного целого сценария.

Другая существенная составляющая — отдельные subprocess workers на dataset.
В реальном partial Qwen-run основной процесс имел около2.4GiB RSS, каждый
LanceDB worker —260–330MiB, Ladybug —80–110MiB. Роли подтверждены открытыми
`.lbug` и загруженными native Lance/Ladybug libraries. Graph и vector factories
независимо используют `closing_lru_cache` с исходным
`DATABASE_MAX_LRU_CACHE_SIZE=6`. RSS разных процессов нельзя складывать как
точный cgroup total: shared pages учитываются повторно.

Для **обеих** экспериментальных моделей выбран одинаковый исправленный профиль:

| Параметр | Значение |
|---|---|
| CPU / RAM / swap limit | прежние2CPU /5GiB /5GiB |
| `KUZU_BUFFER_POOL_SIZE` | 268435456bytes (256MiB) |
| `DATABASE_MAX_LRU_CACHE_SIZE` | 4 на штатный factory cache |
| `DATASET_QUEUE_MAX_CONCURRENT` | прежнее2 |
| Extraction / embedding batch / input limit | прежние GLiNER /32 /512 |
| Model BGE | прежний FastEmbed `BAAI/bge-small-en-v1.5`,384 |
| Model Qwen | native `openai_compatible`, `qwen/qwen3-embedding-8b`,4096 |

Четыре cached engine entries **не означают четыре области памяти**. Все шесть
логических областей и все12datasets корпуса остаются, включая чужие области и
старый cycle. Изоляция subprocess, native eviction/leases, currentness, caps и
assertions не отключены, лимит RAM не увеличен. Это конфигурационная коррекция
существующего владельца; собственный cache manager/embedding pipeline не добавлен.
Точный вклад каждого компонента в прежний исторический OOM без сохранённого
профиля памяти того процесса не восстановлен. После восстановления и продолжения те же50 originals /12datasets обработаны
на исправленном профиле и native control подтвердил50 chunks. Максимум
сохранённого cgroup peak: BGE3663265792bytes (3.412GiB), Qwen4378079232bytes
(4.078GiB), при прежнем limit5GiB; native memory.events max/oom/oom_kill =0.
Это полный допуск данного корпуса, а не вывод только по component probe.
Qwen-подготовка возобновлялась после технических остановок; она не выдаётся за
один непрерывный cold run или за гарантию ресурсов при любой нагрузке.

## 403: подтверждённый внешний отказ до записи оригинала

В профиле `ru-embedding-repair-20261027-pair3` получен полный запрос штатного SDK:

```json
{"input":["test"],"model":"qwen/qwen3-embedding-8b","encoding_format":"float"}
```

Endpoint: `POST https://openrouter.ai/api/v1/embeddings`.
2026-10-27T11:25:05Z: HTTP403, `Server: cloudflare`,
`CF-Ray: a511568aed176acd-HEL`, тело
`{"success":false,"error":"Access denied by security policy."}`.
Cookie names зафиксированы, значения и authorization в отчёт не включены.

Это служебная dimension probe native Lance integration. В этот момент нет
ни original в dataset inventory, ни строки native pipeline для dataset.
Отказ не вызван русским корпусом, чужой областью, правами обычного Cognee-user
или истечением его APIkey. Cognee оборачивает его в
`EmbeddingCredentialsError` / HTTP422; такое имя исключения само не доказывает
неверный OpenRouter key.

Без изменения endpoint/key/запроса тот же SDK probe затем дал HTTP200/4096:

- сеть существующих MCP `itl-karimov-native_default`: `CF-Ray a5115e939b509cbe-CDG`;
- исходная Docker `bridge`: `CF-Ray a51166092e18d0a7-CDG`.

Permanent difference между сетями не установлена, поэтому смена сети не выдана
за исправление. DNS в обеих сетях возвращает одинаковые адреса. IPv4 TCP/TLS и
public HEAD `/api/v1/models` в отдельной пробе работали; IPv6 немедленно вернул
ENETUNREACH, а не длительное зависание. Точное правило Cloudflare — geolocation,
bot detection или иное — **неизвестно без журнала владельца сервиса**. Суффикс
CF POP не является доказательством страны клиента. Подмена TLS/IP/геолокации,
новый proxy/VPN, перенос cookies или отключение security policy не выполнялись.

## TCP/TLS и ограниченный повтор

Native debug подтвердил `connect_tcp(host='openrouter.ai',port=443,timeout=120)`
с повторными ConnectTimeout; позже — `start_tls` с
`ConnectError(BrokenResourceError())`. Это отдельные наблюдаемые transport
failures, не доказанная причина конкретного403.

В диагностике одного и того же harmless `ru-n11` четыре одновременных SDK-вызова
дали0/4 successes; при старте с интервалом1s —3/4, ещё один timeout. Это малый
component sample, а не причинное доказательство WAF rule или статистическая
оценка качества модели. Включены существующие native параметры
`EMBEDDING_RATE_LIMIT_ENABLED=true`, `EMBEDDING_RATE_LIMIT_REQUESTS=1`,
`EMBEDDING_RATE_LIMIT_INTERVAL=1`. Они не исправили транспорт полностью:
после16 подтверждённых originals вновь получен native HTTP422 / connection error.

## Сопоставление с действующими MCP

Live inspect подтвердил: Code, Graph и экспериментальный Qwen Cognee используют
одинаковые ключ (сравнение SHA-256 без вывода секрета), endpoint
`https://openrouter.ai/api/v1` и модель `qwen/qwen3-embedding-8b`. Значения
`remote` / `openai_compatible` — названия локальных адаптеров, а не разные аккаунты.
Proxy environment variables у Code и Cognee отсутствуют. Encoding — `float`.
Рабочие серверы, их настройки и индексы не изменялись.

Code использует `langchain_openai.OpenAIEmbeddings`, отдельный query client,
query LRU и собственную retry policy (`max_retries=0` внутри SDK). Cognee
использует штатный `AsyncOpenAI` с timeout120 и внешним native retry budget128;
BookStack — HTTPX, scalar input для одного текста и `provider.sort=latency`.
Дополнительно native source подтверждает OpenAI SDK3.6.0 у Code против2.54.0
у Cognee (HTTPX0.28.1 у обоих), default Code API timeout600s против жёстко заданных
120s в Cognee adapter и Qwen query instruction в Code. В Cognee такой instruction
в этом профиле не добавлен. Следовательно, одинаковые model/key/URL не означают
идентичные библиотеки, ожидание и query preparation. Это не повод копировать
Code task instruction в knowledge search или менять production SDK.
Эти различия **не доказывают причину403**. У Code
`EMBEDDING_ALLOW_OFFLINE_FALLBACK=false`; успешный `codesearch` за5.497s имел
`vector+bm25`, но первый item был fulltext. Один этот ответ не доказывает новый
внешний embedding call. Отдельный свежий BookStack diagnostic дал embedding
7664.6ms с query/disk/provider cache MISS; ключ BookStack отдельно не сравнивался.

В ограниченном component comparison из того же pinned Cognee image, той же
bridge network, с теми же ключом/model/URL и harmless `test` все четыре пути
вернули4096 dimensions:

| Клиент | Длительность | Результат |
|---|---:|---|
| OpenAI SDK sync | 13.266s | HTTP200, Nebius |
| OpenAI SDK async | 9.223s | HTTP200, DeepInfra |
| HTTPX с native BookStack request shape | 5.916s | HTTP200, Nebius |
| Штатный LiteLLM/OpenRouter | 14.281s | Успешный native result; HTTP status отдельно не извлечён |

Версии image: Cognee1.6.5, OpenAI2.54.0, HTTPX0.28.1, LiteLLM1.106.0.
Это по одному вызову каждого пути, без повторов до успеха и без ranking/gold.
Длительности не являются парным поисковым benchmark и не доказывают превосходство
одного клиента. Подмена headers/TLS, перенос cookies, proxy, другой ключ или
endpoint не применялись. Постоянная несовместимость SDK не подтверждена;
переход на собственный HTTP transport или дополнительный сервис не обоснован.
Запрос поддержки OpenRouter не отправлялся. Общая недоступность аккаунта
опровергается успешными свежими вызовами; точное правило прежнего403 неизвестно.

Сверка `ru-n17` через native raw API подтвердила единственный original с прежним
SHA-256; native processing-status показал8 completed /1 pending, activity feed —
terminal failed. Поэтому выполнен один штатный `POST /api/v1/cognify` для того же
dataset с `dataPerBatch=1`, без нового remember/ручной правки БД. Он завершился
за62.142s,9/9 completed. Существующий ingestion helper сверил original через
GET/raw без повторного POST и продолжил неизменённые заметки. Это восстановление
прерванного fixture, не исправление Cloudflare policy и не смена модели.

Первоначальный `OPENAI_LOG=debug` подавлялся Cognee logging configuration.
Для диагностики применяется обычная Uvicorn app factory: она возвращает тот же
native FastAPI app и включает Python logger `openai._base_client` после import.
Никакие SDK/embedding methods, обработчики или исходники Cognee не изменены.
Factory/code/logging применены к обоим экспериментальным экземплярам и не
поставляются как workflow runtime. Ошибка чтения diagnostic directory при первом
старте non-root user исправлена только для публичного script-directory755;
private directory остаётся700. Этот fixture failure сохранён отдельно.

## Безопасное возобновление и данные

Корпус, вопросы и private gold прежние: 50notes /24queries,
manifest `ru-embedding-1.1`. Corpus SHA-256
`883c6b467a5ccfe5248e967849b53c6dea65e1cf8aa25269009ed513bf0c4cd0`;
questions SHA-256
`390feb33ff4c992a16b2d20a16743c6162df595af2126857698814091950377d`.
Gold и primary/relevant targets не изменялись и не отправлялись Cognee/агентам.

После подтверждённого HTTP200 той же intrinsic probe сначала выполнены
native original reconciliation и read-only проверка pipeline records: для
`ru-n01` inventory пуст и pipeline rows0. Только после этого выполнено одно
явное продолжение того же intent: native remember вернул200/completed,
один original,63.059738s. Ни Cognee DB/status, ни harness journal вручную не
правились. Затем существующий ingestion helper через GET/raw подтвердил этот
original без повторного POST и продолжил прежние notes. Автоматический403 retry,
смена пользователя/ключа или destination не добавлены. Первый failed403 сохранён.

До нового transport failure native raw GET подтвердил16 originals;
`ru-n17` восстановлен описанным выше native cognify. Semantic completeness50/50
у Qwen теперь доказана native control и полным сравнением text hashes. Исходные144 main searches выполнены на допущенной полной паре;
после сохранения144 attempts выполнены12 Codex answers. Native source/frontend caps20s /8cards /
1600tokens остаются прежними. Подготовленная benchmark оснастка теперь также
ограничивает **весь** read-request20s, а не каждый отдельный socket I/O; одна
failed warmup сохраняется и не удаляет последующие фиксированные24cases.
Это усиление точности измерения, не изменение runtime или ослабление критерия.

## BGE и состояние продолжения

Повторная загрузка BGE на исправленном профиле завершена:50 exact originals,
12datasets,640.995s; native control вернул50rows. Проверка полного множества
text hashes завершена для обеих моделей: ровно50, без лишних/изменённых chunks.
Candidate native control вернул50rows за30.980225s, BGE — за18.355139s.
Это12dataset completeness controls вне144, с прежним control timeout120s,
не samples20s search budget. `both-index-admission.json` и
`indices-public-bundle.json` (SHA-256
`576f2c341d30eecaaa5027750c9e4581de24d5f47f55d71b1ded03595476cfa0`)
сохраняют native proof. Исходные24questions×3×2 =144 attempts выполнены сбалансированно:
BGE1/Qwen1/Qwen2/BGE2/BGE3/Qwen3; по одному warmup вне144 на блок.
Main deadline20s прежний, failed warmup не скрывается и не удаляет24cases.
Native attempt, качество, полный агентский ответ и регистрация — разные факты.

После сопоставления действующих клиентов установлено, что прежний запрос
provider access был преждевременным: свежие успешные вызовы есть. Минимальный
incident с exact payload/time/CF-Ray сохранён, но никому не отправлен. Новый
transport/proxy, ключ, сеть или профиль модели ради обхода403 не добавлены.

Отдельно подтверждён дефект preparation harness: ожидание HTTP-ответа для
`ru-n26` закончилось через180s, но native remember продолжил работу и завершился
успешно за274.95s; processing-status показал10/10 completed. Эта попытка
сохранена как HTTP timeout плюс отдельное native eventual success, без подмены
исходного failed observation. Оснастка теперь после такого timeout не повторяет
remember: она сверяет единственный exact raw original и читает processing-status
этого dataId с отдельным ограниченным продолжением до180s. Только completed
позволяет продолжить загрузку. Pending сохраняется и останавливает подготовку;
автоматического retry native failed pipeline нет. Ограничения исходного HTTP
ожидания180s, поискового whole deadline20s и runner budget5400s не увеличены.
Дополнительное ожидание — контроль завершения подготовки, не успешный timed
поиск и не изменение production frontend. Старый controller сохранён по SHA.
Таким образом HTTP timeout не выдаётся ни за гарантированный native failure,
ни за разрешение повторить запись. Работа продолжается в прежнем SDK profile.

## Сохранение, совместимость и доставка

Старые failed stands и все три repair profiles сохраняются раздельно в
`/home/mcp/itl-g5/ru-embedding-20261027-0852` и
`/home/mcp/itl-g5/ru-embedding-repair-20261027-pair1..pair3` на
`dev-karimov-mcp`. Перед изменением profiles предыдущие контейнеры штатно
остановлены, их DB/intent/evidence не заменялись. Один benchmark arm работает
одновременно; исходный G5 Cognee и Code/Graph не заменяются.

Локальные inputs, native responses и scripts:
`build/agent-artifacts/memory-ru-embedding-repair-20261027/`;
старый task retention/completion не переписан. APIkey остаётся в существующем
user-local MCP home / private host storage; provider key на ПК не переносился.
В source меняются документы обеих OpenSpec и точный ignore runtime receipts
`.agent-1c/diagnostic-artifacts/`: стандартный cleanup сохраняет их у прежнего
владельца, они не должны попадать в Git. Dirty guards и source-delivery не меняются. Git-реестр, canonical home,
различия project/MCP-source, общий доступ, шесть областей, policy ai_rules_1c
и рабочая embedding-модель прежние. Native fixture reader не выдаётся за
installed acceptance или новый qualified G1 production profile.

Документы проходят обычные strict OpenSpec checks и регистрацию
`RegisterChange -QueueId product-project-registry-g2 -CoverageContract documentation`;
Targeted принадлежит только helper. Доставка не является доказательством
качества/скорости Qwen или разрешением на rollout. Конечный остаток144/12 завершён. Непринятая замена рабочей модели
не превращается в дополнительный release gate.


## Итог конечного сравнения, 28 октября (МСК)

Все144 attempts сохранены, без дополнительных повторов до успеха. Все40 failures
Qwen — whole-request TimeoutError на20s; они не удалены из знаменателя.
Новых403 HTTP responses в native SDK trace этого продолжения не обнаружено;
исторический403 и его неизвестное CF rule сохраняются. Успешный повтор не
доказывает постоянного устранения внешней policy или TCP/TLS нестабильности.

| Метрика | BGE384 | Qwen4096 |
|---|---:|---:|
| Ответ в пределах20s | 72/72 | 32/72 |
| Failed timed attempts | 0 | 40 |
| Median /p95 успешных requests | 10.325 /10.741s | 16.271 /18.923s |
| Primary MRR с unavailable как miss | 0.4190 | 0.3986 |
| Primary Recall@3 с unavailable как miss | 0.6522 | 0.4493 |
| Primary MRR на31 одинаковых успешных положительных парах | 0.3830 | 0.8871 |
| Primary Hit@1 на этих31 парах | 16.1% | 77.4% |
| Primary Recall@3 на этих31 парах | 67.7% | 100% |
| Чужие datasets / изменённые chunks в выдаче | 0 /0 | 0 /0 |

Rank измерен **внутри dataset целевого original**, без выдуманного global union
rank и сравнения абсолютных scores двух моделей. RU24 — negative/abstention,
не включён в MRR/hit denominator. Success-only31 — дополнительный срез с
отбором по доступности, не замена полной выборки. Для40 failures полная
backend latency неизвестна:20s — время до unavailable, не завершения backend.

Read-phase cgroup CPU1354.614 /1016.304s и peak1618051072 /1432383488bytes
относятся к BGE/Qwen measured block intervals **включая6 отдельных warmups**
(по3 на модель), без process startup. CPU удалённого Qwen inference здесь
не измерен. Native embedding monetary cost остаётся unknown; меньший local CPU
не доказывает меньшую общую стоимость. JSON row byte counts — proxy повторной
сериализации, не actual wire bytes и не количество токенов контекста.

### Полные ответы через прежний scoped frontend

12 fresh ephemeral Codex CLI runs, один и тот же gpt-6.1-sol/high, без shell,
web, других MCP или write tools. Те же6cases на модель, прежние caps:
3recall /4exact /1local status,8cards /1600 configured token budget /20s.
Gold клиентам не передавался; оценивался **весь** ответ и tool trace, а не
только совпадение noteId. Все caps соблюдены, guessed-ID bypass и scope widening
не использовались, запись памяти не выполнялась.

| Case | BGE | Qwen |
|---|---|---|
| RU01: пустой массив, ru-n01 | Выполнен | Выполнен |
| RU10: документ/справочник, ru-n05 | Выполнен | Выполнен |
| RU16: отозванная/актуальная ревизия, ru-n08 | Выполнен | Выполнен через exact original после transport error |
| RU20: переносимое в ПРОФ правило, ru-n10 | Выполнен | Безопасный unavailable; конкретный факт не получен |
| RU22: клиентская инфраструктура, ru-n20 | Выполнен | Выполнен; scope не расширен по origin |
| RU24: неизвестный сертификат/срок | Корректный bounded отказ | Корректный bounded отказ |

Итого выполненных задач6/6 против5/6; безопасное обращение с неизвестностью,
актуальностью, применимостью и границами —6/6 у обоих. В RU20 Qwen не выдумал
конкретный факт; общая рекомендация не считается получением нужного знания.
Median whole-answer52.872 /59.178s, суммарно322.932 /360.555s для BGE/Qwen.
Tools: BGE15recall+9exact+6local, Qwen14recall+12exact+6local.

CLI aggregate input625665 /631020tokens, cached subset523392 /543744,
uncached102273 /87276, output3350 /3913 (reasoning76 /323 — subset).
Это суммарные входы нескольких model requests с повторяемым source/client
context. Их нельзя выдавать за memory-only tokens, независимую экономию Qwen
или новое сравнение с files-only. Порядок и prompt cache влияют на uncached;
экономия контекста новой моделью здесь **не доказана**.

Два pre-client preparation failures сохранены: Windows PowerShell5 не распознал
UTF-8 без BOM, затем не загрузил Get-FileHash. Исправлены только encoding того
же fixture script и явный import native PSHOME Utility. Model calls на этих
двух failed preparations =0; native cases не повторялись. Cyrillic+whitespace
fixture paths, assertions, policy proof и caps сохранены. PSModulePath reset
применён только к дочерним процессам по existing source process contract.

### Решение и остающийся предел

Qwen даёт существенное улучшение semantic ranking на доступных ответах,
но текущий native profile/канал не обеспечивает приемлемую доступность при
прежнем20s budget и не улучшил итоговые ответы. Рабочая BGE не переключается.
Исправлены подтверждённый RAM contribution в test profile и ошибочная
классификация HTTP wait в harness; нестабильность TCP/TLS не объявлена устранённой.
Точное правило исторического403 остаётся неизвестным. Его нельзя объявлять
невалидным ключом/обязательной ротацией или решать новым proxy/fork Cognee.
После основного сравнения новые SDK, дополнительные profiles, увеличенные
пороги и дополнительные сценарии не вводились.

Эксперимент закрыт в конечном согласованном объёме; дальнейшая оптимизация
Qwen требует отдельного ограниченного решения. G3/R6/G5/MO не переоткрыты,
это не блокер первого выпуска с прежней моделью. Gate6/G6, рабочая миграция,
workflow/fork publication, push/PR не запускались.

Primary retained evidence: frozen-manifest, both-index-admission,
indices/searches-public-bundle, recall-completion, native-answer-completion,
все144native case JSON, все12полных answer/events/tool traces и recovery scripts
в текущем ignored task root. Search bundle SHA-256
`1882c358e4b59397bd2be0ada2ff2ffad3860342f038b661e7903144186c06dd`.
Документы и mandatory Targeted/регистрация отделены от этих native результатов.
