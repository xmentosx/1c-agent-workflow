# G3: интерактивная отмена и штатное восстановление PM5, 2026-10-23

Последующий [owner repair и original PM5 repeat](g3-completed-resume-repair-2026-10-23.md) закрыл named blocker в указанной области. Ниже сохранён исходный failed срез на runtime176bd2fa; его JSON/raw results не переписаны.

**Ctrl+C / пустой ответ и public owned restore прошли в указанной области; обнаружен открытый G3-CATALOG-COMPLETED-RESUME-INVALID-APPLIED. Полный G3 / AC-39 открыт.** [JSON с identities, native steps и SHA evidence](g3-pm5-interactive-recovery-2026-10-23.json). [Предыдущий срез](g3-pm5-cache-record-qualification-2026-10-22.md) проверял только invalid-applied admission и idle cancel; они не выдаются за нынешний native proof.

Source `3cfbf0fd30cc7b086dcdb07a6f06ac3b84903b2f`, installed runtime `176bd2fa6b8d107d33df2b92600e0c14d365ee45`, ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Три runtime SHA source=installed подтверждены. Main `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch` в прежнем parent: PM5 КОРП / `pm5-core-development`, Kilo+Cursor; Windows PowerShell5.1, без elevation. Код/пакет/правила не менялись.

## Интерактивная отмена: AC-16/24/26 subset

Создан отдельный private local bare origin/cache, содержащий прежнюю историю; только в нём Graph объявлен disabled. В исходном Cursor actor заменил лишь собственный Graph URL, сохранив остальной текст. Это реальный three-way conflict: registry retirement / applied endpoint / local edit. Нормальный cache/origin не переключался. Public ordinary `vibecoding1c-mcp-write-client-config` запущен в native Windows PTY с `inputRedirected=False`; вопрос `Catalog conflict: keep-local / registry / defer:` наблюдался непосредственно. Read-Host не подменялся, решения параметром/в stdin pipe не передавались.

- На видимом вопросе отправлен **Ctrl+C (U+0003)**: pipeline остановлен, native process exit1. Девять protected paths сохранили SHA/mtime/absence, предыдущая operation и applied прежние, новая операция/основная фаза не запускались.
- На том же исходном conflict повторён **пустой ответ (Enter)**: agent exit1 / CATALOG_CONFLICT_NEEDS_USER_ACTION, protected paths неизменны, принятого решения/новой операции/main нет. Outer diagnostic harness exit0 не выдан за agent success: отдельный returned receipt содержит exit1.
- Actor отменил только свою URL замену, с точным сравнением исходного текста; возвращён исходный mtime. Следующая обычная команда на штатном cache прошла exit0, protected inputs прежние. Product receipts вручную не восстанавливались.

Native prompt виден в PTY tool output и сохранён отдельным observer record; PowerShell transcript опускает текст Read-Host. Transcript подтверждает реальный conflict preview, unredirected input и interruption/error. Полной raw PTY записи не заявляется. Первый transcript-only validator отказал и сохранён; native сценарий ради зелёного результата не менялся. Это отмена **до записи**, не cooperative cancellation посередине partial apply; последняя остаётся отдельным installed критерием.

## Повреждённая applied-квитанция и реальный recovery

Сначала public select того же проекта создал законную completed operation `37f07c509bc849bd837cefbf5ed35065` на pinned revision `c29e72af12049b8227ac836e26f283220c2ab5b3` с durable beforeApplied `b08bbfa5ba4542ceb8bd8f929f1c45fc`. Это обычная операция helper, не вручную подготовленный receipt. Архивированы before/prepared/damaged/restored/final inputs. Затем только в applied JSON заменён contextHash на нули; JSON остаётся синтаксически валидным. Backup не подставлялся обратно.

| Public шаг | Наблюдение |
|---|---|
| Исходная обычная команда | exit1, CATALOG_LOCAL_RECORD_INVALID: applied; main не запущен |
| Catalog status | exit0 / invalid-applied; файлы не меняются |
| Resume завершённой операции | **exit0 / configured, damaged marker без изменения** |
| Повтор исходной команды после resume | **снова exit1 / CATALOG_LOCAL_RECORD_INVALID**, main не запущен |
| Public restore той же pinned operation | exit0 / restored; валидная applied-квитанция восстановлена из durable beforeApplied; operation ID/revision прежние |
| Public context → исходная команда | context валиден, PM5 КОРП / тот же project ID; исходная команда exit0/main reached |

