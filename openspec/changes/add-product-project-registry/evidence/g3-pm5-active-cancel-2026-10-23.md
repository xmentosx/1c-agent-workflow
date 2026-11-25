# G3: отмена активного PM5 writer между записями, 2026-10-23

**Active-writer cancellation evidence gap закрыт для текущего PM5 native-helper subset.** [JSON с результатами, identities и SHA raw evidence](g3-pm5-active-cancel-2026-10-23.json). Оба original recovery пути passed; full G3 / AC-39 открыт. [Прежний faulted-partial cancel report](g3-pm5-partial-cancel-2026-10-23.md) сохраняет свою историческую границу, его failed timing attempts не превращены в pass. Runtime, package/tests, пороги, ai_rules_1c и серверы не менялись.

## Стенд и граница между A/B

Тот же PM5 КОРП / `pm5-core-development`, main **`C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`**, sibling `branch`, Kilo + Cursor, прежние path/topology/порядок клиентов. Source base **`a6439c46577360b9b3721ba52f0dc215a0687b3f`**; installed implementation **`909d1e229351d0b0cdca2db6c3fa81ff92b31503`**, runtime SHA **`c204c13a55f2bd504c6ae3c2e70087e46305179fab1c6f015bf3b84daea93da4`** одинаков у source/main/sibling. ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f` прежний. Update пакета и запуск 1С не выполнялись.

В независимом локальном private Git catalog/home задан harmless Graph URL `http://127.0.0.1:9/g3-active-cancel`. Он вызывает реальное изменение client settings, без обращения к endpoint. Shared native capture запускает установленный public `vibecoding1c-mcp-select -CatalogAction sync -CatalogDecision registry`. Timing-only PowerShell **command breakpoint** останавливает вход в существующий `Assert-ItlProductProjectNotCancelled`: call stack подтверждает runtime line223 → client writer line1499. Файлы установленного runtime не патчились; writer, проверки, receipts и исключение не mock/stub.

В момент паузы доказаны физические A=new / B=old, ровно одна Kilo receipt, `status=partial`, `activeWrite=null`, прежний applied marker и живой PID writer. До второй записи нет ни IO-fault, ни подмены marker/operation. Независимый public cancel завершился при всё ещё живом writer; SHA+mtime восьми остальных paths неизменны, создан только request с его operation ID. После release выполняется настоящая проверка cancel; public apply **exit1 / CATALOG_CANCEL_REQUESTED**, receipt остаётся одна, B и marker не записаны. В обоих принятых trace нет timeout/breakpoint-action-error.

Pause управляет только временем межпроцессного сценария и ограничена 55 s; это instrumented native-helper proof, не измерение естественного пользовательского timing и не новая IDE/frontend qualification. Единственный fixture-use lease удерживает процесс capture; контроллер выполняет public cancel в этой же уже защищённой копии и не пытается заново захватить exclusive fixture lease. Production lifecycle/guard/cancel authority остаются прежними; принудительное завершение writer/PID не использовалось.

## Два принятых сценария: 15 public native calls

| Шаг | Cancel → resume → restore | Cancel → direct restore |
|---|---|---|
| Живой writer при cancel | Да; cancel exit0, **2.481 s** | Да; cancel exit0, **2.388 s** |
| Остановка на настоящей cancellation check | Apply exit1; A записан, B/marker прежние, одна receipt | Те же условия; apply exit1 |
| Original до recovery | Exit1 / CATALOG_OPERATION_PENDING, main не запущен | Exit1 / CATALOG_OPERATION_PENDING, main не запущен |
| Status после остановки | Canonical `vibecoding1c-mcp-status -CatalogAction status`, exit0/read-only по SHA+mtime девяти paths | То же |
| Recovery | Resume exit0, **3.690 s**; тот же operation ID и pinned SHA при более новом catalog tip; B дописан, marker completed, cancel request удалён | Restore exit0, **3.636 s**, без промежуточного resume; тот же operation ID, cancel request удалён |
| Owned restore | Exit0, **3.648 s**; original beforeApplied и оба old URL | Original beforeApplied и оба old URL восстановлены непосредственно |
| Original после restore | Exit0/main reached, **9.109 s** | Exit0/main reached, **8.559 s** |

Resume operation **`731230a884f8408d8a6af290c17fa84f`**, pinned **`246192b3f2607f6377e738879728ffb5358c1b4d`**, later tip **`857c5a086c40248092983f63253324fbd618bbe3`**. Direct-restore operation **`cfa5f8f4300d493db0dc925240f026e5`**, pinned **`6b9d4a8d5237b96cce428f7ab3b0dafbacd0adf5`**. Resume не подменён startup/latest; beforeApplied сравнен канонически, ручных copies/правок квитанций **0**.

