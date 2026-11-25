# Разбор накопленных заметок PM5, 2026-11-15

Задача 7.1. Источник — локальные исходники памяти всех копий PM5: 65 записей, синтетика G5 исключена. Список с предложенными текстами пользователь утвердил в чате 2026-11-15 с одной правкой: заметка о кэше повторно используемых значений относится к линейке PM5, а не к organization (в PM4 может работать иначе), и перенесена в product с оговоркой «для PM4 не проверено». Тексты заметок сюда не переносятся.

## Итог

| Действие | Заметок | Результат |
|---|---|---|
| Новые заметки | 16 из 17 исходных | 16 `durable`: product 9, organization 4, project 3 |
| Оставлены в task (решения пользователя текущего change) | 13 | без изменений |
| Сняты `retire_note` | 47 | 47 `retired`: 2-branch2 38, 1-branch10 7 (в т.ч. 1 project), 1-branch4 2 |
| Черновик pending от 2026-11-08 | 1 | `discarded-unsent` |
| Без действия | 4 | canary уже снята; task прошлого цикла не видна в recall; заметка уже в product; синтетика QP5 из удалённой копии |

## Квитанции новых заметок

| ID | Назначение | routeReason | dataId |
|---|---|---|---|
| `pm5-econ-single-task-read-merge-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `5601c666-2b19-447d-9d2f-3eddf702ff67` |
| `pm5-model-uuid-field-identity-role-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `8a0285c2-ad3b-4a65-bfe4-5c833ae15ceb` |
| `pm5-deferred-redistribution-immediate-flag-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `27931d76-5167-469a-a5c0-314b29b8d1a4` |
| `1c-date-arity-yaxunit-module-skip-20261115` | `itl_organization_itland_qwen4096_v1` | — | `a2592e0f-6ee4-4e0b-8e55-ab2b79822697` |
| `pm5-manual-fact-physical-source-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `050a4c80-44eb-4397-b7b0-de344df5220c` |
| `pm5-scaled-distribution-signature-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `e3042d24-90e0-4440-a82b-4934280731a7` |
| `1c-structure-property-resets-output-20261115` | `itl_organization_itland_qwen4096_v1` | — | `dfab8d35-107e-4124-9c34-b2f849195008` |
| `1c-or-short-circuit-property-20261115` | `itl_organization_itland_qwen4096_v1` | — | `a0bc0123-61ad-47ee-bc56-36734a73da13` |
| `pm5-table-editor-vanessa-input-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `c8482f71-921e-4ffd-ba12-c64cb5cf75e7` |
| `pm5-econ-date-expansion-plan-model-key-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `78793a1c-28fb-4e4f-a4aa-996179489bfa` |
| `pm5-option-cache-during-call-tests-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `78bd2385-894b-4f9a-acad-89b4dd7ab6f5` |
| `1c-current-row-after-async-question-20261115` | `itl_organization_itland_qwen4096_v1` | — | `06b2affa-b009-4bc9-8337-8742bfcd98e8` |
| `pm5-plan-model-location-constant-20261115` | `itl_product_pm5-corp_qwen4096_v1` | product-home | `ca9535e8-3894-4ea5-b181-c63de2b4397a` |
| `pm5-daily-grid-5000-testclient-memory-20261115` | `itl_project_pm5-core-development_qwen4096_v1` | existing-note | `523e0f5b-f4eb-4c54-b99a-6065dc2fb81e` |
| `pm5-arp-renga-import-baseline-defects-20261115` | `itl_project_pm5-core-development_qwen4096_v1` | no-area | `e26de989-648f-4efd-9bd2-67b7d19a1b34` |
| `pm5-fresh-ib-roles-bsp-itl-update-20261115` | `itl_project_pm5-core-development_qwen4096_v1` | no-area | `0b069895-4996-43a9-a9bc-5287c65e1bdb` |

Три записи в project сначала вернули `unconfirmed` (таймаут 61 с). Одна подтверждена повтором с тем же `note_id`; для двух сервер ответил «не повторять remember», и `memory_status(dataset_name, note_id)` через несколько минут показал `durable`. Дублей нет, pending пуст.

## Проверка

`recall` из 2-branch2: запрос о `Структура.Свойство` вернул одну карточку `1c-structure-property-resets-output-20261115` (organization), запрос о чтении экономики одной задачи — одну карточку `pm5-econ-single-task-read-merge-20261115` (product); `belowThreshold` 35 и 34.
