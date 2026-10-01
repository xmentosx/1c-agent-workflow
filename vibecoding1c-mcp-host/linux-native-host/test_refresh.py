import tempfile
import subprocess
import sys
from pathlib import Path
import unittest

from refresh import code_phase, export_revision, graph_phase, input_fingerprint, run_metadata_generator


class RefreshBoundaryTests(unittest.TestCase):
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
