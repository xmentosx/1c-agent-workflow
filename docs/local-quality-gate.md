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
qualification v2 в `build/test-results/qualification/full.json`. Три Pester
worker по умолчанию получают детерминированно сбалансированные файлы и собирают
один SHA-проверяемый JUnit. Qualification переносится на merge-коммит только
когда evidence commit является его предком, tree идентичен, а fork, окружение и
полный inventory тестов/gate-скриптов совпадают. `-PesterWorkers 1` оставляет
последовательный диагностический путь.

`Release` сохраняет статическую qualification после Pester, helper, fork,
compatibility и проверки tracked state, поэтому runtime-сбой не повторяет эту
часть. `git diff --check` и `helper -Action help` выполняются всегда;
`check-summary.json` показывает `executed|reused|skipped`, причину и длительность.

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
`templates/release-e2e.example.json`. Дорогая конфигурационная часть состоит ровно из трёх
configuration-проверок: первая metadata load, test-only отрицательный прогон
без Designer/Enterprise и вторая metadata load с восстановленным тестом. Затем
идут fingerprint-стадии config roundtrip, extension smoke, on-demand MCP и
result/cleanup. Checkpoint v2 хранит SHA-проверяемые `.dt`, state, `.dev.env`,
тайминги и попытки. После обрыва `Auto` продолжает текущий релиз, а между
релизами переиспользует capability-стадию только при точном fingerprint.
Финальные passing `/itl-check`, export/SHA и cleanup остаются свежими. Старый
checkpoint v1 один раз мигрируется штатным `Restart`.
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
