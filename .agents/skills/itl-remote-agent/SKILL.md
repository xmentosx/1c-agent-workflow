---
name: itl-remote-agent
description: Assign, continue, inspect or diagnose work with an AI agent on another Windows machine, including remote 1C tests and measurements through the shared ITL runner. Use when the user chooses an agent or a machine profile permits assistance after worker failure.
---

# ITL remote agent

This is an alternative execution route to `itl-remote-runner`. Performance jobs still use `itl-performance` and its identical runtime on the target machine. An agent's chat response is not a measurement artifact.

Read [agent adapters](references/adapters.md) for the chosen harness. Shared job and authorization details are in [the runner contract](../itl-remote-runner/references/contracts.md).

1. Resolve the exact host, workspace, target and existing/new agent task from the user's request and private profile. Do not infer remote task control from SSH access or from a UI feature being documented. Probe the actual adapter. Preserve a requested model; otherwise use the host's configured default.
2. Package the scenario and allowed operations through the shared runtime with `--route agent`, and send through SSH or the configured exchange folder. The user-started remote worker dispatches the job to the selected agent. No remote agent is needed for the ordinary worker route.
3. Deliver the job ID, input locations, runtime path, criteria and permissions. Instruct the agent to invoke `remote_work.py execute --via-agent` for the same job, never to replace timings with its own observation or a chat-based timer. The measurement and profiling clocks run on the execution host.
4. Save the actual returned thread ID immediately. Inspect state and collect `result.json` and its artifacts. Do not create a replacement task after uncertain delivery. Use the adapter's explicit follow-up action only when further work is authorized.
5. If the worker failed, automatic fallback may inspect the existing state and write diagnosis. It may not replay updates, remove locks, alter assertions, change target/permissions, or claim a partial result complete. Continued modifying work is a new job after effect/ownership reconciliation.

Agent authentication and approval prompts retain the host's policy. Surface a pending user action; do not disable sandbox/approvals to make the bridge work. Desktop incompatibility leaves worker/SSH usable. Computer Use is not needed for Vanessa/TestClient and is not automatically enabled; any additional tools must be available on the intended remote host and within the user's task.
