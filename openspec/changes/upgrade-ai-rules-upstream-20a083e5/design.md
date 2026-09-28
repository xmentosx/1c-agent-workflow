## Context

Постановка относится к исходному workflow и controlled fork, а не к изменению
живой конфигурации 1С. Точные входы указаны в proposal.md. Remote main повторно
проверен 2026-09-28: `20a083e5`. `path-inventory.json` охватывает 196 downstream
и 379 upstream изменённых путей; пересечение 116, объединение 459. Это инвентарь
планирования, не 459 доказанных конфликтов и не готовый release ledger.

Старые 197 записей path ledger содержат 22 группы, но функциональный
`docs/DOWNSTREAM-PATCHES.md` fork дополнительно описывает подинварианты.
`migration-map.md` связывает оба реестра с новыми владельцами и приёмкой.
Итоговые byte hashes появятся после реализации у существующего сборщика.

Текущие точки расширения ITL: `agent-1c.core.ps1` (набор клиентов),
`agent-1c.client-adapters.ps1` (surface/MCP/configuration),
`agent-1c.ai-rules-migration.ps1` (snapshot/preflight/restore),
`agent-1c.verification-modes.ps1` (результат и repair session),
`agent-1c.lifecycle.ps1` (закреплённый fork, bootstrap, refresh),
`scripts/build-ai-rules-release.ps1` и существующий delivery supervisor.
Все `agent-1c.*` здесь — файлы под
`.agents/skills/1c-workflow/scripts/lib/` исходного пакета.

## Goals / Non-Goals

**Goals:** реализовать Q1–Q20 и замечания двух ревью; сохранить конкретные
действующие исправления; принять новое поведение upstream через все точки
входа; сделать установку, многоклиентность, store и доказательства совместимыми
с существующими владельцами и проверяемым откатом.

**Non-Goals:** перечислены в proposal.md. Этот change не включает автоматическую
публикацию, смену production-баз, общий демон управления клиентами, глобальный
переход всех проектов на один CLI или неявный выбор новых memory providers.

## Decisions

### D1. Новый root и одна смысловая обязанность у одного владельца

Сборщик прекращает подстановку целого `templates/ai-rules-overlay/AGENTS.md` как
альтернативной редакции root. Базовый root берётся из нового upstream; компактный
обязательный ITL ownership contract и ссылки включаются воспроизводимым
рендерером. Общие upstream правила остаются у новых владельцев `mcp-policy`,
`verification-*`, `subagent-core`, operation skills; ITL runtime детали остаются
в host references. Локальные дополнения, отсутствующие в MCP standards corpus
(например, проверка контекста управляемой формы), получают локальное правило с
обязательным точным маршрутом загрузки. Нельзя считать наличие router доказательством
наличия нашего текста в corpus.

`USER-RULES.md` сохраняет пользовательскую часть и идемпотентно обновляемый
ITL-блок. Приоритет пользовательских инструкций не меняется. Проверка эффективных
overrides даёт report-only конфликт с источником, приоритетом и последствием;
блокируется только зависимое действие. Автоматически удалять пользовательское
требование ради обновления запрещено. `/evolve` сохраняет явный запуск и поштучное
решение; защитные ограничения обновляются по принятым контрактам, а не сохраняют
отменённый обязательный test-plan/persistent-level.

Альтернатива «сохранить старый compact root и дописать ссылки» отвергнута Q15:
она возвращает второго владельца общих правил. Простое удаление всех downstream
правок теряет проверенные исправления. Искусственные старые заголовки удаляются
только после переноса реальных ссылок и смысловой приёмки.

### D2. Все новые мутирующие маршруты подчиняются существующему owner

Managed scope определяется существующим `.agent-1c/project.json` и контекстом
helper, а не одним `.dev.env`. Сохраняется guard в общих DB/web tools; новые
repo-ops, Python web, first dump, plugin, test-fix, EDT/deploy и agent-repair
проверяются на ту же границу до мутации. Поддерживаемая операция маршрутизируется
в ITL; неподдерживаемая даёт `ITL_LIFECYCLE_HELPER_REQUIRED` с точным продолжением.
В standalone scope обычный upstream сохраняется; plugin-предложение не расширяет
разрешение на изменения чужого проекта.

