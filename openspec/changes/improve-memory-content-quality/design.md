# Design

## Context

Мотивация — в [proposal.md](proposal.md), цифры — в
[исходном срезе](evidence/baseline-2026-11-14.md). Текущее устройство после
`improve-scoped-memory-adoption` и r58:

- Ядро правила (~2,3 КБ) — раздел `## Scoped project memory` в
  `templates/ai-rules-overlay/AGENTS.md`, попадает в корень форка как
  ITL-приложение. Подробности — блок `ITL-SCOPED-MEMORY-V1` в
  `content/rules/project-memory.md` форка (по запросу).
- Описания `remember`, `recall`, `memory_status`, `retire_note` — в
  `scripts/cognee-memory-mcp.ps1`.
- Владелец поведения памяти — `scripts/lib/agent-1c.memory.ps1`:
  - `Get-ItlMemoryScopes` разрешает label и для product-записи требует ровно одну
    применимую область с этим home;
  - `Invoke-ItlMemoryRemember` (около стр. 640–700) проверяет `standing`,
    доработку проекта (`MEMORY_PROJECT_CANDIDATE`) и сохраняет pending до проверок
    назначения;
  - `Get-ItlMemoryRecallCards` чередует группы датасетов по рангу и ставит
    `partial`, когда набрано `top_k`;
  - `memory_status` строит `destinations` с отдельными строками product и
    `writeGuidance`;
  - `Get-ItlMemoryUsageLine` даёт информационную строку для `/itl-check`
    (вызов в `agent-1c.lifecycle.ps1`) только из журнала вызовов.
- Исходники заметок хранятся локально в `memory/source/<workspaceId>/` с
  `cycleId`, `title`, `datasetName`; журнал вызовов текста не содержит.
- `/api/v1/recall` вызывается с `top_k=24`; используемые поля ответа —
  `dataset_id`, `data_id`, `metadata`, `source`, `status`. Есть ли в ответе
  оценка сходства, в evidence не зафиксировано.

## Goals / Non-Goals

**Goals:**
- Сократить запись хода работы и длинных журналов, сохраняя переносимые уроки
  на уровне проекта, продукта или организации.
- Убрать из выдачи `recall` карточки, которые попадают туда только из-за
  чередования групп.
- Упростить выбор назначения, не меняя серверную структуру и установленное
  состояние.

**Non-Goals:**
- Автоматическое повышение или консолидация заметок.
- Семантическая проверка содержимого заметки в адаптере, кроме длины.
- Изменение сервера Cognee, новых уровней, привязки, журнала или pending.
- Удаление или перенос workspace-датасетов и старых заметок.

## Decisions

### D1. Граница «знание или ход работы» задаётся правилом, длина — адаптером

Правило и описание `remember` перечисляют, чего не сохранять, и направляют
рабочее состояние в `checkpoint`. Адаптер проверяет только длину `data` (600
символов) — единственный признак журнала, который проверяется надёжно и без
ложных срабатываний на содержательные заметки.

Отказ возвращается до отправки, тем же путём, что `MEMORY_STANDING_TOO_LONG`:
pending-исходник уже сохранён, повтор с тем же `note_id` заменяет черновик (D7
change `improve-scoped-memory-adoption`). Код — `MEMORY_NOTE_TOO_LONG`, текст
продолжения: «сократи до правила, причины и условий; доказательства передай
ссылками в evidence; повтори remember с тем же note_id».

Политика блокировок соблюдена: отказ касается одной записи, данные не теряются,
продолжение выполнимо агентом, приёмка — успешный повтор.

Рассмотрено: только правило — не сработало в срезе; эвристики по SHA и номерам
строк — ложные срабатывания на заметки о версиях и объектах.

### D2. Task-уровень остаётся, но с узким назначением

Task нужен для разрешений пользователя на цикл, когда OpenSpec не используется и
другого места нет. Меняются только тексты: ядро, справочник, описание `remember`,
пример в `scoped-memory.md`. Проверки содержимого task-записей в адаптере нет.

Рассмотрено: убрать task из вариантов записи — теряется место для разрешений в
прямом режиме.

### D3. Маршрутизация «проект → product» в адаптере

Агент передаёт label проекта и, для поведения базового продукта,
`applicability.knowledgeArea`. В `Invoke-ItlMemoryRemember` до сохранения попытки
адаптер выбирает целевой датасет:

1. Если у pending есть попытка или у `note_id` есть квитанция, датасет берётся из
   неё (обновление и повтор не меняют назначение; `MEMORY_DESTINATION_LOCKED`
   сохраняется).
2. Иначе, если указан label проекта, область задана, применима, у неё ровно один
   home среди допущенных product-датасетов, статус не `candidate`, а проект не
   доработан или `independentOfCustomization=true` — product home.
