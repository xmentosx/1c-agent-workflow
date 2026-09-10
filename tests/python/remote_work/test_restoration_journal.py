"""Pending source restoration survives native completion and parent failure."""
import copy
import hashlib
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
from itl_remote.common import WorkError, digest, read_json, write_json
from itl_remote import native_journal as native, restoration_journal as duties


class RestorationJournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Откат файла с пробелом ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.coordinator = Coordinator(self.root / 'Общая очередь')
        self.base = {'kind': 'file', 'path': str(self.root / 'База ветки')}

    def lease(self, inherited=None):
        return Lease(self.coordinator.root, [self.base],
                     {'nativeJournalProtocol': 1, 'parentPid': os.getpid(), 'operation': 'source-load'},
                     timeout=0, inherited=inherited)

    def payload(self, lease, *, existed=True, policy='always'):
        journal, identifier = uuid.uuid4().hex, uuid.uuid4().hex
        destination = self.root / 'Исходники с пробелом' / 'ConfigDumpInfo.xml'
        destination.parent.mkdir(exist_ok=True)
        snapshot = self.coordinator.root / 'restoration-snapshots' / lease.record['ticket'] / journal / (identifier + '.xml')
        if existed:
            snapshot.parent.mkdir(parents=True)
            snapshot.write_bytes(b'\xef\xbb\xbf<original>\r\n</original>\r\n')
            destination.write_bytes(snapshot.read_bytes())
        return {'schemaVersion': 1, 'journalId': journal, 'ticket': lease.record['ticket'], 'id': identifier,
                'createdAt': '2026-09-10T00:00:00Z', 'updatedAt': '2026-09-10T00:00:00Z',
                'hostName': platform.node(), 'ownerPid': os.getpid(), 'operation': 'source-load', 'project': str(self.root),
                'resources': [self.base], 'resourceIds': [], 'kind': 'config-dump-info', 'destination': str(destination),
                'helperInputs': [{'path': str(RUNTIME / 'DatabaseAccess.ps1'), 'sha256': 'a' * 64}],
                'existed': existed, 'snapshotPath': str(snapshot) if existed else '',
                'snapshotSha256': digest(snapshot) if existed else '', 'policy': policy, 'status': 'pending'}

    def current(self, lease):
        return read_json(self.coordinator.root / 'tickets' / (lease.record['ticket'] + '.json'))

    def database_payload(self, lease, policy='always'):
        value = self.payload(lease, existed=False, policy=policy)
        del value['destination'], value['existed']
        snapshot = self.root / '.agent-1c' / 'snapshots' / (value['id'] + '.dt')
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(b'opaque original database snapshot')
        value.update(kind='infobase-snapshot', snapshotPath=str(snapshot), snapshotSha256=digest(snapshot),
                     infoBase=self.base, restoreOperation='', recoveryContext=None)
        return value

    def native_restore(self, value):
        fields = ('schemaVersion', 'journalId', 'ticket', 'createdAt', 'updatedAt', 'hostName',
                  'ownerPid', 'operation', 'project', 'resources', 'resourceIds')
        return {**{name: value[name] for name in fields}, 'id': uuid.uuid4().hex,
                'purpose': 'designer-restore-snapshot-' + value['id'],
                'helperInputs': [{'path': str(RUNTIME / 'DatabaseAccess.ps1'), 'sha256': 'a' * 64}],
                'admissions': [{**self.base, 'requiredSessions': 1, 'expectedChildRole': ''}],
                'startAttempted': True, 'processId': 1234, 'launcherExited': True,
                'quiescenceConfirmed': True, 'releaseEvidence': 'fixture owned processes released',
                'ownedProcessScopes': [], 'recoveryRequiresLiveVerification': True}

    def context(self, value):
        snapshot = value['snapshotPath']
        state = {'safeDevBranchName': 'branch1', 'worktreePath': str(self.root),
                 'infoBaseKind': self.base['kind'], 'devBranchInfoBasePath': self.base['path']}
        write_json(snapshot + '.state.json', state)
        write_json(snapshot + '.project.json', {'logsPath': 'logs'})
        Path(snapshot + '.env').write_bytes(b'IB_PASSWORD=private-test-credential\r\n')
        executable = self.root / 'Platform' / '1cv8.exe'
        executable.parent.mkdir(exist_ok=True)
        executable.write_bytes(b'fixture executable identity; never executed')
        manifest = {'schemaVersion': 1, 'kind': 'extension-initialization', 'project': str(self.root),
                    'state': {'destination': str(self.root / '.agent-1c/dev-branches/branch1.json'),
                              'snapshotPath': snapshot + '.state.json', 'sha256': digest(snapshot + '.state.json')},
                    'environment': {'destination': str(self.root / '.dev.env'), 'existed': True,
                                    'snapshotPath': snapshot + '.env', 'sha256': digest(snapshot + '.env')},
                    'configuration': {'snapshotPath': snapshot + '.project.json', 'sha256': digest(snapshot + '.project.json')},
                    'source': {'path': str(self.root / 'src/cfe/Расширение ветки'), 'existed': False},
                    'platform': {'path': str(executable), 'sha256': digest(executable)}}
        self.save_context(value, manifest)
        return manifest

    def save_context(self, value, manifest):
        path = value['snapshotPath'] + '.recovery.json'
        write_json(path, manifest)
        value['recoveryContext'] = {'path': path, 'sha256': digest(path)}

    def test_lifecycle_context_is_pinned_before_ack_without_copying_credentials_to_coordinator(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.database_payload(lease)
            manifest = self.context(value)
            ack = duties.publish(lease, producer, value)
            self.assertNotIn('private-test-credential', Path(ack['path']).read_text(encoding='utf-8'))
            Path(manifest['environment']['snapshotPath']).write_text('changed credentials')
            with self.assertRaisesRegex(WorkError, 'CONTEXT_ARTIFACT_CHANGED'):
                duties.publish(lease, producer, value)

    def test_lifecycle_context_rejects_wrong_checkout_and_source_tree_before_ack(self):
        for case in ('checkout', 'source', 'platform', 'malformed-state', 'absent-target', 'absent-foreign'):
            with self.subTest(case=case), self.lease() as lease:
                producer = native.register(lease)
                value = self.database_payload(lease)
                manifest = self.context(value)
                if case in ('checkout', 'malformed-state'):
                    state = read_json(manifest['state']['snapshotPath'])
                    state['worktreePath'] = str(self.root / 'another checkout')
                    write_json(manifest['state']['snapshotPath'], [] if case == 'malformed-state' else state)
                    manifest['state']['sha256'] = digest(manifest['state']['snapshotPath'])
                elif case == 'source':
                    manifest['source']['path'] = str(self.root / 'src/cf')
                elif case.startswith('absent-'):
                    manifest['absentFileResources'] = [self.base if case == 'absent-target' else
                        {'kind': 'file', 'path': str(self.root / 'foreign database')}]
                else:
                    replacement = self.root / 'Platform/python.exe'
                    replacement.write_bytes(b'other executable')
                    manifest['platform'] = {'path': str(replacement), 'sha256': digest(replacement)}
                self.save_context(value, manifest)
                with self.assertRaisesRegex(WorkError, 'RESTORATION_CONTEXT_'):
                    duties.publish(lease, producer, value)
                self.assertEqual([], duties.inspect(self.coordinator, self.current(lease))['duties'])

    def test_pins_an_unused_reserved_service_path_without_accepting_a_missing_existing_database(self):
        from itl_remote.native_database_restore import _quiescent
        service = {'kind': 'file', 'path': str(self.root / ('.agent-1c/infobases/vanessa-service-' + 'a' * 32))}
        with Lease(self.coordinator.root, [self.base, service],
                   {'nativeJournalProtocol': 1, 'parentPid': os.getpid(), 'operation': 'init-dev-branch-extension'}, timeout=0) as lease:
            producer = native.register(lease)
            value = self.database_payload(lease)
            value['resources'].append(service)
            manifest = self.context(value)
            manifest['absentFileResources'] = [service]
            self.save_context(value, manifest)
            duties.publish(lease, producer, value)
            base = {**service, 'sessionCount': 0, 'databasePresent': False, 'directoryPresent': False, 'exclusive': False}
            def observations(item):
                return [{'observation': {'samples': [{'resources': [item]}, {'resources': [item]}]}}]
            _quiescent(self.coordinator, observations(base), manifest)
            for changed in ({**base, 'path': self.base['path']}, {**base, 'directoryPresent': True}, {**base, 'sessionCount': 1}):
                with self.subTest(base=changed), self.assertRaisesRegex(WorkError, 'STILL_IN_USE'):
                    _quiescent(self.coordinator, observations(changed), manifest)

    def test_database_restore_requires_indexed_matching_native_operation(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.database_payload(lease)
            duties.publish(lease, producer, value)
            with self.assertRaisesRegex(WorkError, 'NATIVE_RESTORE_UNPROVEN'):
                duties.publish(lease, producer, {**value, 'status': 'restored'})
            operation = self.native_restore(value)
            native.publish(lease, producer, operation)
            value['restoreOperation'] = operation['journalId'] + '/' + operation['id']
            duties.publish(lease, producer, value)
            self.assertEqual(['restoration-duty-unconfirmed'], native.release_errors(lease, producer))
            duties.publish(lease, producer, {**value, 'status': 'restored'})
            self.assertEqual([], native.release_errors(lease, producer))
            with self.assertRaisesRegex(WorkError, 'COMPLETED_DUTY_REUSED'):
                duties.publish(lease, producer, {**value, 'status': 'restored', 'restoreOperation': ''})
            Path(value['snapshotPath']).unlink()
            self.assertEqual('restored', native.inspect(self.coordinator, self.current(lease))['restoration']['duties'][0]['status'])

    def test_unrelated_or_not_quiescent_native_restore_cannot_close_database_duty(self):
        for change in ({'purpose': 'designer-other-snapshot'}, {'launcherExited': False, 'quiescenceConfirmed': False, 'releaseEvidence': ''},
                       {'quiescenceConfirmed': False, 'releaseEvidence': ''}):
            # Each negative case deliberately leaves its own unresolved ticket.
            self.coordinator = Coordinator(self.root / ('Очередь ' + uuid.uuid4().hex))
            with self.subTest(change=change), self.lease() as lease:
                producer = native.register(lease)
                value = self.database_payload(lease)
                duties.publish(lease, producer, value)
                operation = {**self.native_restore(value), **change}
                native.publish(lease, producer, operation)
                with self.assertRaisesRegex(WorkError, 'NATIVE_RESTORE_UNPROVEN'):
                    duties.publish(lease, producer, {**value, 'status': 'restored',
                                   'restoreOperation': operation['journalId'] + '/' + operation['id']})
                self.assertEqual('pending', duties.inspect(self.coordinator, self.current(lease))['duties'][0]['status'])

    def test_database_snapshot_keeps_original_path_and_rechecks_bytes(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.database_payload(lease, policy='on-failure')
            duties.publish(lease, producer, value)
            self.assertEqual(value['snapshotPath'], duties.inspect(self.coordinator, self.current(lease))['duties'][0]['snapshotPath'])
            self.assertFalse((self.coordinator.root / 'restoration-snapshots').exists())
            Path(value['snapshotPath']).write_bytes(b'replaced database snapshot')
            with self.assertRaisesRegex(WorkError, 'SNAPSHOT_CHANGED'):
                duties.publish(lease, producer, {**value, 'status': 'committed'})
            self.assertEqual(['restoration-duty-unconfirmed'], native.release_errors(lease, producer))

    def test_database_target_and_owned_snapshot_directory_are_required_before_ack(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.database_payload(lease)
            for change, error in [({'infoBase': {'kind': 'server', 'path': 'server/other'}}, 'TARGET_NOT_RESERVED'),
                                  ({'snapshotPath': str(self.root / 'foreign.dt')}, 'SNAPSHOT_SCOPE_CHANGED')]:
                with self.subTest(change=change), self.assertRaisesRegex(WorkError, error):
                    duties.publish(lease, producer, {**value, **change})
            self.assertEqual([], duties.inspect(self.coordinator, self.current(lease))['duties'])

    def test_native_and_restoration_collections_cannot_steal_another_producers_journal(self):
        for first_kind in ('native', 'restoration'):
            self.coordinator = Coordinator(self.root / ('Очередь ' + uuid.uuid4().hex))
            with self.subTest(first_kind=first_kind), self.lease() as parent:
                producer = native.register(parent)
                value = self.database_payload(parent)
                operation = self.native_restore(value)
                operation.update(startAttempted=False, processId=0, launcherExited=False, quiescenceConfirmed=False, releaseEvidence='')
                if first_kind == 'native':
                    native.publish(parent, producer, operation)
                else:
                    duties.publish(parent, producer, value)
                with self.lease(inherited=parent.proof()) as child:
                    child_producer = native.register(child)
                    with self.assertRaisesRegex(WorkError, 'ANOTHER_PRODUCER'):
                        if first_kind == 'native':
                            duties.publish(child, child_producer, value)
                        else:
                            native.publish(child, child_producer, operation)

    def test_pending_duty_prevents_release_without_any_native_process(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            ack = duties.publish(lease, producer, value)
            observed = native.inspect(self.coordinator, self.current(lease))
            self.assertEqual([], observed['operations'])
            self.assertEqual('available', observed['restoration']['protocol'])
            self.assertTrue(observed['restoration']['requiresOperationRestorationContract'])
            self.assertEqual('pending', observed['restoration']['duties'][0]['status'])
            self.assertEqual(['restoration-duty-unconfirmed'], native.release_errors(lease, producer))
            self.assertNotIn(lease.proof()['token'], Path(ack['path']).read_text(encoding='utf-8'))
            self.assertEqual('needs-attention', lease.release(cleanup_errors=native.release_errors(lease, producer)))
        self.assertTrue(Path(value['snapshotPath']).is_file())

    def test_cursor_intent_retains_recovery_code_even_before_any_native_operation(self):
        from itl_remote.native_recovery_helpers import NAMES
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            contents = {name: ('# retained ' + name).encode() for name in NAMES}
            hashes = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
            generation = hashlib.sha256('\n'.join(name + ':' + hashes[name] for name in NAMES).encode()).hexdigest()
            directory = self.coordinator.root / 'native-helper-generations' / generation
            directory.mkdir(parents=True)
            for name, data in contents.items():
                (directory / name).write_bytes(data)
            value['helperInputs'] = [{'path': str(directory / name), 'sha256': hashes[name]} for name in NAMES]
            duties.publish(lease, producer, value)
            observed = native.inspect(self.coordinator, self.current(lease), resolve_helpers=True)
            self.assertEqual([], observed['operations'])
            self.assertEqual(generation, observed['restoration']['helperGenerations'][value['journalId'] + '/' + value['id']]['generation'])
            (directory / NAMES[0]).write_bytes(b'changed code')
            with self.assertRaisesRegex(WorkError, 'ARCHIVE_CHANGED'):
                native.inspect(self.coordinator, self.current(lease), resolve_helpers=True)

    def test_claimed_rollback_requires_original_file_bytes(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            duties.publish(lease, producer, value)
            Path(value['destination']).write_bytes(b'changed')
            with self.assertRaisesRegex(WorkError, 'RESTORATION_UNCONFIRMED'):
                duties.publish(lease, producer, {**value, 'status': 'restored'})
            Path(value['destination']).write_bytes(Path(value['snapshotPath']).read_bytes())
            duties.publish(lease, producer, {**value, 'status': 'restored'})
            self.assertEqual([], native.release_errors(lease, producer))
            Path(value['snapshotPath']).unlink()
            self.assertEqual('restored', native.inspect(self.coordinator, self.current(lease))['restoration']['duties'][0]['status'])

    def test_absent_file_requires_actual_absence_at_resolution(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease, existed=False)
            duties.publish(lease, producer, value)
            Path(value['destination']).write_bytes(b'new cursor')
            with self.assertRaisesRegex(WorkError, 'RESTORATION_UNCONFIRMED'):
                duties.publish(lease, producer, {**value, 'status': 'restored'})
            Path(value['destination']).unlink()
            duties.publish(lease, producer, {**value, 'status': 'restored'})
            self.assertEqual([], native.release_errors(lease, producer))

    def test_successful_load_can_commit_only_an_on_failure_duty(self):
        with self.lease() as lease:
            producer = native.register(lease)
            always = self.payload(lease)
            duties.publish(lease, producer, always)
            with self.assertRaisesRegex(WorkError, 'INPUT_INVALID'):
                duties.publish(lease, producer, {**always, 'status': 'committed'})
            conditional = self.payload(lease, policy='on-failure')
            duties.publish(lease, producer, conditional)
            Path(conditional['destination']).write_bytes(b'accepted new cursor')
            duties.publish(lease, producer, {**conditional, 'status': 'committed'})
            self.assertEqual(['restoration-duty-unconfirmed'], native.release_errors(lease, producer))

    def test_snapshot_hash_and_scope_are_required_before_intent_ack(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            for field, changed in [('snapshotSha256', 'a' * 64), ('snapshotPath', str(self.root / 'other.xml'))]:
                with self.subTest(field=field), self.assertRaisesRegex(WorkError, 'SNAPSHOT_.*CHANGED'):
                    duties.publish(lease, producer, {**value, field: changed})
            self.assertEqual([], native.inspect(self.coordinator, self.current(lease))['restoration']['duties'])

    def test_resolving_cannot_change_the_original_snapshot_target_or_policy(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            duties.publish(lease, producer, value)
            for field, changed in [('destination', str(self.root / 'ConfigDumpInfo.xml')), ('policy', 'on-failure'), ('snapshotSha256', 'a' * 64)]:
                with self.subTest(field=field), self.assertRaisesRegex(WorkError, 'IMMUTABLE_INPUT_CHANGED'):
                    duties.publish(lease, producer, {**value, field: changed})
            duties.publish(lease, producer, {**value, 'status': 'restored'})
            with self.assertRaisesRegex(WorkError, 'COMPLETED_DUTY_REUSED'):
                duties.publish(lease, producer, value)

    def test_index_failure_leaves_no_authoritative_duty_and_no_mutation_permission(self):
        with self.lease() as lease:
            producer = native.register(lease)
            value = self.payload(lease)
            with patch.object(lease.coordinator, 'save', side_effect=OSError('authority unavailable')):
                with self.assertRaisesRegex(OSError, 'authority unavailable'):
                    duties.publish(lease, producer, value)
            self.assertEqual([], native.inspect(self.coordinator, self.current(lease))['restoration']['duties'])
            self.assertEqual(1, len(list((self.coordinator.root / 'restoration-duties').rglob('*.json'))))

    def test_inherited_participant_cannot_resolve_another_producers_duty(self):
        with self.lease() as parent:
            producer = native.register(parent)
            value = self.payload(parent)
            duties.publish(parent, producer, value)
            with self.lease(inherited=parent.proof()) as child:
                child_producer = native.register(child)
                with self.assertRaisesRegex(WorkError, 'ANOTHER_PRODUCER'):
                    duties.publish(child, child_producer, {**value, 'status': 'restored'})
            self.assertEqual(['restoration-duty-unconfirmed'], native.release_errors(parent, producer))

    def test_old_producer_does_not_gain_invented_restoration_coverage(self):
        with self.lease() as lease:
            producer = native.register(lease)
            record = self.current(lease)
            record['nativeJournal']['producers'][producer].pop('restorationProtocol')
            record['nativeJournal']['producers'][producer].pop('restorations')
            self.coordinator.save(record)
            observed = native.inspect(self.coordinator, record)['restoration']
            self.assertEqual('legacy-unknown', observed['protocol'])
            self.assertTrue(observed['requiresLiveVerification'])


if __name__ == '__main__':
    unittest.main()
