"""Prepare a user-started worker and export the same runtime without full ITL."""
from __future__ import annotations

import os
import hashlib
import json
from pathlib import Path
import platform
import re
import secrets
import shutil
import sys
import tempfile
import uuid
import zipfile
from datetime import datetime, timezone

from . import VERSION
from .common import (WorkError, current_user_identity, digest, process_identity, process_is_alive, read_json,
                     publish_path, resolve_resource_limits, stamp, write_json)


WORKER_HEARTBEAT_MAX_AGE_SECONDS = 5.0


def _worker_heartbeat_age(value):
    try:
        captured = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if captured.tzinfo is None:
            captured = captured.replace(tzinfo=timezone.utc)
        return max(0.0, (datetime.now(timezone.utc) - captured).total_seconds())
    except (TypeError, ValueError):
        return None


def inspect(spool):
    spool = Path(spool).resolve()
    result = {"schemaVersion": 1, "version": VERSION, "python": platform.python_version(),
              "host": platform.node(), "spool": str(spool), "ssh": shutil.which("ssh"),
              "powershell": shutil.which("pwsh") or shutil.which("powershell"),
              "worker": None, "pull": None, "runtime": {"current": None, "pending": None},
              "targets": [], "agentConfigured": False, "hostCommandsEnabled": False}
    if (spool / "worker.json").exists():
        result["worker"] = read_json(spool / "worker.json")
        worker = result["worker"]
        worker["heartbeatAgeSeconds"] = _worker_heartbeat_age(worker.get("updatedAt"))
        # A saved PID is never enough: bind it to process creation and a fresh pulse.
        if not process_is_alive(worker.get("pid")):
            worker["liveness"] = "stale"
        elif not isinstance(worker.get("processIdentity"), dict):
            worker["liveness"] = "identity-unverified"
        else:
            try:
                current_identity = process_identity(worker["pid"])
            except WorkError:
                current_identity = None
            if current_identity != worker["processIdentity"]:
                worker["liveness"] = "identity-mismatch"
            elif worker["heartbeatAgeSeconds"] is None or worker["heartbeatAgeSeconds"] > WORKER_HEARTBEAT_MAX_AGE_SECONDS:
                worker["liveness"] = "heartbeat-expired"
            else:
                worker["liveness"] = "process-identity-and-heartbeat-verified"
        if worker["liveness"] != "process-identity-and-heartbeat-verified" and worker.get("status") != "stopped":
            worker["status"] = "stale"
    if (spool / "profile.json").exists():
        profile = read_json(spool / "profile.json")
        result["targets"] = [{"name": name, "workspaceExists": Path(target["workspace"]).is_dir(),
                              "operations": target.get("allowedOperations", []), "profilingConfigured": bool(target.get("rdbg"))}
                             for name, target in profile.get("targets", {}).items()]
        result["agentConfigured"] = bool(profile.get("agent"))
        host_commands = profile.get("hostCommands")
        result["hostCommandsEnabled"] = (isinstance(host_commands, dict) and
                                         host_commands.get("enabled") is True)
        result["workerUpdatePolicy"] = profile.get("workerUpdatePolicy", "disabled")
    if (spool / "pull-connection.json").exists():
        result["pull"] = read_json(spool / "pull-connection.json")
    for name in ("current", "pending"):
        path = spool / "runtime" / (name + ".json")
        if path.exists():
            value = read_json(path)
            result["runtime"][name] = {key: value.get(key) for key in
                                       ("version", "archiveSha256", "stagedAt", "confirmedAt", "bootstrap")
                                       if value.get(key) is not None}
    return result


