"""Multi-process admission regressions; these do not claim live SMB/1C proof."""
import ast
import json
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
RUNTIME = REPO / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote import access as access_module
from itl_remote.access import Coordinator, Lease, binding, target_access
from itl_remote.common import FileLock, WorkError, read_json, stamp, write_json


CHILD = r'''
import json, os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from itl_remote.access import Lease
from itl_remote.common import read_json, write_json
config = read_json(sys.argv[2]); out = Path(config['output'])
def waiting(record):
    write_json(out / ('transition-waiting.json' if record.get('status') == 'waiting-for-mode' else 'waiting.json'), record)
try:
    with Lease(config['root'], config['bases'], {'jobId': config['name'], 'workspace': str(out)},
               timeout=config.get('timeout', 5), cancelled=lambda: (out / 'cancel').exists(),
               progress=waiting, inherited=config.get('inherited'), access_mode=config.get('accessMode', 'mutation-exclusive')) as lease:
        write_json(out / 'acquired.json', {'ticket': lease.record['ticket'], 'proof': lease.proof(),
                                           'accessMode': lease.access_mode, 'wait': lease.wait_seconds})
        if config.get('transition'):
            result = lease.transition(config['transition'])
            write_json(out / 'transitioned.json', result)
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

    def old_runtime(self):
        runtime = self.root / "frozen-a4a86d6-runtime"
        package = runtime / "itl_remote"
        if not package.exists():
            package.mkdir(parents=True)
            for name in ("__init__.py", "common.py", "access.py"):
                payload = subprocess.check_output([
                    "git", "-C", str(REPO), "show",
                    "a4a86d6:.agents/skills/itl-remote-runner/scripts/itl_remote/" + name,
                ])
                (package / name).write_bytes(payload)
        return runtime

    def old_child(self, name, **options):
        self.assertIn(options.get("accessMode"), ("shared-read", "test-run", "exclusive"))
        out = self.root / ("старый процесс " + name)
        out.mkdir()
        config = {"root": str(self.coordinator), "bases": [self.base], "name": name,
                  "output": str(out), **options}
        path = out / "request.json"
        write_json(path, config)
        process = subprocess.Popen([sys.executable, "-X", "utf8", "-c", CHILD,
                                    str(self.old_runtime()), str(path)],
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

    def legacy_record(self, ticket, sequence, status, base=None):
        coordinator = Coordinator(self.coordinator)
        record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                  "token": "0" * 64, "sequence": sequence,
                  "resources": coordinator.resources([base or self.base]),
                  "accessMode": "exclusive", "status": status,
                  "createdAt": "2026-01-01T00:00:00+00:00", "owner": {"jobId": ticket[:4]}}
        if status in ("released", "cancelled"):
            record["finishedAt"] = "2026-01-01T00:01:00+00:00"
        if status == "needs-attention":
            record["reason"] = "fixture recovery debt"
        path = self.coordinator / "tickets" / (ticket + ".json")
        write_json(path, record)
        return record

    def test_different_projects_wait_in_order_for_the_same_database(self):
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", hold=True)
        waiting = self.wait_file(b / "waiting.json")
        self.assertEqual("mutation-exclusive", waiting["accessMode"])
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

    def test_roctup_read_and_one_functional_test_share_the_database(self):
        reader, reader_process = self.child("reader", hold=True, accessMode="shared-read")
        self.wait_file(reader / "acquired.json")
        tests, tests_process = self.child("tests", hold=True, accessMode="functional-test")
        self.wait_file(tests / "acquired.json")
        another, another_process = self.child("other-tests", timeout=0, accessMode="functional-test")
        result = self.wait_file(another / "done.json")
        self.assertIn("WAIT_TIMEOUT", result["error"])
        self.assertIsNone(reader_process.poll())
        self.assertIsNone(tests_process.poll())
        self.release(tests, tests_process)
        self.release(reader, reader_process)

    def test_new_dual_mode_records_are_rolling_compatible_with_a4a86d6_reader(self):
        cases = (
            ("shared-read", "shared-read", (("test-run", True),)),
            ("functional-test", "test-run", (("shared-read", True), ("test-run", False))),
            ("measurement-exclusive", "exclusive", (("shared-read", False),)),
            ("mutation-exclusive", "exclusive", (("shared-read", False),)),
        )
        for canonical, projection, old_attempts in cases:
            with self.subTest(canonical=canonical):
                current, current_process = self.child("new-" + canonical, hold=True, accessMode=canonical)
                acquired = self.wait_file(current / "acquired.json")
                record = read_json(self.coordinator / "tickets" / (acquired["ticket"] + ".json"))
                self.assertEqual(projection, record["accessMode"])
                self.assertEqual(canonical, record["accessModeV2"])
                self.assertNotIn("accessModeV2", json.dumps(Coordinator(self.coordinator).snapshot()))
                for number, (old_mode, coexists) in enumerate(old_attempts):
                    old, old_process = self.old_child(
                        f"{canonical}-{number}", accessMode=old_mode, timeout=0)
                    result = self.wait_file(old / "done.json")
                    if coexists:
                        self.assertEqual("released", result.get("status"), result)
                    else:
                        self.assertIn("WAIT_TIMEOUT", result.get("error", ""), result)
                    old_process.wait(timeout=10)
                self.release(current, current_process)

    def test_old_reader_honors_a_new_pending_mutation_projection(self):
        reader, reader_process = self.child("new-reader", hold=True, accessMode="shared-read")
        self.wait_file(reader / "acquired.json")
        tests, tests_process = self.child(
            "new-functional", hold=True, accessMode="functional-test", transition="mutation-exclusive")
        acquired = self.wait_file(tests / "acquired.json")
        self.wait_file(tests / "transition-waiting.json")
        record = read_json(self.coordinator / "tickets" / (acquired["ticket"] + ".json"))
        self.assertEqual("exclusive", record["requestedAccessMode"])
        self.assertEqual("mutation-exclusive", record["requestedAccessModeV2"])
        old, old_process = self.old_child("pending-reader", accessMode="shared-read", timeout=0)
        result = self.wait_file(old / "done.json")
        self.assertIn("WAIT_TIMEOUT", result.get("error", ""), result)
        old_process.wait(timeout=10)
        self.release(reader, reader_process)
        self.wait_file(tests / "transitioned.json")
        self.release(tests, tests_process)

    def test_mutation_transition_blocks_new_readers_without_a_second_ticket(self):
        reader, reader_process = self.child("reader", hold=True, accessMode="shared-read")
        self.wait_file(reader / "acquired.json")
        tests, tests_process = self.child("tests", hold=True, accessMode="functional-test", transition="mutation-exclusive")
        acquired = self.wait_file(tests / "acquired.json")
        waiting = self.wait_file(tests / "transition-waiting.json")
        self.assertEqual(acquired["ticket"], waiting["ticket"])
        later, later_process = self.child("later-reader", hold=True, accessMode="shared-read")
        blocker = self.wait_file(later / "waiting.json")["blockers"][0]
        self.assertEqual("mutation-exclusive", blocker["requestedAccessMode"])
        self.release(reader, reader_process)
        self.wait_file(tests / "transitioned.json")
        self.assertFalse((later / "acquired.json").exists())
        self.release(tests, tests_process)
        self.wait_file(later / "acquired.json")
        self.release(later, later_process)

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

    def test_inherited_work_cannot_broaden_shared_access_to_mutation(self):
        with Lease(self.coordinator, [self.base], {}, access_mode="shared-read") as parent:
            with self.assertRaisesRegex(WorkError, "INHERITED_MODE_INVALID"):
                with Lease(self.coordinator, [self.base], {}, inherited=parent.proof(), access_mode="mutation-exclusive"):
                    self.fail("shared ownership authorized a mutation child")
            with Lease(self.coordinator, [self.base], {}, inherited=parent.proof(), access_mode="shared-read") as child:
                participant = next(iter(read_json(self.coordinator / "tickets" / (parent.record["ticket"] + ".json"))["participants"].values()))
                self.assertEqual("shared-read", participant["accessMode"])

    def test_compatibility_matrix_is_declarative_symmetric_and_exhaustive(self):
        modes = access_module.NORMALIZED_ACCESS_MODES
        expected = {
            ("shared-read", "shared-read"),
            ("shared-read", "functional-test"),
            ("functional-test", "shared-read"),
        }
        self.assertEqual(set(modes), set(access_module.ACCESS_COMPATIBILITY))
        for first in modes:
            self.assertEqual(set(access_module.ACCESS_COMPATIBILITY[first]),
                             {second for left, second in expected if left == first})
            for second in modes:
                self.assertEqual((first, second) in expected, access_module.compatible(first, second))
                self.assertEqual(access_module.compatible(first, second), access_module.compatible(second, first))

    def test_legacy_modes_are_read_only_aliases_with_fail_closed_exclusive_semantics(self):
        legacy = {"accessMode": "test-run"}
        self.assertEqual("functional-test", access_module.access_mode(legacy))
        self.assertEqual("functional-test", access_module.public(legacy)["accessMode"])
        for legacy in ({"accessMode": "exclusive"}, {}):
            self.assertEqual("legacy-exclusive", access_module.access_mode(legacy))
            self.assertEqual("legacy-exclusive", access_module.public(legacy)["accessMode"])
            self.assertTrue(all(not access_module.compatible("legacy-exclusive", mode)
                                for mode in access_module.NORMALIZED_ACCESS_MODES))
        for legacy in ("test-run", "exclusive", "legacy-exclusive"):
            with self.assertRaisesRegex(WorkError, "MODE_INVALID"):
                Lease(self.coordinator, [self.base], {}, access_mode=legacy)

    def test_v2_modes_require_an_exact_legacy_projection_and_stay_internal(self):
        valid = {"accessMode": "test-run", "accessModeV2": "functional-test"}
        self.assertEqual("functional-test", access_module.access_mode(valid))
        self.assertEqual({"accessMode": "functional-test"}, access_module.public(valid))
        for invalid in (
                {"accessMode": "exclusive", "accessModeV2": "functional-test"},
                {"accessMode": "functional-test", "accessModeV2": "functional-test"},
                {"accessModeV2": "mutation-exclusive"},
                {"accessMode": "exclusive", "accessModeV2": "legacy-exclusive"}):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(WorkError, "MODE_INVALID"):
                access_module.access_mode(invalid)
        with self.assertRaisesRegex(WorkError, "MODE_INVALID"):
            access_module.effective_access_mode({
                "accessMode": "shared-read", "accessModeV2": "shared-read",
                "requestedAccessMode": "test-run", "requestedAccessModeV2": "mutation-exclusive",
            })

    def test_inherited_modes_stay_within_the_root_compatibility_envelope(self):
        expected = {
            "shared-read": {"shared-read"},
            "functional-test": {"shared-read", "functional-test"},
            "measurement-exclusive": set(access_module.ACCESS_MODES),
            "mutation-exclusive": set(access_module.ACCESS_MODES),
            "legacy-exclusive": set(access_module.ACCESS_MODES),
        }
        self.assertEqual(set(expected), set(access_module.INHERITED_MODE_PERMISSIONS))
        for parent, children in expected.items():
            for child in access_module.ACCESS_MODES:
                self.assertEqual(child in children, access_module.permits(parent, child), (parent, child))

    def test_transition_accepts_only_canonical_modes_and_requires_no_active_participant(self):
        with Lease(self.coordinator, [self.base], {}, access_mode="functional-test") as parent:
            for legacy in ("test-run", "exclusive", "legacy-exclusive"):
                with self.assertRaisesRegex(WorkError, "TRANSITION_INVALID"):
                    parent.transition(legacy)
            with Lease(self.coordinator, [self.base], {}, inherited=parent.proof(),
                       access_mode="shared-read"):
                with self.assertRaisesRegex(WorkError, "PARTICIPANTS_ACTIVE"):
                    parent.transition("mutation-exclusive")
            changed = parent.transition("measurement-exclusive")
            self.assertEqual("measurement-exclusive", changed["accessMode"])
            self.assertEqual("measurement-exclusive", Coordinator(self.coordinator).snapshot()[0]["accessMode"])

    def test_registered_connection_aliases_share_one_queue(self):
        alias = {"kind": "server", "path": "192.0.2.10:1541/test"}
        Coordinator(self.coordinator).register("shared-test", [self.base, alias])
        a, pa = self.child("A", hold=True)
        self.wait_file(a / "acquired.json")
        b, pb = self.child("B", bases=[alias])
        self.wait_file(b / "waiting.json")
        self.release(a, pa)
        self.assertEqual("released", self.wait_file(b / "done.json")["status"])

    def test_registered_file_aliases_share_one_queue_across_projects(self):
        canonical = {"kind": "file", "path": str(self.root / "База проекта A")}
        alias = {"kind": "file", "path": str(self.root / "Псевдоним базы проекта B")}
        Coordinator(self.coordinator).register("shared-file-test", [canonical, alias])
        a, pa = self.child("file-A", bases=[canonical], hold=True)
        acquired = self.wait_file(a / "acquired.json")
        b, pb = self.child("file-B", bases=[alias])
        waiting = self.wait_file(b / "waiting.json")
        self.assertEqual(acquired["ticket"], waiting["blockers"][0]["ticket"])
        self.assertEqual("file-A", waiting["blockers"][0]["owner"]["jobId"])
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

    def test_schema_one_migration_archives_terminal_records_and_preserves_sequence(self):
        terminal = self.legacy_record("a" * 32, 7, "released")
        first_active = self.legacy_record("c" * 32, 8, "needs-attention")
        second_active = self.legacy_record("b" * 32, 9, "needs-attention")
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        self.assertEqual({"schemaVersion": 2}, read_json(coordinator.layout_path))
        index = read_json(coordinator.index_path)
        self.assertEqual(10, index["nextSequence"])
        self.assertEqual({first_active["ticket"], second_active["ticket"]}, set(index["entries"]))
        self.assertEqual([8, 9], [record["sequence"] for record in coordinator.records()])
        self.assertEqual(terminal, coordinator.record(terminal["ticket"]))
        self.assertFalse((coordinator.tickets / (terminal["ticket"] + ".json")).exists())
        with Lease(self.coordinator, [self.other], {"jobId": "new"}, timeout=0) as lease:
            self.assertEqual(10, lease.record["sequence"])

    def test_schema_one_migration_restarts_after_every_publication_boundary(self):
        boundaries = ("migration-terminal-archive", "cleanup-debt",
                      "migration-active-index", "migration-layout")
        for boundary in boundaries:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL migration restart ") as root:
                coordinator_path = Path(root) / "координатор баз"
                self.coordinator = coordinator_path
                terminal = self.legacy_record("a" * 32, 7, "released")
                active = self.legacy_record("b" * 32, 9, "needs-attention")
                coordinator = Coordinator(coordinator_path)
                injected = False
                def crash_after_publication(actual):
                    nonlocal injected
                    if actual == boundary and not injected:
                        injected = True
                        raise RuntimeError("injected crash after " + boundary)
                coordinator._published = crash_after_publication
                with self.assertRaisesRegex(RuntimeError, "injected crash"):
                    with coordinator.mutex(time.monotonic() + 5, lambda: False):
                        pass
                restarted = Coordinator(coordinator_path)
                with restarted.mutex(time.monotonic() + 5, lambda: False):
                    pass
                restarted.cleanup(256)
                index = read_json(restarted.index_path)
                self.assertEqual(10, index["nextSequence"])
                self.assertEqual({active["ticket"]}, set(index["entries"]))
                self.assertEqual(terminal, restarted.record(terminal["ticket"]))
                self.assertFalse((restarted.tickets / (terminal["ticket"] + ".json")).exists())
                self.assertEqual({}, restarted._read_cleanup_debt()["items"])

    def test_live_schema_one_owner_defers_migration_and_new_layout_blocks_old_reader(self):
        ticket = "c" * 32
        self.legacy_record(ticket, 1, "running")
        live = FileLock(self.coordinator / "tickets" / (ticket + ".alive"))
        live.__enter__()
        try:
            coordinator = Coordinator(self.coordinator)
            with coordinator.mutex(time.monotonic() + 5, lambda: False):
                self.assertFalse(coordinator.layout_path.exists())
        finally:
            live.__exit__(None, None, None)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            self.assertTrue(coordinator.layout_path.exists())
        with self.assertRaisesRegex(WorkError, "RECORD_INVALID"):
            coordinator._legacy_records()

    def test_terminal_transition_is_repaired_after_index_update_is_interrupted(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            sequence = coordinator.take_sequence()
            record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": "d" * 32,
                      "token": "1" * 64, "sequence": sequence,
                      "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                      "status": "running", "createdAt": "2026-01-01T00:00:00+00:00", "owner": {}}
            coordinator.save(record)
            record.update(status="released", finishedAt="2026-01-01T00:01:00+00:00")
            # Model a crash after the authoritative terminal record write but
            # before archive publication and active-index removal.
            write_json(coordinator.tickets / (record["ticket"] + ".json"), record)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        self.assertNotIn(record["ticket"], read_json(coordinator.index_path)["entries"])
        self.assertEqual("released", coordinator.record(record["ticket"])["status"])

    def test_terminal_transition_restarts_after_every_publication_boundary(self):
        boundaries = ("terminal-active-record", "terminal-archive", "cleanup-debt", "terminal-index")
        for boundary in boundaries:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL terminal restart ") as root:
                coordinator = Coordinator(Path(root) / "координатор баз")
                with coordinator.mutex(time.monotonic() + 5, lambda: False):
                    sequence = coordinator.take_sequence()
                    record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": "d" * 32,
                              "token": "1" * 64, "sequence": sequence,
                              "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                              "status": "running", "createdAt": "2026-01-01T00:00:00+00:00", "owner": {}}
                    coordinator.save(record)
                    record.update(status="released", finishedAt="2026-01-01T00:01:00+00:00")
                    injected = False
                    def crash_after_publication(actual):
                        nonlocal injected
                        if actual == boundary and not injected:
                            injected = True
                            raise RuntimeError("injected crash after " + boundary)
                    coordinator._published = crash_after_publication
                    with self.assertRaisesRegex(RuntimeError, "injected crash"):
                        coordinator.save(record)
                restarted = Coordinator(coordinator.root)
                with restarted.mutex(time.monotonic() + 5, lambda: False):
                    pass
                restarted.cleanup(256)
                self.assertNotIn(record["ticket"], read_json(restarted.index_path)["entries"])
                self.assertEqual(record, restarted.record(record["ticket"]))
                self.assertFalse((restarted.tickets / (record["ticket"] + ".json")).exists())
                self.assertEqual({}, restarted._read_cleanup_debt()["items"])

    def test_cleanup_debt_survives_unlink_publication_crash(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            sequence = coordinator.take_sequence()
            record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": "f" * 32,
                      "token": "3" * 64, "sequence": sequence,
                      "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                      "status": "running", "createdAt": "2026-01-01T00:00:00+00:00", "owner": {}}
            coordinator.save(record)
            record.update(status="released", finishedAt="2026-01-01T00:01:00+00:00")
            coordinator.save(record)
            coordinator._published = lambda boundary: (_ for _ in ()).throw(
                RuntimeError("injected crash after unlink")) if boundary == "cleanup-terminal-record" else None
            with self.assertRaisesRegex(RuntimeError, "injected crash after unlink"):
                coordinator._run_cleanup_locked(limit=1, ticket=record["ticket"])
        restarted = Coordinator(self.coordinator)
        with restarted.mutex(time.monotonic() + 5, lambda: False):
            restarted._run_cleanup_locked(limit=2, ticket=record["ticket"])
        self.assertEqual({}, restarted._read_cleanup_debt()["items"])
        self.assertEqual(record, restarted.record(record["ticket"]))

    def test_alive_sharing_violation_uses_bounded_retry_and_persists_debt(self):
        coordinator = Coordinator(self.coordinator)
        ticket = "9" * 32
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                      "token": "4" * 64, "sequence": coordinator.take_sequence(),
                      "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                      "status": "running", "createdAt": "2026-01-01T00:00:00+00:00", "owner": {}}
            coordinator.save(record)
        live = FileLock(coordinator.tickets / (ticket + ".alive"))
        live.__enter__()
        try:
            with coordinator.mutex(time.monotonic() + 5, lambda: False):
                record.update(status="released", finishedAt="2026-01-01T00:01:00+00:00")
                coordinator.save(record)
                result = coordinator._run_cleanup_locked(limit=2, ticket=ticket, retries=2)
                debt = coordinator._read_cleanup_debt()["items"]
                alive = debt["alive-sidecar|" + ticket]
                self.assertEqual(1, result["remaining"])
                self.assertEqual(1, alive["attempts"])
                self.assertIn("OWNER_BUSY", alive["lastError"])
        finally:
            live.__exit__(None, None, None)
        coordinator.cleanup_alive(ticket)
        self.assertFalse((coordinator.tickets / (ticket + ".alive")).exists())
        self.assertEqual({}, coordinator._read_cleanup_debt()["items"])
        self.assertEqual(record, coordinator.record(ticket))

    def test_alive_cleanup_debt_survives_unlink_publication_crash(self):
        coordinator = Coordinator(self.coordinator)
        ticket = "8" * 32
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                      "token": "5" * 64, "sequence": coordinator.take_sequence(),
                      "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                      "status": "running", "createdAt": "2026-01-01T00:00:00+00:00", "owner": {}}
            coordinator.save(record)
        live = FileLock(coordinator.tickets / (ticket + ".alive"))
        live.__enter__()
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            record.update(status="released", finishedAt="2026-01-01T00:01:00+00:00")
            coordinator.save(record)
            coordinator._run_cleanup_locked(limit=2, ticket=ticket)
        live.__exit__(None, None, None)
        coordinator._published = lambda boundary: (_ for _ in ()).throw(
            RuntimeError("injected crash after alive unlink")) if boundary == "cleanup-alive-sidecar" else None
        with self.assertRaisesRegex(RuntimeError, "injected crash after alive unlink"):
            coordinator.cleanup_alive(ticket)
        self.assertFalse((coordinator.tickets / (ticket + ".alive")).exists())
        restarted = Coordinator(self.coordinator)
        with restarted.mutex(time.monotonic() + 5, lambda: False):
            restarted._run_cleanup_locked(limit=2, ticket=ticket)
        self.assertEqual({}, restarted._read_cleanup_debt()["items"])
        self.assertEqual(record, restarted.record(ticket))

    def test_semantically_invalid_index_always_uses_index_error(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        valid = {"schemaVersion": 2, "nextSequence": 3, "entries": {
            "1" * 32: {"sequence": 1, "resources": ["base-a"]},
            "2" * 32: {"sequence": 2, "resources": ["base-b"]}}}
        invalid = [
            [],
            {**valid, "nextSequence": 2},
            {**valid, "entries": {**valid["entries"], "2" * 32: {"sequence": 1, "resources": ["base-b"]}}},
            {**valid, "entries": {"1" * 32: {"sequence": 1, "resources": ["base-b", "base-a"]}}},
            {**valid, "entries": {"1" * 32: {"sequence": 1, "resources": ["bad resource"]}}},
        ]
        for value in invalid:
            with self.subTest(value=value):
                write_json(coordinator.index_path, value)
                with self.assertRaisesRegex(WorkError, "^INFOBASE_ACCESS_INDEX_INVALID"):
                    coordinator._read_index()

    def test_invalid_legacy_authority_fails_before_any_migration_publication(self):
        cases = ("invalid-resource", "duplicate-resource", "unsorted-resource", "duplicate-sequence")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(prefix="ITL invalid legacy ") as root:
                self.coordinator = Path(root) / "координатор баз"
                terminal = self.legacy_record("a" * 32, 1, "released")
                active = self.legacy_record("b" * 32, 2, "needs-attention")
                path = self.coordinator / "tickets" / (active["ticket"] + ".json")
                if case == "invalid-resource":
                    active["resources"] = ["bad resource"]
                elif case == "duplicate-resource":
                    active["resources"] = ["base-a", "base-a"]
                elif case == "unsorted-resource":
                    active["resources"] = ["base-b", "base-a"]
                else:
                    active["sequence"] = terminal["sequence"]
                write_json(path, active)
                coordinator = Coordinator(self.coordinator)
                with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_(RECORD|MIGRATION)_INVALID"):
                    with coordinator.mutex(time.monotonic() + 5, lambda: False):
                        pass
                self.assertFalse(coordinator.layout_path.exists())
                self.assertFalse(coordinator.index_path.exists())
                self.assertFalse(coordinator._archive_path(terminal["ticket"]).exists())
                self.assertEqual({}, coordinator._read_cleanup_debt()["items"])

    def test_unshipped_monolithic_cleanup_debt_fails_closed_even_beside_sharded_state(self):
        root = self.coordinator
        root.mkdir(parents=True)
        (root / "cleanup-debt").mkdir()
        write_json(root / "cleanup-debt" / "state.json", {"fixture": True})
        write_json(root / "cleanup-debt.json", {"schemaVersion": 1, "items": {}})
        with self.assertRaisesRegex(WorkError, "^INFOBASE_ACCESS_CLEANUP_DEBT_LEGACY_UNSUPPORTED"):
            Coordinator(root)

    def test_corrupt_active_record_blocks_only_its_indexed_resources(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": "e" * 32,
                      "token": "2" * 64, "sequence": coordinator.take_sequence(),
                      "resources": coordinator.resources([self.base]), "accessMode": "exclusive",
                      "status": "needs-attention", "createdAt": "2026-01-01T00:00:00+00:00",
                      "reason": "fixture", "owner": {}}
            coordinator.save(record)
            (coordinator.tickets / (record["ticket"] + ".json")).write_text("{", encoding="utf-8")
        with Lease(self.coordinator, [self.other], {"jobId": "unrelated"}, timeout=0):
            pass
        with self.assertRaisesRegex(WorkError, "RECOVERY_REQUIRED") as blocked:
            with Lease(self.coordinator, [self.base], {"jobId": "blocked"}, timeout=0):
                self.fail("corrupt indexed owner cannot be bypassed")
        self.assertIn("repair the indexed ticket record", str(blocked.exception))
        self.assertNotIn("access-recovery-plan", str(blocked.exception))
        corrupt = next(item for item in coordinator.snapshot() if item["ticket"] == record["ticket"])
        self.assertEqual("legacy-exclusive", corrupt["accessMode"])
        self.assertTrue(corrupt["corruptRecord"])

    def test_hot_path_does_not_read_ten_thousand_corrupt_archive_records(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        archive = coordinator.archive_root / "ff"
        archive.mkdir(parents=True)
        for number in range(10000):
            (archive / (f"{number:032x}.json")).write_text("{", encoding="utf-8")
        archived_reads = []
        original_read = access_module.read_json
        def observed_read(path):
            if coordinator.archive_root in Path(path).parents:
                archived_reads.append(Path(path))
            return original_read(path)
        with mock.patch("itl_remote.access.read_json", side_effect=observed_read):
            with Lease(self.coordinator, [self.base], {"jobId": "active"}, timeout=0) as lease:
                self.assertEqual([lease.record["ticket"]], [record["ticket"] for record in coordinator.snapshot()])
        self.assertEqual([], archived_reads)

    def test_status_with_ten_thousand_terminal_and_ten_active_tickets_is_under_one_second(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            for number in range(10):
                ticket = f"{number + 1:032x}"
                record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                          "token": f"{number + 1:064x}", "sequence": coordinator.take_sequence(),
                          "resources": [f"base-{number}"], "accessMode": "exclusive",
                          "status": "needs-attention", "createdAt": "2026-01-01T00:00:00+00:00",
                          "reason": "fixture", "owner": {}}
                coordinator.save(record)
        archived = {"schemaVersion": 1, "participantProtocol": 1, "token": "f" * 64,
                    "sequence": 100, "resources": ["base-archive"], "accessMode": "exclusive",
                    "status": "released", "createdAt": "2025-01-01T00:00:00+00:00",
                    "finishedAt": "2025-01-01T00:01:00+00:00", "owner": {}}
        for number in range(10000):
            ticket = f"{number + 256:032x}"
            path = coordinator._archive_path(ticket)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({**archived, "ticket": ticket}, separators=(",", ":")), encoding="utf-8")
        archived_reads = []
        original_read = access_module.read_json
        def observed_read(path):
            if coordinator.archive_root in Path(path).parents:
                archived_reads.append(Path(path))
            return original_read(path)
        started = time.monotonic()
        with mock.patch("itl_remote.access.read_json", side_effect=observed_read):
            status = coordinator.snapshot()
        elapsed = time.monotonic() - started
        self.assertEqual(10, len(status))
        self.assertEqual([], archived_reads)
        self.assertLess(elapsed, 1.0, f"status took {elapsed:.3f}s")

    def test_twenty_thousand_cleanup_debts_do_not_touch_status_and_maintenance_writes_are_bounded(self):
        coordinator = Coordinator(self.coordinator)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            for number in range(10):
                ticket = f"{number + 1:032x}"
                coordinator.save({"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                                  "token": f"{number + 1:064x}", "sequence": coordinator.take_sequence(),
                                  "resources": [f"base-{number}"], "accessMode": "exclusive",
                                  "status": "needs-attention", "createdAt": stamp(),
                                  "reason": "fixture", "owner": {}})
        for number in range(20000):
            ticket = f"{number % 256:02x}{number:030x}"
            item = {"kind": "alive-sidecar", "ticket": ticket, "attempts": 0,
                    "createdAt": stamp(), "queueId": number}
            write_json(coordinator._cleanup_debt_item_path("alive-sidecar", ticket), item)
            write_json(coordinator._queue_slot_path(coordinator.cleanup_queue_path, number),
                       {"schemaVersion": 1, "id": number, "status": "active",
                        "kind": "alive-sidecar", "ticket": ticket})
        write_json(coordinator.cleanup_tail_path,
                   {"schemaVersion": 2, "reclaimId": 0, "headId": 0, "nextId": 20000})
        debt_reads, debt_writes = [], []
        original_read, original_write = access_module.read_json, access_module.write_json
        def observed_read(path):
            if coordinator.cleanup_debt_path in Path(path).parents:
                debt_reads.append(Path(path))
            return original_read(path)
        def observed_write(path, value):
            if coordinator.cleanup_debt_path in Path(path).parents:
                debt_writes.append(Path(path))
            return original_write(path, value)
        started = time.monotonic()
        with mock.patch("itl_remote.access.read_json", side_effect=observed_read), \
                mock.patch("itl_remote.access.write_json", side_effect=observed_write):
            status = coordinator.snapshot()
        self.assertEqual(10, len(status))
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual([], debt_reads)
        self.assertEqual([], debt_writes)
        lease = Lease(self.coordinator, [self.base], {"jobId": "timed-admission"}, timeout=0)
        started = time.monotonic()
        with mock.patch("itl_remote.access.read_json", side_effect=observed_read), \
                mock.patch("itl_remote.access.write_json", side_effect=observed_write):
            lease.__enter__()
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual([], debt_reads)
        self.assertEqual([], debt_writes)
        lease.__exit__(None, None, None)
        maintenance_writes = []
        def maintenance_write(path, value):
            maintenance_writes.append(Path(path))
            return original_write(path, value)
        with mock.patch("itl_remote.access.write_json", side_effect=maintenance_write), \
                mock.patch.object(Path, "glob", side_effect=AssertionError("unbounded directory enumeration")):
            result = coordinator.cleanup(256)
        self.assertLessEqual(result["attempted"], access_module.MAX_CLEANUP_ITEMS_PER_CALL)
        self.assertLessEqual(len(maintenance_writes), access_module.MAX_CLEANUP_ITEMS_PER_CALL + 3)
        self.assertGreater(len(list(coordinator.cleanup_debt_path.glob("??/*.json"))), 19000)

    def test_cleanup_queue_page_reclamation_restarts_after_head_and_page_publication(self):
        for boundary in ("cleanup-queue-reclaim-head", "cleanup-queue-reclaim-delete",
                         "cleanup-queue-reclaim-cursor"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL cleanup reclaim ") as root:
                coordinator = Coordinator(Path(root) / "координатор баз")
                for number in range(access_module.MAINTENANCE_PAGE_SIZE):
                    ticket = f"{number + 1:032x}"
                    item = {"kind": "alive-sidecar", "ticket": ticket, "attempts": 0,
                            "createdAt": stamp()}
                    path = coordinator._cleanup_debt_item_path("alive-sidecar", ticket)
                    write_json(path, item)
                    coordinator._queue_cleanup_item_locked(path, item)
                page = coordinator._queue_slot_path(coordinator.cleanup_queue_path, 0).parent
                injected = False
                def crash_after_publication(actual):
                    nonlocal injected
                    if actual == boundary and not injected:
                        injected = True
                        raise RuntimeError("injected crash after " + boundary)
                coordinator._published = crash_after_publication
                with self.assertRaisesRegex(RuntimeError, "injected crash"):
                    coordinator.cleanup()
                if boundary == "cleanup-queue-reclaim-head":
                    coordinator._queue_slot_path(coordinator.cleanup_queue_path, 0).with_name(
                        "000.json.pending").write_bytes(b"hard-kill partial")
                restarted = Coordinator(coordinator.root)
                restarted.cleanup()
                tail = read_json(restarted.cleanup_tail_path)
                self.assertEqual(access_module.MAINTENANCE_PAGE_SIZE, tail["headId"])
                self.assertEqual(tail["headId"], tail["reclaimId"])
                self.assertFalse(page.exists())
                self.assertEqual({}, restarted._read_cleanup_debt()["items"])

    def test_cleanup_selection_crash_cannot_skip_original_debt_under_continuous_arrivals(self):
        coordinator = Coordinator(self.coordinator)
        original = []
        def append_batch(start):
            for number in range(start, start + access_module.MAINTENANCE_PAGE_SIZE):
                ticket = f"{number + 1:032x}"
                item = {"kind": "alive-sidecar", "ticket": ticket, "attempts": 0,
                        "createdAt": stamp()}
                path = coordinator._cleanup_debt_item_path("alive-sidecar", ticket)
                write_json(path, item)
                coordinator._queue_cleanup_item_locked(path, item)
                if start == 0:
                    original.append(path)
        append_batch(0)
        for generation in range(1, 4):
            coordinator._published = lambda boundary: (_ for _ in ()).throw(
                RuntimeError("injected crash after selection")) if boundary == "cleanup-queue-selected" else None
            with self.assertRaisesRegex(RuntimeError, "after selection"):
                coordinator.cleanup()
            self.assertFalse(coordinator.cleanup_state_path.exists())
            coordinator._published = lambda boundary: None
            append_batch(generation * access_module.MAINTENANCE_PAGE_SIZE)
        coordinator.cleanup()
        self.assertTrue(all(not path.exists() for path in original))
        tail = read_json(coordinator.cleanup_tail_path)
        self.assertEqual(access_module.MAINTENANCE_PAGE_SIZE, tail["headId"])
        self.assertEqual(tail["headId"], tail["reclaimId"])

    def test_unknown_queue_page_orphan_is_explicit_reclaim_debt(self):
        coordinator = Coordinator(self.coordinator)
        for number in range(access_module.MAINTENANCE_PAGE_SIZE):
            ticket = f"{number + 1:032x}"
            item = {"kind": "alive-sidecar", "ticket": ticket, "attempts": 0,
                    "createdAt": stamp()}
            path = coordinator._cleanup_debt_item_path("alive-sidecar", ticket)
            write_json(path, item)
            coordinator._queue_cleanup_item_locked(path, item)
        page = coordinator._queue_slot_path(coordinator.cleanup_queue_path, 0).parent
        orphan = page / "foreign-orphan.tmp"
        orphan.write_bytes(b"unknown")
        with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_CLEANUP_QUEUE_INVALID_RECLAIM_BLOCKED"):
            coordinator.cleanup()
        tail = read_json(coordinator.cleanup_tail_path)
        self.assertEqual(access_module.MAINTENANCE_PAGE_SIZE, tail["headId"])
        self.assertEqual(0, tail["reclaimId"])
        orphan.unlink()
        Coordinator(self.coordinator).cleanup()
        self.assertEqual(access_module.MAINTENANCE_PAGE_SIZE,
                         read_json(coordinator.cleanup_tail_path)["reclaimId"])

    def test_retention_preserves_horizon_and_pins_then_compacts_to_exact_tombstone(self):
        coordinator = Coordinator(self.coordinator)
        old = self.legacy_record("0" * 32, 1, "released")
        young = self.legacy_record("1" * 32, 2, "released")
        young["createdAt"] = stamp()
        young["finishedAt"] = stamp()
        write_json(coordinator.tickets / (young["ticket"] + ".json"), young)
        coordinator.configure_retention(30, 365, 100)
        coordinator.pin(old["ticket"], "fixture", days=1)
        coordinator.compact(2)
        self.assertEqual(old, coordinator.record(old["ticket"]))
        self.assertEqual(young, coordinator.record(young["ticket"]))
        coordinator.unpin(old["ticket"], "fixture")
        result = coordinator.compact(2)
        self.assertEqual(1, result["compacted"])
        with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_TICKET_COMPACTED"):
            coordinator.record(old["ticket"])
        self.assertEqual(young, coordinator.record(young["ticket"]))

    def test_compaction_restarts_after_each_publication_boundary(self):
        for boundary in ("compaction-tombstone", "compaction-delete", "compaction-state"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL compaction restart ") as root:
                coordinator = Coordinator(Path(root) / "координатор баз")
                coordinator.configure_retention(1, 1, 10)
                ticket = "0" * 32
                path = coordinator._archive_path(ticket)
                if boundary == "compaction-delete":
                    write_json(path, {"schemaVersion": 2, "ticket": ticket, "status": "released",
                                      "finishedAt": "2020-01-01T00:00:00+00:00",
                                      "compactedAt": "2020-01-02T00:00:00+00:00",
                                      "recordIdentity": "f" * 64})
                else:
                    write_json(path, {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                                      "token": "f" * 64, "sequence": 1, "resources": ["base-a"],
                                      "accessMode": "exclusive", "status": "released",
                                      "createdAt": "2020-01-01T00:00:00+00:00",
                                      "finishedAt": "2020-01-02T00:00:00+00:00", "owner": {}})
                coordinator._queue_archive_locked(ticket)
                injected = False
                def crash_after_publication(actual):
                    nonlocal injected
                    if actual == boundary and not injected:
                        injected = True
                        raise RuntimeError("injected crash after " + boundary)
                coordinator._published = crash_after_publication
                with self.assertRaisesRegex(RuntimeError, "injected crash"):
                    coordinator.compact()
                restarted = Coordinator(coordinator.root)
                restarted.compact()
                if boundary == "compaction-delete":
                    self.assertFalse(path.exists())
                else:
                    with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_TICKET_COMPACTED"):
                        restarted.record(ticket)
                self.assertEqual(0, read_json(restarted.compaction_path)["nextId"])

    def test_retention_configuration_restarts_after_every_publication_boundary(self):
        boundaries = ("retention-config-transaction", "retention-config-policy",
                      "retention-config-pins", "retention-config-complete")
        for boundary in boundaries:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL retention restart ") as root:
                coordinator = Coordinator(Path(root) / "координатор баз")
                record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": "7" * 32,
                          "token": "7" * 64, "sequence": 1, "resources": ["base-a"],
                          "accessMode": "exclusive", "status": "needs-attention",
                          "createdAt": stamp(), "reason": "fixture", "owner": {}}
                write_json(coordinator.tickets / (record["ticket"] + ".json"), record)
                coordinator.configure_retention(90, 730, 128)
                coordinator.pin(record["ticket"], "fixture", days=700)
                injected = False
                def crash_after_publication(actual):
                    nonlocal injected
                    if actual == boundary and not injected:
                        injected = True
                        raise RuntimeError("injected crash after " + boundary)
                coordinator._published = crash_after_publication
                with self.assertRaisesRegex(RuntimeError, "injected crash"):
                    coordinator.configure_retention(30, 60, 10000)
                restarted = Coordinator(coordinator.root)
                with restarted.mutex(time.monotonic() + 5, lambda: False):
                    restarted._repair_retention_update_locked()
                self.assertEqual(60, restarted._retention_policy()["tombstoneRetentionDays"])
                expiry = restarted._time(restarted._read_pins()["entries"][record["ticket"]]["fixture"],
                                         "test", restarted.pins_path)
                self.assertLessEqual(expiry, datetime.now(timezone.utc) + timedelta(days=60, seconds=1))
                self.assertFalse(restarted.retention_update_path.exists())

    def test_compaction_enforces_one_call_record_budget_even_for_maximum_cli_shape(self):
        coordinator = Coordinator(self.coordinator)
        coordinator.configure_retention(1, 1, 10000)
        for number in range(600):
            ticket = "00" + f"{number:030x}"
            write_json(coordinator._archive_path(ticket),
                       {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                        "token": "f" * 64, "sequence": number + 1, "resources": ["base-a"],
                        "accessMode": "exclusive", "status": "released",
                        "createdAt": "2020-01-01T00:00:00+00:00",
                        "finishedAt": "2020-01-02T00:00:00+00:00", "owner": {}})
            coordinator._queue_archive_locked(ticket)
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        with mock.patch.object(Path, "glob", side_effect=AssertionError("unbounded directory enumeration")):
            result = coordinator.compact(256)
        self.assertEqual(access_module.MAX_COMPACTION_RECORDS_PER_CALL, result["visited"])
        self.assertEqual(access_module.MAX_COMPACTION_RECORDS_PER_CALL, result["scanned"])
        self.assertEqual(access_module.MAX_COMPACTION_RECORDS_PER_CALL, result["nextId"])
        tail = read_json(coordinator.compaction_tail_path)
        self.assertEqual(access_module.MAX_COMPACTION_RECORDS_PER_CALL, tail["headId"])
        self.assertEqual(tail["headId"], tail["reclaimId"])
        self.assertFalse(coordinator._queue_slot_path(coordinator.compaction_queue_path, 0).parent.exists())
        self.assertEqual(600, len(list(coordinator.compaction_queue_path.glob("*/*.json"))))

    def test_compaction_queue_cycles_ineligible_records_without_duplicates_and_revisits_tombstones(self):
        class Clock(datetime):
            current = datetime(2026, 1, 10, tzinfo=timezone.utc)
            @classmethod
            def now(cls, tz=None):
                return cls.current
        coordinator = Coordinator(self.coordinator)
        coordinator.configure_retention(1, 1, 128)
        tickets = [f"{number + 1:032x}" for number in range(4)]
        records = []
        for number, ticket in enumerate(tickets):
            value = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                     "token": "f" * 64, "sequence": number + 1, "resources": ["base-a"],
                     "accessMode": "exclusive", "status": "released",
                     "createdAt": "2020-01-01T00:00:00+00:00",
                     "finishedAt": (Clock.current if number == 0 else datetime(2020, 1, 2, tzinfo=timezone.utc)).isoformat(),
                     "owner": {}}
            records.append(value)
            write_json(coordinator._archive_path(ticket), value)
            coordinator._queue_archive_locked(ticket)
        write_json(coordinator._archive_path(tickets[3]),
                   {"schemaVersion": 2, "ticket": tickets[3], "status": "released",
                    "finishedAt": "2020-01-02T00:00:00+00:00", "compactedAt": Clock.current.isoformat(),
                    "recordIdentity": "e" * 64})
        write_json(coordinator.pins_path, {"schemaVersion": 1, "entries": {
            tickets[1]: {"fixture": (Clock.current + timedelta(days=1)).isoformat()}}})
        debt_path = coordinator._cleanup_debt_item_path("alive-sidecar", tickets[2])
        write_json(debt_path, {"kind": "alive-sidecar", "ticket": tickets[2],
                               "attempts": 0, "createdAt": Clock.current.isoformat()})
        with mock.patch.object(access_module, "datetime", Clock):
            first = coordinator.compact(256)
            second = coordinator.compact(256)
            self.assertEqual(4, first["visited"])
            self.assertEqual(4, second["visited"])
            self.assertEqual(0, read_json(coordinator.compaction_path)["nextId"])
            self.assertEqual(12, read_json(coordinator.compaction_tail_path)["nextId"])
            Clock.current += timedelta(days=2)
            write_json(coordinator.pins_path, {"schemaVersion": 1, "entries": {}})
            third = coordinator.compact(256)
        self.assertEqual(1, third["deleted"])
        self.assertFalse(coordinator._archive_path(tickets[3]).exists())
        self.assertEqual(15, read_json(coordinator.compaction_tail_path)["nextId"])
        self.assertEqual(records[2], read_json(coordinator._archive_path(tickets[2])))

    def test_compaction_queue_is_idempotent_and_fails_closed_on_a_gap_or_duplicate_pointer(self):
        coordinator = Coordinator(self.coordinator)
        ticket = "d" * 32
        record = self.legacy_record(ticket, 1, "released")
        with coordinator.mutex(time.monotonic() + 5, lambda: False):
            pass
        self.assertEqual(1, read_json(coordinator.compaction_tail_path)["nextId"])
        coordinator._queue_archive_locked(ticket)
        self.assertEqual(1, read_json(coordinator.compaction_tail_path)["nextId"])
        slot = coordinator._queue_slot_path(coordinator.compaction_queue_path, 0)
        saved_slot = read_json(slot)
        slot.unlink()
        with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_COMPACTION_QUEUE_INVALID"):
            coordinator.compact()
        write_json(slot, saved_slot)
        write_json(coordinator._compaction_pointer_path(ticket),
                   {"schemaVersion": 1, "ticket": ticket, "id": 1})
        with self.assertRaisesRegex(WorkError, "INFOBASE_ACCESS_COMPACTION_QUEUE_INVALID"):
            coordinator.compact()

    def test_compaction_requeue_restarts_after_every_authority_publication(self):
        boundaries = ("compaction-queue-new-slot", "compaction-queue-authority",
                      "compaction-queue-tail", "compaction-queue-old-retired")
        for boundary in boundaries:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="ITL queue restart ") as root:
                coordinator = Coordinator(Path(root) / "координатор баз")
                coordinator.configure_retention(30, 365, 128)
                ticket = "e" * 32
                record = {"schemaVersion": 1, "participantProtocol": 1, "ticket": ticket,
                          "token": "e" * 64, "sequence": 1, "resources": ["base-a"],
                          "accessMode": "exclusive", "status": "released",
                          "createdAt": stamp(), "finishedAt": stamp(), "owner": {}}
                write_json(coordinator._archive_path(ticket), record)
                coordinator._queue_archive_locked(ticket)
                injected = False
                def crash_after_publication(actual):
                    nonlocal injected
                    if actual == boundary and not injected:
                        injected = True
                        raise RuntimeError("injected crash after " + boundary)
                coordinator._published = crash_after_publication
                with self.assertRaisesRegex(RuntimeError, "injected crash"):
                    coordinator.compact()
                restarted = Coordinator(coordinator.root)
                restarted.compact()
                pointer = read_json(restarted._compaction_pointer_path(ticket))
                slot = restarted._queue_slot_path(restarted.compaction_queue_path, pointer["id"])
                self.assertEqual({"schemaVersion": 1, "id": pointer["id"],
                                  "status": "active", "ticket": ticket}, read_json(slot))
                self.assertEqual(record, read_json(restarted._archive_path(ticket)))

    def test_terminal_ticket_is_addressable_from_archive_and_alive_sidecar_is_removed(self):
        coordinator = Coordinator(self.coordinator)
        with Lease(self.coordinator, [self.base], {"jobId": "complete"}, timeout=0) as lease:
            ticket = lease.record["ticket"]
            self.assertTrue((coordinator.tickets / (ticket + ".alive")).exists())
        self.assertEqual("released", coordinator.record(ticket)["status"])
        self.assertTrue(coordinator._archive_path(ticket).exists())
        self.assertFalse((coordinator.tickets / (ticket + ".alive")).exists())

    def test_zero_wait_allows_immediate_admission_and_invalid_budget_is_rejected(self):
        with Lease(self.coordinator, [self.base], {"jobId": "A"}, timeout=0):
            pass
        for value in (-1, float("nan"), float("inf"), True, 86401):
            with self.assertRaisesRegex(WorkError, "TIMEOUT_INVALID"):
                Lease(self.coordinator, [self.base], {}, timeout=value)

    def test_unconfigured_authority_does_not_claim_cross_host_coordination(self):
        self.assertEqual("execution-host-only", target_access({"workspace": str(self.root)})["scope"])

    def test_python_lease_sites_match_the_machine_inventory(self):
        manifest = json.loads((REPO / "tests/database-access-producers.json").read_text(encoding="utf-8"))
        expected = {(item["file"], item["function"], item["call"]): item["mode"]
                    for item in manifest["pythonCalls"]}

        class LeaseVisitor(ast.NodeVisitor):
            def __init__(self):
                self.scope = []
                self.calls = []

            def visit_ClassDef(self, node):
                self.scope.append(node.name)
                self.generic_visit(node)
                self.scope.pop()

            def visit_FunctionDef(self, node):
                self.scope.append(node.name)
                self.generic_visit(node)
                self.scope.pop()

            visit_AsyncFunctionDef = visit_FunctionDef

            def visit_Call(self, node):
                if ((isinstance(node.func, ast.Name) and node.func.id == "Lease") or
                        (isinstance(node.func, ast.Attribute) and node.func.attr == "Lease")):
                    self.calls.append((".".join(self.scope), node))
                self.generic_visit(node)

        actual = []
        aliased_imports = []
        package = REPO / ".agents/skills/itl-remote-runner/scripts/itl_remote"
        for path in package.glob("*.py"):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            aliased_imports.extend(
                (path.name, alias.name, alias.asname)
                for node in ast.walk(tree) if isinstance(node, (ast.Import, ast.ImportFrom))
                for alias in node.names
                if (alias.name == "Lease" and alias.asname is not None) or alias.asname == "Lease")
            visitor = LeaseVisitor()
            visitor.visit(tree)
            relative = path.relative_to(REPO).as_posix()
            for function, call in visitor.calls:
                actual.append(((relative, function, "Lease"), call))

        self.assertEqual([], aliased_imports)
        actual_keys = [key for key, _ in actual]
        self.assertEqual(len(actual_keys), len(set(actual_keys)), "duplicate Lease call in one inventoried function")
        self.assertEqual(sorted(expected), sorted(actual_keys))
        actual_by_key = dict(actual)
        for key, mode in expected.items():
            keywords = {item.arg: item.value for item in actual_by_key[key].keywords}
            if mode == "inherit-parent":
                self.assertIn("inherited", keywords)
                self.assertNotIn("access_mode", keywords)
            elif mode == "measurement-exclusive":
                self.assertEqual(ast.dump(ast.parse('access["accessMode"]', mode="eval").body),
                                 ast.dump(keywords["access_mode"]))
            elif mode == "wire-canonical":
                self.assertEqual(ast.dump(ast.parse('request.get("accessMode")', mode="eval").body),
                                 ast.dump(keywords["access_mode"]))
            else:
                self.fail("Unknown Python producer mode: " + mode)


if __name__ == "__main__":
    unittest.main()
