"""Complete verified retrieval/search results; leave synthesis flows intact.

The native client owns discovery, the initial tool-call request, ACK, session
guards and deadlines. A scoped observer examines only the matched ACK stream; the native reader
retains parsing, error handling and request deadlines.
No HTTPX method is patched and no assistant completion is fabricated.
"""
from dataclasses import dataclass, field
import json
from urllib.parse import quote


# This allowlist describes direct result contracts, not tools a model may use
# while composing a review/configuration/rewrite answer. Keep exact arguments.
_RESULT_CONTRACTS = {
    'its.fetch': ('mcp__knowledge-hub__Fetch_ITS', frozenset({'id'})),
    'its.search': ('mcp__knowledge-hub__Search_ITS', frozenset({'query'})),
    'documentation.search': (
        'mcp__knowledge-hub__Search_Documentation', frozenset({'query', 'version'})),
}


def _has_result_contract(resolved, arguments):
    contract = _RESULT_CONTRACTS.get(resolved.capability)
    return (contract is not None and resolved.is_available
            and resolved.upstream_name == contract[0]
            and isinstance(arguments, dict) and set(arguments) == contract[1]
            and all(isinstance(value, str) and value.strip()
                    for value in arguments.values()))


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
    """Observe the ACK while the native reader retains deadlines and parsing."""
    import codecs
    import contextvars
    import re

    current = contextvars.ContextVar('itl_verified_its_fetch', default=None)

    def observed_stream(stream, scope):
        # HTTPX belongs to the native runtime; non-native contract tests are stdlib only.
        import httpx

        class ObservedStream(httpx.AsyncByteStream):
            def __init__(self, stream, scope):
                self.stream, self.scope = stream, scope

            async def __aiter__(self):
                decoder = codecs.getincrementaldecoder('utf-8')('strict')
                fragments, after_cr = [], False
                async for chunk in self.stream:
                    decoded = decoder.decode(chunk)
                    if decoded:
                        if after_cr and decoded.startswith('\n'):
                            decoded = decoded[1:]
                        after_cr = decoded.endswith('\r')
                        pieces = re.split(r'\r\n|\r|\n', decoded)
                        fragments.append(pieces[0])
                        for piece in pieces[1:]:
                            self.scope.observe(''.join(fragments))
                            fragments = [piece]
                    yield chunk
                tail = decoder.decode(b'', final=True)
                if tail:
                    fragments.append(tail)
                if fragments:
                    self.scope.observe(''.join(fragments))

            async def aclose(self):
                await self.stream.aclose()

        return ObservedStream(stream, scope)

    class FetchClient(base):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.client.event_hooks.setdefault('response', []).append(self._observe_its_ack)

        async def _observe_its_ack(self, response):
            scope = current.get()
            if scope is None or scope.client is not self or not scope.call_id:
                return
            import httpx
            if (response.request.method != 'POST' or response.status_code != 200
                    or response.headers.get('content-type', '').split(';', 1)[0].strip().lower() != 'text/event-stream'
                    or response.request.url != httpx.URL(self.base_url.rstrip('/') + '/chat_api/v1/conversations/' + quote(scope.conversation_id, safe='') + '/messages')):
                return
            response.stream = observed_stream(response.stream, scope)

        async def _collect_stream_inner(self, entry, payload, read_timeout=None):
            result = await super()._collect_stream_inner(entry, payload, read_timeout)
            scope = current.get()
            if (scope is not None and scope.client is self
                    and scope.conversation_id == entry.conversation_id and not scope.call_id):
                scope.bind_call(result.get('assistant_uuid'), result.get('tool_calls'))
            return result

        async def _call_capability_guarded(self, entry, resolved, arguments, budget, *native_args, **native_kwargs):
            if not _has_result_contract(resolved, arguments):
                return await super()._call_capability_guarded(entry, resolved, arguments, budget, *native_args, **native_kwargs)
            scope = _FetchScope(self, resolved.upstream_name, dict(arguments))
            scope.conversation_id = entry.conversation_id
            previous = getattr(entry, '_itl_fetch_scope', None)
            entry._itl_fetch_scope = scope
            token = current.set(scope)
            try:
                return await super()._call_capability_guarded(entry, resolved, arguments, budget, *native_args, **native_kwargs)
            except _FetchReady as ready:
                if ready.scope is not scope:
                    raise
                return ready.result
            finally:
                current.reset(token)
                try:
                    from MCP_1copilot.observability import log_event
                    log_event('its_fetch_completion', reason=scope.reason,
                              matchedCall=bool(scope.call_id), capability=resolved.capability)
                except Exception:
                    pass
                if previous is None:
                    del entry._itl_fetch_scope
                else:
                    entry._itl_fetch_scope = previous

    FetchClient.__name__ = 'ItsFetchClient'
    return FetchClient