def prepare(spool, configuration, worker_connection=None, update_policy=None, *, resume=False):
    spool = Path(spool).resolve()
    profile = read_json(configuration)
    host_commands = profile.get("hostCommands", {})
    if (profile.get("schemaVersion") != 1 or not isinstance(host_commands, dict) or
            not isinstance(profile.get("targets", {}), dict) or
            (not profile.get("targets") and host_commands.get("enabled") is not True)):
        raise WorkError("WORKER_PROFILE_TARGETS_REQUIRED")
    if host_commands.get("enabled") is not None and type(host_commands["enabled"]) is not bool:
        raise WorkError("HOST_COMMANDS_PROFILE_INVALID")
    if host_commands.get("enabled") is True:
        resolve_resource_limits(host_commands)
    for target in profile.get("targets", {}).values():
        if not Path(target["workspace"]).is_dir() or not target.get("allowedOperations"):
            raise WorkError("TARGET_WORKSPACE_OR_OPERATIONS_MISSING")
        resolve_resource_limits(target, target["allowedOperations"])
    connection = None
    if worker_connection is not None:
        connection = read_json(worker_connection)
        if connection.get("transport") != "pull":
            raise WorkError("WORKER_CONNECTION_PULL_REQUIRED")
        from .pull import _pull, _bulk_folders
        _pull(connection)
        _bulk_folders(connection)
        if update_policy is None:
            update_policy = "compatible"
    if update_policy is not None:
        if update_policy not in ("disabled", "compatible"):
            raise WorkError("WORKER_UPDATE_POLICY_INVALID")
        profile["workerUpdatePolicy"] = update_policy
    profile["workerOwner"] = current_user_identity()
    spool.mkdir(parents=True, exist_ok=True)
    profile["profilePath"] = str(spool / "profile.json")
    existing_profile = spool / "profile.json"
    if existing_profile.exists():
        if not resume:
            raise WorkError("WORKER_ALREADY_CONFIGURED: edit its private profile explicitly")
        if read_json(existing_profile) != profile or (spool / "worker.json").exists():
            raise WorkError("WORKER_RESUME_PROFILE_OR_OWNER_MISMATCH")
        jobs_dir = spool / "jobs"
        if jobs_dir.is_dir() and any(jobs_dir.iterdir()):
            raise WorkError("WORKER_RESUME_JOB_STATE_EXISTS")
    else:
        write_json(existing_profile, profile)
    script = Path(__file__).resolve().parent.parent / "remote_work.py"
    supervisor = script.parent / "worker_supervisor.py"
    if not supervisor.is_file():
        raise WorkError("WORKER_SUPERVISOR_MISSING")
    worker_connection_path = None
    if connection is not None:
        worker_connection_path = spool / "worker-connection.json"
        if worker_connection_path.exists() and read_json(worker_connection_path) != connection:
            raise WorkError("WORKER_RESUME_CONNECTION_MISMATCH")
        write_json(worker_connection_path, connection)
    runtime_root = spool / "runtime"
    current_path = runtime_root / "current.json"
    current = {"schemaVersion": 1, "version": VERSION, "runtime": str(script),
               "supervisor": str(supervisor), "bootstrap": True}
    if current_path.exists() and read_json(current_path) != current:
        raise WorkError("WORKER_RESUME_RUNTIME_MISMATCH")
    write_json(current_path, current)
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    launcher = ("$ErrorActionPreference='Stop'\n$env:PYTHONUTF8='1'\n$env:PYTHONIOENCODING='utf-8'\n"
                "$env:PYTHONDONTWRITEBYTECODE='1'\n$env:PYTHONNOUSERSITE='1'\n$env:PYTHONHOME=$null\n"
                "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"
                "$current=" + quote(runtime_root / "current.json") + "\n"
                "$supervisor=" + quote(supervisor) + "\n"
                "if(Test-Path -LiteralPath $current){$state=[IO.File]::ReadAllText($current,[Text.Encoding]::UTF8)|ConvertFrom-Json;"
                "if($state.supervisor -and (Test-Path -LiteralPath $state.supervisor)){$supervisor=$state.supervisor}}\n"
                "& " + quote(sys.executable) + " -B -X utf8 -u $supervisor --spool " + quote(spool) +
                " --bootstrap-runtime " + quote(script) +
                ((" --connection " + quote(worker_connection_path) + " --persistent") if worker_connection_path else "") +
                "\nexit $LASTEXITCODE\n")
    (spool / "Start-Worker.ps1").write_text(launcher, encoding="utf-8-sig")
    (spool / "Start-Worker.cmd").write_bytes(b'@echo off\r\npowershell.exe -NoProfile -File "%~dp0Start-Worker.ps1"\r\npause\r\n')
    controller_connection = {"schemaVersion": 1, "transport": "exchange", "spool": str(spool),
                             "host": platform.node(), "targets": list(profile["targets"]),
                             "ssh": {"host": profile.get("sshAlias", ""), "python": sys.executable,
                                     "runtime": str(script), "spool": str(spool)}}
    write_json(spool / "connection.json", controller_connection)
    return {"status": "prepared-user-start-required", "launcher": str(spool / "Start-Worker.cmd"),
            "connection": str(spool / "connection.json"),
            "workerConnection": str(worker_connection_path) if worker_connection_path else None,
            "workerUpdatePolicy": profile.get("workerUpdatePolicy", "disabled")}


