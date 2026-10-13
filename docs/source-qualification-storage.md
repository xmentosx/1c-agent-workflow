# Хранение одноразовых qualification copies

Владелец — source-only factory (`source-e2e-fixture.ps1`) и её storage helper.
Это продолжение согласованного удаления временных копий и диагностики disk112.
Установленные проекты, исходные capsules и Release checkpoint не мигрируют.
Нового общего cleanup coordinator, фонового опроса и installed-state нет.

## Завершение Develop

Factory записывает claim schema2 с canonical copy root, исходным capsule SHA,
candidate commit и common Git directory исходного workflow. Orchestrator держит
эксклюзивную lease этой копии; параллельные копии имеют разные roots и leases.

Сначала прежний database owner освобождает базы через существующие execution
guards и seed leases. Затем orchestrator сохраняет терминальный raw report.
Только после этого storage owner может удалить всю собственную Develop-копию:

- claim и терминальный отчёт должны совпасть с владельцем и кандидатом;
- все Git worktrees должны оставаться внутри private clone;
- активная lease, процесс, ссылающийся на копию, оставшаяся 1CD или reparse point
  сохраняют копию; чужой процесс ради уборки не останавливается;
- claim, журналы и lifecycle/run state сначала копируются побайтно в
  `fixture-diagnostics/<journey>` рядом с существующими gate logs;
- при failed сохраняются Git bundle с reflog-коммитами и binary working patches,
  чтобы pending-контекст можно было восстановить после удаления tools/snapshots;
- копия удаляется под lease, диагностика остаётся под существующей политикой
  хранения gate outputs. При частичной ошибке удаления сохранённый claim и
  raw report позволяют повторить owner-local `source-e2e-fixture.ps1 -Action
  DisposeCopy`. При отложенной очистке raw report содержит точные program/arguments.

Терминальный отчёт дополнительно фиксируется в claim под lease. Перед следующей
материализацией factory делает неглубокий sweep только своих schema2/Develop/
disposed/terminal claims. Это повторяет ранее отложенную очистку после выхода
владельца, даже если старый gate output уже прошёл обычную retention. Активная
копия не блокирует подготовку другой; неизвестные и Release claims пропускаются.

Для passed и failed Develop повтор начинается из неизменного sealed capsule,
поэтому после сохранения диагностики тяжёлая копия не нужна для ResumePlan.
Release, schema1 и неизвестные claims автоматически не удаляются. Старые архивы
на D:/E: этим изменением не затрагиваются; широкой миграции legacy ownership нет.
Ошибка вспомогательной очистки сохраняется как предупреждение в raw report,
а не отменяет доказанный результат journey.

## Место и disk112

Перед материализацией проверяются известные одновременные записи: исходный размер
1CD, копия snapshot DT и временная рабочая 1CD. Перед fresh new-dev-branch — копия
базы и временная база нормализации. Аллокации суммируются по реальным volumes,
включая отдельный TEMP; фиксированного порога в гигабайтах нет. Это нижняя граница
из известных файлов, а не гарантия максимального потребления всех команд 1С.
Недоступное измерение предупреждает; подтверждённо недостаточная ёмкость даёт
SOURCE_E2E_SPACE_INSUFFICIENT до запуска зависимой операции.

На существующем heartbeat30s monitor читает ограниченные UTF-8 tails и окна только
своего процесса/потомков с проверкой creation identity. Win32-чтение окон имеет
bounded SendMessageTimeout и общий бюджет; оно не нажимает кнопки. Подтверждённый
disk112 сохраняется в `<step>.disk-full.json`; штатный process owner завершает
свой job. Само низкое свободное место не объявляется доказательством disk112.
Неполный UTF-8 символ живого потока ожидается, повреждённый завершённый поток
считается transport failure. Shared child-process helper владеет encoding и stop.

Оба отказа сохраняют queue/checkpoint и ранее прошедшие proof. Продолжение:
`scripts/source-delivery.ps1 -Action Cleanup`, освободить указанный volume,
затем повторить ту же `PublishDevelop -ResumePlan` команду. Cleanup не разрешает
удалять активную копию или обходить checkpoint ради места.

Проверки разделены: SourceE2EStorage — filesystem/capacity; SourceE2EDiskMonitor —
настоящие дочерние процессы и скрытые Win32 окна, без заполнения реального диска.
Проверка Prepare после восстановления ёмкости входит в SourceQualificationFixture.
Новые runtime suites conservatively non-reusable; полного 1С-прогона для каждого
условия нет. Source selection и native input fingerprints включают storage helper.
