"""Root admission self-healing for trusted, persisted recovery contracts."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform

from .access import Lease
from .access_recovery import plan
from .common import WorkError
from .workflow_scope import same_git_workspace

RECOVERY_REQUIRED = "INFOBASE_ACCESS_RECOVERY_REQUIRED: "
WAIT_TIMEOUT = "INFOBASE_ACCESS_WAIT_TIMEOUT: "
INTERVENTION_ERRORS = (
    "INFOBASE_ACCESS_RECOVERY_OWNER_LIVE",
    "ITL_ONDEMAND_RECOVERY_ORIGINAL_HOST_REQUIRED",
    "NATIVE_RECOVERY_ORIGINAL_HOST_REQUIRED",
    "RECOVERY_EXECUTION_HOST_REQUIRED",
    "NATIVE_RECOVERY_PRODUCER_STILL_RUNNING",
    "ITL_ONDEMAND_RECOVERY_DATABASE_STILL_IN_USE",
    "ITL_ONDEMAND_RECOVERY_DATABASE_MISSING",
    "NATIVE_RECOVERY_DATABASE_STILL_IN_USE",
    "NATIVE_RECOVERY_REQUIRED_DATABASE_MISSING",
    "ITL_ONDEMAND_RECOVERY_DATABASE_NOT_EXCLUSIVE",
    "ITL_ONDEMAND_RECOVERY_PROCESS_COMMAND_LINE_UNAVAILABLE",
    "ITL_ONDEMAND_RECOVERY_RESOURCE_PLAN_CHANGED",
    "ITL_ONDEMAND_RECOVERY_OWNER_CHANGED",
    "ITL_ONDEMAND_RECOVERY_PLAN_INVALID",
    "NATIVE_RECOVERY_STARTED_OPERATION_ADAPTER_REQUIRED",
    "NATIVE_RECOVERY_DATABASE_RESTORATION_ADAPTER_REQUIRED",
    "NATIVE_RECOVERY_ADDITIONAL_DATABASE_RESTORATION_REQUIRED",
    "NATIVE_RECOVERY_RESTORATION_CONTRACT_REQUIRED",
    "NATIVE_RECOVERY_NATIVE_CONTEXT_REQUIRED",
    "NATIVE_RECOVERY_SERVER_INSPECTOR_REQUIRED",
    "NATIVE_RECOVERY_SERVER_INSPECTOR_CHANGED",
    "NATIVE_RECOVERY_INSPECTION_",
    "NATIVE_RECOVERY_SOURCE_",
    "NATIVE_RECOVERY_SNAPSHOT_ORDER_UNKNOWN",
    "RESTORATION_JOURNAL_SNAPSHOT_CHANGED",
    "INFOBASE_ACCESS_RECOVERY_NESTED_CLEANUP_UNCONFIRMED",
    "RECOVERY_ORIGINAL_OWNER_UNPROVEN",
    "RECOVERY_ORIGINAL_INPUTS_CHANGED",
    "RECOVERY_RESOURCE_BINDING_CHANGED",
    "RECOVERY_ADAPTER_REQUIRED",
)
WORKFLOW_CHANGE_ERRORS = (
    "ITL_ONDEMAND_RECOVERY_HELPER_MISSING",
    "ITL_ONDEMAND_RECOVERY_HELPER_FAILED",
    "ITL_ONDEMAND_RECOVERY_HELPER_RESULT_INVALID",
    "NATIVE_RECOVERY_STARTED_OPERATION_ADAPTER_REQUIRED",
    "NATIVE_RECOVERY_DATABASE_RESTORATION_ADAPTER_REQUIRED",
    "NATIVE_RECOVERY_ADDITIONAL_DATABASE_RESTORATION_REQUIRED",
)

def _admission_details(error, prefix, *, require_single=True):
    text = str(error)
    if not text.startswith(prefix):
        return None
    try:
        value = json.loads(text[len(prefix):])
    except json.JSONDecodeError:
        return None
    blockers = value.get("blockers") if isinstance(value, dict) else None
    if not isinstance(blockers, list) or (require_single and len(blockers) != 1) or not blockers:
        return None
    if any(not isinstance(blocker, dict) or not isinstance(blocker.get("ticket"), str) for blocker in blockers):
        return None
    return value


def _scope(owner):
    for name in ("project", "workspace"):
        value = owner.get(name) if isinstance(owner, dict) else None
        if isinstance(value, str) and value:
            return value
    return ""


def _same_path(first, second):
    try:
        left, right = str(Path(first).resolve()), str(Path(second).resolve())
    except (OSError, TypeError, ValueError):
        return False
    return left.casefold() == right.casefold() if os.name == "nt" else left == right


def _primary_recovery_error(error):
    _, separator, raw = str(error).partition(": ")
    if not separator:
        return ""
    try:
        value = json.loads(raw).get("primaryError", "")
    except (AttributeError, json.JSONDecodeError):
        return ""
    if (not isinstance(value, str) or not value or len(value) > 128 or
            value.upper() != value or not value.replace("_", "").isalnum()):
        return ""
    return value


def _intervention(reason, *, coordinator, ticket, owner, recovery_error="",
                  classification="user-decision-or-external-action", required_action=None,
                  requires_user_decision=True, workflow_change_required=False, retry_allowed=True,
                  primary_error=""):
    payload = {
        "schemaVersion": 1,
        "classification": classification,
        "reason": reason,
        "coordinator": str(coordinator),
        "ticket": ticket,
        "owner": owner,
        "requestExecuted": False,
        "recoveryAttempted": bool(recovery_error),
        "recoveryError": recovery_error,
        "workflowChangeRequired": bool(workflow_change_required),
        "requiresUserDecision": requires_user_decision,
        "retryAllowed": bool(retry_allowed),
        "retryOriginalCommandAfterResolution": True,
        "requiredAction": required_action or "resolve-database-access-blocker",
        "instruction": (
            "Do not edit workflow state or force-unlock. Preserve the identified owner. "
            "Use only its owning finish/cancel/stop surface. Ask the user only when the classified action "
            "requires a decision or external work. After confirmed release, repeat the original command."
        ),
    }
    if primary_error:
        payload["primaryError"] = primary_error
    raise WorkError("INFOBASE_ACCESS_INTERVENTION_REQUIRED: " +
                    json.dumps(payload, ensure_ascii=True, separators=(",", ":")))


def _requires_intervention(error):
    text = str(error)
    return any(text.startswith(prefix) for prefix in INTERVENTION_ERRORS)


def _requires_workflow_change(error):
    text = str(error)
    return any(text.startswith(prefix) for prefix in WORKFLOW_CHANGE_ERRORS)


def _live_blocker(blocker, requester):
    owner = blocker.get("owner", {})
    action = owner.get("releaseAction") if isinstance(owner, dict) else None
    requester_scope, owner_scope = _scope(requester), _scope(owner)
    same_scope = bool(requester_scope and owner_scope and _same_path(requester_scope, owner_scope))
    next_action = blocker.get("nextAction", {})
    coordinator = next_action.get("coordinator", "")
    if same_scope and isinstance(action, dict) and action.get("kind") == "finish-owned-on-demand":
        _intervention("live-owned-on-demand-holder", coordinator=coordinator, ticket=blocker["ticket"], owner=owner,
                      classification="agent-owned-handoff-required", required_action=action,
                      requires_user_decision=False)
    _intervention("live-or-foreign-holder", coordinator=coordinator, ticket=blocker["ticket"], owner=owner)


def _recover(blocker, requester, seen, cancelled):
    ticket, coordinator = blocker["ticket"], blocker.get("nextAction", {}).get("coordinator")
    if not isinstance(coordinator, str) or not coordinator:
        raise WorkError("INFOBASE_ACCESS_AUTO_RECOVERY_BLOCKER_INVALID")
    try:
        prepared = plan(coordinator, ticket)
    except WorkError as error:
        if str(error).startswith("INFOBASE_ACCESS_RECOVERY_NOT_REQUIRED"):
            return
        if _requires_intervention(error):
            _intervention("owner-became-live", coordinator=coordinator, ticket=ticket,
                          owner=blocker.get("owner", {}), recovery_error=str(error))
        raise WorkError("INFOBASE_ACCESS_AUTO_RECOVERY_FAILED: " + str(error)) from error
    owner = prepared.get("operation", {}).get("owner", {})
    original_host = str(owner.get("host", ""))
    if original_host and original_host.casefold() != platform.node().casefold():
        _intervention("foreign-host", coordinator=coordinator, ticket=ticket, owner=owner)
    requester_scope, owner_scope = _scope(requester), _scope(owner)
    if requester_scope and owner_scope and not same_git_workspace(requester_scope, owner_scope):
        _intervention("foreign-project", coordinator=coordinator, ticket=ticket, owner=owner)
    key = ticket + ":" + prepared["revision"]
    if key in seen:
        raise WorkError("INFOBASE_ACCESS_AUTO_RECOVERY_STALLED: ticket/revision repeated after recovery")
    seen.add(key)
    if cancelled():
        raise WorkError("INFOBASE_ACCESS_CANCELLED")
    from .access_dispatch import recover
    try:
        recover(coordinator, ticket, cancelled=cancelled)
    except WorkError as error:
        if str(error).startswith(("INFOBASE_ACCESS_RECOVERY_PLAN_STALE", "INFOBASE_ACCESS_RECOVERY_NOT_REQUIRED")):
            return
        if _requires_workflow_change(error):
            _intervention("trusted-recovery-contract-missing", coordinator=coordinator, ticket=ticket, owner=owner,
                          recovery_error=str(error), classification="workflow-repair-required",
                          required_action="repair-workflow-recovery-contract", requires_user_decision=False,
                          workflow_change_required=True, retry_allowed=False,
                          primary_error=_primary_recovery_error(error))
        if _requires_intervention(error):
            _intervention("trusted-recovery-needs-external-evidence", coordinator=coordinator,
                          ticket=ticket, owner=owner, recovery_error=str(error))
        raise WorkError("INFOBASE_ACCESS_AUTO_RECOVERY_FAILED: " + str(error)) from error


def enter_root_lease(coordinator, bases, owner, *, timeout=3600, cancelled=lambda: False,
                     progress=lambda record: None, access_mode=None):
    """Acquire a root lease, reconciling only trusted orphan contracts in scope."""
    seen = set()
    for _ in range(16):
        lease = Lease(coordinator, bases, owner, timeout=timeout, cancelled=cancelled,
                      progress=progress, access_mode=access_mode)
        try:
            lease.__enter__()
            return lease
        except WorkError as error:
            details = _admission_details(error, RECOVERY_REQUIRED)
            if details is not None:
                blocker = details["blockers"][0]
                if progress:
                    progress({"status": "recovering-database-access", "ticket": blocker["ticket"],
                              "resources": [], "waitSeconds": details.get("waitSeconds", 0),
                              "blockers": details["blockers"]})
                _recover(blocker, owner, seen, cancelled)
                continue
            waiting = _admission_details(error, WAIT_TIMEOUT, require_single=False)
            if waiting is not None:
                if len(waiting["blockers"]) == 1:
                    _live_blocker(waiting["blockers"][0], owner)
                _intervention("multiple-live-or-foreign-holders", coordinator=waiting.get("coordinator", coordinator),
                              ticket=waiting["blockers"][0]["ticket"],
                              owner={"blockers": waiting["blockers"]})
            raise
    raise WorkError("INFOBASE_ACCESS_AUTO_RECOVERY_CHAIN_LIMIT: more than 16 distinct orphan revisions")


from contextlib import contextmanager


@contextmanager
def root_lease(coordinator, bases, owner, **kwargs):
    lease = enter_root_lease(coordinator, bases, owner, **kwargs)
    try:
        yield lease
    except BaseException as error:
        lease.__exit__(type(error), error, error.__traceback__)
        raise
    else:
        lease.__exit__(None, None, None)
