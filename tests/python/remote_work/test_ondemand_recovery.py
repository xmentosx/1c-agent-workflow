import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))

from itl_remote.access import Coordinator, Lease
from itl_remote.common import WorkError
from itl_remote import common, ondemand_recovery


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

    def invoke(self, project, family, instance, operation, env=None, **kwargs):
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
        def changed(project, family, instance, operation, env=None, **kwargs):
            return {"databaseAccess": {"coordinator": str(self.coordinator),
                    "bases": [{"kind": "file", "path": str(self.root / "other")} ]}}
        with mock.patch.object(ondemand_recovery, "_invoke", side_effect=changed):
            with self.assertRaisesRegex(WorkError, "RESOURCE_PLAN_CHANGED"):
                ondemand_recovery.recover_on_demand(self.coordinator, ticket)
        self.assertEqual("needs-attention", Coordinator(self.coordinator).snapshot()[0]["status"])

    def test_initiating_package_helper_is_used_instead_of_poisoned_target_copy(self):
        target_helper = self.project / ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
        target_helper.write_text("throw 'poisoned stale helper'", encoding="utf-8")
        observed = {}

        class SuccessfulProcess:
            def __init__(inner, argv, cwd, output, env=None):
                observed.update(argv=argv, cwd=cwd, output=Path(output))
                Path(output).write_text(
                    ondemand_recovery.MARKER + json.dumps({"status": "planned"}), encoding="utf-8")
                inner.process = SimpleNamespace(returncode=0)

            def __enter__(inner):
                return inner

            def __exit__(inner, *_):
                pass

            def wait(inner, timeout, cancelled):
                pass

        output = self.root / "журнал trusted helper"
        with mock.patch.object(ondemand_recovery, "OwnedProcess", SuccessfulProcess):
            result = ondemand_recovery._invoke(
                str(self.project), "vanessa-ui", self.action["instanceId"], "access-plan", output=output)
        helper = Path(observed["argv"][observed["argv"].index("-File") + 1])
        self.assertEqual(REPO / ".agents/skills/1c-workflow/scripts/agent-1c.ps1", helper)
        self.assertNotEqual(target_helper, helper)
        self.assertEqual(str(self.project), observed["cwd"])
        self.assertEqual("planned", result["status"])

    def test_helper_failure_reports_safe_primary_error_and_retains_full_log(self):
        secret = "password=do-not-copy"

        class FailedProcess:
            def __init__(inner, argv, cwd, output, env=None):
                Path(output).write_text(secret + "\nINFOBASE_ACCESS_MODE_INVALID\n", encoding="utf-8")
                inner.process = SimpleNamespace(returncode=17)

            def __enter__(inner):
                return inner

            def __exit__(inner, *_):
                pass

            def wait(inner, timeout, cancelled):
                raise WorkError("COMMAND_FAILED: exit=17")

        output = self.root / "диагностика helper"
        with mock.patch.object(ondemand_recovery, "OwnedProcess", FailedProcess):
            with self.assertRaisesRegex(WorkError, "ITL_ONDEMAND_RECOVERY_HELPER_FAILED") as raised:
                ondemand_recovery._invoke(
                    str(self.project), "vanessa-ui", self.action["instanceId"], "access-plan", output=output)
        message = str(raised.exception)
        payload = json.loads(message.split(": ", 1)[1])
        self.assertEqual("INFOBASE_ACCESS_MODE_INVALID", payload["primaryError"])
        self.assertEqual("COMMAND_FAILED", payload["processError"])
        self.assertEqual(17, payload["helperExitCode"])
        self.assertNotIn(secret, message)
        self.assertIn(secret, Path(payload["logPath"]).read_text(encoding="utf-8"))

    def test_helper_failure_marks_recovery_attempt_terminal(self):
        ticket = self.orphan()
        error = WorkError(
            'ITL_ONDEMAND_RECOVERY_HELPER_FAILED: '
            '{"schemaVersion":1,"operation":"access-plan","primaryError":"COMMAND_TIMEOUT"}')
        with mock.patch.object(ondemand_recovery, "_invoke", side_effect=error):
            with self.assertRaisesRegex(WorkError, "ITL_ONDEMAND_RECOVERY_HELPER_FAILED"):
                ondemand_recovery.recover_on_demand(self.coordinator, ticket)
        record = Coordinator(self.coordinator).record(ticket)
        self.assertEqual("needs-attention", record["status"])
        self.assertEqual("failed", record["recoveryAttempts"][-1]["status"])

    @unittest.skipUnless(os.name == "nt", "native Job Object contract is Windows-only")
    def test_timeout_closes_the_helper_and_its_output_holding_child(self):
        helper = self.root / "trusted helper with spaces" / "восстановление.ps1"
        helper.parent.mkdir(parents=True)
        helper.write_text(
            "param([string]$ProjectRoot,[string]$InternalOnDemandOperation,"
            "[string]$InternalOnDemandFamily,[string]$InternalOnDemandInstanceId)\n"
            "$child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\\PING.EXE') "
            "-ArgumentList @('-t','127.0.0.1') -NoNewWindow -PassThru\n"
            "[IO.File]::WriteAllText($env:ITL_TEST_CHILD_PID,[string]$child.Id,[Text.Encoding]::ASCII)\n"
            "Start-Sleep -Seconds 60\n",
            encoding="utf-8")
        pid_path = self.root / "дочерний pid with spaces.txt"
        child_env = os.environ.copy()
        child_env["ITL_TEST_CHILD_PID"] = str(pid_path)
        pid = None
        try:
            with mock.patch.object(ondemand_recovery, "_helper", return_value=helper):
                with self.assertRaisesRegex(WorkError, "ITL_ONDEMAND_RECOVERY_HELPER_FAILED") as raised:
                    ondemand_recovery._invoke(
                        str(self.project), "vanessa-ui", self.action["instanceId"], "access-plan",
                        output=self.root / "timeout logs", env=child_env, timeout=3)
            payload = json.loads(str(raised.exception).split(": ", 1)[1])
            self.assertEqual("COMMAND_TIMEOUT", payload["processError"])
            self.assertTrue(pid_path.is_file(), str(raised.exception))
            pid = int(pid_path.read_text(encoding="ascii"))
            deadline = time.monotonic() + 5
            while common.process_is_alive(pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(common.process_is_alive(pid))
        finally:
            if pid and common.process_is_alive(pid):
                subprocess.run(["taskkill.exe", "/PID", str(pid), "/T", "/F"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


if __name__ == "__main__":
    unittest.main()
