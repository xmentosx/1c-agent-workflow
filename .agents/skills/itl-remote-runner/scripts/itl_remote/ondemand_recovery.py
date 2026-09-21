"""Trusted recovery dispatcher for orphaned on-demand MCP database owners."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import re

from .access import Coordinator, on_demand_release_action
from .access_recovery import Recovery, VerifiedRecovery, plan
from .common import OwnedProcess, WorkError

MARKER = "ITL_ONDEMAND_RESULT="
ERROR_CODE = re.compile(r"\b(?:COMMAND|INFOBASE|ITL|NATIVE|RECOVERY|RESOURCE)_[A-Z0-9_]+\b")
HELPER_TIMEOUT_SECONDS = 180
LOG_TAIL_BYTES = 64 * 1024


def _powershell() -> str:
    return str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")


def _helper() -> Path:
    # Recovery is part of the initiating package generation. The target project
    # may contain the stale helper whose update was interrupted.
    path = Path(__file__).resolve().parents[3] / "1c-workflow" / "scripts" / "agent-1c.ps1"
    if not path.is_file():
        raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_MISSING")
    return path


def _log_tail(path: Path) -> str:
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - LOG_TAIL_BYTES))
            return stream.read().decode("utf-8-sig", errors="replace")
    except OSError:
        return ""


def _error_code(text: str) -> str:
    values = [value for value in ERROR_CODE.findall(text) if value != "ITL_ONDEMAND_RESULT"]
    return values[-1] if values else ""


def _helper_failed(operation: str, log: Path, process_error: str, exit_code, text: str):
    payload = {
        "schemaVersion": 1,
        "operation": operation,
        "helperExitCode": exit_code if isinstance(exit_code, int) else None,
        "primaryError": _error_code(text) or _error_code(process_error),
        "processError": _error_code(process_error),
        "logPath": str(log),
    }
    raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_FAILED: " +
                    json.dumps(payload, ensure_ascii=True, separators=(",", ":")))


def _invoke(project: str, family: str, instance: str, operation: str, *, output, env=None,
            timeout=HELPER_TIMEOUT_SECONDS, cancelled=lambda: False):
    helper = _helper()
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    log = output / (operation + ".log")
    command = [
        _powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(helper),
        "-ProjectRoot", project, "-InternalOnDemandOperation", operation,
        "-InternalOnDemandFamily", family, "-InternalOnDemandInstanceId", instance,
    ]
    process = None
    try:
        with OwnedProcess(command, project, log, env=env) as process:
            process.wait(timeout, cancelled)
    except WorkError as error:
        if str(error) == "CANCELLED":
            raise WorkError("INFOBASE_ACCESS_CANCELLED") from error
        if not str(error).startswith("COMMAND_"):
            raise
        exit_code = getattr(getattr(process, "process", None), "returncode", None)
        _helper_failed(operation, log, str(error), exit_code, _log_tail(log))
    except OSError:
        exit_code = getattr(getattr(process, "process", None), "returncode", None)
        _helper_failed(operation, log, "ITL_ONDEMAND_RECOVERY_PROCESS_START_FAILED",
                       exit_code, _log_tail(log))
    text = _log_tail(log)
    index = text.rfind(MARKER)
    if index < 0:
        exit_code = getattr(getattr(process, "process", None), "returncode", None)
        _helper_failed(operation, log, "ITL_ONDEMAND_RECOVERY_RESULT_MARKER_MISSING", exit_code, text)
    line = text[index + len(MARKER):].splitlines()[0].strip()
    try:
        return json.loads(line)
    except json.JSONDecodeError as error:
        payload = {"schemaVersion": 1, "operation": operation, "logPath": str(log)}
        raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_RESULT_INVALID: " +
                        json.dumps(payload, ensure_ascii=True, separators=(",", ":"))) from error


def recover_on_demand(root, ticket, *, cancelled=lambda: False):
    prepared = plan(root, ticket)
    original = prepared["operation"].get("owner", {})
    action = on_demand_release_action(original)
    if action is None or original.get("operation") != "ondemand-" + action["family"] or original.get("requestId") != action["instanceId"]:
        raise WorkError("ITL_ONDEMAND_RECOVERY_OWNER_CONTRACT_REQUIRED")
    project = original.get("project")
    if not isinstance(project, str) or not Path(project).is_absolute():
        raise WorkError("ITL_ONDEMAND_RECOVERY_PROJECT_REQUIRED")
    if str(original.get("host", "")).casefold() != platform.node().casefold():
        raise WorkError("ITL_ONDEMAND_RECOVERY_ORIGINAL_HOST_REQUIRED")
    with Recovery(root, ticket, prepared["revision"], {"operation": "on-demand-recovery", "family": action["family"]}, cancelled=cancelled) as recovery:
        output = recovery.coordinator.root / "recovery-observations" / recovery.ticket / recovery.attempt
        def verify(operation):
            if cancelled():
                raise WorkError("INFOBASE_ACCESS_CANCELLED")
            current = recovery._current()
            current_action = on_demand_release_action(current.get("owner", {}))
            if current_action != action:
                raise WorkError("ITL_ONDEMAND_RECOVERY_OWNER_CHANGED")
            planned = _invoke(project, action["family"], action["instanceId"], "access-plan",
                              output=output, cancelled=cancelled)
            database = planned.get("databaseAccess") if isinstance(planned, dict) else None
            if not isinstance(database, dict) or database.get("coordinator") is None or not isinstance(database.get("bases"), list):
                raise WorkError("ITL_ONDEMAND_RECOVERY_PLAN_INVALID")
            coordinator = Coordinator(root)
            if Path(database["coordinator"]).resolve() != coordinator.root or coordinator.resources(database["bases"]) != sorted(current["resources"]):
                raise WorkError("ITL_ONDEMAND_RECOVERY_RESOURCE_PLAN_CHANGED")
            proof = recovery.proof()
            invocation = {"schemaVersion": 1, "proof": proof, "plan": database}
            child_env = os.environ.copy()
            child_env["ITL_DATABASE_ACCESS_CONTEXT"] = json.dumps(invocation, ensure_ascii=False, separators=(",", ":"))
            child_env["ITL_INFOBASE_ACCESS_LEASE"] = json.dumps(proof, ensure_ascii=False, separators=(",", ":"))
            stopped = _invoke(project, action["family"], action["instanceId"], "recover-stop",
                              output=output, env=child_env, cancelled=cancelled)
            evidence = stopped.get("recoveryEvidence") if isinstance(stopped, dict) else None
            if not isinstance(evidence, dict) or evidence.get("instanceId") != action["instanceId"] or evidence.get("family") != action["family"]:
                raise WorkError("ITL_ONDEMAND_RECOVERY_EVIDENCE_INVALID")
            return VerifiedRecovery(tuple(current["resources"]), {
                "adapter": "finish-owned-on-demand/" + action["family"],
                "originalOwner": original, "releaseAction": action,
                "liveVerification": evidence, "originalOutcome": "orphaned",
            })
        return recovery.complete(verify)
