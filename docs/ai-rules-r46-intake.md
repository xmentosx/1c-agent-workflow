# R46: полный перенос upstream 2f640143

Кандидат реконструирован непосредственно от
`2f640143756ecd01fed42100e412632aa9082385` на `upgrade/main-2f640143-r46`.
Точный fork commit — `85b2892bbd6f5927a5dd47faef84b79dc6b89736`.
Предыдущий downstream — r45 `b5177c16b236a9177d2c18e23600c5daaf9ce993`:
его дерево совпадает с r44 `0e304aaa7989df1daaec1fc4b7b38e419188aec9`.
Старые refs и свидетельства не заменяются. Источник workflow —
`e6f342f046ad5471c5d60709cd35cb9057d2cfa6`, включающий согласованные изменения
lifecycle, production preparation и каталога. Поставка в этом change ограничена
локальной подготовкой, проверками и RegisterChange; публикация не разрешена.

## Принятые решения

- Принят весь upstream delta от `5700f54` до `2f640143`: 39 файлов,
  включая исправления CFE, событий/параметров форм, прав ролей, порядка объектов,
  PowerShell Dynamic и актуальный каталог KD20.
- По прямому решению пользователя приняты HTTP endpoint поддержки и его
  исключение `/doctor` без дополнительной downstream политики. Пользовательский
  `SUPPORT_API_URL` сохраняет прежний приоритет.
- В `db-update.ps1` сохранён `Assert-ItlLifecycleOwnership` и добавлены
  upstream `auto/disable`. В каталоге MCP сохранены ITL ROCTUP и managed
  Vanessa UI, добавлен условный KD20. Это два разрешённых текстовых конфликта.
- В генераторах сохранены исправления XML-порядка, Representation, явного
  false и возврат ошибки `cf-validate`. `NEW_OBJECT_POSITION` принят как upstream:
  end по умолчанию, byName по настройке; CFE заимствование сохраняет свой порядок.
- Политика AI из r44 сохранена: механическое опровержение, проверка реальных
  дефектов, timeout/компенсация auto, required, запрет слепого повтора,
  свежесть доказательств и независимые ITL readiness/repair ограничения.
- Актуальный managed `USER-RULES` workflow остаётся владельцем development /
  production preparation. Его явный приоритет над generic Gate 6 сохранён:
  компиляция/применимость обязательны, полный CheckConfig выбирает существующий
  helper по ResultPurpose. Generic fork ladder не становится вторым загрузчиком.
- Каталог проектов, его operation-local snapshot, источник/namespace и readiness
  не заменяются generic MCP aliases или business ID. KD20 не устанавливается,
  sandbox не выбирается, память/Cognee не включается этим обновлением.

## Проверки и границы

Существующий schema-3 ledger пересчитан от r45 и точного upstream; прежние
причины решений сохранены. Prepare/Verify и overlay-lock проверяют покрытие,
источники, managed targets и фактические hashes. Новый CFE regression включён
в существующий Full catalog форка. Новые owner tests исполняют оба компилятора
форм и проверяют File-safe Dynamic вместе с реальным managed отказом.

Первый Full: 181/181 Pester, затем rules-validator остановился на
`dev-standards-env.md`: 40966 при лимите 40960 нормализованных UTF-8 байт.
Удалён только дублирующий display label `(KD20)` рядом с `1c-kd20` в таблице
TOOL_CONVERSION; оба имени остаются в профильном KD20 catalog. Trigger,
обязательное действие, запреты, исключения, precedence и исход отказа сохранены.
Итоговый размер 40959 байт; предел не изменён. Относительно r45 справочник
вырос с 40895 на 64 байта (грубая оценка 16 токенов по bytes/4).
AGENTS/USER-RULES побайтно прежние; always-on delta 0, измеренные full-cycle
138084 и subagent-start 30616 байт не изменились. Начальный failure сохранён
в `build/test-results/r46-initial-failed` форка; новый exact-commit Full использует
отдельный `build/test-results/r46-final`.

Окончательная schema-3 Verify: 297 решений, 0 blockers. Hash contract совпадает
со штатными UTF-8 readers: BOM декодируется, CRLF нормализуется только для
текстового fingerprint; Git bytes и транспорт 1C не переписываются.
Пять файлов AI policy/skill и gate-scenarios сохранены из r44 побайтно.

На окончательном commit прошли:

- fork Full: 181/181 Pester, 0 failed/skipped; 19/19 стадий, clean/reusable;
  `build/test-results/qualification/r46-final.json` и
  `build/test-results/r46-final/check-summary.json` в fork checkout;
- metadata-tools 61/61 и новый cfe-borrow 12/12 в составе этого Full;
- Python ports 59 passed / 1 skipped: symlink negative case недоступен без
  соответствующего права Windows (WinError 1314); skip сохранён, elevation не применялась;
- source 12-client init/update/doctor: Protocol 1.1 / McpMode delegated,
  byte-idempotence, пользовательские настройки/LLM-RULES и общие Codex prompts
  сохранены; `build/r46-intake/compatibility-final.log` в workflow checkout;
- schema-3 Verify и overlay-lock: 297 решений, без расхождений.

Штатный fork publisher без Push повторно проверил reusable qualification и
подготовил только локальные `itl-main-2f640143-r46` и
`release/itl-main-2f640143-r46`, с canonical annotation
`upstream=refs/heads/main@2f640143756ecd01fed42100e412632aa9082385`.
Full выше выполнен с explicit SHA; эти локальные proof/ref не подменяют
парную квалификацию source или публикацию. `compatibilityStatus` остаётся
pending до штатной парной квалификации поставки. Structural validator не
получал внешний standards corpus: body/heading checks штатно пропущены,
а отсутствие этих проверок не объявляется выполненной проверкой стандартов.

Один source commit регистрируется через `source-delivery.ps1 -Action RegisterChange`
в очереди `ai-rules-upstream-r46` с base `e6f342f0`. Регистрация владеет Targeted
и записывает точные base/head/results в общий Git ledger; актуальное состояние
читается через Status, без второго журнала mutable delivery state в этом документе.

Локальные тесты не доказывают загрузку CFE на платформе, работу KD20 или
полную приёмку каталога G3. Для будущей поставки сохраняются исходные native
сценарии: Configuration.xml в частичном списке плюс дефект вне списка,
load/dump заимствованной формы и её зависимостей, сохранение модулей и
визуального поведения. AC-39/наполнение каталога и G4 памяти этим change
не закрываются. Рабочие проекты и серверы не изменяются.