`SOURCE_USES_REPOSITORY` и `REPOSITORY_PATH` продолжают описывать source.
Признак фактической repository binding текущей копии определяется lifecycle state;
наличие source settings не включает upstream lock/edit/commit цикл. ITL может
отвязать созданную им копию на предусмотренном этапе. Source repository locks,
object list и sync остаются helper-owned; branch changes не загружаются напрямую
в source. Настройки source не очищаются для обхода нового правила.

Первичное предложение dump считается обработанным внутри ITL bootstrap либо
переводится в его существующий source-acquisition шаг. Upstream agent-repair
в managed scope выполняет диагностику и вызывает host recovery вместо ручного
копирования/правки manifest. `/installtools` показывает существующее provisioning
и не включает второй installer MCP. Standalone поведение не удаляется глобально.

Preview метаданных выполняет реальные временные файловые записи. В managed
scope write-set ограничен исходниками запрошенной операции; snapshot, hashes
и восстановление относятся только к нему. Dirty/параллельно изменённые файлы не
попадают под общий checkout/clean. При невозможности безопасного preview агент
возвращает причину и продолжение; запрос «показать» не становится apply.

### D3. Проверка сейчас, хранение теста и cadence

Единственный owner readiness — текущий verification coordinator. Расширяются
существующие versioned catalogs/selection и ignored evidence, без второй системы
готовности. Краткий контракт содержит obligation ID, ожидаемый результат,
затронутые inputs, допустимый вид текущего доказательства, решение о сохранении
и cadence. Это не новый обязательный test-plan.md.

Evidence содержит actual/expected, тип проверки, точный source/fragment hash,
область применимости, identity тестовой ИБ и загруженного состояния, runner/tool
identity, revisions применимых требований (включая external store), артефакты
результата и ограничения. Ключ свежести включает также версию схемы evidence и
effective policy. Изменение зависимого входа инвалидирует соответствующую запись;
Git commit того же содержимого и посторонняя правка не инвалидируют её.
При ручном/runtime доказательстве сохраняются реально наблюдавшиеся шаги и
результат; словесного «я проверил» без evidence недостаточно.

Cadence: `affected` для изменённых входов владельца; `handoff` для дорогой
регрессии к значимой передаче/закрытию с reuse свежего результата; `explicit`
для диагностики по запросу. Purpose теста независим от cadence: функциональный
тест нельзя переименовать в benchmark ради исключения. Существующие fast suites
мигрируют в `affected`, явная диагностика — в `explicit`; существующие тесты не
удаляются автоматически.

`/itl-check` остаётся одним каноническим нефильтрованным assessment всех текущих
obligations после последней релевантной правки. Он переиспользует подходящее
свежее доказательство и исполняет недостающие разрешённые проверки. Отсутствующая
по обоснованному решению suite с достаточным one-off proof отличается от suite,
которая была запущена и вернула zero tests/invalid JUnit/failure: второе остаётся
ошибкой. Экспорт/close используют тот же assessment, source/load fingerprints,
event-log evidence и SHA; `block` принимает настоящее полное one-off proof,
`warn` сохраняет действующую явно предупреждённую выдачу результата.

### D4. Эффективные режимы и Gates

Приоритет: актуальная область разрешения пользователя и широкий запрет UI;
затем явное разрешение конкретного разового запуска; затем project execution
switches и upstream provider policy. Разовый запрос создаёт только invocation
override названного компонента/метода с причиной и сроком данного вызова.
Общий «проверь» не снимает `off`; named Vanessa разрешает именно этот запуск,
включая относящиеся к нему сохранённые execution switches. Явный широкий запрет
открывать UI требует явного снятия для UI-метода, а не предположения по названию.
Сохранённые значения не меняются. Недоступный required provider не заменяется
скрытым alias/HTTP/CLI. Неприменимый provider не включается просто из-за настройки.

