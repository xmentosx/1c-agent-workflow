# Разделение независимых host suites

База переноса: `9884c820ba704c42db279b4197cf002e86c6a645`.
Оригинальный HostTooling содержал 133 It definitions. 122 остаются в общем
suite; 11 интеграционных команд перенесены в семь component suites.

| Suite | Перенесено It | Реальное вложенное исполнение |
|---|---:|---|
| HostNativeTransport | 3 | Unicode child capture; SQLite/vector snapshot; HTTP identity/Linux ownership |
| HostLinux | 1 | Linux native host unittest discovery |
| HostCodeChecker | 2 | beta overlay; retry policy |
| HostToolsProxy | 1 | реальный Node proxy contract |
| HostBookStack | 1 | BookStack response/continuation Python tests |
| HostMantis | 2 | server tools; index refresh |
| HostSppr | 1 | corpus; HTTP transport; Unicode child capture |

Одноразовый producer `split-host-suites.ps1` переносит AST command text,
сверяет число совпадений и сохраняет inherited DirectEndpointRecovery tag.
Все 11 command hashes совпали с исходными после нормализации CRLF/LF;
оставшиеся 122 команды также совпали. Assertions, workload, native boundaries,
literal nested counts и runtime preconditions не изменены. Повторно запускать
producer на уже разделённом дереве нельзя; это не runtime-инструмент пакета.

Новые owners выбирают непосредственно соответствующий component suite;
общие host assertions остаются выбраны через standalone-mcp-host.
Mantis зависит также от реально загружаемых core/vanessa helper inputs.
Shared installer выбирает всех непосредственных пользователей installer.
Для семи внешних runtime suites reuse отключён явно: неизвестная Python/Node
identity не может стать доказательством пригодности cached pass.

## Приёмка и ограничения

- HostTestSelection: 10 expanded cases passed, 0 failed, ~0.77 s Pester.
  Строго проверены семь component selections, installer consumer closure,
  docs-only route и запрет reuse при неизвестной external runtime identity.
- HostTooling + HostMantis через штатный sharded runner/Windows PowerShell:
  154 expanded Pester cases passed, 0 failed; suite durations 44.421 s и
  34.619 s. Это focused owner proof, не Targeted/Full квалификация.
- Перенос не решает подготовку Python-сред B.4. Старые PATH Python/Node routes
  и существующий SPPR isolated-runtime precondition сохранены.
- Остальные пять suites: 8 cases passed, 0 failed, worker span 23833 ms.
  SPPR: 1 passed, 0 failed, worker 26582 ms. Для focused SPPR подготовлен
  отдельный ignored build/sppr-venv из существующего requirements.txt;
  глобальная Python-среда не менялась. Автоматизация подготовки B.4 ещё не сделана.
- Отдельные Mantis protocol/zvec/extract suites не включались автоматически
  этим переносом. Их необходимость, платформы и маршрут остаются в аудите.
- Проверки точного числа nested tests пока сохранены: удаление assertions
  требует отдельного эквивалентного completeness proof.

Регистрация этой единицы ещё не выполнена. Следующая регистрация должна
добавить её в QueueId `codex/redesign-source-delivery`, поскольку ветка
source-test-selection наследует уже зарегистрированный JSON commit.
