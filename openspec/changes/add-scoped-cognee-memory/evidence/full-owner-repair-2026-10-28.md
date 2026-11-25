# Два отказа Full: ограниченный ремонт, 2026-10-28

Исходный Full `9bdd4a2c3dd671bb2b64359440df2b6e55546fae` с exact fork r50
`a2cbdcef52316db426acedc852f495564189f1ca` завершился отказом: 12/12 client
installation compatibility passed; частичный Pester 2683/2/0 в 136 завершённых
файлах. Этот результат не переписывается; frozen executor и все исходные
JUnit/Go JSONL сохранены. Отказ не означает дефект Cognee или registry routing.

## Endpoint owner sync

Оригинальный сценарий
`EndpointIdentity.test_stale_publication_recovers_through_git_owner_sync_and_original_read`
повторён на неизменённом 9bdd, с тем же Python Native и дополнительным
сохранением `CalledProcessError.output`. В окружении обычного Codex он прошёл;
при штатном Full `ITL_TEST_AGENT_HOST_ISOLATED=1` воспроизвёл отказ
`ITL_CLIENT_AMBIGUOUS`: два подключённых клиента, исполнитель не назван.
Путь с пробелом и кириллицей, fake HTTP endpoints, Git publisher/cache,
seed → sync → reconnect/read и все assertions остались исходными.

Уже принятый в отдельную очередь коммит
`61a0140234759581af80dcf2f7349fa6f130fef7` задаёт fixture executor через
`-AgentTarget codex`. Дублировать его в memory/registry change не требуется.
Общий ledger дополнительно содержит прошедший Full более позднего кандидата
`5458c665b0d2dd67e2b022af913d1d6efb3c6195`, 14:52:23–15:03:02 UTC.
Это отдельный кандидат, не успешный повтор 9bdd и не приёмка текущего ремонта.

## Windows PID witness

Исходный отказ: `Original PID still present: 39840` после успешного `cmd.Wait`.
Он не повторился отдельно, в полном прежнем Go-наборе (223 passed) и в 20,
затем 100 диагностических повторах того же теста. Какие именно process name,
start time и exit state были у PID 39840, исходный журнал не содержит;
приписывать ему конкретный чужой процесс или доказанный retained-handle zombie
нельзя. Диагностический вариант с удержанием observer handles также прошёл
при неизменённом witness: сама доступность завершённого process object через
handle не равна его наличию в `Get-Process`.

В fixture найдена конкретная гонка identity: `cmd.Wait` освобождает Go handle,
а следующее наблюдение знает только PID. Windows допускает повторное
использование PID после освобождения последнего handle. Поэтому утверждение
fixture «PID завершённых cmd обязательно свободен до запуска PowerShell» не
обеспечено её собственным кодом. Это возможная причина исходного разового
отказа, а не восстановленная идентичность PID 39840.

Минимальный ремонт удерживает отдельный `os.FindProcess` observer каждого из
тех же двух cmd до конца исходного witness. Это закрепляет identity fixture,
не меняя команды, exit/wait последовательность или положительные/отрицательные
assertions. Полученный handle текущего процесса также освобождается cleanup.
Все handles освобождает `t.Cleanup`, в том числе при failed assertion.
Production witness остаётся побайтно прежним: live/reused PID по-прежнему
отказ, access/inspection errors не становятся доказательством завершения,
15-секундный timeout не увеличивается. Новых тестовых случаев нет.

Основание Windows identity contract:
[Microsoft: Process Handles and Identifiers](https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers),
[Microsoft: lifetime and PID reuse](https://devblogs.microsoft.com/oldnewthing/20110107-00/?p=11803).

## Проверка и доставка

Owner — существующий on-demand Go component; единственная executable дельта
этого изменения находится внутри прежнего Go test function. Selection должен
включить прежний `OnDemandGo.Tests.ps1` с полным `go test ./... -count=1
-timeout 120s`, не новый отдельный suite. До ремонта этот набор прошёл 223/0;
новый результат, стоимость и reusable scope фиксирует единственный Targeted
в штатном `RegisterChange -QueueId product-project-registry-g2`. Итог этой
регистрации читается из общего ledger, без последующей правки checkbox того же
head. Исходные failure/diagnostic proof находятся в ignored
`build/agent-artifacts/full-9bdd-r50-20261028` и
`build/agent-artifacts/full-owner-repair-20261028`; frozen 9bdd не изменяется.

Runtime authority, always-on инструкции, память, provider/index, registry data
и новая матрица приёмки не добавляются. Самостоятельные Gate 6, native PM5
lifecycle, QP5, рабочая миграция и публикация этим ремонтом не разрешены.
Внешняя параллельная публикация в Status наблюдается только read-only;
её процесс, очередь и checkpoints не изменяются этой задачей.
