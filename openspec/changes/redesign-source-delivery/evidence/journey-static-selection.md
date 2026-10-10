# Статические journey expectations должны проверяться при правке каталога

Первый RegisterChange runtime единицы `42ba85bacf751c2262614051bab4b2ac9e97b4e2`
остановился: 185 passed / 2 failed, raw Targeted 621208 ms, check-summary
619225 ms. Raw record в common Git:
`itl/runs/20261010-223619-607-targeted-ae9f6be8989c4a81829ad9bfb4c17e36.json`.
Очередь осталась на `ccadf448`; публикация не выполнялась.

Все шесть Pester runtime regressions прошли, worker 99940 ms. Отказы:

1. `LocalQualityGate` искал `SpecialFolder::MyDocuments` внутри worker после
   переноса initialization в общий helper. Native Unicode/Core/Desktop proof
   сохранился. Source assertion теперь проверяет authoritative helper, его
   импорт worker и initialization до первого Import-Module Pester.
2. `DevelopE2EQualification` ожидал прежний точный список contract ids.
   `Resolve-DevelopE2EJourneyPlan` намеренно возвращает все найденные owners,
   затем отдельно пересекает их с declared journey routes. Новый test owner
   CodeChecker и static catalog owner процесса доставки корректно появились
   в диагностике. Для обоих путей journeys всё ещё пусты. Фильтровать этих
   owners из production-плана ради старого assertion было бы неверным ремонтом.

Недействительным было ожидание единственности owner, а не запрет лишней 1C
квалификации. Исправлены только два точных диагностических ожидания:
CodeChecker → host-codechecker-tests + standalone-mcp-host;
source-delivery-process → source-delivery-process + source-quality-catalog.
Остальные прежние owner assertions, reason и отсутствие journeys сохранены.

Два полностью статических It (`validates exact journey names...` и
`routes each installed owner...`) перенесены целиком из process suite в
SourceQualityCatalog. Кроме описанных двух ожиданий их тела и предусловия
сохранены. Добавлена matrix восьми representative component paths, которая
проверяет точный diagnostic owner set, пустые journeys, unknownPaths и fullPaths.
Это другая граница, чем выбор Python/Node suites в HostTestSelection:
добавленный source-test owner не должен включать installed 1C journey.

SourceQualityCatalog уже принадлежит существующему checker owner с входами
develop-e2e-qualification/quality-contracts/git-path-list. Каталог выбирает его
напрямую. Поэтому новые static assertions исполняются при catalog-only изменении
и сохраняют применимость proof только при совпадении production inputs.
Процессные qualification/continuation regressions остаются в исходном suite;
условия Full, fresh proof и publication не менялись.

Focused proof: восемь component cases, exact journey catalog и исправленный
worker source-boundary case прошли в первом filtered запуске; полный перенесённый
owner-route case после уточнения process diagnostic expectation прошёл за
11.64 s. Это не новая успешная регистрация. Named artifacts:
`build/redesign-source-delivery/runtime-proof/first-registration-failure/`,
`host-journey-plans.json`, `journey-test-transfer.json`,
`failure-repair-focused.xml`, `journey-route-repair.xml`.

Прежняя регистрация catalog split не исполняла эту process suite: отдельный
статический catalog owner выбирал быстрые наборы, но оставшиеся статические
journey assertions были спрятаны в process-файле. Это пробел выбора проверки,
а не подтверждённое ложное reuse. Перенос закрывает его до следующего выпуска.

Повтор RegisterChange выполняется после этой диагностики на исправленном
immutable head. Неизменённые passed shards допускают штатное переиспользование;
failed файлы и новые static inputs требуют исполнения. A/B целиком не завершены.
