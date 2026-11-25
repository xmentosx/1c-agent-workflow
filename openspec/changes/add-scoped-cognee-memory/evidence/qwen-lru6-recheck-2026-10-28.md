# Qwen: повтор RU21 и72 запросов с native cache6, 2026-10-28

## Результат

Согласованный native profile прошёл отдельный RU21 и все72 исходных timed
requests при прежнем whole deadline20s. Рабочая модель/установка не менялась.
[Предыдущие144/12](ru-embedding-repair-2026-10-27.md) и failed evidence сохранены;
этот результат не заменяет их задним числом и не переоткрывает G3/R6/G5/MO.

## Применённое изменение и сохранённые условия

На dev-karimov-mcp подготовлена отдельная копия:
`/home/mcp/itl-g5/ru-qwen-lru6-20261028`, container
`itl-cognee-ru-qwen-lru6-20261028`, loopback port18203.
Source `itl-cognee-ru-repair3-qwen` /pair3 остался остановлен и сохранён.
935files /147645083bytes базы скопированы побайтно с подтверждением SHA-256.
Native DB/status не правились;50 originals повторно не добавлялись.
Общие managed model caches переиспользованы, не скопированы в новый runtime.

Точный env diff новой копии относительно source содержит **две** записи:

```dotenv
DATABASE_MAX_LRU_CACHE_SIZE=6
EMBEDDING_RATE_LIMIT_ENABLED=false
```

`KUZU_BUFFER_POOL_SIZE=268435456` сохранён. Не менялись2CPU/5GiB RAM/5GiB swap
limit, queue2, batch32, input cap512, bridge network/MTU, provider/key/endpoint,
Qwen4096, auth/common user, API mode, extraction и command. Тот же Cognee1.6.5
image `sha256:e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`.
Logger-only diagnostic factory прежняя; Cognee/SDK/Code/Graph sources не патчились.
Секреты остались в native private host storage, в Git/вывод не включались.

## Тот же корпус и протокол

Локальные frozen files `ru-embedding-1.1` прежние:
corpus SHA-256 `883c6b467a5ccfe5248e967849b53c6dea65e1cf8aa25269009ed513bf0c4cd0`;
questions `390feb33ff4c992a16b2d20a16743c6162df595af2126857698814091950377d`.
Новый native control вернул50chunks; **полное** множество text hashes равно
frozen corpus. Каждый из72query texts и списков6dataset IDs совпал с прежним
case/replicate. Возвращённые notes сверены с frozen objects, чужих datasets,
подменённых и лишних originals не найдено. Шесть logical scopes/12fixture
physical datasets, product home и отличия проекта/MCP-источника сохранены.
Gold не менялся, не передавался Cognee и читался только offline evaluator.

Повторён отдельный RU21, затем24questions×3 =72requests. Внутри72 — тот же
CHUNKS/top_k24/only_context=false/один union recall, два cold process blocks
(1и3), один warm (2). Один warmup20s на блок вне72, как прежде. Все3warmups
получили ответы:16.163 /2.116 /15.839s. Native completeness control с прежним
120s budget находится вне timed samples и не увеличивает20s search deadline.

Исходная `request()` сохранена с AST-identical implementation: Linux timer
ограничивает весь HTTP read, а не отдельные socket I/O. Повторов до успеха,
исключённых timed failures, новых вопросов и смягчённых assertions нет.
Полные Codex answers и повторная ingestion в этом задании не запускались.

## Численные результаты

| Метрика | Прежний Qwen cache4/pacing1s | Новый Qwen cache6/pacing off |
|---|---:|---:|
| Timed responses | 32/72 | 72/72 |
| TimeoutError на20s | 40 | 0 |
| Median успешных requests | 16.271s | 3.137s |
| p95 успешных requests | 18.923s | 6.647s |
| Maximum нового timed набора | — | 13.698s |
| Primary MRR с unavailable как miss | 0.3986 | 0.9130 |
| Primary Recall@3 с unavailable как miss | 0.4493 | 1.0000 |

