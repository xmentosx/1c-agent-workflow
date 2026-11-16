# Семь раскрытых параметризованных определений

База `fa0e3c91694112c1da3ecda7209a8a81ea828264`. Проверены тела семи
определений и выражения параметров в шести файлах; текущие file SHA256 совпали
с frozen inventory. Индивидуальные source identities, параметры и решения —
в [parameter-case-review.json](parameter-case-review.json). Это 29 вариантов
семи исходных определений, а не 29 дополнительных тестов к baseline 2814.
Остальной inventory остаётся pending. Свежие тесты ради этого read-only review
не запускались; стоимость и история отказов по каждому варианту не измерены.

| Определение | Входы и сохраняемое доказательство | Необходимость, уровень и ограничения |
|---|---|---|
| ReleaseCatalogSchemasResolveAndIndex | Оба настоящих pinned JSON catalogs: roctup и vanessa-ui. Число validators/tools и поиск каждого tool. | Оставить обе backend families. 13/38 здесь — identity конкретных каталогов, не произвольный размер test suite. Go filesystem/validator contract, без живого backend. |
| ProbeSequenceCancellationAndCleanupFailureRemainFailures | Cancel до первого call и обычный call с последующим cleanup failure; точные calls/records, один close, сохранённая ошибка cleanup и context.Canceled. | Оставить оба временных исхода: иначе потеряется либо запрет call после отмены, либо фактическое наблюдение при ошибке уборки. Go MCP session fixture/in-memory transport, без настоящего 1C. |
| ProbeSequenceRejectsInvalidInputBeforeFacadeLaunch | Unknown tool, array arguments, unknown field, trailing JSON, empty sequence, invalid UTF8; nil calls/error и неизменность bytes файла с Unicode/whitespace. | Оставить все шесть: tool allowlist, object shape, strict fields, single document, nonempty workload и byte transport — разные причины отказа. Go parser/catalog preflight; метод не запускает native facade, поэтому это не доказательство process isolation. |
| ProfileOwnerFinalResponseSurvivesExitDuringInspection | В liveness callback owner уже вышел; response либо записан, либо отсутствует. Ровно одна inspection, final read, CleanupConfirmed или EXITED_UNCONFIRMED. | Оставить оба race outcomes. Go control-file/liveness unit fixture. Файл помечен windows build tag; этот case не доказывает настоящий OS process-exit race. |
| GatewayRejectsAmbiguousOrInvalidArgumentsJSONBeforeStartup | Both forms, invalid JSON, array root, null root через реальную MCP session; отдельная oversized-input assertion; backend ensure=0. | Оставить четыре subtests и отдельную oversized проверку: двусмысленность, синтаксис, форма объекта и лимит bytes не эквивалентны. Go gateway/session integration с fake broker и in-memory transport; без настоящего backend. |
| Reset form validation despite equal parent blobs | 5 путей staged/unstaged/staged-reverted-worktree/repair/relative-repair × 2 состояния command ids. Реальная Git merge topology, source integrity validator, warnings/report, unchanged bytes и незавершённый merge. | Оставить 10 вариантов. Они доказывают достижимость проверки для разных источников candidate paths, а не повторяют один parent-blob comparison. Pester/helper/Git fixture, подставленные source validator paths, собственный temp root; без Designer/infobase acceptance. |
| NUL and disallowed C0/C1 controls | Суффиксы 00, 01, C2 85; original prefix; точные byteOffset, code point/reason, test-fixture category и /itl-verify-fix continuation. | Оставить три byte-input cases: NUL, однобайтовый control и валидный многобайтовый UTF8 control. Pester canonical feature preflight через helper/private files; без Vanessa runtime acceptance. |

Маршруты Go сохраняются у `Build-ItlOnDemandMcp.ps1` (`go test ./...` без
SkipTests) и Release ondemand-mcp qualification. Pester definitions остаются
в исходных DevBranchLifecycle/VanessaAuthoring suites, Full discovery и своих
catalog owners. Этот review не меняет маршруты и не объявляет действующую
широкую granularity оптимальной; перенос большого lifecycle файла требует
отдельного анализа зависимостей и сохранения исходной матрицы.

Работа с parameters не требует дополнительного runtime gate на каждый вариант.
Уровень выбирается по поведению: parser cases можно проверить без native backend,
а session/race/merge cases не заменяются проверкой строк исходника. Историю
ошибок и реальные длительности необходимо дополнять по существующим журналам,
не выдумывать из названия теста или количества assertions.
