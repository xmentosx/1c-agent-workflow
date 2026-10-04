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

Не смешивать fork baseline для сохранения смыслов и исходный установленный
workflow. Основная приёмка стартует с опубликованного `master`
`69c0863bfe3bd837543267f122e81a28dcfa5488`, rules
`itl-main-410951e7-r33` / `9309bfbbc9f8d844a21bce55178c2e0d72eaf965`
(remote и lock проверены 2026-09-28). r36 остаётся дополнительным baseline для
проектов develop. Замена только rules tag в новом helper не моделирует этот upgrade.

Текущие точки расширения ITL: `agent-1c.core.ps1` (набор клиентов),
`agent-1c.client-adapters.ps1` (surface/MCP/configuration),
`agent-1c.ai-rules-migration.ps1` (snapshot/preflight/restore),
`agent-1c.verification-modes.ps1` (результат и repair session),
`agent-1c.lifecycle.ps1` (закреплённый fork, bootstrap, refresh),
`scripts/build-ai-rules-release.ps1` и существующий delivery supervisor.
Все `agent-1c.*` здесь — файлы под
`.agents/skills/1c-workflow/scripts/lib/` исходного пакета.

## Goals / Non-Goals

**Goals:** реализовать Q1–Q21 и замечания ревью; сохранить конкретные
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
identity, revisions применимых требований (включая локальные OpenSpec артефакты), артефакты
результата и ограничения. Ключ свежести включает также версию схемы evidence и
применимые требования к достаточности результата. Разрешение нового запуска
отделено от этих требований: invocation override сохраняется как provenance,
его штатное истечение не инвалидирует результат. Изменение зависимого входа инвалидирует соответствующую запись;
Git commit того же содержимого и посторонняя правка не инвалидируют её.
При ручном/runtime доказательстве сохраняются реально наблюдавшиеся шаги и
результат; словесного «я проверил» без evidence недостаточно.

Обновление workflow не инвалидирует proof только из-за нового package commit
или изменения посторонней записи dependency-lock. Вместо хеша всего lock
используются относящиеся к доказательству зависимости/контракты проверяющего кода;
классификация принадлежит существующему verification owner. Изменение checker,
runner или acceptance, влияющее на достоверность, делает соответствующий proof
stale; неизвестная совместимость не объявляется passed. Файловое обновление
не запускает эту перепроверку: необходимость отражается для следующего обычного
assessment/export/close. Новый результат не подделывается переносом старого хеша.

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

#### D4.1. Q23: essential UI и отдельная сохранённая Vanessa

Принято 2026-10-02 при следующей интеграции upstream
`c1fb8e687be5b9d71d5a05c6f5d32cf6a6919dcb`: новым проектам по умолчанию
`UI_TESTING=essential`. После разрешённого размещения изменения в dev/test ИБ
автоматически проверяется важное новое или изменённое поведение, видимое
пользователю. Требуется реальное UI evidence expected/actual на текущем артефакте;
статическая проверка, наличие сценария или общий passed saved-suite результат
не заменяют подтверждения конкретного поведения. Сам режим не разрешает deploy,
загрузку ИБ или автоматический запуск opt-in test-fix loop.

В managed scope новый fork направляет интерактивную проверку через существующий
ITL Vanessa UI route, сохраняя target authorization, provider policy, широкий
no-UI запрет и ownership native launch. Нет разрешённого доступного UI route —
зависимое доказательство остаётся unverified с точным prerequisite; явный запрос
такой проверки делает отсутствие prerequisite блокирующим для этого шага.
Standalone QA интеграция — отдельная возможность, пока не реализованная и не
квалифицированная. `ITL_VANESSA_TESTING` управляет сохранённой Vanessa независимо:
`essential` не включает сохранённые suite и не меняет этот switch. Объём `auto`,
явный запрос для `manual` и запрет `off` сохраняют upstream смысл и приоритет D4.
Однократный переход существующих scopes определён D11/IM7; файловое обновление
не является триггером UI запуска.

