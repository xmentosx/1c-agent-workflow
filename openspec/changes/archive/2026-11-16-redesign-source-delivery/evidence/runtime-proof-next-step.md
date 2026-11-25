# Следующая единица A.6: фактический runtime Pester child

Обновление: owner-local реализация и focused приёмка описаны в
[pester-runtime-proof.md](pester-runtime-proof.md). Ниже сохранена исходная
постановка; её формулировки о выполняющейся регистрации относятся к моменту
планирования. Текущая база этой единицы — `ccadf4482655810203119b6088a79c5e2bbd034d`.

База следующей работы: 747aa75facdbd5a16f386e8d3c743d321d772010.
Branch codex/source-runtime-proof, повторно использован чистый managed worktree
redesign-source-delivery. Зарегистрированный JSON branch сохранён.
747aa75f в другом worktree сейчас проходит единственный RegisterChange;
этот файл не изменяет проверяемое дерево той регистрации.

Подтверждённая проблема: Get-ShardInputDigest использует родительский
PSVersionTable/Get-Module -ListAvailable Pester, а Start-PesterFileEntry запускает
powershell.exe. run-pester-shard импортирует Pester самостоятельно. Следовательно,
родительский fingerprint не устанавливает фактическую child/module identity.

Предлагаемое owner-local исправление без новой общей authority:

1. Разрешить абсолютный child executable один раз. Использовать его и в probe,
   и во всех shard launches через существующего process owner. Сохранить UTF-8,
   shared quoting и очистку Core PSModulePath при запуске Desktop.
2. Получить identity из реального child с тем же module-path initialization и
   Import-Module Pester -MinimumVersion 5.0.0 -Force, что в настоящем worker.
   Включить версию/edition PowerShell, executable и engine assembly SHA,
   фактически импортированный Pester и его исполняемые module inputs.
3. Probe выполняется один раз, ограничен по времени. Неизвестная identity
   отключает reuse; исходные тесты продолжают исполняться. Сохранить причину
   в bounded summary/именованном артефакте. Не добавлять новый общий запрет.
4. Worker записывает фактическую identity результата. Cache admission требует
   совпадения квалифицированной identity и SHA-protected result. Отсутствие
   identity в старом proof не означает совпадение. Не принимать старый key
   только потому, что parent version сохранилась.
5. Legacy worker-count keys допустимы лишь когда сам сохранённый result имеет
   проверяемую matching child identity. Старые записи без неё один раз холодно
   исполняются. Не переписывать старые cache records вручную.
6. Привязать новый stateless helper к shared worker inputs и существующему
   checker owner. Не вводить отдельный coordinator, service или state store.

Приёмка: вызов из Core действительно квалифицирует Desktop child; одинаковая
identity переиспользуется между worktrees; изменение фактического engine/module
input инвалидирует proof; неизвестная identity исполняет оригинальную задачу;
legacy proof без identity не используется; доказанный legacy scheduler key с
matching child identity остаётся применимым. Сохранить tamper/path/owner guards,
Unicode whitespace path и штатную registration ownership Targeted.

Это проект следующей единицы, не реализованный runtime fix. Измерить добавленную
стоимость probe и cold/warm fingerprints до утверждения об ускорении.

До runtime fix завершено отдельное уточнение catalog-selector inputs:
HostTestSelection принадлежит source-quality-catalog, catalog-only запускает
два static suites, component-only запускает свой runtime suite и общий HostTooling.
34 focused cases прошли. Эта единица должна регистрироваться только после
успешного включения 747aa75f, чтобы Targeted проверял её собственную дельту,
а не повторял ещё не включённый перенос всех host/process suites.
