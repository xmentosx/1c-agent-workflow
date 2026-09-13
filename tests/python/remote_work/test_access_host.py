"""Real pipe owners sharing the same authority with portable measurement leases."""
import json
import os
import platform
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

RUNTIME = Path(__file__).resolve().parents[3] / ".agents/skills/itl-remote-runner/scripts"
sys.path.insert(0, str(RUNTIME))
from itl_remote.access import Coordinator, Lease
from itl_remote.common import WorkError
from itl_remote import native_journal


class AccessHostTests(unittest.TestCase):
    def native_record(self, ticket):
        return {"schemaVersion": 1, "journalId": uuid.uuid4().hex, "ticket": ticket, "id": uuid.uuid4().hex,
                "createdAt": "2026-09-10T00:00:00Z", "updatedAt": "2026-09-10T00:00:00Z", "hostName": platform.node(),
                "ownerPid": os.getpid(), "operation": "native-test", "project": str(self.root), "purpose": "test-manager-run",
                "resources": [self.base], "resourceIds": [], "helperInputs": [{"path": str(RUNTIME / "DatabaseAccess.ps1"), "sha256": "a" * 64}],
                "admissions": [{**self.base, "requiredSessions": 1, "expectedChildRole": "test-client"}],
                "startAttempted": True, "processId": 0, "launcherExited": False, "quiescenceConfirmed": False, "releaseEvidence": "",
                "ownedProcessScopes": [], "recoveryRequiresLiveVerification": True}

    def test_native_intent_survives_parent_disconnect_and_overrides_an_incorrect_clean_release(self):
        for disconnect in (False, True):
            with self.subTest(disconnect=disconnect):
                authority = self.root / ("Native журнал " + str(disconnect))
                child, received = self.start(coordinator=str(authority), nativeJournalProtocol=1)
                admitted = self.next(received, "admitted")
                self.assertNotIn("nativeJournal", admitted["owner"])
                payload = self.native_record(admitted["proof"]["ticket"])
                self.send(child, {"event": "native-operation", "record": payload})
                ack = self.next(received, "native-operation-recorded")
                self.assertTrue(Path(ack["path"]).is_file())
                competitor, competitor_events = self.start(coordinator=str(authority), timeout=0)
                waiting = self.next(competitor_events, "waiting")
                self.assertTrue(waiting["blockers"])
                self.assertTrue(all("nativeJournal" not in blocker for blocker in waiting["blockers"]))
                self.next(competitor_events, "error")
                competitor.wait(timeout=5)
                if disconnect:
                    child.stdin.close()
                    self.next(received, "error")
                else:
                    self.send(child, {"event": "release", "cleanupErrors": []})
                    self.assertEqual("needs-attention", self.next(received, "released")["status"])
                child.wait(timeout=5)
                coordinator = Coordinator(authority)
                record = coordinator.records()[0]
                self.assertEqual("needs-attention", record["status"])
                bundle = native_journal.inspect(coordinator, record)
                self.assertEqual([payload["id"]], [p["id"] for p in bundle["operations"]])
                self.assertTrue(bundle["operations"][0]["startAttempted"])
                with self.assertRaisesRegex(WorkError, "RECOVERY_REQUIRED"):
                    with Lease(authority, [self.base], {}, timeout=0):
                        pass

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Общая очередь базы ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.coordinator = self.root / "координатор"
        self.base = {"kind":"file", "path":str(self.root / "целевая база")}
        self.children = []
        self.addCleanup(self.close_children)

    def close_children(self):
        for child, _ in self.children:
            if child.poll() is None:
                child.stdin.close()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()

    def start(self, **overrides):
        environment = {**os.environ, "PYTHONPATH":str(RUNTIME), "PYTHONUTF8":"1"}
        child = subprocess.Popen([sys.executable, "-X", "utf8", "-u", "-m", "itl_remote.access_host"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, encoding="utf-8", env=environment)
        received = queue.Queue()
        def read():
            for line in child.stdout:
                received.put(json.loads(line))
            received.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.children.append((child, received))
        self.send(child, {"schemaVersion":1, "coordinator":str(self.coordinator), "bases":[self.base],
                          "owner":{"project":"проект с пробелом", "operation":"native-test", "parentPid":os.getpid()},
                          "timeout":5, **overrides})
        return child, received

    def send(self, child, value):
        child.stdin.write(json.dumps(value) + "\n")
        child.stdin.flush()

    def next(self, received, event):
        value = received.get(timeout=8)
        self.assertIsNotNone(value)
        self.assertEqual(event, value["event"], value)
        return value

    def test_live_native_owner_blocks_portable_and_releases_after_cleanup(self):
        child, received = self.start()
        admitted = self.next(received, "admitted")
        self.assertNotIn("token", json.dumps(admitted["owner"]))
        with self.assertRaisesRegex(WorkError, "WAIT_TIMEOUT"):
            with Lease(self.coordinator, [self.base], {}, timeout=0):
                self.fail("native parent must own the database")
        self.send(child, {"event":"release", "cleanupErrors":[]})
        self.assertEqual("released", self.next(received, "released")["status"])
        self.assertEqual(0, child.wait(timeout=5), child.stderr.read())
        with Lease(self.coordinator, [self.base], {}, timeout=0):
            pass

    def test_host_accepts_only_the_exact_diagnostic_on_demand_release_action(self):
        instance = "c" * 32
        owner = {"project": "проект с пробелом", "operation": "ondemand-roctup",
                 "requestId": instance, "lifecycle": "on-demand",
                 "releaseAction": {"kind": "finish-owned-on-demand", "family": "roctup",
                                   "instanceId": instance, "tool": "finish_database_access"}}
        child, received = self.start(owner=owner)
        admitted = self.next(received, "admitted")
        self.assertEqual(owner["releaseAction"], admitted["owner"]["owner"]["releaseAction"])
        self.send(child, {"event": "release", "cleanupErrors": []})
        self.assertEqual("released", self.next(received, "released")["status"])
        self.assertEqual(0, child.wait(timeout=5), child.stderr.read())

        tainted = {**owner, "releaseAction": {**owner["releaseAction"], "command": "arbitrary-command"}}
        rejected, rejected_events = self.start(owner=tainted)
        error = self.next(rejected_events, "error")
        self.assertIn("INFOBASE_ACCESS_HOST_REQUEST_INVALID", error["error"])
        self.assertNotIn("arbitrary-command", json.dumps(error))
        self.assertNotEqual(0, rejected.wait(timeout=5))

    def test_host_transitions_the_same_functional_ticket_to_mutation_and_back(self):
        child, received = self.start(accessMode="functional-test")
        admitted = self.next(received, "admitted")
        self.assertEqual("functional-test", admitted["owner"]["accessMode"])
        self.assertEqual("functional-test", admitted["proof"]["accessMode"])
        self.send(child, {"event":"transition", "accessMode":"mutation-exclusive", "timeout":1})
        self.assertEqual("mutation-exclusive", self.next(received, "transitioned")["accessMode"])
        self.send(child, {"event":"transition", "accessMode":"functional-test"})
        self.assertEqual("functional-test", self.next(received, "transitioned")["accessMode"])
        self.send(child, {"event":"release", "cleanupErrors":[]})
        self.assertEqual("functional-test", self.next(received, "released")["accessMode"])
        self.assertEqual(0, child.wait(timeout=5), child.stderr.read())

    def test_host_normalizes_legacy_wire_modes_fail_closed(self):
        for legacy, canonical in ((None, "mutation-exclusive"), ("exclusive", "mutation-exclusive"),
                                  ("test-run", "functional-test")):
            with self.subTest(legacy=legacy):
                values = {} if legacy is None else {"accessMode": legacy}
                child, received = self.start(**values)
                admitted = self.next(received, "admitted")
                self.assertEqual(canonical, admitted["owner"]["accessMode"])
                self.assertEqual(canonical, admitted["proof"]["accessMode"])
                self.send(child, {"event":"release", "cleanupErrors":[]})
                self.assertEqual(canonical, self.next(received, "released")["accessMode"])
                self.assertEqual(0, child.wait(timeout=5), child.stderr.read())
        child, received = self.start(accessMode="legacy-exclusive")
        self.assertIn("MODE_INVALID", self.next(received, "error")["error"])
        self.assertEqual(1, child.wait(timeout=5))

    def test_source_sync_observation_keeps_pin_until_explicit_consume_ack(self):
        owner = {"project": str(self.root), "operation": "sync-dev-branches", "parentPid": os.getpid()}
        record = {"schemaVersion": 2, "groupId": uuid.uuid4().hex, "stepId": uuid.uuid4().hex,
                  "step": "load", "status": "running", "project": str(self.root), "member": "primary",
                  "members": [{"name": "primary", "project": str(self.root), "target": self.base}],
                  "sourceFingerprint": "v2|git-tree-sha256|" + "a" * 64,
                  "sourceCommit": "b" * 40, "exportPath": "src/cf",
                  "contentKind": "configuration", "extensionName": "", "result": {}}
        producer, producer_events = self.start(owner=owner, nativeJournalProtocol=1)
        ticket = self.next(producer_events, "admitted")["proof"]["ticket"]
        self.send(producer, {"event": "source-sync-phase", "record": record})
        self.next(producer_events, "source-sync-phase-recorded")
        self.send(producer, {"event": "release", "cleanupErrors": []})
        self.next(producer_events, "released")
        producer.wait(timeout=5)
        coordinator = Coordinator(self.coordinator)
        self.assertIn(ticket, coordinator._read_pins()["entries"])
        consumer, consumer_events = self.start(owner=owner, nativeJournalProtocol=1)
        self.next(consumer_events, "admitted")
        self.send(consumer, {"event": "source-sync-phase-read", "ticket": ticket, "record": record})
        self.next(consumer_events, "source-sync-phase-observed")
        self.assertIn(ticket, coordinator._read_pins()["entries"])
        self.send(consumer, {"event": "source-sync-phase-consumed", "ticket": ticket,
                             "stepId": record["stepId"]})
        self.next(consumer_events, "source-sync-phase-consumed")
        self.assertNotIn(ticket, coordinator._read_pins()["entries"])
        self.send(consumer, {"event": "release", "cleanupErrors": []})
        self.next(consumer_events, "released")
        consumer.wait(timeout=5)

    def test_portable_parent_is_inherited_and_never_released_by_native_child(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, received = self.start(inherited=parent.proof())
            self.assertEqual(parent.record["ticket"], self.next(received, "admitted")["proof"]["ticket"])
            self.send(child, {"event":"release", "cleanupErrors":[]})
            self.assertTrue(self.next(received, "released")["inherited"])
            self.assertEqual(0, child.wait(timeout=5))
            self.assertTrue(Coordinator(self.coordinator).alive(parent.record["ticket"]))
            self.assertEqual("running", Coordinator(self.coordinator).records()[0]["status"])

    def test_measurement_root_runs_an_inherited_mutation_phase_and_stays_externally_exclusive(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0, access_mode="measurement-exclusive") as parent:
            child, received = self.start(inherited=parent.proof(), accessMode="mutation-exclusive")
            admitted = self.next(received, "admitted")
            self.assertEqual(parent.record["ticket"], admitted["proof"]["ticket"])
            self.assertEqual("mutation-exclusive", admitted["proof"]["accessMode"])
            self.assertNotIn("accessModeV2", json.dumps(admitted))
            raw_participant = next(iter(Coordinator(self.coordinator).records()[0]["participants"].values()))
            self.assertEqual("exclusive", raw_participant["accessMode"])
            self.assertEqual("mutation-exclusive", raw_participant["accessModeV2"])
            competitor, competitor_events = self.start(accessMode="shared-read", timeout=0)
            waiting = self.next(competitor_events, "waiting")
            self.assertEqual("measurement-exclusive", waiting["blockers"][0]["accessMode"])
            self.assertIn("WAIT_TIMEOUT", self.next(competitor_events, "error")["error"])
            self.assertEqual(1, competitor.wait(timeout=5))
            self.send(child, {"event":"release", "cleanupErrors":[]})
            self.assertTrue(self.next(received, "released")["inherited"])
            self.assertEqual(0, child.wait(timeout=5), child.stderr.read())

    def test_waiter_cancel_starts_no_operation_and_does_not_keep_ownership(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, received = self.start()
            waiting = self.next(received, "waiting")
            self.assertNotIn("token", json.dumps(waiting))
            self.send(child, {"event":"cancel"})
            self.assertIn("CANCELLED", self.next(received, "error")["error"])
            self.assertEqual(1, child.wait(timeout=5))
        coordinator = Coordinator(self.coordinator)
        self.assertEqual("released", coordinator.record(parent.record["ticket"])["status"])
        self.assertEqual("cancelled", coordinator.record(waiting["ticket"])["status"])

    def test_parent_disconnect_after_admission_retains_recovery_debt(self):
        child, received = self.start()
        self.next(received, "admitted")
        child.stdin.close()
        self.assertIn("PARENT_DISCONNECTED", self.next(received, "error")["error"])
        self.assertEqual(1, child.wait(timeout=5))
        self.assertEqual("needs-attention", Coordinator(self.coordinator).records()[0]["status"])
        with self.assertRaisesRegex(WorkError, "RECOVERY_REQUIRED"):
            with Lease(self.coordinator, [self.base], {}, timeout=0):
                self.fail("EOF is not proof of stopped database work")

    def test_parent_disconnect_while_waiting_cancels_only_waiter(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, received = self.start()
            waiting = self.next(received, "waiting")
            child.stdin.close()
            self.next(received, "error")
            self.assertEqual(1, child.wait(timeout=5))
            coordinator = Coordinator(self.coordinator)
            self.assertEqual("running", coordinator.record(parent.record["ticket"])["status"])
            self.assertEqual("cancelled", coordinator.record(waiting["ticket"])["status"])

    def test_unproven_cleanup_and_cancel_after_admission_retain_debt(self):
        for control in ({"event":"release", "cleanupErrors":["owned server work unproven"]}, {"event":"cancel"}):
            coordinator = self.root / ("authority-" + control["event"])
            child, received = self.start(coordinator=str(coordinator))
            self.next(received, "admitted")
            self.send(child, control)
            self.next(received, "released" if control["event"] == "release" else "error")
            child.wait(timeout=5)
            self.assertEqual("needs-attention", Coordinator(coordinator).records()[0]["status"])

    def test_full_resource_set_and_unrelated_database_progress(self):
        second = {"kind":"file", "path":str(self.root / "база менеджера")}
        other = {"kind":"file", "path":str(self.root / "другая база")}
        with Lease(self.coordinator, [second], {}, timeout=0):
            child, received = self.start(bases=[self.base, second])
            self.assertEqual(2, len(self.next(received, "waiting")["resources"]))
            with Lease(self.coordinator, [other], {}, timeout=0):
                pass
        while True:
            value = received.get(timeout=8)
            if value["event"] != "waiting":
                self.assertEqual("admitted", value["event"], value)
                break
        self.send(child, {"event":"release", "cleanupErrors":[]})
        self.next(received, "released")
        self.assertEqual(0, child.wait(timeout=5))

    def test_release_before_admission_is_rejected(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0):
            child, received = self.start()
            waiting = self.next(received, "waiting")
            self.send(child, {"event":"release", "cleanupErrors":[]})
            self.next(received, "error")
            self.assertEqual(1, child.wait(timeout=5))
        self.assertEqual("cancelled", Coordinator(self.coordinator).record(waiting["ticket"])["status"])

    def test_invalid_inheritance_exits_without_buffered_stdin_shutdown_failure(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            proof = {**parent.proof(), "token":"wrong-private-token"}
            child, received = self.start(inherited=proof)
            error = self.next(received, "error")
            self.assertEqual("INFOBASE_ACCESS_INHERITANCE_INVALID", error["error"])
            # Leave the input pipe open: startup rejection must still exit cleanly.
            self.assertEqual(1, child.wait(timeout=5))
            self.assertEqual("", child.stderr.read())
            self.assertNotIn("wrong-private-token", json.dumps(error))
            self.assertTrue(Coordinator(self.coordinator).alive(parent.record["ticket"]))

    def test_inherited_failure_prevents_a_clean_parent_release(self):
        parent, parent_events = self.start()
        proof = self.next(parent_events, "admitted")["proof"]
        child, child_events = self.start(inherited=proof)
        self.next(child_events, "admitted")
        self.send(child, {"event": "release", "cleanupErrors": ["native child still unproven"]})
        self.assertEqual("needs-attention", self.next(child_events, "released")["status"])
        self.assertEqual(0, child.wait(timeout=5))
        self.send(parent, {"event": "release", "cleanupErrors": []})
        self.assertEqual("needs-attention", self.next(parent_events, "released")["status"])
        parent.wait(timeout=5)
        record = Coordinator(self.coordinator).records()[0]
        self.assertEqual("uncertain", next(iter(record["participants"].values()))["status"])
        with self.assertRaisesRegex(WorkError, "RECOVERY_REQUIRED"):
            with Lease(self.coordinator, [self.base], {}, timeout=0):
                self.fail("nested cleanup must not be forgotten")

    def test_crashed_borrowed_host_keeps_a_participant_after_os_exit(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, events = self.start(inherited=parent.proof())
            self.next(events, "admitted")
            child.kill()
            child.wait(timeout=5)
            self.assertEqual("needs-attention", parent.release())
        self.assertEqual("active", next(iter(Coordinator(self.coordinator).records()[0]["participants"].values()))["status"])

    def test_parent_cannot_release_while_a_child_or_grandchild_remains(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, child_events = self.start(inherited=parent.proof())
            proof = self.next(child_events, "admitted")["proof"]
            grandchild, grandchild_events = self.start(inherited=proof)
            self.next(grandchild_events, "admitted")
            self.send(child, {"event": "release", "cleanupErrors": []})
            self.assertEqual("released", self.next(child_events, "released")["status"])
            child.wait(timeout=5)
            self.assertEqual("needs-attention", parent.release())
            self.send(grandchild, {"event": "validate"})
            self.assertIn("INHERITANCE_INVALID", self.next(grandchild_events, "error")["error"])
            grandchild.wait(timeout=5)
        self.assertEqual("needs-attention", Coordinator(self.coordinator).records()[0]["status"])

    def test_validation_does_not_create_work_participants(self):
        with Lease(self.coordinator, [self.base], {}, timeout=0) as parent:
            child, events = self.start(inherited=parent.proof())
            self.next(events, "admitted")
            original = Coordinator(self.coordinator).records()[0]["participants"]
            self.assertEqual(1, len(original))
            for _ in range(4):
                self.send(child, {"event": "validate"})
                self.next(events, "validated")
                self.assertEqual(original, Coordinator(self.coordinator).records()[0]["participants"])
            self.send(child, {"event": "release", "cleanupErrors": []})
            self.next(events, "released")
            child.wait(timeout=5)
            self.assertEqual("released", parent.release())

    def test_parent_release_and_child_admission_are_serialized(self):
        for index in range(3):
            coordinator = self.root / ("release-race-" + str(index))
            parent, parent_events = self.start(coordinator=str(coordinator))
            proof = self.next(parent_events, "admitted")["proof"]
            child, child_events = self.start(coordinator=str(coordinator), inherited=proof)
            self.send(parent, {"event": "release", "cleanupErrors": []})
            release = self.next(parent_events, "released")
            admission = child_events.get(timeout=8)
            if admission["event"] == "admitted":
                self.assertEqual("needs-attention", release["status"])
                self.send(child, {"event": "release", "cleanupErrors": []})
                self.next(child_events, "released")
            else:
                self.assertEqual("error", admission["event"], admission)
                self.assertIn("INHERITANCE_INVALID", admission["error"])
                self.assertEqual("released", release["status"])
            child.wait(timeout=5)
            parent.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
