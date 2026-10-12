# Приоритеты по стоимости и повторным отказам

Объём уточнён пользователем 2026-10-12: полный inventory и маршруты сохраняются,
сплошной индивидуальный разбор оставшихся определений не требуется. Число
прочитанных тестов не принимается как показатель ускорения или сокращения.

## Наблюдения из существующих регистраций

| Источник | Полное время | Исполнено / reused | Наблюдение |
| --- | ---: | ---: | --- |
| rejected-8d344c50 | 474188 ms | 38 / 86 | Новый consumer guard отсутствовал в ожидании selection; SPPR six-request overlap отказал |
| rejected-8777640e | 148439 ms | 14 / 112 | Selection исправлен; SPPR four-request overlap отказал |

Во втором прогоне fingerprintPlanMs=30557, workerSpanMs=107563. Самый долгий
исполненный shard — HostSourceRuntime (106918 ms), затем HostMantis (53165 ms),
HostSppr (26185 ms, failed), ParserDocsBudgets (22927 ms), OnDemandGo (21559 ms).
Cached duration старых reused workers не суммируется как время этого прогона.
Это два разных дерева и состава: сравнение не доказывает ускорение изменения.

HostSourceRuntime намеренно создаёт частную среду, удаляет tzdata и принимает
восстановление через исходный SPPR corpus. Это отдельный риск от обычного SPPR
прогона; удаление corpus acceptance или уменьшение workload не обоснованы.
Повторяется из-за cumulative legacy registration и неизвестной внешней runtime
identity. Приоритет после live — доказать безопасный owner input/runtime reuse
и измерить warm регистрацию; просто включать reuse по имени suite нельзя.
31 s fingerprinting также требует отдельного сравнения при одинаковых входах.

## Диагностика SPPR

После двух отказов общий Targeted вслепую не повторялся. Тем же isolated Python
и штатными native Pester wrappers выполнены ограниченные диагностические наборы:

- HostSppr + HostSourceRuntime, два workers: 5/0, span92643 ms.
- Дополнены HostMantis + OnDemandGo, четыре workers: 8/0, span103755 ms.
- Все14 реально исполнявшихся shards отказавшего прогона, четыре workers:
  75/0, span108743 ms. Raw `sppr-failed-selection.log` и exception trace сохранены.
- Исходные four/six overlap cases, 20 пар: 40/0 за15.012 s.

Диагностика через ignored sitecustomize сохраняла исключения Future.result;
барьер, timeout5, workload, assertions и production scheduling не менялись.
Последние два набора не логировали вход в barrier. Отказ не воспроизвёлся;
BrokenBarrierError и влияние нагрузки остаются гипотезами, не причиной.

Подтверждён отдельный дефект: worker заменял неожиданное исключение общим
SpprError и терял traceback причины из Future. Теперь причина сохранена через
exception chaining, публичный текст и persisted message остаются редактированными.
Регрессия проверяет cause identity, скрытие деталей, сохранность двух committed
vectors и продолжение без повторной отправки. Она и три исходных failure/overlap
cases passed:4/0 за1.258 s. Это улучшение диагностики, не доказанное устранение
исходного intermittent отказа. Новая регистрация проверит исходный native путь
без sitecustomize; при повторе исходная причина станет доступна в traceback.

## Условие результата

Принимать оптимизации по сравнимому cold/warm/retry времени и сохранённым
рискам. Не расширять аудит на сотни новых описаний до завершения текущей live
приёмки. Отдельно подтвердить малую изолированную доработку и параллельную
регистрацию после активации нового опубликованного supervisor.