Готовность policy подтверждается actual installed rules, а не одним новым helper
или ref: essential должен поддерживаться установленным контрактом. Source-only
проверка setting/receipt не доказывает managed UI execution или новую fork identity.

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

Gate 6 из `verification-gates` / `designer-batch-checks` входит в существующий
ITL load/check/apply owner. Триггеры: применение расширения; загрузка/применение
основной конфигурации с metadata/modules, не покрытыми MCP validators.
Тот же механизм даёт platform fallback Gates 1–3 только при разрешённой работе
с подходящей dev/test ИБ. Он не запускается от обновления файлов workflow.
После snapshot и загрузки текущего артефакта в редактируемую конфигурацию,
до `/UpdateDBCfg`, owner выполняет `/CheckModules` с применимыми runtime modes,
`/CheckCanApplyConfigurationExtensions` для расширения, затем `/CheckConfig`.
Нельзя оставлять объединённый load+apply обход этой границы. Первая ошибка
останавливает apply; существующий owner сохраняет диагностику и восстанавливает
своё состояние, давая продолжение исходной команды. Per-infobase guard,
native process ownership, timeout, Unicode transport и маскирование секретов
остаются общими; upstream пример с прямым Start-Process не становится ITL launcher.

Clean pass требует согласованного process exit, свежего числового `/DumpResult` и
отсутствия errors/warnings в `/Out`. Для основной CF действует уточнение D13;
отсутствующий result, timeout и необъяснённый nonzero
считаются отказом; success-фраза нейтрализует только свой фрагмент, не остаток
строки с предупреждением/ошибкой. Evidence связывает source/artifact и загруженную
конфигурацию, точную ИБ/extension, platform, modes и три сигнала. Повторное
использование возможно только при совпадающих релевантных входах. EDT использует
свой подтверждённый validation/update путь без второго deployment owner.
Нет разрешённой платформы/dev-test ИБ — Gate 6 честно unverified с причиной:
это не новое безусловное запрещение выдачи результата и не разрешение применять
изменения в production либо обходить действующие ITL требования к apply.

### D13. Принятое уточнение Gate 6 и исходная приёмка (2026-10-04)

Пользователь принял три связанные части: вернуть условность Gate 6 при малой
проверенной CF правке; сохранить работу со старыми структурными замечаниями;
устранить текущий блокер на исходном PM5 стенде. Проверка fresh на 356698ca
остановилась на настоящей ошибке компиляции в старом корпусе. После временного
исправления процедура→функция CheckModules прошёл, полный CheckConfig выдал
631 строку (398 «возможно ошибочных», 216 отсутствующих обработчиков, 17 ссылок).
Два изученных metadata-to-handler несоответствия уже присутствовали в initial
48f011. Все 631 не признаны ни дефектами продукта, ни безопасными исключениями.
Это первоначальная диагностика: после неё база и repository binding были
восстановлены, apply и публикация тогда не выполнялись. Последующая реальная
приёмка и согласованное исправление отражаются отдельно в evidence.

Архитектурный checkpoint: invariant — достоверная проверка текущего артефакта
без требования исправлять посторонние старые замечания. Владелец остаётся
существующий ITL load/check/apply helper; controlled fork описывает ту же
политику, но не исполняет второй deployment loop. Предыдущая версия и текущий
артефакт сравниваются только в разрешённом dev/test scope с подтверждённой
source/target/layer identity. Evidence привязан к операции и исходным bytes;
глобальный baseline, whitelist, сервис, новый coordinator и installed migration
не вводятся. Не расширяются ресурсы guard, клиенты, платформы или полномочия.
Cancellation, timeout, snapshot и restoration duty остаются у прежнего owner.

