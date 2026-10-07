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

Последняя проверка выявила перенос partial MCP coverage в автоматический Full
fallback. Явный Full уже защищался sentinel. Сохранены отдельные native PS5
результаты **RED 1/2 → 7/1 → affected 1/0**; первый отказ GREEN batch обнаружил
устаревший in-memory `lastGate6Evidence` при записи fallback-failed. Owner
исправляет invalidated projection, Full всегда идёт через strict ladder, а
прежний legacy context допускается только после confirmed DT/cursor restoration.
Qualification SHA-256
`a15be3ce86162c951f56fd222ea33d278f4efa24d8a889fa1f69c7a3cde77ff4`.
Новый общий 8/0 не заявлен; финальная registration проверяет целые owner files.

Первый source RegisterChange r41 остановил scheduling после LocalQualityGate
**48/1**: inventory ожидал 57, получил 63 после добавления шести Gate 6 files.
Test contract сохраняет исходный observed 57-file cohort, отдельно требует
все шесть новых paths (current 63; с шестью quality files — 69). Тот же
original It прошёл **1/0**, 2,541 с, inputs unchanged; остальные 48 не повторены.
Qualification SHA-256
`ceaa2bb8ac961544bd0fdb195711150e9905f47a54e96e6cf434d0f7b8f1d473`.
Исходный count failure сохранён побайтно. Runtime watchdogs, budgets и
все прежние capacity assertions не изменены; новый общий 49/0 не заявлен.

## Исходный стенд

### Реальный full-text MCP и исправление старых test fixtures

Проверка пакета на `85b62bce` завершилась **643 passed / 6 failed**: прежние
low-level Full/fallback fixtures не предоставляли обязательный source identity.
Raw summary/JUnit/worker logs сохранены в publication clone
`build/gate6-r41-source-delivery/targeted-85b62bce-failed`. Эти failures не
обойдены ослаблением runtime: Memory fixture сохранил original fallback/memory
assertions, causal 0/1 → 2/0; пять Lifecycle cursor/fallback fixtures сохранили
original 21 assertions, causal 0/5 → 5/0. Native Designer здесь имитируется,
реальные Git source fingerprints и checked load-owner boundaries сохранены.
Qualification SHA соответственно `dbf65d68a2c9bc1e9a5b63492d547d4f857d4d2aef69e0f9b1bdb0ae7513a788`
и `f5a5ccfdbaf20a8f1fcf7afbd8fb8ec3e0abe879218af033126cf869c6066ff5`.

Живой Syntax `dev-ermakov:22002/mcp` подтвердил `BslSyntaxChecker 3.4.7`,
analyzer `0.2.81` и отсутствие `syntaxcheck_file`: exposed `syntaxcheck`,
`plugin_state`, `plugin_reload`. Единственный вызов `syntaxcheck` передал
полный исправленный модуль, raw SHA `f402af6a…`; transport/tool прошли, два Hint
сохранены, ошибок нет. Actual full-code SHA `555d6551d7b544b60ece1aff024b38251ff91327c1824138cd2bef58351016cc`,
requested/used provider prefix `555d6551d7b544b6`, 245 Unicode characters,
12 lines, whole-file, без rewrite/filter/truncation. Исходник не менялся.
Raw artifacts: `build/platform-mcp-live-audit-658c48abf9d94e6bb128235a12ddd209`,
report SHA `a75e6eed70411a0e5729a42cce0b611d3e48bd6c4137a7027cebccc6ed5c2f0b`.

Те же сохранённые request/result/source дали coverage RED 0/1 на path-only
reader, затем GREEN 1/0 на full-text reader. Connected owner batch:
**51/1**, включая Trigger 15/0 и LoadContinuation 13/0. Единственный failure
показал culture comparison U+FEFF; ordinal BSL/XML boundary исправлен,
affected 2/0; последующие raw-name/обычные diagnostic-tags cases дали 2/0.
Первый 51/1 receipt сохраняется, новый общий 52/0 не заявлен.
Final names/tags qualification SHA `4f9b54c102f0fabc61e539c75435272eb78b4cf1ed07453b6751589bb0be438d`;
перед ним ordinal/live replay SHA `aa46f9b8ccb8de46b5833264c069a17b6a52f8d35225eee4afc59e7efc5b96b0`.
File-path-only proof без actual remote input binding теперь сохраняет fallback;
полный подтверждённый text fallback соответствует upstream.

Gate 2 того же unchanged полного модуля: один живой `check_1c_logic`,
`1C_Code_Checker 3.4.7` на `22003/mcp`, HTTP 200/isError=false, блокирующих
замечаний нет; необязательное предложение direct return сохранено без правок.
Оба фактических caller используют возвращаемую строку. Report SHA
`b3a3c99662cc01ef55febf8ee7c586d2c767c6b283def8fe27913a9cec771c2d`,
assessment SHA `8ca0ba0316d1e573ce1f3d314cb8d1e28732a14c5205898cd5f470f9b6cd5f65`;
raw: `build/gate2-codechecker-live-audit-50d5c74ae9534504b9b25c2146e3b0ae`.
Обе собственные MCP sessions закрыты DELETE 200. Это статическое proof
конкретного input, не новое native loaded proof и не завершённый Develop gate.

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

