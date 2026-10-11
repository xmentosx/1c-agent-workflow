# Compact runner: предметный аудит и сохранение native границ

В [ledger](compact-runner-review.csv) разобраны 40 исходных определений.
SHA файла перед переносом совпал с `fa0e3c91`:
`4892160074cde776872ef86a969291cfb73575bc5bfef6d2fb81a9e314ceb846`.
Пять других границ (1085, 1632, 1638, 1650, 1664) ранее рассмотрены в
[priority review](priority-test-review.md). Итого рассмотрены все 45 исходных
определений. Necessity review не менял reproducer и не запускал native suite.
Отдельный последующий source transfer сохраняет исходные тела и scoped setup;
его приёмка не подменяется этим аудитом.

Отчёты различают bounded JSON с полным log, short userReport, long failure,
четыре успешных действия и filesystem fallback при невозможности создать файл.
Сходство темы отчётов не делает эти случаи эквивалентными. Git cases проверяют
разные направления: update направлен в master, refresh использует чистый master
runtime с projectRoot ветки; обычная проверка остаётся локальной и dirty master
отвергается. Classification case исполняет реальный dispatcher/helper, проверяет
четыре результата и неизменность существующего proof без запуска 1С.

Все 40 оставлены; конкретные follow-ups записаны индивидуально. Static Win32 markers
не доказывают настоящую отмену. One-off case проверяет аргументы, но явно не
утверждает exit/status. Export fixture не квалифицирует SHA. Live-progress case
не измеряет полный предел stderr. Caveman matrix выполняет десять native
запусков: возможную замену части матрицы дешёвым доказательством нужно сначала
обосновать с сохранением реальной .dev.env/process boundary, а не просто убрать
повторяющиеся комбинации. Per-case cost и flake history здесь неизвестны.

Оставшиеся 18 рассмотрены по полным телам, включая BeforeAll fresh fixture:
реальный parent/child/grandchild, signed context, pinned c6 function, terminal
writer, очистка и error propagation. Случаи успеха, native exit7, отсутствующего
terminal, неверного terminal PID и ошибки cleanup после первоначального успеха
различаются. Отдельный 126-second silent workload остаётся неизменным.

Уточнены ограничения: epoch case не создаёт unreadable JSON; report equality
сравнивает decoded strings; window launcher stub не подтверждает полный argv;
cleanup case утверждает финальный результат, но не снимает live snapshot в
середине cleanup. Это основания для усиления конкретного доказательства,
а не для удаления исходной регрессии. Optional fresh baseline override требует
отдельного closure review; его отсутствие не делает весь аудит завершённым.

## Разделение последовательного хвоста

[One-shot transfer](split-compact-runner-suites.ps1),
[42 переноса](compact-suite-transfers.csv) и [exact source proof](compact-suite-proof.json)
разделяют исходные 45 It между пятью файлами. В CompactItlRunner остаются
Win32 wiring, принудительное завершение job tree и настоящий console Ctrl+C.
Исходный serial admission этого файла сохранён. Четыре остальные группы:
Reports 15, Routing 5, Watchdog 12, FreshContinuation 10.

Первые три получают точный исходный scoped BeforeAll и неизменные It; fresh
Describe перенесён целиком со всеми native child fixtures. Describe names,
assertions, preconditions, workload, параметры и cleanup не менялись. Множество
полных It совпало; отдельное Desktop discovery сравнивает expanded names.
Консольный тест выполняется после завершения parallel queue по существующему
scheduler. Ни scheduler, ни его Win32 cancellation policy не расширяются.

Reports/Routing/Watchdog используют private GUID roots; свежие helper процессы
имеют private project, operation и status paths. Env меняется внутри отдельного
worker и восстанавливается. Routing и fresh загружают actual helper definitions:
дополнительный stateless contract удерживает все helper definitions как reuse
inputs для этих двух suites. Lifecycle production routes сохранены для всех
переносов; дальнейшее сужение широкого lifecycle owner не заявляется. Один
neighbor test edit не должен инвалидировать остальные группы. Набор Smoke
сохраняет прежний состав: исходный Compact в него не входил.

Actual concurrent isolation и длительность устанавливаются Targeted через
RegisterChange, а не только source proof. Произвольные concurrent регистрации
и помехи соседнему чужому процессу этим переносом не объявляются проверенными.
