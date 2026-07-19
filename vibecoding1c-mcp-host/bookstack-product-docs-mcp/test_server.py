import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server


def make_settings(cache_path):
    return server.Settings(
        base_url="http://bookstack.local",
        token_id="token-id",
        token_secret="token-secret",
        cache_path=str(cache_path),
        timeout_seconds=5,
        host="127.0.0.1",
        port=8000,
        reindex_interval_hours=0,
        index_on_startup=False,
        max_index_pages=0,
        reset_database=False,
        embedding_api_base="",
        embedding_api_key="",
        embedding_model="",
        embedding_cache_dir=str(cache_path.parent / "models"),
    )


def page(page_id, body):
    return {
        "id": page_id,
        "name": f"Architecture {page_id}",
        "url": f"http://bookstack.local/books/product/page/{page_id}",
        "book_id": 10,
        "chapter_id": 20,
        "book": {"name": "Product"},
        "chapter": {"name": "Architecture"},
        "tags": [{"name": "architecture"}],
        "updated_at": "2026-07-19T00:00:00Z",
        "markdown": body,
        "html": "",
    }


class FakeClient:
    def __init__(self, pages):
        self.pages = {item["id"]: item for item in pages}

    def read_page(self, page_id):
        return self.pages[page_id]

    def export_page(self, page_id, fmt):
        return self.pages[page_id]["markdown"]

    def search(self, query, limit):
        return []

    def structure(self, scope, limit):
        values = []
        for index in range(limit):
            values.append(
                {
                    "id": index + 1,
                    "name": f"Item {index + 1}",
                    "url": f"http://bookstack.local/{scope}/{index + 1}",
                    "book_id": 10,
                    "description": "x" * 5000,
                    "books": [{"id": nested} for nested in range(100)],
                }
            )
        key = "pages" if scope == "all" else scope
        return {key: [server.compact_structure_item(item, key) for item in values]}


class BookStackClientStructureTests(unittest.TestCase):
    def test_all_scope_uses_one_balanced_total_limit_and_compacts_items(self):
        client = object.__new__(server.BookStackClient)
        calls = []

        def paginated(path, count=500, max_items=0):
            calls.append((path, max_items))
            return [
                {
                    "id": index + 1,
                    "name": f"Item {index + 1}",
                    "url": f"http://bookstack.local{path}/{index + 1}",
                    "description": "x" * 5000,
                    "books": [{"id": nested} for nested in range(100)],
                }
                for index in range(max_items)
            ]

        client.paginated = paginated
        result = client.structure("all", 30)

        self.assertEqual(sum(len(items) for items in result.values()), 30)
        self.assertEqual([limit for _, limit in calls], [8, 8, 7, 7])
        self.assertEqual(list(result), ["shelves", "books", "chapters", "pages"])
        self.assertNotIn("description", result["shelves"][0])
        self.assertNotIn("books", result["shelves"][0])


