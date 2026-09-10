"""Source-group acknowledgements distinguish safe continuation from unknown effects."""
import copy
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import test_native_continuation as fixtures
import test_native_journal as operations
from itl_remote import native_journal as native, native_source_sync as phases
from itl_remote.common import WorkError, read_json, write_json


CRASHED_OWNER = r'''
import hashlib, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
from itl_remote.access import Lease
from itl_remote.common import read_json, write_json
from itl_remote import native_journal as native, native_continuation, native_source_sync as phases
from itl_remote.native_recovery_helpers import NAMES
from test_native_journal import NativeJournalTests
request = read_json(sys.argv[3]); plan = request['plan']
coordinator = Path(request['coordinator'])
library = Path(sys.argv[1]).parent.parent / '1c-workflow/scripts/lib'
contents = {name: (library / name).read_bytes() for name in NAMES}
hashes = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
generation = hashlib.sha256('\n'.join(name + ':' + hashes[name] for name in NAMES).encode()).hexdigest()
directory = coordinator / 'native-helper-generations' / generation
directory.mkdir(parents=True)
for name, data in contents.items(): (directory / name).write_bytes(data)
plan['helperInputs'] = [{'path': str(directory / name), 'sha256': hashes[name]} for name in NAMES]
with Lease(coordinator, plan['bases'], {**request['owner'], 'parentPid': os.getpid()}, timeout=0) as lease:
    producer = native.register(lease)
    native_continuation.publish(lease, producer, plan, None)
    phases.publish(lease, producer, request['intent'])
    fixture = NativeJournalTests(); fixture.root = Path(plan['project']); fixture.base = plan['target']
    operation = fixture.payload(lease)
    operation.update(operation='sync-dev-branches', helperInputs=plan['helperInputs'],
                     startAttempted=True, launcherExited=True, quiescenceConfirmed=True,
                     releaseEvidence='fixture action returned; live inspection remains required')
    native.publish(lease, producer, operation)
    if request['completed']:
        phases.publish(lease, producer, {**request['intent'], 'status': 'completed', 'result': {'loaded': True}})
    write_json(request['ready'], {'ticket': lease.record['ticket']})
    os._exit(77)
'''


class NativeSourceSyncTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.NativeContinuationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.owner['operation'] = 'sync-dev-branches'
        self.fixture.plan['operation'] = 'sync-dev-branches'
        self.coordinator = self.fixture.coordinator
        self.intent = dict(schemaVersion=1, groupId=uuid.uuid4().hex, stepId=uuid.uuid4().hex,
                           step='load', status='running', project=str(self.fixture.root), member='primary',
                           members=[dict(name='primary', project=str(self.fixture.root), target=self.fixture.base)],
                           sourceFingerprint='v2|git-tree-sha256|' + 'a' * 64, sourceCommit='b' * 40, exportPath='src/cf', result={})

    def current(self, lease):
        return read_json(self.coordinator.root / 'tickets' / (lease.record['ticket'] + '.json'))

    def publish(self, lease):
        producer = native.register(lease)
        phases.publish(lease, producer, self.intent)
        return producer

    def native_work(self, lease, producer):
        fixture = operations.NativeJournalTests()
        fixture.root, fixture.base = self.fixture.root, self.fixture.base
        operation = fixture.payload(lease)
        operation.update(operation='sync-dev-branches', startAttempted=True, processId=1234,
                         launcherExited=True, quiescenceConfirmed=True, releaseEvidence='fixture process exited')
        native.publish(lease, producer, operation)
        return operation

    def observations(self):
        resources = [{**base, 'sessionCount': 0, 'exclusive': True,
                      'databasePresent': True, 'directoryPresent': True} for base in self.fixture.plan['bases']]
        return [{'observation': {'samples': [{'resources': copy.deepcopy(resources)} for _ in range(2)]}}]

    def recover(self, record, observations=None):
        recovery = SimpleNamespace(coordinator=self.coordinator, _current=lambda: record)
        return phases.recover(recovery, native.inspect(self.coordinator, record), [],
                              self.observations() if observations is None else observations)

    def test_completed_phase_survives_reacquisition_without_replaying_its_effects(self):
        with self.fixture.lease() as lease:
            producer = self.publish(lease)
            self.native_work(lease, producer)
            complete = {**self.intent, 'status': 'completed', 'result': {'cursorSha256': 'c' * 64}}
            ack = phases.publish(lease, producer, complete)
            self.assertEqual(ack, phases.publish(lease, producer, complete))
            self.assertEqual('workflow-source-sync-phase', self.recover(self.current(lease)).evidence['adapter'])
            ticket = lease.record['ticket']
        with self.fixture.lease() as successor:
            observed = phases.observe(successor, ticket, self.intent)
            self.assertTrue(observed['completed'])
            self.assertFalse(observed['canStart'])
            self.assertEqual(complete['result'], observed['result'])

    def test_intent_before_any_effect_is_restartable_but_acknowledged_native_work_is_not_completion(self):
        with self.fixture.lease() as lease:
            producer = self.publish(lease)
            self.assertTrue(phases.observe(lease, lease.record['ticket'], self.intent)['canStart'])
            self.recover(self.current(lease))
            self.native_work(lease, producer)
            self.assertFalse(phases.observe(lease, lease.record['ticket'], self.intent)['canStart'])
            with self.assertRaisesRegex(WorkError, 'UNACKNOWLEDGED_NATIVE_WORK'):
                self.recover(self.current(lease))

    def test_missing_intent_after_failed_index_save_never_implies_native_work_started(self):
        with self.fixture.lease() as lease:
            producer = native.register(lease)
            with patch.object(lease.coordinator, 'save', side_effect=OSError('disk full')):
                with self.assertRaises(OSError): phases.publish(lease, producer, self.intent)
            self.assertEqual([], phases.inspect(self.coordinator, self.current(lease)))
            self.assertTrue(phases.observe(lease, lease.record['ticket'], self.intent)['canStart'])
            self.native_work(lease, producer)
            self.assertFalse(phases.observe(lease, lease.record['ticket'], self.intent)['canStart'])

    def test_completion_requires_intent_and_cannot_change_source_identity(self):
        with self.fixture.lease() as lease:
            producer = native.register(lease)
            with self.assertRaisesRegex(WorkError, 'INTENT_REQUIRED'):
                phases.publish(lease, producer, {**self.intent, 'status': 'completed'})
            phases.publish(lease, producer, self.intent)
            for changed in ({'sourceCommit': 'c' * 40}, {'member': 'other'}, {'sourceFingerprint': 'v2|git-tree-sha256|' + 'd' * 64}):
                with self.subTest(changed=changed), self.assertRaises(WorkError):
                    phases.publish(lease, producer, {**self.intent, **changed, 'status': 'completed'})

    def test_active_native_child_prevents_phase_acknowledgement(self):
        with self.fixture.lease() as lease:
            producer = self.publish(lease)
            operation = self.native_work(lease, producer)
            operation.update(launcherExited=False, quiescenceConfirmed=False, releaseEvidence='')
            native.publish(lease, producer, operation)
            with self.assertRaisesRegex(WorkError, 'NATIVE_WORK_PENDING'):
                phases.publish(lease, producer, {**self.intent, 'status': 'completed'})
            operation.update(launcherExited=True, quiescenceConfirmed=True, releaseEvidence='fixture process exited')
            native.publish(lease, producer, operation)

    def test_recovery_requires_two_complete_exclusive_observations(self):
        with self.fixture.lease() as lease:
            self.publish(lease)
            record = self.current(lease)
            for case in ('empty', 'one-sample', 'missing-resource', 'busy', 'not-exclusive', 'missing-database'):
                observations = self.observations()
                resources = observations[0]['observation']['samples'][0]['resources']
                if case == 'empty': observations = []
                if case == 'one-sample': observations[0]['observation']['samples'].pop()
                if case == 'missing-resource': resources.pop()
                if case == 'busy': resources[0]['sessionCount'] = 1
                if case == 'not-exclusive': resources[0]['exclusive'] = False
                if case == 'missing-database': resources[0]['databasePresent'] = False
                with self.subTest(case=case), self.assertRaises(WorkError): self.recover(record, observations)

    def test_peer_unused_manager_may_be_absent_but_arbitrary_missing_database_may_not(self):
        peer = self.fixture.root / 'Ветка соседа'
        self.intent['members'].append(dict(name='peer', project=str(peer), target=self.fixture.base))
        manager = dict(kind='file', path=str(peer / '.agent-1c/infobases' / ('vanessa-service-' + 'c' * 32)))
        self.fixture.plan['bases'].append(manager)
        with self.fixture.lease() as lease:
            self.publish(lease)
            observations = self.observations()
            for sample in observations[0]['observation']['samples']:
                sample['resources'][-1].update(directoryPresent=False, databasePresent=False, exclusive=False)
            self.recover(self.current(lease), observations)
            observations[0]['observation']['samples'][0]['resources'][-1]['directoryPresent'] = True
            with self.assertRaisesRegex(WorkError, 'DATABASE_STILL_IN_USE'):
                self.recover(self.current(lease), observations)

    def test_corrupt_completion_and_its_intent_are_both_detected(self):
        for which in ('completion', 'intent'):
            with self.subTest(which=which), self.fixture.lease() as lease:
                producer = self.publish(lease)
                phases.publish(lease, producer, {**self.intent, 'status': 'completed'})
                record = self.current(lease)
                entry = record['nativeJournal']['producers'][producer]['sourceSyncPhases'][self.intent['stepId']]
                if which == 'intent': entry = read_json(self.coordinator.root / entry['path'])['intent']
                (self.coordinator.root / entry['path']).write_bytes(b'changed')
                with self.assertRaises(WorkError): native.inspect(self.coordinator, record)

    def test_an_unrelated_database_can_proceed_while_group_scope_remains_owned(self):
        with self.fixture.lease() as lease:
            self.publish(lease)
            with self.assertRaisesRegex(WorkError, 'WAIT_TIMEOUT'):
                with self.fixture.lease(): pass
            with self.fixture.lease(bases=[dict(kind='file', path=str(self.fixture.root / 'Другая база'))]): pass

    def test_crashed_process_releases_only_acknowledged_boundary_through_public_live_inspection(self):
        # Real process death, coordinator and Windows file/process inspection.
        # The database file is an access sentinel, not a functioning 1C database.
        base = Path(self.fixture.base['path'])
        base.mkdir()
        (base / '1Cv8.1CD').write_bytes(b'fixture file access sentinel')
        from itl_remote.native_recovery import recover_workflow_operation
        for completed in (True, False):
            with self.subTest(completed=completed):
                coordinator = self.fixture.root / ('Очередь завершенная' if completed else 'Очередь неизвестная')
                request = self.fixture.root / 'crash-request.json'
                ready = self.fixture.root / 'crash-ready.json'
                write_json(request, dict(coordinator=str(coordinator), plan=self.fixture.plan,
                                         owner=self.fixture.owner, intent=self.intent, completed=completed, ready=str(ready)))
                process = subprocess.run([sys.executable, '-B', '-X', 'utf8', '-c', CRASHED_OWNER,
                                          str(operations.RUNTIME), str(Path(__file__).parent), str(request)],
                                         capture_output=True, timeout=30)
                self.assertEqual(77, process.returncode, process.stderr.decode('utf-8'))
                ticket = read_json(ready)['ticket']
                original = read_json(coordinator / 'tickets' / (ticket + '.json'))
                if completed:
                    recovered = recover_workflow_operation(coordinator, ticket)
                    self.assertEqual('released', recovered['status'])
                    self.assertEqual('workflow-source-sync-phase', recovered['recoveryAttempts'][-1]['evidence']['adapter'])
                    self.assertEqual(original['nativeJournal'], recovered['nativeJournal'])
                    from itl_remote.access import Lease
                    with Lease(coordinator, self.fixture.plan['bases'], self.fixture.owner, timeout=0) as successor:
                        self.assertTrue(phases.observe(successor, ticket, self.intent)['completed'])
                else:
                    with self.assertRaisesRegex(WorkError, 'UNACKNOWLEDGED_NATIVE_WORK'):
                        recover_workflow_operation(coordinator, ticket)
                    retained = read_json(coordinator / 'tickets' / (ticket + '.json'))
                    self.assertEqual('needs-attention', retained['status'])
                self.assertEqual(b'fixture file access sentinel', (base / '1Cv8.1CD').read_bytes())


if __name__ == '__main__':
    unittest.main()
