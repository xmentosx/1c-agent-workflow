# Gate 6: правила r41 и границы приёмки — 2026-10-04

Принятые D13/EV8a–EV8c сохраняют три части: условная проверка малой CF правки,
доказанная совместимость с прежними замечаниями и повтор исходной PM5 приёмки
после исправления известного дефекта только в owned стенде. Эта запись
разделяет квалификацию правил, адресные helper tests и ещё не завершённую
платформенную приёмку; она не объявляет workflow опубликованным.

## Controlled fork

Upstream остаётся `c1fb8e687be5b9d71d5a05c6f5d32cf6a6919dcb`.
Чистый fork commit `84ed7c7a8dcc783159537f41f38196640ffa968c`, tree
`dc1d895bf4b993e3cb83d35c0b8f33c8df0c2aa9`, добавляет уточнение двух
managed-policy разделов поверх прежнего `25b60321`. Общая upstream политика
проверок и остановки при ошибке сохранена; исключения main CF ограничены
полной matching MCP coverage и подтверждённым operation-local сравнением.

Exact Full: **166 passed, 0 failed, 0 skipped; 18/18 этапов; 1421,588 с**,
native Windows PowerShell 5.1 / Pester 5.8.0, clean/reusable, 175 input hashes.
Receipt: `D:/Git/itl_ai_rules_1c-upgrade-c1fb8e6/build/gate6-r41-qualification/qualification.json`,
SHA-256 `3b3f7a73a64145e2f893b8aeeef60a518f358aba9a84804a7e97030a1fd5d740`.
Завершение: `2026-10-03T22:34:35.8608180Z`. Реальный общий publisher
`QualificationProbeOnly` прошёл exit 0, исходный receipt сохранил exact bytes.
После прошедшего preview штатный publisher создал локальные annotated tag
`itl-main-c1fb8e6-r41` и release branch без push. Default Full receipt
побайтно скопирован из квалифицированного файла; прежний default сохранён.

Schema-3 overlay Verify прошёл для 480 решений. Причины прежних решений
сохранены, уточнение D13 добавлено к двум владельцам. Source pin r41/84ed
имеет `compatibilityStatus=pending`: installability и remote finalization
получаются только через парный `PublishDevelop`, а не из fork Full или tag.

## Адресные helper proof

Новые библиотеки находятся у прежнего load/check/apply owner и используют
существующие Git path/blob readers, snapshot и native guard. Они не вводят
общий baseline, whitelist, coordinator или отдельный launcher.

| Проверенная граница | Результат |
|---|---|
| Полные saved inputs/raw MCP results, target/source binding, отсутствие truncated/unknown/error результата | 18/0 actual reader tests |
| Native structural/known compiler parser, точный multiset, неизвестные и current compiler failures | 33/0 |
| Доказанный source impact; body/comment, additive metadata, отказ при descriptor/API/неясной зависимости | 26/0 real Git; 49,633 с |
| Реальный seed/loaded proof и previous-tree fingerprint; чужая база/FP/metadata impact отклоняются | 16/0 real Git; 40,974 с |
| Native 101 retained, outside-scope unchanged допускается, new/unknown/inside и подмена baseline блокируют apply | 6/0 checked-attempt cases |
| Conditional trigger: generated ConfigDumpInfo не увеличивает размер смысловой правки; большой diff и невалидный proof сохраняют fallback | исходный запуск 14/1 выявил index-count defect; после owner repair 4/0 затронутых сценариев |

Это focused proof конкретных входов; новая целая source qualification и
платформенное продолжение не следуют из суммы результатов. Ревью выявило
два остававшихся интеграционных дефекта: combined MCP-exempt apply без
проверки после editable load и потерю previous Designer proof после точного
DT rollback. Их causal RED **0/2** сохранён отдельно от setup failure.
После owner repair **15/0/0**, 64,648 с (9 новых Load-continuation и 6 прежних
checked-attempt cases; остальные 15 обнаруженных cases намеренно не запускались).
Actual Git/current receipt/state/load/snapshot owners доказывают source/receipt/
raw-result races, точный rollback, неизменный proof и повтор той же Load-команды;
native 1C и validator responses в этом unit batch — явные collaborators.
Полный публичный `/itl-check` и новый native candidate не заявлены этим proof.

## Исходный стенд

Guarded export основной CF дал 19 286 файлов, совпадающих с checkout по
relative paths и raw SHA. Runtime inventory содержит 11 расширений; DT
сохраняет их целиком. Реальный before CheckConfig: exit/DumpResult 101,
631 structural findings, 3 диагностических пары известного procedure-return
дефекта в разных runtime modes, repository notice и **0 неизвестных строк**
после узкого parser repair. Это native failure, а не passed baseline.

Исправление меняет только Procedure/EndProcedure на Function/EndFunction
в `упо_ФИ_УправлениеДоступомКлиентСервер`; два фактических call sites
ожидают возвращаемую строку. API-changing общий путь legacy исключение не
получает: для этого конкретного owned repair фактический before export,
same-target snapshot и три проверенных owner dependencies предъявлены явно.
631 замечание не признаны безопасным whitelist. Исходные failed receipts
сохраняются; fresh/Vanessa/export/refresh/UI требуют новых фактических proof.

Фактический repair завершился `2026-10-03T22:50:31.2077164Z`, released=true:
strict CheckModules exit/DumpResult 0; CheckConfig exit/DumpResult 101,
631 unchanged legacy, 3 resolved previous compiler, 0 new и 0 unresolved.
`nativePassed=false` / `cleanPassed=false` сохранены. Apply завершился.
Repair receipt SHA-256
`70ea52868c5884800b3f0e2265345963346bcfdd6b593681d9752ae5bb018f4c`;
assessment SHA-256
`074c4cb7ca6af4a031a97c132b1b4029944f23ba9472db819f5a64b88733c783`.
DT SHA-256 `d26b3378473db98742de88e3e04489bf0332c015cf7e3a94e8eed6f43d62af0f`.
Отдельная проверенная source-delivery continuation создала стендовый commit
`6d569ac79efb92020d9d99bd3aa1110eb4ce96eb` только для module и ConfigDumpInfo
(4 insertions/4 deletions). Workflow master и реальные проекты не обновлялись.
Штатный `sync-master` прошёл exit 0/status=succeeded, seed ready,
sync ID `8dbd6ef0cc0e4282aedd2caa0a02b478`, matching fingerprint
`v2|git-tree-sha256|56bb357dd8139232e329011f4873a73938bbd4877a064b91614e51314ee37614`.
Стенд clean; failed predecessor/native receipts и восстановительные snapshots
сохранены. Это готовность исходного стенда, а не завершённый Develop gate.
