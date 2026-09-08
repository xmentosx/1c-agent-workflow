# Remote agent adapters

Configure the optional `agent` object in the worker's private profile. Do not infer a working adapter merely from the installed app. SSH/exchange provides delivery; the selected agent runs on the worker host.

## Codex App Server

Use `kind: codex-app-server`, `command: ["codex", "app-server"]`, optional explicit `model`, and `timeoutSeconds` (default 900). `codex` must be installed and authenticated for the worker user. The adapter performs `initialize` → `initialized`, `thread/start`, `turn/start` and observes completion. It preserves host approval/sandbox defaults.

Thread identity is saved before a turn is submitted. An uncertain request is never repeated automatically. `agent-request` supports explicit follow-up/read/interrupt on the saved task; a completed agent turn is not proof of a measurement unless the same job's engine result exists. If the server requests approval or input, the adapter saves `pending-request.json` and reports attention required. The connection stays open until its timeout. Inspect with `agent-request --spool <path> --id <id> --action read`, then explicitly answer with `--action respond --payload <json>` containing the exact `requestId` and protocol `result`. Never invent consent. After a lost connection, `--action followup --payload <json>` with a `prompt` resumes the saved task; it does not replay an interrupted engine job. `interrupt` stops a live owned App Server turn; Desktop interruption is available only if advertised by that build. SSH controllers use `remote --action agent-request --agent-action ...`. Remote follow-up payloads also require a unique `controlId`: resend that same ID/payload after uncertain delivery. Follow-ups are queued for the user-started worker, so SSH never starts a new agent in the wrong Windows session. `read` includes control delivery states; a dispatched control without a result requires inspection, not replay.

The stdio protocol is documented at https://learn.chatgpt.com/docs/app-server . It is distinct from Desktop MCP app tools; do not send `tools/list` to App Server or `thread/start` to MCP.

## Codex Desktop

Use `kind: codex-desktop`, the exact target `threadId` (or an explicitly authorized `createThread` object with the supported tool's `target` and optional title/model), and `discoverCommand`, an argv array returning JSON with `command`, optional `cwd`/`env`, and `contextThreadId`. The bundled `Discover-CodexDesktop.ps1` supports current exported Codex pipe/Node environment or one unambiguous configured Desktop installation/live pipe. It refuses ambiguous discovery. Run discovery on every connection rather than saving a versioned installation path or pipe UUID.

The command starts the app-tools MCP bridge on the execution host. Probe `initialize` → `notifications/initialized` → `tools/list`, validate the required tool names and thread-ID input fields, then call app tools with the discovered context. `send_message_to_thread` assigns work and `read_thread` observes it. A target task must be explicitly selected or created through the supported app tool. If the requested task, bridge or method is unavailable, report that precise capability gap; preserve SSH execution.

This is a compatibility adapter, not a promise that every Desktop build exposes remote task control. An app upgrade invalidates discovery; do not reuse stale coordinates, pipes or private bundle paths. No browser/mouse/keyboard tools are enabled automatically.

## Execution and diagnosis

The task receives the shared job, runtime path, profile path, allowed operations and completion contract. It must call `execute --via-agent` for actual work. It may not produce invented result JSON or replace the supplied scenario with an easier benchmark. A worker interruption instead assigns diagnosis-only work; the agent reads current artifacts and writes diagnosis without replaying mutations. Its thread and current status are in `agents/<job-id>/state.json`.

Normal controller disconnection does not stop the worker or Desktop task. After an uncertain assignment, inspect the saved thread and job; do not submit another paid turn automatically. Timeouts/interruptions are surfaced with saved task IDs so the user can continue intentionally.
