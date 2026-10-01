import tempfile
import subprocess
import sys
from pathlib import Path
import unittest
import json
from unittest.mock import patch, Mock

from refresh import code_phase, export_revision, graph_phase, input_fingerprint, refresh, run_metadata_generator
from windows_nightly import refresh_linux


class RefreshBoundaryTests(unittest.TestCase):
    def test_wait_existing_preserves_live_index_and_rejects_changed_deployment(self):
        with tempfile.TemporaryDirectory(prefix='индекс ERP ') as directory:
            root = Path(directory).resolve()
            source = root / 'sources/erp/src/cf'; source.mkdir(parents=True)
            metadata = root / 'metadata/erp'; metadata.mkdir(parents=True)
            (source / 'Configuration.xml').write_text('<Configuration/>')
            (source / 'ConfigDumpInfo.xml').write_text('<ConfigVersion version="first"/>')
            (metadata / 'Report.txt').write_text('completed report')
            state = root / 'refresh-state/erp.json'; state.parent.mkdir()
            previous = {'state': 'running', 'stage': 'index-code-and-graph', 'startedAt': 1,
                        'inputFingerprint': input_fingerprint(source, metadata / 'Report.txt')}
            state.write_text(json.dumps(previous))
            item = {'configId': 'erp', 'sourcePath': str(source), 'metadataPath': str(metadata),
                    'exportPath': str(source), 'codeContainer': 'code', 'graphContainer': 'graph',
                    'codeUrl': 'code-url', 'graphUrl': 'graph-url'}
            job = {'dataRoot': str(root), 'exportRoot': str(root / 'sources'), 'configurations': [item]}
            code = {'data': {'indexing': {'last_outcome': 'completed'}, 'collections': {'metadata': 4, 'code': 7},
                            'embedding_provider': {'status': 'ok', 'provider': 'remote'}}}
            graph = {'data': {'background_tasks': {name: {'status': 'completed'} for name in
                      ('metadata_ingest', 'bsl_code_graph', 'vector_indexing', 'routine_embedding_indexing')}}}
            clients = {'code-url': Mock(), 'graph-url': Mock()}
            clients['code-url'].call.return_value = code
            clients['graph-url'].call.return_value = graph
            with patch('refresh.command', side_effect=AssertionError('must not mutate Docker')), \
                 patch('refresh.run_metadata_generator', side_effect=AssertionError('must not regenerate report')), \
                 patch('refresh.container_identity', return_value='owned') as identities, \
                 patch('refresh.wait_ready', side_effect=lambda url, deadline: clients[url]):
                result = refresh({'containers': ['code', 'graph']}, job, 'erp', wait_existing=True)
                self.assertEqual(result['state'], 'succeeded')
                self.assertEqual(result['startedAt'], 1)
                self.assertEqual(identities.call_count, 2)
                self.assertEqual(result['codeCollections'], {'metadata': 4, 'code': 7})
                state.write_text(json.dumps(previous))
                (source / 'ConfigDumpInfo.xml').write_text('<ConfigVersion version="changed"/>')
                with self.assertRaisesRegex(ValueError, 'Deployed indexing input changed'):
                    refresh({'containers': ['code', 'graph']}, job, 'erp', wait_existing=True)
                self.assertEqual(json.loads(state.read_text()), previous)

    def test_extended_refresh_runtime_bounds_both_unit_and_control_wait(self):
        config = {'linuxUser': 'mcp', 'linuxHost': 'guest', 'sshPath': 'ssh',
                  'refreshRuntimeSeconds': 172800, 'timeoutSeconds': 46800,
                  'knownHostsFile': 'known hosts', 'hostKeyAlias': 'guest', 'identityFile': 'key'}
        with patch('windows_nightly.run', return_value=Mock(stdout='{"state":"succeeded"}')) as run:
            refresh_linux(config, 'erp', False)
            self.assertIn('--property=RuntimeMaxSec=172800', run.call_args.args[0][-1])
            self.assertEqual(run.call_args.kwargs['timeout'], 172920)

    def test_metadata_owner_warning_exit_is_accepted_but_error_exit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'report.log'
            self.assertEqual(run_metadata_generator([sys.executable, '-c', "print('warning'); raise SystemExit(1)"], log), 1)
            self.assertEqual(log.read_text(encoding='utf-8').strip(), 'warning')
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                run_metadata_generator([sys.executable, '-c', "print('error'); raise SystemExit(2)"], log)
            self.assertEqual(raised.exception.returncode, 2)
            self.assertEqual(log.read_text(encoding='utf-8').strip(), 'error')

    def test_designer_revision_detects_changed_source_with_unchanged_report(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / 'Configuration.xml').write_text('<Configuration/>')
            (source / 'ConfigDumpInfo.xml').write_text('<ConfigVersion version="first"/>')
            report = source / 'Report.txt'; report.write_text('same metadata')
            before = input_fingerprint(source, report)
            (source / 'ConfigDumpInfo.xml').write_text('<ConfigVersion version="second"/>')
            self.assertNotEqual(input_fingerprint(source, report), before)

    def test_incomplete_shared_export_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                export_revision(Path(directory))

    def test_successful_empty_index_is_not_accepted(self):
        data = {'indexing': {'running': False, 'last_outcome': 'completed'},
                'embedding_provider': {'status': 'ok', 'provider': 'remote'},
                'collections': {'code': 0, 'metadata': 0}}
        with self.assertRaisesRegex(RuntimeError, 'empty'):
            code_phase({'data': data})

    def test_provider_fallback_is_not_accepted_as_remote_indexing(self):
        data = {'indexing': {'last_outcome': 'completed'}, 'collections': {'code': 3, 'metadata': 2},
                'embedding_provider': {'status': 'ok', 'provider': 'remote', 'local_active': True}}
        with self.assertRaisesRegex(RuntimeError, 'remote embedding'):
            code_phase({'data': data})

    def test_disabled_optional_graph_lane_does_not_mask_required_failure(self):
        tasks = {name: {'status': 'completed'} for name in ('metadata_ingest','bsl_code_graph','vector_indexing','routine_embedding_indexing')}
        tasks['extension_catalog'] = {'status': 'skipped', 'error': 'EXTENSION_CATALOG_ENABLED=false'}
        result = {'data': {'background_tasks': tasks, 'metadata_source': {'branch': 'xml'}, 'service_mode': {'graph_only': False}}}
        self.assertEqual(graph_phase(result), 'completed')
        tasks['routine_embedding_indexing'] = {'status': 'failed', 'error': 'provider unavailable'}
        with self.assertRaisesRegex(RuntimeError, 'routine_embedding_indexing'):
            graph_phase(result)


if __name__ == '__main__':
    unittest.main()
