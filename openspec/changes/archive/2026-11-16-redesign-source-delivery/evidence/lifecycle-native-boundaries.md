# Lifecycle: фактические границы вместо заявленных

Разобраны 26 исходных определений, строки 1249–2044 из frozen `fa0e3c91`:
[индивидуальные решения](lifecycle-boundary-review.csv). До изменения SHA всего
файла совпал с inventory. Это не review остальных 210 определений этого файла
или новая live-квалификация 1С. Общий охват исходного inventory — 343/2814.

Найдены три конкретные проблемы доказательства:

- «Cross-process lock» использовал два обращения из одного процесса.
  Теперь реальный PS5.1 child встречает удерживаемый родителем lock, возвращает
  23 и точный путь одновременно с пробелами и кириллицей. После освобождения
  тот же child получает lock и возвращает 0. Исходная проверка finally/dispose
  у wrapper сохранена; child ограничен 30 секундами штатным native owner.
- «Persisted normalization» подменял `Update-DevBranchState` изменением объекта
  в памяти. Теперь child выполняет настоящие pending/passed записи через
  lifecycle owner, затем завершается с искусственной последующей ошибкой 17.
  Родитель после завершения читает реальный файл и проверяет прежние status,
  timestamp, log, updates, а также точный Unicode и proof version. Только
  Enterprise/result остаются synthetic; реальную EPF/PM5-приёмку это не заменяет.
- Две Git/Unicode-фикстуры содержали уже испорченный текст. Исправлены литералы;
  topology, Git commands, C-quoted negative и все исходные assertions сохранены.

Усиленная lock-проверка обнаружила product defect: фактический child exit23
превращался в0 в `Invoke-NativeProcessAndWaitResult`. Отдельный PS5.1 reproducer
вне Pester подтвердил0 у owner и23 при прямом запуске. Удержание `Process.Handle`
в том же реальном owner до начала наблюдения вернуло23. Исправление добавлено
у owner; ожидание теста не ослаблялось. Восемь process mocks в трёх существующих
suites теперь предоставляют Handle как часть реального process contract;
их assertions и сценарии не менялись.

Четыре изменённых существующих lifecycle It прошли focused-проверку PS5.1:
lock1/0 за6.77s, persistence/Unicode3/0 за6.03s. Количество It не увеличилось. Дополнительная focused-проверка восьми process fixtures и прежних completion/release сценариев: 19/0 за52.88s.
Штатный Targeted принадлежит одной регистрации всей связной единицы; его
receipt проверяется через Status, а не повторным gate ради времени.

Остальные 22 решения read-only. Source-offset тест финального init-order пока
сохранён с явным ограничением: наличие и порядок строк не доказывают реальную
последовательность процессов. Ни дешёвый seam, ни этот review не дают основания
удалить обязательную PM5 negative, rollback, fresh passed или SHA-проверки.

## Обновление пропущенной Vanessa build fixture — 2026-10-12

Общий Develop `d7a4dc52` прошёл native upgrade за2324386ms, затем Pester
остановился на трёх случаях VanessaBuildRuntime: подставной Start-Process
не предоставлял Handle. После его добавления focused воспроизвёл следующую
неполноту того же mock: отсутствовали перенаправленные stdout/stderr файлы.
Настоящий Start-Process создаёт оба файла и возвращает System.Diagnostics.Process
с Handle; это необходимые части используемого native API, а не новые условия
ожидаемого результата. Production owner не менялся.

Фикстура теперь принимает штатные redirect arguments, создаёт пустые stream
файлы при успешном старте и предоставляет Handle. Исходный отказ запуска
происходит до создания файлов. Fake PID, inventory чужого клиента и живого
descendant, exit7, admissions, workload и все исходные assertions сохранены.
Все15 случаев прошли focused за12.38s. Это исправление контракта mock, не live
проверка настоящего OneScript/1С launcher.

Failed общий shard plan:47 executed/110 reused, fingerprint54015ms,
workerSpan553925ms; один worker150 содержит12 passed/3 failed. Остальные14
pending групп остановлены fail-fast, поэтому общий исход не восстанавливается
по этим числам. Сообщение omitted/duplicated files сопровождает неполное
выполнение; самостоятельный дефект inventory этим не доказан.
Upgrade report SHA256 f011d692ebf9131b055cd156a4899cd8dc24ad6d9fd951f4f7d28604b6ea8255,
tree ba5fd118dfce73f613fb755cbcd23ebabbc7f04c, shared cache manifest сохранён.
Повтор должен использовать этот proof при неизменных native inputs. До
проверки продолжения и отдельной fresh journey общая квалификация не принята.
