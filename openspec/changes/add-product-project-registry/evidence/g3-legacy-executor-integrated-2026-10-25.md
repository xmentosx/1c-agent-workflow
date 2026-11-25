# G3-LD1 после согласования накопленного кандидата

**Повтор исходного PM5 downgrade на объединённом коде — PASS:** source `7ba9f0a3ce6ebd08b227b4b35b65e43fe5b2f99c` → неизменённый old `fa0e3c91694112c1da3ecda7209a8a81ea828264`, exit0 / succeeded / **381883 мс**. Новых проверок или test cases нет; исполнен прежний direct-v5 workload на прежней сохранённой main+sibling topology. Полная приёмка G3 этим не объявляется.

## Конфликт регистрации и его разрешение

[Первый native PASS](g3-legacy-executor-2026-10-25.md) на3645c8e4 сохранён. Первая регистрация95698fd8 остановилась до Targeted на трёх content-конфликтах одного lifecycle.ps1; candidate/proof1173 сохранён. Причина — накопленный develop candidate8f7aaee4 уже содержит изменения legacy-copy recovery и temporary-patch retirement, которых не было в source base760250f2.

Один unregistered commit перенесён обычным rebase на принятый candidate8f7aaee4; accepted own760 остаётся ancestor. Обе стороны сохранены: foreign master-only/repeatAction вместе с LD1 exact child executor; branch snapshotDetails содержит и localPatchRetirement Bind, и recoveryExecutorRoot/Commit; foreign legacy-copy functions и LD1 resolver оставлены отдельно с корректными границами. Source-side launcher сохраняет foreign Recovery legacy-status/legacy-copy и LegacySourceRoot. Ручной merge commit, правки чужих worktree или queue refs не выполнялись. Успех старого native не использован как proof нового исходника — после разрешения повторён тот же original workload.

## Фактический результат

Update current7ba9 (workflow/schema2, MCP0.4.26) → preview/select → отказ incompatible update при активном binding без protected изменений → restore-compatible → **single direct current-to-old update** → прежний verifier: PASS. Старый source/helper bytes не патчились. Использованы прежние исправления harness: штатный per-pin verified cache вместо global single-EXE override; safe optional diagnostic fields при неизменных mandatory assertions. Ошибки первых попыток остаются в первом evidence root.

| Критерий | Main | Sibling |
|---|---|---|
| HEAD | `d458e3ac4a1be090554ad2cd0ca0816cac3ee23b` | `614bef5d1748f05f93e2e843fcfc989058b0b8e8` |
| Target | oldfa0 exact helpers | oldfa0 exact helpers |
| Lock/project/dotenv | schema1 / locked / locked / locked | schema1 / locked / locked / locked |
| MCP | 0.4.15, SHA95968ccc… | 0.4.15, SHA95968ccc… |
| Git / pending | clean / 0 | clean / 0 |

Parent и fresh child terminal succeeded; branch rollout завершён. Completed transaction identities с targetfa0/executor7ba9 и dependency plan сохранены в JSON. Исходный CF tree и база 3295928320 bytes, SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` unchanged. Прежний current PM5, четыре исторических root, runtime и capsule сохранены. Existing prior verifier подтвердил957sealed files и original failed ZIP; первые native/evidence root не изменялись.

Raw `253` files; manifest SHA `4a14faef2edf726da5fb3ebea6267e2db698fcd514c59f2b92a11053c4d0b6e7`. [JSON](g3-legacy-executor-integrated-2026-10-25.json) фиксирует source identity/runtime hashes и paths. Последующие doc-only commit изменения отделяются от native source. **Регистрация того же финального head проверяется отдельно через scripts/source-delivery.ps1 -Action Status, queue product-project-registry-g2; после принятия очереди tracked приёмка не переписывается.** Targeted запускает только штатный RegisterChange; дополнительных gates или новых checks нет.

Оба downgrade blocker закрыты для исходного PM5 сценария; full G3/AC18/39 и memory AC43/G5 остаются по общей матрице. Непроверенные standalone unavailable-executor/fault варианты не выданы за PASS. OpenCode SKIPPED; Gate6/G4, рабочая миграция, публикация/push/PR не выполнялись. Accepted Startup deviation не пересматривается.
