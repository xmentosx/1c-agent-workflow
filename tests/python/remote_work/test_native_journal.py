"""Authority-indexed snapshots survive loss of the native parent process."""
import copy
import json
import os
from pathlib import Path
import platform
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

RUNTIME = Path(__file__).resolve().parents[3] / '.agents/skills/itl-remote-runner/scripts'
sys.path.insert(0, str(RUNTIME))
from itl_remote.access import Coordinator, Lease
from itl_remote.common import WorkError, read_json
from itl_remote import native_journal as journal


class NativeJournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Журнал базы с пробелом ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.coordinator = Coordinator(self.root / 'Общая очередь')
        self.base = {'kind': 'file', 'path': str(self.root / 'Целевая база')}
        self.second = {'kind': 'server', 'path': 'server/Другая база'}

    def lease(self, bases=None, inherited=None):
        return Lease(self.coordinator.root, bases or [self.base],
                     {'nativeJournalProtocol': 1, 'parentPid': os.getpid(), 'project': str(self.root), 'operation': 'native-test'},
                     timeout=0, inherited=inherited)

    def payload(self, lease):
        return {'schemaVersion': 1, 'journalId': uuid.uuid4().hex, 'ticket': lease.record['ticket'], 'id': uuid.uuid4().hex,
                'createdAt': '2026-09-10T00:00:00Z', 'updatedAt': '2026-09-10T00:00:00Z', 'hostName': platform.node(),
                'ownerPid': os.getpid(), 'operation': 'native-test', 'project': str(self.root), 'purpose': 'test-manager-run',
                'resources': [self.base], 'resourceIds': [], 'helperInputs': [{'path': str(RUNTIME / 'DatabaseAccess.ps1'), 'sha256': 'a' * 64}],
                'admissions': [{**self.base, 'requiredSessions': 1, 'expectedChildRole': 'test-client'}],
                'startAttempted': False, 'processId': 0, 'launcherExited': False, 'quiescenceConfirmed': False, 'releaseEvidence': '',
                'ownedProcessScopes': [], 'recoveryRequiresLiveVerification': True}

    def current(self, ticket):
        return next(r for r in self.coordinator.records() if r['ticket'] == ticket)

    def test_index_precedes_ack_and_contains_no_private_token(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            payload = self.payload(lease)
            ack = journal.publish(lease, producer, payload)
            record = self.current(lease.record['ticket'])
            operation = journal.inspect(self.coordinator, record)['operations'][0]
            self.assertEqual(self.coordinator.resources([self.base]), operation['resourceIds'])
            entry = record['nativeJournal']['producers'][producer]['records'][payload['journalId'] + '/' + payload['id']]
            self.assertEqual(ack['sha256'], entry['sha256'])
            self.assertNotIn(lease.proof()['token'], Path(ack['path']).read_text(encoding='utf-8'))
            self.assertTrue(operation['recoveryRequiresLiveVerification'])

    def test_missing_or_corrupted_indexed_file_cannot_disappear_from_recovery(self):
        for mutation in ('delete', 'corrupt'):
            with self.subTest(mutation=mutation), self.lease() as lease:
                producer = journal.register(lease)
                ack = journal.publish(lease, producer, self.payload(lease))
                path = Path(ack['path'])
                if mutation == 'delete':
                    path.unlink()
                else:
                    path.write_text('{}', encoding='utf-8')
                with self.assertRaisesRegex(WorkError, 'RECORD_MISSING_OR_CHANGED'):
                    journal.inspect(self.coordinator, self.current(lease.record['ticket']))

    def test_unindexed_snapshot_after_failed_index_commit_never_authorizes_a_start(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            payload = self.payload(lease)
            with patch.object(lease.coordinator, 'save', side_effect=OSError('disk unavailable')):
                with self.assertRaisesRegex(OSError, 'disk unavailable'):
                    journal.publish(lease, producer, payload)
            self.assertEqual([], journal.inspect(self.coordinator, self.current(lease.record['ticket']))['operations'])
            self.assertEqual(1, len(list((self.coordinator.root / 'native-operations').rglob('*.json'))))

    def test_old_snapshots_are_retained_and_release_observations_can_be_withdrawn(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            payload = self.payload(lease)
            first = journal.publish(lease, producer, payload)
            payload.update(startAttempted=True, processId=1234)
            journal.publish(lease, producer, payload)
            self.assertEqual(['native-operation-cleanup-unconfirmed'], journal.release_errors(lease, producer))
            payload.update(launcherExited=True, quiescenceConfirmed=True, releaseEvidence='live observation')
            journal.publish(lease, producer, payload)
            self.assertEqual([], journal.release_errors(lease, producer))
            payload.update(quiescenceConfirmed=False, releaseEvidence='')
            journal.publish(lease, producer, payload)
            self.assertFalse(read_json(first['path'])['startAttempted'])
            self.assertEqual(['native-operation-cleanup-unconfirmed'], journal.release_errors(lease, producer))

    def test_started_scope_and_database_inputs_cannot_be_rebound(self):
        with self.lease([self.base, self.second]) as lease:
            producer = journal.register(lease)
            payload = self.payload(lease)
            payload['startAttempted'] = True
            journal.publish(lease, producer, payload)
            for mutation in ('started', 'resources', 'scope'):
                value = copy.deepcopy(payload)
                if mutation == 'started': value['startAttempted'] = False
                elif mutation == 'resources': value['resources'] += [self.second]
                else:
                    value['ownedProcessScopes'] = [{'schemaVersion': 1, 'role': 'test-client', **self.base,
                                                   'runParamsPath': str(self.root / 'VAParams.json'), 'runParamsSha256': 'b' * 64, 'testPorts': [53941]}]
                with self.subTest(mutation=mutation), self.assertRaisesRegex(WorkError, 'IMMUTABLE_INPUT_CHANGED'):
                    journal.publish(lease, producer, value)

    def test_unreserved_client_scope_is_rejected_before_any_record_is_indexed(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            value = self.payload(lease)
            value['ownedProcessScopes'] = [{'schemaVersion': 1, 'role': 'test-client', **self.second,
                                           'runParamsPath': str(self.root / 'VAParams.json'), 'runParamsSha256': 'b' * 64, 'testPorts': [53941]}]
            with self.assertRaisesRegex(WorkError, 'TARGET_NOT_RESERVED'):
                journal.publish(lease, producer, value)
            self.assertEqual([], journal.inspect(self.coordinator, self.current(lease.record['ticket']))['operations'])

    def test_native_invocation_scope_is_reserved_and_immutable_after_start(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            value = self.payload(lease)
            scope = {'schemaVersion': 1, 'role': 'native-invocation', **self.base, 'mode': 'DESIGNER',
                     'logPath': str(self.root / 'Журнал запуска.log'), 'notBeforeUtc': '2026-09-10T00:00:00Z'}
            value['ownedProcessScopes'] = [scope]
            journal.publish(lease, producer, value)
            value['startAttempted'] = True
            journal.publish(lease, producer, value)
            changed = copy.deepcopy(value)
            changed['ownedProcessScopes'][0]['logPath'] = str(self.root / 'Чужой журнал.log')
            with self.assertRaisesRegex(WorkError, 'IMMUTABLE_INPUT_CHANGED'):
                journal.publish(lease, producer, changed)
            for change in ({'notBeforeUtc': 'unknown'}, {'logPath': 'relative.log'}, {'mode': 'SHELL'}, {'path': self.second['path'], 'kind': 'server'}):
                invalid = self.payload(lease)
                invalid['ownedProcessScopes'] = [{**scope, **change}]
                with self.subTest(change=change), self.assertRaises(WorkError):
                    journal.publish(lease, producer, invalid)

    def test_inherited_producers_cannot_overwrite_one_another_and_both_are_read(self):
        with self.lease() as parent:
            first = journal.register(parent)
            payload = self.payload(parent)
            journal.publish(parent, first, payload)
            with self.lease(inherited=parent.proof()) as child:
                second = journal.register(child)
                other = self.payload(child)
                other['journalId'] = payload['journalId']
                with self.assertRaisesRegex(WorkError, 'ANOTHER_PRODUCER'):
                    journal.publish(child, second, other)
                other['journalId'] = uuid.uuid4().hex
                journal.publish(child, second, other)
                bundle = journal.inspect(self.coordinator, self.current(parent.record['ticket']))
                self.assertEqual({payload['id'], other['id']}, {p['id'] for p in bundle['operations']})

    def test_untracked_participant_and_missing_owner_manifest_are_not_empty_work(self):
        with self.lease() as parent:
            with self.assertRaisesRegex(WorkError, 'INDEX_MISSING'):
                journal.inspect(self.coordinator, self.current(parent.record['ticket']))
            journal.register(parent)
            with self.lease(inherited=parent.proof()):
                with self.assertRaisesRegex(WorkError, 'UNTRACKED_PARTICIPANT'):
                    journal.inspect(self.coordinator, self.current(parent.record['ticket']))

    def test_index_cannot_redirect_reader_outside_the_ticket_directory(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            value = self.payload(lease)
            journal.publish(lease, producer, value)
            record = self.current(lease.record['ticket'])
            entry = next(iter(record['nativeJournal']['producers'][producer]['records'].values()))
            entry['path'] = '../foreign.json'
            with self.assertRaisesRegex(WorkError, 'INDEX_PATH_INVALID'):
                journal.inspect(self.coordinator, record)

    def test_zero_session_admission_is_only_valid_for_existing_runtime_cleanup(self):
        with self.lease() as lease:
            producer = journal.register(lease)
            value = self.payload(lease)
            value['admissions'][0]['requiredSessions'] = 0
            with self.assertRaisesRegex(WorkError, 'ADMISSION_INVALID'):
                journal.publish(lease, producer, value)
            value['purpose'] = 'owned-runtime-drain'
            ack = journal.publish(lease, producer, value)
            self.assertEqual(0, read_json(ack['path'])['admissions'][0]['requiredSessions'])

    def test_legacy_producer_is_not_upgraded_to_complete_tracking_by_a_new_host(self):
        with self.lease() as parent:
            journal.register(parent)
            with Lease(self.coordinator.root, [self.base], {'parentPid': os.getpid()}, timeout=0, inherited=parent.proof()) as legacy:
                producer = journal.register(legacy)
                with self.assertRaisesRegex(WorkError, 'PROTOCOL_NOT_DECLARED'):
                    journal.publish(legacy, producer, self.payload(legacy))
                with self.assertRaisesRegex(WorkError, 'UNTRACKED_PRODUCER'):
                    journal.inspect(self.coordinator, self.current(parent.record['ticket']))


if __name__ == '__main__':
    unittest.main()
