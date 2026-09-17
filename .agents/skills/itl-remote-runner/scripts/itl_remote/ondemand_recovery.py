"""Trusted recovery dispatcher for orphaned on-demand MCP database owners."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import subprocess

from .access import Coordinator, on_demand_release_action
from .access_recovery import Recovery, VerifiedRecovery, plan
from .common import WorkError

MARKER = "ITL_ONDEMAND_RESULT="


def _powershell() -> str:
    return str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")


def _helper(project: str) -> Path:
    path = Path(project) / ".agents" / "skills" / "1c-workflow" / "scripts" / "agent-1c.ps1"
    if not path.is_file():
        raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_MISSING")
    return path


def _invoke(project: str, family: str, instance: str, operation: str, *, env=None):
    helper = _helper(project)
    result = subprocess.run([
        _powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(helper),
        "-ProjectRoot", project, "-InternalOnDemandOperation", operation,
        "-InternalOnDemandFamily", family, "-InternalOnDemandInstanceId", instance,
    ], cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, encoding="utf-8", errors="replace")
    text = result.stdout + "\n" + result.stderr
    index = text.rfind(MARKER)
    if result.returncode != 0 or index < 0:
        raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_FAILED: operation=" + operation)
    line = text[index + len(MARKER):].splitlines()[0].strip()
    try:
        return json.loads(line)
    except json.JSONDecodeError as error:
        raise WorkError("ITL_ONDEMAND_RECOVERY_HELPER_RESULT_INVALID") from error


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
        def verify(operation):
            if cancelled():
                raise WorkError("INFOBASE_ACCESS_CANCELLED")
            current = recovery._current()
            current_action = on_demand_release_action(current.get("owner", {}))
            if current_action != action:
                raise WorkError("ITL_ONDEMAND_RECOVERY_OWNER_CHANGED")
            planned = _invoke(project, action["family"], action["instanceId"], "access-plan")
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
            stopped = _invoke(project, action["family"], action["instanceId"], "recover-stop", env=child_env)
            evidence = stopped.get("recoveryEvidence") if isinstance(stopped, dict) else None
            if not isinstance(evidence, dict) or evidence.get("instanceId") != action["instanceId"] or evidence.get("family") != action["family"]:
                raise WorkError("ITL_ONDEMAND_RECOVERY_EVIDENCE_INVALID")
            return VerifiedRecovery(tuple(current["resources"]), {
                "adapter": "finish-owned-on-demand/" + action["family"],
                "originalOwner": original, "releaseAction": action,
                "liveVerification": evidence, "originalOutcome": "orphaned",
            })
        return recovery.complete(verify)