| Возможность | Owner execution mode | Provider policy |
|---|---|---|
| Подготовить тест | решение о текущем доказательстве/retention | execution off не запрещает authoring |
| YAxUnit | ITL_YAXUNIT_TESTING | registry выбранного runtime; не UI |
| Сохранённая Vanessa | ITL_VANESSA_TESTING | TOOL_BROWSER как saved UI runner |
| Интерактивный UI | UI_TESTING | конкретный TOOL_BROWSER / TOOL_AGENT_BROWSER / TOOL_WINDOWS_MCP |
| Vanessa UI MCP | UI_TESTING, отдельная возможность от saved Vanessa | соответствующая capability/provider запись, без двойного запуска |
| Optional visual test MCP | UI_TESTING | TOOL_UI_TEST; не является именем всех Vanessa проверок |
| Query/pure BSL | разрешённый read-only test target | TOOL_DATA, включая квалифицированный ROCTUP |

Gate 3a допускает bounded read-only запросы и pure BSL с проверенными эффектами,
достаточными параметрами и целевой test IB. Unknown side effects не исполняются.
`NOT_READY` не даёт права загрузить конфигурацию: helper recovery используется,
только если соответствующая мутация уже входит в поручение; иначе dependent
evidence остаётся unverified с конкретным продолжением.

Глубина Gates 1–3 берётся из нового `verification-policy`: не переносить прежнее
«всегда все три». Сохраняются standalone syntax, logic-only preference/fallback,
закрывающий согласованный снимок и однократное in-budget unsupported-result
recovery. Raw ответы и решения adjudication не заменяются фальшивым clean pass.
Новые `1c-validate`, `subagent-core`, `allowed-tools`, `/sdlc`, модели и все
OpenSpec/test entrypoints используют этот контракт. Full-cycle parent review
обязателен независимо от reviewer subagent; quick-fix без запроса не получает
лишнего отдельного review.

### D5. Один repair session для двух входов

Расширяется существующий persisted repair session в verification-modes:
`canonical-repair` и `scenario-loop` — виды входа, не независимые циклы.
`/itl-check` сам цикл не начинает. `/test-fix-loop` явно выбирает user scenarios;
transient сценарий допустим, сохранение определяется отдельно. Default limit
scenario-loop = 3; canonical repair сохраняет ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS
(сейчас 5). Явный N задаёт лимит новой сессии, не обнуляет активную.

Одна попытка — проверочный раунд на подготовленном input fingerprint. Перед
следующим раундом нужно содержательное исправление product/fixture/runner,
обоснованное evidence. Существующий bounded deploy recovery не выдаёт новый
test budget; его исчерпание завершает loop. После успеха сценариев остальные due
obligations проверяются в том же раунде с reuse; их провал продолжает ту же
сессию. Переход между командами, interruption или новый чат сохраняет ID,
attempts и terminal state. Exhausted не обходится новым скрытым ID.

Исправление fixture/шага восстанавливает уже согласованный результат по evidence.
Изменение самого ожидаемого бизнес-результата сохраняет ограничение upstream:
сначала обоснование ошибки ожидания и подтверждение пользователя. Loop не меняет
требование ради зелёного результата; это не отдельное одобрение retention.

### D6. CLI OpenSpec отдельно от глобальной установки

Целевой CLI — официальный `@fission-ai/openspec@1.13.1`, как новый bundle.
Registry metadata проверена 2026-09-28: Node `>=20.19.0`, tarball
`https://registry.npmjs.org/@fission-ai/openspec/-/openspec-1.13.1.tgz`, integrity
`sha512-UHJSV2n6ohjfRaJLvi526avOohFS/orCjM+7JPgvDzuEJbCCkykKfP2fp3gcsvthDLeWolMRT5JAE08MSPnr8Q==`.
Package source и transitive lock закрепляются при реализации компонента. Resolver
квалифицирует пару absolute Node executable + exact OpenSpec JS entrypoint;
Node version/hash входят в receipt и reuse identity. Можно использовать уже
доступный подходящий Node после проверки engines/capabilities; отдельный Node
distributor не вводится. Изменение executable требует повторной qualification.
Один npm shim не считается pin runtime: смена PATH не меняет выбранную пару.

Выбор — immutable versioned user cache с точной integrity, в стиле существующих
ITL components. Небольшой resolver/launcher выбирает pin текущего checkout и
абсолютный executable, не глобальный PATH. Provisioning вызывается явно через
существующую подготовку зависимостей; resolver ничего не скачивает. Не хватает
CLI — файлы правил устанавливаются, зависимая операция сообщает точную команду
подготовки. Explicit external executable допускается после той же capability
qualification. Старые проекты продолжают использовать прежний CLI; rollback
возвращает pin, не удаляет shared cache и не меняет другие проекты.

