import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('watchdog', Path(__file__).with_name('watchdog.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class RecoveryBoundaries(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix='host проверка с пробелом ')
        root = Path(self.root.name).resolve()
        self.config = {'hostId': 'dev-example', 'containers': ['itl-test-code', 'itl-test-graph'],
                       'composePath': str(root / 'compose.yml'), 'lockPath': str(root / 'maintenance.lock'),
                       'statusPath': str(root / 'status.json')}
        self.calls = []
        self.items = {}
        for index, name in enumerate(self.config['containers']):
            self.items[name] = {'Name': '/' + name, 'Id': str(index + 1) * 64,
                                'Config': {'Labels': {host.LABEL: 'dev-example'}},
                                'State': {'Status': 'running', 'Health': {'Status': 'healthy'}}}
        self.compose = {'services': {name: {'container_name': name, 'labels': {host.LABEL: 'dev-example'},
                                          'image': 'example@sha256:' + 'a' * 64}
                                     for name in self.config['containers']}}

    def tearDown(self):
        self.root.cleanup()

    def run_command(self, args, timeout=30):
        self.calls.append(args)
        if args[:3] == ['docker', 'container', 'ls']:
            return '\n'.join(self.items) + '\nforeign-container\n'
        if args[:2] == ['docker', 'inspect']:
            return json.dumps([self.items[args[2]]])
        if args[-3:] == ['config', '--format', 'json']:
            return json.dumps(self.compose)
        return ''

    def mutations(self):
        return [a for a in self.calls if a[:2] in (['docker', 'start'], ['docker', 'restart'], ['systemctl', 'restart']) or 'up' in a]

    def test_foreign_identity_prevents_recovery_of_every_target(self):
        self.items['itl-test-code']['State']['Health']['Status'] = 'unhealthy'
        self.items['itl-test-graph']['Config']['Labels'][host.LABEL] = 'foreign-host'
        with self.assertRaisesRegex(ValueError, 'ownership mismatch'):
            host.recover(self.config, self.run_command)
        self.assertEqual(self.mutations(), [])

    def test_restart_uses_validated_id_and_preserves_healthy_and_foreign_containers(self):
        self.items['itl-test-code']['State']['Health']['Status'] = 'unhealthy'
        result = host.recover(self.config, self.run_command)
        self.assertEqual(result['actions'], ['restarted:itl-test-code'])
        self.assertEqual(self.mutations(), [['docker', 'restart', '--time', '20', '1' * 64]])

    def endpoint(self):
        self.config['mcpEndpoints'] = [{'container': 'itl-test-code', 'url': 'http://host:22100/mcp',
                                       'hostPort': 22100, 'healthTool': 'stats'}]

    def test_foreign_public_endpoint_restarts_only_its_owned_id_and_requalifies(self):
        self.endpoint()
        results = iter([{'status': 'mismatch', 'container_id': '1' * 64},
                        {'status': 'matched', 'health_passed': True}])
        result = host.recover(self.config, self.run_command, lambda *a, **k: next(results))
        self.assertEqual(result['actions'], ['endpoint-restarted:itl-test-code'])
        self.assertEqual(self.mutations(), [['docker', 'restart', '--time', '20', '1' * 64]])
        self.assertEqual(result['endpoints'][0]['status'], 'matched')

    def test_unverified_or_indexing_endpoint_does_not_restart(self):
        self.endpoint()
        for status in ('unverified', 'indexing'):
            self.calls.clear()
            result = host.recover(self.config, self.run_command, lambda *a, **k: {'status': status})
            self.assertEqual(self.mutations(), [])
            self.assertNotEqual(result['status'], 'recovered')

    def test_owner_uses_shared_health_budget_and_keeps_timeout_diagnostics(self):
        self.endpoint()
        def probe(*args, **kwargs):
            self.assertEqual(kwargs['timeout'], 5)
            self.assertEqual(kwargs['health_timeout'], host.HEALTH_TIMEOUT_SECONDS)
            return {'status': 'unverified', 'reason': 'TimeoutError', 'stage': 'public safe health',
                    'method': 'tools/call', 'timeoutSeconds': 30, 'elapsedSeconds': 30.1}
        result = host.recover(self.config, self.run_command, probe)
        self.assertEqual(result['status'], 'degraded')
        self.assertEqual(result['endpoints'][0]['method'], 'tools/call')
        self.assertEqual(self.mutations(), [])

    def test_second_mismatch_stops_after_one_restart(self):
        self.endpoint()
        with self.assertRaisesRegex(RuntimeError, 'after one restart'):
            host.recover(self.config, self.run_command,
                         lambda *a, **k: {'status': 'mismatch', 'container_id': '1' * 64})
        self.assertEqual(len(self.mutations()), 1)

    def test_probe_cannot_replace_the_validated_container_id(self):
        self.endpoint()
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            host.recover(self.config, self.run_command,
                         lambda *a, **k: {'status': 'mismatch', 'container_id': 'f' * 64})
        self.assertEqual(self.mutations(), [])

    def test_missing_container_cannot_expand_compose_ownership(self):
        del self.items['itl-test-code']
        self.compose['services']['foreign'] = {'container_name': 'foreign-container'}
        with self.assertRaisesRegex(ValueError, 'allowlist'):
            host.recover(self.config, self.run_command)
        self.assertEqual(self.mutations(), [])

    def test_compose_requires_owned_digest_pins_before_restore(self):
        del self.items['itl-test-code']
        self.compose['services']['itl-test-code']['image'] = 'example:latest'
        with self.assertRaisesRegex(ValueError, 'pinned'):
            host.recover(self.config, self.run_command)
        self.assertEqual(self.mutations(), [])

    @unittest.skipUnless(os.name == 'posix', 'OS lock is exercised on the Linux backend')
    def test_index_lease_blocks_a_real_second_process_and_releases_after_exit(self):
        path = Path(self.root.name) / 'конфигурация хоста.json'
        path.write_text(json.dumps(self.config), encoding='utf-8')
        with host.maintenance_lock(self.config['lockPath']) as acquired:
            self.assertTrue(acquired)
            result = subprocess.run([sys.executable, str(Path(host.__file__)), '--config', str(path)],
                                    capture_output=True, text=True, encoding='utf-8', timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['status'], 'maintenance-active')
        with host.maintenance_lock(self.config['lockPath']) as acquired:
            self.assertTrue(acquired)


if __name__ == '__main__':
    unittest.main()
