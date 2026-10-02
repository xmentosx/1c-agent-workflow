# Локальная квалификация c1 upstream — 2026-10-02

Аудированный upstream — `c1fb8e687be5b9d71d5a05c6f5d32cf6a6919dcb`.
Новый controlled fork построен линейно от него; прежний downstream не влит
через merge. Текущий чистый локальный commit —
`25b603215b3893f94fbd382e9a03fa99db4678e5`, tree
`3fd218ac6d37bcddac2c8ab51ac5128f76803248`.
Он не опубликован. 2026-10-03 штатный fork publisher подготовил локальный
annotated tag `itl-main-c1fb8e6-r40` и release branch на этом exact commit,
без push. Revision 40 продолжает установленную числовую миграцию из r36;
исходная qualification branch r1 сохранена. Все 175 recorded input hashes
проверены повторно; fail-only reuse probe прошёл. Qualified receipt побайтно
перенесён в default Full location, прежний failed default сохранён отдельно.
Source pin теперь pending: совместимость, публикация fork и installability
остаются у парного `PublishDevelop` и не следуют из создания локального tag.

| Доказательство | Наблюдаемый результат |
|---|---|
| Schema-3 Verify | 480 решений, все intake paths классифицированы, blockers отсутствуют |
| Exact fork Full | 166 passed, 0 failed, 0 skipped; 18/18 этапов; 762.583 s; clean worktree |
| Общий reader publisher, `QualificationProbeOnly` | Exit 0, сохранённый exact Full пригоден к reuse; tag/push не выполнялись |
| Existing twelve-client compatibility | Exit 0: actual init/update/doctor всех 12 клиентов; повтор update byte-idempotent; delegated MCP |
| Исторические причины решений | Все прежние причины и r36 baseline hashes сохранены; upstream hashes отражают c1, прежние 20a0 hashes остаются в Git history |

Ignored доказательства Full находятся в fork:
`build/c1-corrective-qualification/full-25b60321/`.
SHA-256 `qualification.json`:
`b4cd63b1eab2260b096192d4792123983bb0f6f29fcba5a976ec8d45d8e69e60`.
Квалификация содержит 175 входов. Source Verify находится в
`build/c1-corrective-qualification/overlay-verify.json`, SHA-256
`da3f3a7497f583a2d74980d0e19679624634d838e6334cb4553fb4081400a106`.
Ledger SHA-256 после шести owner corrections:
`6a2b03911623700aadecb74f269804b3eb87905e2ea6c7ac2d24865a0d85bb99`.

Exact twelve-client compatibility выполнена существующим source script на
`41414989296053115ee874d2c686eb972f696b22` с clean clone fork `25b60321`.
Проверены Codex, Kilo Code, Claude Code, Cursor, OpenCode, Kimi, Qwen,
Command Code, Cline, Pi, ZCode и MiMo Code: protocol 1.1, per-client model maps,
helper extension resolution, сохранность ITL skills и user memory. Bundle
completeness проверена для пяти имеющихся native layouts: Claude Code, Codex,
Cursor, Kilo Code и OpenCode; это не native-bundle proof остальных семи клиентов.
Config MCP оставался у ITL, live provider не вызывался.
Source receipt: `build/c1-corrective-qualification/client-compatibility-evidence.json`,
SHA-256 `83b6c08e56e33f5acede3230e2eb8eba62b41227887d3ce795f36a6d14cacd17`.
Driver log SHA-256:
`81dbd4332b53ea77df1e9a32ff82f36d1c11ed8e50a1177f1ffbc3e4fdc67035`.
Физическое размещение и doctor не доказывают discovery в запущенном AI-клиенте.

Первый Full на `001f5bafa5c6b874a5e0a2836317bc61ca8856c6` не прошёл:
161 Pester case были passed, но validator остановил gate. Его результаты
сохранены и не выданы за квалификацию. Затем исправлены противоречие QA skill
с разрешённым named one-off run и учёт входных файлов Full. Inventory теперь
читает tracked Git paths через NUL/strict UTF-8: ignored evals, logs и сама
qualification не становятся входами своего доказательства. Тот же исходный
inventory reproducer сначала упал, затем owning native проверки прошли 5/5;
source-edit invalidation, обязательные входы и clean-state refusal сохранены.