def pair(url, controller_output, worker_output, *, worker_id=None,
         controller_folder=None, worker_folder=None, threshold_bytes=64 * 1024 * 1024):
    """Create private controller/worker halves without printing their bearer secret."""
    controller_output, worker_output = Path(controller_output).resolve(), Path(worker_output).resolve()
    if controller_output == worker_output or controller_output.exists() or worker_output.exists():
        raise WorkError("PAIRING_DESTINATION_EXISTS")
    if (controller_folder is None) != (worker_folder is None):
        raise WorkError("PAIRING_BULK_FOLDER_ENDPOINTS_REQUIRED")
    if type(threshold_bytes) is not int or threshold_bytes < 0:
        raise WorkError("PAIRING_BULK_THRESHOLD_INVALID")
    worker_id = worker_id or (platform.node().lower() + "-" + uuid.uuid4().hex[:12])
    pull = {"url": url, "workerId": worker_id, "token": secrets.token_urlsafe(32),
            "timeoutSeconds": 120, "persistent": True}
    common = {"schemaVersion": 1, "transport": "pull", "pull": pull}
    controller, worker = dict(common), dict(common)
    if controller_folder is not None:
        controller["bulkFolders"] = [{"id": "default", "path": str(Path(controller_folder).resolve()),
                                      "thresholdBytes": threshold_bytes}]
        worker["bulkFolders"] = [{"id": "default", "path": str(Path(worker_folder).resolve()),
                                  "thresholdBytes": threshold_bytes}]
    from .pull import _pull, _bulk_folders
    _pull(controller)
    _bulk_folders(controller)
    _bulk_folders(worker)
    try:
        write_json(controller_output, controller)
        write_json(worker_output, worker)
    except Exception:
        controller_output.unlink(missing_ok=True)
        worker_output.unlink(missing_ok=True)
        raise
    return {"status": "paired-files-created", "workerId": worker_id,
            "controllerConnection": str(controller_output), "workerConnection": str(worker_output),
            "bulkFolderConfigured": controller_folder is not None}


