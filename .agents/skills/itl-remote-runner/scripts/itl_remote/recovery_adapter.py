"""Pinned scenario recovery hooks, separate from the original workload.

Scenario authors are trusted, as for action/verification scripts. The runtime
validates fresh correlation, exact resources and retained evidence; the hooks
own the meaning of database-side observations and idempotent restoration.
"""
from __future__ import annotations

import json
from pathlib import Path
import uuid

from .access_recovery import VerifiedRecovery
from .common import OwnedProcess, WorkError, beneath, digest, read_json, stamp, write_json
from .deadlines import Deadline, budgets


def validate_contract(contract):
    if (not isinstance(contract, dict) or contract.get("schemaVersion") != 1 or
            set(contract) - {"schemaVersion", "inspect", "quiesce", "restore", "operations", "repeatableActions"} or
            "inspect" not in contract):
        raise WorkError("RECOVERY_CONTRACT_INVALID")
    for name in ("inspect", "quiesce", "restore"):
        if name in contract:
            command = contract[name]
            if (not isinstance(command, list) or not command or
                    any(not isinstance(a, str) or "\0" in a for a in command)):
                raise WorkError("RECOVERY_COMMAND_REQUIRES_ARGUMENT_ARRAY: " + name)
    operations = contract.get("operations")
    if (not isinstance(operations, list) or any(op not in ("write-data", "update") for op in operations) or
            len(operations) != len(set(operations))):
        raise WorkError("RECOVERY_OPERATIONS_INVALID")
    if any(name in contract for name in ("quiesce", "restore")) and contract.get("repeatableActions") is not True:
        raise WorkError("RECOVERY_IDEMPOTENT_ACTIONS_REQUIRED")


def inspect_observation(path, context, root):
    value = read_json(path)
    recovery = context["recovery"]
    if (value.get("schemaVersion") != 1 or value.get("jobId") != context["jobId"] or
            value.get("attemptId") != recovery["attemptId"] or
            value.get("observationId") != recovery["observationId"]):
        raise WorkError("RECOVERY_OBSERVATION_STALE")
    resources = value.get("resources")
    if not isinstance(resources, list) or any(not isinstance(r, dict) for r in resources):
        raise WorkError("RECOVERY_OBSERVATION_RESOURCES_INVALID")
    actual = [r.get("resourceId") for r in resources]
    if any(not isinstance(r, str) for r in actual) or sorted(actual) != sorted(recovery["resources"]):
        raise WorkError("RECOVERY_OBSERVATION_SCOPE_MISMATCH")
    for resource in resources:
        if (resource.get("ownedWork") not in ("stopped", "running", "unknown") or
                resource.get("restoration") not in ("complete", "required", "unknown") or
                not isinstance(resource.get("explanation"), str) or not resource["explanation"].strip()):
            raise WorkError("RECOVERY_OBSERVATION_INCOMPLETE")
        artifacts = resource.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise WorkError("RECOVERY_OBSERVATION_EVIDENCE_REQUIRED")
        for artifact in artifacts:
            if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str):
                raise WorkError("RECOVERY_OBSERVATION_EVIDENCE_INVALID")
            evidence = beneath(root, artifact["path"])
            if not evidence.is_file() or digest(evidence) != artifact.get("sha256"):
                raise WorkError("RECOVERY_OBSERVATION_EVIDENCE_CHANGED")
    return value


def verify_job(recovery, package, target, run, request, scenario, output, cancelled, *, validate_inputs=lambda: None):
    from .execution import render
    from .jobs import validate_package
    import sys
    contract = scenario.get("recovery")
    if contract is None:
        raise WorkError("RECOVERY_ADAPTER_REQUIRED")
    validate_contract(contract)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    context = {"schemaVersion": 1, "jobId": request["id"], "scenarioId": scenario["id"],
               "parameters": request["parameters"], "target": target,
               "operations": request["operations"], "accessLease": recovery.proof(),
               "phaseTimeoutSeconds": budgets(scenario), "cancelPath": None,
               "recovery": {"attemptId": recovery.attempt, "originalRun": str(run),
                            "resources": recovery.record["resources"]}}
    # One bounded recovery budget, never reset by successive inspections.
    deadline = Deadline("cleanup", budgets(scenario)["cleanup"])
    context["phase"] = deadline.record()
    records = []
    context_path = output / "context.json"

    def command(name):
        recovery.proof()  # Recheck fencing before each hook, especially mutations.
        validate_inputs()
        validate_package(package)
        if cancelled():
            raise WorkError("INFOBASE_ACCESS_CANCELLED")
        deadline.remaining()
        step = output / ("%02d-%s" % (len(records), name))
        step.mkdir()
        context["recovery"].update(stage=name, observationId=uuid.uuid4().hex,
                                   output=str(step / "observation.json"))
        write_json(context_path, context)
        variables = {"python": sys.executable, "runtime": Path(__file__).resolve().parent.parent,
                     "workspace": target["workspace"], "input": Path(package) / "input", "run": run,
                     "recovery": step, "context": context_path}
        record = {"name": name, "startedAt": stamp(), "status": "running"}
        records.append(record)
        write_json(output / "progress.json", records)
        try:
            with OwnedProcess(render(contract[name], variables), target["workspace"], step / "command.log",
                              {"ITL_RUN_CONTEXT": str(context_path),
                               "ITL_INFOBASE_ACCESS_LEASE": json.dumps(context["accessLease"])}) as process:
                process.wait(deadline.remaining(), cancelled)
            validate_package(package)
            validate_inputs()
            value = inspect_observation(step / "observation.json", context, step) if name == "inspect" else None
            record.update(status="completed", finishedAt=stamp())
            if value is not None:
                record.update(observation=str(step / "observation.json"),
                              sha256=digest(step / "observation.json"))
            return value
        except BaseException as error:
            record.update(status="failed", error=str(error), finishedAt=stamp())
            raise
        finally:
            write_json(output / "progress.json", records)

    observed = command("inspect")
    if any(r["ownedWork"] != "stopped" for r in observed["resources"]):
        if "quiesce" not in contract:
            raise WorkError("RECOVERY_OWNED_WORK_UNPROVEN")
        command("quiesce")
        observed = command("inspect")
    if any(r["ownedWork"] != "stopped" for r in observed["resources"]):
        raise WorkError("RECOVERY_OWNED_WORK_UNPROVEN")
    if any(r["restoration"] != "complete" for r in observed["resources"]):
        if "restore" not in contract:
            raise WorkError("RECOVERY_RESTORATION_UNPROVEN")
        command("restore")
        observed = command("inspect")
    if any(r["ownedWork"] != "stopped" or r["restoration"] != "complete" for r in observed["resources"]):
        raise WorkError("RECOVERY_FINAL_STATE_UNPROVEN")
    if cancelled():
        raise WorkError("INFOBASE_ACCESS_CANCELLED")
    deadline.remaining()
    return VerifiedRecovery(tuple(recovery.record["resources"]),
                            {"adapter": "pinned-scenario", "scenarioSha256": request["scenarioSha256"],
                             "observations": records, "finalObservation": observed})
