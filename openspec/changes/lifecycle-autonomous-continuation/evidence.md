# Реализация и границы проверки

Source base: `c900620e6569ce4cec39e30abfa3f8ce2c150ce1`; отдельная ветка `codex/lifecycle-autonomous-continuation`. Исходный checkout и его три чужих untracked OpenSpec change не изменялись. PM5, source/branch ИБ и установленные runtime не обновлялись.

## Что проверено

- Red до изменения runtime: 3/3 новых сценария не проходили — untracked Markdown/JSON видимы Git, отсутствует фазовый допуск, не заполнен agent-owned requiredAction. Локальный артефакт: `build/test-results/lifecycle-autonomy-red.xml`.
- Новый owner-тест: 13/13 (`build/test-results/autonomy-final/testResults.xml`); проверяет template/fallback/legacy-template, отсутствие завершающего LF в пользовательском gitignore, идемпотентность, SHA Markdown/JSON, tracked handoff, staged/unstaged/unknown/source/runtime paths, обе стороны Unicode rename, legacy и schema-2 input scopes (включая `./` и корень), незавершённый rebase и ошибочный каталог.
- Тест reviewed commit сохраняет чужие index entries и unstaged bytes для обоих вариантов branch creation. Проверены 48 маршрутов команд: 12 клиентов × master/dev × две команды, включая отдельный native OpenCode renderer и его preflight.
- Для refresh и refresh-lite выполнены реальные Git merge/checkpoint/postcondition/state-переходы через `Invoke-RefreshDevBranchCore`: документация появляется в dependency-фазе, остаётся staged/unstaged/untracked, cursor коммитится отдельно, original target сохраняется, pending merge очищается только после успешного load. Изменение исходника в той же точке блокирует вызов load. Граница Designer/Enterprise/MCP заменена тестовыми адаптерами; это не native-1C proof.
- `ParserDocsBudgets`: 40/40 после измеренного изменения бюджета. `BootstrapUpdate`: 77/77; `WorkflowUpdateRollback`: 52/52. Диагностический `DevBranchLifecycle`: 305/305, включая исходный dirty `branch.txt`, неправильные HEAD/branch/operation/checkpoint и failed verification. Часть исходников уточнялась во время этого длинного диагностического прогона, поэтому его нельзя выдавать за exact-tree qualification: окончательные owner fingerprints проверяет регистрационный Targeted.
- Strict OpenSpec validation и `git diff --check` успешны. Источник окончательной регистрации и Targeted — shared `source-delivery Status` для точного HEAD; результат не дублируется самоссылочным новым коммитом.

Первый регистрационный Targeted на `07dd527d` выявил неверное ожидание количества файлов в `LocalQualityGate`: 57 без Gate 6 превратились в 58 после добавления нового owner-теста. Исходный cohort из 57 и все шесть Gate 6 owners сохранены явными утверждениями; дополнительно требуется новый файл, полный cohort 64 и self-selected cohort 70 при сохранённом историческом 69 без нового файла. Исходные hard limits, runtime watchdogs и обязательный serial tail не изменены. Полная стоимость нового набора 33.218 s учтена в прежней capacity-модели, scheduler weight округлён вверх до 34 s. Та же падавшая проверка прошла отдельно: 1/1 (`build/test-results/autonomy-capacity-green.xml`), red сохранён в `autonomy-capacity-red.xml`. Это исправление ожидания inventory, не ослабление проверки lifecycle. Повторная регистрация проверяет исправленный единый коммит.

## Наблюдаемое продолжение основным агентом

Во временном `build/test-results/lifecycle-autonomy-agent/Проект агента с пробелом` агент вызвал настоящий source helper для `new-dev-branch` и `new-extension-dev-branch`. Он получил `prepare-lifecycle-git:`, точный `task.md`, `blockerRequiresUserDecision=false`, `blockerRetryOriginalCommand=true`; проверил staged/unstaged diff, выполнил path-limited локальный коммит и повторил тот же helper без вопроса пользователю. Fixture-коммиты: `b467436e2c2095ccb49b6ececf52c582387bf1fd` и `74cd15f6af3a318a1cd55a51965a45dcdbf5cc31`.

