import json
import tempfile
import unittest
from types import SimpleNamespace
from pathlib import Path

from test_index import FakeApi, ticket
from mantis_index import Index, SEARCH_CANDIDATE_LIMIT
from mantis_state import State


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Mantis scope ')
        root = Path(self.temp.name)
        self.state = State(root / 'state', root / 'files')
        self.index = Index(self.state, FakeApi())
        self.index.catalogs()

    def tearDown(self):
        self.state.close()
        self.temp.cleanup()

    def test_project_scope_precedes_10000_foreign_candidates_and_empty_query_cap(self):
        # Preserve the original 10000 global cap and exceed it with foreign data.
        # Batch the same persisted issue/fragment schema, not a reduced cap fixture.
        with self.state.transaction():
            for number in range(1, SEARCH_CANDIDATE_LIMIT + 2):
                item = ticket(number, project=1, text='sharedmarker')
                self.state.run('INSERT INTO issues VALUES(?,?,?,?,?,?,?)',
                               (number, 1, 2000000000, json.dumps(item), 'fixture', '', 0))
                key = str(number) + ':summary'
                self.state.run('INSERT INTO fragments VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                               (key, number, 'summary', 0, 0, 'summary', 'sharedmarker', 'sharedmarker', 'v', '', ''))
                self.state.run('INSERT INTO search_text(id,text) VALUES(?,?)', (key, 'sharedmarker'))
        self.state.put_issue(ticket(999999, project=2, text='sharedmarker'))
        for query in ('sharedmarker', ''):
            for filters in ({'project_ids': [2]}, {'project_id': 2}):
                with self.subTest(query=query, filters=filters):
                    found = self.index.search(query, filters=filters, semantic=False)
                    self.assertEqual([999999], [item['id'] for item in found['issues']])

    def test_union_empty_and_conflicting_scopes_do_not_widen(self):
        for identifier, project in ((1, 1), (2, 2), (3, 3)):
            self.state.put_issue(ticket(identifier, project=project, text='marker'))
        found = self.index.search('marker', filters={'project_ids': [2, 1, 2]}, semantic=False)
        self.assertEqual({1, 2}, {item['id'] for item in found['issues']})
        self.assertEqual([], self.index.search('', filters={'project_ids': []}, semantic=False)['issues'])
        for filters in ({'project_ids': '1'}, {'project_ids': [True]}, {'project_ids': [-1]},
                        {'project_ids': [1, 2], 'project_id': 1}):
            with self.subTest(filters=filters), self.assertRaises(ValueError):
                self.index.search('marker', filters=filters, semantic=False)

    def test_cursor_is_bound_to_the_canonical_project_union(self):
        for identifier in range(1, 5):
            self.state.put_issue(ticket(identifier, project=1 if identifier < 3 else 2, text='marker'))
        first = self.index.search('marker', filters={'project_ids': [2, 1]}, limit=1, semantic=False)
        second = self.index.search('marker', filters={'project_ids': [1, 2]}, limit=1,
                                   cursor=first['next_cursor'], semantic=False)
        self.assertNotEqual(first['issues'][0]['id'], second['issues'][0]['id'])
        with self.assertRaises(ValueError):
            self.index.search('marker', filters={'project_ids': [1]}, limit=1,
                              cursor=first['next_cursor'], semantic=False)

    def test_semantic_candidates_and_exact_ids_are_scoped_before_selection(self):
        self.state.put_issue(ticket(1, project=1, text='foreign'))
        self.state.put_issue(ticket(2, project=2, text='target'))
        self.state.run('UPDATE fragments SET vector_id=id,vector_version=version')
        self.index.embeddings = object()
        self.index.query_vector = lambda query: ([1.0, 0.0], 'hit')
        expected = {row['vector_id'] for row in self.state.all('SELECT vector_id FROM fragments WHERE issue_id=2')}
        calls = []
        def query(vector, allowed_ids=None):
            calls.append(set(allowed_ids))
            self.assertEqual(expected, set(allowed_ids))
            return list(allowed_ids)
        self.index.vectors = SimpleNamespace(query=query)
        result = self.index.search('semantic-only-no-lexical-match', filters={'project_ids': [2]})
        self.assertEqual([2], [item['id'] for item in result['issues']])
        self.assertEqual([expected], calls)
        self.assertEqual([], self.index.search('#1', filters={'project_ids': [2]}, semantic=False)['issues'])


if __name__ == '__main__':
    unittest.main()
