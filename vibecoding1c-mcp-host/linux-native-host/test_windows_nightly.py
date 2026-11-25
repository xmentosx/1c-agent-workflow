import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / '.agents/skills/itl-remote-runner/scripts'))

from itl_remote.common import process_is_alive  # noqa: E402
import windows_nightly  # noqa: E402

# Stands in for 1cv8.exe: the real export script starts it through Start-Process,
# so cmd.exe and this Python are grandchildren of the nightly's PowerShell child.
FAKE_DESIGNER = ('@"%ITL_NIGHTLY_TEST_PYTHON%" -c "import os, pathlib, time; '
                 "pathlib.Path(os.environ['ITL_NIGHTLY_TEST_PIDS']).write_text("
                 "str(os.getpid()) + ' ' + str(os.getppid()), encoding='ascii'); time.sleep(120)\"\r\n")


class FakeGuard:
    def __init__(self, root, resources, operation, timeout):
        self.operation = operation

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def context(self):
        return {'encoded': 'test-context', 'key': b'test-key'}


@unittest.skipUnless(os.name == 'nt', 'Windows nightly export owns a Windows job object')
class WindowsNightlyExportTimeoutTests(unittest.TestCase):
    def test_export_timeout_terminates_designer_grandchildren(self):
        with tempfile.TemporaryDirectory(prefix='ночной экспорт ') as directory:
            root = Path(directory).resolve()
            base = root / 'bases/unf pm5'
            base.mkdir(parents=True)
            (base / '1Cv8.1CD').write_bytes(b'')
            designer = root / 'platform/8.5.4 платформа/1cv8.cmd'
            designer.parent.mkdir(parents=True)
            designer.write_text(FAKE_DESIGNER, encoding='ascii')
            pids = root / 'designer pids.txt'
            configuration = {'configId': 'unfpm5', 'sourcePath': str(root / 'sources/unf pm5'),
                             'mainConfigPath': 'src/cf',
                             'dump': {'platformPath': str(designer), 'infoBaseKind': 'file',
                                      'sourceInfoBasePath': str(base), 'logsPath': str(root / 'logs/unf pm5'),
                                      'repositoryPath': str(root / 'хранилище УНФ'), 'repositoryUser': 'nightly'}}
            config = {'rootPath': str(root), 'workflowPath': str(REPOSITORY_ROOT), 'guardRoot': str(root / 'guard'),
                      'stateRoot': str(root / 'state'), 'configurations': [configuration]}
            config_path = root / 'host config.json'
            config_path.write_text(json.dumps(config, ensure_ascii=False), encoding='utf-8')
            output = root / 'logs/nightly/export.log'
            output.parent.mkdir(parents=True)
            observed = []
            try:
                with patch.dict(os.environ, ITL_NIGHTLY_TEST_PYTHON=sys.executable, ITL_NIGHTLY_TEST_PIDS=str(pids)), \
                     patch('windows_nightly.EXPORT_TIMEOUT_SECONDS', 10), \
                     patch('windows_nightly.refresh_linux', side_effect=AssertionError('must not refresh')):
                    with self.assertRaises(subprocess.TimeoutExpired) as raised:
                        windows_nightly.export_and_refresh(config, configuration, config_path, FakeGuard,
                                                           lambda resources: resources, output=output)
                self.assertEqual(raised.exception.timeout, 10)
                self.assertTrue(pids.is_file(), 'the fake Designer grandchild never started: '
                                + output.read_text(encoding='utf-8', errors='replace'))
                observed = [int(value) for value in pids.read_text(encoding='ascii').split()]
                deadline = time.monotonic() + 10
                while any(process_is_alive(pid) for pid in observed) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertEqual([pid for pid in observed if process_is_alive(pid)], [])
            finally:
                for pid in observed:
                    if process_is_alive(pid):
                        with contextlib.suppress(OSError):
                            os.kill(pid, signal.SIGTERM)


class AiGatewayMaintenanceTests(unittest.TestCase):
    SCRIPT = r'C:\ITL\mcp-host\host\ai-gateway-maintenance.ps1'

    def config(self, **settings):
        return {'aiGatewayMaintenance': {'enabled': True, 'scriptPath': self.SCRIPT, **settings}}

    def test_disabled_does_not_touch_the_gateway(self):
        with patch('windows_nightly.subprocess.run', side_effect=AssertionError('must not run')):
            self.assertIsNone(windows_nightly.maintain_ai_gateway({}))
            self.assertIsNone(windows_nightly.maintain_ai_gateway({'aiGatewayMaintenance': {'enabled': False}}))

    def test_result_line_is_returned_and_failures_never_raise(self):
        completed = subprocess.CompletedProcess([], 0, stdout='noise\n{"status": "restarted", "egress": "vpn-auto"}\n', stderr='')
        with patch('windows_nightly.subprocess.run', return_value=completed) as run:
            self.assertEqual(windows_nightly.maintain_ai_gateway(self.config(timeoutSeconds=240))['status'], 'restarted')
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[arguments.index('-File') + 1], self.SCRIPT)
        self.assertEqual(arguments[-2:], ['-TimeoutSeconds', '240'])
        self.assertEqual(run.call_args.kwargs['timeout'], 420)
        silent = subprocess.CompletedProcess([], 3, stdout='', stderr='boom')
        with patch('windows_nightly.subprocess.run', return_value=silent):
            self.assertEqual(windows_nightly.maintain_ai_gateway(self.config())['status'], 'failed')
        with patch('windows_nightly.subprocess.run', side_effect=subprocess.TimeoutExpired('powershell', 480)):
            self.assertEqual(windows_nightly.maintain_ai_gateway(self.config())['status'], 'failed')

    def test_gateway_runs_before_indexing_and_its_failure_does_not_stop_it(self):
        with tempfile.TemporaryDirectory(prefix='ночной шлюз ') as directory:
            root = Path(directory)
            config = {'rootPath': str(root), 'workflowPath': str(REPOSITORY_ROOT),
                      'configurations': [{'configId': 'unfpm5'}, {'configId': 'erppm5'}], **self.config()}
            config_path = root / 'nightly config.json'
            config_path.write_text(json.dumps(config, ensure_ascii=False), encoding='utf-8')
            order = []
            gateway = {'status': 'degraded', 'message': 'still direct'}

            def export(config, configuration, *_args, **_kwargs):
                order.append(configuration['configId'])
                return {'configId': configuration['configId'], 'state': 'succeeded'}

            stdout, stderr = sys.stdout, sys.stderr
            try:
                with patch.object(sys, 'argv', ['windows_nightly.py', '--config', str(config_path)]), \
                     patch('windows_nightly.maintain_ai_gateway', side_effect=lambda _c: order.append('gateway') or gateway), \
                     patch('windows_nightly.export_and_refresh', side_effect=export):
                    self.assertEqual(windows_nightly.main(), 0)
            finally:
                sys.stdout.close()
                sys.stdout, sys.stderr = stdout, stderr
            self.assertEqual(order, ['gateway', 'unfpm5', 'erppm5'])
            state = json.loads((root / 'state/nightly-index-state.json').read_text(encoding='utf-8'))
            self.assertEqual(state['aiGateway'], gateway)
            self.assertEqual(state['state'], 'succeeded')


if __name__ == '__main__':
    unittest.main()