Лимиты контекста изменены явно с сохранением обязательного смысла. По сравнению
с ранее квалифицированным `9ec86f75`, hot set вырос 136393 → 138224 bytes
(1831 bytes, примерно 495 tokens), start set 29427 → 31370
(1943 bytes, примерно 525 tokens). Ceilings теперь 136 и 31 KiB; root остаётся
в прежнем лимите 14 KiB. README согласован с владельцем этих значений.

Source owner исправления Q23 зарегистрирован отдельно на чистом
`41414989296053115ee874d2c686eb972f696b22`: Targeted 817/0/0,
1190.063 s при неизменном hard limit 1200 s. Предшествующий cache owner
`9996b97d402588c6ddc40f96ea274dced8ae728a` зарегистрирован с 88/0/0.
Исторический e130 record с подтверждённым digest alias остаётся непригодным
для заявленной квалификации; новые записи не делают его корректным задним числом.
Настоящий Codex init/detector и 32 UI owner cases описаны в `../test-plan.md`.

### Первый настоящий Q23 update/rollback: source 41414989

В новой копии прежнего published-master/r33 fixture выполнен публичный updater:
first update 128.573 s, repeat 2.053 s, deliberate later manual repeat 2.221 s,
защитный restore refusal 5.893 s, поддерживаемый exact rollback 50.447 s,
rollback repeat 9.028 s и old helper help 2.079 s. Исходные roots/индексы,
runtime/guards и 1270 raw source/fork files остались неизменными. Private source
commit `43b8505f71515f2ff1198ee2baa18d59ee5e7634` отличается от 41414989
только двумя test pin files; private tag не опубликован. Подтверждены переход
manual→essential, независимость saved Vanessa, late-edit refusal без записи,
побайтное восстановление `.dev.env` и исходного дерева
`fa481f93f9335aad58f13c1f00735f69fc0f33ed`.

Этот первый прогон имеет status `passed-with-existing-env-writer-limitation`,
а не полную BOM приёмку. Общий `Set-DotEnvValues` удалил BOM ещё при добавлении
session-limit setting до Q23; сам UI receipt начинался с уже изменённых байтов.
Откат вернул исходный BOM. Исходный reproducer сохранён; requirement сохранения
формата не ослаблен. Receipt в source UI worktree:
`build/q23-c1-869d8824/file-only-qualification-v2.json`, SHA-256
`168cdbdf6252596a6b468dfaa3e40b51c83eca81614f74b05eceae581d006cce`.
Generic writer repair `3638706c0a57973c43d5f8685d47ff5f07fc5ec3` прошёл
native focused 12/0/0 в 6.681 s после сохранённого RED 3/9. Actual sequence
session limit → Vanessa settings → UI transition проверяет BOM/plain UTF-8,
CRLF/LF, exact no-op, mixed lines и deterministic append missing keys.
Тот же clean source зарегистрирован Targeted 822/0/0 в 256.902 s. Первый
прогон остановлен hard deadline с 784 passed и незавершённым Compact file;
он не выдан за passed gate. После проверки отсутствия owned processes/lease
повтор того же public RegisterChange использовал 33 проверенных shard records
и выполнил оставшиеся Compact 38 cases в 233.494 s. Timeout/assertions/inputs
не изменялись. Receipt в source dotenv worktree:
`build/dotenv-writer-5a8ac748afc74f71be9b847721402bef/targeted-registration.json`,
SHA-256 `2f94b0f1d87b28432c83f165847027a9328c492c79edb3fdb5414e8a1c641209`.
Второй настоящий проход на private source
`9b1bab3fe93943cc518726863c1bf695525ea446` от exact 3638706c с теми же двумя
test pins сохранил BOM до Caveman. Затем прежний descriptor
`preserveUtf8Bom=false` удалил его. Hash-match actual Caveman before/after и
UI before доказал следующий owner; этот второй прогон не принят как BOM proof.
First update 146.487 s и штатный restore 62.040 s вернули исходный tree/env
побайтно, old helper прошёл в 1.836 s. Поздние edits/repeats после RED не делались.
Receipt: source UI worktree `build/q23-bomfix-e26a374d/failed-acceptance-safe-recovery.json`,
SHA-256 `0560258b8282dd11864bdfc4bbd3066e1a8b7678c2fe8cf7fc6d48c7954f410b`;
causal receipt SHA-256
`4a895d7984186c76b0a9c799f5dd3c65840ec8a69172725331755c8a40c8ce7a`.
Owner repair Caveman `fe9401c4c480bea78b41d587e9146b3ddeb71c50` прошёл
native 62/0/0 в 52.240 s, сохранив все 51 прежние cases. Fresh переходы теперь
сохраняют BOM. Authentic legacy applying receipts продолжают только свой exact
recorded target; completed receipts не переписываются. Late edit, неверный
after hash и чужая UI policy сохраняют strict refusal/no writes. Source receipt:
`build/caveman-bom-recovery-20261002/qualification.json`, SHA-256
`b70a26008f0ae885b2af2a3953c94b5b262f5fcbd49176c72ceb566682c09087`.
Новая миграция/receipt schema не вводится. Clean exact source зарегистрирован
штатным RegisterChange: Targeted 847/0/0 в 250.374 s, tree
`9612122a5820ed52a939aa8369ca2b7809599b1f`. Первый прогон остановлен
hard deadline 1200 s: 35 passed files / 809 cases и незавершённый Compact.
Он сохранён отдельно и не считается passed gate. После проверки immutable
inputs, producer paths/hashes и отсутствия owned processes тот же public
command использовал ровно 35 проверенных shards / 809 cases и выполнил
Compact 38/0/0 в 228.079 s. Assertions, timeout и workload не менялись.
Queue base `6d3514749d7e8c8ed7fe09f55972bffffd817cb0`, head exact `fe9401c4`.
Authoritative schema-3 passed receipt в общем Git directory:
`.git/itl/runs/20261002-153219-881-targeted-59e4fb558daf41bcb7fa45c8aa1029d1.json`,
SHA-256 `8f09e52e2fe6613911aba0764aa25cd811a3a954d7712f840b18d1803f2459b1`.
Его delivery duration 252.095 s включает обвязку; собственный gate duration
250.374 s взят из check-summary. Эти длительности не складываются.
Третий исходный native сценарий квалифицирован отдельно; первые RED не скрываются
изменением fixture, Caveman input или воспроизводителя.

