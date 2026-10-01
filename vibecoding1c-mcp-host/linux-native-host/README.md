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

## Nightly refresh

`windows_nightly.py` is the Windows scheduled-task entrypoint. The existing
Windows host export helper remains the Designer owner and inherits the exact
infobase execution guard. It exports one configuration, creates an immutable
UTF-8 tar archive, transfers it using a dedicated SSH key and a pinned guest host
key, and calls `refresh.py` in the VM. Configurations run sequentially; failure
of one is recorded and does not prevent the next configuration from running.
Use a password-backed Task Scheduler principal with access to the repository
share for unattended exports. Enter that password locally during provisioning;
never put it in JSON, arguments or logs. `IgnoreNew` prevents overlapping task
instances. Set the same 02:00 schedule as the existing Windows host.

The deployment-only Windows config extends the normal host export config with
`rootPath`, `workflowPath`, `guardRoot`, `linuxHost`, `linuxUser`, `identityFile`,
`knownHostsFile`, `hostKeyAlias`, `sshPath`, `scpPath`, and `timeoutSeconds`.
Each configuration keeps the canonical `sourcePath`, `mainConfigPath`, and
`dump` settings, including its own platform version and repository address.
Provision dedicated export infobases first. Use paths on the selected SSD.

Linux `refresh.config.json` contains `dataRoot`, `metadataGenerator`,
`timeoutSeconds`, `pollSeconds`, and `configurations`. Each configuration has
`configId`, `sourcePath`, `metadataPath`, `codeContainer`, `graphContainer`,
`codeUrl`, and `graphUrl`. Sources must be under `<dataRoot>/sources`, metadata
under `<dataRoot>/metadata`. Create `<dataRoot>/incoming` for the transfer user
with mode 0700; install `rsync` and the pinned metadata report generator.

`refresh.py` consumes the watchdog's existing maintenance lease. It validates
the archive checksum and paths and generates the report before stopping either
MCP. A failed export, checksum or report does not replace the live source. Both
container identities are checked against the existing allowlist and host/config
labels. Only the selected Code and Graph services stop briefly while their bind
directories are synchronized; they restart in a `finally` block. Neo4j and index
volumes are preserved. Native startup updates changed input incrementally with
database reset disabled. Identical successful input is skipped. Disabled optional
Graph lanes are allowed; failed required lanes, empty Code indexes, local
embedding fallback and an unhealthy remote provider fail acceptance.

Windows writes `state/nightly-index-state.json` and UTF-8 logs under
`logs/nightly`. Linux writes `<dataRoot>/refresh-state/<configId>.json`, report
logs and full native Code/Graph status snapshots. A successful timestamp is
recorded only after both native indexing statuses complete. The Linux refresh
runs in the exact `itl-mcp-refresh-<configId>` systemd unit with a twelve-hour
runtime limit and survives a control-channel disconnect. Stop the Windows task
to prevent further configuration work; stop that exact Linux unit to cancel its
active refresh. Process exit releases the corresponding lease. After a failure,
inspect these states and rerun the same task: a fresh
export and incremental native refresh provide the continuation, without manual
lock or state edits. Initial full indexing and a reboot/search acceptance remain
separate from registration of the schedule.
