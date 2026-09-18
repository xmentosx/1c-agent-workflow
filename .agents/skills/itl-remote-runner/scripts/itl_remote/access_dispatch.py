"""Dispatch persisted database-access recovery contracts without replaying work."""
from __future__ import annotations

from .access import on_demand_release_action
from .access_recovery import plan


def recover(root, ticket, *, cancelled=lambda: False):
    prepared = plan(root, ticket)
    owner = prepared.get("operation", {}).get("owner", {})
    if on_demand_release_action(owner) is not None:
        from .ondemand_recovery import recover_on_demand
        return recover_on_demand(root, ticket, cancelled=cancelled)
    if (owner.get("operation") == "measure" and isinstance(owner.get("jobId"), str) and
            isinstance(owner.get("spool"), str)):
        from . import recovery_job
        recovery_plan = recovery_job.create_plan(owner["spool"], owner["jobId"])
        return recovery_job.run(owner["spool"], owner["jobId"], recovery_plan["planId"])
    from .native_recovery import recover_workflow_operation
    return recover_workflow_operation(root, ticket, cancelled=cancelled)
