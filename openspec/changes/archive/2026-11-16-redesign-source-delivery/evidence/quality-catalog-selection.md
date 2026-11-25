# Каталог и process suites имеют разные изменения входов

До разделения `tests/quality-contracts.json` выбирал шесть файлов
source-quality-gate, включая LocalQualityGate (~608 s) и serial ReleaseGate
(~645 s по последней регистрации). Большинство тяжёлых сценариев создаёт свой
fixture catalog; изменение production owner mapping не требует повторять эти
процессы, но должно делать прежний Full proof неприменимым.

В SourceQualityCatalog перенесены семь самостоятельных It из LocalQualityGate,
полный Describe Develop journey catalog hard budgets и полный Describe Shared
Release budget projection. Assertions и тела сценариев сохранены, кроме
обоснованных strict-selection ожиданий ниже. Transfer identity записана в
`quality-catalog-transfers.csv`; одноразовый producer рядом.

Production runner/quality resolver не изменён. Использован существующий
`reuseInputPaths`: catalog больше не выбирает шесть process suites через paths,
но остаётся входом их fingerprint. Изменения production gate scripts продолжают
выбирать process suites через прежний source-quality-gate и новый static suite.
Изменение самого process-suite файла выбирает этот файл штатным direct route.
Budget consumers source-delivery-process/stages выбирают перенесённые проверки.

## Намеренные изменения ожиданий

- Новый owner source-quality-catalog появился в process-only и stabilization E
  selection; добавлен соответствующий suite, прежние обязательные consumers сохранены.
- Исторический 57-file cohort и Gate 6 проверяются отдельно и сохранены.
  Mantis extension добавляет реального helper consumer.
- Catalog-only больше не добавляет пять посторонних process suites в расширенный
  cohort. Строгий список разницы теперь содержит LocalQualityGate (его файл явно
  изменён в сценарии) и SourceQualityCatalog. Историческая модель времени оставлена
  как историческое сравнение, не объявляется измерением нового пути.
- Новый строгий regression требует единственный SourceQualityCatalog для
  catalog-only change. Второй regression вызывает реальные fingerprint-функции
  для всех шести прежних consumers: неизменённые входы дают тот же digest,
  изменённые catalog bytes меняют каждый digest. Fixture создаёт все объявленные
  reuse dependencies, отсутствие которых по-прежнему запрещает cache proof.

## Приёмка

Штатный focused test wrapper, Windows PowerShell 5.1 / Pester 5.8.0:
24 expanded cases passed, 0 failed / 0 skipped. Worker 11012 ms,
fingerprint plan 1867 ms. Первые три failures локализованы до регистрации:
два старых точных ожидания selection и неполный dependency fixture нового
fingerprint-теста. Исправлены ожидаемые новые selections и полнота fixture;
runtime assertions и negative cases не ослаблялись.

Это focused proof одного suite; время полной регистрации/выпуска ещё не измерено.
LocalQualityGate и ReleaseGate изменены переносом, поэтому их оставшиеся process
сценарии должны один раз пройти регистрацию данной единицы. Отдельный Full
ради окончания разработки не требуется.

## Уточнение входов селектора после 747aa75f

Review выявил недостающий input нового HostTestSelection: его прежний
standalone-mcp-host owner не включал catalog bytes в digest. Исправление в
следующей единице передаёт selector существующему source-quality-catalog owner.
Catalog-only теперь выбирает два дешёвых файла (24 + 10 cases); изменение
компонента выбирает его реальный suite и общий HostTooling, не повторяя
неизменённый selector. Набор assertions самого селектора сохранён; ожидания
строго отражают эту новую границу.

Fingerprint regression расширен на selector: все семь consumers сохраняют
точный digest для неизменённых входов и меняют его после изменения catalog bytes.
Focused proof двух файлов: 34 passed, 0 failed / 0 skipped; worker span 13619 ms.
Это исправляет конкретную пропущенную dependency, а не снимает обязательный proof.
