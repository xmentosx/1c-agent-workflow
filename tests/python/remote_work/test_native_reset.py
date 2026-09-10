"""Reset phases retain their original inputs across producers and restarts."""
import copy
from pathlib import Path
import unittest
from unittest.mock import patch

import test_native_continuation as fixtures
from itl_remote import native_journal as native, native_reset as reset, native_completion as completion
from itl_remote.access import Coordinator
from itl_remote.common import WorkError, read_json


class NativeResetTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.NativeContinuationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.owner['operation'] = self.fixture.plan['operation'] = 'reset-dev-branch'
        self.coordinator = self.fixture.coordinator
        root = self.fixture.root
        self.context = {'schemaVersion': 1, 'project': str(root), 'mainProject': str(root / 'Главная ветка'),
            'branch': 'itldev/test', 'branchName': 'test', 'target': self.fixture.base,
            'oldHead': '1' * 40, 'masterCommit': '2' * 40, 'masterTree': '3' * 40,
            'masterFingerprint': 'master-configuration', 'masterConfigTree': '4' * 40,
            'archivePath': str(root / 'Главная ветка/.agent-1c/branch-archives/test/Исходный архив'),
            'phase': 'archive-pending', 'newHead': '', 'archiveManifest': None,
            'seed': {'schemaVersion': 1, 'sourceKey': 'source', 'syncId': 'original-generation',
                'artifactKind': 'file-1cd', 'artifactPath': str(root / 'Копия базы/1Cv8.1CD'),
                'artifactSha256': 'a' * 64, 'artifactBytes': 123, 'configurationFingerprint': 'master-configuration',
                'baselinePath': str(root / 'Копия базы/baseline.json'), 'baselineHash': '', 'baselineSha256': 'b' * 64}}

    def phase(self, phase):
        value = copy.deepcopy(self.context)
        value['phase'] = phase
        if reset.PHASES.index(phase) >= 1:
            value['archiveManifest'] = {'path': str(Path(value['archivePath']) / 'manifest.json'), 'sha256': 'c' * 64}
        if reset.PHASES.index(phase) >= 2:
            value['newHead'] = '5' * 40
        return value

    def start(self, lease):
        return self.fixture.publish(lease)['reference']

    def test_parent_child_chain_survives_coordinator_restart_and_seals_with_completion(self):
        with self.fixture.lease() as parent:
            reference = self.start(parent)
            producer = reference['producerId']
            for phase in reset.PHASES[:3]:
                reset.publish(parent, producer, self.phase(phase))
            with self.fixture.lease(parent.proof()) as child:
                child_id = self.fixture.publish(child, parent=reference)['reference']['producerId']
                for phase in reset.PHASES[2:]:
                    reset.publish(child, child_id, self.phase(phase))
                completion.publish(child, child_id)
                self.assertEqual([], native.release_errors(child, child_id))
            completion.publish(parent, producer)
            current = read_json(self.coordinator.root / 'tickets' / (parent.record['ticket'] + '.json'))
            restarted = Coordinator(self.coordinator.root)
            inspected = native.inspect(restarted, current)
            self.assertEqual(list(range(1, 7)), [v['sequence'] for v in inspected['resetCheckpoints']])
            self.assertEqual('complete', inspected['resetCheckpoints'][-1]['context']['phase'])
            self.assertEqual(self.context['seed'], inspected['resetCheckpoints'][-1]['context']['seed'])
            self.assertEqual([], native.release_errors(parent, producer))
            with self.assertRaisesRegex(WorkError, 'ALREADY_COMPLETED'):
                reset.publish(parent, producer, self.phase('complete'))

    def test_a_matching_configuration_cannot_hide_seed_or_master_substitution(self):
        with self.fixture.lease() as lease:
            producer = self.start(lease)['producerId']
            reset.publish(lease, producer, self.context)
            for field in ('syncId', 'artifactSha256', 'baselineSha256', 'artifactPath'):
                value = self.phase('archive-complete')
                value['seed'][field] = ('d' * 64 if field.endswith('Sha256') else
                                        str(self.fixture.root / 'Другой seed') if field == 'artifactPath' else 'later')
                with self.subTest(field=field), self.assertRaisesRegex(WorkError, 'PINNED_INPUT_CHANGED'):
                    reset.publish(lease, producer, value)
            for field in ('oldHead', 'masterCommit', 'masterTree', 'branch'):
                value = self.phase('archive-complete')
                value[field] = 'itldev/other' if field == 'branch' else 'e' * 40
                with self.subTest(field=field), self.assertRaisesRegex(WorkError, 'PINNED_INPUT_CHANGED'):
                    reset.publish(lease, producer, value)
            self.assertEqual(1, len(reset.inspect(self.coordinator, lease.record)))

    def test_phases_cannot_skip_regress_or_rebind_the_confirmed_archive_and_head(self):
        with self.fixture.lease() as lease:
            producer = self.start(lease)['producerId']
            with self.assertRaisesRegex(WorkError, 'INITIAL_PHASE_REQUIRED'):
                reset.publish(lease, producer, self.phase('git-reset-complete'))
            reset.publish(lease, producer, self.context)
            with self.assertRaisesRegex(WorkError, 'PHASE_TRANSITION_INVALID'):
                reset.publish(lease, producer, self.phase('git-reset-complete'))
            for phase in reset.PHASES[1:3]:
                reset.publish(lease, producer, self.phase(phase))
            with self.assertRaisesRegex(WorkError, 'PHASE_TRANSITION_INVALID'):
                reset.publish(lease, producer, self.phase('archive-complete'))
            for field in ('archiveManifest', 'newHead'):
                value = self.phase('runtime-initializing')
                if field == 'newHead': value[field] = 'e' * 40
                else: value[field]['sha256'] = 'e' * 64
                with self.subTest(field=field), self.assertRaisesRegex(WorkError, 'PINNED_INPUT_CHANGED'):
                    reset.publish(lease, producer, value)

    def test_incomplete_reset_keeps_database_owned_and_cannot_claim_completion(self):
        with self.fixture.lease() as lease:
            producer = self.start(lease)['producerId']
            reset.publish(lease, producer, self.context)
            with self.assertRaisesRegex(WorkError, 'RESET_PENDING'):
                completion.publish(lease, producer)
            errors = native.release_errors(lease, producer)
            self.assertEqual(['native-reset-continuation-required'], errors)
            lease.release(cleanup_errors=errors)
        with self.assertRaisesRegex(WorkError, 'RECOVERY_REQUIRED'):
            with self.fixture.lease(): pass
        from itl_remote.native_recovery import recover_workflow_operation
        with patch('itl_remote.native_recovery._require_process_exited'), patch(
                'itl_remote.native_reset_resume.recover', side_effect=WorkError('RESET_RESUME_NOT_FINISHED')) as adapter:
            with self.assertRaisesRegex(WorkError, 'RESET_RESUME_NOT_FINISHED'):
                recover_workflow_operation(self.coordinator.root, lease.record['ticket'])
            adapter.assert_called_once()
        current = read_json(self.coordinator.root / 'tickets' / (lease.record['ticket'] + '.json'))
        self.assertEqual('needs-attention', current['status'])

    def test_recovery_handoff_requires_the_current_attempt_and_exact_checkpoint(self):
        from itl_remote.access import Lease
        from itl_remote.access_recovery import Recovery, plan
        with self.fixture.lease() as original:
            reference = self.start(original)
            reset.publish(original, reference['producerId'], self.context)
            original.release(cleanup_errors=native.release_errors(original, reference['producerId']))
        prepared = plan(self.coordinator.root, original.record['ticket'])
        with Recovery(self.coordinator.root, original.record['ticket'], prepared['revision'], {'operation': 'unit-reset-recovery'}) as recovery:
            checkpoint = reset.inspect(self.coordinator, recovery._current())[-1]
            for authorization in ('missing', 'wrong-checkpoint', 'valid'):
                record = recovery._current()
                if authorization != 'missing':
                    record['recoveryAttempts'][-1]['resetResume'] = {
                        'checkpoint': checkpoint['reference'] if authorization == 'valid' else {**checkpoint['reference'], 'sha256': '0'*64},
                        'continuation': reference}
                    recovery.coordinator.save(record)
                    recovery.record = record
                with Lease(self.coordinator.root, self.fixture.plan['bases'], self.fixture.owner,
                           timeout=0, inherited=recovery.proof(), purpose='recovery') as child:
                    with self.subTest(authorization=authorization):
                        if authorization != 'valid':
                            with self.assertRaisesRegex(WorkError, 'GENERATION_CHANGED|CHECKPOINT_CHANGED'):
                                self.fixture.publish(child, parent=reference)
                        else:
                            inherited = self.fixture.publish(child, parent=reference)
                            reset.publish(child, inherited['reference']['producerId'], self.context)
                            self.assertEqual(2, len(reset.inspect(self.coordinator, child.record)))

    def test_corrupt_checkpoint_is_not_ignored_by_inspection_or_release(self):
        with self.fixture.lease() as lease:
            producer = self.start(lease)['producerId']
            reset.publish(lease, producer, self.context)
            entry = lease.record['nativeJournal']['producers'][producer]['resetCheckpoints'][0]
            (self.coordinator.root / entry['path']).write_bytes(b'changed record')
            with self.assertRaisesRegex(WorkError, 'CHECKPOINT_CHANGED'):
                native.inspect(self.coordinator, lease.record)
            with self.assertRaisesRegex(WorkError, 'CHECKPOINT_CHANGED'):
                native.release_errors(lease, producer)

    def test_context_cannot_include_secrets_escape_the_archive_or_change_target(self):
        with self.fixture.lease() as lease:
            producer = self.start(lease)['producerId']
            for mutation in ('secret', 'archive', 'target'):
                value = copy.deepcopy(self.context)
                if mutation == 'secret': value['password'] = 'must-not-store'
                if mutation == 'archive': value['archivePath'] = str(self.fixture.root / 'foreign')
                if mutation == 'target': value['target'] = self.fixture.plan['bases'][1]
                with self.subTest(mutation=mutation), self.assertRaises(WorkError):
                    reset.publish(lease, producer, value)
            self.assertEqual([], reset.inspect(self.coordinator, lease.record))


if __name__ == '__main__':
    unittest.main()
