"""Shared native-recovery resource-state policy."""
from pathlib import Path
import re

from .common import WorkError
from .workflow_scope import git_main_worktree

MASTER_RETRY_OPERATIONS = frozenset({"refresh-dev-branch", "sync-master"})


def _resource_key(coordinator, base):
    return coordinator.resources([{"kind": base["kind"], "path": base["path"]}])[0]


def _legacy_service_roles(coordinator, plan):
    roles = {}
    target = _resource_key(coordinator, plan["target"])
    project = Path(plan["project"])
    reserved = set(coordinator.resources(plan["bases"]))
    for name in ("serviceGeneration", "serviceReserveGeneration"):
        generation = plan.get(name, "")
        if not generation:
            continue
        base = {"kind": "file", "path": str(project / ".agent-1c" / "infobases" /
                                             ("vanessa-service-" + generation))}
        key = _resource_key(coordinator, base)
        if key == target or key not in reserved:
            raise WorkError("NATIVE_RECOVERY_CONTINUATION_RESOURCE_BINDING_CHANGED")
        roles[key] = "vanessa-service"
    return roles


def _legacy_branch_seed_roles(coordinator, plan):
    if plan.get("operation") not in MASTER_RETRY_OPERATIONS:
        return {}
    main = git_main_worktree(plan.get("project", ""))
    if main is None:
        return {}
    roles = {}
    for base in plan["bases"]:
        if base["kind"] != "file":
            continue
        path = Path(base["path"])
        try:
            relative = path.resolve().relative_to(main.resolve())
        except (OSError, ValueError):
            continue
        parts = relative.parts
        if (len(parts) == 4 and parts[0].casefold() == ".agent-1c" and
                parts[1].casefold() == "branch-seed" and
                re.fullmatch(r"[a-f0-9]{64}", parts[2], re.I) and
                parts[3].casefold() == "infobase"):
            roles[_resource_key(coordinator, base)] = "branch-seed"
    return roles


def rebuildable_resources(coordinator, plan):
    roles = _legacy_service_roles(coordinator, plan)
    if plan.get("schemaVersion") == 2:
        for value in plan.get("resourceRoles", []):
            key = _resource_key(coordinator, value)
            roles[key] = value["role"]
    else:
        roles.update(_legacy_branch_seed_roles(coordinator, plan))
    return roles


def resource_problem(base, *, rebuildable=False):
    sessions = base.get("sessionCount", 0)
    owned = base.get("ownedProcessIds") or []
    other = base.get("otherProcessIds") or []
    detail = f"kind={base.get('kind')} path='{base.get('path')}'"
    if sessions or owned or other:
        return ("NATIVE_RECOVERY_DATABASE_STILL_IN_USE: " + detail +
                f" sessions={sessions} owned={owned} other={other}")
    if base.get("databasePresent"):
        if base.get("exclusive"):
            return None
        return "NATIVE_RECOVERY_DATABASE_STILL_IN_USE: " + detail + " exclusive=false"
    if rebuildable and base.get("kind") == "file":
        return None
    return "NATIVE_RECOVERY_REQUIRED_DATABASE_MISSING: " + detail


def require_quiescent(base, *, rebuildable=False):
    problem = resource_problem(base, rebuildable=rebuildable)
    if problem:
        raise WorkError(problem)
