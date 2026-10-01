import io
import tarfile
import tempfile
from pathlib import Path
import unittest

from refresh import code_phase, extract_export, graph_phase


class RefreshBoundaryTests(unittest.TestCase):
    def test_unsafe_archive_is_rejected_before_any_files_are_written(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'dump.tar.gz'
            with tarfile.open(archive, 'w:gz') as handle:
                for name in ('src/cf/Configuration.xml', 'src/cf/../../outside'):
                    item = tarfile.TarInfo(name); item.size = 1
                    handle.addfile(item, io.BytesIO(b'x'))
            output = Path(directory) / 'output'; output.mkdir()
            with self.assertRaisesRegex(ValueError, 'unsafe'):
                extract_export(archive, output)
            self.assertEqual(list(output.iterdir()), [])

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
