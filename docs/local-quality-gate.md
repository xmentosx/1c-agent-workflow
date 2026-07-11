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

`Release` зарезервирован для immutable fork tag и отдельного 1С E2E-стенда. До
их интеграции режим намеренно завершается ошибкой, чтобы не создавать ложную
гарантию готовности релиза.

Git hooks автоматически не устанавливаются. GitHub Actions сейчас не является
частью гарантий проекта; локальная команда выше — единственный канонический gate.

