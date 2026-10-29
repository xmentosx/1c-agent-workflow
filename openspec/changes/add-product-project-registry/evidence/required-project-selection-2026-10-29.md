# Обязательный выбор существующего проекта, 2026-10-29

## Согласованная граница

Владелец согласовал: новая установка и первое обновление без привязки требуют
выбора существующего опубликованного проекта. Нет действий «позже», «оставить
как есть» или inline создания. Уже привязанный проект не выбирается повторно.
Отмена останавливает переход; отсутствие записи или валидного cache требует
подготовить запись/восстановить доступ и повторить ту же операцию.
Старый `associationOffer=later` не освобождает от выбора.

Создание остаётся отдельным `catalog create` у прежнего Git registry owner.
Пользователь сообщает название, заказчика/контекст и базовый продукт; агент
готовит запись по источникам, наследует проверенные настройки и показывает
проектные различия и связи для проверки. Адреса/UUID не становятся обязательной
анкетой пользователя. При отсутствии Git-прав прежний owner сохраняет готовую
заявку со стабильным ID, не отправляя её другим людям. Черновик доступен для
preview, но до подтверждённой публикации не подходит для init/select/update.
Неполные обязательные метаданные дополняются отдельно; осознанно отсутствующие
необязательные интеграции не превращаются в обязательный опрос.

## Архитектурный checkpoint

Инвариант принадлежит существующему registry setup owner: переход не завершается
без выбранной опубликованной записи. Прежний lifecycle owner отвечает за
пакет, снимок, commit и возобновление. Одного post-success сообщения недостаточно:
пустой ответ раньше позволял завершить update, а `later` навсегда убирал вопрос.

Обычный update разрешает выбор до managed copy. ID/profile/revision/settings hash
передаются в существующей snapshot receipt; post-copy проверяет тот же выбор.
Если старый caller уже скопировал пакет, новый signed child сначала проверяет
исходный snapshot и восстанавливает unfinished owned MCP, затем требует выбор
до пакетных изменений, через проверенный foreground input owner. Без ввода/при ошибке
он не сообщает успех: сохранённая транзакция продолжается тем же update helper
с `-CatalogProjectId`; для отмены/восстановления используются прежние recovery
команды и снимки. Уже скопированный пакет не называется автоматически откатанным.
Post-copy читает закреплённую revision через прежний operation pin, не новый
publisher tip. Расхождение ID/settings hash не принимается молча: требуется
прежнее restore/reconcile и новый переход. Время ожидания/locks/watchdog прежние;
unattended без ID немедленно получает конкретное продолжение, без сетевого опроса.

Применение использует прежний preview, full hash guard, marker-last, resume/restore
и включается в master commit обновляемой тестовой/установленной копии до её
обычного branch rollout. Новых машинных служб, ACL, координаторов, файлов очереди
и always-on правил нет. Metadata fetch остаётся у прежнего bounded reader/cache;
изменение касается init/update/явного select, не вводит барьер обычным командам.
Старые пакеты при downgrade не получают политику нового recovery executor:
признак читается у exact target source. Controlled ai_rules_1c не изменяется.

Привязка не доказывает native MCP/Cognee readiness. Memory default-on, explicit
off, шесть scopes, общая связь, IDs/pending и сохранение данных прежние. Рабочая
миграция, публикация workflow/реестра, master, Gate 6 и расширение G3/G5 не разрешены.

## Реализация и доказательства

Изменены прежние setup/init/update owners и source-side update launcher.
Существующие setup/caller-input регрессии обновлены под согласованную семантику;
отказ черновика сохраняет его preview/заявку, а успешный опубликованный read-back
допускает выбор. Положительный путь через исходную консоль, повтор без второго
выбора и строгий отказ до записи проверяются теми же владельцами тестов.

