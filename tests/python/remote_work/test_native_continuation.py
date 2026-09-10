"""Resource-plan inheritance uses the live authority and immutable producer data."""
import copy
import os
from pathlib import Path
import unittest

import test_native_recovery_helpers as helper_fixtures
from itl_remote.access import Lease
from itl_remote.common import WorkError, read_json
from itl_remote import native_journal, native_continuation as continuation


class NativeContinuationTests(unittest.TestCase):
    def setUp(self):
        fixture = helper_fixtures.NativeRecoveryHelpersTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.coordinator = fixture.coordinator
        self.root = self.coordinator.root.parent
        self.base = {'kind': 'file', 'path': str(self.root / 'База ветки')}
        self.owner = {'project': str(self.root), 'operation': 'refresh-dev-branch-lite',
                      'nativeJournalProtocol': 1, 'parentPid': os.getpid()}
        self.plan = {'schemaVersion': 1, 'operation': self.owner['operation'], 'project': str(self.root),
                     'target': self.base, 'bases': [self.base], 'helperInputs': fixture.inputs,
                     'serviceGeneration': 'a' * 32, 'serviceReserveGeneration': 'b' * 32}
        for name in ('serviceGeneration', 'serviceReserveGeneration'):
            self.plan['bases'].append({'kind': 'file', 'path': str(self.root / '.agent-1c/infobases' / ('vanessa-service-' + self.plan[name]))})

    def lease(self, inherited=None, bases=None, owner=None):
        return Lease(self.coordinator.root, bases or self.plan['bases'], owner or self.owner,
                     timeout=0, inherited=inherited)

    def publish(self, lease, plan=None, parent=None):
        producer = native_journal.register(lease)
        return continuation.publish(lease, producer, plan or self.plan, parent)

    def test_child_keeps_the_whole_reservation_and_parent_plan_is_immutable(self):
        with self.lease() as parent:
            published = self.publish(parent)
            original = read_json(self.coordinator.root / 'tickets' / (parent.record['ticket'] + '.json'))
            parent_entry = original['nativeJournal']['producers'][published['reference']['producerId']]['continuation']
            original_bytes = (self.coordinator.root / parent_entry['path']).read_bytes()
            changed = {**self.plan, 'serviceGeneration': self.plan['serviceReserveGeneration']}
            with self.lease(parent.proof()) as child:
                result = self.publish(child, changed, published['reference'])
                self.assertEqual(changed, result['plan'])
                self.assertEqual(published['reference'], continuation.read(self.coordinator, child.record, result['reference'])['parent'])
                self.assertEqual(original_bytes, (self.coordinator.root / parent_entry['path']).read_bytes())
            with self.assertRaisesRegex(WorkError, 'WAIT_TIMEOUT'):
                with self.lease(): pass
        with self.lease(): pass

    def test_reference_cannot_cross_another_admission_even_for_the_same_database(self):
        with self.lease() as first:
            reference = self.publish(first)['reference']
        with self.lease() as second:
            with self.lease(second.proof()) as child:
                with self.assertRaisesRegex(WorkError, 'REFERENCE_INVALID'):
                    self.publish(child, parent=reference)

    def test_child_cannot_drop_a_reservation_change_target_or_choose_another_generation(self):
        with self.lease() as parent:
            reference = self.publish(parent)['reference']
            for mutation in ('drop', 'target', 'reserve', 'generation'):
                changed = copy.deepcopy(self.plan)
                if mutation == 'drop': changed['bases'] = changed['bases'][:2]; changed['serviceReserveGeneration'] = ''
                if mutation == 'target': changed['target'] = changed['bases'][1]
                if mutation == 'reserve': changed['serviceReserveGeneration'] = changed['serviceGeneration']
                if mutation == 'generation': changed['serviceGeneration'] = 'c' * 32
                with self.subTest(mutation=mutation), self.lease(parent.proof(), changed['bases']) as child:
                    with self.assertRaisesRegex(WorkError, 'PLAN_CHANGED|SERVICE_NOT_RESERVED'):
                        self.publish(child, changed, reference)

    def test_mutated_or_forged_plan_reference_is_rejected(self):
        with self.lease() as parent:
            reference = self.publish(parent)['reference']
            forged = {**reference, 'sha256': '0' * 64}
            with self.lease(parent.proof()) as child:
                with self.assertRaisesRegex(WorkError, 'REFERENCE_CHANGED'):
                    self.publish(child, parent=forged)
            current = read_json(self.coordinator.root / 'tickets' / (parent.record['ticket'] + '.json'))
            path = self.coordinator.root / current['nativeJournal']['producers'][reference['producerId']]['continuation']['path']
            path.write_bytes(b'changed immutable plan')
            with self.lease(parent.proof()) as child:
                with self.assertRaisesRegex(WorkError, 'RECORD_CHANGED'):
                    self.publish(child, parent=reference)

    def test_rejects_secret_fields_and_operation_or_project_substitution(self):
        with self.lease() as lease:
            for change in ({'password': 'do-not-store'}, {'operation': 'reset-dev-branch'}, {'project': str(self.root / 'Other')}):
                with self.subTest(change=list(change)), self.assertRaises(WorkError):
                    self.publish(lease, {**self.plan, **change})

    def test_late_caller_cannot_use_a_released_lease(self):
        with self.lease() as parent:
            producer = native_journal.register(parent)
        with self.assertRaisesRegex(WorkError, 'INHERITANCE_INVALID'):
            continuation.publish(parent, producer, self.plan)

    def test_the_same_producer_cannot_replace_its_published_plan(self):
        with self.lease() as parent:
            producer = native_journal.register(parent)
            continuation.publish(parent, producer, self.plan)
            with self.assertRaisesRegex(WorkError, 'ALREADY_PUBLISHED'):
                continuation.publish(parent, producer, self.plan)

    def test_inspection_retains_prelaunch_resources_and_helpers_after_producer_restart(self):
        with self.lease() as parent:
            published = self.publish(parent)
            inspected = native_journal.inspect(self.coordinator, parent.record, resolve_helpers=True)
            self.assertEqual([], inspected['operations'])
            self.assertEqual(self.plan, inspected['continuations'][published['reference']['producerId']]['plan'])
            self.assertEqual(5, len(inspected['continuationHelperGenerations'][published['reference']['producerId']]['files']))
            # A fresh coordinator reads the indexed records rather than relying
            # on a producer's still-live Python objects or environment.
            from itl_remote.access import Coordinator
            restarted = Coordinator(self.coordinator.root)
            current = read_json(restarted.root / 'tickets' / (parent.record['ticket'] + '.json'))
            self.assertEqual(inspected, native_journal.inspect(restarted, current, resolve_helpers=True))

    def test_inspection_and_normal_release_reject_corrupted_indexed_plan(self):
        with self.lease() as parent:
            published = self.publish(parent)
            producer_id = published['reference']['producerId']
            entry = parent.record['nativeJournal']['producers'][producer_id]['continuation']
            (self.coordinator.root / entry['path']).write_bytes(b'corrupt plan')
            with self.assertRaisesRegex(WorkError, 'RECORD_CHANGED'):
                native_journal.inspect(self.coordinator, parent.record)
            with self.assertRaisesRegex(WorkError, 'RECORD_CHANGED'):
                native_journal.release_errors(parent, producer_id)


if __name__ == '__main__':
    unittest.main()
