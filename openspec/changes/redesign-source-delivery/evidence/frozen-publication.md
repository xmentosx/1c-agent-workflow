# Фиксированный состав публикации: C.7/C.10 и часть C.9/C.11

Предыдущая единица C.3–C.6 принята как7084a7df. Эта единица продолжает того же
владельца source-delivery: отдельного координатора, shadow queue или новой
authority нет. Единица принята какfcd8763895555f0c3d12a38777fa9120408e2800:
Targeted213/0/0,18 executed /5 reused, check651469ms, raw653175ms,
fingerprint planning5359ms, clean treec171a65c2ed8d2bf25ca258f9b2cf5501d246605.
Raw: itl/runs/20261011-081529-074-targeted-c32f20f6ff7242d7853f3dbb9dabb3a4.json.
Официальный Status подтвердил queue headfcd87638, indexStatus ready,
invalidCount0, activeOperation null. C.7/C.10/CA.3 закрыты; остальные открытые
границы ниже сохраняются. Цель300s не достигнута; сравнивать failed и passed
прогоны как ускорение нельзя. Реальной публикации проекта не было.

`Plan` использует принятый интегрированный кандидат, включает копию queue
id/base/head в идентичность новых планов. Старый schema1 без queue сохраняет
прежнюю идентичность. `PublishDevelop` продолжает состав существующего attempt
либо сохранённого плана. Поздние регистрации не заменяют queuedCandidate,
состав и planId начатого выпуска. Promotion и применимость qualification по
окружению продолжают принадлежать прежним владельцам.

После push очистка сравнивает замороженные пары с текущими refs. Новые записи
и продвижения прежних остаются. Реальное движение refs повторяет только CAS
очистки, максимум три попытки; неизменившиеся refs при ошибке означают настоящий
отказ Git. Отказ сохраняет checkpoint, тот же publication action завершает
очистку уже опубликованного кандидата без gate. Проверка interrupted publication
смотрит frozen attempt.queue, включая пустой состав старого плана, когда все
его прежние live heads уже продвинулись.

## Доказательства до штатной регистрации

Шесть новых сценариев, все passed в Windows PowerShell5.1/Pester5.8.0:

| Сценарий | Проверяемая граница | Наблюдённые case seconds |
| --- | --- | ---: |
| Legacy plan identity | Golden SHA из принятого7084; новое membership меняет новый ID, authority прежняя | 0.409 |
| Cleanup CAS race | Настоящий Git update-ref отказывает атомарной транзакции; повтор сохраняет advanced alpha и удаляет совпавший beta | 11.22 |
| Failed Release then late work | Native PS5/Git: alpha продвинут и beta зарегистрирован после отказа; ResumePlan выпускает прежний SHA/ID; следующий выпуск включает обе доработки | 341.22 |
| Saved current plan | План создан до новой beta; первый запуск выпускает прежний кандидат, beta остаётся | 170.33 |
| Saved legacy plan | Старый формат без queue; alpha уже продвинут и beta новая; прежний SHA/ID выпущен, оба новых диапазона сохранены | 212.23 |
| Post-push cleanup failure | Собственный lock в одноразовом fixture блокирует Git cleanup после настоящего push; новая beta принята; recovery не вызывает gate и сохраняет beta | 174.26 |

Native fixtures публикуют в собственный bare remote настоящий production
supervisor с его import closure. Это требуется для доверенного ResumePlan.
Тестовые gate/finalizer и минимальная stand identity не являются реальным
Release/1С proof. Lock принадлежит только disposable fixture; пользовательские
блокировки и состояние не редактировались. Параллельная задача сохраняет свою
исходную base через явный BaseRef, без удобного rebase воспроизводителя.

Сначала непригодный bootstrap fixture закономерно отказал ResumePlan; исправлена
его обязательная published-authority предпосылка, проверка доверия не ослаблена.
Пробный запуск из PS7 выявил несовместимый inherited module path; он не считается
приёмкой PS5. Повторы выполнены штатным runtime. Эти наблюдения сохранены
раздельно в ignored candidate-protocol artifacts.

Шесть It-команд перенесены без изменения extent SHA в четыре независимых файла,
BeforeAll body — в общий SourceDeliveryFrozen.TestSupport. Transfer ledger
содержит исходные SHA. Каждый файл использует частный GUID/TestDrive fixture;
release-failure environment меняется и восстанавливается только в своём процессе.
Новые группы допускают параллельный scheduler. Веса — соответствующие суммы
case times +5 s, округлённые вверх:347/176/218/191. Это ordering weights,
не измерение нового параллельного ускорения и не доказательство цели300 s.

Loaded production definitions/imports и общий fixture входят в reuse closure
отдельного fixture contract. Они не расширяют selection на любой helper.
Каталог сохраняет все прежние владельцы и историческую модель E; только текущая
модель дополнена новыми группами. SourceQueue necessity ledger добавляет15
исходных определений:12 тел совпадают с baseline, два изменены по утверждённому C,
один isolated fixture дополнен исходной queue в attempt без изменения assertions.
Общий предметный review276/2814; новые C тесты не увеличивают этот baseline.

## Открытые границы

Первый canonical RegisterChange на5921a750 завершился failed за741791ms:
SourceDeliveryQueue original17 получил отсутствующее поле queue вместо ожидаемой
ошибки owned asset. Остальные14 native/contract cases файла продолжили выполнение
после раннего дефекта. Отдельная проверка за1.67s также обнаружила старый seam
Get-QueueEntries в SourceDeliveryPlan original598: планирование уже использует
Get-SourceRegistrationSnapshot. Оба fixture приведены к новым границам; исходные
данные, пути и capability/asset assertions сохранены. Четыре focused cases passed
за2.37s; все27 текущих SourceDeliveryPlan cases также passed за86.32s. Общий gate после исправления ещё не выполнен. Failed artifacts сохранены
в ignored candidate-protocol/failed-5921. Это конкретное основание для A.3:
короткие owner checks должны завершаться до дорогих native групп, без добавления
новых проверок или ослабления существующих.

C.8 реализуется в [candidate-integrity.md](candidate-integrity.md): проверка
неизменности перед finalizer и после него, отправка явного qualified commit.
Native callback scenarios доказали продолжение того же плана через существующее
восстановление, без нового reset/replanning и без повторного Develop.
После выделения helper ещё требуется canonical acceptance. Для исправления
самого замороженного исходника и исторического controller C.9/C.11 остаются
открыты; ручное удаление checkpoint недопустимо. Уже отправленный кандидат
нужно завершить через recovery.

Полный rollback исторического controller и все семейства отказов доставки пока
не проверены. Native legacy-record совместимость и golden identity уже доказаны;
это не подмена исторического controller текущим. C.9/C.11 остаются открыты.
Также требуется автоматический выбор прежней plan authority при обычном повторе
PublishDevelop без явного ResumePlan: сейчас wrapper закрепляет её только при
явном флаге. Новый published owner не должен переинтерпретировать старый attempt.
Реальной публикации проекта и новой проверки пользовательских баз не было.
