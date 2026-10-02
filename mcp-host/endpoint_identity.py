"""Read-only MCP identity proof shared by the existing Windows/Linux host owners.

Only a twice-observed foreign public endpoint with a healthy, idle internal
endpoint is repairable. Timeouts, tool failures and indexing never authorize a
restart. This module has no recovery, lock, configuration or persistent state.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request

SAFE_TOOLS = {'syntaxcheck', 'vector_store_state', 'list_templates', 'fetch_its',
              'index_status', 'health', 'sppr_index_status', 'stats', 'get_indexing_status'}


class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, url):
        if (code in (307, 308) and urllib.parse.urlsplit(request.full_url).netloc
                == urllib.parse.urlsplit(url).netloc):
            return urllib.request.Request(url, data=request.data, headers=dict(request.headers),
                                          method=request.get_method())
        raise RuntimeError('MCP redirect changed origin or POST semantics')


class Client:
    def __init__(self, url, timeout):
        self.url, self.timeout, self.session, self.sequence = url, timeout, None, 0
        self.protocol = '2025-03-26'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), Redirect())
        try:
            self.initialized = self.request('initialize', {
                'protocolVersion': self.protocol, 'capabilities': {},
                'clientInfo': {'name': 'itl-endpoint-identity', 'version': '1'}})
            self.protocol = self.initialized['protocolVersion']
            self.request('notifications/initialized', notification=True)
        except Exception:
            self.close()
            raise

    def headers(self):
        result = {'Content-Type': 'application/json; charset=utf-8',
                  'Accept': 'application/json, text/event-stream',
                  'MCP-Protocol-Version': self.protocol}
        if self.session:
            result['Mcp-Session-Id'] = self.session
        return result

    def request(self, method, params=None, notification=False):
        self.sequence += 1
        body = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            body['id'] = self.sequence
        if params is not None:
            body['params'] = params
        request = urllib.request.Request(self.url, json.dumps(body, ensure_ascii=False).encode('utf-8'),
                                         self.headers())
        with self.opener.open(request, timeout=self.timeout) as response:
            self.url = response.url
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            text = response.read().decode('utf-8')
        if notification:
            return {}
        if text.lstrip().startswith('{'):
            value = json.loads(text)
        else:
            values = [json.loads(line[5:].strip()) for line in text.splitlines() if line.startswith('data:')]
            value = next(item for item in values if item.get('id') == self.sequence)
        if value.get('error') or 'result' not in value:
            raise RuntimeError('MCP request failed: ' + method)
        return value['result']

    def close(self):
        if self.session:
            try:
                with self.opener.open(urllib.request.Request(self.url, headers=self.headers(), method='DELETE'),
                                      timeout=self.timeout):
                    pass
            except Exception:
                pass
            self.session = None


def structural(value, properties=False):
    if isinstance(value, dict):
        return {key: structural(item, key in ('properties', 'patternProperties'))
                for key, item in value.items() if properties or key != 'description'}
    if isinstance(value, list):
        return [structural(item) for item in value]
    return value


def payload(result):
    if result.get('isError'):
        raise RuntimeError('Safe MCP health tool reported an error')
    if 'structuredContent' in result:
        value = result['structuredContent']
    else:
        texts = [item['text'] for item in result.get('content', []) if item.get('type') == 'text']
        if len(texts) != 1:
            raise RuntimeError('Safe health tool returned no single status payload')
        value = json.loads(texts[0])
    if isinstance(value, dict) and isinstance(value.get('result'), str):
        value = json.loads(value['result'])
    if not isinstance(value, dict) or value.get('ok') is False or value.get('error') or value.get('status') == 'error':
        raise RuntimeError('Safe MCP health status failed')
    return value


def indexing(value):
    if not isinstance(value, dict):
        return False
    if value.get('index_in_progress') is True or value.get('is_indexing') is True:
        return True
    if isinstance(value.get('indexing'), dict) and value['indexing'].get('running') is True:
        return True
    if value.get('running') is True:
        return True
    return any(indexing(item) for item in value.values() if isinstance(item, dict))


def read_endpoint(url, timeout=5, health_tool='', health_arguments=None, expected_signature=None):
    client = Client(url, timeout)
    try:
        name = client.initialized.get('serverInfo', {}).get('name', '')
        tools = client.request('tools/list').get('tools', [])
        names = sorted(item['name'] for item in tools)
        if not name or not names or len(names) != len(set(names)):
            raise RuntimeError('MCP identity or tool catalog is empty/invalid')
        document = {'server': name, 'tools': sorted(structural(tools), key=lambda item: item['name'])}
        digest = hashlib.sha256(json.dumps(document, sort_keys=True, ensure_ascii=False,
                                          separators=(',', ':')).encode('utf-8')).hexdigest()
        busy = False
        if expected_signature and digest != expected_signature:
            raise RuntimeError('Public identity changed before safe call')
        if health_tool:
            if health_tool not in SAFE_TOOLS or health_tool not in names:
                raise RuntimeError('Required safe health tool is missing')
            busy = indexing(payload(client.request('tools/call', {
                'name': health_tool, 'arguments': health_arguments or {}})))
        return {'signature': digest, 'server_name': name, 'tool_count': len(names),
                'indexing': busy, 'health_passed': bool(health_tool)}
    finally:
        client.close()


def command(arguments, timeout=30):
    result = subprocess.run(arguments, capture_output=True, text=True, encoding='utf-8',
                            errors='strict', timeout=timeout)
    if result.returncode:
        raise RuntimeError('Endpoint probe child process failed')
    return result.stdout


def check_endpoint(container, url, host_port, health_tool='', health_arguments=None, timeout=5, run=command):
    stage = 'container binding'
    try:
        address = urllib.parse.urlsplit(url)
        if address.scheme not in ('http', 'https') or address.port != host_port or address.username:
            raise ValueError('Invalid tracked public endpoint')
        item = json.loads(run(['docker', 'inspect', container], timeout=10))[0]
        identity = item['Id']
        if (item['Name'] != '/' + container or item['State']['Status'] != 'running'
                or not re.fullmatch(r'[0-9a-f]{64}', identity)):
            raise ValueError('Tracked container identity/state changed')
        ports = [key.split('/')[0] for key, bindings in item['NetworkSettings']['Ports'].items()
                 if key.endswith('/tcp') and any(int(binding['HostPort']) == host_port for binding in bindings or [])]
        if len(ports) != 1:
            raise ValueError('Tracked public port has no unique container binding')
        internal_url = 'http://127.0.0.1:' + ports[0] + (address.path or '/mcp')
        encoded = base64.b64encode(Path(__file__).read_bytes()).decode('ascii')
        code = "import base64;exec(compile(base64.b64decode('" + encoded + "'),'<itl-endpoint-probe>','exec'))"
        arguments = ['--local', '--url', internal_url, '--timeout', str(timeout),
                     '--health-tool', health_tool, '--health-arguments', json.dumps(health_arguments or {})]
        # The script works without files or third-party libraries inside the container.
        stage = 'internal MCP'
        internal = json.loads(run(['docker', 'exec', identity, 'python', '-X', 'utf8', '-c', code] + arguments,
                                  timeout=timeout * 5 + 5))
        if internal.get('status') != 'matched':
            return {'status': 'unverified', 'reason': 'internal endpoint is not qualified'}
        expected = internal['proof']
        public = []
        for number in range(2):
            stage = 'public identity ' + str(number + 1)
            public.append(read_endpoint(url, timeout))
        matches = [proof['signature'] == expected['signature'] for proof in public]
        result = {'container_id': identity, 'expected_server': expected['server_name'],
                  'observed_servers': [proof['server_name'] for proof in public]}
        if all(matches):
            stage = 'public safe health'
            health = read_endpoint(url, timeout, health_tool, health_arguments, expected['signature'])
            if health['signature'] != expected['signature']:
                return dict(result, status='unverified', reason='identity changed before safe call')
            return dict(result, status='matched', indexing=expected['indexing'] or health['indexing'],
                        health_passed=health['health_passed'])
        if any(matches):
            return dict(result, status='unverified', reason='public identity is unstable')
        if expected['indexing']:
            return dict(result, status='indexing', reason='foreign endpoint; internal indexing is active')
        if not expected['health_passed']:
            return dict(result, status='unverified', reason='foreign endpoint; no safe internal health proof')
        return dict(result, status='mismatch', reason='foreign public identity confirmed twice')
    except Exception as error:
        # Never persist response bodies, environment, credentials or child command lines.
        return {'status': 'unverified', 'reason': type(error).__name__, 'stage': stage}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--local', action='store_true')
    parser.add_argument('--container')
    parser.add_argument('--url', required=True)
    parser.add_argument('--host-port', type=int)
    parser.add_argument('--health-tool', default='')
    parser.add_argument('--health-arguments', default='{}')
    parser.add_argument('--health-arguments-base64')
    parser.add_argument('--timeout', type=int, default=5)
    args = parser.parse_args()
    try:
        health_arguments = json.loads(base64.b64decode(args.health_arguments_base64).decode('utf-8')
                                      if args.health_arguments_base64 else args.health_arguments)
        if args.local:
            result = {'status': 'matched', 'proof': read_endpoint(args.url, args.timeout,
                       args.health_tool, health_arguments)}
        else:
            result = check_endpoint(args.container, args.url, args.host_port, args.health_tool,
                                    health_arguments, args.timeout)
    except Exception as error:
        result = {'status': 'unverified', 'reason': type(error).__name__}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
