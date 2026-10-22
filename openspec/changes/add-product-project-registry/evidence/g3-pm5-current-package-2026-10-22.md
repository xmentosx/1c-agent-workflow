# G3: установленный PM5 на текущем пакете, 2026-10-22

[JSON и hashes исходных результатов](g3-pm5-current-package-2026-10-22.json) — единый evidence для обеих OpenSpec. Это native installed subset на `d109a95dc1db95199bb3b2d4114b6cafddd05adb`, а не повтор старого установленного `b4338057` или полный G3/AC-39. Production code, tests, серверы и controlled fork не менялись.

Через existing Develop fixture factory подготовлена новая отдельная copy `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed` из прежней capsule `c2c570fe…`; подготовка 147,687 s, RestoreIB внутри неё 66,634 s, времена inclusive. Исходный caller `fa0e3c` в обеих roots clean, без catalog hook/binding/selection. Original live raw seed по-прежнему unavailable: квалифицируется восстановленный snapshot, его currentness не выдумывается. Все операции используют private registry/MCP home и lease нового stand; прежние stand/failed copies сохранены.

| Проверка | Наблюдаемый результат |
|---|---|
| Первое обновление старого caller | Один foreground `update-workflow`, exit 0 / terminal succeeded, 318,793 s, без предварительного upgrade caller и внешнего resume. Обе roots получили `d109a95d`, fork остался locked `987320be` / r43. После package success виден `choose / new / later`; настоящий terminal input `later` сохранил defer без auto-association/memory opt-in |
| Поздняя ассоциация | Public preview/select/context на текущем installed helper; preview не меняет descriptor/client. Родитель привязан, sibling branch остаётся unbound. Две ordinary `sync-client-mcp` завершаются успешно, вторая сохраняет client SHA. Чужой disabled MCP не включён и не удалён |
| Восстановление | `restore` после sync возвращает состояние перед последней операцией, включая прежнюю binding. Полное снятие привязки через `restore-compatible` возвращает исходный descriptor/lock/HEAD/clean. Отдельно повторён исходный непосредственный `select → restore` без sync: тот же exact byte/head/clean proof, descriptor SHA `ed4daf2f…` |
| Partial и pinned continuation | Настоящий read-sharing handle не даёт атомарно заменить private selection. Native select exit 1, operation partial, финального applied marker нет. Ordinary sync блокируется `CATALOG_OPERATION_PENDING`, diagnostic status доступен. После изменения tip только private каталога resume сохраняет прежние operation ID и pinned revision, затем restore возвращает точный baseline |
| Новый неполный внешний проект | Public create готовит local pending record/request со стабильным `qualification-pm5-custom`, без публикации и автоматической ассоциации. Отдельный select/context использует PM5 CORP, отсутствующие optional СППР/Mantis links не вызывают обязательных вопросов, memory off. Последующий compatible restore сохраняет baseline roots. Synthetic record не является выпускным наполнением |

Partial проверен для одного установленного клиента и ошибки записи settings. Это не multi-client A/B foreign-write topology и не доказательство всех interactive conflict decisions. В этом срезе нет native Agent tool reads/reload нового stand; ранее полученный native frontend proof сохраняет собственные границы.

## Время и неизменность

Измерены по 20 warm public `sync-client-mcp` после исключённого warmup на одном установленном PM5 и private local Git registry:

| Состояние | Median whole CLI | p95 whole CLI |
|---|---:|---:|
| Unbound | 4,3445 s | 5,148 s |
| Bound | 4,6565 s | 5,066 s |

Разница median **+0,312 s**, разница p95 **−0,082 s** — наблюдения двух последовательных серий, не isolated Startup duration или p95 индивидуальной добавки. В bound серии неизменны SHA и actual mtime пяти файлов: descriptor, dependency lock, client config, client-managed receipt и applied marker. В unbound baseline explicit sync переписывает mtime client-managed receipt при том же SHA, до включения G3 binding; исходный no-write failure сохранён. Это наблюдение existing writer, не доказанная регрессия Startup G3 и не подтверждение полного отсутствия writes. Network transport, terminal/multi-user/platform costs, agent/provider tokens и billing не измерялись; full AC-20/25/39/5.5 остаётся открыт.

Диагностические drivers имели сохранённые ошибки parser/PowerShell object shape/доступа к nested selection/финальной агрегации; create и restore также сначала проверялись с неверным предположением о границе операции. Причины и исходные failed reports перечислены в JSON. Итоговые валидаторы проверили те же captured native results, точные snapshots и unchanged original direct select/restore, без выдачи zero-step pseudo-pass за успех или повторного выполнения прошедших команд ради timing. Bound continuation завершил 20 native calls, guards и owned restore; отказ финального formatter не скрыт. Transcript update содержит пойманный sharing exception временного fresh-status, после которого тот же command завершился succeeded; повторяемый product blocker этим не установлен. Optional Windows MCP явно degraded из-за отсутствия uv/uvx; готовность этого компонента не заявляется.

## Сохранность и остаток

После последнего действия DB SHA `c323a334…` / 3 295 928 320 bytes прежний; business Git trees `src/cf`, `src/cfe`, `tests/features` совпадают с baseline. Обе roots имеют исходные post-update HEAD/descriptor/lock и clean tracked/untracked state. Сохранены 21 protected file/четыре старые Git roots, все 11 capsule artifacts и семь Gate 6 artifacts. Новый stand оставлен для продолжения; Gate 6 не запускался и не исправлялся.

Full G3/AC-39 остаётся открыт: новый init/new branch/full refresh/downgrade не квалифицированы этим snapshot-only stand; исходная live seed/master DB currentness недоступна, подменять workload или запускать отложенный Gate 6 нельзя. Остались multi-client foreign-write/conflict decisions, remote/offline и полная client/platform matrix; выделенных PM4/Windows 10/Server terminal stands не предоставлено. Сохраняются installed-facing walkthrough и полное cost/context proof. Отдельно обязательны release population 1.9–1.11/5.7 и AC-36–38; память использует тот же будущий результат AC-44. Source Code/Graph patches/index stamps не возвращаются в prerequisites.

Memory consumer4.2/AC-43/G5/44 не реализован/не принят; Cognee calls 0, six scopes/canonical home/ai_rules_1c contracts прежние. G4, рабочая миграция, production registry/workflow publication не начинались. Последующая документационная регистрация принадлежит existing RegisterChange/Status; её успех не означает полный G3 или выпуск.