Для малой partial CF загрузки helper учитывает текущую MCP validation coverage
с сохранёнными inputs/raw results, а не boolean «passed». Живой Syntax MCP
предоставляет типовой `syntaxcheck` полного текста вместо файлового метода.
Helper связывает весь strict UTF-8 текст сохранённого модуля с raw request и
фактическими requested/used descriptors провайдера; снимает только один BOM и
сохраняет остальные символы и EOL. Совпадение локального пути без подтверждения
прочитанных сервером bytes недостаточно. Это тот же stateless evidence owner и
прежний `VerificationEvidencePath`, без нового override или deployment owner.
Full/unknown load и
применимость расширения остаются вне этого исключения. MCP исключение сохраняет
snapshot и раздельные editable load/apply; source и исходные evidence bytes
повторно проверяются после load, до первого apply. После подтверждённого точного
DT rollback прежний Designer proof восстанавливается тем же load owner вместе с
cursor, чтобы повтор исходной команды не терял доказанную прежнюю конфигурацию.
Это не passed-кандидат; uncertain/borrowed rollback и потерянный apply ACK не
восстанавливают proof автоматически. Структурная проверка
полной CF сохраняет весь native Out, exit и DumpResult. Только доказанные
неизменившиеся замечания вне scope допускают продолжение с явным legacy
assessment; новые, усилившиеся, внутри scope и неизвестные не разрешаются
автоматически. Такой результат не называется clean Gate 6. Компиляция и
применимость расширений остаются блокирующими. Автоматический blanket WARN для
любого CheckConfig=101 отвергнут; массовый ремонт старой PM5 выходит за scope.

Current corpus acceptance: подтвердить фактические runtime расширения и
происхождение snapshot/export, исправить известную ошибку компиляции только в
owned стенде, затем пройти прежнюю fresh journey, Vanessa, export и refresh.
Сохранить исходные reproducer/failed receipts и equivalent regression новых
findings среди legacy. Смена корпуса или ослабление проверок не является
решением. Runtime cost сравнивается с уже измеренной полной проверкой; каждый
добавленный platform run должен закрывать конкретную evidence gap.

Уточнение фактической проверки: 2026-10-04 guarded read-only export основной CF
содержал те же 19 286 файлов и exact raw SHA, что checkout стенда; guard был
освобождён, HEAD/status не изменены. Реальный before CheckConfig снова дал 631
структурную строку и известную compiler ошибку procedure-return в трёх режимах.
Распознанная прежняя compiler ошибка не переносится в legacy: только настоящий
строгий after CheckModules может подтвердить её устранение в области исправления.
Неполная compiler пара и любая иная неизвестная строка остаются unresolved.
Repository-disconnected status сохраняется отдельно как атрибут read-only
проверки, а не объявляется исправленной ошибкой или чистым platform результатом.
В production неизвестное влияние descriptor/API/dependency изменений означает
отсутствие legacy admission. Одноразовый ремонт owned стенда использует реальный
before export/snapshot и явно разобранные зависимости; фиктивный passed State
для исходной базы запрещён.

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

### D7. Локальный OpenSpec в этом выпуске

Текущий релиз принимает совместимый закреплённый CLI и шесть OpenSpec фаз
для локального `openspec/` workspace старых и новых проектов. CLI остаётся
источником схемы, scaffold, context и путей. Host проверяет выбор до записи:
если CLI разрешил registered, declared или global-default внешний store,
зависимая операция возвращает `OPEN_SPEC_EXTERNAL_STORE_DEFERRED`, сообщает
выбранный root и продолжение через осознанный выбор локального workspace либо
будущий релиз. Ни прямой upstream bundle route, ни host helper не записывают
внешний store и не создают локальную замену молча.

