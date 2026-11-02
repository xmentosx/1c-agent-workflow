"""Small native MCP HTTP client for dedicated host operations."""
import json
import urllib.request


class Client:
    def __init__(self, url, timeout=90):
        self.url, self.timeout, self.session, self.sequence = url, timeout, None, 0
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.request('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                   'clientInfo': {'name': 'itl-native-host', 'version': '1'}})
        self.request('notifications/initialized', notification=True)

    def request(self, method, params=None, notification=False):
        self.sequence += 1
        body = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            body['id'] = self.sequence
        if params is not None:
            body['params'] = params
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                   'MCP-Protocol-Version': '2025-03-26'}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        request = urllib.request.Request(self.url, data=json.dumps(body, ensure_ascii=False).encode('utf-8'), headers=headers)
        with self.opener.open(request, timeout=self.timeout) as response:
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            text = response.read().decode('utf-8')
        if not text:
            return {}
        if text.lstrip().startswith('{'):
            result = json.loads(text)
        else:
            # SSE may start with heartbeat comments, empty ping events or
            # notifications. Only the response for this request completes it.
            result = None
            for block in text.replace('\r\n', '\n').split('\n\n'):
                data = '\n'.join(line[5:].lstrip(' ') for line in block.splitlines()
                                 if line.startswith('data:'))
                if not data:
                    continue
                value = json.loads(data)
                if value.get('id') == self.sequence:
                    result = value
                    break
            if result is None:
                raise RuntimeError('MCP stream has no matching response')
        if result.get('id') != self.sequence:
            raise RuntimeError('MCP response id does not match the request')
        if 'error' in result:
            raise RuntimeError('MCP protocol error: ' + json.dumps(result['error'], ensure_ascii=False))
        return result.get('result', {})

    def call(self, name, arguments=None):
        result = self.request('tools/call', {'name': name, 'arguments': arguments or {}})
        if result.get('isError'):
            raise RuntimeError('MCP tool failed: ' + name)
        if 'structuredContent' in result:
            return result['structuredContent']
        texts = [item['text'] for item in result.get('content', []) if item.get('type') == 'text']
        if len(texts) == 1:
            try:
                return json.loads(texts[0])
            except json.JSONDecodeError:
                pass
        raise RuntimeError('MCP tool did not return structured status: ' + name)
