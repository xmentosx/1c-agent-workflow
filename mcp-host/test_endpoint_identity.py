import json
import shutil
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
        self.heartbeat = False
        self.header_drip = False
        self.close_delay = 0
        self.redirect_to_slash = True
        self.redirect_health = False
        self.redirects = 0
        self.schema = {'type': 'object', 'properties': {'description': {'type': 'string'}}}
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_DELETE(self):
                fixture.closed += 1
                time.sleep(fixture.close_delay)
                self.send_response(204)
                self.end_headers()

            def do_POST(self):
                # Drain the POST body before closing the redirect response. An
                # unread body makes this HTTP/1.0 fixture reset Windows sockets.
                raw = self.rfile.read(int(self.headers['Content-Length']))
                if self.path == '/mcp' and fixture.redirect_to_slash:
                    fixture.redirects += 1
                    self.send_response(307)
                    self.send_header('Location', '/mcp/')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                request = json.loads(raw)
                if fixture.redirect_health and request['method'] == 'tools/call':
                    fixture.redirects += 1
                    self.send_response(307)
                    self.send_header('Location', '/later')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
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
                    if fixture.header_drip:
                        try:
                            self.wfile.write(b'HTTP/1.0 200 OK\r\n')
                            for _ in range(40):
                                self.wfile.write(b'X-Heartbeat: yes\r\n')
                                self.wfile.flush()
                                time.sleep(0.05)
                            self.wfile.write(b'\r\n')
                        except ConnectionError:
                            pass
                        return
                    if fixture.heartbeat:
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.end_headers()
                        try:
                            for _ in range(40):
                                self.wfile.write(b': heartbeat\n\n')
                                self.wfile.flush()
                                time.sleep(0.05)
                        except ConnectionError:
                            pass
                        return
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

    def test_exact_qualification_reports_redirect_without_following_or_calling_tools(self):
        started = time.monotonic()
        with self.assertRaises(identity.ProbeError) as caught:
            identity.read_endpoint(self.public.url, timeout=1, exact_endpoint=True)
        error = identity.failure(caught.exception, 'public identity', started)
        self.assertEqual(error['reason'], 'EndpointRedirectError')
        self.assertEqual(error['originalUrl'], self.public.url)
        self.assertEqual(error['httpStatus'], 307)
        self.assertEqual(error['location'], '/mcp/')
        self.assertEqual(self.public.redirects, 1)
        self.assertEqual(self.public.calls, [])
        self.assertEqual(self.public.closed, 0)

    def test_canonical_candidate_is_qualified_exactly_and_preserves_public_origin(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                        'index_status', timeout=2, run=self.command_run, qualify_url=True)
        self.assertEqual(result['status'], 'matched', result)
        self.assertTrue(result['health_passed'])
        self.assertEqual(result['original_url'], self.public.url)
        self.assertEqual(result['qualified_url'], self.public.url + '/')
        self.assertEqual(self.public.redirects, 1)
        self.assertEqual(sum(item['method'] == 'tools/list' for item in self.public.calls), 3)
        self.assertEqual(sum(item['method'] == 'tools/call' for item in self.public.calls), 1)
        self.assertEqual(self.public.closed, 3)

    def test_a_direct_endpoint_keeps_its_unsuffixed_path(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.redirect_to_slash = False
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                        'index_status', timeout=2, run=self.command_run, qualify_url=True)
        self.assertEqual(result['status'], 'matched', result)
        self.assertTrue(result['health_passed'])
        self.assertEqual(result['qualified_url'], self.public.url)
        self.assertEqual(self.public.redirects, 0)

    def test_redirect_during_exact_safe_call_remains_a_failed_health_proof(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.redirect_health = True
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                        'index_status', timeout=2, run=self.command_run, qualify_url=True)
        self.assertFalse(result['health_passed'])
        self.assertEqual(result['health_error']['reason'], 'EndpointRedirectError')
        self.assertEqual(result['health_error']['originalUrl'], self.public.url + '/')
        self.assertEqual(result['health_error']['httpStatus'], 307)
        self.assertEqual(result['health_error']['location'], '/later')
        self.assertFalse(any(item['method'] == 'tools/call' for item in self.public.calls))

    def test_canonical_candidate_cannot_change_public_origin_or_query(self):
        for candidate in ('https://server:8006/mcp/', 'http://other:8006/mcp/',
                          'http://server:9006/mcp/', 'http://server:8006/mcp/?token=new',
                          'http://server:8006/mcp/#ignored'):
            with self.subTest(candidate=candidate):
                with self.assertRaises(ValueError):
                    identity.canonical_endpoint('http://server:8006/mcp', candidate)

    def test_dripping_headers_cannot_extend_health_deadline(self):
        self.public.header_drip = True
        started = time.monotonic()
        result = identity.read_endpoint(self.public.url, timeout=0.3,
                                        health_tool=self.public.tool, health_timeout=0.2)
        self.assertTrue(result['signature'])
        self.assertFalse(result['health_passed'])
        self.assertEqual(result['health_error']['method'], 'tools/call')
        self.assertLess(time.monotonic() - started, 1.0)

    def test_session_delete_has_its_own_absolute_cleanup_budget(self):
        self.public.close_delay = 1.5
        started = time.monotonic()
        result = identity.read_endpoint(self.public.url, timeout=0.2)
        self.assertTrue(result['signature'])
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(self.public.closed, 1)

    @unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('git'),
                         'Windows owner integration requires PowerShell and Git')
    def test_stale_publication_recovers_through_git_owner_sync_and_original_read(self):
        # This is a real loopback MCP client reconnect, not a claim that Codex
        # exposes its owning App Server connection to an external process.
        with tempfile.TemporaryDirectory(prefix='itl MCP ') as temporary:
            root = Path(temporary) / '\u0423\u0444\u0430 PM5'
            root.mkdir()
            project = root / 'project'
            (project / '.agent-1c').mkdir(parents=True)
            (project / '.agent-1c' / 'project.json').write_text(
                json.dumps({'aiRules': {'tools': ['codex', 'claude-code']}}), encoding='utf-8')
            publisher, registry = root / 'published registry', root / 'cached registry'
            publisher.mkdir()

            def git(*arguments):
                return subprocess.check_output(['git', *map(str, arguments)], stderr=subprocess.STDOUT,
                                               encoding='utf-8').strip()

            git('init', '--quiet', publisher)
            git('-C', publisher, 'config', 'user.email', 'fixture@example.com')
            git('-C', publisher, 'config', 'user.name', 'Fixture')
            self.internal.name = self.public.name = '1C-docs-mcp'
            self.internal.tool = self.public.tool = 'health'
            previous_proof = identity.read_endpoint(self.internal.url, health_tool='health', timeout=1)
            self.assertTrue(previous_proof['health_passed'])
            endpoint = {'id': 'docs', 'scope': 'global', 'family': 'vibecoding1c',
                        'provider': 'remote', 'name': '1C-docs-mcp', 'hostId': 'chosen',
                        'url': self.internal.url, 'status': 'running'}

            def publish(message):
                (publisher / 'registry.json').write_text(json.dumps({
                    'schemaVersion': 1, 'host': {'hostId': 'chosen'},
                    'servers': [endpoint], 'configurations': []}), encoding='utf-8')
                git('-C', publisher, 'add', 'registry.json')
                git('-C', publisher, 'commit', '--quiet', '-m', message)

            publish('old')
            git('clone', '--quiet', publisher, registry)
            helper = Path(__file__).resolve().parents[1] / '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
            script = root / 'owner integration.ps1'
            script.write_text(r"""param($Helper,$Project,$Registry,$Publisher,$Mode)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$caseMode=$Mode
. $Helper -ProjectRoot $Project -Action help *> $null
function Get-Vibecoding1cMcpRegistryRoot { $Registry }
function Test-Vibecoding1cMcpRegistryPathOverride { $false }
function Get-Vibecoding1cMcpRegistryRepo { $Publisher }
function Read-Vibecoding1cMcpManifest { @{servers=@(@{id='docs';scope='global';name='1C-docs-mcp'})} }
function Get-Vibecoding1cMcpTargetScopes { @('global') }
function Get-Vibecoding1cMcpCurrentEndpoints { @() }
function Write-ItlOnDemandMcpClientConfig { $null }
function Sync-ItlUiToolsMcp { $null }
if($caseMode -eq 'seed'){
 Write-Vibecoding1cMcpSelection -Selection @{defaultProvider='remote';servers=@(@{id='docs';provider='remote';enabled=$true;hostId='chosen'})}
 Write-Vibecoding1cMcpClientConfig -Client claude-code
}else{ Sync-ItlClientMcpConfig -Client claude-code }
""", encoding='utf-8-sig')

            def owner(mode):
                return subprocess.check_output(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', str(script), str(helper), str(project), str(registry), str(publisher), mode],
                    stderr=subprocess.STDOUT, timeout=60).decode('utf-8')

            owner('seed')
            self.internal.close()
            with self.assertRaises(identity.ProbeError):
                identity.Client(endpoint['url'], 0.3)
            endpoint['url'] = self.public.url
            publish('recovered')
            # Verify the new publication before touching the client config.
            proof = identity.read_endpoint(endpoint['url'], health_tool=self.public.tool, timeout=1,
                                           expected_signature=previous_proof['signature'])
            self.assertTrue(proof['health_passed'])
            report = owner('sync')
            self.assertEqual(git('-C', registry, 'rev-parse', 'HEAD'), git('-C', publisher, 'rev-parse', 'HEAD'))
            config = json.loads((project / '.mcp.json').read_text(encoding='utf-8-sig'))
            configured = config['mcpServers']['1C-docs-mcp']['url']
            self.assertEqual(configured, self.public.url)
            self.assertIn('does not attach servers to an already open chat', report)
            # Supported reconnect of this test's owning client, then original read.
            client = identity.Client(configured, 1)
            try:
                self.assertEqual(client.request('tools/list')['tools'][0]['name'], self.public.tool)
                result = client.request('tools/call', {'name': self.public.tool, 'arguments': {}})
                self.assertTrue(identity.payload(result)['ok'])
            finally:
                client.close()
            selection = json.loads((project / '.agent-1c/mcp/vibecoding1c-selection.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(selection['servers'][0]['hostId'], 'chosen')

    def test_fetch_its_timeout_keeps_identity_and_recovery_resumes_without_init(self):
        self.public.name, self.public.tool = 'codechecker', 'fetch_its'
        self.public.health_delay = 0.6
        proof = identity.read_endpoint(self.public.url, timeout=1,
                                       health_tool='fetch_its', health_arguments={'topic': 'root'},
                                       health_timeout=0.1)
        self.assertTrue(proof['signature'])
        self.assertFalse(proof['health_passed'])
        self.assertEqual(proof['health_error']['method'], 'tools/call')
        self.public.health_delay = 0
        resumed = identity.read_endpoint(self.public.url, timeout=1, health_tool='fetch_its',
                                         expected_signature=proof['signature'])
        self.assertTrue(resumed['health_passed'])
        self.assertEqual(proof['signature'], resumed['signature'])

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
        self.assertEqual(result['health_error']['stage'], 'safe health')
        self.assertEqual(result['health_error']['method'], 'tools/call')
        self.assertEqual(result['health_error']['timeoutSeconds'], 1)
        self.assertGreaterEqual(result['health_error']['requestElapsedSeconds'], 1)
        self.assertEqual(sum(item['method'] == 'tools/list' for item in self.public.calls), 2)
        self.assertFalse(any(item['method'] == 'tools/call' for item in self.public.calls))
        self.assertNotIn('structuredContent', json.dumps(result))

    def test_public_health_timeout_keeps_identity_checks_and_never_becomes_a_restart_signal(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.public.health_delay = 1.2
        result = identity.check_endpoint('itl-bookstack', self.public.url, self.public.port,
                                         'index_status', timeout=1, health_timeout=1, run=self.command_run,
                                         qualify_url=True)
        self.assertEqual(result['status'], 'matched')
        self.assertEqual(result['qualified_url'], self.public.url + '/')
        self.assertFalse(result['health_passed'])
        self.assertEqual(result['health_error']['stage'], 'safe health')
        self.assertEqual(result['health_error']['method'], 'tools/call')
        self.assertEqual(result['health_error']['timeoutSeconds'], 1)
        self.assertEqual(sum(call['method'] == 'tools/list' for call in self.public.calls), 3)

    def test_matched_identity_survives_internal_optional_health_error(self):
        self.public.name, self.public.tool = self.internal.name, self.internal.tool
        self.internal.error = True
        result = self.check()
        self.assertEqual(result['status'], 'matched')
        self.assertFalse(result['health_passed'])
        self.assertEqual(result['health_error']['method'], 'tools/call')

    def test_sse_heartbeat_cannot_extend_elapsed_health_budget(self):
        self.public.heartbeat = True
        started = time.monotonic()
        proof = identity.read_endpoint(self.public.url, timeout=1, health_tool=self.public.tool,
                                       health_timeout=0.3)
        self.assertLess(time.monotonic() - started, 1.2)
        self.assertFalse(proof['health_passed'])
        self.assertEqual(proof['health_error']['method'], 'tools/call')
        self.assertEqual(proof['health_error']['timeoutSeconds'], 0.3)

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
