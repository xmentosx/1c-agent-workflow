# G3: исправление completed resume и исходный PM5-повтор, 2026-10-23

**G3-CATALOG-COMPLETED-RESUME-INVALID-APPLIED закрыт в исходном PM5 subset; full G3 / AC-39 открыт.** [JSON с inputs, native результатами, ограничениями и SHA evidence](g3-completed-resume-repair-2026-10-23.json). [Исходные failed resume и штатный restore](g3-pm5-interactive-recovery-2026-10-23.md) сохранены; все 128 прежних raw files сверены без изменений.

## Причина и owner-local исправление

В `Invoke-ItlProductProjectClientApply -Mode resume` shortcut status=completed возвращал configured по старому плану до чтения текущего applied. Теперь существующий `Read-ItlProductProjectRecord` проверяет schema/root/contextHash/revision; completed resume дополнительно сопоставляет operationId, catalogRevision и contextHash с ожидаемым результатом этой операции. Для completed compatibility restore ожидается исходный marker из compatibilityBaseline.applied: прежний валидный marker либо допустимое отсутствие. Это локальный Git catalog/context hash, не требование revision stamp от Code/Graph.

При invalid/missing/mismatched record возникает **CATALOG_COMPLETED_RESUME_NEEDS_RESTORE**, без изменения client files/receipts, с точным status → public restore → original command continuation. Валидный completed resume остаётся read-only/no-op. Partial/pinned resume, существующий restore и restored/cancelled ветви не менялись. Новых coordinator/state/locks/migrations/probes, автоисправления marker, Code/Graph patches или ai_rules_1c changes нет. Проверка выполняется только на явно запрошенном completed resume и предотвращает false success; native continuation ниже доводит исходную задачу до успеха.

## Регрессии

| Proof | Результат |
|---|---|
| Причинный red на прежнем runtime | После исправления исходного synthetic original-marker fixture: 1 passed / 7 failed; все семь отказов показывают прежний ложный success вместо нового recovery-needed |
| Focused green | 8 passed / 0 failed / 0 skipped: valid completed no-write/no-registry-read; invalid hash, missing marker, wrong operation, revision и context; compatibility original marker / legitimate absence |
| Полный owner batch | **122 passed / 0 failed / 0 skipped**, 169.47 s; ProductProjectApply, ProductProjectContext, ProductProjectSetup. Existing partial/cancel/pinned/foreign/compatibility/restore cases сохранены |

Первый red содержал отдельную fixture ошибку: compatibility=true наследовал более ранний empty baseline, а не ожидаемый original marker. Fixture моделирует валидный prior marker без прежнего compatibilityBaseline; assertions и исходный native reproducer не ослаблены. Первая попытка owner batch остановилась до tests на Pester.StringArrayOption +=; final runner передаёт обычный массив. Все журналы сохранены.

## Повтор на том же PM5-стенде

