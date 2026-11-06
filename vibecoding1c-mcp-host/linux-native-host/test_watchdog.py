import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

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


class StatusWriteBoundaries(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix='статус хоста с пробелом ')
        self.path = Path(self.root.name) / 'состояние обновления.json'
        host.write_status(self.path, {'state': 'старое'})

    def tearDown(self):
        self.root.cleanup()

    @unittest.skipUnless(os.name == 'nt', 'Windows rename sharing denial')
    def test_transient_windows_reader_is_retried_and_replaces_status(self):
        reader = self.path.open('rb')
        release = threading.Timer(0.2, reader.close)
        original_replace = os.replace
        try:
            with patch.object(host.os, 'replace', wraps=original_replace) as replacing:
                release.start()
                host.write_status(self.path, {'state': 'новое'})
                self.assertGreater(replacing.call_count, 1)
        finally:
            release.cancel()
            if release.ident is not None:
                release.join()
            reader.close()
        self.assertEqual(json.loads(self.path.read_text(encoding='utf-8')), {'state': 'новое'})
        self.assertEqual(list(Path(self.root.name).glob('*.tmp')), [])

    def test_persistent_denial_is_bounded_and_keeps_previous_status(self):
        denied = PermissionError(13, 'denied')
        denied.winerror = 5
        with patch.object(host.os, 'replace', side_effect=denied) as replacing, \
                patch.object(host.time, 'perf_counter', side_effect=[0.0, 0.0, 0.6, 1.1]), \
                patch.object(host.time, 'sleep'):
            with self.assertRaises(PermissionError) as failure:
                host.write_status(self.path, {'state': 'новое'})
        self.assertIs(failure.exception, denied)
        self.assertGreater(replacing.call_count, 1)
        self.assertEqual(json.loads(self.path.read_text(encoding='utf-8')), {'state': 'старое'})
        self.assertEqual(list(Path(self.root.name).glob('*.tmp')), [])

    def test_unrelated_replace_failure_is_not_retried(self):
        failure = OSError(22, 'invalid operation')
        with patch.object(host.os, 'replace', side_effect=failure) as replacing:
            with self.assertRaises(OSError):
                host.write_status(self.path, {'state': 'новое'})
        self.assertEqual(replacing.call_count, 1)
        self.assertEqual(json.loads(self.path.read_text(encoding='utf-8')), {'state': 'старое'})


if __name__ == '__main__':
    unittest.main()
