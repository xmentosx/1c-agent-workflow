# Dedicated Linux Docker host

This backend runs pinned native Code and Graph containers in a dedicated Linux
VM. Windows remains the owner of 1C Designer exports. Docker Engine and the
systemd timer run without a logged-in session. The Windows host installer and
its existing watchdog remain separate and unchanged.

Runtime Compose files, credentials, sources, indexes and `host.config.json`
are local deployment data and must remain outside Git. Use this configuration:

```json
{
  "hostId": "dev-example",
  "composePath": "/opt/itl-mcp/compose.yml",
  "containers": ["itl-example-code", "itl-example-graph", "itl-example-neo4j"],
  "lockPath": "/var/lib/itl-mcp/maintenance.lock",
  "statusPath": "/var/lib/itl-mcp/watchdog-state.json"
}
```

Every Compose service must have an explicit allowlisted `container_name`, an
image pinned with `@sha256:...`, and label `itland.mcp.host=<hostId>`. Install
this directory as `/opt/itl-mcp/host` and the units under `/etc/systemd/system`;
then enable `itl-mcp-watchdog.timer`. Keep Compose and secret files readable
only by the administrator. Recovery validates all existing container identities
before starting or restarting any. It does not delete containers, volumes or
indexes. A failed Docker daemon may be restarted because the VM is dedicated.

The same owner serializes watchdog recovery and indexing. Run every indexing,
source replacement, intentional stop or other maintenance command with:

```sh
sudo python3 /opt/itl-mcp/host/watchdog.py --config /opt/itl-mcp/host.config.json --hold <command> <arguments>
```

The watchdog skips while that OS lock is held. Waiting maintenance is blocking;
cancel the waiting command normally to stop waiting. Process exit releases the
lock automatically; there is no stale lock-file deletion step. Timer recovery
is bounded by the service timeout and records state in `statusPath` and the
journal. Disable the timer before leaving containers intentionally stopped.
`healthy` means container liveness; initial acceptance separately requires MCP
initialization, tools, full index status and representative searches, including
after a Windows restart without user login.
