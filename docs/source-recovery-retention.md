# Хранение архивов исходных qualification-копий

Владелец — существующий source-delivery supervisor. Только ручной
`scripts/source-delivery.ps1 -Action Cleanup` удаляет просроченные payloads
в общем Git-каталоге `itl/evidence/fixture-cleanup`. Publication sweeps их не
удаляют. Дополнительных служб, locks, установленных настроек или фоновых задач нет.

Предпросмотр без записи:

```powershell
./scripts/source-delivery.ps1 -Action Status -StatusDetail Full
```

`recoveryArchives` показывает политику, точные пути, bytes, `eligible`/`keep`
и причину сохранения. Обычный Summary не сканирует архивы. Предпросмотр не
разрешает последующее удаление: Cleanup заново вычисляет inventory под своей
существующей operation lease и повторяет guards перед удалением.

В исходном `.dev.env` можно задать:

```dotenv
ITL_SOURCE_RECOVERY_RETENTION_DAYS=7
ITL_SOURCE_RECOVERY_KEEP_COUNT=2
```

Это значения по умолчанию; process environment имеет приоритет. В отдельном
worktree без своего `.dev.env` читается `.dev.env` рядом с common `.git`.
Допускаются неотрицательные целые: `RETENTION_DAYS=0` отключает удаление,
`KEEP_COUNT=0` отключает только квоту. Две новейшие owned попытки сохраняются
отдельно для Develop и Release, даже после истечения срока. Возраст считается
по новейшему файлу попытки, кроме самой квитанции retention.

Удаляются только `recovery.zip`, `source.bundle`, `branch-working.patch` и
`project-working.patch` в корне распознанной попытки или `archived-inactive`.
Требуется известный cleanup proof с точным common Git, candidate и исходным
copyRoot; исходная копия должна отсутствовать. Неизвестные/старые каталоги без
такого proof сохраняются и показываются как `ownership-unverified`. Нельзя
назначать им владельца только по имени или возрасту.

Любая незакрытая publication attempt, другая delivery operation, ссылка из
неудалённого ledger resource или plan checkpoint сохраняет архив. Нечитаемое
состояние, изменившийся inventory/policy, reparse point и открытый reader/writer
также сохраняют данные. Это warning для уборки, а не новый барьер публикации.
Продолжение: устранить указанную причину через прежнего владельца и повторить
тот же Cleanup; не удалять checkpoint или lease ради освобождения места.

Перед первым удалением открываются все payloads попытки с запретом readers и
writers: занятый bundle сохраняет и соответствующий ZIP с patches. SHA-256
считается под этими handles. Квитанция `retention.json` сначала сохраняет
`pending`, затем `removed`.
При ошибке она не утверждает успешное удаление. Повтор под той же operation
lease обрабатывает оставшиеся payloads; уже отсутствующие файлы не учитываются
как вновь освобождённые bytes. Директории рекурсивно не удаляются.

Cleanup сохраняет исходные proofs, recovery indexes, маленькую диагностику и
stage evidence в `itl/evidence/v1`. После удаления payloads восстановление
просроченной попытки из них невозможно; retained indexes и SHA объясняют,
что было удалено. Это сознательный срок хранения recovery, а не новая
квалификация, успешный тест или изменение исторического failed evidence.

Стоимость появляется только у явных Full Status/Cleanup: обход имён и metadata
архивов и plan checkpoints; Cleanup дополнительно читает только удаляемые
payloads для SHA. Размер этих payloads виден в preview. Gates и installed
runtime не получают новых проверок. Дедупликация с переписыванием recovery
ссылок не выполняется: каждый сохраняемый архив остаётся самодостаточным в
рамках прежнего recovery-index контракта.
