"""FastMCP session cancellation; --native uses the pinned SDK, HTTP and .so."""
import ast
import asyncio
import inspect
from pathlib import Path
import sys
import unittest

from patch_fastmcp_lifecycle import patch_source

FIXTURE = '''class LowLevelServer:
    async def run(self, read_stream, write_stream, initialization_options, raise_exceptions=False, stateless=False):
        async with AsyncExitStack() as stack:
            session = await stack.enter_async_context(open_session())
            async with anyio.create_task_group() as tg:
                session._subscription_task_group = tg
                async for message in session.incoming_messages:
                    tg.start_soon(self._handle_message, message, session, lifespan_context, raise_exceptions)

    def other(self):
        return 'unchanged'
'''


class PatchTests(unittest.TestCase):
    def test_closing_transport_cancels_exact_session_group_in_finally(self):
        tree = ast.parse(patch_source(FIXTURE))
        group = next(n for n in ast.walk(tree) if isinstance(n, ast.AsyncWith)
                     and ast.unparse(n.items[0].context_expr) == 'anyio.create_task_group()')
        self.assertEqual(ast.unparse(group.body[0]), 'session._subscription_task_group = tg')
        self.assertIsInstance(group.body[1], ast.Try)
        self.assertEqual(ast.unparse(group.body[1].finalbody[0]), 'tg.cancel_scope.cancel()')
        self.assertEqual(len(group.body[1].body), 1)
        self.assertIsInstance(group.body[1].body[0], ast.AsyncFor)

    def test_only_dispatch_loop_changes_and_newlines_are_preserved(self):
        before, after = ast.parse(FIXTURE), ast.parse(patch_source(FIXTURE))
        self.assertEqual(ast.dump(before.body[0].body[1]), ast.dump(after.body[0].body[1]))
        crlf = patch_source(FIXTURE.replace('\n', '\r\n'))
        self.assertNotIn('\n', crlf.replace('\r\n', ''))

    def test_changed_owner_or_dispatch_fails_closed(self):
        for source in [FIXTURE.replace('LowLevelServer', 'OtherServer'),
                       FIXTURE.replace('session.incoming_messages', 'other_messages'),
                       FIXTURE.replace('raise_exceptions)', 'False)'),
                       FIXTURE.replace('session._subscription_task_group = tg', 'unrelated = tg')]:
            with self.subTest(source=source):
                with self.assertRaises(RuntimeError): patch_source(source)

    def test_does_not_apply_twice_or_accept_an_ambiguous_owner(self):
        for source in [patch_source(FIXTURE), FIXTURE+'\n'+FIXTURE]:
            with self.assertRaises(RuntimeError): patch_source(source)


class NativeOperation:
    """An actual binary-client request on an in-memory upstream, never code.1c.ai."""
    def __init__(self, deadline=3):
        self.deadline = deadline
        self.started, self.done = asyncio.Event(), asyncio.Event()
        self.state = {'active': False, 'opened': 0, 'closed': 0, 'finish': None}

    async def run(self):
        import httpx
        from datetime import datetime, timezone
        from MCP_1copilot.api_client import OneCApiClient, Config, OperationBudget, OperationTimeoutError
        from MCP_1copilot.capabilities import CapabilitySnapshot, SnapshotEntry
        from MCP_1copilot.session_registry import ScopeOwner
        from MCP_1copilot.fetch_completion import make_fetch_client
        client = make_fetch_client(OneCApiClient)(Config(onec_ai_token='offline-fixture', _env_file=None))
        await client.client.aclose()
        probe = self

        class Stream(httpx.AsyncByteStream):
            async def __aiter__(self):
                probe.state['opened'] += 1
                probe.started.set()
                while True:
                    await asyncio.sleep(.01)
                    yield b': waiting for first upstream response\n\n'

            async def aclose(self):
                probe.state['closed'] += 1

        async def upstream(request):
            return httpx.Response(200, headers={'content-type': 'text/event-stream'}, stream=Stream())

        client.client = httpx.AsyncClient(transport=httpx.MockTransport(upstream))
        name = 'mcp__knowledge-hub__Fetch_ITS'
        client.capabilities.set_snapshot(CapabilitySnapshot(True, datetime.now(timezone.utc), {
            name: SnapshotEntry(name, argument_names=('id',))}))
        entry = client.conversations.register(ScopeOwner('offline', 'lifecycle', 'fetch'),
                                              '12345678-1234-1234-1234-123456789abc')
        budget = OperationBudget(self.deadline)
        start = asyncio.get_running_loop().time()
        self.state['active'] = True
        try:
            return await client.call_capability(entry, 'its.fetch', {'id': 'root'}, budget)
        except asyncio.CancelledError:
            self.state['finish'] = 'cancelled'
            raise
        except OperationTimeoutError:
            self.state['finish'] = 'own_budget'
            return 'deadline'
        finally:
            self.state.update(active=False, guardReleased=not entry.guard.locked(),
                              inFlight=entry.in_flight, requestsIssued=budget.requests_issued,
                              elapsedMs=round((asyncio.get_running_loop().time()-start)*1000))
            value = client.close()
            if inspect.isawaitable(value): await value
            self.done.set()


