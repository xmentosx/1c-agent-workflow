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

## Acceptance completion

Registry snapshot belongs to the existing vibecoding1c operation invocation.
Initialize (including selection and setup) and common update post-copy use the
same in-memory snapshot; nested operations reuse it and finally discard it.
Refresh failure captures cached data for selection only, never rewrites remote
connections, and does not turn unavailable dependent verification into a pass.
Ready/committed update continuation does not enter the post-copy operation again.

HTTP request and cleanup each have an explicit elapsed budget covering DNS,
connect, headers, redirects and body. An invocation-local cancellable transport
closes active sockets on expiry; daemon resolver work cannot hold the probe open.
Identity remains valid after optional health failure. Cleanup has its own bounded
budget and cannot expand the health method's recorded deadline.

Recovery sequencing and 60-second real-demand retry remain agent-owned, as already
specified; no service or durable retry state is added. Local acceptance uses real
loopback MCP endpoints, local Git publication and actual owner config writes.
An explicitly simulated supported client reconnect proves that branch only;
absence of a callable owning-client reload channel proves reload-required, not
attachment. Deployment, actual Ufa init and production reconnect stay excluded
by the user's server boundary.

## Qualification-discovered terminal cleanup defect

The exact integrated Targeted run exposed a compact-runner defect outside the
MCP transport: successful terminal status was overwritten when the action
budget elapsed during process cleanup. The existing 60-second terminal grace
was incorrectly preempted by that action deadline. The existing runner remains
the sole owner; no coordinator, persisted state or new blocking check is added.
Nonterminal operation and stale-heartbeat deadlines remain unchanged. Once a
terminal result is published, process exit uses the existing 60-second grace,
capped by the global 86400-second maximum. A helper that does not exit is still
stopped through the same owned process-tree termination path.

This corrects precedence at the existing terminal boundary. Normal operation
cost does not change; the edge case can wait up to the existing cleanup grace
instead of overwriting the result at the action deadline. Native evidence:
8-second action budget plus 10-second cleanup fails the old runner in 9.58s;
fixed runner completes in 14.16s. A deliberately stuck terminal helper is stopped
in 63.53s, below the 80-second regression bound. Original watchdog reproducer
workload, timeouts and assertions were retained; independent active-operation
and stale-heartbeat failure tests still pass.
