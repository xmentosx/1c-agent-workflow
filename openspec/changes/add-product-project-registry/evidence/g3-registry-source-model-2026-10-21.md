# G3: registry и различия проекта/MCP-источника, 2026-10-21

**Source alignment 2.1/2.1b выполнен; full G3 / AC-39 открыт.** Основание — отдельное разрешение пользователя привести реализацию к обновлённой модели. [JSON](g3-registry-source-model-2026-10-21.json) содержит exact runtime inputs, тесты, paired Startup и raw references. Source base `b747fa8f64eb910269b1d9d40c5e8a11fd6d31d5`; последующий commit/Targeted/регистрация принадлежат existing delivery ledger очереди `product-project-registry-g2`.

## Что изменено

Существующие schema/catalog resolver принимают optional `sources.origin.productId/projectId`, `roles.usage` (`project`, `base-product`, `reference-product`), `roles.limitations` и `projects.customizations`. Краткие notes ограничены 512 символами и 8 ссылками по 512 символов; ссылки на продукт/проект проверяются, origin project должен принадлежать указанному origin product. `inherit` может уточнить назначение/ограничения явно выбранного источника нижнего слоя. Product relation сама по себе MCP не выбирает. Legacy неизвестное остаётся `incomplete`, заявленный собственный проект с чужим origin project — `needs-review`; значения не выводятся из имени endpoint или native IDs.

Тот же endpoint/context owner проецирует опубликованные configurationName/version/indexedAt/status/date из registry; preference — server metadata, затем существующая configuration запись. Source version не становится версией local/custom проекта. Preview и публичный `context` показывают project/base product, project differences и выбранные Code/Graph origin/usage/limitations. Доработки входят в knowledge/context hash, не в settings hash; source role/origin входят в existing settings projection. Нет второго resolver, реестра, updater или startup probe.

Read-only optional observation сохраняет exact endpoint, полезное чтение, Graph project/namespace и отдельное доказательство native activation. Registry version constraint проверяется по registry; старый exact revision pin не объявляется выполненным. Code sourceKey/stamp, Graph generation/manifest и равенство продуктов проекта/source больше не admission conditions. Metadata call опционален; одного HTTP/file-only результата недостаточно для native activation. Invalid/empty/wrong endpoint/scope чтение не принято; продолжение — existing client sync/reload/read либо local evidence. Обычные команды не запускают такой diagnostic автоматически.

Ненужный `vibecoding1c-mcp-host/code-source-identity` candidate удалён вместе с его отдельным тестом/quality path. Host installer больше не выставляет его opt-in env и не публикует выдуманный sourceKey/contractVersion; существующие published configuration/index metadata и native selectors сохранены. Образы/Code/Graph на серверах не изменялись, индексация не запускалась. Остальные host/native transport regressions сохранены.

## Проверки и границы

| Проверка | Результат | Граница |
|---|---|---|
| Focused Context/Registry/Setup/Apply/HostTooling/HostNativeTransport | 314 passed, 0 failed/skipped; 6 executed workers, reuse 0 | Source owner suites до последнего compact diagnostic изменения |
| Публичный context и preservation | 33/33; config/applied/operation/selection/managed/client bytes и mtime прежние | Private TestDrive, no refresh, без installed 1C |
| Финальные Context/Setup после удаления дубликата metadata | 55/55, 0 failed/skipped | Те же две owner suites, не сумма с предыдущими прогонами |
| Custom PM5 КОРП → типовой PM5 КОРП | Schema/resolver/public preview/context + настоящий native Code/Graph read passed | Custom факт требует local/project evidence; native Codex app-server core/API, не desktop frontend |
| PM5 ПРОФ → PM5 КОРП | Schema/resolver/public context и существующий applicability resolver passed: общая область допустима, исключённая КОРП-область не доступна в ПРОФ | Fresh native read **unverified**: Graph handshake failure, затем Code handshake failure. Нет подмены fixtures/replay результатом live acceptance |
| Wrong endpoint / native project / namespace / HTTP masquerade / disabled / legacy fields | Owner regressions passed; captured custom observation также отвергает wrong endpoint/namespace | Последние два — comparator replays, не новый реальный wrong-endpoint/reload прогон |
| Registry metadata | Из существующего local published cache: УправлениеПроектамиКОРП 5.0.3.66, indexedAt `2026-10-21T02:14:46.4006997+03:00`, publishedAt `2026-10-21T02:17:02.9317436+03:00`; status отсутствует → null | Кеш не обновлялся, exact текущая revision каждого ответа не утверждается |