Для локального workspace остаются Git versioning и обычные OpenSpec операции;
новая межпроектная store-write authority, lease и journal в этот релиз не входят.
Полный ранее согласованный D7 и его OS1–OS3 требования перенесены в отдельный
`add-external-openspec-store` по решению пользователя 2026-09-29. Прототип
сохранён отдельно и не считается квалифицированной частью текущего пакета.
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
Граница одной root-транзакции начинается до замены host package и продолжается
через fresh-process post-copy, rules/client migration, commit и terminal outcome.
Для первого перехода с опубликованного r33 старый установленный helper нельзя
считать владельцем этой границы: он исполняет свой pre-copy до загрузки нового
кода. Первый update запускается через узкий source-side handoff, который вызывает
новый `update-workflow` из проверенного exact package checkout с `ProjectRoot`
старой установки и не копирует файлы сам. Это тот же lifecycle/update owner,
не отдельный hotfix updater. Canary обязан подтвердить, что старый helper не
исполняется до snapshot, а прямой старый маршрут не объявляется атомарным.
Pre-copy snapshot/receipt нельзя удалять сразу после копирования: новое поколение
helper должно уметь возобновить/откатить это состояние. Target eligibility и
переход lock планируются до первой замены; добавление OpenSpec dependency в locked
проект выполняется явной миграцией lock без переключения dependencyMode в fresh.
Failure до rules snapshot, после второго клиента, после commit и между roots
имеет точное продолжение. Успешные roots сохраняются; сбой другого root не запускает
глобальный откат уже обновлённых веток. Сводка не объявляет весь rollout завершённым.
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

Q23 добавляет одну миграцию `UI_TESTING` в того же update/snapshot owner:
при будущем update eligible старого root/worktree `manual` переходит в
`essential` один раз; `off`, `auto`, существующий `essential` и независимый
`ITL_VANESSA_TESTING` сохраняются. Per-root receipt фиксирует исходное значение,
результат и завершение даже для no-op и входит в существующий snapshot вместе
с изменением setting. Eligibility привязана к происхождению/версии scope,
а не только отсутствию receipt. Новый проект получает essential default и
принятую политику; новая ветка от уже мигрированного baseline наследует её,
сохраняя сознательный `manual`. Повтор update не сбрасывает позднейший `manual`.
Restore сохраняет согласованность значения и receipt и защищает поздние правки
штатными expected-post-state проверками. Deferred старый root получает переход
при своём последующем update; никакой общий registry или второй recovery owner
не вводится. File-only update не запускает базу, UI, saved Vanessa или другие тесты.

До перехода owner учитывает snapshot pre-update installed-rules support и actual
support после разрешённой установки правил. `SkipAiRules` со старыми rules без
essential оставляет Q23 deferred, значение сохранено, completed receipt не создаётся.
Неизвестный или повреждённый before-proof не означает unsupported: setting и
незавершённость миграции сохраняются. При первом доказанном supporting переходе
missing/empty получает записанный essential, соответствующий effective default
нового upstream; явные invalid/off/auto не переписываются.
Последующая установка supporting rules при том же workflow pin должна выполнить
первый supported переход один раз: равенство workflow commit не заменяет это
доказательство и не считает legacy manual сознательным новым выбором. После
completion поздний manual защищён прежним receipt. Запись сохраняет UTF-8 BOM,
line endings и bytes вне изменяемого значения; source task не меняет live env.
Это требует сохранности формата также у существующего generic env writer и
предшествующего нового Caveman перехода. Уже applying legacy Caveman продолжает
точный recorded target по before/after SHA; completed receipt не переписывается
ради возврата прежде утраченного BOM. Схема receipt и recovery owner сохраняются.

Legacy parent snapshot может не владеть добавленным policy receipt. Новый child
останавливается до policy writes с `UI_TESTING_POLICY_LEGACY_SNAPSHOT` и точным
source-side продолжением `scripts/update-installed-workflow.ps1 -ProjectRoot
<exact-root> -Recovery update` из чистого exact нового checkout. Existing новый
parent атомарно включает добавленные receipt paths в тот же snapshot перед
post-copy и сохраняет original target/recovery. Child не расширяет snapshot под
старым parent: его in-memory state может записать старый список обратно. Новый
recovery executor сам по себе не включает Q23 для recorded old package target,
который не владел policy. Это тот же update owner, без второго recovery runtime.

