# Локальная проверка workflow

Действующий quality gate запускается из корня репозитория одной командой:

```powershell
.\scripts\check.ps1
```

По умолчанию используется `Full`: все Pester-тесты, smoke-проверка helper и
compatibility-проверка `ai_rules_1c`. Результаты сохраняются в
`build/test-results/local` и не коммитятся.

Для короткого цикла разработки используйте:

```powershell
.\scripts\check.ps1 -Mode Fast
```

Для совместной проверки с локальным fork:

```powershell
.\scripts\check.ps1 -AiRulesSource D:\Git\itl_ai_rules_1c
```

Успешный `Full` на clean workflow commit и точном clean/tagged fork сохраняет
`build/test-results/qualification/full.json`. В нём фиксируются commit/tree
обоих репозиториев, полный список и SHA256 Pester-файлов и gate-скриптов,
окружение, JUnit и qualification fork. Повторный `Full` или последующий
`Release` переиспользует только полностью совпадающее доказательство; изменение
любого файла, SHA, tree, fork commit, JUnit или dirty worktree заставляет
выполнить соответствующие стадии заново. `git diff --check` и быстрый запуск
`helper -Action help` не переиспользуются никогда, а Release E2E всегда
выполняется на стенде. `check-summary.json` для каждой стадии показывает
`executed|reused|skipped`, причину и длительность.

Путь можно передать через `ITL_AI_RULES_SOURCE_PATH`. `-Offline` пропускает
network compatibility, если локальный источник не указан; такой результат не
квалифицирует release.

`Release` принимает только clean checkout контролируемого fork на единственном
annotated `itl-*` tag, совпадающем с tag и commit в workflow templates. Режим
требует отдельный E2E-стенд и запускается вручную:

```powershell
.\scripts\check.ps1 -Mode Release `
  -AiRulesSource D:\Git\itl_ai_rules_1c `
  -E2EProjectRoot D:\Git\itl-workflow-e2e-pm5
```

Стенд настраивается локальным `.agent-1c/release-e2e.json` по примеру
`templates/release-e2e.example.json`. Дорогая часть состоит ровно из трёх
configuration-проверок: первая metadata load, test-only отрицательный прогон
без Designer/Enterprise и вторая metadata load с восстановленным тестом. Затем
идут независимые checkpoint-стадии config roundtrip, extension smoke и
result/cleanup. Перед ними сохраняются SHA-проверяемые `.dt`, state и `.dev.env`.
После обрыва повторите ту же команду: режим
`-ReleaseResumeMode Auto` продолжит с первой незавершённой стадии только при
точном совпадении workflow/fork/helper/project config/HEAD и снимков. Код
`RELEASE_E2E_RESUME_STATE_MISMATCH` запрещает небезопасное продолжение.
Для осознанного возврата к зафиксированному baseline используйте
`-ReleaseResumeMode Restart`; произвольное удаление checkpoint или ручная
правка state не являются штатным восстановлением.

Release требует fresh passed `/itl-check`, экспортирует CF/CFE, сверяет SHA256
и останавливает Vanessa UI MCP и ROCTUP MCP. Extension smoke создаёт Empty-
расширение, проверяет повторные form/template операции, сохранность
пользовательских `Form.xml`, `Module.bsl`, template content и явные
Synonym/default/`SetMainSKD`, открывает форму в реальном TestClient, повторно
загружает CFE и восстанавливает базу из snapshot.

Git hooks автоматически не устанавливаются. GitHub Actions сейчас не является
частью гарантий проекта; локальная команда выше — единственный канонический gate.