class ProductDocsServiceTests(unittest.TestCase):
    def make_service(self, temp_root, pages):
        service = server.ProductDocsService(make_settings(Path(temp_root) / "cache.sqlite"))
        service.client = FakeClient(pages)
        return service

    def test_search_returns_five_compact_results_by_default(self):
        pages = [page(index, f"Architecture decision {index}. " + "detail " * 200) for index in range(1, 9)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            result = service.search_docs("Architecture", filters=None, limit=server.DEFAULT_SEARCH_LIMIT)

        self.assertTrue(result["ok"])
        self.assertEqual(result["result_count"], 5)
        self.assertEqual(result["total_matches"], 8)
        self.assertEqual(result["cursor"], 0)
        self.assertEqual(result["next_cursor"], 5)
        self.assertTrue(result["has_more"])
        self.assertEqual(len(result["results"]), 5)
        self.assertNotIn("cache_pages", result)
        self.assertNotIn("embedding_enabled", result)
        self.assertNotIn("name", result["results"][0])
        self.assertNotIn("indexed_at", result["results"][0])
        self.assertLessEqual(len(result["results"][0]["preview"]), server.SEARCH_PREVIEW_CHARS + 6)
        self.assertLess(len(json.dumps(result, ensure_ascii=False)), 6000)
        self.assertIn("next_cursor=5", server.tool_result_summary("search", result))

    def test_search_cursor_pages_through_all_results_without_repeating_items(self):
        pages = [page(index, f"Architecture decision {index}.") for index in range(1, 13)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            first = service.search_docs("Architecture", filters=None, limit=5)
            second = service.search_docs("Architecture", filters=None, limit=5, cursor=first["next_cursor"])
            final = service.search_docs("Architecture", filters=None, limit=5, cursor=second["next_cursor"])

        result_ids = [item["id"] for result in (first, second, final) for item in result["results"]]
        self.assertEqual(len(result_ids), 12)
        self.assertEqual(len(set(result_ids)), 12)
        self.assertEqual(second["cursor"], 5)
        self.assertEqual(second["next_cursor"], 10)
        self.assertEqual(final["cursor"], 10)
        self.assertEqual(final["result_count"], 2)
        self.assertEqual(final["total_matches"], 12)
        self.assertFalse(final["has_more"])
        self.assertIsNone(final["next_cursor"])

    def test_search_rejects_negative_cursor(self):
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [])
            result = service.search_docs("Architecture", filters=None, limit=5, cursor=-1)

        self.assertFalse(result["ok"])
        self.assertIn("cursor", result["error"])

    def test_read_page_returns_query_window_and_cursor_instead_of_full_page(self):
        body = "# Intro\n" + ("intro text\n" * 2500) + "\n# Critical section\nneedle decision\n" + ("detail\n" * 2500)
        item = page(1, body)
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [item])
            default_window = service.read_page(1, "", "markdown")
            result = service.read_page(1, "", "markdown", query="needle decision", max_chars=1000)
            full = service.read_page(1, "", "markdown", max_chars=0)

        self.assertEqual(len(default_window["content"]), server.DEFAULT_PAGE_MAX_CHARS)
        self.assertTrue(default_window["truncated"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["selection"], "query")
        self.assertTrue(result["match_found"])
        self.assertIn("needle decision", result["content"])
        self.assertLessEqual(len(result["content"]), 1000)
        self.assertTrue(result["truncated"])
        self.assertIsNotNone(result["next_cursor"])
        summary = server.tool_result_summary("read", result)
        self.assertIn("1000/", summary)
        self.assertNotIn("needle decision", summary)
        self.assertGreater(full["total_chars"], server.DEFAULT_PAGE_MAX_CHARS)
        self.assertFalse(full["truncated"])

    def test_read_page_selects_markdown_heading_and_reports_missing_heading(self):
        body = "# Intro\nintro\n\n## Selected section\nselected text\n\n## Following section\nother text"
        item = page(1, body)
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [item])
            selected = service.read_page(1, "", "markdown", heading="Selected", max_chars=1000)
            missing = service.read_page(1, "", "markdown", heading="Missing", max_chars=1000)

        self.assertTrue(selected["ok"])
        self.assertIn("selected text", selected["content"])
        self.assertNotIn("other text", selected["content"])
        self.assertFalse(missing["ok"])
        self.assertIn("Selected section", missing["available_headings"])

    def test_structure_rejects_invalid_scope_and_caps_the_limit(self):
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, [])
            invalid = service.list_structure("invalid", 10)
            capped = service.list_structure("pages", 1000)

        self.assertFalse(invalid["ok"])
        self.assertEqual(capped["limit"], server.MAX_STRUCTURE_LIMIT)
        self.assertEqual(capped["result_count"], server.MAX_STRUCTURE_LIMIT)
        self.assertLess(len(json.dumps(capped, ensure_ascii=False)), 30000)


if __name__ == "__main__":
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout))