Обе original commands проверены на том же desired catalog/home **до** fixture cleanup. Как и раньше, restore возвращает owned before-состояние, не сохраняет defer/override: обычный startup снова применяет актуальный desired catalog. После проверки desired endpoint/display name возвращены через private Git и public sync; normal catalog и предыдущий private fixture origin не изменены. Private fixture commits/push не являются публикацией общего каталога/workflow.

## Сохранённые непринятые harness попытки

- `active-resume`: Start-Job capture не достиг паузы, завершён shared deadline 100 s; точная причина недостижения рабочего вызова не доказана. Прямой shared capture без Start-Job затем воспроизвёл настоящий command breakpoint. Это изменение qualification orchestration, не runtime fix.
- `direct-resume`: пауза достигнута, но контроллер потребовал второй exclusive fixture lease и получил FIXTURE_COPY_IN_USE. До корректного cancel пауза истекла; writer продолжился, pass не заявлен. Контроллер затем использует lease уже работающего capture owner, не обходит guard установленного проекта.
- `direct2-resume`: диагностический status был вызван через mutation action `vibecoding1c-mcp-select`, который сериализуется с writer; он ожидал **50.979 s**, пауза истекла и protected-input assertion отказал. Существующая классификация core выделяет read-only `vibecoding1c-mcp-status`; финальная проверка status выполнена этим entrypoint после cooperative stop. Неблокирующий status активного writer данным финальным subset не объявлен проверенным. Отказ не скрыт и не выдан за дефект cancel.
- `direct3-resume`: настоящий cancel остановил writer до B, но wrapper не передал `LASTEXITCODE` вложенного скрипта и process exit оказался 0. Physical partial и CATALOG_CANCEL_REQUESTED сохранены, assertion остался красным. Diagnostic partial восстановлен public restore; wrapper теперь явно возвращает exit code. Два принятых сценария выше полностью повторены с apply exit1, без переоценки старого exit0 как pass.

Все failed журналы/снимки сохранены в raw evidence; начальный wrapper без передачи exit code восстанавливается из точного diff и помечен как reconstruction, не pre-run hashed artifact. Предыдущие line-breakpoint/no-output/metadata ошибки также сохранены в прежних reports. Новая command-breakpoint qualification закрывает прежний evidence gap, не устанавливая задним числом причину каждого старого harness failure. Изменения ограничены ignored test harness и OpenSpec, новых product barriers/recovery paths нет.

## Сохранность и остаток

Source/main/sibling runtime identity, main/sibling HEAD/descriptor/lock/binding/pins неизменны; обе PM5 ветки clean. База **3,295,928,320 bytes**, SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, совпадает с retained qualified baseline. В этом прогоне оба client JSON **целиком побайтно равны before**; отдельно подтверждены полная семантика, порядок ключей и все foreign bytes. Исторические whole-file mismatch observations прежних runs не переписаны.

Strict before/after прошёл для **21 protected files и четырёх старых roots**; семь Gate6 artifacts, 11 capsule hashes и **358 raw files двух предыдущих reports** совпали. Normal registry origin/cache остались на `c29e72af…`, прежний fixture origin — `0d493bf0…`. Все timing worker процессы завершены. Исторический отдельный seed movement failure остаётся в прежнем report; original raw seed всё ещё отсутствует, его live currentness не заявляется.

Source runtime/instructions/tool schemas не менялись: добавочная always-on стоимость **0 bytes**, клиентские LLM turns / direct Code–Graph tools / Cognee calls **0**. Apply timings включают искусственную паузу; остальные CLI samples также не являются paired Startup/context/token/billing benchmark. Failed qualification overhead отделён от рабочего startup.

Закрыт только названный PM5 active-writer cancel/recovery gap в AC-16/26 subset. **Full task4.2/5.2/5.6/AC-16/24/26/39 открыты**: остаются межсессионная race, terminal multi-user, другие installed/client/PM4/Windows 10/Server/paired-cost критерии, обязательное наполнение AC-36–38. Memory consumer4.2/G4/AC-43/G5/44 не начат/не принят; шесть областей/home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. **Gate6, G4, рабочая миграция, server/client upgrades и публикация не выполнялись.** Document-only RegisterChange/Targeted имеет отдельный ledger и не заменяет full G3 acceptance.