Focused setup/caller/scope: 65 passed, 0 failed, 218900 ms. После уточнений
owner setup/caller/compact: 63 passed, 0 failed, 255130 ms. Это последовательные
development observations, не A/B сравнение одного дерева; окончательный head
проверяется штатным RegisterChange в очереди `product-project-registry-g2`.
Регистрация этого же commit подтверждается через source-delivery Status, а не
дополнительной правкой checkbox после регистрации. Реальное исполнение/reuse,
выбранные владельцы и стоимость Targeted остаются в его штатном summary/журнале.
Selection использует прежние contracts product-project-setup/caller-input и
owners core/lifecycle/bootstrap; wildcard, бюджеты и selection rules не расширены.
Первый проход включает disabled-context/reuse regression, второй — исходную
capture/child/Unicode границу с теми же guards/deadlines. Постоянного Startup
опроса/нового сетевого запроса обычным командам не добавлено.

Первая регистрация отклонила общий кандидат на DeliveryGoInputScope: добавление
трёх catalog arguments/forwarding изменило audited SHA source-side launcher,
поэтому прежний fail-closed reader check перестал считать Go tests/README
build-only. Review полного diff подтвердил отсутствие чтения этих файлов;
к прежним допустимым SHA добавлен точный нормализованный UTF-8 SHA
`0112c05de9d755f9351571e4f76376aae8e26689599588fefd075f7b584f3855`.
Существующий тест без изменения assertions прошёл 4/0, 54680 ms: чтение README
новым consumer, runtime/Go embed изменения по-прежнему запрещают reuse.
Прошедшие shards первой попытки сохраняются у прежнего source-delivery owner;
повтор регистрации использует его обычную проверку inputs/runtime/reuse.

Вторая регистрация выявила преждевременный catalog barrier перед MCP snapshot
admission. Он перенесён после прежних guards/owned recovery, до новых policy и
package writes. Семь исходных snapshot/rollback проверок прошли без изменения
assertions, включая hash неизменённой receipt и прежние пути/количество слоёв.
Другой отказ — прежнее ожидание успеха unbound v1 fixture без project ID —
противоречит согласованному обязательному выбору. Тот же source fixture теперь
сначала доказывает отказ на исходном v1/unbound и неизменность HEAD/package,
затем публикует явный project/product в своём прежнем registry, сохраняя SPPR
endpoint, и повторяет исходный update на той же копии. Все прежние проверки
custom/runtime/DB-independent bytes, commits, MCP и clean Git сохранены.
Обе стороны child capture используют прежний общий UTF-8 transport; persisted
stdout/stderr читаются явно как UTF-8. Exact round-trip пути с пробелом и
кириллицей проверяется и в captured stdout, и после сохранения/чтения.
Dirty-source focused запуск был корректно отвергнут exact-source guard;
эта проверка не ослаблялась, приёмка продолжена только на чистом commit.
На чистом source дереве исходный snapshot/package-update набор завершился:
8 passed, 0 failed, 74210 ms; тот же временный проект после обязательного выбора
завершил update с прежними runtime/custom/MCP/commit assertions и Unicode proof.
Это source fixture acceptance, а не запуск на установленном PM5-пилоте.

В третьей регистрации full BootstrapUpdate уже прошёл; оставшиеся 9 отказов
UiTestingPolicyTransition были следствием отсутствующего контракта нового
registry owner в её unit-оснастке. Как и её прежние package/client installers,
успешные selection/association теперь заданы локальными dependency stubs только
для этих UI-policy fixtures; production capability/guard не отключены, пути,
snapshot/env bytes, policy assertions и rollback прежние. Все 45 UI-policy
тестов прошли, 87020 ms. Настоящие отсутствие ID/published selection и общий
writer сохраняются в полном исходном BootstrapUpdate/RequiredCatalogTransition.
Откат обязательной привязки противоречил бы решению владельца; расширение
UI-unit fixtures до отдельного Git/MCP/Cognee стенда добавило бы чужую
квалификацию. Выбран owner-local fixture contract без нового runtime state,
барьера или общего redesign. Новый прогон регистрации меняет только эти
test inputs/docs; reuse прошедших остальных shards остаётся у helper.