3. Иначе — проект.

Ответ содержит `routedTo` (label) и `routeReason`
(`product-home`, `no-area`, `area-not-applicable`, `ambiguous-home`,
`customization-unproven`, `candidate`, `existing-note`). Явный product-label
работает по прежним правилам, включая `MEMORY_PROJECT_CANDIDATE`.

Pending сохраняет исходное намерение (label проекта); попытка фиксирует
фактический `datasetId`, поэтому сверка по точному ID не меняется.

Рассмотрено: один датасет с зависимостями проектов — повторяет граф
`product-relations` на уровне проектов и даёт второго владельца применимости;
явный выбор product агентом — в срезе агент не различает уровни.

### D4. Destinations для агента

`memory_status.destinations` для записи: проект (со списком маршрутизируемых
областей вместо отдельных product-строк), организация, workplace, host, task.
Workspace остаётся в составе чтения и в `readState`, но не в списке записи;
явный workspace-label принимается. `writeGuidance` переписывается под D3.

### D5. Порог релевантности внутри групп

Чередование групп сохраняется (защита из a17172fc). До формирования очереди
кандидатов адаптер отбрасывает в каждой группе кандидатов ниже порога.

Источник релевантности определяется квалификацией (задача 1.1):

- **Основной путь:** оценка сходства из ответа `/api/v1/recall` для `CHUNKS` и
  `CHUNKS_LEXICAL`. Порог — одно значение на `search_type` в
  `assets/scoped-memory-policy.json` со ссылкой на evidence калибровки.
- **Запасной путь, если оценки нет:** доля значимых терминов запроса (без
  служебных слов, нормализованных по регистру и `ё`), найденных в тексте
  фрагмента; порог — тоже в политике. Это хуже семантической оценки, но убирает
  карточки без общих терминов.

Калибровка: 72 реальных запроса из сессий PM5 повторяются только на чтение;
пары «запрос — кандидат» размечаются как релевантные или нет; порог выбирается
так, чтобы доля повторяющейся заметки была не больше 25% при сохранении
релевантных карточек, отмеченных при разметке. Тексты запросов в evidence не
переносятся, только счётчики и идентификаторы заметок.

Рассмотрено: глобальная сортировка по сходству — большой датасет снова может
вытеснить маленькие.

### D6. `partial` и обрезка

`Get-ItlMemoryRecallCards` перестаёт ставить `partial` при `cards >= top_k` и
при `chunks > candidates` (это предел кандидатов). Вместо этого ответ получает
`truncated=true`. `partial` остаётся для сбоев групп, срока, неприменимых и
непрочитанных оригиналов. Журнал вызовов пишет `readOutcome` по новой метке.

### D7. Частота recall — только тексты

Ядро и описание `recall`: один раз на тему; повторно — при новой области или
объекте, недостающем контексте или по правилу восстановления после сбоя. Фраза
«recall afresh in the next eligible turn» удаляется из ядра, а в
`project-memory` остаётся только как часть правила восстановления после сбоя.
Принудительной проверки частоты нет; приёмка — по пилоту.

### D8. Строка заметок цикла в `/itl-check`

`Get-ItlMemoryUsageLine` дополнительно читает локальные исходники
`memory/source/<workspaceId>/` с текущим `cycleId` и выводит до 8 заголовков
(`title` или начало факта до 60 символов) с уровнем, затем «ещё N». Без сети и
без новых файлов. Ошибка чтения исходника пропускает его и не меняет результат
проверки.

### D9. Уточнения требований незаархивированных change

При sync требования ниже оформляются как MODIFIED в том change, который будет в
`openspec/specs` первым:

- `improve-scoped-memory-adoption`, «Обязательное ядро памяти всегда в
  контексте»: выбор назначения — по D3/D4, task — по D2, повторный recall — по
  D7, формат и предел — по D1.
- `improve-scoped-memory-adoption`, «Компактный список destinations»:
  product-строки свёрнуты в строку проекта (D4).
- `improve-scoped-memory-adoption`, «Сводка без блокировки»: добавлены заголовки
  заметок цикла (D8).
- `add-scoped-cognee-memory`: требование выбора самой узкой достаточной области
  заменяется вариантами D4 с маршрутизацией D3.

### Черновик ядра правила (ITL-приложение)

Целевой размер — не больше текущего раздела. Окончательный текст измеряется в
задаче 4.1.