def export_bundle(repository, output, python_archive=None):
    root, output = Path(repository).resolve(), Path(output).resolve()
    if output.exists():
        raise WorkError("EXPORT_DESTINATION_EXISTS")
    selected = []
    for name in ("itl-remote-runner", "itl-remote-agent", "itl-performance"):
        folder = root / ".agents" / "skills" / name
        selected += [path for path in folder.rglob("*") if path.is_file() and "__pycache__" not in path.parts]
    # The same shared process/session code used by ITL, not a reimplementation.
    lib = root / ".agents/skills/1c-workflow/scripts/lib"
    selected += [lib / ("agent-1c." + name + ".ps1") for name in ("core", "ports", "sessions", "runtime-values", "immutable-download", "vanessa")]
    if any(not path.is_file() for path in selected):
        raise WorkError("PORTABLE_DEPENDENCY_MISSING")
    entries = {path.relative_to(root).as_posix(): path for path in selected}
    if python_archive is not None:
        asset_dir = ".agents/skills/itl-remote-runner/assets/python-runtime/"
        definition = read_json(root / asset_dir / "manifest.json")
        package = Path(python_archive).resolve()
        if not package.is_file() or digest(package) != definition["sha256"]:
            raise WorkError("PORTABLE_PYTHON_ARCHIVE_HASH_MISMATCH")
        name = definition["package"]
        if Path(name).name != name or "/" in name or "\\" in name:
            raise WorkError("PORTABLE_PYTHON_MANIFEST_INVALID")
        entries[asset_dir + name] = package
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"schemaVersion": 1, "version": VERSION, "createdAt": stamp(), "files": {}}
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for relative, path in sorted(entries.items()):
            archive.write(path, relative)
            manifest["files"][relative] = {"sha256": digest(path), "bytes": path.stat().st_size}
        import json
        archive.writestr("bundle-manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
    return {"path": str(output), "sha256": digest(output), "files": len(entries), "version": VERSION}


def onboard(bundle, worker_connection, profile, destination, name, *, ca_certificate=None,
            trusted_transfer=False):
    """Stage one user-started launcher in an explicitly trusted transfer folder."""
    if not trusted_transfer:
        raise WorkError("ONBOARD_TRUSTED_TRANSFER_REQUIRED")
    if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", name):
        raise WorkError("ONBOARD_NAME_INVALID")
    bundle = Path(bundle).resolve(strict=True)
    worker_connection = Path(worker_connection).resolve(strict=True)
    profile = Path(profile).resolve(strict=True)
    destination = Path(destination).resolve()
    if destination.exists():
        raise WorkError("ONBOARD_DESTINATION_EXISTS")
    connection_value = read_json(worker_connection)
    from .pull import _pull
    pull = _pull(connection_value)
    if connection_value.get("transport") != "pull":
        raise WorkError("WORKER_CONNECTION_PULL_REQUIRED")
    profile_value = read_json(profile)
    if (profile_value.get("schemaVersion") != 1 or
            not isinstance(profile_value.get("targets", {}), dict) or
            not isinstance(profile_value.get("hostCommands"), dict) or
            profile_value["hostCommands"].get("enabled") is not True):
        raise WorkError("ONBOARD_HOST_COMMANDS_NOT_ENABLED")
    if ca_certificate is not None:
        ca_certificate = Path(ca_certificate).resolve(strict=True)
        if not pull["url"].startswith("https://"):
            raise WorkError("ONBOARD_CA_REQUIRES_HTTPS")
    starter = ".agents/skills/itl-remote-runner/scripts/Start-Worker-Onboard.ps1"
    with zipfile.ZipFile(bundle) as archive:
        manifest = json.loads(archive.read("bundle-manifest.json"))
        if starter not in manifest.get("files", {}):
            raise WorkError("ONBOARD_LAUNCHER_MISSING_FROM_BUNDLE")
        script_bytes = archive.read(starter)
        if hashlib.sha256(script_bytes).hexdigest() != manifest["files"][starter]["sha256"]:
            raise WorkError("ONBOARD_LAUNCHER_HASH_MISMATCH")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".itl-onboard-", dir=destination.parent))
    try:
        shutil.copyfile(bundle, stage / "bundle.zip")
        shutil.copyfile(worker_connection, stage / "worker-connection.json")
        shutil.copyfile(profile, stage / "profile.json")
        if ca_certificate is not None:
            shutil.copyfile(ca_certificate, stage / "controller-ca.pem")
        (stage / "Start-Worker.ps1").write_bytes(script_bytes)
        (stage / "Start-Worker.cmd").write_bytes(
            b'@echo off\r\npushd "%~dp0" || exit /b 1\r\n'
            b'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Worker.ps1"\r\n'
            b'set "itlExit=%errorlevel%"\r\npopd\r\nexit /b %itlExit%\r\n')
        write_json(stage / "onboard.json", {"schemaVersion": 1, "name": name,
                   "bundleSha256": digest(stage / "bundle.zip"),
                   "connectionSha256": digest(stage / "worker-connection.json"),
                   "profileSha256": digest(stage / "profile.json"),
                   "caSha256": digest(stage / "controller-ca.pem") if ca_certificate else None,
                   "createdAt": stamp()})
        publish_path(stage, destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return {"status": "user-start-required", "launcher": str(destination / "Start-Worker.cmd"),
            "statusFile": str(destination / "bootstrap-status.json"),
            "workerId": pull["workerId"], "bundleSha256": digest(bundle)}