Текущий CLI 1.4.1 уже возвращает planningHome, но его status не принимает общий
`--store`; одно наличие нового JSON-поля не доказывает совместимость. Проверяются
real JSON/flags для list/context/status/instructions, root/path resolution,
local/project/global/explicit store и invalid pointer, archive/sync. CLI не
перегенерирует адаптированные skills через произвольный `openspec update`.
Source-pilot использует тот же resolver с source pin, сохраняя source-only
routing и invocation metadata; установленный bundle принадлежит fork.

### D7. Store resolver и защита записей

CLI остаётся единственным resolver store registry/precedence/schema/path.
Задача фиксирует canonical physical root, selector, change ID, CLI identity и
связь с checkout/branch. Настройки пользователя разрешают последующую смену,
но не переносят документы. Без выбора внешнего store локальный default сохраняется
для старых и новых проектов. Broken binding не инициализирует локальную замену.

Для записи агент читает документы и hashes, готовит candidate batch отдельно.
Небольшой host operation helper принимает readSet зависимых входов и writeSet
целевых файлов, canonical paths/root identity, expected hashes и кандидат.
При archive вход включает состав дерева change: новая delta/metadata также
меняет revision. Он не является вторым resolver, registry или демоном.
На короткое окно compare/write helper берёт упорядоченные shared read locks
и exclusive write locks, включая namespace membership при создании/перемещении
дерева. Все изменяющие store маршруты участвуют в одном протоколе. Read/write
пересечение конфликтует; общие read-only inputs не сериализуют независимые writes.
Locks не удерживаются во время рассуждений. Ожидание ограничено 30 секундами с диагностикой владельца;
по timeout никакого принудительного удаления lock, продолжение — повтор исходной
операции после завершения владельца. Независимые write-sets работают параллельно.

Lock и краткий operation journal находятся в runtime области выбранного store
(Git common runtime при наличии Git). Lease — OS/file handle с проверенной
shared/exclusive семантикой, а не сам факт существования lock-файла. После crash
handle освобождается; recovery получает его обычным способом, не удаляя чужой
lock. Owner identity служит диагностике. Файловая система должна обеспечивать
эту семантику участвующим клиентам/машинам;
если shared transport её не обеспечивает, зависимая concurrent write операция
не объявляется безопасной, предлагается локальный store или сериализованный
единственный writer. Никакой новый удалённый сервис не устанавливается.
Обычный внешний редактор может не участвовать в lock: повторная сверка хешей
обнаруживает наблюдаемый drift; эксклюзивная запись охватывает заменяемый файл,
а не обещает защиту от произвольного обхода протокола другим процессом.

Journal содержит собственные prepared/before/after bytes и состояние batch.
При recovery откатываются только записи, чьи текущие hashes совпадают с after
данной операции; иначе оставляются обе версии и точное reconciliation.
Scope не допускает symlink/junction escape, весь store не reset/rollback.
Разные changes, пишущие один main spec, конфликтуют по target path. Sync,
validation и archive выполняются последовательно одним operation owner; archive
не удаляет активный change до успешного sync/validation и повторной проверки
той же change/delta revision. Drift оставляет новый delta активным; старый sync
не разрешает archive изменившегося change. Смена alias/root перед
записью останавливает её. Ошибка/параллельное изменение не требует повторного
пользовательского разрешения на техническое перечитывание в прежней области.

Local Git versioning остаётся прежним. Lifecycle snapshot включает binding и
инструкции проекта, но не содержимое external store. Reset/refresh/close/update
не архивируют и не откатывают его документы. Повторное продолжение сверяет
актуальные требования с кодом и proof identity из D3.

### D8. Установленный набор клиентов и контекст вызова

