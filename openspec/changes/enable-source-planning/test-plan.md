## Evidence contract

Критерии относятся к этой доработке. Формат OpenSpec проверяет структуру, а не качество решения. Ретроспективный разбор не заменяет исполнение теста. Успешная регистрация не означает публикацию. Исходные проверки запускаются по `docs/local-quality-gate.md`, без изменения их владельцев.

| ID | Сценарий и ожидаемый результат | Доказательство | Результат реализации |
|---|---|---|---|
| A1 | Ясный локальный баг: доступен прямой путь без навязанного grill/OpenSpec | Изолированный read-only запрос к Codex с фиксацией ответа и контекста | Passed: предложен только diff замены слова, без формального процесса и файловых изменений |
| A2 | Неясная причина сбоя обновления: агент ищет факты, формулирует неопределённость, предлагает маршрут и ждёт выбора | Поведенческий запрос; отсутствие реализации или самовольного OpenSpec | Passed: исследованы владельцы update/guard, гипотезы отделены от доказанной причины; предложены grill/explore на выбор |
| A3 | Выбранный grill и подтверждённые ответы переходят в OpenSpec без повторного интервью; отражены пять элементов постановки | Артефакты и трасса ответа без предыдущего чата | Passed: свежий exec создал 4/4 артефакта add-registration-status-guide, сохранил согласованные границы/альтернативу, без повторных вопросов; strict validation exit=0, реализация не начата |
| A4 | Свежий Codex видит обе grill точки входа и четыре OpenSpec навыка, их зависимости доступны | Наблюдение discovery/явного вызова в новом контексте конкретного checkout | Passed: новый app-server вернул 8/8 source навыков enabled, errors=[]; свежий exec явно прочитал grill-me → grilling и провёл первый раунд |
| A5 | Source-only файлы не попадают в managed-copy; нет новых личных настроек или 1С preflight для source | Фактический inventory владельца копирования и focused regression существующего owner; проверка policy и ссылок | Passed: 71 BootstrapUpdate и 39 ParserDocsBudgets; импортированные тексты совпадают с источниками |
| A6 | CLI отсутствует: понятный prerequisite, файлы сохранены, нет ложного validate-pass или автоматической установки | Изолированная проверка инструкции/маршрута с недоступным CLI | Passed: openspec недоступен, агент не создал change и не объявил валидацию; установку не выполнял |
| A7 | Простой достаточный дизайн выявляет проблему конечного результата исторического update | Ретроспектива ниже с code/test anchors и границами вывода | Выполнен анализ; это не live replay |
| A8 | Пилот имеет валидные артефакты; новая metadata не скрывает обязательные source правила | `openspec validate enable-source-planning --strict`; измерение UTF-8 bytes router и skill metadata до/после | Passed: strict validation; root router +305 bytes; name/description восьми source навыков 1529 bytes; metadata explicit-only |

На этапе реализации результаты дополняются командами/контекстом, наблюдениями и ограничениями; статический pass не подменяет поведенческий. При отсутствии свежей сессии A4 остаётся непроверенным. Из этого чата новый пользовательский чат автоматически не создаётся.

Проверка постановки 2026-09-26, CLI 1.4.1: `validate --strict` — valid; `instructions apply --json` — ready, 12 задач, 0 завершено. Файлы читаются как строгий UTF-8 и не содержат trailing whitespace. `status.isComplete=true` означает наличие всех четырёх артефактов схемы; это не завершённая реализация. Source gates и живые обновления на этапе постановки не запускались.

## Implementation evidence, 2026-09-26

Все поведенческие проверки выполняются в новых `codex exec --ephemeral` с Codex CLI `0.158.0-alpha.2.1`, без истории этого чата и без указания ожидаемого ответа. A1/A2/A4 ограничены чтением source checkout; A3 использует отдельный disposable Git fixture и разрешает только подготовку постановки; A6 — отдельный fixture с недоступным CLI. Модель не переопределялась. Это конечная выборка поведения, не гарантия любого будущего ответа.

Локальные сырые результаты находятся в игнорируемом `build/source-planning-validation`: `discovery.json`, `a1/a2/a4/a6-*.jsonl`, соответствующие `*-answer.md`, изолированные fixtures. Discovery получен реальными `initialize → initialized → skills/list(forceReload=true)` нового app-server. YAML проверен парсером; реальные ссылки вне примеров разрешаются локально. Проверено совпадение импортированных grill Markdown с pinned fork и OpenSpec Markdown с результатом генератора 1.4.1.

A3: первоначальная sandbox-сессия не смогла прочитать глобальный npm launcher, сохранила частичные артефакты без ложного CLI-pass и достигла лимита тестового процесса. Она не засчитана. Для положительного сценария новый fixture получил локальную копию того же Node/OpenSpec 1.4.1 и process-local PATH; workspace-write sandbox сохранён, глобальные настройки не менялись. В `a3-cli-events.jsonl` зафиксирован настоящий `openspec validate add-registration-status-guide --type change --strict --no-interactive`, exit=0. Проверены цель/границы/альтернатива/обязанности/приёмка в артефактах; отсутствуют документ реализации и commit. CLI должен быть доступен именно среде Codex, а не только внешнему терминалу.

