"""Complete only a verified ITS fetch result; leave other native flows intact.

The native client owns discovery, the initial tool-call request, ACK, session
guards and deadlines. Only the ACK response for a matched ITS fetch is read here.
No HTTPX method is patched and no assistant completion is fabricated.
"""
from dataclasses import dataclass, field
import json
from urllib.parse import quote


class _FetchReady(BaseException):
    """Internal successful tool completion, not a transport error or cancellation."""
    def __init__(self, scope, result):
        self.scope, self.result = scope, result


@dataclass
class _FetchScope:
    client: object
    upstream_name: str
    arguments: dict
    assistant_uuid: str = ''
    call_id: str = ''
    data_lines: list = field(default_factory=list)
    reason: str = 'no_completed_tool_result'

    def observe(self, line):
        if line.startswith('data:'):
            self.data_lines.append(line[5:].lstrip(' '))
            try:
                value = json.loads('\n'.join(self.data_lines))
            except (ValueError, TypeError):
                return
            self.data_lines.clear()
            if isinstance(value, dict):
                self.event(value)
                return value
        elif not line:
            self.data_lines.clear()

    def event(self, value):
        if value.get('finished') is not True:
            return
        content = value.get('content')
        if not isinstance(content, dict):
            return
        if value.get('role') == 'assistant':
            self.bind_call(value.get('uuid'), content.get('tool_calls'))
            return
        if (value.get('role') != 'tool' or not self.call_id
                or value.get('parent_uuid') != self.assistant_uuid
                or content.get('tool_call_id') != self.call_id
                or content.get('name') != self.upstream_name
                or content.get('status') != 'ok'):
            if value.get('role') == 'tool':
                self.reason = 'tool_identity_or_status_mismatch'
            return
        structured = content.get('structured_content')
        document = structured.get('result') if isinstance(structured, dict) else None
        if not isinstance(document, dict) or document.get('truncated') is not False:
            self.reason = 'tool_result_not_complete'
            return
        text = document.get('content')
        if not isinstance(text, str) or not text.strip():
            self.reason = 'tool_result_empty'
            return
        self.reason = 'validated_tool_result'
        raise _FetchReady(self, {
            'assistant_uuid': None,
            'full_text': text, 'final_text': text, 'reasoning_text': '',
            'tool_calls': [], 'tool_results': [content],
            '_itl_fetch_completion': {
                'source': 'upstream_tool', 'assistant_synthesis': 'not_completed',
            },
        })

    def bind_call(self, assistant, calls):
        """Bind the complete call selected and checked by the native first round."""
        self.reason = 'assistant_without_matched_call'
        self.assistant_uuid = self.call_id = ''
        if not isinstance(calls, list) or len(calls) != 1:
            return
        call = calls[0]
        if not isinstance(call, dict):
            return
        function = call.get('function')
        if not isinstance(function, dict) or function.get('name') != self.upstream_name:
            return
        try:
            arguments = json.loads(function.get('arguments', ''))
        except (TypeError, ValueError):
            return
        if arguments != self.arguments:
            self.reason = 'arguments_mismatch'
            return
        call_id = call.get('id')
        if isinstance(assistant, str) and assistant and isinstance(call_id, str) and call_id:
            self.assistant_uuid, self.call_id = assistant, call_id
            self.reason = 'matched_call_waiting_for_tool'


def make_fetch_client(base):
    """Keep the native client's sessions, budgets and validation for every call."""
    class FetchClient(base):
        async def _collect_stream_inner(self, entry, payload, read_timeout=None):
            scope = getattr(entry, '_itl_fetch_scope', None)
            if scope is None or scope.client is not self:
                return await super()._collect_stream_inner(entry, payload, read_timeout)
            if not scope.call_id:
                # Keep the native parser and validation of the requested tool call.
                result = await super()._collect_stream_inner(entry, payload, read_timeout)
                scope.bind_call(result.get('assistant_uuid'), result.get('tool_calls'))
                return result
            from MCP_1copilot.api_client import ApiError, DirectToolError, UpstreamTransportError
            from MCP_1copilot.text_assembly import FragmentAccumulator
            import httpx
            url = self.base_url.rstrip('/') + '/chat_api/v1/conversations/' + quote(entry.conversation_id, safe='') + '/messages'
            text, reasoning, tools = FragmentAccumulator(), FragmentAccumulator(), []
            try:
                async with self.client.stream('POST', url, json=payload,
                        headers={'Accept': 'text/event-stream'}, timeout=self._stream_timeout(read_timeout)) as response:
                    if response.status_code != 200:
                        await response.aread()
                        details = self._extract_upstream_error(response)
                        raise ApiError(details.get('message', 'Upstream HTTP '+str(response.status_code)),
                                       status_code=response.status_code, data=details)
                    async for line in response.aiter_lines():
                        value = scope.observe(line)
                        if not isinstance(value, dict):
                            continue
                        delta, content = value.get('content_delta'), value.get('content')
                        if value.get('role') in (None, 'assistant'):
                            for fragment in (delta, content):
                                if isinstance(fragment, dict):
                                    text.add(fragment.get('content'))
                                    reasoning.add(fragment.get('reasoning_content'))
                        if value.get('role') == 'tool' and value.get('finished') is True and isinstance(content, dict):
                            tools.append(content)
                        if value.get('role') == 'assistant' and value.get('finished') is True:
                            entry.last_assistant_uuid = value.get('uuid')
                            return {'assistant_uuid': value.get('uuid'), 'full_text': text.text(),
                                    'final_text': content.get('content', '') if isinstance(content, dict) else '',
                                    'reasoning_text': reasoning.text(), 'tool_results': tools,
                                    'tool_calls': (content.get('tool_calls') or []) if isinstance(content, dict) else []}
            except httpx.HTTPError as error:
                raise UpstreamTransportError('ITS stream transport failed: '+type(error).__name__,
                                             capability='its.fetch', phase='stream') from error
            raise DirectToolError('ITS stream ended without a completed result', capability='its.fetch', phase='stream')

        async def _call_capability_guarded(self, entry, resolved, arguments, budget):
            if (resolved.capability != 'its.fetch' or not resolved.is_available
                    or set(arguments) != {'id'} or not isinstance(arguments['id'], str)
                    or not arguments['id']):
                return await super()._call_capability_guarded(entry, resolved, arguments, budget)
            scope = _FetchScope(self, resolved.upstream_name, dict(arguments))
            previous = getattr(entry, '_itl_fetch_scope', None)
            entry._itl_fetch_scope = scope
            try:
                return await super()._call_capability_guarded(entry, resolved, arguments, budget)
            except _FetchReady as ready:
                if ready.scope is not scope:
                    raise
                return ready.result
            finally:
                try:
                    from MCP_1copilot.observability import log_event
                    log_event('its_fetch_completion', reason=scope.reason,
                              matchedCall=bool(scope.call_id), capability='its.fetch')
                except Exception:
                    # Diagnostics cannot change the operation's result or cancellation.
                    pass
                if previous is None:
                    del entry._itl_fetch_scope
                else:
                    entry._itl_fetch_scope = previous

    FetchClient.__name__ = 'ItsFetchClient'
    return FetchClient
