# G3: повреждённый кэш и локальная квитанция на текущем PM5, 2026-10-22

**Восемь native controls passed в указанной области; полный G3 / AC-39 открыт.** [JSON с identities, измерениями и SHA raw evidence](g3-pm5-cache-record-qualification-2026-10-22.json). Это продолжение [первого update на том же стенде](g3-post-copy-startup-repair-2026-10-22.md), без изменения runtime, критериев или архитектуры.

Source `17a134b49ec8a1060f38a121383a258fe175e474`; установленный runtime `176bd2fa6b8d107d33df2b92600e0c14d365ee45`, controlled ai_rules_1c r43 / `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Три runtime файла последнего исправления сверены SHA source=installed. Main `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch`: прежние HEAD/descriptor/lock, main bound PM5 КОРП / `pm5-core-development`, branch unbound; Kilo+Cursor settings сохранены. Это действующий тестовый пакет, а не утверждение об опубликованном выпуске.

## Новые проверки

Все вызовы — installed public `agent-1c.ps1` через shared UTF-8 native capture под fixture lease, Windows PowerShell 5.1. Основная команда — `vibecoding1c-mcp-write-client-config`; она не требует запуска 1С/Gate 6. Отдельная копия cache с whitespace+Cyrillic path создана `git clone --no-hardlinks`, её containment проверен; обычный cache и origin не менялись.

| Existing AC | Условия / наблюдение | Результат |
|---|---|---|
| AC-17/25 | HEAD отдельного cache ссылается на отсутствующую ветку, но pinned object доступен | Bound main: offline warning, main reached, exit 0, 6.314 s. Unbound explicit select: CATALOG_REFRESH_UNAVAILABLE, exit 1, 4.707 s, ассоциация не записана |
| AC-17/25 | Затем все Git objects той же независимой копии недоступны: objects сохранены под другим именем, без удаления | Bound main использует saved selected projection с refresh/validation warning, main reached, exit 0, 5.893 s. Unbound select отказывает, exit 1, 3.588 s, без guessed source |
| AC-16/17/26 | В applied record сохранён валидный JSON, намеренно испорчен только contextHash | Обычная команда: CATALOG_LOCAL_RECORD_INVALID: applied, exit 1, 3.028 s, основная фаза не запущена. Catalog status: exit 0 / invalid-applied, 3.212 s, без записи |
| AC-15/26 | Отменена только собственная fault injection, возвращены точные bytes и прежний mtime; затем public command | Main reached, exit 0, 5.352 s, no-write. Это проверка возврата тестового input, **не** native owned recovery повреждённой квитанции |
| AC-16/24 | Public cancel при завершённой операции | idle / cancellationRequested=false, exit 0, 3.037 s; новый cancel marker не создан. Это **не** интерактивная отмена или cooperative cancel во время записи |

На каждом соответствующем шаге девять protected paths/root сохраняют SHA, actual mtime и отсутствие файла; из них восемь существующих и absent cancel marker на main, отсутствующие paths sibling учитываются отдельно. Итоговые оба roots совпадают с baseline и предыдущим final-state. В faulted-cache фазе trace содержит **0 fetch/clone**: отказ происходит до transport; setup clone и healthy check вне этого счётчика. Это не повтор stalled-network deadline/cleanup qualification.

Первый harness attempt сохранён: native exit 0 и правдивый offline warning были ошибочно отвергнуты узким matcher, ожидавшим только validation warning. Pinned object читался несмотря на сломанный HEAD. В отдельном повторе учтены оба допустимых freshness warnings и дополнительно проверена полная недоступность objects. Исходный workload/guard/no-write assertions сохранены; всего 9 captured native calls, из них 8 в финальном принятом срезе, включая три ожидаемых exit 1. Runtime не исправлялся и тестовые требования не ослаблялись.

## Актуальный остаток G3

Предыдущие accepted source/native subsets остаются в [общей матрице](g3-final-qualification-2026-10-20.md) и linked reports. Новое evidence закрывает installed corrupt-cache **subset** AC-17 и invalid-applied admission/diagnostic **subset** AC-16/26; checkbox полных задач/AC-39 не закрывается.

| Критерии / существующий owner | Что остаётся / достаточное продолжение |
|---|---|
| AC-16/24/26, operation/input | Actual foreground cancel/no answer, pinned cooperative cancel и owned recovery повреждённого applied в установленном сценарии; idle/fault reversal не заменяют этот proof |
| AC-13/14/18/21/22/31–33/39, bootstrap/lifecycle/setup | Остальные original fresh init, first-pass choose/create/later, pending → опубликованный ID, branch/refresh/managed downgrade journeys. Исторические bounded PM5 successes сохранены; полный путь не принят. Gate 6 по поручению не выполняется и не исправляется |
| AC-08–12/20/26, existing registry/source/client owners | Прежние ПРОФ → КОРП/custom → typical/native reads/reload/server controls имеют свои inputs/builds; текущий run их не переигрывает. Полная current installed/frontend/CUSTOM/source/routes matrix остаётся открытой. Source metadata — из registry, различия проекта/source явные; native source stamp/патчи Code/Graph не возвращаются в требования |
| AC-19, test stands | PM4 installed, Win10, Server2019+ и независимые terminal users недоступны; ранее пользователь сообщил, что готовых стендов нет. Это unverified поддерживаемые клетки, не сокращение поддержки |
| AC-20/25/39, timing/context | Paired installed Startup/context/token cost и strict stalled-transport child cleanup открыты. Прежние whole CLI около 25 s и late child exits не закрыты локальным cache-fault pass. Нужны отдельные measurements по прежнему workload; цели 1 s/2 s и metadata deadline 10 s прежние |
| AC-36–38, release population | Подтверждённый выпускной перечень продуктов/проектов, resolved настройки и карта функциональности на отдельно опубликованном SHA; pilot-only недостаточен. Обязательно до первого выпуска, не gate разработки G3 |
| Memory4.2/G4/AC-43/G5/44 | Registry dependency остаётся частично принятой; consumer/full memory journey и выпускное наполнение не закрыты. G4 не начинался |

## Стоимость и сохранность

Новых always-on инструкций/tool schemas **0 bytes**, LLM turns/Code/Graph tool calls/Cognee calls **0**. Healthy whole CLI output 477 UTF-8 bytes; offline warnings дали 593/738 bytes. Эти размеры и восемь одиночных whole-CLI durations не являются agent token count, paired Startup overhead, benchmark или network deadline proof; always-on budgets не менялись.

PM5 DB SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045`, 3,295,928,320 bytes, прежний. Main/branch clean; до/после сохранены 21 protected files/четыре старых roots, включая failed copy и семь Gate 6 artifacts. Sealed capsule `c2c570fe…` и все 11 artifact hashes проверены; original raw seed по-прежнему отсутствует, live currentness не заявляется. Кэши с fault и все raw failed/passed attempts сохранены.

Шесть областей, canonical home, Q1–Q7/D9/G2, ai_rules_1c и optional OpenViking прежние; memory opt-in false. **Gate 6, G4, рабочая миграция, server changes, client upgrades и публикация workflow/каталога не выполнялись.** Source commit/registration принадлежат source-delivery ledger и не являются native/full G3 acceptance.
