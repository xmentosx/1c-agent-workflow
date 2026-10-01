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
infobase execution guard. It exports one configuration and calls `refresh.py`
over SSH using a dedicated key and a pinned guest host key. The VM reads the
Windows export directory through a read-only SMB 3.1.1 share. The exact export
infobase guard remains held through refresh, so another authorized Designer
export cannot change that input. Configurations run sequentially; failure
of one is recorded and does not prevent the next configuration from running.
Use a password-backed Task Scheduler principal with access to the repository
share for unattended exports. Enter that password locally during provisioning;
never put it in JSON, arguments or logs. `IgnoreNew` prevents overlapping task
instances. Set the same 02:00 schedule as the existing Windows host.

The deployment-only Windows config extends the normal host export config with
`rootPath`, `workflowPath`, `guardRoot`, `linuxHost`, `linuxUser`, `identityFile`,
`knownHostsFile`, `hostKeyAlias`, `sshPath`, and `timeoutSeconds`.
Each configuration keeps the canonical `sourcePath`, `mainConfigPath`, and
`dump` settings, including its own platform version and repository address.
Provision dedicated export infobases first. Use paths on the selected SSD.

Linux `refresh.config.json` contains `dataRoot`, `exportRoot`, `metadataGenerator`,
`timeoutSeconds`, `pollSeconds`, and `configurations`. Each configuration has
`configId`, `exportPath`, `sourcePath`, `metadataPath`, `codeContainer`, `graphContainer`,
`codeUrl`, and `graphUrl`. Sources must be under `<dataRoot>/sources`, metadata
under `<dataRoot>/metadata`. `exportPath` is under the read-only `exportRoot`
mount. Use a dedicated Windows account with read permission only for the
owned export directory, SMB encryption, a firewall rule scoped to the VM and
credentials readable only by the administrator. Configure an on-demand systemd
mount with explicit `iocharset=utf8` and the `nls_utf8` kernel module so Cyrillic
names round-trip correctly and the share works after restart without a user session. Minimal
Ubuntu VM images require the matching `linux-modules-extra` package; retain it
for future kernels through the `linux-image-generic` package. If mounting reports
missing UTF-8 support, install that package and remount the owned export share
before rerunning the same refresh. Create
`<dataRoot>/incoming` for temporary report generation; install `rsync` and the
pinned metadata report generator.

`refresh.py` consumes the watchdog's existing maintenance lease. It validates
the export paths and Designer revision records and generates the report before
stopping either MCP. A failed export or report does not replace the live source. Both
container identities are checked against the existing allowlist and host/config
labels. Only the selected Code and Graph services stop briefly while their bind
directories are synchronized with only changed files; they restart in a `finally` block. No
daily archive or full transfer is performed. Neo4j and index
volumes are preserved. Native startup updates changed input incrementally with
database reset disabled. The Designer-owned `ConfigDumpInfo.xml`, configuration
identity and report define refresh input; this avoids rereading all BSL over SMB
just to compute a second content hash. Revision checks detect input changing
during report generation or synchronization. Identical successful input is
skipped. Disabled optional
Graph lanes are allowed; failed required lanes, empty Code indexes, local
embedding fallback and an unhealthy remote provider fail acceptance.

The metadata generator's documented exit code 1 means completed with warnings;
other nonzero codes fail refresh, matching the Windows host owner. The report
and its diagnostics are retained, and missing or empty reports fail acceptance.

Windows writes `state/nightly-index-state.json` and UTF-8 logs under
`logs/nightly`. Linux writes `<dataRoot>/refresh-state/<configId>.json`, report
logs and full native Code/Graph status snapshots. A successful timestamp is
recorded only after both native indexing statuses complete. The Linux refresh
runs in the exact `itl-mcp-refresh-<configId>` systemd unit with a twelve-hour
runtime limit and survives a control-channel disconnect. The configured refresh
deadline also bounds source synchronization: a first full ERP export can exceed
10 GiB and must not inherit a short command timeout intended for small updates.
Stop the Windows task
to prevent further configuration work; stop that exact Linux unit to cancel its
active refresh. Process exit releases the corresponding lease. After a failure,
inspect these states and rerun the same task: a fresh
export and incremental native refresh provide the continuation, without manual
lock or state edits. Initial full indexing and a reboot/search acceptance remain
separate from registration of the schedule.
