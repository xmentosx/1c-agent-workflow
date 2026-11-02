"""Retain one Code generation through the existing native owner, including resume."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import refresh as owner


class RetentionCompletion(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native retention пробел ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = self.root / 'sources/erp'; source.mkdir(parents=True)
        metadata = self.root / 'metadata/erp'; metadata.mkdir(parents=True)
        (source / 'Configuration.xml').write_text('<Configuration/>', encoding='utf-8')
        (source / 'ConfigDumpInfo.xml').write_text('<Version value="one"/>', encoding='utf-8')
        (metadata / 'Report.txt').write_text('existing report', encoding='utf-8')
        self.item = {'configId': 'erp', 'sourcePath': str(source), 'metadataPath': str(metadata),
                     'codeUrl': 'code', 'graphUrl': 'graph'}
        self.status = {'state': 'running', 'stage': 'index-code-and-graph', 'startedAt': 1,
                       'inputFingerprint': owner.input_fingerprint(source, metadata / 'Report.txt')}
        self.path = self.root / 'refresh-state/erp.json'
        self.code = {'data': {'indexing': {'running': False, 'last_outcome': 'completed',
                                         'started_at': '2026-11-02T17:08:32Z'},
                              'collections': {'metadata': 4, 'code': 7},
                              'embedding_provider': {'status': 'ok', 'provider': 'remote'},
                              'generation': {'published': {'generation_id': 'current'},
                                             'lease': {'held': False}, 'pinned': ['current'], 'in_flight': None}}}
        self.graph = {'data': {'background_tasks': {name: {'status': 'completed'} for name in
                      ('metadata_ingest', 'bsl_code_graph', 'vector_indexing', 'routine_embedding_indexing')}}}
        self.client = Mock(); self.graph_client = Mock()
        self.graph_client.call.return_value = self.graph

    def completed_pass(self):
        value = copy.deepcopy(self.code)
        value['data']['indexing']['started_at'] = '2026-11-02T17:45:00Z'
        return value

    def run_wait(self, states, *, retain_one=True, clock=None):
        states = iter(states)
        self.client.call.side_effect = lambda name, *args: (next(states) if name == 'stats' else {'status': 'success'})
        with patch.object(owner, 'wait_ready', side_effect=lambda url, _: self.client if url == 'code' else self.graph_client), \
             patch.object(owner.time, 'sleep'), \
             patch.object(owner, 'command', side_effect=AssertionError('No Docker mutation or restart is allowed')):
            if clock is None:
                return owner.wait_indexes(self.item, {'timeoutSeconds': 5}, self.status, self.path, self.root, retain_one=retain_one)
            with patch.object(owner.time, 'monotonic', side_effect=clock):
                return owner.wait_indexes(self.item, {'timeoutSeconds': 1}, self.status, self.path, self.root, retain_one=retain_one)

    def request_marker(self):
        self.status['codeRetention'] = {'phase': 'requesting', 'generation': 'current',
                                       'inputFingerprint': self.status['inputFingerprint'],
                                       'beforeStartedAt': self.code['data']['indexing']['started_at'], 'requestedAt': 2}

    def test_completion_requires_one_new_native_unchanged_pass_without_restart_or_force(self):
        running = self.completed_pass(); running['data']['indexing']['running'] = True
        result = self.run_wait([self.code, running, self.completed_pass()])
        self.assertEqual(result['state'], 'succeeded')
        self.assertEqual(result['codeRetention']['phase'], 'completed')
        self.assertEqual([c.args for c in self.client.call.call_args_list],
                         [('stats',), ('reindex', {'force': False}), ('stats',), ('stats',)])
        self.assertEqual(json.loads(self.path.read_bytes())['codeRetention']['generation'], 'current')

    def test_existing_reader_defers_native_request_until_the_reader_releases(self):
        pinned = copy.deepcopy(self.code); pinned['data']['generation']['pinned'].append('previous')
        self.run_wait([pinned, self.code, self.completed_pass()])
        self.assertEqual([c.args[0] for c in self.client.call.call_args_list], ['stats', 'stats', 'reindex', 'stats'])

    def test_lost_reply_resumes_the_observed_same_pass_without_reissuing_it(self):
        self.request_marker()
        result = self.run_wait([self.completed_pass()])
        self.assertEqual(result['state'], 'succeeded')
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])

    def test_unobserved_request_never_replays_or_reports_success(self):
        self.request_marker()
        with self.assertRaisesRegex(RuntimeError, 'preserve codeRetention'):
            self.run_wait([self.code], clock=[0, 0, 2])
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])
        self.assertEqual(self.status['codeRetention']['phase'], 'requesting')

    def test_a_missing_run_timestamp_cannot_prove_completion_or_authorize_request(self):
        code = copy.deepcopy(self.code); code['data']['indexing'].pop('started_at')
        with self.assertRaisesRegex(RuntimeError, 'timestamp unavailable'):
            self.run_wait([code])
        self.assertNotIn('codeRetention', self.status)
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])

    def test_first_build_can_still_be_running_without_a_published_generation(self):
        code = {'data': {'indexing': {'running': True}}}
        self.assertFalse(owner.finish_code_retention(self.client, code, self.item, self.status, self.path, 'running'))
        self.client.call.assert_not_called()

    def test_same_second_waits_before_dispatch_then_a_tiny_pass_can_complete(self):
        from datetime import datetime
        initial = datetime.fromisoformat(self.code['data']['indexing']['started_at'].replace('Z', '+00:00')).timestamp()
        self.client.call.return_value = {'status': 'success'}
        with patch.object(owner.time, 'time', return_value=initial + 0.8):
            self.assertFalse(owner.finish_code_retention(self.client, self.code, self.item, self.status, self.path, 'completed'))
        self.client.call.assert_not_called(); self.assertNotIn('codeRetention', self.status)
        with patch.object(owner.time, 'time', return_value=initial + 1.1):
            self.assertFalse(owner.finish_code_retention(self.client, self.code, self.item, self.status, self.path, 'completed'))
        self.client.call.assert_called_once_with('reindex', {'force': False})
        fresh = copy.deepcopy(self.code)
        fresh['data']['indexing']['started_at'] = datetime.fromtimestamp(initial + 1, tz=datetime.fromisoformat('2026-01-01T00:00:00+00:00').tzinfo).isoformat()
        self.assertTrue(owner.finish_code_retention(self.client, fresh, self.item, self.status, self.path, 'completed'))
        self.client.call.assert_called_once()

    def test_changed_publication_preserves_original_intent(self):
        self.request_marker()
        code = self.completed_pass(); code['data']['generation']['published']['generation_id'] = 'unexpected'
        with self.assertRaisesRegex(RuntimeError, 'publication/input changed'):
            self.run_wait([code])
        self.assertEqual(self.status['codeRetention']['phase'], 'requesting')
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])

    def test_changed_input_preserves_original_intent(self):
        self.request_marker()
        (Path(self.item['sourcePath']) / 'ConfigDumpInfo.xml').write_text('<Version value="changed"/>', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'Deployed input changed'):
            self.run_wait([self.code])
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])

    def test_an_older_or_malformed_timestamp_never_proves_a_new_native_pass(self):
        self.request_marker()
        for stamp in ('2026-11-01T17:45:00Z', 'not-a-time', None):
            code = self.completed_pass(); code['data']['indexing']['started_at'] = stamp
            self.assertFalse(owner.finish_code_retention(self.client, code, self.item, self.status, self.path, 'completed'))
        self.client.call.assert_not_called()
        self.assertEqual(self.status['codeRetention']['phase'], 'requesting')

    def test_other_retention_policies_keep_the_existing_single_pass(self):
        self.assertTrue(owner.retention_one({'Config': {'Env': ['GENERATION_RETENTION_COUNT=1']}}))
        self.assertFalse(owner.retention_one({'Config': {'Env': ['GENERATION_RETENTION_COUNT=2']}}))
        self.assertFalse(owner.retention_one({'Config': {}}))
        self.assertFalse(owner.retention_one({'Config': {'Env': None}}))
        self.run_wait([self.code], retain_one=False)
        self.assertNotIn('codeRetention', self.status)
        self.assertEqual([c.args for c in self.client.call.call_args_list], [('stats',)])

    def test_graph_or_native_failures_are_not_hidden_by_retention_completion(self):
        self.graph['data']['background_tasks']['bsl_code_graph']['status'] = 'failed'
        with self.assertRaisesRegex(RuntimeError, 'Graph indexing failed'):
            self.run_wait([self.code])
        self.assertNotIn('codeRetention', self.status)
        code = self.completed_pass(); code['data']['indexing']['last_outcome'] = 'failed'
        with self.assertRaisesRegex(RuntimeError, 'Code indexing failed'):
            self.run_wait([code])


if __name__ == '__main__':
    unittest.main()
