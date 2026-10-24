# G3: managed downgrade repair и остаток legacy rollout, 2026-10-24

**Исправлены wire/process handoff и применение выбранных правил на main; исходный downgrade целиком не принят.** На той же сохранённой PM5-копии прямой installed update нового `15b7bcd476c518afb94a6ded648a2a1c633395d6` → неизменённый old `fa0e3c91694112c1da3ecda7209a8a81ea828264` завершил post-copy/commit основного проекта, затем exit1/258955мс на sibling. Новый blocker — **G3-MANAGED-DOWNGRADE-LEGACY-ROLLOUT-PINS**. Full G3/AC-18/39 и memory AC-43/G5 остаются открытыми.

## Реализация и проверки

Один stateless dependency owner выбирает wire format целевого шаблона: schema1/fresh/latest/locked/pinned → schema1/locked, current schema2 → workflow. Sync и entry writer согласуют lock/project/dotenv без изменения selected pins, provenance, foreign entries или pinned receipt intent. Current Get-DependencyMode остаётся workflow; второй version-selection policy нет.

Existing snapshot coordinator до legacy child синхронизирует settings, передаёт locked через process environment и explicit argument, заменяет прежний аргумент ровно один раз и восстанавливает parent environment в finally. Dotenv import сохраняет inherited process value, поэтому прежнее исправление только файлов не устраняло original direct failure. Старый helper/source не патчились.

Следующий direct repeat показал ai_rules not-newer при r43→r42. Existing migration owner уже поддерживает exact qualified bundle в admitted workflow transition. Для legacy handoff он теперь вызывается перед старым child внутри той же transaction, с прежними preflight/ownership/result/rollback проверками; current-state receipt записывается до child. Standalone monotonic guard, SkipAiRules и отрицательный result не ослаблены. Нового migration protocol/coordinator/cache и произвольного downgrade правил нет.

Owner suites DependencyLocks + WorkflowUpdateRollback: **99 PASS / 0 FAIL / 0 SKIP / 0 NotRun**, 246728мс. Семь новых regressions покрывают wire/pins, exact rules/settings rollback, inherited environment/finally, single child argument, refusal и SkipAiRules. Existing rules-policy subset: **2 PASS / 0 FAIL**, 29 остальных tests не запускались из-за tag filter; это не full-suite proof. Прежние assertions, watchdog120, artifact SHA, signed operation, CAS и source/dirty guards сохранены.

## Повтор исходного native workload

```
C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\project
C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\branch
```

Без пересоздания, переноса базы или ручных mode/receipt/pin правок выполнены: update на исправленный current source, schema2/workflow во всех трёх surfaces обоих roots, public preview/select, unchanged incompatible-package rejection при активной ассоциации, public restore-compatible и original installed update на old source. Upgrader/executor этого прямого повтора запускался из установленного пакета; source-assisted recovery отдельно и не подменяет direct proof.

Main завершил old post-copy и commit: clean Git, pending=0, schema1 и lock/project/dotenv=locked, ondemand0.4.15, workflowfa0. Native old child прошёл прежние mode и not-newer errors. Sibling old rollout создал transaction без dependencyPlan и оставил прежние schema2/workflow, ondemand0.4.24 при уже скопированной compatibility0.4.15. Old locked sync сохраняет имеющиеся pins и не знает нового bundle intent. Поэтому он штатно остановился на строгой проверке:

```
WORKFLOW_UPDATE_BRANCHES_INCOMPLETE: master is updated; repeat update-workflow when the named branches are available or repaired. itldev/workflow-release-e2e-preflight=blocked: WORKFLOW_UPDATE_BRANCH_POST_COPY_INCOMPLETE: ITL_ONDEMAND_FACADE_LOCK_MISMATCH: compatibility='0.4.15' dependencyLock='0.4.24'. Snapshot: C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\branch\.agent-1c\snapshots\workflow-update\itl-workflow-update-rollback-399283752e274338b8bf90768e596e20 Report: C:\itlj\g3-lifecycle-20261024\q Проект\develop-c2c570fe1ec5-34c623e6e9cc-c1ed2864\project\.agent-1c\snapshots\workflow-update-rollout.json
```

Main успех не считается общим успехом. Sibling pending `399283752e274338b8bf90768e596e20`, failed copy и report оставлены; отдельный архив578files/3386656bytes SHA `a003e5c8c5a3c6343596a77ea528c08cb9acdb6478976f3da40e22402efba983`. Его settings/lock вручную не исправлялись, исходный сценарий/target/workload не менялись, mismatch не скрыт подбором executable.

## Промежуточные попытки и сохранность

[Original failure](g3-pm5-lifecycle-2026-10-24.md) и [промежуточный not-newer](g3-managed-downgrade-mode-partial-2026-10-24.md) сохранены как история. Original snapshot3ad штатно завершён source recovery; old replay exit0/7624мс после этого был no-op и не квалифицирует fresh handoff. Первый recovery получил неверный новый executable и штатный SHA refusal; harness исправлен на существующий exact old0.4.15/95968ccc cache, SHA contract не менялся. Direct первой версии exit1/67530мс выявил inherited environment, следующей exit1/87125мс — not-newer. Transactions e45 и400 завершены штатным recovery; все original terminal/recovery reports сохранены. Source launcher WORKFLOW_UPDATE_NEW_CANDIDATE_PENDING после завершения pinned old не выдавался за общий PASS.

