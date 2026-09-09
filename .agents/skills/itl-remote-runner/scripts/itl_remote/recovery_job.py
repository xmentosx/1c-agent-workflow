"""Recover one admitted job using its original pinned scenario and target."""
from __future__ import annotations

from pathlib import Path
import platform
import re
import time
import uuid

from .access import Coordinator, target_access
from .access_recovery import Recovery, plan as access_plan
from .common import FileLock, WorkError, identity, read_json, stamp, write_json
from .jobs import authorize, job_id, status, validate_package
from .recovery_adapter import verify_job


def _plan_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise WorkError("RECOVERY_PLAN_ID_INVALID")
    return value


def _inputs(spool, identifier):
    request, scenario = validate_package(spool / "jobs" / identifier)
    target = authorize(request, scenario, read_json(spool / "profile.json"))
    access = target_access(target)
    coordinator = Coordinator(access["coordinator"])
    with coordinator.mutex(time.monotonic() + 30, lambda: False):
        records = [r for r in coordinator.records() if r.get("owner", {}).get("jobId") == identifier and
                   r["owner"].get("spool") and Path(r["owner"]["spool"]).resolve() == spool and
                   r["owner"].get("operation") == "measure"]
        if len(records) != 1:
            raise WorkError("RECOVERY_ORIGINAL_OWNER_UNPROVEN")
        record = records[0]
        if record["resources"] != coordinator.resources(access["bases"]):
            raise WorkError("RECOVERY_RESOURCE_BINDING_CHANGED")
    if record["owner"].get("host", "").casefold() != platform.node().casefold():
        raise WorkError("RECOVERY_EXECUTION_HOST_REQUIRED: " + record["owner"].get("host", "unknown"))
    if record["owner"].get("recoveryBinding") != {"requestSha256": identity(request), "targetSha256": identity(target)}:
        raise WorkError("RECOVERY_ORIGINAL_INPUTS_CHANGED")
    if "recovery" not in scenario:
        raise WorkError("RECOVERY_ADAPTER_REQUIRED")
    return request, scenario, target, coordinator, record


def create_plan(spool, identifier):
    spool, identifier = Path(spool).resolve(), job_id(identifier)
    with FileLock(spool / "claims" / (identifier + ".lock")):
        request, scenario, target, coordinator, record = _inputs(spool, identifier)
        inspected = access_plan(coordinator.root, record["ticket"])
        result = {"schemaVersion": 1, "jobId": identifier, "spool": str(spool),
                  "createdAt": stamp(), "nonce": uuid.uuid4().hex,
                  "coordinator": str(coordinator.root), "ticket": record["ticket"],
                  "revision": inspected["revision"], "resources": record["resources"],
                  "requestSha256": identity(request), "targetSha256": identity(target),
                  "steps": [s for s in ("inspect", "quiesce", "restore") if s in scenario["recovery"]],
                  "automaticReplay": False}
        result["planId"] = identity(result)
        path = spool / "recovery-plans" / identifier / (result["planId"] + ".json")
        if not path.exists():
            write_json(path, result)
        elif read_json(path) != result:
            raise WorkError("RECOVERY_PLAN_CONTENT_CHANGED")
        return result


def _read_plan(spool, identifier, plan_id):
    value = read_json(spool / "recovery-plans" / identifier / (_plan_id(plan_id) + ".json"))
    if (value.get("planId") != plan_id or value.get("jobId") != identifier or
            not value.get("spool") or Path(value["spool"]).resolve() != spool or
            identity({k: v for k, v in value.items() if k != "planId"}) != plan_id):
        raise WorkError("RECOVERY_PLAN_CONTENT_CHANGED")
    return value


def _control(spool, identifier, plan_id, suffix):
    return spool / "control" / (identifier + ".recovery-" + _plan_id(plan_id) + suffix)


def cancel(spool, identifier, plan_id):
    spool, identifier = Path(spool).resolve(), job_id(identifier)
    _read_plan(spool, identifier, plan_id)
    write_json(_control(spool, identifier, plan_id, ".cancel.json"), {"jobId": identifier, "at": stamp()})
    return {"jobId": identifier, "planId": plan_id, "status": "cancellation-requested"}


