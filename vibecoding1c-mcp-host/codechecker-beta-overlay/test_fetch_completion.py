"""ITS completion/deadline regressions; --native also exercises the pinned .so."""
import ast
import asyncio
import copy
from dataclasses import dataclass
import inspect
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from typing import Dict, Optional
import unittest

from fetch_completion import _FetchReady, _FetchScope, make_fetch_client
from patch_mcp_server import patch_fetch_source

NAME = 'mcp__knowledge-hub__Fetch_ITS'
TEXT = 'Проверочный документ ИТС: путь с пробелом.'


def events(item='root'):
    return [
        {'uuid': 'assistant-1', 'role': 'assistant', 'finished': True,
         'content': {'content': '', 'tool_calls': [{'id': 'call-1', 'type': 'function',
                     'function': {'name': NAME, 'arguments': json.dumps({'id': item})}}]}},
        {'uuid': 'tool-1', 'parent_uuid': 'assistant-1', 'role': 'tool', 'finished': True,
         'content': {'type': 'tool', 'content': TEXT, 'tool_call_id': 'call-1',
                     'name': NAME, 'status': 'ok',
                     'structured_content': {'result': {'content': TEXT, 'truncated': False}}}},
    ]


class FetchProofTests(unittest.TestCase):
    def scope(self):
        return _FetchScope(object(), NAME, {'id': 'root'})

    def test_returns_exact_document_and_explicitly_no_assistant_completion(self):
        scope = self.scope()
        first, tool = events()
        scope.event(first)
        with self.assertRaises(_FetchReady) as raised:
            scope.event(tool)
        result = raised.exception.result
        self.assertEqual(result['final_text'], TEXT)
        self.assertIsNone(result['assistant_uuid'])
        self.assertEqual(result['_itl_fetch_completion'], {'source': 'upstream_tool', 'assistant_synthesis': 'not_completed'})
        self.assertEqual(result['tool_results'], [tool['content']])

    def test_rejects_foreign_call_parent_name_and_unfinished_result(self):
        mutations = [('parent_uuid', 'other'), ('role', 'assistant'), ('finished', False),
                     ('content.tool_call_id', 'other'), ('content.name', 'other')]
        for path, value in mutations:
            with self.subTest(path=path):
                scope = self.scope()
                first, tool = events()
                scope.event(first)
                target = tool
                parts = path.split('.')
                for key in parts[:-1]: target = target[key]
                target[parts[-1]] = value
                scope.event(tool)

    def test_rejects_wrong_arguments_or_ambiguous_tool_calls(self):
        for change in ('arguments', 'name', 'multiple', 'missing_id'):
            with self.subTest(change=change):
                scope = self.scope()
                first, tool = events()
                calls = first['content']['tool_calls']
                if change == 'arguments': calls[0]['function']['arguments'] = '{"id":"superior"}'
                if change == 'name': calls[0]['function']['name'] = 'other'
                if change == 'multiple': calls.append(copy.deepcopy(calls[0]))
                if change == 'missing_id': calls[0]['id'] = ''
                scope.event(first)
                scope.event(tool)

    def test_rejects_error_empty_truncated_and_unstructured_results(self):
        for change in ('error', 'empty', 'partial', 'unknown_completeness', 'unstructured'):
            with self.subTest(change=change):
                scope = self.scope()
                first, tool = events()
                scope.event(first)
                content = tool['content']
                if change == 'error': content['status'] = 'error'
                elif change == 'unstructured': content['structured_content'] = None
                else:
                    result = content['structured_content']['result']
                    if change == 'empty': result['content'] = ' '
                    if change == 'partial': result['truncated'] = True
                    if change == 'unknown_completeness': result.pop('truncated')
                scope.event(tool)

    def test_multiline_sse_comments_and_invalid_events_do_not_fake_completion(self):
        scope = self.scope()
        scope.observe(': heartbeat')
        scope.observe('data: [DONE]')
        scope.observe('')
        for event in events()[:1]: scope.observe('data: '+json.dumps(event))
        text = json.dumps(events()[1], ensure_ascii=False, indent=2)
        with self.assertRaises(_FetchReady):
            for line in text.splitlines(): scope.observe('data: '+line)

    def test_other_capabilities_delegate_to_the_native_client_unchanged(self):
        class Base:
            def __init__(self): self.client = SimpleNamespace(event_hooks={})
            async def _call_capability_guarded(self, *args): return args
        client = make_fetch_client(Base)()
        args = (object(), SimpleNamespace(capability='syntax.validate', is_available=True), {'code': 'Возврат Истина;'}, object())
        self.assertEqual(asyncio.run(client._call_capability_guarded(*args)), args)

    def test_native_options_are_forwarded_without_reinterpretation(self):
        class Base:
            def __init__(self): self.client = SimpleNamespace(event_hooks={})
            async def _call_capability_guarded(self, *args, **kwargs): return args, kwargs
        client = make_fetch_client(Base)()
        entry = SimpleNamespace(conversation_id='fixture')
        args = (entry, SimpleNamespace(capability='its.fetch', is_available=True, upstream_name=NAME), {'id':'root'}, object())
        for positional, keywords in ((('native-note',), {}), ((), {'note':'native-note'})):
            self.assertEqual(asyncio.run(client._call_capability_guarded(*args, *positional, **keywords)),
                             (args + positional, keywords))
            self.assertFalse(hasattr(entry, '_itl_fetch_scope'))


