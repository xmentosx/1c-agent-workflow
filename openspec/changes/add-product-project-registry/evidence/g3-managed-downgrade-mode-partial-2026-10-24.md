# G3: dependency mode repair и следующий downgrade blocker, 2026-10-24

Исправление dependency wire/process handoff реализовано и прошло **97 PASS / 0 FAIL / 0 SKIP / 0 NotRun** в DependencyLocks и WorkflowUpdateRollback (459564 мс). Однако исходный direct downgrade на сохранённой PM5-копии **не принят**: прежняя ошибка Invalid dependency mode: workflow больше не возникает, но старый child остановился дальше на `ai_rules_1c migration is blocked (not-newer)`. Полный named scenario, AC-18/39 и memory AC-43/G5 остаются открытыми.

## Исправление и доказанные границы

Implementation commit `6673930a8c152b6de7a5b9fc7190da89b6eb483e`, predecessor `760250f2cf6f7f27970008069c053733759a744f`. Один stateless dependency owner выбирает wire format целевого шаблона: schema1/fresh/latest/locked/pinned → schema1/locked; current schema2 → workflow. Existing sync и entry writer согласуют lock, project.dependencyMode и dotenv. Pins/provenance/foreign entries и pinned receipt intent не заменяются второй политикой выбора; current Get-DependencyMode остаётся workflow.

Existing snapshot coordinator синхронизирует legacy settings до child. Исправление только файлов оказалось недостаточным: direct repeat первой версии завершился exit1/67530мс, поскольку dotenv import не перезаписывает inherited process environment. Теперь child получает locked через environment и explicit argument, прежний аргумент заменяется ровно один раз, parent environment восстанавливается в finally. Пять новых regressions покрывают legacy/current formats, exact pins/rollback, inherited environment и child arguments; прежние assertions, signed operation, CAS, watchdog и SHA gates сохранены. Старый source/helper не патчились.

## Нативный исходный сценарий

Использованы прежние main и sibling без пересоздания и ручных mode/receipt правок:

```
C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\project
C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\branch
```

Первоначальный failed snapshot `3ad27342dd144f5487c218e946340715` штатно завершён source-assisted recovery. Уже установленный old replay exit0/7624мс не используется как доказательство fresh handoff. Первый recovery attempt со случайно выбранным новым ondemand executable штатно остановила SHA-проверка; затем harness выбрал exact old immutable 0.4.15 / `95968cccdcc38e3327ce7dc2ebe521fc34d55b44459d0a9d301cdec0be114aff`. Исходные errors сохранены, SHA contract не менялся. Source launcher после завершения pinned old возвращает ожидаемый WORKFLOW_UPDATE_NEW_CANDIDATE_PENDING при запросе нового source; этот exit1 не объявляется общим PASS.

После первого direct failure inherited environment transaction `e45cb33bcad64ad293d3e9477fdfaffb` также завершена штатным recovery. Итоговый direct-v2 цикл обновил main+sibling на исправленный source (exit0/290120мс); записанное предусловие в обоих roots: schema2, lock/project/dotenv=workflow, exact implementation commit. Public preview/select passed; активная ассоциация отвергла несовместимый пакет до copy с unchanged protected bytes/mtime/HEAD/dirty state, включая dotenv. Public restore-compatible passed.

Затем original installed update-workflow → неизменённый старый `fa0e3c91694112c1da3ecda7209a8a81ea828264` завершился **exit1/87125мс**. Parent: WORKFLOW_UPDATE_POST_COPY_INCOMPLETE. Исходный fresh-child terminal:

```
ai_rules_1c migration is blocked (not-newer): target downstream revision is not newer than the installed controlled fork. Recovery report: C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\project\.agent-1c\runs\ai-rules-migration-recovery-20261024-212321-787\recovery-report.json
```

Новый blocker: **G3-MANAGED-DOWNGRADE-AI-RULES-NOT-NEWER**. Это наблюдение policy refusal, а не законченная причинная диагностика. Post-copy/commit/sibling rollout успешными не объявляются; pending snapshot `400b27db91cc4fdb80a81e70a998ad29` и текущая failed-copy сохранены. Mode fix прошёл прежнюю точку ошибки, но named downgrade acceptance остаётся открытым.

## Сохранность, пауза и следующий шаг

До финального direct-v2 были проверены unchanged original current PM5/DB/runtime, четыре historical roots, 21 historical file, 11 capsule objects, прежние 957 sealed evidence files и исходный failed snapshot ZIP SHA `88b317d3d2740311d9d9a6e2bd2f278efc8606c9e8aab610fec9b780e0058a38`. Recovery proof отдельно подтвердил exact old helpers, clean main+sibling, locked modes, unchanged canary CF/DB и отсутствие Gate6/pending на той предыдущей границе. Эти результаты не выдаются за final preservation proof после direct-v2. Финальная success verification в запущенном цикле не стартовала из-за native failure; итоговые preservation checks отложены.

Пользователь в чате «Оценить ускорение workflow» прямо разрешил согласовать паузу новых проверок и lifecycle/registration для холодного A/B. Уже запущенные тесты и native cycle завершены штатно; новые проверки, recovery, регистрация и OpenSpec CLI validation ждут сообщения об окончании A/B. Никакие процессы принудительно не остановлены. Code commit создан, но не зарегистрирован; документация этого partial result ещё не validated/committed. После паузы нужно разобрать новый отказ в existing ai_rules migration/update owners, сохранить исходный reproducer и защиты, завершить direct downgrade, затем preservation/sealing, согласованность обеих OpenSpec, validation и RegisterChange. Подготовленный `finish-evidence.py` — неисполненный success draft; использовать его без нового положительного proof нельзя.

OpenCode SKIPPED. Gate6/G4, рабочая миграция и публикация не выполнялись. Full init/new/fork/refresh, foreground legacy choices, PM4/platform/native-client клетки и обязательное population остаются по общей матрице; шесть областей, optional OpenViking, canonical home и ai_rules ownership не изменены. Warm deviation ранее принят, новый performance run не требуется.

[JSON](g3-managed-downgrade-mode-partial-2026-10-24.json). Ignored raw root `build/test-results/g3/downgrade-mode-repair-20261024` **пока не sealed**; parent/child terminal, console и recovery report скопированы отдельно. Прежний sealed raw root и ZIP не переписывались.
