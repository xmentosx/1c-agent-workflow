import os
from pathlib import Path
import platform
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote.access import Coordinator, Lease
from itl_remote.common import WorkError
from itl_remote import ondemand_recovery


class OnDemandRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL on-demand recovery ")
        self.root = Path(self.temp.name)
        self.coordinator = self.root / "coordinator"
        self.project = self.root / "проект with spaces"
        (self.project / ".agents/skills/1c-workflow/scripts").mkdir(parents=True)
        (self.project / ".agents/skills/1c-workflow/scripts/agent-1c.ps1").write_text("# fixture", encoding="utf-8")
        self.base = {"kind": "file", "path": str(self.root / "база with spaces")}
        instance = "a" * 32
        self.action = {"kind": "finish-owned-on-demand", "family": "vanessa-ui",
                       "instanceId": instance, "tool": "finish_database_access"}
        self.owner = {"project": str(self.project), "operation": "ondemand-vanessa-ui", "requestId": instance,
                      "lifecycle": "on-demand", "releaseAction": self.action}

    def tearDown(self):
        self.temp.cleanup()

    def orphan(self, nested=False):
        parent = Lease(self.coordinator, [self.base], self.owner, timeout=0, access_mode="functional-test")
        parent.__enter__()
        if nested:
            child = Lease(self.coordinator, [self.base], {"operation": "ondemand-stop"}, timeout=0,
                          inherited=parent.proof(), access_mode="functional-test")
            child.__enter__()
            self.assertEqual("needs-attention", child.release(cleanup_errors=["cleanup unproven"]))
        self.assertEqual("needs-attention", parent.release(cleanup_errors=[] if nested else ["cleanup unproven"]))
        return parent.record["ticket"]

    def invoke(self, project, family, instance, operation, env=None):
        self.assertEqual(str(self.project), project)
        self.assertEqual("vanessa-ui", family)
        self.assertEqual(self.action["instanceId"], instance)
        if operation == "access-plan":
            return {"databaseAccess": {"schemaVersion": 1, "family": family, "projectRoot": project,
                    "instanceId": instance, "coordinator": str(self.coordinator), "bases": [self.base],
                    "accessMode": "functional-test", "servicePlan": None}}
        self.assertEqual("recover-stop", operation)
        self.assertIsNotNone(env)
        self.assertIn('"purpose":"recovery"', env["ITL_INFOBASE_ACCESS_LEASE"])
        return {"status": "stopped", "family": family, "instanceId": instance,
                "recoveryEvidence": {"adapter": "finish-owned-on-demand", "family": family,
                    "instanceId": instance, "ownedRuntimeCleanup": "strict-ownership-confirmed",
                    "restoration": "no-restoration-duties-created", "samples": [{}, {}]}}

    def test_nested_orphan_is_released_only_after_trusted_recovery(self):
        ticket = self.orphan(nested=True)
        with mock.patch.object(ondemand_recovery, "_invoke", side_effect=self.invoke):
            result = ondemand_recovery.recover_on_demand(self.coordinator, ticket)
        self.assertEqual("released", result["status"])
        self.assertEqual("recovery-verified", result["reason"])
        attempt = result["recoveryAttempts"][-1]
        self.assertEqual("completed", attempt["status"])
        self.assertEqual(1, len(attempt["resolvedParticipants"]))
        self.assertEqual("finish-owned-on-demand/vanessa-ui", attempt["evidence"]["adapter"])

    def test_live_owner_is_not_recoverable(self):
        lease = Lease(self.coordinator, [self.base], self.owner, timeout=0, access_mode="functional-test")
        lease.__enter__()
        try:
            with self.assertRaisesRegex(WorkError, "RECOVERY_OWNER_LIVE"):
                ondemand_recovery.recover_on_demand(self.coordinator, lease.record["ticket"])
        finally:
            lease.release()

    def test_changed_resource_plan_fails_closed(self):
        ticket = self.orphan()
        def changed(project, family, instance, operation, env=None):
            return {"databaseAccess": {"coordinator": str(self.coordinator),
                    "bases": [{"kind": "file", "path": str(self.root / "other")} ]}}
        with mock.patch.object(ondemand_recovery, "_invoke", side_effect=changed):
            with self.assertRaisesRegex(WorkError, "RESOURCE_PLAN_CHANGED"):
                ondemand_recovery.recover_on_demand(self.coordinator, ticket)
        self.assertEqual("needs-attention", Coordinator(self.coordinator).snapshot()[0]["status"])


if __name__ == "__main__":
    unittest.main()