### Третий исходный Q23 canary: все 26 file-only checks passed

На exact `fe9401c4` с private source
`7b1de4055f8fc7cd629c473d8432f95488ca9172` и неизменным qualified fork
`25b60321` выполнен тот же public owner journey. Единственные private source
изменения — два прежних test pin files. Исходные r33, tree, 381 raw files,
env SHA и topology воспроизведены без обходов. First update 140.699 s сохранил
BOM/CRLF и преобразовал UI manual→essential, Caveman On→auto. Read-only status
2.577 s, immediate repeat 1.868 s и later manual repeat 2.288 s прошли.
Поздний edit менял только UI token: BOM и prefix/suffix hashes сохранены.
Защитный restore refusal 6.821 s не менял captured state. После сохранения
поздних пользовательских байтов и восстановления только известного fixture
after-state исходный public restore прошёл в 52.765 s; receipts не редактировались.
Повтор restore 12.751 s и actual old helper help 2.141 s прошли.

Final tree `fa481f93f9335aad58f13c1f00735f69fc0f33ed` и `.dev.env` SHA-256
`5700f6b3575916f73b0787f9764c61769e619cc5b7d032690d1f8f7be5ffd0b7`
совпадают с оригиналом побайтно; UI/Caveman receipts отсутствуют после rollback.
Все шесть защищённых roots/индексов и 118 named proof/runtime/guard files
остались неизменными, включая оба предыдущих RED. Raw 761 source files и
private producer inputs также неизменны. Итог в source UI worktree:
`build/q23-caveman-bom-be631766/file-only-qualification.json`, SHA-256
`ca2490bf2d5ec1e4bac44d3d530d4be6c641f64170f133fc58e3720093a53832`.
Qualification serializer сначала имел PowerShell bare-false typo; исходный
driver failure сохранён, после исправления повторялся только read-only serializer,
не операции обновления. Этот canary не выдан за live 1C/MCP/UI acceptance.

Full проверяет код, installer, адаптеры, validators, overlay и renderer. Он
не доказывает выполнение LLM evals, обнаружение skills всеми клиентами,
живые MCP providers, загрузку изменённых метаданных в платформу или UI outcome.
Структурные проверки объектов Template/IntegrationService и UUID сохранены;
прежняя platform acceptance остаётся со своей исходной identity.

Production pin остаётся r36. Stage A support и его согласуемый publication plan
не меняются. File-only managed Q23 canary принят на указанной exact identity;
задачи 12.1–12.2 до требуемой общей приёмки остаются открыты. Standalone QA
lifecycle для managed ITL и предложенная multi-file OpenCode адаптация не
квалифицированы этим Full. Внешнее хранилище OpenSpec остаётся отдельной задачей.
