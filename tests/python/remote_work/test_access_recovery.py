"""Recovery ownership and live verifier boundaries; no SMB/1C qualification."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from test_access import CHILD, RUNTIME
from itl_remote.access import Coordinator, Lease
from itl_remote.access_recovery import Recovery, VerifiedRecovery, plan
from itl_remote.common import FileLock, WorkError, read_json, write_json


RECOVER = r'''
import os, sys
sys.path.insert(0, sys.argv[1])
from itl_remote.access_recovery import Recovery, plan
from itl_remote.common import read_json, write_json
c = read_json(sys.argv[2])
p = plan(c['root'], c['ticket'])
with Recovery(c['root'], c['ticket'], p['revision'], {'jobId': 'recovery-child'}) as owner:
    write_json(c['output'], {'attempt': owner.attempt})
    os._exit(23)
'''


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ITL восстановление очереди ")
        self.root = Path(self.temp.name)
        self.coordinator = self.root / "общие базы"
        self.base = {"kind": "server", "path": "server:1541/test"}
        self.other = {"kind": "server", "path": "server:1541/manager"}
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            process.stderr.close()
        self.temp.cleanup()

    def wait_file(self, path):
        deadline = time.monotonic() + 10
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail("Missing signal: " + str(path))
            time.sleep(.02)
        return read_json(path)

    def child(self, name, **options):
        out = self.root / ("проект " + name)
        out.mkdir()
        path = out / "request.json"
        write_json(path, {"root": str(self.coordinator), "bases": [self.base],
                          "name": name, "output": str(out), **options})
        process = subprocess.Popen([sys.executable, "-X", "utf8", "-c", CHILD, str(RUNTIME), str(path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        return out, process

    def orphan(self, **options):
        out, process = self.child("original", crash=True, **options)
        acquired = self.wait_file(out / "acquired.json")
        process.wait(timeout=10)
        self.assertEqual(19, process.returncode)
        return acquired["proof"]

    def recovery(self, ticket, **options):
        p = plan(self.coordinator, ticket)
        return Recovery(self.coordinator, ticket, p["revision"], {"jobId": "reconcile"}, **options)

    def verified(self, operation):
        # This fixture's workload is only the owning Python process. Its crash
        # is observed before recovery; it has no 1C process or restoration duty.
        self.assertTrue(all(p.poll() is not None for p in self.processes[:1]))
        return VerifiedRecovery(tuple(operation["resources"]),
                                {"fixture": "owner-only; observed terminated; no database mutation"})

    def test_plan_is_read_only_and_contains_no_private_token(self):
        proof = self.orphan()
        path = self.coordinator / "tickets" / (proof["ticket"] + ".json")
        before = path.read_bytes()
        p = plan(self.coordinator, proof["ticket"])
        self.assertEqual(before, path.read_bytes())
        self.assertNotIn(proof["token"], json.dumps(p))
        self.assertFalse(p["automaticReplay"])
        self.assertEqual(2, len(p["requirements"]))

    def test_live_owner_cannot_be_recovered(self):
        out, process = self.child("original", hold=True)
        proof = self.wait_file(out / "acquired.json")["proof"]
        with self.assertRaisesRegex(WorkError, "RECOVERY_OWNER_LIVE"):
            plan(self.coordinator, proof["ticket"])
        self.assertIsNone(process.poll())
        self.assertEqual("running", Coordinator(self.coordinator).snapshot()[0]["status"])

    def test_recovery_preserves_original_owner_and_blocks_stale_proof(self):
        proof = self.orphan()
        with self.recovery(proof["ticket"]) as recovery:
            current = Coordinator(self.coordinator).snapshot()[0]
            self.assertEqual("recovering", current["status"])
            self.assertEqual("original", current["owner"]["jobId"])
            self.assertEqual("reconcile", current["recoveryAttempts"][-1]["owner"]["jobId"])
            with self.assertRaisesRegex(WorkError, "INHERITANCE_INVALID"):
                with Lease(self.coordinator, [self.base], {}, inherited=proof):
                    self.fail("An original action must not inherit recovery ownership")
            with self.assertRaisesRegex(WorkError, "RECOVERY_OWNER_LIVE"):
                plan(self.coordinator, proof["ticket"])
            current_proof = recovery.proof()
            with self.assertRaisesRegex(WorkError, "INHERITANCE_INVALID"):
                with Lease(self.coordinator, [self.base], {}, inherited=current_proof):
                    self.fail("An ordinary operation must not inherit a recovery token")
            with Lease(self.coordinator, [self.base], {}, inherited=current_proof, purpose="recovery") as nested:
                self.assertEqual(current_proof, nested.proof())
        record = Coordinator(self.coordinator).snapshot()[0]
        self.assertEqual("needs-attention", record["status"])
        self.assertEqual("incomplete", record["recoveryAttempts"][-1]["status"])

    def test_stale_plan_cannot_claim_a_new_recovery_attempt(self):
        proof = self.orphan()
        p = plan(self.coordinator, proof["ticket"])
        with Recovery(self.coordinator, proof["ticket"], p["revision"], {}):
            with self.assertRaisesRegex(WorkError, "PLAN_STALE"):
                with Recovery(self.coordinator, proof["ticket"], p["revision"], {}):
                    self.fail("Second recovery admitted")
        with self.assertRaisesRegex(WorkError, "PLAN_STALE"):
            with Recovery(self.coordinator, proof["ticket"], p["revision"], {}):
                self.fail("Old plan reused after an incomplete attempt")

    def test_old_owner_cannot_overwrite_a_recovery_with_its_late_release(self):
        proof = self.orphan()
        path = self.coordinator / "tickets" / (proof["ticket"] + ".json")
        old_owner = Lease(self.coordinator, [self.base], {})
        old_owner.record = read_json(path)
        # Model an executor resuming with stale local state after it lost its
        # authority handle. The stale object must not overwrite a rotated token.
        old_owner.live_lock = FileLock(self.root / "stale-local-handle")
        old_owner.live_lock.__enter__()
        with self.recovery(proof["ticket"]) as recovery:
            before = path.read_bytes()
            with self.assertRaisesRegex(WorkError, "RELEASE_OWNERSHIP_CHANGED"):
                old_owner.release()
            self.assertEqual(before, path.read_bytes())
            self.assertIsNone(old_owner.live_lock)
            recovery.complete(self.verified)

    def test_live_verification_releases_waiters_in_order_without_replay(self):
        proof = self.orphan()
        with self.recovery(proof["ticket"]) as recovery:
            b, pb = self.child("B", hold=True)
            waiting = self.wait_file(b / "waiting.json")
            self.assertEqual("recovering", waiting["blockers"][0]["status"])
            c, pc = self.child("C")
            self.wait_file(c / "waiting.json")
            self.assertFalse((b / "acquired.json").exists())
            unrelated, pu = self.child("unrelated", bases=[self.other])
            self.assertEqual("released", self.wait_file(unrelated / "done.json")["status"])
            result = recovery.complete(self.verified)
            self.assertEqual("released", result["status"])
            self.assertNotIn(proof["token"], json.dumps(result))
            self.assertEqual("completed", result["recoveryAttempts"][-1]["status"])
        self.wait_file(b / "acquired.json")
        self.assertFalse((c / "acquired.json").exists())
        (b / "release").touch()
        self.assertEqual("released", self.wait_file(b / "done.json")["status"])
        self.assertEqual("released", self.wait_file(c / "done.json")["status"])
        self.assertEqual([], Coordinator(self.coordinator).snapshot())
        self.assertEqual(19, self.processes[0].returncode)

    def test_unproven_or_partial_verification_never_releases_resource_set(self):
        proof = self.orphan(bases=[self.base, self.other])
        bad = [True, {"passed": True}, VerifiedRecovery((), {"fixture": True}),
               VerifiedRecovery(("foreign",), {"fixture": True})]
        for response in bad:
            with self.subTest(response=response):
                with self.assertRaisesRegex(WorkError, "VERIFICATION_INVALID"):
                    with self.recovery(proof["ticket"]) as recovery:
                        recovery.complete(lambda _: response)
                self.assertEqual("needs-attention", Coordinator(self.coordinator).snapshot()[0]["status"])
        with self.recovery(proof["ticket"]) as recovery:
            resources = tuple(recovery.record["resources"])
            with self.assertRaisesRegex(WorkError, "REGISTRATION_BUSY"):
                Coordinator(self.coordinator).register("split", [self.base])
            with self.assertRaisesRegex(WorkError, "VERIFICATION_INVALID"):
                recovery.complete(lambda _: VerifiedRecovery(resources[:1], {"fixture": True}))
            recovery.complete(self.verified)

    def test_verifier_failure_keeps_attention_and_audit_of_both_attempts(self):
        proof = self.orphan()
        def failed(_):
            raise WorkError("OWNED_WORK_STILL_RUNNING")
        with self.assertRaisesRegex(WorkError, "OWNED_WORK_STILL_RUNNING"):
            with self.recovery(proof["ticket"]) as recovery:
                recovery.complete(failed)
        with self.recovery(proof["ticket"]) as recovery:
            result = recovery.complete(self.verified)
        self.assertEqual(["failed", "completed"], [a["status"] for a in result["recoveryAttempts"]])

    def test_cancel_after_verification_does_not_release(self):
        proof = self.orphan()
        cancelled = []
        def verify(record):
            cancelled.append(True)
            return self.verified(record)
        with self.assertRaisesRegex(WorkError, "ACCESS_CANCELLED"):
            with self.recovery(proof["ticket"], cancelled=lambda: bool(cancelled)) as recovery:
                recovery.complete(verify)
        self.assertEqual("needs-attention", Coordinator(self.coordinator).snapshot()[0]["status"])

    def test_recovery_crash_retains_exclusion_and_can_be_reconciled_again(self):
        proof = self.orphan()
        request = self.root / "recovery.json"
        output = self.root / "recovery-started.json"
        write_json(request, {"root": str(self.coordinator), "ticket": proof["ticket"], "output": str(output)})
        process = subprocess.Popen([sys.executable, "-X", "utf8", "-c", RECOVER, str(RUNTIME), str(request)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        self.wait_file(output)
        process.wait(timeout=10)
        self.assertEqual(23, process.returncode)
        b, pb = self.child("blocked")
        self.assertIn("RECOVERY_REQUIRED", self.wait_file(b / "done.json")["error"])
        self.assertFalse((b / "acquired.json").exists())
        with self.recovery(proof["ticket"]) as recovery:
            result = recovery.complete(self.verified)
        self.assertEqual(["interrupted", "completed"], [a["status"] for a in result["recoveryAttempts"]])

    def test_public_cli_produces_plan_without_claiming_or_releasing(self):
        proof = self.orphan()
        result = subprocess.run([sys.executable, "-X", "utf8", str(RUNTIME / "remote_work.py"),
                                 "access-recovery-plan", "--coordinator", str(self.coordinator),
                                 "--ticket", proof["ticket"]], capture_output=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8"))
        output = json.loads(result.stdout)
        self.assertEqual(proof["ticket"], output["ticket"])
        self.assertNotIn(proof["token"], result.stdout.decode("utf-8"))
        self.assertEqual("running", Coordinator(self.coordinator).snapshot()[0]["status"])

    def test_invalid_ticket_cannot_escape_authority(self):
        for ticket in ("../foreign", "", "f" * 32):
            with self.subTest(ticket=ticket), self.assertRaisesRegex(WorkError, "RECOVERY_TICKET_"):
                plan(self.coordinator, ticket)


if __name__ == "__main__":
    unittest.main()