Инвентарь областей берётся из явно известных/названных project roots, настроенных
проектов клиента и зарегистрированных worktrees каждого Git common root; ошибки
доступа и неготовые ветки сохраняются в результате, не исчезают из подсчёта.
Это конечный inventory конкретного запуска, без рекурсивного поиска по всему
диску и без нового глобального project registry. Недостающий root — уточнение
факта перед rollout; не основание заявлять «все проекты обновлены».

Q21.1: update-workflow обновляет основной проект и workflow во всех доступных
зарегистрированных ветках тем же владельцем и тем же exact candidate. Обновляются
согласованно helper, rules, client surfaces, lock и owned env/MCP contributions;
branch-specific базы, подключения, выбор клиента и пользовательские значения
сохраняются. Это файловая операция: без merge src/cf/src/cfe из master, загрузки
базы и автоматического запуска Vanessa/YAxUnit/Gate 6. Зависимость, требующая
установки в ИБ, получает явный pending preparation и существующее продолжение;
скачивание/выбор pin не выдаётся за выполненную установку в базу.
Незатронутые dirty business files не мешают обновлению. Пользовательская правка
в write-set, недоступный root или действительно работающий с ним процесс дают
точный outcome и продолжение, не перезаписываются и не исчезают из inventory.
Живую работу определяют существующие guards/ownership, не один статус failed
или отсутствие окна терминала. Повтор update-workflow обрабатывает отложенные
roots, завершённые roots идемпотентны; обязательного refresh и фонового ожидателя
нет. Обычный refresh также использует тот же migration owner, когда сам запрошен;
его исходные действия с конфигурацией/базой/проверками сохраняются. Client reload
отражается в report. Для Q4 «все проекты» deferred/unreachable не равны completed.

Q21.2: если процессы остановлены, pending/failed lifecycle или MERGE_HEAD сами по
себе не запрещают обычное обновление workflow. Нет отдельного hotfix installer,
пользовательского выбора «совместимого helper» или обязанности сначала закончить
сломанный шаг. Совместимость сохранённого состояния — обязанность новой версии.
После обновления повтор исходной команды продолжает прежнюю операцию либо входит
в её существующее восстановление. Оно не запускается автоматически как часть
файлового update и не получает права на дополнительные 1С-действия.
Восстановление сначала сопоставляет recorded stage, Git и реально наблюдаемые
owned effects; подтверждённые завершённые шаги не повторяет. Оно продолжает с
доказанной точки либо восстанавливает только незавершённые owned effects для
повтора конкретного шага. Неоднозначность сохраняет evidence и даёт адресное
продолжение; нет произвольного reset, удаления конфликтов или правки JSON агентом.

Update сохраняет цель операции, идентификатор и checkpoint, Git index/stages,
уже разрешённые конфликты и пользовательские изменения. Изменения owned workflow
paths учитывает тот же update/lifecycle owner в переходе baseline; он не делает
случайный merge commit из чужого staging, не сбрасывает merge и не ослабляет
проверки результата до «любой новый HEAD допустим». Если конфликт касается самих
workflow paths, owner сверяет current/before/candidate и сохраняет все варианты
до адресного reconciliation. Частичный cutover helper/templates отменяется как
второй обычный updater: требуемый legacy execution-guard transition становится
этапом той же операции, с существующими guards и сохранением recovery evidence.
Повторная установка уже действующего поколения не чистит живое runtime-состояние.

Цель refresh A отделена от версии его исполнителя. Даже если master стал B,
продолжение переносит исходный бизнес-target A; новый helper читает его состояние.
Rules/bundles восстанавливаются из точного fork и client/render identity
согласованного installed workflow state, включая подтверждённые owned contributions.
Без отдельного workflow update это target из исходной операции; после него — pin
из записанного owned перехода. Например, бизнес-target остаётся A, а отдельно
обновлённый workflow остаётся B. Main — только cache после проверки identity/hashes.
Уже установленный пакет не понижается старым merge: его owned изменения учитываются
как известный переход, а branch env/MCP не копируются из master. Недостающий
immutable input даёт точное получение того же input, не замену на latest.
Hash checks остаются строгими.

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

