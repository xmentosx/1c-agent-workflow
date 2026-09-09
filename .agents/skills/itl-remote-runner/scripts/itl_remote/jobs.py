"""Immutable input packages, durable queue and connection-independent job ownership."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

from .common import FileLock, WorkError, beneath, digest, identity, publish_path, read_json, stamp, write_json
from .deadlines import budgets
from .source_mapping import Selection


def job_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}", value):
        raise WorkError("INVALID_JOB_ID")
    return value


def validate_scenario(scenario):
    budgets(scenario)
    if scenario.get("sourceAnalysis", "none") not in ("none", "optional", "required"):
        raise WorkError("INVALID_SOURCE_ANALYSIS_POLICY")
    Selection(scenario.get("sourceAnalysisModules"))
    if scenario.get("sourceAnalysisModules") is not None and scenario.get("sourceAnalysis", "none") == "none":
        raise WorkError("SOURCE_MODULE_SELECTION_REQUIRES_ANALYSIS")
    if scenario.get("schemaVersion") != 1 or not scenario.get("id"):
        raise WorkError("SCENARIO_VERSION_OR_ID_INVALID")
    if scenario.get("adapter", "command") not in ("command", "handshake"):
        raise WorkError("UNKNOWN_SCENARIO_ADAPTER")
    if not scenario.get("readyDescription"):
        raise WorkError("SCENARIO_READY_CRITERION_REQUIRED")
    if not isinstance(scenario.get("commands"), dict) or not scenario["commands"].get("action"):
        raise WorkError("SCENARIO_ACTION_REQUIRED")
    if "verify" not in scenario["commands"]:
        raise WorkError("SCENARIO_VERIFICATION_REQUIRED")
    for name, command in scenario["commands"].items():
        if name not in ("prepare", "update", "action", "ready", "verify", "reset", "cleanup"):
            raise WorkError("UNKNOWN_SCENARIO_PHASE: " + name)
        if not isinstance(command, list) or not command or any(not isinstance(a, str) for a in command):
            raise WorkError("COMMAND_REQUIRES_ARGUMENT_ARRAY: " + name)
    if type(scenario.get("repeatable")) is not bool or type(scenario.get("mutates")) is not bool:
        raise WorkError("SCENARIO_MUTATION_AND_REPEATABILITY_REQUIRED")
    if scenario["mutates"] and scenario["repeatable"] and not scenario["commands"].get("reset"):
        raise WorkError("MUTATING_REPEAT_REQUIRES_RESET")
    recovery = scenario.get("recovery")
    if recovery is not None:
        from .recovery_adapter import validate_contract
        validate_contract(recovery)


def parameters(scenario, supplied):
    result = {}
    types = {"string": str, "integer": int, "number": (int, float), "boolean": bool,
             "object": dict, "array": list}
    specs = scenario.get("parameters", {})
    if set(supplied) - set(specs):
        raise WorkError("UNKNOWN_SCENARIO_PARAMETER")
    for name, spec in specs.items():
        value = supplied.get(name, spec.get("default"))
        if value is None and spec.get("required", True):
            raise WorkError("MISSING_PARAMETER: " + name)
        if value is not None:
            kind = types.get(spec.get("type"))
            if kind is None or not isinstance(value, kind) or (isinstance(value, bool) and spec["type"] in ("integer", "number")):
                raise WorkError("PARAMETER_TYPE: " + name)
            if "enum" in spec and value not in spec["enum"]:
                raise WorkError("PARAMETER_ENUM: " + name)
            result[name] = value
    identity(result)  # rejects NaN/Infinity before serialization
    return result


def pack(scenario_path, destination, *, target, values=None, mode="time+profile", route="auto",
         repeats=3, warmups=1, operations=None, identifier=None, parent=None):
    scenario_path = Path(scenario_path).resolve()
    scenario = read_json(scenario_path)
    validate_scenario(scenario)
    if mode not in ("time", "profile", "time+profile") or route not in ("local", "auto", "ssh", "agent"):
        raise WorkError("INVALID_MODE_OR_ROUTE")
    if mode == "time" and scenario.get("sourceAnalysis", "none") != "none":
        raise WorkError("SOURCE_ANALYSIS_REQUIRES_PROFILE")
    if not 1 <= repeats <= 1000 or not 0 <= warmups <= 100:
        raise WorkError("INVALID_REPETITIONS")
    destination = Path(destination).resolve()
    if destination.exists():
        raise WorkError("PACKAGE_ALREADY_EXISTS")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".itl-package-", dir=destination.parent))
    try:
        files = {}
        for relative in scenario.get("files", []):
            original = beneath(scenario_path.parent, relative)
            copied = beneath(stage / "input", relative)
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, copied)
            files[str(relative).replace("\\", "/")] = {"sha256": digest(copied), "bytes": copied.stat().st_size}
        write_json(stage / "scenario.json", scenario)
        request = {"schemaVersion": 1, "id": job_id(identifier or uuid.uuid4().hex), "parentId": parent,
                   "createdAt": stamp(), "target": target, "route": route, "mode": mode,
                   "parameters": parameters(scenario, values or {}), "repeats": repeats, "warmups": warmups,
                   "operations": sorted(set(operations or ["measure"])), "files": files,
                   "scenarioSha256": digest(stage / "scenario.json")}
        if scenario["mutates"] and "write-data" not in request["operations"]:
            raise WorkError("WRITE_DATA_AUTHORIZATION_REQUIRED")
        if "update" in scenario["commands"] and "update" not in request["operations"]:
            raise WorkError("UPDATE_AUTHORIZATION_REQUIRED")
        if set(scenario.get("recovery", {}).get("operations", [])) - set(request["operations"]):
            raise WorkError("RECOVERY_OPERATION_NOT_AUTHORIZED")
        write_json(stage / "request.json", request)
        publish_path(stage, destination)
        return request
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def validate_package(package):
    package = Path(package)
    request = read_json(package / "request.json")
    job_id(request.get("id"))
    if request.get("schemaVersion") != 1:
        raise WorkError("JOB_SCHEMA_UNSUPPORTED")
    if request.get("mode") not in ("time", "profile", "time+profile") or request.get("route") not in ("local", "auto", "ssh", "agent"):
        raise WorkError("INVALID_MODE_OR_ROUTE")
    if type(request.get("repeats")) is not int or not 1 <= request["repeats"] <= 1000 or type(request.get("warmups")) is not int or not 0 <= request["warmups"] <= 100:
        raise WorkError("INVALID_REPETITIONS")
    if "measure" not in request.get("operations", []):
        raise WorkError("MEASURE_AUTHORIZATION_REQUIRED")
    if digest(package / "scenario.json") != request["scenarioSha256"]:
        raise WorkError("SCENARIO_HASH_MISMATCH")
    scenario = read_json(package / "scenario.json")
    validate_scenario(scenario)
    if request["mode"] == "time" and scenario.get("sourceAnalysis", "none") != "none":
        raise WorkError("SOURCE_ANALYSIS_REQUIRES_PROFILE")
    if parameters(scenario, request["parameters"]) != request["parameters"]:
        raise WorkError("PARAMETERS_NOT_RESOLVED")
    for relative, entry in request["files"].items():
        path = beneath(package / "input", relative)
        if not path.is_file() or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
            raise WorkError("INPUT_HASH_MISMATCH: " + relative)
    if {str(p).replace("\\", "/") for p in scenario.get("files", [])} != set(request["files"]):
        raise WorkError("INPUT_INVENTORY_MISMATCH")
    return request, scenario


def authorize(request, scenario, profile):
    target = profile.get("targets", {}).get(request["target"])
    if target is None:
        raise WorkError("TARGET_NOT_CONFIGURED")
    if set(request["operations"]) - set(target.get("allowedOperations", [])):
        raise WorkError("OPERATION_NOT_ALLOWED")
    if scenario["mutates"] and "write-data" not in request["operations"]:
        raise WorkError("WRITE_DATA_AUTHORIZATION_REQUIRED")
    if "update" in scenario["commands"] and "update" not in request["operations"]:
        raise WorkError("UPDATE_AUTHORIZATION_REQUIRED")
    if set(scenario.get("recovery", {}).get("operations", [])) - set(request["operations"]):
        raise WorkError("RECOVERY_OPERATION_NOT_AUTHORIZED")
    workspace = Path(target["workspace"]).resolve(strict=True)
    if not workspace.is_dir():
        raise WorkError("WORKSPACE_NOT_DIRECTORY")
    if scenario.get("dataIdentity") is None:
        raise WorkError("SCENARIO_DATA_IDENTITY_REQUIRED")
    return target


def submit(package, spool):
    request, _ = validate_package(package)
    spool = Path(spool).resolve()
    final = spool / "jobs" / request["id"]
    with FileLock(spool / "queue.lock"):
        if final.exists():
            existing, _ = validate_package(final)
            if identity(existing) != identity(request):
                raise WorkError("JOB_ID_CONTENT_CONFLICT")
            return status(spool, request["id"])
        final.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=".incoming-", dir=final.parent))
        try:
            shutil.copytree(package, staging, dirs_exist_ok=True)
            validate_package(staging)
            publish_path(staging, final)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        write_json(spool / "state" / (request["id"] + ".json"),
                   {"id": request["id"], "status": "queued", "updatedAt": stamp()})
    return status(spool, request["id"])


def status(spool, identifier):
    spool = Path(spool)
    state = spool / "state" / (job_id(identifier) + ".json")
    if state.exists():
        return read_json(state)
    if (spool / "jobs" / identifier).exists():
        return {"id": identifier, "status": "queued"}
    raise WorkError("JOB_NOT_FOUND")


def cancel(spool, identifier):
    state = status(spool, identifier)
    write_json(Path(spool) / "control" / (identifier + ".cancel.json"), {"requestedAt": stamp()})
    return state


def collect(spool, identifier, destination):
    source = Path(spool) / "runs" / job_id(identifier)
    if not (source / "result.json").is_file():
        raise WorkError("RESULT_NOT_READY")
    destination = Path(destination)
    if destination.exists():
        raise WorkError("RESULT_DESTINATION_EXISTS")
    from .transport import Connection
    return Connection({"transport": "exchange", "spool": str(spool)}).collect(identifier, destination)