После Git-подготовки оба вызова дошли до прежней защиты интерактивного подтверждения unsafe-action protection и остановились; `lastProcessId=0`. Подтверждение не подменялось `skip`. Это доказывает наблюдаемую подготовку агентом и сохранность защитного барьера, но не успешное создание веточной базы или полный Windowed-wrapper journey. Raw status-файлы сохранены в `.agent-1c/acceptance-before.json`, `acceptance-after.json`, `extension-before.json`, `extension-after.json` внутри того же fixture.

## Время и контекст

Windows PowerShell `5.1.26100.9711`, один fixture с пробелами и кириллицей, по 5 wall-clock samples на вариант; параллельно шли focused Pester. Это измерение Git-допуска, не полной операции 1С.

| Workload | До, среднее ms | После, среднее ms | Результат |
|---|---:|---:|---|
| clean | 52.41 | 404.98 | оба допускают |
| independent documents | 50.83 | 393.62 | до 5 отказов, после 0 |

Дополнительные ~0.35 s на проверку оплачивают проверку незавершённых Git-операций и фазовых входов; end-to-end overhead native refresh не измерен. Постоянного коллектора нет.

Каждый из четырёх изменённых template вырос на 259 UTF-8 bytes. Реально отрендеренный набор master/dev вырос на 518 bytes для каждого клиента; native OpenCode master — на 496. Например, master Codex 33204 → 33722, dev Codex 50443 → 50961, master OpenCode 42665 → 43161, dev OpenCode 62060 → 62578. Число файлов и discovery metadata не изменились. Явные ceilings увеличены ровно на эти измеренные delta с сохранением прежнего запаса; обязательные инструкции не удалялись. Новая reference — 3616 bytes, читается только при соответствующем Git-блокере. Bytes не являются точным числом токенов. Raw measurements: `build/test-results/lifecycle-autonomy-benchmark/result.json` и `lifecycle-autonomy-context/result.json`.

## Совмещение с более свежей очередью и отчётом CheckConfig

Исходный lifecycle commit `c9002396` был принят прежним регистратором отдельно
от cumulative candidate `96d319e0`. Их объединение конфликтовало в восьми файлах
ещё до добавления исправления отчёта `b0c65e98`. Обе исходные истории сохраняются.
Перенесённые ранее тесты не возвращаются в старые монолитные файлы: lifecycle
inventory и измеренные 33.218 s учтены в текущем `SourceQualityCatalog`, новые
context delta прибавлены к уже сохранённым refresh/result delta.

Проверки refresh сведены к `Get-RefreshGitPathDisposition` / `Assert-RefreshGitInputs`;
прежние имена остаются совместимыми делегатами. Declared input scopes имеют
приоритет перед независимыми Markdown/JSON; executable и неизвестные пути
блокируют продолжение, обе стороны rename сохраняют классификацию. Ограниченный
index-check перед cursor-коммитом сохраняется. Прежнее ожидание отказа для
staged-документа заменено проверкой результата на тех же путях и состояниях:
`Commit-IfChanged` передаёт явный pathspec в `git commit`, а регрессии проверяют
точный состав cursor-коммита, неизменность чужого index entry и unstaged bytes.
Отказы при изменении исходников, неизвестных файлах, executable в docs и
незавершённой Git-операции сохранены; общий failed verification не становится passed.

## Непроверенная приёмка

В этом worktree нет `.dev.env` и настроенного disposable E2E stand. Наличие установленных платформ 1С не определяет разрешённую ИБ и не заменяет stand. Полные native сценарии A3/A5, file/server journeys, native OpenCode API и обнаружение командами свежего клиентского контекста остаются непроверенными. Для них нужен отдельный disposable stand; пользовательский PM5 не использован как тестовый. Задача 3.1 остаётся открытой, change не архивируется. Это ограничение не подменяется Pester, успешным транспортом или регистрацией source candidate.