Главный upgrade canary создаётся исходным опубликованным workflow master из
Context, с его настоящим helper/rules/lock/runtime state. Перед квалификацией
проверяется актуальный remote master: если он изменился, добавляется точный новый
baseline и повторяется затронутая приёмка; старый результат не переименовывается.
Дополнительно проверяются r36→new и представительные ранее поддержанные
legacy upstream/controlled-fork manifest classes (global paths/ownership,
delegated MCP, rollback), без каждого исторического тега и обязательной r36
переустановки. Canary включает pending merge, остановку до/после post-copy,
получение исправления ошибки старого helper, master A→B при resume A и частичный
rollout с живой веткой. Неизменность бизнес-файлов/БД и отсутствие тестовых запусков
проверяются у файлового update; продолжение исходной операции проверяется отдельно.

Ordinary coherent source changes commit/RegisterChange; fork reconstruction from
exact upstream с новым immutable tag остаётся pending. PublishDevelop владеет
квалификацией, продвижением lock и finalization; master не меняется без отдельного
поручения. Перед повторным использованием stage evidence проверяются owner inputs.
Fork mirror origin/main продвигается fast-forward до audited upstream тем же
atomic push, что immutable component branch/tag, с прежним ancestry preflight
(INFRA-003). Это обязанность finalizer, не дополнительный ручной publish route.

### Architecture checkpoint for the implementation

**Обновление границ 2026-09-29.** Принятый ранее механизм D7 для внешнего
OpenSpec store вынесен по прямому решению пользователя в отдельный change
`add-external-openspec-store` и отдельный чат. Этот выпуск квалифицирует только
локальный OpenSpec. Публикация и установка в реальные проекты остаются
отдельными этапами с собственными задачами.

Q1–Q21 фиксируют продуктовые решения; этот раздел задаёт конкретные границы для
принятого checkpoint по docs/package-architecture.md. Новые изменения installed
state — multi-owner client membership, evidence schema, Caveman receipt и pinned
CLI selection — мигрируются существующими host owners. Plugin — вызывающая
сторона, без своей очереди/repair. Source/fork ownership остаётся прежним.

**Accepted Q23 checkpoint, 2026-10-02.** Согласовано расширение существующей
per-root settings migration: legacy `UI_TESTING=manual` → `essential` один раз,
сохранение off/auto, позднего manual и независимого saved Vanessa switch.
Владелец receipt, отмены, completion и recovery — прежний update/snapshot owner;
новый coordinator, persistent framework или отдельная команда не добавляются.
Затронуты только default/policy нового fork и этот exact setting/receipt известных
roots/worktrees; бизнес-источники, ИБ, client membership и чужие настройки не
переходят во владение миграции. Busy/deferred/status и rollback следуют D11/IM2.
UI execution остаётся у ITL managed Vanessa UI route и только после отдельного
разрешённого размещения бизнес-изменения; updater не запускает UI/DB/tests.
Альтернатива сбрасывать manual при каждом update отвергнута: она теряет поздний
выбор пользователя. Сохранение всех legacy manual оставляет старую default
политику вопреки Q23. Canary обязан показать first/no-op/repeat/deferred/rollback,
наследование новой веткой и реальное essential UI evidence, включая unavailable
route без ложного pass (IM7/EV9, 12.1–12.2). Standalone QA остаётся отдельно и
не объявляется реализованной. Старые evidence и checkbox сохраняют свой exact
срез; Q23 и новый c1 fork требуют новой приёмки, исторический 9ec её не доказывает.
Этот checkpoint не меняет готовый source-only Stage A план и production pins.

