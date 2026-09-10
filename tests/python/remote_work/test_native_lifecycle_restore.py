"""State reconciliation fixtures; DT execution is qualified separately with 1C."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_restoration_journal as restoration_fixtures
from itl_remote.access import Coordinator, Lease
from itl_remote.access_recovery import plan, Recovery
from itl_remote.common import WorkError, capture, digest, read_json, write_json
from itl_remote import native_journal, restoration_journal, native_lifecycle_restore as lifecycle


class NativeLifecycleRestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Восстановление состояния ветки ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fixture = restoration_fixtures.RestorationJournalTests()
        self.fixture.root = self.root
        self.coordinator = self.fixture.coordinator = Coordinator(self.root / 'Общая очередь')
        self.fixture.base = {'kind': 'file', 'path': str(self.root / 'База ветки')}

    def interrupted(self, *, source_existed=False, source_missing=False, runtime_live=False, nested_committed=False, git_branch=None, extra_mutation=False):
        extra = {'kind': 'file', 'path': str(self.root / 'Другая рабочая база')}
        bases = [self.fixture.base, extra] if extra_mutation else [self.fixture.base]
        with Lease(self.coordinator.root, bases,
                   {'operation': 'init-dev-branch-extension', 'nativeJournalProtocol': 1, 'parentPid': os.getpid()}, timeout=0) as lease:
            producer = native_journal.register(lease)
            self.duty = self.fixture.database_payload(lease)
            if extra_mutation:
                self.duty['resources'].append(extra)
            self.manifest = self.fixture.context(self.duty)
            state_snapshot = self.manifest['state']['snapshotPath']
            original = read_json(state_snapshot)
            original.update(lastVerificationStatus='passed', lastConfigDesignerFingerprint='old-fingerprint',
                            toolingInfoBaseGeneration='old-generation', vanessaMcpSafeModeProof={'passed': True},
                            yaxunitInstallationProof={'passed': True}, userSetting='keep baseline setting')
            if git_branch:
                original['devBranch'] = git_branch
            write_json(state_snapshot, original)
            self.manifest['state']['sha256'] = digest(state_snapshot)
            self.manifest['source']['existed'] = source_existed
            self.fixture.save_context(self.duty, self.manifest)
            self.state_path = Path(self.manifest['state']['destination'])
            self.state_path.parent.mkdir(parents=True)
            current = {**original, 'extensionName': 'InterruptedExtension', 'lastVerificationStatus': 'passed',
                       'roctupMcpPid': os.getpid() if runtime_live else ''}
            write_json(self.state_path, current)
            self.interrupted_state = self.state_path.read_bytes()
            self.env_path = Path(self.manifest['environment']['destination'])
            self.env_path.write_bytes(b'IB_PASSWORD=interrupted-test-credential\r\n')
            self.source = Path(self.manifest['source']['path'])
            if not source_missing:
                self.source.mkdir(parents=True)
                (self.source / 'Module.bsl').write_bytes(b'\xef\xbb\xbfinterrupted source\r\n')
            restoration_journal.publish(lease, producer, self.duty)
            if extra_mutation:
                operation = self.fixture.native_restore(self.duty)
                operation['admissions'] = [{**extra, 'requiredSessions': 1, 'expectedChildRole': ''}]
                native_journal.publish(lease, producer, operation)
            if nested_committed:
                inner = self.fixture.database_payload(lease, policy='on-failure')
                self.fixture.context(inner)
                inner['createdAt'] = '2026-09-10T00:00:01Z'
                Path(inner['snapshotPath']).write_bytes(b'intermediate database snapshot')
                inner['snapshotSha256'] = digest(inner['snapshotPath'])
                restoration_journal.publish(lease, producer, inner)
                restoration_journal.publish(lease, producer, {**inner, 'status': 'committed'})
                cursor = self.fixture.payload(lease, existed=False)
                cursor['destination'] = str(self.source / 'ConfigDumpInfo.xml')
                restoration_journal.publish(lease, producer, cursor)
                Path(cursor['destination']).write_bytes(b'intermediate cursor')
            self.ticket = lease.record['ticket']
            lease.release(cleanup_errors=['fixture interrupted before lifecycle rollback'])

    def recovery(self):
        prepared = plan(self.coordinator.root, self.ticket)
        return Recovery(self.coordinator.root, self.ticket, prepared['revision'], {'operation': 'state-regression'})

    def database_result_fixture(self, recovery):
        # Only the state layer is under test here. The production caller writes
        # this after validating its indexed native restore and live observations.
        current = recovery._current()
        current['recoveryAttempts'][-1]['databaseRestorations'] = [{'result': {
            'originalDuty': self.duty['journalId'] + '/' + self.duty['id'],
            'snapshotSha256': self.duty['snapshotSha256']}}]
        self.coordinator.save(current)
        recovery.record = current

    def test_invalidates_receipts_before_database_restore_and_requires_native_result(self):
        self.interrupted()
        with self.recovery() as recovery:
            entry = lifecycle.prepare(recovery, self.duty)
            current = read_json(self.state_path)
            self.assertEqual('pending', current['restorationStatus'])
            self.assertEqual('stale', current['lastVerificationStatus'])
            self.assertEqual('', current['lastConfigDesignerFingerprint'])
            self.assertIsNone(current['vanessaMcpSafeModeProof'])
            self.assertIsNone(current['yaxunitInstallationProof'])
            self.assertNotEqual('old-generation', current['toolingInfoBaseGeneration'])
            saved = read_json(entry['plan']['path'])
            self.assertEqual(self.interrupted_state, Path(saved['interruptedState']['path']).read_bytes())
            with self.assertRaisesRegex(WorkError, 'DATABASE_PROOF_REQUIRED'):
                lifecycle.complete(recovery, self.duty)
            self.assertTrue(self.source.exists())

    def test_restores_baseline_and_preserves_interrupted_source_and_environment_bytes(self):
        self.interrupted()
        with self.recovery() as recovery:
            entry = lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            complete = lifecycle.complete(recovery, self.duty)
            self.assertFalse(self.source.exists())
            self.assertEqual(b'\xef\xbb\xbfinterrupted source\r\n', (Path(complete['quarantine']) / 'Module.bsl').read_bytes())
            self.assertEqual(Path(self.manifest['environment']['snapshotPath']).read_bytes(), self.env_path.read_bytes())
            state = read_json(self.state_path)
            self.assertNotIn('extensionName', state)
            self.assertEqual('keep baseline setting', state['userSetting'])
            self.assertEqual('failed', state['extensionInitializationStatus'])
            self.assertEqual('restored', state['restorationStatus'])
            before = self.state_path.read_bytes()
            self.assertEqual(complete, lifecycle.complete(recovery, self.duty))
            self.assertEqual(before, self.state_path.read_bytes())
            saved = read_json(entry['plan']['path'])
            self.assertEqual(b'IB_PASSWORD=interrupted-test-credential\r\n', Path(saved['interruptedEnvironment']['path']).read_bytes())
            ticket_text = (self.coordinator.root / 'tickets' / (self.ticket + '.json')).read_text()
            self.assertNotIn('interrupted-test-credential', ticket_text)
            self.assertNotIn('private-test-credential', ticket_text)

    def test_resumes_after_source_rename_without_losing_the_quarantine(self):
        self.interrupted()
        with self.recovery() as recovery:
            lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            with patch.object(lifecycle, '_atomic', side_effect=WorkError('fixture environment write failure')):
                with self.assertRaisesRegex(WorkError, 'environment write failure'):
                    lifecycle.complete(recovery, self.duty)
            self.assertFalse(self.source.exists())
            self.assertEqual('pending', read_json(self.state_path)['restorationStatus'])
        with self.recovery() as recovery:
            lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            complete = lifecycle.complete(recovery, self.duty)
            self.assertTrue((Path(complete['quarantine']) / 'Module.bsl').is_file())
            self.assertEqual('restored', read_json(self.state_path)['restorationStatus'])

    def test_rejects_state_edits_after_preparation_without_moving_source(self):
        self.interrupted()
        with self.recovery() as recovery:
            lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            self.state_path.write_bytes(b'{"manual":"preserve this edit"}')
            with self.assertRaisesRegex(WorkError, 'CHANGED_OUTSIDE_OPERATION'):
                lifecycle.complete(recovery, self.duty)
            self.assertTrue(self.source.exists())
            self.assertEqual(b'{"manual":"preserve this edit"}', self.state_path.read_bytes())

    def test_rejects_source_edits_after_preparation_and_keeps_every_file(self):
        self.interrupted()
        with self.recovery() as recovery:
            lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            (self.source / 'NewModule.bsl').write_bytes(b'manual edit')
            with self.assertRaisesRegex(WorkError, 'SOURCE_CHANGED_OUTSIDE_OPERATION'):
                lifecycle.complete(recovery, self.duty)
            self.assertTrue((self.source / 'Module.bsl').is_file())
            self.assertEqual(b'manual edit', (self.source / 'NewModule.bsl').read_bytes())

    def test_recreates_an_original_empty_directory_and_repeats_without_quarantine(self):
        self.interrupted(source_existed=True, source_missing=True)
        with self.recovery() as recovery:
            lifecycle.prepare(recovery, self.duty)
            self.database_result_fixture(recovery)
            lifecycle.complete(recovery, self.duty)
            lifecycle.complete(recovery, self.duty)
            self.assertEqual([], list(self.source.iterdir()))

    def test_live_recorded_runtime_prevents_invalidation_and_is_not_stopped(self):
        self.interrupted(runtime_live=True)
        with self.recovery() as recovery:
            with self.assertRaisesRegex(WorkError, 'RUNTIME_STOP_UNCONFIRMED'):
                lifecycle.prepare(recovery, self.duty)
            self.assertEqual(self.interrupted_state, self.state_path.read_bytes())

    def test_outer_snapshot_restores_source_even_when_an_inner_step_committed(self):
        from itl_remote.native_recovery import _recover_extension_snapshots
        self.interrupted(nested_committed=True)
        with self.recovery() as recovery:
            journal = native_journal.inspect(self.coordinator, recovery._current())
            selected = []

            def database_fixture(active, key):
                selected.append(key)
                self.assertEqual(self.duty['journalId'] + '/' + self.duty['id'], key)
                lifecycle.prepare(active, self.duty)
                self.database_result_fixture(active)
                return {'lifecycle': lifecycle.complete(active, self.duty)}

            with patch('itl_remote.native_database_restore.restore', side_effect=database_fixture):
                result = _recover_extension_snapshots(recovery, journal, [])
            self.assertEqual(1, len(selected))
            self.assertEqual(1, len(result.evidence['supersededCursors']))
            self.assertFalse(self.source.exists())
            kept = Path(result.evidence['restorations'][0]['lifecycle']['quarantine'])
            self.assertEqual(b'intermediate cursor', (kept / 'ConfigDumpInfo.xml').read_bytes())

    def test_does_not_move_source_from_a_switched_checkout(self):
        capture(['git', 'init', '-b', 'itldev/other', str(self.root)])
        self.interrupted(git_branch='itldev/branch1')
        with self.recovery() as recovery:
            with self.assertRaisesRegex(WorkError, 'CHECKOUT_CHANGED'):
                lifecycle.prepare(recovery, self.duty)
            self.assertEqual(self.interrupted_state, self.state_path.read_bytes())
            self.assertTrue((self.source / 'Module.bsl').exists())

    def test_staged_unicode_source_is_preserved_in_the_same_exact_checkout(self):
        capture(['git', 'init', '-b', 'itldev/branch1', str(self.root)])
        self.interrupted(git_branch='itldev/branch1')
        capture(['git', '-C', str(self.root), 'add', '--', str(self.source.relative_to(self.root))])
        with self.recovery() as recovery:
            with self.assertRaisesRegex(WorkError, 'SOURCE_BECAME_TRACKED'):
                lifecycle.prepare(recovery, self.duty)
            self.assertEqual(self.interrupted_state, self.state_path.read_bytes())
            self.assertTrue((self.source / 'Module.bsl').exists())

    def test_primary_snapshot_does_not_claim_to_restore_another_mutated_business_database(self):
        from itl_remote.native_recovery import _recover_extension_snapshots
        self.interrupted(extra_mutation=True)
        with self.recovery() as recovery:
            journal = native_journal.inspect(self.coordinator, recovery._current())
            with patch('itl_remote.native_database_restore.restore') as native_restore:
                with self.assertRaisesRegex(WorkError, 'ADDITIONAL_DATABASE_RESTORATION_REQUIRED'):
                    _recover_extension_snapshots(recovery, journal, [])
                native_restore.assert_not_called()
            self.assertEqual(self.interrupted_state, self.state_path.read_bytes())


if __name__ == '__main__':
    unittest.main()
