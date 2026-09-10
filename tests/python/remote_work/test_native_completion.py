"""Completion is indexed, freezes native work, and still requires live recovery."""
import copy
import re
from pathlib import Path
from types import SimpleNamespace
import unittest

import test_native_continuation as plan_fixtures
import test_native_journal as operation_fixtures
import test_restoration_journal as duty_fixtures
from itl_remote import native_journal as native, native_completion as completion, restoration_journal as duties
from itl_remote.common import WorkError, read_json


class NativeCompletionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = plan_fixtures.NativeContinuationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.coordinator = self.fixture.coordinator

    def current(self, lease):
        return read_json(self.coordinator.root / 'tickets' / (lease.record['ticket'] + '.json'))

    def test_supported_operations_match_the_lifecycle_completion_publisher(self):
        source = (operation_fixtures.RUNTIME.parent.parent / '1c-workflow/scripts/lib/agent-1c.lifecycle.ps1').read_text(encoding='utf-8-sig')
        body = source.split('function Publish-ItlDevBranchLifecycleCompletion {', 1)[1].split('function Complete-ItlDevBranchMutationDatabaseAdmission', 1)[0]
        declared = re.search(r'Admission.operation -notin @\(([^)]+)\)', body).group(1)
        self.assertEqual(completion.OPERATIONS, set(re.findall(r"'([^']+)'", declared)))

    def operation(self, lease):
        fixture = operation_fixtures.NativeJournalTests()
        fixture.root, fixture.base = self.fixture.root, self.fixture.base
        value = fixture.payload(lease)
        value.update(helperInputs=self.fixture.plan['helperInputs'], operation=self.fixture.owner['operation'])
        return value

    def duty(self, lease):
        fixture = duty_fixtures.RestorationJournalTests()
        fixture.root, fixture.base, fixture.coordinator = self.fixture.root, self.fixture.base, self.coordinator
        value = fixture.payload(lease)
        value.update(helperInputs=self.fixture.plan['helperInputs'], operation=self.fixture.owner['operation'])
        return value

    def test_acknowledgement_does_not_release_the_database_and_disallows_more_native_work(self):
        with self.fixture.lease() as lease:
            producer = self.fixture.publish(lease)['reference']['producerId']
            acknowledgement = completion.publish(lease, producer)
            self.assertEqual('lifecycle-completed', acknowledgement['event'])
            record = self.current(lease)
            self.assertEqual('running', record['status'])
            self.assertEqual(self.fixture.owner['operation'], native.inspect(self.coordinator, record)['completions'][producer]['operation'])
            with self.assertRaisesRegex(WorkError, 'WAIT_TIMEOUT'):
                with self.fixture.lease(): pass
            with self.assertRaisesRegex(WorkError, 'ALREADY_COMPLETED'):
                native.publish(lease, producer, self.operation(lease))
            with self.assertRaisesRegex(WorkError, 'ALREADY_COMPLETED'):
                duties.publish(lease, producer, self.duty(lease))
            with self.assertRaisesRegex(WorkError, 'ALREADY_COMPLETED'):
                native.register(lease)
            self.assertEqual([], native.release_errors(lease, producer))

    def test_root_waits_for_all_participants_and_unfinished_native_work(self):
        with self.fixture.lease() as parent:
            producer = self.fixture.publish(parent)['reference']['producerId']
            with self.fixture.lease(parent.proof()) as child:
                self.fixture.publish(child)
                with self.assertRaisesRegex(WorkError, 'PARTICIPANTS_ACTIVE'):
                    completion.publish(parent, producer)
            value = self.operation(parent)
            value.update(startAttempted=True, processId=1234)
            native.publish(parent, producer, value)
            with self.assertRaisesRegex(WorkError, 'NATIVE_WORK_PENDING'):
                completion.publish(parent, producer)
            value.update(launcherExited=True, quiescenceConfirmed=True, releaseEvidence='unit fixture observation')
            native.publish(parent, producer, value)
            completion.publish(parent, producer)

    def test_pending_restore_cannot_be_hidden_by_completion(self):
        with self.fixture.lease() as lease:
            producer = self.fixture.publish(lease)['reference']['producerId']
            value = self.duty(lease)
            duties.publish(lease, producer, value)
            with self.assertRaisesRegex(WorkError, 'RESTORATION_PENDING'):
                completion.publish(lease, producer)
            value['status'] = 'restored'
            duties.publish(lease, producer, value)
            completion.publish(lease, producer)

    def test_completed_child_does_not_freeze_its_parent_but_root_seals_the_whole_journal(self):
        with self.fixture.lease() as parent:
            published = self.fixture.publish(parent)
            producer = published['reference']['producerId']
            with self.fixture.lease(parent.proof()) as child:
                child_id = self.fixture.publish(child, parent=published['reference'])['reference']['producerId']
                completion.publish(child, child_id)
            native.publish(parent, producer, self.operation(parent))
            completion.publish(parent, producer)
            inspected = native.inspect(self.coordinator, self.current(parent))
            self.assertEqual({producer, child_id}, set(inspected['completions']))

    def test_corrupt_completion_or_changed_index_is_rejected_by_inspection(self):
        for mutation in ('completion-file', 'index'):
            with self.subTest(mutation=mutation), self.fixture.lease() as lease:
                producer = self.fixture.publish(lease)['reference']['producerId']
                completion.publish(lease, producer)
                record = self.current(lease)
                if mutation == 'completion-file':
                    (self.coordinator.root / record['nativeJournal']['producers'][producer]['completion']['path']).write_bytes(b'changed')
                else:
                    record['nativeJournal']['producers'][producer]['createdAt'] = 'changed'
                with self.assertRaisesRegex(WorkError, 'COMPLETION_CHANGED'):
                    native.inspect(self.coordinator, record)

    def test_live_recovery_checks_every_reserved_database_and_preserves_completed_results(self):
        with self.fixture.lease() as lease:
            producer = self.fixture.publish(lease)['reference']['producerId']
            completion.publish(lease, producer)
            record = self.current(lease)
            journal = native.inspect(self.coordinator, record)
            recovery = SimpleNamespace(coordinator=self.coordinator, _current=lambda: record)
            resources = [{**base, 'sessionCount': 0, 'exclusive': True, 'databasePresent': True, 'directoryPresent': True}
                         for base in self.fixture.plan['bases']]
            observations = [{'observation': {'samples': [{'resources': copy.deepcopy(resources)} for _ in range(2)]}}]
            receipt = completion.recover_completed(recovery, journal, [], observations)
            self.assertEqual('workflow-completed-lifecycle', receipt.evidence['adapter'])
            for mutation in ('busy', 'missing-source', 'partial', 'empty'):
                changed = copy.deepcopy(observations)
                if mutation == 'busy': changed[0]['observation']['samples'][0]['resources'][0]['sessionCount'] = 1
                if mutation == 'missing-source': changed[0]['observation']['samples'][0]['resources'][0].update(databasePresent=False, directoryPresent=False)
                if mutation == 'partial': changed[0]['observation']['samples'][0]['resources'].pop()
                if mutation == 'empty': changed = []
                with self.subTest(mutation=mutation), self.assertRaises(WorkError):
                    completion.recover_completed(recovery, journal, [], changed)

    def test_child_completion_alone_is_not_whole_operation_completion(self):
        with self.fixture.lease() as parent:
            self.fixture.publish(parent)
            with self.fixture.lease(parent.proof()) as child:
                child_id = self.fixture.publish(child)['reference']['producerId']
                completion.publish(child, child_id)
            record = self.current(parent)
            with self.assertRaisesRegex(WorkError, 'ROOT_COMPLETION_REQUIRED'):
                completion.recover_completed(SimpleNamespace(coordinator=self.coordinator, _current=lambda: record), native.inspect(self.coordinator, record), [], [])


if __name__ == '__main__':
    unittest.main()
