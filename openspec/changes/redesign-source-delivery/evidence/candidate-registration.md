# Общий кандидат при регистрации: первая единица C

Checkpoint пользователя от 2026-10-11 записан в `../design.md`. Реализация
регистрации подготовлена; штатная RegisterChange этой единицы ещё требуется.
Замороженная публикация C.7–C.10 и полный controller rollback C.11 не завершены.

## Протокол

Существующий supervisor остаётся владельцем. Новые RegisterChange выбирают
опубликованный develop; master-релизы и закреплённая authority старых планов
сохраняют прежние маршруты. До публикации нового владельца реально действует
его прежний registration code, а не код task checkout.

Registration снимает queue/candidate snapshot, собирает комбинацию в собственном
worktree и выполняет Targeted от предыдущего принятого кандидата. Для legacy
queue без квалифицированного candidate первая проверка включает всю комбинацию
от develop. Список изменений задачи остаётся её собственной дельтой; очередь
не заменяется веткой интеграции. Текстовый либо семантический конфликт сохраняет
принятые refs и исходную задачу.

Одна Git transaction проверяет прежние refs и принимает queue base/head,
candidate commit и membership blob. Длительная проверка не держит общий lease.
Проигравшая CAS попытка пересобирает tree; прежний input-bound shard cache остаётся
единственным путём повторного использования результатов. Исходный deadline
охватывает все попытки и ограничивает дочерние gates. Новый явный вызов продолжения
получает новый бюджет; бесконечного автоматического CAS retry нет.

Отказ сохраняет candidate worktree и `build/source-registration/checkpoint.json`.
Продолжение — тот же RegisterChange из исходной задачи с тем же QueueId.
Успешная регистрация сохраняет checkpoint, gate logs, local reports и manifest
их SHA в common Git `itl/registrations/v1/<run-id>` перед удалением своего worktree.
Membership blob связывает candidate с этим manifest. Это архив доказательств,
не новый cache admission. Сбой архива оставляет старые accepted refs и worktree.

Status показывает legacy/ready/requires-integration; поздние изменения legacy
refs требуют новой интеграции и проверки, а не ручной переписи candidate.
Это состояние не заменяет Develop/Release qualification.

## Первый штатный gate и исправление владельца

Первый commit `f8d1e665` не принят: Targeted failed за 409208 ms, raw 410857 ms:
`itl/runs/20261011-061211-846-targeted-eabaede4cf9140b88270730f108632b0.json`.
Завершились первые четыре файла; восемь failed assertions и их каскады связаны
с новым расчётом deadline по умолчанию. Windows PS5 выбрал Int32 overload
`Math.Max(0, MaxValue-now)`. Исправление находится в владельце Invoke-SourceGate:
для отсутствующего общего deadline прежний расчёт не меняется; конечный deadline
ограничивает бюджет через явно double operands. Assertions и маршруты прежних
publication/resume/orphan сценариев сохранены.

Отдельно подтверждена повреждённая кириллица в native stderr этих ошибок.
Source entrypoint и supervisor теперь явно устанавливают UTF-8 до запуска
или декодирования дочерних процессов. Точный Unicode round-trip проверяет
ошибку отсутствующего gate с абсолютным путём, содержащим пробелы и кириллицу,
и успешное продолжение той же alpha задачи с тем же QueueId через исправленный
путь gate. PS5 переносит длинное сообщение даже внутри кириллического слова;
регрессия убирает только CR/LF форматирования, сохраняя каждый пробел и символ.
Это исправление доказанного неверного ожидания физически одной строки,
не разрешение потери символов. Сценарий вместе с исходным semantic conflict
прошёл за 89.80 s. Повторный штатный gate исправленного commit ещё требуется.

Status после первого отказа подтвердил сохранённые base `fa0e3c91` / head
`fccd4048`, отсутствие активной операции и sourceCandidate legacy. Новый маршрут
RegisterChange использует published develop writer; indexStatus стал ready,
invalidCount 0, без ручного repair. Status authority остаётся master reader
boundary и не выдаётся за authority завершившейся регистрации.

