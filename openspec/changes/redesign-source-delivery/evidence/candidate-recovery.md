# Восстановление кандидата и переход контроллера: C.9/C.11

## Реализованный контракт

Обычный повтор PublishDevelop автоматически выбирает authority сохранённого
плана. Состав выпуска остаётся прежним. После успешного push восстановление
проверяет достижимость исходного кандидата даже при последующем продвижении
remote: результат называет исходные commit/tree и отдельно фактический remoteHead.
Поздние регистрации сохраняются. Повтор уже завершённого ResumePlan возвращает
already-reachable / qualificationStatus=not-revalidated без нового checkpoint,
изменения очереди или заявления о свежей квалификации позднего remote.

Изменение замороженных входов сообщает expected/actual candidate или stage
fingerprint. Явный PublishDevelop -Replan <originalPlanId> сохраняет исходные
immutable plan/proof и копию checkpoint по SHA, затем фиксирует новый состав.
Повтор этого же Replan продолжает replacement и не включает поздние задачи.
Неизменённый, в том числе вложенный replacement, не сбрасывает circuit breaker.
Первый план сохраняется также при ожидании long-plan approval.

Повреждённый выбранный proof сообщает путь, ожидаемый/фактический SHA и причину.
Только явный Replan переносит его в evidence-rejected/v1 после повторной проверки
SHA и принадлежности пути. Валидный proof не перемещается. Повреждение только
Release повторяет Release и сохраняет применимый Develop. Движение remote до
push сохраняет checkpoint и требует явного Replan; новый кандидат включает
публикуемый develop перед очередью. Plan и Publish строят одинаковый commit.
Эти новые continuations относятся к PublishDevelop; master authority сохранена.

## Исторический переход и rollback

Native fixture использует реальные тела опубликованного контроллера fa0e3c91,
а не современную реализацию под старой меткой. Immutable archive содержит
46 source paths / 273876 bytes, SHA256
e87ff74cf69d289b2b957a996b8e4bd3951e72a31cd651180938728f5cdfadec;
manifest фиксирует полный source commit. Fixture остаётся test-only.

До вызова исторического owner wrapper обнаруживает изменившийся состав legacy
плана: сохраняет checkpoint byte-for-byte, предлагает явный Replan. Он разрешает
историческому owner закончить его собственный переход. Пока legacy checkpoint
активен, новая регистрация получает продолжение через старый PublishDevelop;
после его завершения тот же RegisterChange проходит новым CAS. Закрытый старый
owner не может записывать очередь с уже принятым новым candidate state.

Rollback функционального изменения допустим с совместимым queue decoder.
Кандидат с буквальным старым decoder отклоняется до Develop: сохранены все
регистрации. Repair возвращает совместимый decoder, сохраняет функциональный
rollback и публикует его вместе с независимой задачей. Новых lock/state owners,
ручной правки состояния, обхода locks или смены master authority нет.
Исторический Clear-PublishedQueueEntries сам проверяет ancestry и ожидаемые
SHA ref transaction: отдельная новая блокировка по предположению не добавлена.

## Измеренные native сценарии

Windows PowerShell 5.1, Pester 5.8.0; private Git remotes, fake gate/finalizer,
без пользовательских баз, внешней публикации и настоящего запуска 1С.

| Сценарий | Результат focused | Полное время, s |
|---|---|---:|
| Изменённый план, unchanged/nested replan, freeze replacement | 1/0 | 52.57 |
| Повреждённый Develop proof и явное восстановление | 1/0 | 25.13 |
| Повреждённый только Release proof, Develop 1 / Release 2 | 1/0 | 25.23 |
| Divergent remote, Plan=Publish, исходный checkpoint сохранён | 1/0 | 27.21 |
| Реальный исторический owner, переход и поздняя регистрация | 1/0 | 235.71 |
| Буквальный decoder rollback, repair и независимая задача | 1/0 | 39.92 |
| Post-push advance и повтор закрытого ResumePlan | 1/0 | 28.51 |
| Каталог: два изменённых точных набора | 2/0 | 3.48 |

Первый divergent-remote reproducer выявил реальный дефект: публикация начинала
со stale accepted candidate и не включала новый remote. Исправлен общий владелец
сборки; исходные topology/preconditions/assertions сохранены. В двух других
первых прогонах исправлены fixture: реальный hashed gate report и порядок
проверки changed checker до checkout другой ветки. Assertions не ослаблены.

Raw XML/log находятся в ignored build/redesign-source-delivery/candidate-protocol.
Окончательная приёмка единицы — один RegisterChange / Targeted. Focused native
proof подтверждает управление потоком, сохранение состояния и отсутствие новых
вызовов fake Develop; он не заменяет реальную квалификацию 1С или пробный выпуск
V.7. Цель 300 секунд и весь аудит тестов остаются открытыми.

Первый canonical RegisterChange выявил пропущенную зависимость изолированного
CAS-deadline fixture: AST extraction подключал только Register-SourceChange.
Исправление подключает также настоящий Assert-SourceRegistrationTransitionReady
и задаёт отсутствующий checkpoint внутри TestDrive. Production barrier, workload,
deadline/assertions не ослаблены; остальные прошедшие shard сохраняются в cache.
Отказ не изменил accepted queue head. Повтор выполняется штатной регистрацией
после исправления этой же единицы.

## Накладные расходы Git и transport

Подтверждена причина: PowerShell string-параметр с default null преобразовывал
отсутствующий stdin в пустую строку. Все обычные Git reads попадали в tempfile /
Start-Process -Wait. Object-параметр различает отсутствующий и явно пустой stdin.
На том же инструментированном fa0 controller при 18 Git calls регистрация:
22280 → 4101 ms; суммарный Git 18500 → 1640 ms; весь fixture 35.47 → 8.10 s.
Это контролируемый эксперимент с исправленными типами, не квалификация нового
публикационного выпуска и не измерение полного Targeted. Три rev-parse отдельно:
1062/1026/1028 → 92/30/30 ms. Git 2.54.0.windows.1.

Прямой процесс закрывает stdin и параллельно читает stdout/stderr с явным UTF-8.
Воспроизводитель заполненного stderr доказал deadlock синхронного чтения и
завершился ограниченным отказом через 10.8 s; исправленный transport проходит.
Native regression проверяет Unicode Git -z paths, exact stdout/stderr, явно
пустой/ASCII/Unicode stdin и большие оба потока на пути с пробелом и кириллицей.
Последний прогон: 3/0 за 5.56 s. Owned probe ограничен 10 s и завершает только
свои процессы. Это три самостоятельных transport-инварианта, без ещё одного
широкого gate. Нового always-on контекста и collector нет; context delta 0.

## Явная замена активного Frozen-плана

`PublishDevelop -Replan <активный planId>` создаёт новую Current-замену даже
после Frozen-плана: текущая очередь выбирается заново, а прежние plan/checkpoint
сохраняются неизменными по SHA. Повтор Replan по id прежнего родителя продолжает
его существующую замену и не меняет Frozen на Current. Поздняя регистрация после
создания Current-замены остаётся на следующую публикацию. Проверка выполняет
настоящие native команды с private Git remote и fake gate/finalizer; она не
подтверждает live 1С или публикацию рабочего репозитория.
