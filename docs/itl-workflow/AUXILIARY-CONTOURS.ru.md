# Дополнительные контуры

`auxiliaryContours` нужны, когда одной ветке разработки требуется ещё одна конфигурация или база: для обмена, серверного замера либо временного эксперимента. Если раздел отсутствует, workflow работает как раньше.

```json
{
  "auxiliaryContours": {
    "exchange": {
      "configurationPath": "src/configs/exchange/cf",
      "baseMode": "managed-file",
      "sourceMode": "read-write",
      "tests": { "includePrimary": true, "path": "tests/auxiliary/exchange" },
      "extensions": [
        { "name": "ExchangeSupport", "path": "src/configs/exchange/cfe/ExchangeSupport" }
      ],
      "mcp": { "roctup": true, "vanessaUi": true }
    }
  }
}
```

- `managed-file` — локальная база workflow; reset перемещает её в игнорируемый архив. `attached-readonly` — внешняя база без загрузки, выгрузки исходников и тестов; `attached-disposable` — явно одноразовая внешняя тестовая база.
- `load-only` загружает файлы в базу; `read-write` также разрешает транзакционную выгрузку. `src/cf` всегда только `load-only`, у другого пути может быть лишь один `read-write` владелец.
- Подключение внешней базы хранится в `.dev.env`: `ITL_AUX_<REF>_INFOBASE_KIND`, `ITL_AUX_<REF>_INFOBASE_PATH`, `ITL_AUX_<REF>_USER`, `ITL_AUX_<REF>_PASSWORD`.
- Обновление всегда выполняет полную загрузку конфигурации и объявленных расширений. Обычные операции основной базы дополнительные контуры не обновляют.
- `includePrimary` запускает на контуре основной набор Vanessa; `path` добавляет отдельный. При наличии обоих только полный последовательный прогон создаёт доказательство для CF.
- Корни наборов не должны пересекаться: отдельный набор нельзя размещать внутри `tests/features`, если это корень основных тестов.
- CF и манифест сохраняются в `build/result/auxiliary/<id>/`, отчёты — в `build/test-results/vanessa/auxiliary/<id>/`.
- MCP имеют отдельные имена `itl-roctup-aux-<id>` и `itl-vanessa-ui-aux-<id>`; основные MCP не меняются.

Для одного сценария обмена между базами используйте manifest TestClient schema 2 и поле `contour` в профиле:

```json
{
  "schemaVersion": 2,
  "maxConcurrency": 2,
  "profiles": [
    { "name": "Source", "contour": "primary" },
    { "name": "Receiver", "contour": "exchange" }
  ]
}
```

Schema 1 остаётся совместимой и всегда адресует основную базу. Выбор контура явный; глобального активного контура нет.