## Проверенные границы до штатной регистрации

- Native Desktop: mergeable alpha и beta проходят отдельно; их несовместимая
  комбинация завершается exit 29 при регистрации beta. Alpha и оба task HEAD
  сохранены. 71.38 s; после добавления Unicode failure/continuation — 89.80 s.
  Проверка hook стоит перед завершающим exit тестового gate.
- Native Desktop: два независимых процесса доходят до барьера своих gates
  одновременно. Два начальных BaseRef совпадают, третья проверка использует
  candidate победителя. Сумма attempts равна 3; конечный commit содержит обе
  задачи, membership содержит alpha/beta. 81.60 s. Это доказательство реальной
  CAS-гонки; после добавления архива окончательное покрытие проверит RegisterChange.
- Native Desktop: legacy base/head refs включены в первую комбинацию; поздняя
  запись по старому ref-интерфейсу включена в следующую дельту. Два accepted
  диапазона сохранены. После добавления архива сценарий прошёл за 94.46 s;
  проверены SHA manifest и каждого сохранённого файла и ссылка на raw gate record.
  Это совместимость интерфейса refs, не исполнение полного старого controller
  и не завершённая приёмка rollback публикации.
- Owner sequencing с подставленными gate/CAS границами: повторные проигрыши
  используют один deadline и одно чтение бюджета; операция прекращается,
  checkpoint сохраняет QueueId, task HEAD и source root. 1.11 s. Этот сценарий
  не выдаётся за нативный timeout дочернего процесса.
- Divergent published develop/master fixture: RegisterChange выбирает published
  develop, release выбирает master; candidate supervisor не запускается. 6.83 s.
  Остальные существующие old-plan/resume сценарии сохранены для штатного gate.

Первоначальный текстовый конфликт с путём «скрипт с пробелами.ps1» сохранён.
Ожидание изменено в соответствии с утверждённым C: отказ теперь при второй
регистрации, вместо принятия несовместимого диапазона с последующим отказом
публикации. Assertions принятого диапазона, Unicode-пути и сохранности refs
усилены; путь и конфликт не заменены удобным стендом.

Injected gate fixture раньше полагался на build directory исходного checkout,
созданный старым RegisterChange. Теперь fixture сам создаёт каталог своих логов;
qualification продолжает исполняться в интегрированном worktree. UTF-8 stdout
задан явно. Pester source с кириллицей сохранён с UTF-8 BOM для Windows PS 5.1.

Новый suite имеет четыре сценария и отдельный owner contract. Loaded production
definitions входят в reuse closure, не расширяя selection на каждый helper.
Вес 279 s получен из четырёх case times штатного b0c7168f worker-5:
1.040 + 90.716 + 83.631 + 97.981 s, плюс 5 s, округление вверх.
Вес PesterRuntimeProof 90 s взят из сохранённого fccd worker-12 JUnit:
84.857 s case sum + 5 s. Отдельной регистрации весов нет.

Вторая штатная регистрация b0c7168f завершилась отказом: check 942611 ms,
16 выполненных файлов, три ошибки в SourceQualityCatalog. Все четыре новых
C сценария и 15 SourceDeliveryQueue прошли. Списки ожидаемых владельцев и
тестов отставали от добавленного source-candidate-registration. Исправлены
точные составы, сохранены прежние владельцы и отсутствие Develop journey.
Три затронутых сценария проверены отдельно. Историческая модель E сохранена;
текущая модель дополнена весом новых проверок. Очередь при отказе не продвинута.

Пять минут для произвольной небольшой доработки пока не доказаны. Полный audit
остаётся 261/2814 исходных definitions; новые C сценарии не прибавляются к этому
baseline. Стендовые версии, Python/Mantis runtime routes, frozen publication и
полная совместимость старых controller/планов остаются следующей работой.
