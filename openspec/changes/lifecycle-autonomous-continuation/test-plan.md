# Проверки и приёмка

Source-реализация выполнена; фактические проверки и оставшаяся native-приёмка описаны в [evidence.md](evidence.md). Pester-fixture подтверждает контракт helper, фактическое создание/обновление базы — отдельный результат исходной команды на disposable стенде. Исходную пользовательскую PM5-базу не использовать как тестовую.

| ID | Сценарий | Наблюдаемый результат / владелец |
|---|---|---|
| A1 | Новый проект, обновление с заполненным handoffs, повтор; обычный, старый и отсутствующий template | `/handoffs/` исключён, bytes/пользовательские правила сохранены, без дублей; BootstrapUpdate / WorkflowUpdateRollback |
| A2 | Tracked handoff, source dirty, staged source, неизвестный untracked вне каталога | Ничто не скрыто ignore; нужный фазе блокер возвращает точные пути и продолжение; core / DevBranchLifecycle |
| A3 | Агент создаёт configuration и extension branch при изменениях своей задачи | Проверенный локальный коммит без вопроса, штатный wrapper завершает создание worktree и веточной базы; SHA и userReport сохранены |
| A4 | Own change рядом с чужими staged/unstaged правками; смешанный файл | Коммит содержит только разрешённую работу; чужие bytes/index entries сохранены; неразделимый конфликт даёт конкретные варианты |
| A5 | Во время refresh и refresh-lite после merge меняются CONTEXT.md и docs/adr, включая staged/untracked | Операция достигает post-merge load и нормального завершения; документация не меняется; master/seed/merge выполнены один раз; DevBranchLifecycle + disposable ИБ |
| A6 | Изменяются source/runtime/config/evidence inputs, branch/HEAD/target; merge/rebase; повторный сбой и гонка | Нет неверной мутации/ложного passed, pending state сохранён, доступен owner continuation; прежний dirty `branch.txt` reproducer сохранён |
| A7 | Resume старой транзакции, failure после merge, invalid checkpoint, wrong parents, freshness и load failure | Исходные отрицательные регрессии действуют; выполненные этапы не повторяются; после разрешённого repair завершается исходная команда |
| A8 | Все клиентские шаблоны, прочие Assert-CleanGit callers, время/контекст | Одинаковая маршрутизация recovery; close/reset/sync/export/publication не расширены; штатные guards и userReport сохранены; профильные contract-тесты |

Все пути fixture содержат пробелы и кириллицу одновременно; сравнивать SHA-256 файлов и index entries до/после. Начальный отказ A1/A5 сохранить как red evidence; не менять workload/топологию для получения green. Для agent-owned continuation нужен наблюдаемый прогон агента: helper-only проверка не доказывает отсутствие лишнего вопроса.

Во время apply запускать непосредственно затронутые owner-тесты одним осмысленным набором. Измерить до/после одинаковую clean/dirty подготовку и сериализованные UTF-8 bytes изменённых клиентских поверхностей; bytes не называть точными токенами. Статус и доставку вести только существующим source-delivery: один coherent commit, RegisterChange владеет Targeted; публикация/установка отдельно. Planning проверялась strict OpenSpec validation; реализация регистрируется через Targeted, без Smoke/Full/Develop/Release.
