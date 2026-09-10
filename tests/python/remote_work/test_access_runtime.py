"""The admission interval encloses the actual engine, including its cleanup."""
import concurrent.futures
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import test_runtime
from itl_remote import access, execution, jobs
from itl_remote.common import digest, read_json, write_json


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
        self.target["credentials"] = {"password": "never-publish-profile-secret"}
        request = self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            self.assertFalse((self.fixture.spool / "runs/one/context.json").exists())
            provenance_path = self.fixture.spool / "runs/one/provenance.json"
            original_hash = digest(provenance_path)
            original = read_json(provenance_path)
            self.assertEqual(request["files"], original["files"])
            self.assertEqual(request["parameters"], original["parameters"])
            self.assertEqual(1, original["repeats"])
            self.assertEqual(0, original["warmups"])
            output = self.fixture.root / "Диагностика ожидания"
            collection = jobs.collect(self.fixture.spool, "one", output, allow_partial=True)
            self.assertFalse(collection["resultAvailable"])
            self.assertEqual("waiting-for-base", collection["observedJob"]["status"])
            self.assertEqual(original_hash, digest(output / "provenance.json"))
            self.assertNotIn("never-publish-profile-secret", json.dumps(original))
            time.sleep(.2)
        state = pending.result(timeout=10)
        self.assertEqual("completed", state["status"], state)
        result = read_json(self.fixture.spool / "runs/one/result.json")
        context = read_json(self.fixture.spool / "runs/one/context.json")
        self.assertGreaterEqual(result["access"]["waitSeconds"], .2)
        self.assertNotIn(context["accessLease"]["token"], json.dumps(result))
        self.assertNotIn(context["accessLease"]["token"], json.dumps(state))
        self.assertNotIn(context["accessLease"]["token"], json.dumps(original))
        self.assertEqual(original_hash, digest(provenance_path))
        self.assertEqual({"path": "provenance.json", "sha256": original_hash}, result["provenance"])
        self.assertEqual([], access.Coordinator(self.config["coordinator"]).snapshot())

    def test_cancellation_while_waiting_does_not_create_runtime(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            jobs.cancel(self.fixture.spool, "one")
            state = pending.result(timeout=5)
            self.assertEqual("cancelled", state["status"], state)
            # Input evidence is allowed before admission; execution artifacts
            # still prove whether any runtime was started after cancellation.
            run = self.fixture.spool / "runs/one"
            self.assertEqual(["provenance.json"], sorted(p.name for p in run.iterdir()))

    def test_changed_provenance_is_preserved_and_rejected_before_workload(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            path = self.fixture.spool / "runs/one/provenance.json"
            changed = read_json(path)
            # Even an edit outside the comparable input fields breaks the
            # retained artifact hash; do not bless it by hashing it afresh.
            changed["recordedAt"] = "2020-01-01T00:00:00Z"
            write_json(path, changed)
        state = pending.result(timeout=5)
        self.assertIn("MEASUREMENT_PROVENANCE_CHANGED", state["error"])
        self.assertEqual(changed, read_json(path))
        self.assertFalse((path.parent / "context.json").exists())
        self.assertFalse((path.parent / "result.json").exists())
        self.assertEqual([], access.Coordinator(self.config["coordinator"]).snapshot())

        with self.own_base() as subsequent:
            self.assertEqual("running", subsequent.record["status"])

    def test_changed_package_is_revalidated_before_runtime_after_admission(self):
        self.package()
        with self.own_base():
            pending = self.run_async()
            self.wait_for_queue()
            (self.fixture.spool / "jobs/one/input/workload.py").write_text("changed", encoding="utf-8")
        state = pending.result(timeout=5)
        self.assertEqual("needs-attention", state["status"])
        self.assertIn("INPUT_HASH_MISMATCH", state["error"])
        self.assertEqual(["provenance.json"], sorted(p.name for p in (self.fixture.spool / "runs/one").iterdir()))
        self.assertEqual([], access.Coordinator(self.config["coordinator"]).snapshot())

    def test_cleanup_error_keeps_admission_blocked_for_followup(self):
        self.package()
        with patch.object(execution, "run_measurement", return_value={"status": "needs-attention", "cleanupErrors": ["restore failed"]}):
            state = execution.execute_job(self.fixture.spool, "one", self.fixture.profile)
        self.assertEqual("needs-attention", state["status"])
        _, second = self.fixture.package("two")
        jobs.submit(second, self.fixture.spool)
        state = execution.execute_job(self.fixture.spool, "two", self.fixture.profile)
        self.assertIn("INFOBASE_ACCESS_RECOVERY_REQUIRED", state["error"])
        self.assertEqual(["provenance.json"], sorted(p.name for p in (self.fixture.spool / "runs/two").iterdir()))

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
        self.assertEqual(["provenance.json"], sorted(p.name for p in (self.fixture.spool / "runs/one").iterdir()))
        self.assertEqual([], access.Coordinator(self.config["coordinator"]).snapshot())

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
