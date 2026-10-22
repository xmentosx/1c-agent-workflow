# G3: первый update-workflow и Startup post-copy, 2026-10-22

**G3-UPDATE-POST-COPY-STARTUP закрыт в исходном PM5 subset; full G3 / AC-39 открыт.** [JSON с identities, результатами и SHA raw evidence](g3-post-copy-startup-repair-2026-10-22.json). [Прежний failed первый проход и его штатный continuation](g3-owned-mcp-defer-repair-2026-10-22.md) сохранены как исторический результат.

## Причина и исправление

После копирования новый `agent-1c.ps1 -Action update-workflow -LifecyclePhase post-copy` запускал общий catalog startup раньше `Update-WorkflowPackage`. Новый writer легитимно восстанавливал отсутствующие Code/Graph в `.kilo/kilo.json`, но это происходило до `Assert-WorkflowUpdateSnapshotCurrentState`: снимок `post-copy-running` ещё фиксировал прежние bytes. Guard обоснованно останавливал непредусмотренную запись.

Existing startup disposition получает уже существующий LifecyclePhase. Только `update-workflow/post-copy` возвращает `inherited-update`; fresh child сначала входит в прежний update owner и проверяет снимок. Затем file post-copy явно вызывает тот же Initialize для bound catalog-only проекта, не полагаясь на наличие legacy MCP selection, и согласует client surfaces под его checkpoint/registry operation. Обычный top-level/pre-copy update, sync-client-mcp, explicit recovery и broker policy сохраняются. Snapshot guard, receipts, locks, writer ownership, ai_rules_1c и серверы не менялись. Один прежний startup apply перенесён под его owner; новых probes/state/контекста/barriers нет, отдельный token/Startup delta не измерялся.

Промежуточный phase-only candidate `a63af800…` дал exit 0 без guard failure, но оставил Code/Graph физически отсутствующими: legacy-only ветвь пропускала catalog-only setup. Он **не принят**; raw native result, before-setup copies и rejection сохранены. Финальное исправление включает обе части порядка и отдельную catalog-only regression. Технические ошибки первых unit stubs также сохранены; исправленный fixture дал ожидаемый red `catalogCalls=0`, затем green без ослабления acceptance.

## Повтор исходного сценария

Root тот же: `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch` в том же parent. До подготовки архивированы settings/receipts и identities. Штатный `restore-compatible`, normal update на exact clean `d109a95d…` и старый public select восстановили исходное состояние: PM5 КОРП / `pm5-core-development`, Kilo→Cursor, прежний bound descriptor SHA, absent/unowned Kilo Code/Graph с сохранёнными `lastWritten` baseline. Ни receipts, ни managed config вручную не подставлялись. Два fixture commits закрепили только полученную tracked association для строгого clean preflight; история и topology сохранены.

Implementation commit **`176bd2fa6b8d107d33df2b92600e0c14d365ee45`**, финальный source-коммит добавляет документацию без изменения этих runtime bytes. Один public compact-runner `update-workflow` на этом baseline: **exit 0, 414.871 s**, outer и fresh-child statuses succeeded, main и eligible sibling установлены на этот commit. Дополнительных update/recovery/reconcile/status-команд для доведения прохода до успеха **0**, receipt edits **0**. Это повтор названного первого обновления, не всех вариантов installed migration.

| Проверка | Результат |
|---|---|
| Регрессия actual dispatcher block | До исправления post-copy вызывает Initialize один раз вместо нуля; остальные 3 случая green. После исправления все 4 входят в проверенный owner batch |
| Owned tests | Финальный полный batch: 159 passed / 0 failed / 0 skipped. Прежний batch 158 passed + 1 failed из-за отсутствующего default local Vanessa archive и unchanged exact-SHA retry 1 passed сохранены отдельно; catalog-only phase regression проверяет physical write после snapshot guard и его захват checkpoint |
| Snapshot / foreign-edit negatives | Existing rollback/reconciliation suite сохраняет guard rejection поздних правок, исходные bytes/index/HEAD и guarded continuation |
| First native update | Одна команда, без защитной остановки; main+sibling clean; fork r43 / `987320be…` прежний |
| MCP materialization | Code/Graph physically present в обоих config, URL совпадают с applied context; Kilo imported aliases disabled; три прежних foreign entries сохранены. Native frontend/LLM reads здесь не повторялись; optional windows-mcp preparation degraded из-за отсутствующего uv/uvx |
| Сохранность | DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` прежний; 894 файлов исходного failed/completed snapshot и 273 прежних raw evidence unchanged; прежние 21 protected files / 4 roots, 7 Gate 6 artifacts и 11 capsule artifacts проверены |
| Memory / стоимость | Memory opt-in false, Cognee calls 0. Длительность whole update не является isolated Startup/paired token proof |

## Остаток

Existing AC-15/20/24/25/35/39 получает этот bounded first-pass result. Остальные fresh/live-source/PM4/platform/terminal/frontend/cache/cost критерии full G3 / AC-39, обязательное release population AC-36–38 и memory4.2/G4/AC-43/G5/44 открыты. Gate 6 не исправлялся; рабочая миграция и публикация не выполнялись. Temporary exact old-source checkout служил только fixture preparation, не каналом выпуска.