Четвёртая регистрация дошла до 70 файлов и обнаружила другой audited consumer:
Test-DevelopColdCutoverConsumers закреплял прежний SHA установщика. Review его
четырёх добавленных строк подтвердил: два catalog parameters и forwarding идут
после прежнего execution-guard cutover; cold admission/enumerator не меняются.
В прежний список добавлен точный нормализованный UTF-8 SHA установщика
`bd2b47285dffd7193c644abcb87af4ef46c401d7e1a192e33d53cc530d25729c`.
Прямой installer input остаётся связанным с proof; неизвестный consumer по-прежнему
закрывает projection. Все 6 DevelopBrokerInputScope прошли без изменения assertions,
156500 ms: исходная retained-record topology, cold Unicode root, malformed-state
refusal и отрицательные cold-guard/generation/unknown function/top-level/library/
live-prefix/runner/bootstrap/historical-SHA/unknown-scenario случаи сохранены.

Пятая регистрация завершила все 101 файла: 2052 passed, один отказ в исходном
SourceUpgradeHandoff. Его post-copy diagnostics fixture передаёт пустой sourceRoot.
Три прежних capability detectors (UI/verification/OpenCode) в таком случае
возвращают false; новый registry detector вызывал Join-Path до этой проверки.
Исправлена подтверждённая причина в его owner: отсутствие target source не
означает наличие новой policy. В существующий capability тест добавлена проверка
пустого пути; исходный SourceUpgradeHandoff и его assertions не изменены.
Проверка валидного target AST, обязательный выбор на актуальном пакете, source
admission и full hash guards сохранены. Failed candidate/proof сохранены,
принятые queue refs отказом не заменены.
Полный повтор SourceUpgradeHandoff + ProductProjectSetup: 99 passed, 0 failed,
129094 ms. Первый ручной повтор (98/1) сохранён: его дополнительный отказ был
RemoteException на обычном stderr `git worktree add` из-за Stop у ручной
оснастки. Для окончательного повтора применена та же Continue policy вокруг
Invoke-Pester, что в scripts/run-pester-shard.ps1; сами тесты не менялись.

Шестая регистрация проверяла обновлённый общий candidate на принятой базе
`a50a7fd968ddf1f393ad2aa4de7ec1e5566d6637`. Первые 101 parallel файла прошли
2055/0, затем serial ReleaseGate выявил один documentation regression: при
обновлении описания нового gate-stand исчезло точное имя source-snapshot.
Новый владелец scripts/new-gate-stand.ps1 по-прежнему использует
`.agent-1c/infobases/source-snapshot`; восстановлено именно это описание без
изменения теста, кода стенда или safety contract. Все остальные выполненные
файлы прошли: итог остановленного прогона 105 файлов, 2081/1.
Незарегистрированный коммит перенесён на эту уже принятую общую базу, сохраняя
прежний принятый own head в ancestry и все чужие изменения; range diff неизменен.
Полный исходный ReleaseGate после docs-исправления прошёл: 12/0, 5080 ms.
Седьмая попытка остановилась до Targeted: параллельно принята auto-gate-stand,
общая база стала `4c5238ce2d79c97413b7c73ada60c3261be4be12`, переписав тот же
вводный раздел. Собственный непринятый коммит перенесён на эту актуальную
принятую базу; точный snapshot path добавлен в неизменившийся safety paragraph,
а все принятые auto-stand изменения оставлены. На этой базе полный прежний
ReleaseGate снова прошёл 12/0, 6020 ms. Ни test assertion, ни код стенда не менялись.

Native переход PM5/клиентский reload этого изменения пока не выполнен;
исторические G3/G5 и QP5 не объявляются его native приёмкой.
Ignored inputs/results: `build/agent-artifacts/required-project-selection-20261029/`.