def enqueue(spool, identifier, plan_id):
    spool, identifier = Path(spool).resolve(), job_id(identifier)
    _read_plan(spool, identifier, plan_id)
    path = _control(spool, identifier, plan_id, ".request.json")
    if not path.exists():
        write_json(path, {"jobId": identifier, "planId": plan_id})
    return {"jobId": identifier, "planId": plan_id, "status": "recovery-queued"}


def run(spool, identifier, plan_id):
    spool, identifier = Path(spool).resolve(), job_id(identifier)
    expected = _read_plan(spool, identifier, plan_id)
    cancelled = lambda: _control(spool, identifier, plan_id, ".cancel.json").exists()
    with FileLock(spool / "claims" / (identifier + ".lock")):
        request, scenario, target, coordinator, original = _inputs(spool, identifier)
        if (expected["coordinator"] != str(coordinator.root) or expected["ticket"] != original["ticket"] or
                expected["resources"] != original["resources"] or expected["requestSha256"] != identity(request) or
                expected["targetSha256"] != identity(target)):
            raise WorkError("RECOVERY_PLAN_TARGET_CHANGED")
        state_path = spool / "state" / (identifier + ".json")
        state = status(spool, identifier)

        def save_state(value):
            # Reconciliation never turns a failed/interrupted measurement into
            # success, nor allows the worker to restart a queued-looking orphan.
            if state["status"] in ("queued", "running", "waiting-for-base", "agent-running"):
                state.update(status="needs-attention", error="INTERRUPTED_OWNER: measurement was not replayed")
            state.update(recovery=value, updatedAt=stamp())
            write_json(state_path, state)

        # Completion may have been durable before the recovering process died
        # while publishing job state. Reconcile it without running hooks again.
        completed = [a for a in original.get("recoveryAttempts", []) if
                     a.get("previousRevision") == expected["revision"] and a.get("status") == "completed"]
        if original["status"] == "released" and len(completed) == 1:
            value = {"status": "completed", "planId": plan_id, "attemptId": completed[0]["id"],
                     "baseReleased": True, "measurementReplayed": False}
            save_state(value)
            return value
        try:
            with Recovery(coordinator.root, original["ticket"], expected["revision"],
                          {"jobId": identifier, "operation": "recover-measurement", "spool": str(spool)},
                          cancelled=cancelled) as owner:
                output = spool / "runs" / identifier / "recovery" / owner.attempt
                save_state({"status": "running", "planId": plan_id, "attemptId": owner.attempt,
                            "output": str(output), "baseReleased": False})
                def verify(record):
                    def validate():
                        current = _inputs(spool, identifier)
                        if identity(current[0]) != expected["requestSha256"] or identity(current[2]) != expected["targetSha256"]:
                            raise WorkError("RECOVERY_ORIGINAL_INPUTS_CHANGED")
                    validate()
                    proof = verify_job(owner, spool / "jobs" / identifier, target,
                                       spool / "runs" / identifier, request, scenario, output, cancelled,
                                       validate_inputs=validate)
                    validate()
                    return proof
                owner.complete(verify)
                value = {"status": "completed", "planId": plan_id, "attemptId": owner.attempt,
                         "output": str(output), "baseReleased": True, "measurementReplayed": False}
                save_state(value)
                return value
        except Exception as error:
            save_state({"status": "cancelled" if cancelled() else "needs-attention", "planId": plan_id,
                        "baseReleased": None, "error": str(error)})
            raise


def run_queued(spool):
    spool = Path(spool).resolve()
    for path in sorted((spool / "control").glob("*.recovery-*.request.json")):
        result_path = path.with_name(path.name.replace(".request.json", ".result.json"))
        if result_path.exists():
            continue
        request = read_json(path)
        try:
            result = run(spool, request["jobId"], request["planId"])
        except Exception as error:
            if str(error).startswith("OWNER_BUSY:"):
                continue
            result = {"status": "needs-attention", "error": str(error)}
        write_json(result_path, result)