FIXTURE = '''from dataclasses import dataclass
from typing import Dict, Optional
def _get_client():
    return OneCApiClient(None)
@dataclass
class DirectOutcome:
    text: str
    tool_results: list = None
    fallback_reason: object = None
async def _call_capability(owner, capability, arguments, fallback_prompt="", *, context=None, options=None):
    client = _get_client()
    resolved = client.resolve_capability(capability)
    if not resolved.is_available:
        return await _fallback(owner, fallback_prompt, 'unavailable', capability, context=context)
    budget = client.new_budget()
    try:
        result = await client.call_capability(None, capability, arguments, budget=budget)
    except UpstreamTransportError as e:
        return await _fallback(owner, fallback_prompt, 'transport', capability, context=context)
    text = result['text']
    return DirectOutcome(text=text, tool_results=[], fallback_reason=None)
async def _fallback(owner, fallback_prompt, reason, capability, diagnostic="", *, context=None):
    """Existing fallback."""
    if fallback_prompt:
        outcome = await _send_prompt(owner, fallback_prompt, context=context, is_fallback=True)
        return DirectOutcome(text=outcome.text, fallback_reason=reason)
    return DirectOutcome(text=diagnostic, fallback_reason=reason)
async def fetch_its(id='root') -> AnswerResult:
    if direct:
        return AnswerResult(answer=outcome.text, fallback_reason=outcome.fallback_reason)
    return AnswerResult(answer=outcome.text)
'''


class TransportError(Exception): pass
class TimeoutError_(TransportError):
    def __init__(self, message='', **kwargs): super().__init__(message)


