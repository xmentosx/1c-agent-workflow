# A.6 — фактический runtime Pester worker

Исходная база: `ccadf4482655810203119b6088a79c5e2bbd034d`.
Это owner-local часть A.6. Полный аудит тестов, внешние Python/Node/Go runtime
и проверка environment identity агрегированного Full proof ещё не завершены.

## Причина и изменение

Scheduler вычислял ключ из версии своего PowerShell и доступного ему Pester,
но запускал другой процесс — `powershell.exe`, импортирующий модуль заново.
Одинаковая версия не доказывала совпадение реально исполненных файлов.

`invoke-pester-runtime.ps1` теперь владеет общим stateless контрактом hash и
module-path initialization. Перед выбором shard proof scheduler один раз
запускает ограниченный probe тем же абсолютным executable и тем же process
owner, что и worker. Receipt содержит фактические PowerShell version/edition,
разрядность, executable/engine SHA и SHA всех файлов импортированного Pester.
Worker наблюдает эти входы до и после тестов; result защищён существующим
cache manifest. Admission требует matching identity в самом result, включая
legacy lookup. Integrity-valid чужая или старая запись сохраняется.

Неизвестная identity или изменение runtime во время исполнения запрещает
только reuse: исходная задача продолжает исполняться и может завершиться passed.
Manifest из probe закрепляет импорт worker; недоступный manifest возвращает
штатный импорт, после которого несовпадение отключает reuse, а не задачу.
Нового coordinator, state store или общего запрета нет. Старые cache records
не мигрируются вручную: отсутствие identity требует одного холодного исполнения.

Shared worker inputs включают новый helper. Он также включён в точный script
inventory существующего Full checker; его изменение отвергает прежний inventory.
Это не устраняет отдельный оставшийся пробел: ранняя проверка environment у
агрегированного Full proof пока использует parent/module version. Не объявлять
Pester shard proof доказательством завершения всей A.6 или Full qualification.

## Проверки и измерения

`PesterRuntimeProof.Tests.ps1` сохраняет реальные process/module/cache boundaries:

- Core parent исполняет Desktop 5.1 worker; matching proof применим в другом
  worktree того же Git common directory. SHA engine/executable сверены с файлами.
- Реальный приватный Pester заменяется по тому же пути при той же версии:
  cold → reuse → изменение executable module input → cold → reuse.
- Замена module input внутри оригинального теста оставляет passed, но исключает
  qualification и последующий cache reuse.
- Integrity-valid proof без identity и с другой identity сохраняется; исходный
  тест исполняется, после чего пригоден новый proof.
- Неизвестное наблюдение дважды исполняет исходную задачу без кэша и общего отказа.

Первые focused прогоны выявили Desktop-особенность `Start-Process`:
без раннего получения native Handle `ExitCode` после `WaitForExit` был пуст.
Probe теперь получает Handle так же, как существующий worker owner. Четыре
падавших runtime сценария после исправления прошли за 66.26 s. Core/worktree
сценарий прошёл за 7.94 s; in-flight сценарий — за 13.15 s. Семь существующих
catalog checks и исходный binary hashing regression также прошли. Новый
отрицательный whole-gate inventory regression прошёл за 0.367 s.
Эти focused результаты не заменяют единственную последующую RegisterChange.

Измерение на отдельном реальном fixture с пробелами и кириллицей:

| Запуск | Полное время | Probe | Fingerprint | Git identity inventory | Worker span | Исполнено / reused |
|---|---:|---:|---:|---:|---:|---:|
| cold | 6161 ms | 776 ms | 129 ms | 1048 ms | 2563 ms | 1 / 0 |
| warm | 3518 ms | 772 ms | 110 ms | 1046 ms | 1 ms | 0 / 1 |

Отдельный Desktop probe: 867 ms целиком, 59 ms получение identity, 19 файлов
Pester 5.8.0, PowerShell 5.1.26100.9549. Это стоимость маленького fixture,
а не измерение полного выпуска или гарантия пяти минут для любой доработки.
Новые runtime поля подробного receipt остаются в named artifacts; обычный
check-summary получает только время probe и известность identity.

Ignored доказательства текущего worktree:
`build/redesign-source-delivery/runtime-proof/desktop-runtime.json`,
`cold-warm-measurement.json`, `focused.xml`, `focused-repair.xml`,
`static-and-boundary.xml`, `gate-inventory.xml`.

## Продолжение

Первый RegisterChange завершился failed на двух старых source/catalog
expectations; все шесть runtime cases прошли на immutable head. Диагностика,
границы допустимой правки ожиданий и перенос static routes:
[journey-static-selection.md](journey-static-selection.md).

Исправленная единица зарегистрирована: commit
`3d2658d5d416ea14ff11300f4e4d0281d48e82e1`, exact tree
`682b95e6e4361b3f3d06bab9f11060782dc0ca3c`; 241/0/0,
check-summary 1256977 ms, raw registration 1259549 ms.
Raw proof: common Git `itl/runs/20261010-225036-523-targeted-7518fcf152be4180bf1f91fc3fb4f478.json`.
Executed 5 workers, reused 5 matching proofs; native runtime cases сохранили
доказательство из первого immutable прогона. После gate tracked tree чистое;
Status подтвердил принятую head общей очереди. Публикации не было.

Следующий шаг: закрыть identity
агрегированного Full proof у checker owner и компонентные runtime у их owners.
Семь Python/Node host suites пока консервативно nonreusable. A.6 целиком остаётся
незавершённой; расширение delivery authority относится к отдельному checkpoint C.