Конкретная compatibility граница Q23: parent-owned admission новых receipt paths
до post-copy, early legacy-child refusal с source-side Recovery update и сохранение
recorded target; newer executor не применяет Q23 к old target. Acceptance включает
installed-rules support false→true при неизменном workflow pin, SkipAiRules defer,
BOM preservation и прежний original-task recovery. Source-only implementation или
focused proof не закрывают полную c1 integration/UI приёмку либо финальную валидацию
документов; задачи 12.1–12.2 остаются открыты.

**Accepted Q24 c1 OpenCode checkpoint, 2026-10-03.** Пользователь
согласовал upstream сохранение всех четырёх project configs (opencode.json,
opencode.jsonc, .opencode/opencode.json, .opencode/opencode.jsonc), без
удаления/переноса и competing JSON при наличии любого из них. Следующее предложение
об installed ownership-path migration принято отдельным прямым ответом Q24.
Зависимая JSONC runtime реализация разрешена в этих границах; само принятие
не закрывает integration/live приёмку 12.2–12.3.

Причина: ITL сейчас читает/пишет fixed root opencode.json, сериализует весь JSON,
а existing client-managed.json хранит только client/owner names. Эффективный
объединённый MCP config и физическое право изменения файла должны быть разными
представлениями. В предложении existing owner state/receipts связывают вклад с canonical
project-relative filepath и provenance; старый names-only record относится только
к legacy root opencode.json, не присваивает same-name вклад в другом слое.
Новые writes в JSONC/nested config не выводят ownership из одного совпадения имени.

