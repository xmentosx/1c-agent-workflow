# Первые семантические решения аудита

Это частичный review; основной inventory 166/2814 сохраняет pending для
непросмотренных сценариев. Отсутствие старых failures не означает ненужность.

## CompactItlRunner: дорогие сценарии имеют разный риск

Источник fa0e3c91, CompactItlRunner.Tests.ps1; файл не менялся при переносе host
и catalog suites. Проверены реальные тела следующих сценариев:

| Исходная строка / сценарий | Риск и доказательство | Решение |
|---|---|---|
| 1085: real Win32 Ctrl+C | Реальный AttachConsole/GenerateConsoleCtrlEvent; проверяет terminal failure, lifecycle и exact Vanessa cleanup после прерывания | Сохранить process regression; serial до доказательства изоляции соседнего процесса |
| 1632: streams UTF8 stdout/stderr | Порядок видимости вывода до завершения fresh child; helper-only string assertion не устанавливает эту границу | Сохранить native regression; не заменять mock |
| 1638: foreign/stale private observation | Чужое или устаревшее сообщение не должно стать terminal success родителя; два независимых negative inputs | Сохранить обе параметризации |
| 1650: silent deadline + descendants | Истечение исходного operation budget должно завершить свой child и descendant; assertions требуют отсутствия обоих PID | Сохранить реальный process/deadline regression |
| 1664: beyond unchanged 120s watchdog | Реальная тишина 126s при неизменённом watchdog 120s; положительный reproducer исходного ложного stall | Сохранить 120s boundary; нельзя ускорить подменой времени или уменьшением workload |

Owner: compact runner и fresh continuation; inputs: runner/helper/continuation
contracts, execution guard и test fixture. Level: native process integration;
environment: Windows / PowerShell; resources: собственные временные корни,
child processes/console. Это не live 1C acceptance. Последний сценарий по
условию занимает >120 s; per-case свежие измерения других сценариев не получены.
История исходного stall не объявляется конкретным свежим passed result этого change.

Общий serial restriction сейчас применяется ко всему Compact-файлу, хотя
GenerateConsoleCtrlEvent есть в отдельном сценарии. Возможное ускорение:
выделить console canary в свой suite и доказать неизменность соседней задачи
при настоящем Ctrl+C. Одного переноса файлов недостаточно, чтобы снять serial.
Между независимыми registrations нынешний per-run serial list сам по себе
не доказывает console isolation.

## Host suite wrappers

Все 11 перенесённых wrappers выполняют разные непосредственные boundaries:
Unicode child capture, snapshot archive atomicity, HTTP identity/Linux ownership,
Linux refresh, CodeChecker beta logic, retry policy, Node proxy contracts,
BookStack response bounds/continuation, Mantis stateless server, Mantis index
recovery/write journal, SPPR corpus/HTTP transport. Решение: сохранить эти routes
и разделить по окружению (сделано в 747aa75f); необходимость каждого вложенного
Python/Node случая ещё рассматривается. Windows pass Linux suite не доказывает
POSIX locking: соответствующий skip явно записан в inventory.

Три проверки буквального числа nested tests (3/50/12) — кандидаты на замену
эквивалентным completeness proof. Они ловят неполное исполнение, но фиксируют
размер suite и требуют правки при добавлении валидного теста. Сейчас assertions
сохранены. Их удаление без защиты от пустого/частичного запуска недопустимо.

## Mantis: 13 существующих сценариев вне автоматического маршрута

Обновление одного сценария: [State route и equivalence](mantis-state-test-route.md).
Исходный метод legacy_state_migrates_to_safe_pause подготовлен к переносу без
изменения тела; original-case ledger сохранён. Автоматическая приёмка переноса
ещё ожидает регистрации. Остальные 12 маршрутов не объявляются исправленными.

Индивидуальные решения и source identities сохранены в
`mantis-route-gap-review.csv`. Просмотрены тела трёх extraction, семи Zvec и
трёх real protocol cases, включая параметры и родственные test_index assertions.
test_extract не найден в automated route и README-командах; test_zvec/protocol
имеют только ручные README-команды. Выполнение этого аудита read-only: suites
не запускались, runtime/платформенная готовность не предполагается.

Решение по 12 сценариям: сохранить поведение и подготовить принадлежавший
компоненту автоматический маршрут. Fake-vector index tests не устанавливают
real Zvec storage, migration или protocol serialization. Production image
использует Python 3.12 Linux; поддержка real Zvec на текущем Windows не проверена.
Нельзя превращать этот неизвестный runtime в общий блокер небольшой MCP-правки.
Нужны воспроизводимая component preparation и штатное продолжение оригинального
сценария на поддерживаемом backend, до добавления gate barrier.

Отдельное решение: legacy_state_migrates_to_safe_pause проверяет State/SQLite
без создания Vectors и импорта zvec внутри тела. Поведение необходимо, но его
можно перенести в дешёвый State owner после equivalence review, сохранив исходный
legacy reproducer. Это конкретное лишнее требование окружения, а не ненужный риск.

## Исторические scheduler assertions

SourceQualityCatalog сохраняет исходные исторические модели длительностей.
Проверка точного веса каждой старой строки timings не доказывает актуальную
производительность. Следующее решение аудита должно отделить воспроизводимый
capacity model от обновляемых observations, сохранив hard budgets и исходные
regressions. Пока assertions не удалены и старые durations не названы текущими.
