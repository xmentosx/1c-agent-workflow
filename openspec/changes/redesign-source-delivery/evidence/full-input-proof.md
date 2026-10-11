# Full proof: aggregate reuse и завершение свежей проверки

Причина подтверждена на `b0c882a2`: Test-WorkflowQualification сравнивает
parent PS/version доступного Pester, но не actual child/module bytes и не
per-file external inputs. При exact-tree Full shortcut scheduler вообще
не вызывается. Семь nonreusable host suites могут оказаться пропущены этим
shortcut. Всего каталог объявляет 11 nonreusable suites: четыре Vanessa/OneScript
и семь host suites. Наличие свежей per-shard защиты не закрывает такой обход.

## Выбранный owner-local контракт

Checker остаётся владельцем Full qualification, scheduler — единственным
владельцем fingerprints. Stateless helpers нормализуют и сравнивают manifest;
они не владеют queue, lock, новым cache или recovery. C.2 не реализуется здесь.

- Private scheduler `InputIdentityOnly` использует те же discovered files,
  owner inputs, external inputs и actual worker probe, что обычный запуск.
  Он не запускает тесты и не восстанавливает/пишет shard proof.
- Обычный scheduler сохраняет input manifest из реально завершённых worker
  results. Empty digest, unknown identity и in-flight drift запрещают aggregate
  reuse. Текущий passed результат при этом сохраняется.
- Full schema 4 записывает manifest и честный `reusable`. Старые schema 1–3
  остаются readable passed records при своих исходных условиях, но без нового
  manifest не разрешают пропуск Pester.
- Transport/cache/compatibility promotion принимают корректный passed Full
  schema 4 с `reusable=false`, сохраняя свои exact-tree, JUnit, fork, clean-tree
  и result checks. Transport не является разрешением пропустить тесты.
- Checker различает проверенный Full record и разрешение пропустить Pester.
  При невозможности whole reuse вызывает обычный scheduler: пригодные shards
  переиспользуются, неизвестные/изменённые выполняются. Это continuation исходной
  задачи, а не требование вручную запускать ещё один Full.
- Release сохраняет исходные Full/Develop/E2E проверки. После успешного свежего
  static gate обновляет связь с Full только для повторно проверенного прежнего
  Develop evidence. Journey inputs, hashes, newer-failure и stand/runtime
  checks остаются обязательными; новые E2E успехи не фабрикуются.

## Приёмка

Проверить исходный shortcut на private Git проекте с Unicode/whitespace:
изменённые module bytes, external inputs и nonreusable file не пропускаются.
Unchanged known input set допускает whole reuse; modified/unknown input set
доходит через реальный scheduler до passed исходной задачи. Проверить точный
manifest inventory, duplicate/malformed entries и повреждённый proof.
Сохранить legacy/JUnit/cache/continuation regressions, показать valid passed
nonreusable Full transport и повторную привязку уже проверенного Develop
evidence без ослабления runtime/stand/newer-failure assertions.

Стоимость нового identity-only пути измерить отдельно; не заявлять ускорение
полного выпуска из focused fixture. Внешние Python/Node окружения остаются
nonreusable до реализации B.4; этот контракт делает их честный повтор возможным.

## Выполненная focused приёмка

В ignored `build/redesign-source-delivery/full-input-proof/` сохранены:

- `focused.xml`: 18/0, первоначальные шесть runtime cases, три aggregate cases,
  legacy cache и promotion. `continuation.xml`: 7/0, оба cache transports,
  legacy/schema4 promotion и повторная привязка Develop.
- После выделения aggregate cases в `FullInputProof.Tests.ps1` native cases
  повторно прошли: один Core-parent case и три aggregate cases. В том же запуске
  статический каталог выявил устаревший exact owner set, не учитывавший новый
  owner. Исходные 20 test paths сохраняются, добавлен один новый. Удалён только
  дублирующий Count=20 assertion: точное равенство полного списка остаётся.
  Исторические измерения и сравнение трёх/четырёх workers сохранены; текущий
  резерв дополнительно учитывает стоимость нового файла. `catalog-repair.xml`:
  исправленный сценарий прошёл.
- `external-drift.xml`: 3/0, 63.54 s. Known case дополнительно меняет байты
  объявленного внешнего файла с Unicode/whitespace path при неизменном clean
  Git tree. Новый manifest остаётся valid/reusable, но старый Full получает
  `canReusePester=false`. Реальный scheduler исполняет файл, fresh writer/reader
  снова допускает matching reuse. Unknown external/runtime cases завершают
  исходную задачу успешно с честным `reusable=false`, включая оба transports.
- Повреждённые/duplicate/missing manifest entries отвергнуты. Identity-only
  путь не исполняет fixture test и не создаёт worker result/JUnit. Пять прежних
  runtime It definitions (шесть expanded cases) сохраняются точно по AST;
  `runtime-transfer.json` фиксирует сравнение. Shared fixture helper вынесен
  для двух suites.
- Existing Develop case сохраняет original report/route hashes: изменение
  Full SHA отвергает старую связь, неверный stand запрещает rebind без записи,
  корректный rebind сохраняет прежнее E2E evidence; tamper по-прежнему отвергается.

Scheduling weight нового файла округлён до 64 s по последнему focused запуску.
Это стоимость регрессии, а не измерение ускорения выпуска. Полный identity-only
путь будет измерен отдельно на committed inventory; регистрация этой связной
единицы ещё требуется. Полные Full/Develop/Release и live publication здесь
не запускались. A.6/B.4 и аудит всего каталога ещё не завершены.

## Регистрация и исправление ожидания каталога

Первая регистрация `11680e14` завершилась штатно с failure: 30 завершённых
workers, 530 passed / 1 failed / 0 skipped; check duration 1078017 ms. Единственное
падение — прежний exact contract set для `source-delivery-candidate.ps1` в
`SourceQualityCatalog.Tests.ps1`: новый owner `pester-full-input-proof` намеренно
добавляет независимое aggregate-input доказательство этому caller. Ожидание
обновлено до двух точных owners; требование пустого live journey set сохранено.
Это исправление недействительного ожидания, не изменение production маршрута
или ослабление проверяемого поведения. `journey-owner-repair.xml`: 1/0, 10.43 s;
все исходные assertions того же сценария прошли. Очередь после отказа сохранена
на `b0c882a2`; требуется повторная регистрация исправленной связной единицы.
