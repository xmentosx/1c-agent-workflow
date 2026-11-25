# Регистрация JSON-исправления и повторное устаревание индекса

Проверено 2026-10-11. Это результаты регистрации, не публикации.

Commit `9884c820ba704c42db279b4197cf002e86c6a645`, родительская база
`fa0e3c91694112c1da3ecda7209a8a81ea828264`, зарегистрирован штатным
`source-delivery.ps1 -Action RegisterChange` один раз. Общая очередь:
`codex/redesign-source-delivery`, base fa0e3c91, head 9884c820.
После завершения activeOperation=null; worktree чистый.

Авторитетный raw record в common Git:
`itl/runs/20261010-211030-221-targeted-a4aca4bf97974290b7f6c3b9a42f9f20.json`.
Passed, точный commit совпадает, 1287331 ms, 308 passed / 0 failed / 1 skipped.
14 Pester-файлов исполнены, 0 переиспользованы. Full, Develop, Release и
публикация этой единицы не выполнялись.

| Измерение | ms |
|---|---:|
| Targeted целиком | 1287331 |
| Pester stage | 1279841 |
| fingerprintPlan | 18436 |
| cacheLookup | 57 |
| workerSpan | 1254013 |
| identityInventory | 1152 |

LocalQualityGate: 607.618 s; ReleaseGate: 645.297 s, выполнялся после
параллельной части; Queue: 411.6 s. Эти suite durations нельзя суммировать
как последовательное календарное время. Широкий quality-catalog owner
остаётся отдельной причиной дорогой регистрации; JSON-исправление её не решает.

## Почему index снова stale

После регистрации reader исправленного commit различает валидный, но
устаревший индекс и повреждённый JSON. Наблюдение: stale, pending markers 0.
Сохранённый source-directory stamp: `2026-10-10T20:21:12.9480843Z`;
фактический: `2026-10-10T21:31:57.8336411Z`;
updatedAt: `2026-10-10T20:21:25.9747754Z`.

Причина подтверждена кодом владельца:

- `source-delivery.ps1` выбирает develop только для Plan/PublishDevelop;
  RegisterChange выбирает master.
- Закреплённый origin/master `69c0863bfe3bd837543267f122e81a28dcfa5488`
  содержит Write-DeliveryRunRecord, но не Write-DeliveryRunHotIndex и
  не Add-DeliveryRunToHotIndex.
- Поэтому доверенный старый supervisor пишет новый raw proof без обновления
  индекса, который обслуживает более новая develop-версия.

Повторное перестроение индекса не устраняет эту несовместимость writers.
Диагностика выполнена read-only; общий index/refs вручную не меняли.
Raw passed proof сохраняет силу независимо от свежести ускоряющего индекса.

## Условие активации C

Нельзя считать, что PublishDevelop автоматически активирует новый протокол
RegisterChange: при текущем выборе authority регистрация остаётся на master.
До реализации C нужно согласовать канал supervisor для source registration,
совместимость старых закреплённых планов и переход существующей очереди.
Предложение: новый source registration использует опубликованный develop owner;
начатые планы продолжают свою закреплённую authority. Это изменение authority
включено в ожидающий архитектурный checkpoint; сейчас оно не реализовано.

## Ещё один вход cache proof

В текущем sharded runner fingerprint включает версию родительского PowerShell
и Pester, тогда как исполнение запускается через powershell.exe (Desktop 5.1).
Необходимо моделировать фактический child runtime/module identity при reuse.
Неизвестная identity должна отключать reuse и продолжать исполнение; она не
оправдывает новый общий запрет. Это отдельный пункт A.6, пока не исправлен.
