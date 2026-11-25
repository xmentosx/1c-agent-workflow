# R6: исправление блокера регистрации Git deadline

**Причина подтверждена и исправлена у существующего владельца очистки.** Исходный `ProductProjectGitSave.Tests.ps1` не изменён: transport reserve 3 s, закрытие соединения до абсолютного deadline и return `<10 s` сохранены. Source implementation/focused proof и штатная регистрация — отдельные факты; конечный результат доставки определяется только source-delivery Status/queue ledger, не повторным tracked checkbox.

## Причина

Два прежних Targeted на исходном reproduction дали return `10.8678824` и `10.4910746 s`; peer-close до deadline уже проходил. Их failed candidates `9a8196cb7f2f485691b745a2d2059259` / `4d22e3162ecd4ef5ba976a6169614f71` сохранены.

Разовый временный observer на том же существующем testcase показал: snapshot дерева Git содержит пять PID; после остановки транспортного leaf остальные процессы завершаются сами. Прежний `Stop-ItlUiToolProcessTree` всё равно выполнял по отдельному CIM round trip для каждого уже исчезнувшего PID. Было шесть CIM calls суммарно `2162.1116 ms`, из них четыре завершающих запроса к исчезнувшим PID — `1398.2391 ms`; одна фактическая остановка — `18.6834 ms`. Не установлено, что корнем была параллельная регистрация: повторяемый лишний cleanup work подтверждён напрямую, без такого предположения.

## Исправление и границы

- Existing `Stop-ItlUiToolProcessTree` сначала открывает ещё живой процесс; только достоверное отсутствие PID пропускается без CIM. Неожиданная ошибка lookup возвращает unconfirmed cleanup, не success.
- Для живого PID сохранена точная проверка `CreationDate` по существующему CIM inventory. Handle закрепляется до проверки; остановка идёт через прежний `Stop-NativeProcessForSafety -UseOpenedProcess`, поэтому повторное использование PID не перенаправляет kill на чужой процесс. Открытый объект всегда Dispose.
- Root identity check, descendant selection, порядок cleanup, трёхсекундный reserve, absolute deadline, watchdog и assertions не ослаблены. `Invoke-ItlNativeProcessCapture`, catalog retry/state и обычный успешный Git путь не менялись.
- Runtime owner прежний. Затронуты его вызовы из catalog Git, UI commands и existing fresh-process relay; нового process manager/job/service/state/lock, elevation или installed migration нет. Это owner-local repair, не расширение cleanup authority.

## Доказательства

1. Инструментированный повтор того же testcase после основного исправления: два CIM calls вместо шести, суммарно `784.5139 ms`; одна фактическая остановка. Это диагностическое наблюдение, не performance SLA или обещание ускорения на другом ПК. Оба instrumented runs прошли; прежние failed Targeted не переименованы в PASS.
2. Observer hook полностью удалён. Оригинальный GitSave test file имеет тот же Git blob, что до работы; topology, Unicode/whitespace paths, stalled HTTP server и `<10 s` assertions прежние.
3. Полный directly owned batch ProductProjectGitSave + UiTools после основной правки: **27 passed / 0 failed / 0 skipped**. Затем при review явно сохранён отказ на неожиданную ошибку Get-Process lookup; final focused selection — исходный Git HTTP timeout, реальный UI child timeout/retry и три identity/liveness/lookup controls — **5 passed / 0 failed / 0 skipped**, 23 unrelated cases не запускались повторно. Whole testcase durations 9.47/11.54 s включают создание fixture и teardown; это не `$elapsed` timed Git call. Его `<10 s` и peer-close подтверждены неизменёнными assertions.
4. Для окончательного source набора полный отбор, исполнение/reuse и результат Targeted выполняет только RegisterChange. Final focused proof не объявляется регистрацией или полной G3/G5 приёмкой.

Raw artifacts: `build/registry-population-20261025/deadline-before.trace.jsonl`, `deadline-after.trace.jsonl`, соответствующие logs/XML, `deadline-owned.log/xml`, `deadline-final-focused.log/xml`. [Компактный evidence manifest](r6-git-deadline-repair-2026-10-25.json) содержит hashes исходного reproducer и runtime/test/log inputs. Temporary profiling code в build игнорируется, hook не поставляется.

## Согласованность OpenSpec и данных

Обе OpenSpec используют этот единый registry-owned результат. Предыдущие записи о registration blocker сохранены как история до исправления; актуальная code/focused причина закрыта, delivery state проверяется отдельно через штатный Status. G3 остаётся принят в согласованной границе. R6 data candidate **fae719cac93c820add276ff7201d84473b621543** и publisher registry bytes не менялись в этом исправлении; data release completeness/PM4/optional exceptions/точный опубликованный SHA всё ещё отдельны.

Memory не получает нового cleanup/updater/query budget. Шесть областей, optional OpenViking, canonical home, ai_rules_1c ownership и отдельное разрешение G4 прежние. Gate 6, G4, рабочая миграция, публикация, push и PR не запускались.
