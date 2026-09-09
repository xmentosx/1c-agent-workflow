"""Pinned recovery hooks against SQLite state and real competing processes."""
import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import unittest

import test_runtime
from itl_remote import access, execution, jobs, recovery_job, transport
from itl_remote.common import WorkError, read_json, write_json


HOOK = r'''
import os, sys, sqlite3, time
from contextlib import closing
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote.access import Lease, target_access
from itl_remote.common import FileLock, WorkError, digest, read_json, write_json
c = read_json(os.environ['ITL_RUN_CONTEXT']); r = c['recovery']
root = Path(c['target']['workspace']); stage = sys.argv[2]
case = c['parameters']['recoveryCase']; out = Path(r['output']).parent
proof = c['accessLease']; config = target_access(c['target'])
with Lease(proof['coordinator'], config['bases'], {}, inherited=proof, purpose='recovery'):
    def work_stopped():
        for name in ['work.lock', 'restore.lock']:
            try:
                with FileLock(root / name): pass
            except WorkError: return False
        return True
    if stage == 'quiesce':
        if case != 'quiesce-noeffect':
            (root / 'stop-work').touch()
            until = time.monotonic() + 3
            while not work_stopped() and time.monotonic() < until: time.sleep(.01)
    elif stage == 'restore':
        with FileLock(root / 'restore.lock'):
            with closing(sqlite3.connect(root / 'state.sqlite')) as db, db:
                db.execute('update calls set restores=restores+1')
                if case != 'restore-noeffect': db.execute('update state set value=0')
            (root / 'restore-committed').touch()
            if case == 'crash-window': time.sleep(30)
    else:
        if case == 'hang': time.sleep(10)
        with closing(sqlite3.connect(root / 'state.sqlite')) as db, db:
            value = db.execute('select value from state').fetchone()[0]
        stopped = work_stopped()
        evidence = out / 'observed.json'
        write_json(evidence, {'sqliteValue': value, 'workLocksFree': stopped})
        resources = [{'resourceId': resource, 'ownedWork': 'stopped' if stopped else 'running',
                      'restoration': 'complete' if value == 0 else 'required',
                      'explanation': 'Queried fixture SQLite baseline and probed owned work locks',
                      'artifacts': [{'path': evidence.name, 'sha256': digest(evidence)}]}
                     for resource in r['resources']]
        if case == 'scope': resources = []
        if case == 'flag-only': resources[0]['artifacts'] = []
        if case == 'tamper': evidence.write_text('replaced after hashing')
        write_json(r['output'], {'schemaVersion': 1, 'jobId': c['jobId'], 'attemptId': r['attemptId'],
                               'observationId': 'old' if case == 'stale' else r['observationId'],
                               'resources': resources})
'''

WORK = r'''
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote.common import FileLock
root = Path(sys.argv[2])
with FileLock(root / 'work.lock'):
    (root / 'work-started').touch()
    while not (root / 'stop-work').exists(): time.sleep(.01)
'''


class JobRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_runtime.RuntimeTests()
        self.fixture.setUp()
        self.root = self.fixture.source
        self.spool = self.fixture.spool
        self.processes = []
        with closing(sqlite3.connect(self.root / "state.sqlite")) as db, db:
            db.execute("create table state(value integer)")
            db.execute("insert into state values(0)")
            db.execute("create table calls(actions integer, restores integer)")
            db.execute("insert into calls values(0,0)")
        workload = self.root / "workload.py"
        source = workload.read_text(encoding="utf-8")
        source = source.replace('if sys.argv[2] == "action":', '''if sys.argv[2] == "action":
    import sqlite3
    from contextlib import closing
    with closing(sqlite3.connect(Path(c['target']['workspace']) / 'state.sqlite')) as db, db:
        db.execute('update state set value=value+1')
        db.execute('update calls set actions=actions+1')''')
        workload.write_text(source, encoding="utf-8")
        (self.root / "recover.py").write_text(HOOK, encoding="utf-8")
        s = self.fixture.scenario
        s.update(mutates=True, repeatable=False)
        s["parameters"]["recoveryCase"] = {"type": "string", "default": "normal"}
        s["files"].append("recover.py")
        s["commands"]["cleanup"] = ["{python}", "-c", "raise RuntimeError('fixture cleanup failed')"]
        s["recovery"] = {"schemaVersion": 1, "operations": ["write-data"], "repeatableActions": True,
                         **{name: ["{python}", "{input}/recover.py", "{runtime}", name]
                            for name in ("inspect", "quiesce", "restore")}}
        self.target = self.fixture.profile["targets"]["fixture"]
        self.target["allowedOperations"].append("write-data")
        write_json(self.spool / "profile.json", self.fixture.profile)

    def tearDown(self):
        (self.root / "stop-work").touch()
        for p in self.processes:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=10)
            if p.stderr: p.stderr.close()
        self.fixture.tearDown()

    def failed_measurement(self, case="normal"):
        request, package = self.fixture.package(values={"recoveryCase": case}, operations=["measure", "write-data"])
        state, result = self.fixture.execute(package)
        self.assertEqual("needs-attention", state["status"], state)
        self.assertTrue(result["cleanupErrors"])
        self.assertEqual((1, 1, 0), self.data())
        return recovery_job.create_plan(self.spool, "one")

    def data(self):
        with closing(sqlite3.connect(self.root / "state.sqlite")) as db, db:
            value = db.execute("select value from state").fetchone()[0]
            actions, restores = db.execute("select actions,restores from calls").fetchone()
        return value, actions, restores

    def run_plan(self, plan):
        return recovery_job.run(self.spool, "one", plan["planId"])

    def start_work(self):
        p = subprocess.Popen([sys.executable, "-X", "utf8", "-c", WORK, str(test_runtime.RUNTIME), str(self.root)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(p)
        self.wait_file(self.root / "work-started")
        return p

    def wait_file(self, path):
        until = time.monotonic() + 10
        while not path.exists():
            if time.monotonic() > until: self.fail("Missing signal: " + str(path))
            time.sleep(.02)

    def test_live_inspection_restores_state_without_replaying_measurement(self):
        plan = self.failed_measurement()
        original = (self.spool / "runs/one/result.json").read_bytes()
        jobs.cancel(self.spool, "one")  # Original cancellation is not a new recovery cancellation.
        result = self.run_plan(plan)
        self.assertTrue(result["baseReleased"])
        self.assertEqual((0, 1, 1), self.data())
        self.assertEqual(original, (self.spool / "runs/one/result.json").read_bytes())
        state = execution.execute_job(self.spool, "one", self.fixture.profile)
        self.assertEqual("needs-attention", state["status"])
        self.assertEqual("completed", state["recovery"]["status"])
        # A lost completion response can be reconciled using the same plan.
        self.assertTrue(self.run_plan(plan)["baseReleased"])
        self.assertEqual((0, 1, 1), self.data())
        output = Path(result["output"])
        self.assertEqual(["inspect", "restore", "inspect"], [s["name"] for s in read_json(output / "progress.json")])
        inventory = transport.endpoint(self.spool, {"operation": "results", "id": "one"})
        self.assertTrue(any("recovery/" in f["path"] for f in inventory["files"]))
        self.assertFalse(any(f["path"].endswith("context.json") for f in inventory["files"]))

    def test_owned_work_is_quiesced_before_restoration(self):
        plan = self.failed_measurement()
        process = self.start_work()
        result = self.run_plan(plan)
        process.wait(timeout=5)
        self.assertEqual(0, process.returncode)
        steps = read_json(Path(result["output"]) / "progress.json")
        self.assertEqual(["inspect", "quiesce", "inspect", "restore", "inspect"], [s["name"] for s in steps])
        self.assertEqual((0, 1, 1), self.data())

    def test_uncertain_quiescence_never_starts_restoration(self):
        plan = self.failed_measurement("quiesce-noeffect")
        process = self.start_work()
        with self.assertRaisesRegex(WorkError, "OWNED_WORK_UNPROVEN"):
            self.run_plan(plan)
        self.assertIsNone(process.poll())
        self.assertEqual((1, 1, 0), self.data())

    def test_hook_exit_zero_does_not_prove_restoration(self):
        plan = self.failed_measurement("restore-noeffect")
        with self.assertRaisesRegex(WorkError, "FINAL_STATE_UNPROVEN"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 1), self.data())
        records = access.Coordinator(plan["coordinator"]).snapshot()
        self.assertEqual("needs-attention", records[0]["status"])

    def test_stale_observation_does_not_authorize_restore(self):
        plan = self.failed_measurement("stale")
        with self.assertRaisesRegex(WorkError, "OBSERVATION_STALE"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    def test_partial_scope_is_rejected(self):
        plan = self.failed_measurement("scope")
        with self.assertRaisesRegex(WorkError, "SCOPE_MISMATCH"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    def test_a_success_flag_without_evidence_cannot_release(self):
        plan = self.failed_measurement("flag-only")
        with self.assertRaisesRegex(WorkError, "EVIDENCE_REQUIRED"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    def test_changed_observation_artifact_is_rejected(self):
        plan = self.failed_measurement("tamper")
        with self.assertRaisesRegex(WorkError, "EVIDENCE_CHANGED"):
            self.run_plan(plan)

    def test_original_inputs_cannot_be_replaced_after_plan(self):
        plan = self.failed_measurement()
        (self.spool / "jobs/one/input/recover.py").write_text("print('replacement')", encoding="utf-8")
        with self.assertRaisesRegex(WorkError, "HASH_MISMATCH"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    def test_changed_target_is_rejected_before_hooks(self):
        plan = self.failed_measurement()
        profile = read_json(self.spool / "profile.json")
        profile["targets"]["fixture"]["sourceIdentity"] = "different"
        write_json(self.spool / "profile.json", profile)
        with self.assertRaisesRegex(WorkError, "ORIGINAL_INPUTS_CHANGED"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    def test_remote_request_is_queued_and_worker_executes_it_once(self):
        plan = self.failed_measurement()
        request = {"operation": "recover", "id": "one", "planId": plan["planId"]}
        self.assertEqual("recovery-queued", transport.endpoint(self.spool, request)["status"])
        self.assertEqual((1, 1, 0), self.data())
        worker = subprocess.run([sys.executable, "-X", "utf8", str(test_runtime.RUNTIME / "remote_work.py"),
                                 "worker", "--spool", str(self.spool), "--once"], capture_output=True, timeout=20)
        self.assertEqual(0, worker.returncode, worker.stderr.decode("utf-8"))
        self.assertEqual((0, 1, 1), self.data())
        transport.endpoint(self.spool, request)
        recovery_job.run_queued(self.spool)
        self.assertEqual((0, 1, 1), self.data())

    def test_cancelled_recovery_request_never_runs_hooks(self):
        plan = self.failed_measurement()
        recovery_job.enqueue(self.spool, "one", plan["planId"])
        recovery_job.cancel(self.spool, "one", plan["planId"])
        recovery_job.run_queued(self.spool)
        self.assertEqual((1, 1, 0), self.data())
        self.assertEqual("cancelled", jobs.status(self.spool, "one")["recovery"]["status"])
        # A cancelled plan remains immutable; a freshly inspected plan has its
        # own cancellation identity even when the original ticket did not change.
        fresh = recovery_job.create_plan(self.spool, "one")
        self.assertNotEqual(plan["planId"], fresh["planId"])
        self.assertTrue(self.run_plan(fresh)["baseReleased"])
        self.assertEqual((0, 1, 1), self.data())

    def test_missing_adapter_keeps_existing_measurement_support_but_blocks_recovery(self):
        del self.fixture.scenario["recovery"]
        _, package = self.fixture.package(operations=["measure", "write-data"])
        state, _ = self.fixture.execute(package)
        self.assertEqual("needs-attention", state["status"])
        with self.assertRaisesRegex(WorkError, "RECOVERY_ADAPTER_REQUIRED"):
            recovery_job.create_plan(self.spool, "one")
        self.assertEqual((1, 1, 0), self.data())

    def test_recovery_hook_has_a_bounded_deadline(self):
        self.fixture.scenario["phaseTimeoutSeconds"] = {"cleanup": .4}
        plan = self.failed_measurement("hang")
        with self.assertRaisesRegex(WorkError, "TIMEOUT"):
            self.run_plan(plan)
        self.assertEqual((1, 1, 0), self.data())

    @unittest.skipUnless(os.name == "nt", "Windows owned-job crash containment")
    def test_crash_after_restore_commit_is_inspected_without_repeating_restore(self):
        plan = self.failed_measurement("crash-window")
        process = subprocess.Popen([sys.executable, "-X", "utf8", str(test_runtime.RUNTIME / "remote_work.py"),
                                    "recover", "--spool", str(self.spool), "--id", "one", "--plan-id", plan["planId"]],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        self.wait_file(self.root / "restore-committed")
        process.kill(); process.wait(timeout=5)
        fresh = recovery_job.create_plan(self.spool, "one")
        self.assertNotEqual(plan["planId"], fresh["planId"])
        result = self.run_plan(fresh)
        self.assertTrue(result["baseReleased"])
        self.assertEqual((0, 1, 1), self.data())
        self.assertEqual(["inspect"], [s["name"] for s in read_json(Path(result["output"]) / "progress.json")])

    def test_contract_cannot_expand_authorization_or_replay_non_idempotent_cleanup(self):
        self.fixture.scenario["recovery"]["repeatableActions"] = False
        with self.assertRaisesRegex(WorkError, "IDEMPOTENT_ACTIONS_REQUIRED"):
            self.fixture.package(operations=["measure", "write-data"])
        self.fixture.scenario["recovery"]["repeatableActions"] = True
        self.fixture.scenario["recovery"]["operations"].append("update")
        with self.assertRaisesRegex(WorkError, "RECOVERY_OPERATION_NOT_AUTHORIZED"):
            self.fixture.package(operations=["measure", "write-data"])


if __name__ == "__main__":
    unittest.main()
