import json
import multiprocessing
import os
import tempfile
import time
import unittest
from pathlib import Path

from itl_remote.common import WorkError
from itl_remote.execution_guard import (ExecutionGuard, canonical_base, canonical_resources,
                                        decode_execution_context, resource_key, target_execution,
                                        _OsHandle)


def _hold(root, resources, ready, release):
    with ExecutionGuard(root, resources, "test-owner", timeout=5):
        ready.set()
        release.wait(5)


def _acquire_and_report(root, resources, queue, delay=0.0):
    if delay:
        time.sleep(delay)
    started = time.monotonic()
    with ExecutionGuard(root, resources, "test-waiter", timeout=5):
        queue.put(time.monotonic() - started)


class ExecutionGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "execution-guards-v2"
        self.base_a = {"kind": "file", "path": str(Path(self.temp.name) / "База с пробелом")}
        self.base_b = {"kind": "file", "path": str(Path(self.temp.name) / "Другая база")}
        self.a = canonical_resources([self.base_a])
        self.b = canonical_resources([self.base_b])

    def tearDown(self):
        self.temp.cleanup()

    def test_canonical_file_identity_handles_spaces_and_cyrillic(self):
        same = {"kind": "file", "path": str(Path(self.temp.name) / "." / "База с пробелом")}
        self.assertEqual(resource_key(self.base_a), resource_key(same))
        self.assertEqual("file", canonical_base(self.base_a)["kind"])

    @unittest.skipUnless(os.name == "nt", "Windows named-mutex namespace")
    def test_windows_authority_is_shared_across_logon_sessions(self):
        handle = _OsHandle(self.root, self.a[0])
        self.assertTrue(handle.name.startswith("Global\\ITL.ExecutionGuard.V2."))

    def test_server_identity_requires_exact_server_and_infobase(self):
        first = resource_key({"kind": "server", "server": "Srv", "infobase": "Base"})
        self.assertEqual(first, resource_key({"kind": "server", "cluster": "srv", "name": "base"}))
        self.assertEqual(first, resource_key({"kind": "server", "path": "srv/Base"}))
        self.assertEqual(first, resource_key({"kind": "server", "path": 'Srvr="Srv";Ref="Base";'}))
        self.assertNotEqual(first, resource_key({"kind": "server", "server": "srv2", "infobase": "base"}))

    def test_same_base_waits_and_different_base_does_not(self):
        ready = multiprocessing.Event()
        release = multiprocessing.Event()
        owner = multiprocessing.Process(target=_hold, args=(self.root, self.a, ready, release))
        owner.start()
        self.assertTrue(ready.wait(5))
        queue = multiprocessing.Queue()
        different = multiprocessing.Process(target=_acquire_and_report,
                                            args=(self.root, self.b, queue))
        same = multiprocessing.Process(target=_acquire_and_report,
                                       args=(self.root, self.a, queue))
        different.start()
        same.start()
        self.assertLess(queue.get(timeout=5), 1.0)
        release.set()
        self.assertGreaterEqual(queue.get(timeout=5), 0.01)
        for process in (different, same, owner):
            process.join(5)
            self.assertEqual(0, process.exitcode)

    def test_multi_resource_waiter_never_holds_partial_set(self):
        ready = multiprocessing.Event()
        release = multiprocessing.Event()
        owner = multiprocessing.Process(target=_hold, args=(self.root, self.b, ready, release))
        owner.start()
        self.assertTrue(ready.wait(5))
        queue = multiprocessing.Queue()
        combined = multiprocessing.Process(target=_acquire_and_report,
                                            args=(self.root, self.a + self.b, queue))
        combined.start()
        deadline = time.monotonic() + 5
        records = []
        while time.monotonic() < deadline:
            records = list((self.root / "waiters").glob("*.json"))
            if records:
                break
            time.sleep(0.02)
        self.assertTrue(records)
        raw_a = _OsHandle(self.root, self.a[0])
        self.assertTrue(raw_a.try_acquire(), "the waiting multi-resource job retained a partial handle")
        raw_a.release()
        release.set()
        self.assertGreaterEqual(queue.get(timeout=5), 0.01)
        for process in (combined, owner):
            process.join(5)
            self.assertEqual(0, process.exitcode)

    def test_reentrant_acquisition_requires_inherited_context(self):
        with ExecutionGuard(self.root, self.a, "outer", timeout=2):
            with self.assertRaisesRegex(WorkError, "REENTRANT"):
                with ExecutionGuard(self.root, self.a, "inner", timeout=2):
                    self.fail("same-process acquisition was recursively admitted")

    def test_owner_death_releases_os_authority(self):
        ready = multiprocessing.Event()
        release = multiprocessing.Event()
        owner = multiprocessing.Process(target=_hold, args=(self.root, self.a, ready, release))
        owner.start()
        self.assertTrue(ready.wait(5))
        owner.terminate()
        owner.join(5)
        with ExecutionGuard(self.root, self.a, "after-crash", timeout=2):
            pass

    def test_corrupt_and_terminal_diagnostics_do_not_block(self):
        state = self.root / "executions" / "old.json"
        state.parent.mkdir(parents=True)
        state.write_text("not-json", encoding="utf-8")
        with ExecutionGuard(self.root, self.a, "new", timeout=2) as guard:
            current = json.loads(guard.state_path.read_text(encoding="utf-8"))
            self.assertEqual("running", current["state"])

    def test_cancel_stops_only_waiter(self):
        ready = multiprocessing.Event()
        release = multiprocessing.Event()
        owner = multiprocessing.Process(target=_hold, args=(self.root, self.a, ready, release))
        owner.start()
        self.assertTrue(ready.wait(5))
        cancel = self.root / "cancel"
        cancel.parent.mkdir(parents=True, exist_ok=True)
        cancel.write_text("cancel", encoding="utf-8")
        with self.assertRaisesRegex(WorkError, "EXECUTION_GUARD_CANCELLED"):
            with ExecutionGuard(self.root, self.a, "cancelled", timeout=2, cancel_path=cancel):
                self.fail("cancelled waiter was admitted")
        self.assertTrue(owner.is_alive())
        release.set()
        owner.join(5)

    def test_phase_deadline_bounds_guard_wait(self):
        ready = multiprocessing.Event()
        release = multiprocessing.Event()
        owner = multiprocessing.Process(target=_hold, args=(self.root, self.a, ready, release))
        owner.start()
        self.assertTrue(ready.wait(5))
        try:
            deadline = time.monotonic_ns() + 75_000_000
            with self.assertRaisesRegex(WorkError, "PHASE_DEADLINE_EXPIRED"):
                with ExecutionGuard(self.root, self.a, "deadline", timeout=2,
                                    phase_deadline=deadline):
                    self.fail("expired phase was admitted")
        finally:
            release.set()
            owner.join(5)

    def test_nested_context_is_signed_and_cannot_expand_resources(self):
        with ExecutionGuard(self.root, self.a, "outer", timeout=2) as outer:
            context = outer.context()
            payload = decode_execution_context(context["encoded"], context["key"], self.a)
            self.assertEqual(outer.execution_id, payload["executionId"])
            with self.assertRaisesRegex(WorkError, "RESOURCE_EXPANSION"):
                decode_execution_context(context["encoded"], context["key"], self.a + self.b)
            wrong = bytearray(context["key"])
            wrong[0] ^= 1
            with self.assertRaisesRegex(WorkError, "SIGNATURE"):
                decode_execution_context(context["encoded"], bytes(wrong), self.a)

    def test_target_rejects_multi_host_server_configuration(self):
        target = {"workspace": self.temp.name,
                  "infoBase": {"kind": "server", "server": "srv", "infobase": "base"},
                  "execution": {"hosts": ["one", "two"]}}
        with self.assertRaisesRegex(WorkError, "MULTI_HOST"):
            target_execution(target)


if __name__ == "__main__":
    unittest.main()
