# G5: общее подключение — первый нативный прогон, 2026-10-26

Статус: **STARTED / BLOCKED, G5 не принят**. Пользователь разрешил конечный
N1–N7 план словом «делай», включая три proposed homes для qualification snapshot.
Новых случаев/порогов/матриц прав не добавляли. Gate 6, рабочая миграция,
публикация workflow/fork/реестра, push и PR не выполнялись.

## Входы и граница доказательств

- Отдельный Docker `itl-cognee-g5-common-20261026-112117` на фактическом
  SSH host `dev-karimov-mcp` (`itl-mcp-karimov`), loopback 18192. Старый G1
  container/volume/evidence сохранён остановленным. Clone проверен: 1248 файлов,
  2 564 431 965 байт; права исходных UID/GID сохранены после отдельного
  стендового исправления `copytree`. Cognee не дорабатывался.
- Cognee 1.6.5, image `e5de80619fd8d0c53cdaca2aea6020b046f57f8800e62120faa50807fa4f3820`,
  canonical OpenAPI SHA `b863f72d912c07ceb4bb914d790152659427c0ad33863d553d38b5fa64e24171`.
  Те же 2 CPU/5 GiB, GLiNER demo, bge-small-en-v1.5/384,
  `self_improvement=false`, без improve/background jobs. Один ordinary technical
  principal; account/ACL тестов людей нет. Истёкший токен обновлён для того же
  principal, аутентификация не отключалась; credential вне Git/логов.
- Published R6 остаётся `0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`.
  Локальный qualification registry `d705dfb78c749dd54c20f4ee99cc6bbb8b97776b`
  задаёт ровно три подтверждённых home: plan-model/project-requests → pm5-corp,
  payroll-allocation → erppm5. Actual immutable reader/resolver проверил
  pm5-core-development, pm5-prof-development, erppm5-development. MCP sources
  не менялись; ERP+PM5 сохраняет `erppm5-lts`. Эти homes не опубликованы.
- Отдельная PM5-копия подготовлена existing capsule owner на E:, без Gate 6.
  Capsule SHA `c2c570fe1ec57619f1a516b9752c48159da7b703eb8c8bb275977abde19cd8b6`;
  старые стенды/failed copies сохранены. Matching fork
  `162f2ea7a5734b65bc1de80943d057e9b7c0a525` установлен через supported
  dependency-selection hotfix/local tag, без ручных installed pin/manifest edits.

## Конечная матрица N1–N7