Native CLI `0.163.0-alpha.11` проверен по текущему executable SHA и generated local protocol schemas: прежний exe уже отсутствует. Private Codex homes/Unicode roots, ephemeral threads, `turn/start=0`, global config не меняется. Custom pair занял 9.828 s, 4 safe calls; частичные ПРОФ calls и оба transport отказа сохранены в raw RPC. Все попытки ограничены прежним 20 s pair deadline, сверх него нет retry-loop. Отсутствие сети не расширяет разрешения на deploy/reindex. В финальном read-only context 20 protected paths каждого fixture сохранили bytes/mtime. Нативный reload прежнего среза остаётся [историческим proof](g3-source-client-qualification-2026-10-20.md), не новой приёмкой текущего CLI.

Синтетические product IDs, доработка и ПРОФ restriction созданы только для квалификации. Это не заполнение рабочего реестра и не подтверждение реальной карты функциональности. Первый fixture пропустил технический config ID; создан отдельный v2, исходный сохранён. Relation-only PROF fixture исправлен явным binding без изменения runtime. Ошибки console summary/test-selection harness сохранены; exit code сам по себе не считался acceptance.

## Startup и контекст

| Тот же synthetic stand, 20 warm samples/фаза | До median / p95 | После median / p95 | Изменение median |
|---|---|---|---|
| PM4 | 0.458 / 0.509 s | 0.641 / 0.685 s | +0.184 s |
| PM5 | 0.430 / 0.450 s | 0.662 / 0.692 s | +0.232 s |

Цели 1/2 s выполнены, ускорение не заявляется. Baseline снят на чистом source base до изменений тем же already-qualified child harness; его поле `phase=after` означает no-op measurement mode, а отдельные `*-before.json` — фактический baseline. Оба повтора используют те же roots/workload/assertions. По одному fetch/top-level, nested reuse и protected bytes/mtime без изменений. Warm synthetic proof не заменяет полный installed cost/platform proof.

Новые always-on instructions/tool schemas/startup MCP/LLM/embedding calls — 0. On-demand выбранные differences + два source summary: custom 1339 bytes, PROF 1301 bytes UTF-8 compact JSON. Отдельный diagnostic summary — 682 bytes/pair после удаления повторённого registry payload. Полный каталог/карта/raw RPC в prompt не добавлены. Токены без tokenizer/model не измерялись; внутренний server usage этих чтений не инструментировался и не объявляется нулевым.

## Остаток

Продолжить native ПРОФ и актуальный reload после восстановления доступности выбранных endpoints; затем отдельные frontend/другие clients/installed/Windows 10/Server terminal критерии прежней матрицы. AC-08/39 не закрываются этим source срезом. Перед выпуском по-прежнему обязательно реальное наполнение AC-36–38: продукты/проекты/настройки, origin/назначение/ограничения, доработки и подтверждённая карта функций. Старые stands, failed copies, capsule и raw proof сохранены.

Память использует готовую selected projection в будущем consumer; шесть областей/home/grants/applicability/Q1–Q7/D9/ai_rules_1c/optional OpenViking не меняются. G4/consumer/AC-43/G5/44 не реализованы и не приняты. Gate 6 не исправлялся/не запускался; working-project migration, публикация/push и server deployment не выполнялись.

## Коррекция границы proof после client qualification

[Последующий client/installed result](g3-clients-installed-2026-10-21.md#сохранность-стоимость-и-исправление-прежнего-evidence-claim) установил: `Get-ItlMcpFileState` сохраняет SHA, не mtime. Прежний all-20 guard доказывает bytes, но заявленные timestamps им не установлены; historical JSON не переписывается. Независимые Startup receipt timestamp controls не затронуты. Новая context проверка явно сняла SHA+actual mtime_ns 20 paths до/после и passed; native Kilo ранее добавил `$schema` в два fixture config файла, поэтому сохранность за весь день не заявляется. Default CLI nested source values скрыты PowerShell formatter, хотя DTO корректен: task 3.5 остаётся открытой. Последующий native ПРОФ/reload proof имеет отдельный успешный срез и не отменяет исходные failed runs.
