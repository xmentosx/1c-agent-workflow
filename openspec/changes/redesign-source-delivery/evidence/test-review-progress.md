# Навигация по аудиту необходимости тестов

Исходный inventory `fa0e3c91` сохраняет 2814 определений. Индивидуальные решения
находятся в предметных ledgers; [review-index.csv](review-index.csv) связывает
их с уникальными исходными file/line/name и body/file SHA, где они имеются.
[Summary](review-index-summary.json): 235 определений имеют явный предметный
review, 2579 остаются pending. Из рассмотренных: Pester 202, Python 28, Go 5,
Node 0. Это охват исходных определений, не количество запусков или новых тестов.

Индекс объединяет ParserDocs, ReleaseGate, Mantis route-gap, пять Compact
boundaries, 11 host wrappers, семь параметризованных определений и новый
15-case nested review, все 56 исходных определений LocalQualityGate и частичный
22-definition review CompactItlRunner.
Параметризованные строки deduplicate по исходному
определению. Review wrapper не означает review вложенных Python/Node cases;
AST transfer proof сам по себе не считается решением о необходимости.
Любое определение, отсутствующее в индексе, по-прежнему требует review.

Воспроизведение индекса выполняется явным source-only скриптом:

```powershell
& ./openspec/changes/redesign-source-delivery/evidence/build-review-index.ps1 -RepositoryRoot (Get-Location).Path
```

Скрипт проверяет соответствие исходных identities frozen inventory и обновляет
только audit artifacts. Это не новый gate, сборщик runtime, очередь или журнал
доставки. Нет связи между этим счётчиком и разрешением публикации. Не добавлять
его в managed-copy или routine checks.

## Новые 15 nested случаев

В [nested-boundary-review.csv](nested-boundary-review.csv) рассмотрены все три
CodeChecker beta и все 12 Mantis server definitions. Текущие SHA обоих файлов
совпали с frozen source SHA. Для каждого записаны риск, inputs, production owner,
уровень, среда, ресурсы, решение, сохраняемое доказательство и ограничения.
Все оставлены: конкретного дубля или безопасной замены не установлено.
Свежие suites ради read-only review не запускались, история flake и per-case
стоимость остаются неизвестными.

Beta случаи различают пустой ввод без запроса, новый диалог с logic-only prompt
и plain answer, отказ при vendor layout drift или повторном patch. Последний
использует synthetic vendor source; реальная pinned vendor проверка через
`--vendor-source` остаётся отдельным доказательством.

Mantis проверяет реальную очередь executor с fake index, stateless registration,
неразглашение private-note событий, историю и длинные comments с изменением
cursor inputs, parser/formatting и сборку image responses. Default OCR,
явно запрошенный fallback, comment image и прямое attachment API имеют разные
условия и assertions, поэтому общая тема images не делает их дубликатами.
Fake SDK/client/PNG bytes не доказывают реальный MCP protocol, HTTP permissions,
PNG rendering, OCR accuracy или Zvec. Таймер 80 ms в search case настоящий;
не объявлять его flake-free без изучения истории.

Три outer assertions `Ran 3/50/12 tests` остаются кандидатами на замену после
доказательства эквивалентной completeness защиты. Они не удалены: нулевой или
частичный nested запуск должен по-прежнему отвергаться, а исходные script
entrypoints и их preconditions — сохраняться. Этот review не вводит новый runner
ради удаления констант. Остальные файлы не помечаются рассмотренными по форме
assertion.

## LocalQualityGate

[56 индивидуальных решений](local-quality-review.csv) и
[границы, split и доказательства](local-quality-review.md) закрывают review
исходных definitions этого файла. 47 retain, девять retain с конкретным follow-up;
целых тестов не удалено. Пять независимых групп сохраняют все исходные It и
expanded cases; зарегистрированы в `2a8c2052`: 206/0/0, check 390564 ms.
Целевой бюджет 300 s ещё превышен. Следующий priority — оставшиеся
CompactItlRunner и DevBranchLifecycle, а также не закрытые follow-ups уже
рассмотренных случаев. Остальные pending не объявляются рассмотренными по AST transfer.

## CompactItlRunner

[Полный review](compact-runner-review.md) содержит 40 предметно просмотренных
определений и пять ранее разобранных границ: 45/45 этого файла. Перед переносом
source SHA совпал с frozen baseline. Все retained, индивидуальные follow-ups
сохранены. Necessity review не запускал native suite. 42 It перенесены в четыре
isolated worker suites; оригинальные Win32 console/job boundaries остаются serial.
Exact body/setup proof отделён от ещё необходимой native acceptance.

## ReleaseReadiness

[Все 15 исходных определений / 19 expanded cases](readiness-review.csv)
просмотрены по телам. [Closure и решения](readiness-review.md) сохраняют
реальные archive/encoding/Git/checkpoint boundaries. Один независимый owner
исключает checker/timings/scheduler из выбора readiness, добавляет пропущенный
lifecycle route и сохраняет loaded/stage fingerprint inputs. Исходный файл
не изменён, necessity review не запускал его заново. Static/function проверка
catalog: первоначально 36 passed / 2 failed (явный дополнительный owner и
неполный dependency inventory тестового fixture); оба исходных случая после
исправления прошли 2/0 за 14.96 s. Штатная регистрация `bd0f06f1`: 88/0/0,
check 67083 ms, raw 69092 ms; очередь сохранила исходный base fa0e3c91.
Публикация не выполнялась. Это приёмка выделенного owner, не всего плана.
