# Гранулярность Local/Fresh и зависимости Develop qualification

База этой единицы — принятый `1af9455b`, очередь остаётся
`codex/redesign-source-delivery` с исходной базой `fa0e3c91`.
Новая регистрация и её native-приёмка пока требуются.

## Сохранённое поведение

Остаток LocalQualityGate: 24 определения разобраны ранее в полном
[Local ledger](local-quality-review.csv). Теперь transport (4), targeted
selection (6) и shard cache (7) вынесены отдельно; в исходном файле остаются 7.
Каждый `It` и единственный top-level `BeforeAll` перенесены точно, с прежним
Describe. Три новые группы добавлены в Smoke, где раньше находился исходный
Local. Производственные зависимости source-quality-gate для всех четырёх
Local-файлов пока сохранены консервативно; более узкое владение не заявляется.

Обязательный native Fresh-кейс с 126 секундами тишины выделен в
CompactRunnerLongContinuation. Таймауты 120/180 секунд, parent/child/grandchild,
fixture, assertions и scoped BeforeAll сохранены. Обычный Fresh содержит
9 определений / 10 expanded cases, Long — 1/1. Все пять выделенных Compact
групп остаются параллельными; исходные console interruption cases — serial.
Compact не добавляется в Smoke. Все helper definitions остаются reuse inputs
обоих Fresh-файлов; прежние lifecycle production routes сохранены.

[Точный перенос](local-and-long-suite-proof.json) и
[поимённый ledger](local-and-long-suite-transfers.csv) воспроизводятся
one-shot скриптом `split-local-and-long-continuation.ps1` только на указанной
неизменённой базе. Native PS5 discovery подтвердил равенство имён: Local 24→24,
Fresh 11→11. AST/discovery доказывают сохранность сценариев, не их исполнение.

## Develop qualification

Все текущие 20 определений получили индивидуальный
[review](develop-qualification-review.csv). Два из исходных 22 ранее перенесены
в SourceQualityCatalog и уже учтены. Девятнадцать нормализованных тел совпадают;
исходное 738/current693 расширено Full-rebind assertions с сохранением прежних.
Разные raw SHA исходника в двух checkout объясняются mixed/complete CRLF;
LF-normalized bytes совпадают (`c282b395...`). Файл тестов этой единицей не менялся.

Новый owner `develop-e2e-qualification-tests` сохраняет реально используемые
check AST, router, quality catalog, Git, release/runtime qualification,
stand identity, оба E2E entrypoint, project template и helper dependencies.
Все загруженные helper definitions, Release modules и source-delivery-process
остаются входами переиспользования. Timings, scheduler, worker, resolver,
develop-static-qualification и source-delivery-plan fixture не используются;
их отдельное изменение больше не выбирает этот 20-case process suite.
Check.ps1 по-прежнему выбирает Develop. Это не новая runtime authority.

Review различает реальные Git/native child boundaries и синтетические raw
Targeted/Full/route records. Зелёные fixture tests не доказывают настоящий
Develop, установку или journey. Два static-wiring случая сохраняют явный
behavior-proof follow-up. Динамические helper loads не объявлены полностью
доказанными только по импорту; closure удерживается консервативно.

## Стоимость и приёмка

[Ordering costs](local-and-long-ordering-costs.json) получены из названных
предыдущих JUnit: Local — `012a1225`, Fresh — `1af9455b`. Это сумма case time
плюс 5 секунд на setup с округлением вверх, не новый замер wall time.
Веса Local: 48/20/116/108; Fresh/Long: 144/139. Исторические capacity модели
и наблюдавшаяся стоимость цельных файлов не переписаны.

Семь focused catalog checks прошли: Smoke/direct selection, serial exclusion,
Develop positive/negative routes, unchanged historical cohort и фактические
digest mutations. Canary сохраняет catalog/helper invalidation, пропускает
неиспользуемые Develop scheduler inputs, обнаруживает check mutation и
изолирует соседние Compact test edits. Отдельный E-cohort check прошёл без
повтора остальных шести. Штатная одна RegisterChange всей связной единицы ещё
требуется. Цель 300 секунд и
конкурентность native workers должны подтверждаться каноническим результатом,
а не арифметикой или одним source proof. Аудит всех 2814 tests не завершён.
