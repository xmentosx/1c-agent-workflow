# Spec Delta

## Purpose

Обеспечить соответствие правил и инструментов установленному workflow каждого worktree, сохранив явные временные хотфиксы и восстановление незавершённого обновления.

## ADDED Requirements

### Requirement: Installed workflow defines dependency versions
Система SHALL использовать набор установленного workflow при init, update, refresh, восстановлении и отдельной установке компонентов. Проектный lock SHALL фиксировать точные версии, hashes/commits и происхождение; новый upstream release сам по себе набор не меняет.

#### Scenario: Reinstall after a newer upstream release
- **WHEN** upstream выпустил новую версию, а установленный workflow не обновлялся
- **THEN** восстановление и запуск используют прежний согласованный набор или явно оформленный хотфикс

### Requirement: Hotfix is an explicit scoped exception
Хотфикс SHALL задавать конкретный worktree, более новую полную сборку, источник, SHA/commit и причину. Связанные артефакты и MCP-каталог SHALL иметь совместимое подтверждённое описание; проверки hashes и фактического tools/list сохраняются. Статус SHALL показывать штатную и выбранную версии.

#### Scenario: New MCP build requires a matching catalog
- **WHEN** пользователь применяет более новый ROCTUP или Vanessa-комплект
- **THEN** helper проверяет весь комплект; неподтверждённый каталог не допускается к вызову, а отчёт предлагает снять исключение либо предоставить совместимый комплект через тот же helper

### Requirement: Workflow updates retire incorporated hotfixes
Успешное обновление SHALL снимать исключение при совпадении полной идентичности сборки либо переходе на доказуемо более новую сборку той же линии. Более новый совместимый хотфикс SHALL сохраняться. Разные SHA при равном номере и несравнимые fork SHALL требовать явного выбора; unrelated операции сохраняют доступность.

#### Scenario: Workflow catches up with the hotfix
- **WHEN** новый workflow содержит ту же или более новую сопоставимую сборку
- **THEN** worktree получает штатный набор, а исключение снимается только при успешном завершении его обновления

#### Scenario: Workflow has not caught up
- **WHEN** штатная сборка остаётся старее совместимого хотфикса
- **THEN** исключение и его происхождение сохраняются

### Requirement: Update all available worktrees independently of configuration refresh
Обновление SHALL доставлять согласованный workflow-комплект в master и доступные рабочие ветки без ожидания refresh конфигурации. Занятый или заблокированный root SHALL сохранять прежнее состояние и точное продолжение. Подготовка расширения в ИБ SHALL отражаться отдельно и завершаться существующим маршрутом до зависимого MCP-вызова.

#### Scenario: One branch is busy
- **WHEN** master и свободная ветка обновлены, а другая ветка занята
- **THEN** занятая ветка остаётся на прежнем комплекте, rollout показывает deferred и повтор update продолжает её без повторного обновления завершённых roots

### Requirement: Legacy modes migrate with an explicit dependency decision
Первое обновление SHALL переводить `fresh`/`locked` на общую политику с предварительным отчётом различий. Нестандартный старый pin SHALL получать явное решение «набор workflow» либо «совместимый хотфикс» до замены; чужие записи сохраняются.

#### Scenario: Existing locked project has a custom pin
- **WHEN** обновляется проект с отличающимся старым pin
- **THEN** отчёт сохраняет исходную идентичность, предлагает два допустимых решения и продолжение той же команды; без решения проект не получает частично заменённый комплект

### Requirement: Recovery restores the complete prior dependency selection
Сбой и rollback SHALL восстанавливать согласованные package/rules, lock, исключения и управляемые env/client contributions в затронутом root. Поздние пользовательские правки SHALL сохраняться для существующего reconciliation; успех другого root не отменяется глобально.

#### Scenario: Update fails while retiring a hotfix
- **WHEN** обновление прервано после замены lock до подтверждённого завершения root
- **THEN** resume продолжает тот же переход, а rollback восстанавливает прежний комплект и хотфикс, сохраняя посторонние изменения