Восстановление сделал существующий owner `Invoke-ItlProductProjectClientApply -Mode restore`; ручных receipt copies **0**. Квитанция непосредственно после restore канонически равна сохранённому beforeApplied, её contextHash валиден. Sibling/HEAD/descriptor/lock и личные настройки сохранены.

Первый final validator требовал неизменный SHA целого client JSON и отказал: restore изменил порядок полей внутри управляемых Code/Graph values (Kilo4 с aliases, Cursor2). Failure сохранён, whole-file byte pass **не** заявляется. Полный JSON семантически равен прежнему; отдельный parser исключает из сравнения только эти owned value spans и подтверждает **побайтное равенство всего остального текста**, включая 4 прочих Kilo и 5 Cursor entries, separators и порядок keys. Shared ownership contract AC-16 требует restore owned sections / сохранность чужих bytes, а не неизменную раскладку полей owned values. Никакие product assertions/исходные сценарии не переписаны; дополнительная проверка сохраняет именно foreign-byte границу. Runtime не исправлялся.

Область recovery proof — повреждение после completed операции с валидным durable beforeApplied. Состояния restored/cancelled, повреждённый operation или его отсутствие этим прогоном не приняты.

## Открытый блокер: G3-CATALOG-COMPLETED-RESUME-INVALID-APPLIED

**Подтверждённый runtime defect, не fixture failure.** Existing resume для status=completed возвращает configured из durable operation до чтения/валидации текущего applied record. Это подтверждено последовательностью resume exit0 → unchanged damaged marker → original command exit1. Status и безопасность main сохраняются; дефект относится к правдивости recovery outcome. Public restore доступен и проверен как штатное продолжение.

Existing apply/recovery owner должен не объявлять configured при invalid/missing/mismatched applied: вернуть честный recovery-needed/error с существующим restore continuation либо подтвердить действительно восстановленный валидный контекст. Приёмка будущего исправления — тот же completed operation → corrupt applied → resume → статус, соответствующий фактическому marker, затем исходная команда; прежние valid completed idempotent resume, pinned partial resume, foreign guards и owned restore сохранить. Нельзя лечить результат guessed context/ручным backup/новым recovery owner или ослаблением guard. **Исправление в этом срезе не выполнялось. AC-16/26/39 целиком открыты.**

## Измерения, сохранность и остаток

11 public product calls: 2 интерактивных, 1 healthy repeat после отмены и 8 recovery шагов. Standalone harmless console probe указан отдельно. Recovery whole captures 2.755–7.778 s; Ctrl+C/пустой ответ включают operator wait и не являются Startup benchmark. Новых always-on/schema bytes, LLM turns, native Code/Graph tools и Cognee calls **0**; memory opt-in false. Токены/paired cost этим срезом не измерены.

DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3,295,928,320 bytes, прежний. Main/branch clean; descriptor/lock/HEAD прежние, foreign client bytes сохранены. 21 protected files/четыре старых roots, failed copy, семь Gate6 artifacts и 11 capsule hashes проверены. Исчезнувший raw seed не объявляется актуальным; прежняя approved sealed-capsule admission сохраняется.

Помимо нового resume blocker открыты cooperative cancellation/прочие original installed journeys, остальные client/CUSTOM/source/routes, PM4/Win10/Server/terminal stands, paired Startup/context/token cost/strict stalled-transport cleanup, full G3/AC-39. Mandatory release population AC-36–38 отдельно обязательно. Memory4.2/G4/AC-43/G5/44 не принято; шесть областей/canonical home/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. **Gate6, G4, рабочая миграция, remote changes/client upgrades и публикация не выполнялись.**

Fixture-only failures сохранены отдельно: slash spelling при первом containment check (до mutation), transcript prompt omission, PS5.1 JSON-array aggregation после собственной URL reversal и слишком сильный whole-file SHA assertion. Их коррекция/дополнительное evidence не изменяли runtime, исходный native workload или guards. Source-delivery регистрация оценивается отдельно по ledger, не заменяет full G3 acceptance.
