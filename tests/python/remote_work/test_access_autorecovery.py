import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote.access import Coordinator, Lease
from itl_remote.access_autorecovery import enter_root_lease
from itl_remote.common import WorkError
from itl_remote import access_autorecovery, access_dispatch, ondemand_recovery, recovery_job


class AutoRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL auto recovery ")
        self.root = Path(self.temp.name)
        self.coordinator = self.root / "координатор с пробелом"
        self.project = self.root / "проект с пробелом"
        (self.project / ".agents/skills/1c-workflow/scripts").mkdir(parents=True)
        (self.project / ".agents/skills/1c-workflow/scripts/agent-1c.ps1").write_text("# fixture", encoding="utf-8")
        self.base = {"kind": "file", "path": str(self.root / "база с пробелом")}
        self.instance = "a" * 32
        self.action = {"kind": "finish-owned-on-demand", "family": "vanessa-ui",
                       "instanceId": self.instance, "tool": "finish_database_access"}
        self.owner = {"project": str(self.project), "operation": "ondemand-vanessa-ui",
                      "requestId": self.instance, "lifecycle": "on-demand", "releaseAction": self.action}
        self.requester = {"project": str(self.project), "operation": "refresh-dev-branch-lite"}

    def tearDown(self):
        self.temp.cleanup()

    def orphan(self):
        lease = Lease(self.coordinator, [self.base], self.owner, timeout=0, access_mode="functional-test")
        lease.__enter__()
        self.assertEqual("needs-attention", lease.release(cleanup_errors=["cleanup unproven"]))
        return lease.record["ticket"]

    def invoke(self, project, family, instance, operation, env=None):
        if operation == "access-plan":
            return {"databaseAccess": {"schemaVersion": 1, "family": family, "projectRoot": project,
                    "instanceId": instance, "coordinator": str(self.coordinator), "bases": [self.base],
                    "accessMode": "functional-test", "servicePlan": None}}
        return {"status": "stopped", "family": family, "instanceId": instance,
                "recoveryEvidence": {"family": family, "instanceId": instance,
                    "ownedRuntimeCleanup": "runtime-state-absent-live-quiescence-confirmed",
                    "restoration": "no-restoration-duties-created", "samples": [{}, {}]}}

    def test_root_admission_recovers_orphan_and_retries_with_new_ticket(self):
        old_ticket = self.orphan()
        with mock.patch.object(ondemand_recovery, "_invoke", side_effect=self.invoke):
            lease = enter_root_lease(self.coordinator, [self.base], self.requester,
                                    timeout=0, access_mode="mutation-exclusive")
        try:
            self.assertNotEqual(old_ticket, lease.record["ticket"])
            old = Coordinator(self.coordinator).record(old_ticket)
            self.assertEqual("released", old["status"])
            self.assertEqual("recovery-verified", old["reason"])
            self.assertEqual("running", lease.record["status"])
        finally:
            lease.release()

    def test_live_owned_on_demand_holder_is_agent_handoff_not_workflow_failure(self):
        holder = Lease(self.coordinator, [self.base], self.owner, timeout=0, access_mode="functional-test")
        holder.__enter__()
        try:
            with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_INTERVENTION_REQUIRED") as raised:
                enter_root_lease(self.coordinator, [self.base], self.requester,
                                 timeout=0, access_mode="mutation-exclusive")
            payload = json.loads(str(raised.exception).split(": ", 1)[1])
            self.assertEqual("agent-owned-handoff-required", payload["classification"])
            self.assertFalse(payload["requiresUserDecision"])
            self.assertFalse(payload["workflowChangeRequired"])
            self.assertEqual(self.action, payload["requiredAction"])
            self.assertTrue(payload["retryOriginalCommandAfterResolution"])
        finally:
            holder.release()

    def test_foreign_live_holder_requires_user_decision(self):
        foreign_owner = dict(self.owner, project=str(self.root / "чужой проект"))
        holder = Lease(self.coordinator, [self.base], foreign_owner, timeout=0, access_mode="functional-test")
        holder.__enter__()
        try:
            with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_INTERVENTION_REQUIRED") as raised:
                enter_root_lease(self.coordinator, [self.base], self.requester,
                                 timeout=0, access_mode="mutation-exclusive")
            payload = json.loads(str(raised.exception).split(": ", 1)[1])
            self.assertEqual("user-decision-or-external-action", payload["classification"])
            self.assertTrue(payload["requiresUserDecision"])
            self.assertFalse(payload["workflowChangeRequired"])
            self.assertEqual("resolve-database-access-blocker", payload["requiredAction"])
        finally:
            holder.release()

    def test_ambiguous_recovery_evidence_is_classified_as_intervention(self):
        self.orphan()
        with mock.patch.object(access_autorecovery, "plan", wraps=access_autorecovery.plan), \
             mock.patch("itl_remote.access_dispatch.recover", side_effect=WorkError("NATIVE_RECOVERY_STARTED_OPERATION_ADAPTER_REQUIRED")):
            with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_INTERVENTION_REQUIRED") as raised:
                enter_root_lease(self.coordinator, [self.base], self.requester,
                                 timeout=0, access_mode="mutation-exclusive")
        payload = json.loads(str(raised.exception).split(": ", 1)[1])
        self.assertEqual("workflow-repair-required", payload["classification"])
        self.assertTrue(payload["workflowChangeRequired"])
        self.assertFalse(payload["requiresUserDecision"])
        self.assertEqual("repair-workflow-recovery-contract", payload["requiredAction"])
        self.assertTrue(payload["recoveryAttempted"])

    def test_dispatcher_routes_measurement_owner_to_pinned_job_recovery(self):
        prepared = {"operation": {"owner": {"operation": "measure", "jobId": "job-a", "spool": str(self.root / "spool")}}}
        with mock.patch.object(access_dispatch, "plan", return_value=prepared), \
             mock.patch.object(recovery_job, "create_plan", return_value={"planId": "d" * 64}) as create, \
             mock.patch.object(recovery_job, "run", return_value={"status": "completed"}) as run:
            result = access_dispatch.recover(self.coordinator, "e" * 32)
        self.assertEqual("completed", result["status"])
        create.assert_called_once_with(str(self.root / "spool"), "job-a")
        run.assert_called_once_with(str(self.root / "spool"), "job-a", "d" * 64)


if __name__ == "__main__":
    unittest.main()