Root **`C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`**, sibling `branch` в прежнем parent, PM5 КОРП / `pm5-core-development`, Kilo+Cursor. Путь/topology/семейство/проект и сам fault (valid JSON с contextHash=0) прежние. Обычный source-fixture updater установил clean implementation **`909d1e229351d0b0cdca2db6c3fa81ff92b31503`** на обе копии одним public update: exit0, **422.363 s**. Runtime SHA **`c204c13a55f2bd504c6ae3c2e70087e46305179fab1c6f015bf3b84daea93da4`** source=main=sibling. Итоговый source-коммит объединяет тот же runtime/test bytes и документацию; exact SHA доказательства не заменяются версией опубликованного пакета. ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f` прежний. Package/lock/managed commits обновлены штатно; внутри самого fault/recovery replay HEAD/descriptor/lock неизменны.

Далее ровно 9 public calls через installed helper, shared UTF-8 capture и fixture lease:

| Шаг | Результат |
|---|---|
| Public select того же проекта | Создана законная completed operation `dc919c895fcb4fb4b9d738ff31665050` с durable beforeApplied; pinned revision `c29e72af12049b8227ac836e26f283220c2ab5b3` |
| Valid completed resume | configured/exit0, **3.756 s**, SHA+actual mtime/absence девяти paths неизменны |
| Hash corruption → исходная команда / status | Main exit1/CATALOG_LOCAL_RECORD_INVALID; status доступен/invalid-applied; main не запущен |
| Completed resume на повреждённой квитанции | **exit1 / CATALOG_COMPLETED_RESUME_NEEDS_RESTORE**, **3.622 s**; configured не объявлен; девять paths без записи; explicit restore continuation |
| Повтор original до recovery | По-прежнему exit1; отказ resume не выдан за автоматическое восстановление |
| Штатный public restore | exit0/restored, тот же operation ID/SHA; marker канонически равен durable beforeApplied и имеет валидный contextHash; ручных backup copies **0** |
| Public context → исходная команда | Тот же project/product; **original command exit0/main reached**, 5.801 s |

Непосредственно этот repeat закрывает named blocker и доказывает agent-usable continuation. Более широкие restored/cancelled/missing-operation случаи и full AC-16/26/39 не закрываются этим subset.

## Сохранность и ограничение параллельного стенда

В текущем replay оба client JSON не только семантически, но и **целиком побайтно равны before**; все foreign bytes сохранены. Исторический owned-property-order mismatch из прежнего прогона не переписан. В copied analysis сначала осталась его старая текстовая подпись, хотя actual booleans уже были true; первоначальные metadata сохранены, read-only summary исправлен без новых native calls. Main/sibling clean; database SHA **`c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`**, 3,295,928,320 bytes, прежний. Memory opt-in false.

Strict checker сохранности прежних четырёх roots **отказал**: `D:\Git\itl-workflow-e2e-pm5` перешёл с 4e540b3c на 6de621e4 и завершил отдельное обновление до workflow `350e92d…`. Commit time **00:54:24 MSK**, наша изолированная update invocation началась **00:57:52 MSK**, её candidate — `909d1e22`. Before capture в 00:54:12 уже содержал dirty managed files на том seed; movement зафиксирован позже. Это доказанное более раннее обновление другого пакета, не выполнение update на том root из этой задачи. Raw chronology/root diffs и strict failure сохранены; чужое изменение не отменялось и не очищалось. **Нельзя заявлять полную неизменность всех четырёх roots.**

При этом все **21 immutable protected files**, ещё **три старых roots**, failed-copy состояния, семь Gate6 artifacts и все **11 capsule hashes** подтверждены. Original raw seed по-прежнему отсутствует; его live currentness не объявляется доказанной. Movement старого seed ограничивает общую global-root immutability часть evidence и не отменяет отдельный accepted replay на текущем owned C:\itlj stand.

## Стоимость и остаток

Новых always-on instructions/tool schemas **0 bytes**; startup не изменён. Completed resume читает один local applied record и сравнивает существующие identity/hash поля, без нового Git refresh/MCP probe. Error output **401 UTF-8 bytes** появляется только при отказе. Приведённые single whole-CLI timings не являются paired Startup/token benchmark; token count/billing и existing update background traffic не измерялись. Qualification client LLM turns, direct Code/Graph tools и Cognee calls **0**.

Full G3/AC-39, прочие original installed/client/CUSTOM/platform/terminal/paired cost/strict stalled-transport cleanup и обязательное release population AC-36–38 открыты. Memory4.2/G4/AC-43/G5/44 не реализован/не принят; шесть областей/canonical home/grants/Q1–Q7/D9/G2/optional OpenViking/ai_rules_1c прежние. **Gate6, G4, рабочая миграция, server changes/client upgrades и публикация из этой задачи не выполнялись.** Source-delivery Targeted/registration имеют отдельный ledger и не являются полным G3 pass.
