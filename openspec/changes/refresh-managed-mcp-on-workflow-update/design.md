# Design

## Context

См. proposal.md. Общий final-set writer уже проверяет collisions до записи,
сохраняет auth/policy/disabled и умеет PreserveOwnedKeys; update имеет snapshot,
resume и registry-failure fallback. Используем этих владельцев.

## Goals / Non-Goals

Цель: безопасная сходимость MCP без глобального health gate.
За пределами: ремонт серверов, смена host/provider, повтор неизвестной мутации,
обещание reconnect без канала управления текущим клиентом.

## Decisions

1. В существующем client-managed.json хранить только семантические отпечатки
   последних подтверждённых записей по client/owner/key. Не хранить auth/секреты.
   При update изменённую запись сохранять целиком; legacy без отпечатка тоже
   сохранять консервативно. Не принимать сохранённый override за новый baseline.
   Это расширение данных существующего владельца, не отдельная state machine.
2. Полнота выбора требует однозначного endpoint/параметров, не health.
   Готовность остаётся отдельной проверкой зависимой операции. Отказ не удаляет
   уже установленное соединение; foreign identity никогда не доказывает готовность.
3. Identity probe сохраняет успешные initialize/tools/list отдельно от safe call.
   Health failure не даёт restart authority; mismatch repair по-прежнему требует
   здоровый idle internal endpoint и две чужие public identity.
4. Свежесть: существующий authenticated Git refresh один раз на операцию.
   Raw HTTP отвергнут: отдельный auth/override/cache контракт не нужен.
   Recovery выполняет refresh → тот же selection → owner sync → поддерживаемый
   reload/discovery → исходная операция. Отсутствующий канал reload честно означает
   reload-required. Интервал попыток контролируется текущей работой агента,
   без фонового процесса и постоянного offline-флага.

## Architecture checkpoint

Инвариант: настройки пользователя не становятся управляемыми по имени, сетевой
отказ не меняет selection. Владельцы и транзакции остаются прежними; новый общий
координатор, межвладельческое recovery и installed migration не вводятся.
Дополнительные отпечатки необязательны для чтения старым кодом; legacy значения
не перезаписываются автоматически. Windows 10/11/Server 2019+, все существующие
клиенты и terminal sessions сохраняются. Отсутствующий baseline требует
консервативного сохранения, а не блокировки. Штатный snapshot владеет rollback,
resume повторяет исходный update, ready checkpoint не делает новый fetch.
Canary: изолированные JSON/TOML/OpenCode fixtures и original init selection.
Live Уфа/dev-ermakov не входят в локальное доказательство.

## Risks / Trade-offs

- Legacy URL может остаться устаревшим → конкретная диагностика и явный review/
  штатный sync после согласования; угадывание по имени отвергнуто.
- При отказе registry свежесть не доказана → сохранить текущие записи.
- HTTP timeout не равен сроку SSE → читать поток частями с оставшимся бюджетом,
  завершать после нужного JSON-RPC результата.

## Migration Plan

Новые записи получают baseline при штатной записи; старые сохраняются без
принудительной миграции. Rollback через существующий workflow snapshot.
Публикация/установка и live canary требуют отдельного поручения.