Утилита skill-creator `quick_validate.py` принимает четыре grill навыка, но отвергает стандартное upstream поле OpenSpec `compatibility`: её allowlist уже, чем фактический загрузчик Codex. Поле не удалялось ради прохождения утилиты; все восемь навыков приняты реальным `skills/list` без ошибок.

При проверке source tests исправлены две неверные предпосылки тестов: inventory в ParserDocsBudgets и LocalQualityGate теперь различает installed и source-only навыки, а regex описания допускает апостроф внутри корректного plain YAML scalar (`project's`). Второй inventory обнаружен первым Targeted: ожидание только installed навыков больше не соответствует согласованной source-only поверхности; точное сравнение списка сохранено. Проверка allowlist вынесена в собственный Git fixture; существующий reexec fixture и его исходные assertions сохранены. Bootstrap regression проверяет фактический результат installer, список копирования update, запрет source-only путей и сохранение явного fork ownership одноимённого установленного навыка.

Focused evidence: `build/test-results/source-planning-repair/pester-shards/worker-1.xml` — BootstrapUpdate 71/0/0; `build/test-results/source-planning-parser/focused.xml` — ParserDocsBudgets 39/0/0. Регистрация, её точный head и итоговый Targeted принадлежат `source-delivery Status` в общем Git ledger, а не checkbox внутри уже зарегистрированного commit. Это уточнение убрало самоссылочную задачу доставки; её обязательность сохранена в `tasks.md`.

На рабочем дереве до/после маршрутизации корневой AGENTS: 9662 → 9967 UTF-8 bytes, 2416 → 2492 по proxy `ceil(bytes/4)`; это не точные токены. Новые name/description: 1529 bytes (383 по той же proxy), не включая filesystem paths/UI metadata. Инструкции навыков загружаются по требованию; immutable тексты не сокращались ради бюджета. Установленная поверхность проектов не расширена.

## Retrospective: blocked ai_rules migration reported as update success

**Происхождение.** Исторический fix `60e15346562c4c1497e73294c383c6932ca7ef17` от 2026-07-28, `Fail closed on blocked ai-rules migration`. Текущий код и тесты проверены чтением в базе пилота; старые численные результаты тестов не переносятся на текущий checkout.

**Сценарий.** Пользователь обновляет установленный workflow, включая managed rules. Изменения `USER-RULES.md` могут быть внесены как пользователем, так и самим ITL overlay. В историческом пути миграция могла вернуть `migrated=false`, `suppressRegularUpdate=true`, `status=user-modified`, а внешний update не превращал это в неуспех всей операции.

**Постановка, которая обнаруживает границу.** Успех означает, что требуемая миграция действительно завершена. Нельзя объявлять обновление завершённым после блокировки managed migration. Подлинные правки пользователя сохраняются. ITL-only overlay можно классифицировать как managed drift лишь по доказанному совпадению оставшегося содержимого с baseline. Исключение custom repository — отдельный предусмотренный контракт, а не общий обход защиты.

**Достаточное решение и альтернатива.** Владелец внешней операции обязан обработать результат миграции; владелец классификации устанавливает, какие байты изменил ITL. Новая очередь, повторный координатор или безусловное исключение `USER-RULES.md` не нужны. Последнее упрощает прохождение обновления ценой потери защиты настоящих правок и поэтому неприемлемо.

**Текущие anchors.**

- `.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1`, вызов `Assert-AiRulesBaselineMigrationResult -Migration $migration` в пути update после `Invoke-AiRulesBaselineMigration`.
- `.agents/skills/1c-workflow/scripts/lib/agent-1c.ai-rules-migration.ps1`, `Assert-AiRulesBaselineMigrationResult`: категория `ai-rules-migration-blocked`, actionable recovery report и исключение для custom repository.
- `tests/pester/AiRulesMigration.Tests.ps1`: `clears a USER-RULES marker when the ITL overlay is the only change from installedHash`; `keeps USER-RULES blocking when content outside the ITL overlay changed`; `reports blocking files and makes a blocked managed migration fail closed`.
- `.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1`, `Get-WorkflowPackageCopyDirectoryPaths`: explicit список исходных каталогов, используемый для проверки A5.

**Что установлено.** Эти критерии различают успех внутреннего шага и конечный результат update, а также заставляют проверить альтернативу, которая ослабляет защиту. Текущий код обрабатывает результат миграции, а названные тесты описывают обе стороны классификации и ошибку при блокировке.

**Что не установлено.** Здесь не воспроизводилось живое обновление, не запускались исторические/текущие gates, не доказывалось, что весь release path защищён от удаления вызова проверки результата. По одному чтению helper-тестов нельзя объявлять сквозное покрытие ни достаточным, ни отсутствующим.

**Отдельный возможный follow-up.** Аудит негативного сценария полной команды update: искусственно заблокированная managed migration должна дать неуспех внешней операции, сохранить пользовательские файлы и показать recovery action. Сначала установить существующее покрытие; изменять gate только при подтверждённом пробеле. Этот аудит и исправление не входят в реализацию пилота.