Один источник desired state — `.agent-1c/project.json:aiRules.tools`; результат
применения — `.ai-rules.json:tools`. Не вводится второй независимый installedClients
конфиг. Current session client — аргумент вызова: explicit client, затем
подтверждённый host, затем единственный установленный. При нескольких и неизвестном
host возвращается точный запрос выбора для этой операции, не меняющий набор.
Старое сведение `[codex,kilocode]` к одному клиенту удаляется.
Идентификация клиента не означает, что его поверхность установлена. Если
подтверждённый клиент отсутствует в наборе, клиентские действия дают attach
continuation; session switch/sync/routine не подключают его неявно. Общие
операции, не требующие клиентской поверхности, остаются доступны.

В существующем client-operation owner добавляются attach/detach/reconcile set;
session switch меняет контекст команды, а не desired set. Add/remove формируют
один план всего конечного набора. Временно пустой набор после явного последнего
detach сохраняет проект, базы, общие пользовательские документы и baseline;
клиентские действия предлагают attach. Это не удаление workflow/данных.

Shared ownership использует существующие manifests:
`.agent-1c/client-surface.json`, `.agent-1c/mcp/client-managed.json`, `.ai-rules.json`.
Ключ файла — canonical path, MCP — path/container/server key. Идентичные вклады
объединяют owners; несовместимые дают conflict до записи. Последний owner может
удалить лишь свой вклад. Нельзя просто вызвать нынешний sync в цикле: он удаляет
поверхности других клиентов и старые MCP keys без учёта совладения.

Рендерер fork использует полный конечный набор и его canonical layout для всех
root/nested Markdown, frontmatter и agent TOML; тот же результат участвует в
плане и hashes. Add/remove пересчитывают и оставшиеся ссылки. Собственные generated
ITL wrappers используют invocation syntax каждого клиента. Codex сохраняет
project `.agents/skills`, без user-global prompts и случайного remap в `.codex`.
Модифицированные legacy artifacts сохраняются и диагностируются.

Model defaults из прежних SUBAGENT_MODEL_* при миграции остаются прежнему клиенту.
Client-specific overrides сохраняются в существующем project runtime config,
не копируются как одинаковые IDs всем клиентам и не стираются при attach.
Фактическое model selection/reviewer gate определяется capability registry.

### D9. Матрица клиентов определяет честную поддержку

Полная матрица — в migration-map.md. Базовые десять сохраняются; ZCode/MiMo входят
в реализацию и квалификацию. Механизмы native/reference-only/MCP-extension
называются явно. Pi сохраняет extension pin/integrity/Node>=22, OpenCode —
workspace native adoption/handoff, Kilo — native layout/config collision guard.
Новые tool denylist/permission/readonly преобразования принимаются с реальной
проверкой Shell/MCP и ограничений роли, а не по наличию YAML.

