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

Путь можно передать через `ITL_AI_RULES_SOURCE_PATH`. `-Offline` пропускает
network compatibility, если локальный источник не указан; такой результат не
квалифицирует release.

`Release` принимает только clean checkout контролируемого fork на единственном
annotated `itl-*` tag, совпадающем с tag и commit в workflow templates. Режим
требует отдельный E2E-стенд и запускается вручную:

```powershell
.\scripts\check.ps1 -Mode Release `
  -AiRulesSource D:\Git\itl_ai_rules_1c `
  -E2EProjectRoot D:\Git\itl-workflow-e2e
```

Стенд настраивается локальным `.agent-1c/release-e2e.json` по примеру
`templates/release-e2e.example.json`. Release повторно запускает проверку
ветки, требует fresh passed `/itl-check`, экспортирует CF/CFE, сверяет SHA256 и
останавливает Vanessa UI MCP и ROCTUP MCP.

Git hooks автоматически не устанавливаются. GitHub Actions сейчас не является
частью гарантий проекта; локальная команда выше — единственный канонический gate.
