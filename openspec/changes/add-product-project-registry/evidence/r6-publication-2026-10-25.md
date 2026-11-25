# R6 закрыт: опубликованное наполнение реестра, 2026-10-25

## Решение и публикация

Пользователь согласовал подготовленный кандидат и явно поручил: «Опубликуй данные
в существующий Git-реестр, зафиксируй SHA и закрой R6 в обеих OpenSpec».
Согласование включает восемь типовых проектов, таблицу настроек, карту основной
функциональности и явно отложенные поля registry-only выпуска.

**R6 закрыт в обеих OpenSpec.** Registry AC-36–38 выполнены. В memory AC-44 закрыта
зависимость обязательного наполнения и указан тот же опубликованный SHA;
это не приёмка памяти, G4/G5 или shared-product native сценариев.

- Repository: http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git
- Published branch: `main`.
- **Опубликованный SHA: [`0274a8ffb5a03ba7b856736c2b4a637ccbe98b73`](http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry/-/commit/0274a8ffb5a03ba7b856736c2b4a637ccbe98b73).**
- Подтверждённое время публикации: 2026-10-25T23:25:29.949295+03:00 (Europe/Moscow).
- Согласованный кандидат: `2cde7b6f1479cbdf5030cba34be4f3ab9adce521`.
- Актуальный publisher parent: `3f66d6f2854ce7bfbcef7a2f841873c2c54baec1`.

Кандидат был подготовлен на более раннем publisher commit abb04af6. Перед
публикацией fetch обнаружил новые publisher commits, менявшие только registry.json.
Все девять выбранных endpoint identities/URL сохранились. Четыре согласованных
catalog файла перенесены поверх актуального main; отличия от согласованного
кандидата — только статусы согласования/публикационные пояснения и ссылка на
актуальное основание endpoints. Бизнес-настройки, роли/links/composition и
44 правила доступности сравнились без изменений. Force push и откат publisher
не использовались; push main был fast-forward.

## Один опубликованный snapshot

Git fetch и ls-remote после push подтвердили main=0274a8ffb5a03ba7b856736c2b4a637ccbe98b73.
Действующий immutable reader прочитал refs/remotes/origin/main ровно на этом SHA;
schema/references и 8/8 selected contexts прошли повторную проверку данных.

| Файл | Git blob |
|---|---|
| registry.json | `b92e2b9229a35e9722c76414acd267a517a0973d` |
| catalog/catalog.json | `c36515a232f374f23acc444ac204467b5490ed44` |
| catalog/product-relations.json | `e8529c323a2987e700f676e22d6f56f90b9731fd` |
| catalog/README.md | `d8005518d6ed3288cb80d039e13b4d781de20eaf` |
| catalog/functional-map.md | `fb8154a552fe37208225e598e15149f6233ce64b` |

registry.json сохранён byte-exact актуальному publisher parent; он не переписан
вручную и не объявляет версии MCP версиями проектов. Новые версии endpoint
registry могут публиковаться дальше; этот SHA остаётся точным основанием R6.

## Приёмка R6

| Критерий | Итог |
|---|---|
| Registry AC-36 / задачи 1.9, 5.7 | PASS: восемь типовых проектов PM4/PM5 КОРП/ПРОФ/УНФ+PM/ERP+PM, stable IDs, один базовый продукт, customized=false; 1С:ERP и 1С:УНФ как два компонента. Владелец согласовал состав и публикацию. Отдельные расширения исключены; внешние проекты вне первого выпуска до отдельного перечня. Это граница выпуска, не утверждение отсутствия внешних проектов в организации |
| Registry AC-37 / задача 1.10 | PASS: восемь resolved contexts, независимые code/graph/productDocs roles, source origin/usage/limitations, общие PM5 СППР и точные Mantis search/create маршруты. ERP+PM5 использует собственный erppm5-lts. УНФ+PM4 search/bug/feature/improvement=327. PM4 SPPR отсутствует, productDocs disabled осознанно; адрес СППР сверён с deployed reader config |
| Registry AC-38 / задача 1.11 | PASS: 22 PM4 + 22 PM5 области, явные availableIn/ограничения/composition, первичные источники и provenance. PM4 различия подтверждены владельцем как совпадающие с PM5, без утверждения одинаковой реализации или PM5 документации для PM4. Optional homes явно отложены для registry-only; shared remember этим не разрешён |
| Memory AC-44 / задача 6.6a | Registry dependency CLOSED: тот же опубликованный SHA и единое наполнение. Никакого второго каталога/ingestion, grants, provider activation или memory acceptance. Native shared-product условия прежней задачи 6.6 сохранены отдельной 6.6b в будущем G5, не объявлены PASS |

Live source identity/scope proof переиспользован из ранее сохранённых G3 и
`build/registry-population-20261025/native-metadata.json` наблюдений для тех же
endpoint identities/bindings; новые native G3 сценарии не запускались. Адреса
сверены с актуальным publisher registry, а exact selected projection — с
опубликованным commit. Предыдущие native snapshots не объявлены новой проверкой
индексов или полной свежестью бизнес-данных. См. [согласованную таблицу и источники](r6-final-catalog-review-2026-10-25.md)
и [принятую границу G3](../g3-acceptance.md).

## Границы и продолжение

R6 больше не блокирует первый registry-only выпуск; иные обязательства выпуска
не закрыты автоматически. R1–R5 остаются отдельной квалификацией/решением.
G3 не переоткрывается. В memory остаются G4, G5 и прежние native/installed критерии;
optional homes, datasets/grants/currentness нужны до заявленного общего remember.

Публикация затронула только Git-репозиторий данных реестра. G4, Gate 6,
рабочая миграция, публикация workflow, deployment MCP, push workflow и PR не
выполнялись. Source-документация этой квитанции регистрируется отдельно обычным
RegisterChange/Status с существующим documentation contract; регистрация не
является вторым выпуском или публикацией workflow.

Сохранены ignored receipts `publication-inputs.json`, `publication-remote-proof.json`,
`published-data-validation.json`, `r6-publication-receipt.json` и проверенный
`registry-published-20261025.bundle`. История кандидатов, прежние стенды и sealed
G3 evidence сохранены. Секреты, локальные проекты и клиентские MCP config не менялись.
