"""Native status polling must survive valid SSE heartbeats without replay."""
import json
import unittest
from unittest.mock import Mock

from mcp_client import Client


class NativeSseStatus(unittest.TestCase):
    def client(self, body):
        # Exercise the real HTTP-response/request decoder with one issued POST.
        client = Client.__new__(Client)
        client.url, client.timeout, client.session, client.sequence = 'http://host/mcp', 90, 'owned', 2
        response = Mock()
        response.headers = {}
        response.read.return_value = body.encode('utf-8')
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        client.opener = Mock()
        client.opener.open.return_value = response
        return client

    def test_comment_heartbeat_empty_ping_and_notifications_precede_multiline_status(self):
        status = {'data': {'indexing': {'running': False}, 'name': 'конфигурация ERP'}}
        envelope = json.dumps({'jsonrpc': '2.0', 'id': 3, 'result': {'structuredContent': status}},
                              ensure_ascii=False, indent=2)
        body = (': ping - 2026-11-02T17:31:51\r\n\r\nevent: ping\r\ndata:\r\n\r\n'
                'event: message\r\ndata: {"jsonrpc":"2.0","method":"notifications/message"}\r\n\r\n'
                'data: {"id":99,"result":{"wrong":true}}\r\n\r\nevent: message\r\n'
                + '\r\n'.join('data: ' + line for line in envelope.splitlines()) + '\r\n\r\n')
        client = self.client(body)
        self.assertEqual(client.call('stats'), status)
        self.assertEqual(client.opener.open.call_count, 1)
        request = client.opener.open.call_args.args[0]
        self.assertEqual(json.loads(request.data)['params']['name'], 'stats')
        self.assertEqual(request.get_header('Mcp-session-id'), 'owned')

    def test_plain_json_and_text_content_status_remain_supported(self):
        client = self.client(json.dumps({'id': 3, 'result': {'content': [
            {'type': 'text', 'text': '{"data":{"any_running":true}}'}]}}))
        self.assertEqual(client.call('get_indexing_status'), {'data': {'any_running': True}})

    def test_heartbeat_only_or_foreign_response_never_becomes_success_or_replays(self):
        for body in (': ping\n\n', 'event: ping\ndata:\n\n',
                     'data: {"id":99,"result":{}}\n\n', '{"id":99,"result":{}}'):
            with self.subTest(body=body):
                client = self.client(body)
                with self.assertRaises(RuntimeError):
                    client.call('stats')
                self.assertEqual(client.opener.open.call_count, 1)

    def test_real_protocol_tool_and_malformed_payload_failures_are_preserved(self):
        for body, error in (
            ('data: {"id":3,"error":{"code":-32603,"message":"failed"}}\n\n', RuntimeError),
            ('data: {"id":3,"result":{"isError":true}}\n\n', RuntimeError),
            ('data: malformed\n\ndata: {"id":3,"result":{}}\n\n', json.JSONDecodeError)):
            with self.subTest(body=body):
                client = self.client(body)
                with self.assertRaises(error):
                    client.call('stats')
                self.assertEqual(client.opener.open.call_count, 1)


if __name__ == '__main__':
    unittest.main()