## Завершённый Develop и диагностика Release, 2026-10-07

Штатный Develop прошёл на source `abc8221b4934445ca3908f7b2d3170cd2e08909f`,
tree `d8022fc3dd742eec7110646be013023fb65c630c`, fork r41
`84ed7c7a8dcc783159537f41f38196640ffa968c`. Full: **2622/0/0**, 116 групп,
6 выполнены и 110 переиспользованы; upgrade/fork proof также переиспользованы.
Это фактическое завершение Develop, без заявления о публикации.
Закрытые qualification/raw records сохранены в
`build/yax-vendor-exception/closed-develop-abc8221b-ps7/immutable-passed-develop-map.json`,
SHA `1c97795cad3b932d6bcbf9bfda29f5884016ba11a243f108d623437a8383e71a`.

Оригинальная fresh journey прошла bootstrap, missing-suite refusal, check,
export, recovery, refresh, recheck и close. Native CheckModules: **0/0**;
before/after CheckConfig: **101/101**, assessment: **629 legacy / 0 new /
0 unresolved**, `applyAllowed=true`, `cleanPassed=false`. Два фактических
Vanessa-прогона дали каждый **2/0/0/0**. Третий check после refresh
переиспользовал полную принятую freshness и не запускал Vanessa.
Устаревший export фактически разрешён по policy `warn` с
`decision=warn-unverified`, `freshPassed=false`; это не refusal. После recovery
export имеет `decision=fresh-passed`, `freshPassed=true`. Отсутствующий ранее
`UI_TESTING` получил `essential`. Семь карт оригинальных native/runtime
артефактов находятся в `build/yax-vendor-exception/fresh-native-abc8221b`;
данные env и VAParams в proof не публикуются. Это не отдельная EV8a/EV9
приёмка и не доказательство standalone QA.

Следующий штатный Release с `ResumeMode=Restart` прошёл **config-cadence**
за 3431049 ms: два metadata load, test-only failure без Designer/Enterprise,
исправление и второй успешный запуск. JUnit последовательность **4/0/0/0 →
4/1/0/0 → 4/0/0/0**; оба native assessment сохранили 629/0/0 и clean=false.
Owner evidence SHA `2f2bceabbed678ec6c534c0f58189313492ed86cf9012b0eae8382594a08bffb`,
архивная карта `release-native-abc8221b/closed-config-cadence/immutable-files-map.json`
под `build/yax-vendor-exception`, SHA
`2093044ff4287fd57d5bc9851cee76372f8fc55f4469f88bf7808ba83f6f390e`.

Release завершился ошибкой: `extension-smoke` прошёл UI, но исчерпал 899 s
во время canonical dump Cfe Init, после промежуточного Empty restore и перед
final restore. Cleanup остановил owned clients/backends; это не доказательство
DT restore прерванного Init. Failed map
`build/yax-vendor-exception/closed-release-extension-timeout-abc8221b/immutable-failed-release-map.json`,
SHA `a9e5d0cef66fdb89240771db531e2235054dc0196d89a37b88879f708f26a833`.
Ondemand/YAxUnit, публикация и EV8a/EV9 не пройдены.

Диагностика нашла около 117 s новых snapshots и 208 s Gate 6 checks;
guard waits равны нулю. Init корректно передаёт собственный snapshot Gate 6;
обоснования сокращать roundtrip, проверки или restoration нет. Бюджет этой
стадии изменён 900→1200; derived totals меняются на +300, остальные пределы,
no-progress и predicates сохранены. 75 s на оставшуюся работу и 225 s reserve —
оценки, требующие оригинального успешного прогона. Measured record
`build/yax-vendor-exception/extension-smoke-budget-correction/measured-change.json`,
SHA `a30c78db77f2db185dbf2fe1c0ca0e8e1926b75561bdacf196475038687d1dc9`.

Отдельный ранее сохранённый Release stderr оказался OEM866, а не strict UTF-8:
SHA `fd9ddc5eae5aca4ae6dcce58da9294050c8bc0f92fe82e93a7e4d32027fcb976`.
Release entrypoint теперь устанавливает UTF-8 до первого dot-source;
регрессия исполняет production bootstrap через существующий native child
helper с OEM866 initial state, кириллицей и пробелом в одном пути. Corrected
private probe WinPS 5.1 сохранил точные stdout/stderr и ожидаемый exit 1;
это не Pester/Release qualification. Manifest
`build/yax-vendor-exception/transport-fix-preparation/preparation-manifest.json`,
SHA `0fa0ff032920947621876cde6f81171dbdfcc26bf1939910e5f7ddb4be33df6f`.
Исправленный source требует обычной регистрации и нового immutable plan;
старые qualification, failed receipts и runtime identities не переписываются.
