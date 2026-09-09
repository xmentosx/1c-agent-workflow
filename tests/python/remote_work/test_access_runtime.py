"""The admission interval encloses the actual engine, including its cleanup."""
import concurrent.futures
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import access, execution, jobs
from itl_remote.common import read_json, write_json


class AccessRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()
        self.target = self.fixture.profile["targets"]["fixture"]
        self.config = access.target_access(self.target)
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)

    def tearDown(self):
        self.pool.shutdown(wait=True)
        self.fixture.tearDown()

    def package(self):
        request, package = self.fixture.package()
        jobs.submit(package, self.fixture.spool)
        return request

    def run_async(self):
        return self.pool.submit(execution.execute_job, self.fixture.spool, "one", self.fixture.profile)

    def wait_for_queue(self):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            state = jobs.status(self.fixture.spool, "one")
            if state["status"] == "waiting-for-base":
                return state
            time.sleep(.02)
        self.fail("Engine did not publish database wait state")

    def own_base(self):
        return access.Lease(self.config["coordinator"], self.config["bases"], {"jobId": "other-project"})

    def test_wait_is_outside_measurement_and_private_lease_is_not_reported(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            self.assertFalse((self.fixture.spool / "runs/one/context.json").exists())
            time.sleep(.2)
        state = pending.result(timeout=10)
        self.assertEqual("completed", state["status"], state)
        result = read_json(self.fixture.spool / "runs/one/result.json")
        context = read_json(self.fixture.spool / "runs/one/context.json")
        self.assertGreaterEqual(result["access"]["waitSeconds"], .2)
        self.assertNotIn(context["accessLease"]["token"], json.dumps(result))
        self.assertNotIn(context["accessLease"]["token"], json.dumps(state))
        self.assertEqual([], access.Coordinator(self.config["coordinator"]).snapshot())

    def test_cancellation_while_waiting_does_not_create_runtime(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            jobs.cancel(self.fixture.spool, "one")
            state = pending.result(timeout=5)
            self.assertEqual("cancelled", state["status"], state)
            self.assertFalse((self.fixture.spool / "runs").exists())

    def test_changed_package_is_revalidated_before_runtime_after_admission(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            (self.fixture.spool / "jobs/one/input/workload.py").write_text("changed", encoding="utf-8")
        state = pending.result(timeout=5)
        self.assertEqual("needs-attention", state["status"])
        self.assertIn("INPUT_HASH_MISMATCH", state["error"])
        self.assertFalse((self.fixture.spool / "runs").exists())

    def test_cleanup_error_keeps_admission_blocked_for_followup(self):
        self.package()
        with patch.object(execution, "run_measurement", return_value={"status": "needs-attention", "cleanupErrors": ["restore failed"]}):
            state = execution.execute_job(self.fixture.spool, "one", self.fixture.profile)
        self.assertEqual("needs-attention", state["status"])
        _, second = self.fixture.package("two")
        jobs.submit(second, self.fixture.spool)
        state = execution.execute_job(self.fixture.spool, "two", self.fixture.profile)
        self.assertIn("INFOBASE_ACCESS_RECOVERY_REQUIRED", state["error"])
        self.assertFalse((self.fixture.spool / "runs/two").exists())

    def test_worker_profile_change_during_wait_does_not_run_stale_target(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            path = self.fixture.spool / "profile.json"
            profile = read_json(path)
            profile["targets"]["fixture"]["allowedOperations"] = []
            write_json(path, profile)
        state = pending.result(timeout=5)
        self.assertIn("INFOBASE_ACCESS_TARGET_CHANGED", state["error"])
        self.assertFalse((self.fixture.spool / "runs").exists())

    def test_owned_action_receives_a_verifiable_inherited_lease(self):
        workload = self.fixture.source / "workload.py"
        text = workload.read_text(encoding="utf-8")
        text = text.replace('c = context()', '''c = context()
import json
from itl_remote.access import Lease
proof = json.loads(os.environ['ITL_INFOBASE_ACCESS_LEASE'])
with Lease(proof['coordinator'], [{'kind':'workspace','path':c['target']['workspace']}],
           {'operation':'nested'}, inherited=proof):
    (Path(c['iteration']) / 'inherited.json').write_text(json.dumps({'ticket':proof['ticket']}))''')
        workload.write_text(text, encoding="utf-8")
        self.package()
        state = execution.execute_job(self.fixture.spool, "one", self.fixture.profile)
        self.assertEqual("completed", state["status"], state)
        evidence = list((self.fixture.spool / "runs/one").glob("*/inherited.json"))
        self.assertEqual(1, len(evidence))
        self.assertEqual(state["access"]["ticket"], read_json(evidence[0])["ticket"])

    def test_completed_workload_cannot_hide_uncertain_nested_cleanup(self):
        workload = self.fixture.source / "workload.py"
        text = workload.read_text(encoding="utf-8")
        text = text.replace('c = context()', '''c = context()
import json
from itl_remote.access import Lease
proof = json.loads(os.environ['ITL_INFOBASE_ACCESS_LEASE'])
with Lease(proof['coordinator'], [{'kind':'workspace','path':c['target']['workspace']}],
           {'operation':'nested'}, inherited=proof) as nested:
    nested.release(cleanup_errors=['native outcome unproven'])''')
        workload.write_text(text, encoding="utf-8")
        self.package()
        state = execution.execute_job(self.fixture.spool, "one", self.fixture.profile)
        self.assertEqual("needs-attention", state["status"], state)
        result = read_json(self.fixture.spool / "runs/one/result.json")
        self.assertEqual("needs-attention", result["status"])
        self.assertIn("INFOBASE_ACCESS_NESTED_CLEANUP_UNCONFIRMED", result["cleanupErrors"])
        self.assertTrue(result["timings"], "retain collected performance evidence")
        self.assertEqual("needs-attention", access.Coordinator(self.config["coordinator"]).snapshot()[0]["status"])


if __name__ == "__main__":
    unittest.main()
