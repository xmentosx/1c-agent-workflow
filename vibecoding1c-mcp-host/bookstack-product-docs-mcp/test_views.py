import asyncio
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

from test_server import FakeClient, make_settings, page
import server
from views import ACTIVE_VIEW, ViewRouter, effective_filters, load_views


class ViewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='BookStack scopes ')
        settings = replace(make_settings(Path(self.temp.name) / 'cache.sqlite'),
                           views_json=json.dumps({'corp': {'book_ids': [10]}}))
        self.service = server.ProductDocsService(settings)
        self.inside = page(1, 'shared marker')
        self.outside = dict(page(2, 'shared marker'), book_id=20)
        self.service.client = FakeClient([self.inside, self.outside])
        self.service.index_page(self.inside)
        self.service.index_page(self.outside)

    def tearDown(self):
        self.temp.cleanup()

    def test_negative_and_unknown_book_ids_cannot_leak_live_results(self):
        with self.assertRaises(ValueError):
            self.service.search_docs('marker', {'book_id': -1}, 5)
        self.service.client.search = lambda *args: [self.inside, self.outside]
        self.assertEqual([], self.service.search_docs('marker', {'book_id': 999}, 5)['results'])

    def test_view_filters_cache_and_live_and_rejects_foreign_reads_before_indexing(self):
        token = ACTIVE_VIEW.set('corp')
        try:
            self.service.client.search = lambda *args: [self.inside, self.outside]
            found = self.service.search_docs('marker', {'live': True}, 5)
            self.assertEqual([1], [item['id'] for item in found['results']])
            with mock.patch.object(self.service, 'index_page', side_effect=AssertionError('no foreign write')):
                self.assertFalse(self.service.read_page(2, '', 'markdown')['ok'])
            self.assertTrue(self.service.read_page(1, '', 'markdown')['ok'])
            self.assertEqual([1], [item['id'] for item in self.service.list_structure('pages', 20)['structure']['pages']])
            self.assertFalse(self.service.reindex_docs()['ok'])
        finally:
            ACTIVE_VIEW.reset(token)

    def test_semantic_branch_receives_the_same_narrowed_scope(self):
        token = ACTIVE_VIEW.set('corp')
        try:
            def semantic(query, limit, filters, *args):
                return [server.normalize_search_item(item) for item in [self.inside, self.outside]
                        if server.matches_filters(server.normalize_search_item(item), filters)]
            with mock.patch.object(self.service, 'semantic_results', side_effect=semantic):
                result = self.service.search_docs('marker', {}, 5, mode='semantic')
            self.assertEqual([1], [item['id'] for item in result['results']])
        finally:
            ACTIVE_VIEW.reset(token)

    def test_filters_only_narrow_view_and_empty_intersection_never_means_global(self):
        token = ACTIVE_VIEW.set('corp')
        try:
            narrowed = effective_filters({'book_ids': [20]}, self.service.views)
            self.assertEqual([], narrowed['book_ids'])
            self.assertFalse(server.matches_filters(server.normalize_search_item(self.inside), narrowed))
            self.assertFalse(server.matches_filters(server.normalize_search_item(self.outside), narrowed))
        finally:
            ACTIVE_VIEW.reset(token)

    def test_invalid_view_configuration_never_expands_to_global(self):
        with self.assertRaises(ValueError):
            effective_filters({'unknown_book_selector': 10}, self.service.views)
        for value in ({'corp': {}}, {'corp': {'book_ids': []}}, {'corp': {'book_ids': [-1]}},
                      {'corp': {'books': [10]}}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                load_views(json.dumps(value))

    def test_routes_are_request_local_without_redirect_or_cross_session_state(self):
        async def run():
            observations = []
            async def app(scope, receive, send):
                await asyncio.sleep(0)
                observations.append((scope['path'], ACTIVE_VIEW.get()))
                await send({'type': 'http.response.start', 'status': 200, 'headers': []})
                await send({'type': 'http.response.body', 'body': b'ok'})
            route = ViewRouter(app, self.service.views)
            async def request(path, query=b''):
                messages = []
                async def send(message): messages.append(message)
                await route({'type': 'http', 'path': path, 'query_string': query}, None, send)
                return messages[0]['status']
            values = await asyncio.gather(request('/views/corp/mcp'), request('/mcp'),
                                          request('/mcp', b'view=missing'), request('/mcp', b'view=corp'))
            self.assertEqual([200, 200, 404, 200], values)
            self.assertCountEqual([('/mcp', 'corp'), ('/mcp', ''), ('/mcp', 'corp')], observations)
            self.assertEqual('', ACTIVE_VIEW.get())
        asyncio.run(run())


if __name__ == '__main__':
    unittest.main()