В owners-v3 три fixture failures были вызваны plan-after-backup порядком и отсутствием admitted SourceRoot plan. Fixtures приведены к реальному public updater порядку plan-before-snapshot; проверки не ослаблены. Итог owners-v4 99/0/0/0. Между попытками по прямому согласованию пользователя освобождено окно холодного A/B другого чата; процессы завершались штатно, новые запуски ожидали сообщения об окончании. Пауза снята, последующие проверки завершены.

Final preservation: CF tree и working business paths обоих roots не изменены; DB 3295928320bytes, SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` прежний. Old helpers в обоих roots совпадают с unchanged old source. Main clean, branch dirty/pending ровно на зафиксированной границе; он clean не объявляется. Прежний current PM5/DB/runtime, четыре historical roots, 21 historical file, 11 capsule objects сохранены. Все 957 прежних sealed files и original failed ZIP SHA `88b317d3d2740311d9d9a6e2bd2f278efc8606c9e8aab610fec9b780e0058a38` повторно проверены без изменений. Gate6 artifacts=0.

OpenCode SKIPPED. Gate6/G4, рабочая миграция и публикация не выполнялись. Native Kilo/Cursor чтения здесь не заявляются: membership canary только Kilo, Cursor config отсутствует. Full init/new/fork/refresh, foreground legacy choices, PM4/platform/native-client и обязательное population остаются по общей матрице. Шесть областей, optional OpenViking, canonical knowledge home и независимость registry от G4 прежние. Accepted warm deviation не пересматривается.

## Архитектурный checkpoint G3-LD1 — предложен, не одобрен

Инвариант: exact selected legacy bundle и wire format применяются одним действующим update owner ко всем eligible roots; payload старого пакета не должен подменять executor перехода на legacy код, не понимающий pinned plan. Минимальный reproducer — current15b main+sibling → oldfa0 после restore-compatible, основной commit успешен, old branch coordinator сохраняет pin0.4.24. Изменение раннего rollout/исполняющего helper между roots затрагивает process/compatibility/recovery границу и требует checkpoint по AGENTS/package-architecture; нового runtime решения в этом прогоне нет.

Варианты: (A) штатный restore ранее завершённого snapshot ограничен конкретным before-image и не заменяет original arbitrary-target update; (B, предлагается) existing update/recovery owner сохраняет exact verified current executor для всего legacy master+branch перехода, а target source/pins остаются oldfa0; использовать существующие source/cache resolver, receipt executor identity, per-root leases, rollout/status/resume/restore, без нового service/registry/state machine; (C) новый shared executor/cache manager или снятие поддержки legacy — лишняя authority/сложность либо support reduction, не согласованы. Патч old source, ручное исправление pins и ослабление lock mismatch/not-newer отвергнуты.

План B после одобрения: проверить поддерживаемый источник current executor и зафиксировать его identity до copy; сохранить разделение executor и payload в existing transaction; при отсутствии exact executor остановиться до записи с продолжением через verified current SourceRoot; провести master/sibling через существующий per-root owner, не менять порядок на branch-before-master без отдельного обоснования. Retain прежние bounded waits, signed generation, result checks, cancellation/status и recovery. Acceptance — исходный single native current→old update на той же PM5 topology завершается exit0 с post-copy/commit/rollout, все roots exact old pins/schema1/locked и clean, DB/CF/foreign settings unchanged; отдельные fault tests на unavailable executor, partial branch и resume/restore. Recovery/no-op replay, preformatted branch или удаление sibling не заменяют этот proof. Gate6/G4/рабочая миграция/публикация остаются вне допуска. Это предлагаемый checkpoint, не разрешение реализации.

[JSON](g3-managed-downgrade-repair-2026-10-24.json). Raw `build/test-results/g3/downgrade-mode-repair-20261024`, 468files, manifest SHA `db4aa3578c39d463d6038f4ae76be45e47a84d0f20d7f47fe4d8e16be9bd7015`. Native terminals, console и pending/rollout reports сохранены отдельно. Validation/registration logs — вне sealed raw root; регистрация не является full G3 или публикацией. Success draft finish-evidence.py не выполнялся: его положительные assumptions не являются результатом.

## Дополнение при регистрации: literal LifecyclePhase

Первый Targeted кандидата11c обнаружил regression в existing emitted-phase completeness test: post-copy был передан через переменную и исчез из статически проверяемого списка фаз. Исправлен owning call: литерал post-copy снова находится прямо в Invoke-Agent1cFreshProcess, только optional dependency arguments добавляются отдельно. Итоговый argv тот же; существующий ValidateSet test не менялся. Focused original phase test1/0 (194 unselected) и handoff tests4/0 (58 unselected) прошли. Исходный native proof относится к implementation15b, после него изменена эта запись аргументов; exact final tree подтверждается отдельно штатным Targeted, а новый native/full G3 proof не заявляется. Sealed raw468 сохранён без изменения; дополнительные diagnostics — build/g3-downgrade-registration-repair и исходный failed registration log, не внутри sealed raw.

Дополнительная проверка commit checkpoints обнаружила, что новый migration call нельзя повторять после master-commit-ready/master-committed. Две regressions дали RED (2 FAIL/4 PASS), затем GREEN (6 PASS/0 FAIL,58 unselected): rules/dependency writers не вызываются, child получает прежнюю фазу, receipt/current-state не откатываются в post-copy-running. Вызов ограничен pre-commit стадиями существующей transaction; signed continuation/commit recovery не расширены. Native15b не покрывал этот commit-resume case; финальное дерево проверяется штатным Targeted. First failed registration retained, accepted queue refs не заменены.
