# G3: содержательные изменения каталога на установленном PM5, 2026-10-24

**Итоговый прогон: 10/10 публичных команд, exit 0; восемь содержательных изменений каталога применены. Новых дефектов workflow в этом наборе не обнаружено.** Это дополнение к прежней квалификации, а не полная приёмка G3/AC-39. Принятое пользователем отклонение warm Startup 49.731мс не блокирует G3; новые performance batches не запускались. OpenCode SKIPPED; Gate 6, G4, рабочая миграция и публикация не выполнялись.

## Стенд и способ проверки

Прежняя изолированная PM5 КОРП копия `C:\itlj\g3-pm5-current-20261022\q Проект\develop-c2c570fe1ec5-d109a95dc1db-4b0defed\project`, sibling `branch`; выбранные `pm5-core-development` / `pm5-corp`, membership Kilo+Cursor. Installed workflow `78f11bd861543dfea89eab722d4f5b869dd64c25`, source checkout `acc7e771fe0666179692f3af5dc91a749d098fd4`; десять relevant source/installed runtime hashes совпали. ai_rules r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f` сохранён. Нового package update не требовалось: изменились только документы.

Windows PowerShell 5.1 запускал установленный публичный `agent-1c.ps1` через existing UTF-8 native capture helper. Девять вызовов `sync-client-mcp -Client kilocode` включают prime и восемь изменений; десятый — read-only `vibecoding1c-mcp-status -CatalogAction context`. Каталог клонирован в новый отдельный local bare origin и author/cache внутри ignored evidence. Fixture-коммиты отправлялись только в этот локальный origin; исходный origin и общий каталог не менялись. Использована existing exclusive fixture lease.

СППР/Mantis instances, IDs и дополнительный продукт/область/home в этом наборе синтетические. Они не являются наполнением выпуска или утверждённой картой продуктовых знаний. Реальные серверные записи, native MCP tool calls, model turns и 1С-запуски тестом не выполнялись. Успех конфигурации не объявляется reload/активацией инструментов в IDE.

## Фактические результаты

| Проверка | Результат и граница |
|---|---|
| Prime | Текущий bound PM5 принимает прежний snapshot с теми же IDs; клиентские файлы без записи |
| Переименование выбранного проекта | Новый Unicode `projectName` появился в applied context; `projectId`/`productId`, `settingsHash`/`knowledgeHash` сохранены |
| Типовой → доработанный проект | `customized=true` и описание доработки появились в `projectContext`; изменён knowledge hash, settings hash сохранён; MCP-источник прежний |
| Связи СППР/Mantis | Новый СППР project ID, Mantis project list/search subset/create route появились в контексте до завершения обычного sync; изменён settings hash, knowledge hash сохранён |
| Карта функциональности и home | Explicit `availableIn` и optional home попали в применимую область; изменён knowledge hash, settings hash сохранён |
| Смена home | Новый home/read candidate применён из нового immutable SHA; MCP-файлы не записаны, данные памяти не переносились |
| Удаление home | Optional home исчез, автоматической подстановки нет; read candidates вернулись к одному выбранному продукту |
| Замена/удаление связей | Mantis list заменён целиком, прежние IDs отсутствуют; удалённая связь СППР отсутствует |
| Доработанный → типовой проект | `customized=false`, старое описание отсутствует; knowledge hash обновлён без изменения endpoint/settings |
| Публичный context CLI | Stdout целиком читается как JSON и содержит правильный выбранный project ID |

Для каждого из девяти sync проверены exact applied catalog SHA, стабильные IDs, неизменные descriptor/lock и bytes+mtime Kilo/Cursor. Все девять защищённых файлов соседнего unbound worktree сравнивались после каждой команды. Это native installed PM5 proof для AC-02/11/23/29 и инвалидации после publisher-only оптимизации в указанной границе; не native memory consumer/G5 и не вся platform/client/lifecycle матрица.

## Исходные ошибки проверочного скрипта

Сохранены две остановки до публичных команд: Windows PowerShell отверг Unicode script без UTF-8 BOM; затем harness попытался использовать read-only `$HOME`. Исправлены только encoding и имя локальной переменной. В первом функциональном наборе восемь CLI-команд завершились exit 0; проверка правильно удалённого `sppr` остановилась из-за прямого чтения отсутствующего свойства под StrictMode. Проверка заменена явной проверкой отсутствия свойства, требование удаления не ослаблено. Исходный workload целиком повторён в отдельной evidence directory; итоговый набор прошёл 10/10. Это ошибки harness, не подтверждённые дефекты workflow; все исходные logs/failure и teardown records сохранены.

## Сохранность

Оба прогона выполнили test-actor CAS teardown девяти архивированных main inputs; это снятие внесённой тестом подготовки, а не новая приёмка product restore. Финальные **46/46** protected paths совпали с исходным состоянием по SHA, mtime и отсутствию файлов. Main/sibling HEAD и clean tracked/untracked state сохранены. Database **3295928320 bytes**, SHA `c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045` unchanged. Повторно проверены 21 historical file, четыре старых roots и 11 capsule objects. Исходный live seed по-прежнему отсутствует; capsule остаётся доказательством только согласованного snapshot route.

## Текущий остаток

| Область | Статус после этого набора |
|---|---|
| B1 | Win11 local subset сохранён; Win10/Server2019+/terminal/независимые пользователи UNVERIFIED: подготовленных стендов нет |
| B2 | Реальная изолированная PM4 installation UNVERIFIED; source/file fixtures не заменяют базу |
| B3 | PM5 catalog/update/association/recovery subsets и новые metadata transitions подтверждены. Full fresh init/new branch/refresh/managed downgrade и оставшиеся foreground first legacy choices этим набором не проверялись; это отдельные оставшиеся сценарии, а не новые обнаруженные дефекты. Gate 6 не запускался |
| B4 | Прежние Kilo/Cursor IDE и Codex core/API proof сохранены. Codex Desktop/model UI и восемь остальных native clients/full platform/lifecycle не приняты; native desktop automation в текущей tool session недоступна, новые клиенты/профили не устанавливались. OpenCode SKIPPED |
| Стоимость | Warm median excess принят пользователем и не блокирует G3. Другие непроверенные cost scopes не переименованы в PASS; новых замеров/оптимизаций ради порога нет |
| До первого выпуска | Owner-confirmed products/projects/settings/functionality population AC-36–38 / memory AC-44 остаётся обязательным отдельным этапом; синтетические записи этого набора его не закрывают |

**Полная G3/AC-39 остаётся частично квалифицированной.** В этом наборе нет нового функционального blocker; известные пробелы инфраструктуры и оставшиеся сценарии перечислены отдельно. Решение о warm goal не сокращает поддержку, не даёт разрешение на Gate6/G4/рабочую миграцию/публикацию и не закрывает consumer/G5.

## Артефакты

[JSON результата](g3-project-metadata-functional-2026-10-24.json) хранит exact per-case revisions, runtime hashes, stand identity, границы и manifests. Первый raw root: `build/test-results/g3/project-metadata-functional-20261024`, manifest SHA `e85588aa87832a74287622597d3afe8ce90e04fee78b681c75420a444104ed1b`, 637 files. Итоговый: `build/test-results/g3/project-metadata-functional-replay-20261024`, manifest SHA `aee7d912de430926b9f8ffe53b4f52f66198fac77f6532e742a11d44e28d9e95`, 655 files. Все 18 фактических публичных команд сохранены: восемь в первом наборе и десять в полном повторе. Поздние validation/registration logs хранятся отдельно; штатный RegisterChange владеет своим Targeted, не публикацией.
