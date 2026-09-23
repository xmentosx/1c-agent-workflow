"""Durable user-session commands carried by the existing worker queue."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import tempfile
import uuid

from .common import (FileLock, OwnedProcess, WorkError, beneath, digest,
                     process_identity, publish_path, read_json, resolve_resource_limits,
                     stamp, write_json)
from .jobs import job_id, status


def validate_spec(spec):
    if not isinstance(spec, dict) or spec.get("schemaVersion") != 1:
        raise WorkError("HOST_COMMAND_SPEC_INVALID")
    argv = spec.get("argv")
    if (not isinstance(argv, list) or not argv or
            any(not isinstance(arg, str) or not arg or "\0" in arg for arg in argv)):
        raise WorkError("HOST_COMMAND_ARGV_INVALID")
    cwd = spec.get("cwd")
    if cwd is not None and (not isinstance(cwd, str) or not cwd or "\0" in cwd):
        raise WorkError("HOST_COMMAND_CWD_INVALID")
    if cwd is not None and not (Path(cwd).is_absolute() or cwd.startswith("{input}") or cwd.startswith("{run}")):
        raise WorkError("HOST_COMMAND_CWD_MUST_BE_ABSOLUTE")
    timeout = spec.get("timeoutSeconds", 300)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 1 <= timeout <= 3600:
        raise WorkError("HOST_COMMAND_TIMEOUT_INVALID")
    files = spec.get("files", [])
    if not isinstance(files, list) or any(not isinstance(path, str) for path in files) or len(set(files)) != len(files):
        raise WorkError("HOST_COMMAND_FILES_INVALID")
    for path in files:
        beneath(Path("input").resolve(), path)
    if set(spec) - {"schemaVersion", "argv", "cwd", "timeoutSeconds", "files"}:
        raise WorkError("HOST_COMMAND_FIELD_UNKNOWN")
    return spec


def pack(spec_path, destination, *, identifier=None):
    spec_path, destination = Path(spec_path).resolve(strict=True), Path(destination).resolve()
    spec = validate_spec(read_json(spec_path))
    if destination.exists():
        raise WorkError("PACKAGE_ALREADY_EXISTS")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".itl-host-command-", dir=destination.parent))
    try:
        files = {}
        for relative in spec.get("files", []):
            source = beneath(spec_path.parent, relative)
            if not source.is_file():
                raise WorkError("HOST_COMMAND_INPUT_MISSING: " + relative)
            target = beneath(stage / "input", relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            files[relative.replace("\\", "/")] = {"sha256": digest(target), "bytes": target.stat().st_size}
        write_json(stage / "scenario.json", spec)
        request = {"schemaVersion": 1, "kind": "host-command", "id": job_id(identifier or uuid.uuid4().hex),
                   "createdAt": stamp(), "runner": "worker", "agentPolicy": "off",
                   "scenarioSha256": digest(stage / "scenario.json"), "files": files}
        write_json(stage / "request.json", request)
        validate_package(stage, request)
        publish_path(stage, destination)
        return request
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def validate_package(package, request):
    package = Path(package)
    if (request.get("schemaVersion") != 1 or request.get("kind") != "host-command" or
            request.get("runner") != "worker" or request.get("agentPolicy") != "off"):
        raise WorkError("HOST_COMMAND_REQUEST_INVALID")
    if set(request) - {"schemaVersion", "kind", "id", "createdAt", "runner", "agentPolicy",
                        "scenarioSha256", "files"}:
        raise WorkError("HOST_COMMAND_REQUEST_INVALID")
    if digest(package / "scenario.json") != request.get("scenarioSha256"):
        raise WorkError("SCENARIO_HASH_MISMATCH")
    spec = validate_spec(read_json(package / "scenario.json"))
    inventory = request.get("files")
    if not isinstance(inventory, dict) or set(inventory) != {path.replace("\\", "/") for path in spec.get("files", [])}:
        raise WorkError("INPUT_INVENTORY_MISMATCH")
    for relative, entry in inventory.items():
        path = beneath(package / "input", relative)
        if (not isinstance(entry, dict) or not path.is_file() or path.stat().st_size != entry.get("bytes") or
                digest(path) != entry.get("sha256")):
            raise WorkError("INPUT_HASH_MISMATCH: " + relative)
    return request, spec


def execute(spool, identifier, profile):
    spool, identifier = Path(spool).resolve(), job_id(identifier)
    request, spec = validate_package(spool / "jobs" / identifier,
                                     read_json(spool / "jobs" / identifier / "request.json"))
    if not isinstance(profile.get("hostCommands"), dict) or profile["hostCommands"].get("enabled") is not True:
        raise WorkError("HOST_COMMANDS_NOT_AUTHORIZED")
    with FileLock(spool / "claims" / (identifier + ".lock")):
        state = status(spool, identifier)
        if state["status"] != "queued":
            if state["status"] == "running":
                try:
                    observed = process_identity(state.get("ownerPid"))
                except (WorkError, TypeError, ValueError):
                    observed = None
                if observed != state.get("ownerIdentity"):
                    state.update(status="interrupted", error="HOST_COMMAND_OUTCOME_UNKNOWN_NO_REPLAY",
                                 updatedAt=stamp())
                    write_json(spool / "state" / (identifier + ".json"), state)
            return state
        state = {"id": identifier, "status": "running", "ownerPid": os.getpid(),
                 "ownerIdentity": process_identity(os.getpid()), "updatedAt": stamp()}
        write_json(spool / "state" / (identifier + ".json"), state)
        run = spool / "runs" / identifier
        run.mkdir(parents=True, exist_ok=False)
        write_json(run / "provenance.json", {"kind": "host-command", "id": identifier,
                    "requestSha256": digest(spool / "jobs" / identifier / "request.json"),
                    "scenarioSha256": request["scenarioSha256"], "files": request["files"],
                    "startedAt": stamp()})
        replace = lambda value: value.replace("{input}", str(spool / "jobs" / identifier / "input")).replace("{run}", str(run))
        argv = [replace(value) for value in spec["argv"]]
        cwd = replace(spec.get("cwd") or str(run))
        if (spool / "control" / (identifier + ".cancel.json")).exists():
            result = {"id": identifier, "status": "cancelled", "error": "CANCELLED_BEFORE_LAUNCH",
                      "exitCode": None, "finishedAt": stamp()}
        elif not Path(cwd).is_dir():
            error = "HOST_COMMAND_CWD_MISSING"
            result = {"id": identifier, "status": "failed", "error": error, "exitCode": None, "finishedAt": stamp()}
        else:
            process = None
            try:
                with OwnedProcess(argv, cwd, run / "stdout.log",
                                  resource_limits=resolve_resource_limits(profile["hostCommands"]),
                                  telemetry=run / "resource-telemetry.jsonl",
                                  stderr_output=run / "stderr.log") as process:
                    process.wait(spec.get("timeoutSeconds", 300),
                                 cancelled=lambda: (spool / "control" / (identifier + ".cancel.json")).exists())
                result = {"id": identifier, "status": "completed", "exitCode": 0, "finishedAt": stamp()}
            except (WorkError, OSError) as exc:
                error = str(exc)
                result = {"id": identifier, "status": "cancelled" if error == "CANCELLED" else "failed",
                          "error": error, "exitCode": process.process.returncode if process is not None else None,
                          "finishedAt": stamp()}
        write_json(run / "result.json", result)
        write_json(spool / "state" / (identifier + ".json"), dict(result, updatedAt=stamp()))
        return result