Принят один stateless config-path/JSONC contract у existing clientcfg owner,
без нового coordinator, очереди или recovery records. Read учитывает native merge
project layers; write меняет только доказанные managed fields losslessly, сохраняя
comments, BOM, line endings и bytes вне этих полей. Наличие нескольких файлов само
по себе не collision. Для OpenCode v1.18.11 порядок четырёх файлов в root worktree:
root JSON → root JSONC → nested JSON → nested JSONC; later conflicting fields
override, non-conflicting fields merge. Это версия [primary config loader](https://github.com/anomalyco/opencode/blob/v1.18.11/packages/opencode/src/config/config.ts),
[project paths](https://github.com/anomalyco/opencode/blob/v1.18.11/packages/opencode/src/config/paths.ts)
и [path enumeration](https://github.com/anomalyco/opencode/blob/v1.18.11/packages/core/src/fs-util.ts),
не новая live qualification либо универсальный порядок всех версий.

Final-set preflight и existing snapshot/restore owner фиксируют состояния всех
четырёх candidate paths, включая absence, до первого write. Resolved path inventory
и provenance общие для reader/writer, tracked-config guard, write-set, detach/legacy cleanup,
doctor и Product Docs status. Snapshot capture не превращает user config в
commit-owned файл. Foreign same-name contribution сохраняется; реальный конфликт
идёт через existing collision/reconcile с продолжением исходной операции, без
blanket JSONC/multiple-config barrier. Право записи не расширяется на global/HOME,
custom/inline/managed configs, client membership, permissions или business files.
Внешнее перекрытие project contribution не объявляется effective attachment.

Альтернативы fixed root writer/whole-document serialization и принудительная
консолидация файлов отвергнуты: первая теряет comments/реальную
config selection, вторая меняет штатную layering семантику и user configs.
Acceptance согласована в test-plan.md и ещё не выполнена: same-name foreign, nested JSONC,
absence/path race, last-owner removal, rollback и effective Product Docs.
Реализация следует принятому checkpoint; исторические checkbox/proofs не
повышаются до новой приёмки. Source-only Stage A опубликован в develop
`f5466e6ff98e95bae989a80d65809d1bff2bc31e`; его pins остаются r36.

Source-only e130 registration record сохраняется, но его qualification integrity
pending: P1 deterministic cache alias подменил два requested test files чужими
results. Official 1004 и individual raw totals 1028 не являются новой квалификацией;
Cache owner исправлен отдельным commit `9996b97d402588c6ddc40f96ea274dced8ae728a`: RegisterChange Targeted 88/0/0, 550.943 s, clean tree. Selected test входит в digest самостоятельно, producer path проверяется до reuse. Это новое доказательство cache owner; оно не превращает прежний e130 record в квалификацию Q23.

Store write batch D7 и его cross-project runtime authority не включаются в этот
релиз. В текущем пакете host и managed rules останавливают внешний store до
записи с точным продолжением, а локальные OpenSpec операции используют
закреплённый CLI и прежний Git ownership.

Q21.1 и упрощение Q21.2 согласованы в последующем обсуждении: существующий
update owner распространяет файловую миграцию на зарегистрированные worktrees,
включая остановленные pending operations. Минимальный reproducer — старый helper
не может завершить refresh из-за дефекта, а blanket pending guard не даёт обновить
его. Только ожидание завершения/refresh не решает этот цикл; выбран обычный update
и продолжение/восстановление у прежнего lifecycle owner, без второго repair owner
или специального hotfix runtime. Границы — managed package/client state этих roots
и учёт owned перехода в сохранённой операции; бизнес-источники, внешние specs,
неавторизованные DB-действия и чужие процессы не переходят во владение updater.
Работающий root откладывается без принудительной остановки; ожидание/отмена следуют
существующим guards. Per-root recovery, partial outcome и повтор update описаны D11;
это не распределённая транзакция и не новый service/registry. Guards, поддержка
Windows/terminal и модель прав не ослабляются. Это согласование постановки,
не разрешение apply; подробности внутри этих границ агент прорабатывает сам.

Ресурсы текущего выпуска: project/client write-set и локальные OpenSpec paths.
Windows/privilege/terminal support не сужается. Cancellation идёт через
существующего operation owner. Нет бесконечного ожидания и автоматического
убийства чужих процессов.
Canary: existing single-client upgrade/rollback; add/remove двух клиентов;
локальный new-change/sync/archive; one-off proof→block export. Client hooks ограничены
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
- Обновление останавливается между поколениями helper либо во время чужого merge →
  pre-copy recovery на весь root, сохранение index/checkpoint и приёмка новой
  версией старых остановленных операций; без blanket запрета pending state.

## Migration Plan

1. Зафиксировать решение этой постановки и inputs; обновить reconstruction ledger
   по migration-map и итоговым реализованным hashes, не подменять его planning JSON.
2. Реализовать fork rules/tools/adapters и host owners согласованными порциями;
   до включения нового формата подготовить чтение старого и rollback.
3. Квалифицировать isolated installs/updates/failure injection и конкретные client
   capabilities; собрать component/live evidence по acceptance scenarios.
4. Через existing PublishDevelop получить immutable installable candidate.
5. При явно выбранном rollout подготовить конечный inventory проектов/worktrees;
   обновить master и workflow доступных веток одним update-workflow, провести
   one-time Caveman и подтвердить каждый scope. Отложенные roots обрабатывает
   повтор update-workflow; исходную остановленную операцию продолжают её командой.
   Refresh не обязателен для установки workflow. Plugin подключается опционально.
6. При сбое restore собственного write-set/ownership; shared store/CLI cache не
   возвращаются вместе с веткой. После успешного обновления откат на прежний формат
   выполняется только через сохранённый совместимый snapshot/helper, не установкой
   старого installer поверх нового multi-client state.

## Open Questions

Новых продуктовых выборов вместо Q1–Q21 не требуется. Неизвестные результаты
qualification (минимальные runtime versions клиентов, live corpus, фактический
inventory rollout) не считаются выполненными и имеют явные задачи/критерии.
Если implementation выявит необходимость изменить owner, расширить authority,
снизить поддержку или отказаться от принятого поведения, это новый checkpoint,
а не разрешение молча упростить требования. Эта постановка не авторизует apply.