Это сравнение двух **Qwen profiles**, не новый парный benchmark BGE против Qwen:
BGE с cache6 здесь не измерялся. Для40 прежних failures full backend latency
неизвестна; их20s не подменяется успешной service latency. Ranking — внутри
целевого dataset; global union rank/межмодельные scores не выдумываются.
RU24 negative исключён из MRR/hit denominator и сохранён в72attempts.

RU21 standalone получил ответ за12.705286s. Три RU21 внутри основного набора
завершились за6.646728 /4.757317 /4.061213s; primary original в rank1 во всех.
Native lock errors `Could not set lock` /`Resource temporarily unavailable` в
журналах нового container не обнаружены. TCP/TLS failed и HTTP403 —0.

Peak read memory1701060608bytes (1.584GiB) при исходном limit5368709120bytes.
Во всех3block memory.events max/oom/oom_kill/oom_group_kill=0; container OOMKilled
false. CPU125.009s за измеренные block intervals **включая3warmups**, startup
вне интервала. Ingestion peak cache6 не измерялся: corpus/index переиспользован,
поэтому это приёмка указанного **чтения**, а не доказательство любых writes/load.
Native embedding monetary usage/cost unknown, экономия контекста не заявляется.
Количество logical scopes и внешних embedding calls не сокращалось; сняты
ограничения native profile. Раздельный вклад двух флагов не изолировался,
провайдер/время наблюдения не контролировались как randomized experiment.

## Сохранённые оговорки

В захваченных логах17 native shutdown warnings `cannot schedule new futures…`
при плановых cold restarts, без других runtime issue lines. Они сохранены
отдельно от запросов; их отсутствие/исправление не заявляется. Это не прежний
Ladybug lock: в query intervals lock и20s failure отсутствуют. Все72результата
сохранены, а не повторялись до зелёного.

Подготовка имела два pre-scenario fixture incidents, оба до запросов/model calls.
Первый guard сравнивал byte SHA локального frozen JSON с remote pretty JSON;
исправление требует source/clone bytes equality, canonical parity **и всех50
exact serialized-note payload hashes**, не просто игнорирует mismatch.
После копирования935files последний print recovery script имел NameError;
готовая stopped copy подтверждена отдельной проверкой ID/image/env/resource
parameters без повторного create/копирования. Ошибочные attempts/скрипты
сохранены. Они не включены в успешность native RU21/72.

Согласованная настройка вместе сняла наблюдавшиеся тайм-ауты на этом workload.
Это не автоматическое принятие Qwen как production model. Прежние12full answers,
включая unavailable RU20, не заменены предположением об их исправлении; они
здесь не повторялись. Конкурентные проекты/ingestion и произвольная нагрузка
не квалифицировались этим заданием. Шесть областей, common connection,
ai_rules_1c policy и опубликованный registry не меняются. Новый rollout/release
barrier не вводится. Gate6/G6, рабочая миграция, workflow/fork publication,
push и PR не запускались.

## Evidence и доставка

Native proof: `build/agent-artifacts/memory-qwen-lru6-recheck-20261028/`,
включая verified clone/input parity, index-admission, separate RU21, все72case
JSON +3warmups, cgroup resources, source hashes, frozen input hashes и native
logs. `collect-result-1.stdout.json` SHA-256: 763636f68d2e20bba8b94c2430dfcc8a4e62cc05567e934a1576e5b1fe11127d.
`recheck-result.json` хранит exact actual values и проверки границ.

После сбора результатов остановлен только новый owned test container; исходные
failed stands/DBs и рабочая установка сохраняются. Strict OpenSpec validation,
локальный commit и RegisterChange — отдельная source delivery, не замена native
proof. Targeted запускает только existing registration helper с documentation
coverage; другие gates этой работой не выбираются.
