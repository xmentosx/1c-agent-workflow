"""Multi-process admission regressions; these do not claim live SMB/1C proof."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote.access import Coordinator, Lease, binding, target_access
from itl_remote.common import WorkError, read_json, write_json


CHILD = r'''
import json, os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote.access import Lease
from itl_remote.common import read_json, write_json
config = read_json(sys.argv[2]); out = Path(config['output'])
def waiting(record):
    write_json(out / 'waiting.json', record)
try:
    with Lease(config['root'], config['bases'], {'jobId': config['name'], 'workspace': str(out)},
               timeout=config.get('timeout', 5), cancelled=lambda: (out / 'cancel').exists(),
               progress=waiting, inherited=config.get('inherited')) as lease:
        write_json(out / 'acquired.json', {'ticket': lease.record['ticket'], 'proof': lease.proof(), 'wait': lease.wait_seconds})
        if config.get('crash'):
            os._exit(19)
        if config.get('hold'):
            while not (out / 'release').exists(): time.sleep(.02)
        if config.get('cleanupError'):
            lease.release(cleanup_errors=['restore failed'])
    write_json(out / 'done.json', {'status': 'released'})
except Exception as error:
    write_json(out / 'done.json', {'error': str(error)})
'''


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL общая очередь ")
        self.root = Path(self.temp.name)
        self.coordinator = self.root / "координатор баз"
        self.base = {"kind": "server", "path": "server:1541/test"}
        self.other = {"kind": "server", "path": "server:1541/other"}
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            process.stderr.close()
        self.temp.cleanup()

    def child(self, name, **options):
        out = self.root / ("проект " + name)
        out.mkdir()
        config = {"root": str(self.coordinator), "bases": [self.base], "name": name, "output": str(out), **options}
        path = out / "request.json"
        write_json(path, config)
        process = subprocess.Popen([sys.executable, "-X", "utf8", "-c", CHILD, str(RUNTIME), str(path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        return out, process

    def wait_file(self, path):
        deadline = time.monotonic() + 10
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail("Missing signal: " + str(path))
            time.sleep(.02)
        return read_json(path)

    def release(self, out, process):
        (out / "release").touch()
        process.wait(timeout=10)
        result = self.wait_file(out / "done.json")
        self.assertNotIn("error", result, result)

    def test_different_projects_wait_in_order_for_the_same_database(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", hold=True)
        waiting = self.wait_file(b / "waiting.json")
        self.assertEqual("A", waiting["blockers"][0]["owner"]["jobId"])
        c, pc = self.child("C", hold=True)
        self.wait_file(c / "waiting.json")
        self.assertFalse((b / "acquired.json").exists())
        self.release(a, pa)
        self.wait_file(b / "acquired.json")
        self.assertFalse((c / "acquired.json").exists())
        self.release(b, pb)
        self.wait_file(c / "acquired.json")
        self.release(c, pc)
        self.assertEqual([], Coordinator(self.coordinator).snapshot())

    def test_unrelated_database_does_not_wait_for_a_busy_database(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", bases=[self.other])
        self.assertEqual("released", self.wait_file(b / "done.json")["status"])
        self.assertIsNone(pa.poll())
        self.release(a, pa)

    def test_legacy_parent_cannot_admit_a_new_untracked_child(self):
        with Lease(self.coordinator, [self.base], {"jobId": "legacy-parent"}) as parent:
            path = self.coordinator / "tickets" / (parent.record["ticket"] + ".json")
            record = read_json(path)
            record.pop("participantProtocol")
            write_json(path, record)
            legacy_proof = {"coordinator": str(self.coordinator), "ticket": record["ticket"], "token": record["token"]}
            with self.assertRaisesRegex(WorkError, "INHERITANCE_PROTOCOL_UNSUPPORTED"):
                with Lease(self.coordinator, [self.base], {}, inherited=legacy_proof):
                    self.fail("legacy parent cannot preserve child participation")

    def test_new_proof_is_incompatible_with_legacy_untracked_inheritance(self):
        with Lease(self.coordinator, [self.base], {}) as parent:
            proof = parent.proof()
            record = read_json(self.coordinator / "tickets" / (parent.record["ticket"] + ".json"))
            # The pre-participant protocol admits only if these two values are
            # equal. A new proof must fail that historical admission condition.
            self.assertNotEqual(record["token"], proof["token"])
            self.assertNotIn(proof["token"], json.dumps(Coordinator(self.coordinator).snapshot()))
            with self.assertRaisesRegex(WorkError, "INHERITANCE_INVALID"):
                with Lease(self.coordinator, [self.base], {}, inherited={**proof, "token": record["token"]}):
                    self.fail("raw legacy token admitted unversioned inheritance")
            with Lease(self.coordinator, [self.base], {}, inherited=proof):
                self.assertEqual(1, len(read_json(self.coordinator / "tickets" / (parent.record["ticket"] + ".json"))["participants"]))

    def test_registered_connection_aliases_share_one_queue(self):
        alias = {"kind": "server", "path": "192.0.2.10:1541/test"}
        Coordinator(self.coordinator).register("shared-test", [self.base, alias])
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", bases=[alias])
        self.wait_file(b / "waiting.json")
        self.release(a, pa)
        self.assertEqual("released", self.wait_file(b / "done.json")["status"])

    def test_registration_cannot_split_an_existing_waiting_or_running_identity(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        with self.assertRaisesRegex(WorkError, "REGISTRATION_BUSY"):
            Coordinator(self.coordinator).register("replacement", [self.base])
        self.release(a, pa)
        Coordinator(self.coordinator).register("replacement", [self.base])
        with self.assertRaisesRegex(WorkError, "BINDING_CONFLICT"):
            Coordinator(self.coordinator).register("different", [self.base])

    def test_cancelled_waiter_does_not_run_or_block_next_waiter(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B")
        self.wait_file(b / "waiting.json")
        (b / "cancel").touch()
        self.assertEqual("INFOBASE_ACCESS_CANCELLED", self.wait_file(b / "done.json")["error"])
        self.assertFalse((b / "acquired.json").exists())
        c, pc = self.child("C")
        self.wait_file(c / "waiting.json")
        self.release(a, pa)
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])

    def test_wait_timeout_does_not_run_operation(self):
        a, pa = self.child("A", hold=True)
        acquired = self.wait_file(a / "acquired.json")
        b, pb = self.child("B", timeout=.15)
        error = self.wait_file(b / "done.json")["error"]
        code, payload = error.split(": ", 1)
        self.assertEqual("INFOBASE_ACCESS_WAIT_TIMEOUT", code)
        details = json.loads(payload)
        self.assertFalse(details["requestExecuted"])
        self.assertEqual(acquired["ticket"], details["blockers"][0]["ticket"])
        self.assertEqual("A", details["blockers"][0]["owner"]["jobId"])
        self.assertEqual("access-status", details["blockers"][0]["nextAction"]["command"])
        self.assertNotIn(acquired["proof"]["token"], error)
        self.assertFalse((b / "acquired.json").exists())
        self.assertIsNone(pa.poll())
        c, pc = self.child("C", bases=[self.other])
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])
        self.release(a, pa)
        d, pd = self.child("D")
        self.assertEqual("released", self.wait_file(d / "done.json")["status"])

    def test_crashed_waiter_can_be_skipped_because_it_was_never_admitted(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B")
        self.wait_file(b / "waiting.json")
        pb.kill(); pb.wait(timeout=5)
        self.release(a, pa)
        c, pc = self.child("C")
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])
        self.assertFalse((b / "acquired.json").exists())

    def test_crashed_owner_blocks_replay_even_after_os_released_its_lock(self):
        a, pa = self.child("A", crash=True)
        acquired = self.wait_file(a / "acquired.json"); pa.wait(timeout=5)
        b, pb = self.child("B")
        error = self.wait_file(b / "done.json")["error"]
        code, payload = error.split(": ", 1)
        self.assertEqual("INFOBASE_ACCESS_RECOVERY_REQUIRED", code)
        details = json.loads(payload)
        self.assertFalse(details["requestExecuted"])
        self.assertEqual(str(self.coordinator), details["coordinator"])
        action = details["blockers"][0]["nextAction"]
        self.assertEqual("access-recovery-plan", action["command"])
        self.assertEqual(acquired["ticket"], action["ticket"])
        self.assertNotIn(acquired["proof"]["token"], error)
        self.assertFalse((b / "acquired.json").exists())
        records = Coordinator(self.coordinator).snapshot()
        self.assertEqual("needs-attention", records[0]["status"])
        self.assertNotIn("token", records[0])
        c, pc = self.child("C", bases=[self.other])
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])

    def test_failed_cleanup_keeps_database_unavailable(self):
        a, pa = self.child("A", cleanupError=True)
        self.wait_file(a / "done.json"); pa.wait(timeout=5)
        b, pb = self.child("B")
        self.assertIn("INFOBASE_ACCESS_RECOVERY_REQUIRED", self.wait_file(b / "done.json")["error"])

    def test_nested_child_inherits_exact_ownership_without_reacquiring(self):
        a, pa = self.child("A", hold=True)
        proof = self.wait_file(a / "acquired.json")["proof"]
        b, pb = self.child("B", inherited=proof)
        acquired = self.wait_file(b / "acquired.json")
        self.assertEqual(proof["ticket"], acquired["ticket"])
        self.assertEqual("released", self.wait_file(b / "done.json")["status"])
        self.assertEqual("running", Coordinator(self.coordinator).snapshot()[0]["status"])
        self.release(a, pa)

    def test_inherited_ownership_cannot_add_a_database_or_use_wrong_token(self):
        a, pa = self.child("A", hold=True)
        proof = self.wait_file(a / "acquired.json")["proof"]
        b, pb = self.child("B", inherited=proof, bases=[self.other])
        self.assertIn("INHERITANCE_INVALID", self.wait_file(b / "done.json")["error"])
        proof["token"] = "wrong"
        c, pc = self.child("C", inherited=proof)
        self.assertIn("INHERITANCE_INVALID", self.wait_file(c / "done.json")["error"])
        self.release(a, pa)

    def test_multi_database_admission_is_atomic_and_order_independent(self):
        a, pa = self.child("A", bases=[self.other], hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", bases=[self.base, self.other], hold=True)
        self.wait_file(b / "waiting.json")
        c, pc = self.child("C", bases=[self.other, self.base])
        self.wait_file(c / "waiting.json")
        self.release(a, pa)
        self.wait_file(b / "acquired.json")
        self.assertFalse((c / "acquired.json").exists())
        self.release(b, pb)
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])

    def test_local_paths_on_different_hosts_are_not_assumed_to_be_one_database(self):
        path = str(self.root / "локальная база")
        self.assertNotEqual(binding({"kind": "file", "path": path, "host": "A"}),
                            binding({"kind": "file", "path": path, "host": "B"}))
        self.assertEqual(binding(self.base), binding({"kind": "server", "path": "SERVER:1541\\test/"}))

    def test_zero_wait_allows_immediate_admission_and_invalid_budget_is_rejected(self):
        with Lease(self.coordinator, [self.base], {"jobId": "A"}, timeout=0):
            pass
        for value in (-1, float("nan"), float("inf"), True, 86401):
            with self.assertRaisesRegex(WorkError, "TIMEOUT_INVALID"):
                Lease(self.coordinator, [self.base], {}, timeout=value)

    def test_unconfigured_authority_does_not_claim_cross_host_coordination(self):
        self.assertEqual("execution-host-only", target_access({"workspace": str(self.root)})["scope"])


if __name__ == "__main__":
    unittest.main()
