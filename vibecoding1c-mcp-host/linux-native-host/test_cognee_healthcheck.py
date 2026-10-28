import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location(
    'cognee_healthcheck', Path(__file__).with_name('cognee_healthcheck.py'))
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class CogneeProbe(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.credential = self.root / 'credential.json'
        self.credential.write_text(json.dumps({'apiKey': 'private-marker'}))
        (self.root / 'memory.current').write_text('95')
        (self.root / 'memory.max').write_text('100')
        self.calls = []

    def run_probe(self, replies=None, free=10 * 1024**3, clock=lambda: 0):
        replies = list(replies if replies is not None else [
            {'id': 'ordinary', 'is_superuser': False}, [{'id': 'dataset'}]])

        def open_url(request, timeout):
            self.calls.append((request.get_method(), request.full_url, timeout))
            self.assertEqual(request.get_header('X-api-key'), 'private-marker')
            item = replies.pop(0)
            if isinstance(item, Exception):
                raise item
            return contextlib.closing(io.BytesIO(json.dumps(item).encode()))

        return health.probe(self.credential, 'ordinary', cgroup=self.root,
                            open_url=open_url,
                            disk_usage=lambda _: SimpleNamespace(free=free),
                            clock=clock)

    def test_authenticated_read_only_probe_and_pressure_telemetry(self):
        result = self.run_probe(free=4 * 1024**3)
        self.assertEqual(result['status'], 'healthy')
        self.assertEqual(result['datasetCount'], 1)
        self.assertEqual(self.calls, [
            ('GET', 'http://127.0.0.1:8000/api/v1/users/me', 8),
            ('GET', 'http://127.0.0.1:8000/api/v1/datasets', 8)])
        self.assertEqual(result['warnings'], [
            'data-disk-reserve-under-5GiB', 'memory-at-least-90-percent'])
        self.assertNotIn('private-marker', json.dumps(result))

    def test_auth_failure_is_redacted_and_never_retried(self):
        error = urllib.error.HTTPError('secret-url', 403, 'private-marker', {}, None)
        result = self.run_probe([error])
        self.assertEqual(result['status'], 'unhealthy')
        self.assertEqual(result['reason'], 'api-http-403')
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn('private-marker', json.dumps(result))

    def test_foreign_or_admin_identity_never_probes_datasets(self):
        for user in [{'id': 'other', 'is_superuser': False},
                     {'id': 'ordinary', 'is_superuser': True}]:
            with self.subTest(user=user):
                self.calls.clear()
                result = self.run_probe([user])
                self.assertEqual(result['reason'], 'ordinary-principal-mismatch')
                self.assertEqual(len(self.calls), 1)

    def test_disk_exhaustion_reports_unhealthy_without_recovery(self):
        result = self.run_probe(free=1024)
        self.assertEqual(result['reason'], 'data-disk-low')
        self.assertEqual(result['status'], 'unhealthy')
        self.assertNotIn('actions', result)

    def test_one_deadline_bounds_both_reads_and_redacts_transport_errors(self):
        times = iter([0, 0, 9, 9])
        result = self.run_probe(clock=lambda: next(times))
        self.assertEqual(result['reason'], 'TimeoutError')
        self.assertEqual(len(self.calls), 1)
        self.calls.clear()
        result = self.run_probe([OSError('private-marker')])
        self.assertEqual(result['reason'], 'OSError')
        self.assertNotIn('private-marker', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
