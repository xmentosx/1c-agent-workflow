import json
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time
import tempfile
import unittest

import endpoint_identity as identity


class MCPFixture:
    def __init__(self, name, tool):
        self.name, self.tool, self.busy, self.error = name, tool, False, False
        self.calls, self.closed = [], 0
        self.health_delay = 0
        self.schema = {'type': 'object', 'properties': {'description': {'type': 'string'}}}
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_DELETE(self):
                fixture.closed += 1
                self.send_response(204)
                self.end_headers()

            def do_POST(self):
                # Drain the POST body before closing the redirect response. An
                # unread body makes this HTTP/1.0 fixture reset Windows sockets.
                raw = self.rfile.read(int(self.headers['Content-Length']))
                if self.path == '/mcp':
                    self.send_response(307)
                    self.send_header('Location', '/mcp/')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                request = json.loads(raw)
                fixture.calls.append(request)
                method = request['method']
                if method == 'notifications/initialized':
                    self.send_response(202)
                    self.end_headers()
                    return
                if method == 'initialize':
                    result = {'protocolVersion': '2025-03-26', 'serverInfo': {'name': fixture.name}}
                elif method == 'tools/list':
                    result = {'tools': [{'name': fixture.tool, 'inputSchema': fixture.schema}]}
                elif method == 'tools/call':
                    if request['params']['name'] != fixture.tool:
                        raise AssertionError('A foreign MCP received a safe call')
                    result = {'structuredContent': {'ok': not fixture.error,
                                                   'index_in_progress': fixture.busy}}
                    time.sleep(fixture.health_delay)
                else:
                    raise AssertionError(method)
                body = ('event: message\ndata: ' + json.dumps({'jsonrpc': '2.0', 'id': request['id'],
                                                              'result': result}) + '\n\n').encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Mcp-Session-Id', 'fixture-session')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except ConnectionError:
                    # A deadline regression deliberately closes a slow reply.
                    pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_port
        self.url = f'http://127.0.0.1:{self.port}/mcp'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class EndpointIdentity(unittest.TestCase):
    def setUp(self):
        self.internal = MCPFixture('bookstack-product-docs', 'index_status')
        self.public = MCPFixture('sppr-knowledge', 'sppr_index_status')
        self.commands = []

    def tearDown(self):
        self.internal.close()
        self.public.close()

    def command_run(self, arguments, timeout=30):
        self.commands.append(arguments)
        if arguments[:2] == ['docker', 'inspect']:
            return json.dumps([{'Name': '/itl-bookstack', 'Id': 'a' * 64, 'State': {'Status': 'running'},
                                'NetworkSettings': {'Ports': {f'{self.internal.port}/tcp': [
                                    {'HostPort': str(self.public.port)}]}}}])
        self.assertEqual(arguments[:4], ['docker', 'exec', 'a' * 64, 'python'])
        # Execute the actual transported, self-contained script with no __file__.
        result = subprocess.run([sys.executable] + arguments[4:], capture_output=True,
                                text=True, encoding='utf-8', timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def check(self):
        return identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                       'index_status', timeout=2, run=self.command_run)

    def test_healthy_container_with_open_foreign_port_is_confirmed_without_foreign_tool_calls(self):
        result = self.check()
        self.assertEqual(result['status'], 'mismatch')
        self.assertEqual(result['container_id'], 'a' * 64)
        self.assertEqual(result['observed_servers'], ['sppr-knowledge'] * 2)
        self.assertEqual(sum(item['method'] == 'tools/list' for item in self.public.calls), 2)
        self.assertFalse(any(item['method'] == 'tools/call' for item in self.public.calls))
        self.assertEqual(self.public.closed, 2)

    def test_correct_public_endpoint_requires_safe_call_and_releases_sessions(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        result = self.check()
        self.assertEqual(result['status'], 'matched', result)
        self.assertTrue(result['health_passed'])
        self.assertEqual(sum(item['method'] == 'tools/call' for item in self.public.calls), 1)
        self.assertEqual(self.public.closed, 3)

    def test_active_internal_index_never_authorizes_restart(self):
        self.internal.busy = True
        self.assertEqual(self.check()['status'], 'indexing')

    def test_internal_health_failure_never_authorizes_restart(self):
        self.internal.error = True
        self.assertEqual(self.check()['status'], 'unverified')

    def test_slow_healthy_tool_uses_its_own_budget_through_the_real_child_transport(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.internal.health_delay = self.public.health_delay = 1.2
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                         'index_status', timeout=1, health_timeout=3, run=self.command_run)
        self.assertEqual(result['status'], 'matched', result)
        self.assertTrue(result['health_passed'])
        self.assertEqual(sum(call['method'] == 'tools/call' for call in self.public.calls), 1)

    def test_internal_health_timeout_retains_method_budget_and_duration_without_payload(self):
        self.internal.health_delay = 1.2
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                         'index_status', timeout=1, health_timeout=1, run=self.command_run)
        self.assertEqual(result['status'], 'unverified')
        self.assertEqual(result['stage'], 'internal safe health')
        self.assertEqual(result['method'], 'tools/call')
        self.assertEqual(result['timeoutSeconds'], 1)
        self.assertGreaterEqual(result['requestElapsedSeconds'], 1)
        self.assertFalse(self.public.calls)
        self.assertNotIn('structuredContent', json.dumps(result))

    def test_public_health_timeout_keeps_identity_checks_and_never_becomes_a_restart_signal(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.health_delay = 1.2
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                         'index_status', timeout=1, health_timeout=1, run=self.command_run)
        self.assertEqual(result['status'], 'unverified')
        self.assertEqual(result['stage'], 'public safe health')
        self.assertEqual(result['method'], 'tools/call')
        self.assertEqual(result['timeoutSeconds'], 1)
        self.assertEqual(sum(call['method'] == 'tools/list' for call in self.public.calls), 3)

    def test_real_connection_refusal_is_unverified_with_initialize_diagnostics(self):
        unused = ThreadingHTTPServer(('127.0.0.1', 0), BaseHTTPRequestHandler)
        url = f'http://127.0.0.1:{unused.server_port}/mcp'
        unused.server_close()
        with self.assertRaises(identity.ProbeError) as caught:
            identity.read_endpoint(url, timeout=1, health_timeout=3)
        self.assertEqual(caught.exception.method, 'initialize')
        self.assertEqual(caught.exception.timeout, 1)

    def test_same_server_name_with_wrong_schema_is_still_foreign(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.schema['properties']['description']['type'] = 'integer'
        self.assertEqual(self.check()['status'], 'mismatch')

    def test_documentation_text_does_not_change_the_structural_identity(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.schema['description'] = 'Different documentation'
        self.assertEqual(self.check()['status'], 'matched')

    def test_child_timeout_is_unverified_and_never_a_restart_signal(self):
        def unavailable(arguments, timeout=30):
            raise subprocess.TimeoutExpired('fixture', timeout)
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                         'index_status', run=unavailable)
        self.assertEqual(result['status'], 'unverified')

    def test_unicode_path_and_health_arguments_survive_the_real_child_transport(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        with tempfile.TemporaryDirectory(prefix='MCP проверка с пробелом ') as root:
            source = Path(root) / 'проверка endpoint.py'
            source.write_bytes(Path(identity.__file__).read_bytes())
            spec = importlib.util.spec_from_file_location('unicode_probe', source)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            arguments = {'description': r'C:\Данные проекта\проверка с пробелом.json'}
            result = module.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                           'index_status', arguments, timeout=2, run=self.command_run)
            self.assertEqual(result['status'], 'matched', result)
            for fixture in (self.internal, self.public):
                call = next(item for item in fixture.calls if item['method'] == 'tools/call')
                self.assertEqual(call['params']['arguments'], arguments)


if __name__ == '__main__':
    unittest.main()
