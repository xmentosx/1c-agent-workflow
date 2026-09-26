# Постановки для разработки исходного workflow

Этот процесс относится к `1c-agent-workflow`. Установленные проекты используют
свои правила и инструменты. Планирование помогает согласовать достаточное
решение и проверяемый результат; количество документов не доказывает качество.

## Выбор процесса

Сначала агент исследует доступные факты по Routing в корневом `AGENTS.md`.
Если остаются разные трактовки поведения, недоказанная причина сбоя,
необоснованные новые состояния/исключения/восстановление или отсутствует
конкретный сценарий приёмки, он объясняет неопределённость и предлагает grill
и/или OpenSpec. Пользователь выбирает. Ясная ограниченная задача сохраняет
прямой путь. Выбранный этап и ранее данное разрешение не согласовываются заново.

| Выбор в Codex | Назначение |
|---|---|
| `$grill-me` | Критическое интервью без записи glossary/ADR |
| `$grill-with-docs` | Интервью с записью согласованных терминов и существенных решений |
| `$openspec-explore` | Исследование перед постановкой или уточнение существующего change |
| `$openspec-propose` | Требования, дизайн и задачи выбранного изменения |
| `$openspec-apply-change` | Реализация согласованного change в пределах разрешения пользователя |
| `$openspec-archive-change` | Архив завершённого и проверенного change |

Навыки находятся в `.agents/skills`; invocation metadata отключает неявное
включение. `grilling` и `domain-modeling` — локальные зависимости двух grill
entrypoints. Generic OpenSpec подсказки `/opsx:*` и дополнительные навыки из
полного upstream каталога не являются установленными здесь командами: используйте
точки входа таблицы и `openspec status/instructions` для продолжения артефактов.

OpenSpec требует доступного CLI; проверенная версия — `1.4.1`. Проверьте
`openspec --version` перед первой CLI-операцией в выбранном этапе. Если CLI
отсутствует, сообщите предпосылку и сохраните артефакты: не заявляйте валидацию
и не устанавливайте инструменты автоматически. Grill работает независимо.
CLI должен быть доступен из среды выполнения Codex; установка в другом
терминале сама по себе не доказывает доступность из sandbox.

## Достаточная постановка

При выбранном формальном процессе отразите пять элементов, соразмерно задаче:

1. Конкретную проблему и сценарий пользователя, подтверждённые фактами.
2. Требуемое поведение, границы изменения и исключения.
3. Самое простое достаточное решение, рассмотренную альтернативу и rationale.
4. Новые обязанности сопровождения: состояние, совместимость, восстановление.
5. Критерии приёмки, доказательства результата и то, что остаётся непроверенным.

Простота оценивается по суммарной стоимости эксплуатации и сопровождения.
Сначала примените существующий контракт владельца из
[архитектуры пакета](package-architecture.md); постановка не заменяет требуемый
checkpoint. Существенные решения о поведении, ответственности, совместимости
и приёмке разрешаются до зависимой реализации. Рутинные технические детали
агент выбирает сам в рамках договорённостей. Новое противоречащее им
свидетельство требует уточнения соответствующего решения, а не нового
интервью обо всём изменении.

После grill переносите подтверждённые решения, факты и оставшиеся вопросы в
артефакты выбранного OpenSpec change. Не повторяйте уже отвеченные вопросы.
Храните требования, дизайн и задачи в OpenSpec. Glossary создаётся только для
согласованных специфичных терминов; ADR — для трудно обратимого, неочевидного
без контекста решения с реальным trade-off. Пустые документы не нужны.

При apply прочитайте `test-plan.md`, если он существует, вместе с `contextFiles`.
Связывайте выполненные задачи с наблюдаемым результатом. Helper-тест не
доказывает конечный успех обновления; ретроспектива не является live-прогоном;
наличие навыка на диске не доказывает его обнаружение новым контекстом Codex.
Не отмечайте непроверенную приёмку выполненной. Следуйте
[существующей проверке и доставке](local-quality-gate.md): commit/RegisterChange
не означает публикацию. Завершение OpenSpec artifacts означает готовую
постановку, а archive требует фактического завершения согласованного change.
В checkbox-задачах фиксируйте реализацию и приёмку. Регистрацию того же commit
проверяйте через source-delivery Status: правка checkbox после регистрации
создала бы новый, ещё не проверенный head и второй журнал состояния доставки.

## Зависимости и обновление

| Содержимое | Авторитетный источник |
|---|---|
| Четыре grill навыка, `ADR-FORMAT.md`, `CONTEXT-FORMAT.md` | [controlled fork](https://github.com/xmentosx/itl_ai_rules_1c/tree/451c5a52e5b614c67406445d4af4b636da043aec/content/skills), commit `451c5a52e5b614c67406445d4af4b636da043aec`, tag `itl-main-410951e7-r36` |
| Четыре generic OpenSpec навыка | `@fission-ai/openspec@1.4.1`, `dist/core/shared/skill-generation.js` |
| Invocation metadata и source routing | Этот исходный репозиторий |

Grill — адаптация [mattpocock/skills](https://github.com/mattpocock/skills/tree/0ab1b63a410a03d3627979a109c8695de27af954), MIT.
Уведомления обеих зависимостей сохранены в [third-party notices](source-planning-notices.md).
Общие импортированные инструкции изменяются у владельца, затем обновляется
закреплённая копия. Source-only правила не встраиваются в эти инструкции.

Для обновления grill используйте чистый checkout указанного immutable commit,
скопируйте `content/skills/{grill-me,grill-with-docs,grilling,domain-modeling}`
в `.agents/skills`, сохраните references и атрибуцию. Сравните импортированные
тексты с источником; сохраните в `agents/openai.yaml` каждого навыка
`policy.allow_implicit_invocation: false`, не удаляя существующие UI fields.

Для воспроизведения OpenSpec получите путь к уже установленному пакету 1.4.1
(например, каталог `@fission-ai/openspec` под результатом `npm root -g`).
Из корня репозитория передайте его вторым аргументом следующему Node ES module;
тело можно передать через stdin с `node --input-type=module - <package-root>`:

```javascript
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
if (version !== '1.4.1') throw new Error(`Expected 1.4.1, found ${version}`);
const { getSkillTemplates, generateSkillContent } = await import(
  pathToFileURL(path.join(root, 'dist/core/shared/skill-generation.js')));
for (const { template, dirName } of getSkillTemplates(['explore', 'propose', 'apply', 'archive'])) {
  const target = path.join('.agents/skills', dirName);
  fs.mkdirSync(path.join(target, 'agents'), { recursive: true });
  fs.writeFileSync(path.join(target, 'SKILL.md'), generateSkillContent(template, version));
  fs.writeFileSync(path.join(target, 'agents/openai.yaml'),
    'policy:\n  allow_implicit_invocation: false\n');
}
```

Это рецепт явного обновления проверенной зависимости, а не шаг обычной задачи.
Не запускайте здесь `openspec init --tools codex` или автоматический
`openspec update`: adapter 1.4.1 может менять глобальные prompts.
Не добавляйте эти навыки, `openspec/` и source-planning docs в bootstrap или
update-workflow managed-copy. Одноимённые навыки установленного проекта
принадлежат controlled fork и не заменяются исходным набором.

При обновлении проверьте metadata и ссылки, измерьте bytes router/skill metadata,
поведение выбранных маршрутов и обнаружение в свежем контексте Codex. Пилот и
его ограничения: [enable-source-planning](../openspec/changes/enable-source-planning/test-plan.md).
