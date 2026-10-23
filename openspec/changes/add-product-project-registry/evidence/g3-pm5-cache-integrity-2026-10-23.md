# G3: PM5 cache/schema/local-record qualification, 2026-10-23

**Passed только bounded subset AC-17/21/24/26; full G3/AC-39 остаётся открыт.** На прежнем PM5 main+sibling штатный installed update установил source `fac4bc51`, exit0 за376761 ms без retry/recovery. По одной completed snapshot на root, records680/359. Watchdog120 s/action-default3600 s и assertions runner прежние. Код пакета и его тесты в этой задаче не менялись. [Canonical JSON](g3-pm5-cache-integrity-2026-10-23.json) содержит raw refs/SHA и отдельный frozen manifest.

## Что выполнено

| Native installed сценарий | Результат | Защищённая граница |
|---|---|---|
| Healthy ordinary writer | exit0, реальная main-фаза | Состояния 9 защищённых путей на root прежние, включая SHA/mtime существующих файлов |
| Dangling cached HEAD, bound | exit0; точный offline WARN, validated applied revision f00ff92 сохранён, main выполнен | Ни замены cache, ни client writes; неподтверждённая freshness не объявлена ready |
| Тот же cache, unbound select/status | select exit1 CATALOG_REFRESH_UNAVAILABLE; status exit0 | Нет guessed association; transport clone/fetch0 за обе команды и diagnostic |
| Registry schema3 вместо поддерживаемой2, bound | exit0; validation-fallback WARN, старый applied, main | Отдельный existing validator подтвердил точное поле/schema3; новая revision не применена |
| Тот же schema3 catalog, unbound | exit1 CATALOG_REFRESH_UNAVAILABLE | Нет ассоциации/записи. Native wrapper обобщает причину; field error отдельно в validator evidence |
| Unknown project preview | exit1 CATALOG_PROJECT_UNKNOWN с точным запрошенным ID | Ни project ID, ни client config не меняются |
| Valid JSON applied с нулевым contextHash | ordinary exit1 CATALOG_LOCAL_RECORD_INVALID: applied до main; status exit0 invalid-applied | Faulted bytes/mtime не меняются от команд, sibling прежний |
| Возврат только внесённого fault → ordinary; idle cancel | exit0/main; cancel idle/false | Исходные bytes+mtime восстановлены самим test actor. Это не proof продуктового recovery повреждённой записи |

11 native calls в нормализованном наборе; ещё2 calls первого harness attempt сохранены отдельно, всего13 qualification calls и отдельный package update. Реальных 1C/Code/Graph/LLM/Cognee/OpenViking tool calls нет. Это installed CLI/config/admission proof, не frontend/native MCP activation или business readiness.

## Сценарий и сохранность

Тот же root `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch`. Main bound pm5-core-development/pm5-corp Kilo+Cursor, sibling unbound Kilo. Normal fixture catalog f00ff92 и два новых повреждённых cache/schema fixtures независимы; старый shared catalog/cache c29e72 и предыдущий private origin не менялись. Schema3 commit существует только в новом локальном fixture-репозитории, внешней публикации нет.

Оба roots clean/exact fac4bc51, descriptor/binding/r43 прежние. Все 18 состояний защищённых путей (по 9 на root, включая отсутствие файла) сохранились; SHA/actual mtime существующих файлов прежние; src/cf и src/cfe не менялись при update. PM5 DB3295928320 bytes/SHA c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045 прежняя. Сверены12864 старых snapshot files,2349 прежних raw files,161 refs предыдущего copy-status proof и4 его terminal receipts;21 protected seed files/4 old roots/11 capsule hashes/7 Gate6 artifacts сохранены. Missing live raw seed остаётся unavailable; нового admission не делали.

## Сохранённые harness failures и уточнение ожиданий

Первый UTF8 script без BOM не распарсился в PS5.1 до выполнения действий; исходник сохранён, добавлен BOM. Затем first attempt получил правильный offline WARN/main/exit0, но harness ждал текст другой validation-error ветки. Owner context:411 и414 различают их; corrected check требует точный offline diagnostic, а не отсутствие warning. Повтор использовал тот же cache/root/HEAD fault; оригинальные SHA+mtime/root preconditions проверены до повтора. Никакие runtime thresholds/guards/source tests не менялись.

Unknown preview правильно вернул публичный CATALOG_PROJECT_UNKNOWN, а harness ждал внутренний CATALOG_INVALID. Existing public UI owner:73 подтверждает ранний typed refusal. Исходные artifact/error сохранены; исходные protected preconditions перепроверены, continuation выполнял только ещё не выполненные applied/healthy/cancel cases. Оба сообщения не стали runtime-блокерами; native результаты и source-контракт подтверждают семантику требований.

Raw continuation сводка PS5.1 сохранила предыдущие массивы как один wrapped value, напечатав4/5 вместо8/11. Исправлена только агрегация отчёта: recursive flatten с проверкой каждого шага по его индивидуальному result, исходные nested JSON сохранены. Сценарии не перезапускались ради счётчика. Единый uninterrupted harness pass не заявляется; каждый принятый native case связан со своими результатом и guard checks.

## Стоимость и остаток

Individual CLI1.188–4.101 s, local file origins; это не проверка stalled Git deadline≤10 s/child cleanup, paired Startup, точных tokens или полного feature delta. Runtime/context/tool schemas/production input closure не менялись; added always-on/schema bytes0, новые provider/LLM/memory calls0. Passed Startup full-window0.932/1.238 s из предыдущего repair сохраняет свою область; previous whole CLI+1.756 s и full feature cost не атрибутированы этим batch.

Открыты full G3/AC-39; other original init/branch/refresh/downgrade/client/frontend/interactive cases; PM4/Win10/Server2019+/independent terminal sessions отсутствуют. Gate6 исключает соответствующие реальные 1C journeys; capsule не доказывает current live seed. Owned recovery именно этого fault-applied variant здесь не квалифицирован. Stalled transport deadline/cleanup, full feature baseline, other live source/client admission остаются открытыми; точные index stamps/Code/Graph server patches не возвращаются в prerequisites.

До первого выпуска остаётся обязательное population5.7/AC36–38 с отдельным поручением на реальные данные/публикацию; memory AC44 использует тот же результат. Memory consumer4.2/G4/AC43/G5/44 не реализованы/не приняты. Шесть областей, canonical home/grants/Q1–Q7/D9/G2, optional OpenViking/ai_rules_1c неизменны. Gate6, G4, рабочая миграция, server replacement/reindex и публикация не выполнялись. Documentation-only commit/RegisterChange — отдельная source delivery qualification, не installed или release proof.
