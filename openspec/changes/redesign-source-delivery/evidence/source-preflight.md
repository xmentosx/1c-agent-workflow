# A.3: короткие проверки до дорогих native сценариев

Основание — failed5921: unit original17 упал за0.409s, но остальные случаи
SourceDeliveryQueue продолжились; файл занял441.360s, весь check741791ms.
Изолированная проверка original598 SourceDeliveryPlan нашла второй старый seam
за1.67s. Прежний LPT порядок запуска и смешанные файлы откладывали эти ошибки.

Все15 текущих It из принятогоfcd87638 перенесены в четыре файла. Точные It extent
SHA и multiset проверены в source-queue-case-transfer.csv; BeforeAll и Describe
сохранены. Admission содержит original4/17/46/106, authority —62/126/144/184/195/
242/303, Queue —342/373/406, OperationRecovery —419. Исходные номера последних
четырёх сопоставляются через C-reviewed SourceQueue ledger; текущие fcd номера
377/410/423 сохранены в transfer proof. Ни один native reproducer, путь, fault,
assertion или case не удалён. Все прежние owner selections получают все четыре
группы; loaded/reuse inputs не сужены на основании одного переноса.

Existing sharded runner владеет одной фазой admission рядом с serial policy.
Выбранный SourceDeliveryAdmission завершается перед запуском дорогих workers.
Неудача прекращает scheduling; после успеха native groups могут работать
параллельно. Passed cache по точным входам пропускает повторное выполнение
admission. Число прежних тестов и правила serial isolation не изменены.

Два новых meaningful native cases проверяют эту изменённую sequencing policy:
два независимых child workers видят завершённый admission, затем все три proof
reused без нового выполнения; исходная ошибка сохраняется в JUnit, тяжёлые
файлы не запускаются, после исправления выполняются те же три задачи. Каждый
native worker пишет свой файл, устраняя обнаруженную гонку тестового журнала.
Последний focused native2/0 за31.26s; short owner/catalog7/0 за4.94s. Первая
проверка fixture ожидала JSON из stdout ошибки, хотя runner сохраняет его в
summary перед throw; исправлен consumer fixture, assertions исходного отказа
сохранены. Ошибочные focused артефакты сохранены отдельно, не считаются proof.

Weights — суммы именованных testcase из accepted-fcd87638 worker2 плюс5s,
округлённые вверх: admission7, authority66, registration192, recovery198.
SourceDeliveryPlan текущие27 cases заняли85.93s в canonical и86.32s отдельно:
weight91 заменяет старую оценку30 для20-case suite. Историческая E capacity
модель сохраняет прежние наблюдения; текущая учитывает split и admission reserve.
Это ordering estimates, не доказанное ускорение и не изменение deadlines.
На успешном пути admission добавляет около1.2s перед native запуском; общий
эффект ещё требует штатной регистрации. Новый native policy suite имеет weight36.

Границы: пока автоматически вынесен только дешёвый admission очереди.
SourceDeliveryPlan всё ещё смешивает короткие seams с Git/planner integration;
его следующий split и дальнейшее owner narrowing остаются A.3/A.2. Отмена,
одновременные независимые доработки,300s и весь A не закрыты этим изменением.
Audit Plan27 включён отдельно: всего303/2814 рассмотрены,2511 pending.
