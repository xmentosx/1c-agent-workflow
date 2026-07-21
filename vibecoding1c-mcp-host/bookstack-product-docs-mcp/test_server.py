import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server


def make_settings(cache_path, embedding_model=""):
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
        semantic_min_score=server.DEFAULT_SEMANTIC_MIN_SCORE,
        reset_database=False,
        embedding_api_base="",
        embedding_api_key="",
        embedding_model=embedding_model,
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
        self.search_calls = []

    def read_page(self, page_id):
        return self.pages[page_id]

    def export_page(self, page_id, fmt):
        return self.pages[page_id]["markdown"]

    def search(self, query, limit):
        self.search_calls.append((query, limit))
        return []

    def list_pages(self, max_items=0):
        pages = list(self.pages.values())
        return pages[:max_items] if max_items else pages

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


class FakeEmbeddings:
    def __init__(self, profile="fake-model::retrieval-v2"):
        self.model = "fake-model"
        self.profile = profile
        self.cache_dir = "/fake/model-cache"
        self.query_inputs = []
        self.passage_inputs = []

    def enabled(self):
        return True

    def mode(self):
        return "fake"

    def storage_model(self):
        return self.profile

    def embed_query(self, text):
        self.query_inputs.append(text)
        return [1.0, 0.0]

    def embed_passage(self, text):
        self.passage_inputs.append(text)
        page_id = int(text.split("\n", 1)[0].rsplit(" ", 1)[-1])
        return [1.0, page_id / 100.0]


class LowConfidenceEmbeddings(FakeEmbeddings):
    def embed_passage(self, text):
        self.passage_inputs.append(text)
        return [0.8, 0.6]


class RankingEmbeddings(FakeEmbeddings):
    def embed_passage(self, text):
        self.passage_inputs.append(text)
        page_id = int(text.split("\n", 1)[0].rsplit(" ", 1)[-1])
        return [0.8, 0.6] if page_id == 1 else [1.0, 0.0]


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


class EmbeddingClientTests(unittest.TestCase):
    def test_multilingual_e5_uses_retrieval_prefixes_and_versioned_storage_key(self):
        with tempfile.TemporaryDirectory() as temp_root:
            settings = make_settings(
                Path(temp_root) / "cache.sqlite",
                embedding_model="intfloat/multilingual-e5-base",
            )
            client = server.EmbeddingClient(settings)
            inputs = []
            client.embed = lambda text: inputs.append(text) or [1.0]

            client.embed_query("заказ")
            client.embed_passage("Документ заказа")

        self.assertEqual(inputs, ["query: заказ", "passage: Документ заказа"])
        self.assertEqual(
            client.storage_model(),
            "intfloat/multilingual-e5-base::retrieval-v2::e5-prefixed",
        )


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

    def test_multi_term_search_requires_every_term_and_does_not_fill_partial_results_live(self):
        pages = [
            page(1, "Обмен знаниями."),
            page(2, "Модель данных."),
            page(3, "Обмен данными между системами."),
        ]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            for item in pages:
                service.index_page(item)
            result = service.search_docs("обмен данными", filters=None, limit=5)

        self.assertEqual([item["id"] for item in result["results"]], [3])
        self.assertEqual(service.client.search_calls, [])

    def test_low_confidence_semantic_results_are_not_returned_as_matches(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 6)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = LowConfidenceEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("unrelated semantic query", filters=None, limit=5)

        self.assertEqual(result["total_matches"], 0)
        self.assertEqual(result["results"], [])
        self.assertEqual(len(service.client.search_calls), 1)

    def test_confident_semantic_match_outranks_distributed_lexical_terms(self):
        pages = [
            page(1, "Обмен знаниями и модель с данными проекта."),
            page(2, "Трансляция экономической информации между системами."),
        ]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = RankingEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("обмен данными", filters=None, limit=5)

        self.assertEqual([item["id"] for item in result["results"]], [2, 1])
        self.assertGreater(result["results"][0]["semantic_score"], server.DEFAULT_SEMANTIC_MIN_SCORE)

    def test_semantic_search_uses_a_bounded_candidate_set(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 31)]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings()
            for item in pages:
                service.index_page(item)
            first = service.search_docs("term absent from every page", filters=None, limit=5)
            final = service.search_docs("term absent from every page", filters=None, limit=5, cursor=15)

        self.assertEqual(first["total_matches"], server.MAX_SEMANTIC_CANDIDATES)
        self.assertEqual(first["result_count"], 5)
        self.assertEqual(first["next_cursor"], 5)
        self.assertEqual(final["result_count"], 5)
        self.assertIsNone(final["next_cursor"])
        self.assertFalse(final["has_more"])

    def test_exact_search_match_stays_ahead_of_semantic_only_candidates(self):
        pages = [page(index, f"Product detail {index}.") for index in range(1, 31)]
        pages[-1]["markdown"] += " unique-needle"
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings()
            for item in pages:
                service.index_page(item)
            result = service.search_docs("unique-needle", filters=None, limit=5)

        self.assertEqual(result["results"][0]["id"], 30)
        self.assertIn("unique-needle", result["results"][0]["preview"])

    def test_reindex_refreshes_unchanged_pages_when_embedding_profile_changes(self):
        pages = [page(1, "Architecture decision.")]
        with tempfile.TemporaryDirectory() as temp_root:
            service = self.make_service(temp_root, pages)
            service.embeddings = FakeEmbeddings(profile="fake-model::old-profile")
            service.index_page(pages[0])
            service.embeddings.profile = "fake-model::retrieval-v2"
            result = service.reindex_docs(force=False)
            status = service.index_status()

        self.assertEqual(result["indexed"], 1)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(status["embedded_pages"], 1)
        self.assertEqual(status["embedding_profile"], "fake-model::retrieval-v2")

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
