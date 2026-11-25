# A.1 / аудит — State migration без лишнего Zvec-окружения

Подготовлено в отдельном managed worktree source-test-selection, branch
codex/mantis-state-test-route, база `3d2658d5d416ea14ff11300f4e4d0281d48e82e1`.
База пока проходит регистрацию runtime единицы в соседнем worktree; эту
следующую единицу регистрировать только после успешного включения её базы
в существующую очередь codex/redesign-source-delivery.

## Необходимость и граница

`test_legacy_state_migrates_to_safe_pause` проверяет конкретный риск: старый
SQLite volume без `index_paused` после повторного открытия должен перейти
в безопасную паузу. Проверка необходима. До изменения она лежала в test_zvec,
который импортирует mantis_vector_migration, а тот импортирует настоящий zvec
на уровне модуля. Поэтому state-only поведение требовало чужого vector runtime
и не попадало в существующий автоматический маршрут test_index.

Перенесён один исходный метод в новый unittest.TestCase StateMigrationTests
внутри уже исполняемого test_index.py. Этот класс не наследует IndexTests и
его setUp с FakeApi/catalogs. Исходный класс ZvecTests также не имел setUp;
State, tempfile и Path в обоих модулях соответствуют тем же владельцам.
Сохранены все строки тела, Unicode/whitespace prefix, legacy DELETE, закрытие
и повторное открытие базы, исходный assertion и finally. Production не менялся.
Оставшиеся шесть Zvec cases и все прежние Index cases сохраняют свой путь.

## Доказательства

- AST исходного и перенесённого метода совпадает:
  `683889eb98620fefdf8f925942d868bce5d8ece81204f4dfa118eb8cf3274778`.
- Полный AST Zvec-модуля после удаления только этого метода совпадает;
  полный AST Index-модуля после удаления только нового класса совпадает.
- Реальный unittest loader test_index обнаруживает новый case ровно один раз.
- С явным import guard, запрещающим zvec, исходный сценарий проходит за 138 ms.
- Приватный mutant State, ошибочно восстанавливающий старую базу без паузы,
  отвергнут исходным assertion (`0 != 1`). Тело теста не заменялось.
- Focused equivalence + expected mutant занимают 314 ms; использован явный
  Python 3.13.13 executable Windows. Это State/SQLite proof, а не Linux 3.12
  qualification реального Zvec, FastMCP protocol или готовности всех dependencies.

Ignored artifacts этого worktree:
`build/redesign-source-delivery/state-route/verify-move.py`, `equivalence.json`.
Исходный inventory fa0e3c91 остаётся замороженным; строка semantic review ledger
сохраняет original case identity и ссылается на эквивалентный новый маршрут.

## Приёмка и продолжение

Изменение не добавляет test case и не удаляет проверяемый риск. Оно снимает
лишнюю зависимость окружения для одного необходимого теста. Существующий
HostMantis wrapper запускает test_index.py через UTF-8 native transport;
проверка полного owner route принадлежит единственной RegisterChange этой
единицы. Повторять отдельно весь неизменённый Index suite перед ней не нужно.
Регистрация завершена: commit `3cf487bd032a8e66c15ebb2ac7b1a189a86aaaa4`,
tree `08880735da9eac1d63444d84f5dfd049e85ec8f5`; Targeted 194 passed,
0 failed / 0 skipped, check-summary 66007 ms, raw registration 68215 ms.
HostMantis case действительно исполнил существующий `test_index.py` через
UTF-8 native helper и прошёл; loader equivalence выше устанавливает включение
перенесённого метода в этот неизменённый маршрут. Gate выполнил три workers,
без reuse. Tracked tree чистое, Status принял head в ту же очередь.
Raw proof: common Git `itl/runs/20261010-231216-547-targeted-7a075e755be740d181dc42d6a877e679.json`.
Это автоматическая приёмка State route, а не real Zvec qualification.

Остальные 12 исходно рассмотренных Mantis случаев требуют своих component
routes и воспроизводимого runtime. Полный аудит 2814 определений и пакет B.4
этим переносом не закрыты.