class DeadlineTests(unittest.IsolatedAsyncioTestCase):
    def scope(self, available=True, failure=None, expired=False):
        budgets, prompts = [], []
        budget = SimpleNamespace(expired=lambda: expired, requests_issued=1)
        def new_budget(): budgets.append(budget); return budget
        async def call(*args, **kwargs):
            self.assertIs(kwargs['budget'], budget)
            if failure: raise failure
            return {'text': TEXT, '_itl_fetch_completion': {'source': 'upstream_tool'}}
        client = SimpleNamespace(new_budget=new_budget, resolve_capability=lambda _: SimpleNamespace(is_available=available), call_capability=call)
        async def prompt(*args, **kwargs):
            prompts.append(kwargs['budget'])
            return SimpleNamespace(text='fallback')
        scope = {'dataclass': dataclass, 'Optional': Optional, 'Dict': Dict, 'OperationBudget': object,
                 '_get_client': lambda: client, '_send_prompt': prompt,
                 'UpstreamTransportError': TransportError, 'OperationTimeoutError': TimeoutError_}
        tree = ast.parse(patch_fetch_source(FIXTURE))
        tree.body = [n for n in tree.body if getattr(n, 'name', '') in {'_call_capability', '_fallback', 'DirectOutcome'}]
        exec(compile(tree, '<patched-owner>', 'exec'), scope)
        return scope, budgets, prompts, budget

    async def test_direct_timeout_does_not_start_fallback(self):
        scope, budgets, prompts, _ = self.scope(failure=TimeoutError_())
        with self.assertRaises(TimeoutError_): await scope['_call_capability']('owner','its.fetch',{},'fallback')
        self.assertEqual(len(budgets), 1)
        self.assertEqual(prompts, [])

    async def test_transport_failure_and_unavailable_capability_share_one_budget(self):
        for available in (True, False):
            scope, budgets, prompts, budget = self.scope(available=available, failure=TransportError())
            await scope['_call_capability']('owner','its.fetch',{},'fallback')
            self.assertEqual(budgets, [budget])
            self.assertEqual(prompts, [budget])

    async def test_expired_fallback_cannot_open_a_fresh_budget(self):
        scope, budgets, prompts, _ = self.scope(failure=TransportError(), expired=True)
        with self.assertRaises(TimeoutError_): await scope['_call_capability']('owner','its.fetch',{},'fallback')
        self.assertEqual(len(budgets), 1)
        self.assertEqual(prompts, [])

    async def test_cancellation_is_not_a_fallback_reason(self):
        scope, _, prompts, _ = self.scope(failure=asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError): await scope['_call_capability']('owner','its.fetch',{},'fallback')
        self.assertEqual(prompts, [])

    async def test_success_preserves_tool_completion_metadata(self):
        scope, budgets, prompts, _ = self.scope()
        result = await scope['_call_capability']('owner','its.fetch',{},'fallback')
        self.assertEqual(result.completion, {'source': 'upstream_tool'})
        self.assertEqual(result.text, TEXT)
        self.assertEqual(len(budgets), 1)
        self.assertEqual(prompts, [])

    def test_patch_preserves_decorators_and_rejects_changed_owner_boundaries(self):
        source = FIXTURE.replace('async def fetch_its', '@mcp.tool()\nasync def fetch_its')
        result = patch_fetch_source(source)
        fetch = next(n for n in ast.parse(result).body if getattr(n,'name','') == 'fetch_its')
        self.assertEqual(len(fetch.decorator_list), 1)
        with self.assertRaises(RuntimeError): patch_fetch_source(result)
        with self.assertRaises(RuntimeError): patch_fetch_source(FIXTURE.replace('budget = client.new_budget()', 'budget = other()'))

    def test_unqualified_native_budget_layout_is_rejected(self):
        source = FIXTURE.replace('diagnostic="", *, context=None):', 'diagnostic="", *, context=None, budget=None):')
        with self.assertRaisesRegex(RuntimeError, 'Unqualified native shared-budget owner'):
            patch_fetch_source(source)