if '--native' in sys.argv:
    sys.argv.remove('--native')
    import anyio
    import httpx
    from fastmcp import FastMCP

    class NativeLifecycleTests(unittest.IsolatedAsyncioTestCase):
        async def exercise(self, action, other_session=False):
            owner = FastMCP('ITLReadOnlyLifecycleTest')
            operations = {}

            @owner.tool()
            async def blocked(marker: str):
                operation = operations[marker]
                return await operation.run()

            @owner.tool()
            async def echo(value: str):
                return value

            app = owner.http_app(path='/mcp', stateless_http=False)
            async with app.router.lifespan_context(app):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://localhost') as client:
                    async def initialize():
                        headers = {'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json'}
                        response = await client.post('/mcp', headers=headers, json={'jsonrpc': '2.0', 'id': 0,
                            'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {},
                            'clientInfo': {'name': 'ITLReadOnlyProbe', 'version': '1'}}})
                        response.raise_for_status()
                        headers['mcp-session-id'] = response.headers['mcp-session-id']
                        response = await client.post('/mcp', headers=headers, json={'jsonrpc': '2.0', 'method': 'notifications/initialized'})
                        response.raise_for_status()
                        return headers

                    headers = await initialize()
                    operations['first'] = first = NativeOperation()
                    tasks = []
                    try:
                        tasks.append(asyncio.create_task(client.post('/mcp', headers=headers, json={
                            'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                            'params': {'name': 'blocked', 'arguments': {'marker': 'first'}}})))
                        await asyncio.wait_for(first.started.wait(), 1)
                        second_headers = None
                        if other_session:
                            second_headers = await initialize()
                            operations['second'] = second = NativeOperation()
                            tasks.append(asyncio.create_task(client.post('/mcp', headers=second_headers, json={
                                'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                'params': {'name': 'blocked', 'arguments': {'marker': 'second'}}})))
                            await asyncio.wait_for(second.started.wait(), 1)
                        start = asyncio.get_running_loop().time()
                        if action == 'delete':
                            response = await client.delete('/mcp', headers=headers)
                            self.assertEqual(response.status_code, 200)
                        else:
                            response = await client.post('/mcp', headers=headers, json={'jsonrpc': '2.0',
                                'method': 'notifications/cancelled', 'params': {'requestId': 1}})
                            self.assertEqual(response.status_code, 202)
                        await asyncio.wait_for(first.done.wait(), 1)
                        self.assertLess(asyncio.get_running_loop().time()-start, .5)
                        self.assertEqual(first.state['finish'], 'cancelled')
                        self.assertTrue(first.state['guardReleased'])
                        self.assertFalse(first.state['inFlight'])
                        self.assertFalse(first.state['active'])
                        self.assertEqual(first.state['opened'], 1)
                        self.assertEqual(first.state['closed'], 1)
                        self.assertEqual(first.state['requestsIssued'], 1)
                        if second_headers:
                            self.assertTrue(second.state['active'])
                            self.assertFalse(second.done.is_set())
                            response = await client.post('/mcp', headers=second_headers, json={'jsonrpc': '2.0',
                                'id': 2, 'method': 'tools/call', 'params': {'name': 'echo', 'arguments': {'value': 'alive'}}})
                            self.assertEqual(response.status_code, 200)
                            self.assertIn('alive', response.text)
                            await client.delete('/mcp', headers=second_headers)
                            await asyncio.wait_for(second.done.wait(), 1)
                            self.assertEqual(second.state['finish'], 'cancelled')
                        if action != 'delete': await client.delete('/mcp', headers=headers)
                        await asyncio.wait_for(asyncio.gather(*tasks), 1)
                    finally:
                        for task in tasks:
                            if not task.done(): task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)

        async def test_delete_cancels_native_request_and_releases_stream_and_guard(self):
            await self.exercise('delete')

        async def test_explicit_request_cancellation_still_releases_native_resources(self):
            await self.exercise('notification')

        async def test_closing_one_session_preserves_other_session_and_its_calls(self):
            await self.exercise('delete', other_session=True)


if __name__ == '__main__':
    unittest.main()
