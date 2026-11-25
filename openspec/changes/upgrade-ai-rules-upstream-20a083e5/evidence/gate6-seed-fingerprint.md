# Seed и побайтный индекс: отказ первой fresh journey — 2026-10-04

На кандидате `beee31c997b83c5ff5c8107305336168bcc22fe9` прошли upgrade
journey с реальной Vanessa и экспортом, 2504 Pester-проверки без ошибок и
пропусков и совместимость с двенадцатью клиентами. Fresh project установился,
ветка создалась, но исходный `fresh-check` отказал на Gate 6. Публикации нет;
10.6, 12.1/12.2 и 13.5 остаются открытыми.

Исходный reproducer сохранён: `C:\itlj\p Проект\d-2db8a026-develop-golden`,
run `compact-20261004-062453-522-f5b3e125`. CheckModules прошёл; CheckConfig
сохранил exit/DumpResult 101. Его полный `/Out` содержит 629 строк/141700
байт, SHA-256 `6631d07d3f9c4900c1e0ac540ba644695c728791ed3d3ea4997402f9ab971726`.
Одно замечание в кратком сообщении означает ограниченный excerpt, а не весь
результат. Отказ завершился штатным RestoreIB; before-load CheckConfig не
запускался, поскольку seed context не прошёл проверку соответствия.

Seed получил fingerprint `bc744fc3b0737ce5983946f10b110afd50a1916866194556ce92264aefea165e`
до включения `-text`; первый authoritative commit получил
`56bb357dd8139232e329011f4873a73938bbd4877a064b91614e51314ee37614`.
Retained CF trees `e78132ccf27da4ede52b022b57ab693701915f2d` и
`53a9c5c3256d9ee6851ca367a5457dd5b5660a73` воспроизводят эти fingerprints
исходным алгоритмом. В обоих 19286 путей: добавленных/удалённых нет,
16793 blob изменились только из-за CRLF; `--ignore-cr-at-eol` даёт diff exit 0.
Raw export Configuration.xml уже до fingerprint имел SHA-256
`bb127cb4e355cf2d23e8ec5d7acde9bb4f35198aa9492bbf6230d511fcd86faa`,
равный итоговому raw blob. Golden Comment добавлен после записи обоих stamps.

Исправлен producer: существующий `Ensure-OneCSourceGitAttributes` вызывается
после успешной authoritative выгрузки, перед fingerprint — в file seed и
четырёх Init/Sync ветках. Алгоритм fingerprint, seed equality guard, native
flags и финальный authoritative rebuild/commit сохранены. Read-only status
и fingerprint не получают записи. Неуспешная native выгрузка не добавляет
новую грязную `.gitattributes` перед повтором Sync.

Focused PS5.1/Pester5.8: RED 0/2 на первой установке и старом Sync;
GREEN 3/3 на том же CRLF input, включая failed dump → ту же Sync/Rebuild.
Реальные Git blobs и рабочие файлы совпадают побайтно; root/module содержат
пробел и кириллицу. Дополнительно прошли шесть исходных affected tests и
positive LegacyContext. Negative ForEach не был выбран; прежнее ожидание
драйвера «8» не является результатом 8/8. Все setup/expectation failures
сохранены отдельно. После review изменена только проверка containment нового
test cleanup; окончательный test input квалифицирует RegisterChange.

Повторная live fresh journey требуется на исправленном producer с исходными
условиями и workload. Старая failed ветка не исправлялась вручную: rebuild
главного seed не переписывает её stamp. Существующий reset архивирует ветку
и DT, затем заменяет исходники/базу; он не принят как прозрачное продолжение
этого reproducer. Реальные проекты и workflow master не обновлялись.