```markdown
## Scoped project memory

Applies only when the `memory_status` tool is available; `project-memory`
holds the details on demand.

- Call `memory_status` once at session start and after a `contextChanged`
  notice. Keep task progress in its `checkpoint`, never in notes.
- `recall` once per topic before designing a 1C change; again only for a new
  area or object, missing context or a transient failure.
- `remember` in the same turn after a user correction, a rejected approach, a
  standing condition or a confirmed lesson that changes work in another
  session or branch. Never save what code, OpenSpec, evidence, Git or test
  results hold: progress, runs, SHAs, line numbers, statuses.
- One fact, at most 600 characters: rule, why, when, conditions and versions;
  evidence by reference. A user statement is `verified`, an "always/never"
  rule `standing`, evidence `{source:"user", reference:"chat <date>"}`.
- Destination: the project; add `applicability.knowledgeArea` for base-product
  behavior and it is routed to the product home. Organization only for
  knowledge true across projects and products, never client, project or
  configuration data; `standing` there only at the user's word. Workplace for
  your practices, `host` for machine facts, task only for the user's decisions
  for this cycle.
- Update a note that contradicts checked sources in place (`note_id` +
  `data_id`) or `retire_note` it in the same turn; another project's
  organization note only after the user confirms.
- Verify current branch code before claiming a recalled fix is present.
- End a 1C task report with `Memory: recall N, saved N, updated N, retired N`,
  naming any `standing` note.
- Project corrections stay in project memory. Shared `1c-templates-mcp`
  `remember` is only for verified cross-project knowledge; `templatesearch`
  remains available for code templates. Do not turn on a new shared-memory
  provider implicitly.
```

## Architecture checkpoint

| Пункт | Содержание |
|---|---|
| Инвариант | Выбор датасета записи, предел длины, порог и метка покрытия поиска |
| Владелец | `agent-1c.memory.ps1` (единственный владелец поведения памяти); тексты — ITL-приложение и блок `ITL-SCOPED-MEMORY-V1` форка |
| Почему нужен checkpoint | Меняется always-on правило агента и описания инструментов; меняется наблюдаемое поведение `remember` (новый отказ) |
| Новое состояние, блокировки, координаторы | Нет. Порог — поле существующей политики. Pending, квитанции, привязка, журнал — без новых полей |
| Затронуто | Описания и схема ответов `remember`, `recall`, `memory_status`; строка `/itl-check`; ядро и `project-memory`; все клиенты, получающие правила форка |
| Не затронуто | Сервер Cognee, lifecycle и reset, реестр и `product-relations`, корневой `memory.md`, `1c-templates-mcp`, верификация и поставка |
| Контекст агента | Ядро — не больше текущего раздела; описания инструментов — не больше +0,3 КБ; рост сверх этого требует отдельного согласования |
| Совместимость | Старые правила с явным product-label работают; старые длинные заметки читаются. Агенты на старых правилах получат отказ по длине с продолжением |
| Canary | Одна копия PM5 после `update-workflow`: длинная запись отклоняется и проходит после сокращения; запись с областью уходит в product; `recall` по чужой теме не возвращает заметку о Редакторе планов |
| Откат | Возврат ITL-коммита и пинов форка; состояние и данные не мигрируют |
| Статус | Одобрен пользователем 2026-11-14 |

## Risks / Trade-offs

- [Порог отсечёт полезную заметку] → калибровка на реальных запросах с разметкой
  до выбора значения; порог в политике меняется без смены кода.
- [Нет оценки сходства в ответе Cognee] → запасной лексический порог (D5);
  результат квалификации фиксируется в evidence до реализации.
- [Агент начнёт дробить журнал на несколько коротких заметок] → пилот считает
  `remember` на сессию и долю task; при росте — правка формулировок, без новых
  проверок.
- [Ошибочная маршрутизация в product] → только при однозначном home и
  подтверждённой независимости; ответ называет назначение и причину; ошибочная
  заметка снимается `retire_note`.
- [Предел 600 символов мал для сложного факта] → evidence и `applicability`
  передаются отдельными полями и в предел не входят; при систематических отказах
  по содержательным заметкам предел пересматривается по пилоту.

## Migration Plan

1. ITL-часть и новый релиз форка поставляются обычным порядком;
   `update-workflow` обновляет копии PM5.
2. Canary на одной копии (см. checkpoint), затем остальные копии.
3. Разовый разбор накопленных заметок PM5 (задача 7.1): список готовит агент,
   утверждает пользователь, запись — штатными `remember` и `retire_note`.
4. Пилот по [test-plan.md](test-plan.md).
5. Откат: вернуть ITL-коммит и пины; заметки, записанные по новым правилам,
   остаются валидными.

## Open Questions

- Значения порогов для `CHUNKS` и `CHUNKS_LEXICAL` и их источник (оценка Cognee
  или лексический запасной путь) — определяются задачами 1.1–1.2 и не меняют
  спецификацию.
