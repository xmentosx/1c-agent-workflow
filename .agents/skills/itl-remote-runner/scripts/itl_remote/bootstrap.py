"""Prepare a user-started worker and export the same runtime without full ITL."""
from __future__ import annotations

import os
from pathlib import Path
import platform
import shutil
import sys
import zipfile
from datetime import datetime, timezone

from . import VERSION
from .common import (WorkError, digest, process_identity, process_is_alive, read_json,
                     resolve_resource_limits, stamp, write_json)


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
              "worker": None, "targets": [], "agentConfigured": False}
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
    return result


def prepare(spool, configuration):
    spool = Path(spool).resolve()
    profile = read_json(configuration)
    if profile.get("schemaVersion") != 1 or not profile.get("targets"):
        raise WorkError("WORKER_PROFILE_TARGETS_REQUIRED")
    if (spool / "profile.json").exists():
        raise WorkError("WORKER_ALREADY_CONFIGURED: edit its private profile explicitly")
    for target in profile["targets"].values():
        if not Path(target["workspace"]).is_dir() or not target.get("allowedOperations"):
            raise WorkError("TARGET_WORKSPACE_OR_OPERATIONS_MISSING")
        resolve_resource_limits(target, target["allowedOperations"])
    spool.mkdir(parents=True, exist_ok=True)
    profile["profilePath"] = str(spool / "profile.json")
    write_json(spool / "profile.json", profile)
    script = Path(__file__).resolve().parent.parent / "remote_work.py"
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    launcher = ("$ErrorActionPreference='Stop'\n$env:PYTHONUTF8='1'\n$env:PYTHONIOENCODING='utf-8'\n"
                "$env:PYTHONDONTWRITEBYTECODE='1'\n$env:PYTHONNOUSERSITE='1'\n$env:PYTHONHOME=$null\n"
                "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"
                "& " + quote(sys.executable) + " -B -X utf8 -u " + quote(script) + " worker --once --spool " + quote(spool) + "\nexit $LASTEXITCODE\n")
    (spool / "Start-Worker.ps1").write_text(launcher, encoding="utf-8-sig")
    (spool / "Start-Worker.cmd").write_bytes(b'@echo off\r\npowershell.exe -NoProfile -File "%~dp0Start-Worker.ps1"\r\npause\r\n')
    connection = {"schemaVersion": 1, "transport": "exchange", "spool": str(spool),
                  "host": platform.node(), "targets": list(profile["targets"]),
                  "ssh": {"host": profile.get("sshAlias", ""), "python": sys.executable,
                          "runtime": str(script), "spool": str(spool)}}
    write_json(spool / "connection.json", connection)
    return {"status": "prepared-user-start-required", "launcher": str(spool / "Start-Worker.cmd"),
            "connection": str(spool / "connection.json")}


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
