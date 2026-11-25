# G3: PM5 partial apply → cancel → resume/restore, 2026-10-23

**Оба пути восстановления после отмены частично применённого плана прошли; full G3 / AC-39 открыт.** [JSON: результаты, SHA raw evidence и ограничения](g3-pm5-partial-cancel-2026-10-23.json). Это квалификация существующего пакета без изменения runtime, tests, ai_rules_1c или серверов. [Предыдущее исправление completed resume](g3-completed-resume-repair-2026-10-23.md) остаётся принятым в своей области.

## Стенд и воспроизводитель

Тот же PM5 КОРП / `pm5-core-development`, main **`C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`**, sibling `branch`, Kilo + Cursor, Unicode/whitespace path. Source base **`e87afb76cca75e77f95ab8e01335ccb452316be8`**; установленный implementation **`909d1e229351d0b0cdca2db6c3fa81ff92b31503`**, runtime SHA **`c204c13a55f2bd504c6ae3c2e70087e46305179fab1c6f015bf3b84daea93da4`** равен source/main/sibling. ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f` прежний. Новый update пакета не выполнялся.

Для безопасного изменения desired Graph URL создан отдельный локальный bare Git catalog с независимыми author/cache/home, на основе истории прежнего тестового каталога; normal origin/cache остались на **`c29e72af12049b8227ac836e26f283220c2ab5b3`**. Тестовый URL `http://127.0.0.1:9/g3-partial-cancel-native` не использовался для tool calls. Private commits/push идут только в локальный fixture remote, без публикации общего каталога/workflow.

Реальный public installed `sync -CatalogDecision registry` применяет изменение в Kilo. Read-sharing handle на Cursor позволяет preflight/read, затем штатный atomic Replace получает sharing violation. После освобождения handle подтверждены реальные разные Graph URL: A=new / B=old, одна Kilo receipt, `status=partial`, durable `activeWrite.client=cursor` и прежний applied marker. Это тот же A-write/B-fault механизм, использованный в прежнем multi-client proof; path/topology/client order и assert контракты не менялись.

## Public recovery: 17 native calls

| Проверка | Наблюдаемый результат |
|---|---|
| Два настоящих partial apply | Оба exit1 на Cursor Replace; A действительно записан, B и applied marker прежние |
| Original command до recovery | Два exit1 / `CATALOG_OPERATION_PENDING`; main не запущен |
| Status и cancel на partial | Status exit0/read-only по SHA + mtime девяти paths. Cancel exit0; меняется только request с текущим operation ID, восемь остальных paths неизменны |
| Cancel → pinned resume | Exit0, **3.705 s**; прежний operation ID, revision **`427700d5ab32f47091ed51251a4306ec61268ef0`**, несмотря на новый tip **`41872fe8585048853edca9e0f21040aa027b74b4`**. B дописан, обе настройки new, marker завершён, cancel request удалён |
| Затем owned restore | Exit0, **3.501 s**; обе настройки old, marker канонически равен durable beforeApplied. Ручное копирование marker/operation не использовалось |
| Отдельный cancel → direct restore | Без промежуточного resume: exit0, **3.707 s**, тот же второй operation ID / revision **`f3371dbdff0fb4ab49f81683cd0b945901623bd1`**; восстановлены old URL и beforeApplied, status=restored, cancel request удалён |
| Original после каждого restore | Оба exit0, **8.305 / 8.304 s**, при том же desired catalog/home; main достигнут. Startup штатно снова применяет текущий desired URL |
| Завершение | Тестовый desired URL/display name возвращены через private Git и public sync; final original exit0, **6.349 s**. Обе ветки clean, исходные endpoints и foreign entries сохранены |