Cline различается по runtime variant/version. Первичные источники сейчас
различают старое global-only описание и новый CLI с project `.cline/mcp.json`:
[официальный CLI reference](https://github.com/cline/cline/blob/main/docs/cli/cli-reference.mdx),
[открытое сообщение о старой области настроек](https://github.com/cline/cline/issues/13596).
Выбранный дизайн сохраняет project-scoped интеграцию, квалифицируя конкретный
CLI/build; неподдерживающий её editor/старый runtime получает явную диагностику
версии/варианта, а не скрытую глобальную запись или успешный статус по файлу.
Минимальные подтверждённые версии/сборки заполняются результатом live qualification,
не выдумываются при планировании. Это не удаление клиента из принятого списка.

OpenSpec native bundle — пять исходных клиентов; остальные используют intentional
natural route. Plugin channel — отдельная capability, не обещание всех 12 hooks.

### D10. Необязательный plugin dispatcher

Адаптируется thin wrapper controlled fork. В managed root он разрешает локальный
ITL helper и проверяет версию его командного протокола. Источником rules pin
остаётся существующий `Sync-AiRules1cCheckout`; отдельный plugin cache origin HEAD
для managed проектов удаляется из маршрута. При несовместимом helper выдаётся
поддержанный ITL upgrade, не fallback на upstream installer.

`ensure` при открытии — read-only обнаружение/краткий статус, без автоattach,
bootstrap или upgrade. Explicit install/add/update dispatch к тому же client/
lifecycle owner. Новый проект с явным поручением установить workflow использует
существующий bootstrap. Standalone rules-only проект не объявляется managed и
не присваивается плагином; обычная standalone функция fork остаётся явно отдельной.

Plugin update и project update независимы. События hook не повторяют длинную
диагностику/doctor в каждом чате; не загружают весь каталог правил always-on.
Ошибки helper и exit status видны, включая OpenCode/Kilo event handler. Disable/
uninstall plugin не удаляет проектные файлы; explicit detach не отменяется новым
ensure. Codex package advertises skills only, пока автоматический hook не
реализован и не проверен; Kilo CLI и editor различаются в capability report.
Совместимость с ITL OpenCode workspace plugin проверяется как отдельный сценарий.

### D11. Установленная миграция и Caveman

Расширяется существующий preflight/snapshot/restore owner. Snapshot строится из
полного write-set и включает desired/actual client sets, `.dev.env`, lock,
manifest, generated files, `client-surface.json`, `mcp/client-managed.json`, новые
client roots и факт исходного отсутствия файлов. Shared внешние store и plugin/
CLI cache не откатываются вместе с проектом. Отменённая или неудачная операция
восстанавливает owned state и выдаёт existing recovery continuation.
Restore проверяет expected post-state каждого затрагиваемого файла/managed
вклада, включая ignored env/MCP и ownership manifests. Если после операции
появилась пользовательская или чужая правка, её нельзя заменить старым snapshot:
сохраняются current/before/candidate и точное owned reconciliation. Это правило
действует и при отказе установки, и при возврате после успешной миграции.

Для Q4 одноразовая миграция имеет ID и per-root receipt в существующем runtime
состоянии миграции. Без receipt старые case-insensitive on значения переходят в
auto; off/auto сохраняются; missing/invalid используют принятый auto default.
Старый CAVEMAN_LEVEL перестаёт влиять, его исходное значение сохраняется в
snapshot/receipt для отката; командный persist удаляется. Session level default
full, userReport и runtime wrapper style сохраняются во всех новых фазах.
Receipt и env меняются одной транзакцией; повтор не переписывает новое on.
Eligibility определяется происхождением/версией scope, а не одним отсутствием
receipt. Новый проект и новая ветка от уже мигрированного baseline сразу получают
отметку принятой политики; скопированное сознательное on не сбрасывается.
Для старого scope receipt пишется также при no-op off/auto/missing. Старые
deferred ветки остаются самостоятельными eligible scopes до их перехода.

Инвентарь областей берётся из явно известных/названных project roots, настроенных
проектов клиента и зарегистрированных worktrees каждого Git common root; ошибки
доступа и неготовые ветки сохраняются в результате, не исчезают из подсчёта.
Это конечный inventory конкретного запуска, без рекурсивного поиска по всему
диску и без нового глобального project registry. Недостающий root — уточнение
факта перед rollout; не основание заявлять «все проекты обновлены».

Clean master принимает rules/client transition; активные worktrees обновляются
через штатный refresh/refresh-lite с собственным env/receipt. Busy/dirty scope
получает deferred outcome, сохранённые данные и точное продолжение. Для запроса
Q4 «все существующие проекты» итог показывает каждую найденную область и
не объявляет завершение при deferred/unreachable scope.

### D12. Квалификация и доставка

Fork Full включает применимые новые deterministic suites из upstream
`.github/workflows/validate-rules.yml`, а не только прежний `tests/**/*.ps1`.
Inventory/reuse identity учитывает tools/tests, renderer, plugins, adapters,
CLI/bundle, Node/Python/docx/lxml versions и runtime flavor. Сохраняются исходные
регрессии; отменённые требования меняются по решению с эквивалентным proof
первоначального дефекта. Windows parity обязательна для используемых портов;
Linux upstream component checks не означают поддержку ITL lifecycle на Linux.
Build prerequisites не становятся обязательной установкой в каждом 1С-проекте.

Структура файлов, обнаружение в свежем host context, tool execution, live MCP и
1С-приёмка — отдельные статусы. Render eval corpus не является его выполнением.
Поддерживаемые client/runtime rows требуют реального подтверждения обещанных
capabilities; фикстуры не создают fake live evidence. Existing publication policy,
включая честный unverified server evidence и запрет direct push, сохраняется.

Ordinary coherent source changes commit/RegisterChange; fork reconstruction from
exact upstream с новым immutable tag остаётся pending. PublishDevelop владеет
квалификацией, продвижением lock и finalization; master не меняется без отдельного
поручения. Перед повторным использованием stage evidence проверяются owner inputs.
Fork mirror origin/main продвигается fast-forward до audited upstream тем же
atomic push, что immutable component branch/tag, с прежним ancestry preflight
(INFRA-003). Это обязанность finalizer, не дополнительный ручной publish route.

### Architecture checkpoint for the implementation

Q1–Q20 фиксируют продуктовые решения; этот раздел задаёт конкретные границы для
review перед apply по docs/package-architecture.md. Новые изменения installed
state — multi-owner client membership, evidence schema, Caveman receipt и pinned
CLI selection — мигрируются существующими host owners. Plugin — вызывающая
сторона, без своей очереди/repair. Source/fork ownership остаётся прежним.

Единственная новая узкая runtime authority — store write batch D7. Минимальный
reproducer: два changes читают один main spec, первый пишет, второй теряет его
добавление. Prompt-only предупреждение и проверка hash без эксклюзивной записи
не закрывают race. Выбран scoped file operation с ограниченным ожиданием и
compare/write/recovery; машинный демон, глобальный lock registry и перенос store
под lifecycle отвергнуты как избыточные. Непересекающиеся записи не блокируются.

Ресурсы: project/client write-set и точные store paths. Windows/privilege/terminal
support не сужается. Cancellation идёт через существующего operation owner;
store cancellation до write сохраняет targets, после частичного write — scoped
recovery D7. Нет бесконечного ожидания и автоматического убийства чужих процессов.
Canary: existing single-client upgrade/rollback; add/remove двух клиентов;
параллельный shared-spec sync; one-off proof→block export. Client hooks ограничены
коротким read-only discovery, дополнительные инструкции on demand. Измеряются
контекст до/после, init/update duration и unchanged-operation overhead по текущей
базовой версии; не вводится always-on network probing.

## Risks / Trade-offs

- Новый root может незаметно потерять вызов ITL-правила → полный semantic map,
  новые consumers и поведенческие сценарии вместо одних anchors.
- Shared files/client model IDs конфликтуют → полный set plan, multi-owner keys,
  per-client capability/model resolution, transactional snapshots.
- Store transport не даёт надёжной atomic file operation → explicit dependent
  limitation и safe serialized/local continuation, без заявлений о distributed lock.
- Больше supported surfaces увеличивает qualification → одна inventory и reuse
  по точным входам; smoke-by-file не подменяет проверку нового контекста.
- Внешние стандарты/клиентские версии меняются → фиксировать фактические corpus,
  runtime/tool identity и exact intake; неизвестное не выдавать за passed.
- Разовое proof можно переоценить → obligation coverage, context identity и единый
  assessment у всех потребителей; старые failures не стираются сменой режима.

## Migration Plan

1. Зафиксировать решение этой постановки и inputs; обновить reconstruction ledger
   по migration-map и итоговым реализованным hashes, не подменять его planning JSON.
2. Реализовать fork rules/tools/adapters и host owners согласованными порциями;
   до включения нового формата подготовить чтение старого и rollback.
3. Квалифицировать isolated installs/updates/failure injection и конкретные client
   capabilities; собрать component/live evidence по acceptance scenarios.
4. Через existing PublishDevelop получить immutable installable candidate.
5. При явно выбранном rollout подготовить конечный inventory проектов/worktrees;
   обновить master, затем ветки штатным refresh, провести one-time Caveman и
   подтвердить каждый scope. Plugin подключается опционально.
6. При сбое restore собственного write-set/ownership; shared store/CLI cache не
   возвращаются вместе с веткой. После успешного обновления откат на прежний формат
   выполняется только через сохранённый совместимый snapshot/helper, не установкой
   старого installer поверх нового multi-client state.

## Open Questions

Новых продуктовых выборов вместо Q1–Q20 не требуется. Неизвестные результаты
qualification (минимальные runtime versions клиентов, live corpus, фактический
inventory rollout) не считаются выполненными и имеют явные задачи/критерии.
Если implementation выявит необходимость изменить owner, расширить authority,
снизить поддержку или отказаться от принятого поведения, это новый checkpoint,
а не разрешение молча упростить требования. Эта постановка не авторизует apply.