if '--native' in sys.argv:
    sys.argv.remove('--native')
    import httpx
    from datetime import datetime, timezone
    from MCP_1copilot.api_client import OneCApiClient, Config, OperationBudget
    from MCP_1copilot.capabilities import CapabilitySnapshot, SnapshotEntry
    from MCP_1copilot.session_registry import ScopeOwner

    class NativeFetchTests(unittest.IsolatedAsyncioTestCase):
        async def exercise(self, client_type, frames, *, capability='its.fetch', cancel=False, item='root', split_utf8=False, note=None):
            client = client_type(Config(onec_ai_token='offline-fixture', _env_file=None))
            hooks = client.client.event_hooks
            await client.client.aclose()
            closed, requests, yielded = [], [], []
            class Stream(httpx.AsyncByteStream):
                def __init__(self, number): self.number = number
                async def __aiter__(self):
                    yielded.append(self.number)
                    if split_utf8:
                        wire = ('data: '+json.dumps(frames[self.number], ensure_ascii=False)+'\r\n\r\n').encode('utf-8')
                        for byte in wire: yield bytes([byte])
                    else:
                        yield ('data: '+json.dumps(frames[self.number])+'\n\n').encode()
                    if self.number:
                        while True:
                            await asyncio.sleep(.005)
                            yield b': heartbeat\n\n'
                async def aclose(self): closed.append(self.number)
            async def handler(request):
                requests.append(json.loads(request.content))
                return httpx.Response(200, headers={'content-type':'text/event-stream'}, stream=Stream(len(requests)-1))
            client.client = httpx.AsyncClient(transport=httpx.MockTransport(handler), event_hooks=hooks)
            client.capabilities.set_snapshot(CapabilitySnapshot(True, datetime.now(timezone.utc), {NAME:SnapshotEntry(NAME, argument_names=('id',))}))
            entry = client.conversations.register(ScopeOwner('offline','fixture','fetch'),'12345678-1234-1234-1234-123456789abc')
            try:
                budget = OperationBudget(.08)
                if note is None:
                    task = asyncio.create_task(client.call_capability(entry,capability,{'id':item},budget))
                else:
                    task = asyncio.create_task(client.call_capability(entry,capability,{'id':item},budget,note=note))
                if cancel:
                    while 1 not in yielded: await asyncio.sleep(.001)
                    task.cancel()
                try:
                    result = await task
                    return result
                finally:
                    self.assertEqual(sorted(closed), [0,1])
                    self.assertFalse(entry.guard.locked())
                    self.assertFalse(entry.in_flight)
                    self.assertFalse(hasattr(entry, '_itl_fetch_scope'))
                    self.assertEqual(budget.requests_issued, len(requests))
            finally:
                value = client.close()
                if inspect.isawaitable(value): await value

        async def test_original_binary_waits_after_successful_tool_result(self):
            from MCP_1copilot.api_client import OperationTimeoutError
            with self.assertRaises(OperationTimeoutError): await self.exercise(OneCApiClient,events())

        async def test_adapter_completes_and_closes_actual_native_streams(self):
            result = await self.exercise(make_fetch_client(OneCApiClient),events())
            self.assertEqual(result['final_text'], TEXT)
            self.assertEqual(result['_itl_fetch_completion']['assistant_synthesis'], 'not_completed')

        async def test_utf8_and_crlf_split_across_native_chunks_preserve_exact_document(self):
            result = await self.exercise(make_fetch_client(OneCApiClient),events(),split_utf8=True)
            self.assertEqual(result['final_text'], TEXT)

        async def test_new_native_note_option_remains_compatible(self):
            if 'note' not in inspect.signature(OneCApiClient.call_capability).parameters:
                self.skipTest('The October 1 native ABI has no note option; its original regressions still run.')
            result = await self.exercise(make_fetch_client(OneCApiClient),events(),note='native-option-fixture')
            self.assertEqual(result['final_text'], TEXT)

        async def test_truncated_result_does_not_become_success(self):
            from MCP_1copilot.api_client import OperationTimeoutError
            frames = events(); frames[1]['content']['structured_content']['result']['truncated'] = True
            with self.assertRaises(OperationTimeoutError): await self.exercise(make_fetch_client(OneCApiClient),frames)

        async def test_cancellation_closes_both_native_responses(self):
            frames = events(); frames[1]['finished'] = False
            with self.assertRaises(asyncio.CancelledError): await self.exercise(make_fetch_client(OneCApiClient),frames,cancel=True)

        async def test_concurrent_native_calls_do_not_share_fetch_proofs(self):
            first, second = events('root'), events('superior')
            first[1]['content']['structured_content']['result']['content'] = TEXT+' root'
            second[1]['content']['structured_content']['result']['content'] = TEXT+' superior'
            client = make_fetch_client(OneCApiClient)
            a,b = await asyncio.gather(self.exercise(client,first),self.exercise(client,second,item='superior'))
            self.assertEqual(a['final_text'], TEXT+' root')
            self.assertEqual(b['final_text'], TEXT+' superior')


if __name__ == '__main__':
    unittest.main()
