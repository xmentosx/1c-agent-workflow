# G3-LD1: current executor, legacy payload

**Исходный native PM5 downgrade принят.** Checkpoint согласован пользователем 2026-10-25; A/B-пауза явно снята чатом «Оценить ускорение workflow» после завершения обоих холодных прогонов. Native implementation `3645c8e46184284b50573a6164709252533a986c` → неизменённый old `fa0e3c91694112c1da3ecda7209a8a81ea828264`: **exit0 / succeeded / 331540 мс**. G3-MANAGED-DOWNGRADE-DEPENDENCY-MODE и G3-MANAGED-DOWNGRADE-LEGACY-ROLLOUT-PINS закрыты для исходного workload. Общая приёмка G3/AC18/39 и memory AC43/G5 из этого не следует.

## Один владелец перехода

Existing update owner проверяет clean exact current checkout до copy, сверяет исполняемые helper/lifecycle/dependencies и сохраняет recoveryExecutorRoot/Commit в существующей transaction. Fresh post-copy запускает этот current helper с прежним signed operation context, target source и dependency plan остаются old payload. Master commit → branch rollout, per-root leases и штатные resume/restore сохраняются. У каждой новой branch transaction свой dependency plan. Перед child exact source проверяется повторно. При недоступности exact executor предусмотрен existing source-side launcher из current checkout с -SourceRoot старого payload; новый кэш, сервис или state machine не добавлены. Старая версия helper в source/installed payload не патчилась.

## Повтор исходного сценария

На той же сохранённой PM5 topology выполнены update current → schema2/workflow precondition для обоих roots → preview/select → несовместимый update при binding отклонён без protected изменений → restore-compatible → **один прямой native current-to-old downgrade** → прежний verifier. Новые тестовые случаи не добавлялись.

| Результат | Основной проект | Связанная ветка |
|---|---|---|
| HEAD | `891afc69630fee01a89c79a9908ccdaaa33616ee` | `16d77dd5938d5c61bbf164a02300efde484e6fb8` |
| Пакет | old fa0e3c91, исходные helper bytes | old fa0e3c91, исходные helper bytes |
| Lock/project/dotenv | schema1 / locked / locked / locked | schema1 / locked / locked / locked |
| On-demand MCP | 0.4.15, SHA 95968ccc… | 0.4.15, SHA 95968ccc… |
| Pending / Git | 0 / clean | 0 / clean |

Новые completed receipts: main `51c2cd62e3c8404597f283fa4da81d02`, branch `8eecf3e5e3f6444e8c7f22100149ebf0`; target oldfa0 и executor `3645c8e46184284b50573a6164709252533a986c` разделены, dependency plan сохранён. Старый failed branch snapshot399 восстановлен existing owner и retained как completed; его прежний failed ZIP и исторические доказательства сохранены. Parent и fresh child terminal статусы succeeded подтверждены verifier.

## Исправления тестового harness

Первая подготовительная попытка остановилась на SHA guard: глобальный ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE указывал 0.4.24, а восстановление pending399 требовало 0.4.15. Один EXE не может удовлетворять двум SHA. В новой копии existing harness убран этот override, штатный installer выбирает уже имеющийся кэш каждой exact версии и сохраняет SHA проверки. Failed attempt сохранён в initial-upgrade-override-failure. Пути, workload, topology, pins и квитанции вручную не менялись.

Сам direct downgrade завершился exit0. Прежний verifier затем упал только при экспорте optional recoveryExecutorCommit у исторической квитанции. В новой копии экспорт использует существующий safe accessor для необязательных executor/intent полей; все mandatory assertions неизменны. Прежний verifier повторён и **PASS**, failure сохранён в verification-optional-field-failure. Повторного native downgrade вместо успешного не запускалось.

## Сохранность и границы

CF/CFE и база `3295928320` bytes, SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` unchanged. Прежний current PM5, четыре исторических root, runtime и 11 capsule objects сохранены; existing prior verifier подтвердил 957 sealed файлов и failed ZIP. Новые raw evidence: `266` файлов, manifest SHA `7284481afd963e7dc7baf833fefd4701f36a6aeeb379791bef795394a55200f5`; RESUME.md не входит в seal. [JSON](g3-legacy-executor-2026-10-25.json). [Исторический partial FAIL](g3-managed-downgrade-repair-2026-10-24.md) не переименован в PASS.

Новые standalone unavailable-executor/fault cases не добавлялись по прямому указанию пользователя; отсутствие такого запуска не считается fault proof. Используется только существующий original scenario и штатный RegisterChange-owned Targeted. Runtime hashes зафиксированы в JSON; финальные doc-only изменения commit отделяются от native source identity. **Регистрацию этого же head подтверждает source-delivery Status / queue product-project-registry-g2; native PASS сам по себе не означает принятую очередь.** После регистрации tracked статус повторно не переписывается.

OpenCode SKIPPED. Gate6/G4, рабочая миграция, публикация/push/PR не выполнялись. PM4/platform/client/lifecycle остаток и обязательное наполнение реестра остаются по общей матрице. Малые ранее принятые расходы Startup не пересматриваются.
