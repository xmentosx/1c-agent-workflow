# Аудит ParserDocsBudgets: 40 исходных случаев

База: `fa0e3c91694112c1da3ecda7209a8a81ea828264`, файл
`tests/pester/ParserDocsBudgets.Tests.ps1`, Git blob
`48015d7452cee5a706021b465de15594ba1c0fa2`.
Тот же blob находился в принятом runtime commit `3d2658d5`.
Индивидуальные решения, original line/name/body SHA, риски, входы, уровень,
ресурсы и ограничения: [ledger](parser-docs-review.csv).

Все 40 тел просмотрены; это завершение предметного просмотра одного файла,
а не аудита всех 2814 исходных определений. История flakes отдельных случаев
не исследована и обозначена как неизвестная. Документационные assertions
не объявляются доказательством выполнения guard, live 1С или публикации.

## Доказанный дубль

В исходном случае `requires an explicit owned database access handoff before
incompatible phases` две соседние строки проверяют один `$userRules` тем же
regex `Let bounded database executions finish or cancel them through their
exact owner`. Между ними нет изменения значения или matcher. Их множества
отказа совпадают. Удаляется только второе assertion; первое и все остальные
ограничения foreign owner, retained phase и нормального ожидания сохраняются.
Количество случаев не меняется.

## Ложный успех проверки ссылок

Существующий `agent guidance references stay resolvable` проверял наличие
названий тем в `workflow.md`, но не наличие самих файлов. Другой случай
проверяет Markdown-ссылки README и human guides; backtick-оглавление skill
не входит ни в его синтаксис, ни во входы.

В отдельном ignored fixture `Guidance Проект с пробелом` использованы реальные
`workflow.md` и USER-RULES. Из шести индексированных topic files отсутствовал
`mcp.md`. Выполнено именно извлечённое исходное тело случая:

- Исходная проверка прошла при отсутствующем `mcp.md`.
- Дополнение к тому же случаю отвергло отсутствие с сообщением
  `workflow.md references missing topic mcp.md`.
- После восстановления файла дополненное тело прошло.

Теперь тот же существующий случай извлекает все реальные topic references,
требует непустой индекс и существование каждого target как файла. Старые
assertions сохранены. Нового runtime barrier или отдельного Pester case нет.
Имена не зафиксированы вторым списком: authoritative owner остаётся оглавление.
Продолжение при отказе — восстановить названный файл или исправить неверную
ссылку в оглавлении, затем повторить принадлежащую проверку.

Canary receipt и proposed-body сохранены в ignored
`build/redesign-source-delivery/runtime-proof/guidance-link-review.json` и
`guidance-link-body.txt`. Приёмка внесённой проверки принадлежит одной
регистрации этой связной единицы; standalone canary её не заменяет.

## Сохранённые случаи и незакрытые вопросы

Проверки публичных команд, skill identifiers, 24 rendered client surfaces
и MCP catalogs проверяют API/контекстную полноту, а не случайное число тестов.
Повторяющийся обязательный текст в независимо загружаемых entrypoints — разные
входы: удалять их как дубль нельзя без общей authoritative генерации и proof
каждого потребителя. Три help-сценария сохраняют исходные Git/child-process
границы и разные состояния legacy/missing CLI, natural mode и changed source.

В случае lifecycle guards жадный межфункциональный regex слабее проверки
конкретного owner и цепочки вызовов. Assertion пока сохранён. Замена требует
отдельного доказательства настоящих wrappers/core owners и исходного отказа;
этот аудит не приписывает ему доказанное выполнение guard. Также сохраняются
обязательные UTF-8, dirty-state, non-elevation, fresh-pass и ownership contracts.

## Принятая runtime единица и следующая граница

Runtime commit `3d2658d5d416ea14ff11300f4e4d0281d48e82e1` принят общей очередью
`codex/redesign-source-delivery`; exact tree
`682b95e6e4361b3f3d06bab9f11060782dc0ca3c`, Targeted `passed`,
241 passed / 0 failed / 0 skipped, 1256977 ms (check-summary).
ReleaseGate: 46/46, Pester 637.39 s. Рабочее дерево после проверки чистое.
Это регистрация, не публикация. Aggregate Full environment и внешние runtime
остаются незавершёнными A.6/B.4; общий кандидат требует C.2 checkpoint.
