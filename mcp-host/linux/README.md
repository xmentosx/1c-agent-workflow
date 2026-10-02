# Dedicated Linux MCP host

`watchdog.py` is the source of the existing dedicated-host watchdog deployed on
dev-karimov-new. It owns only the configured, label-validated container allowlist
and the existing OS maintenance lock. Its systemd service/timer and indexing
runner retain their existing configuration and lock; this package does not
install a new coordinator, privilege boundary or scheduler.

Deploy `watchdog.py` into the existing host directory and deploy the shared
`../endpoint_identity.py` into its parent directory. Preserve a copy of the old
watchdog and host config before replacing them. Existing configs without
`mcpEndpoints` keep their original container recovery behavior.

Add `mcpEndpoints` entries only for owned MCP containers, for example:

```json
{
  "container": "itl-unfpm5-code",
  "url": "http://dev-karimov-new.itland.local:22100/mcp",
  "hostPort": 22100,
  "healthTool": "stats"
}
```

The common read-only probe validates the published port binding, initializes
MCP inside the immutable container ID, reads its full structural tool catalog,
and runs its agreed safe health tool. Two public probes must match that server
name and catalog; a safe public health call completes acceptance. Description
text is excluded from the fingerprint, while JSON schema properties remain.
Diagnostic sessions are terminated. No response bodies or credentials enter
the persisted status.

A twice-confirmed foreign endpoint authorizes at most one restart per run of
that exact owned container, only when its internal health proof passed and no
indexing is active. The public identity and safe call must pass afterward.
Unknown identity, timeout, tool errors or indexing preserve the container and
appear in the existing watchdog status. A failed recovery reports failure
instead of publishing success. Use the existing service again after fixing the
route; the timer retries through the same lock. A maintenance lease skips the
entire recovery path, including endpoint probes.

Acceptance includes HTTP fixtures for an open foreign port and real transported
container probes, both owners' bounded recovery tests, and the real Linux lock
test. On the live host run the existing service and compare container IDs,
images, mounts and start times to prove a healthy installation caused no restart.
Rollback restores the prior watchdog/config; container images and volumes are
never changed by this endpoint repair.