| Шаг | Фактический результат | Статус / остаток |
|---|---|---|
| N1 | Через установленный stdio MCP записаны 6 заметок: taskCycle/workspace/workplace/product/project/organization. Все 6 durable, exact native IDs; другой процесс подтвердил все 6 originals durable/applicable и completed dataset pipelines. Один union CHUNKS recall дал 2 проверенные карточки, `coverage=partial`, 6 source lookups/8 backend calls | PARTIAL: storage/fresh-process proof есть; полнота выдачи и label/owner collision не доказаны. Partial не трактуется как отсутствие остальных фактов |
| N2 | Исходный project original/dataId сохранён. Попытка correction выявила неверное multipart-поле `file` вместо native `data`. Source исправлен; owner tests 23/0/0. До завершения branch rollout повтор ещё исполнил старый модуль и снова rejected; это не native proof исправленного source | BLOCKED на update ниже. Pending исправления сохранён; новой заметки/дубля вместо correction не создано. Body-loss/retire/stale-fragment сценарии не выполнены |
| N3 | Legacy update → association → отдельный enable прошли; initial cycle создан без reset. HEAD `f213d357dedba2967673cfa496f5617ec565bdfc` и DB 3 295 928 320 bytes/SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` до/после initial enable совпали. Fresh stdio process использует тот же cycle | PARTIAL: reset/reserve/interruption/resume не запускались. В seed есть только event-log-baseline.json, нет manifest/образа; необходима поддерживаемая подготовка seed. Запрещённый Gate 6 не запускался |
| N4 | Три homes подтверждены пользователем, qualification snapshot/resolver и native IDs двух product homes подготовлены | BLOCKED на незавершённом installed update. ERP-origin → home → КОРП/ПРОФ и negative applicability ещё не проверены. Конфигурация не выдаётся за native proof |
| N5 | Kilo VS Code 7.8.15 запущен на той же branch-копии с отдельным профилем, exact repository trust, Review First/Ask; новых worktrees нет. Окно штатно закрыто перед resume. Agent prompt/tool calls ещё не отправлялись. Master имеет Kilo+Cursor, branch пока Kilo | BLOCKED на update. Cursor/reload/policy/remember/recall/retire/offline/disable не приняты; core/stdio не заменяет IDE proof. Cursor policy/manifest не копировались вручную |
| N6 | Отдельный clone и common connection подготовлены; прежний G1 restore proof сохранён исторически | NOT RUN: новый common-connection restore admission не выполнен; old G1 не заменяет N6 |
| N7 | Frozen корпус/manifest и закрытые evaluator answers сохранены; paired executions 0/24 | NOT RUN: нет сопоставимого model/client proof на согласованной pair. Выигрыш токенов/денег/качества не заявлен |

## Source repairs и фактическая установка

1. Explicit enable входит в существующую registry operation и получает raw
   snapshot **точного applied SHA** через existing owner, без дополнительного
   refresh/fetch. Первоначальный native `MEMORY_REGISTRY_PROJECTION` устранён,
   тот же enable завершён успешно.
2. Local status проецирует project/organization label/scopeId/scopeKind из
   persisted dictionaries явно: Select-Object давал null. Повтор native status:
   все 6 видов scopes, 0 null destinations. Existing owner batch 23/0/0.
3. PATCH multipart использует `name="data"` по frozen OpenAPI. Усилен existing
   correction case: RED 0/1/22, затем весь owner batch **23/0/0, 12.91 s**.
   Число тестовых случаев осталось 23; assertions/deadlines не ослаблены.
   Native приёмка этой правки **не завершена**.

Первые две правки проверены на installed branch source
`0f698781d20103ff75ff4e8013bc86340c6e9a01`. Последний исходный payload
`6b46c0ea12b31911f19a5df427ebfade2222cb3a` установлен/закоммичен в master
стенда, но rollout branch не завершён. SHA-256 memory.ps1 source/master:
`64167e79a5fae33412362c0a872a8ca720cd6b3d16bbcc0b76ba8affd964c9e7`;
branch: `5bbc7c95d27d5333d9f988f62e9805f2e0bfb04cc37b39357e88a9cadc43e9d5`.
Это сохранённый промежуточный state, не принятая целиком installed pair.

## Блокер штатного продолжения

**G5-WORKFLOW-UPDATE-CONNECTION-RECEIPT**: cutover рекурсивно обходит
`.agent-1c/mcp/ondemand/**/connections/<id>/owner.json` как process runtime.
Эта connection receipt хранит отдельный `process` DTO и не обязана иметь
`testClientOwnershipMarkers`/верхнеуровневый `pid`. Первый update exit1 на
отсутствующем testClientOwnershipMarkers. Master checkpoint сохранён:
`itl-workflow-update-rollback-ac721ba1b63c4e03b80406065096a89e`.
После штатного закрытия только тестового VS Code повтор exact update exit1
на отсутствующем `pid`. Удаление квитанций/ручная правка runtime/installed
файлов/обход guard не применялись. Повторять неизменный update ещё раз бессмысленно.

Continuation: workflow-update/runtime owner должен корректно различать native
runtime records, VAParams и connection receipts, сохранить проверки ownership
реальных процессов и дать поддерживаемое продолжение **сохранённого** checkpoint.
Затем повторить исходную correction с тем же dataId, а не новый reproducer.
В этом прогоне guard/cross-owner recovery не менялись. Seed — отдельный
стендовый prerequisite N3; его отсутствие не является дефектом Cognee.

Стендовые ошибки отделены от продукта: PS5.1 stdio получил Utility от PS7 —
исправлено окружение запуска через existing shared Windows PowerShell helper;
повтор UTF-8 intent первоначально читался как cp1251 — исправлен harness,
`MEMORY_PENDING_CONFLICT` при изменённых байтах был корректен. Native note не
переписывалась для обхода guard; данные/failed logs сохранены.

## Evidence / регистрация

Ignored run: `build/test-results/g5/common-20261026-112117/`, continuation
`RESUME.md`, sanitized `g5-result.json` с hashes исходных result/log/JUnit,
module-identities-at-blocker.json; SHA-256 g5-result.json
`119d8063aff89bc71d97984f23597df0f3e2e4d598030e43a35a8ce1d514a503`.
Native source/status/receipts, failed
attempts и old assets сохранены; credentials/settings runtime не коммитятся.
Полный cost accounting/agent token metrics неизвестны: N7 не выполнен.
Измеренные named-encoding counts из stdio не являются actual client model usage.

Один coherent source commit включает три source repairs, усиление существующих
cases и эту фиксацию обеих OpenSpec. Регистрацию подтверждает только штатный
`RegisterChange`/`Status` для `product-project-registry-g2`; helper владеет
Targeted. Source/unit/registration не закрывают G5/AC-43/44 native acceptance.