Первый operation **`a8642fce5abb4abf9f231712cb00a8c8`**, второй **`21517d745bd145468593a2df1a731840`**. Resume закреплён за сохранённым планом и не читает новый tip вместо него. Restore — восстановление owned before-состояния этой операции; он не создаёт persisted defer/override и не отменяет remote desired settings. Поэтому следующий обычный startup вправе снова применить актуальный каталог. Это поведение проверено до возвращения fixture к baseline, без смены home/remote ради успешного original command.

## Граница cancellation proof

**Отмена ещё работающего writer между A и B не доказана; это открытый evidence gap, а не установленная ошибка runtime.** В принятых двух случаях запрос cancel отправлен после остановки writer на sharing violation, пока durable plan остаётся partial. Проверены точное назначение запроса, отсутствие writer authority у cancel и обе штатные recovery continuation; не утверждается, что активный writer прочитал request и прекратил B.

Отдельная попытка timing-only PowerShell line breakpoint без изменения установленного файла не достигла паузы. Первый timing запуск фактически успел применить настройки, а не был отменён. Второй не дал принятого native capture: qualification worker не импортировал `Get-StateValue` для timeout cleanup; первичный worker ранее не импортировал shared capture вообще. Причина непопадания line breakpoint не установлена. Failed harness scripts/diagnostics сохранены, не включены в 17 принятых calls и не выданы за native cancel pass. Ранняя raw подпись `publicWritesObserved=0` оказалась неверной; отдельный `timing-attempt-audit.json` явно корректирует её по archived operation/physical settings, не переписывая исходный diagnostic.

Все timing worker процессы завершились; отсутствие оставшихся `paused-apply` процессов проверено. После попыток public sync восстановил desired baseline, затем отдельно выполнены два принятых original partial reproducer. Для закрытия оставшегося gap нужен запрос public cancel при ещё работающем writer после реальной receipt A, доказанный останов B/marker и успешные original resume/restore при тех же preconditions. Нельзя заменять его отменой уже faulted плана, mock callback или принудительным завершением PID. Existing owner fixtures cancellation и настоящая CLI отмена до writes сохраняют свою прежнюю область. Полные task 4.2/5.2/5.6 и AC-16/24/26/39 остаются открытыми.

## Сохранность, стоимость и остаток

Client JSON в конце семантически равны исходным; **все байты вне четырёх Kilo / двух Cursor owned values сохранены**, включая common/foreign MCP и порядок ключей. Whole-file byte equality **false** для обоих клиентов из-за owned serialization; byte pass не заявляется. Main/sibling HEAD, descriptor, dependency lock, binding и installed pins неизменны; memory opt-in не включён. DB **3,295,928,320 bytes**, SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, совпадает с прежним квалифицированным baseline.

В этом прогоне strict before/after **21 protected files и все четыре старых roots прошли**, включая seed на его уже обновлённом HEAD. Все 11 immutable capsule hashes, семь Gate6 artifacts и **127 raw files предыдущего repair report** совпали. Исторический strict failure движения другого seed из предыдущего прогона сохранён и не превращён в pass; новый before/after имеет собственную границу. Original raw seed по-прежнему отсутствует, live source currentness этим не доказана.

Runtime/instructions/tool schemas не менялись: добавочная always-on стоимость **0 bytes**. Приведены отдельные whole-CLI timings; это не paired Startup/context/token benchmark и не измерение billing. Native клиентские LLM turns, прямые Code/Graph tools и Cognee calls **0**; дополнительный qualification harness traffic/время не приписаны рабочему startup.

Открыты active-writer cancellation proof, остальные installed/client/PM4/Windows 10/Server/terminal/race/paired-cost критерии, полный G3/AC-39 и обязательное release population AC-36–38. Memory consumer4.2/G4/AC-43/G5/44 не начат/не принят; шесть областей, canonical home, grants, Q1–Q7/D9/G2, optional OpenViking и ai_rules_1c прежние. **Gate6, G4, рабочая миграция, server/client upgrades и публикация не выполнялись.** Документальная регистрация source change имеет отдельный ledger и не заменяет G3 acceptance.
