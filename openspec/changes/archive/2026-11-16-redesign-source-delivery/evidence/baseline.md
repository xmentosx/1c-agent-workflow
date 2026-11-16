# Исходное состояние после публикации

Проверено 2026-10-10 после завершения чата
`01a120cd-969b-74f0-a272-00fa4efaf689` (completed, idle).

## Checkout и состояние доставки

- Реализация: managed worktree `redesign-source-delivery/1c-agent-workflow`,
  branch `codex/redesign-source-delivery`.
- HEAD и полученный `origin/develop`: `fa0e3c91694112c1da3ecda7209a8a81ea828264`.
- Дерево опубликованного кандидата: `52613e2e344d10db62886a9548f7381b9650006b`.
- Штатный Status: `status=ok`, очередь 0, activeOperation=null,
  publicationAttempt=null. Новые gates для этой проверки не запускались.
- Hot run-history index: `corrupt`, count=0; это не доказательство отсутствия
  запусков или нулевой длительности. Существующий Cleanup уже не устранил дефект;
  его повтор ради этого аудита не выполнялся.
- Исходный checkout остался на `c900620e` с незакоммиченными OpenSpec changes
  `redesign-source-delivery` и `workflow-bound-dependencies`; чужой change не копировали
  и не меняли. Этот change скопирован в отдельный worktree для реализации.
- OpenSpec 1.13.1 подготовлен в ignored runtime нового worktree штатным явным
  `scripts/source-openspec.ps1 -Provision`; глобальные настройки не менялись.

## Подтверждённая квалификация

Raw record в общем Git-каталоге:
`itl/runs/20261010-183300-709-develop-0d627a092b2e4e9280012f2a0414112b.json`.
Schema 3, commit/tree совпадают с опубликованным кандидатом, status=passed.
Все десять записанных стадий passed. Record прочитан напрямую, а не через
повреждённый hot-index. Доказательство относится к старой базе, не к реализации
данного change.

| Стадия | durationMs | Минуты |
|---|---:|---:|
| Develop, всего | 6489926 | 108,17 |
| develop-e2e-fresh | 3315488 | 55,26 |
| develop-e2e-upgrade | 2920953 | 48,68 |
| ai-rules-compatibility | 198645 | 3,31 |
| pester | 138818 | 2,31 |
| release-readiness | 13237 | 0,22 |

Две live journey определяют почти всё время этого финального прогона.
Оптимизация только Pester не доказывает сокращение полного пути выпуска.
Это отдельный срез от предыдущих 25-минутных Targeted и суммы повторных
регистраций; их нельзя складывать как последовательное календарное время без
проверки пересечений и вложенных операций.

## Новый транспортный дефект

В чате публикации проверено несовпадение hash hot-index после автоматического
преобразования JSON date strings в DateTime в PowerShell 7. С сохранением дат
строками owner hash совпал. Однако штатный Status из PowerShell 5.1 тоже сообщил
corrupt; полная граница преобразования ещё не локализована. Не считать проблему
устранённой переходом на другой shell или просто перестроением индекса.

Существующие диагностические артефакты именованного инцидента находятся в
`e2e-configuration-outcomes/1c-agent-workflow/build/configuration-acceptance/`:
`history-index-readonly-probe.json`, `status-final-ps51-native.json`,
`cleanup-history-index.log`, `current-state.txt`.

Следующая проверка: минимальный неизменяемый payload с ISO dates и целыми timing
значениями через реальный reader/writer boundary обоих runtime; реальная порча
payload должна по-прежнему отвергаться. Нельзя отключать проверку SHA или править
существующий hot-index вручную.
