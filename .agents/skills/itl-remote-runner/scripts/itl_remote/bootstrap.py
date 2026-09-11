"""Prepare a user-started worker and export the same runtime without full ITL."""
from __future__ import annotations

import os
from pathlib import Path
import platform
import shutil
import sys
import zipfile

from . import VERSION
from .common import WorkError, digest, process_is_alive, read_json, resolve_resource_limits, stamp, write_json


def inspect(spool):
    spool = Path(spool).resolve()
    result = {"schemaVersion": 1, "version": VERSION, "python": platform.python_version(),
              "host": platform.node(), "spool": str(spool), "ssh": shutil.which("ssh"),
              "powershell": shutil.which("pwsh") or shutil.which("powershell"),
              "worker": None, "targets": [], "agentConfigured": False}
    if (spool / "worker.json").exists():
        result["worker"] = read_json(spool / "worker.json")
        # A saved heartbeat is observation, never proof of an active session.
        result["worker"]["liveness"] = ("process-alive-heartbeat-unverified" if
                                         process_is_alive(result["worker"].get("pid")) else "stale")
        if result["worker"]["liveness"] == "stale" and result["worker"].get("status") != "stopped":
            result["worker"]["status"] = "stale"
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
                "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"
                "& " + quote(sys.executable) + " -u " + quote(script) + " worker --once --spool " + quote(spool) + "\n")
    (spool / "Start-Worker.ps1").write_text(launcher, encoding="utf-8-sig")
    (spool / "Start-Worker.cmd").write_bytes(b'@echo off\r\npowershell.exe -NoProfile -File "%~dp0Start-Worker.ps1"\r\npause\r\n')
    connection = {"schemaVersion": 1, "transport": "exchange", "spool": str(spool),
                  "host": platform.node(), "targets": list(profile["targets"]),
                  "ssh": {"host": profile.get("sshAlias", ""), "python": sys.executable,
                          "runtime": str(script), "spool": str(spool)}}
    write_json(spool / "connection.json", connection)
    return {"status": "prepared-user-start-required", "launcher": str(spool / "Start-Worker.cmd"),
            "connection": str(spool / "connection.json")}


def export_bundle(repository, output):
    root, output = Path(repository).resolve(), Path(output).resolve()
    if output.exists():
        raise WorkError("EXPORT_DESTINATION_EXISTS")
    selected = []
    for name in ("itl-remote-runner", "itl-remote-agent", "itl-performance"):
        folder = root / ".agents" / "skills" / name
        selected += [path for path in folder.rglob("*") if path.is_file() and "__pycache__" not in path.parts]
    # The same shared process/session code used by ITL, not a reimplementation.
    lib = root / ".agents/skills/1c-workflow/scripts/lib"
    selected += [lib / ("agent-1c." + name + ".ps1") for name in ("core", "ports", "sessions", "runtime-values")]
    if any(not path.is_file() for path in selected):
        raise WorkError("PORTABLE_DEPENDENCY_MISSING")
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"schemaVersion": 1, "version": VERSION, "createdAt": stamp(), "files": {}}
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(selected):
            relative = path.relative_to(root).as_posix()
            archive.write(path, relative)
            manifest["files"][relative] = {"sha256": digest(path), "bytes": path.stat().st_size}
        import json
        archive.writestr("bundle-manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
    return {"path": str(output), "sha256": digest(output), "files": len(selected), "version": VERSION}
