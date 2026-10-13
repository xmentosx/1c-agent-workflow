# Версии зависимостей workflow

Штатные версии задаёт `templates/dependency-lock.json` установленного workflow.
Compatibility manifest подтверждает совместимость MCP и их tools/list; отдельного
выбора latest нет. Проектный `.agent-1c/dependency-lock.json` хранит выбранные
артефакты, происхождение и временные исключения. `fresh`, `locked`, `latest` и
`pinned` принимаются как legacy aliases единой политики `workflow`.

Обновление workflow сразу доставляет комплект в master и доступные `itldev/*`.
Занятая ветка остаётся на прежнем комплекте и получает deferred с продолжением.
Refresh конфигурации и подготовка CFE в ИБ имеют собственное состояние: запись
нового lock не подтверждает, что расширение уже загружено в ИБ. После изменения
клиентских MCP contributions выполните reload по сообщению существующего helper.

## Первое обновление

Для перехода со старого helper используйте чистый checkout новой версии и
его source launcher, который входит в новый update owner до копирования файлов:

```powershell
./scripts/update-installed-workflow.ps1 -ProjectRoot 'D:\Проект с пробелом'
```

Обычные pins прежнего установленного workflow переходят автоматически. Custom
pin требует решения до замены файлов. Ошибка `DEPENDENCY_SELECTION_REQUIRED`
указывает ignored-отчёт `.agent-1c/snapshots/dependency-selection.json` с исходным
lock, предложенным комплектом и спорными компонентами. Чужие записи сохраняются.
Подготовьте отдельный UTF-8 JSON; каждый worktree указывается абсолютным путём:

```json
{
  "schemaVersion": 1,
  "worktrees": [
    {
      "worktreePath": "D:\\Проект с пробелом",
      "decisions": { "yaxunit": "workflow" }
    }
  ]
}
```

Повторите ту же операцию с `-DependencySelectionFile '<путь к JSON>'`.
Source launcher принимает тот же параметр. `workflow` означает явное принятие
штатной сборки, включая переход с нестандартного fork правил. Пользовательские
правки управляемых правил по-прежнему требуют reconciliation владельцем.
Неизвестные или повторяющиеся worktreePath отклоняются до записи.

## Временный hotfix

В записи нужного worktree добавьте `hotfixes`: map с устойчивым id исключения.
Каждое исключение содержит `reason` и `dependencies` с полными lock entries
проверенного релиза: источник, точная версия, SHA256/commit или npm integrity.
Не редактируйте установленный lock вручную. Поле `hotfixes` в selection-файле
задаёт весь желаемый набор исключений этого worktree; отсутствующее поле сохраняет
существующий набор. Пустой map явно снимает все его исключения.

Для зависимых компонентов дополнительно нужны:

- ROCTUP: `compatibility.families.roctup` и строка `catalogs.roctup` с полным
  JSON-каталогом, соответствующим version и canonical SHA256 из definition.
- Vanessa: одновременно `vanessaAutomation` и полный `vanessaMcp` с обеими CFE;
  `compatibility.families.vanessa-ui`, каталог `catalogs.vanessa-ui`, matching
  versions и hashes парных артефактов. Проверка фактического tools/list сохраняется.
- MCP facade: `compatibility.facadeVersion` для точного выбранного executable.
- OpenSpec: строки `resources.openSpecCli.packageJson` и `packageLockJson`,
  соответствующие version, integrity и полному `packageLockSha256`.
- Windows-MCP: точные HTTPS wheel `url` и `sha256`; запуск uvx использует этот
  артефакт. Транзитивная заморозка Python/npm здесь не вводится.

Для применения через существующий update без смены workflow используйте:

```powershell
./.agents/skills/1c-workflow/scripts/agent-1c.ps1 `
  -Action update-workflow -DependencyHotfixOnly `
  -DependencySelectionFile 'D:\Решения\hotfix.json'
```

Helper выбирает точный installed workflow commit. При source override он обязан
совпадать; иначе исправьте checkout либо выполните обычный update без этого флага.
Отсутствующий installed commit требует сначала завершить обычное обновление.
Все изменения входят в существующий per-root snapshot и recovery. Неудача
обновления сохраняет прежний набор; rollback возвращает прежние исключения.
Resume использует решение, сохранённое в transaction receipt, даже если входной
JSON после начала операции был изменён.

Успешный update снимает исключение, если workflow содержит ту же полную сборку
с тем же MCP-каталогом либо более новую сопоставимую сборку той же линии.
Более новый hotfix сохраняется. Равный номер с другими bytes/каталогом или
несопоставимый fork требует решения по id исключения: `workflow` либо `hotfix`.
Некорректный комплект исправьте или снимите через тот же selection-файл и повторите
исходную операцию. Независимые компоненты и общий status/help остаются доступны.

```powershell
./.agents/skills/1c-workflow/scripts/agent-1c.ps1 -Action status -Mode dependencies
```

Этот отчёт показывает штатную и выбранную идентичность и причину исключения.
Кеши артефактов различают версии и hashes, поэтому другой worktree продолжает
использовать свою сборку. Локальный vibecoding1c пока сохраняет прежнюю политику;
его runtime, порты и индексы требуют отдельной миграции и изоляции версий.
